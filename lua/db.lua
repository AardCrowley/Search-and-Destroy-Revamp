-- db.lua
-- Database lifecycle helpers, schema DDL, and the migration entry point.
-- Does NOT contain game logic. Does NOT know about campaigns, quests, or mobs.
-- Depends on: constants.lua, util.lua

-- ─── DATABASE PATH ────────────────────────────────────────────────────────────

-- Absolute path to the SnD SQLite database file.
-- GetInfo(66) returns the MUSHclient data folder (the same location used by
-- the Aardwolf mapper, so SnDdb.db lives alongside the mapper's database).
snd_db_file = GetInfo(66) .. "SnDdb.db"

-- Absolute path to the Aardwolf mapper database (read-only).
-- The mapper plugin stores its chosen database name in its "db_name" plugin
-- variable.  PLUGIN_ID_MAPPER is defined in constants.lua.
-- Returns nil (and pathing will be disabled) if the mapper is not installed.
local _mapper_db_name = GetPluginVariable(PLUGIN_ID_MAPPER, "db_name")
mapper_db_file = _mapper_db_name and (GetInfo(66) .. _mapper_db_name .. ".db") or nil

-- ─── CONNECTION HELPERS ───────────────────────────────────────────────────────

-- Open the database and apply standard session pragmas.
-- Returns an open sqlite3 database object.
function db_open()
    local db = sqlite3.open(snd_db_file)
    db:exec("PRAGMA foreign_keys = ON")
    db:exec("PRAGMA journal_mode = WAL")
    return db
end

-- Close the database, releasing all prepared statements and the file handle.
function db_close(db)
    if db then
        db:close()
    end
end

-- Validate a SQLite return code.
-- Raises a Lua error if code is not sqlite3.OK, sqlite3.ROW, or sqlite3.DONE.
-- The query string is included in the error message for diagnostics.
-- Does NOT roll back or close — callers (execute_in_transaction) handle that.
function dbcheck(db, code, query)
    if code ~= sqlite3.OK  and
       code ~= sqlite3.ROW and
       code ~= sqlite3.DONE
    then
        error(db:errmsg() .. "\n\nCODE: " .. tostring(code) ..
              "\nQUERY: " .. tostring(query) .. "\n", 2)
    end
end

-- dbcheck() with the handle protected.
--
-- db_open() hands back a NEW connection every call, so a raising dbcheck()
-- between open and close unwinds straight past db_close() and orphans that
-- connection.  lsqlite3 does finalize it on garbage collection, but in WAL
-- mode the orphan keeps its lock until then, which is nondeterministic and
-- can stall other writers.
--
-- Use this instead of a bare dbcheck() anywhere the caller owns the handle
-- and is not already inside a pcall that closes it:
--
--     if not dbguard(db, db:exec(sql), "label") then return end
--
-- On failure the database is closed and the error reported, so callers only
-- have to handle the boolean.  Returns true when the code was OK/ROW/DONE.
function dbguard(db, code, query)
    local ok, err = pcall(dbcheck, db, code, query)
    if ok then return true end
    db_close(db)
    ErrorNote("SnD: " .. tostring(query) .. " failed: " .. tostring(err))
    return false
end

-- Execute fn(db) inside a BEGIN / COMMIT transaction.
-- Rolls back and re-raises any Lua error thrown by fn.
function execute_in_transaction(db, fn)
    dbcheck(db, db:exec("BEGIN"), "BEGIN")
    local ok, err = pcall(fn, db)
    if ok then
        dbcheck(db, db:exec("COMMIT"), "COMMIT")
    else
        db:exec("ROLLBACK")
        error(err, 2)
    end
end

-- ─── SCHEMA INTROSPECTION ─────────────────────────────────────────────────────

-- Returns true if a table named tbl_name exists in the database.
-- NOTE: must NOT return early from the nrows loop. An un-exhausted nrows
-- iterator leaves an open prepared statement, which holds a read lock on
-- sqlite_master and causes SQLITE_LOCKED (code 6) on subsequent DDL
-- (DROP TABLE, ALTER TABLE) within the same connection.
local function table_exists(db, tbl_name)
    local found = false
    for row in db:nrows(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=" ..
        fixsql(tbl_name)
    ) do
        found = true
    end
    return found
end

-- Returns true if column col_name exists in table tbl_name.
-- Same early-return restriction as table_exists above.
local function column_exists(db, tbl_name, col_name)
    local found = false
    for row in db:nrows("PRAGMA table_info(" .. tbl_name .. ")") do
        if row.name == col_name then found = true end
    end
    return found
end

-- ─── TABLE DDL ────────────────────────────────────────────────────────────────
-- One function per table. All use IF NOT EXISTS for idempotency.

local function create_characters_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS characters (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT    NOT NULL UNIQUE COLLATE NOCASE,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        )
    ]]), "create characters")
