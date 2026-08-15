-- keywords.lua
-- Mob keyword lookup, guessing, and per-character overrides.
-- Depends on: constants.lua, util.lua, db.lua, characters.lua
--
-- The mob_keywords table stores exceptions to the keyword-guesser algorithm.
-- char_id NULL = global exception (all characters).
-- char_id N    = per-character override for that character.
-- Query pattern: char-specific row first, fall back to global row.
--
-- GMKW_AREA_FILTERS stays in Lua because it is logic (regexes), not data.

-- ─── STOP-WORDS ───────────────────────────────────────────────────────────────
-- Words that are never mob keywords: articles, prepositions, conjunctions,
-- and a small set of intensifiers.
--
-- NOTE: Common adjectives (old, dark, small, etc.) are intentionally NOT here.
-- They CAN be valid Aardwolf keywords set by area builders (e.g., "old man",
-- "dark elf"). Stripping them would break those mobs.

local GMKW_OMIT = {
    -- Articles / determiners
    ["a"]=true, ["an"]=true, ["the"]=true, ["some"]=true,
    -- Conjunctions
    ["and"]=true, ["or"]=true, ["nor"]=true, ["but"]=true,
    -- Prepositions (never standalone keywords)
    ["of"]=true,   ["in"]=true,   ["on"]=true,  ["at"]=true,
    ["to"]=true,   ["for"]=true,  ["by"]=true,  ["as"]=true,
    ["from"]=true, ["with"]=true, ["into"]=true, ["upon"]=true,
    -- Pure intensifiers
    ["very"]=true,
}

-- ─── AREA-SPECIFIC REGEX FILTERS ─────────────────────────────────────────────
-- Applied after stop-word removal to handle area-specific naming quirks.
-- Each entry is a list of {f=pattern, g=replacement}. First match wins.
-- Stays in Lua: these are coding rules, not data.

local GMKW_AREA_FILTERS = {
    ["adaldar"]   = {{f = "^.*(el)vish (%a*%s?%a+)$",             g = "%1 %2"}},
    ["bonds"]     = {{f = "^(.*[bgry]%a+) dragon$",               g = "%1"}},
    ["citadel"]   = {{f = "^([bgjlmsv]%a+) ([ap]r%a+[el]) .+$",  g = "%1 %2"}},
    ["elemental"] = {
        {f = "^(%a+)%'(%a+) (%a+)$",          g = "%1'%2 %3"},
        {f = "^wandering (%a+)%'(%a+) (%a+)$", g = "%1'%2 %3"},
    },
    ["hatchling"] = {
        {f = "^(%a+) dragon (egg)$",           g = "%1 %2"},
        {f = "^(%a+) dragon (hatchling)$",     g = "%1 %2"},
        {f = "^(%a+ %a+) dragon whelp$",       g = "%1"},
        {f = "^(%a+) dragon (whelp)$",         g = "%1 %2"},
    },
    ["sirens"]  = {{f = "^miss ([%a']+)%s?(%a*).*%a$",            g = "%1 %2"}},
    ["sohtwo"]  = {
        {f = "^(evil) %a+",  g = "%1"},
        {f = "^(good) %a+",  g = "%1"},
    },
    ["verume"]  = {{f = "^lizardman (temple %a+)$",               g = "%1"}},
    ["wooble"]  = {
        {f = "^sea (%a+)$",       g = "%1"},
        {f = "^sea (%a+ %a+)$",   g = "%1"},
    },
}

-- ─── DATABASE HELPERS ────────────────────────────────────────────────────────

local function db_get_keyword(zone, mob_name)
    local db  = db_open()
    local kw
    local cid = get_current_char_id()

    if cid then
        for row in db:nrows(
            "SELECT keyword FROM mob_keywords " ..
            "WHERE char_id = " .. cid ..
            " AND zone = "     .. fixsql(zone) ..
            " AND mob_name = " .. fixsql(mob_name) ..
            " LIMIT 1"
        ) do kw = row.keyword end
    end

    if kw == nil then
        for row in db:nrows(
            "SELECT keyword FROM mob_keywords " ..
            "WHERE char_id IS NULL " ..
            " AND zone = "     .. fixsql(zone) ..
            " AND mob_name = " .. fixsql(mob_name) ..
            " LIMIT 1"
        ) do kw = row.keyword end
    end

    db_close(db)
    return kw
end

