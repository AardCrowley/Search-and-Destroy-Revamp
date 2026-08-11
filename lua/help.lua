-- help.lua
-- Attractive, hyperlinked help system for Search & Destroy.
-- Replaces the monolithic onHelp() if/elseif chain in the XML script block.
-- Depends on: util.lua (helpWrap)
--
-- Content is stored as a plain Lua table (TOPICS) rather than a separate JSON
-- file.  Help content is tightly coupled to the code and changes with it;
-- external JSON makes more sense for shared/authored data like areas.json.
-- If you want to edit help text, just edit the TOPICS table below.

-- ─── DISPLAY CONSTANTS ───────────────────────────────────────────────────────

local COL          = 76     -- content column width (fits 80-col terminal)

-- Color palette (hex strings for ColourTell / ColourNote)
local C_SEP        = "#404040"    -- dim separator lines
local C_HDR_LABEL  = "#808080"    -- "SEARCH & DESTROY" prefix
local C_HDR_TOPIC  = "#00D4FF"    -- topic name in header
local C_SYNTAX_LBL = "#A0A0A0"    -- "Syntax" label
local C_SYNTAX     = "#FFD700"    -- syntax text
local C_SECTION    = "#7CFC00"    -- section headings
local C_BODY       = "#D0D0D0"    -- body text
local C_LINK       = "#00E5FF"    -- hyperlink text
local C_NEW        = "#FF6030"    -- "NEW" badge
local C_CAT        = "#FF8C00"    -- category headers on index page

local C_SUMMARY    = "#909090"    -- one-line summary on index page

local HR   = string.rep("─", COL)
local HR2  = string.rep("═", COL)

-- ─── TOPIC DATA ──────────────────────────────────────────────────────────────
-- Each topic is a table with:
--   key      : primary lookup key  (required)
--   aliases  : alternative keys that also match this topic  (optional)
--   category : group label shown on the index page  (required)
--   syntax   : array of syntax line strings  (optional)
--   summary  : one-line description used on the index page  (required)
--   new_in   : version string shown as a badge, e.g. "v6"  (optional)
--   sections : array of { heading=, text= } paragraphs  (required)
--   see_also : array of topic keys for clickable cross-references  (optional)

