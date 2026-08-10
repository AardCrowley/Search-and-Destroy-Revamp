-- areas.lua
-- Area data management: JSON seed loading, in-memory cross-reference,
-- maze room management, and CRUD for user/scraped (non-JSON) areas.
-- Depends on: constants.lua, util.lua, db.lua, characters.lua

-- ─── CONSTANTS ────────────────────────────────────────────────────────────────

-- Raw URL for the areas.json seed file.  Only fetched on fresh installs.
-- Resolved at call time through snd_raw_url() (XML preamble) rather than
-- hardcoded here, so the repository is named in exactly one place.
local function areas_json_url()
    if type(snd_raw_url) == "function" then return snd_raw_url("areas.json") end
    ErrorNote("SnD: remote source is not configured; cannot fetch areas.json.")
    return nil
end

-- ─── IN-MEMORY CROSS-REFERENCE ────────────────────────────────────────────────

-- Maps lowercased area name → area key string.
-- Built by build_area_name_xref() during init_plugin_after_load().
local _area_xref = {}

-- Returns the area key for a given area name (case-insensitive), or nil.
function area_key_from_name(name)
    if not name then return nil end
    return _area_xref[name:lower()]
end

-- Return the start_room id for the given area identifier.
-- exact=true  : arid must match areas.key exactly.
-- exact=false : tries exact key first, then falls back to a substring search on key and name.
-- Returns a positive integer room id, or nil if no start room is set.
function get_start_room(arid, exact)
    if not arid or arid == "" then return nil end
    local db  = db_open()
    local rid = nil

    -- Always try exact key match first.
    for row in db:nrows(
        "SELECT start_room FROM areas WHERE key=" .. fixsql(arid) ..
        " AND start_room IS NOT NULL LIMIT 1"
    ) do
        rid = row.start_room
    end

    -- Partial/name fallback when exact=false and key match found nothing.
    if not rid and not exact then
        local lc = arid:lower()
        -- Try the in-memory name xref first (fast path).
        local key = _area_xref[lc]
        if key then
            for row in db:nrows(
                "SELECT start_room FROM areas WHERE key=" .. fixsql(key) ..
                " AND start_room IS NOT NULL LIMIT 1"
            ) do
                rid = row.start_room
            end
        end
        -- Last resort: LIKE search on key and name columns.
        if not rid then
            for row in db:nrows(
                "SELECT start_room FROM areas " ..
                "WHERE (key LIKE " .. fixsql("%" .. arid .. "%") ..
                "    OR name LIKE " .. fixsql("%" .. arid .. "%") .. ")" ..
                " AND start_room IS NOT NULL LIMIT 1"
            ) do
                rid = row.start_room
            end
        end
    end

    db_close(db)
    return rid and tonumber(rid) or nil
end

-- Build (or rebuild) the in-memory area name → key cross-reference from the DB.
-- Called once at plugin load; safe to call again after areas table changes.
function build_area_name_xref()
    _area_xref = {}
    local db = db_open()
    for row in db:nrows("SELECT key, name FROM areas") do
        _area_xref[row.name:lower()] = row.key
    end
    db_close(db)
end

-- ─── MARKS: USER-DEFINED ROOM SHORTCUTS ──────────────────────────────────────

-- Look up a custom mark by name (case-insensitive). Returns the room_id or nil.
function get_mark_room(name)
    if not name or name == "" then return nil end
    local db  = db_open()
    local rid = nil
    for row in db:nrows(
        "SELECT room_id FROM marks WHERE name=" .. fixsql(name) .. " LIMIT 1"
    ) do
        rid = row.room_id
    end
    db_close(db)
    return rid and tonumber(rid) or nil
end

-- Fetch all marks ordered by name.
-- Returns array of {id, name, room_id, area_name, room_name}.
local function db_get_all_marks()
    local db   = db_open()
    local rows = {}
    for row in db:nrows(
        "SELECT id, name, room_id, area_name, room_name FROM marks ORDER BY name ASC"
    ) do
        rows[#rows + 1] = {
            id        = row.id,
            name      = row.name,
            room_id   = row.room_id,
            area_name = row.area_name or "",
            room_name = row.room_name or "",
        }
    end
    db_close(db)
    return rows
end

-- Return the area_name and room_name for the current GMCP room if its id
-- matches roomid, otherwise return empty strings.
local function gmcp_room_info(roomid)
    local cur = tonumber(gmcp("room.info.num") or "")
    if cur == roomid then
        return gmcp("room.info.zone") or "", gmcp("room.info.name") or ""
    end
    return "", ""
end

