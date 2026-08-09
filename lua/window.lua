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
local _height           = DEFAULT_H
local _min_expand_h     = DEFAULT_H   -- floor for expand-mode shrink; updated on manual resize
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

function xg_set_active_tab(tab)
    if tab == "cp" or tab == "gq" or tab == "quest" then
        _active_tab = tab
        xg_draw_window()
    end
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

local function is_tab_visible(key)
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

        WindowRectOp(win, 2, tx1, tab_top + 2, tx2, tab_bot - 1,
            active and Theme.PRIMARY_BODY or Theme.SECONDARY_BODY)

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

-- Pixel x positions for the four-column table layout.
-- Returns: text_x, hops_x, mob_x, dest_x, right_x
local function list_col_pos(row_x, row_right)
    local tx     = row_x + EDGE_W + 3
    local rx     = row_right or (_width - PAD_RIGHT)
    local idx_w  = WindowTextWidth(win, FONT_ID, "88) ")
    local hops_w = WindowTextWidth(win, FONT_ID, "9999 ")
    local diff_w = WindowTextWidth(win, FONT_ID, "Diff ")
    local rest   = rx - tx - idx_w - hops_w - diff_w
    local mob_w  = math.floor(rest * 0.54)
    local diff_x = tx + idx_w + hops_w
    local mob_x  = diff_x + diff_w
    return tx, tx + idx_w, diff_x, mob_x, mob_x + mob_w, rx
end

local function draw_list_header(y, lh, row_right)
    local tx, hops_x, diff_x, mob_x, dest_x = list_col_pos(PAD_LEFT, row_right)
    local ty  = y + ROW_PAD
    local col = 0x3A5878
    WindowText(win, FONT_ID, "#",          tx,      ty, 0, 0, col, false)
    WindowText(win, FONT_ID, "Hops",       hops_x,  ty, 0, 0, col, false)
    WindowText(win, FONT_ID, "Diff",       diff_x,  ty, 0, 0, col, false)
    WindowText(win, FONT_ID, "Mob",        mob_x,   ty, 0, 0, col, false)
    WindowText(win, FONT_ID, "Type  Dest", dest_x,  ty, 0, 0, col, false)
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

    local tx, hops_x, diff_x, mob_x, dest_x, rx = list_col_pos(row_x, row_right)
    local ty  = row_y + ROW_PAD
    local clr = entry_color(entry, index)

    -- ── Index column ──────────────────────────────────────────────────────────
    WindowText(win, FONT_ID, string.format("%2d) ", index), tx, ty, 0, 0, 0x506070, false)

    -- ── Hops column ───────────────────────────────────────────────────────────
    -- Hop count from the previous stop (or from current room for the first entry).
    -- Populated by optimize_target_order; nil when pathing did not run.
    local hops = entry.path_hops
    if hops and hops < 99999 then
        WindowText(win, FONT_ID, tostring(hops), hops_x, ty, 0, 0, 0x4488AA, false)
    elseif hops then
        WindowText(win, FONT_ID, "?", hops_x, ty, 0, 0, 0x555555, false)
    end

    -- ── Diff column ───────────────────────────────────────────────────────────
    -- Difficulty rating (1-5), populated by attach_difficulty in targets.lua:
    -- the mob's own rating when it has one, otherwise its area's. Left blank
    -- when the area is unknown and the mob is unrated.
    local diff = entry.difficulty
    if diff then
        WindowText(win, FONT_ID, tostring(diff), diff_x, ty, 0, 0,
            DIFF_COLS[diff] or DIFF_COLS[1], false)
    end

    -- ── Mob column ────────────────────────────────────────────────────────────
    local is_dead       = entry.is_dead == "yes"
    local player_killed = entry.player_killed == true
    local qty           = tonumber(entry.qty) or 1
    local char_w        = math.max(1, WindowTextWidth(win, FONT_ID, "W"))

    local cx = mob_x
    if entry.unlikely then
        cx = cx + WindowText(win, FONT_ID, "(U) ", cx, ty, 0, 0, 0x506070, false)
    end
    if is_dead and not player_killed then
        cx = cx + WindowText(win, FONT_ID, "[D] ", cx, ty, 0, 0, 0xCC8800, false)
    end

    local qty_sfx    = (qty > 1) and (" x" .. qty) or ""
    local sfx_w      = WindowTextWidth(win, FONT_ID, qty_sfx)
    local mob_avail  = dest_x - cx - sfx_w - 4
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

    -- ── Dest column ───────────────────────────────────────────────────────────
    local express = type(is_express_target) == "function" and is_express_target(entry)
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
    local ax = dest_x
    if entry.link_type ~= "unknown" then
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

