-- navigation.lua
-- Movement, room search, xrun/goto logic, execute-in-area/room, Vidblain nav.
-- Depends on: constants.lua, util.lua, db.lua, areas.lua, targets.lua,
--             express.lua, settings.lua, hunting.lua

-- ─── STATE ────────────────────────────────────────────────────────────────────

-- Ordered list of area keys and room IDs populated by search_rooms_results().
-- Indexed by go-command numbers.
gotoList  = {}
gotoArea  = -1
gotoIndex = 1
next_room = -1

-- Snapshot of gotoList/gotoIndex/next_room saved when a non-target room search
-- overwrites navigation state mid-CP.  Cleared on restore or activity reset.
-- Fields: activity, target_id, mob_key, gotoList, gotoIndex, next_room, gotoArea
_saved_nav = nil

-- Room ID we are navigating toward (nil when idle).
going_to_room = nil

-- Room-link navigation state (set when routing through a linked room pair).
_go_link_near_roomid = nil   -- mapper-accessible link entrance room
_go_link_far_roomid  = nil   -- actual target room (behind the link)
_go_link_far_arid    = nil   -- area key of the target room

-- State tables for timer-driven execute-in-area/room/vidblain loops.
--   i = ticks spent traveling (still not at the destination)
--   j = consecutive ticks the character has been settled and ready
--   k = ticks spent AT the destination without ever settling
execute_in_area_tbl  = {i=0, j=0, k=0, arid="",  f=function() end, stat=1}
execute_in_room_tbl  = {i=0, j=0, k=0, rmid="",  f=function() end, stat=1}
vidblain_nav_tbl     = {i=0, j=0, k=0, rmid="",  arid="",          stat=1}

-- Tick budget for reaching the destination (0.1s timer, so ~20 seconds).
local TRAVEL_TICK_LIMIT = 200

-- Tick budget for the character to settle into "ready" AFTER arriving.
--
-- Without this the loops could poll forever: the travel counter only advances
-- while still en route, so a character that arrived but never reported state
-- "3" left the queued action pending indefinitely with no message. Combat is
-- the normal reason for the delay, and while fighting the timer is switched
-- off and back on 1.5s later, so these ticks are ~1.5s apart rather than 0.1s
-- -- generous enough that a long legitimate fight is never cut short.
local SETTLE_TICK_LIMIT = 600

-- Character state constants (from GMCP char.status.state).
local CHARACTER_STATES = {
    [1]  = "logging in",
    [2]  = "logging in",
    [3]  = "ready",
    [4]  = "AFK",
    [5]  = "writing a note",
    [6]  = "building",
    [7]  = "reading a page",
    [8]  = "fighting",
    [9]  = "sleeping",
    [10] = "in an unknown state",
    [11] = "resting",
    [12] = "running",
}

-- ─── CHARACTER STATE ─────────────────────────────────────────────────────────

function is_character_ready()
    return current_character_state == "3"
end

function character_state_string()
    local n = tonumber(current_character_state)
    return (n and CHARACTER_STATES[n]) or "in an unknown state"
end

-- ─── POST-ARRIVAL ACTION ─────────────────────────────────────────────────────

-- What 'xcp mode' asked for, queued by xcp_goto_target and run once on
-- arrival.  Only xcp ever sets it, so plain 'nx' and 'go' are unaffected.
local _xcp_arrival_fn = nil

-- Queue (fn) or clear (nil) the arrival action for the navigation now starting.
function set_xcp_arrival_action(fn)
    _xcp_arrival_fn = (type(fn) == "function") and fn or nil
end

-- The 'xset nx' action: what to do on arriving anywhere at all.
local function nx_arrival_action()
    local action = snd_get_setting("nx_action", "qs")
    if action == "smartscan" then
        if type(smart_scan) == "function" then smart_scan() end
    elseif action == "con" then
        EnableTrigger("consider_end_empty", true)
        -- Not the smart-noscan variety: this one is asked for by the arrival
        -- action and should report everything it sees.
        if type(consider_begin) == "function" then consider_begin(false) end
        SendNoEcho("consider")
    elseif action == "scan" or action == "scanhere" then
        if has_activity_target()
        and mob_has_tag(current_target.name, current_target.area, "noscan") then
            InfoNote("SnD: Skipping scan — mob is tagged noscan.")
            return
        end
        SendNoEcho(action == "scan" and "scan" or "scan here")
    elseif action == "qs" then
        if type(quick_scan) == "function" then quick_scan() end
    end
end

function action_on_destination_arrived()
    nx_arrival_action()

    -- Then whatever 'xcp mode' asks for.  Taken rather than read, so one
    -- navigation fires it once however the arrival is detected.
    local fn = _xcp_arrival_fn
    _xcp_arrival_fn = nil
    if fn then fn() end
end

function set_going_to_room(room_id)
    -- Guard nil: tostring(nil) is the string "nil", which can never equal a
    -- real room number, so the arrival action would silently never fire.
    -- Callers such as xcp_goto_target pass get_start_room(...) straight in,
    -- and that returns nil for an area with no start room configured.
    if room_id == nil or room_id == "" then
        going_to_room = nil
        return
    end
    going_to_room = tostring(room_id)
    if gmcp("room.info.num") == going_to_room then
        action_on_destination_arrived()
        going_to_room = nil
    end
end

-- ─── XRUN / GOTO ROOM ────────────────────────────────────────────────────────

-- Alias handler: 'xrt' with no argument — navigate to current quest target.
function xrt_noarg(name, line, wildcards)
    if not current_target or current_target.activity ~= "quest" then
        InfoNote("\nSnD: 'xrt' — no quest target set. Use 'xrt <area>' to navigate to an area.\n")
        return
    end
    if not is_character_ready() then
        InfoNote(string.format("\nYou can't go there while you're %s!\n", character_state_string()))
        return
    end

    gotoArea  = -1
    gotoIndex = 1
    next_room = -1
    gotoList  = {}

    local arid   = current_target.area
    local roomid = current_target.roomid
    local rname  = current_target.room_name

    if roomid then
        -- Navigate to the quest's specific room first.
        set_going_to_room(roomid)
        goto_room_id(tostring(roomid), arid)
        DebugNote("SnD: xrt quest → room " .. tostring(roomid))
        -- Populate the room list for nx cycling.  search_rooms_results resets
        -- next_room to -1, so we restore it afterward.
        if rname and rname ~= "" then
            search_rooms_exact(rname, arid, current_target.name)
            next_room = tostring(roomid)
        else
            gotoList  = { [0] = arid, [1] = tostring(roomid) }
            next_room = tostring(roomid)
        end
    elseif arid and arid ~= "" then
        -- Area known but no specific room found in mapper: go to area start.
        InfoNote("SnD: Quest room not in mapper — routing to area " .. arid .. ".")
        xrun_to(arid, true)
    else
        InfoNote("SnD: Quest target has no area information.")
    end
end

