-- window.lua  (Search & Destroy)
-- Miniwindow: four-tab display (QST / CP / GQ / Settings) with themed chrome.
-- Dependencies: constants.lua, util.lua, db.lua, settings.lua, history.lua
-- MUSHClient packages used: aard_register_z_on_create, mw_theme_base,
--   movewindow, copytable, scrollbar, commas

require "aard_register_z_on_create"
require "mw_theme_base"
require "movewindow"
require "copytable"
require "scrollbar"
require "commas"

-- ─── WINDOW IDENTITY ─────────────────────────────────────────────────────────

local win = GetPluginID()

-- ─── CONSTANTS ───────────────────────────────────────────────────────────────

local DEFAULT_W    = 539
local DEFAULT_H    = 320
local DEFAULT_X    = 0
local DEFAULT_Y    = 0
local MIN_W        = 240
local MIN_H        = 140

local PAD_LEFT     = 6
local PAD_TOP      = 4
local PAD_RIGHT    = 6
local PAD_BOTTOM   = 4

local TAB_H_MIN    = 24
local INFO_H_MIN   = 14
local STATUS_H_MIN = 16

local TNL_STEP     = 500
local FONT_ID      = "snd_font"
local EDGE_W       = 2
local ROW_PAD      = 2    -- pixels of padding above and below each target-row's text
local SCROLLBAR_W  = 10

-- Difficulty color scale (1-5), indexed by entry.difficulty
-- (mob rating where set, else the area's).
-- Matches the palette used by 'xset area list' (Search_and_Destroy.xml).
local DIFF_COLS = {
    0x506070,  -- 1: default/dim
    0x44CC44,  -- 2: green
    0xFFCC00,  -- 3: yellow
    0xFF8800,  -- 4: orange
    0xFF3333,  -- 5: red
}

-- ─── MODULE STATE ────────────────────────────────────────────────────────────

local windowinfo        = nil
local _width            = DEFAULT_W
-- Pixels claimed by the optional columns at the last draw, so a change in the
-- column set can be turned into a change in window width.
local _col_fixed_w      = nil
local _height           = DEFAULT_H
local _min_expand_h     = DEFAULT_H   -- floor for expand-mode shrink; updated on manual resize

-- 'xset win max|expand' / 'min|collapse': whether the window is rolled up
-- to just beneath the info (TNL) bar, and the height to restore on expand.
local _collapsed        = false
local _pre_collapse_h   = nil
local _screen_w         = 0
local _screen_h         = 0
local _scale            = 1.0
local _resize_sx        = 0
local _resize_sy        = 0

local _cp_list          = {}
local _gq_list          = {}
local _active_tab       = "quest"
local _scroll_offset    = { cp = 0, gq = 0 }
local _scrollbar        = nil

-- Quest tab flash: set by xg_flash_quest_tab() when a quest event fires
-- while the player is looking at cp/gq (see quest_status_gmcp in targets.lua,
-- which no longer forces the tab switch mid-activity, and calls this instead
-- so the event is still noticed). _quest_flash_until is an os.time() deadline;
-- quest_flash_timer ticks _quest_flash_on between draws until that passes.
local _quest_flash_until = nil
local _quest_flash_on    = false

local _active_font_name = ""
local _active_font_size = 0

local _row_hotspot_ids  = {}
local _info_hotspot_ids = {}
local _last_reward      = nil

-- ─── TAB DEFINITIONS ─────────────────────────────────────────────────────────

local TABS = {
    { key = "quest", label = "QST", hs = "snd_tab_quest", tooltip = "Quest target"         },
    { key = "cp",    label = "CP",  hs = "snd_tab_cp",    tooltip = "Campaign targets"     },
    { key = "gq",    label = "GQ",  hs = "snd_tab_gq",    tooltip = "Global Quest targets" },
}

-- ─── FORWARD DECLARATIONS ────────────────────────────────────────────────────
-- draw_list and redraw_list_area reference each other; declare locals so both
-- function bodies can capture the variable as an upvalue.

local draw_list
local redraw_list_area

-- ─── PUBLIC INTERFACE ────────────────────────────────────────────────────────

-- Which tab is currently showing. Used by xcp (navigation.lua) to decide
-- which activity a bare 'xcp' means when the player is on both a campaign
-- and a gquest at once and current_activity (whichever was checked last)
-- does not agree with what they are actually looking at.
function xg_get_active_tab()
    return _active_tab
end

function xg_set_active_tab(tab)
    if tab == "cp" or tab == "gq" or tab == "quest" then
        _active_tab = tab
        if tab == "quest" then xg_stop_quest_flash() end
        xg_draw_window()
    end
end

-- Called when a quest event fires but the tab switch to it was suppressed
-- because the player is mid-campaign or mid-gquest (quest_status_gmcp,
-- targets.lua). A no-op if the quest tab is already showing -- there is
-- nothing to draw attention to that isn't already on screen.
function xg_flash_quest_tab()
    if _active_tab == "quest" then return end
    _quest_flash_until = os.time() + 5
    _quest_flash_on    = true
    if type(EnableTimer) == "function" then EnableTimer("quest_flash_timer", true) end
    xg_draw_window()
end

-- Called by quest_flash_timer (every second) to alternate the tab color, and
-- by xg_stop_quest_flash to cut it short (e.g. the player clicked the tab
-- themselves, or switched some other way -- see xg_set_active_tab above).
function xg_stop_quest_flash()
    _quest_flash_until = nil
    _quest_flash_on    = false
    if type(EnableTimer) == "function" then EnableTimer("quest_flash_timer", false) end
end

function quest_flash_tick()
    if not _quest_flash_until or os.time() >= _quest_flash_until then
        xg_stop_quest_flash()
    else
        _quest_flash_on = not _quest_flash_on
    end
    xg_draw_window()
end

function xg_update_target_list(activity, list)
    if activity == "cp" then
        _cp_list           = list or {}
        _scroll_offset.cp  = 0
        _active_tab        = "cp"
        _last_reward       = nil
    elseif activity == "gq" then
        _gq_list           = list or {}
        _scroll_offset.gq  = 0
        _active_tab        = "gq"
        _last_reward       = nil
    end
end

function xg_show_reward(activity, data)
    _last_reward          = data
    _last_reward.activity = activity
    if type(xg_draw_window) == "function" then xg_draw_window() end
end

-- ─── FONT SELECTION ──────────────────────────────────────────────────────────

-- Combine the resolution-based heuristic (large screen -> assume the user
-- wants a bigger window) with the OS's actual DPI setting (GetDeviceCaps(88),
-- horizontal logical pixels per inch; 96 = 100%), taking whichever calls for
-- more scale. A 1920x1080 display at 150% Windows scaling has a "normal"
-- pixel resolution but is still rendering everything 1.5x visually larger,
-- so resolution alone under-detects it -- title bar and button chrome sized
-- off the un-scaled font metrics then gets visually clipped.
local function compute_scale(screen_w, dpi_h)
    local screen_ratio = (tonumber(screen_w) or 1920) / 1920
    local dpi_ratio     = (tonumber(dpi_h) or 96) / 96
    return math.min(3.0, math.max(1.0, screen_ratio, dpi_ratio))
end

local function select_font(scale)
    scale = scale or 1.0
    local saved_name = snd_get_setting("window_font", "")
    local saved_size = tonumber(snd_get_setting("window_font_size", ""))
    if saved_name ~= "" and saved_size and saved_size > 0 then
        return saved_name, saved_size
    end
    local fonts = utils.getfontfamilies()
    if not fonts.Dina then
        AddFont(GetInfo(66) .. "\\Dina.fon")
        fonts = utils.getfontfamilies()
    end
    local function scaled(base)
        return math.max(6, math.floor(base * scale + 0.5))
    end
    if fonts.Dina           then return "Dina",         scaled(8) end
    if fonts["Courier New"] then return "Courier New",  scaled(9) end
    return                           "Lucida Console",  scaled(9)
end

function snd_pick_font()
    local cur_name = _active_font_name ~= "" and _active_font_name
                     or snd_get_setting("window_font", "")
    local cur_size = _active_font_size > 0 and _active_font_size
                     or (tonumber(snd_get_setting("window_font_size", "")) or 0)
    if cur_name == "" or cur_size == 0 then
        cur_name, cur_size = select_font(_scale)
    end
    local result = utils.fontpicker(cur_name, cur_size, 0)
    if not result then return end
    snd_set_setting("window_font",        result.name,                          true)
    snd_set_setting("window_font_size",   tostring(result.size),                true)
    snd_set_setting("window_font_bold",   result.bold   == 1 and "on" or "off", true)
    snd_set_setting("window_font_italic", result.italic == 1 and "on" or "off", true)
    _active_font_name = result.name
    _active_font_size = result.size
    WindowFont(win, FONT_ID, result.name, result.size,
        result.bold == 1, result.italic == 1, false, false, 0)
    xg_draw_window()
    if type(sp_draw_if_open) == "function" then sp_draw_if_open() end
    InfoNote(string.format("SnD: Font set to %s %dpt%s.",
        result.name, result.size,
        result.style ~= "" and (" " .. result.style) or ""))
end

function snd_reset_font()
    snd_set_setting("window_font",        "", true)
    snd_set_setting("window_font_size",   "", true)
    snd_set_setting("window_font_bold",   "", true)
    snd_set_setting("window_font_italic", "", true)
    local font_name, font_size = select_font(_scale)
    _active_font_name = font_name
    _active_font_size = font_size
    WindowFont(win, FONT_ID, font_name, font_size, false, false, false, false, 0)
    xg_draw_window()
    if type(sp_draw_if_open) == "function" then sp_draw_if_open() end
    InfoNote(string.format("SnD: Font reset to default (%s %dpt).", font_name, font_size))
end

-- ─── COLOR ACCESSORS ─────────────────────────────────────────────────────────

local function accent_col(tab_key)
    if tab_key then
        local per = snd_get_setting("color_tab_" .. tab_key, "")
        if per ~= "" then return ColourNameToRGB(per) end
    end
    return ColourNameToRGB(snd_get_setting("color_accent", "#00B4E0"))
end

local function accent2_col()
    return ColourNameToRGB(snd_get_setting("color_accent2", "#005070"))
end

local function info_bg_col()
    return ColourNameToRGB(snd_get_setting("color_info_bg", "#0A1A20"))
end

local function status_bg_col()
    return ColourNameToRGB(snd_get_setting("color_status_bg", "#060C10"))
end

-- ─── HELPERS ─────────────────────────────────────────────────────────────────