end

local function create_areas_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS areas (
            key        TEXT    PRIMARY KEY,
            name       TEXT    NOT NULL,
            minlvl     INTEGER NOT NULL DEFAULT 1,
            maxlvl     INTEGER NOT NULL DEFAULT 201,
            lock       INTEGER NOT NULL DEFAULT 0,
            start_room INTEGER,
            noquest    INTEGER NOT NULL DEFAULT 0,
            vidblain   INTEGER NOT NULL DEFAULT 0,
            -- 0 means "not rated", the convention mob_tags.difficulty
            -- already uses. This defaulted to 1, so every area was born
            -- rated easiest, a deliberate 1 could not be told from an area
            -- nobody had looked at, and routing treated the entire unrated
            -- map as its top-priority tier.
            difficulty INTEGER NOT NULL DEFAULT 0,
            source     TEXT    NOT NULL DEFAULT 'scrape',
            updated_at INTEGER
        )
    ]]), "create areas")
end

local function create_mob_sightings_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS mob_sightings (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            mob        TEXT    NOT NULL COLLATE NOCASE,
            room_name  TEXT    NOT NULL COLLATE NOCASE,
            roomid     INTEGER NOT NULL,
            zone       TEXT    NOT NULL REFERENCES areas(key),
            seen_count INTEGER NOT NULL DEFAULT 0,
            last_seen  INTEGER,
            UNIQUE(mob, roomid)
        )
    ]]), "create mob_sightings")
end

local function create_mob_kills_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS mob_kills (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            mob         TEXT    NOT NULL COLLATE NOCASE,
            roomid      INTEGER NOT NULL,
            zone        TEXT    NOT NULL REFERENCES areas(key),
            kill_count  INTEGER NOT NULL DEFAULT 0,
            last_killed INTEGER,
            UNIQUE(mob, roomid)
        )
    ]]), "create mob_kills")
end

local function create_mob_keywords_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS mob_keywords (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            char_id  INTEGER REFERENCES characters(id),
            zone     TEXT    NOT NULL REFERENCES areas(key),
            mob_name TEXT    NOT NULL COLLATE NOCASE,
            keyword  TEXT    NOT NULL,
            UNIQUE(char_id, zone, mob_name)
        )
    ]]), "create mob_keywords")
end

local function create_maze_rooms_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS maze_rooms (
            roomid   INTEGER PRIMARY KEY,
            zone     TEXT    NOT NULL REFERENCES areas(key),
            added_by INTEGER REFERENCES characters(id),
            added_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        )
    ]]), "create maze_rooms")
end

local function create_mob_tags_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS mob_tags (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            mob           TEXT    NOT NULL COLLATE NOCASE,
            zone          TEXT    NOT NULL REFERENCES areas(key),
            nowhere       INTEGER NOT NULL DEFAULT 0,
            nohunt        INTEGER NOT NULL DEFAULT 0,
            noscan        INTEGER NOT NULL DEFAULT 0,
            express       INTEGER NOT NULL DEFAULT 0,
            levelok       INTEGER NOT NULL DEFAULT 0,
            difficulty    INTEGER NOT NULL DEFAULT 0,
            priority_room INTEGER,
            UNIQUE(mob, zone)
        )
    ]]), "create mob_tags")
end

