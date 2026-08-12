-- targets.lua
-- Target state, target list building (CP/GQ), target display, and parse logic.
-- Depends on: constants.lua, util.lua, db.lua, areas.lua, mobs.lua,
--             keywords.lua, express.lua, settings.lua, characters.lua

-- ─── MODULE STATE ─────────────────────────────────────────────────────────────

-- Current activity: "cp", "gq", "quest", or "none"
current_activity    = "none"

-- "area" | "room" | "none" — determined from the first cp/gq check list
area_room_type      = "none"

-- Guards the one automatic 'cp info' / 'gq info' that a check may trigger when
-- the campaign type is unknown. Without it the two would call each other
-- indefinitely, because info always finishes by running the check.
_type_recovery_tried = false

-- Ordered list of target entries built by build_main_target_list().
-- Each entry is a table with keys: mob, arid, roomid, roomName, qty, is_dead,
-- link_type, kw, results, kills, unlikely, duplicates, index, etc.
main_target_list    = {}

-- Targets from build_room_targets() that were filtered out by level range.
room_targets_ignored = {}

-- Current navigation target: {name, keyword, room_name, area, activity, index}
-- nil when no target is selected.
current_target      = nil

-- Current quest target from GMCP: {mob, areaName, arid, room, qstat}
quest_target        = {qstat = "0"}

-- Accumulated cp check list (filled by on_cp_check_captured).
cp_check_list       = {}

-- Accumulated cp info list (filled by on_cp_info_captured).
cp_info_list        = {}

-- Level taken for the current campaign (parsed from cp info output).
cp_info_level       = 0

-- Accumulated gq check list (filled by on_gq_check_captured).
gq_check_list       = {}

-- GQ target list from gq info; used for area/room type detection.
gq_info_list        = {}

-- Effective level for the current global quest.
gq_info_efflvl      = 0

-- Level range for the current global quest (set by on_gq_info_parsed).
gq_info_minlvl      = 0
gq_info_maxlvl      = 0

-- Timestamp guard to prevent double cp checks.
last_cp_check       = 0

-- Today's campaign completion counts (session-only; parsed from cp check output).
-- nil = not yet seen this session.  Updated whenever cp check returns the
-- "You have completed N campaign(s) today" lines.
today_cp_total      = nil   -- all remorts combined
today_cp_superhero  = nil   -- at this superhero tier only

-- ─── COLOR HELPERS ────────────────────────────────────────────────────────────

-- Returns the display color string for a target row.
function color_for_target(target, targeted)
    if targeted then
        return snd_get_setting("color_targeted", "#FF4000")
    elseif target.unlikely then
        return snd_get_setting("color_unlikely", "#484848")
    elseif target.is_dead == "yes" and target.link_type == "unknown" then
        return snd_get_setting("color_unknown_dead", "#900000")
    elseif target.is_dead == "yes" then
        return snd_get_setting("color_dead", "#484848")
    elseif target.link_type == "unknown" then
        return snd_get_setting("color_unknown", "#FF0000")
    else
        return snd_get_setting("color_normal", "#E0E0E0")
    end
end

-- Returns a color based on the percentage probability (0–1).
function mob_room_percentage_color(pct)
    if pct >= 0.75 then return "#00FF00"
    elseif pct >= 0.5 then return "#FFFF00"
    elseif pct >= 0.25 then return "#FF8C00"
    else return "#FF4040" end
end

-- ─── AREA-VS-ROOM DETECTION ───────────────────────────────────────────────────

-- Inspect a cp/gq check list and decide whether targets are identified by
-- area or room name.  Returns "area" | "room" | "none".
function area_room_type_check(list)
    if not list or #list == 0 then return "none" end
    if not mapper_db_file then return "none" end
    local db = sqlite3.open(mapper_db_file)
    if not db then return "none" end

    local first = list[1]
    local loc = first.loc or ""
    -- Check if it's a known area name.
    local found_area = false
    for _ in db:nrows(
        "SELECT uid FROM areas WHERE LOWER(name) = LOWER(" .. fixsql(loc) .. ") LIMIT 1"
    ) do
        found_area = true
    end
    db:close()

    if found_area then return "area" end

    -- Fall back to areaNameXref lookup (built from areas table).
    if area_key_from_name(loc) then return "area" end

    return "room"
end

-- ─── PARSE TARGET LINE ────────────────────────────────────────────────────────

-- Parse a single 'cp check' / 'gq check' target line of the form:
--   "mob name (location)" or "mob name (location - Dead)"
-- Returns mob_name, location, is_dead ("yes"/"no").
function parse_mob_target(target_line)
    local mob_name      = ""
    local temp          = ""
    local location      = nil
    local paren_depth   = 0

    for i = 1, #target_line do
        local ch = target_line:sub(i, i)
        if ch == "(" then
            paren_depth = paren_depth + 1
            if paren_depth == 1 then
                mob_name = mob_name .. temp
                temp     = ch
            else
                temp = temp .. ch
            end
        elseif ch == ")" then
            paren_depth = paren_depth - 1
            temp = temp .. ch
            if paren_depth == 0 then
                if i == #target_line then
                    location = temp
                else
                    mob_name = mob_name .. temp
                end
                temp = ""
            end
        else
            temp = temp .. ch
        end
    end

    if not location then
        ErrorNote("SnD: parse_mob_target: could not parse '" .. target_line .. "'")
        return nil, nil, "no"
    end

    location = Trim(location):sub(2, -2)  -- strip outer parens
    local is_dead = "no"
    if location:match(" %- Dead$") then
        location = location:sub(1, -8)
        is_dead  = "yes"
    end

    return Trim(mob_name), Trim(location), is_dead
end

-- ─── BUILD TARGET LIST ────────────────────────────────────────────────────────