-- Alias handler: 'xrt <destination>'
function xrun_to_alias(name, line, wildcards)
    xrun_to(wildcards.destination, false)
end

-- Navigate to the start room of area arid.
-- exact=true forces exact key match; false allows partial/name match.
-- Checks user-defined marks (marks table) before falling through to areas.
function xrun_to(arid, exact)
    if arid == "ft2" then arid = "ftii" end
    local s = nil
    if arid == "start" then
        arid = gmcp("room.info.zone") or ""
        s    = "walk"
    end

    -- User-defined marks take priority over area keys.
    local mark_room = get_mark_room(arid)
    if mark_room then
        InfoNote("SnD: xrt " .. arid .. " (mark) → room " .. mark_room)
        goto_room_id(tostring(mark_room), nil, s)
        return
    end

    local rmid = get_start_room(arid, exact)
    if not rmid or tostring(rmid) == "-1" then
        InfoNote("SnD: No start room defined for area '" .. arid .. "'.")
        SendNoEcho("areas 1 299 keywords " .. arid)
    else
        InfoNote("SnD: xrt " .. arid .. ", room " .. rmid)
        goto_room_id(tostring(rmid), arid, s)
    end
end

-- Navigate to a specific room ID.
-- rmid: room ID (string or number)
-- arid: area key (optional; used for Vidblain check)
-- speed: "walk" | nil (nil = current mapper speed)
function goto_room_id(rmid, arid, speed)
    -- Do NOT fall back to the global 'speed' variable here.  The mapper plugin
    -- only accepts "mapper goto <roomid>" (no speed suffix); adding " run" breaks
    -- its alias pattern.  Callers that need an explicit speed (e.g. xrt start →
    -- walk) pass it directly.
    arid = arid or ""

    if is_vidblain_area(arid) then
        local cur_arid = gmcp("room.info.zone") or ""
        if not is_vidblain_area(cur_arid) then
            vidblain_nav(rmid, arid)
            return
        end
    end

    do_mapper_goto(rmid, speed)
end

-- Send the mapper goto command.
function do_mapper_goto(rmid, speed)
    if speed and speed ~= "" then
        Execute("mapper goto " .. rmid .. " " .. speed)
    else
        Execute("mapper goto " .. rmid)
    end
end

-- ─── ROOM-LINK NAVIGATION ────────────────────────────────────────────────────

-- Look up any room link for a given target room ID.
-- Returns the near-side (mapper-accessible entrance) room ID, or nil if none.
local function find_room_link_near(target_roomid)
    local tid  = tonumber(target_roomid)
    local near = nil
    if not tid then return nil end
    pcall(function()
        local db = db_open()
        for row in db:nrows(
            "SELECT room1, room2 FROM room_links WHERE room1=" .. tid ..
            " OR room2=" .. tid .. " LIMIT 1"
        ) do
            near = (row.room1 == tid) and row.room2 or row.room1
        end
        db_close(db)
    end)
    return near
end

-- Called by execute_in_room when the player arrives at the near (entrance) side
-- of a room link.  Sends mapper goto for the far room, then sets up a second
-- execute_in_room to clear link state once the player reaches the far room.
-- action_on_destination_arrived() fires automatically from the XML layer via
-- going_to_room when the far room is entered.
function go_link_arrived_at_near_side()
    local far  = _go_link_far_roomid
    local arid = _go_link_far_arid
    if not far then return end
    InfoNote(string.format(
        "SnD: Arrived at link entrance — attempting to continue to room %d.", far
    ))
    -- Attempt mapper path to the far room.  Inside a maze this will fail, in
    -- which case the player navigates manually and execute_in_room still fires.
    goto_room_id(tostring(far), arid)
    -- Clear link state when the far room is reached.
    execute_in_room(far, function()
        _go_link_near_roomid = nil
        _go_link_far_roomid  = nil
        _go_link_far_arid    = nil
    end)
end

-- Navigate to the current CP, GQ, or quest target.
-- Room-link-aware: if the target room has a configured link, navigates to the
-- near (entrance) side first and auto-continues on arrival.
-- Called by 'go' with no argument.
function go_to_current_target()
    if not current_target then
        InfoNote("\nSnD: 'go' — no target set.\n")
        return
    end
    if not is_character_ready() then
        InfoNote(string.format(
            "\nYou can't go there while you're %s!\n", character_state_string()
        ))
        return
    end

    local act = current_target.activity

    -- ── Quest ──────────────────────────────────────────────────────────────
    if act == "quest" then
        local roomid = current_target.roomid
        local arid   = current_target.area
        -- Check whether the goto list is already built for this exact room.
        -- If it is, skip the reset and re-search — just navigate.
        local list_ready = roomid
                        and tostring(roomid) == tostring(next_room)
                        and next_room ~= -1
                        and next_room ~= "-1"
        if not list_ready then
            gotoArea  = -1
            gotoIndex = 1
            next_room = -1
            gotoList  = {}
        end
        if roomid then
            local near = find_room_link_near(roomid)
            if near then
                -- Room link: navigate to the entrance first.
                _go_link_near_roomid = near
                _go_link_far_roomid  = roomid
                _go_link_far_arid    = arid
                set_going_to_room(roomid)   -- triggers action_on_destination_arrived at far room
                InfoNote(string.format(
                    "SnD: Quest room %d is behind a link — navigating to entrance %d first.",
                    roomid, near
                ))
                goto_room_id(tostring(near), arid)
                execute_in_room(near, go_link_arrived_at_near_side)
            else
                -- Navigate directly; build nx list only if not already done.
                set_going_to_room(roomid)
                goto_room_id(tostring(roomid), arid)
                if not list_ready then
                    local rname = current_target.room_name
                    if rname and rname ~= "" then
                        search_rooms_exact(rname, arid, current_target.name)
                        next_room = tostring(roomid)  -- search_rooms_exact resets this; restore
                    else
                        gotoList  = { [0] = arid, [1] = tostring(roomid) }
                        next_room = tostring(roomid)
                    end
                end
            end
        elseif arid and arid ~= "" then
            InfoNote("SnD: Quest room not in mapper — routing to area " .. arid .. ".")
            xrun_to(arid, true)
        else
            InfoNote("SnD: Quest target has no location information.")
        end

    -- ── CP / GQ ────────────────────────────────────────────────────────────
    elseif act == "cp" or act == "gq" then
        -- Check whether the current target's specific room has a room link.
        local idx    = current_target.index
        local t      = idx and main_target_list[idx]
        local roomid = t and t.roomid
        if roomid and tonumber(roomid) and tonumber(roomid) ~= 0 then
            local near = find_room_link_near(roomid)
            if near then
                set_target_from_main_target_list(idx)
                gotoArea  = -1
                gotoIndex = 1
                next_room = -1
                gotoList  = {}
                _go_link_near_roomid = near
                _go_link_far_roomid  = roomid
                _go_link_far_arid    = t.arid
                set_going_to_room(roomid)
                InfoNote(string.format(
                    "SnD: Target room %d is behind a link — navigating to entrance %d first.",
                    roomid, near
                ))
                goto_room_id(tostring(near), t.arid)
                execute_in_room(near, go_link_arrived_at_near_side)
                if type(xg_draw_window) == "function" then xg_draw_window() end
                return
            end
        end
        -- No room link (or area-type target): use standard xcp navigation.
        xcp_noarg()

    else
        InfoNote("\nSnD: 'go' — not on a CP, GQ, or quest.\n")
    end
