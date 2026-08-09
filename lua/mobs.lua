-- mobs.lua
-- Mob sightings, kills, tags (nowhere/nohunt/priority), and room lookups.
-- Depends on: constants.lua, util.lua, db.lua, areas.lua

-- ─── MOB SIGHTINGS ────────────────────────────────────────────────────────────

-- Record a list of mob names seen in the current room.
-- Inserts into mob_sightings (INSERT OR IGNORE) then increments seen_count.
-- room_name, roomid, and zone are read from gmcp() at call time.
function write_mob_list_to_db(mob_list)
    if not mob_list or #mob_list < 1 then
        DebugNote("SnD: write_mob_list_to_db: no mobs to write")
        return
    end

    local rname = strip_colours(gmcp("room.info.name"))
    local rmid  = tonumber(gmcp("room.info.num"))
    local zone  = gmcp("room.info.zone")

    if not rmid or rmid <= 0 then
        DebugNote("SnD: write_mob_list_to_db: invalid roomid")
        return
    end

    local db = db_open()
    local ok, err = pcall(function()
        execute_in_transaction(db, function(db)
            for _, mob in ipairs(mob_list) do
                local mob_lc = mob:lower()
                DebugNote(string.format("SnD: write_mob_list_to_db storing mob=|%s|", mob_lc))
                db:exec(
                    "INSERT OR IGNORE INTO mob_sightings " ..
                    "(mob, room_name, roomid, zone, seen_count, last_seen) VALUES (" ..
                    fixsql(mob_lc) .. ", " ..
                    fixsql(rname) .. ", " ..
                    rmid .. ", " ..
                    fixsql(zone) .. ", " ..
                    "0, " ..
                    tostring(os.time()) .. ")"
                )
                db:exec(
                    "UPDATE mob_sightings " ..
                    "SET seen_count = seen_count + 1, last_seen = " .. tostring(os.time()) ..
                    " WHERE mob = " .. fixsql(mob_lc) ..
                    " AND roomid = " .. rmid
                )
            end
        end)
    end)

    db_close(db)

    if not ok then
        ErrorNote("SnD: write_mob_list_to_db failed: " .. tostring(err))
    else
        DebugNote("SnD: wrote " .. #mob_list .. " mob sighting(s) to DB")
    end
end

-- Record one kill for target.mob at the current room.
-- Inserts into mob_kills (INSERT OR IGNORE) then increments kill_count.
function record_target_killed(target)
    if not target or not target.mob then return end

    local rmid = tonumber(gmcp("room.info.num"))
    local zone = gmcp("room.info.zone")

    if not rmid or rmid <= 0 then
        DebugNote("SnD: record_target_killed: invalid roomid")
        return
    end

    local db = db_open()
    local ok, err = pcall(function()
        execute_in_transaction(db, function(db)
            local mob_lc = target.mob:lower()
            db:exec(
                "INSERT OR IGNORE INTO mob_kills " ..
                "(mob, roomid, zone, kill_count, last_killed) VALUES (" ..
                fixsql(mob_lc) .. ", " ..
                rmid .. ", " ..
                fixsql(zone) .. ", " ..
                "0, " ..
                tostring(os.time()) .. ")"
            )
            db:exec(
                "UPDATE mob_kills " ..
                "SET kill_count = kill_count + 1, last_killed = " .. tostring(os.time()) ..
                " WHERE mob = " .. fixsql(mob_lc) ..
                " AND roomid = " .. rmid
            )
        end)
    end)

    db_close(db)

    if not ok then
        ErrorNote("SnD: record_target_killed failed: " .. tostring(err))
    else
        DebugNote("SnD: recorded kill for " .. target.mob .. " in room " .. rmid)
    end
end

-- Returns a list of {rmid, room_name, zone, seen_count} rows for mob_name in zone,
-- sorted by seen_count descending. Used when a "not found" response fires during qw.
function lookup_not_found_mob(mob_name, zone)
    local rows = {}
    local db = db_open()
    for row in db:nrows(
        "SELECT roomid, room_name, zone, seen_count " ..
        "FROM mob_sightings " ..
        "WHERE mob = " .. fixsql(mob_name:lower()) ..
        " AND zone = " .. fixsql(zone) ..
        " ORDER BY seen_count DESC"
    ) do
        rows[#rows + 1] = {
            rmid       = row.roomid,
            name       = row.room_name,
            zone       = row.zone,
            seen_count = row.seen_count,
        }
    end
    db_close(db)
    return rows
end

-- Returns a list of {roomid, kill_count} rows for mob_name, sorted by kill_count
-- descending. Used by express mode and target list building.
function mob_kill_rooms(mob_name, zone)
    local rows = {}
    local db = db_open()
    for row in db:nrows(
        "SELECT roomid, kill_count " ..
        "FROM mob_kills " ..
        "WHERE mob = " .. fixsql(mob_name:lower()) ..
        " AND zone = " .. fixsql(zone) ..
        " ORDER BY kill_count DESC"
    ) do
        rows[#rows + 1] = { roomid = row.roomid, kill_count = row.kill_count }
    end
    db_close(db)
    return rows
end

-- ─── MOB DUPLICATES ───────────────────────────────────────────────────────────
-- mob_duplicates tracks how many times each mob appears in an area and the set
-- of levels at which it has been seen dying (from 'mobdeaths here hs' output).
-- This data is used by consider output to narrow down a mob's level given its
-- CON_DETAILS difficulty band.

-- Returns {count=N, levels={L1,L2,...}} for mob_name in arid, or nil if unknown.
function mob_duplicates_get(mob_name, arid)
    local db = db_open()
    local result = nil
    for row in db:nrows(
        "SELECT count, levels FROM mob_duplicates " ..
        "WHERE arid=" .. fixsql(arid) ..
        " AND mob_name=" .. fixsql(mob_name:lower())
    ) do
        local lvls = {}
        -- levels is stored as a JSON array: '[10,12,15]'
        local s = (row.levels or "[]"):match("^%[(.-)%]$") or ""
        for n in s:gmatch("([^,]+)") do
            local v = tonumber(n)
            if v then lvls[#lvls+1] = v end
        end
        result = { count = row.count or 0, levels = lvls }
    end
    db_close(db)
    return result
end

-- Upsert a mob_duplicates row.  count is the number of distinct mobs with this
-- name in the area; levels is an integer array.
function mob_duplicates_set(mob_name, arid, count, levels)
    -- Encode levels array as a simple JSON array string.
    local parts = {}
    for _, v in ipairs(levels or {}) do parts[#parts+1] = tostring(math.floor(v)) end
    local lvl_json = "[" .. table.concat(parts, ",") .. "]"

    local db = db_open()
    local ok, err = pcall(function()
        execute_in_transaction(db, function(db)
            dbcheck(db, db:exec(
                "INSERT OR REPLACE INTO mob_duplicates (arid, mob_name, count, levels) " ..
                "VALUES (" ..
                fixsql(arid) .. ", " ..
                fixsql(mob_name:lower()) .. ", " ..
                math.floor(count) .. ", " ..
                fixsql(lvl_json) .. ")"
            ), "mob_duplicates_set")
        end)
    end)
    db_close(db)
    if not ok then
        ErrorNote("SnD: mob_duplicates_set failed: " .. tostring(err))
    end
end

-- Guess the level of mob_name (in arid) given a CON_DETAILS entry.
-- Returns a level integer if exactly one candidate level falls in the band,
-- nil otherwise (ambiguous or no data).
function mob_guess_level(mob_name, arid, con_details)
    if not con_details then return nil end
    local data = mob_duplicates_get(mob_name, arid)
    if not data or #data.levels == 0 then return nil end

    local char_level = tonumber(gmcp("char.base.level")) or 1
    local lo = math.max(1,   char_level + con_details.min_modifier)
    local hi = math.min(250, char_level + con_details.max_modifier) -- 250 is Aardwolf max level

    local candidates = {}
    for _, lvl in ipairs(data.levels) do
        if lvl >= lo and lvl <= hi then
            candidates[#candidates+1] = lvl
        end
    end

    if #candidates == 1 then return candidates[1] end
    return nil  -- ambiguous
end

-- ─── MOB TAGS ─────────────────────────────────────────────────────────────────

-- ─── INTERNAL HELPERS ─────────────────────────────────────────────────────────

-- Ensure a mob_tags row exists for (mob, zone) with all defaults.
-- Uses INSERT OR IGNORE so it is safe to call unconditionally.
local function ensure_mob_tag_row(db, mob, zone)
    db:exec(
        "INSERT OR IGNORE INTO mob_tags (mob, zone) VALUES (" ..
        fixsql(mob) .. ", " .. fixsql(zone) .. ")"
    )
end

-- ─── PUBLIC API ───────────────────────────────────────────────────────────────

-- Returns true if the given mob in zone has the specified boolean flag set.
-- flag must be "nowhere", "nohunt", "noscan", or "express".
function mob_has_tag(mob, zone, flag)
    if flag ~= "nowhere" and flag ~= "nohunt" and flag ~= "noscan" and flag ~= "express" and flag ~= "levelok" then return false end
    local db = db_open()
    local result = false
    for row in db:nrows(
        "SELECT " .. flag .. " FROM mob_tags " ..
        "WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
    ) do
        result = row[flag] == 1
    end
    db_close(db)
    return result
end

-- Toggle a boolean mob flag ("nowhere", "nohunt", "noscan", or "express") for mob in zone.
-- Returns the new flag value: true = now on, false = now off.
function mob_toggle_tag(mob, zone, flag)
    if flag ~= "nowhere" and flag ~= "nohunt" and flag ~= "noscan" and flag ~= "express" and flag ~= "levelok" then
        ErrorNote("SnD: mob_toggle_tag: unknown flag '" .. tostring(flag) .. "'")
        return false
    end

    local db = db_open()
    ensure_mob_tag_row(db, mob, zone)

    local current = 0
    for row in db:nrows(
        "SELECT " .. flag .. " FROM mob_tags " ..
        "WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
    ) do
        current = row[flag] or 0
    end

    local new_val = (current == 0) and 1 or 0
    local ok, err = pcall(dbcheck, db, db:exec(
        "UPDATE mob_tags SET " .. flag .. "=" .. new_val ..
        " WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
    ), "mob_toggle_tag: " .. flag)

    db_close(db)
    if not ok then ErrorNote("SnD: mob_toggle_tag failed: " .. tostring(err)) end
    return new_val == 1
end

-- Set multiple boolean mob flags in one DB write.
-- flags = { nowhere=bool, nohunt=bool, noscan=bool } (any subset).
function mob_set_tags(mob, zone, flags)
    local valid = { nowhere = true, nohunt = true, noscan = true, express = true, levelok = true }
    local db    = db_open()
    ensure_mob_tag_row(db, mob, zone)
    local parts = {}
    for flag, val in pairs(flags) do
        if valid[flag] then
            parts[#parts + 1] = flag .. "=" .. (val and 1 or 0)
        end
    end
    if #parts > 0 then
        local ok, err = pcall(dbcheck, db, db:exec(
            "UPDATE mob_tags SET " .. table.concat(parts, ", ") ..
            " WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
        ), "mob_set_tags")
        if not ok then ErrorNote("SnD: mob_set_tags failed: " .. tostring(err)) end
    end
    db_close(db)
end

-- Set or clear the priority room for a mob in a zone.
-- Pass roomid=nil to clear (the next sightings/kills rank is used instead).
function mob_set_priority_room(mob, zone, roomid)
    local db = db_open()
    ensure_mob_tag_row(db, mob, zone)

    local rid_sql = roomid and tostring(math.floor(tonumber(roomid))) or "NULL"
    if not dbguard(db, db:exec(
        "UPDATE mob_tags SET priority_room=" .. rid_sql ..
        " WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
    ), "mob_set_priority_room") then return end

    db_close(db)
end

-- Returns the priority room ID for a mob in a zone, or nil if none is set.
function mob_get_priority_room(mob, zone)
    local db = db_open()
    local result = nil
    for row in db:nrows(
        "SELECT priority_room FROM mob_tags " ..
        "WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
    ) do
        result = row.priority_room
    end
    db_close(db)
    return result
end

-- ─── MOB DIFFICULTY ───────────────────────────────────────────────────────────

-- Per-mob difficulty on the same 1-5 scale as areas.difficulty.
-- 0 means unrated: the mob inherits whatever its area is rated.
--
-- Ratings are per (mob, zone), so the same mob name in two areas is rated
-- independently -- the same grain the rest of mob_tags already uses.

-- Returns the stored rating for a mob, or 0 when it has none.
function mob_get_difficulty(mob, zone)
    local db     = db_open()
    local result = 0
    for row in db:nrows(
        "SELECT difficulty FROM mob_tags " ..
        "WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
    ) do
        result = tonumber(row.difficulty) or 0
    end
    db_close(db)
    return result
end

-- Set a mob's difficulty. Pass 0 to clear it (back to the area's rating).
-- Returns true on success, false when the value is out of range or the write
-- failed.
function mob_set_difficulty(mob, zone, value)
    local n = tonumber(value)
    if not n then
        ErrorNote("SnD: mob difficulty must be a number 0-5 (0 clears it).")
        return false
    end
    n = math.floor(n)
    if n < 0 or n > 5 then
        ErrorNote("SnD: mob difficulty must be 1-5, or 0 to clear it.")
        return false
    end

    local db = db_open()
    ensure_mob_tag_row(db, mob, zone)
    if not dbguard(db, db:exec(
        "UPDATE mob_tags SET difficulty=" .. n ..
        " WHERE mob=" .. fixsql(mob) .. " AND zone=" .. fixsql(zone)
    ), "mob_set_difficulty") then return false end
    db_close(db)
    return true
end

-- Returns { [mob_lowercase] = difficulty } for every rated mob in a zone.
-- Batched so the target list can annotate a whole campaign in one query
-- rather than one per mob.
function mob_difficulties_for_zone(zone)
    local out = {}
    local db  = db_open()
    for row in db:nrows(
        "SELECT mob, difficulty FROM mob_tags " ..
        "WHERE zone=" .. fixsql(zone) .. " AND difficulty > 0"
    ) do
        if row.mob then out[tostring(row.mob):lower()] = tonumber(row.difficulty) or 0 end
    end
    db_close(db)
    return out
end

-- Remove all tag data for a specific mob in a zone.
-- This deletes the entire mob_tags row (all flags cleared).
function mob_clear_tags(mob, zone)
    local db = db_open()
    if not dbguard(db, db:exec(
        "DELETE FROM mob_tags WHERE mob=" .. fixsql(mob) ..
        " AND zone=" .. fixsql(zone)
    ), "mob_clear_tags") then return end
    db_close(db)
end

-- Return all mob_tags rows for a zone that have at least one flag or priority set.
-- Returns a list of {mob, nowhere, nohunt, noscan, express, levelok, priority_room} tables, sorted by mob.
function mob_list_tags(zone)
    local rows = {}
    local db = db_open()
    for row in db:nrows(
        "SELECT mob, nowhere, nohunt, noscan, express, levelok, difficulty, priority_room FROM mob_tags " ..
        "WHERE zone=" .. fixsql(zone) ..
        " AND (nowhere=1 OR nohunt=1 OR noscan=1 OR express=1 OR levelok=1" ..
        "      OR difficulty > 0 OR priority_room IS NOT NULL) " ..
        "ORDER BY mob"
    ) do
        rows[#rows + 1] = {
            mob           = row.mob,
            nowhere       = row.nowhere == 1,
            nohunt        = row.nohunt == 1,
            noscan        = row.noscan == 1,
            express       = row.express == 1,
            levelok       = row.levelok == 1,
            difficulty    = tonumber(row.difficulty) or 0,
            priority_room = row.priority_room,
        }
    end
    db_close(db)
    return rows
end

-- ─── DB CLEANUP ───────────────────────────────────────────────────────────────

-- Alias handler: 'xdb clean'
-- Phase 1: strip aura/status flags from mob names already in the DB.
-- Phase 2: merge case-variant duplicates within the same (roomid, zone),
--          keeping the name with the most uppercase letters, summing counts.
function xdb_clean(name, line, wildcards)
    local db = db_open()
    local fixed_flags = 0
    local fixed_case  = 0

    local function count_upper(s)
        local n = 0
        for c in s:gmatch(".") do if c:match("%u") then n = n + 1 end end
        return n
    end

    local function strip_flags_phase(tbl, cnt_col)
        local flagged = {}
        for row in db:nrows(
            "SELECT id, mob, roomid, zone, " .. cnt_col ..
            " FROM " .. tbl .. " WHERE mob GLOB '(*' OR mob GLOB '[[]*'"
        ) do
            local stripped = strip_mob_flags(row.mob)
            if stripped ~= row.mob then
                flagged[#flagged+1] = {
                    id       = row.id,
                    stripped = stripped,
                    roomid   = row.roomid,
                    zone     = row.zone,
                    cnt      = row[cnt_col] or 0,
                }
            end
        end
        local ok, err = pcall(function()
            execute_in_transaction(db, function(db)
                for _, r in ipairs(flagged) do
                    local ex_id, ex_cnt
                    for row in db:nrows(
                        "SELECT id, " .. cnt_col .. " FROM " .. tbl ..
                        " WHERE mob=" .. fixsql(r.stripped) ..
                        " AND roomid=" .. r.roomid ..
                        " AND zone=" .. fixsql(r.zone)
                    ) do
                        ex_id  = row.id
                        ex_cnt = row[cnt_col] or 0
                    end
                    if ex_id then
                        db:exec("UPDATE " .. tbl .. " SET " .. cnt_col .. "=" ..
                            (ex_cnt + r.cnt) .. " WHERE id=" .. ex_id)
                        db:exec("DELETE FROM " .. tbl .. " WHERE id=" .. r.id)
                    else
                        db:exec("UPDATE " .. tbl .. " SET mob=" .. fixsql(r.stripped) ..
                            " WHERE id=" .. r.id)
                    end
                    fixed_flags = fixed_flags + 1
                end
            end)
        end)
        if not ok then ErrorNote("SnD: xdb clean (flags/" .. tbl .. "): " .. tostring(err)) end
    end

    local function merge_case_phase(tbl, cnt_col)
        local groups = {}
        for row in db:nrows(
            "SELECT LOWER(mob) AS ml, roomid, zone, COUNT(*) AS n FROM " .. tbl ..
            " GROUP BY LOWER(mob), roomid, zone HAVING n > 1"
        ) do
            groups[#groups+1] = {ml=row.ml, roomid=row.roomid, zone=row.zone}
        end
        local ok, err = pcall(function()
            execute_in_transaction(db, function(db)
                for _, g in ipairs(groups) do
                    local variants = {}
                    for row in db:nrows(
                        "SELECT id, mob, " .. cnt_col .. " FROM " .. tbl ..
                        " WHERE LOWER(mob)=" .. fixsql(g.ml) ..
                        " AND roomid=" .. g.roomid ..
                        " AND zone=" .. fixsql(g.zone)
                    ) do
                        variants[#variants+1] = {id=row.id, mob=row.mob, cnt=row[cnt_col] or 0}
                    end
                    if #variants > 1 then
                        local best = variants[1]
                        local best_u = count_upper(best.mob)
                        for i = 2, #variants do
                            local v = variants[i]
                            local vu = count_upper(v.mob)
                            if vu > best_u or (vu == best_u and #v.mob > #best.mob) then
                                best = v; best_u = vu
                            end
                        end
                        local total = 0
                        for _, v in ipairs(variants) do total = total + v.cnt end
                        db:exec("UPDATE " .. tbl .. " SET " .. cnt_col .. "=" .. total ..
                            " WHERE id=" .. best.id)
                        for _, v in ipairs(variants) do
                            if v.id ~= best.id then
                                db:exec("DELETE FROM " .. tbl .. " WHERE id=" .. v.id)
                                fixed_case = fixed_case + 1
                            end
                        end
                    end
                end
            end)
        end)
        if not ok then ErrorNote("SnD: xdb clean (case/" .. tbl .. "): " .. tostring(err)) end
    end

    strip_flags_phase("mob_sightings", "seen_count")
    strip_flags_phase("mob_kills",     "kill_count")
    merge_case_phase("mob_sightings",  "seen_count")
    merge_case_phase("mob_kills",      "kill_count")

    db_close(db)
    InfoNote(string.format(
        "SnD: DB cleanup complete — %d flag entries cleaned, %d case duplicates merged.",
        fixed_flags, fixed_case))
end