local function create_history_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS history (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            char_id       INTEGER NOT NULL REFERENCES characters(id),
            type          INTEGER NOT NULL,
            level_taken   INTEGER NOT NULL,
            start_time    INTEGER NOT NULL,
            end_time      INTEGER,
            status        INTEGER NOT NULL DEFAULT 1,
            qp_base       INTEGER NOT NULL DEFAULT 0,
            qp_bonus      INTEGER NOT NULL DEFAULT 0,
            tp_rewards    INTEGER NOT NULL DEFAULT 0,
            train_rewards INTEGER NOT NULL DEFAULT 0,
            prac_rewards  INTEGER NOT NULL DEFAULT 0,
            gold_rewards  INTEGER NOT NULL DEFAULT 0
        )
    ]]), "create history")
end

local function create_settings_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS settings (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            char_id INTEGER REFERENCES characters(id),
            name    TEXT    NOT NULL,
            value   TEXT    NOT NULL,
            UNIQUE(char_id, name)
        )
    ]]), "create settings")
end

-- mob_duplicates stores per-area mob death counts and the set of levels at which
-- each mob has been observed dying.  Populated by the xmobdeaths command, which
-- sends 'mobdeaths here hs' and parses the output.
-- levels is a JSON-encoded array of integers, e.g. '[10,12,15]'.
-- Used by consider output to guess mob level from CON_DETAILS difficulty ranges.
local function create_mob_duplicates_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS mob_duplicates (
            arid      TEXT NOT NULL REFERENCES areas(key),
            mob_name  TEXT NOT NULL COLLATE NOCASE,
            count     INTEGER NOT NULL DEFAULT 0,
            levels    TEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY (arid, mob_name)
        )
    ]]), "create mob_duplicates")
end

-- room_links stores player-configured connections between two specific room IDs
-- with an optional descriptive note (e.g. "6 room maze").  TSP does NOT use these
-- for shorter routes — the link exists purely to annotate the route with a note
-- that appears in the CP/GQ target list next to the relevant mob.
-- Room IDs are stored with room1 < room2 to avoid duplicate pairs.
local function create_room_links_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS room_links (
            room1  INTEGER NOT NULL,
            room2  INTEGER NOT NULL,
            note   TEXT    NOT NULL DEFAULT '',
            PRIMARY KEY (room1, room2)
        )
    ]]), "create room_links")
end

-- marks stores user-defined named room shortcuts.
-- 'xset mark <name> <roomid>' inserts/replaces a row.
-- 'xrt <name>' checks this table before falling through to areas.start_room.
local function create_marks_table(db)
    dbcheck(db, db:exec([[
        CREATE TABLE IF NOT EXISTS marks (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            name      TEXT    NOT NULL UNIQUE COLLATE NOCASE,
            room_id   INTEGER NOT NULL,
            area_name TEXT    NOT NULL DEFAULT '',
            room_name TEXT    NOT NULL DEFAULT ''
        )
    ]]), "create marks")
end

local function create_indexes(db)
    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_mob_sightings_zone_mob
            ON mob_sightings (zone, mob, room_name)
    ]]), "idx_mob_sightings_zone_mob")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_mob_sightings_roomid
            ON mob_sightings (roomid)
    ]]), "idx_mob_sightings_roomid")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_mob_kills_zone_mob
            ON mob_kills (zone, mob)
    ]]), "idx_mob_kills_zone_mob")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_mob_kills_roomid_kill
            ON mob_kills (roomid, kill_count DESC)
    ]]), "idx_mob_kills_roomid_kill")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_mob_keywords_zone_mob
            ON mob_keywords (zone, mob_name, char_id)
    ]]), "idx_mob_keywords_zone_mob")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_history_char_type_start
            ON history (char_id, type, start_time DESC)
    ]]), "idx_history_char_type_start")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_history_end_status_type
            ON history (end_time, status, type)
    ]]), "idx_history_end_status_type")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_mob_tags_zone_mob
            ON mob_tags (zone, mob)
    ]]), "idx_mob_tags_zone_mob")

    dbcheck(db, db:exec([[
        CREATE INDEX IF NOT EXISTS idx_room_links_room2
            ON room_links (room2)
    ]]), "idx_room_links_room2")

end

-- ─── MIGRATION STEPS ──────────────────────────────────────────────────────────