end

-- ─── GO / NX / NX- ───────────────────────────────────────────────────────────

-- Alias handler: 'go [<index>]'
-- With no index: navigate to gotoList[1] if the list is populated; otherwise
--   navigate to the current CP/GQ/quest target (room-link-aware).
-- With an index:  navigate to gotoList[index].
function goto_number(name, line, wildcards)
    if not is_character_ready() then
        InfoNote(string.format("\nYou can't use 'go' while you're %s!", character_state_string()))
        return
    end
    local idx = tonumber(wildcards.index)
    if idx == nil then
        if gotoList and gotoList[1] then
            idx = 1
        else
            go_to_current_target()
            return
        end
    end
    gotoIndex = idx
    local dest = gotoList[gotoIndex]
    if dest then
        if not tonumber(dest) then
            set_going_to_room(get_start_room(dest, true))
            xrun_to(dest, true)
        else
            next_room = dest
            set_going_to_room(next_room)
            goto_room_id(next_room)
        end
    elseif next(gotoList) == nil then
        -- gotoList was cleared (e.g., area-type target navigation or stale hyperlink);
        -- fall back to routing to the current target rather than aborting.
        go_to_current_target()
    else
        InfoNote("SnD: 'go' aborted — no destination at index " .. gotoIndex)
    end
end

-- Toggle autonav on/off.
-- Alias handler: 'xset autonav [on|off]'
-- When on, search_rooms_results() auto-navigates (as if 'go 1' were typed)
-- whenever an xcp/qw search resolves to exactly one mapper room. Default off.
function xset_autonav(name, line, wildcards)
    local opt = Trim(wildcards.state or "")

    if opt == "on" or opt == "off" then
        snd_set_setting("autonav_onoff", opt, true)
        InfoNote("SnD: Autonav is now " .. string.upper(opt) .. ".")
    elseif opt == "" then
        local cur = snd_get_setting("autonav_onoff", "off")
        InfoNote("SnD: Autonav: " .. string.upper(cur) ..
                 " -- auto-navigates when xcp/qw resolves to exactly one room.")
        InfoNote("SnD: Usage: xset autonav [on|off]")
    else
        UsageNote("SnD: xset autonav: invalid option '" .. opt .. "'. Use on or off.")
    end
end

