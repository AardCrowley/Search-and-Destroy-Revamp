-- settings_popup.lua
-- Standalone settings popup window.
-- Open with sp_open() / sp_toggle(), or the 'snd settings' alias / right-click menu.
-- Depends on: constants.lua, util.lua, settings.lua, window.lua (for snd_pick_font,
--   xg_draw_window, _active_font_name, _active_font_size via snd_get_setting)

require "movewindow"
require "scrollbar"

-- ─── CONSTANTS ───────────────────────────────────────────────────────────────

local SP_WIN        = "snd_sp"
local SP_FONT       = "sp_f"
local SP_MIN_W      = 300
local SP_MIN_H      = 180
local SP_DEF_W      = 410
local SP_DEF_H      = 540
local SP_PAD_LEFT   = 6
local SP_PAD_RIGHT  = 6
local SP_SB_W       = 10

-- ─── STATE ───────────────────────────────────────────────────────────────────

local _sp_created   = false
local _sp_width     = SP_DEF_W
local _sp_height    = SP_DEF_H
local _sp_hs        = {}
local _sp_scroll    = 0
local _sp_sb        = nil
local _sp_items     = {}
local _sp_resize_sx = 0
local _sp_resize_sy = 0
local _sp_winfo     = nil   -- movewindow state

-- ─── SETTINGS DEFINITIONS ────────────────────────────────────────────────────

