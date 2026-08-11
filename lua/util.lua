-- util.lua
-- Pure utility functions. No DB access. No game state. Safe to call from anywhere.
-- Depends on: constants.lua (NOTE_COLORS, PLUGIN_ID_GMCP_HANDLER, PLUGIN_ID_REPAINT_BUFFER,
--             PLUGIN_ID_Z_ORDER_MONITOR)

-- ─── SQL ──────────────────────────────────────────────────────────────────────

-- Escape s for safe embedding in a SQL string literal.
-- Returns the value wrapped in single quotes with internal quotes doubled.
-- Returns the string NULL (unquoted) if s is nil/false.
function fixsql(s)
    if s then
        return "'" .. (string.gsub(tostring(s), "'", "''")) .. "'"
    else
        return "NULL"
    end
end

-- ─── GMCP ─────────────────────────────────────────────────────────────────────

-- gmcp(s) is loaded via 'require "gmcphelper"' in the plugin script block.
-- We only define send_gmcp_packet here because it is not in the package.

function send_gmcp_packet(s)
    CallPlugin(PLUGIN_ID_GMCP_HANDLER, "Send_GMCP_Packet", s)
end

-- ─── CONDITIONALS ─────────────────────────────────────────────────────────────

function ifc(condition, ctrue, cfalse)
    if condition then
        return ctrue
    else
        return cfalse
    end
end

-- ─── STRING UTILITIES ─────────────────────────────────────────────────────────

-- Truncate str to max_length characters, appending "..." if truncated.
function ellipsify(str, max_length)
    if #str <= max_length then
        return str
    else
        -- Reserve 3 chars for "..." so the result is exactly max_length chars.
        return str:sub(1, math.max(0, max_length - 3)) .. "..."
    end
end

-- Strip Aardwolf @-style color codes from a string.
function strip_colours(s)
    s = s:gsub("@@", "\0")          -- protect escaped @
    s = s:gsub("@%-", "~")          -- fix tildes (historical)
    s = s:gsub("@x%d?%d?%d?", "")  -- strip xterm color codes
    s = s:gsub("@.([^@]*)", "%1")   -- strip normal color codes and hidden garbage
    s = s:gsub("\0", "@")           -- restore escaped @
    return s
end

-- Word-wrap str to limit columns with optional indentation.
-- indent  = prefix applied to all continuation lines (default "")
-- indent1 = prefix applied to the first line (default = indent)
function helpWrap(str, limit, indent, indent1)
    indent  = indent  or ""
    indent1 = indent1 or indent
    limit   = limit   or 76
    local here = 1 - #indent1
    return indent1 ..
        str:gsub(
            "(%s+)()(%S+)()",
            function(sp, st, word, fi)
                if fi - here > limit then
                    here = st - #indent
                    return "\n" .. indent .. word
                end
            end
        )
end

-- Split line into tokens matching delim (a gmatch pattern).
-- Default delim captures non-whitespace runs.
function split(line, delim)
    delim = delim or "%S+"
    local result = {}
    for token in string.gmatch(line, delim) do
        result[#result + 1] = token
    end
    return result
end

-- Sorted pairs iterator. f is an optional comparator for table.sort.
function spairs(t, f)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, f)
    local i = 0
    return function()
        i = i + 1
        if keys[i] ~= nil then
            return keys[i], t[keys[i]]
        end
    end
end

-- Banker's rounding: round half to nearest even (avoids consistent upward bias).
function round_banker(x)
    if (x + 0.5) % 2 == 0 then
        return math.floor(x + 0.5)
    else
        return math.ceil(x - 0.5)
    end
end

function rtrim(s)
    local n = #s
    while n > 0 and s:sub(n, n):match("%s") do
        n = n - 1
    end
    return s:sub(1, n)
end

-- Strip leading Aardwolf mob/player status flags from a raw mob name.
-- Handles parenthesized flags (single or multi-word) like (R), (Red Aura),
-- (Golden Aura), (Animated), (Wounded), etc., and bracket tags like [AFK].
-- Player detection must be done on the raw name before calling this.
function strip_mob_flags(raw)
    local s = raw
    while true do
        local rest = s:match("^%([A-Za-z][A-Za-z ]*%)%s*(.+)$")
                  or s:match("^%(!%)%s*(.+)$")             -- Aimed, rendered as bare "(!)"
                  or s:match("^%[[A-Za-z%-]+%]%s*(.+)$")
        if rest then s = rest else break end
    end
    return s
end

-- Remove characters that are unsafe in filenames, leaving alphanumerics,
-- spaces, parentheses, underscores, and hyphens.
function sanitize_filename(str)
    return string.gsub(str, "[^%w%s()_-]", "")
