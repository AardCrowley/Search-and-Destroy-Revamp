-- settings.lua
-- Settings table operations, in-memory cache, and mcvar_ migration.
-- Depends on: constants.lua, util.lua, db.lua, characters.lua

-- ─── CACHE ────────────────────────────────────────────────────────────────────

-- In-memory cache of resolved setting values.
-- Key   = setting name string.
-- Value = resolved string value, OR false meaning "queried the DB; not found".
--         false lets the caller's default_value vary per call without re-hitting
--         the DB every time.
-- Populated on first access per session.  Invalidated by snd_set_setting().
local _settings_cache = {}

-- Invalidate the entire settings cache (called when character identity changes).
function clear_settings_cache()
    _settings_cache = {}
end

-- ─── PUBLIC API ───────────────────────────────────────────────────────────────

-- Get a setting value for the current character.
-- Resolution order:
--   1. In-memory cache
--   2. Per-character row in settings table (char_id = current)
--   3. Global row in settings table (char_id IS NULL)
--   4. default_value (not persisted)
-- Returns default_value if the setting is not found in the database.
function snd_get_setting(name, default_value)
    -- Fast path: cache hit.  false = "not in DB"; return caller's default.
    if _settings_cache[name] ~= nil then
        local cached = _settings_cache[name]
        return cached ~= false and cached or default_value
    end

    local db = db_open()
    local value = nil
    local char_id = get_current_char_id()

    -- Wrap in pcall: the settings table may not exist if migration has not yet
    -- completed (or failed), in which case we fall through to default_value.
    pcall(function()
        -- Try per-character setting first.
        if char_id then
            for row in db:nrows(
                "SELECT value FROM settings WHERE char_id=" .. char_id ..
                " AND name=" .. fixsql(name)
            ) do
                value = row.value
            end
        end

        -- Fall back to global setting.
        -- ORDER BY id DESC so that if duplicate NULL-keyed rows exist (from a
        -- prior INSERT OR REPLACE bug), the most recently written row wins.
        if value == nil then
            for row in db:nrows(
                "SELECT value FROM settings WHERE char_id IS NULL AND name=" .. fixsql(name) ..
                " ORDER BY id DESC LIMIT 1"
            ) do
                value = row.value
            end
        end
    end)

    db_close(db)

    if value ~= nil then
        _settings_cache[name] = value
        return value
    end

    -- Not in DB: cache the absence so subsequent calls skip the DB entirely.
    _settings_cache[name] = false
    return default_value
end

-- Set a setting value.
-- is_global = true  → writes char_id = NULL (applies to all characters)
-- is_global = false → writes char_id = current character
-- Invalidates the cache entry for name.
function snd_set_setting(name, value, is_global)
    -- Guard: per-character writes need a resolved character identity.
    -- Global writes (char_id = NULL) are attempted regardless — they don't
    -- reference a character row — but are wrapped in pcall in case the
    -- settings table doesn't exist yet (migration failed/incomplete).
    local char_id = get_current_char_id()
    if not is_global and not char_id then return end

    local db = db_open()

    local char_id_sql = char_id and tostring(char_id) or "NULL"

    -- pcall so that a missing settings table (migration incomplete) doesn't crash.
    pcall(function()
        if is_global then
            -- SQLite UNIQUE treats NULLs as distinct, so INSERT OR REPLACE does NOT
            -- replace an existing (NULL, name) row — it silently inserts a duplicate.
            -- Use explicit DELETE + INSERT for global settings to avoid accumulation.
            dbcheck(db, db:exec(
                "DELETE FROM settings WHERE char_id IS NULL AND name=" .. fixsql(name)
            ), "snd_set_setting delete: " .. tostring(name))
            dbcheck(db, db:exec(
                "INSERT INTO settings (char_id, name, value) VALUES (NULL, " ..
                fixsql(name) .. ", " .. fixsql(tostring(value)) .. ")"
            ), "snd_set_setting insert: " .. tostring(name))
        else
            dbcheck(db, db:exec(
                "INSERT OR REPLACE INTO settings (char_id, name, value) VALUES (" ..
                char_id_sql .. ", " .. fixsql(name) .. ", " .. fixsql(tostring(value)) .. ")"
            ), "snd_set_setting: " .. tostring(name))
        end
    end)

    db_close(db)

    -- Invalidate the cache so the next read reflects the new value.
    _settings_cache[name] = nil
end

-- ─── MCVAR MIGRATION MAP ──────────────────────────────────────────────────────
-- Maps old MUSHclient plugin variable names to their v7 setting names and scope.
-- Keys MUST match the actual stored variable name exactly as returned by
-- GetVariableList().  Confirmed against a real state-file.xml:
--   · color_*, debug_mode, index_already_checked, last_installed_version,
--     and xset_express_min_kill_count are stored WITHOUT the "mcvar_" prefix.
--   · Everything else is stored WITH the "mcvar_" prefix.
-- global = true  → stored in settings with char_id = NULL
-- global = false → stored in settings with char_id = <current character>

