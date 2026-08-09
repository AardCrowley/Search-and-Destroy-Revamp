-- constants.lua
-- Read-only data only. No functions. No DB access. No side effects on load.
-- Loaded first in the module chain; everything else may depend on these values.

-- ─── VERSION ──────────────────────────────────────────────────────────────────

-- Target database schema version for this release.
SCHEMA_VERSION = 7

PLUGIN_VERSION = GetPluginInfo(GetPluginID(), 19)

-- ─── PLUGIN IDs ───────────────────────────────────────────────────────────────

-- MUSHclient plugin ID for the GMCP Handler (used by gmcp() and send_gmcp_packet()).
PLUGIN_ID_GMCP_HANDLER = "3e7dedbe37e44942dd46d264"

-- MUSHclient plugin ID for the Aardwolf Mapper (used for room lookups).
PLUGIN_ID_MAPPER = "b6eae87ccedd84f510b74714"

-- MUSHclient plugin ID for the Aardwolf Theme Controller.
-- Plugins declare theme-awareness by requiring mw_theme_base, which registers
-- the Theme.b9315e040989d3f81f4328d6 detection function in the plugin scope.
PLUGIN_ID_THEME_CONTROLLER = "b9315e040989d3f81f4328d6"

-- MUSHclient plugin ID for the Repaint Buffer.
-- Call buffered_repaint() (util.lua) after every miniwindow draw operation.
PLUGIN_ID_REPAINT_BUFFER = "abc1a0944ae4af7586ce88dc"

-- MUSHclient plugin ID for the Miniwindow Z-Order Monitor.
-- All miniwindows must register on creation and handle msg=996 re-register.
PLUGIN_ID_Z_ORDER_MONITOR = "462b665ecb569efbf261422f"

-- MUSHclient plugin ID for the Aardwolf Layout plugin.
-- Check GetPluginVariable(PLUGIN_ID_LAYOUT, "lock_down_miniwindows") before
-- allowing drag/resize operations.
PLUGIN_ID_LAYOUT = "c293f9e7f04dde889f65cb90"

-- ─── NOTE COLORS ──────────────────────────────────────────────────────────────
-- Color pairs used by InfoNote, ErrorNote, ImportantNote, DebugNote.
-- Each entry is a foreground hex color; backgrounds default to "" (transparent)
-- unless a *_BACKGROUND key is provided.

NOTE_COLORS = {
    INFO                 = "#FF5000",
    INFO_HIGHLIGHT       = "#00B4E0",
    IMPORTANT            = "#FFFFFF",
    IMPORTANT_HIGHLIGHT  = "#00FF00",
    IMPORTANT_BACKGROUND = "#000080",
    ERROR                = "#FFFFFF",
    ERROR_HIGHLIGHT      = "#FFE32E",
    ERROR_BACKGROUND     = "#650101",
    DEBUG                = "#87CEFA",
    DEBUG_HIGHLIGHT      = "#FFD700",
}

-- ─── TEXT COLOR DETAILS ───────────────────────────────────────────────────────
-- Ordered list of color slot definitions used by the target-list window and the
-- xset color settings UI.  Each entry has:
--   key       : the settings table name (maps to a color_<key> setting)
--   default   : the default hex color value
--   menu_name : label shown in the settings UI
--   desc      : longer description shown in help text

TEXT_COLOR_DETAILS = {
    {
        key       = "normal",
        default   = "#E0E0E0",
        menu_name = "Normal mobs",
        desc      = "normal mobs",
    },
    {
        key       = "targeted",
        default   = "#FF4000",
        menu_name = "Targeted mob",
        desc      = "the currently targeted mob",
    },
    {
        key       = "dead",
        default   = "#484848",
        menu_name = "Dead mobs",
        desc      = "dead mobs",
    },
    {
        key       = "unknown",
        default   = "#FF0000",
        menu_name = "Unknown mobs",
        desc      = "mobs in an unknown area",
    },
    {
        key       = "unknown_dead",
        default   = "#900000",
        menu_name = "Unknown dead mobs",
        desc      = "dead mobs in an unknown area",
    },
    {
        key       = "unlikely",
        default   = "#484848",
        menu_name = "Unlikely mobs",
        desc      = "mobs that are not likely to be the target in a room-based campaign or global quest",
    },
    {
        key       = "unlikely_tag",
        default   = "#0000CD",
        menu_name = "Unlikely tag",
        desc      = "the tag beside unlikely mobs",
    },
    {
        key       = "quest_available",
        default   = "#1E90FF",
        menu_name = "Quest available",
        desc      = "the text informing you that you have a quest available",
    },
    {
        key       = "quest_complete",
        default   = "#7CFC00",
        menu_name = "Quest complete",
        desc      = "the text informing you that you have a quest to turn in",
    },
    {
        key       = "quest_waiting",
        default   = "#FF7A7A",
        menu_name = "Next quest time",
        desc      = "the next quest timer when you are waiting for your next quest",
    },
    {
        key       = "alternating_row",
        default   = "#0C0C1A",
        menu_name = "Alternating Row Backgrounds",
        desc      = "the background color on alternating rows of the targets list in the mud window. Set it to black to disable",
    },
}