end

-- Return the player's effective level for area-range comparisons.
-- Adds 10 * tier to the current level so higher-tier characters can access
-- appropriately-levelled areas.
function tier_level()
    local l = tonumber(gmcp("char.status.level")) or 0
    local t = tonumber(gmcp("char.base.tier"))    or 0
    return l + 10 * t
end

-- Format a duration in seconds as a compact human-readable string.
-- Returns "N/A" if duration is nil; returns "0s" for zero duration.
function format_duration(duration)
    if duration ~= nil then
        local days    = math.floor(duration / 86400)
        local hours   = math.floor(math.fmod(duration, 86400) / 3600)
        local minutes = math.floor(math.fmod(duration, 3600) / 60)
        local seconds = math.floor(math.fmod(duration, 60))
        if days > 0 then
            return string.format("%dd%dh%dm%ds", days, hours, minutes, seconds)
        elseif hours > 0 then
            return string.format("%dh%dm%ds", hours, minutes, seconds)
        elseif minutes > 0 then
            return string.format("%dm%ds", minutes, seconds)
        else
            return string.format("%ds", seconds)
        end
    end
    return "N/A"
end

-- ─── DEBUG LOG FILE ──────────────────────────────────────────────────────────

local _debug_log_fh = nil

-- ─── NOTE OUTPUT ──────────────────────────────────────────────────────────────

-- Print alternating-color message segments to the output window.
-- messages       : array of strings printed consecutively
-- regular_color  : hex foreground color for odd-indexed segments
-- highlight_color: hex foreground color for even-indexed segments
-- background     : optional hex background color (default "" = transparent)
function print_alternating_note(messages, regular_color, highlight_color, background)
    local current_color, other_color = regular_color, highlight_color
    background = background or ""
    for _, message in ipairs(messages) do
        ColourTell(current_color, background, message)
        current_color, other_color = other_color, current_color
    end
    print("")
end

function InfoNote(...)
    print_alternating_note({...}, NOTE_COLORS.INFO, NOTE_COLORS.INFO_HIGHLIGHT)
end

-- Error note in white/yellow on dark red background.
-- Always logged to the debug log file when debug mode is on.
function ErrorNote(...)
    print_alternating_note(
        {...},
        NOTE_COLORS.ERROR,
        NOTE_COLORS.ERROR_HIGHLIGHT,
        NOTE_COLORS.ERROR_BACKGROUND
    )
    if type(snd_get_setting) == "function"
    and snd_get_setting("debug_mode", "off") == "on" then
        if not _debug_log_fh then debug_log_open() end
        debug_log_write("ERROR", ...)
    end
end

function ImportantNote(...)
    print_alternating_note(
        {...},
        NOTE_COLORS.IMPORTANT,
        NOTE_COLORS.IMPORTANT_HIGHLIGHT,
        NOTE_COLORS.IMPORTANT_BACKGROUND
    )
end

-- ─── DEBUG LOG FILE ──────────────────────────────────────────────────────────

function debug_log_path()
    local base = (type(GetInfo) == "function" and GetInfo(66)) or ""
    return base .. "SnD_debug.log"
end

-- Open (or no-op if already open) the log for appending and write a header.
function debug_log_open()
    if _debug_log_fh then return end
    pcall(function()
        local fh = io.open(debug_log_path(), "a")
        if not fh then return end
        _debug_log_fh = fh
        local ts  = os.date("%Y-%m-%d %H:%M:%S")
        local ver = snd_version()
        local chr = (type(gmcp) == "function" and gmcp("char.base.name")) or "?"
        fh:write(string.format(
            "\n=== S&D Debug Log  v%s  char:%s  %s ===\n",
            ver, chr, ts
        ))
        fh:flush()
    end)
end

function debug_log_close()
    if not _debug_log_fh then return end
    pcall(function()
        _debug_log_fh:write(string.format(
            "[%s] [INFO ] Debug logging stopped.\n", os.date("%H:%M:%S")
        ))
        _debug_log_fh:flush()
        _debug_log_fh:close()
    end)
    _debug_log_fh = nil
end

-- Append one timestamped line to the log (silently no-ops when not open).
-- level: short tag such as "DEBUG", "ERROR", "INFO".
function debug_log_write(level, ...)
    if not _debug_log_fh then return end
    local parts = {...}
    local msg   = ""
    for i, v in ipairs(parts) do
        msg = msg .. (i > 1 and " " or "") .. tostring(v)
    end
    pcall(function()
        _debug_log_fh:write(string.format(
            "[%s] [%-5s] %s\n", os.date("%H:%M:%S"), level, msg
        ))
        _debug_log_fh:flush()
    end)