-- Attach room link notes to target entries.
-- Queries the room_links table for any entry whose roomid appears as a link
-- endpoint, and stores the note in entry.rlink_note for display.
local function attach_room_link_notes(list)
    if not list or #list == 0 then return end

    -- Collect all unique positive roomids from the list.
    local rids      = {}
    local rid_set   = {}
    for _, entry in ipairs(list) do
        local rid = tonumber(entry.roomid)
        if rid and rid > 0 and not rid_set[rid] then
            rid_set[rid] = true
            rids[#rids + 1] = rid
        end
    end
    if #rids == 0 then return end

    -- Single query: match any link where either endpoint is in our room set.
    local notes_by_room = {}
    local in_clause     = table.concat(rids, ",")
    local ok = pcall(function()
        local db = db_open()
        for row in db:nrows(
            "SELECT room1, room2, note FROM room_links " ..
            "WHERE (room1 IN (" .. in_clause .. ") OR room2 IN (" .. in_clause .. "))" ..
            " AND note != '' AND note IS NOT NULL"
        ) do
            local r1 = tonumber(row.room1)
            local r2 = tonumber(row.room2)
            -- Associate the note with each endpoint that is in our target-room set.
            if r1 and rid_set[r1] and not notes_by_room[r1] then
                notes_by_room[r1] = row.note
            end
            if r2 and rid_set[r2] and not notes_by_room[r2] then
                notes_by_room[r2] = row.note
            end
        end
        db_close(db)
    end)
    if not ok then return end

    for _, entry in ipairs(list) do
        local rid = tonumber(entry.roomid)
        if rid and notes_by_room[rid] then
            entry.rlink_note = notes_by_room[rid]
        end
    end
end

-- Attach area difficulty ratings to target entries.
-- Queries the areas table once for every distinct area key in the list, and
-- stores the result in entry.difficulty for display in the miniwindow's
-- "Diff" column.  Entries with no area (arid nil or "-1") are left alone.
local function attach_difficulty(list)
    if not list or #list == 0 then return end

    local arids     = {}
    local arid_set  = {}
    for _, entry in ipairs(list) do
        local arid = entry.arid
        if arid and arid ~= "-1" and not arid_set[arid] then
            arid_set[arid] = true
            arids[#arids + 1] = fixsql(arid)
        end
    end
    if #arids == 0 then return end

    local diff_by_arid = {}
    local ok = pcall(function()
        local db = db_open()
        for row in db:nrows(
            "SELECT key, difficulty FROM areas WHERE key IN (" .. table.concat(arids, ",") .. ")"
        ) do
            -- 0 is "not rated", not "rated zero": leaving it as a number
            -- would draw a 0 in the Diff column and sort the area as easier
            -- than anything anyone had actually rated.
            local d = tonumber(row.difficulty)
            diff_by_arid[row.key] = (d and d > 0) and d or nil
        end
        db_close(db)
    end)
    if not ok then return end

    -- Per-mob ratings for the same areas.  Guarded separately: a mob rating
    -- refines the display, so a database predating mob_tags.difficulty should
    -- still show area ratings rather than none at all.
    local mob_diff = {}   -- arid -> { [mob_lc] = difficulty }
    pcall(function()
        local db = db_open()
        for row in db:nrows(
            "SELECT zone, mob, difficulty FROM mob_tags WHERE difficulty > 0" ..
            " AND zone IN (" .. table.concat(arids, ",") .. ")"
        ) do
            local z, m = row.zone, row.mob
            if z and m then
                z = tostring(z)
                mob_diff[z] = mob_diff[z] or {}
                mob_diff[z][tostring(m):lower()] = tonumber(row.difficulty)
            end
        end
        db_close(db)
    end)

    -- Each row in the target list IS a mob, so its own rating is the more
    -- useful number when it has one; otherwise fall back to its area's.
    for _, entry in ipairs(list) do
        if entry.arid then
            local own
            if entry.mob then
                local by_zone = mob_diff[entry.arid]
                own = by_zone and by_zone[tostring(entry.mob):lower()]
            end
            entry.difficulty     = own or diff_by_arid[entry.arid]
            entry.mob_difficulty = own      -- set only when the mob is rated
        end
    end
end

-- Entry point: build and store main_target_list, then refresh the window.
-- cp_or_gq: "cp" | "gq"
-- area_or_room: "area" | "room"
function build_main_target_list(cp_or_gq, area_or_room)
    if area_or_room == "area" then
        main_target_list = build_area_targets(cp_or_gq)
    elseif area_or_room == "room" then
        main_target_list, room_targets_ignored = build_room_targets(cp_or_gq)
    elseif area_or_room == "none" or area_or_room == nil then
        -- The campaign type is not known yet, which after a reload is every
        -- time: it comes from parsing 'cp info' / 'gq info' output and does
        -- not survive one.
        --
        -- Telling the player to go and run that themselves was busywork -- the
        -- command is known, nothing is ambiguous, and the info handler already
        -- chains back into the check when it finishes. So fetch it.
        local what  = (cp_or_gq == "gq") and "gq info" or "cp info"
        local fetch = (cp_or_gq == "gq") and do_gq_info or do_cp_info

        -- Once only. If the info comes back and the type is still unknown --
        -- which is what happens when there is no campaign at all -- asking
        -- again would run the pair forever, since info always ends by running
        -- the check.
        if _type_recovery_tried or type(fetch) ~= "function" then
            _type_recovery_tried = false
            InfoNote("SnD: '", what, "' did not say whether this campaign is ",
                     "by area or by room. If you are not on one, that is why.")
            return
        end
        _type_recovery_tried = true
        InfoNote("SnD: no target list yet -- running '", what, "' first.")
        fetch()
        return
    else
        ErrorNote("SnD: build_main_target_list: unknown area_or_room value: " .. tostring(area_or_room))
        return
    end

    -- A list was built, so whatever the recovery was for is over.
    _type_recovery_tried = false

    -- Attach room link notes to any target whose roomid has a configured link.
    attach_room_link_notes(main_target_list)

    -- Attach each target's area difficulty rating for the window's Diff column.
    attach_difficulty(main_target_list)

    -- Optimize visit order using TSP pathing (pathing.lua).
    if type(optimize_target_order) == "function" then
        optimize_target_order()
    end

    if type(xg_update_target_list) == "function" then
        xg_update_target_list(cp_or_gq, main_target_list)
    end
    if type(xg_draw_window) == "function" then xg_draw_window() end
    print_target_links(main_target_list)
end

-- Build a target list using area-level lookups (area CP or dead mobs).
function build_area_targets(cp_gq)
    local list = (cp_gq == "cp") and cp_check_list or gq_check_list
    local t, unlikely = {}, {}

    if not mapper_db_file then return t end
    local mapdb = sqlite3.open(mapper_db_file)
    local snddb = db_open()

    local ok, err = pcall(function()
    for _, v in ipairs(list) do
        local dead  = v.is_dead
        local possibilities = {}
        local areas_sql     = {}

        -- Mapper lookup: area by name (case-insensitive).
        for row in mapdb:nrows(
            "SELECT uid AS arid, name AS area_name FROM areas " ..
            "WHERE LOWER(name) = LOWER(" .. fixsql(v.loc) .. ") ORDER BY uid"
        ) do
            possibilities[#possibilities+1] = {
                mob=v.mob, arid=row.arid, qty=v.qty,
                is_dead=dead, link_type="area"
            }
            areas_sql[#areas_sql+1] = fixsql(row.arid)
        end

        -- Fallback: areaNameXref lookup.
        if #possibilities == 0 then
            local key = area_key_from_name(v.loc)
            if key then
                for row in mapdb:nrows(
                    "SELECT uid AS arid FROM areas WHERE uid=" .. fixsql(key) .. " LIMIT 1"
                ) do
                    possibilities[#possibilities+1] = {
                        mob=v.mob, arid=row.arid, qty=v.qty,
                        is_dead=dead, link_type="area"
                    }
                    areas_sql[#areas_sql+1] = fixsql(row.arid)
                end
            end
        end

        -- nowhere-tagged mobs remain in the list; the tag only skips the 'where'
        -- command during hunting.  They are valid targets reached via area routing.
        if #possibilities > 1 then
            -- Disambiguate: check which areas have sightings data.
            local seen_zones = {}
            for row in snddb:nrows(
                "SELECT DISTINCT zone FROM mob_sightings " ..
                "WHERE mob=" .. fixsql(v.mob:lower()) ..
                " AND zone IN (" .. table.concat(areas_sql, ",") .. ")"
            ) do
                seen_zones[row.zone] = true
            end

            local found, not_found = {}, {}
            for _, mob in ipairs(possibilities) do
                mob.duplicates = #possibilities
                if seen_zones[mob.arid] then
                    found[#found+1] = mob
                else
                    mob.unlikely = true
                    not_found[#not_found+1] = mob
                end
            end

            -- When multiple areas all have sightings (e.g. two areas share the
            -- same display name like "The School of Horror" = soh + sohtwo),
            -- disambiguate further by kill count so the mob only appears once.
            if #found > 1 then
                local best_zone, best_kills = nil, -1
                for row in snddb:nrows(
                    "SELECT zone, SUM(kill_count) AS total FROM mob_kills " ..
                    "WHERE mob=" .. fixsql(v.mob:lower()) ..
                    " AND zone IN (" .. table.concat(areas_sql, ",") .. ")" ..
                    " GROUP BY zone"
                ) do
                    if (row.total or 0) > best_kills then
                        best_kills = row.total
                        best_zone  = row.zone
                    end
                end
                if best_zone then
                    local primary, rest = {}, {}
                    for _, m in ipairs(found) do
                        if m.arid == best_zone then primary[#primary+1] = m
                        else m.unlikely = true; rest[#rest+1] = m end
                    end
                    if #primary > 0 then
                        found = primary
                        for _, m in ipairs(rest) do not_found[#not_found+1] = m end
                    end
                else
                    -- No kill data yet; keep only the first match, mark rest unlikely.
                    for i = 2, #found do
                        found[i].unlikely = true
                        not_found[#not_found+1] = found[i]
                    end
                    found = { found[1] }
                end
            end

            for i, mob in ipairs(found)     do mob.index = i;            t[#t+1]        = mob end
            for i, mob in ipairs(not_found) do mob.index = i+#found;     unlikely[#unlikely+1] = mob end

        elseif #possibilities == 1 then
            local entry = possibilities[1]
            -- Attach best kill room.
            for row in snddb:nrows(
                "SELECT roomid, kill_count FROM mob_kills " ..
                "WHERE mob=" .. fixsql(v.mob:lower()) ..
                " AND zone=" .. fixsql(entry.arid) ..
                " ORDER BY kill_count DESC LIMIT 1"
            ) do
                entry.roomid  = row.roomid
                entry.kills   = row.kill_count
            end
            -- Count distinct kill rooms.
            local results = 0
            for row in snddb:nrows(
                "SELECT COUNT(*) AS n FROM mob_kills " ..
                "WHERE mob=" .. fixsql(v.mob:lower()) ..
                " AND zone=" .. fixsql(entry.arid)
            ) do
                results = row.n
            end
            entry.results = results
            t[#t+1] = entry

        else
            -- Unknown location.
            t[#t+1] = {
                mob=v.mob, location=v.loc, arid="-1",
                qty=v.qty, is_dead=dead, link_type="unknown"
            }
        end
    end
    end)  -- end pcall

    snddb:close()
    mapdb:close()

    if not ok then
        ErrorNote("SnD: build_area_targets: " .. tostring(err))
    end

    for _, mob in ipairs(unlikely) do t[#t+1] = mob end
    for _, v   in ipairs(t)        do v.kw = gmkw(v.mob, v.arid) end
    return t
end

-- Parse per-area level overrides from settings.
-- Format stored: "sohtwo:120:250,anotherarea:1:200" (arid:min:max).
-- Returns a table {arid -> {min, max}}.
local function get_level_overrides()
    local s = snd_get_setting("area_level_overrides", "") or ""
    local t = {}
    for entry in s:gmatch("[^,]+") do
        local arid, mn, mx = entry:match("^([^:]+):(%d+):(%d+)$")
        if arid then t[arid] = {tonumber(mn), tonumber(mx)} end
    end
    return t
end

-- Build a target list using room-level lookups (room CP with live mobs).
function build_room_targets(cp_gq)
    local list         = (cp_gq == "cp") and cp_check_list or gq_check_list
    local level_taken  = (cp_gq == "cp")
        and tonumber(cp_info_level)
        or  tonumber(gq_info_efflvl) or 0

    local high, low, ig = {}, {}, {}
    local level_overrides = get_level_overrides()

    if not mapper_db_file then return high, ig end
    local mapdb = sqlite3.open(mapper_db_file)
    local snddb = db_open()

    local area_sorter = function(a, b)
        if a.arid == "-1" then return false
        elseif b.arid == "-1" then return true
        else return a.arid < b.arid end
    end

    for _, v in ipairs(list) do
        local dead        = v.is_dead
        local link_type   = (dead == "yes") and "area" or "room"
        local possibilities = {}
        local areas_sql   = {}

        -- Room lookup in mapper.
        for row in mapdb:nrows(
            "SELECT r.uid AS roomid, r.name AS room_name, a.uid AS arid, a.name AS area_name " ..
            "FROM rooms r INNER JOIN areas a ON r.area = a.uid " ..
            "WHERE r.name = " .. fixsql(v.loc) .. " ORDER BY a.uid"
        ) do
            local lvl_min = 1
            local lvl_max = 201
            -- Look up level range from areas table.
            for ar in snddb:nrows(
                "SELECT minlvl, maxlvl FROM areas WHERE key=" .. fixsql(row.arid) .. " LIMIT 1"
            ) do
                lvl_min = ar.minlvl
                lvl_max = ar.maxlvl
            end
            -- Apply per-area override if configured.
            local ov = level_overrides[row.arid]
            if ov then lvl_min = ov[1]; lvl_max = ov[2] end

            local lvl_buf   = tonumber(snd_get_setting("level_buffer", "25")) or 25
            -- 'levelok' overrides the level-range check entirely for mobs known
            -- to be outside their zone's normal range (e.g. a level-40 mob in an
            -- otherwise level-90+ area) -- otherwise a genuinely-present room
            -- match gets silently discarded before we ever check the room name.
            local level_ok  = mob_has_tag(v.mob, row.arid, "levelok")
            if level_ok or (level_taken >= lvl_min and level_taken <= (lvl_max + lvl_buf)) then
                possibilities[#possibilities+1] = {
                    mob=v.mob, arid=row.arid,
                    roomid=tonumber(row.roomid), roomName=row.room_name,
                    qty=v.qty, is_dead=dead,
                    results=0, kills=-1,
                    minlvl=lvl_min, maxlvl=lvl_max,
                    link_type=link_type,
                }
                areas_sql[#areas_sql+1] = fixsql(row.arid)
            else
                ig[#ig+1] = {
                    mob=v.mob, arid=row.arid,
                    roomid=tonumber(row.roomid), roomName=row.room_name,
                    qty=v.qty, is_dead=dead,
                    results=0, kills=-1,
                    minlvl=lvl_min, maxlvl=lvl_max,
                    link_type="ignored",
                }
            end
        end

        -- nowhere-tagged mobs remain in the list; the tag only skips 'where'.
        if #possibilities > 0 then
            -- Check sightings: exact room match first, then area-wide.
            --
            -- The area-wide half used to be missing. Only the exact
            -- (mob, room_name) query below existed, so when a mob had never
            -- been seen in a room of that exact name, every candidate area was
            -- ranked identically -- discarding the fact that we may well have
            -- seen the mob elsewhere in one of them. An area you have met the
            -- mob in is a far better guess than one you have never seen it in,
            -- and that information was already sitting in mob_sightings.
            local mob_found = false

            for row in snddb:nrows(
                "SELECT ms.zone, ms.roomid, mk.kill_count " ..
                "FROM mob_sightings ms " ..
                "LEFT JOIN mob_kills mk ON mk.mob=ms.mob AND mk.roomid=ms.roomid " ..
                "WHERE ms.mob=" .. fixsql(v.mob:lower()) ..
                " AND ms.room_name=" .. fixsql(v.loc) ..
                " AND ms.zone IN (" .. table.concat(areas_sql, ",") .. ") " ..
                "ORDER BY COALESCE(mk.kill_count,0) DESC"
            ) do
                for _, p in ipairs(possibilities) do
                    if p.arid == row.zone then
                        mob_found   = true
                        p.found     = true
                        p.results   = p.results + 1
                        if p.kills < 1 then p.kills = 1 end
                        if p.roomid == row.roomid then
                            local kc = tonumber(row.kill_count) or 0
                            if p.kills < kc + 1 then p.kills = kc + 1 end
                        end
                    end
                end
            end

            -- Area-wide fallback: has this mob been seen anywhere in each
            -- candidate area, regardless of room name? Only consulted when no
            -- exact room sighting was found, since an exact match is strictly
            -- better evidence and should not be diluted by it.
            local area_seen = {}
            if not mob_found then
                for row in snddb:nrows(
                    "SELECT ms.zone AS zone, SUM(ms.seen_count) AS seen " ..
                    "FROM mob_sightings ms " ..
                    "WHERE ms.mob=" .. fixsql(v.mob:lower()) ..
                    " AND ms.zone IN (" .. table.concat(areas_sql, ",") .. ") " ..
                    "GROUP BY ms.zone"
                ) do
                    area_seen[row.zone] = tonumber(row.seen) or 1
                end
                for _, p in ipairs(possibilities) do
                    local n = area_seen[p.arid]
                    if n then
                        p.area_seen = n
                        p.results   = p.results + 1
                    end
                end
            end

            -- Deduplicate by (arid, roomName).
            local seen_keys = {}
            local deduped   = {}
            for _, p in ipairs(possibilities) do
                local key = p.arid .. "|" .. p.roomName
                if not seen_keys[key] then
                    seen_keys[key] = p
                    deduped[#deduped+1] = p
                elseif p.kills > seen_keys[key].kills then
                    seen_keys[key].kills   = p.kills
                    seen_keys[key].results = p.results
                    seen_keys[key].roomid  = p.roomid
                end
                if p.area_seen and (seen_keys[key].area_seen or 0) < p.area_seen then
                    seen_keys[key].area_seen = p.area_seen
                end
            end
            possibilities = deduped
            table.sort(possibilities, area_sorter)

            if mob_found then
                local tmp_high, tmp_low = {}, {}
                for _, p in ipairs(possibilities) do
                    p.duplicates = #possibilities
                    if p.found then tmp_high[#tmp_high+1] = p
                    else p.unlikely = true; tmp_low[#tmp_low+1] = p end
                end
                for i, p in ipairs(tmp_high) do p.index = i;           high[#high+1] = p end
                for i, p in ipairs(tmp_low)  do p.index = i+#tmp_high; low[#low+1]   = p end
            else
                -- No exact room sighting. Areas we have actually met this mob
                -- in rank above areas we have not; only when we have seen it
                -- nowhere are all candidates genuinely equally likely.
                local any_area_seen = false
                for _, p in ipairs(possibilities) do
                    if p.area_seen then any_area_seen = true break end
                end

                if any_area_seen then
                    -- Only the best-attested area stays in the main list.
                    --
                    -- Ordering these by sighting count is not enough on its
                    -- own: `high` is re-sorted by area at the end of this
                    -- function, so every target in one area is visited
                    -- together, and that sort discards any order set here.
                    -- Which tier an entry lands in does survive it, so the
                    -- weaker guesses are deferred rather than merely ranked
                    -- below the stronger one.
                    --
                    -- Ties keep every area that is equally attested -- there
                    -- is nothing to choose between them.
                    local best = 0
                    for _, p in ipairs(possibilities) do
                        local n = p.area_seen or 0
                        if n > best then best = n end
                    end

                    table.sort(possibilities, function(x, y)
                        local sx, sy = x.area_seen or 0, y.area_seen or 0
                        if sx ~= sy then return sx > sy end
                        return area_sorter(x, y)
                    end)
                    local tmp_high, tmp_low = {}, {}
                    for _, p in ipairs(possibilities) do
                        p.duplicates = #possibilities
                        if (p.area_seen or 0) == best then
                            tmp_high[#tmp_high+1] = p
                        else
                            p.unlikely = true; tmp_low[#tmp_low+1] = p
                        end
                    end
                    for i, p in ipairs(tmp_high) do p.index = i;            high[#high+1] = p end
                    for i, p in ipairs(tmp_low)  do p.index = i + #tmp_high; low[#low+1]   = p end
                else
                    for i, p in ipairs(possibilities) do
                        p.duplicates = #possibilities
                        p.index      = i
                        high[#high+1] = p
                    end
                end
            end

        else
            -- No room match. Fall back to area lookup if dead, else unknown.
            if dead == "yes" then
                local found_area = false
                for row in mapdb:nrows(
                    "SELECT uid AS arid FROM areas " ..
                    "WHERE LOWER(name)=LOWER(" .. fixsql(v.loc) .. ") LIMIT 1"
                ) do
                    found_area = true
                    high[#high+1] = {mob=v.mob, arid=row.arid, qty=v.qty,
                                     is_dead="yes", link_type="area"}
                end
                if not found_area then
                    high[#high+1] = {mob=v.mob, arid="-1", location=v.loc,
                                     qty=v.qty, is_dead="yes", link_type="unknown"}
                end
            else
                high[#high+1] = {mob=v.mob, arid="-1", location=v.loc,
                                  qty=v.qty, is_dead="no", link_type="unknown"}
            end
        end
    end

    table.sort(ig,   area_sorter)
    table.sort(high, area_sorter)
    table.sort(low,  area_sorter)

    for _, v in ipairs(low)  do high[#high+1] = v end

    snddb:close()
    mapdb:close()

    for _, v in ipairs(high) do v.kw = gmkw(v.mob, v.arid) end
    return high, ig
end

-- ─── DISPLAY ──────────────────────────────────────────────────────────────────

-- Print clickable target links into the MUD output window.
function print_target_links(list)
    if snd_get_setting("silent_mode", "off") == "on" then return end

    -- Ignored rooms: always log to the debug file; show on screen only in debug mode.
    if #room_targets_ignored > 0 then
        if type(debug_log_write) == "function" then
            debug_log_write("DEBUG", string.format(
                "Ignored room targets (%d):", #room_targets_ignored
            ))
            for _, v in ipairs(room_targets_ignored) do
                debug_log_write("DEBUG", string.format(
                    "  (lvl %d-%d) %s - '%s' (%s)",
                    v.minlvl or 0, v.maxlvl or 0,
                    v.mob, v.roomName or "?", v.arid
                ))
            end
        end
        if type(snd_get_setting) == "function"
        and snd_get_setting("debug_mode", "off") == "on" then
            print_room_links_ignored()
        end
    end

    if #list == 0 then
        InfoNote("   No target items to show.")
        return
    end

    local alt_bg = snd_get_setting("color_alternating_row", "#0C0C1A")
    local shown_express = false
    ColourNote("#808080", "", string.rep("-", 80))

    for i, v in ipairs(list) do
        local is_current  = current_target
            and current_target.name == v.mob
            and current_target.area == v.arid
        local color       = color_for_target(v, is_current)
        local bg          = (i % 2 == 0) and alt_bg or ""
        -- Express targets carry a leading asterisk, as they did in 5.99.
        -- The destination column already says "Mob " for them, but that is a
        -- distinction nobody reads as "express" -- and when xcp behaves oddly
        -- on one, being unable to tell which targets are express is the
        -- difference between a useful report and a guess.
        local is_express  = (v.link_type == "room") and is_express_target(v)
        if is_express then shown_express = true end
        local mob_text    = string.format("%s%s%s",
            (v.is_dead == "no") and "" or "[D] ",
            is_express and "*" or "", v.mob)
        local arid_str    = tostring(v.arid):sub(1, 10)
        local tooltip     = "Target mob " .. i .. " - " .. mob_text
        if is_express then
            tooltip = tooltip .. "\n* express: goes straight to the room you " ..
                      "have killed it in, not the area entrance."
        end
        mob_text          = ellipsify(mob_text, 32)

        -- Destination type: "Mob " = go navigates to mob's kill room (express),
        --                   "Area" = go navigates to area start room only.
        local dest_type, dest_color
        if v.link_type == "area" then
            dest_type  = "Area"
            dest_color = "#808080"
        elseif is_express then
            dest_type  = "Mob "
            dest_color = "#FFD700"
        elseif v.link_type == "room" then
            dest_type  = "Area"
            dest_color = "#808080"
        else
            dest_type  = "----"
            dest_color = "#404040"
        end

        if v.link_type == "area" then
            local txt = string.format("%2d  %-32s - %-10s  ", i, mob_text, arid_str)
            Hyperlink("xcp " .. i, txt, tooltip, color, bg, 0, 1)
            Hyperlink("xcp " .. i, dest_type, tooltip, dest_color, bg, 0, 1)
            Hyperlink("roomnote area " .. v.arid,
                string.format("  %-29s", "[notes]"),
                "Notes for " .. v.arid,
                (v.is_dead == "yes") and "#006000" or "lightgreen", bg, 0, 1)

        elseif v.link_type == "room" and v.unlikely then
            Hyperlink("xcp " .. i, string.format("%2d  ", i), tooltip, color, bg, 0, 1)
            Hyperlink("xcp " .. i, "(U) ", tooltip,
                snd_get_setting("color_unlikely_tag", "#0000CD"), bg, 0, 1)
            Hyperlink("xcp " .. i, dest_type, tooltip, dest_color, bg, 0, 1)
            local rt  = string.format("'%s'", ellipsify(v.roomName or "", 27))
            local txt = string.format("%-28s - %-10s  %-29s",
                ellipsify(mob_text, 28), arid_str, rt)
            Hyperlink("xcp " .. i, txt, tooltip, color, bg, 0, 1)

        elseif v.link_type == "room" then
            local rt  = string.format("'%s'", ellipsify(v.roomName or "", 27))
            local txt = string.format("%2d  %-32s - %-10s  ", i, mob_text, arid_str)
            Hyperlink("xcp " .. i, txt, tooltip, color, bg, 0, 1)
            Hyperlink("xcp " .. i, dest_type, tooltip, dest_color, bg, 0, 1)
            Hyperlink("xcp " .. i, string.format("  %-29s", rt), tooltip, color, bg, 0, 1)

        elseif v.link_type == "unknown" then
            local loc = ellipsify(v.location or "?", 30)
            local txt = string.format("%2d  %-32s - unknown: '%s'%s  ",
                i, mob_text, loc, string.rep(" ", 30 - #loc))
            -- Space command: no navigation for unknown-location targets; row is display-only.
            Hyperlink(" ", txt, "Location not in mapper database", color, bg, 0, 1)
            Hyperlink(" ", dest_type, "Location not in mapper database", dest_color, bg, 0, 1)
        end

        -- Room link annotation: shown after the main line when configured.
        if v.rlink_note then
            ColourTell("#5858CC", bg, "  {" .. v.rlink_note .. "}")
        end

        -- Hop count from previous stop (set by optimize_target_order).
        if v.path_hops then
            local hops_str = v.path_hops < 99999 and tostring(v.path_hops) or "?"
            ColourTell("#4488AA", bg, "  " .. hops_str .. "h")
        end

        print("")
    end

    ColourNote("#808080", "", string.rep("-", 80))
    ColourNote("#808080", "", "Type 'xcp <index>' or click a link to go to that target.")
    if shown_express then
        ColourNote("#808080", "", "* express — goes straight to a known kill " ..
                   "room rather than the area entrance.")
    end
end

-- Print ignored targets (out-of-level-range room CP results).
function print_room_links_ignored()
    ColourNote("#808080", "", string.rep("-", 80))
    for _, v in ipairs(room_targets_ignored) do
        local txt = string.format(" ** Ignoring (level %d-%d): %s - '%s' (%s)",
            v.minlvl, v.maxlvl, v.mob, v.roomName or "?", v.arid)
        if v.roomid then
            Hyperlink("xmapper move " .. v.roomid, txt,
                "Move to room " .. v.roomid, "#002460", "", 0, 1)
            print("")
        else
            ColourNote("#002460", "", txt)
        end
    end
end

-- ─── TARGET STATE API ─────────────────────────────────────────────────────────

function has_target()
    return current_target ~= nil
end

function has_activity_target()
    return current_target ~= nil
        and (current_target.activity == "cp"
          or current_target.activity == "gq"
          or current_target.activity == "quest")
end

function has_active_quest()
    return quest_target and quest_target.qstat == "2"
end

function is_quest_mob_targeted()
    return current_target ~= nil and current_target.activity == "quest"
end

function is_cp_or_gq_mob_targeted()
    return current_target ~= nil
        and (current_target.activity == "cp" or current_target.activity == "gq")
end

function target_matches_current_target(target, index)
    if not current_target then return false end
    if target.mob       ~= current_target.name     then return false end
    if target.roomName  ~= current_target.room_name then return false end
    if target.arid      ~= current_target.area      then return false end
    if current_activity ~= current_target.activity  then return false end
    if index and index  ~= current_target.index     then return false end
    return true
end

function set_target_from_main_target_list(index, keyword)
    local target = main_target_list[index]
    if not target then return end
    keyword = keyword or target.kw
    change_target({
        name      = target.mob,
        keyword   = keyword,
        room_name = target.roomName,
        index     = index,
        area      = target.arid,
        activity  = current_activity,
    })
end

function set_target_from_quest(qt)
    -- Special-case SoH2 outer-space rooms.
    if qt.room == "Outer Space" and qt.areaName == "The School of Horror" then
        qt.arid = "sohtwo"
    end
    qt.keyword = gmkw(qt.mob, qt.arid)

    -- Look up the mapper room ID so navigation can path directly to the room.
    local roomid = nil
    if mapper_db_file and (qt.room or "") ~= "" then
        local ok = pcall(function()
            local mapdb = sqlite3.open(mapper_db_file)
            -- Prefer exact area-key match (fast path).
            if (qt.arid or "") ~= "" then
                for row in mapdb:nrows(
                    "SELECT r.uid FROM rooms r " ..
                    "INNER JOIN areas a ON r.area = a.uid " ..
                    "WHERE r.name = " .. fixsql(qt.room) ..
                    " AND a.uid = "   .. fixsql(qt.arid) ..
                    " LIMIT 1"
                ) do
                    roomid = tonumber(row.uid)
                end
            end
            -- Fallback: match by area display name (handles cases where arid
            -- resolution via area_key_from_name() did not find a mapper key).
            if not roomid and (qt.areaName or "") ~= "" then
                for row in mapdb:nrows(
                    "SELECT r.uid FROM rooms r " ..
                    "INNER JOIN areas a ON r.area = a.uid " ..
                    "WHERE r.name = "          .. fixsql(qt.room) ..
                    " AND LOWER(a.name) = LOWER(" .. fixsql(qt.areaName) .. ")" ..
                    " LIMIT 1"
                ) do
                    roomid = tonumber(row.uid)
                end
            end
            mapdb:close()
        end)
        if ok then
            if roomid then
                DebugNote("SnD: quest room lookup: '" .. qt.room .. "' → roomid " .. roomid)
            else
                DebugNote("SnD: quest room lookup: '" .. qt.room .. "' not found in mapper")
            end
        else
            DebugNote("SnD: quest room lookup failed (mapper DB error)")
        end
    end

    change_target({
        name      = qt.mob,
        keyword   = qt.keyword,
        room_name = qt.room,
        roomid    = roomid,
        area      = qt.arid,
        activity  = "quest",
    })
end

-- A target the player named directly, via 'qw <mob>' or 'ht <mob>', rather
-- than one picked off the campaign list.
--
-- `name` matters: it is what the rest of the plugin prints when it refers to
-- "the mob you are targeting", and it was left unset here. Killing a campaign
-- mob while one of these was current then hit
-- ".. current_target.name" with nil and threw, which also poisoned the trigger
-- so the window stopped updating for the rest of the session. The typed
-- keyword is the only name we have, and it is what the player called it.
function set_adhoc_target(keyword)
    change_target({
        name     = keyword,
        keyword  = keyword,
        area     = gmcp("room.info.zone") or "",
    })
end

function clear_target()
    change_target(nil)
end

function change_target(new_target)
    if are_targets_identical(current_target, new_target) then
        DebugNote("SnD: change_target: target unchanged")
        return
    end
    current_target = new_target
    if new_target then
        BroadcastPlugin(1, "target_changed")
    else
        BroadcastPlugin(2, "target_cleared")
    end
end

function update_target_keyword(new_keyword)
    if not current_target then return end
    current_target.keyword = new_keyword
    BroadcastPlugin(3, "keyword_changed")
end

function are_targets_identical(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return a.name     == b.name
       and a.keyword  == b.keyword
       and a.room_name== b.room_name
       and a.area     == b.area
       and a.activity == b.activity
       and a.index    == b.index
end

function target_as_json()
    return json.encode(current_target)
end

-- ─── CP/GQ CAPTURE HELPERS ────────────────────────────────────────────────────

-- Concatenate style-run text fields from one captured output line.
-- MUSHclient passes styles as {[1]={text="..",textcolour=..}, [2]=...}.
local function styles_to_text(line_styles)
    local parts = {}
    for _, run in ipairs(line_styles) do
        if run.text then parts[#parts+1] = run.text end
    end
    return table.concat(parts)
end

-- Re-emit a captured (and gagged) block of lines to the output window with
-- their original colors intact.  Used when a capture that was hidden by
-- omit_response_from_output turns out to contain output the player should see
-- (e.g. "You are not currently on a campaign").
local function replay_captured_styles(captured_styles)
    for _, line_styles in ipairs(captured_styles) do
        for _, run in ipairs(line_styles) do
            if run.text then
                ColourTell(
                    RGBColourToName(run.textcolour),
                    RGBColourToName(run.backcolour),
                    run.text
                )
            end
        end
        print("")
    end
end

-- ─── CAPTURE TIMEOUT ─────────────────────────────────────────────────────────

-- Capture.untagged_output fires this only when a capture genuinely times out:
-- the library nils the timeout callback as soon as the end tag is seen, so a
-- successful capture never reaches here.
--
-- Every capture below clears the target list and redraws BEFORE sending its
-- command, so a timeout used to leave an empty CP/GQ tab with nothing said
-- about why -- indistinguishable from "you have no targets". Say what
-- happened and what to run again.
local function capture_timeout(what, retry_cmd)
    return function()
        ErrorNote("SnD: '" .. what .. "' did not finish within 20 seconds.")
        InfoNote("SnD: The target list may be empty or stale — run '" ..
                 retry_cmd .. "' to try again.")
        if type(xg_draw_window) == "function" then xg_draw_window() end
    end
end

-- ─── CP INFO ─────────────────────────────────────────────────────────────────

-- Send "cp info" and capture the full response via echo bookmarks.
-- Capture.untagged_output handles paging, compact, and prompt mode.
function do_cp_info()
    cp_info_list         = {}
    main_target_list     = {}
    room_targets_ignored = {}
    if type(xg_draw_window) == "function" then xg_draw_window() end
    Capture.untagged_output(
        "cp info",
        true,                -- no_command_echo: suppress the sent line
        false,               -- omit_response_from_output: show output to user
        false,               -- no_prompt_after
        on_cp_info_captured, -- callback(captured_styles, start_line, end_line)
        false,               -- send_via_execute
        capture_timeout("cp info", "xcp"),   -- timeout_callback
        20                   -- timeout_duration (seconds)
    )
end

-- Called by Capture once the full "cp info" response has been collected.
function on_cp_info_captured(captured_styles, start_line, end_line)
    for _, ls in ipairs(captured_styles) do
        local text = styles_to_text(ls)
        -- "Level Taken........: [  201 ]"
        local level = text:match("Level Taken%.+:%s*%[%s*(%d+)%s*%]")
        if level then
            cp_info_level = tonumber(level) or 0
            snd_set_setting("cp_level_taken", tostring(cp_info_level), false)
        end
        -- "Find and kill 1 * mob name (location)"
        local target = text:match("^Find and kill %d+ %* (.+)$")
        if target then
            local mob, loc = parse_mob_target(target)
            if mob then cp_info_list[#cp_info_list+1] = {mob=mob, loc=loc} end
        end
    end
    cp_info_end()
end

function cp_info_end()
    player_on_cp    = "yes"
    current_activity= "cp"
    area_room_type  = area_room_type_check(cp_info_list)
    InfoNote("SnD: cp type: " .. area_room_type .. " (level " .. cp_info_level .. ")")
    if type(xg_draw_window) == "function" then xg_draw_window() end
    DoAfterSpecial(0.1, [[ do_cp_check() ]], sendto.script)
end

-- ─── CP CHECK ────────────────────────────────────────────────────────────────

function do_cp_check()
    local now = os.clock()
    if (now - last_cp_check) < 1.0 then return end
    last_cp_check  = now
    cp_check_list  = {}
    Capture.untagged_output(
        "cp ch",
        true,                 -- no_command_echo
        true,                 -- omit_response_from_output: hide from user
        false,                -- no_prompt_after
        on_cp_check_captured, -- callback
        false,                -- send_via_execute
        capture_timeout("cp check", "xcp"),  -- timeout_callback
        20                    -- timeout_duration (seconds)
    )
end

-- Called by Capture once the full "cp ch" response has been collected.
-- Works regardless of 'nohelp' setting — no sentinel line required.
function on_cp_check_captured(captured_styles, start_line, end_line)
    local not_on_cp = false
    for _, ls in ipairs(captured_styles) do
        local text = styles_to_text(ls)

        -- Detect "not on a campaign" — bail out cleanly.
        if text:match("You are not currently on a campaign") then
            not_on_cp = true
        end

        -- Parse today's CP completion counts (appear when not on a campaign).
        -- "You have completed N campaign(s) today."
        local n = text:match("You have completed (%d+) campaigns? today%.$")
        if n then
            today_cp_total = tonumber(n)
            if type(xg_draw_window) == "function" then xg_draw_window() end
        end
        -- "You have completed N campaign(s) today at this superhero."
        local m = text:match("You have completed (%d+) campaigns? today at this superhero%.$")
        if m then
            today_cp_superhero = tonumber(m)
            if type(xg_draw_window) == "function" then xg_draw_window() end
        end

        -- "You still have to kill * mob name (location)"
        local target = text:match("^You still have to kill %* (.+)$")
        if target then
            DebugNote(string.format("SnD: cp_check raw text=|%s|", text))
            local mob, loc, is_dead = parse_mob_target(target)
            if mob then
                DebugNote(string.format("SnD: cp_check parsed mob=|%s| loc=|%s|", mob, loc or ""))
                cp_check_list[#cp_check_list+1] = {mob=mob, qty=1, loc=loc, is_dead=is_dead}
            end
        end
    end

    if not_on_cp then
        replay_captured_styles(captured_styles)
        player_not_on_cp()
    else
        cp_check_end()
    end
end

function cp_check_end()
    player_on_cp    = "yes"
    current_activity= "cp"
    build_main_target_list("cp", area_room_type)
    if type(xcp_retry)           == "function" then xcp_retry() end
    if type(print_cp_prediction) == "function" then print_cp_prediction() end
end

-- ─── GQ INFO ─────────────────────────────────────────────────────────────────

-- Called from gqmsg_joined / gqmsg_started in the XML script block.
function do_gq_info()
    if gqid_joined ~= "-1" then
        if type(xcp_clear_target) == "function" then xcp_clear_target(false) end
        main_target_list     = {}
        room_targets_ignored = {}
        gq_info_list         = {}
        send_gq_info(gqid_joined)
    else
        send_gq_info()
    end
end

function send_gq_info(gqid)
    if debug_gq_mode then
        simulate_send_gq_info(gqid)
        return
    end
    local cmd = gqid and ("gq info " .. gqid) or "gq info"
    Capture.untagged_output(
        cmd,
        true,                -- no_command_echo
        false,               -- omit_response_from_output: show output to user
        false,               -- no_prompt_after
        on_gq_info_captured, -- callback
        false,               -- send_via_execute
        capture_timeout("gq info", "xgq"),   -- timeout_callback
        20                   -- timeout_duration (seconds)
    )
end

-- Called by Capture once the full "gq info" response has been collected.
function on_gq_info_captured(captured_styles, start_line, end_line)
    local pg = { id=nil, targets={}, extended=false, finished=false, efflvl=0 }
    for _, ls in ipairs(captured_styles) do
        local text = styles_to_text(ls)
        -- "Quest Name.........: [ Global quest # 1234 ]"
        local gqid = text:match("Quest Name%.+:%s*%[ Global quest # (%d+) %]")
        if gqid then pg.id = gqid end
        -- "Quest Status.......: [ Extended ]"
        if text:match("Quest Status%.+:%s*%[ Extended %]") then pg.extended = true end
        -- "Quest Status.......: [ Finished ]"
        if text:match("Quest Status%.+:%s*%[ Finished %]") then pg.finished = true end
        -- "Level range........: [  186 ] - [  201 ]"
        local minlvl, maxlvl =
            text:match("Level range%.+:%s*%[%s*(%d+)%s*%]%s*%-%s*%[%s*(%d+)%s*%]")
        if minlvl then
            pg.minlvl = tonumber(minlvl)
            pg.maxlvl = tonumber(maxlvl)
            pg.efflvl = math.floor((pg.minlvl + pg.maxlvl) / 2)
        end
        -- "Kill at least 1 * mob name (location)."
        local qty, target = text:match("^Kill at least (%d+) %* (.+)%.$")
        if qty and target then
            local mob, loc = parse_mob_target(target)
            if mob then table.insert(pg.targets, {mob=mob, qty=qty, loc=loc}) end
        end
    end
    on_gq_info_parsed(pg)
end

-- Process a fully-built gq-info record.  Called from on_gq_info_captured for
-- live output or directly from simulate_send_gq_info in debug mode.
function on_gq_info_parsed(pg)
    if pg.finished then
        DebugNote("SnD: gq info — finished quest, no action.")
        return
    elseif #pg.targets > 0 then
        player_is_on_gq()
        if pg.id ~= gq_history_id then
            history_start(HISTORY_TYPE_GQ)
            gq_history_id = pg.id
        end
        gq_info_list   = pg.targets
        gqid_joined    = pg.id
        gqid_started   = pg.id
        gqid_extended  = pg.extended and pg.id or "-1"
        snd_set_setting("gqid_joined",    gqid_joined,   false)
        snd_set_setting("gqid_started",   gqid_started,  false)
        snd_set_setting("gqid_extended",  gqid_extended, false)
        gq_info_efflvl = pg.efflvl
        snd_set_setting("gq_info_efflvl", tostring(gq_info_efflvl), false)
        gq_info_minlvl = pg.minlvl or 0
        gq_info_maxlvl = pg.maxlvl or 0
        area_room_type = area_room_type_check(gq_info_list)
        DebugNote("SnD: gq type: ", area_room_type, " (level ", gq_info_efflvl, ")")
        if type(xg_draw_window) == "function" then xg_draw_window() end
        DoAfterSpecial(0.1, "do_gq_check()", sendto.script)
    else
        DebugNote("SnD: gq info — pending/foreign gq, no action.")
    end
end

-- ─── GQ CHECK ────────────────────────────────────────────────────────────────

function do_gq_check()
    gq_check_list = {}
    if debug_gq_mode then
        simulate_send_gq_check()
        return
    end
    Capture.untagged_output(
        "gq ch",
        true,                  -- no_command_echo
        true,                  -- omit_response_from_output: hide from user
        false,                 -- no_prompt_after
        on_gq_check_captured,  -- callback
        false,                 -- send_via_execute
        capture_timeout("gq check", "xgq"),  -- timeout_callback
        20                     -- timeout_duration (seconds)
    )
end

-- Called by Capture once the full "gq ch" response has been collected.
-- Works regardless of 'nohelp' setting — no sentinel line required.
function on_gq_check_captured(captured_styles, start_line, end_line)
    local not_on_gq = false
    for _, ls in ipairs(captured_styles) do
        local text = styles_to_text(ls)

        -- Detect "not in a global quest" — bail out cleanly.
        if text:match("You are not in a global quest") then
            not_on_gq = true
        end

        -- "You still have to kill N * mob name (location)"
        local qty, target = text:match("^You still have to kill (%d+) %* (.+)$")
        if qty and target then
            local mob, loc, is_dead = parse_mob_target(target)
            if mob then
                gq_check_list[#gq_check_list+1] = {mob=mob, qty=qty, loc=loc, is_dead=is_dead}
            end
        end
    end

    if not_on_gq then
        replay_captured_styles(captured_styles)
        player_not_on_gq()
    else
        gq_check_end()
    end
end

function gq_check_end()
    player_is_on_gq()
    -- Every other assignment of current_activity is "cp" or "none" -- this one
    -- was missing, so on a gquest it stayed "none" and every command that
    -- guards on it refused to run. 'xcp' in particular aborted with "not on a
    -- CP or GQ" while the gq target list sat fully populated beside it.
    current_activity = "gq"
    build_main_target_list("gq", area_room_type)
    if type(xcp_retry) == "function" then xcp_retry() end
end

function player_is_on_gq()
    player_on_gq = "yes"
end

function player_not_on_gq()
    player_on_gq = "no"
    -- These are the groups the XML actually defines. The previous name here,
    -- "trg_gq", matches no trigger at all, so EnableTriggerGroup was a silent
    -- no-op and the GQ message triggers -- switched on when a GQ starts, and
    -- shipped enabled="n" precisely because they should only be live during
    -- one -- stayed armed for the rest of the session.
    EnableTriggerGroup("trg_gqmsg", false)
    EnableTriggerGroup("trg_gqmsg_ext", false)
    gq_check_list    = {}
    gq_info_efflvl   = 0
    gq_info_minlvl   = 0
    gq_info_maxlvl   = 0
    -- Always flush the GQ window cache so the tab clears immediately.
    if type(xg_update_target_list) == "function" then
        xg_update_target_list("gq", {})
    end
    if player_on_cp ~= "yes" then
        main_target_list    = {}
        room_targets_ignored= {}
        area_room_type      = "none"
        current_activity    = "none"
        if is_cp_or_gq_mob_targeted() then clear_target() end
    end
    if type(xg_draw_window) == "function" then xg_draw_window() end
end

function player_not_on_cp()
    player_on_cp = "no"
    -- No EnableTriggerGroup call here on purpose.  This used to disable
    -- "trg_campaign", a group no trigger belongs to, so it did nothing.  The
    -- campaign groups the XML does define must stay enabled: trg_cp_2 carries
    -- player_start_new_cp and player_not_on_cp themselves (disabling it would
    -- stop the next campaign being noticed), and nothing anywhere re-enables
    -- trigger_group_campaign_rewards, so switching that off would silently
    -- kill reward capture for the rest of the session.
    cp_info_level = 0
    snd_set_setting("cp_level_taken", "0", false)
    cp_info_list  = {}
    cp_check_list = {}
    -- Always flush the CP window cache so the tab clears immediately.
    if type(xg_update_target_list) == "function" then
        xg_update_target_list("cp", {})
    end
    if player_on_gq ~= "yes" then
        main_target_list    = {}
        room_targets_ignored= {}
        area_room_type      = "none"
        current_activity    = "none"
        if is_cp_or_gq_mob_targeted() then clear_target() end
    end
    if type(xg_draw_window) == "function" then xg_draw_window() end
end

-- Search main_target_list for the mob we just killed using the damage/XP
-- tracking globals (last_mob_killed, set by trigger_receive_xp in the XML).
-- Returns index, entry (the first alive target matching the killed mob name in
-- the current zone), or nil, nil if no match is found.
-- Falls back to a zone-independent search so kills in adjacent rooms still work.
local function find_killed_target_by_last_mob()
    -- last_mob_killed is set in the XML preamble and updated by trigger_receive_xp.
    local killed_name = type(last_mob_killed) == "string"
        and last_mob_killed:lower() or nil
    if not killed_name or killed_name == "" then return nil, nil end

    local cur_zone = gmcp("room.info.zone") or ""

    -- Pass 1: match by mob name AND current zone (most precise).
    for i, entry in ipairs(main_target_list) do
        if entry.is_dead ~= "yes"
        and type(entry.mob) == "string"
        and entry.mob:lower() == killed_name
        and entry.arid == cur_zone then
            return i, entry
        end
    end
    -- Pass 2: match by mob name only (handles edge cases where zone differs).
    for i, entry in ipairs(main_target_list) do
        if entry.is_dead ~= "yes"
        and type(entry.mob) == "string"
        and entry.mob:lower() == killed_name then
            return i, entry
        end
    end
    return nil, nil
end

-- Common kill handler.  Identifies the killed mob via last_mob_killed (damage
-- tracker), marks it dead, and records the kill.  If the killed mob is the
-- same as current_target, clears navigation.  If it's a DIFFERENT mob (player
-- killed a CP mob incidentally while targeting another), the kill is recorded
-- and the list is updated but current_target is left unchanged so navigation
-- continues toward the originally-targeted mob.
-- What to call the current target in a message.
--
-- Never nil: a nil here does not just spoil the wording, it throws inside a
-- trigger, and MUSHclient then refuses to run that trigger again for the rest
-- of the session -- so one bad message stops the CP window updating entirely.
function snd_target_label()
    if type(current_target) ~= "table" then return "your target" end
    return tostring(current_target.name
                 or current_target.keyword
                 or "your target")
end

-- The keyword to send to the MUD for the current target, or nil.
--
-- Returns nil rather than a placeholder on purpose: a caller about to send
-- "scan <keyword>" must say it cannot, not send "scan " and confuse the
-- parser. Keywords come from gmkw(), which can legitimately have nothing for
-- a mob it has never seen.
function snd_target_keyword()
    if type(current_target) ~= "table" then return nil end
    local kw = current_target.keyword or current_target.name
    if type(kw) ~= "string" or kw == "" then return nil end
    return kw
end

-- Returns the index that was marked dead, or nil.
local function handle_mob_killed(activity)
    local killed_index, killed_entry = find_killed_target_by_last_mob()

    if killed_entry then
        -- Record the kill against the mob that was actually killed.
        record_target_killed({ mob = killed_entry.mob, area = killed_entry.arid })

        -- Multi-kill handling: GQ entries can have qty > 1 (e.g. "kill 2 * a hawk").
        -- Decrement the remaining count on each kill; only mark dead on the last one.
        -- CP entries always have qty = 1, so they always take the else branch.
        local qty = tonumber(main_target_list[killed_index].qty) or 1
        if qty > 1 then
            main_target_list[killed_index].qty = tostring(qty - 1)
            DebugNote("SnD: " .. activity .. " mob killed (multi): " .. killed_entry.mob ..
                      " (index " .. killed_index .. ", " .. (qty - 1) .. " remaining)")
        else
            main_target_list[killed_index].is_dead      = "yes"
            main_target_list[killed_index].player_killed = true
            DebugNote("SnD: " .. activity .. " mob killed: " .. killed_entry.mob ..
                      " (index " .. killed_index .. ")")
        end

        -- Only clear navigation if the killed mob WAS our current nav target.
        local is_nav_target = current_target
            and current_target.activity == activity
            and current_target.index   == killed_index
            and current_target.name    == killed_entry.mob
        if is_nav_target then
            -- Still more of this mob to kill at the same spot; keep navigating.
            if qty <= 1 then clear_target() end
        else
            -- Killed a mob we weren't explicitly heading toward.  Keep targeting.
            if current_target then
                if qty > 1 then
                    InfoNote("SnD: " .. killed_entry.mob ..
                             " [" .. activity:upper() .. "] count now " .. (qty - 1) ..
                             " (killed incidentally). Still targeting: " .. snd_target_label())
                else
                    InfoNote("SnD: " .. killed_entry.mob ..
                             " [" .. activity:upper() .. "] marked dead (killed incidentally)." ..
                             " Still targeting: " .. snd_target_label())
                end
            end
        end
        return killed_index

    elseif is_cp_or_gq_mob_targeted() then
        -- No last_mob_killed data available (damage tracker missed the fight).
        -- Fall back to original behavior: trust current_target.
        DebugNote("SnD: " .. activity .. " kill — no last_mob_killed; using current_target fallback")
        record_target_killed(current_target)
        local index = current_target.index
        if index and main_target_list[index] then
            local qty = tonumber(main_target_list[index].qty) or 1
            if qty > 1 then
                main_target_list[index].qty = tostring(qty - 1)
            else
                main_target_list[index].is_dead      = "yes"
                main_target_list[index].player_killed = true
            end
            if qty <= 1 then clear_target() end
        else
            clear_target()
        end
        return index
    end

    return nil
end

-- Called after the player kills a CP mob.
function cp_mob_killed()
    handle_mob_killed("cp")
    if type(xg_draw_window) == "function" then xg_draw_window() end
end

-- Called after a GQ mob kill.
function gq_mob_killed()
    handle_mob_killed("gq")
    -- Slightly longer than the cp path to let the server finish the kill-confirmation message.
    DoAfterSpecial(0.3, [[ do_gq_check() ]], sendto.script)
    if type(xg_draw_window) == "function" then xg_draw_window() end
end

-- Quest GMCP handler.
function quest_status_gmcp(q)
    local quest_time = q.wait or q.timer
    if quest_time then
        next_quest_time = os.time() + quest_time * 60
    end

    if q.action == "start" then
        history_start(HISTORY_TYPE_QUEST)
        quest_target = {
            qstat    = "2",
            mob      = q.targ,
            areaName = q.area,
            arid     = area_key_from_name(q.area) or q.area,
            room     = (q.room or ""):gsub("@[bcgmrwyBCDGMRWY]", ""),
        }
        target_quest_mob(true)

    elseif q.action == "status" and q.targ and q.timer then
        quest_target = {
            qstat    = "2",
            mob      = q.targ,
            areaName = q.area,
            arid     = area_key_from_name(q.area) or q.area,
            room     = (q.room or ""):gsub("@[bcgmrwyBCDGMRWY]", ""),
        }
        target_quest_mob(true)

    elseif q.action == "killed" then
        quest_target.qstat = "3"

    elseif q.action == "comp" or q.action == "fail" or q.action == "reset" then
        local status = HISTORY_STATUS_COMPLETE
        if q.action == "fail"  then status = HISTORY_STATUS_FAILED end
        if q.action == "reset" then status = HISTORY_STATUS_RESET  end
        history_quest_end(status, q.totqp, q.gold, q.pracs, q.trains, q.tp)
        quest_target = {qstat = "1"}
        if type(xcp_clear_target) == "function" then xcp_clear_target(false) end
        if type(qw_reset)         == "function" then qw_reset(false)          end

    elseif q.action == "ready" or q.action == "timeout" then
        quest_target     = {qstat = "0"}
        next_quest_time  = os.time()

    elseif q.action == "status" and q.status == "ready" then
        next_quest_time  = os.time()
        quest_target     = {qstat = "0"}

    elseif q.action == "status" and q.wait then
        quest_target     = {qstat = "1"}
    end

    snd_set_setting("qt_mob",      quest_target.mob      or "", false)
    snd_set_setting("qt_arid",     quest_target.arid     or "", false)
    snd_set_setting("qt_areaName", quest_target.areaName or "", false)
    snd_set_setting("qt_room",     quest_target.room     or "", false)

    if is_quest_mob_targeted() and quest_target.qstat ~= "2" then
        clear_target()
    end

    if type(quest_timer_tick)    == "function" then quest_timer_tick() end
    if type(xg_set_active_tab)   == "function" then xg_set_active_tab("quest") end
    if type(xg_draw_window)      == "function" then xg_draw_window() end
end

-- Re-target the quest mob if it is not already targeted.
-- On the initial accept (force=true) also pre-populates the nx room list so
-- the player sees the search results immediately without needing to type 'go'.
function target_quest_mob(force)
    if not quest_target or quest_target.qstat ~= "2" then return end
    if not force and has_activity_target() then return end
    set_target_from_quest(quest_target)
    -- Auto-populate the goto/nx list when we have both a resolved roomid and a room name.
    if force and current_target and current_target.roomid
    and (current_target.room_name or "") ~= ""
    and type(search_rooms_exact) == "function" then
        gotoArea  = -1
        gotoIndex = 1
        next_room = -1
        gotoList  = {}
        search_rooms_exact(current_target.room_name, current_target.area, current_target.name)
        next_room = tostring(current_target.roomid)
    end
    if type(xg_draw_window) == "function" then xg_draw_window() end
end
