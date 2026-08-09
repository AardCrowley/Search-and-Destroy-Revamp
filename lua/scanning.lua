-- scanning.lua
-- Scan/consider output processing, smart scan, roomchars, mob activity tags.
-- Depends on: constants.lua, util.lua, db.lua, mobs.lua, targets.lua,
--             settings.lua, hunting.lua

-- ─── SCAN STATE ───────────────────────────────────────────────────────────────

-- Built during a scan sequence; flushed in scan_end().
local scan_full_display        = {}
local mobs_in_scanned_room     = {}
local doors_in_scanned_room    = {}
local scanned_mobs_here        = {}

-- Flags set during scan processing.
local scanning_current_room    = false
local activity_target_found_here = false
local quest_target_found_here  = false
local target_found_nearby      = false
local other_target_found_here  = false

-- Set by roomchars triggers; used by smart_scan to detect noscan mobs.
mob_count_here = 0

-- True after scan_end when consider should follow (noscan mob suspected).
local con_after_scan = false


-- ─── STYLE HELPERS ────────────────────────────────────────────────────────────

local function convert_one_style(s)
    return {
        style  = s.style  or 0,
        color  = RGBColourToName(s.textcolour),
        bcolor = RGBColourToName(s.backcolour),
        text   = s.text,
    }
end