-- Alias handler: 'nx'
function goto_next(name, line, wildcards)
    if not is_character_ready() then
        InfoNote(string.format("\nYou can't use 'nx' while you're %s!", character_state_string()))
        return
    end
    if not next_room or next_room == "" or not tonumber(next_room) then
        InfoNote("SnD: 'nx' aborted — no destination yet.")
        return
    end
    if tonumber(next_room) == tonumber(gmcp("room.info.num"))
    and gotoIndex < #gotoList then
        gotoIndex = gotoIndex + 1
    end
    gotoIndex = math.max(1, gotoIndex)
    local dest = gotoList[gotoIndex]
    if dest then
        InfoNote("SnD: nx — " .. gotoIndex .. " of " .. #gotoList)
        next_room = dest
        set_going_to_room(next_room)
        do_mapper_goto(next_room)
    else
        InfoNote("SnD: 'nx' aborted — no more rooms.")
    end
end

-- Alias handler: 'nx-'
function goto_previous(name, line, wildcards)
    if not is_character_ready() then
        InfoNote(string.format("\nYou can't use 'nx-' while you're %s!", character_state_string()))
        return
    end
    if not next_room or not tonumber(next_room) then
        InfoNote("SnD: 'nx-' aborted — no destination yet.")
        return
    end
    if tonumber(next_room) == tonumber(gmcp("room.info.num")) and gotoIndex > 1 then
        gotoIndex = gotoIndex - 1
    end
    local dest = gotoList[gotoIndex]
    if dest then
        InfoNote("SnD: nx- — " .. gotoIndex .. " of " .. #gotoList)
        next_room = dest
        set_going_to_room(next_room)
        do_mapper_goto(next_room)
    else
        InfoNote("SnD: 'nx-' aborted — no more rooms.")
    end
end

-- ─── XCP NAVIGATION ──────────────────────────────────────────────────────────

xcp_retry_stat    = 0
xcp_index_attempt = 0

-- What 'xcp mode' asks for once we get where we are going: hunt the mob down
-- (ht), ask the game where it is (qw), or nothing (off).  Returns a function
-- to run on arrival, or nil.
--
-- 'ht' is campaign-only.  Hunt does not answer for gquest mobs, so a gquest
-- falls back to 'where' -- which is what the area route has always done.
-- Said once per gquest rather than once per target: the substitution is the
-- same every time, and repeating it on every xcp would be noise.
local _ht_on_gq_explained = false
function reset_ht_on_gq_notice() _ht_on_gq_explained = false end

local function xcp_arrival_action(t)
    local action = snd_get_setting("xcp_action_mode", "qw")
    if action == "ht" and current_activity == "cp" then
        return function() do_hunt_trick(1, t.kw) end
    elseif action == "qw" or (action == "ht" and current_activity ~= "cp") then
        -- 'ht' quietly became 'qw' on anything that is not a campaign, and had
        -- since 2021. The substitution is right -- hunt only answers for
        -- campaign targets -- but saying nothing makes a correctly-set mode
        -- look broken, which is exactly the report that led here.
        if action == "ht" and not _ht_on_gq_explained then
            _ht_on_gq_explained = true
            InfoNote("SnD: 'xcp mode ht' uses 'where' on a gquest -- hunt " ..
                     "only answers for campaign targets. The mode itself is " ..
                     "unchanged.")
        end
        return function() qw_exact() end
    end
    return nil
end

-- Navigate to target at index in main_target_list.
function xcp_goto_target(index)
    local t = main_target_list[index]
    if not t then
        InfoNote("SnD: xcp: no target at index " .. tostring(index))
        return
    end

    if xcp_retry_stat ~= 0 then
        set_target_from_main_target_list(index)
        xcp_index_attempt = index
        xcp_retry_stat    = 2
        return
    end

    -- Restore saved nav state if the player is returning to the same target
    -- after a detour (e.g. fetching a key mob via ms/xwhere).
    if _saved_nav and _saved_nav.target_id == index then
        local sn = _saved_nav
        local saved_t = main_target_list[index]
        -- Verify the target is still the same mob and still alive.
        if saved_t
        and saved_t.is_dead == "no"
        and (saved_t.mob or "") == sn.mob_key then
            _saved_nav = nil
            set_target_from_main_target_list(index)
            if not is_character_ready() then
                InfoNote(string.format(
                    "\nYou can't go there while you're %s!\n",
                    character_state_string()
                ))
                return
            end
            gotoList  = sn.gotoList
            gotoIndex = sn.gotoIndex
            next_room = sn.next_room
            gotoArea  = sn.gotoArea
            local dest = gotoList[gotoIndex]
            if dest and tonumber(dest) then
                ColourNote("#00FF00", "", string.format(
                    "SnD: Resumed [%s] — room %d of %d.",
                    sn.mob_key, gotoIndex, #gotoList
                ))
                set_xcp_arrival_action(xcp_arrival_action(t))
                set_going_to_room(tonumber(dest))
                goto_room_id(tostring(dest), t.arid)
            elseif dest then
                ColourNote("#00FF00", "", string.format(
                    "SnD: Resumed [%s] — routing to area %s.",
                    sn.mob_key, tostring(dest)
                ))
                local fn = xcp_arrival_action(t)
                if fn then execute_in_area(tostring(dest), fn) end
                xrun_to(dest, true)
            end
            if type(xg_draw_window) == "function" then xg_draw_window() end
            return
        else
            -- Stale save (mob dead or CP changed) — discard it.
            _saved_nav = nil
        end
    elseif _saved_nav and _saved_nav.target_id ~= index then
        -- Player explicitly navigated to a different target — discard the save.
        _saved_nav = nil
    end

    gotoArea  = -1
    gotoIndex = 1
    next_room = -1
    gotoList  = {}

    set_target_from_main_target_list(index)

    if not is_character_ready() then
        InfoNote(string.format("\nYou can't go there while you're %s!\n", character_state_string()))
        return
    end

    local express = is_express_target(t)
    local arrival = xcp_arrival_action(t)

    -- Nothing is queued yet for this navigation, and a previous one may have
    -- been abandoned part-way.
    set_xcp_arrival_action(nil)

    -- Which route this target takes decides almost everything that follows,
    -- and none of it was recoverable from a report afterwards.  One line, so
    -- that "it went somewhere else" can be read rather than reconstructed.
    DebugNote(string.format(
        "SnD: xcp #%s '%s': link=%s arid=%s roomid=%s room='%s'%s%s, mode=%s",
        tostring(index), tostring(t.mob), tostring(t.link_type),
        tostring(t.arid), tostring(t.roomid), tostring(t.roomName or ""),
        express and ", express" or "",
        t.pinned_room and ", pinned" or "",
        snd_get_setting("xcp_action_mode", "qw")))

    if express then
        -- Express: go directly to the highest-kill room.
        -- Exception: if the target's area is a maze area, the specific roomid
        -- is inside the maze and unreachable by normal navigation.  Fall back to
        -- routing to the area start room so the player arrives at the maze
        -- entrance and can navigate manually.
        -- Also fall back when no specific roomid is recorded.
        local use_area_fallback = false
        if not t.roomid or tonumber(t.roomid) == nil or tonumber(t.roomid) == 0 then
            use_area_fallback = true
        else
            -- Check if the target's area contains maze rooms.
            if type(mazeStartRooms) == "table" and t.arid then
                for _, v in pairs(mazeStartRooms) do
                    if type(v) == "table" and v.areaname == t.arid then
                        use_area_fallback = true
                        break
                    end
                end
            end
        end

        if use_area_fallback then
            InfoNote("SnD: Express target is in a maze area — routing to area entrance instead of specific room.")
            gotoList[0] = t.arid
            if arrival then execute_in_area(t.arid, arrival) end
            xrun_to(t.arid, true)
            DebugNote("SnD: xcp express target → area " .. tostring(t.arid))
        else
            -- Navigate immediately to the express (highest-kill) room.
            -- The express room is a guess from history: the mob was killed
            -- there before, not necessarily today.  So queue the 'xcp mode'
            -- action for arrival -- without it, landing in the wrong room
            -- ends the attempt with nothing looking for the mob.
            set_xcp_arrival_action(arrival)
            set_going_to_room(t.roomid)
            goto_room_id(tostring(t.roomid), t.arid)
            -- Said out loud, not just to the debug log. An express target
            -- walks straight to one room instead of the area entrance, which
            -- looks like ordinary routing gone wrong unless you are told --
            -- and it is the first thing to know when reporting one.
            InfoNote("SnD: Express target — going straight to room ",
                     tostring(t.roomid), ", where you have killed it before. ",
                     "'nx' cycles the other rooms of that name.")

            -- Also find and display all similarly-named rooms so the player
            -- can use nx to cycle through them if the mob isn't in the express
            -- room on this run.  The express room is the most likely spot; the
            -- list gives fallbacks.
            --
            -- For room-type targets, t.roomName is set directly.
            -- For area-type express targets, look up the name from the mapper DB.
            local express_room_name = (t.roomName and t.roomName ~= "")
                and t.roomName or nil
            if not express_room_name and mapper_db_file then
                pcall(function()
                    local mapdb = sqlite3.open(mapper_db_file)
                    for row in mapdb:nrows(
                        "SELECT name FROM rooms WHERE uid=" ..
                        tostring(t.roomid) .. " LIMIT 1"
                    ) do
                        express_room_name = row.name
                    end
                    mapdb:close()
                end)
            end

            if express_room_name and express_room_name ~= "" then
                -- search_rooms_exact populates gotoList with all matching rooms
                -- and prints the list.  Restore next_room afterward because
                -- search_rooms_results resets it to -1.
                search_rooms_exact(express_room_name, t.arid, t.mob, true)
                next_room = tostring(t.roomid)
            else
                -- Fallback if room name is unavailable.
                gotoList    = { [0] = t.arid, [1] = t.roomid }
                next_room   = t.roomid
            end
        end

    elseif t.link_type == "area" then
        -- Area CP: go to area, then hunt/qw on arrival.  There is no room to
        -- arrive at, so this one waits on the zone instead.
        if arrival then execute_in_area(t.arid, arrival) end
        if gmcp("room.info.zone") ~= t.arid then
            xrun_to(t.arid, true)
        end

    else
        -- Room CP: find all matching rooms, display list, and navigate to the
        -- best one.  The room the campaign named is where the mob was, not
        -- where it necessarily is, so the 'xcp mode' action is queued here too.
        search_rooms_exact(t.roomName, t.arid, t.mob, true)

        -- A pinned room ('xset mob priority') is a deliberate answer to which
        -- of the same-named rooms this mob is in, so it outranks the sighting
        -- ranking.  Otherwise gotoList[1] is the best room after
        -- search_rooms_results has sorted by sightings.
        local rid = nil
        if t.pinned_room and tonumber(t.roomid) then
            rid = tostring(t.roomid)
        elseif gotoList[1] then
            rid = tostring(gotoList[1])
        end

        if rid then
            set_xcp_arrival_action(arrival)
            set_going_to_room(tonumber(rid))
            goto_room_id(rid, t.arid)
            next_room = rid
        end
    end
end

-- xcp with no argument: go to first alive, known-location target.
function xcp_noarg()
    if snd_get_setting("xcp_targets_quest_onoff", "off") == "on" and has_active_quest() then
        target_quest_mob(true)
        if type(xg_draw_window) == "function" then xg_draw_window() end
        return
    end

    if current_activity == "none" then
        -- "not on a CP or GQ" is true but unhelpful when the player IS on a
        -- quest: quest targeting is opt-in, and nothing said so. Point at the
        -- switch rather than leaving them to guess why nothing works.
        if type(has_active_quest) == "function" and has_active_quest() then
            InfoNote("\nSnD: 'xcp' only handles quest targets when quest " ..
                     "targeting is on. Use 'xcp q' to enable it, or 'xqt' to " ..
                     "target the quest mob directly.\n")
        else
            InfoNote("\nSnD: 'xcp' aborted — not on a CP or GQ.\n")
        end
        return
    end
    if #main_target_list == 0 then
        InfoNote("\nSnD: 'xcp' aborted — target list is empty.\n")
        return
    end

    for i, mob in ipairs(main_target_list) do
        if mob.is_dead == "no"
        and (mob.link_type == "area" or mob.link_type == "room") then
            xcp_goto_target(i)
            if type(xg_draw_window) == "function" then xg_draw_window() end
            return
        end
    end
    InfoNote("\nSnD: 'xcp' aborted — no reachable targets (all dead or location unknown).\n")
end

-- xcp <index> alias handler.
function xcp_arg(name, line, wildcards)
    local index = tonumber(wildcards.index)
    if current_activity == "none" then
        if type(has_active_quest) == "function" and has_active_quest() then
            InfoNote("\nSnD: 'xcp' only handles quest targets when quest " ..
                     "targeting is on. Use 'xcp q' to enable it, or 'xqt' to " ..
                     "target the quest mob directly.\n")
        else
            InfoNote("\nSnD: 'xcp' aborted — not on a CP or GQ.\n")
        end
    elseif #main_target_list == 0 then
        InfoNote("\nSnD: 'xcp' aborted — target list is empty.\n")
    elseif not index or index < 0 or index > #main_target_list then
        InfoNote("\nSnD: 'xcp' aborted — index " .. tostring(index) .. " out of range.\n")
    elseif index == 0 then
        xcp_clear_target(true)
        InfoNote("\nSnD: Target cleared.\n")
    elseif main_target_list[index].link_type == "unknown" then
        InfoNote("\nSnD: 'xcp' aborted — no mapper data for target #" .. index .. ".\n")
    else
        xcp_goto_target(index)
        if type(xg_draw_window) == "function" then xg_draw_window() end
    end
end

function xcp_clear_target(redraw)
    if type(clear_target) == "function" then clear_target() end
    _saved_nav = nil
    -- There is no target left to hunt for, so a queued arrival action would
    -- fire against a stale one the next time any navigation finishes.
    set_xcp_arrival_action(nil)
    gotoArea  = -1
    gotoIndex = 0
    gotoList  = {}
    if redraw and type(xg_draw_window) == "function" then xg_draw_window() end
end

-- Retry handler called after cp/gq check completes.
function xcp_retry()
    if xcp_retry_stat == 2 then
        xcp_retry_stat = 0
        xcp_goto_target(xcp_index_attempt)
    else
        xcp_retry_stat = 0
    end
end

-- ─── EXECUTE-IN-AREA ─────────────────────────────────────────────────────────

-- Run func() once we arrive in area arid.
-- If already there, runs immediately; otherwise enables the EIA timer.
function execute_in_area(arid, func)
    local fn = type(func) == "function" and func or function() end
    execute_in_area_tbl = {
        i=0, j=0, k=0, arid=arid, f=fn,
        stat=current_character_state
    }
    if gmcp("room.info.zone") == arid then
        fn()
        execute_in_area_tbl = {i=0, j=0, k=0, arid="", f=function() end, stat=1}
    else
        EnableTimer("execute_in_area_timer", true)
    end
end

-- Called every 0.1s by execute_in_area_timer.
function execute_in_area_tick()
    local eiat   = execute_in_area_tbl
    local cur_zone = gmcp("room.info.zone")
    local ch_state = current_character_state

    if not cur_zone or not ch_state then return end

    if cur_zone ~= eiat.arid then
        eiat.i = eiat.i + 1
        if eiat.i > TRAVEL_TICK_LIMIT then
            EnableTimer("execute_in_area_timer", false)
            xcp_clear_target(true)
            InfoNote("SnD: execute-in-area timed out.")
            execute_in_area_tbl = {i=0, j=0, k=0, arid="", f=function() end, stat=1}
        end
    else
        if ch_state == "3" and eiat.stat == "3" then
            eiat.k = 0
            eiat.j = eiat.j + 1
            if eiat.j > 3 then
                EnableTimer("execute_in_area_timer", false)
                eiat.f()
            end
        else
            -- Arrived, but the character never settled. Bounded so the queued
            -- action cannot stay pending forever with no feedback.
            eiat.k = (eiat.k or 0) + 1
            if eiat.k > SETTLE_TICK_LIMIT then
                EnableTimer("execute_in_area_timer", false)
                xcp_clear_target(true)
                InfoNote("SnD: execute-in-area gave up — still " ..
                         character_state_string() .. " after arriving.")
                execute_in_area_tbl = {i=0, j=0, k=0, arid="", f=function() end, stat=1}
                return
            end
            eiat.stat = ch_state
            eiat.j    = 0
            if ch_state == "8" then
                EnableTimer("execute_in_area_timer", false)
                DoAfterSpecial(1.5, [[ EnableTimer("execute_in_area_timer", true) ]], 12)
            end
        end
    end
end

-- ─── EXECUTE-IN-ROOM ─────────────────────────────────────────────────────────

function execute_in_room(rmid, func)
    local fn = type(func) == "function" and func or function() end
    execute_in_room_tbl = {
        i=0, j=0, k=0, rmid=tostring(rmid), f=fn,
        stat=current_character_state
    }
    if gmcp("room.info.num") == tostring(rmid) then
        fn()
        execute_in_room_tbl = {i=0, j=0, k=0, rmid="", f=function() end, stat=1}
    else
        EnableTimer("execute_in_room_timer", true)
    end
end

function execute_in_room_tick()
    local eirt   = execute_in_room_tbl
    local cur_rm = gmcp("room.info.num")
    local ch_state = current_character_state

    if not cur_rm or not ch_state then return end

    if cur_rm ~= eirt.rmid then
        eirt.i = eirt.i + 1
        if eirt.i > TRAVEL_TICK_LIMIT then
            EnableTimer("execute_in_room_timer", false)
            xcp_clear_target(true)
            InfoNote("SnD: execute-in-room timed out.")
            execute_in_room_tbl = {i=0, j=0, k=0, rmid="", f=function() end, stat=1}
        end
    else
        if ch_state == "3" and eirt.stat == "3" then
            eirt.k = 0
            eirt.j = eirt.j + 1
            if eirt.j > 3 then
                EnableTimer("execute_in_room_timer", false)
                eirt.f()
            end
        else
            eirt.k = (eirt.k or 0) + 1
            if eirt.k > SETTLE_TICK_LIMIT then
                EnableTimer("execute_in_room_timer", false)
                xcp_clear_target(true)
                InfoNote("SnD: execute-in-room gave up — still " ..
                         character_state_string() .. " after arriving.")
                execute_in_room_tbl = {i=0, j=0, k=0, rmid="", f=function() end, stat=1}
                return
            end
            eirt.stat = ch_state
            eirt.j    = 0
            if ch_state == "8" then
                EnableTimer("execute_in_room_timer", false)
                DoAfterSpecial(1.5, [[ EnableTimer("execute_in_room_timer", true) ]], 12)
            end
        end
    end
end

-- ─── VIDBLAIN NAVIGATION ─────────────────────────────────────────────────────

function vidblain_nav(rmid, arid)
    vidblain_nav_tbl = {i=0, j=0, k=0, rmid=rmid, arid=arid, stat=current_character_state}
    EnableTimer("execute_in_area_timer",  false)
    EnableTimer("vidblain_nav_timer",     true)
    Execute("mapper goto 11910")
    Execute("enter hole")
end

function vidblain_nav_tick()
    local vnt      = vidblain_nav_tbl
    local cur_zone = gmcp("room.info.zone")
    local ch_state = current_character_state

    if not cur_zone or not ch_state then return end

    if cur_zone ~= "vidblain" then
        vnt.i = vnt.i + 1
        if vnt.i > TRAVEL_TICK_LIMIT then
            EnableTimer("vidblain_nav_timer", false)
            xcp_clear_target(true)
            InfoNote("SnD: Vidblain nav timed out.")
            vidblain_nav_tbl = {i=0, j=0, k=0, rmid="", arid="", stat=1}
        end
    else
        if ch_state == "3" and ch_state == vnt.stat then
            vnt.k = 0
            vnt.j = vnt.j + 1
            if vnt.j > 3 then
                EnableTimer("vidblain_nav_timer", false)
                do_mapper_goto(vnt.rmid, "walk")
                execute_in_area(vnt.arid, execute_in_area_tbl.f)
                vidblain_nav_tbl = {i=0, j=0, k=0, rmid="", arid="", stat=1}
            end
        else
            -- j must be reset here, as the other two loops do: without it the
            -- settled-tick count survived a state change, so a character that
            -- flapped in and out of "ready" could satisfy the 4-consecutive
            -- check without ever having been ready for four ticks running.
            vnt.k = (vnt.k or 0) + 1
            if vnt.k > SETTLE_TICK_LIMIT then
                EnableTimer("vidblain_nav_timer", false)
                xcp_clear_target(true)
                InfoNote("SnD: Vidblain nav gave up — still " ..
                         character_state_string() .. " after arriving.")
                vidblain_nav_tbl = {i=0, j=0, k=0, rmid="", arid="", stat=1}
                return
            end
            vnt.stat = ch_state
            vnt.j    = 0
        end
    end
end

-- ─── ROOM SEARCH ─────────────────────────────────────────────────────────────

-- Exact match: find rooms named room in area arid.
-- If soh/sohtwo, also searches the paired area.
-- no_autonav: the caller is going to navigate itself the moment this
-- returns, and is only running the search to populate the 'nx' list. Without
-- it, a search that resolves to exactly one room walks there under autonav and
-- the caller then walks there again -- two run-tos to the same room.
function search_rooms_exact(room, arid, mob_name, no_autonav)
    local q
    if arid == "soh" or arid == "sohtwo" then
        q = string.format(
            "SELECT uid, name, area FROM rooms " ..
            "WHERE name=%s AND (area=%s OR area=%s) ORDER BY area",
            fixsql(room), fixsql("soh"), fixsql("sohtwo"))
    else
        q = string.format(
            "SELECT uid, name, area FROM rooms " ..
            "WHERE name=%s AND area=%s ORDER BY area",
            fixsql(room), fixsql(arid))
    end
    _search_rooms(q, mob_name, no_autonav)
end

-- Fuzzy match: exact name first, then LIKE.
function search_rooms_fuzzy(room, arid, mob_name)
    arid = arid or "all"
    local like_room = "%" .. room .. "%"
    local q = string.format([[
        SELECT uid, name, area, 1 AS ord FROM rooms
        WHERE name=%s AND (%s='all' OR area=%s)
        UNION
        SELECT uid, name, area, 0 AS ord FROM rooms
        WHERE name<>%s AND name LIKE %s AND (%s='all' OR area=%s)
        ORDER BY area, ord DESC
    ]], fixsql(room), fixsql(arid), fixsql(arid),
        fixsql(room), fixsql(like_room), fixsql(arid), fixsql(arid))
    _search_rooms(q, (mob_name ~= "") and mob_name or nil)
end

-- Internal: execute room search query and display results.
function _search_rooms(query, mob_name, no_autonav)
    if not mapper_db_file then search_rooms_results({}, no_autonav); return end
    local mapdb   = sqlite3.open(mapper_db_file)
    local results = {}
    local rmid_list = {}

    for row in mapdb:nrows(query) do
        local id = tonumber(row.uid) or -1
        results[#results+1] = {rmid=id, name=row.name, arid=row.area}
        if id > 0 then rmid_list[#rmid_list+1] = fixsql(row.uid) end
    end

    -- Attach mapper bookmarks/notes.
    if #rmid_list > 0 then
        for row in mapdb:nrows(
            "SELECT uid, notes FROM bookmarks WHERE uid IN (" ..
            table.concat(rmid_list, ",") .. ")"
        ) do
            for _, r in ipairs(results) do
                if tostring(r.rmid) == row.uid then
                    r.notes = row.notes; break
                end
            end
        end
    end
    mapdb:close()

    -- Attach seen_count from mob_sightings.
    if #results > 0 and mob_name and #rmid_list > 0 then
        local snddb = db_open()
        local total = 0
        local by_room = {}
        for row in snddb:nrows(
            "SELECT roomid, seen_count FROM mob_sightings " ..
            "WHERE mob=" .. fixsql(mob_name) ..
            " AND roomid IN (" .. table.concat(rmid_list, ",") .. ")"
        ) do
            by_room[row.roomid] = row.seen_count
            total = total + row.seen_count
        end
        snddb:close()

        for _, r in ipairs(results) do
            r.seen_count = by_room[r.rmid] or 0
            r.percentage = total > 0 and (r.seen_count / total) or 0
        end

        table.sort(results, function(a, b)
            if a.seen_count ~= b.seen_count then
                return a.seen_count > b.seen_count
            end
            return a.rmid < b.rmid
        end)

        -- Promote maze start rooms to top.
        if type(mazeStartRooms) == "table" then
            for k = #results, 1, -1 do
                if mazeStartRooms[results[k].rmid] then
                    local entry = table.remove(results, k)
                    entry.mz = "yes"
                    table.insert(results, 1, entry)
                end
            end
        end
    end

    search_rooms_results(results, no_autonav)
end

-- Display a list of 'go N' hyperlinks from search_rooms results.
function search_rooms_results(results, no_autonav)
    -- If we are mid-navigation for a CP/GQ target and something is overwriting
    -- the room list (e.g. the player searched for a key mob), snapshot the
    -- current nav state so xcp can restore it afterward.
    local nr = tostring(next_room or "")
    if current_target
    and (current_target.activity == "cp" or current_target.activity == "gq")
    and current_target.index
    and nr ~= "" and nr ~= "-1"
    and #gotoList > 0 then
        local snap = {
            activity  = current_target.activity,
            target_id = current_target.index,
            mob_key   = current_target.name or "",
            gotoIndex = gotoIndex,
            next_room = next_room,
            gotoArea  = gotoArea,
            gotoList  = {},
        }
        for k, v in pairs(gotoList) do snap.gotoList[k] = v end
        _saved_nav = snap
        ColourNote("#FF8C00", "", string.format(
            "SnD: Nav saved for [%s] — type 'xcp' to resume after your detour.",
            snap.mob_key
        ))
    end

    gotoArea  = -1
    gotoIndex = 1
    next_room = -1
    gotoList  = {}

    local table_width    = tonumber(snd_get_setting("table_width", "80")) or 80
    local show_notes     = snd_get_setting("table_notes", "off") == "on"
    local alt_bg         = snd_get_setting("color_alternating_row", "#0C0C1A")
    local note_width     = table_width - 62
    local has_pct        = #results > 0 and results[1].percentage ~= nil
    local last_area      = ""
    local line_num       = 0
    local idx            = 0   -- go-index counter
    local room_go_idx    = nil -- go-index of the single room result, if there is exactly one

    ColourTell("#808080", "", string.format("\nXCP  %-38s  %-7s  %-6s", "Location", "(uid)", ""))
    if has_pct then
        note_width = note_width - 11
        ColourTell("#808080", "", string.format("  %-9s", "(chance)"))
    end
    ColourTell("#808080", "", "  Notes")
    print("")
    ColourNote("#808080", "", string.rep("-", table_width))

    for _, v in ipairs(results) do
        line_num = line_num + 1
        local bg = (line_num % 2 == 0) and alt_bg or ""

        local arid_str = v.arid or "?"
        if last_area ~= arid_str then
            local pad = math.max(0, table_width - 5 - #arid_str)
            if idx == 0 then
                local line = string.format("%3d  %s%s", idx, arid_str,
                    string.rep(" ", pad))
                Hyperlink("go " .. idx, line, "go to area " .. arid_str, "silver", bg, 0, 1)
                gotoList[idx] = arid_str
                gotoArea      = arid_str
                idx           = idx + 1
            else
                local line = string.format("     %s%s", arid_str,
                    string.rep(" ", pad))
                Hyperlink("xrt " .. arid_str, line, "go to area " .. arid_str, "silver", bg, 0, 1)
            end
            print("")
            line_num = line_num + 1
            last_area = arid_str
        end

        bg = (line_num % 2 == 0) and alt_bg or ""
        local clean_name = ellipsify(strip_colours(v.name), 38)
        local sw_tip = "speedwalk to room " .. v.rmid
        local sw_cmd = "mapper where " .. v.rmid

        if v.mz == "yes" then
            clean_name = ellipsify(strip_colours(v.name), 34)
            local txt = string.format("%3d  %-34s  %-7s ", idx, clean_name,
                string.format("(%s)", v.rmid))
            Hyperlink("go " .. idx, txt:sub(1,4), "go "..idx, "lightblue", bg, 0, 1)
            ColourTell("ghostwhite", bg, "[")
            ColourTell("magenta",    bg, "MZ")
            ColourTell("ghostwhite", bg, "]")
            Hyperlink("go " .. idx, txt:sub(5), "go "..idx, "lightblue", bg, 0, 1)
        else
            local txt = string.format("%3d  %-38s  %-7s ", idx, clean_name,
                string.format("(%s)", v.rmid))
            Hyperlink("go " .. idx, txt, "go "..idx, "lightblue", bg, 0, 1)
        end

        Hyperlink(sw_cmd, "   {sw}", sw_tip, "#FF5000", bg, 0, 1)
        gotoList[idx] = v.rmid
        room_go_idx = idx
        idx = idx + 1

        if has_pct and v.percentage then
            local pct_str = string.format("%6.2f%%", v.percentage * 100)
            Hyperlink(sw_cmd, "  (", sw_tip, "silver", bg, 0, 1)
            Hyperlink(sw_cmd, pct_str, sw_tip, mob_room_percentage_color(v.percentage), bg, 0, 1)
            Hyperlink(sw_cmd, ")", sw_tip, "silver", bg, 0, 1)
        end

        if v.notes then
            local note_txt = show_notes
                and ellipsify(strip_colours(v.notes), note_width)
                or "[notes]"
            note_txt = string.format("  %-" .. note_width .. "s", note_txt)
            Hyperlink(string.format("roomnote %i", v.rmid), note_txt,
                v.notes, "lightgreen", bg, 0, 1)
        end

        print("")
    end

    if #results == 0 then
        InfoNote("SnD: No rooms found.")
    end

    -- Autonav (xset autonav on): when the search resolved to exactly one
    -- mapper room, navigate to it immediately instead of waiting for the
    -- user to click/type 'go N'. Quest retargeting is excluded on purpose --
    -- it can fire on GMCP events (reconnect/login), so auto-walking there
    -- would move the player unexpectedly.
    if #results == 1 and room_go_idx and not no_autonav
    and current_target and current_target.activity ~= "quest"
    and snd_get_setting("autonav_onoff", "off") == "on" then
        goto_number(nil, nil, {index = tostring(room_go_idx)})
    end
end

-- ─── XSET NX ACTION ──────────────────────────────────────────────────────────

local NX_OPTIONS = {
    smartscan = "smartscan — smart scan on arrival",
    scan      = "scan — scan on arrival",
    scanhere  = "scanhere — scan here on arrival",
    con       = "con — consider on arrival",
    qs        = "qs — quick scan on arrival",
    none      = "none — take no action on arrival",
}

local NX_ORDER = { "smartscan", "scan", "scanhere", "con", "qs", "none" }

-- What each option actually does, for the bare 'xset nx'.
local NX_DESC = {
    smartscan = "You will scan every room on arrival after nx or go, filtered " ..
                "down to campaign, gquest and quest targets. If a potential " ..
                "noscan mob turns up, a filtered consider follows to check " ..
                "whether it is here.",
    scan      = "You will scan the surrounding rooms on arrival after nx or go.",
    scanhere  = "You will scan the current room on arrival after nx or go.",
    con       = "You will consider every room on arrival after nx or go.",
    qs        = "You will quick-scan on arrival after nx or go.",
    none      = "You will take no action on arrival after nx or go.",
}

-- Alias handler: 'xset nx [<action>]'.
--
-- This used to be two commands that disagreed with each other. The bare form
-- lived in the plugin file and printed a global that nothing ever assigned, so
-- it always showed blank; this one reads the wildcard by the wrong name --
-- the alias captures `action`, not `option` -- so setting an action fell
-- through to the "show current" branch and silently did nothing. Between them
-- the arrival action could not be inspected or changed, and stayed on its
-- default forever.
function xset_nx(name, line, wildcards)
    local w   = (type(wildcards) == "table" and wildcards) or {}
    local opt = Trim(tostring(w.action or w[1] or "")):lower()

    if NX_OPTIONS[opt] then
        snd_set_setting("nx_action", opt, false)
        InfoNote("SnD: nx action set to: " .. NX_OPTIONS[opt])
        if NX_DESC[opt] then InfoNote("SnD: " .. NX_DESC[opt]) end
    elseif opt == "" then
        local cur = snd_get_setting("nx_action", "qs")
        InfoNote("SnD: Current nx action: " .. (NX_OPTIONS[cur] or cur))
        if NX_DESC[cur] then InfoNote("SnD: " .. NX_DESC[cur]) end
        InfoNote("SnD: Options: " .. table.concat(NX_ORDER, ", "))
    else
        UsageNote("SnD: Unknown nx action '" .. opt .. "'.")
        InfoNote("SnD: Options: " .. table.concat(NX_ORDER, ", "))
    end
end

-- Alias handler: 'xset autoreload [on|off]'.
--
-- Whether a module update reloads the plugin by itself. On by default: the
-- plugin file update already reloads unasked, and updates that sit unapplied
-- are worse than a reload -- the modules on disk no longer match the ones
-- running. It waits for a quiet moment either way; see _snd_reload_or_prompt.
function xset_autoreload(name, line, wildcards)
    local w   = (type(wildcards) == "table" and wildcards) or {}
    local opt = Trim(tostring(w.state or w[1] or "")):lower()

    if opt == "on" or opt == "off" then
        snd_set_setting("auto_reload", opt, true)
        InfoNote("SnD: auto-reload after updates is now ", opt:upper(), ".")
        if opt == "on" then
            InfoNote("SnD: it waits until you are not mid-campaign or mid-route.")
        end
    elseif opt == "" then
        local cur = snd_get_setting("auto_reload", "on")
        InfoNote("SnD: auto-reload after updates: ", cur:upper(), ".")
        InfoNote("SnD: when on, a module update reloads once nothing is in ",
                 "progress; otherwise it tells you to type 'snd reload'.")
        InfoNote("SnD: Usage: xset autoreload [on|off]")
    else
        UsageNote("SnD: xset autoreload: use 'on' or 'off'.")
    end
end

-- ─── XSET LEVEL BUFFER ────────────────────────────────────────────────────────

-- Alias handler: 'xset level buffer [<n>]'
-- The level buffer is added to a room CP area's maxlvl when deciding whether
-- a matching room is in-range for the current campaign or GQ.  Default = 25.
function xset_level_buffer(name, line, wildcards)
    local n = tonumber(wildcards.value)
    if not n then
        local cur = tonumber(snd_get_setting("level_buffer", "25")) or 25
        InfoNote("SnD: Level buffer is currently " .. cur .. ".")
        InfoNote("SnD: Use 'xset level buffer <n>' to change (default 25).")
        -- Also list any per-area overrides.
        local s = snd_get_setting("area_level_overrides", "") or ""
        if s ~= "" then
            InfoNote("SnD: Per-area level overrides:")
            for entry in s:gmatch("[^,]+") do
                local arid, mn, mx = entry:match("^([^:]+):(%d+):(%d+)$")
                if arid then
                    InfoNote(string.format("      %-12s  %s–%s", arid, mn, mx))
                end
            end
        end
        return
    end
    if n < 0 or n > 200 then
        UsageNote("SnD: Level buffer must be between 0 and 200.")
        return
    end
    snd_set_setting("level_buffer", tostring(n), true)
    InfoNote("SnD: Level buffer set to " .. n .. ".")
end

-- ─── XSET LEVEL AREA OVERRIDE ────────────────────────────────────────────────

-- Alias handler: 'xset level <areaid> <min> <max>'
-- Sets a per-area level range override used when matching room CP/GQ targets.
-- Useful for areas like sohtwo (Outer Space) whose stored range is too narrow.
function xset_level_area(name, line, wildcards)
    local arid   = (wildcards[1] or ""):lower()
    local minlvl = tonumber(wildcards[2])
    local maxlvl = tonumber(wildcards[3])
    if arid == "" or arid == "buffer" then
        InfoNote("SnD: Usage: xset level <areaid> <min> <max>")
        InfoNote("SnD:        xset level <areaid> reset  — remove override")
        return
    end
    if not minlvl or not maxlvl or minlvl > maxlvl then
        UsageNote("SnD: Invalid range — min must be ≤ max.")
        return
    end
    -- Update the stored comma-separated list.
    local s = snd_get_setting("area_level_overrides", "") or ""
    local pat = arid:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")
    s = s:gsub(",?" .. pat .. ":%d+:%d+", ""):gsub("^,", ""):gsub(",$", "")
    s = (s ~= "" and (s .. ",") or "") .. arid .. ":" .. minlvl .. ":" .. maxlvl
    snd_set_setting("area_level_overrides", s, true)
    InfoNote(string.format(
        "SnD: Level override set for '%s': %d–%d  (buffer still adds %d to max).",
        arid, minlvl, maxlvl,
        tonumber(snd_get_setting("level_buffer", "25")) or 25
    ))
end

-- Alias handler: 'xset level <areaid> reset'
-- Removes the per-area level override for the given area key.
function xset_level_area_reset(name, line, wildcards)
    local arid = (wildcards[1] or ""):lower()
    if arid == "" or arid == "buffer" then
        InfoNote("SnD: Usage: xset level <areaid> reset")
        return
    end
    local s   = snd_get_setting("area_level_overrides", "") or ""
    local pat = arid:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")
    local new = s:gsub(",?" .. pat .. ":%d+:%d+", ""):gsub("^,", ""):gsub(",$", "")
    if new == s then
        InfoNote(string.format("SnD: No level override found for '%s'.", arid))
    else
        snd_set_setting("area_level_overrides", new, true)
        InfoNote(string.format("SnD: Level override for '%s' cleared.", arid))
    end
end
