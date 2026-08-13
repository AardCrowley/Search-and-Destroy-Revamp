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

-- ─── ALWAYS-ON TRACE BUFFER ──────────────────────────────────────────────────
--
-- Debug logging only helps if it was already on, and it never is the first time
-- something goes wrong. So every DebugNote and ErrorNote is recorded here
-- regardless of the debug setting, in a fixed-size ring in memory, and written
-- out only when it is worth reading: on an error, or when asked.
--
-- The cost is one table slot per note and no file I/O, so it can stay on
-- permanently. Nothing is written to disk during ordinary play.
local TRACE_MAX   = 250          -- notes kept; a few minutes of active play
local _trace      = {}           -- ring buffer
local _trace_head = 0            -- count of notes ever recorded
local _trace_dumping = false     -- guards against recursion through ErrorNote

local function trace_record(level, parts)
    local msg = ""
    for i = 1, #parts do
        msg = msg .. (i > 1 and " " or "") .. tostring(parts[i])
    end
    _trace_head = _trace_head + 1
    _trace[(_trace_head - 1) % TRACE_MAX + 1] = {
        t = os.date("%H:%M:%S"), lvl = level, msg = msg,
    }
end

-- The buffer in chronological order.
function trace_entries()
    local out = {}
    local n   = math.min(_trace_head, TRACE_MAX)
    local start = (_trace_head > TRACE_MAX) and (_trace_head % TRACE_MAX) or 0
    for i = 1, n do
        out[#out + 1] = _trace[(start + i - 1) % TRACE_MAX + 1]
    end
    return out
end

function trace_count()
    return math.min(_trace_head, TRACE_MAX), _trace_head
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
    trace_record("ERROR", {...})
    if type(snd_get_setting) == "function"
    and snd_get_setting("debug_mode", "off") == "on" then
        if not _debug_log_fh then debug_log_open() end
        debug_log_write("ERROR", ...)
    end
    -- An error is the moment the preceding notes become worth having. Written
    -- out even with debug mode off, which is the whole point: nobody turns it
    -- on until after the thing they wanted to see has happened.
    trace_dump("error")
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
        -- Silent when there is nothing set: the header of a log opened before
        -- the database is ready should not read like a failure, and a session
        -- with no settings changed has nothing here worth a heading.
        local settings, n_settings = debug_settings_lines()
        if n_settings > 0 then
            fh:write(string.format(
                "----- settings changed from default (%d) -----\n", n_settings))
            for _, l in ipairs(settings) do fh:write(l .. "\n") end
            fh:write("-----\n")
        end
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

-- Roll the log over once it passes LOG_MAX_BYTES, keeping one generation.
--
-- Without this an always-on trace grows without limit on a machine nobody is
-- watching. One previous generation is enough to cover "it broke, and the
-- interesting part scrolled past".
local LOG_MAX_BYTES = 512 * 1024

function debug_log_rotate_if_large()
    local path = debug_log_path()
    local size = nil
    pcall(function()
        local fh = io.open(path, "rb")
        if fh then size = fh:seek("end"); fh:close() end
    end)
    if not size or size < LOG_MAX_BYTES then return false end

    local was_open = _debug_log_fh ~= nil
    debug_log_close()
    pcall(function() os.remove(path .. ".1") end)
    pcall(function() os.rename(path, path .. ".1") end)
    if was_open then debug_log_open() end
    return true
end

-- ─── SETTINGS SNAPSHOT ───────────────────────────────────────────────────────

-- Colors and fonts are the bulk of the rows and change no behaviour, so they
-- would only bury the settings that do.
local function setting_is_cosmetic(name)
    return name:find("^color_") ~= nil or name:find("font") ~= nil
end

-- The settings this character is actually running under.
--
-- Returns the lines to write, and how many settings they describe -- which is
-- not #lines, since a failure or an untouched install has something to say and
-- no settings to say it about.
--
-- Only what has been written to the settings table -- a setting still at its
-- default reads the same for everyone, so it can never be the reason two
-- people see different behaviour, and listing all of them would hide the few
-- that can. Per-character rows shadow global ones, so where both exist the
-- effective value is shown with the global it is overriding.
function debug_settings_lines()
    local lines = {}

    if type(db_open) ~= "function" then
        return { "  (settings unavailable -- the database module is not loaded)" }, 0
    end

    local globals, chars, names = {}, {}, {}
    local ok = pcall(function()
        local db = db_open()
        if not db then return end
        local char_id = (type(get_current_char_id) == "function")
            and get_current_char_id() or nil
        for row in db:nrows(
            "SELECT name, value, char_id FROM settings " ..
            "WHERE char_id IS NULL OR char_id=" .. tostring(char_id or -1)
        ) do
            local n = tostring(row.name or "")
            if n ~= "" and not setting_is_cosmetic(n) then
                if row.char_id == nil then
                    globals[n] = tostring(row.value)
                else
                    chars[n] = tostring(row.value)
                end
                names[n] = true
            end
        end
        db_close(db)
    end)

    if not ok then
        return { "  (settings could not be read)" }, 0
    end

    local sorted = {}
    for n in pairs(names) do sorted[#sorted + 1] = n end
    table.sort(sorted)

    for _, n in ipairs(sorted) do
        local per_char = chars[n] ~= nil
        local value    = per_char and chars[n] or globals[n]
        local scope    = per_char and "char" or "global"
        -- A per-character value hiding a different global one is worth seeing:
        -- it is how the same command reports two answers on two characters.
        if per_char and globals[n] ~= nil and globals[n] ~= value then
            scope = scope .. ", global=" .. globals[n]
        end
        lines[#lines + 1] = string.format("  %-32s %-16s (%s)", n, value, scope)
    end

    local count = #lines
    if count == 0 then
        lines[1] = "  (nothing set -- every setting is at its default)"
    end
    return lines, count
end

-- Write the trace buffer to the log.
--
-- reason: what prompted it, recorded at the top so the file explains itself.
-- Returns the number of entries written.
function trace_dump(reason)
    if _trace_dumping then return 0 end
    _trace_dumping = true

    local entries = trace_entries()
    local kept, total = trace_count()
    local ok = pcall(function()
        debug_log_rotate_if_large()
        local fh = io.open(debug_log_path(), "a")
        if not fh then return end
        fh:write(string.format(
            "\n===== SnD trace (%s) - %s - v%s - %d of %d note(s) =====\n",
            tostring(reason or "on request"),
            os.date("%Y-%m-%d %H:%M:%S"),
            (type(snd_version) == "function" and snd_version()) or "?",
            kept, total))
        -- Before the notes rather than after: "which settings was this run
        -- under" is the first question asked of a report that cannot be
        -- reproduced, and the notes below can be thousands of lines.
        local settings, n_settings = debug_settings_lines()
        fh:write(string.format(
            "----- settings changed from default (%d) -----\n", n_settings))
        for _, l in ipairs(settings) do fh:write(l .. "\n") end
        fh:write("----- notes -----\n")

        for _, e in ipairs(entries) do
            fh:write(string.format("[%s] [%-5s] %s\n", e.t, e.lvl, e.msg))
        end
        fh:write("===== end of trace =====\n")
        fh:flush(); fh:close()
    end)

    _trace_dumping = false
    return ok and #entries or 0
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
-- ─── PLUGIN FILE SELF-UPGRADE ────────────────────────────────────────────────
--
-- Replace the plugin file when it is older than the published release.
--
-- This lives in a module on purpose. Modules are refreshed by 'snd update' on
-- every install including v6.0, but the plugin file itself is only replaced by
-- code that lives IN the plugin file -- and v6.0's has no such code, because
-- do_update() was never called from anywhere. Left there, every v6.0 user would
-- have to replace Search_and_Destroy.xml by hand. Put here, it arrives with the
-- ordinary module update and does the job itself.
--
-- Everything it needs already exists in v6.0's plugin file: snd_raw_url,
-- download_file, do_update and callback_update_plugin. Each is checked before
-- use anyway, since a module must never assume what the plugin file provides.
local _plugin_upgrade_checked = false

function snd_upgrade_plugin_file_if_stale()
    if _plugin_upgrade_checked then return end
    _plugin_upgrade_checked = true          -- once per session, whatever happens

    if type(snd_get_setting) == "function"
    and snd_get_setting("automatic_update_checks", "on") ~= "on" then
        return                              -- update checks are switched off
    end
    if type(download_file) ~= "function"
    or type(snd_raw_url)   ~= "function"
    or type(do_update)     ~= "function" then
        return                              -- older plugin file than expected
    end

    local running = (type(snd_version) == "function") and snd_version()
                    or tostring(PLUGIN_VERSION or "?")

    download_file(snd_raw_url("VERSION"), function(retval, page, status)
        if status ~= 200 or type(page) ~= "string" then return end
        local latest = Trim(page)
        if latest == "" or latest == running then return end

        InfoNote("SnD: your plugin file is v", running, "; v", latest,
                 " is available.")
        InfoNote("SnD: fetching it now -- the plugin will reload itself.")
        do_update(latest)
    end)
end

function snd_debug_cmd(name, line, wildcards)
    local action = ((wildcards and wildcards.action) or ""):lower()
    if action == "clear" then
        debug_log_clear()
    elseif action == "settings" then
        -- The same block the dump writes, on screen, for pasting into a report
        -- when the log file is more than the question deserves.
        local lines, n = debug_settings_lines()
        InfoNote("SnD: settings changed from default (" .. n .. "):")
        for _, l in ipairs(lines) do InfoNote(l) end
        InfoNote("SnD: anything not listed is at its default. Colors and " ..
                 "fonts are left out.")
    elseif action == "dump" then
        -- For when behaviour is wrong but nothing errored, which is most
        -- reports. Notes are recorded continuously but never written during
        -- ordinary play, so this is the only way to capture such a run.
        local kept, total = trace_count()
        local n = trace_dump("requested")
        if n > 0 then
            InfoNote("SnD: wrote " .. n .. " of " .. total ..
                     " recorded note(s) to:")
            InfoNote("  " .. debug_log_path())
            InfoNote("SnD: send that file along with what you were doing.")
        else
            InfoNote("SnD: nothing recorded yet.")
        end
    else
        local cur = snd_get_setting("debug_mode", "off")
        local kept, total = trace_count()
        InfoNote("SnD: Debug mode is " .. ((cur == "on") and "ON" or "OFF") .. ".")
        InfoNote("SnD: Log file: " .. debug_log_path())
        InfoNote("SnD: Trace buffer holds " .. kept .. " of the last " ..
                 total .. " note(s), recorded whether or not debug mode is on.")
        InfoNote("SnD: 'snd debug dump' writes them out; it happens by itself " ..
                 "on an error.")
        InfoNote("SnD: 'snd debug settings' lists what you have changed from " ..
                 "the defaults — the dump records it too.")
        if cur ~= "on" then
            InfoNote("SnD: Use 'xset debug on' to also show them as they happen.")
        end
    end
end

-- ─── NOTE FUNCTIONS ──────────────────────────────────────────────────────────

-- Debug note: only prints when the debug_mode setting is "on".
-- Also writes to the log file.  Safe to call before settings.lua is loaded.
function DebugNote(...)
    -- Recorded whether or not debug mode is on; only *shown* when it is.
    trace_record("DEBUG", {...})
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