-- ─── MAIN DRAW ───────────────────────────────────────────────────────────────

function xg_draw_window()
    if not window_exists() then return end

    -- Expand mode: resize the window height to fit the full CP/GQ list.
    -- Only applies to the event tabs; settings is never expanded.
    if snd_get_setting("list_display_mode", "expand") == "expand" then
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

    -- [x] close button painted on top of the title bar chrome.
    do
        local body_top = geometry()
        local lh       = font_line_h()
        local btn_str  = "[x]"
        local btn_w    = WindowTextWidth(win, FONT_ID, btn_str) + 4
        local btn_x    = _width - btn_w - 2
        local btn_y    = math.max(0, math.floor((body_top - lh) / 2))
        WindowText(win, FONT_ID, btn_str, btn_x, btn_y, 0, 0, 0xAAAAAA, false)
        WindowDeleteHotspot(win, "snd_close_btn")
        WindowAddHotspot(win, "snd_close_btn",
            btn_x - 1, 0, _width - 1, body_top,
            "", "", "", "", "xg_hide_window",
            "Hide window  (right-click title bar or tabs to restore)",
            miniwin.cursor_hand, 0)
    end

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
    xg_draw_window()
end

function snd_row_click(flags, hotspot_id)
    if hotspot_id == "snd_row_q" then
        Execute("xqt")
    else
        local idx = hotspot_id:match("^snd_row_(%d+)$")
        if idx then Execute("xcp " .. idx) end
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

-- ─── RESIZE ──────────────────────────────────────────────────────────────────

function snd_win_resize_down()
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
            parts[#parts + 1] = (it.checked and "^" or "") .. it.label
            label_map[it.label] = it.action
        end
    end

    local result = WindowMenu(win, WindowInfo(win, 14), WindowInfo(win, 15),
                              table.concat(parts, "|"))
    if not result or result == "" then return end

    local clean  = result:match("^%^?(.+)$") or result
    local action = label_map[clean] or label_map[result]
    if action == "toggle_tab" then
        snd_set_setting("tab_show_" .. key, is_tab_visible(key) and "off" or "on", false)
        ensure_active_tab_visible(); xg_draw_window()
    elseif action == "open_settings" then sp_open()
    elseif action == "font_pick"     then snd_pick_font()
    elseif action == "font_reset"    then snd_reset_font()
    end
end

local function snd_right_click_menu()
    local win_visible = snd_get_setting("xgui_window_onoff", "on") == "on"
    local list_expand = snd_get_setting("list_display_mode", "expand") == "expand"

    local items = {
        { action = "open_settings",  label = "Settings..."                                            },
        { action = "sep" },
        { action = "font_pick",      label = "Change Font..."                                         },
        { action = "font_reset",     label = "Reset Font"                                             },
        { action = "sep" },
        { action = "tab_cp",         label = "Show Campaign Tab",        checked = is_tab_visible("cp") },
        { action = "tab_gq",         label = "Show Global Quest Tab",    checked = is_tab_visible("gq") },
        { action = "sep" },
        { action = "list_mode",      label = "Auto-Expand List (CP/GQ)", checked = list_expand          },
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
            parts[#parts + 1] = (it.checked and "^" or "") .. it.label
            label_map[it.label] = it.action
        end
    end

    local result = WindowMenu(win, WindowInfo(win, 14), WindowInfo(win, 15),
                              table.concat(parts, "|"))
    if not result or result == "" then return end

    local clean  = result:match("^%^?(.+)$") or result
    local action = label_map[clean] or label_map[result]
    if     action == "open_settings"  then sp_open()
    elseif action == "font_pick"      then snd_pick_font()
    elseif action == "font_reset"     then snd_reset_font()
    elseif action == "list_mode"      then
        local cur = snd_get_setting("list_display_mode", "expand")
        snd_set_setting("list_display_mode", cur == "expand" and "scroll" or "expand", true)
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
    WindowShow(win, true)
    snd_set_setting("xgui_window_onoff", "on", false)
end

function xg_hide_window()
    WindowShow(win, false)
    snd_set_setting("xgui_window_onoff", "off", false)
end

function xg_toggle_window()
    if snd_get_setting("xgui_window_onoff", "on") == "on" then
        xg_hide_window()
    else
        xg_show_window()
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