-- True only when the MUSHClient window really exists.
--
-- `windowinfo` on its own is not proof: it is set once by xg_create_window and
-- survives xg_destroy_window, so after a disconnect it still looks installed
-- while the underlying window is gone.  Anything that calls a Window* API on
-- `win` must check this, not just `windowinfo` -- WindowFontInfo() returns nil
-- for a deleted window and the arithmetic in font_line_h() then fails.
local function window_exists()
    return windowinfo ~= nil and WindowInfo(win, 1) ~= nil
end

local function font_line_h()
    return WindowFontInfo(win, FONT_ID, 1) - WindowFontInfo(win, FONT_ID, 4)
end

local function entry_color(entry, index)
    if type(color_for_target) == "function" and
       type(target_matches_current_target) == "function" then
        return ColourNameToRGB(
            color_for_target(entry, target_matches_current_target(entry, index))
        )
    end
    if entry.is_dead == "yes" then
        return ColourNameToRGB(snd_get_setting("color_dead",    "#484848"))
    end
    if entry.link_type == "unknown" then
        return ColourNameToRGB(snd_get_setting("color_unknown", "#FF0000"))
    end
    return ColourNameToRGB(snd_get_setting("color_normal", "#E0E0E0"))
end

local function edge_color(entry, index)
    if type(target_matches_current_target) == "function" and
       target_matches_current_target(entry, index) then
        return ColourNameToRGB(snd_get_setting("color_targeted", "#FF4000"))
    end
    if entry.is_dead == "yes" then return 0x383838 end
    if entry.link_type == "unknown" then
        return ColourNameToRGB(snd_get_setting("color_unknown", "#FF0000"))
    end
    return 0x005C00
end

