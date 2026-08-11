-- hunting.lua
-- Hunt trick, quick where, quick scan, quick kill, auto-hunt, roomchars.
-- Depends on: constants.lua, util.lua, settings.lua, targets.lua, navigation.lua

-- ─── STATE ────────────────────────────────────────────────────────────────────

-- Hunt-trick state.
ht  = {index=1, first_target=true}

-- Upper bound on hunt-trick / quick-where iterations. Neither loop is
-- self-terminating: each continues until a trigger matches the game's "found"
-- or "failed" line, so unrecognised output would otherwise spam the MUD
-- forever. 101 covers any realistic number of same-named mobs.
HUNT_INDEX_LIMIT = 101

-- Quick-where state.
qw  = {index=1, exact=false, match=nil}

-- Set to true by smart_scan when performing a target-aware scan.
running_smart_scan = false

-- ─── QUICK WHERE ─────────────────────────────────────────────────────────────

function qw_reset(exact)
    EnableTrigger("trg_quick_where_match",    false)
    EnableTrigger("trg_quick_where_no_match", false)
    qw = {index=1, exact=exact or false}
end

-- 'qw' with no argument: re-run quick-where on the current target.
function qw_noarg()
    if not has_target() then
        InfoNote("\nSnD: Quick-where has no target. Use 'xcp', 'qw <mob>', or 'ht <mob>'.\n")
        return
    end
    if qw.exact then
        qw_exact()
    else
        do_quick_where(qw.index or 1, current_target.keyword)
    end
end

-- 'qw <mob>' alias handler.
function qw_arg_alias(name, line, wildcards)
    qw_arg(tonumber(wildcards.index) or 1, wildcards.mob)
    if type(xg_draw_window) == "function" then xg_draw_window() end
end

function qw_arg(index, mob)
    set_adhoc_target(mob)
    qw.index = index
    qw.exact = false
    do_quick_where(index, mob)
end

-- Called by xcp when the target is an activity mob (exact name match).
function qw_exact()
    if not has_activity_target() then
        InfoNote("\nSnD: qw exact: no activity target.\n")
        return
    end

    -- Skip where for mobs tagged nowhere — the server returns no results for them.
    if mob_has_tag(current_target.mob, current_target.arid, "nowhere") then
        InfoNote("SnD: Mob tagged nowhere — skipping where (not visible in where output).")
        return
    end

    -- qw_match() compares this against the raw, unstripped mob-name text
    -- captured from the actual 'where' output line, which always includes
    -- the mob's full name (article included, e.g. "the rabbit hound") --
    -- so the target must be the verbatim name, not stripped of stop-words.
    qw.exact = true
    qw.match = current_target.name
    do_quick_where(qw.index or 1, current_target.keyword)
end

function do_quick_where(ix, s)
    EnableTrigger("trg_quick_where_match",    true)
    EnableTrigger("trg_quick_where_no_match", true)
    if ix == 1 then
        Send(string.format("where %s", s))
    else
        Send(string.format("where %s.%s", ix, s))
    end
end

-- Trigger handler: a 'where' line matched.
function qw_match(name, line, wildcards)
    if not has_target() then return end

    local mob_lower = Trim(wildcards.mobname):lower()
    local room      = wildcards.roomname
    local found     = false

    if qw.exact then
        -- Aardwolf WHERE truncates mob names to 30 chars; compare against the
        -- verbatim target name (qw.match), not a stop-word-stripped version.
        if mob_lower == (qw.match or ""):lower():sub(1, 30) then
            found = true
        end
    else
        -- gmkw() can have no keyword for a mob it has never seen, and a nil
        -- here throws inside a trigger -- which MUSHclient then disables for
        -- the rest of the session.
        local parts = split((snd_target_keyword() or ""):lower(), "[^ ]+")
        for _, p in ipairs(parts) do
            if string.find(mob_lower, p, 1, true) then
                found = true; break
            end
        end
    end

    if not found then
        qw.index = (qw.index or 1) + 1
        if qw.index < HUNT_INDEX_LIMIT then
            local kw = snd_target_keyword()
            if not kw then
                InfoNote("SnD: no keyword for the current target -- set one with 'xset kw'.")
                qw_reset(qw.exact)
                return
            end
            SendNoEcho(string.format("where %s.%s", qw.index, kw))
        else
            DebugNote("SnD: qw: too many iterations, giving up.")
            qw_reset(qw.exact)
        end
        return
    end

    qw_reset(qw.exact)

    -- Update target from quest or main list.
    if quest_target and quest_target.mob
    and gmcp("room.info.zone") == quest_target.arid
    and quest_target.mob:lower() == mob_lower then
        set_target_from_quest(quest_target)
    else
        for i, target in ipairs(main_target_list) do
            if gmcp("room.info.zone") == target.arid
            and mob_lower == target.mob:lower() then
                set_target_from_main_target_list(i, current_target and current_target.keyword)
                break
            end
        end
    end

    if type(xg_draw_window) == "function" then xg_draw_window() end
    -- search_rooms_exact -> search_rooms_results handles autonav (xset autonav)
    -- itself once the room list is built, since it's the only place that
    -- knows whether the search resolved to exactly one room.
    search_rooms_exact(room, gmcp("room.info.zone"), Trim(wildcards.mobname))