-- Step 1: Ensure the characters table exists and insert the initial character
-- record.  Returns the char_id that will be used for all subsequent steps.
local function migration_step1_characters(db)
    create_characters_table(db)

    -- Attempt to get the character name from GMCP.
    -- OnPluginInstall fires before GMCP data arrives, so the value may be nil.
    -- gmcp() itself may also be unavailable in some package configurations.
    local char_name = type(gmcp) == "function" and gmcp("char.base.name") or nil
    if type(char_name) ~= "string" or char_name == "" then
        char_name = "__pending__"
    end

    dbcheck(db, db:exec(
        "INSERT OR IGNORE INTO characters (name) VALUES (" .. fixsql(char_name) .. ")"
    ), "step1: insert initial character")

    local char_id = nil
    for row in db:nrows(
        "SELECT id FROM characters WHERE name=" .. fixsql(char_name)
    ) do
        char_id = row.id
    end

    if not char_id then
        error("migration_step1: failed to retrieve char_id for " .. char_name)
    end

    return char_id
end

-- Step 2: Create all tables (idempotent — uses IF NOT EXISTS).
-- Also adds any columns that were introduced after the initial v7 stamp so that
-- databases created by older alpha builds are brought forward without a full
-- drop-and-recreate.
-- NOTE: create_indexes() is intentionally NOT called here. The history index
-- references history.char_id, which may not exist yet on a v6 beta upgrade
-- (step 6 adds it). Indexes are created as the final step instead.
local function migration_step2_create_tables(db)
    create_areas_table(db)
    -- Add source column to areas if upgrading from a beta DB that predates it.
    if not column_exists(db, "areas", "source") then
        dbcheck(db, db:exec(
            "ALTER TABLE areas ADD COLUMN source TEXT NOT NULL DEFAULT 'scrape'"
        ), "add areas.source column")
    end
    if not column_exists(db, "areas", "difficulty") then
        dbcheck(db, db:exec(
            "ALTER TABLE areas ADD COLUMN difficulty INTEGER NOT NULL DEFAULT 0"
        ), "add areas.difficulty column")
    end
    create_mob_sightings_table(db)
    create_mob_kills_table(db)
    create_mob_keywords_table(db)
    create_mob_tags_table(db)
    -- Add columns to mob_tags when upgrading from older schema versions.
    if not column_exists(db, "mob_tags", "express") then
        dbcheck(db, db:exec(
            "ALTER TABLE mob_tags ADD COLUMN express INTEGER NOT NULL DEFAULT 0"
        ), "add mob_tags.express column")
    end
    if not column_exists(db, "mob_tags", "noscan") then
        dbcheck(db, db:exec(
            "ALTER TABLE mob_tags ADD COLUMN noscan INTEGER NOT NULL DEFAULT 0"
        ), "add mob_tags.noscan column")
    end
    if not column_exists(db, "mob_tags", "levelok") then
        dbcheck(db, db:exec(
            "ALTER TABLE mob_tags ADD COLUMN levelok INTEGER NOT NULL DEFAULT 0"
        ), "add mob_tags.levelok column")
    end
    -- Per-mob difficulty, 1-5 on the same scale as areas.difficulty.
    -- 0 means unrated: the mob inherits its area's rating.
    if not column_exists(db, "mob_tags", "difficulty") then
        dbcheck(db, db:exec(
            "ALTER TABLE mob_tags ADD COLUMN difficulty INTEGER NOT NULL DEFAULT 0"
        ), "add mob_tags.difficulty column")
    end
    create_maze_rooms_table(db)
    create_mob_duplicates_table(db)
    create_room_links_table(db)
    create_marks_table(db)
    create_history_table(db)
    create_settings_table(db)
end

