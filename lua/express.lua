-- express.lua
-- Express mode: skip straight to the kill room when kill_count threshold is met.
-- Depends on: util.lua, db.lua, settings.lua

-- ─── PUBLIC API ───────────────────────────────────────────────────────────────

-- Returns true if target qualifies for express navigation (go directly to kill room).
-- A target qualifies when ANY of the following is true:
--   * The mob has the 'express' flag set in mob_tags (unconditional override), OR
--   * Express mode is enabled (xset express on) AND:
--     - The target has at least one known result room (results > 0)
--     - The highest kills count meets or exceeds the threshold
function is_express_target(target)
    -- Express flag override: always express regardless of kill count or mode setting.
    if target.mob and target.arid then
        if mob_has_tag(target.mob, target.arid, "express") then
            return true
        end
    end

    if snd_get_setting("express_onoff", "on") ~= "on" then
        return false
    end
    local min_kills = tonumber(snd_get_setting("express_min_kill_count", "2")) or 2
    return  target.results  ~= nil
        and target.kills    ~= nil
        and tonumber(target.results) > 0
        and tonumber(target.kills)   >= min_kills
end

-- Toggle express mode on/off, or set min kill count.
-- Alias handler: 'xset express [on|off|<number>]'
function xset_express(name, line, wildcards)
    local w = (type(wildcards) == "table" and wildcards) or {}

    -- Read under the names the alias actually captures. It defines
    -- (?<state>on|off) and (?<min_kill>\d+); this read wildcards.option, which
    -- nothing ever sets, so every form fell through to the "show current"
    -- branch and the command silently did nothing at all.
    local state    = Trim(w.state    or "")
    local min_kill = Trim(w.min_kill or "")
    local changed = false

    if state == "on" or state == "off" then
        snd_set_setting("express_onoff", state, true)
        InfoNote("SnD: Express mode is now " .. string.upper(state) .. ".")
        changed = true
    elseif state ~= "" then
        ErrorNote("SnD: xset express: '" .. state .. "' is not on or off.")
        return
    end

    if min_kill ~= "" then
        local n = tonumber(min_kill)
        if not n then
            ErrorNote("SnD: xset express: '" .. min_kill ..
                      "' is not a number of kills.")
            return
        end
        n = math.max(1, math.floor(n))
        snd_set_setting("express_min_kill_count", tostring(n), true)
        InfoNote("SnD: Express minimum kill count set to " .. n .. ".")
        changed = true
    end

    if changed then
        -- The list already on screen was built under the old rule, so which
        -- targets count as express has just changed underneath it.
        if type(build_main_target_list) == "function"
        and type(current_activity) == "string"
        and (current_activity == "cp" or current_activity == "gq") then
            build_main_target_list(current_activity, area_room_type)
        elseif type(xg_draw_window) == "function" then
            xg_draw_window()
        end
        return
    end

    local cur_onoff  = snd_get_setting("express_onoff", "on")
    local cur_thresh = snd_get_setting("express_min_kill_count", "2")
    InfoNote("SnD: Express mode: " .. string.upper(cur_onoff) ..
             " (threshold: " .. cur_thresh .. " kill(s)).")
    InfoNote("SnD: Express sends you straight to a mob's known kill room " ..
             "instead of the area entrance, once you have killed it there " ..
             "that many times.")
    InfoNote("SnD: Usage: xset express [on|off] [<number>]  " ..
             "-- 'xset mob express <mob>' forces one mob regardless.")
end