-- ─── HISTORY TYPE ENUMS ───────────────────────────────────────────────────────

HISTORY_TYPE_QUEST = 1   -- standard quest
HISTORY_TYPE_GQ    = 2   -- global quest
HISTORY_TYPE_CP    = 3   -- campaign

-- ─── HISTORY STATUS ENUMS ─────────────────────────────────────────────────────

HISTORY_STATUS_IN_PROGRESS = 1
HISTORY_STATUS_COMPLETE    = 2
HISTORY_STATUS_TIMEOUT     = 3
HISTORY_STATUS_FAILED      = 4
HISTORY_STATUS_RESET       = 5
HISTORY_STATUS_SKIPPED     = 6

-- ─── SCAN FLAGS ───────────────────────────────────────────────────────────────
-- Mob/player state flags that appear in scan output alongside mob names.

SCAN_FLAGS = {
    -- Player flags
    "P", "Player", "OPK", "Linkdead", "WANTED", "HARDCORE",
    "Raider", "Traitor",
    -- Mob flags
    "Animated", "A",
    "Angry",
    "Charmed",  "C",
    "Diseased", "D",
    "Flying",   "F",
    "Golden Aura", "G",
    "Hidden",   "H",
    "Invis",    "I",
    "Marked",   "X",
    "Red Aura", "R",
    "Stealth",  "S",
    "Translucent", "T",
    "Undead",   "U",
    "White Aura", "W",
    "Wounded",
    "Aimed",
    "Old",      "O",
}

-- ─── CONSIDER OUTCOMES ────────────────────────────────────────────────────────
-- Ordered patterns for the 'consider' command output, weakest mob first.
-- Each pattern must contain a named capture (?<mob_name>...).
-- Used by scanning.lua to parse consider results.

CONSIDER_OUTCOMES = {
    "You would stomp (?<mob_name>.+?) into the ground\\.$",
    "(?<mob_name>.+?) would be easy, but is it even worth the work out\\?$",
    "No Problem! (?<mob_name>.+?) is weak compared to you\\.$",
    "(?<mob_name>.+?) looks a little worried about the idea\\.$",
    "(?<mob_name>.+?) should be a fair fight!$",
    "(?<mob_name>.+?) snickers nervously\\.$",
    "(?<mob_name>.+?) chuckles at the thought of you fighting \\S+\\.$",
    "Best run away from (?<mob_name>.+?) while you can!$",
    "Challenging (?<mob_name>.+?) would be either very brave or very stupid\\.$",
    "(?<mob_name>.+?) would crush you like a bug!$",
    "(?<mob_name>.+?) would dance on your grave!$",
    "(?<mob_name>.+?) says 'BEGONE FROM MY SIGHT unworthy\\!'$",
    "You would be completely annihilated by (?<mob_name>.+?)!$",
}

-- ─── CONSIDER DIFFICULTY DETAILS ─────────────────────────────────────────────
-- Parallel to CONSIDER_OUTCOMES (index 1–13). Maps each consider outcome to a
-- display color and a human-readable level-range label.
-- min_modifier / max_modifier are approximate mob-level offsets relative to the
-- player's level; used by future level-guessing logic.

CON_DETAILS = {
    { level_range = "-20 and below", color = "cornflowerblue",    min_modifier = -201, max_modifier = -20 }, -- -201 sentinel = no lower bound
    { level_range = "-19 to -10",    color = "deepskyblue",       min_modifier = -19,  max_modifier = -10 },
    { level_range = "-9 to -5",      color = "turquoise",         min_modifier = -9,   max_modifier = -5  },
    { level_range = "-4 to -2",      color = "mediumspringgreen", min_modifier = -4,   max_modifier = -2  },
    { level_range = "-1 to +1",      color = "lime",              min_modifier = -1,   max_modifier = 1   },
    { level_range = "+2 to +4",      color = "lawngreen",         min_modifier = 2,    max_modifier = 4   },
    { level_range = "+5 to +9",      color = "limegreen",         min_modifier = 5,    max_modifier = 9   },
    { level_range = "+10 to +15",    color = "greenyellow",       min_modifier = 10,   max_modifier = 15  },
    { level_range = "+16 to +20",    color = "#EFF22D",           min_modifier = 16,   max_modifier = 20  },
    { level_range = "+21 to +30",    color = "gold",              min_modifier = 21,   max_modifier = 30  },
    { level_range = "+31 to +40",    color = "darkorange",        min_modifier = 31,   max_modifier = 40  },
    { level_range = "+41 to +50",    color = "orangered",         min_modifier = 41,   max_modifier = 50  },
    { level_range = "+51 and above", color = "red",               min_modifier = 51,   max_modifier = 250 },
}