local function db_save_keyword(zone, mob_name, keyword, is_global)
    local cid_sql = is_global and "NULL" or tostring(get_current_char_id() or "NULL")
    local db = db_open()
    local ok, err = pcall(function()
        dbcheck(db, db:exec(
            "INSERT OR REPLACE INTO mob_keywords (char_id, zone, mob_name, keyword) " ..
            "VALUES (" ..
            cid_sql .. ", " .. fixsql(zone) .. ", " ..
            fixsql(mob_name) .. ", " .. fixsql(keyword) .. ")"
        ), "db_save_keyword")
    end)
    db_close(db)
    if not ok then
        ErrorNote("SnD: db_save_keyword failed: " .. tostring(err))
        return false
    end
    return true
end

-- ─── KEYWORD GUESSER INTERNALS ────────────────────────────────────────────────

-- Score a word as a keyword candidate. Higher = better.
-- Proper nouns (originally capitalized, non-first-position) score strongly.
-- Longer words score higher because they give more specific prefixes.
local function _gmkw_score(word, is_proper)
    local n = #word
    if n < 2 then return -100 end           -- too short to be useful
    return n + (is_proper and 20 or 0)
end

-- Truncate a word to at most max_len characters.
local function _gmkw_trunc(word, max_len)
    if #word <= max_len then return word end
    return string.sub(word, 1, max_len)
end

-- ─── PUBLIC: gmkw ─────────────────────────────────────────────────────────────
-- Guess or look up the keyword(s) for mob name `s` in area `a`.
--
-- Resolution order:
--   1. DB lookup  — char-specific row, then global (char_id IS NULL).
--   2. Area filter — area-specific regex transforms (GMKW_AREA_FILTERS).
--   3. Algorithm  — deterministic selection of the 1-2 most distinctive words.
--
-- Algorithm:
--   a. Detect proper nouns before lowercasing (mid-name capitals = proper).
--   b. Clean tokens: lowercase, strip trailing punctuation and possessives.
--   c. Remove stop-words (prepositions, articles, conjunctions).
--   d. Apply area filter if present.
--   e. Re-tokenise the filtered string (area filter may have changed the word set).
--   f. For 1-2 remaining words: use all of them.
--      For 3+ remaining words: score each (proper nouns first, then by length);
--      pick the top-2 highest-scoring, preserving original order.
--   g. Truncate each chosen word to at most 7 characters.
--
-- This is deterministic: the same input always produces the same output.
-- The DB exception system handles mobs where the algorithm produces wrong results.