end

-- Trigger handler: Aardwolf refused to run 'where' at all because the
-- current room's area is too complex ("There are too many doors and fences
-- to see who is in this area." -- the manor, notably). Neither qw_match nor
-- qw_no_match's regex matches this sentence, so without an explicit handler
-- the QuickWhere trigger group is left enabled and the next unrelated line
-- of output gets misread as a failed match, incrementing qw.index and
-- resending 'where N.mob' forever.
function qw_area_too_complex()
    qw_reset(qw.exact)
    InfoNote("SnD: Quick-where stopped -- too many doors and fences to see who is in this area.")
end

-- Trigger handler: 'where' returned no match.
function qw_no_match()
    qw_reset(qw.exact)
    if has_activity_target() then
        -- Show DB-backed room suggestions.
        local rows = lookup_not_found_mob(
            snd_target_label():lower(),
            current_target.arid or gmcp("room.info.zone") or ""
        )
        if #rows == 0 then return end

        local total = 0
        for _, r in ipairs(rows) do total = total + r.seen_count end
        for _, r in ipairs(rows) do
            r.percentage = total > 0 and (r.seen_count / total) or 0
        end
        table.sort(rows, function(a,b) return a.seen_count > b.seen_count end)

        InfoNote("\nSnD: Mob not found in current room.  Previous sightings:")
        search_rooms_results(rows)
    end
end

-- ─── HUNT TRICK ──────────────────────────────────────────────────────────────

function ht_reset()
    EnableTriggerGroup("HuntTrick", false)
    ht = {index=1, first_target=true}
end

-- 'ht' with no argument.
function ht_noarg()
    if not has_target() then
        InfoNote("\nSnD: Hunt trick has no target. Use 'xcp', 'ht <mob>', or 'qw <mob>'.\n")
        return
    end
    do_hunt_trick(ht.index or 1, current_target.keyword)
end

-- 'ht [<index>] <mob>' alias handler.
function ht_arg(name, line, wildcards)
    local ix = tonumber(wildcards.index) or 1
    set_adhoc_target(wildcards.mob)
    if type(xg_draw_window) == "function" then xg_draw_window() end
    do_hunt_trick(ix, current_target.keyword)
end

function do_hunt_trick(ix, s)
    ht.index = ix or 1

    -- Skip hunt entirely for mobs tagged nohunt.
    if has_activity_target() and
       mob_has_tag(current_target.mob, current_target.arid, "nohunt") then
        if mob_has_tag(current_target.mob, current_target.arid, "nowhere") then
            InfoNote("SnD: Mob tagged nohunt+nowhere — skipping both hunt and where.")
        else
            InfoNote("SnD: Mob tagged nohunt — mob cannot be hunted, using quick where.")
            qw_exact()
        end
        return
    end

    EnableTriggerGroup("AutoHunt", false)
    EnableTriggerGroup("HuntTrick", true)
    if ix == 1 then
        Send(string.format("hunt %s", s))
    else
        Send(string.format("hunt %s.%s", ix, s))
    end
end