-- Step 3: Migrate old monolithic 'mobs' table → mob_sightings + mob_kills.
-- Only runs if the 'mobs' table exists and has not yet been renamed.
--
-- mob_sightings.zone and mob_kills.zone both FK-reference areas(key).
-- Unlike UNIQUE violations, FK failures are NOT suppressed by INSERT OR IGNORE
-- in SQLite.  We therefore stub-insert any zone keys from mobs that are absent
-- from areas before attempting the data migration; the stubs carry source='stub'
-- so they can be identified and enriched by the areas.json refresh later.
local function migration_step3_mobs(db)
    if not table_exists(db, "mobs") then return end

    -- Ensure every zone key referenced by mobs exists in areas.
    dbcheck(db, db:exec([[
        INSERT OR IGNORE INTO areas (key, name, source, difficulty)
        SELECT DISTINCT zone, zone, 'stub', 0
        FROM mobs
        WHERE zone IS NOT NULL AND zone != ''
    ]]), "step3: stub missing area zones")

    dbcheck(db, db:exec([[
        INSERT OR IGNORE INTO mob_sightings (mob, room_name, roomid, zone, seen_count)
        SELECT mob, room, roomid, zone, seen_count FROM mobs
    ]]), "step3: mob_sightings insert")

    dbcheck(db, db:exec([[
        INSERT OR IGNORE INTO mob_kills (mob, roomid, zone, kill_count)
        SELECT mob, roomid, zone, kill_count FROM mobs WHERE kill_count > 0
    ]]), "step3: mob_kills insert")

    -- Rename rather than drop: kept for one version cycle as a safe rollback path.
    -- Drop in v8.
    dbcheck(db, db:exec(
        "ALTER TABLE mobs RENAME TO _legacy_mobs"
    ), "step3: rename mobs")
end

-- Step 4: Migrate 'mob_keyword_exceptions' → mob_keywords.
-- Migrated rows are global (char_id = NULL).
-- Only runs if the old table exists.
local function migration_step4_keywords(db)
    if not table_exists(db, "mob_keyword_exceptions") then return end

    -- Same FK requirement as step 3: stub-insert any area_name values not in areas.
    dbcheck(db, db:exec([[
        INSERT OR IGNORE INTO areas (key, name, source, difficulty)
        SELECT DISTINCT area_name, area_name, 'stub', 0
        FROM mob_keyword_exceptions
        WHERE area_name IS NOT NULL AND area_name != ''
    ]]), "step4: stub missing area zones")

    dbcheck(db, db:exec([[
        INSERT OR IGNORE INTO mob_keywords (char_id, zone, mob_name, keyword)
        SELECT NULL, area_name, mob_name, keyword FROM mob_keyword_exceptions
    ]]), "step4: mob_keywords insert")

    dbcheck(db, db:exec(
        "ALTER TABLE mob_keyword_exceptions RENAME TO _legacy_mob_keyword_exceptions"
    ), "step4: rename mob_keyword_exceptions")
end

-- Step 5: Migrate old 'area' table → new 'areas' table.
-- The old table used text 'true'/'false' for boolean columns.
-- Rows with a NULL or empty key are skipped to avoid FK constraint violations
-- (confirmed issue in some beta installs — see DESIGN.md §12).
-- Only runs if the old 'area' table exists.
local function migration_step5_areas(db)
    if not table_exists(db, "area") then return end

    dbcheck(db, db:exec([[
        INSERT OR IGNORE INTO areas (key, name, minlvl, maxlvl, lock,
                                     start_room, noquest, vidblain, difficulty)
        SELECT
            key,
            name,
            CAST(minlvl AS INTEGER),
            CAST(maxlvl AS INTEGER),
            CAST(lock AS INTEGER),
            CAST(startRoom AS INTEGER),
            CASE WHEN noquest = 'true' OR noquest = '1' THEN 1 ELSE 0 END,
            CASE WHEN vidblain = 'true' OR vidblain = '1' THEN 1 ELSE 0 END,
            0
        FROM area
        WHERE key IS NOT NULL AND key != ''
    ]]), "step5: areas insert")

    dbcheck(db, db:exec(
        "ALTER TABLE area RENAME TO _legacy_area"
    ), "step5: rename area")
end