local TOPICS = {

    -- ── WINDOW & DISPLAY ────────────────────────────────────────────────────

    {
        key      = "win",
        aliases  = { "xset window", "xset fontsize", "xset linespace" },
        category = "Window & Display",
        syntax   = {
            "xset win <on|off|show|hide>",
            "xset win <max[imize]|min[imize]|expand|collapse>",
            "xset winreset",
        },
        summary  = "Show, hide, resize, or reset the S&D miniwindow.",
        sections = {
            {
                heading = "xset win  on/off/show/hide",
                text    = "Toggles the Search & Destroy miniwindow. 'on' and 'show' are synonyms; 'off' and 'hide' are synonyms.",
            },
            {
                heading = "xset win  max / expand  |  min / collapse",
                text    = "Expands or collapses the window between its normal and minimized state.",
            },
            {
                heading = "xset winreset",
                text    = "If the window disappears off-screen or becomes unresponsive to 'xset win on', this command resets it to a default position in the center of your screen.",
            },
            {
                heading = "xset fontsize  |  xset linespace",
                text    = "Both are reminders rather than settings. Font size in the targets window is controlled by MUSHclient itself: right-click the window's title bar and choose 'Change Font'. Line spacing follows from the font you pick and is not separately adjustable.",
            },
        },
        see_also = { "silent", "sound" },
    },

    {
        key      = "silent",
        category = "Window & Display",
        syntax   = { "xset silent <on|off>" },
        summary  = "Toggle printing the target list in the main MUD window.",
        sections = {
            {
                text = "When silent mode is on, campaign and global-quest target lists are only shown in the miniwindow and are suppressed from the main output window. Useful if you find the main-window list redundant.",
            },
        },
        see_also = { "win", "cp|gq" },
    },

    {
        key      = "sound",
        category = "Window & Display",
        syntax   = { "xset sound" },
        summary  = "Toggle audible alerts when a target enters your vicinity.",
        sections = {
            {
                text = "Toggles sound alerts.  A sound fires when a scanned mob is found in a nearby room (determined by scan output), or when a non-current target from your campaign or gquest list is in the same room as you.  The soundpack plugin must also be enabled for full functionality.",
            },
            {
                heading = "Where the sounds live",
                text    = "The two sound files ship with the plugin in a 'sounds' folder next to Search_and_Destroy.xml. Nothing is downloaded at runtime. If that folder is missing, the first alert says so once and then stays quiet rather than complaining on every scan -- reinstall to restore it, or turn sound back off."
            },
        },
        see_also = { "qs", "win" },
    },

    {
        key      = "xset table notes",
        aliases  = { "table notes" },
        category = "Window & Display",
        syntax   = { "xset table notes" },
        summary  = "Show room notes inline in the room results table.",
        sections = {
            {
                text = "When enabled, room notes are shown directly in the room-search results table, up to the available column width.  Use 'xset table width' to control how wide that column is.",
            },
        },
        see_also = { "xset table width", "xm|xmall|rlh" },
    },

    {
        key      = "xset table width",
        aliases  = { "table width" },
        category = "Window & Display",
        syntax   = { "xset table width <number>" },
        summary  = "Set the width of the room-search results table (80–150).",
        sections = {
            {
                text = "Sets the column width for room-search result tables to the given number, which must be between 80 and 150.  Wider tables show more of room notes when 'xset table notes' is enabled.",
            },
        },
        see_also = { "xset table notes" },
    },

    {
        key      = "xset rlink",
        aliases  = { "rlink" },
        category = "Window & Display",
        syntax   = {
            "xset rlink",
            "xset rlink <room1> <room2>",
            "xset rlink <room1> <room2> {note}",
        },
        summary  = "Configure room links that annotate the CP/GQ target list.",
        sections = {
            {
                heading = "xset rlink",
                text    = "Lists all configured room links.",
            },
            {
                heading = "xset rlink <room1> <room2>",
                text    = "Toggles a link between two room IDs.  If the link already exists it is removed; if it does not exist it is added.  Room IDs come from the mapper — use 'mapper where' or 'xm <name>' to find them.",
            },
            {
                heading = "xset rlink <room1> <room2> {note}",
                text    = "Adds or updates a link with an annotation note.  The note appears in curly braces next to any CP/GQ target whose shortest path passes through this link — useful for marking maze entrances, portal rooms, or other notable traversals.",
            },
        },
        see_also = { "xm|xmall|rlh", "xcp" },
    },

    -- ── NAVIGATION ──────────────────────────────────────────────────────────

    {
        key      = "xrt|xrun",
        aliases  = { "xrt", "xrun",
            "xrunto",
        },
        category = "Navigation",
        syntax   = {
            "xrt <area keyword>",
            "xrun <area keyword>",
        },
        summary  = "Run to the start room of an area by keyword.",
        sections = {
            {
                text = "Runs you to the designated start room of the named area.  If a start room has been set with 'xset mark', it runs there directly; otherwise it uses the mapper's area portal.",
            },
        },
        see_also = { "xset mark", "xset speed", "xcp" },
    },

    {
        key      = "xset speed",
        aliases  = { "speed" },
        category = "Navigation",
        syntax   = { "xset speed <walk|run>" },
        summary  = "Display or change the movement speed used by the mapper.",
        sections = {
            {
                text = "Without an argument, shows the current movement speed.  With 'walk', the mapper moves without using portals.  With 'run', it uses portals where available (faster but may skip scenic routes).",
            },
        },
        see_also = { "xrt|xrun", "nx" },
    },

    {
        key      = "nx",
        category = "Navigation",
        syntax   = {
            "nx        (next room in list)",
            "nx-       (previous room in list)",
        },
        summary  = "Step to the next or previous room in the current search results.",
        sections = {
            {
                text = "Moves you to the next (or with '-', the previous) room in the active room search result list.  The action taken on arrival is controlled by 'xset nx'.",
            },
        },
        see_also = { "go", "xset nx", "xm|xmall|rlh" },
    },

    {
        key      = "go",
        category = "Navigation",
        syntax   = {
            "go          (first room in list)",
            "go <index>  (jump to index number)",
        },
        summary  = "Jump to a specific room in the current search results by index.",
        sections = {
            {
                text = "Runs you to room #1 in the active result list, or to the room at the specified index number.  The action taken on arrival is controlled by 'xset nx'.",
            },
        },
        see_also = { "nx", "xset nx" },
    },

    {
        key      = "xset nx",
        category = "Navigation",
        syntax   = { "xset nx <smartscan|con|scan|scanhere|qs|none>" },
        summary  = "Set the action taken automatically when you arrive via 'nx' or 'go'.",
        sections = {
            {
                text = "Sets the behavior triggered when you arrive at a room via nx or go.  Without an argument, displays the current setting.  Options:",
            },
            {
                heading = "smartscan",
                text    = "Scan for your targets only.  Falls back to 'con' when a potential noscan target is detected in the room.",
            },
            {
                heading = "con",
                text    = "Run the 'consider' command on everything in the room.",
            },
            {
                heading = "scan",
                text    = "Perform a full room scan.",
            },
            {
                heading = "scanhere",
                text    = "Scan only the current room (no adjacent rooms).",
            },
            {
                heading = "qs",
                text    = "Quick-scan: look only for your current target mob, skipping everything else.",
            },
            {
                heading = "none",
                text    = "Do nothing on arrival.",
            },
        },
        see_also = { "nx", "go", "qs" },
    },

    {
        key      = "xmap",
        aliases  = { "xmapper", "xmapper move", "xmapper rlh", "xmap rlh" },
        category = "Navigation",
        syntax   = { "xmap move <roomID> <walk|run>" },
        summary  = "Move directly between rooms by room ID.",
        sections = {
            {
                text = "Runs you to the specified room ID at the given speed.  Without an explicit speed argument, uses the current default speed (see 'xset speed').",
            },
        },
        see_also = { "xset speed", "xrt|xrun" },
    },

    {
        key      = "xm|xmall|rlh",
        aliases  = { "xm", "xmall", "rlh" },
        category = "Navigation",
        syntax   = {
            "xm <room name>       (search in current area)",
            "xmall <room name>    (search across all areas)",
            "xm rlh <roomID>      (show rooms that link to a room)",
        },
        summary  = "Search for rooms by name, or list rooms linking to a given room.",
        sections = {
            {
                heading = "xm <room name>",
                text    = "Searches for rooms by name within the current area.  Partial names are matched.  Use '%' as a wildcard to list every room in the area.",
            },
            {
                heading = "xmall <room name>",
                text    = "As above, but searches across all mapped areas.  Avoid using '%' here — it will return every room in your mapper database.",
            },
            {
                heading = "xm rlh <roomID>",
                text    = "Without an argument, shows all rooms that contain an exit leading to your current room.  With a room ID, shows the same for that room.  Output includes room ID, room name, and zone.",
            },
        },
        see_also = { "nx", "go", "xset table notes" },
    },

    -- ── SCANNING & HUNTING ───────────────────────────────────────────────────

    {
        key      = "qw",
        category = "Scanning & Hunting",
        syntax   = {
            "qw           (where current target)",
            "qwx          (where current target, exact match)",
            "qw <mob>     (where supplied mob name)",
            "qwx <mob>    (where supplied mob name, exact match)",
        },
        summary  = "Send the 'where' command for your current target or a named mob.",
        sections = {
            {
                text = "Sends the game 'where' command using the keyword of your current campaign, gquest, or quest target.  Append 'x' for an exact keyword match.  You can also supply a mob name directly as an argument to bypass the stored target.",
            },
        },
        see_also = { "ht", "qs", "xcp mode" },
    },

    {
        key      = "ht",
        aliases  = { "ht abort", "ht0", "hta" },
        category = "Scanning & Hunting",
        syntax   = {
            "ht          (hunt current target)",
            "ht <mob>    (hunt named mob)",
            "ht stop     (stop hunt trick)",
        },
        summary  = "Perform the 'hunt trick' for your current target or a named mob.",
        sections = {
            {
                text = "Executes the hunt trick on your current campaign target, or on the mob name supplied as an argument.  The hunt trick uses successive 'hunt' commands to move toward the mob.  Type 'ht stop' to abort — note that this may not work if the mob has a keyword of 'stop'.",
            },
        },
        see_also = { "ah|aha", "qw", "xcp mode" },
    },

    {
        key      = "ah|aha",
        aliases  = { "ah", "aha",
            "ah0",
        },
        category = "Scanning & Hunting",
        syntax   = {
            "ah       (start auto-hunt on current target)",
            "aha      (abort auto-hunt)",
        },
        summary  = "Automatically follow hunt directions until you find the target.",
        sections = {
            {
                text = "Repeatedly sends 'hunt' and follows the indicated direction until the target is reached or hunting is aborted with 'aha'.  Useful for chasing mobs through mazes.  Requires the 'hunt' skill to be practiced.",
            },
        },
        see_also = { "ht", "qw" },
    },

    {
        key      = "ak|kk|qk",
        aliases  = { "ak", "kk", "qk",
            "quick kill",
            "xset qkill",
            "xset kk",
            "xset ak",
            "xset qk",
        },
        category = "Scanning & Hunting",
        syntax   = {
            "ak / kk / qk               (execute quick-kill sequence)",
            "xset kk <cmd1>;;cmd2;;...  (set the kill sequence)",
        },
        summary  = "Set or execute a quick-kill command sequence on your current target.",
        sections = {
            {
                text = "The 'xset kk' command stores a sequence of combat commands that can be fired instantly with 'ak', 'kk', or 'qk'.  Separate commands with ';;' (or start the line with ';' and use single semicolons).  Example:  xset kk backstab;;bash;;slap",
            },
            {
                heading = "notarg",
                text    = "Append 'notarg' to any individual command to execute it without appending the target keyword.  Example: 'xset kk backstab;;spiral notarg' becomes 'backstab guard;spiral' when your target is 'guard'.",
            },
        },
        see_also = { "ht", "qw" },
    },

    {
        key      = "qs",
        category = "Scanning & Hunting",
        syntax   = { "qs" },
        summary  = "Scan for your current campaign/gquest/quest target in the room.",
        sections = {
            {
                text = "Performs a scan looking specifically for your current target mob.  Results are stored in the mob database for future room lookups.",
            },
        },
        see_also = { "xset nx", "qw" },
    },

    {
        key      = "ms",
        aliases  = { "mobsearch", "xms", "xmobsearch", "mob search" },
        category = "Scanning & Hunting",
        syntax   = {
            "ms <mob>                   search all areas",
            "ms here <mob>              search current area",
            "ms <areakey> <mob>         search a specific area by key",
            "ms <mob> <level>           filter results by level proximity",
            "ms <areakey> <mob> <level> combine area and level filters",
            "xmgo <#>                   navigate to result #",
        },
        summary  = "Search the mob database by name, area, and level.",
        new_in   = "v6",
        sections = {
            {
                text = "Searches mobs you have previously seen while scanning rooms.  Results include the room name, area key, area level range, and kill count, sorted by kills then sightings.",
            },
            {
                heading = "Location filter",
                text    = "Use 'here' to limit results to the current area.  Use an exact area key (e.g. 'galadon') to limit to a specific area.  If the first word you type is not 'here' and does not exactly match a known area key, the entire input is treated as the mob name.",
            },
            {
                heading = "Level filter",
                text    = "Append a number to filter by level.  S&D accepts areas whose level range overlaps ±5 of the number you give.  For example, 'ms hawk 120' returns hawks in areas that include level 115–125.",
            },
            {
                heading = "Navigating results",
                text    = "After a search the row numbers are clickable — clicking any row navigates directly to that room.  You can also type 'xmgo <#>' to go to result number N.",
            },
            {
                heading = "Why no results?",
                text    = "Mob data is recorded passively when you scan rooms.  If you have never scanned an area, its mobs will not appear.  Explore and scan new areas to populate the database.",
            },
        },
        see_also = { "qs", "xmobdeaths", "xwhere", "xset mob" },
    },

    {
        key      = "xset con_overwrite",
        category = "Scanning & Hunting",
        syntax   = { "xset con_overwrite" },
        summary  = "Toggle whether S&D replaces the standard 'consider' output.",
        sections = {
            {
                text = "By default, S&D replaces the game's 'consider' output with richer information including target flags.  Toggle this off if you have another plugin that needs to process consider output undisturbed.",
            },
        },
        see_also = { "xset nx" },
    },

    -- ── CAMPAIGN & QUEST ─────────────────────────────────────────────────────

    {
        key      = "cp|gq",
        aliases  = { "cp", "gq", "cpi", "gqi", "cpc", "gqc" },
        category = "Campaign & Quest",
        syntax   = {
            "cp i / cp info    (load campaign info into window)",
            "gq i / gq info    (load gquest info into window)",
            "cp c / cp check   (run 'campaign check')",
            "gq c / gq check   (run 'gquest check')",
        },
        summary  = "Display campaign or global-quest info and load targets into the window.",
        sections = {
            {
                text = "These commands delegate to the game's 'campaign' and 'gquest' commands, while also loading the resulting target list into the S&D miniwindow.  The 'info'/'i' variants load the list; the 'check'/'c' variants run a check.",
            },
        },
        see_also = { "xcp", "xcp mode", "xset gqalias" },
    },

    {
        key      = "xcp",
        category = "Campaign & Quest",
        syntax   = {
            "xcp          (go to first target in list)",
            "xcp <index>  (go to target at index number)",
        },
        summary  = "Navigate to a campaign or gquest target by index.",
        sections = {
            {
                text = "Without an argument, navigates to the first un-killed mob in the miniwindow list.  With an index number, goes to that specific target.  The action taken after arriving (hunt, where, nothing) is set by 'xcp mode'.",
            },
        },
        see_also = { "xcp mode", "xcp quest", "cp|gq" },
    },

    {
        key      = "xcp mode",
        category = "Campaign & Quest",
        syntax   = { "xcp mode <ht|qw|off>" },
        summary  = "Set the action taken after arriving at an xcp target location.",
        sections = {
            {
                text = "Without an argument, shows your current mode.  With an argument, sets the default action after 'xcp' navigation completes:",
            },
            {
                heading = "ht",
                text    = "Automatically start a hunt trick (see 'xhelp ht').",
            },
            {
                heading = "qw",
                text    = "Automatically run 'where' on the mob (see 'xhelp qw').",
            },
            {
                heading = "off",
                text    = "Do nothing — just arrive at the start room of the area.",
            },
        },
        see_also = { "xcp", "ht", "qw" },
    },

    {
        key      = "quest|xcp quest",
        aliases  = { "quest", "xcp quest" },
        category = "Campaign & Quest",
        syntax   = { "xcp quest" },
        summary  = "Toggle targeting your quest mob when xcp is used with no argument.",
        sections = {
            {
                text = "When enabled, 'xcp' with no argument will target your active quest mob rather than the first campaign/gquest entry.  Useful if you want to do quests and campaigns together.",
            },
        },
        see_also = { "xcp", "xq", "xqt" },
    },

    {
        key      = "xq",
        aliases  = { "xq1" },
        category = "Campaign & Quest",
        syntax   = { "xq" },
        summary  = "Reload and display current quest information.",
        sections = {
            {
                text = "Forces a refresh of the current quest data from GMCP and displays it.  Useful if you changed quests or the display seems stale.",
            },
        },
        see_also = { "xqt", "quest|xcp quest" },
    },

    {
        key      = "xqt",
        category = "Campaign & Quest",
        syntax   = { "xqt" },
        summary  = "Retarget the current quest mob (e.g. after using xcp or qw).",
        sections = {
            {
                text = "Re-applies the quest mob as the active target after it may have been displaced by a campaign or gquest navigation command.",
            },
        },
        see_also = { "xq", "quest|xcp quest" },
    },

    {
        key      = "noexp",
        category = "Campaign & Quest",
        syntax   = {
            "xset noexp off     (disable noexp monitoring)",
            "xset noexp <#>     (set TNL threshold to trigger noexp)",
        },
        summary  = "Prevent accidental levelling during campaign levelling.",
        sections = {
            {
                text = "Without an argument, shows the current setting.  With 'off', disables noexp monitoring.  With a number, S&D will automatically toggle 'noexp' on when your TNL drops below that number — preventing accidental level-ups when grinding campaigns.",
            },
        },
        see_also = { "cp|gq" },
    },

    {
        key      = "xset gqalias",
        category = "Campaign & Quest",
        syntax   = { "xset gqalias" },
        summary  = "Enable or disable the shortcut 'qq' and 'gg' aliases.",
        sections = {
            {
                text = "Toggles extra convenience aliases: both 'qq' and 'gg' run 'gquest check'.  Disable if these conflict with other plugins or your own aliases.",
            },
        },
        see_also = { "cp|gq" },
    },

    -- ── DATA & KEYWORDS ──────────────────────────────────────────────────────

    {
        key      = "mgo|mgoto",
        aliases  = { "mgo", "mgoto", "xmgo", "xmgoto" },
        category = "Data & Keywords",
        syntax   = {
            "mgo <index>   (go to mob-search result #index)",
            "xmgo / xmgoto (same, 'x' prefix is optional)",
        },
        summary  = "Navigate to a room from the last mob-search results by index.",
        sections = {
            {
                text = "After running 'ms' or 'msearch', use this command to navigate to the room at the supplied index number from that result list.",
            },
        },
        see_also = { "ms" },
    },

    {
        key      = "kw|keyword",
        aliases  = { "kw", "keyword" },
        category = "Data & Keywords",
        syntax   = {
            "xset kw <keyword>   (set keyword while on target)",
            "xset kw             (interactive keyword dialog)",
        },
        summary  = "Override a mob's target keyword when the default does not work.",
        sections = {
            {
                text = "S&D automatically guesses a keyword for each target mob.  When the guess is wrong (e.g. the mob is 'a yummy beef pot pie' but you need to target 'beef pie'), use 'xset kw beef pie' while that mob is your active target to store the correct keyword.",
            },
            {
                heading = "Interactive mode",
                text    = "Typing 'xset kw' with no argument opens a step-by-step dialog that walks you through selecting the mob and entering the keyword.",
            },
        },
        see_also = { "ms", "xset mob" },
    },

    {
        key      = "express",
        category = "Data & Keywords",
        syntax   = {
            "xset express <on|off>",
            "xset express <min_kill_count>",
        },
        summary  = "Skip the area start room for mobs you reliably find in the same room.",
        sections = {
            {
                text = "Express mode scans your campaign or gquest targets for mobs you have killed in the same room enough times to be confident of their location.  When an 'express' mob is selected, S&D navigates directly to the mob's room instead of the area start room first.",
            },
            {
                heading = "min_kill_count",
                text    = "The minimum number of kills in a single room before a mob is flagged as 'express'.  Increasing this makes the feature more conservative; lowering it makes it more aggressive.",
            },
        },
        see_also = { "xcp", "xset mark" },
    },

    -- ── AREA MANAGEMENT ──────────────────────────────────────────────────────

    {
        key      = "xset mark",
        aliases  = { "mark", "xmark", "xset mark list", "mark list", "xmark list" },
        category = "Area Management",
        syntax   = {
            "xset mark                        (save current room as a mark for this area)",
            "xset mark <name> <roomid>        (save a named room shortcut remotely)",
            "xset start [<areakey> <roomid>]  (set an area's start_room in the area table)",
            "xmark list [filter]              (list all marks, optional keyword filter)",
        },
        summary  = "Save named room shortcuts (marks) used by xrt/xrun for navigation.",
        sections = {
            {
                text = "Marks are named room shortcuts stored in the S&D database.  'xset mark' with no arguments saves your current room under your current area's zone key.  'xset mark <name> <roomid>' stores any room by number under a custom name.  Either way, 'xrt <name>' navigates to that room.",
            },
            {
                heading = "xset start",
                text    = "Sets the start_room column directly in the areas table (the older interface).  Used when S&D knows an area from the JSON index but you want to override its entry point without creating a separate named mark.  'xset start' with no arguments uses your current area and room.",
            },
            {
                heading = "xmark list [filter]",
                text    = "Lists every saved mark.  Pass an optional keyword or partial name to narrow the results: 'xmark list haunt' shows only marks whose name or area contains 'haunt'.",
            },
        },
        see_also = { "xset marks", "xrt|xrun", "xset area", "xset maze" },
    },

    {
        key      = "xset marks",
        aliases  = { "marks" },
        category = "Area Management",
        syntax   = {
            "xset marks                  (list all saved marks)",
            "xset marks <keyword>        (search marks by name, area, or room)",
            "xset marks edit <#>         (edit the name or room ID of mark #)",
            "xset marks delete <#>       (delete mark #)",
            "xset marks del <#>          (same as delete)",
        },
        summary  = "Browse, search, edit, and delete saved marks.",
        new_in   = "v6",
        sections = {
            {
                text = "Manage the full list of saved marks.  'xset marks' lists every mark with an index number.  Use the index numbers with the edit and delete sub-commands.",
            },
            {
                heading = "Searching",
                text    = "Typing a keyword after 'xset marks' filters by mark name, area name, room name, or room ID — all case-insensitive.  The index numbers shown in filtered results are global (same as in the full list), so they work correctly with edit and delete.",
            },
            {
                heading = "Editing",
                text    = "Opens two input dialogs to update the mark's name and room ID.  If you are standing in the room when you edit, the area and room name are refreshed automatically from GMCP.",
            },
        },
        see_also = { "xset mark", "xrt|xrun" },
    },

    {
        key      = "xset maze",
        aliases  = { "maze", "xset maze list", "maze list", "xset maze del", "maze del" },
        category = "Area Management",
        syntax   = {
            "xset maze            (toggle current room as a maze entrance)",
            "xset maze list       (list all saved maze entrances)",
            "xset maze del <id>   (remove maze entrance by room ID)",
        },
        summary  = "Mark a room as a maze entrance so it sorts first in search results.",
        sections = {
            {
                text = "Toggles the current room as the entrance to a maze-type area.  When a mob is found in a room with the same name as a registered maze entrance, that maze room is sorted to the top of your search results — so S&D sends you to the correct starting point instead of a random room with that name.",
            },
            {
                heading = "xset maze list",
                text    = "Prints all saved maze entrances with their room ID, zone key, and area name.",
            },
            {
                heading = "xset maze del <roomID>",
                text    = "Removes the maze entrance record for the given room ID from the database.",
            },
        },
        see_also = { "xset mark", "xset area" },
        new_in   = "v6",
    },

    {
        key      = "xset area",
        category = "Area Management",
        syntax   = {
            "xset area list                           (list user-added/imported areas)",
            "xset area list unset                     (list areas missing a start room)",
            "xset area del <key>                      (remove a custom area entry)",
            "xset area edit <key> start <roomid>      (set start room)",
            "xset area edit <key> min <level>         (set minimum level)",
            "xset area edit <key> max <level>         (set maximum level)",
            "xset area edit <key> lock <level>        (set lock level)",
            "xset area edit <key> difficulty <1-5>    (set area difficulty rating)",
            "xset area edit <key> noquest <on|off>    (mark area as no-quest)",
            "xset area edit <key> vidblain <on|off>   (mark area as vidblain-style)",
            "xset area edit <key> name <text>         (rename the area)",
        },
        summary  = "View and edit area records you have added or customized.",
        sections = {
            {
                text = "Manages area entries that you have created or imported (source = 'scrape' or 'stub').  Areas seeded from the official areas.json are read-only and cannot be deleted or renamed here.",
            },
            {
                heading = "xset area list",
                text    = "Shows all non-JSON area entries with their key, name, level range, lock level, and current start room.",
            },
            {
                heading = "xset area list unset",
                text    = "Lists areas of any source that have no start room set (start room = -1 or unset), excluding clan areas (210-210) and non-player areas (0-0) which do not have accessible entry points.  Scrape-added areas appear in blue; stub entries (auto-created from mob data) appear in orange.  Use 'xset mark' after visiting an area to set its start room.",
            },
            {
                heading = "xset area del <key>",
                text    = "Permanently removes the area entry with that key.  Will refuse to delete a JSON-seeded area.",
            },
            {
                heading = "xset area edit <key> ...",
                text    = "Edits one field of a custom area record.  'start' sets the preferred start room by room ID.  'min' and 'max' set the level range used for tier-adjusted area matching.  'difficulty' sets a 1–5 rating used to prioritize this area during CP route planning — lower numbers are visited first.  'noquest on' marks the area as ineligible for campaign/GQ targets.  'vidblain on' marks it as a Vidblain-style area.",
            },
        },
        see_also = { "xset mark", "xset index", "xset maze" },
        new_in   = "v6",
    },

    {
        key      = "xset mob",
        aliases  = {
            "mob",
            "mob noaction",   "xset mob noaction",
            "mob nowhere",    "xset mob nowhere",
            "mob nohunt",     "xset mob nohunt",
            "mob noscan",     "xset mob noscan",
            "mob express",    "xset mob express",
            "mob priority",   "xset mob priority",
            "mob unpriority", "xset mob unpriority",
            "mob tags",       "xset mob tags",
            "mob clearflags", "xset mob clearflags",
            "mob difficulty", "xset mob difficulty",
            "mob levelok",    "xset mob levelok",
        },
        category = "Area Management",
        syntax   = {
            "xset mob noaction <mob>           (toggle: set nowhere + nohunt + noscan all at once)",
            "xset mob nowhere <mob>            (toggle: mob can't be found via 'where')",
            "xset mob nohunt <mob>             (toggle: mob can't be hunted)",
            "xset mob noscan <mob>             (toggle: mob not visible in scan output)",
            "xset mob express                         (toggle express for current target in this room)",
            "xset mob express <mob>                   (toggle express for named mob in current zone)",
            "xset mob express <mob> here              (same as above — explicit current room)",
            "xset mob express <mob> <roomid>          (toggle express for named mob in specific room)",
            "xset mob priority <mob>           (set current room as priority for mob)",
            "xset mob unpriority <mob>         (clear priority room for mob)",
            "xset mob difficulty                      (show current target's rating)",
            "xset mob difficulty <0-5>                (rate current target; 0 clears)",
            "xset mob difficulty <0-5> <mob>          (rate a named mob in current zone)",
            "xset mob levelok <mob>            (toggle: mob is valid here despite zone level range)",
            "xset mob tags [zone]              (list all mob flags in current/named zone)",
            "xset mob clearflags <mob>         (remove all flags for a mob)",
        },
        summary  = "Tag mobs with behavior flags: hide them, skip hunt, or pin their room.",
        sections = {
            {
                heading = "noaction",
                text    = "Convenience toggle that sets the nowhere, nohunt, and noscan flags all at once.  Useful for mobs that share a name across many room IDs and cannot be located by any of the three methods — for example, a mob with six different key IDs all spawning in rooms named 'Battlefields of Faith'.  If all three flags are already on, the command turns them all off.  To toggle the flags individually, use the separate nowhere, nohunt, and noscan subcommands.",
            },
            {
                heading = "nowhere",
                text    = "Marks this mob as 'nowhere' in the current zone.  Mobs tagged nowhere do not appear in 'where <mob>' output — the server returns no results for them.  The mob is still a valid target and stays in the target list; S&D simply skips the where step and routes to the area normally.  Use this to prevent endless where cycling for mobs that must be found by scan or con on arrival.",
            },
            {
                heading = "nohunt",
                text    = "Marks this mob as 'nohunt' in the current zone.  Mobs tagged nohunt cannot be hunted by any means — the hunt command returns no results for them.  S&D skips hunt entirely and falls back to where instead.",
            },
            {
                heading = "difficulty",
                text    = "Your assessment of how hard a mob is to GET TO, on the same 1-5 scale as an area's difficulty -- awkward to reach, buried behind a maze, needs a key, wanders, whatever makes it a chore. It is not a measure of how dangerous the mob is in a fight. Defaults to whatever you are currently targeting.\n\nRun it bare to see the current target's rating, give a number to set one, and give 0 to clear it so the mob goes back to inheriting its area's rating. Ratings are per mob per zone, so the same mob name in two areas is rated separately -- one may be trivial to reach and the other a long detour.\n\nA rating affects routing in two ways. An area is rated by the average of its targets, and only ever upward: an unrated mob counts as its area's own rating, so an area with nothing rated averages exactly to itself and does not move, while rating mobs pulls the average toward their numbers. An area rated 3 with four targets, one of them rated 5, averages (5+3+3+3)/4 = 3.5 and sorts between plain-3 and plain-4 areas; rate three of those four and it becomes 4.5. Averaging below the area's own rating never demotes it. Difficulty outranks hop distance entirely. Within an area the easiest-to-reach mobs are listed first, so you pick up the quick ones on the way in and leave the awkward one for last. Express mobs are still listed before non-express ones regardless of rating, because that ordering is about having a known kill room to navigate to rather than about how awkward the mob is to reach.\n\nThe Diff column in the CP/GQ window shows the mob's own rating where it has one and its area's otherwise. Note that 'xset mob clearflags' removes the rating along with the flags, and that a rating only affects a route while that mob is actually one of your targets.",
            },
            {
                heading = "noscan",
                text    = "Marks this mob as 'noscan' in the current zone.  Mobs tagged noscan do not appear in scan output at all — the server simply does not report them.  S&D skips the scan step for these mobs and goes straight to 'con' instead.",
            },
            {
                heading = "express",
                text    = "Forces this mob to always use express navigation in the current zone, regardless of kill count or the global express threshold.  Use this when you already know exactly where a mob spawns but haven't killed it enough times for the automatic express threshold to kick in.\n\nWith no arguments, uses your currently targeted mob and sets the express room to the room you are in.  With a mob name only (or with 'here' appended), sets the express room to your current location.  With a mob name and a room ID, sets the express room to that specific room — useful for scripting or setting rooms you are not currently in.",
            },
            {
                heading = "priority / unpriority",
                text    = "Sets or clears a priority room for the mob.  When S&D has multiple rooms to choose from, the priority room is always shown first, regardless of sighting or kill counts.  The priority room is the room you are in when you type the command.",
            },
            {
                heading = "tags [zone]",
                text    = "Lists every mob in the current area (or a named zone) that has at least one active flag: nowhere, nohunt, noscan, express, or a priority room assignment.",
            },
            {
                heading = "levelok <mob>",
                text    = "Toggles the 'levelok' flag, which marks a mob as a legitimate resident of a zone that sits outside the zone's normal level range. Room-name campaign targets are normally matched only against mobs whose level fits the area, so a genuine out-of-range resident is skipped; a mob flagged levelok is looked for here regardless. Use it for the odd mob that really does live in an area despite its level -- a low-level shopkeeper in a high-level zone, or a boss well above everything around it -- when S&D keeps failing to find a target it should be finding. The flag is per mob per zone and clears with 'xset mob clearflags'.",
            },
            {
                heading = "clearflags <mob>",
                text    = "Removes all nowhere, nohunt, noscan, express, and priority-room data for the named mob in the current zone.",
            },
        },
        see_also = { "kw|keyword", "xset area", "express" },
        new_in   = "v6",
    },

    {
        key      = "vidblain",
        category = "Area Management",
        syntax   = {
            "xset vidblain               (toggle Vidblain routing fix)",
            "xset vidblain level <#>     (set lowest portal level to Vidblain area)",
        },
        summary  = "Fix navigation to areas inside Vidblain.",
        sections = {
            {
                heading = "xset vidblain",
                text    = "Toggles a workaround for Vidblain's random-drop entry rooms.  When enabled, S&D uses an alternate routing strategy to reach areas within Vidblain reliably.",
            },
            {
                heading = "xset vidblain level <#>",
                text    = "Sets the level of the lowest-level portal you own to a Vidblain area.  For example, if you have a level 1 portal to Sendhia, type 'xset vidblain level 1'.  S&D uses this to decide when it can portal directly versus needing the alternate routing.",
            },
        },
        see_also = { "xrt|xrun", "xset mark" },
    },

    {
        key      = "index areas",
        aliases  = { "xset index", "xset index areas" },
        category = "Area Management",
        syntax   = {
            "xset index areas          (index all areas, range 0–300)",
            "xset index <zone>         (index one area by keyword)",
        },
        summary  = "Import area data from the MUD into the S&D database.",
        sections = {
            {
                text = "Sends 'areas keywords 0 300' (or 'areas keywords <zone>' for a single area) to the MUD and inserts any areas not yet in the S&D database.  Existing entries are never overwritten.  Newly added areas get a start room of -1; use 'xset mark' once you visit the area to set the correct start room.",
            },
            {
                heading = "Auto-detection",
                text    = "S&D also auto-indexes unknown zones as you move through the world — no manual command needed.  Use 'xset index areas' for a bulk import when you first install, or after a game update adds new areas.",
            },
        },
        see_also = { "xset mark", "xset area", "ms" },
    },

    {
        key      = "roomnote",
        aliases  = { "rn", "rn a", "roomnote a" },
        category = "Area Management",
        syntax   = {
            "roomnote           (notes for the current room)",
            "roomnote area      (notes for the current area)",
            "roomnote area <key> (notes for a specific area)",
        },
        summary  = "Display mapper room notes for the current room or an area.",
        sections = {
            {
                text = "Displays any room notes stored in the mapper database.  With 'area', shows notes for all rooms in the current area.  With 'area <key>', shows notes for the named area.",
            },
        },
        see_also = { "xset table notes", "xm|xmall|rlh" },
    },

    -- ── SYSTEM ───────────────────────────────────────────────────────────────

    {
        key      = "snd update",
        category = "System",
        aliases  = { "snd force update", "snd dev update" },
        syntax   = {
            "snd update              (update to the latest release)",
            "snd force update        (re-download every module regardless)",
            "snd dev update          (pull from the development branch)",
        },
        summary  = "Update Search & Destroy to the latest version.",
        sections = {
            {
                text = "Downloads and installs the latest released version of S&D. Modules are fetched first -- only the ones that actually changed -- and then the plugin file itself if a newer release is out.\n\nWhen only modules changed, type 'snd reload' afterwards to apply them. When the plugin file is replaced it reloads on its own. Your database and settings are never touched by an update.",
            },
            {
                heading = "snd dev update",
                text    = "Pulls modules and the plugin file from the development branch rather than a release, for testing work in progress. Always a full re-download, since a development branch's version does not change between pushes, and it says clearly that you are on a development build. Run a normal 'snd update' to get back onto releases.",
            },
            {
                heading = "snd force update",
                text    = "Re-downloads every module whether or not it already matches the published version -- for when an update looks wrong, or a file has been damaged. If you had edited a module yourself, your copy is saved alongside it as <file>.backup before being replaced.",
            },
        },
        see_also = { "snd reload", "snd version", "snd changelog", "snd check_update" },
    },

    {
        key      = "snd reload",
        category = "System",
        syntax   = { "snd reload" },
        summary  = "Reload the Search & Destroy plugin.",
        sections = {
            {
                text = "Reloads S&D without requiring you to open the plugin manager.  Try this first if something stops working.  If a reload does not fix the problem, open the plugin manager (Ctrl+Shift+P) and manually reinstall.",
            },
        },
        see_also = { "snd update" },
    },

    {
        key      = "snd check_update",
        category = "System",
        syntax   = { "snd check_update" },
        summary  = "Toggle automatic update checks at login.",
        sections = {
            {
                text = "Turns automatic version checking on or off.  When enabled, S&D silently checks for a newer version once per hour and notifies you if one is available.",
            },
        },
        see_also = { "snd update" },
    },

    {
        key      = "snd version",
        aliases  = { "version" },
        category = "System",
        syntax   = { "snd version" },
        summary  = "Show which version is installed, and where it loaded from.",
        sections = {
            {
                text    = "Reports the installed version, the plugin file it is running from, and how many modules loaded and out of which folder. That last part is usually the answer when an update appears not to have taken effect -- modules loaded from a developer folder are deliberately never replaced by 'snd update'.",
            },
            {
                text    = "If any module failed to load it is named here, and if the changelog was last shown for an older version it says so. Worth pasting in full when reporting a problem.",
            },
        },
        see_also = { "snd update", "snd changelog", "snd reload" },
    },

    {
        key      = "snd changelog",
        aliases  = { "changelog", "snd changelog all", "snd changelog since" },
        category = "System",
        syntax   = {
            "snd changelog                  (what changed since your version)",
            "snd changelog all              (the complete history)",
            "snd changelog since <version>  (everything newer than <version>)",
        },
        summary  = "See what changed, since your version or in full.",
        sections = {
            {
                text = "Run bare, this shows only the releases newer than the version you were last running -- not the whole file. If you are already on the newest release it says so rather than printing nothing, since silence is hard to tell apart from a broken command.",
            },
            {
                text = "The same summary appears by itself the first time you load S&D after an update, so you generally do not have to ask. If the download fails, nothing is recorded as seen and the notice comes back on the next load rather than being lost.",
            },
            {
                heading = "snd changelog all",
                text    = "Every release, newest first. This is what plain 'snd changelog' used to do.",
            },
            {
                heading = "snd changelog since <version>",
                text    = "Everything newer than the version you name, e.g. 'snd changelog since 6.0'. Useful when helping someone else work out what changed between their install and yours. The version must be a dotted number.",
            },
        },
        see_also = { "snd update", "snd reload", "snd check_update" },
    },

    {
        key      = "snd migrate",
        aliases  = { "mergePwar",
            "mergePwar confirm",
            "snd migrate confirm",
        },
        category = "System",
        syntax   = { "snd migrate" },
        summary  = "Import mob sighting data from Pwar's Search & Destroy.",
        sections = {
            {
                text = "Migrates mob sightings, kills, and keyword data from the original Pwar S&D database into this version.  The source file must be named 'WinkleGold_Database.db' and located in your MUSHclient plugins folder.  Run this once after switching from Pwar's version.",
            },
        },
        see_also = { "ms" },
    },

    {
        key      = "summary",
        category = "System",
        syntax   = { "xhelp summary" },
        summary  = "Quick-reference list of every S&D command.",
        sections = {}, -- rendered dynamically below
    },

    {
        key      = "snd history",
        aliases  = { "history" },
        category = "System",
        syntax   = {
            "snd history                 (last 20 rows, all types)",
            "snd history campaign",
            "snd history quest",
            "snd history gquest",
        },
        summary  = "Show the last 20 campaign, quest, or gquest history rows.",
        sections = {
            {
                text = "Displays a table of your most recent activity — start time, duration, status, and rewards for each campaign, quest, or global quest.  Optionally filter to one activity type.",
            },
        },
        see_also = { "snd stats", "snd summary" },
    },

    {
        key      = "snd stats",
        aliases  = { "stats" },
        category = "System",
        syntax   = {
            "snd stats quest|campaign|gquest [<period> [<N>|last]]",
            "snd stats overtime",
            "snd stats areas",
        },
        summary  = "Display per-level stats with optional time range, a daily summary, or area kill counts.",
        sections = {
            {
                heading = "snd stats quest | campaign | gquest",
                text    = "Shows per-level aggregate statistics (min/avg/max duration, count, total QP) for completed activities. Add a time period to narrow the window:\n" ..
                          "  snd stats quest             — all time\n" ..
                          "  snd stats quest day         — today\n" ..
                          "  snd stats quest day 45      — last 45 days\n" ..
                          "  snd stats quest day last    — yesterday\n" ..
                          "  snd stats quest week        — this week (Sun–now)\n" ..
                          "  snd stats quest week last   — previous full week\n" ..
                          "  snd stats quest month       — this calendar month\n" ..
                          "  snd stats quest month 3     — last 3 months\n" ..
                          "  snd stats quest month last  — previous calendar month\n" ..
                          "  snd stats quest year        — this calendar year\n" ..
                          "  snd stats quest year last   — previous calendar year",
            },
            {
                heading = "snd stats overtime",
                text    = "Shows a rolling 14-day daily breakdown across all characters: quests, campaigns, global quests won, and total rewards earned each day.",
            },
            {
                heading = "snd stats areas",
                text    = "Shows the 30 areas where you have the most accumulated kills, with total kill count and the number of distinct mob types seen.  Useful for knowing which areas to prioritize learning.",
            },
        },
        see_also = { "snd history", "snd summary" },
    },

    {
        key      = "snd summary",
        category = "System",
        syntax   = { "snd summary" },
        summary  = "Show a summary of QP, TP, and activity counts for this session.",
        new_in   = "v6",
        sections = {
            {
                text = "Prints a compact summary of everything completed since S&D was loaded: number of campaigns, quests, and global quests; total QP, TP, trains, practices, and gold earned.  Useful for a quick end-of-session overview.",
            },
        },
        see_also = { "snd history", "snd stats" },
    },

    {
        key      = "pathing",
        aliases  = { "xset pathing", "xset pathing express" },
        category = "System",
        syntax   = {
            "xset pathing                          (show current status)",
            "xset pathing on|off                   (toggle route optimization)",
            "xset pathing express off|first|last   (control express mob grouping)",
        },
        summary  = "Control campaign route optimization and express mob ordering.",
        new_in   = "v6",
        sections = {
            {
                text = "When enabled (the default), S&D reorders your campaign or GQ target list after each 'cp check' or 'gq check' to minimize total travel distance.  Express mobs are routed to their specific kill room; all other mobs are routed to their area start room.  Mobs in the same area are always kept consecutive.",
            },
            {
                heading = "xset pathing express",
                text    = "Controls whether express mobs are grouped together and where in the route they appear:\n\n'off' (default) — express and non-express areas are interleaved; the entire list is ordered by area difficulty then hop count.\n\n'first' — area groups containing at least one express mob are placed before all non-express area groups.  Within each half, groups are sorted by difficulty then hop count.\n\n'last' — express area groups are placed after non-express groups.\n\nWhen an area contains both express and non-express mobs, the group is treated as an express group (for 'first'/'last' purposes) and the express mobs within the group are listed first.",
            },
        },
        see_also = { "level buffer", "xcp", "express" },
    },

    {
        key      = "level buffer",
        aliases  = { "xset level buffer" },
        category = "System",
        syntax   = {
            "xset level buffer         (show current value)",
            "xset level buffer <n>     (set to n levels above area max)",
        },
        summary  = "Set how far above an area's max level a room CP target is still accepted.",
        new_in   = "v6",
        sections = {
            {
                text = "Room-type campaigns and global quests include a level check: only rooms from areas whose level range overlaps your effective level are accepted.  The level buffer adds N levels above the area's stated maximum before filtering.  Default is 25.  Increase this if legitimate CP or GQ rooms are being filtered out; decrease it if you are seeing too many out-of-range results.",
            },
        },
        see_also = { "pathing", "xcp", "xset level" },
    },

    {
        key      = "xset level",
        aliases  = { "xset level area" },
        category = "System",
        syntax   = {
            "xset level <areakey> <min> <max>   (set per-area level override)",
            "xset level <areakey> reset          (remove per-area override)",
        },
        summary  = "Override the level range for a specific area used in CP/GQ filtering.",
        new_in   = "v6",
        sections = {
            {
                text = "Stores a per-area level override that replaces the area's normal level range when S&D decides whether to accept a CP or GQ target.  Useful when an area's stated levels differ from where you actually hunt (e.g. an area listed as 1–201 but you only go there at level 201).",
            },
            {
                heading = "Level buffer interaction",
                text    = "The level buffer is still added on top of the overridden max, so if you set a max of 200 and the buffer is 25, targets up to level 225 in that area will be accepted.",
            },
        },
        see_also = { "level buffer", "pathing", "xcp" },
    },

    {
        key      = "xdb clean",
        aliases  = { "xdb" },
        category = "Area Management",
        syntax   = { "xdb clean" },
        summary  = "Strip mob flags and merge case duplicates from the mob database.",
        new_in   = "v6",
        sections = {
            {
                text = "Cleans up the mob sightings and kills database in two passes.  First, any mob names that were stored with leading status flags (such as '(Red Aura) a wizard' or '(R) a wizard') have the flags stripped.  If a clean version of the name already exists in the same room, the counts are merged.  Second, mobs with the same lowercased name in the same room but different capitalisation (e.g. 'an elephant' vs 'An Elephant') are merged into the variant with the most uppercase letters, with counts summed.",
            },
        },
        see_also = { "ms", "xset mob" },
    },

    {
        key      = "xmobdeaths",
        aliases  = { "mobdeaths", "mob deaths" },
        category = "Area Management",
        syntax   = {
            "xmobdeaths     (scan deaths for mobs in current room's area)",
        },
        summary  = "Query mob death counts for the current area and store duplicate-level data.",
        new_in   = "v6",
        sections = {
            {
                text = "Sends the MUD command 'mobdeaths here' and parses the response.  For each mob that appears more than once in the area's death log the plugin records the levels at which duplicates were seen.  This data is used by the mob-tracking system to distinguish same-named mobs at different levels.",
            },
            {
                heading = "When to use",
                text    = "Run xmobdeaths after entering a new area or when the hunt window shows unexpected duplicate mob names.  The data persists in the session database.",
            },
        },
        see_also = { "xset mob", "mob" },
    },

    {
        key      = "xwhere",
        aliases  = { "xw", "xwh", "xw mob", "xwhere mob" },
        category = "Scanning & Hunting",
        syntax   = {
            "xw <mob>             (send 'where 1.mob' through 'where 5.mob')",
            "xw <n1> <mob>        (send 'where 1.mob' through 'where n1.mob')",
            "xw <n1> <n2> <mob>   (send 'where n1.mob' through 'where n2.mob')",
        },
        summary  = "Send a series of 'where N.mob' commands to locate all instances of a mob.",
        new_in   = "v6",
        sections = {
            {
                text = "Sequentially sends 'where N.mob' for each N in the requested range.  Useful when a mob has multiple instances across zones and a single 'where 1.mob' would only reveal the first.",
            },
            {
                heading = "Examples",
                text    = "xw gnoll        — checks where 1 through 5 gnoll\nxw 3 gnoll      — checks where 1 through 3 gnoll\nxw 2 4 gnoll    — checks where 2 through 4 gnoll",
            },
        },
        see_also = { "xmobdeaths", "xset mob", "ms" },
    },

    {
        key      = "xg",
        aliases  = { "xg refresh", "xg reload",
            "xgui",
            "xgui ref",
            "xgui refresh",
            "xgui rel",
            "xgui reload",
            "xg ref",
            "xg rel",
        },
        category = "Window & Display",
        syntax   = {
            "xg refresh    (redraw the miniwindow without reloading data)",
            "xg reload     (reload window UI state and redraw)",
        },
        summary  = "Refresh or reload the S&D miniwindow.",
        new_in   = "v6",
        sections = {
            {
                text = "Use 'xg refresh' when the miniwindow display looks garbled or out of date — it redraws all panels from current in-memory data without re-querying the database.  Use 'xg reload' when the window layout itself needs to be reset (e.g. after changing font or size settings).",
            },
        },
        see_also = { "win" },
    },

    {
        key      = "xset autonav",
        aliases  = { "autonav" },
        category = "Navigation",
        syntax   = {
            "xset autonav              (show the current setting)",
            "xset autonav on|off       (turn it on or off)",
        },
        summary  = "Walk there automatically when a search finds exactly one room.",
        sections = {
            {
                text    = "When a campaign lookup or a quick-where narrows down to exactly one room -- no ambiguity about where the mob is -- autonav starts walking you there without waiting for an 'xrt'. If the search returns several candidate rooms it does nothing, because there is no single obvious destination to pick.",
            },
            {
                text    = "It is off by default. Leave it off if you like reading the candidate list before committing to a route, or if you are somewhere that walking off unprompted is expensive. The setting persists across reloads.",
            },
        },
        see_also = { "xrt|xrun", "qw", "xcp", "xset speed" },
    },

    {
        key      = "snd settings",
        aliases  = { "settings", "snd setting" },
        category = "System",
        syntax   = {
            "snd settings     (open or close the settings window)",
        },
        summary  = "Open the point-and-click settings window.",
        sections = {
            {
                text    = "Opens a window listing S&D's settings with their current values, so you can see and change them without remembering the 'xset' command for each one. Running it again closes the window; it is a toggle, not two separate commands.",
            },
            {
                text    = "Everything in the window is also reachable from the command line, and changes made either way are the same setting -- the window is a convenience, not a separate configuration. Its position and size are remembered between sessions.",
            },
        },
        see_also = { "win", "xset level", "xset speed" },
    },

    {
        key      = "xset debug",
        aliases  = { "debug", "snd debug" },
        category = "System",
        syntax   = {
            "xset debug            (show whether logging is on, and the log path)",
            "xset debug on|off     (start or stop logging)",
            "snd debug clear       (empty the log file)",
        },
        summary  = "Log S&D's internal activity to a file for bug reports.",
        sections = {
            {
                text    = "Turns on a running log of what S&D is doing internally -- what it captured, what it decided, and where it gave up. It is meant for chasing a problem you can reproduce: turn it on, do the thing that misbehaves, turn it off, and attach the log to a bug report.",
            },
            {
                text    = "Run it bare to see whether logging is currently on and where the file lives. 'snd debug clear' empties the log, which is worth doing right before reproducing a problem so the file contains only the relevant run. Leave debug off for normal play -- the log grows steadily and is never truncated on its own.",
            },
        },
        see_also = { "snd reload", "snd stats" },
    },

    {
        key      = "xset import",
        aliases  = { "import" },
        category = "Area Management",
        syntax   = {
            "xset import     (one-time import from a pre-v6 installation)",
        },
        summary  = "Import area ranges and marks from an older S&D install.",
        sections = {
            {
                text    = "Older versions of S&D kept area level ranges, area start rooms, and marks in MUSHclient plugin variables rather than in the database. This reads those variables once and writes what it finds into the current database: area ranges, start rooms, and marks, resolving room and area names through the mapper database as it goes.",
            },
            {
                text    = "It reports how many entries it imported, updated, and skipped. If you have no prior installation the variables are simply absent and it says so and stops, which is harmless -- add marks by hand with 'xset mark' instead. There is no reason to run this more than once, and nothing to import back the other way.",
            },
        },
        see_also = { "xset mark", "xset marks", "xset area", "snd migrate" },
    },

}