function gmkw(s, a)
    if not s or s == "" then return "" end
    local zone = a or gmcp("room.info.zone") or ""

    -- 1. DB lookup first.
    local stored = db_get_keyword(zone, s)
    if stored then
        DebugNote("SnD: gmkw: stored override for '" .. s .. "': " .. stored)
        return stored
    end

    -- 2. Detect proper nouns BEFORE lowercasing.
    --    A token is a "proper noun" when it:
    --      (a) Is not the first token (first word may be capitalized grammatically).
    --      (b) Starts with an uppercase letter followed by a lowercase letter.
    --          This rules out ALL-CAPS tokens (abbreviations, not names).
    local raw_words, is_proper = {}, {}
    local n = 0
    for w in string.gmatch(s, "[^ ]+") do
        n = n + 1
        raw_words[n] = w
        is_proper[n] = (n > 1) and (w:match("^%u%l") ~= nil)
    end

    -- 3. Clean tokens.
    local tokens = {}
    for i, w in ipairs(raw_words) do
        w = string.lower(w)
        w = string.gsub(w, "[,%.!%?;:%%]+$",   "")  -- trailing punctuation
        w = string.gsub(w, "^[%(%)%[%]\"\']+", "")  -- leading brackets/quotes
        w = string.gsub(w, "'s$",              "")  -- possessives
        -- Hyphens are kept intact: Aardwolf treats them as significant
        -- characters in keywords (e.g. "yama-uba", "will-o-wisp") the same
        -- way it treats apostrophes, so splitting on '-' can produce a
        -- keyword the game won't match ("yama uba" instead of "yama-uba").
        if #w > 0 then
            tokens[#tokens + 1] = {word = w, proper = is_proper[i]}
        end
    end

    -- 4. Remove stop-words.
    --    Preserve all tokens if every token would be stripped (degenerate names).
    local filtered = {}
    for _, t in ipairs(tokens) do
        if not GMKW_OMIT[t.word] then
            filtered[#filtered + 1] = t
        end
    end
    if #filtered == 0 then filtered = tokens end

    -- 5. Apply area-specific filter on the joined filtered-word string.
    local joined_words = {}
    for _, t in ipairs(filtered) do joined_words[#joined_words + 1] = t.word end
    local s2 = table.concat(joined_words, " ")
    local s3 = s2

    local rules = GMKW_AREA_FILTERS[zone]
    if rules then
        for _, rule in ipairs(rules) do
            local result = string.gsub(s2, rule.f, rule.g)
            if result ~= s2 then s3 = result; break end
        end
    end

    -- 6. Re-tokenise post-filter (area filter may have changed the word set).
    --    Restore proper-noun markers for any token that survives unchanged.
    local final = {}
    for w in string.gmatch(s3, "[^ ]+") do
        local proper = false
        for _, t in ipairs(filtered) do
            if t.word == w then proper = t.proper; break end
        end
        final[#final + 1] = {word = w, proper = proper}
    end
    if #final == 0 then return string.lower(s) end

    -- 7. Select the best 1-2 words by score (preserving original order).
    --    For ties, later tokens are preferred (tend to be more specific in MUD names).
    local chosen
    if #final <= 2 then
        chosen = final
    else
        local i1, i2 = 1, 2
        local s1 = _gmkw_score(final[1].word, final[1].proper)
        local sc2 = _gmkw_score(final[2].word, final[2].proper)
        -- Ensure i1 holds the highest scorer; >= so later words win ties.
        if sc2 >= s1 then i1, i2, s1, sc2 = 2, 1, sc2, s1 end

        for k = 3, #final do
            local sc = _gmkw_score(final[k].word, final[k].proper)
            if sc >= s1 then        -- >= so later words win ties for top slot
                i2, sc2 = i1, s1
                i1, s1  = k, sc
            elseif sc >= sc2 then   -- >= so later words win ties for second slot
                i2, sc2 = k, sc
            end
        end

        -- Re-sort the two chosen indices to preserve original token order.
        local lo, hi = math.min(i1, i2), math.max(i1, i2)
        chosen = {final[lo], final[hi]}
    end

    -- 8. Truncate to at most 7 characters per word.
    --    7 chars gives a specific-enough prefix for MUD prefix-matching while
    --    keeping hunt/kill commands short. The DB exception system handles
    --    cases where a prefix is ambiguous or the game uses a nonsense keyword.
    local parts = {}
    for _, t in ipairs(chosen) do
        parts[#parts + 1] = _gmkw_trunc(t.word, 7)
    end

    return table.concat(parts, " ")
end

-- ─── PUBLIC API ───────────────────────────────────────────────────────────────

function save_mob_keyword(zone, mob_name, keyword, is_global)
    if is_global == nil then is_global = true end
    if db_save_keyword(zone, mob_name, keyword, is_global) then
        InfoNote("SnD: keyword for '" .. mob_name ..
                 "' set to '" .. keyword .. "' in " .. zone)
        update_main_target_list_keyword(zone, mob_name, keyword)
        return true
    end
    return false
end

function update_main_target_list_keyword(zone, mob_name, keyword)
    if type(main_target_list) ~= "table" then return end
    for _, entry in ipairs(main_target_list) do
        if entry.arid == zone and entry.mob == mob_name then
            entry.kw = keyword
        end
    end
end

function set_mob_keyword()
    local current_area = gmcp("room.info.zone") or ""
    local area_list    = {}

    local db = db_open()
    for row in db:nrows("SELECT key FROM areas ORDER BY key ASC") do
        area_list[row.key] = row.key
    end
    db_close(db)

    local area = utils.choose("Area", "Please choose the mob's area.",
                              area_list, current_area)
    if not area then return end

    local function require_input(input) return #Trim(input) > 0 end

    local mob_name = utils.inputbox(
        "Enter the mob's full name.\nFor example: a yummy beef pot pie",
        "Enter mob name", nil, nil, 0, {validate = require_input}
    )
    if not mob_name then return end
    mob_name = Trim(mob_name)

    local keyword = utils.inputbox(
        string.format("Enter the new keyword for '%s'.\nFor example: beef pie", mob_name),
        "Enter new keyword", nil, nil, 0, {validate = require_input}
    )
    if not keyword then return end
    keyword = Trim(keyword)

    save_mob_keyword(area, mob_name, keyword, true)
end

-- Alias handler: 'xset kw <keyword>'.
--
-- The alias used to call set_current_mob_keyword directly, and MUSHclient
-- calls a script function as (name, line, wildcards) -- so `keyword` received
-- the alias's own internal name and the mob was helpfully assigned a keyword
-- of "*alias2533801". A handler that takes the keyword as its only argument
-- cannot be wired to an alias; it needs one in front of it.
function xset_kw(name, line, wildcards)
    local w = (type(wildcards) == "table" and wildcards) or {}
    set_current_mob_keyword(Trim(tostring(w.keyword or w[1] or "")))
end

function set_current_mob_keyword(keyword)
    keyword = Trim(keyword or "")
    if keyword == "" then
        InfoNote("SnD: Usage: kw <keyword>")
        return
    end

    if not (type(current_target) == "table" and current_target.name) then
        -- On a quest, "use xcp first" is a dead end: xcp only handles quest
        -- targets when quest targeting is switched on, and it does not say so.
        if type(has_active_quest) == "function" and has_active_quest() then
            InfoNote("SnD: 'kw' has no current target. On a quest, use 'xqt' " ..
                     "to target the quest mob first (or 'xcp q' to let 'xcp' " ..
                     "do it).")
        else
            InfoNote("SnD: 'kw' has no current target. " ..
                     "Use 'xcp' first, or use 'xset kw' with no arguments.")
        end
        return
    end

    if not current_target.area then
        InfoNote("SnD: Target area is unknown. Visit its area and try again.")
        return
    end

    if save_mob_keyword(current_target.area, current_target.name, keyword, true) then
        if type(update_target_keyword) == "function" then
            update_target_keyword(keyword)
        end
    end
end

-- ─── LISTING ─────────────────────────────────────────────────────────────────

-- Every keyword override that applies to this character: the global ones the
-- upgrade from the old plugin brought across, plus any set for this character
-- alone. A per-character row wins over a global one for the same mob, so both
-- are shown where they differ rather than only the one in force.
--
-- Returns rows { zone, mob_name, keyword, scope, shadows } sorted by zone then
-- mob, and the totals for each scope.
function keyword_list(area_filter)
    local rows, n_global, n_char = {}, 0, 0
    local cid = get_current_char_id()

    local ok = pcall(function()
        local db  = db_open()
        local globals, mine, order = {}, {}, {}
        local where = ""
        if area_filter and area_filter ~= "" then
            where = " AND zone = " .. fixsql(area_filter)
        end

        for row in db:nrows(
            "SELECT zone, mob_name, keyword, char_id FROM mob_keywords " ..
            "WHERE (char_id IS NULL" ..
            (cid and (" OR char_id = " .. cid) or "") .. ")" .. where ..
            " ORDER BY zone, mob_name"
        ) do
            local key = tostring(row.zone) .. "\0" .. tostring(row.mob_name)
            if row.char_id == nil then
                globals[key] = row
                n_global = n_global + 1
            else
                mine[key] = row
                n_char = n_char + 1
            end
            if not order[key] then
                order[key] = true
                rows[#rows + 1] = key
            end
        end
        db_close(db)

        for i, key in ipairs(rows) do
            local mine_row, glob_row = mine[key], globals[key]
            local row = mine_row or glob_row
            rows[i] = {
                zone     = row.zone,
                mob_name = row.mob_name,
                keyword  = row.keyword,
                scope    = mine_row and "char" or "global",
                shadows  = (mine_row and glob_row
                            and glob_row.keyword ~= mine_row.keyword)
                           and glob_row.keyword or nil,
            }
        end
    end)

    if not ok then return nil end
    return rows, n_global, n_char
end

-- Alias handler: 'xset kw list [<area>]'
--
-- Months of keyword corrections carried over from the old plugin, and no way
-- to see whether any of it arrived -- 'xset import' does not cover keywords
-- and never did, so its report of having imported nothing said nothing about
-- them either way. This is that answer.
function xset_kw_list(name, line, wildcards)
    local w    = (type(wildcards) == "table" and wildcards) or {}
    local area = Trim(tostring(w.area or "")):lower()

    local rows, n_global, n_char = keyword_list(area ~= "" and area or nil)
    if not rows then
        ErrorNote("SnD: could not read the keyword table.")
        return
    end

    if #rows == 0 then
        if area ~= "" then
            InfoNote("SnD: no keyword overrides for '", area,
                     "'. Run 'xset kw list' for all areas.")
        else
            InfoNote("SnD: no keyword overrides stored. Keywords set in an " ..
                     "earlier version come across when the database upgrades, " ..
                     "not through 'xset import' -- if you had some and this " ..
                     "is empty, say so and send 'snd debug dump'.")
        end
        return
    end

    InfoNote(string.format("SnD: %d keyword override(s)%s -- %d global, %d for this character.",
        #rows, (area ~= "") and (" in " .. area) or "", n_global, n_char))
    local last_zone = nil
    for _, r in ipairs(rows) do
        if r.zone ~= last_zone then
            InfoNote("SnD: ", tostring(r.zone))
            last_zone = r.zone
        end
        local suffix = ""
        if r.scope == "char" then
            suffix = "   (this character" ..
                     (r.shadows and (", global: " .. r.shadows) or "") .. ")"
        end
        InfoNote("SnD: ", string.format("    %-38s %s%s",
            tostring(r.mob_name), tostring(r.keyword), suffix))
    end
end