-- Step 6: Migrate 'history' table from beta schema (no char_id, combined qp) to
-- v7 schema (char_id required, qp_base / qp_bonus split).
-- Only runs if history exists but lacks the char_id column.
local function migration_step6_history(db, char_id)
    if not table_exists(db, "history")                   then return end
    if column_exists(db, "history", "char_id")            then return end

    dbcheck(db, db:exec([[
        CREATE TABLE history_new (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            char_id       INTEGER NOT NULL REFERENCES characters(id),
            type          INTEGER NOT NULL,
            level_taken   INTEGER NOT NULL,
            start_time    INTEGER NOT NULL,
            end_time      INTEGER,
            status        INTEGER NOT NULL DEFAULT 1,
            qp_base       INTEGER NOT NULL DEFAULT 0,
            qp_bonus      INTEGER NOT NULL DEFAULT 0,
            tp_rewards    INTEGER NOT NULL DEFAULT 0,
            train_rewards INTEGER NOT NULL DEFAULT 0,
            prac_rewards  INTEGER NOT NULL DEFAULT 0,
            gold_rewards  INTEGER NOT NULL DEFAULT 0
        )
    ]]), "step6: create history_new")

    -- qp_rewards maps to qp_base; qp_bonus starts at 0 for all migrated rows.
    dbcheck(db, db:exec(
        "INSERT INTO history_new " ..
        "    (char_id, type, level_taken, start_time, end_time, status, " ..
        "     qp_base, tp_rewards, train_rewards, prac_rewards, gold_rewards) " ..
        "SELECT " ..
        "    " .. char_id .. ", type, level_taken, start_time, end_time, status, " ..
        "    qp_rewards, tp_rewards, train_rewards, prac_rewards, gold_rewards " ..
        "FROM history"
    ), "step6: history_new insert")

    dbcheck(db, db:exec("DROP TABLE history"),                   "step6: drop history")
    dbcheck(db, db:exec("ALTER TABLE history_new RENAME TO history"), "step6: rename history")
end

-- Step 7: Migrate mcvar_ plugin variables → settings table.
-- Delegates to migrate_mcvars() in settings.lua (loaded before migrate_database
-- is ever called, since init_plugin_after_load() runs after all dofile()s).
local function migration_step7_settings(db, char_id)
    if type(migrate_mcvars) == "function" then
        migrate_mcvars(db, char_id)
    end
end

-- Step 8: Migrate mazeStartRooms plugin variable → maze_rooms table.
-- The variable holds a serialized Lua table:
--   { [roomid] = { areaname = "key" }, ... }
-- Uses INSERT OR IGNORE so re-running is safe.  Rows whose zone does not
-- exist in the areas table will be silently skipped (foreign key violation
-- caught by the ignored error) rather than aborting the whole migration.
local function migration_step8_maze_rooms(db, char_id)
    local raw = GetVariable("mazeStartRooms")
    if not raw or raw == "" then return end

    -- Deserialize: load the string as a Lua chunk returning the table.
    local ok, obj = pcall(function() return (loadstring("return " .. raw))() end)
    if not ok or type(obj) ~= "table" then return end

    for roomid, data in pairs(obj) do
        local rid  = tonumber(roomid)
        -- data is { areaname = "key" }; guard against malformed entries.
        local zone = type(data) == "table" and data.areaname
        if rid and type(zone) == "string" and zone ~= "" then
            -- Ignore FK errors for unknown zone keys; don't abort migration.
            db:exec(
                "INSERT OR IGNORE INTO maze_rooms (roomid, zone, added_by) VALUES (" ..
                rid .. ", " .. fixsql(zone) .. ", " .. char_id .. ")"
            )
        end
    end
end