-- ─── TOPIC LOOKUP MAP ────────────────────────────────────────────────────────

local TOPIC_MAP = {}
for _, t in ipairs(TOPICS) do
    TOPIC_MAP[t.key:lower()] = t
    for _, alias in ipairs(t.aliases or {}) do
        TOPIC_MAP[alias:lower()] = t
    end
end

-- ─── CATEGORY ORDER ──────────────────────────────────────────────────────────
-- Controls the left-to-right order of categories on the index page.

local CATEGORY_ORDER = {
    "Navigation",
    "Campaign & Quest",
    "Scanning & Hunting",
    "Window & Display",
    "Area Management",
    "Data & Keywords",
    "System",
}

-- ─── RENDERER HELPERS ────────────────────────────────────────────────────────

-- Print a horizontal rule in the given style.
local function hr(heavy)
    ColourNote(C_SEP, "", heavy and HR2 or HR)
end

-- Print a clickable hyperlink that runs "xhelp <topic>" when clicked.
local function help_link(topic_key, label)
    Hyperlink(
        "xhelp " .. topic_key,
        "[" .. (label or topic_key) .. "]",
        "Type: xhelp " .. topic_key,
        C_LINK, "", false
    )
end

-- Wrap and print a body paragraph with consistent left indent.
local function body(text, extra_indent)
    local indent = "  " .. (extra_indent or "")
    local wrapped = helpWrap(text, COL - #indent, indent)
    ColourNote(C_BODY, "", wrapped)
end

-- ─── INDEX PAGE ──────────────────────────────────────────────────────────────

-- Build category → topics map.
local function build_category_map()
    local cats = {}
    for _, cat in ipairs(CATEGORY_ORDER) do
        cats[cat] = {}
    end
    for _, t in ipairs(TOPICS) do
        local bucket = cats[t.category]
        if bucket then
            bucket[#bucket + 1] = t
        end
    end
    return cats
end

local function show_help_index()
    hr(true)
    ColourTell(C_HDR_LABEL, "", "  SEARCH & DESTROY ")
    ColourTell(C_SEP,       "", "v" .. snd_version() .. "  ·  ")
    ColourNote(C_HDR_TOPIC, "", "Type  xhelp <topic>  for full details")
    hr(true)
    Note("")

    -- Introduction
    body("Search & Destroy is a quality-of-life plugin for Aardwolf.  It tracks campaign, global-quest, and quest targets, maintains a mob-sighting database, and integrates with the mapper to navigate you directly to your goals.")
    Note("")
    body("All commands start with  xhelp <keyword>.  Each entry below is a clickable link.")
    Note("")

    local cats = build_category_map()

    for _, cat_name in ipairs(CATEGORY_ORDER) do
        local topics = cats[cat_name]
        if topics and #topics > 0 then
            hr(false)
            ColourNote(C_CAT, "", "  " .. cat_name:upper())
            Note("")
            for _, t in ipairs(topics) do
                -- Left-pad with two spaces, then hyperlinked key, then summary
                ColourTell("", "", "  ")
                help_link(t.key)
                if t.new_in then
                    ColourTell(C_NEW, "", " " .. t.new_in)
                end
                local pad = math.max(1, 26 - #t.key - (t.new_in and #t.new_in + 1 or 0))
                ColourTell(C_SEP, "", string.rep(" ", pad))
                ColourNote(C_SUMMARY, "", t.summary)
            end
            Note("")
        end
    end

    hr(true)
    ColourTell(C_HDR_LABEL, "", "  Also try: ")
    help_link("summary")
    ColourTell(C_HDR_LABEL, "", "   ")
    help_link("history")
    ColourTell(C_HDR_LABEL, "", "   ")
    help_link("stats")
    Note("")
    hr(true)
end

-- ─── TOPIC PAGE ──────────────────────────────────────────────────────────────

-- Render the summary pseudo-topic (all commands at a glance).
-- Layout: syntax left-column (max 36 visible chars), summary right-column
-- starting at col 40 (2 indent + 36 + 2 gap), wrapping at 78.
local function show_help_summary()
    local SYN_MAX   = 36   -- max chars for syntax column
    local SUM_COL   = 40   -- column where summary starts (0-based offset in line)
    local TOTAL_COL = 78   -- total line width

    -- Word-wrap a string to fit within `width` chars, with `indent` on continuation lines.
    local function wrap_at(text, width, indent)
        local lines = {}
        local line  = ""
        for word in text:gmatch("%S+") do
            if #line == 0 then
                line = word
            elseif #line + 1 + #word <= width then
                line = line .. " " .. word
            else
                lines[#lines + 1] = line
                line = word
            end
        end
        if #line > 0 then lines[#lines + 1] = line end
        local sep = "\n" .. indent
        return table.concat(lines, sep)
    end

    hr(true)
    ColourTell(C_HDR_LABEL, "", "  SEARCH & DESTROY  ·  ")
    ColourNote(C_HDR_TOPIC, "", "Command Quick Reference")
    hr(true)
    Note("")

    local last_cat = nil
    for _, t in ipairs(TOPICS) do
        if t.key ~= "summary" and t.syntax and #t.syntax > 0 then
            -- Category divider between groups
            if t.category ~= last_cat then
                if last_cat then Note("") end
                ColourNote(C_CAT, "", "  " .. (t.category or ""):upper())
                last_cat = t.category
            end

            local syn = "  " .. t.syntax[1]

            if #syn <= SYN_MAX + 2 then
                -- Fits in left column: print syntax + pad + summary on same line.
                local pad = SUM_COL - #syn
                local sum_width = TOTAL_COL - SUM_COL
                local sum_lines = {}
                local line = ""
                for word in t.summary:gmatch("%S+") do
                    if #line == 0 then
                        line = word
                    elseif #line + 1 + #word <= sum_width then
                        line = line .. " " .. word
                    else
                        sum_lines[#sum_lines + 1] = line
                        line = word
                    end
                end
                if #line > 0 then sum_lines[#sum_lines + 1] = line end

                ColourTell(C_SYNTAX,  "", syn)
                ColourTell(C_SEP,     "", string.rep(" ", math.max(1, pad)))
                ColourNote(C_SUMMARY, "", sum_lines[1] or "")
                for i = 2, #sum_lines do
                    ColourNote(C_SUMMARY, "", string.rep(" ", SUM_COL) .. sum_lines[i])
                end
            else
                -- Syntax too long: syntax on its own line, summary indented below.
                ColourNote(C_SYNTAX, "", syn)
                local sum_indent = string.rep(" ", SUM_COL)
                local sum_width  = TOTAL_COL - SUM_COL
                local wrapped    = wrap_at(t.summary, sum_width, sum_indent)
                ColourNote(C_SUMMARY, "", sum_indent .. wrapped)
            end
        end
    end

    Note("")
    hr(true)
end

local function show_help_topic(t)
    -- Header
    hr(true)
    ColourTell(C_HDR_LABEL, "", "  SEARCH & DESTROY  ·  xhelp ")
    ColourTell(C_HDR_TOPIC, "", t.key)
    if t.new_in then
        ColourTell(C_NEW, "", "  (" .. t.new_in .. ")")
    end
    Note("")
    hr(true)

    -- Syntax block
    if t.syntax and #t.syntax > 0 then
        Note("")
        ColourTell(C_SYNTAX_LBL, "", "  Syntax  ")
        for i, line in ipairs(t.syntax) do
            if i == 1 then
                ColourNote(C_SYNTAX, "", line)
            else
                ColourNote(C_SYNTAX, "", "          " .. line)
            end
        end
    end

    -- Sections
    if #(t.sections or {}) > 0 then
        for _, section in ipairs(t.sections) do
            Note("")
            if section.heading then
                ColourNote(C_SECTION, "", "  " .. section.heading)
                Note("")
            end
            body(section.text, section.heading and "  " or "")
        end
    end

    -- See also
    if t.see_also and #t.see_also > 0 then
        Note("")
        hr(false)
        Note("")
        ColourTell(C_SYNTAX_LBL, "", "  See also  ")
        for i, ref in ipairs(t.see_also) do
            if i > 1 then ColourTell(C_SEP, "", "   ") end
            help_link(ref)
        end
        Note("")
    end

    Note("")
    hr(true)
end

-- ─── CONTENT SEARCH ──────────────────────────────────────────────────────────

-- Search topic text/summaries/syntax for `query` (plain string, case-insensitive).
-- Returns a list of { topic=t, context="matched snippet" } tables, deduplicated.
local function search_topic_content(query)
    local results = {}
    local seen    = {}
    local q       = query:lower()
    for _, t in ipairs(TOPICS) do
        if not seen[t.key] then
            local ctx = nil
            -- summary
            if not ctx and t.summary and t.summary:lower():find(q, 1, true) then
                ctx = t.summary
            end
            -- syntax lines
            if not ctx then
                for _, s in ipairs(t.syntax or {}) do
                    if s:lower():find(q, 1, true) then ctx = s; break end
                end
            end
            -- section headings and body text
            if not ctx then
                for _, sec in ipairs(t.sections or {}) do
                    if sec.heading and sec.heading:lower():find(q, 1, true) then
                        ctx = sec.heading; break
                    end
                    if sec.text and sec.text:lower():find(q, 1, true) then
                        -- Extract a short snippet around the match.
                        local s = sec.text
                        local lo = s:lower()
                        local si = lo:find(q, 1, true)
                        if si then
                            local start = math.max(1, si - 20)
                            local stop  = math.min(#s, si + #q + 40)
                            ctx = (start > 1 and "…" or "") .. s:sub(start, stop):gsub("\n", " ") ..
                                  (stop < #s and "…" or "")
                        end
                        break
                    end
                end
            end
            if ctx then
                results[#results + 1] = { topic = t, context = ctx }
                seen[t.key] = true
            end
        end
    end
    return results
end

-- Print text with the first occurrence of `word` highlighted.
local function print_with_highlight(text, word, base_color, hi_color)
    local lo = text:lower()
    local wi = word:lower()
    local si = lo:find(wi, 1, true)
    if not si then
        ColourNote(base_color, "", text)
        return
    end
    ColourTell(base_color, "",  text:sub(1, si - 1))
    ColourTell(hi_color,   "",  text:sub(si, si + #word - 1))
    ColourNote(base_color, "",  text:sub(si + #word))
end

-- ─── ENTRY POINT ─────────────────────────────────────────────────────────────

function onHelp(name, line, wildcards)
    local raw = (wildcards.search or ""):lower():match("^%s*(.-)%s*$")

    if raw == "" or raw == "xhelp" then
        show_help_index()
        return
    end

    if raw == "summary" then
        show_help_summary()
        return
    end

    -- 1. Exact key / alias lookup.
    local topic = TOPIC_MAP[raw]
    if topic then
        show_help_topic(topic)
        return
    end

    -- 2. Partial key / alias match (substring in any key or alias string).
    local key_matches = {}
    for key, t in pairs(TOPIC_MAP) do
        if key:find(raw, 1, true) then
            local already = false
            for _, m in ipairs(key_matches) do
                if m == t then already = true; break end
            end
            if not already then key_matches[#key_matches + 1] = t end
        end
    end

    if #key_matches == 1 then
        show_help_topic(key_matches[1])
        return
    elseif #key_matches > 1 then
        ColourNote(C_HDR_LABEL, "", HR)
        ColourNote(C_HDR_TOPIC, "", "  Multiple topic matches for '" .. raw .. "':")
        Note("")
        for _, m in ipairs(key_matches) do
            ColourTell("", "", "  ")
            help_link(m.key)
            ColourTell(C_SEP, "", "  ")
            ColourNote(C_SUMMARY, "", m.summary)
        end
        Note("")
        ColourNote(C_HDR_LABEL, "", HR)
        return
    end

    -- 3. Full-content search across summaries, syntax lines, and section text.
    local content_matches = search_topic_content(raw)

    if #content_matches > 0 then
        ColourNote(C_HDR_LABEL, "", HR)
        ColourNote(C_HDR_TOPIC, "", "  Content search results for '" .. raw .. "':")
        Note("")
        for _, m in ipairs(content_matches) do
            ColourTell("", "", "  ")
            help_link(m.topic.key)
            ColourTell(C_SEP, "", "  ")
            print_with_highlight(m.context, raw, C_SUMMARY, C_HDR_TOPIC)
        end
        Note("")
        ColourNote(C_BODY, "", "  Type  xhelp <topic>  to read the full entry.")
        Note("")
        ColourNote(C_HDR_LABEL, "", HR)
    else
        ColourNote(C_HDR_LABEL, "", HR)
        ColourNote(C_BODY, "", "  No help topic found for '" .. raw .. "'.")
        Note("")
        ColourTell(C_BODY, "", "  Type ")
        help_link("xhelp", "xhelp")
        ColourNote(C_BODY, "", " to see the full topic list.")
        Note("")
        ColourNote(C_HDR_LABEL, "", HR)
    end
end