local function fmt_n(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then return string.format("%.1fk", n / 1000)
    else return tostring(math.floor(n)) end
end

-- ─── GEOMETRY ────────────────────────────────────────────────────────────────

local function geometry()
    local lh     = font_line_h()
    local font_h = Theme.TextHeight(win, FONT_ID)
    local _, body_top = Theme.BodyMetrics(win, FONT_ID, font_h, 1)

    local tab_h    = math.max(TAB_H_MIN,    lh + 8)
    local info_h   = math.max(INFO_H_MIN,   lh + 4)
    local status_h = math.max(STATUS_H_MIN, lh + 4)

    local tab_top  = body_top
    local tab_bot  = body_top + tab_h
    local info_top = tab_bot + 1
    local info_bot = info_top + info_h
    local list_top = info_bot + PAD_TOP
    local list_bot = _height - PAD_BOTTOM - status_h - 2
    local status_y = _height - PAD_BOTTOM - status_h

    -- status_h is the 9th value; used by the expand-mode chrome height calc.
    return body_top, tab_top, tab_bot, info_top, info_bot, list_top, list_bot, status_y, status_h
end

-- ─── TAB VISIBILITY ──────────────────────────────────────────────────────────

-- Single-tab mode ('xset win tabs single'): one tab, following whichever of
-- quest/CP/GQ is currently active, instead of three clickable ones. Reusing
-- visible_tabs/ensure_active_tab_visible for this rather than a parallel
-- mechanism -- they already do exactly "show only what is_tab_visible allows,
-- fall back to _active_tab's first visible choice" -- means every caller of
-- either keeps working unchanged; only the definition of "visible" needs to
-- change; only the currently active tab is a tab at all.
local function is_tab_visible(key)
    if snd_get_setting("tab_mode", "multi") == "single" then
        return key == _active_tab
    end
    if key == "quest" then return true end
    return snd_get_setting("tab_show_" .. key, "on") == "on"
end

local function visible_tabs()
    local t = {}
    for _, tab in ipairs(TABS) do
        if is_tab_visible(tab.key) then t[#t + 1] = tab end
    end
    return t
end

local function ensure_active_tab_visible()
    if is_tab_visible(_active_tab) then return end
    local vt = visible_tabs()
    _active_tab = vt[1] and vt[1].key or "quest"
end

-- ─── DRAW: REWARD SUMMARY ────────────────────────────────────────────────────

local function draw_reward_summary(data, list_top, list_bot)
    local lh  = font_line_h()
    local x   = PAD_LEFT + EDGE_W + 3
    local y   = list_top + 2

    local act_label = (data.activity == "cp")    and "Campaign"
                   or (data.activity == "gq")    and "Global Quest"
                   or (data.activity == "quest") and "Quest"
                   or "Activity"
    local dur_str = (data.duration_secs and data.duration_secs > 0)
                    and ("  " .. format_duration(data.duration_secs)) or ""
    if y < list_bot then
        WindowText(win, FONT_ID, act_label .. " Complete" .. dur_str,
                   x, y, 0, 0, 0x44CC44, false)
    end
    y = y + lh + 2
    if y < list_bot then
        WindowLine(win, PAD_LEFT, y, _width - PAD_RIGHT, y, 0x1A3A20, miniwin.pen_solid, 1)
    end
    y = y + 4

    local function reward_row(label, value, col)
        if not value or value == 0 then return end
        if y >= list_bot then return end
        local lw = WindowText(win, FONT_ID, label, x, y, 0, 0, 0x506070, false)
        WindowText(win, FONT_ID, commas(value), x + lw + 4, y, 0, 0, col, false)
        y = y + lh + 1
    end

    local qp_total = (data.qp or 0) + (data.qp_bonus or 0)
    if qp_total > 0 and y < list_bot then
        local qp_str = commas(qp_total)
        if (data.qp_bonus or 0) > 0 then
            qp_str = qp_str .. "  (+" .. commas(data.qp_bonus) .. " daily bonus)"
        end
        local lw = WindowText(win, FONT_ID, "QP:     ", x, y, 0, 0, 0x506070, false)
        WindowText(win, FONT_ID, qp_str, x + lw + 4, y, 0, 0, 0xFFCC44, false)
        y = y + lh + 1
    end
    reward_row("Gold:   ", data.gold,   0xFFD700)
    reward_row("TP:     ", data.tp,     0x44AAFF)
    reward_row("Trains: ", data.trains, 0x88FF88)
    reward_row("Pracs:  ", data.pracs,  0xFFAAAA)
end

-- ─── DRAW: TAB BAR ───────────────────────────────────────────────────────────

local function count_alive(list)
    if not list or #list == 0 then return 0 end
    local n = 0
    for _, e in ipairs(list) do
        if e.is_dead ~= "yes" then n = n + 1 end
    end
    return n
end

local function tab_label(tab)
    local key = tab.key
    if key == "cp" then
        local parts = { "CP" }
        local lv = tonumber(type(cp_info_level) ~= "nil" and cp_info_level or 0)
        if lv and lv > 0 then parts[#parts + 1] = "Lv" .. lv end
        local alive = count_alive(_cp_list)
        if alive > 0 then parts[#parts + 1] = tostring(alive) end
        return table.concat(parts, " ")

    elseif key == "gq" then
        local parts = { "GQ" }
        local gqid = (type(gqid_joined) == "string" and gqid_joined ~= "-1") and gqid_joined or nil
        if gqid then parts[#parts + 1] = "#" .. gqid end
        local mn = tonumber(type(gq_info_minlvl) ~= "nil" and gq_info_minlvl or 0)
        local mx = tonumber(type(gq_info_maxlvl) ~= "nil" and gq_info_maxlvl or 0)
        if mn and mx and mn > 0 then parts[#parts + 1] = mn .. "-" .. mx end
        local alive = count_alive(_gq_list)
        if alive > 0 then parts[#parts + 1] = tostring(alive) end
        return table.concat(parts, " ")

    else
        local qt    = (type(quest_target) == "table") and quest_target or nil
        local qstat = qt and tostring(qt.qstat or "1") or "1"
        if     qstat == "0" then return "QST ready"
        elseif qstat == "2" then return "QST"
        elseif qstat == "3" then return "QST done!"
        else
            local nqt = type(next_quest_time) == "number" and next_quest_time or nil
            if nqt then
                local remaining = math.max(0, math.ceil((nqt - os.time()) / 60))
                if remaining > 0 then return "QST " .. remaining .. "m" end
                return "QST ready"
            end
            return "QST"
        end
    end
end

local function draw_tab_bar(tab_top, tab_bot)
    for _, tab in ipairs(TABS) do WindowDeleteHotspot(win, tab.hs) end
    ensure_active_tab_visible()

    local vtabs    = visible_tabs()
    local usable_w = _width - PAD_LEFT - PAD_RIGHT
    local tab_w    = math.floor(usable_w / math.max(1, #vtabs))
    local lh       = font_line_h()

    for i, tab in ipairs(vtabs) do
        local tx1   = PAD_LEFT + (i - 1) * tab_w
        local tx2   = (i == #vtabs) and (_width - PAD_RIGHT - 1) or (tx1 + tab_w - 2)
        local active = (_active_tab == tab.key)
        -- In single-tab mode the one tab there is counts as "active"
        -- trivially (it's the only visible entry, by construction), but it
        -- can still be showing cp/gq while a quest event fires -- with no
        -- separate quest tab to flash instead. So there, flash it regardless
        -- of the active check, whenever it isn't already showing quest.
        local flashing
        if snd_get_setting("tab_mode", "multi") == "single" then
            flashing = (tab.key ~= "quest") and _quest_flash_on
        else
            flashing = (tab.key == "quest") and (not active) and _quest_flash_on
        end

        local bg = active and Theme.PRIMARY_BODY or Theme.SECONDARY_BODY
        if flashing then
            bg = ColourNameToRGB(snd_get_setting("color_tab_flash", "#FFA500"))
        end
        WindowRectOp(win, 2, tx1, tab_top + 2, tx2, tab_bot - 1, bg)

        if active then
            WindowLine(win, tx1 + 1, tab_top + 2, tx2 - 1, tab_top + 2,
                accent_col(tab.key), miniwin.pen_solid, 2)
        else
            WindowLine(win, tx1, tab_bot - 1, tx2, tab_bot - 1,
                accent2_col(), miniwin.pen_solid, 1)
        end

        if not active and i < #vtabs and _active_tab ~= vtabs[i + 1].key then
            WindowLine(win, tx2 + 1, tab_top + 6, tx2 + 1, tab_bot - 6,
                Theme.THREE_D_SOFTSHADOW, miniwin.pen_solid, 1)
        end

        local label = tab_label(tab)
        local tw    = WindowTextWidth(win, FONT_ID, label)
        local tx    = tx1 + math.max(0, math.floor((tx2 - tx1 - tw) / 2))
        local tab_h = tab_bot - tab_top
        local ty    = tab_top + 2 + math.max(0, math.floor(((tab_h - 2) - lh) / 2))
        local fg    = active and Theme.THREE_D_SURFACE_DETAIL or Theme.BODY_TEXT
        WindowText(win, FONT_ID, label, tx, ty, tx2, 0, fg, false)

        WindowAddHotspot(win, tab.hs,
            tx1, tab_top + 2, tx2, tab_bot - 1,
            "", "", "", "", "snd_tab_click",
            tab.tooltip .. "\nLeft-click: switch  Right-click: options",
            miniwin.cursor_hand, 0)
    end

    WindowLine(win, 0, tab_bot, _width, tab_bot, Theme.THREE_D_SOFTSHADOW, miniwin.pen_solid, 1)
end

-- ─── DRAW: INFO BAR ──────────────────────────────────────────────────────────

local function clear_info_hotspots()
    for _, id in ipairs(_info_hotspot_ids) do WindowDeleteHotspot(win, id) end
    _info_hotspot_ids = {}
end

local function draw_info_bar(info_top, info_bot)
    clear_info_hotspots()
    WindowRectOp(win, 2, 0, info_top, _width, info_bot, info_bg_col())
    WindowLine(win, 0, info_top, _width, info_top, accent2_col(), miniwin.pen_solid, 1)

    local col_tnl       = ColourNameToRGB(snd_get_setting("color_info_tnl",          "#C0C0C0"))
    local col_nx        = ColourNameToRGB(snd_get_setting("color_info_nx",            "#00DD44"))
    local col_today_lbl = ColourNameToRGB(snd_get_setting("color_info_today_label",   "#506070"))
    local col_today_val = ColourNameToRGB(snd_get_setting("color_info_today_val",     "#87CEFA"))

    local lh     = font_line_h()
    local info_h = info_bot - info_top
    local ty     = info_top + math.max(0, math.floor((info_h - lh) / 2))
    local x      = PAD_LEFT

    if noexp_onoff == "on" then
        x = x + WindowText(win, FONT_ID, "NX:ON ", x, ty, 0, 0, col_nx, false) + 4
    end

    local tnl = tonumber(gmcp("char.status.tnl")) or 0
    x = x + WindowText(win, FONT_ID, "TNL:" .. fmt_n(tnl), x, ty, 0, 0, col_tnl, false) + 6

    local cutoff = tonumber(anex_tnl_cutoff) or 0
    if cutoff > 0 or (type(anex_automatic_onoff) == "string" and anex_automatic_onoff == "on") then
        local btn_col = 0x00B4E0
        local cut_col = cutoff > 0 and col_today_val or 0x444444

        local up_str = "[+]"
        local up_w   = WindowTextWidth(win, FONT_ID, up_str)
        WindowText(win, FONT_ID, up_str, x, ty, 0, 0, btn_col, false)
        local hs_up  = "snd_tnl_up"
        table.insert(_info_hotspot_ids, hs_up)
        WindowDeleteHotspot(win, hs_up)
        WindowAddHotspot(win, hs_up, x - 1, info_top + 1, x + up_w + 1, info_bot - 1,
            "", "", "", "", "snd_tnl_up_click",
            "Increase TNL cutoff by " .. TNL_STEP .. " (current: " .. cutoff .. ")\nxset noexp N to set precisely",
            miniwin.cursor_hand, 0)
        x = x + up_w + 2

        local cut_str = cutoff > 0 and fmt_n(cutoff) or "off"
        local cut_w   = WindowTextWidth(win, FONT_ID, cut_str)
        WindowText(win, FONT_ID, cut_str, x, ty, 0, 0, cut_col, false)
        x = x + cut_w + 2

        local dn_str = "[-]"
        local dn_w   = WindowTextWidth(win, FONT_ID, dn_str)
        WindowText(win, FONT_ID, dn_str, x, ty, 0, 0, btn_col, false)
        local hs_dn  = "snd_tnl_down"
        table.insert(_info_hotspot_ids, hs_dn)
        WindowDeleteHotspot(win, hs_dn)
        WindowAddHotspot(win, hs_dn, x - 1, info_top + 1, x + dn_w + 1, info_bot - 1,
            "", "", "", "", "snd_tnl_down_click",
            "Decrease TNL cutoff by " .. TNL_STEP .. " (current: " .. cutoff .. ")\nxset noexp 0 to disable",
            miniwin.cursor_hand, 0)
        x = x + dn_w + 2
    end

    local cp_tot = type(today_cp_total)     == "number" and today_cp_total     or nil
    local cp_sh  = type(today_cp_superhero) == "number" and today_cp_superhero or nil
    if cp_tot or cp_sh then
        x = x + 6
        x = x + WindowText(win, FONT_ID, "Today:", x, ty, 0, 0, col_today_lbl, false) + 2
        WindowText(win, FONT_ID,
            tostring(cp_tot or 0) .. "/" .. tostring(cp_sh or 0),
            x, ty, 0, 0, col_today_val, false)
    end

    WindowLine(win, 0, info_bot, _width, info_bot, Theme.THREE_D_SOFTSHADOW, miniwin.pen_solid, 1)
end

-- ─── DRAW: TARGET ROW ────────────────────────────────────────────────────────

-- ─── COLUMN VISIBILITY ───────────────────────────────────────────────────────
--
-- The index, mob and destination columns are fixed: without them a row cannot
-- be clicked, read, or acted on. Everything else is the player's to turn off,
-- because what is worth screen width depends entirely on how they play -- a
-- narrow window with route optimization off wastes a column on hop counts that
-- are never populated.
--
-- "kw" is off by default and is the exception in kind: it shows the keyword
-- that would actually be sent for a target. It exists so a wrong keyword can
-- be seen rather than deduced from a command that quietly does nothing.
LIST_COLUMNS = {
    { key = "hops", setting = "col_show_hops", label = "Hops", default = "on",
      desc = "hops from the previous stop (needs route optimization)" },
    { key = "diff", setting = "col_show_diff", label = "Diff", default = "on",
      desc = "difficulty of reaching the mob, 1-5" },
    { key = "kw",   setting = "col_show_kw",   label = "Kw",   default = "off",
      desc = "the keyword that would be sent for this target",
      -- Sized in characters rather than as a share of the row: a keyword is
      -- short and its useful width does not scale with the window. Most fit
      -- in fifteen; the ones that do not are worth widening for rather than
      -- taking space from the mob name on every other row.
      width_setting = "col_kw_width", width_default = 15,
      width_min = 4, width_max = 40 },
    { key = "type", setting = "col_show_type", label = "Type", default = "on",
      desc = "whether 'go' routes to the mob's room or the area entrance" },
}

function list_column_def(key)
    for _, c in ipairs(LIST_COLUMNS) do
        if c.key == key then return c end
    end
    return nil
end

function list_column_width(key)
    local def = list_column_def(key)
    if not def or not def.width_setting then return nil end
    local n = tonumber(snd_get_setting(def.width_setting,
                                       tostring(def.width_default)))
    if not n then n = def.width_default end
    return math.max(def.width_min, math.min(def.width_max, math.floor(n)))
end

function list_column_shown(key)
    local def = list_column_def(key)
    if not def then return true end
    return snd_get_setting(def.setting, def.default) ~= "off"
end

-- The pixels the optional columns claim outright, before anything is shared
-- out. Hops and Diff are fixed labels; the keyword column is a character count.
-- The mob and destination columns divide whatever is left, so this is exactly
-- the amount the window has to gain or lose for them to keep the room they had.
-- Only ever reached from the redraw, which has already established that the
-- window exists; checking again here would be noise, and it made the measure
-- untestable on its own.
local function fixed_columns_width()
    local w = 0
    if list_column_shown("hops") then
        w = w + WindowTextWidth(win, FONT_ID, "9999 ")
    end
    if list_column_shown("diff") then
        w = w + WindowTextWidth(win, FONT_ID, "Diff ")
    end
    if list_column_shown("kw") then
        w = w + WindowTextWidth(win, FONT_ID,
                                string.rep("W", list_column_width("kw"))) + 4
    end
    return w
end

-- Grow or shrink the window by whatever the column set just cost or freed.
--
-- Adjusting by the DIFFERENCE rather than recomputing an ideal width is the
-- point: the window's width is the player's, set by dragging, and the mob and
-- destination columns should keep the room they had. Turning the keyword
-- column on widens the window by a keyword's worth instead of taking it out of
-- the mob name; turning it off gives the same pixels back.
--
-- Driven from the redraw rather than the command, so it covers the settings
-- window and anything else that changes a column without going through
-- 'xset cols'.
local function fit_window_to_columns()
    local want = fixed_columns_width()
    if _col_fixed_w == nil then
        -- First draw: adopt the current layout without moving anything. The
        -- saved width already accounts for whatever columns were on.
        _col_fixed_w = want
        return
    end
    local delta = want - _col_fixed_w
    _col_fixed_w = want
    if delta == 0 then return end

    -- Never off the edge of the screen, and never below the minimum: a window
    -- that grew past either would be worse than a cramped column.
    local max_w = (_screen_w > 0) and math.floor(_screen_w * 0.95) or nil
    local new_w = _width + delta
    if max_w then new_w = math.min(new_w, max_w) end
    new_w = math.max(MIN_W, new_w)
    if new_w == _width then return end

    _width = new_w
    WindowResize(win, _width, _height, Theme.SECONDARY_BODY)
    SetVariable("snd_win_width", tostring(_width))
end

-- Pixel x positions for the table layout.
--
-- Returns a table rather than a fixed tuple: with columns coming and going,
-- positional returns silently shift meaning when one is hidden, which is
-- exactly the kind of mistake that draws a row on top of itself.
local function list_col_pos(row_x, row_right)
    local tx     = row_x + EDGE_W + 3
    local rx     = row_right or (_width - PAD_RIGHT)
    local idx_w  = WindowTextWidth(win, FONT_ID, "88) ")
    local hops_w = list_column_shown("hops") and WindowTextWidth(win, FONT_ID, "9999 ") or 0
    local diff_w = list_column_shown("diff") and WindowTextWidth(win, FONT_ID, "Diff ") or 0

    local rest    = rx - tx - idx_w - hops_w - diff_w
    local show_kw = list_column_shown("kw")

    -- The keyword takes a fixed number of characters, not a share of the row,
    -- and the mob name keeps its share of whatever is left. A proportional
    -- keyword column grew with the window without ever needing to and shrank
    -- below usefulness on a narrow one.
    local kw_w = 0
    if show_kw then
        kw_w = WindowTextWidth(win, FONT_ID,
                               string.rep("W", list_column_width("kw"))) + 4
        -- Never at the mob name's expense past the point of legibility: the
        -- row exists to name a mob.
        kw_w = math.min(kw_w, math.floor(rest * 0.40))
    end
    local mob_w = math.floor((rest - kw_w) * 0.54)

    local pos = { tx = tx, rx = rx, idx = tx }
    local x = tx + idx_w
    if hops_w > 0 then pos.hops = x; x = x + hops_w end
    if diff_w > 0 then pos.diff = x; x = x + diff_w end
    pos.mob = x; x = x + mob_w
    if show_kw then pos.kw = x; x = x + kw_w end
    pos.dest = x
    -- Where the mob column has to stop, which is no longer always the
    -- destination column.
    pos.after_mob = pos.kw or pos.dest
    return pos
end

local function draw_list_header(y, lh, row_right)
    local c   = list_col_pos(PAD_LEFT, row_right)
    local ty  = y + ROW_PAD
    local col = 0x3A5878
    WindowText(win, FONT_ID, "#",   c.tx,  ty, 0, 0, col, false)
    if c.hops then WindowText(win, FONT_ID, "Hops", c.hops, ty, 0, 0, col, false) end
    if c.diff then WindowText(win, FONT_ID, "Diff", c.diff, ty, 0, 0, col, false) end
    WindowText(win, FONT_ID, "Mob", c.mob, ty, 0, 0, col, false)
    if c.kw then WindowText(win, FONT_ID, "Kw", c.kw, ty, 0, 0, col, false) end
    WindowText(win, FONT_ID,
        list_column_shown("type") and "Type  Dest" or "Dest",
        c.dest, ty, 0, 0, col, false)
    WindowLine(win, PAD_LEFT, y + lh - 1, _width - PAD_RIGHT, y + lh - 1,
               0x1A2A3A, miniwin.pen_solid, 1)
end

local function draw_target_row(entry, index, row_x, row_y, row_h, row_right)
    if (index % 2) == 0 then
        local alt = ColourNameToRGB(snd_get_setting("color_alternating_row", "#0C0C1A"))
        if alt ~= 0 then WindowRectOp(win, 2, 0, row_y, _width, row_y + row_h, alt) end
    end

    local ec = edge_color(entry, index)
    WindowRectOp(win, 2, row_x, row_y + 1, row_x + EDGE_W, row_y + row_h - 1, ec)

    local c   = list_col_pos(row_x, row_right)
    local rx  = c.rx
    local ty  = row_y + ROW_PAD
    local clr = entry_color(entry, index)

    -- ── Index column ──────────────────────────────────────────────────────────
    WindowText(win, FONT_ID, string.format("%2d) ", index), c.tx, ty, 0, 0, 0x506070, false)

    -- ── Hops column ───────────────────────────────────────────────────────────
    -- Hop count from the previous stop (or from current room for the first entry).
    -- Populated by optimize_target_order; nil when pathing did not run.
    local hops = entry.path_hops
    if c.hops and hops and hops < 99999 then
        WindowText(win, FONT_ID, tostring(hops), c.hops, ty, 0, 0, 0x4488AA, false)
    elseif c.hops and hops then
        WindowText(win, FONT_ID, "?", c.hops, ty, 0, 0, 0x555555, false)
    end

    -- ── Diff column ───────────────────────────────────────────────────────────
    -- Difficulty rating (1-5), populated by attach_difficulty in targets.lua:
    -- the mob's own rating when it has one, otherwise its area's. Left blank
    -- when the area is unknown and the mob is unrated.
    local diff = entry.difficulty
    if c.diff and diff then
        WindowText(win, FONT_ID, tostring(diff), c.diff, ty, 0, 0,
            DIFF_COLS[diff] or DIFF_COLS[1], false)
    end

    -- ── Mob column ────────────────────────────────────────────────────────────
    local is_dead       = entry.is_dead == "yes"
    local player_killed = entry.player_killed == true
    local qty           = tonumber(entry.qty) or 1
    local char_w        = math.max(1, WindowTextWidth(win, FONT_ID, "W"))

    -- Computed here rather than beside the destination column, which is where
    -- it used to be: the mob column is drawn first, so an asterisk decided
    -- later could never appear. The text list marks express targets this way
    -- and the window did not, which is the half that gets looked at.
    local express = type(is_express_target) == "function"
                    and is_express_target(entry)

    local cx = c.mob
    if entry.unlikely then
        cx = cx + WindowText(win, FONT_ID, "(U) ", cx, ty, 0, 0, 0x506070, false)
    end
    if is_dead and not player_killed then
        cx = cx + WindowText(win, FONT_ID, "[D] ", cx, ty, 0, 0, 0xCC8800, false)
    end
    if express then
        -- Same asterisk as the printed list, and the same gold as the "Mob "
        -- destination type it corresponds to.
        cx = cx + WindowText(win, FONT_ID, "*", cx, ty, 0, 0, 0xFFD700, false)
    end

    local qty_sfx    = (qty > 1) and (" x" .. qty) or ""
    local sfx_w      = WindowTextWidth(win, FONT_ID, qty_sfx)
    local mob_avail  = c.after_mob - cx - sfx_w - 4
    local mob_max_ch = math.max(4, math.floor(mob_avail / char_w))
    local mob_str    = ellipsify(entry.mob or "?", mob_max_ch)

    local mob_x0 = cx
    cx = cx + WindowText(win, FONT_ID, mob_str, cx, ty, 0, 0, clr, false)
    local mob_x1 = cx

    if qty_sfx ~= "" then
        WindowText(win, FONT_ID, qty_sfx, cx, ty, 0, 0, 0x708090, false)
    end

    if player_killed then
        local sy = ty + math.floor(font_line_h() / 2)
        WindowLine(win, mob_x0, sy, mob_x1, sy, clr, miniwin.pen_solid, 1)
    end

    -- ── Keyword column ────────────────────────────────────────────────────────
    -- What would actually be sent for this target. Shown so a keyword that
    -- does not work can be seen and corrected with 'xset kw', rather than
    -- inferred from a scan or hunt that quietly finds nothing.
    if c.kw then
        local kw_avail  = c.dest - c.kw - 4
        local kw_max_ch = math.max(3, math.floor(kw_avail / char_w))
        local kw_str    = entry.kw
        if type(kw_str) ~= "string" or kw_str == "" then
            -- Distinct from a keyword that is merely odd: there is none, and
            -- commands needing one will refuse rather than misfire.
            WindowText(win, FONT_ID, ellipsify("(none)", kw_max_ch),
                       c.kw, ty, 0, 0, 0x804040, false)
        else
            WindowText(win, FONT_ID, ellipsify(kw_str, kw_max_ch),
                       c.kw, ty, 0, 0, 0x9088C0, false)
        end
    end

    -- ── Dest column ───────────────────────────────────────────────────────────
    local dest_str, dest_clr
    if entry.link_type == "area" then
        dest_str = tostring(entry.arid or "?")
        dest_clr = 0x708090
    elseif entry.link_type == "room" then
        dest_str = (entry.roomName or "?") .. " (" .. (entry.arid or "?") .. ")"
        dest_clr = 0x66BB88
    else
        dest_str = entry.location or "unknown"
        dest_clr = 0x806060
    end

    -- Destination type prefix: "Mob " (gold) = go routes to mob's kill room,
    --                          "Area" (grey) = go routes to area start room only.
    local ax = c.dest
    if entry.link_type ~= "unknown" and list_column_shown("type") then
        local dt_str = express and "Mob " or "Area"
        local dt_clr = express and 0xFFD700 or 0x808080
        ax = ax + WindowText(win, FONT_ID, dt_str, ax, ty, 0, 0, dt_clr, false)
        ax = ax + WindowText(win, FONT_ID, "  ", ax, ty, 0, 0, 0, false)
    end

    local dest_avail  = rx - ax - 4
    local dest_max_ch = math.max(4, math.floor(dest_avail / char_w))
    ax = ax + WindowText(win, FONT_ID, ellipsify(dest_str, dest_max_ch),
                         ax, ty, 0, 0, dest_clr, false)

    if entry.rlink_note then
        WindowText(win, FONT_ID, " {" .. entry.rlink_note .. "}",
                   ax, ty, 0, 0, 0x5858CC, false)
    end

    -- ── Hotspot ───────────────────────────────────────────────────────────────
    if entry.link_type ~= "unknown" then
        local hs_id = "snd_row_" .. index
        table.insert(_row_hotspot_ids, hs_id)
        WindowDeleteHotspot(win, hs_id)
        WindowAddHotspot(win, hs_id,
            row_x - 1, row_y + 1,
            rx, row_y + row_h,
            "", "", "", "", "snd_row_click",
            "Click: xcp " .. index, miniwin.cursor_hand, 0)
        WindowScrollwheelHandler(win, hs_id, "snd_list_scroll")
    end
end

-- ─── SCROLLBAR ───────────────────────────────────────────────────────────────
-- Wraps the stock ScrollBar class.  Called from draw_list.
-- The update callback (drag / arrow buttons) fires redraw_list_area() so only
-- the list pixels change — no chrome flicker.

local function update_scrollbar(total_rows, visible_rows, offset, sb_x, sb_top, sb_bot)
    if not _scrollbar then
        _scrollbar = ScrollBar.new(win, "snd", sb_x, sb_top, sb_x + SCROLLBAR_W, sb_bot)
        _scrollbar:addUpdateCallback(nil, function(step)
            local tab = _active_tab
            if tab == "cp" or tab == "gq" then
                _scroll_offset[tab] = step - 1
                redraw_list_area()
            end
        end)
    else
        _scrollbar:setRect(sb_x, sb_top, sb_x + SCROLLBAR_W, sb_bot)
    end
    _scrollbar:setScroll(offset + 1, visible_rows, total_rows, true)
    _scrollbar:draw(true)
end

-- ─── DRAW: CP / GQ LIST ──────────────────────────────────────────────────────

draw_list = function(list, list_top, list_bot)
    for _, id in ipairs(_row_hotspot_ids) do WindowDeleteHotspot(win, id) end
    _row_hotspot_ids = {}

    local sub_y = list_top
    if _active_tab == "cp" then
        local lv = tonumber(type(cp_info_level) ~= "nil" and cp_info_level or 0)
        if lv and lv > 0 then
            local lh2 = font_line_h()
            WindowText(win, FONT_ID, "Campaign taken at level " .. lv,
                PAD_LEFT + EDGE_W + 3, sub_y, 0, 0, 0x446688, false)
            sub_y = sub_y + lh2
            WindowLine(win, PAD_LEFT, sub_y, _width - PAD_RIGHT, sub_y,
                0x1A2A3A, miniwin.pen_solid, 1)
            sub_y = sub_y + 2
        end
    end

    if not list or #list == 0 then
        if _last_reward and _last_reward.activity == _active_tab then
            draw_reward_summary(_last_reward, sub_y, list_bot)
            return
        end
        local hint = "Run  cp info  or  gq info  to load targets."
        local tw   = WindowTextWidth(win, FONT_ID, hint)
        local cx   = math.max(PAD_LEFT, math.floor((_width - tw) / 2))
        local cy   = sub_y + math.floor((list_bot - sub_y - font_line_h()) / 2)
        WindowText(win, FONT_ID, hint, cx, cy, 0, 0, Theme.BODY_TEXT, false)
        return
    end

    local lh   = font_line_h() + ROW_PAD * 2
    local mode = snd_get_setting("list_display_mode", "expand")

    if mode == "expand" then
        draw_list_header(sub_y, lh, nil)
        local y = sub_y + lh
        for i, entry in ipairs(list) do
            draw_target_row(entry, i, PAD_LEFT, y, lh)
            y = y + lh
        end
    else
        local row_right = _width - PAD_RIGHT - SCROLLBAR_W - 2
        draw_list_header(sub_y, lh, row_right)
        local rows_top = sub_y + lh

        local avail   = list_bot - rows_top
        local visible = math.max(1, math.floor(avail / lh))
        local max_off = math.max(0, #list - visible)
        local offset  = math.min(_scroll_offset[_active_tab] or 0, max_off)
        _scroll_offset[_active_tab] = offset

        local y = rows_top
        for i = offset + 1, math.min(#list, offset + visible) do
            draw_target_row(list[i], i, PAD_LEFT, y, lh, row_right)
            y = y + lh
        end

        -- Register bg after rows so row hotspots win on overlap (first = higher priority).
        local hs_bg = "snd_list_bg"
        table.insert(_row_hotspot_ids, hs_bg)
        WindowDeleteHotspot(win, hs_bg)
        WindowAddHotspot(win, hs_bg,
            PAD_LEFT, rows_top, _width - PAD_RIGHT - SCROLLBAR_W, list_bot,
            "", "", "", "", "", "", miniwin.cursor_arrow, 0)
        WindowScrollwheelHandler(win, hs_bg, "snd_list_scroll")

        local sb_x = _width - PAD_RIGHT - SCROLLBAR_W
        update_scrollbar(#list, visible, offset, sb_x, rows_top, list_bot)
    end
end

-- ─── DRAW: QUEST TAB ─────────────────────────────────────────────────────────

local function draw_quest_tab(list_top, list_bot)
    for _, id in ipairs(_row_hotspot_ids) do WindowDeleteHotspot(win, id) end
    _row_hotspot_ids = {}

    local qt = (type(quest_target) == "table") and quest_target or nil
    if not qt then
        WindowText(win, FONT_ID, "  Quest data unavailable.",
            PAD_LEFT, list_top, 0, 0, Theme.BODY_TEXT, false)
        return
    end

    local lh    = font_line_h()
    local qstat = tostring(qt.qstat or "1")

    if qstat == "0" then
        local col = ColourNameToRGB(snd_get_setting("color_quest_available", "#1E90FF"))
        WindowText(win, FONT_ID, "  You may quest again.", PAD_LEFT, list_top, 0, 0, col, false)
        if _last_reward and _last_reward.activity == "quest" then
            draw_reward_summary(_last_reward, list_top + lh + 4, list_bot)
        end

    elseif qstat == "2" then
        local targeted = type(is_quest_mob_targeted) == "function" and is_quest_mob_targeted()
        local fg_mob   = ColourNameToRGB(
            targeted and snd_get_setting("color_targeted", "#FF4000")
                      or snd_get_setting("color_normal",   "#E0E0E0"))
        local y = list_top

        local ec = targeted and ColourNameToRGB(snd_get_setting("color_targeted", "#FF4000"))
                              or 0x005C00
        WindowRectOp(win, 2, PAD_LEFT, y + 1, PAD_LEFT + EDGE_W, y + lh - 1, ec)
        WindowText(win, FONT_ID, "  Q) " .. (qt.mob or "Unknown"),
            PAD_LEFT + EDGE_W + 3, y, 0, 0, fg_mob, false)

        local hs_q = "snd_row_q"
        table.insert(_row_hotspot_ids, hs_q)
        WindowDeleteHotspot(win, hs_q)
        WindowAddHotspot(win, hs_q, PAD_LEFT - 1, y + 1, _width - PAD_RIGHT, y + lh,
            "", "", "", "", "snd_row_click", "Click: target quest mob", miniwin.cursor_hand, 0)

        y = y + lh
        if y < list_bot then
            WindowText(win, FONT_ID, "     Room:  " .. (qt.room or "Unknown"),
                PAD_LEFT, y, 0, 0, Theme.BODY_TEXT, false)
        end
        y = y + lh
        if y < list_bot then
            WindowText(win, FONT_ID, "     Area:  " .. (qt.areaName or qt.arid or "Unknown"),
                PAD_LEFT, y, 0, 0, Theme.BODY_TEXT, false)
        end

    elseif qstat == "3" then
        local col = ColourNameToRGB(snd_get_setting("color_quest_complete", "#7CFC00"))
        WindowText(win, FONT_ID, "  Quest complete - turn it in!", PAD_LEFT, list_top, 0, 0, col, false)

    else
        WindowText(win, FONT_ID, "  Quest not ready.", PAD_LEFT, list_top, 0, 0, Theme.BODY_TEXT, false)
        if _last_reward and _last_reward.activity == "quest" then
            draw_reward_summary(_last_reward, list_top + lh + 4, list_bot)
        end
    end
end

-- ─── DRAW: STATUS BAR ────────────────────────────────────────────────────────

local function active_history_type()
    if     _active_tab == "cp"    then return HISTORY_TYPE_CP
    elseif _active_tab == "gq"    then return HISTORY_TYPE_GQ
    elseif _active_tab == "quest" then return HISTORY_TYPE_QUEST
    end
    return nil
end

local function draw_status_bar(status_y)
    WindowLine(win, 0, status_y, _width, status_y, Theme.THREE_D_SOFTSHADOW, miniwin.pen_solid, 1)
    WindowRectOp(win, 2, 0, status_y + 1, _width, _height, status_bg_col())

    local lh       = font_line_h()
    local status_h = _height - status_y
    local row_y    = status_y + math.max(1, math.floor(((status_h - 1) - lh) / 2))

    local col_text  = ColourNameToRGB(snd_get_setting("color_status_text",  "#506070"))
    local col_empty = ColourNameToRGB(snd_get_setting("color_status_empty", "#2A3540"))

    local htype = active_history_type()
    if not htype then return end

    local left_str = "  No history recorded yet."
    local left_col = col_empty
    if type(history_quickstats) == "function" then
        local stats = history_quickstats(htype)
        if stats and stats.total > 0 then
            local label = (_active_tab == "cp") and "CP"
                       or (_active_tab == "gq") and "GQ"
                       or "Quest"
            left_str = string.format("  %s: %d done  avg %s  best %s",
                label, stats.total,
                format_duration(stats.avg_secs),
                format_duration(stats.min_secs))
            left_col = col_text
        end
    end
    WindowText(win, FONT_ID, left_str, 0, row_y, 0, 0, left_col, false)

    local right_str
    local elapsed = type(history_elapsed) == "function" and history_elapsed(htype)
    if elapsed then
        local act_name = (_active_tab == "cp") and "Campaign"
                      or (_active_tab == "gq") and "Global Quest"
                      or "Quest"
        right_str = "Ongoing " .. act_name .. "  "
    else
        local dur = type(history_last_duration) == "function" and history_last_duration(htype)
        if dur then right_str = "Last: " .. format_duration(dur) .. "  " end
    end
    if right_str then
        local rw = WindowTextWidth(win, FONT_ID, right_str)
        WindowText(win, FONT_ID, right_str, math.max(0, _width - rw), row_y, 0, 0, col_text, false)
    end
end

-- ─── DRAW: PARTIAL REDRAW ────────────────────────────────────────────────────
-- Called by scroll events.  Redraws only the list area so chrome is untouched.

redraw_list_area = function()
    if not window_exists() then return end
    local _, _, _, _, _, list_top, list_bot = geometry()
    WindowRectOp(win, 2, 0, list_top, _width, list_bot, 0x000000)
    if     _active_tab == "cp" then draw_list(_cp_list, list_top, list_bot)
    elseif _active_tab == "gq" then draw_list(_gq_list, list_top, list_bot)
    end
    Repaint()
end

-- ─── DRAW: CONTENT DISPATCH ──────────────────────────────────────────────────

local function draw_content()
    local _, tab_top, tab_bot, info_top, info_bot, list_top, list_bot, status_y = geometry()
    draw_tab_bar(tab_top, tab_bot)
    draw_info_bar(info_top, info_bot)
    draw_status_bar(status_y)
    if     _active_tab == "cp"    then draw_list(_cp_list, list_top, list_bot)
    elseif _active_tab == "gq"    then draw_list(_gq_list, list_top, list_bot)
    elseif _active_tab == "quest" then draw_quest_tab(list_top, list_bot)
    end
end

-- ─── TITLE BAR BUTTONS ────────────────────────────────────────────────────────

-- [x] close, and [R] info-reset, painted on top of the title bar chrome.
--
-- [R] re-fetches CP/GQ info from the game. v5 had a button for this; v6 only
-- had the typed commands ('xg reload' / 'xgui reload'). Reported missing by
-- Selitos -- particularly useful on a room GQ, where stale info is easy to
-- end up looking at. Acts on whichever tab is active, the same way the typed
-- commands already split on cp/gq; nothing to reset on the quest tab, which
-- stays current on its own via GMCP, so the button is hidden there.
local function draw_title_bar_buttons()
    local body_top = geometry()
    local lh        = font_line_h()
    local btn_y     = math.max(0, math.floor((body_top - lh) / 2))

    local close_str = "[x]"
    local close_w   = WindowTextWidth(win, FONT_ID, close_str) + 4
    local close_x   = _width - close_w - 2
    WindowText(win, FONT_ID, close_str, close_x, btn_y, 0, 0, 0xAAAAAA, false)
    WindowDeleteHotspot(win, "snd_close_btn")
    WindowAddHotspot(win, "snd_close_btn",
        close_x - 1, 0, _width - 1, body_top,
        "", "", "", "", "xg_hide_window",
        "Hide window  (right-click title bar or tabs to restore)",
        miniwin.cursor_hand, 0)

    if _active_tab == "cp" or _active_tab == "gq" then
        local reset_str = "[R]"
        local reset_w   = WindowTextWidth(win, FONT_ID, reset_str) + 4
        local reset_x   = close_x - reset_w - 4
        WindowText(win, FONT_ID, reset_str, reset_x, btn_y, 0, 0, 0xAAAAAA, false)
        WindowDeleteHotspot(win, "snd_info_reset_btn")
        WindowAddHotspot(win, "snd_info_reset_btn",
            reset_x - 1, 0, reset_x + reset_w + 1, body_top,
            "", "", "", "", "snd_info_reset_click",
            "Re-fetch " .. (_active_tab == "cp" and "campaign" or "global quest") ..
                " info from the game",
            miniwin.cursor_hand, 0)
    else
        WindowDeleteHotspot(win, "snd_info_reset_btn")
    end
end

-- ─── MAIN DRAW ───────────────────────────────────────────────────────────────

function xg_draw_window()
    if not window_exists() then return end
    fit_window_to_columns()

    -- Expand mode: resize the window height to fit the full CP/GQ list.
    -- Only applies to the event tabs; settings is never expanded. Skipped
    -- entirely while rolled up (xg_collapse_window) -- otherwise this would
    -- resize straight back open on the very next draw.
    if not _collapsed and snd_get_setting("list_display_mode", "expand") == "expand" then
        local list = (_active_tab == "cp") and _cp_list
                  or (_active_tab == "gq") and _gq_list or nil
        if list and #list > 0 then
            local lh       = font_line_h() + ROW_PAD * 2
            local _, _, _, _, info_bot, _, _, _, status_h = geometry()
            local chrome_h = info_bot + status_h + PAD_BOTTOM + 4
            local lv       = _active_tab == "cp"
                and tonumber(type(cp_info_level) ~= "nil" and cp_info_level or 0) or 0
            local sub_h    = (lv and lv > 0) and (font_line_h() + 2) or 0
            local needed   = math.max(_min_expand_h,
                math.min(chrome_h + sub_h + (1 + #list) * lh,
                         math.floor((_screen_h or 1080) * 0.9)))
            if needed ~= _height then
                _height = needed
                WindowResize(win, _width, _height, Theme.SECONDARY_BODY)
            end
        end
    end

    WindowRectOp(win, 2, 0, 0, 0, 0, 0x000000)
    draw_content()

    Theme.DressWindow(win, FONT_ID, "Search & Destroy")
    Theme.AddResizeTag(win, 1, nil, nil,
        "snd_win_resize_down",
        "snd_win_resize_move",
        "snd_win_resize_up")

    draw_title_bar_buttons()

    Repaint()
end

-- ─── HOTSPOT CALLBACKS ───────────────────────────────────────────────────────

function snd_tab_click(flags, hotspot_id)
    local key = hotspot_id:match("^snd_tab_(.+)$")
    if not (key == "cp" or key == "gq" or key == "quest") then return end
    if bit.band(flags, miniwin.hotspot_got_rh_mouse) ~= 0 then
        snd_tab_right_click_menu(key); return
    end
    if key ~= _active_tab then _scroll_offset[key] = _scroll_offset[key] or 0 end
    _active_tab = key
    if key == "quest" then xg_stop_quest_flash() end
    xg_draw_window()
end

-- The [R] title-bar button: re-fetch info for whichever tab is active.
-- xg_draw_window() only shows the button at all on the cp/gq tabs, so
-- reaching here with anything else would mean a stale hotspot; do nothing.
function snd_info_reset_click(flags, hotspot_id)
    if _active_tab == "cp" and type(do_cp_info) == "function" then
        do_cp_info()
    elseif _active_tab == "gq" and type(do_gq_info) == "function" then
        do_gq_info()
    end
end

function snd_row_click(flags, hotspot_id)
    local right_click = bit.band(flags, miniwin.hotspot_got_rh_mouse) ~= 0
    if hotspot_id == "snd_row_q" then
        if right_click then
            snd_row_right_click_menu(nil)
        else
            Execute("xqt")
        end
        return
    end
    local idx = hotspot_id:match("^snd_row_(%d+)$")
    if not idx then return end
    if right_click then
        snd_row_right_click_menu(tonumber(idx))
    else
        Execute("xcp " .. idx)
    end
end

function snd_tnl_up_click(flags, hotspot_id)
    anex_tnl_cutoff = (tonumber(anex_tnl_cutoff) or 0) + TNL_STEP
    snd_set_setting("anex_tnl_cutoff", tostring(anex_tnl_cutoff), false)
    if type(anex_check_tnl_silent) == "function" then anex_check_tnl_silent() end
    xg_draw_window()
end

function snd_tnl_down_click(flags, hotspot_id)
    anex_tnl_cutoff = math.max(0, (tonumber(anex_tnl_cutoff) or 0) - TNL_STEP)
    snd_set_setting("anex_tnl_cutoff", tostring(anex_tnl_cutoff), false)
    if type(anex_check_tnl_silent) == "function" then anex_check_tnl_silent() end
    xg_draw_window()
end

-- ─── COLLAPSE / EXPAND ────────────────────────────────────────────────────────
--
-- 'xset win max|expand' / 'min|collapse' used to just flip list_display_mode
-- (whether the target list auto-grows to fit its content or scrolls at a
-- fixed height) -- a real, useful setting, but a different one, already
-- exposed on its own via the right-click menu's "Auto-Expand List" entry.
-- Neither form ever touched the window's own height, so despite the help
-- text promising a collapse to "its normal and minimized state", nothing
-- actually minimized.
--
-- This is that: collapse rolls the window up to just past the info (TNL)
-- bar -- tabs and TNL/NX status still visible, target list and status bar
-- hidden -- remembering the height it was at; expand restores it. Bypasses
-- the MIN_H floor deliberately: that guards against dragging the window
-- too small to use, not against a deliberate, code-computed roll-up.

-- Both return true when they actually changed anything, so the alias handler
-- (xg_window_command) can tell "just collapsed it" from "already was".
function xg_collapse_window()
    if _collapsed or not window_exists() then return false end
    local _, _, _, _, info_bot = geometry()
    _pre_collapse_h = _height
    _collapsed      = true
    _height         = info_bot + PAD_BOTTOM
    WindowResize(win, _width, _height, Theme.SECONDARY_BODY)
    xg_draw_window()
    xg_save_window_state()
    return true
end

function xg_expand_window()
    if not _collapsed or not window_exists() then return false end
    _collapsed      = false
    _height         = _pre_collapse_h or DEFAULT_H
    _pre_collapse_h = nil
    WindowResize(win, _width, _height, Theme.SECONDARY_BODY)
    xg_draw_window()
    xg_save_window_state()
    return true
end

-- ─── RESIZE ──────────────────────────────────────────────────────────────────

function snd_win_resize_down()
    -- A manual drag takes the window out of collapsed state: the height
    -- about to result from it is the user's, not xg_expand_window's saved one.
    _collapsed      = false
    _pre_collapse_h = nil
    _resize_sx = WindowInfo(win, 17)
    _resize_sy = WindowInfo(win, 18)
end

function snd_win_resize_move()
    if GetPluginVariable(PLUGIN_ID_LAYOUT, "lock_down_miniwindows") == "1" then return end
    local cx = WindowInfo(win, 17)
    local cy = WindowInfo(win, 18)
    _width    = math.max(MIN_W, _width  + cx - _resize_sx)
    _height   = math.max(MIN_H, _height + cy - _resize_sy)
    _resize_sx, _resize_sy = cx, cy
    WindowResize(win, _width, _height, Theme.SECONDARY_BODY)
    xg_draw_window()
end

function snd_win_resize_up()
    _min_expand_h = _height   -- user explicitly set this height; honor as expand-mode floor
    xg_draw_window()
    SaveState()
end

-- ─── RIGHT-CLICK MENUS ───────────────────────────────────────────────────────

-- Normalizes a main_target_list entry (idx is a number) or the quest row
-- (idx is nil) into the shape snd_row_right_click_menu needs. The quest
-- row's own record (quest_target) has no resolved room id of its own; one
-- is only available when current_target currently reflects the quest.
local function row_menu_entry(idx)
    if idx then
        return main_target_list[idx]
    end
    local qt = quest_target
    if type(qt) ~= "table" or not qt.mob then return nil end
    local roomid = nil
    if type(current_target) == "table" and current_target.activity == "quest" then
        roomid = current_target.roomid
    end
    return { mob = qt.mob, arid = qt.arid, roomid = roomid, link_type = "room" }
end

-- Right-click menu for one target list row (mob or quest). All actions
-- operate on the row's own entry.mob/entry.arid -- never current_room --
-- since a right-click can happen from anywhere, not just while standing in
-- the target's own zone. No 'checked' markers: see the comment above
-- snd_right_click_menu for why (WindowMenu's checked-item marker renders
-- as disabled/unclickable for at least one player).
function snd_row_right_click_menu(idx)
    local entry = row_menu_entry(idx)
    if not entry or not entry.mob or not entry.arid then return end

    local has_nohunt  = mob_has_tag(entry.mob, entry.arid, "nohunt")
    local has_nowhere = mob_has_tag(entry.mob, entry.arid, "nowhere")
    local has_noscan  = mob_has_tag(entry.mob, entry.arid, "noscan")
    local has_levelok = mob_has_tag(entry.mob, entry.arid, "levelok")
    local has_express = mob_has_tag(entry.mob, entry.arid, "express")

    local items = {
        { action = "nohunt",
          label  = (has_nohunt  and "Allow Hunt" or "Nohunt") },
        { action = "nowhere",
          label  = (has_nowhere and "Allow Where" or "Nowhere") },
        { action = "noscan",
          label  = (has_noscan  and "Allow Scan" or "Noscan") },
        { action = "levelok",
          label  = (has_levelok and "Unset Levelok" or "Set Levelok") },
        { action = "sep" },
        { action = "difficulty", label = "Set Difficulty..." },
    }

    if entry.roomid and tonumber(entry.roomid) and tonumber(entry.roomid) > 0 then
        items[#items + 1] = { action = "express",
            label = has_express and "Remove Express" or "Set Express" }
    end

    if entry.link_type == "area" then
        items[#items + 1] = { action = "area_difficulty", label = "Set Area Difficulty..." }
    end

    if idx and current_activity == "cp" then
        items[#items + 1] = { action = "sep" }
        items[#items + 1] = { action = "reroll", label = "Reroll This Target (Premonition)" }
    end

    local parts, label_map = {}, {}
    for _, it in ipairs(items) do
        if it.action == "sep" then parts[#parts + 1] = "-"
        else parts[#parts + 1] = it.label; label_map[it.label] = it.action end
    end

    local result = WindowMenu(win, WindowInfo(win, 14), WindowInfo(win, 15),
                              table.concat(parts, "|"))
    if not result or result == "" then return end
    local action = label_map[result]

    if     action == "nohunt"  then mob_toggle_tag(entry.mob, entry.arid, "nohunt")
    elseif action == "nowhere" then mob_toggle_tag(entry.mob, entry.arid, "nowhere")
    elseif action == "noscan"  then mob_toggle_tag(entry.mob, entry.arid, "noscan")
    elseif action == "levelok" then mob_toggle_tag(entry.mob, entry.arid, "levelok")
    elseif action == "difficulty" then
        local cur = mob_get_difficulty(entry.mob, entry.arid)
        local raw = utils.inputbox(
            "Set difficulty for '" .. entry.mob .. "' (0-5, 0 clears it).",
            "Mob Difficulty", tostring(cur), nil, 0,
            { validate = function(s) return tonumber(s) ~= nil end })
        if raw then
            local n = math.floor(tonumber(raw))
            n = math.max(0, math.min(5, n))
            mob_set_difficulty(entry.mob, entry.arid, n)
        end
    elseif action == "express" then
        if has_express then
            mob_set_tags(entry.mob, entry.arid, { express = false })
            mob_set_priority_room(entry.mob, entry.arid, nil)
        else
            mob_toggle_tag(entry.mob, entry.arid, "express")
            mob_set_priority_room(entry.mob, entry.arid, tonumber(entry.roomid))
        end
    elseif action == "area_difficulty" then
        local raw = utils.inputbox(
            "Set difficulty for area '" .. entry.arid .. "' (1-5).",
            "Area Difficulty", "1", nil, 0,
            { validate = function(s) return tonumber(s) ~= nil end })
        if raw then
            local n = math.floor(tonumber(raw))
            n = math.max(1, math.min(5, n))
            area_edit(entry.arid, "difficulty", n)
        end
    elseif action == "reroll" then
        send_cp_reroll(idx, entry)
    end

    if type(build_main_target_list) == "function"
    and type(current_activity) == "string"
    and (current_activity == "cp" or current_activity == "gq") then
        build_main_target_list(current_activity, area_room_type)
    end
    if type(xg_draw_window) == "function" then xg_draw_window() end
end

function snd_tab_right_click_menu(key)
    local tab_names = { cp = "Campaign", gq = "Global Quest", quest = "Quest" }
    local name      = tab_names[key] or key

    local items = {}
    if key ~= "quest" then
        local vis = is_tab_visible(key)
        items[#items + 1] = { action = "toggle_tab",
            label = (vis and "Hide " or "Show ") .. name .. " Tab" }
        items[#items + 1] = { action = "sep" }
    end
    -- No 'checked' field: see the comment above snd_right_click_menu's own
    -- item list for why (WindowMenu's checked marker rendered as a grayed-
    -- out, unclickable item for at least one player, trapping single-tab
    -- mode with no way back). The label names the action instead.
    items[#items + 1] = { action = "tab_mode",
        label = (snd_get_setting("tab_mode", "multi") == "single")
            and "Show All Tabs" or "Show Single Tab Only" }
    items[#items + 1] = { action = "sep" }
    items[#items + 1] = { action = "open_settings", label = "Settings..."   }
    items[#items + 1] = { action = "sep" }
    items[#items + 1] = { action = "font_pick",     label = "Change Font..." }
    items[#items + 1] = { action = "font_reset",    label = "Reset Font"     }

    local parts     = {}
    local label_map = {}
    for _, it in ipairs(items) do
        if it.action == "sep" then
            parts[#parts + 1] = "-"
        else
            parts[#parts + 1] = it.label
            label_map[it.label] = it.action
        end
    end

    local result = WindowMenu(win, WindowInfo(win, 14), WindowInfo(win, 15),
                              table.concat(parts, "|"))
    if not result or result == "" then return end

    local action = label_map[result]
    if action == "toggle_tab" then
        snd_set_setting("tab_show_" .. key, is_tab_visible(key) and "off" or "on", false)
        ensure_active_tab_visible(); xg_draw_window()
    elseif action == "tab_mode" then
        local cur = snd_get_setting("tab_mode", "multi")
        snd_set_setting("tab_mode", cur == "single" and "multi" or "single", true)
        xg_draw_window()
    elseif action == "open_settings" then sp_open()
    elseif action == "font_pick"     then snd_pick_font()
    elseif action == "font_reset"    then snd_reset_font()
    end
end

local function snd_right_click_menu()
    local win_visible = snd_get_setting("xgui_window_onoff", "on") == "on"
    local list_expand = snd_get_setting("list_display_mode", "expand") == "expand"
    local single_tab  = snd_get_setting("tab_mode", "multi") == "single"

    -- Deliberately no 'checked' field on any of these: WindowMenu's checked-
    -- item marker rendered as a grayed-out, unclickable entry for at least
    -- one player, not a checkmark, so a setting that started checked could
    -- never be un-set again from this menu -- reported as "I can't add
    -- CP/GQ tabs, nothing" after switching to a single tab. Every item here
    -- instead names the action a click performs, the same way
    -- toggle_window/toggle_tab already safely did.
    local items = {
        { action = "open_settings",  label = "Settings..."                                            },
        { action = "sep" },
        { action = "font_pick",      label = "Change Font..."                                         },
        { action = "font_reset",     label = "Reset Font"                                             },
        { action = "sep" },
        { action = "tab_mode",       label = single_tab and "Show All Tabs" or "Show Single Tab Only"  },
        { action = "tab_cp",         label = (is_tab_visible("cp") and "Hide " or "Show ") .. "Campaign Tab" },
        { action = "tab_gq",         label = (is_tab_visible("gq") and "Hide " or "Show ") .. "Global Quest Tab" },
        { action = "sep" },
        { action = "list_mode",      label = (list_expand and "Disable" or "Enable") .. " Auto-Expand List (CP/GQ)" },
        { action = "sep" },
        { action = "toggle_window",  label = win_visible and "Hide Window" or "Show Window"            },
        { action = "bring_front",    label = "Bring To Front"                                          },
        { action = "send_back",      label = "Send To Back"                                            },
    }

    local parts     = {}
    local label_map = {}
    for _, it in ipairs(items) do
        if it.action == "sep" then
            parts[#parts + 1] = "-"
        else
            parts[#parts + 1] = it.label
            label_map[it.label] = it.action
        end
    end

    local result = WindowMenu(win, WindowInfo(win, 14), WindowInfo(win, 15),
                              table.concat(parts, "|"))
    if not result or result == "" then return end

    local action = label_map[result]
    if     action == "open_settings"  then sp_open()
    elseif action == "font_pick"      then snd_pick_font()
    elseif action == "font_reset"     then snd_reset_font()
    elseif action == "list_mode"      then
        local cur = snd_get_setting("list_display_mode", "expand")
        snd_set_setting("list_display_mode", cur == "expand" and "scroll" or "expand", true)
        xg_draw_window()
    elseif action == "tab_mode"       then
        local cur = snd_get_setting("tab_mode", "multi")
        snd_set_setting("tab_mode", cur == "single" and "multi" or "single", true)
        xg_draw_window()
    elseif action == "tab_cp"         then
        snd_set_setting("tab_show_cp", is_tab_visible("cp") and "off" or "on", false)
        ensure_active_tab_visible(); xg_draw_window()
    elseif action == "tab_gq"         then
        snd_set_setting("tab_show_gq", is_tab_visible("gq") and "off" or "on", false)
        ensure_active_tab_visible(); xg_draw_window()
    elseif action == "toggle_window"  then xg_toggle_window()
    elseif action == "bring_front"    then z_order_boost(win)
    elseif action == "send_back"      then z_order_drop(win)
    end
end

function snd_win_mouse_up(flags, hotspot_id)
    if bit.band(flags, miniwin.hotspot_got_rh_mouse) ~= 0 then
        snd_right_click_menu()
    end
    return true
end

-- ─── SHOW / HIDE ─────────────────────────────────────────────────────────────

function xg_show_window()
    -- WindowShow does nothing to a window that no longer exists, which is how
    -- the window could vanish and refuse to come back: 'xset win on' called
    -- WindowShow on a deleted handle, silently, and only 'xset winreset'
    -- (which recreates it) had any effect. Rebuild it first if it is gone.
    if not window_exists() then
        xg_create_window()
    end
    WindowShow(win, true)
    snd_set_setting("xgui_window_onoff", "on", false)
end

function xg_hide_window()
    -- No existence guard: WindowShow on a deleted handle is already a no-op,
    -- and a guard here would only make "hide" depend on module-local state
    -- that nothing outside can observe.
    WindowShow(win, false)
    snd_set_setting("xgui_window_onoff", "off", false)
end

function xg_toggle_window()
    -- A window that has been destroyed while the setting still says "on" must
    -- come back, not toggle off.
    if window_exists() and snd_get_setting("xgui_window_onoff", "on") == "on" then
        xg_hide_window()
    else
        xg_show_window()
    end
end

-- Alias handler: 'xset win <on|off|show|hide|max|expand|min|collapse>'.
--
-- The alias captures that word, but it used to run xg_toggle_window(), which
-- takes no arguments -- so every form simply flipped visibility. 'xset win on'
-- could turn the window OFF, and the expand/collapse forms did nothing they
-- claimed to.
-- Alias handler: 'xset cols [column] [on|off|<width>]', in any order.
--
-- The two arguments are unordered on purpose. "xset cols off hops" and
-- "xset cols hops off" are the same sentence to anyone typing quickly, and
-- refusing one of them teaches nothing.
--
--   xset cols                 list every column and its state
--   xset cols hops            flip one
--   xset cols off hops        set one, either word order
--   xset cols off             every optional column off
--   xset cols on              every optional column back on
--   xset cols 20              20 characters of keyword
--   xset cols on 20           show the keyword column, 20 characters wide
--
-- A bare number means the keyword column because it is the only one with a
-- width; if another ever gains one, a number will have to name its column.
function xset_cols(name, line, wildcards)
    local w  = (type(wildcards) == "table" and wildcards) or {}
    local t1 = tostring(w.col   or w[1] or ""):lower()
    local t2 = tostring(w.state or w[2] or ""):lower()

    local col, state, width
    local function classify(tok)
        if tok == "" then return end
        if tok == "on" or tok == "off" then
            state = tok
        elseif tonumber(tok) then
            width = tonumber(tok)
        elseif list_column_def(tok) then
            col = tok
        else
            return tok            -- unrecognised, reported by the caller
        end
    end
    local bad = classify(t1) or classify(t2)

    if bad then
        local names = {}
        for _, c in ipairs(LIST_COLUMNS) do names[#names + 1] = c.key end
        UsageNote("SnD: xset cols: '", bad, "' is not a column, on, off, or a ",
                  "width. Columns: ", table.concat(names, ", "), ".")
        return
    end

    -- Nothing at all: show what there is.
    if not col and not state and not width then
        InfoNote("SnD: List columns -- 'xset cols <column> [on|off]' to change.")
        for _, c in ipairs(LIST_COLUMNS) do
            local ws = c.width_setting
                       and string.format("  (%d chars)", list_column_width(c.key))
                       or ""
            InfoNote(string.format("  %-5s %-3s  %s%s",
                c.key, list_column_shown(c.key) and "on" or "off", c.desc, ws))
        end
        InfoNote("  The number, mob and destination columns are always shown.")
        InfoNote("  'xset cols off' hides them all; 'xset cols 20' sets the ",
                 "keyword width.")
        return
    end

    -- A width with no column named can only mean the one column that has one.
    if width and not col then col = "kw" end

    -- A bare on/off with no column is the sweeping form.
    if not col then
        for _, c in ipairs(LIST_COLUMNS) do
            snd_set_setting(c.setting, state, true)
        end
        InfoNote("SnD: every optional column is now ", state,
                 " (number, mob and destination always show).")
        if type(xg_draw_window) == "function" then xg_draw_window() end
        return
    end

    local def = list_column_def(col)

    if width then
        if not def.width_setting then
            UsageNote("SnD: xset cols: the ", def.label,
                      " column has no adjustable width.")
            return
        end
        local clamped = math.max(def.width_min,
                                 math.min(def.width_max, math.floor(width)))
        snd_set_setting(def.width_setting, tostring(clamped), true)
        if clamped ~= math.floor(width) then
            InfoNote("SnD: ", def.label, " width must be between ",
                     tostring(def.width_min), " and ", tostring(def.width_max),
                     " characters; set to ", tostring(clamped), ".")
        else
            InfoNote("SnD: ", def.label, " column is ", tostring(clamped),
                     " characters wide.")
        end
    end

    -- A width given with no on/off implies you want to see it; asking for 20
    -- characters of a hidden column and being shown nothing is not an answer.
    if not state and width and not list_column_shown(col) then
        state = "on"
    end

    if state then
        snd_set_setting(def.setting, state, true)
        InfoNote("SnD: ", def.label, " column is ", state, " (", def.desc, ").")
    elseif not width then
        local flipped = list_column_shown(col) and "off" or "on"
        snd_set_setting(def.setting, flipped, true)
        InfoNote("SnD: ", def.label, " column is ", flipped, " (", def.desc, ").")
    end

    if type(xg_draw_window) == "function" then xg_draw_window() end
end

function xg_window_command(name, line, wildcards)
    local w = (type(wildcards) == "table" and wildcards) or {}
    local opt = tostring(w.onoff or w[1] or ""):lower()

    if opt == "on" or opt == "show" or opt == "1" or opt == "true" then
        xg_show_window()
    elseif opt == "off" or opt == "hide" or opt == "0" or opt == "false" then
        xg_hide_window()
    elseif opt == "max" or opt == "maximize" or opt == "expand" then
        if xg_expand_window() then
            InfoNote("SnD: window expanded to its previous height.")
        else
            InfoNote("SnD: window is already at its normal height.")
        end
    elseif opt == "min" or opt == "minimize" or opt == "collapse" then
        if xg_collapse_window() then
            InfoNote("SnD: window rolled up to the tab and TNL bar.")
        else
            InfoNote("SnD: window is already rolled up.")
        end
    else
        xg_toggle_window()
    end
end

-- Alias handler: 'xset win tabs [single|multi]'.
--
-- 'single' collapses quest/CP/GQ down to one tab that always shows whichever
-- is currently active -- current_activity for CP/GQ, quest as the fallback
-- when neither is running -- instead of three you click between. Reuses
-- is_tab_visible/visible_tabs (see the comment above is_tab_visible) rather
-- than a parallel single-tab code path, so drawing, scrolling, and the
-- title-bar buttons all keep working exactly as they already do for
-- whichever one tab is showing.
function xg_window_tabs_command(name, line, wildcards)
    local w    = (type(wildcards) == "table" and wildcards) or {}
    local mode = tostring(w.mode or w[1] or ""):lower()

    if mode == "single" or mode == "multi" then
        snd_set_setting("tab_mode", mode, true)
        InfoNote("SnD: Tabs: " .. mode .. (mode == "single"
            and " -- one tab, following whichever of quest/CP/GQ is active."
            or " -- quest, CP, and GQ each get their own tab again."))
        if window_exists() then xg_draw_window() end
    else
        local cur = snd_get_setting("tab_mode", "multi")
        InfoNote("SnD: Tabs: " .. cur .. ".  'xset win tabs single' for one " ..
            "tab that follows whichever activity is current; " ..
            "'xset win tabs multi' for the usual three.")
    end
end

-- ─── SCROLL HANDLER ──────────────────────────────────────────────────────────
-- Wired to every hotspot in the scrollable area via WindowScrollwheelHandler.
-- Wheel delta: bit 0x100 set = backward (down), clear = forward (up).

function snd_list_scroll(flags, hotspot_id)
    flags = flags or 0
    local tab = _active_tab
    if tab ~= "cp" and tab ~= "gq" then return end

    local lh      = font_line_h()
    local _, _, _, _, _, list_top, list_bot = geometry()
    local visible = math.max(1, math.floor((list_bot - list_top) / lh))

    local total = (tab == "cp") and #_cp_list or #_gq_list
    if total == 0 then return end

    local max_off = math.max(0, total - visible)
    local off     = math.min(_scroll_offset[tab] or 0, max_off)

    if bit.band(flags, 0x100) ~= 0 then
        off = math.min(max_off, off + 3)
    else
        off = math.max(0, off - 3)
    end

    _scroll_offset[tab] = off
    if _scrollbar then _scrollbar.step = off + 1 end
    redraw_list_area()
end

-- ─── THEME ───────────────────────────────────────────────────────────────────

function OnPluginThemeChange()
    xg_create_window()
    return true
end

-- ─── STATE PERSISTENCE ───────────────────────────────────────────────────────

function xg_save_window_state()
    -- Safe to call even after xg_destroy_window: movewindow.save_state guards
    -- its own WindowInfo() calls and falls back to the last known position, so
    -- a destroyed window keeps its saved coordinates rather than losing them.
    movewindow.save_state(win)
    SetVariable("snd_win_width",  tostring(_width))
    SetVariable("snd_win_height", tostring(_height))
    SetVariable("snd_win_min_h",  tostring(_min_expand_h))
    SetVariable("snd_win_collapsed",      _collapsed and "1" or "")
    SetVariable("snd_win_pre_collapse_h", _pre_collapse_h and tostring(_pre_collapse_h) or "")
    if type(sp_save_state) == "function" then sp_save_state() end
end

function xg_destroy_window()
    if WindowInfo(win, 1) then WindowDelete(win) end
    -- Clear the movewindow handle too.  Leaving it set is what made the cheap
    -- `if not windowinfo` guards pass against a window that no longer exists;
    -- xg_create_window reinstalls it, and nothing reads it in between.
    windowinfo = nil
    if type(sp_destroy) == "function" then sp_destroy() end
end

-- ─── CREATE / INIT ───────────────────────────────────────────────────────────

function xg_create_window()
    -- Forget the column footprint: the font is chosen below, and a different
    -- font changes every column's pixel width without any column having
    -- changed. Re-adopting on the next draw stops a font change being read as
    -- a column change and resizing the window for it.
    _col_fixed_w = nil
    _screen_w = tonumber(GetInfo(281)) or 1920
    _screen_h = tonumber(GetInfo(280)) or 1080
    local dpi_h = (type(GetDeviceCaps) == "function") and GetDeviceCaps(88) or nil
    _scale    = compute_scale(_screen_w, dpi_h)

    local saved_w   = tonumber(GetVariable("snd_win_width"))
    local saved_h   = tonumber(GetVariable("snd_win_height"))
    local saved_min = tonumber(GetVariable("snd_win_min_h"))
    _width        = saved_w or math.max(MIN_W, math.floor(_screen_w * 0.28))
    _height       = saved_h or DEFAULT_H
    _min_expand_h = saved_min or DEFAULT_H
    -- _height above may itself be the collapsed height (that is what was
    -- saved) -- restoring _collapsed alongside it is what makes 'xset win
    -- expand' able to do anything after a reload, instead of finding
    -- _collapsed reset to false with no saved height to distrust it against.
    _collapsed      = GetVariable("snd_win_collapsed") == "1"
    _pre_collapse_h = tonumber(GetVariable("snd_win_pre_collapse_h"))

    local font_name, font_size = select_font(_scale)
    _active_font_name = font_name
    _active_font_size = font_size
    local font_bold   = snd_get_setting("window_font_bold",   "off") == "on"
    local font_italic = snd_get_setting("window_font_italic", "off") == "on"

    windowinfo = movewindow.install(
        win,
        miniwin.pos_top_right,
        miniwin.create_absolute_location,
        false,
        nil,
        { mouseup = snd_win_mouse_up },
        { x = DEFAULT_X, y = DEFAULT_Y }
    )

    -- Drag the window back on-screen if its saved position is no longer on it.
    --
    -- movewindow restores an absolute position saved from a previous session,
    -- and nothing checked it against the current desktop. A resolution change
    -- while the client is running -- a monitor sleeping and waking, a laptop
    -- undocking, a remote session resizing -- can leave those coordinates
    -- outside the visible area, and the window is then invisible while very
    -- much existing. The help has always named this ("if the window disappears
    -- off-screen"), and offered 'xset winreset' as the cure, but nothing made
    -- the cure reliable: recreating the window restores the same saved
    -- coordinates.
    --
    -- A sliver is enough to count as visible, since a deliberately
    -- part-offscreen window is a legitimate choice; only a window with nothing
    -- left to grab is moved.
    if windowinfo then
        local EDGE = 40                       -- must remain grabbable
        local left = tonumber(windowinfo.window_left) or 0
        local top  = tonumber(windowinfo.window_top)  or 0
        local off  = left > (_screen_w - EDGE)
                  or top  > (_screen_h - EDGE)
                  or left < (EDGE - _width)
                  or top  < 0
        if off then
            windowinfo.window_left = DEFAULT_X
            windowinfo.window_top  = DEFAULT_Y
            if type(InfoNote) == "function" then
                InfoNote("SnD: the window was off-screen (saved position ",
                         tostring(left), ",", tostring(top),
                         " on a ", tostring(_screen_w), "x", tostring(_screen_h),
                         " desktop) -- moved it back.")
            end
        end
    end

    WindowCreate(
        win,
        windowinfo.window_left,
        windowinfo.window_top,
        _width,
        _height,
        windowinfo.window_mode,
        windowinfo.window_flags,
        0x000000
    )

    WindowFont(win, FONT_ID, font_name, font_size, font_bold, font_italic, false, false, 0)

    if _scrollbar then
        _scrollbar:unInit()
        _scrollbar = nil
    end

    WindowShow(win, snd_get_setting("xgui_window_onoff", "on") == "on")
    xg_draw_window()
end