end

-- Truncate the log file (re-opens if logging was active).
function debug_log_clear()
    local was_open = _debug_log_fh ~= nil
    debug_log_close()
    pcall(function()
        local f = io.open(debug_log_path(), "w")
        if f then f:close() end
    end)
    if was_open then debug_log_open() end
    InfoNote("SnD: Debug log cleared — " .. debug_log_path())
end

-- ─── XSET DEBUG / SND DEBUG COMMANDS ─────────────────────────────────────────

-- Alias handler: 'xset debug [on|off]'
function xset_debug(name, line, wildcards)
    local opt = ((wildcards and (wildcards.option or wildcards[1])) or ""):lower()
    if opt == "on" then
        snd_set_setting("debug_mode", "on", true)
        debug_mode = "on"   -- sync module-level variable used by legacy inline code
        debug_log_open()
        debug_log_write("INFO", "Debug mode enabled.")
        InfoNote("SnD: Debug mode ON — logging to:")
        InfoNote("  " .. debug_log_path())
        InfoNote("SnD: Type 'snd debug clear' to clear the log.")
    elseif opt == "off" then
        debug_log_write("INFO", "Debug mode disabled.")
        debug_log_close()
        snd_set_setting("debug_mode", "off", true)
        debug_mode = "off"
        InfoNote("SnD: Debug mode OFF.")
    else
        local cur = snd_get_setting("debug_mode", "off")
        local state = (cur == "on") and "ON" or "OFF"
        InfoNote("SnD: Debug mode is " .. state .. ".")
        InfoNote("SnD: Log file: " .. debug_log_path())
        if cur ~= "on" then
            InfoNote("SnD: Use 'xset debug on' to enable debug logging.")
        else
            InfoNote("SnD: Use 'snd debug clear' to clear the log.")
            InfoNote("SnD: Use 'xset debug off' to disable debug logging.")
        end
    end
end

-- Alias handler: 'snd debug [clear]'
function snd_debug_cmd(name, line, wildcards)
    local action = ((wildcards and wildcards.action) or ""):lower()
    if action == "clear" then
        debug_log_clear()
    else
        local cur = snd_get_setting("debug_mode", "off")
        InfoNote("SnD: Debug mode is " .. ((cur == "on") and "ON" or "OFF") .. ".")
        InfoNote("SnD: Log file: " .. debug_log_path())
        if cur ~= "on" then
            InfoNote("SnD: Use 'xset debug on' to enable debug logging.")
        end
    end
end

-- ─── NOTE FUNCTIONS ──────────────────────────────────────────────────────────

-- Debug note: only prints when the debug_mode setting is "on".
-- Also writes to the log file.  Safe to call before settings.lua is loaded.
function DebugNote(...)
    if type(snd_get_setting) == "function" and
       snd_get_setting("debug_mode", "off") == "on" then
        if not _debug_log_fh then debug_log_open() end
        ColourTell(NOTE_COLORS.DEBUG_HIGHLIGHT, "", "DEBUG: ")
        print_alternating_note({...}, NOTE_COLORS.DEBUG, NOTE_COLORS.DEBUG_HIGHLIGHT)
        debug_log_write("DEBUG", ...)
    end
end

-- ─── MINIWINDOW HELPERS ───────────────────────────────────────────────────────

-- Trigger a rate-limited display repaint via the Aardwolf repaint buffer plugin.
-- Call after every miniwindow draw operation instead of raw Repaint().
function buffered_repaint()
    CallPlugin(PLUGIN_ID_REPAINT_BUFFER, "BufferedRepaint")
end

function z_order_boost(win_id)
    CallPlugin(PLUGIN_ID_Z_ORDER_MONITOR, "boostMe", win_id)
end

function z_order_drop(win_id)
    CallPlugin(PLUGIN_ID_Z_ORDER_MONITOR, "dropMe", win_id)
end

-- ─── SETTINGS SHIM ────────────────────────────────────────────────────────────

-- Compatibility wrapper that writes to the settings DB table AND to the legacy
-- MUSHclient plugin variable store.  Exists for the transition period while
-- any code still uses GetVariable/SetVariable.  Remove in v8.
--
-- NOTE: snd_set_setting is defined in settings.lua (loaded after util.lua).
--       This function is only invoked at game-event time, so snd_set_setting
--       is always available by the time it is called.
function set_variable(name, value)
    snd_set_setting(name, value, false)
    SetVariable(name, tostring(value))
end
