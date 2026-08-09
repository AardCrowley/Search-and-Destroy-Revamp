-- characters.lua
-- Character table operations and pending character resolution.
-- Depends on: constants.lua, util.lua, db.lua

-- ─── MODULE STATE ─────────────────────────────────────────────────────────────

-- The char_id of the currently active character.
-- nil until init_current_character() has been called.
-- May equal the __pending__ row's id if GMCP has not yet arrived.
local _current_char_id   = nil

-- The name of the currently active character (or "__pending__").
local _current_char_name = nil

-- ─── PUBLIC API ───────────────────────────────────────────────────────────────

-- Returns the char_id for the currently active character.
-- May return the __pending__ id if GMCP has not resolved yet.
-- Returns nil if init_current_character() has not been called.
function get_current_char_id()
    return _current_char_id
end

-- Returns the current character name, or nil if not yet initialized.
function get_current_char_name()
    return _current_char_name
end

-- Get or create a character record by name, returning its char_id.
-- Uses INSERT OR IGNORE so duplicate calls with the same name are safe.
function get_or_create_character(name)
    local db = db_open()

    -- dbguard closes the handle before reporting; re-raise so the contract
    -- ("returns an id, or raises") is unchanged from the caller's view.
    if not dbguard(db, db:exec(
        "INSERT OR IGNORE INTO characters (name) VALUES (" .. fixsql(name) .. ")"
    ), "get_or_create_character: insert " .. tostring(name)) then
        error("get_or_create_character: insert failed for " .. tostring(name))
    end

    local char_id = nil
    for row in db:nrows(
        "SELECT id FROM characters WHERE name=" .. fixsql(name)
    ) do
        char_id = row.id
    end

    db_close(db)

    if not char_id then
        error("get_or_create_character: failed to retrieve id for " .. tostring(name))
    end

    return char_id
end

-- Initialize the module-level character state from the database.
-- Called by init_plugin_after_load() immediately after migrate_database().
-- The characters table is guaranteed to exist at this point.
function init_current_character()
    local db = db_open()

    -- Try to get the real name from GMCP first.
    local char_name = gmcp("char.base.name")

    if type(char_name) == "string" and char_name ~= "" then
        -- Ensure a row exists for the real name (handles the case where migration
        -- inserted __pending__ because GMCP wasn't ready yet).
        if not dbguard(db, db:exec(
            "INSERT OR IGNORE INTO characters (name) VALUES (" .. fixsql(char_name) .. ")"
        ), "init_current_character: insert " .. tostring(char_name)) then return end
        for row in db:nrows(
            "SELECT id FROM characters WHERE name=" .. fixsql(char_name)
        ) do
            _current_char_id   = row.id
            _current_char_name = char_name
        end
    else
        -- GMCP not ready: use the __pending__ row created during migration.
        for row in db:nrows(
            "SELECT id FROM characters WHERE name='__pending__'"
        ) do
            _current_char_id   = row.id
            _current_char_name = "__pending__"
        end
        -- __pending__ was renamed to the real character name in a prior session.
        -- Fall back to the most recently created real character row so that
        -- snd_set_setting / snd_get_setting work until GMCP arrives and
        -- resolve_pending_character() corrects _current_char_id.
        if not _current_char_id then
            for row in db:nrows(
                "SELECT id, name FROM characters" ..
                " WHERE name != '__pending__'" ..
                " ORDER BY id DESC LIMIT 1"
            ) do
                _current_char_id   = row.id
                _current_char_name = row.name
            end
        end
    end

    db_close(db)
end

-- Called from OnPluginBroadcast when a GMCP char.base or char.status packet
-- arrives with a valid character name.
-- Resolves the __pending__ character row to the real name, or switches to a
-- new character record if a different character has logged in.
function resolve_pending_character(char_name)
    if not char_name or char_name == "" then return end

    -- Guard: if plugin initialisation did not complete (e.g. migration failed),
    -- _current_char_id is nil and the characters table may not exist yet.
    if not _current_char_id then return end

    -- Nothing to do if already resolved to this name.
    if _current_char_name == char_name then return end

    local db = db_open()

    if _current_char_name == "__pending__" then
        -- Check whether a real row for this name already exists.
        local existing_id = nil
        for row in db:nrows(
            "SELECT id FROM characters WHERE name=" .. fixsql(char_name)
        ) do
            existing_id = row.id
        end

        if existing_id then
            -- A real row exists: re-point the module state to it.
            -- The orphaned __pending__ row is left in place because it may have
            -- history or settings rows referencing its id.  It will be cleaned
            -- up in a future maintenance migration.
            _current_char_id   = existing_id
            _current_char_name = char_name
            if type(clear_settings_cache) == "function" then clear_settings_cache() end
        else
            -- No real row: rename __pending__ to the actual character name.
            -- On failure leave _current_char_name as __pending__ so a later
            -- call retries, rather than claiming a rename that did not happen.
            if not dbguard(db, db:exec(
                "UPDATE characters SET name=" .. fixsql(char_name) ..
                " WHERE id=" .. _current_char_id
            ), "resolve_pending_character: rename __pending__") then return end
            _current_char_name = char_name
        end

    else
        -- A different character has logged in (e.g. world reconnect with an alt).
        -- Create or find a row for the new name.
        if not dbguard(db, db:exec(
            "INSERT OR IGNORE INTO characters (name) VALUES (" .. fixsql(char_name) .. ")"
        ), "resolve_pending_character: insert " .. tostring(char_name)) then return end
        for row in db:nrows(
            "SELECT id FROM characters WHERE name=" .. fixsql(char_name)
        ) do
            _current_char_id   = row.id
            _current_char_name = char_name
        end

        -- The settings cache contains values resolved for the previous character.
        -- Invalidate it so the next read fetches rows for the new character.
        if type(clear_settings_cache) == "function" then
            clear_settings_cache()
        end
    end

    db_close(db)
end
