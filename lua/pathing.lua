-- pathing.lua
-- Target order optimization using the Aardwolf mapper DB (Aardwolf.db).
-- Depends on: constants.lua, util.lua, db.lua, settings.lua, targets.lua
--
-- Public API:
--   optimize_target_order([current_room])
--     Reorders main_target_list in-place to minimize total travel distance.
--     current_room: player's room ID (number/string); defaults to GMCP value.
--     Returns true if the list was reordered, false otherwise.
--
--   xset_rlink(name, line, wildcards)
--     Manage player-configured room links (room1 ↔ room2 + annotation note).
--     'xset rlink'               → list all configured links
--     'xset rlink R1 R2'         → toggle link (removes if exists; adds if not)
--     'xset rlink R1 R2 {note}'  → add/update link with a route annotation
--
-- Distance oracle: our own BFS over the mapper's `exits` table (bfs_from).
-- The code will use the mapper's findpath when it is reachable, but in a
-- normal install it is NOT: MUSHclient gives every plugin its own Lua state,
-- aardmapper is required by the mapper plugin inside *its* state, and
-- findpath is only assigned there by mapper.init().  Nothing exports it to
-- us, and CallPlugin cannot marshal the table it returns.  So treat BFS as
-- the real implementation and findpath as an opportunistic upgrade.
--
-- Algorithm: each target is resolved to a routing room via a 3-tier fallback
-- (direct path to its specific room → a configured room link's near side →
-- the area's start room; see resolve_target).  Routable targets are grouped by
-- area, and area groups are ordered by a greedy nearest-neighbor chain
-- (see greedy_order_by_distance): difficulty is a hard priority (every
-- difficulty-1 area before any difficulty-2 area, and so on), and WITHIN a
-- difficulty tier each next area is whichever is nearest to wherever the
-- chain currently stands — start room → nearest area, that area's own
-- entry room → next nearest, and so on — not a one-time sort by distance
-- from the player's starting room.  Targets whose room ID is itself a maze
-- entrance skip the direct tier (maze exits shuffle in-game, so static
-- mapper distance data for rooms behind one is not trustworthy) but still
-- resolve via a room link or the area start.  Targets that can't be
-- resolved by any tier are deferred to the end of the list.

-- ─── TUNABLES ─────────────────────────────────────────────────────────────────

-- MAX_BFS_ROOMS controls how many rooms each BFS pass will visit before it
-- gives up.  This is the primary distance oracle in practice (see the header
-- note on findpath), so the cap governs real routing, not just a fallback.
--
-- Every search here is given the specific room(s) it needs and stops as soon
-- as they are all found, so this cap is only reached when a wanted room is
-- genuinely unreachable and the traversal expands the whole graph.  Rooms
-- beyond the cap report UNREACHABLE and get deferred to the end of the list.
--
-- It MUST exceed the real room count or reachable rooms start being reported
-- unreachable.  A live Aardwolf.db measured 35 022 rooms (the earlier 25 000,
-- chosen when the map was ~24 000, truncated a full traversal at depth 19),
-- so this leaves headroom for continued map growth.
local MAX_BFS_ROOMS = 60000  -- rooms explored per BFS before giving up
local UNREACHABLE   = 99999 -- sentinel for pairs with no found path

-- Level-based area entry-room overrides.
-- Prosper has two distinct entry points depending on player level.
local PROSPER_HL_THRESHOLD = 175   -- level above which the override applies
local PROSPER_HL_ROOM      = 28257 -- high-level entry room (level > 175)

-- Apply level-based entry-room overrides for areas that have them.
-- Returns the effective room ID to use for routing (may differ from base_rid).
local function effective_start_room(arid, base_rid)
    if arid == "prosper" then
        local lvl = tonumber(gmcp("char.status.level")) or 0
        if lvl > PROSPER_HL_THRESHOLD then return PROSPER_HL_ROOM end
    end
    return base_rid
end

-- ─── INTERNAL: BEST-KNOWN SPECIFIC ROOM FOR A TARGET ──────────────────────────

-- Return the most specific room we know about for entry, based on kill/
-- sighting history and mapper name matches.  Returns nil when no specific-
-- room signal exists at all.  Deliberately does NOT fall back to the area
-- start room — that's a separate, later tier in resolve_target() below, so
-- callers can distinguish "we have a specific room" from "we're falling
-- back to the area entrance" (the maze-room check needs that distinction).
--
-- room-type CP (mob name + specific room name from game output):
--   Collect all mapper rooms matching (room_name, area), then among those:
--   1. Most-killed room from mob_kills                             [best history]
--   2. Most-seen room from mob_sightings                          [best likelihood]
--   3. First candidate (lowest mapper uid)                         [structural]
--   Fallback when no mapper candidates: entry.roomid, then zone-wide kills.
--
-- area-type CP (mob name + area name from game output):
--   1. entry.roomid — already the best-kill room from build_area_targets
--   2. mob_kills highest-kill room (defensive; should already be in entry.roomid)
--
-- snddb / mapdb: open DB handles shared by the caller; may be nil (graceful skip).
local function specific_target_room(entry, snddb, mapdb)
    local arid = entry.arid
    local arid_ok = arid and arid ~= "-1"

    if entry.link_type == "room" then
        -- Collect all mapper room IDs whose name matches this CP target's room name.
        local candidates = {}
        if mapdb and entry.roomName and entry.roomName ~= "" and arid_ok then
            for row in mapdb:nrows(
                "SELECT CAST(uid AS INTEGER) AS uid FROM rooms" ..
                " WHERE name=" .. fixsql(entry.roomName) ..
                " AND area=" .. fixsql(arid) ..
                " ORDER BY CAST(uid AS INTEGER)"
            ) do
                local rid = tonumber(row.uid)
                if rid and rid > 0 then candidates[#candidates+1] = rid end
            end
        end
        if #candidates > 0 then
            if snddb and entry.mob then
                local in_clause = table.concat(candidates, ",")
                -- 1. Most-killed room among name-matched candidates.
                for row in snddb:nrows(
                    "SELECT roomid FROM mob_kills" ..
                    " WHERE mob=" .. fixsql(entry.mob:lower()) ..
                    " AND roomid IN (" .. in_clause .. ")" ..
                    " ORDER BY kill_count DESC LIMIT 1"
                ) do
                    local rid = tonumber(row.roomid)
                    if rid and rid > 0 then return rid end
                end
                -- 2. Most-seen room among name-matched candidates.
                for row in snddb:nrows(
                    "SELECT roomid FROM mob_sightings" ..
                    " WHERE mob=" .. fixsql(entry.mob:lower()) ..
                    " AND roomid IN (" .. in_clause .. ")" ..
                    " ORDER BY seen_count DESC LIMIT 1"
                ) do
                    local rid = tonumber(row.roomid)
                    if rid and rid > 0 then return rid end
                end
            end
            -- 3. First candidate (lowest mapper uid) — no kill/sighting data yet.
            return candidates[1]
        end
        -- No mapper candidates: fall back to recorded roomid and area anchors.
        -- 4. roomid recorded during target building.
        local rid = tonumber(entry.roomid)
        if rid and rid > 0 then return rid end
        -- 5. Zone-wide kill lookup (mapper doesn't know this room by name).
        if snddb and entry.mob and arid_ok then
            for row in snddb:nrows(
                "SELECT roomid FROM mob_kills" ..
                " WHERE mob=" .. fixsql(entry.mob:lower()) ..
                " AND zone=" .. fixsql(arid) ..
                " ORDER BY kill_count DESC LIMIT 1"
            ) do
                local rid2 = tonumber(row.roomid)
                if rid2 and rid2 > 0 then return rid2 end
            end
        end
        return nil
    end

    if entry.link_type == "area" and arid then
        -- 1. entry.roomid is already the best-kill room (set by build_area_targets).
        local rid = tonumber(entry.roomid)
        if rid and rid > 0 then return rid end
        -- 2. Defensive re-query (entry.roomid not populated for some reason).
        if snddb and entry.mob and arid_ok then
            for row in snddb:nrows(
                "SELECT roomid FROM mob_kills" ..
                " WHERE mob="  .. fixsql(entry.mob:lower()) ..
                " AND zone=" .. fixsql(arid) ..
                " ORDER BY kill_count DESC LIMIT 1"
            ) do
                rid = tonumber(row.roomid)
                if rid and rid > 0 then return rid end
            end
        end
    end

    return nil
end

-- ─── INTERNAL: EXIT GRAPH + BFS ──────────────────────────────────────────────

-- Adjacency for the mapper's `exits` table, built once and reused.
--
-- Walking the graph through SQLite costs one query per BFS depth level, and on
-- a live map a traversal reaches depth 144 across ~32 000 rooms -- measured at
-- roughly 2 seconds per search. Reading all ~107 000 exits once costs about
-- 0.7s and drops each later traversal to ~0.02s.
--
-- Keyed by database path plus modification time when LuaFileSystem is present,
-- so a map updated mid-session is picked up automatically. Without lfs the
-- graph is held for the life of this Lua state; pathing_graph_invalidate()
-- forces a rebuild.
local _graph      = nil   -- { [fromuid] = { touid, ... } }  (strings)
local _graph_seed = nil   -- portal destinations (fromuid='*')
local _graph_key  = nil

local function graph_key(path)
    local ok, lfs_mod = pcall(require, "lfs")
    if ok and type(lfs_mod) == "table" and lfs_mod.attributes then
        local attr = lfs_mod.attributes(path)
        if attr then
            return path .. "|" .. tostring(attr.modification) .. "|" .. tostring(attr.size)
        end
    end
    return path
end

-- The mapper refuses exits the character cannot use, filtering on
-- exits.level: normal exits need level <= your level, while portals and
-- recalls are allowed up to level + tier*10 (aard_GMCP_mapper's findpath).
-- Matching that keeps our distances honest -- without it a route can be
-- measured through an exit the player will be turned away from, and the
-- mapper would then walk a different, longer way.
--
-- Returns nil when the character's level is not known yet (GMCP not in), in
-- which case no filter is applied and every exit is considered, as before.
local function player_exit_limits()
    local lvl = tonumber(gmcp("char.status.level"))
    if not lvl then return nil, nil end
    local tier = tonumber(gmcp("char.base.tier")) or 0
    return lvl, lvl + (tier * 10)
end

-- Older mapper databases (and the test fixtures) have no `level` column.
local function exits_has_level(mapdb)
    local found = false
    pcall(function()
        for row in mapdb:nrows("PRAGMA table_info(exits)") do
            if tostring(row.name) == "level" then found = true end
        end
    end)
    return found
end

-- Drop the cached graph so the next search rebuilds it.
function pathing_graph_invalidate()
    _graph, _graph_seed, _graph_key = nil, nil, nil
end

local function exit_graph(shared_db)
    if not mapper_db_file or mapper_db_file == "" then return nil, nil end

    -- Level is part of the key: a level-up changes which exits are usable, so
    -- the graph must be rebuilt rather than reused.
    local lvl, portal_lvl = player_exit_limits()
    local key = graph_key(mapper_db_file) ..
                "|lvl=" .. tostring(lvl) .. "|plvl=" .. tostring(portal_lvl)
    if _graph and _graph_key == key then return _graph, _graph_seed end

    local mapdb, own_db = shared_db, false
    if not mapdb then
        mapdb = sqlite3.open(mapper_db_file)
        if not mapdb then return nil, nil end
        own_db = true
    end

    local query = "SELECT fromuid, touid FROM exits"
    if lvl and exits_has_level(mapdb) then
        query = query ..
            " WHERE (fromuid NOT IN ('*','**') AND CAST(level AS INTEGER) <= " .. lvl .. ")" ..
            " OR (fromuid IN ('*','**') AND CAST(level AS INTEGER) <= " .. portal_lvl .. ")"
    end

    local adj, seed = {}, {}
    local ok, err = pcall(function()
        for row in mapdb:nrows(query) do
            local f, t = row.fromuid, row.touid
            if f ~= nil and t ~= nil then
                f, t = tostring(f), tostring(t)
                if f == "*" or f == "**" then
                    -- Portals ('*') and recalls ('**') are usable from
                    -- anywhere, so they are seeded at depth 1 rather than
                    -- reached through a real exit.
                    seed[#seed + 1] = t
                else
                    local a = adj[f]
                    if not a then a = {}; adj[f] = a end
                    a[#a + 1] = t
                end
            end
        end
    end)
    if own_db then mapdb:close() end
    if not ok then
        DebugNote("SnD: pathing: exit graph load failed: " .. tostring(err))
        return nil, nil
    end

    _graph, _graph_seed, _graph_key = adj, seed, key
    return _graph, _graph_seed
end

-- BFS from start_room over the in-memory exit graph.
-- Returns dist table: { ["roomid_string"] = hop_count, ... }
-- Stops after MAX_BFS_ROOMS unique rooms are visited.
--
-- Portals (fromuid='*') and recalls (fromuid='**') are stored by the mapper as
-- "usable from anywhere". No real room exits TO them, so they never enter the
-- frontier normally; their destinations are seeded at depth 1 and their own
-- neighbors are only expanded with the depth-2 wave, so rooms behind a
-- portal are not credited one hop short.
--
-- stop_rooms (optional): a single room or a list. The search ends as soon as
-- every listed room has been found -- the early exit is what keeps this cheap
-- when a whole candidate set is wanted at once.
--
-- shared_db (optional): an already-open mapper handle, used only if the graph
-- still needs building.
local function bfs_from(start_room, stop_rooms, shared_db)
    local sid      = tostring(start_room)
    local dist     = { [sid] = 0 }
    local visited  = 1

    local want, remaining = nil, 0
    if type(stop_rooms) == "table" then
        want = {}
        for _, r in ipairs(stop_rooms) do
            local k = tostring(r)
            if k ~= sid and not want[k] then
                want[k]   = true
                remaining = remaining + 1
            end
        end
        if remaining == 0 then want = nil end
    elseif stop_rooms ~= nil then
        local k = tostring(stop_rooms)
        if k ~= sid then want, remaining = { [k] = true }, 1 end
    end
    if want and remaining == 0 then return dist end

    local adj, seed = exit_graph(shared_db)
    if not adj then return dist end

    -- Seed portal destinations at depth 1, expanded with the depth-2 wave.
    local portal_pending = {}
    if seed then
        for i = 1, #seed do
            local tr = seed[i]
            if not dist[tr] and tonumber(tr) then
                dist[tr] = 1
                portal_pending[#portal_pending + 1] = tr
                visited = visited + 1
                if want and want[tr] then
                    want[tr]  = nil
                    remaining = remaining - 1
                    if remaining == 0 then return dist end
                end
            end
        end
    end

    local frontier = { sid }
    local depth    = 0
    while #frontier > 0 and visited < MAX_BFS_ROOMS do
        depth = depth + 1
        local next_fr = {}
        for i = 1, #frontier do
            local a = adj[frontier[i]]
            if a then
                for j = 1, #a do
                    local tr = a[j]
                    if not dist[tr] and tonumber(tr) then
                        dist[tr]              = depth
                        next_fr[#next_fr + 1] = tr
                        visited               = visited + 1
                        if want and want[tr] then
                            want[tr]  = nil
                            remaining = remaining - 1
                            if remaining == 0 then return dist end
                        end
                        if visited >= MAX_BFS_ROOMS then break end
                    end
                end
            end
            if visited >= MAX_BFS_ROOMS then break end
        end

        frontier = next_fr
        if #portal_pending > 0 then
            for k = 1, #portal_pending do
                frontier[#frontier + 1] = portal_pending[k]
            end
            portal_pending = {}
        end
    end

    if visited >= MAX_BFS_ROOMS then
        DebugNote(string.format(
            "SnD: pathing: BFS from %s hit %d-room limit at depth %d — " ..
            "some distant areas may show no path",
            sid, MAX_BFS_ROOMS, depth))
    end

    return dist
end

-- ─── MAPPER PATHFINDING BRIDGE ───────────────────────────────────────────────

-- Returns the Aardwolf mapper module's findpath function, or nil.
-- The mapper loads aardmapper.lua via require "aardmapper", which (through
-- module("aardmapper", package.seeall)) sets _G.aardmapper as the module table.
-- findpath is a module-level (non-local) variable set during mapper.init(),
-- so it is accessible as aardmapper.findpath once the mapper has initialized.
local function get_mapper_findpath()
    local mod = rawget(_G, "aardmapper")
    if type(mod) == "table" and type(mod.findpath) == "function" then
        return mod.findpath
    end
    return nil
end

-- Returns the hop count from start_room to dest_room, or UNREACHABLE.
-- Delegates to the mapper's own findpath when available (no room-count limit,
-- uses the same portal and exit data the game itself uses).
-- Falls back to our BFS when the mapper module is not accessible.
-- Both room IDs should be integers.
local function hop_count(start_room, dest_room, shared_db)
    local fp = get_mapper_findpath()
    if fp then
        local ok, path = pcall(fp, start_room, dest_room, false, false)
        if ok and type(path) == "table" then
            return #path
        end
        return UNREACHABLE
    end
    -- BFS fallback (mapper not loaded / findpath not yet set)
    local dist = bfs_from(start_room, dest_room, shared_db)
    return dist[tostring(dest_room)] or UNREACHABLE
end

-- ─── MAPPER FINDPATH BRIDGE (EXPERIMENTAL) ───────────────────────────────────
--
-- Ask the mapper for a real path, in its own Lua state, and get the hop count.
--
-- Why bother: the mapper's findpath() handles noportal/norecall properly. If
-- the route starts with a portal you cannot use from where you stand, it walks
-- to a room where you can and portals from there, and it knows about bounce
-- portals. Our BFS seeds every portal destination at depth 1 regardless, so it
-- under-estimates distance wherever portals are not usable -- which shows up as
-- a worse visiting order, not a broken path, since the mapper still does the
-- walking.
--
-- Why it is awkward: plugins do not share a Lua state, so aardmapper.findpath
-- is not visible from here. CallPlugin can reach it (findpath is a plain global
-- in the mapper, not inside a module()) but cannot bring a table back. The path
-- arrives instead on broadcast channel 502, which the plugin file captures into
-- _snd_mapper_path_raw.
--
-- NOT VERIFIED IN A LIVE CLIENT. Nothing depends on it yet: it returns nil on
-- any doubt, and hop_count() keeps using the BFS until this is proven.
-- noportals/norecalls are findpath's own arguments, passed through so the
-- comparison can ask the same question twice: once with portals allowed and
-- once without. That difference is the price of our shortcut -- our search
-- treats every portal destination as one hop from anywhere, including from a
-- room that forbids portalling, where the real answer is "walk out first".
function snd_mapper_hops(src, dst, noportals, norecalls)
    if type(CallPlugin) ~= "function" then return nil end
    if type(PLUGIN_ID_MAPPER) ~= "string" then return nil end

    _snd_mapper_path_raw = nil
    local ok, rc = pcall(CallPlugin, PLUGIN_ID_MAPPER, "findpath",
                         tostring(src), tostring(dst),
                         noportals and "1" or "", norecalls and "1" or "")
    if not ok then
        DebugNote("SnD: mapper findpath: CallPlugin raised: " .. tostring(rc))
        return nil
    end

    -- The return code is not a success signal here. findpath returns a table,
    -- which CallPlugin cannot marshal back across plugin states, so it reports
    -- an error (30040) even when the routine ran to completion. What it
    -- broadcasts on channel 502 just before returning is the actual result, so
    -- that is what decides success.
    DebugNote("SnD: mapper findpath: CallPlugin returned " .. tostring(rc))

    local raw = _snd_mapper_path_raw
    _snd_mapper_path_raw = nil
    if type(raw) ~= "string" or raw == "" then
        DebugNote("SnD: mapper findpath: no path broadcast arrived")
        return nil
    end

    local body = raw:match("=%s*(%b{})")
    if not body then return nil end
    local chunk = loadstring("return " .. body)
    if not chunk then return nil end
    local ok2, path = pcall(chunk)
    if not ok2 or type(path) ~= "table" then return nil end

    -- One entry per action, which is what makes this directly comparable to a
    -- hop count: a portal step is one entry just as a walked exit is, e.g.
    --   { [1] = { dir = "port 1264387409", uid = "24391" },
    --     [2] = { dir = "w", uid = "24390" }, ... }
    --
    -- Counted rather than taken from #path: the mapper serialises explicit
    -- integer keys, and # is only defined for a table without holes. A count
    -- says what is meant and cannot be surprised.
    local n = 0
    while path[n + 1] ~= nil do n = n + 1 end
    return n
end

-- The route our BFS believes in, step by step, for comparing against the
-- mapper's during testing.
--
-- Diagnostic only. bfs_from() records distances, not routes, because routing is
-- the mapper's job -- so this walks the same graph again keeping parents. It
-- marks the step where a portal was assumed, which is the disagreement worth
-- seeing: every portal destination is seeded at depth 1 regardless of whether
-- a portal can be used from where the player stands.
function snd_bfs_path(src, dst)
    local adj, seed = exit_graph()
    if not adj then return nil end

    local sid, did = tostring(src), tostring(dst)
    if sid == did then return {} end

    local parent, how = { [sid] = false }, {}
    local frontier    = { sid }

    -- Same seeding as bfs_from: portal and recall destinations are reachable
    -- from anywhere at cost 1.
    local pending = {}
    for i = 1, #(seed or {}) do
        local tr = seed[i]
        if parent[tr] == nil and tonumber(tr) then
            parent[tr] = sid
            how[tr]    = "portal/recall (assumed usable here)"
            pending[#pending + 1] = tr
        end
    end

    local function walk_back(node)
        local out = {}
        while node and node ~= sid do
            table.insert(out, 1, { room = node, via = how[node] or "exit" })
            node = parent[node]
        end
        return out
    end

    if parent[did] ~= nil then return walk_back(did) end

    local depth = 0
    while #frontier > 0 and depth < 400 do
        depth = depth + 1
        local nxt = {}
        for _, from in ipairs(frontier) do
            for _, to in ipairs(adj[from] or {}) do
                if parent[to] == nil then
                    parent[to] = from
                    if to == did then return walk_back(did) end
                    nxt[#nxt + 1] = to
                end
            end
        end
        -- Portal destinations join the search with the depth-2 wave, matching
        -- bfs_from, so rooms behind a portal are not credited one hop short.
        if depth == 1 then
            for _, tr in ipairs(pending) do nxt[#nxt + 1] = tr end
        end
        frontier = nxt
    end
    return nil
end

-- The mapper's route, parsed, for the same comparison.
function snd_mapper_path(src, dst)
    if type(CallPlugin) ~= "function" then return nil end
    _snd_mapper_path_raw = nil
    local ok = pcall(CallPlugin, PLUGIN_ID_MAPPER, "findpath",
                     tostring(src), tostring(dst))
    if not ok then return nil end
    local raw = _snd_mapper_path_raw
    _snd_mapper_path_raw = nil
    if type(raw) ~= "string" then return nil end
    local body = raw:match("=%s*(%b{})")
    if not body then return nil end
    local chunk = loadstring("return " .. body)
    if not chunk then return nil end
    local ok2, path = pcall(chunk)
    if not ok2 or type(path) ~= "table" then return nil end
    return path
end

-- Our own BFS answer, for comparing against the mapper's during testing.
function snd_bfs_hops(src, dst)
    local d = bfs_from(tonumber(src), tonumber(dst))
    local n = d and d[tostring(dst)]
    if not n or n >= UNREACHABLE then return nil end
    return n
end

-- ─── MAZE ROOM DETECTION ─────────────────────────────────────────────────────

-- Returns true when the given room ID is itself a maze entrance.
-- Uses the in-memory mazeStartRooms table (populated at load by areas.lua,
-- keyed by integer room ID).  Checking the ROOM, not the area, prevents
-- false-positive deferral of non-maze targets that share an area with a maze
-- entrance (e.g., guard of the hall in gwillim is not behind the maze even
-- though some gwillim rooms are maze start rooms).
local function is_maze_room(roomid)
    if type(mazeStartRooms) ~= "table" then return false end
    if mazeStartRooms[roomid] then return true end
    local n = tonumber(roomid)
    return n ~= nil and mazeStartRooms[n] ~= nil
end

-- ─── INTERNAL: AREA ANCHOR ROOM ─────────────────────────────────────────────

-- Returns the area start room for non-express mobs — the room used for BFS
-- distance purposes when no specific kill room is needed.
-- Falls back to MIN(uid) from the mapper when no configured start room exists.
local function area_anchor_room(arid, snddb, mapdb)
    if not arid or arid == "-1" then return nil end
    if snddb then
        for row in snddb:nrows(
            "SELECT start_room FROM areas WHERE key=" .. fixsql(arid) .. " LIMIT 1"
        ) do
            local st = effective_start_room(arid, tonumber(row.start_room))
            if st and st > 0 then return st end
        end
    end
    if mapdb then
        for row in mapdb:nrows(
            "SELECT MIN(CAST(uid AS INTEGER)) AS lo FROM rooms" ..
            " WHERE area=" .. fixsql(arid)
        ) do
            local r = tonumber(row.lo)
            if r and r > 0 then return r end
        end
    end
    return nil
end

-- The room routing would actually aim at for an area target, for tests and
-- comparisons.
--
-- An area target has no roomid of its own -- resolve_target() falls back to the
-- area's anchor room -- so comparing only entries that carry a roomid leaves
-- out most of a campaign.
function snd_area_anchor(arid)
    if type(arid) ~= "string" or arid == "" or arid == "-1" then return nil end
    local snddb = (type(db_open) == "function") and db_open() or nil
    local mapdb = (mapper_db_file and mapper_db_file ~= "")
                  and sqlite3.open(mapper_db_file) or nil
    local ok, room = pcall(area_anchor_room, arid, snddb, mapdb)
    if snddb and type(db_close) == "function" then db_close(snddb) end
    if mapdb then pcall(function() mapdb:close() end) end
    if not ok then return nil end
    return tonumber(room)
end


-- ─── INTERNAL: ROOM LINKS ────────────────────────────────────────────────────

-- Returns the "near" (mapper-reachable) side of a configured room link for
-- roomid, or nil when roomid has no link.  Symmetric: works whichever side
-- of the pair roomid is (a link connects two rooms with no inherent direction).
local function room_link_near_side(snddb, roomid)
    local near = nil
    for row in snddb:nrows(
        "SELECT room1, room2 FROM room_links WHERE room1=" .. roomid ..
        " OR room2=" .. roomid .. " LIMIT 1"
    ) do
        local r1, r2 = tonumber(row.room1), tonumber(row.room2)
        near = (r1 == roomid) and r2 or r1
    end
    return near
end

-- ─── INTERNAL: TARGET RESOLUTION (DIRECT → RLINK → AREA START) ───────────────

-- Resolve the routing room, hop count, and arrival room for a single target,
-- trying three tiers in order:
--
--   1. Direct — path straight to the target's best-known specific room
--      (specific_target_room).  Skipped when that room is itself a
--      registered maze entrance/interior: maze exits shuffle in-game, so
--      static mapper distance data for rooms behind one is not trustworthy
--      for routing (see is_maze_room).
--   2. Rlink  — path to the near (mapper-reachable) side of a configured
--      room link for that room.  The player's real arrival room is still
--      the target's own room (reached by hand across the link), so
--      `arrive` differs from `room` for this tier — callers must chain
--      subsequent hop calculations from `arrive`, not `room`.
--   3. Area   — the area's start room.  Always trusted even for maze areas:
--      the entrance itself is a normal, stable room; only rooms *behind* it
--      shuffle.
--
-- hops_fn(a, b) is the memoized hop-count lookup shared by the caller.
-- anchor_cache memoizes area_anchor_room() per arid across every target in
-- the same optimize_target_order() call, since many targets typically share
-- an area.
--
-- Returns { room=<room hops were measured to>, arrive=<room the player ends
-- up standing in>, hops=N, via="direct"|"rlink"|"area" }, or nil when even
-- the area start room can't be resolved or reached.
local function resolve_target(entry, from_room, snddb, mapdb, hops_fn, anchor_cache, from_arid)
    local target_room = specific_target_room(entry, snddb, mapdb)

    if target_room and not is_maze_room(target_room) then
        local h = hops_fn(from_room, target_room)
        if h < UNREACHABLE then
            return { room = target_room, arrive = target_room, hops = h, via = "direct" }
        end
    end

    if target_room then
        local near = room_link_near_side(snddb, target_room)
        if near then
            local h = hops_fn(from_room, near)
            if h < UNREACHABLE then
                return { room = near, arrive = target_room, hops = h, via = "rlink" }
            end
        end
    end

    local arid = entry.arid

    -- Already standing in the target's area.
    --
    -- Reaching this tier means there is no specific room to walk to, so the
    -- plan is "hunt or where from inside the area" -- and you are inside it.
    -- Measuring to the area's start room from here is backwards: it charges
    -- hops for a journey that should not happen, and on a multi-target area it
    -- sends you back to the entrance after each kill. Checked before the
    -- anchor lookup so it holds for areas with no start room configured too.
    if arid and from_arid and from_arid == arid then
        return { room = from_room, arrive = from_room, hops = 0, via = "area" }
    end

    local start_room
    if arid then
        start_room = anchor_cache[arid]
        if start_room == nil then
            start_room = area_anchor_room(arid, snddb, mapdb) or false
            anchor_cache[arid] = start_room
        end
    end
    if start_room then
        local h = hops_fn(from_room, start_room)
        if h < UNREACHABLE then
            return { room = start_room, arrive = start_room, hops = h, via = "area" }
        end
    end

    return nil
end

-- ─── PUBLIC API ───────────────────────────────────────────────────────────────

-- Reorder main_target_list in-place, ordering by hop distance from the player.
--
-- Routing room resolution (resolve_target, applied uniformly to every target
-- regardless of express status — express only affects display/ordering, not
-- which room hop distance is measured to):
--   1. Direct — the target's best-known specific room (specific_target_room),
--      via the mapper's own findpath.  Skipped for rooms flagged as maze
--      entrances/interiors (shuffled exits make static distance data there
--      untrustworthy).
--   2. Rlink  — a configured room link's near (mapper-reachable) side, when
--      direct pathing fails or was skipped.  The player's real arrival room
--      is still the target's own room, reached by hand across the link.
--   3. Area   — the area's start room, always trusted.
--
-- Three-tier ordering:
--   1. "reachable" — resolve_target succeeded (any of the 3 tiers above).
--                    Grouped by area; area groups ordered by a greedy
--                    nearest-neighbor chain within each difficulty tier
--                    (see greedy_order_by_distance) — difficulty ASC always
--                    wins, hop distance ASC breaks ties within a tier, and
--                    that distance is measured from wherever the chain
--                    currently is, not always from the player's start room.
--   2. "no_path"   — resolve_target failed for every tier (no area data, or
--                    genuinely unreachable even at the area-start room).
--   3. "unlikely"  — entry.unlikely = true; always last.
--
-- Express grouping (setting "pathing_express_group"):
--   "off"   — no special grouping; a single greedy chain covers every area
--             (the default).
--   "first" — all area groups that contain at least one express mob are
--             chained first, then non-express area groups continue the
--             chain from wherever the express half ended (each half its
--             own independent greedy chain, not two chains from cur_id).
--   "last"  — same, with non-express chained first and express second.
--
-- Within a mixed area group (both express and non-express mobs): express mobs
-- are listed first so the player navigates to the specific kill room first, then
-- handles the remaining mobs from there.
--
-- Hop count display:
--   First mob in each new area: hops from the previous ARRIVAL room (player
--   start for the first area; where the player actually ends up standing
--   after the prior area's last stop — the target's own room when that stop
--   was rlink-routed, not the link's near side).
--   Subsequent non-express mobs in the same area: 0 (no specific room to
--   navigate to; player searches from wherever the previous kill left them).
--   Subsequent express mobs in the same area: hops from the previous room
--   to their specific kill room (in-area navigation is required).
--
-- Settings: "pathing_enabled" (on/off), "pathing_express_group" (off/first/last).
--
-- Returns true when the list was reordered, false otherwise.
function optimize_target_order(current_room)
    if type(main_target_list) ~= "table" or #main_target_list < 2 then
        return false
    end
    if not mapper_db_file or mapper_db_file == "" then
        DebugNote("SnD: pathing: mapper_db_file not set, skipping")
        return false
    end
    if snd_get_setting("pathing_enabled", "on") ~= "on" then
        return false
    end

    -- Declared outside the pcall so the cleanup below still runs when the body
    -- raises.  Closing is idempotent: cleanup() nils both handles.
    local snddb, mapdb
    local function cleanup()
        if snddb then db_close(snddb); snddb = nil end
        if mapdb then mapdb:close();   mapdb = nil end
    end

    local ok, result = pcall(function()

    local cur_id = tonumber(current_room) or tonumber(gmcp("room.info.num")) or 0

    -- The area the player is standing in, so a target whose only route is
    -- "go to the area" can be recognised as already reached. GMCP is the
    -- authority; current_room is a fallback for when it has not arrived yet.
    local cur_arid = gmcp("room.info.zone")
    if (not cur_arid or cur_arid == "") and type(current_room) == "table" then
        cur_arid = current_room.arid
    end

    snddb = db_open()
    mapdb = sqlite3.open(mapper_db_file)

    -- Memoised hop lookup, keyed "from|to".
    --
    -- The oracle is normally our BFS: findpath belongs to the mapper plugin's
    -- Lua state and is not reachable from ours (see the header note), so
    -- treat the BFS branch as the one that runs.
    --
    -- A BFS that runs to exhaustion is expensive -- on the real ~35 000-room
    -- map that is over two seconds -- so every search is given the specific
    -- room(s) it needs and stops the moment they are all found.  Never start
    -- an open-ended traversal here.
    local findpath  = get_mapper_findpath()
    local hop_cache = {}

    local function hops(a, b)
        local key = tostring(a) .. "|" .. tostring(b)
        local c = hop_cache[key]
        if c ~= nil then return c end
        local h = hop_count(a, b, mapdb)
        hop_cache[key] = h
        return h
    end

    -- Resolve distances from `src` to many rooms in ONE traversal.
    --
    -- The greedy chain asks for the distance from its current position to
    -- every remaining candidate. Done pairwise that repeats the same walk
    -- once per candidate; batched, a single search covers them all and still
    -- stops as soon as the last one is found. Results land in the same cache
    -- hops() reads, so callers need no special path.
    --
    -- Only worthwhile for the BFS oracle: findpath is inherently per-pair.
    local function prewarm(src, rooms)
        if findpath or not rooms or #rooms == 0 then return end
        local ks, missing = tostring(src), {}
        for _, r in ipairs(rooms) do
            if hop_cache[ks .. "|" .. tostring(r)] == nil then
                missing[#missing + 1] = r
            end
        end
        if #missing == 0 then return end
        local dist = bfs_from(src, missing, mapdb)
        for _, r in ipairs(missing) do
            hop_cache[ks .. "|" .. tostring(r)] = dist[tostring(r)] or UNREACHABLE
        end
    end

    -- ── Resolve every target: direct → rlink → area start ────────────────────
    -- One pass, no separate reachability re-check pass: resolve_target()
    -- already tries all three tiers and reports the best reachable outcome.
    local routable          = {}
    local no_path           = {}
    local unlikely_deferred = {}
    local anchor_cache      = {}   -- arid -> area_anchor_room() result (or false)

    for _, entry in ipairs(main_target_list) do
        if entry.unlikely then
            unlikely_deferred[#unlikely_deferred + 1] = entry
        else
            local res = resolve_target(entry, cur_id, snddb, mapdb, hops,
                                       anchor_cache, cur_arid)
            if res then
                routable[#routable + 1] = {
                    entry      = entry,
                    room       = res.room,
                    arrive     = res.arrive,
                    cur_hops   = res.hops,
                    is_express = is_express_target(entry),
                }
            else
                no_path[#no_path + 1] = entry
            end
        end
    end

    if #routable == 0 and #unlikely_deferred == 0 then
        cleanup()
        return false
    end

    if #routable == 0 then
        local new_list = {}
        for _, entry in ipairs(no_path)           do new_list[#new_list+1] = entry end
        for _, entry in ipairs(unlikely_deferred) do new_list[#new_list+1] = entry end
        if #new_list > 0 then
            for i, entry in ipairs(new_list) do entry.index = i end
            for i = #main_target_list, 1, -1 do main_target_list[i] = nil end
            for i, entry in ipairs(new_list) do main_target_list[i] = entry end
        end
        cleanup()
        return false
    end

    -- ── Area difficulty lookup ────────────────────────────────────────────────
    local diff_for     = {}
    local mob_diff_for = {}   -- arid -> { [mob_lc] = difficulty }
    do
        local arids_seen = {}
        for _, r in ipairs(routable) do
            if r.entry.arid then arids_seen[r.entry.arid] = true end
        end
        local keys = {}
        for k in pairs(arids_seen) do keys[#keys + 1] = fixsql(k) end
        if #keys > 0 then
            for row in snddb:nrows(
                "SELECT key, difficulty FROM areas WHERE key IN (" ..
                table.concat(keys, ",") .. ")"
            ) do
                diff_for[row.key] = tonumber(row.difficulty) or 1
            end
            -- Per-mob ratings for the same areas.  Only rated mobs (>0) come
            -- back; everything else simply inherits its area's rating.
            --
            -- Guarded: mob ratings refine the route, they are not required for
            -- one.  A database predating the mob_tags.difficulty column must
            -- still route on area ratings alone rather than failing the whole
            -- pass, so a query error here is logged and skipped.
            local mok, merr = pcall(function()
                for row in snddb:nrows(
                    "SELECT zone, mob, difficulty FROM mob_tags WHERE difficulty > 0" ..
                    " AND zone IN (" .. table.concat(keys, ",") .. ")"
                ) do
                    local z, m = row.zone, row.mob
                    if z and m then
                        mob_diff_for[tostring(z)] = mob_diff_for[tostring(z)] or {}
                        mob_diff_for[tostring(z)][tostring(m):lower()] =
                            tonumber(row.difficulty) or 0
                    end
                end
            end)
            if not mok then
                DebugNote("SnD: pathing: mob difficulty lookup skipped: " .. tostring(merr))
            end
        end
    end

    -- Rating actually applied to one routable target: its own if it has one,
    -- otherwise its area's.
    local function target_difficulty(r)
        local arid = r.entry.arid
        local base = (arid and diff_for[arid]) or 1
        local mob  = r.entry.mob
        if arid and mob then
            local by_zone = mob_diff_for[arid]
            local own     = by_zone and by_zone[tostring(mob):lower()]
            if own and own > 0 then return own end
        end
        return base
    end

    -- The SnD database is finished with here.  The mapper database is NOT:
    -- the BFS hop oracle below reuses this handle for the greedy chain and
    -- the hop annotation pass, so it stays open until cleanup().
    if snddb then db_close(snddb); snddb = nil end

    -- ── Group by area ─────────────────────────────────────────────────────────
    local by_arid  = {}
    local arid_seq = {}
    for _, r in ipairs(routable) do
        local arid = r.entry.arid or ""
        if not by_arid[arid] then
            by_arid[arid]         = {}
            arid_seq[#arid_seq+1] = arid
        end
        by_arid[arid][#by_arid[arid]+1] = r
    end

    -- Area group metadata: difficulty and has_express flag. Difficulty acts
    -- as a hard priority/partition below; has_express drives the "first"/
    -- "last" express-grouping split. Actual visiting order is decided by
    -- greedy_order_by_distance, not a static per-group value.
    local group_key = {}
    for arid, grp in pairs(by_arid) do
        local has_express = false
        -- An area is rated by the AVERAGE of its targets, and only ever
        -- upward. target_difficulty() returns the area's own rating for an
        -- unrated mob, so an area with nothing rated averages exactly to
        -- itself and does not move; a rated mob pulls the average toward its
        -- own number in proportion to how much of the area it represents.
        --
        --   area 3, four mobs, one rated 5 -> (5+3+3+3)/4 = 3.5
        --   area 3, four mobs, three rated 5 -> (5+5+5+3)/4 = 4.5
        --
        -- Averaging below the area's rating never demotes it: an area you
        -- have called hard stays hard even if its mobs are individually mild.
        --
        -- The result is deliberately fractional. It is only ever used to sort
        -- tiers, never shown, so a 3.5 area slots cleanly between plain-3 and
        -- plain-4 areas instead of being rounded into one of them.
        local base  = diff_for[arid] or 1
        local sum, n = 0, 0
        for _, r in ipairs(grp) do
            if r.is_express then has_express = true end
            sum = sum + target_difficulty(r)
            n   = n + 1
        end
        local avg = (n > 0) and (sum / n) or base
        group_key[arid] = { diff = math.max(base, avg), has_express = has_express }
    end

    -- ── Order area groups: greedy nearest-neighbor chain ─────────────────────
    -- Difficulty is a hard priority (every difficulty-1 area before any
    -- difficulty-2 area, and so on), matching the documented "difficulty
    -- ASC, hop ASC" ordering. WITHIN a difficulty tier, each next area is
    -- whichever is nearest to wherever the chain currently stands -- not a
    -- one-time sort by distance from the player's starting room. That
    -- distinction is the whole point: an area that looks close to the START
    -- can be far from the area you actually visit FIRST, while a farther-
    -- from-start area might be right next door to it. Chaining greedily
    -- (start -> nearest, that area's entry room -> next nearest, ...) keeps
    -- the route from backtracking across the map the way a static sort can.
    --
    -- "Where you end up after an area" is approximated as the room nearest
    -- to the chain position at selection time (the area's own entry point)
    -- -- a reasonable stand-in for "still roughly where you entered"
    -- without simulating the area's full internal visiting order. The hop-
    -- count annotation pass below still computes the real per-target
    -- distances for display once this order is fixed.
    local function greedy_order_by_distance(arid_list, start_room)
        local by_diff     = {}
        local diffs_seen  = {}
        for _, arid in ipairs(arid_list) do
            local d = group_key[arid].diff
            if not by_diff[d] then
                by_diff[d] = {}
                diffs_seen[#diffs_seen + 1] = d
            end
            by_diff[d][#by_diff[d] + 1] = arid
        end
        table.sort(diffs_seen)

        local ordered = {}
        local pos = start_room
        for _, d in ipairs(diffs_seen) do
            local remaining = by_diff[d]
            while #remaining > 0 do
                -- One search from `pos` covering every candidate still in
                -- play, instead of one per candidate below.
                local candidates = {}
                for _, arid in ipairs(remaining) do
                    for _, r in ipairs(by_arid[arid]) do
                        candidates[#candidates + 1] = r.room
                    end
                end
                prewarm(pos, candidates)

                local best_i, best_dist, best_room = 1, nil, nil
                for i, arid in ipairs(remaining) do
                    for _, r in ipairs(by_arid[arid]) do
                        local dist = hops(pos, r.room)
                        if not best_dist or dist < best_dist then
                            best_dist, best_i, best_room = dist, i, r.room
                        end
                    end
                end
                local picked = table.remove(remaining, best_i)
                ordered[#ordered + 1] = picked
                pos = best_room or pos
            end
        end
        return ordered, pos
    end

    local express_mode = snd_get_setting("pathing_express_group", "off")

    if express_mode == "first" or express_mode == "last" then
        local exp_arids, non_arids = {}, {}
        for _, arid in ipairs(arid_seq) do
            if group_key[arid].has_express then
                exp_arids[#exp_arids + 1] = arid
            else
                non_arids[#non_arids + 1] = arid
            end
        end
        local first_list, second_list = exp_arids, non_arids
        if express_mode == "last" then first_list, second_list = non_arids, exp_arids end

        -- The second half's chain continues from wherever the first half's
        -- chain ended, not from cur_id -- same reasoning as within a tier.
        local first_ordered, pos = greedy_order_by_distance(first_list, cur_id)
        local second_ordered     = greedy_order_by_distance(second_list, pos)

        arid_seq = {}
        for _, a in ipairs(first_ordered)  do arid_seq[#arid_seq + 1] = a end
        for _, a in ipairs(second_ordered) do arid_seq[#arid_seq + 1] = a end
    else
        arid_seq = greedy_order_by_distance(arid_seq, cur_id)
    end

    -- ── Flatten + within-group ordering (express mobs first) ─────────────────
    local sorted = {}
    for _, arid in ipairs(arid_seq) do
        local grp     = by_arid[arid]
        local exp_grp = {}
        local non_grp = {}
        for i, r in ipairs(grp) do
            r._seq  = i                       -- keeps the sort stable
            r._diff = target_difficulty(r)
            if r.is_express then exp_grp[#exp_grp+1] = r
            else                 non_grp[#non_grp+1] = r end
        end
        -- Easiest-to-reach targets first within each partition, so the quick
        -- ones are picked up on the way in and the awkward one is left for
        -- last.  Express-first stays the outer rule: it is about having a
        -- known kill room to navigate to, which is a separate concern from how
        -- awkward the mob is to reach.
        local function by_difficulty(a, b)
            if a._diff ~= b._diff then return a._diff < b._diff end
            return a._seq < b._seq
        end
        table.sort(exp_grp, by_difficulty)
        table.sort(non_grp, by_difficulty)
        for _, r in ipairs(exp_grp) do sorted[#sorted+1] = r end
        for _, r in ipairs(non_grp) do sorted[#sorted+1] = r end
    end
    routable = sorted

    -- ── Hop count annotation ─────────────────────────────────────────────────
    -- First mob in each new area: hops from the previous ARRIVAL room. When
    -- still cur_id (first area), reuse r.cur_hops -- resolve_target already
    -- measured it from cur_id, so this needs no extra pathfinding call.
    -- Subsequent non-express mobs in the same area: 0 (no specific room).
    -- Subsequent express mobs in the same area: hops to their specific room.
    local prev_room = cur_id
    -- A table, not nil: entry.arid can itself be nil (the grouping above uses
    -- `arid or ""`), and `nil == nil` would make the very first target look
    -- like a same-area continuation and be annotated 0 hops instead of its
    -- real distance from the player.
    local prev_arid = {}
    for _, r in ipairs(routable) do
        local same_area = (r.entry.arid == prev_arid)
        if same_area and not r.is_express then
            r.entry.path_hops = 0
        else
            if prev_room == cur_id then
                r.entry.path_hops = r.cur_hops
            else
                r.entry.path_hops = hops(prev_room, r.room)
            end
            if not same_area then prev_arid = r.entry.arid end
        end
        -- Chain from where the player actually ends up standing, not from
        -- the room hops were measured to -- for an rlink-routed stop those
        -- differ (r.room is the link's near side; r.arrive is the target's
        -- real room, reached by hand across the link).
        prev_room = r.arrive
    end

    for _, entry in ipairs(no_path)           do entry.path_hops = nil end
    for _, entry in ipairs(unlikely_deferred) do entry.path_hops = nil end

    -- ── Build final list ──────────────────────────────────────────────────────
    local new_list = {}
    for _, r      in ipairs(routable)          do new_list[#new_list+1] = r.entry  end
    for _, entry  in ipairs(no_path)           do new_list[#new_list+1] = entry    end
    for _, entry  in ipairs(unlikely_deferred) do new_list[#new_list+1] = entry    end

    for i, entry in ipairs(new_list) do entry.index = i end
    for i = #main_target_list, 1, -1 do main_target_list[i] = nil end
    for i, entry in ipairs(new_list) do main_target_list[i] = entry end

    if type(debug_log_write) == "function" then
        debug_log_write("DEBUG", string.format(
            "pathing: route order (start room %d, express_group=%s):",
            cur_id, express_mode))
        for i, entry in ipairs(main_target_list) do
            local hops_disp = entry.path_hops
            local hops_str = (hops_disp and hops_disp < UNREACHABLE) and tostring(hops_disp) or "?"
            debug_log_write("DEBUG", string.format(
                "  %2d. %-30s (%s) [%s]  %s hops",
                i, entry.mob or "?", entry.arid or "?",
                is_express_target(entry) and "exp" or "nox",
                hops_str))
        end
    end

    InfoNote("SnD: pathing: route optimized.")
    return true

    end)   -- end pcall

    -- Runs on every exit path, including a raise inside the body.  The mapper
    -- handle now stays open for the whole routing pass, so without this an
    -- error partway through would orphan the connection.
    cleanup()

    if not ok then
        ErrorNote("SnD: pathing: " .. tostring(result))
        return false
    end
    return result == true
end

-- ─── XSET RLINK ──────────────────────────────────────────────────────────────

-- Manage player-configured room links.  A room link connects two room IDs with
-- an optional annotation note shown in the CP/GQ target list.  TSP (see
-- resolve_target in optimize_target_order) uses these as its second-tier
-- fallback when a target's specific room has no direct path: it routes to
-- the link's near (mapper-reachable) side and treats the target's own room
-- as the arrival point for chaining subsequent hop counts.
--
-- 'xset rlink'               → list all configured room links
-- 'xset rlink <r1> <r2>'     → toggle link (removes if exists; adds if not)
-- 'xset rlink <r1> <r2> {note}' → add or update link with an annotation note
function xset_rlink(name, line, wildcards)
    local r1   = tonumber(wildcards.r1 or "")
    local r2   = tonumber(wildcards.r2 or "")
    local note = Trim(wildcards.note or "")

    if not r1 or not r2 then
        -- List mode: show all configured links.
        local links = {}
        local db    = db_open()
        for row in db:nrows(
            "SELECT room1, room2, note FROM room_links ORDER BY room1, room2"
        ) do
            links[#links + 1] = row
        end
        db_close(db)

        if #links == 0 then
            InfoNote("SnD: No room links configured.")
        else
            InfoNote("SnD: Configured room links (" .. #links .. "):")
            for _, lnk in ipairs(links) do
                local note_part = (lnk.note and lnk.note ~= "")
                    and ("  {" .. lnk.note .. "}") or ""
                InfoNote(string.format("  %s <-> %s%s",
                    lnk.room1, lnk.room2, note_part))
            end
        end
        InfoNote("SnD: Usage: xset rlink <room1> <room2> [<{note}>]")
        InfoNote("SnD: Room IDs are from the mapper (use 'mapper where' to find them).")
        return
    end

    -- Normalize: always store room1 < room2 to avoid duplicate pairs.
    if r1 > r2 then r1, r2 = r2, r1 end

    local db       = db_open()
    local existing = nil
    for row in db:nrows(
        "SELECT note FROM room_links WHERE room1=" .. r1 .. " AND room2=" .. r2
    ) do
        existing = row.note
    end

    if existing ~= nil and note == "" then
        -- Toggle off: remove the existing link.
        db:exec("DELETE FROM room_links WHERE room1=" .. r1 .. " AND room2=" .. r2)
        db_close(db)
        InfoNote(string.format("SnD: Room link %d <-> %d removed.", r1, r2))
    else
        -- Add or update.
        db:exec(
            "INSERT OR REPLACE INTO room_links (room1, room2, note) VALUES (" ..
            r1 .. ", " .. r2 .. ", " .. fixsql(note) .. ")"
        )
        db_close(db)
        local msg = string.format("SnD: Room link %d <-> %d saved.", r1, r2)
        if note ~= "" then msg = msg .. "  Note: {" .. note .. "}" end
        InfoNote(msg)
    end
end

-- ─── XSET PATHING ─────────────────────────────────────────────────────────────

-- Alias handler: 'xset pathing [on|off]'
function xset_pathing(name, line, wildcards)
    local opt = Trim(wildcards.option or ""):lower()
    local cur = snd_get_setting("pathing_enabled", "on")
    if opt == "" then
        local exp_cur = snd_get_setting("pathing_express_group", "off")
        InfoNote("SnD: Route optimization: " .. string.upper(cur) ..
                 "  |  Express grouping: " .. string.upper(exp_cur))
        InfoNote("SnD: Use 'xset pathing on|off' or 'xset pathing express off|first|last'.")
        return
    end
    if opt ~= "on" and opt ~= "off" then
        ErrorNote("SnD: Usage: xset pathing <on|off>")
        return
    end
    snd_set_setting("pathing_enabled", opt, true)
    InfoNote("SnD: Route optimization is now " .. string.upper(opt) .. ".")
end

-- Alias handler: 'xset pathing express [off|first|last]'
function xset_pathing_express(name, line, wildcards)
    local opt = Trim(wildcards.option or ""):lower()
    local cur = snd_get_setting("pathing_express_group", "off")
    if opt == "" then
        InfoNote("SnD: Express mob grouping is currently " .. string.upper(cur) .. ".")
        InfoNote("SnD: Use 'xset pathing express off|first|last' to change.")
        return
    end
    if opt ~= "off" and opt ~= "first" and opt ~= "last" then
        ErrorNote("SnD: Usage: xset pathing express <off|first|last>")
        return
    end
    snd_set_setting("pathing_express_group", opt, true)
    local desc = {
        off   = "Express mobs are interleaved with others by hop count.",
        first = "Express mob areas are routed before non-express areas.",
        last  = "Express mob areas are routed after non-express areas.",
    }
    InfoNote("SnD: Express mob grouping set to " .. string.upper(opt) .. ". " .. desc[opt])
end
