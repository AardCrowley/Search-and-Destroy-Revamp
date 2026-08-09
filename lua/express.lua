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
    local opt = Trim(wildcards.option or "")

    if opt == "on" or opt == "off" then
        snd_set_setting("express_onoff", opt, true)
        InfoNote("SnD: Express mode is now " .. string.upper(opt) .. ".")

    elseif tonumber(opt) ~= nil then
        local n = math.max(1, math.floor(tonumber(opt)))
        snd_set_setting("express_min_kill_count", tostring(n), true)
        InfoNote("SnD: Express minimum kill count set to " .. n .. ".")

    elseif opt == "" then
        local cur_onoff  = snd_get_setting("express_onoff", "on")
        local cur_thresh = snd_get_setting("express_min_kill_count", "2")
        InfoNote("SnD: Express mode: " .. string.upper(cur_onoff) ..
                 " (threshold: " .. cur_thresh .. " kill(s)).")
        InfoNote("SnD: Usage: xset express [on|off|<number>]")

    else
        ErrorNote("SnD: xset express: invalid option '" .. opt .. "'. Use on, off, or a number.")
    end
end