local SP_DEFS = {
    { cat = "Font",
      key = "__font",                label = "Font",                      type = "font",   is_global = true },
    { cat = "Colors -- Window",
      key = "color_accent",          label = "Active Tab Line",            type = "color",  is_global = true, default = "#00B4E0" },
    { cat = "Colors -- Window",
      key = "color_accent2",         label = "Tab Border",                 type = "color",  is_global = true, default = "#005070" },
    { cat = "Colors -- Window",
      key = "color_info_bg",         label = "Info Bar BG",                type = "color",  is_global = true, default = "#0A1A20" },
    { cat = "Colors -- Window",
      key = "color_info_tnl",        label = "Info Bar TNL Text",          type = "color",  is_global = true, default = "#C0C0C0" },
    { cat = "Colors -- Window",
      key = "color_info_nx",         label = "Info Bar NX:ON",             type = "color",  is_global = true, default = "#00DD44" },
    { cat = "Colors -- Window",
      key = "color_info_today_label",label = "Info Bar Today Label",       type = "color",  is_global = true, default = "#506070" },
    { cat = "Colors -- Window",
      key = "color_info_today_val",  label = "Info Bar Today Count",       type = "color",  is_global = true, default = "#87CEFA" },
    { cat = "Colors -- Window",
      key = "color_status_bg",       label = "Status Bar BG",              type = "color",  is_global = true, default = "#060C10" },
    { cat = "Colors -- Window",
      key = "color_status_text",     label = "Status Bar Text",            type = "color",  is_global = true, default = "#506070" },
    { cat = "Colors -- Window",
      key = "color_status_empty",    label = "Status Bar No History",      type = "color",  is_global = true, default = "#2A3540" },
    { cat = "Colors -- Tabs",
      key = "color_tab_quest",       label = "Quest Tab Line",             type = "color",  is_global = true, default = "" },
    { cat = "Colors -- Tabs",
      key = "color_tab_cp",          label = "CP Tab Line",                type = "color",  is_global = true, default = "" },
    { cat = "Colors -- Tabs",
      key = "color_tab_gq",          label = "GQ Tab Line",                type = "color",  is_global = true, default = "" },
    { cat = "Colors -- Targets",
      key = "color_normal",          label = "Normal",                     type = "color",  is_global = true, default = "#E0E0E0" },
    { cat = "Colors -- Targets",
      key = "color_targeted",        label = "Current Target",             type = "color",  is_global = true, default = "#FF4000" },
    { cat = "Colors -- Targets",
      key = "color_dead",            label = "Server-Dead",                type = "color",  is_global = true, default = "#484848" },
    { cat = "Colors -- Targets",
      key = "color_unknown",         label = "Unknown Location",           type = "color",  is_global = true, default = "#FF0000" },
    { cat = "Colors -- Targets",
      key = "color_alternating_row", label = "Alternating Row",            type = "color",  is_global = true, default = "#0C0C1A" },
    { cat = "Colors -- Quest",
      key = "color_quest_available", label = "Quest Ready",                type = "color",  is_global = true, default = "#1E90FF" },
    { cat = "Colors -- Quest",
      key = "color_quest_complete",  label = "Quest Complete",             type = "color",  is_global = true, default = "#7CFC00" },
    { cat = "Colors -- Quest",
      key = "color_quest_waiting",   label = "Quest Cooldown",             type = "color",  is_global = true, default = "#FF8C00" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_mob",          label = "Mob Name",                   type = "color",  is_global = true, default = "#FFFFFF" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_room",         label = "Room Name",                  type = "color",  is_global = true, default = "#90EE90" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_zone",         label = "Zone",                       type = "color",  is_global = true, default = "#FFD700" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_lvl",          label = "Level Range",                type = "color",  is_global = true, default = "#FFA07A" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_kills",        label = "Kill Count",                 type = "color",  is_global = true, default = "#87CEEB" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_row_bg",       label = "Alternating Row BG",         type = "color",  is_global = true, default = "#191970" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_col_header",   label = "Column Headers",             type = "color",  is_global = true, default = "#606060" },
    { cat = "Colors -- Mob Search",
      key = "color_ms_title",        label = "Search Term",                type = "color",  is_global = true, default = "#00D4FF" },
    { cat = "Colors -- Consider",
      key = "color_con_1",           label = "-20 and below",              type = "color",  is_global = true, default = "cornflowerblue" },
    { cat = "Colors -- Consider",
      key = "color_con_2",           label = "-19 to -10",                 type = "color",  is_global = true, default = "deepskyblue" },
    { cat = "Colors -- Consider",
      key = "color_con_3",           label = "-9 to -5",                   type = "color",  is_global = true, default = "turquoise" },
    { cat = "Colors -- Consider",
      key = "color_con_4",           label = "-4 to -2",                   type = "color",  is_global = true, default = "mediumspringgreen" },
    { cat = "Colors -- Consider",
      key = "color_con_5",           label = "-1 to +1",                   type = "color",  is_global = true, default = "lime" },
    { cat = "Colors -- Consider",
      key = "color_con_6",           label = "+2 to +4",                   type = "color",  is_global = true, default = "lawngreen" },
    { cat = "Colors -- Consider",
      key = "color_con_7",           label = "+5 to +9",                   type = "color",  is_global = true, default = "limegreen" },
    { cat = "Colors -- Consider",
      key = "color_con_8",           label = "+10 to +15",                 type = "color",  is_global = true, default = "greenyellow" },
    { cat = "Colors -- Consider",
      key = "color_con_9",           label = "+16 to +20",                 type = "color",  is_global = true, default = "#EFF22D" },
    { cat = "Colors -- Consider",
      key = "color_con_10",          label = "+21 to +30",                 type = "color",  is_global = true, default = "gold" },
    { cat = "Colors -- Consider",
      key = "color_con_11",          label = "+31 to +40",                 type = "color",  is_global = true, default = "darkorange" },
    { cat = "Colors -- Consider",
      key = "color_con_12",          label = "+41 to +50",                 type = "color",  is_global = true, default = "orangered" },
    { cat = "Colors -- Consider",
      key = "color_con_13",          label = "+51 and above",              type = "color",  is_global = true, default = "red" },
    { cat = "Display",
      key = "list_display_mode",     label = "Auto-Expand List (CP/GQ)",   type = "toggle", is_global = true,
      values = { "expand", "scroll" }, default = "expand" },
    { cat = "Display",
      key = "tab_show_cp",           label = "Show CP Tab",                type = "toggle", is_global = false, default = "on" },
    { cat = "Display",
      key = "tab_show_gq",           label = "Show GQ Tab",                type = "toggle", is_global = false, default = "on" },
    { cat = "Display",
      key = "col_show_hops",         label = "Column: Hops",               type = "toggle", is_global = true,  default = "on" },
    { cat = "Display",
      key = "col_show_diff",         label = "Column: Diff",               type = "toggle", is_global = true,  default = "on" },
    { cat = "Display",
      key = "col_show_kw",           label = "Column: Keyword",            type = "toggle", is_global = true,  default = "off" },
    { cat = "Display",
      key = "col_show_type",         label = "Column: Type",               type = "toggle", is_global = true,  default = "on" },
    { cat = "Behavior",
      key = "debug_mode",            label = "Debug Mode",                 type = "toggle", is_global = true,  default = "off" },
    { cat = "Pathing",
      key = "pathing_enabled",       label = "Route Optimization",         type = "toggle", is_global = true,  default = "on" },
    { cat = "Pathing",
      key = "pathing_express_group", label = "Express Mob Grouping",       type = "cycle",  is_global = true,  default = "off",
      values = { "off", "first", "last" } },
}

local function sp_build_items()
    local items    = {}
    local last_cat = nil
    for _, def in ipairs(SP_DEFS) do
        if def.cat ~= last_cat then
            items[#items + 1] = { is_header = true, label = def.cat }
            last_cat = def.cat
        end
        items[#items + 1] = def
    end
    return items
end

-- ─── FONT ────────────────────────────────────────────────────────────────────

local function sp_font_lh()
    return WindowFontInfo(SP_WIN, SP_FONT, 1)
end

local function sp_setup_font()
    local name = snd_get_setting("window_font", "")
    local size = tonumber(snd_get_setting("window_font_size", "")) or 0
    if name == "" or size == 0 then
        name = "Courier New"; size = 9
    end
    local bold   = snd_get_setting("window_font_bold",   "off") == "on"
    local italic = snd_get_setting("window_font_italic", "off") == "on"
    WindowFont(SP_WIN, SP_FONT, name, size, bold, italic, false, false, 0)
end

-- ─── COLOR HELPERS ───────────────────────────────────────────────────────────

local function sp_rgb_to_colorref(rgb)
    local r = bit.band(bit.rshift(rgb, 16), 0xFF)
    local g = bit.band(bit.rshift(rgb,  8), 0xFF)
    local b = bit.band(rgb,                 0xFF)
    return bit.lshift(b, 16) + bit.lshift(g, 8) + r
end

local function sp_colorref_to_rgb(cref)
    local r = bit.band(cref,                 0xFF)
    local g = bit.band(bit.rshift(cref,  8), 0xFF)
    local b = bit.band(bit.rshift(cref, 16), 0xFF)
    return bit.lshift(r, 16) + bit.lshift(g, 8) + b
end

-- ─── DISPLAY HELPER ──────────────────────────────────────────────────────────

local function sp_display(def)
    if def.key == "__font" then
        local fn = snd_get_setting("window_font", "")
        local fs = snd_get_setting("window_font_size", "")
        if fn == "" then fn = "Courier New"; fs = "9" end
        return fn .. (fs ~= "" and (" " .. fs .. "pt") or "")
    elseif def.type == "toggle" then
        local cur = snd_get_setting(def.key, def.default or "off")
        if def.values then
            return cur == def.values[1] and "On" or "Off"
        end
        return cur == "on" and "On" or "Off"
    elseif def.type == "cycle" then
        local cur = snd_get_setting(def.key, def.default or "")
        return cur:sub(1,1):upper() .. cur:sub(2)
    elseif def.type == "color" then
        local v = snd_get_setting(def.key, def.default or "")
        return v ~= "" and v or "(default)"
    end
    return snd_get_setting(def.key, def.default or "")
end

-- ─── EDIT ────────────────────────────────────────────────────────────────────

local function sp_edit(def)
    if def.key == "__font" then
        snd_pick_font()   -- window.lua; calls xg_draw_window() + sp_draw_if_open()
        return
    end

    if def.type == "color" then
        local cur = snd_get_setting(def.key, def.default or "")
        if cur == "" then cur = def.default or "#FFFFFF" end
        local result = PickColour(sp_rgb_to_colorref(ColourNameToRGB(cur)))
        if result and result >= 0 then
            snd_set_setting(def.key,
                string.format("#%06X", sp_colorref_to_rgb(result)),
                def.is_global ~= false)
            xg_draw_window()
            sp_draw()
        end

    elseif def.type == "toggle" then
        local cur = snd_get_setting(def.key, def.default or "off")
        local new_val
        if def.values then
            new_val = (cur == def.values[1]) and def.values[2] or def.values[1]
        else
            new_val = (cur == "on") and "off" or "on"
        end
        snd_set_setting(def.key, new_val, def.is_global ~= false)
        if def.key == "debug_mode" then
            if new_val == "on" then
                debug_log_open(); debug_log_write("INFO", "Debug mode enabled.")
            else
                debug_log_write("INFO", "Debug mode disabled."); debug_log_close()
            end
        end
        xg_draw_window()
        sp_draw()

    elseif def.type == "cycle" then
        local cur = snd_get_setting(def.key, def.default or "")
        local vals = def.values
        local next_val = vals[1]
        for i, v in ipairs(vals) do
            if v == cur then
                next_val = vals[(i % #vals) + 1]
                break
            end
        end
        snd_set_setting(def.key, next_val, def.is_global ~= false)
        xg_draw_window()
        sp_draw()
    end
end

-- ─── DRAW ────────────────────────────────────────────────────────────────────

local function sp_clear_hs()
    for _, id in ipairs(_sp_hs) do WindowDeleteHotspot(SP_WIN, id) end
    _sp_hs = {}
end

local function sp_add_hs(id, x1, y1, x2, y2, up, tip, cur)
    table.insert(_sp_hs, id)
    WindowDeleteHotspot(SP_WIN, id)
    WindowAddHotspot(SP_WIN, id, x1, y1, x2, y2,
        "", "", "", "", up or "",
        tip or "", cur or miniwin.cursor_arrow, 0)
end

function sp_draw()
    if not _sp_created then return end

    sp_setup_font()
    sp_clear_hs()

    local lh       = sp_font_lh()
    local font_h   = Theme.TextHeight(SP_WIN, SP_FONT)
    local _, body_top = Theme.BodyMetrics(SP_WIN, SP_FONT, font_h, 1)

    WindowRectOp(SP_WIN, 2, 0, body_top, _sp_width, _sp_height, Theme.PRIMARY_BODY)

    _sp_items = sp_build_items()

    local content_top = body_top
    local content_bot = _sp_height

    local visible  = math.max(1, math.floor((content_bot - content_top) / lh))
    local need_sb  = #_sp_items > visible
    local sb_res   = need_sb and SP_SB_W or 0
    local max_off  = math.max(0, #_sp_items - visible)
    _sp_scroll     = math.min(_sp_scroll, max_off)
    local offset   = _sp_scroll

    local row_right = _sp_width - SP_PAD_RIGHT - sb_res
    local usable_w  = _sp_width - SP_PAD_LEFT - SP_PAD_RIGHT - sb_res
    local val_right = row_right - 4
    local val_left  = val_right - math.min(220, math.floor(usable_w * 0.45))

    local y = content_top
    for i = offset + 1, math.min(#_sp_items, offset + visible) do
        local item = _sp_items[i]
        local hs   = "sp_r" .. i
        if item.is_header then
            WindowRectOp(SP_WIN, 2, 0, y, row_right, y + lh, 0x081420)
            WindowText(SP_WIN, SP_FONT, item.label, SP_PAD_LEFT + 2, y, row_right, 0, 0x44AACC, false)
            sp_add_hs(hs, 0, y, row_right, y + lh, "", "", miniwin.cursor_arrow)
            WindowScrollwheelHandler(SP_WIN, hs, "snd_sp_scroll")
        else
            if (i % 2) == 0 then
                local alt = ColourNameToRGB(snd_get_setting("color_alternating_row", "#0C0C1A"))
                if alt ~= 0 then WindowRectOp(SP_WIN, 2, 0, y, row_right, y + lh, alt) end
            end
            WindowText(SP_WIN, SP_FONT, item.label,
                SP_PAD_LEFT + 8, y, val_left - 6, 0, Theme.BODY_TEXT, false)
            if item.type == "color" then
                local hex = snd_get_setting(item.key, item.default or "")
                if hex ~= "" then
                    local rgb = ColourNameToRGB(hex)
                    local sw  = lh - 4
                    WindowRectOp(SP_WIN, 2, val_left,      y + 2, val_left + sw, y + lh - 2, rgb)
                    WindowRectOp(SP_WIN, 1, val_left,      y + 2, val_left + sw, y + lh - 2, 0x888888)
                    WindowText(SP_WIN, SP_FONT, hex, val_left + sw + 3, y, val_right, 0, rgb, false)
                else
                    WindowText(SP_WIN, SP_FONT, "(default)", val_left, y, val_right, 0, 0x446688, false)
                end
            else
                WindowText(SP_WIN, SP_FONT, sp_display(item),
                    val_left, y, val_right, 0, 0x88AACC, false)
            end
            sp_add_hs(hs, SP_PAD_LEFT, y + 1, row_right, y + lh,
                "snd_sp_row_click", "Click to edit: " .. item.label, miniwin.cursor_hand)
            WindowScrollwheelHandler(SP_WIN, hs, "snd_sp_scroll")
        end
        y = y + lh
    end

    -- Tail: covers empty space below last row for scroll continuity.
    if y < content_bot then
        local hs = "sp_tail"
        sp_add_hs(hs, 0, y, _sp_width, content_bot, "", "", miniwin.cursor_arrow)
        WindowScrollwheelHandler(SP_WIN, hs, "snd_sp_scroll")
    end

    -- Scrollbar
    if need_sb then
        local sb_x = _sp_width - SP_PAD_RIGHT - SP_SB_W
        if not _sp_sb then
            _sp_sb = ScrollBar.new(SP_WIN, "sp", sb_x, content_top, sb_x + SP_SB_W, content_bot)
            _sp_sb:addUpdateCallback(nil, function(step)
                _sp_scroll = step - 1
                sp_draw()
            end)
        else
            _sp_sb:setRect(sb_x, content_top, sb_x + SP_SB_W, content_bot)
        end
        _sp_sb:setScroll(offset + 1, visible, #_sp_items, true)
        _sp_sb:draw(true)
    elseif _sp_sb then
        _sp_sb = nil
    end

    -- Chrome: title bar, border, resize handle.
    Theme.DressWindow(SP_WIN, SP_FONT, "SnD Settings")
    Theme.AddResizeTag(SP_WIN, 1, nil, nil,
        "snd_sp_resize_dn", "snd_sp_resize_mv", "snd_sp_resize_up")

    -- [x] painted over the right side of the title bar.
    local btn    = "[x]"
    local btn_w  = WindowTextWidth(SP_WIN, SP_FONT, btn) + 4
    local btn_x  = _sp_width - btn_w - 2
    local btn_ty = math.max(0, math.floor((body_top - lh) / 2))
    WindowText(SP_WIN, SP_FONT, btn, btn_x, btn_ty, 0, 0, 0x4488AA, false)
    local hs_x = "sp_closex"
    table.insert(_sp_hs, hs_x)
    WindowDeleteHotspot(SP_WIN, hs_x)
    WindowAddHotspot(SP_WIN, hs_x, btn_x - 1, 0, _sp_width, body_top,
        "", "", "", "", "snd_sp_close_btn",
        "Close Settings", miniwin.cursor_hand, 0)

    Repaint()
end

-- ─── PUBLIC API ──────────────────────────────────────────────────────────────

function sp_draw_if_open()
    if _sp_created and WindowInfo(SP_WIN, 5) then
        sp_draw()
    end
end

function sp_open()
    if not _sp_created then
        local sx = tonumber(GetInfo(281)) or 1920
        local sy = tonumber(GetInfo(280)) or 1080

        _sp_width  = math.max(SP_MIN_W, tonumber(GetVariable("snd_sp_w")) or SP_DEF_W)
        _sp_height = math.max(SP_MIN_H, tonumber(GetVariable("snd_sp_h")) or SP_DEF_H)

        _sp_winfo = movewindow.install(
            SP_WIN,
            miniwin.pos_top_left,
            miniwin.create_absolute_location,
            false, nil, nil,
            { x = math.floor((sx - _sp_width)  / 2),
              y = math.floor((sy - _sp_height) / 2) }
        )

        WindowCreate(SP_WIN,
            _sp_winfo.window_left, _sp_winfo.window_top,
            _sp_width, _sp_height,
            _sp_winfo.window_mode, _sp_winfo.window_flags,
            Theme.SECONDARY_BODY)

        _sp_created = true
    end

    _sp_scroll = 0
    WindowShow(SP_WIN, true)
    sp_draw()
end

function sp_close()
    if not _sp_created then return end
    WindowShow(SP_WIN, false)
end

function sp_toggle()
    if not _sp_created or not WindowInfo(SP_WIN, 5) then
        sp_open()
    else
        sp_close()
    end
end

function sp_save_state()
    if not _sp_created then return end
    movewindow.save_state(SP_WIN)
    SetVariable("snd_sp_w", tostring(_sp_width))
    SetVariable("snd_sp_h", tostring(_sp_height))
end

function sp_destroy()
    if not _sp_created then return end
    if WindowInfo(SP_WIN, 1) then WindowDelete(SP_WIN) end
    _sp_created = false
    _sp_sb      = nil
    _sp_hs      = {}
    _sp_items   = {}
end

-- ─── HOTSPOT CALLBACKS ───────────────────────────────────────────────────────

function snd_sp_row_click(flags, hotspot_id)
    if bit.band(flags, miniwin.hotspot_got_rh_mouse) ~= 0 then return end
    local idx = tonumber(hotspot_id:match("^sp_r(%d+)$"))
    if not idx then return end
    local item = _sp_items[idx]
    if not item or item.is_header then return end
    sp_edit(item)
end

function snd_sp_close_btn(flags, hotspot_id)
    sp_close()
end

function snd_sp_scroll(flags, hotspot_id)
    flags = flags or 0
    if #_sp_items == 0 then return end
    local lh      = sp_font_lh()
    local font_h  = Theme.TextHeight(SP_WIN, SP_FONT)
    local _, body_top = Theme.BodyMetrics(SP_WIN, SP_FONT, font_h, 1)
    local visible = math.max(1, math.floor((_sp_height - body_top) / lh))
    local max_off  = math.max(0, #_sp_items - visible)
    if max_off == 0 then return end
    if bit.band(flags, 0x100) ~= 0 then
        _sp_scroll = math.min(max_off, _sp_scroll + 3)
    else
        _sp_scroll = math.max(0, _sp_scroll - 3)
    end
    if _sp_sb then _sp_sb.step = _sp_scroll + 1 end
    sp_draw()
end

function snd_sp_resize_dn()
    _sp_resize_sx = WindowInfo(SP_WIN, 17)
    _sp_resize_sy = WindowInfo(SP_WIN, 18)
end

function snd_sp_resize_mv()
    if GetPluginVariable(PLUGIN_ID_LAYOUT, "lock_down_miniwindows") == "1" then return end
    local cx = WindowInfo(SP_WIN, 17)
    local cy = WindowInfo(SP_WIN, 18)
    _sp_width  = math.max(SP_MIN_W, _sp_width  + cx - _sp_resize_sx)
    _sp_height = math.max(SP_MIN_H, _sp_height + cy - _sp_resize_sy)
    _sp_resize_sx, _sp_resize_sy = cx, cy
    WindowResize(SP_WIN, _sp_width, _sp_height, Theme.SECONDARY_BODY)
    sp_draw()
end

function snd_sp_resize_up()
    SetVariable("snd_sp_w", tostring(_sp_width))
    SetVariable("snd_sp_h", tostring(_sp_height))
    sp_draw()
    SaveState()
end