-- Step 9: Migrate mcvar_area_range and mcvar_areaStartRooms → areas table.
--
-- mcvar_area_range format: { ["Area Name"] = { arid="key", min=N, max=N } }
--   Inserts area rows not already present (many overlap with step 5 / areas.json
--   but INSERT OR IGNORE is safe).  Source = 'scrape'.
--
-- mcvar_areaStartRooms format: { [areakey] = { roomid = "N" } }
--   User-customized start rooms.  Ensures the area row exists, then updates
--   start_room.  Runs after area_range so the row is likely already there.
--   Skips entries with roomid <= 0 (crec and similar inaccessible stubs).
local function migration_step9_area_vars(db)
    -- ── Part A: mcvar_area_range ──────────────────────────────────────────────
    -- GetVariable() returns "" for unset vars in some MUSHClient builds;
    -- GetPluginVariable(id, name) reliably returns nil when absent.
    local _pid      = GetPluginID()
    local range_raw = GetPluginVariable(_pid, "mcvar_area_range")
    if range_raw and range_raw ~= "" then
        local ok, obj = pcall(function() return (loadstring("return " .. range_raw))() end)
        if ok and type(obj) == "table" then
            for area_name, data in pairs(obj) do
                local key = type(data) == "table" and data.arid
                if type(key) == "string" and key ~= "" then
                    local minl = tonumber(data.min) or 1
                    local maxl = tonumber(data.max) or 201
                    db:exec(
                        "INSERT OR IGNORE INTO areas (key, name, minlvl, maxlvl, source, difficulty) " ..
                        "VALUES (" ..
                        fixsql(key) .. ", " ..
                        fixsql(tostring(area_name)) .. ", " ..
                        minl .. ", " .. maxl .. ", 'scrape', 0)"
                    )
                end
            end
        end
    end

    -- ── Part B: mcvar_areaStartRooms ─────────────────────────────────────────
    -- Each key is compared against the areas table:
    --   · Key exists, same room_id   → ignore (already correct)
    --   · Key exists, diff room_id   → update areas.start_room (user override)
    --   · Key does not exist         → user-defined shortcut; insert into marks
    local starts_raw = GetPluginVariable(_pid, "mcvar_areaStartRooms")
    if starts_raw and starts_raw ~= "" then
        local ok, obj = pcall(function() return (loadstring("return " .. starts_raw))() end)
        if ok and type(obj) == "table" then
            for key, data in pairs(obj) do
                local roomid = type(data) == "table" and tonumber(data.roomid)
                if type(key) == "string" and key ~= "" and roomid and roomid > 0 then
                    local lc_key      = key:lower()
                    local area_exists = false
                    local area_start  = nil
                    for row in db:nrows(
                        "SELECT start_room FROM areas WHERE key=" .. fixsql(lc_key) .. " LIMIT 1"
                    ) do
                        area_exists = true
                        area_start  = tonumber(row.start_room)
                    end

                    if area_exists then
                        if area_start ~= roomid then
                            -- User has a different start room than the seeded one; honor it.
                            db:exec(
                                "UPDATE areas SET start_room=" .. roomid ..
                                " WHERE key=" .. fixsql(lc_key)
                            )
                        end
                        -- else: same room → nothing to do
                    else
                        -- Not a known area key; treat as a user-defined navigation shortcut.
                        -- Look up room/area names from the GMCP mapper DB if available.
                        local aname, rname = "", ""
                        if mapper_db_file then
                            local mapdb = sqlite3.open(mapper_db_file, sqlite3.OPEN_READONLY)
                            if mapdb then
                                for mr in mapdb:nrows(
                                    "SELECT r.name AS rname, a.name AS aname " ..
                                    "FROM rooms r LEFT JOIN areas a ON r.area = a.uid " ..
                                    "WHERE r.uid = " .. tostring(roomid) .. " LIMIT 1"
                                ) do
                                    aname = mr.aname or ""
                                    rname = mr.rname or ""
                                end
                                mapdb:close()
                            end
                        end
                        db:exec(
                            "INSERT OR IGNORE INTO marks (name, room_id, area_name, room_name) VALUES (" ..
                            fixsql(key) .. ", " .. roomid ..
                            ", " .. fixsql(aname) .. ", " .. fixsql(rname) .. ")"
                        )
                    end
                end
            end
        end
    end
end

-- ─── MIGRATION ENTRY POINT ────────────────────────────────────────────────────