local function convert_full_styles(styles)
    local out = {}
    for _, s in ipairs(styles) do out[#out+1] = convert_one_style(s) end
    return out
end

-- ─── SCAN TRIGGER HANDLERS ────────────────────────────────────────────────────

function scan_start()
    EnableTriggerGroup("scan", true)
    doors_in_scanned_room = {}
    scanned_mobs_here     = {}
    scan_full_display     = {{doors = doors_in_scanned_room}}
end

function scan_end()
    EnableTriggerGroup("scan", false)

    local anything_seen = false

    for _, room in ipairs(scan_full_display) do
        if room.mobs and #room.mobs > 0 then
            if room.header then
                for _, s in ipairs(room.header) do
                    NoteStyle(s.style)
                    ColourTell(s.color, s.bcolor, s.text)
                end
                print("")
            end
            for _, mob in ipairs(room.mobs) do
                anything_seen = true
                for _, s in ipairs(mob) do
                    NoteStyle(s.style)
                    ColourTell(s.color, s.bcolor, s.text)
                end
                print("")
            end
        end
        if #room.doors > 0 then
            for _, door in ipairs(room.doors) do
                for _, s in ipairs(door) do
                    NoteStyle(s.style)
                    ColourTell(s.color, s.bcolor, s.text)
                end
                print("")
            end
        end
    end

    if not anything_seen and running_smart_scan then
        ColourNote(RGBColourToName(GetNormalColour(8)), "", "You see no targets around.")
    end

    write_mob_list_to_db(scanned_mobs_here)

    if not quest_target_found_here then
        if activity_target_found_here then
            play_target_found_sound()
        else
            if running_smart_scan
            and #scanned_mobs_here < mob_count_here then
                InfoNote("SnD: Potential noscan mob. Running consider.")
                con_after_scan = true
                SendNoEcho("con")
            end
            if target_found_nearby   then play_target_nearby_sound()     end
            if other_target_found_here then play_other_target_here_sound() end
        end
    end

    scanning_current_room      = false
    activity_target_found_here = false
    quest_target_found_here    = false
    target_found_nearby        = false
    other_target_found_here    = false
    running_smart_scan         = false
end

function scan_location_current_room(name, line, wildcards, style)
    scanning_current_room = true
    scanned_mobs_here     = {}
    _setup_scan_room(style)
end

function scan_location_nearby_room(name, line, wildcards, style)
    scanning_current_room = false
    _setup_scan_room(style)
end

function _setup_scan_room(style)
    mobs_in_scanned_room  = {}
    doors_in_scanned_room = {}
    scan_full_display[#scan_full_display+1] = {
        header = convert_full_styles(style),
        mobs   = mobs_in_scanned_room,
        doors  = doors_in_scanned_room,
    }
end

function scan_door_nearby(name, line, wildcards, style)
    doors_in_scanned_room[#doors_in_scanned_room+1] = convert_full_styles(style)
end


function scan_mob(name, line, wildcards, style)
    -- Skip player lines. (Player) can appear in flags or mob_name; check all three patterns.
    local mob_name_raw = wildcards.mob_name
    if string.match(wildcards.flags or "", "%(Player%)") or
       string.find(wildcards.flags  or "", "(P)", 1, true) or
       string.match(mob_name_raw,          "%(Player%)") then
        return
    end
    -- Strip flags (R)(I)(H) etc. for storage and activity matching;
    -- keep raw for display (flags are informational in scan output).
    local mob_name = strip_mob_flags(mob_name_raw)
    DebugNote(string.format("SnD: scan_mob raw=|%s| clean=|%s|", mob_name_raw, mob_name))
    local tags     = mob_activity_tags(mob_name, scanning_current_room)

    if scanning_current_room then
        scanned_mobs_here[#scanned_mobs_here+1] = mob_name
    end

    if #tags > 0 or not running_smart_scan then
        local padding      = 5
        local mob_styled   = {}
        for _, tag in ipairs(tags) do
            mob_styled[#mob_styled+1] = {style=0, color=tag.colour, bcolor="", text=tag.text}
            padding = padding - #tag.text
        end
        padding = math.max(0, padding)
        for i, s in ipairs(style) do
            if i == 1 then
                s.text = string.gsub(s.text, "^     ", string.rep(" ", padding))
            end
            mob_styled[#mob_styled+1] = convert_one_style(s)
        end
        mobs_in_scanned_room[#mobs_in_scanned_room+1] = mob_styled
    end
end

function scan_empty(name, line, wildcards, style)
    if not running_smart_scan then
        for _, s in ipairs(style) do
            ColourTell(RGBColourToName(s.textcolour),
                       RGBColourToName(s.backcolour), s.text)
        end
        print("")
    end
end

-- ─── ROOMCHARS ────────────────────────────────────────────────────────────────

function roomchars_start()
    mob_count_here = 0
    EnableTrigger("roomchars", true)
end

function roomchars_end()
    EnableTrigger("roomchars", false)
end

function roomchars()
    mob_count_here = mob_count_here + 1
end

-- ─── MOB ACTIVITY TAGS ───────────────────────────────────────────────────────

-- Returns a list of {text, color} tag entries to prepend to a mob's scan line.
-- Tags: [CP], [GQ], [Q] for activity targets.
-- Side-effect: sets activity_target_found_here / target_found_nearby / other_target_found_here.
function mob_activity_tags(mob_name, in_current_room)
    local lower_name = mob_name:lower()
    local tags       = {}
    local cur_zone   = gmcp("room.info.zone") or ""

    -- Check main target list (CP/GQ).
    local on_list = false
    for _, target in ipairs(main_target_list) do
        if (cur_zone == target.arid or target.link_type == "unknown")
        and target.mob:lower() == lower_name then
            on_list = true
            break
        end
    end

    if on_list then
        if in_current_room then
            if has_activity_target()
            and current_target.name:lower() == lower_name then
                activity_target_found_here = true
            else
                other_target_found_here = true
            end
        else
            target_found_nearby = true
        end
        tags[#tags+1] = {text="[",                       colour="gold"}
        tags[#tags+1] = {text=current_activity:upper(),  colour="magenta"}
        tags[#tags+1] = {text="] ",                      colour="gold"}
    end

    -- Check quest target.
    if quest_target and quest_target.mob
    and quest_target.mob:lower() == lower_name
    and quest_target.arid == cur_zone then
        if in_current_room then
            quest_target_found_here = true
        else
            target_found_nearby = true
        end
        tags[#tags+1] = {text="[",  colour="gold"}
        tags[#tags+1] = {text="Q",  colour="magenta"}
        tags[#tags+1] = {text="] ", colour="gold"}
    end

    return tags
end

-- ─── CONSIDER ─────────────────────────────────────────────────────────────────

-- Called by triggers consider_mob_1 … consider_mob_13 (one per CONSIDER_OUTCOMES
-- entry).  The trigger name encodes the 1-based difficulty index so we can look
-- up the matching CON_DETAILS entry without running a string comparison against
-- all 13 patterns at runtime.
--
-- Original MUD line is omitted by the trigger (omit_from_output="y"); this
-- function always reprints with difficulty coloring and activity tags.
function consider_mob_line(name, line, wildcards, style)
    EnableTrigger("consider_end", true)

    -- Parse difficulty index from trigger name: "consider_mob_3" → 3.
    local con_index = tonumber(string.match(name, "consider_mob_(%d+)"))
    if not con_index then return end

    local details = CON_DETAILS[con_index]
    if not details then return end

    local mob_name_raw = Trim(wildcards.mob_name or "")
    if mob_name_raw == "" then return end
    -- Strip leading flags for storage and activity matching; keep raw for display.
    local mob_name = strip_mob_flags(mob_name_raw)

    write_mob_list_to_db({ mob_name })

    -- Check activity membership; sets activity_target_found_here side-effect.
    local tags = mob_activity_tags(mob_name, true)

    -- In smart noscan mode only report mobs that are on the activity list.
    if con_after_scan and #tags == 0 then return end

    local cur_arid    = gmcp("room.info.zone") or ""
    local level_guess = mob_guess_level(mob_name:lower(), cur_arid, details)

    -- ── Print line: [TAGS] mob_name   <level range>  [Lv N] ─────────────────
    local tag_len = 0
    for _, tag in ipairs(tags) do
        ColourTell(tag.colour, "", tag.text)
        tag_len = tag_len + #tag.text
    end
    -- Left pad to column 5 (aligns mob name with untagged lines).
    local pad = string.rep(" ", math.max(0, 5 - tag_len))
    ColourTell("silver", "", pad .. mob_name_raw)
    -- Pad to column 32 (at least 2 spaces) before the level range.
    local spacer = string.rep(" ", math.max(2, 32 - #mob_name_raw))
    local con_color = snd_get_setting("color_con_" .. con_index, details.color)
    ColourTell(con_color, "", spacer .. details.level_range)
    if level_guess then
        ColourNote("silver", "", "  [Lv " .. level_guess .. "]")
    else
        print("")
    end
end

-- True while a consider is running in smart-noscan mode, where only mobs on
-- the activity list should be reported.
--
-- con_after_scan is a chunk-local, so the XML script block cannot see it: a
-- `local` is not visible outside the file it is declared in, and referencing
-- the name there resolves to a nil global instead. consider_unkillable lives
-- in the XML and guarded on it directly, so that guard silently never fired
-- and unkillable mobs were printed even when filtered out everywhere else.
function con_smart_filter_active()
    return con_after_scan == true
end

function consider_end()
    if con_after_scan then
        con_after_scan = false
        if not activity_target_found_here then
            InfoNote("SnD: Consider finished; target not visible here.")
        end
    end
    EnableTrigger("consider_end", false)
    EnableTrigger("consider_end_empty", false)
end

function xset_con_overwrite(name, line, wildcards)
    local cur = snd_get_setting("con_overwrite", "on")
    local new = (cur == "on") and "off" or "on"
    snd_set_setting("con_overwrite", new, false)
    toggle_con_overwrite_triggers()
    InfoNote("SnD: Consider overwrite is now " .. string.upper(new) .. ".")
end

function toggle_con_overwrite_triggers()
    local on = snd_get_setting("con_overwrite", "on") == "on"
    -- "consider" is the group the XML actually defines for the 15 triggers
    -- that capture and re-render consider output.  The previous name here,
    -- "consider_overwrite", matches no trigger, and EnableTriggerGroup is
    -- silent about that -- so the setting saved, announced itself, and did
    -- nothing.  Turning it off now lets the game's own output through.
    EnableTriggerGroup("consider", on)
end

-- ─── SOUND ────────────────────────────────────────────────────────────────────
--
-- The sound files ship with the plugin, in a sounds/ folder.  They used to be
-- expected loose in the MUSHclient base directory and fetched at runtime by a
-- download_sounds() that was never called -- and could not have worked if it
-- had been, since it built its file list from two variables that were never
-- assigned and wrote to a different directory than playback read from.  So
-- sound was a documented, help-indexed feature that could not work on any
-- install.  That code is gone; these resolve against what is actually shipped.

-- Where the plugin itself lives, then the bootstrap's module directory.  A
-- manual install keeps sounds/ beside the .xml; a bootstrap install has them
-- under snd_modules/.  Resolved once and remembered.
local _sound_dir = nil

local function sound_path(filename)
    if _sound_dir then return _sound_dir .. filename end
    local candidates = {
        GetPluginInfo(GetPluginID(), 20) .. "sounds/",
        GetInfo(60) .. "snd_modules/sounds/",
        GetInfo(60) .. "sounds/",
    }
    for _, dir in ipairs(candidates) do
        local f = io.open(dir .. filename, "rb")
        if f then
            f:close()
            _sound_dir = dir
            return dir .. filename
        end
    end
    return nil
end

-- Plays a shipped sound, or says why it cannot -- once, not on every scan.
local _sound_warned = false
local function play_sound(filename)
    if snd_get_setting("sound_onoff", "off") ~= "on" then return end
    local path = sound_path(filename)
    if not path then
        if not _sound_warned then
            _sound_warned = true
            ErrorNote("SnD: cannot find ", filename, " -- the sounds/ folder ",
                      "is missing from your install. Turn sound off with ",
                      "'xset sound' or reinstall to restore it.")
        end
        return
    end
    PlaySound(0, path)
end

function play_target_found_sound()
    play_sound("target_nearby.wav")
end

function play_target_nearby_sound()
    play_sound("target_nearby.wav")
end

function play_other_target_here_sound()
    play_sound("other_target_here.wav")
end

function xset_sound(name, line, wildcards)
    local cur = snd_get_setting("sound_onoff", "off")
    local new = (cur == "on") and "off" or "on"
    snd_set_setting("sound_onoff", new, true)
    InfoNote("SnD: Sounds are now " .. string.upper(new) .. ".")
end

-- ─── TRIGGER / ALIAS SETUP ───────────────────────────────────────────────────

function setup_scan_con_triggers()
    toggle_con_overwrite_triggers()
end