-- Trigger: hunt found a mob — continue to next index.
function ht_continue()
    ht.first_target = false
    if not has_target() then return end

    local nxt = (ht.index or 1) + 1
    -- Bounded for the same reason quick-where is (see the 101 cap above, and
    -- the doors-and-fences fix in 3aef39b): this loop only ends when ht_complete
    -- or ht_fail matches a line, and when that output is not recognised there is
    -- nothing else to stop it sending 'hunt N.mob' indefinitely.
    if nxt >= HUNT_INDEX_LIMIT then
        DebugNote("SnD: hunt trick: too many iterations, giving up.")
        ht_reset()
        return
    end
    do_hunt_trick(nxt, current_target.keyword)
end

-- Trigger: hunt arrived at target — run qw to pin-point room.
function ht_complete(name, line, wildcards)
    EnableTriggerGroup("AutoHunt", false)
    local ix = ht.index or 1
    if has_activity_target() then
        qw.index = ix
        qw_exact()
    elseif has_target() then
        qw_arg(ix, current_target.keyword)
    end
    ht_reset()
end

-- Trigger: hunt failed.
function ht_fail()
    local was_first = ht.first_target
    ht_reset()
    if was_first and has_activity_target() then
        InfoNote("SnD: Hunt trick failed — trying quick where.")
        qw_exact()
    else
        InfoNote("SnD: Hunt trick failed.")
    end
end

-- Trigger: 'abort' or similar canceled hunt.
function ht_abort(name, line, wildcards)
    ht_reset()
    InfoNote("SnD: Hunt trick canceled.")
end

-- ─── QUICK SCAN / QUICK KILL / SMART SCAN ────────────────────────────────────

function quick_scan()
    -- Skip scan for mobs tagged noscan (they don't appear in scan output).
    if has_activity_target() and
       mob_has_tag(current_target.mob, current_target.arid, "noscan") then
        InfoNote("SnD: Mob tagged noscan — mob not visible in scan output, skipping scan.")
        return
    end
    if has_target() then
        sound_not_played = true  -- suppress "target nearby" beep when scan fires as part of a deliberate search
        local kw = snd_target_keyword()
        if not kw then
            InfoNote("SnD: no keyword for the current target -- set one with 'xset kw'.")
            return
        end
        Send(string.format("scan %s", kw))
    else
        Send("scan")
    end
end

function smart_scan()
    if has_activity_target() then
        if mob_has_tag(current_target.mob, current_target.arid, "noscan") then
            InfoNote("SnD: Skipping scan — mob is tagged noscan.")
            return
        end
        running_smart_scan = true
        SendNoEcho("scan")
    else
        quick_scan()
    end
end

function quick_kill(name, line, wildcards)
    if not has_target() then
        InfoNote("\nSnD: Quick-kill has no target. Use 'ht', 'qw', or 'xcp'.\n")
        return
    end
    local kw = snd_target_keyword()
    if not kw then
        InfoNote("\nSnD: Quick-kill has no keyword for the current target. " ..
                 "Set one with 'xset kw'.\n")
        return
    end
    local targ_name = " '" .. kw .. "'"
    local cmd_str   = snd_get_setting("quick_kill_command", "k")
    for cmd in cmd_str:gmatch("[^;]+") do
        cmd = Trim(cmd)
        if cmd:match("%s+notarg$") then
            Execute(cmd:gsub("%s+notarg$", ""))  -- "notarg" suffix = send command without target name
        else
            Execute(cmd .. targ_name)
        end
    end
end

function xset_quick_kill_command(name, line, wildcards)
    local arg = Trim(wildcards.arg or "")
    if arg == "" then
        InfoNote("SnD: Quick-kill command: '" ..
            snd_get_setting("quick_kill_command", "k") .. "'")
    else
        snd_set_setting("quick_kill_command", arg, false)
        InfoNote("SnD: Quick-kill command set to: '" .. arg .. "'")
    end
end

function xset_silent_mode(name, line, wildcards)
    local opt = Trim(wildcards[1] or ""):lower()
    if opt == "" then
        InfoNote("SnD: Silent mode: " ..
            string.upper(snd_get_setting("silent_mode", "off")))
    elseif opt == "on" or opt == "off" then
        snd_set_setting("silent_mode", opt, false)
        InfoNote("SnD: Silent mode is now " .. string.upper(opt) .. ".")
    else
        ErrorNote("SnD: xset silent [on|off]")
    end
end