-- Run all migration steps in sequence.  Idempotent: safe to call multiple times.
-- Handles all three starting states (see DESIGN.md §6):
--   - Fresh (no DB)           : PRAGMA user_version = 0, no tables
--   - Master branch           : PRAGMA user_version 0–4, legacy table names
--   - Beta branch             : PRAGMA user_version = 6, needs v7 schema changes
function migrate_database()
    local db = db_open()

    -- Read current schema version.
    local version = 0
    for row in db:nrows("PRAGMA user_version") do
        version = row.user_version
    end

    if version >= SCHEMA_VERSION then
        db_close(db)
        return true  -- Already at target version; nothing to do.
    end

    InfoNote("SnD: Migrating database from schema v" .. version ..
             " to v" .. SCHEMA_VERSION .. " ...")

    local ok, err = pcall(function()
        execute_in_transaction(db, function(db)
            InfoNote("SnD: migration step 1: characters")
            local char_id = migration_step1_characters(db)
            InfoNote("SnD: migration step 2: create tables")
            migration_step2_create_tables(db)
            -- step 5 (areas) must run before steps 3 and 4 (mobs/keywords):
            -- those tables FK-reference areas(key).  The old 'area' table (master
            -- branch) is migrated here; beta-branch installs that already have
            -- 'areas' will also have stubs inserted in step 3/4 for any missing keys.
            InfoNote("SnD: migration step 5: areas")
            migration_step5_areas(db)
            InfoNote("SnD: migration step 3: mobs")
            migration_step3_mobs(db)
            InfoNote("SnD: migration step 4: keywords")
            migration_step4_keywords(db)
            InfoNote("SnD: migration step 6: history")
            migration_step6_history(db, char_id)
            InfoNote("SnD: migration step 7: settings")
            migration_step7_settings(db, char_id)
            InfoNote("SnD: migration step 8: maze rooms")
            migration_step8_maze_rooms(db, char_id)
            InfoNote("SnD: migration step 9: area vars")
            migration_step9_area_vars(db)
            -- Step 10: create indexes now that all tables are in their final shape.
            -- Must run after step 6 so idx_history_char_type_start can reference
            -- history.char_id (which step 6 adds for v6 beta upgrades).
            InfoNote("SnD: migration step 10: indexes")
            create_indexes(db)
            InfoNote("SnD: migration step 11: stamp version")
            dbcheck(db, db:exec("PRAGMA user_version = " .. SCHEMA_VERSION),
                    "set user_version")
        end)
    end)

    db_close(db)

    if ok then
        InfoNote("SnD: Database migration complete (schema v" .. SCHEMA_VERSION .. ").")
        return true
    else
        ErrorNote("SnD: Database migration FAILED: " .. tostring(err))
        ErrorNote("SnD: Your data has NOT been changed. Please report this error.")
        return false
    end
end

-- ─── PLUGIN INIT ──────────────────────────────────────────────────────────────

-- Called by the bootstrap loader after all modules have been dofile()'d.
-- This is the real plugin initialization sequence.
function init_plugin_after_load()
    -- 0. Record the session start time for snd summary.
    snd_session_start = os.time()

    -- 1. Migrate the database (creates schema, migrates legacy data).
    if not migrate_database() then
        ErrorNote("SnD: Aborting plugin load due to migration failure.")
        return
    end

    -- 2. Resolve character identity now that the characters table exists.
    --    init_current_character() is defined in characters.lua.
    init_current_character()

    -- 3. Fetch area data if the areas table is empty (fresh install).
    --    fetch_areas_if_empty() is defined in areas.lua (async; returns immediately).
    fetch_areas_if_empty()

    -- 4. Build the in-memory area name cross-reference.
    --    build_area_name_xref() is defined in areas.lua.
    build_area_name_xref()

    -- 5. Load maze rooms into the in-memory mazeStartRooms cache for scan code.
    --    load_maze_rooms_cache() is defined in areas.lua.
    load_maze_rooms_cache()

    -- 6. Create the miniwindow.
    --    xg_create_window() is defined in window.lua.
    xg_create_window()

    -- 7. Reload XML-owned globals (gqid_*, anex_*, xset_*, etc.) from the DB,
    --    overriding the hardcoded defaults that were set at preamble time.
    if type(init_xml_settings) == "function" then
        init_xml_settings()
    end

    -- 8. Initialise history timing state (elapsed + last-completion tracking).
    --    history_init_timing() is defined in history.lua.
    if type(history_init_timing) == "function" then
        history_init_timing()
    end

    -- 9. Request GMCP data from the server.
    send_gmcp_packet("request char")
    send_gmcp_packet("request room")

    -- 10. If the plugin version changed since the user last saw the changelog,
    --     show them what is new. Silent when there is nothing to show or the
    --     download fails; cl_check_new_version() is defined in changelog.lua.
    if type(cl_check_new_version) == "function" then
        cl_check_new_version()
    end

    -- 11. Replace the plugin file if it is older than the published release.
    --     Deliberately driven from a module: the plugin file cannot update
    --     itself on v6.0, so this is what spares those installs a manual
    --     download. Asynchronous and silent unless there is something to do.
    if type(snd_upgrade_plugin_file_if_stale) == "function" then
        snd_upgrade_plugin_file_if_stale()
    end

    InfoNote("SnD: Search & Destroy v" .. snd_version() .. " loaded.")
end