-- If mark_name exactly matches a known area key that has no start room set,
-- also fill in areas.start_room.  xset_area_list_unset's own hint text
-- promises this ("visit entry point, then: xset mark"), and real routing
-- (area_anchor_room in pathing.lua, get_start_room's exact-key lookup) only
-- ever reads areas.start_room -- a same-named mark alone doesn't help
-- anything but 'xrt <name>'.  Only fills a genuinely empty start_room;
-- never overwrites one that's already configured.
-- Returns true if it filled in a start room.
local function _fill_area_start_room_from_mark(db, mark_name, roomid)
    local key = mark_name:lower()
    local found, existing = false, nil
    for row in db:nrows(
        "SELECT start_room FROM areas WHERE key=" .. fixsql(key) .. " LIMIT 1"
    ) do
        found = true
        existing = tonumber(row.start_room)
    end
    if not found or (existing and existing > 0) then return false end

    dbcheck(db, db:exec(
        "UPDATE areas SET start_room=" .. roomid .. ", updated_at=" .. os.time() ..
        " WHERE key=" .. fixsql(key)
    ), "_fill_area_start_room_from_mark")
    return true
end

-- Alias handler: 'xset mark'  (no arguments)
-- Inserts a mark for the current room using the GMCP zone name as the mark name.
function xset_mark_current(name, line, wildcards)
    local zone   = gmcp("room.info.zone") or ""
    local roomid = tonumber(gmcp("room.info.num") or "")
    local rname  = strip_colours(gmcp("room.info.name") or "")

    if zone == "" or not roomid or roomid <= 0 then
        ErrorNote("SnD: No room data available — are you connected and in a room?")
        return
    end

    local db = db_open()
    if not dbguard(db, db:exec(
        "INSERT OR REPLACE INTO marks (name, room_id, area_name, room_name) VALUES (" ..
        fixsql(zone) .. ", " .. tostring(roomid) .. ", " ..
        fixsql(zone) .. ", " .. fixsql(rname) .. ")"
    ), "xset_mark_current") then return end
    local filled_start = _fill_area_start_room_from_mark(db, zone, roomid)
    db_close(db)

    InfoNote(string.format(
        "SnD: Mark '%s' → %s (room %d) saved. Use 'xrt %s' to navigate here.",
        zone, rname ~= "" and rname or "unknown room", roomid, zone))
    if filled_start then
        InfoNote(string.format(
            "SnD: '%s' had no start room configured — set it to room %d.", zone, roomid))
    end
end

-- Alias handler: 'xset mark <name> <roomid>'
-- Inserts or replaces a named room shortcut.
-- If the player is currently standing in <roomid>, area_name and room_name
-- are captured from GMCP automatically.
function xset_mark_set(name, line, wildcards)
    local mname  = Trim((wildcards and (wildcards.mname  or wildcards[1])) or "")
    local roomid = tonumber((wildcards and (wildcards.roomid or wildcards[2])) or "")
    if mname == "" or not roomid or roomid <= 0 then
        InfoNote("SnD: Usage: xset mark <name> <roomid>")
        InfoNote("SnD: Example: xset mark bloodlust 45933")
        return
    end
    local area_name, room_name = gmcp_room_info(roomid)
    local db = db_open()
    if not dbguard(db, db:exec(
        "INSERT OR REPLACE INTO marks (name, room_id, area_name, room_name) VALUES (" ..
        fixsql(mname)      .. ", " .. tostring(roomid) .. ", " ..
        fixsql(area_name)  .. ", " .. fixsql(room_name) .. ")"
    ), "xset_mark_set") then return end
    local filled_start = _fill_area_start_room_from_mark(db, mname, roomid)
    db_close(db)

    local loc = (room_name ~= "" and room_name) or ("room " .. roomid)
    InfoNote(string.format(
        "SnD: Mark '%s' → %s saved. Use 'xrt %s' to navigate there.",
        mname, loc, mname))
    if filled_start then
        InfoNote(string.format(
            "SnD: '%s' had no start room configured — set it to room %d.", mname, roomid))
    end
end

-- ─── MARKS TABLE DISPLAY ─────────────────────────────────────────────────────

-- Column widths for the marks table (content width, not including borders).
local MW_NUM  = 4
local MW_NAME = 22
local MW_AREA = 14
local MW_ROOM = 30
local MW_VNUM = 6

-- Truncate/pad s to exactly n chars.
local function mpad(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n - 1) .. "…" end
    return s .. string.rep(" ", n - #s)
end
local function mpad_r(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n) end
    return string.rep(" ", n - #s) .. s
end

-- Row of separator dashes.
local _MARKS_BORDER =
    "+" .. string.rep("-", MW_NUM  + 2) ..
    "+" .. string.rep("-", MW_NAME + 2) ..
    "+" .. string.rep("-", MW_AREA + 2) ..
    "+" .. string.rep("-", MW_ROOM + 2) ..
    "+" .. string.rep("-", MW_VNUM + 2) .. "+"

-- Print a formatted table of marks rows.  All rows is the full sorted list so
-- indices (i) are globally stable for edit/delete commands.
-- If filter_fn is provided only rows where filter_fn(row) is true are shown,
-- but they are displayed with their original index.
local function marks_print_table(all_rows, filter_fn, title)
    local C_BORDER = ColourNameToRGB "gray"
    local C_HEADER = ColourNameToRGB "white"
    local C_ODD    = ColourNameToRGB "silver"
    local C_EVEN   = ColourNameToRGB "lightcyan"
    local C_NAME   = ColourNameToRGB "yellow"
    local C_STAR   = ColourNameToRGB "lightgreen"
    local C_BG     = ColourNameToRGB "black"

    local old_fg = GetNoteColourFore()

    -- Helper: print one color segment without newline.
    local function t(fg, text) ColourTell(fg, C_BG, text) end

    -- Header line above the table.
    if title then
        SetNoteColourFore(C_HEADER)
        Note(title)
    end

    SetNoteColourFore(C_BORDER)
    Note(_MARKS_BORDER)

    -- Column headers.
    t(C_BORDER, "| ")
    t(C_HEADER, mpad_r("#", MW_NUM))
    t(C_BORDER, " | ")
    t(C_HEADER, mpad("name", MW_NAME))
    t(C_BORDER, " | ")
    t(C_HEADER, mpad("area", MW_AREA))
    t(C_BORDER, " | ")
    t(C_HEADER, mpad("room name", MW_ROOM))
    t(C_BORDER, " | ")
    t(C_HEADER, mpad_r("vnum", MW_VNUM))
    t(C_BORDER, " |")
    Note("")

    SetNoteColourFore(C_BORDER)
    Note(_MARKS_BORDER)

    local printed = 0
    for i, row in ipairs(all_rows) do
        if not filter_fn or filter_fn(row) then
            local C_ROW = (printed % 2 == 0) and C_ODD or C_EVEN
            local area  = row.area_name ~= "" and row.area_name or "?"
            local rname = row.room_name ~= "" and row.room_name or "?"
            local marked = (row.area_name == "" or row.room_name == "") and "*" or " "
            t(C_BORDER, "|")
            t(C_STAR,   marked)
            t(C_ROW,    mpad_r(i, MW_NUM))
            t(C_BORDER, " | ")
            t(C_NAME,   mpad(row.name, MW_NAME))
            t(C_BORDER, " | ")
            t(C_ROW,    mpad(area,     MW_AREA))
            t(C_BORDER, " | ")
            t(C_ROW,    mpad(rname,    MW_ROOM))
            t(C_BORDER, " | ")
            t(C_ROW,    mpad_r(row.room_id, MW_VNUM))
            t(C_BORDER, " |")
            Note("")
            printed = printed + 1
        end
    end

    SetNoteColourFore(C_BORDER)
    Note(_MARKS_BORDER)

    SetNoteColourFore(old_fg)
    return printed
end

-- Alias handler: 'xset marks'
-- Prints a numbered list of all user-defined marks.
function xset_marks_list(name, line, wildcards)
    local rows = db_get_all_marks()
    if #rows == 0 then
        InfoNote("SnD: No marks defined. Use 'xset mark <name> <roomid>' to add one.")
        return
    end
    local title = string.format("Marks (%d):", #rows)
    marks_print_table(rows, nil, title)
    InfoNote("  * = room/area name not yet resolved from mapper DB.")
    InfoNote("  Commands: xset marks edit <#>  |  xset marks delete <#>  |  xset marks <search>")
end

-- Alias handler: 'xset marks <keyword>'
-- Shows marks whose name, area, or room name contains the keyword (case-insensitive).
function xset_marks_search(name, line, wildcards)
    local kw = Trim((wildcards and (wildcards.kw or wildcards[1])) or "")
    if kw == "" then xset_marks_list(name, line, wildcards); return end
    local rows = db_get_all_marks()
    if #rows == 0 then
        InfoNote("SnD: No marks defined.")
        return
    end
    local lkw = kw:lower()
    local function matches(row)
        return row.name:lower():find(lkw, 1, true) or
               row.area_name:lower():find(lkw, 1, true) or
               row.room_name:lower():find(lkw, 1, true) or
               tostring(row.room_id):find(lkw, 1, true)
    end
    local title = string.format("Marks matching '%s':", kw)
    local n = marks_print_table(rows, matches, title)
    if n == 0 then
        InfoNote(string.format("SnD: No marks match '%s'.", kw))
    else
        InfoNote(string.format("  %d match%s. Index numbers are global (for edit/delete).",
            n, n == 1 and "" or "es"))
    end
end

-- Alias handler: 'xset marks edit <N>'
-- Opens inputboxes pre-filled with the current name and room for entry N.
-- If the player is standing in the new room, area_name/room_name are refreshed.
function xset_marks_edit(name, line, wildcards)
    local idx = tonumber((wildcards and (wildcards.idx or wildcards[1])) or "")
    if not idx then
        InfoNote("SnD: Usage: xset marks edit <#>  (see 'xset marks' for numbers)")
        return
    end
    local rows = db_get_all_marks()
    local row  = rows[idx]
    if not row then
        InfoNote(string.format("SnD: No entry #%d. Run 'xset marks' to see valid numbers.", idx))
        return
    end

    local function nonempty(s)  return #Trim(s) > 0 end
    local function isnumber(s)  return tonumber(Trim(s)) ~= nil end

    local new_name = utils.inputbox(
        string.format("Edit name for mark (currently → room %d).", row.room_id),
        "Mark name", row.name, nil, 0, { validate = nonempty }
    )
    if not new_name then return end
    new_name = Trim(new_name)

    local new_room_str = utils.inputbox(
        string.format("Edit room ID for mark '%s'.", new_name),
        "Room ID", tostring(row.room_id), nil, 0, { validate = isnumber }
    )
    if not new_room_str then return end
    local new_room = tonumber(Trim(new_room_str))

    -- Refresh area/room name from GMCP if standing in the (possibly new) room.
    local area_name, room_name = gmcp_room_info(new_room)
    -- If GMCP didn't match, preserve existing names when the room id didn't change.
    if area_name == "" and new_room == row.room_id then
        area_name = row.area_name
        room_name = row.room_name
    end

    local db = db_open()
    if not dbguard(db, db:exec("DELETE FROM marks WHERE id=" .. tostring(row.id)),
                   "xset_marks_edit delete") then return end
    if not dbguard(db, db:exec(
        "INSERT OR REPLACE INTO marks (name, room_id, area_name, room_name) VALUES (" ..
        fixsql(new_name)  .. ", " .. tostring(new_room) .. ", " ..
        fixsql(area_name) .. ", " .. fixsql(room_name)  .. ")"
    ), "xset_marks_edit insert") then return end
    local filled_start = _fill_area_start_room_from_mark(db, new_name, new_room)
    db_close(db)

    local loc = (room_name ~= "" and room_name) or ("room " .. new_room)
    InfoNote(string.format("SnD: Mark updated: '%s' → %s.", new_name, loc))
    if filled_start then
        InfoNote(string.format(
            "SnD: '%s' had no start room configured — set it to room %d.", new_name, new_room))
    end
end

-- Alias handler: 'xset marks delete <N>'
-- Deletes mark entry N by its database id.
function xset_marks_delete(name, line, wildcards)
    local idx = tonumber((wildcards and (wildcards.idx or wildcards[1])) or "")
    if not idx then
        InfoNote("SnD: Usage: xset marks delete <#>  (see 'xset marks' for numbers)")
        return
    end
    local rows = db_get_all_marks()
    local row  = rows[idx]
    if not row then
        InfoNote(string.format("SnD: No entry #%d. Run 'xset marks' to see valid numbers.", idx))
        return
    end
    local db = db_open()
    if not dbguard(db, db:exec("DELETE FROM marks WHERE id=" .. tostring(row.id)),
                   "xset_marks_delete") then return end
    db_close(db)
    local loc = row.room_name ~= "" and row.room_name or ("room " .. row.room_id)
    InfoNote(string.format("SnD: Mark '%s' (%s) deleted.", row.name, loc))
end

-- ─── LEGACY VARIABLE IMPORT ──────────────────────────────────────────────────

-- Alias handler: 'xset import'
-- One-time import of mcvar_area_range and mcvar_areaStartRooms from the
-- old plugin state into the current database.  Safe to re-run — uses
-- INSERT OR IGNORE / UPDATE so nothing is duplicated or overwritten blindly.
--
-- mcvar_area_range:     inserts area rows not already present (source='scrape').
-- mcvar_areaStartRooms: for each key —
--   · known area key, same room   → skip
--   · known area key, diff room   → update areas.start_room
--   · unknown key                 → insert into marks as a user shortcut
function xset_import_area_vars(name, line, wildcards)
    local imported_areas  = 0
    local updated_starts  = 0
    local imported_marks  = 0
    local skipped         = 0

    local _pid = GetPluginID()

    -- ── Part A: mcvar_area_range ──────────────────────────────────────────────
    local range_raw  = GetPluginVariable(_pid, "mcvar_area_range")
    local starts_raw = GetPluginVariable(_pid, "mcvar_areaStartRooms")

    if (not range_raw or range_raw == "") and (not starts_raw or starts_raw == "") then
        InfoNote("SnD: mcvar_area_range and mcvar_areaStartRooms are not set — nothing to import.")
        InfoNote("SnD: These variables come from the old plugin state. If you have no prior")
        InfoNote("SnD: installation, use 'xset mark <name> <roomid>' to add marks manually.")
        return
    end

    local db = db_open()

    -- Open the GMCP mapper SQLite database for room/area name lookups.
    -- mapper_db_file is set in db.lua from the mapper plugin variable.
    local mapdb = mapper_db_file and sqlite3.open(mapper_db_file) or nil

    -- Given a room vnum, return area_name and room_name from the mapper DB,
    -- in that order (matching the `local aname, rname = ...` call site below).
    -- Falls back to empty strings if the mapper DB is unavailable or the room
    -- hasn't been mapped yet.
    local function mapper_room_info(rid)
        if not mapdb then return "", "" end
        for row in mapdb:nrows(
            "SELECT r.name AS rname, a.name AS aname " ..
            "FROM rooms r LEFT JOIN areas a ON r.area = a.uid " ..
            "WHERE r.uid = " .. tostring(rid) .. " LIMIT 1"
        ) do
            return row.aname or "", row.rname or ""
        end
        return "", ""
    end

    if range_raw and range_raw ~= "" then
        local ok, obj = pcall(function() return (loadstring("return " .. range_raw))() end)
        if ok and type(obj) == "table" then
            for disp_name, data in pairs(obj) do
                local key = type(data) == "table" and data.arid
                if type(key) == "string" and key ~= "" then
                    local mn = tonumber(data.min)
                    local mx = tonumber(data.max)
                    db:exec(
                        "INSERT OR IGNORE INTO areas (key, name, minlvl, maxlvl, source) " ..
                        "VALUES (" .. fixsql(key) .. ", " .. fixsql(tostring(disp_name)) ..
                        ", " .. (mn or 1) .. ", " .. (mx or 201) .. ", 'scrape')"
                    )
                    if db:changes() > 0 then imported_areas = imported_areas + 1 end
                end
            end
        end
    end

    -- ── Part B: mcvar_areaStartRooms ─────────────────────────────────────────
    if starts_raw and starts_raw ~= "" then
        local ok, obj = pcall(function() return (loadstring("return " .. starts_raw))() end)
        if not ok then
            InfoNote("SnD import: areaStartRooms parse error: " .. tostring(obj))
        elseif type(obj) == "table" then
            for key, data in pairs(obj) do
                local roomid = type(data) == "table" and tonumber(data.roomid)
                if type(key) == "string" and key ~= "" and roomid and roomid > 0 then
                    local lc_key     = key:lower()
                    local area_start = nil
                    local area_row   = nil
                    for row in db:nrows(
                        "SELECT start_room FROM areas WHERE key=" .. fixsql(lc_key) .. " LIMIT 1"
                    ) do
                        area_row  = row
                        area_start = tonumber(row.start_room)
                    end

                    if area_row then
                        -- Key is a known area keyword → update its start room if different.
                        if area_start ~= roomid then
                            db:exec(
                                "UPDATE areas SET start_room=" .. roomid ..
                                " WHERE key=" .. fixsql(lc_key)
                            )
                            updated_starts = updated_starts + 1
                        else
                            skipped = skipped + 1
                        end
                    else
                        -- Key is a user mark.  Look up room/area names from the mapper DB.
                        local aname, rname = mapper_room_info(roomid)
                        local ins_ok, ins_err = pcall(function()
                            dbcheck(db, db:exec(
                                "INSERT OR IGNORE INTO marks (name, room_id, area_name, room_name) " ..
                                "VALUES (" .. fixsql(key) .. ", " .. roomid ..
                                ", " .. fixsql(aname) .. ", " .. fixsql(rname) .. ")"
                            ), "import marks insert")
                        end)
                        if not ins_ok then
                            InfoNote("SnD import: INSERT failed for '" .. key ..
                                     "': " .. tostring(ins_err))
                        elseif db:changes() > 0 then
                            imported_marks = imported_marks + 1
                        end
                    end
                end
            end
        end
    end

    if mapdb then mapdb:close() end
    db_close(db)

    InfoNote(string.format(
        "SnD: Import complete — %d area(s) added, %d start room(s) updated, " ..
        "%d mark(s) added, %d skipped.",
        imported_areas, updated_starts, imported_marks, skipped))
    if imported_marks > 0 then
        InfoNote("SnD: Room names will be filled in automatically as you visit each marked room.")
    end
end

-- ─── IN-MEMORY MAZE ROOM CACHE ────────────────────────────────────────────────

-- Rebuilds the global mazeStartRooms table from the DB.
-- mazeStartRooms is the in-memory cache used by existing scan display code.
-- Format: mazeStartRooms[roomid] = { areaname = zone_key }
function load_maze_rooms_cache()
    mazeStartRooms = {}
    local db = db_open()
    for row in db:nrows("SELECT roomid, zone FROM maze_rooms") do
        mazeStartRooms[row.roomid] = { areaname = row.zone }
    end
    db_close(db)
end

-- ─── JSON SEED ────────────────────────────────────────────────────────────────

-- Initiate an async download of areas.json if the areas table is empty.
-- Returns immediately; the actual insert happens in areas_json_received().
function fetch_areas_if_empty()
    local db = db_open()
    local count = 0
    for row in db:nrows("SELECT COUNT(*) AS n FROM areas") do
        count = row.n
    end
    db_close(db)

    if count > 0 then return end

    InfoNote("SnD: Areas table is empty. Fetching areas.json ...")
    if type(async) ~= "table" then
        local ok
        ok, async = pcall(require, "async")
        if not ok then
            ErrorNote("SnD: 'async' library not available. Cannot fetch areas.json.")
            return
        end
    end
    local url = areas_json_url()
    if not url then return end
    -- snd_http_get (XML preamble) owns loading async and picking the third
    -- argument, which has meant different things across package versions.
    snd_http_get(url, "areas_json_received")
end

-- Callback fired by MUSHclient when the areas.json async request completes.
-- Parses JSON and inserts rows into the areas table with source = 'json'.
function areas_json_received(url, status, content)
    if status ~= 200 then
        ErrorNote("SnD: Failed to fetch areas.json (HTTP " .. tostring(status) .. ")")
        return
    end

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        ErrorNote("SnD: Failed to parse areas.json: " .. tostring(data))
        return
    end

    local db = db_open()
    local inserted = 0

    local insert_ok, insert_err = pcall(function()
        execute_in_transaction(db, function(db)
            for _, entry in ipairs(data) do
                if type(entry.key) == "string" and entry.key ~= "" then
                    local start_sql
                    local sr = tonumber(entry.start_room)
                    if sr and sr > 0 then
                        start_sql = tostring(sr)
                    else
                        start_sql = "NULL"
                    end
                    db:exec(
                        "INSERT OR IGNORE INTO areas " ..
                        "(key, name, minlvl, maxlvl, lock, start_room, noquest, vidblain, source) " ..
                        "VALUES (" ..
                        fixsql(entry.key)                         .. ", " ..
                        fixsql(entry.name or entry.key)           .. ", " ..
                        tostring(tonumber(entry.minlvl) or 1)     .. ", " ..
                        tostring(tonumber(entry.maxlvl) or 201)   .. ", " ..
                        tostring(tonumber(entry.lock)   or 0)     .. ", " ..
                        start_sql                                  .. ", " ..
                        (entry.noquest  and "1" or "0")           .. ", " ..
                        (entry.vidblain and "1" or "0")           .. ", " ..
                        "'json'" ..
                        ")"
                    )
                    if db:changes() > 0 then inserted = inserted + 1 end
                end
            end
        end)
    end)

    db_close(db)

    if not insert_ok then
        ErrorNote("SnD: areas.json insert failed: " .. tostring(insert_err))
        return
    end

    build_area_name_xref()
    InfoNote("SnD: Loaded " .. inserted .. " areas from areas.json.")
end

-- ─── MAZE ROOM MANAGEMENT ─────────────────────────────────────────────────────

-- Add roomid to the maze_rooms table under the given zone key.
-- Also updates the in-memory mazeStartRooms cache.
function maze_room_add(roomid, zone)
    local rid = tonumber(roomid)
    if not rid or rid <= 0 then
        ErrorNote("SnD: maze_room_add: invalid room ID: " .. tostring(roomid))
        return
    end

    local char_id = get_current_char_id()
    local db = db_open()
    -- Return before touching the cache: if the write failed, adding the room
    -- in memory anyway would leave the cache claiming a maze room the DB does
    -- not have, and it would silently vanish on the next reload.
    if not dbguard(db, db:exec(
        "INSERT OR IGNORE INTO maze_rooms (roomid, zone, added_by) VALUES (" ..
        rid .. ", " ..
        fixsql(tostring(zone)) .. ", " ..
        (char_id and tostring(char_id) or "NULL") .. ")"
    ), "maze_room_add") then return end
    db_close(db)

    -- Keep in-memory cache consistent.
    mazeStartRooms[rid] = { areaname = zone }
end

-- Remove roomid from the maze_rooms table.
-- Also updates the in-memory mazeStartRooms cache.
function maze_room_delete(roomid)
    local rid = tonumber(roomid)
    if not rid then
        ErrorNote("SnD: maze_room_delete: invalid room ID: " .. tostring(roomid))
        return
    end

    local db = db_open()
    if not dbguard(db, db:exec(
        "DELETE FROM maze_rooms WHERE roomid=" .. rid
    ), "maze_room_delete") then return end
    db_close(db)

    mazeStartRooms[rid] = nil
end

-- Return all maze room rows as a list of {roomid, zone, area_name} tables,
-- ordered by zone then roomid.
function maze_room_list()
    local rows = {}
    local db = db_open()
    for row in db:nrows(
        "SELECT mr.roomid, mr.zone, a.name AS area_name " ..
        "FROM maze_rooms mr " ..
        "LEFT JOIN areas a ON a.key = mr.zone " ..
        "ORDER BY mr.zone, mr.roomid"
    ) do
        rows[#rows + 1] = {
            roomid    = row.roomid,
            zone      = row.zone,
            area_name = row.area_name or row.zone,
        }
    end
    db_close(db)
    return rows
end

-- Returns true if roomid is a registered maze start room (uses in-memory cache).
function is_maze_room(roomid)
    local rid = tonumber(roomid)
    if not rid then return false end
    return mazeStartRooms[rid] ~= nil
end

-- ─── AREA CRUD (non-JSON areas) ───────────────────────────────────────────────

-- Return all areas where source != 'json', ordered by key.
-- These are in-game scraped or user-added areas that the user may edit/delete.
function area_list_custom()
    local rows = {}
    local db = db_open()
    for row in db:nrows(
        "SELECT key, name, minlvl, maxlvl, lock, start_room, noquest, vidblain, difficulty, source " ..
        "FROM areas WHERE source != 'json' " ..
        "  AND NOT (minlvl = 210 AND maxlvl = 210) " ..
        "  AND NOT (minlvl = 0   AND maxlvl = 0) " ..
        "ORDER BY key"
    ) do
        rows[#rows + 1] = {
            key        = row.key,
            name       = row.name,
            minlvl     = row.minlvl,
            maxlvl     = row.maxlvl,
            lock       = row.lock,
            start_room = row.start_room,
            noquest    = row.noquest == 1,
            vidblain   = row.vidblain == 1,
            difficulty = tonumber(row.difficulty) or 1,
            source     = row.source,
        }
    end
    db_close(db)
    return rows
end

-- Return areas that have no known start room (start_room IS NULL or < 0),
-- excluding clan areas (210-210) and non-player areas (0-0) which don't
-- have meaningful entry points.  Used by 'xset area list unset'.
function area_list_no_start()
    local rows = {}
    local db = db_open()
    for row in db:nrows(
        "SELECT key, name, minlvl, maxlvl, lock, start_room, source " ..
        "FROM areas " ..
        "WHERE (start_room IS NULL OR start_room < 0) " ..
        "  AND NOT (minlvl = 210 AND maxlvl = 210) " ..
        "  AND NOT (minlvl = 0   AND maxlvl = 0) " ..
        "ORDER BY source, key"
    ) do
        rows[#rows + 1] = {
            key    = row.key,
            name   = row.name,
            minlvl = row.minlvl,
            maxlvl = row.maxlvl,
            lock   = row.lock,
            source = row.source,
        }
    end
    db_close(db)
    return rows
end

-- Delete a non-JSON area by key.
-- Returns true on success.  Prints an error and returns false on failure.
function area_delete(key)
    if not key or key == "" then
        ErrorNote("SnD: area_delete: no key provided")
        return false
    end

    local db = db_open()
    local source = nil
    for row in db:nrows(
        "SELECT source FROM areas WHERE key=" .. fixsql(key)
    ) do
        source = row.source
    end

    if source == nil then
        db_close(db)
        ErrorNote("SnD: Area '" .. key .. "' not found.")
        return false
    end
    if source == "json" then
        db_close(db)
        ErrorNote("SnD: Cannot delete '" .. key .. "' — it is a base area seeded from areas.json.")
        return false
    end

    dbcheck(db, db:exec(
        "DELETE FROM areas WHERE key=" .. fixsql(key)
    ), "area_delete")
    db_close(db)

    -- Remove the deleted area from the name cross-reference.
    for name, k in pairs(_area_xref) do
        if k == key then
            _area_xref[name] = nil
            break
        end
    end

    return true
end

-- Edit one field of a non-JSON area.
-- field: "start_room" | "minlvl" | "maxlvl" | "lock" | "noquest" | "vidblain" | "difficulty" | "name"
-- Returns true on success, false on failure.
function area_edit(key, field, value)
    if not key or key == "" then
        ErrorNote("SnD: area_edit: no key provided")
        return false
    end

    local allowed = {
        start_room = true, minlvl = true, maxlvl = true, lock = true,
        noquest = true, vidblain = true, difficulty = true, name = true,
    }
    if not allowed[field] then
        ErrorNote("SnD: area_edit: unknown field '" .. tostring(field) .. "'")
        return false
    end

    local db = db_open()
    local source = nil
    for row in db:nrows(
        "SELECT source FROM areas WHERE key=" .. fixsql(key)
    ) do
        source = row.source
    end

    if source == nil then
        db_close(db)
        ErrorNote("SnD: Area '" .. key .. "' not found.")
        return false
    end
    if source == "json" then
        db_close(db)
        ErrorNote("SnD: Cannot edit '" .. key .. "' — it is a base area seeded from areas.json.")
        return false
    end

    local value_sql
    if field == "name" then
        value_sql = fixsql(tostring(value))
    else
        local n = tonumber(value)
        if n == nil then
            db_close(db)
            ErrorNote("SnD: area_edit: value must be numeric for field '" .. field .. "'")
            return false
        end
        if field == "difficulty" and (n < 1 or n > 5) then
            db_close(db)
            ErrorNote("SnD: area difficulty must be 1-5.")
            return false
        end
        value_sql = tostring(math.floor(n))
    end

    dbcheck(db, db:exec(
        "UPDATE areas SET " .. field .. "=" .. value_sql ..
        ", updated_at=" .. os.time() ..
        " WHERE key=" .. fixsql(key)
    ), "area_edit: " .. field)

    db_close(db)

    -- If the name changed, rebuild the cross-reference.
    if field == "name" then
        build_area_name_xref()
    end

    return true
end

-- ─── AREA INDEXING FROM MUD OUTPUT ───────────────────────────────────────────
-- 'areas keywords 0 300' returns a fixed-width table:
--   cols  1-4  : minlvl
--   cols  6-9  : maxlvl
--   cols 11-14 : lock level (blank = 0)
--   cols 17-31 : area keyword
--   cols 34+   : area name
-- Clan areas (min=210, max=210) are always noquest.
-- Newly inserted areas get start_room = -1 (unknown until 'xset mark' is used).

local function _join_styles(line_styles)
    local parts = {}
    for _, run in ipairs(line_styles) do
        if run.text then parts[#parts+1] = run.text end
    end
    return table.concat(parts)
end

local function _parse_area_keywords_line(raw)
    if #raw < 17 then return nil end
    local min_l = tonumber(raw:sub(1,4))
    local max_l = tonumber(raw:sub(6,9))
    if not min_l or not max_l then return nil end
    local lock  = tonumber(Trim(raw:sub(11,14))) or 0
    local key   = Trim(raw:sub(17, 31))
    local aname = #raw >= 34 and Trim(raw:sub(34)) or ""
    if key == "" or key:match("^%-+$") then return nil end
    return {
        min_l   = min_l,
        max_l   = max_l,
        lock    = lock,
        key     = key,
        name    = aname ~= "" and aname or key,
        noquest = (min_l == 210 and max_l == 210) and 1 or 0,
    }
end

-- Process captured 'areas keywords' output and insert new areas.
-- silent=true suppresses the summary message (used for auto-detection).
local function _areas_index_process(captured_styles, silent)
    local db = db_open()
    local inserted = 0
    local skipped  = 0

    local ok, err = pcall(function()
        execute_in_transaction(db, function(db)
            for _, ls in ipairs(captured_styles) do
                local a = _parse_area_keywords_line(_join_styles(ls))
                if a then
                    db:exec(
                        "INSERT OR IGNORE INTO areas " ..
                        "(key, name, minlvl, maxlvl, lock, start_room, noquest, source) " ..
                        "VALUES (" ..
                        fixsql(a.key)  .. ", " ..
                        fixsql(a.name) .. ", " ..
                        a.min_l .. ", " .. a.max_l .. ", " .. a.lock .. ", " ..
                        "-1, " ..
                        a.noquest .. ", " ..
                        "'scrape'" ..
                        ")"
                    )
                    if db:changes() > 0 then inserted = inserted + 1
                    else                      skipped  = skipped  + 1 end
                end
            end
        end)
    end)

    db_close(db)

    if not ok then
        ErrorNote("SnD: xset index — failed: " .. tostring(err))
        return
    end

    build_area_name_xref()

    if not silent then
        if inserted > 0 then
            InfoNote(string.format(
                "SnD: Area index — %d new area(s) added, %d already known.", inserted, skipped))
        else
            InfoNote("SnD: Area index — no new areas found (all already in database).")
        end
    elseif inserted > 0 then
        InfoNote(string.format("SnD: Auto-indexed %d new area(s).", inserted))
    end
end

-- Alias handler: 'xset index areas' or 'xset index <zone>'
-- Sends 'areas keywords 0 300' (or 'areas keywords <zone>') and inserts
-- any areas not yet in the database.  Existing entries are not overwritten.
function xset_index_areas(name, line, wildcards)
    local target = Trim((wildcards and (wildcards.target or wildcards[1])) or "")
    local cmd
    if target == "" or target:lower() == "areas" then
        cmd = "areas keywords 0 300"
    else
        cmd = "areas keywords " .. target
    end
    InfoNote("SnD: Indexing areas via '" .. cmd .. "'...")
    Capture.untagged_output(
        cmd,
        true,   -- suppress command echo
        false,  -- show output to user
        false,
        function(styles) _areas_index_process(styles, false) end,
        false,
        nil,
        30
    )
end

-- Called from OnPluginBroadcast when room.info fires with a new zone.
-- Silently indexes the zone if it's not yet in the areas table.
local _last_auto_indexed_zone = nil
function check_zone_known(zone)
    if not zone or zone == "" or zone == _last_auto_indexed_zone then return end
    local db = db_open()
    local known = false
    for _ in db:nrows(
        "SELECT 1 FROM areas WHERE key=" .. fixsql(zone) .. " LIMIT 1"
    ) do known = true end
    db_close(db)
    if not known then
        _last_auto_indexed_zone = zone
        DebugNote("SnD: Zone '" .. zone .. "' not in DB — auto-indexing.")
        Capture.untagged_output(
            "areas keywords " .. zone,
            true,   -- suppress echo
            true,   -- suppress output (silent)
            false,
            function(styles) _areas_index_process(styles, true) end,
            false,
            nil,
            15
        )
    end
end