local MCVAR_MAP = {
    -- ── Global settings ──────────────────────────────────────────────────────
    mcvar_xset_sound_onoff            = { name = "sound_onoff",                 global = true  },
    mcvar_xset_gq_check_extra_aliases = { name = "gq_check_extra_aliases",      global = true  },
    mcvar_window_pos_x                = { name = "window_pos_x",                global = true  },
    mcvar_window_pos_y                = { name = "window_pos_y",                global = true  },
    mcvar_window_width                = { name = "window_width",                global = true  },
    mcvar_window_height               = { name = "window_height",               global = true  },
    mcvar_window_width_max            = { name = "window_width_max",            global = true  },
    mcvar_window_height_max           = { name = "window_height_max",           global = true  },
    mcvar_window_state                = { name = "window_state",                global = true  },
    mcvar_window_font                 = { name = "window_font",                 global = true  },
    mcvar_window_font_size            = { name = "window_font_size",            global = true  },
    mcvar_window_font_bold            = { name = "window_font_bold",            global = true  },
    mcvar_window_font_italic          = { name = "window_font_italic",          global = true  },
    mcvar_window_font_underline       = { name = "window_font_underline",       global = true  },
    mcvar_window_hide_settings_button = { name = "window_hide_settings_button", global = true  },
    mcvar_xset_table_notes            = { name = "table_notes",                 global = true  },
    mcvar_xset_table_width            = { name = "table_width",                 global = true  },
    mcvar_automatic_update_checks     = { name = "automatic_update_checks",     global = true  },
    debug_mode                        = { name = "debug_mode",                  global = true  },
    mcvar_xset_express_onoff          = { name = "express_onoff",               global = true  },
    xset_express_min_kill_count       = { name = "express_min_kill_count",      global = true  },
    color_normal                      = { name = "color_normal",                global = true  },
    color_targeted                    = { name = "color_targeted",              global = true  },
    color_dead                        = { name = "color_dead",                  global = true  },
    color_unknown                     = { name = "color_unknown",               global = true  },
    color_unknown_dead                = { name = "color_unknown_dead",          global = true  },
    color_unlikely                    = { name = "color_unlikely",              global = true  },
    color_unlikely_tag                = { name = "color_unlikely_tag",          global = true  },
    color_quest_available             = { name = "color_quest_available",       global = true  },
    color_quest_complete              = { name = "color_quest_complete",        global = true  },
    color_quest_waiting               = { name = "color_quest_waiting",         global = true  },
    color_alternating_row             = { name = "color_alternating_row",       global = true  },
    last_installed_version            = { name = "last_installed_version",      global = true  },
    index_already_checked             = { name = "index_already_checked",       global = true  },
    -- ── Per-character settings ────────────────────────────────────────────────
    mcvar_cp_level_taken              = { name = "cp_level_taken",              global = false },
    mcvar_xcp_action_mode             = { name = "xcp_action_mode",             global = false },
    mcvar_xcp_targets_quest_onoff     = { name = "xcp_targets_quest_onoff",     global = false },
    mcvar_silentMode_command          = { name = "silent_mode",                 global = false },
    mcvar_anex_tnl_cutoff             = { name = "anex_tnl_cutoff",             global = false },
    mcvar_anex_automatic_onoff        = { name = "anex_automatic_onoff",        global = false },
    mcvar_xset_vidblain_level         = { name = "vidblain_level",              global = false },
    mcvar_xset_vidblain_onoff         = { name = "vidblain_onoff",              global = false },
    mcvar_xset_nx_action              = { name = "nx_action",                   global = false },
    mcvar_auto_reload                 = { name = "auto_reload",                   global = false },
    mcvar_xset_overwrite_con          = { name = "con_overwrite",               global = false },
    mcvar_quick_kill_command          = { name = "quick_kill_command",          global = false },
    mcvar_gqid_joined                 = { name = "gqid_joined",                 global = false },
    mcvar_gqid_started                = { name = "gqid_started",                global = false },
    mcvar_gqid_extended               = { name = "gqid_extended",               global = false },
    mcvar_gq_info_efflvl              = { name = "gq_info_efflvl",              global = false },
    mcvar_qt_mob                      = { name = "qt_mob",                      global = false },
    mcvar_qt_arid                     = { name = "qt_arid",                     global = false },
    mcvar_qt_areaName                 = { name = "qt_areaName",                 global = false },
    mcvar_qt_room                     = { name = "qt_room",                     global = false },
    mcvar_cp_info_qp_reward           = { name = "cp_info_qp_reward",           global = false },
    mcvar_cp_info_gold_reward         = { name = "cp_info_gold_reward",         global = false },
    mcvar_cp_info_train_reward        = { name = "cp_info_train_reward",        global = false },
    mcvar_cp_info_practices_reward    = { name = "cp_info_practices_reward",    global = false },
    mcvar_cp_info_tp_reward           = { name = "cp_info_tp_reward",           global = false },
    mcvar_xgui_window_onoff           = { name = "xgui_window_onoff",           global = false },
}

-- ─── MCVAR MIGRATION ──────────────────────────────────────────────────────────

-- Called from migration Step 7 (inside the migration transaction) after all
-- modules are loaded.  Reads each known mcvar_ plugin variable and inserts it
-- into the settings table using INSERT OR IGNORE so existing rows are preserved.
-- char_id is the ID of the current (or __pending__) character record.
function migrate_mcvars(db, char_id)
    local vars = GetVariableList()
    if not vars then return end

    for _, varname in ipairs(vars) do
        local mapping = MCVAR_MAP[varname]
        if mapping then
            local value = GetVariable(varname)
            if value ~= nil and value ~= "" and (mapping.global or char_id) then
                local char_id_sql = mapping.global and "NULL" or tostring(char_id)
                db:exec(
                    "INSERT OR IGNORE INTO settings (char_id, name, value) VALUES (" ..
                    char_id_sql .. ", " ..
                    fixsql(mapping.name) .. ", " ..
                    fixsql(value) .. ")"
                )
            end
        end
    end
end
