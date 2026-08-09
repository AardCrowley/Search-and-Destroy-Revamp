-- history.lua
-- Activity history: recording, reward capture, display, and stats.
-- Depends on: constants.lua, util.lua, db.lua, characters.lua
--
-- History rows are per-character (char_id NOT NULL).
-- qp_base  = base QP reward from completing the activity.
-- qp_bonus = daily first-campaign bonus QP (captured from a separate trigger).
-- These are stored separately so average-QP stats are not inflated by the bonus.

-- ─── TIMING STATE ────────────────────────────────────────────────────────────
-- Tracks per-activity-type start times (for live elapsed display) and last
-- completion timestamps (for "Last: Xm Ys" display in the status bar).
-- Populated from the DB on load; kept in sync by history_start/history_end.

local _activity_start = {}   -- [htype] = Unix start_time of in-progress activity
local _last_complete  = {}   -- [htype] = Unix end_time of most recent COMPLETE row
local _last_duration  = {}   -- [htype] = duration in seconds of most recent COMPLETE row

-- CP auto-fail threshold: Aardwolf cancels campaigns that are 7 days old.
local CP_TIMEOUT_SECS = 7 * 24 * 3600   -- 604800

-- ─── PENDING REWARD STATE ─────────────────────────────────────────────────────
-- Accumulated between trigger fires and consumed by history_end().

local _cp_qp_base    = 0
local _cp_qp_bonus   = 0
local _cp_tp         = 0
local _cp_trains     = 0
local _cp_pracs      = 0
local _cp_gold       = 0

local _quest_qp      = 0
local _quest_gold    = 0
local _quest_pracs   = 0
local _quest_trains  = 0
local _quest_tp      = 0

-- GQ reward accumulators: populated by reward triggers when _gq_reward_mode is
-- true (set by gq_reward_mode_on() inside gqmsg_winner when winner == you).
local _gq_qp         = 0
local _gq_tp         = 0
local _gq_trains     = 0
local _gq_pracs      = 0
local _gq_gold       = 0
local _gq_reward_mode = false

local function reset_cp_rewards()
    _cp_qp_base  = 0
    _cp_qp_bonus = 0
    _cp_tp       = 0
    _cp_trains   = 0
    _cp_pracs    = 0
    _cp_gold     = 0
end

local function reset_quest_rewards()
    _quest_qp     = 0
    _quest_gold   = 0
    _quest_pracs  = 0
    _quest_trains = 0
    _quest_tp     = 0
end

local function reset_gq_rewards()
    _gq_qp          = 0
    _gq_tp          = 0
    _gq_trains      = 0
    _gq_pracs       = 0
    _gq_gold        = 0
    _gq_reward_mode = false
end

-- Called by gqmsg_winner (XML) before the reward text arrives.
-- Routes subsequent reward trigger fires into GQ accumulators.
function gq_reward_mode_on()
    reset_gq_rewards()
    _gq_reward_mode = true
end

-- ─── HELPERS ──────────────────────────────────────────────────────────────────

local function type_to_string(t)
    if t == HISTORY_TYPE_QUEST    then return "quest"
    elseif t == HISTORY_TYPE_GQ   then return "gquest"
    elseif t == HISTORY_TYPE_CP   then return "campaign"
    end
    return "unknown"
end

local function status_to_string(s)
    if s == HISTORY_STATUS_IN_PROGRESS then return "in progress"
    elseif s == HISTORY_STATUS_COMPLETE then return "complete"
    elseif s == HISTORY_STATUS_TIMEOUT  then return "timeout"
    elseif s == HISTORY_STATUS_FAILED   then return "failed"
    elseif s == HISTORY_STATUS_RESET    then return "reset"
    elseif s == HISTORY_STATUS_SKIPPED  then return "skipped"
    end
    return "unknown"
end

-- ─── CORE RECORD OPS ─────────────────────────────────────────────────────────

-- Open a new in-progress history row for the current character.
-- Cancels any existing in-progress row of the same type first so that
-- duplicate calls (e.g. replaying `gq info`) do not create orphaned rows.
function history_start(history_type)
    history_type = tonumber(history_type)
    local char_id = get_current_char_id()
    if not char_id then
        DebugNote("SnD: history_start: no char_id yet, skipping")
        return
    end

    -- Before starting a new CP, check if the previous one timed out.
    if history_type == HISTORY_TYPE_CP then
        history_check_cp_timeout()
    end

    local level = tonumber(gmcp("char.status.level")) or 0
    local now   = os.time()

    local db = db_open()
    local ok, err = pcall(function()
        -- Cancel any previous in-progress row so re-runs don't orphan rows.
        dbcheck(db, db:exec(
            "UPDATE history SET status = " .. HISTORY_STATUS_RESET ..
            " WHERE char_id = " .. char_id ..
            " AND type = "      .. history_type ..
            " AND status = "    .. HISTORY_STATUS_IN_PROGRESS
        ), "history_start: cancel prior in-progress")

        dbcheck(db, db:exec(
            "INSERT INTO history (char_id, type, level_taken, start_time, status) VALUES (" ..
            char_id .. ", " ..
            history_type .. ", " ..
            level .. ", " ..
            tostring(now) .. ", " ..
            HISTORY_STATUS_IN_PROGRESS .. ")"
        ), "history_start")
    end)
    db_close(db)

    if ok then
        _activity_start[history_type] = now
    else
        ErrorNote("SnD: history_start failed: " .. tostring(err))
    end
end

-- Close the most recent in-progress row of history_type with the given status
-- and reward values.
function history_end(history_type, status)
    history_type = tonumber(history_type)
    status       = tonumber(status)
    local char_id = get_current_char_id()
    if not char_id then return end

    local qp_base, qp_bonus, tp, trains, pracs, gold

    if history_type == HISTORY_TYPE_CP then
        qp_base  = _cp_qp_base
        qp_bonus = _cp_qp_bonus
        tp       = _cp_tp
        trains   = _cp_trains
        pracs    = _cp_pracs
        gold     = _cp_gold
        reset_cp_rewards()
    elseif history_type == HISTORY_TYPE_QUEST then
        qp_base  = _quest_qp
        qp_bonus = 0
        tp       = _quest_tp
        trains   = _quest_trains
        pracs    = _quest_pracs
        gold     = _quest_gold
        reset_quest_rewards()
    elseif history_type == HISTORY_TYPE_GQ then
        qp_base  = _gq_qp
        qp_bonus = 0
        tp       = _gq_tp
        trains   = _gq_trains
        pracs    = _gq_pracs
        gold     = _gq_gold
        reset_gq_rewards()
    else
        qp_base  = 0
        qp_bonus = 0
        tp       = 0
        trains   = 0
        pracs    = 0
        gold     = 0
    end

    local end_time       = os.time()
    local db             = db_open()
    local row_start_time = nil
    local ok, err = pcall(function()
        -- Find the most recent in-progress row for this type + character.
        local id = nil
        for row in db:nrows(
            "SELECT id, start_time FROM history " ..
            "WHERE char_id = " .. char_id ..
            " AND type = " .. history_type ..
            " AND status = " .. HISTORY_STATUS_IN_PROGRESS ..
            " ORDER BY start_time DESC LIMIT 1"
        ) do
            id             = row.id
            row_start_time = tonumber(row.start_time)
        end

        if not id then
            -- No in-progress row: history_start() never ran for this activity,
            -- which is what happens when the plugin is installed or reloaded
            -- part way through one.
            if status ~= HISTORY_STATUS_COMPLETE then
                DebugNote("SnD: history_end: no in-progress row found for type " .. history_type)
                return
            end
            -- It completed and there are rewards to account for, so record it
            -- rather than dropping it. The start time is genuinely unknown, so
            -- use the end time and let the duration read as zero instead of
            -- inventing one.
            dbcheck(db, db:exec(
                "INSERT INTO history (char_id, type, level_taken, start_time, " ..
                "end_time, status, qp_base, qp_bonus, tp_rewards, train_rewards, " ..
                "prac_rewards, gold_rewards) VALUES (" ..
                char_id       .. ", " ..
                history_type  .. ", " ..
                (tonumber(gmcp("char.status.level")) or 0) .. ", " ..
                end_time      .. ", " ..
                end_time      .. ", " ..
                status        .. ", " ..
                qp_base       .. ", " ..
                qp_bonus      .. ", " ..
                tp            .. ", " ..
                trains        .. ", " ..
                pracs         .. ", " ..
                gold          .. ")"
            ), "history_end: record completion with no start row")
            InfoNote("SnD: Recorded a completed " .. type_to_string(history_type) ..
                     " that was already under way when S&D loaded (duration unknown).")
            return
        end

        dbcheck(db, db:exec(
            "UPDATE history SET " ..
            "end_time = "   .. end_time .. ", " ..
            "status = "     .. status    .. ", " ..
            "qp_base = "    .. qp_base   .. ", " ..
            "qp_bonus = "   .. qp_bonus  .. ", " ..
            "tp_rewards = " .. tp        .. ", " ..
            "train_rewards = " .. trains .. ", " ..
            "prac_rewards = "  .. pracs  .. ", " ..
            "gold_rewards = "  .. gold   ..
            " WHERE id = " .. id
        ), "history_end update")
    end)
    db_close(db)

    -- Update in-memory timing state.
    _activity_start[history_type] = nil
    if status == HISTORY_STATUS_COMPLETE then
        _last_complete[history_type] = end_time
        if row_start_time then
            _last_duration[history_type] = end_time - row_start_time
        end
    end

    if not ok then
        ErrorNote("SnD: history_end failed: " .. tostring(err))
    end
    -- Bust the quickstats cache so the window shows fresh totals next draw.
    if type(history_quickstats_invalidate) == "function" then
        history_quickstats_invalidate()
    end
    -- Notify the window to display the reward summary when activity completes.
    if ok and status == HISTORY_STATUS_COMPLETE
    and type(xg_show_reward) == "function" then
        local activity = (history_type == HISTORY_TYPE_CP)    and "cp"
                      or (history_type == HISTORY_TYPE_GQ)    and "gq"
                      or (history_type == HISTORY_TYPE_QUEST)  and "quest"
                      or nil
        if activity then
            xg_show_reward(activity, {
                qp            = qp_base,
                qp_bonus      = qp_bonus,
                tp            = tp,
                trains        = trains,
                pracs         = pracs,
                gold          = gold,
                duration_secs = row_start_time and (end_time - row_start_time) or 0,
            })
        end
    end
end

-- Convenience wrapper: capture quest rewards then close the quest row.
function history_quest_end(status, qp, gold, pracs, trains, tp)
    if tonumber(status) == HISTORY_STATUS_COMPLETE then
        _quest_qp     = tonumber(qp)     or 0
        _quest_gold   = tonumber(gold)   or 0
        _quest_pracs  = tonumber(pracs)  or 0
        _quest_trains = tonumber(trains) or 0
        _quest_tp     = tonumber(tp)     or 0
    end
    history_end(HISTORY_TYPE_QUEST, status)
end

-- ─── REWARD TRIGGERS ─────────────────────────────────────────────────────────
-- Called from XML trigger handlers; accumulate values for history_end().

-- GQ win and CP complete show the same reward output format.  When
-- _gq_reward_mode is true these functions route into the GQ accumulators so
-- both sets of rewards are tracked independently even if you are on a CP and
-- a GQ simultaneously.

function trigger_campaign_rewards_qp(name, line, wildcards, style)
    if _gq_reward_mode then
        _gq_qp = tonumber(wildcards.qp) or 0
    else
        _cp_qp_base = tonumber(wildcards.qp) or 0
        snd_set_setting("cp_info_qp_reward", tostring(_cp_qp_base), false)
    end
end

function trigger_campaign_rewards_bonus_qp(name, line, wildcards, style)
    -- Bonus QP only applies to CP completion; ignore in GQ reward mode.
    if not _gq_reward_mode then
        _cp_qp_bonus = _cp_qp_bonus + (tonumber(wildcards.qp) or 0)
        snd_set_setting("cp_info_qp_reward",
            tostring(_cp_qp_base + _cp_qp_bonus), false)
    end
end

function trigger_campaign_rewards_gold(name, line, wildcards, style)
    if _gq_reward_mode then
        _gq_gold = tonumber(wildcards.gold) or 0
    else
        _cp_gold = tonumber(wildcards.gold) or 0
        snd_set_setting("cp_info_gold_reward", tostring(_cp_gold), false)
    end
end

function trigger_campaign_rewards_trains(name, line, wildcards, style)
    if _gq_reward_mode then
        _gq_trains = tonumber(wildcards.train) or 0
    else
        _cp_trains = tonumber(wildcards.train) or 0
        snd_set_setting("cp_info_train_reward", tostring(_cp_trains), false)
    end
end

function trigger_campaign_rewards_practices(name, line, wildcards, style)
    if _gq_reward_mode then
        _gq_pracs = tonumber(wildcards.prac) or 0
    else
        _cp_pracs = tonumber(wildcards.prac) or 0
        snd_set_setting("cp_info_practices_reward", tostring(_cp_pracs), false)
    end
end

function trigger_campaign_rewards_tps(name, line, wildcards, style)
    if _gq_reward_mode then
        _gq_tp = tonumber(wildcards.tp) or 0
    else
        _cp_tp = tonumber(wildcards.tp) or 0
        snd_set_setting("cp_info_tp_reward", tostring(_cp_tp), false)
    end
end

function trigger_quest_premonition(name, line, wildcards, style)
    -- GMCP fires before this text line: history_start() for the real quest has
    -- already reset the premonition row to RESET status and created a new
    -- in-progress row for the real quest.  Calling history_end(SKIPPED) here
    -- would incorrectly mark the real quest as skipped.  No action needed --
    -- history_start() cleanup is sufficient.
end

-- ─── DISPLAY ─────────────────────────────────────────────────────────────────

-- Print the last 20 history rows, optionally filtered by type.
-- history_type: HISTORY_TYPE_* constant or nil for all.
function history_print(history_type)
    local char_id = get_current_char_id()
    if not char_id then
        InfoNote("SnD: character not identified yet.")
        return
    end

    local where = "WHERE h.char_id = " .. char_id
    if history_type then
        where = where .. " AND h.type = " .. tostring(history_type)
    end

    local db  = db_open()
    local rows = {}
    for r in db:nrows(
        "SELECT h.type, h.level_taken, h.start_time, h.end_time, h.status, " ..
        "h.qp_base, h.qp_bonus, h.tp_rewards, h.train_rewards, " ..
        "h.prac_rewards, h.gold_rewards " ..
        "FROM history h " ..
        where ..
        " ORDER BY h.start_time DESC LIMIT 20"
    ) do
        local duration = (r.end_time and r.start_time)
            and (r.end_time - r.start_time) or 0

        local rewards = ""
        local total_qp = (r.qp_base or 0) + (r.qp_bonus or 0)
        if total_qp     > 0 then rewards = rewards .. total_qp      .. "qp " end
        if (r.tp_rewards    or 0) > 0 then rewards = rewards .. r.tp_rewards    .. "tp " end
        if (r.train_rewards or 0) > 0 then rewards = rewards .. r.train_rewards .. "tr " end
        if (r.prac_rewards  or 0) > 0 then rewards = rewards .. r.prac_rewards  .. "pr " end
        rewards = Trim(rewards)

        rows[#rows + 1] = {
            type        = type_to_string(r.type),
            level_taken = r.level_taken,
            started     = os.date("%Y-%m-%d %H:%M", r.start_time),
            duration    = duration,
            status      = status_to_string(r.status),
            rewards     = rewards,
        }
    end
    db_close(db)

    if #rows == 0 then
        InfoNote("SnD: No history to show.")
        return
    end

    local header = "| Type     | Level | Started          |    Duration | Status      | Rewards          |"
    local sep    = string.rep("-", #header)
    ColourNote("#E0E0E0", "", sep)
    ColourNote("#E0E0E0", "", header)
    ColourNote("#E0E0E0", "", sep)

    for i, v in ipairs(rows) do
        local dur_str = (v.status == "reset" or v.status == "skipped")
            and "N/A" or format_duration(v.duration)
        local bg   = (i % 2 == 0) and "#000040" or ""
        local line = string.format(
            "| %-8s | %5d | %-16s | %11s | %-11s | %-16s |",
            v.type, v.level_taken, v.started, dur_str, v.status, v.rewards
        )
        ColourNote("#E0E0E0", bg, line)
    end
    ColourNote("#E0E0E0", "", sep)
end

-- Alias handler: 'snd history [quest|gquest|campaign]'
function alias_print_history(name, line, wildcards)
    local map = {
        q = HISTORY_TYPE_QUEST,  quest = HISTORY_TYPE_QUEST,
        gq = HISTORY_TYPE_GQ,    gquest = HISTORY_TYPE_GQ,
        cp = HISTORY_TYPE_CP,    campaign = HISTORY_TYPE_CP,
    }
    local arg = wildcards.hist_type
    arg = (arg and arg ~= "") and arg:gsub(" ", ""):lower() or nil
    history_print(arg and map[arg] or nil)
end

-- ─── TIMING PUBLIC API ───────────────────────────────────────────────────────

-- Seconds elapsed since the current in-progress activity of htype started,
-- or nil if no activity is in progress.  Works correctly after offline periods
-- because start_time is the original wall-clock timestamp.
function history_elapsed(htype)
    local st = _activity_start[tonumber(htype)]
    return st and (os.time() - st) or nil
end

-- Unix timestamp of the most recent COMPLETE row for htype, or nil.
function history_last_end(htype)
    return _last_complete[tonumber(htype)]
end

-- Duration in seconds of the most recent COMPLETE row for htype, or nil.
function history_last_duration(htype)
    return _last_duration[tonumber(htype)]
end

-- Mark any in-progress CP older than CP_TIMEOUT_SECS as FAILED.
-- Called on plugin load and before starting a new CP.
function history_check_cp_timeout()
    local char_id = get_current_char_id()
    if not char_id then return end
    local cutoff = os.time() - CP_TIMEOUT_SECS
    local db = db_open()
    pcall(function()
        db:exec(
            "UPDATE history SET status = " .. HISTORY_STATUS_FAILED ..
            " WHERE char_id = " .. char_id ..
            " AND type = "      .. HISTORY_TYPE_CP ..
            " AND status = "    .. HISTORY_STATUS_IN_PROGRESS ..
            " AND start_time <= " .. cutoff
        )
        if db:changes() > 0 then
            _activity_start[HISTORY_TYPE_CP] = nil
            InfoNote("SnD: In-progress campaign exceeded 7 days and was marked failed.")
        end
    end)
    db_close(db)
end

-- Populate _activity_start and _last_complete from the DB on plugin load.
-- Must be called after the character is identified (get_current_char_id non-nil).
function history_init_timing()
    local char_id = get_current_char_id()
    if not char_id then return end

    -- First expire any timed-out CPs.
    history_check_cp_timeout()

    local db = db_open()
    pcall(function()
        -- Latest completion timestamp and duration per type.
        for row in db:nrows(
            "SELECT type, end_time, (end_time - start_time) AS dur FROM history " ..
            "WHERE char_id = " .. char_id ..
            " AND status = "   .. HISTORY_STATUS_COMPLETE ..
            " AND end_time IS NOT NULL" ..
            " AND end_time = (" ..
            "  SELECT MAX(h2.end_time) FROM history h2" ..
            "  WHERE h2.char_id = history.char_id AND h2.type = history.type" ..
            "  AND h2.status = " .. HISTORY_STATUS_COMPLETE .. " AND h2.end_time IS NOT NULL" ..
            " ) GROUP BY type"
        ) do
            local t = row.type
            _last_complete[t] = tonumber(row.end_time)
            if row.dur then _last_duration[t] = tonumber(row.dur) end
        end

        -- In-progress start times (one per type; latest wins).
        for row in db:nrows(
            "SELECT type, start_time FROM history " ..
            "WHERE char_id = " .. char_id ..
            " AND status = "   .. HISTORY_STATUS_IN_PROGRESS ..
            " GROUP BY type HAVING start_time = MAX(start_time)"
        ) do
            _activity_start[row.type] = tonumber(row.start_time)
        end
    end)
    db_close(db)
end

-- Return a lightweight summary for the window status bar.
-- Returns {total, avg_secs, min_secs} or nil when no data / DB unavailable.
-- Results are cached for STATS_CACHE_TTL seconds to avoid per-draw DB hits.
local _stats_cache     = {}
local STATS_CACHE_TTL  = 30

function history_quickstats(history_type)
    history_type = tonumber(history_type)
    if not history_type then return nil end

    local now   = os.time()
    local entry = _stats_cache[history_type]
    if entry and (now - entry.ts) < STATS_CACHE_TTL then
        return entry.data
    end

    local char_id = get_current_char_id()
    if not char_id then return nil end

    local result = nil
    local db = db_open()
    local ok = pcall(function()
        for r in db:nrows(
            "SELECT COUNT(*) AS total, " ..
            "ROUND(AVG(end_time - start_time)) AS avg_dur, " ..
            "MIN(end_time - start_time) AS min_dur " ..
            "FROM history WHERE char_id = " .. char_id ..
            " AND type = "   .. history_type ..
            " AND status = " .. HISTORY_STATUS_COMPLETE
        ) do
            result = r
        end
    end)
    db_close(db)

    local data = nil
    if ok and result and (result.total or 0) > 0 then
        data = {
            total    = result.total   or 0,
            avg_secs = result.avg_dur or 0,
            min_secs = result.min_dur or 0,
        }
    end
    _stats_cache[history_type] = { ts = now, data = data }
    return data
end

-- Invalidate the quickstats cache (call after history_end to ensure fresh data).
function history_quickstats_invalidate()
    _stats_cache = {}
end

-- ─── TIME RANGE PARSER ───────────────────────────────────────────────────────
-- Returns { since=ts, until_ts=ts_or_nil, label=string } or nil for all-time.
-- period   : "day" | "week" | "month" | "year"  (nil → all-time)
-- modifier : "last" | a number string | nil
local function parse_stats_range(period, modifier)
    if not period or period == "" then return nil end

    local now  = os.time()
    local t    = os.date("*t", now)
    local since, until_ts, label

    if period == "day" then
        local n = tonumber(modifier)
        if modifier == "last" then
            local today = os.time({year=t.year, month=t.month, day=t.day,   hour=0, min=0, sec=0})
            since    = today - 86400
            until_ts = today
            label    = "Yesterday"
        elseif n then
            since    = now - n * 86400
            until_ts = nil
            label    = "Last " .. n .. " day" .. (n == 1 and "" or "s")
        else
            since    = os.time({year=t.year, month=t.month, day=t.day, hour=0, min=0, sec=0})
            until_ts = nil
            label    = "Today"
        end

    elseif period == "week" then
        -- wday: 1=Sun … 7=Sat
        local days_back  = t.wday - 1
        local this_sun   = os.time({year=t.year, month=t.month, day=t.day - days_back,
                                    hour=0, min=0, sec=0})
        if modifier == "last" then
            since    = this_sun - 7 * 86400
            until_ts = this_sun
            label    = "Last week"
        else
            since    = this_sun
            until_ts = nil
            label    = "This week"
        end

    elseif period == "month" then
        local n = tonumber(modifier)
        if modifier == "last" then
            local pm = t.month - 1
            local py = t.year
            if pm < 1 then pm = 12; py = py - 1 end
            since    = os.time({year=py,    month=pm,      day=1, hour=0, min=0, sec=0})
            until_ts = os.time({year=t.year, month=t.month, day=1, hour=0, min=0, sec=0})
            label    = os.date("%B %Y", since)
        elseif n then
            -- Go back exactly n months from today; os.time normalizes month overflow
            local bt = os.date("*t", now)
            bt.month = bt.month - n
            since    = os.time(bt)
            until_ts = nil
            label    = "Last " .. n .. " month" .. (n == 1 and "" or "s")
        else
            since    = os.time({year=t.year, month=t.month, day=1, hour=0, min=0, sec=0})
            until_ts = nil
            label    = os.date("%B %Y")
        end

    elseif period == "year" then
        if modifier == "last" then
            since    = os.time({year=t.year-1, month=1, day=1, hour=0, min=0, sec=0})
            until_ts = os.time({year=t.year,   month=1, day=1, hour=0, min=0, sec=0})
            label    = tostring(t.year - 1)
        else
            since    = os.time({year=t.year, month=1, day=1, hour=0, min=0, sec=0})
            until_ts = nil
            label    = tostring(t.year)
        end

    else
        return nil   -- unrecognized period → all-time
    end

    return { since = since, until_ts = until_ts, label = label }
end

-- ─── STATS BY LEVEL ──────────────────────────────────────────────────────────

-- Print per-level duration statistics for history_type (completed rows only).
function history_stats(history_type, range)
    history_type = tonumber(history_type)
    local char_id = get_current_char_id()
    if not char_id then
        InfoNote("SnD: character not identified yet.")
        return
    end

    -- Build optional time-window clause
    local time_clause = ""
    if range then
        time_clause = " AND start_time >= " .. range.since .. " "
        if range.until_ts then
            time_clause = time_clause .. " AND start_time < " .. range.until_ts .. " "
        end
    end

    local db   = db_open()
    local rows = {}
    for r in db:nrows(
        "SELECT level_taken, " ..
        "MIN(end_time - start_time) AS min_dur, " ..
        "ROUND(AVG(end_time - start_time)) AS avg_dur, " ..
        "MAX(end_time - start_time) AS max_dur, " ..
        "COUNT(*) AS total, " ..
        "SUM(qp_base + qp_bonus) AS total_qp " ..
        "FROM history " ..
        "WHERE char_id = " .. char_id ..
        " AND type = " .. history_type ..
        " AND status = " .. HISTORY_STATUS_COMPLETE ..
        time_clause ..
        " GROUP BY level_taken " ..
        "ORDER BY level_taken"
    ) do
        rows[#rows + 1] = r
    end
    db_close(db)

    if #rows == 0 then
        InfoNote("SnD: No stats to show.")
        return
    end

    local type_name = (history_type == HISTORY_TYPE_QUEST)  and "Quest"
                   or (history_type == HISTORY_TYPE_CP)     and "Campaign"
                   or (history_type == HISTORY_TYPE_GQ)     and "Global Quest"
                   or "Activity"
    local period_label = range and range.label or "All time"

    local header = "| Level | Min Duration | Avg Duration | Max Duration | Count | Total QP |"
    local sep    = string.rep("-", #header)
    ColourNote("#E0E0E0", "", sep)
    ColourNote(NOTE_COLORS.INFO_HIGHLIGHT, "", string.format(
        " %s Stats  [%s]", type_name, period_label))
    ColourNote("#E0E0E0", "", header)
    ColourNote("#E0E0E0", "", sep)

    for i, v in ipairs(rows) do
        local bg   = (i % 2 == 0) and "#000040" or ""
        local line = string.format(
            "| %5d | %12s | %12s | %12s | %5d | %8d |",
            v.level_taken,
            format_duration(v.min_dur),
            format_duration(v.avg_dur),
            format_duration(v.max_dur),
            v.total,
            v.total_qp or 0
        )
        ColourNote("#E0E0E0", bg, line)
    end
    ColourNote("#E0E0E0", "", sep)
end

-- Print a rolling 14-day daily summary across all characters.
function history_stats_over_time(range)
    -- Default to last 14 days when no range given
    local time_clause
    local period_label
    if range then
        time_clause  = " AND end_time >= " .. range.since .. " "
        if range.until_ts then
            time_clause = time_clause .. " AND end_time < " .. range.until_ts .. " "
        end
        period_label = range.label
    else
        time_clause  = " AND end_time >= STRFTIME('%s', DATE('now', '-14 day')) "
        period_label = "Last 14 days"
    end

    local db   = db_open()
    local rows = {}
    for r in db:nrows(
        "SELECT " ..
        "DATE(end_time, 'unixepoch', 'localtime') AS day, " ..
        "COUNT(CASE WHEN type = " .. HISTORY_TYPE_QUEST .. " THEN 1 END) AS quests, " ..
        "COUNT(CASE WHEN type = " .. HISTORY_TYPE_CP    .. " THEN 1 END) AS campaigns, " ..
        "COUNT(CASE WHEN type = " .. HISTORY_TYPE_GQ    .. " THEN 1 END) AS gquests, " ..
        "SUM(qp_base + qp_bonus) AS total_qp, " ..
        "SUM(tp_rewards)         AS total_tp, " ..
        "SUM(train_rewards)      AS total_tr, " ..
        "SUM(prac_rewards)       AS total_pr, " ..
        "SUM(gold_rewards)       AS total_gold " ..
        "FROM history " ..
        "WHERE status = " .. HISTORY_STATUS_COMPLETE ..
        time_clause ..
        "GROUP BY day " ..
        "ORDER BY day DESC"
    ) do
        rows[#rows + 1] = r
    end
    db_close(db)

    if #rows == 0 then
        InfoNote("SnD: No stats to show.")
        return
    end

    local header = "| Day        | Quests | Campaigns | GQuests |   QP |  TP |  TR |  PR |    Gold |"
    local sep    = string.rep("-", #header)
    ColourNote("#E0E0E0", "", sep)
    ColourNote(NOTE_COLORS.INFO_HIGHLIGHT, "", string.format(
        " Activity Over Time  [%s]", period_label))
    ColourNote("#E0E0E0", "", header)
    ColourNote("#E0E0E0", "", sep)

    for i, v in ipairs(rows) do
        local bg   = (i % 2 == 0) and "#000040" or ""
        local line = string.format(
            "| %10s | %6d | %9d | %7d | %4d | %3d | %3d | %3d | %7d |",
            v.day, v.quests, v.campaigns, v.gquests or 0,
            v.total_qp or 0, v.total_tp or 0,
            v.total_tr or 0, v.total_pr or 0,
            v.total_gold or 0
        )
        ColourNote("#E0E0E0", bg, line)
    end
    ColourNote("#E0E0E0", "", sep)
end

-- Alias handler: 'snd stats quest|campaign|gquest|overtime|areas [period [N|last]]'
function alias_print_stats(name, line, wildcards)
    local arg1 = Trim(wildcards.arg1 or ""):lower()
    local arg2 = Trim(wildcards.arg2 or ""):lower()
    local arg3 = Trim(wildcards.arg3 or ""):lower()

    if arg1 == "overtime" then
        local range = parse_stats_range(arg2 ~= "" and arg2 or nil,
                                        arg3 ~= "" and arg3 or nil)
        history_stats_over_time(range)
        return
    elseif arg1 == "areas" then
        history_stats_areas()
        return
    end

    local history_type
    if     arg1 == "quest"    then history_type = HISTORY_TYPE_QUEST
    elseif arg1 == "campaign" then history_type = HISTORY_TYPE_CP
    elseif arg1 == "gquest"   then history_type = HISTORY_TYPE_GQ
    else
        ErrorNote("SnD: Usage: snd stats <quest|campaign|gquest|overtime|areas> [day|week|month|year [N|last]]")
        return
    end

    local range = parse_stats_range(arg2 ~= "" and arg2 or nil,
                                    arg3 ~= "" and arg3 or nil)
    history_stats(history_type, range)
end

-- ─── SESSION SUMMARY ─────────────────────────────────────────────────────────

-- Print a summary of activity since the plugin loaded (snd_session_start).
function session_summary()
    local char_id = get_current_char_id()
    if not char_id then
        InfoNote("SnD: Character not identified yet.")
        return
    end

    local start_time = snd_session_start or 0

    local db  = db_open()
    local row = nil
    for r in db:nrows(
        "SELECT " ..
        "COUNT(CASE WHEN type=" .. HISTORY_TYPE_QUEST ..
            " AND status=" .. HISTORY_STATUS_COMPLETE .. " THEN 1 END) AS quests, " ..
        "COUNT(CASE WHEN type=" .. HISTORY_TYPE_CP ..
            " AND status=" .. HISTORY_STATUS_COMPLETE .. " THEN 1 END) AS campaigns, " ..
        "COUNT(CASE WHEN type=" .. HISTORY_TYPE_GQ ..
            " AND status=" .. HISTORY_STATUS_COMPLETE .. " THEN 1 END) AS gquests_won, " ..
        "COUNT(CASE WHEN type=" .. HISTORY_TYPE_GQ .. " THEN 1 END) AS gquests_total, " ..
        "SUM(CASE WHEN status=" .. HISTORY_STATUS_COMPLETE ..
            " THEN qp_base+qp_bonus ELSE 0 END) AS total_qp, " ..
        "SUM(CASE WHEN status=" .. HISTORY_STATUS_COMPLETE ..
            " THEN tp_rewards ELSE 0 END) AS total_tp, " ..
        "SUM(CASE WHEN status=" .. HISTORY_STATUS_COMPLETE ..
            " THEN train_rewards ELSE 0 END) AS total_tr, " ..
        "SUM(CASE WHEN status=" .. HISTORY_STATUS_COMPLETE ..
            " THEN prac_rewards ELSE 0 END) AS total_pr, " ..
        "SUM(CASE WHEN status=" .. HISTORY_STATUS_COMPLETE ..
            " THEN gold_rewards ELSE 0 END) AS total_gold " ..
        "FROM history " ..
        "WHERE char_id=" .. char_id ..
        " AND start_time >= " .. start_time
    ) do
        row = r
    end
    db_close(db)

    local none = not row or
        ((row.quests or 0) == 0 and (row.campaigns or 0) == 0 and (row.gquests_total or 0) == 0)
    if none then
        InfoNote("SnD: No activity recorded this session.")
        return
    end

    local dur = os.time() - start_time
    local sep = string.rep("-", 52)
    ColourNote("#E0E0E0", "", sep)
    ColourNote(NOTE_COLORS.INFO_HIGHLIGHT, "", " Search & Destroy — Session Summary")
    ColourNote("#E0E0E0", "", sep)
    ColourNote("#E0E0E0", "", string.format(" Session time  : %s",  format_duration(dur)))
    ColourNote("#E0E0E0", "", string.format(" Campaigns     : %d",  row.campaigns    or 0))
    ColourNote("#E0E0E0", "", string.format(" Quests        : %d",  row.quests       or 0))
    ColourNote("#E0E0E0", "", string.format(" Global Quests : %d won / %d entered",
        row.gquests_won or 0, row.gquests_total or 0))
    ColourNote("#E0E0E0", "", sep)
    ColourNote("#E0E0E0", "", string.format(" Quest Points  : %d",  row.total_qp  or 0))
    ColourNote("#E0E0E0", "", string.format(" Trivia Points : %d",  row.total_tp  or 0))
    ColourNote("#E0E0E0", "", string.format(" Trains        : %d",  row.total_tr  or 0))
    ColourNote("#E0E0E0", "", string.format(" Practices     : %d",  row.total_pr  or 0))
    ColourNote("#E0E0E0", "", string.format(" Gold          : %d",  row.total_gold or 0))
    ColourNote("#E0E0E0", "", sep)
end

function alias_session_summary(name, line, wildcards)
    session_summary()
end

-- ─── AREA KILL HEATMAP ────────────────────────────────────────────────────────

-- Print the top 30 areas by accumulated kill count (global across all chars).
function history_stats_areas()
    local db   = db_open()
    local rows = {}
    for r in db:nrows(
        "SELECT zone, SUM(kill_count) AS kills, COUNT(*) AS mobs " ..
        "FROM mob_kills " ..
        "GROUP BY zone " ..
        "ORDER BY kills DESC " ..
        "LIMIT 30"
    ) do
        rows[#rows + 1] = r
    end
    db_close(db)

    if #rows == 0 then
        InfoNote("SnD: No area kill data to show yet.")
        return
    end

    local header = "| Area                     | Total Kills | Distinct Mobs |"
    local sep    = string.rep("-", #header)
    ColourNote("#E0E0E0", "", sep)
    ColourNote(NOTE_COLORS.INFO_HIGHLIGHT, "", " Most-visited areas by kill count (all characters)")
    ColourNote("#E0E0E0", "", sep)
    ColourNote("#E0E0E0", "", header)
    ColourNote("#E0E0E0", "", sep)

    for i, v in ipairs(rows) do
        local bg   = (i % 2 == 0) and "#000040" or ""
        local line = string.format(
            "| %-24s | %11d | %13d |",
            ellipsify(tostring(v.zone), 24),
            v.kills or 0,
            v.mobs  or 0
        )
        ColourNote("#E0E0E0", bg, line)
    end
    ColourNote("#E0E0E0", "", sep)
end

-- ─── CP DIFFICULTY PREDICTION ─────────────────────────────────────────────────

-- Print an estimated duration for the current campaign based on history,
-- if enough data exists (minimum 3 completed CPs at this level).
-- Called from cp_check_end in targets.lua after the target list is built.
function print_cp_prediction()
    local char_id = get_current_char_id()
    if not char_id then return end

    -- cp_info_level is a NUMBER initialised to 0, and 0 is truthy in Lua, so
    -- `tonumber(cp_info_level) or <fallback>` never reaches the fallback --
    -- it returns 0 and the guard below then silently skipped the prediction
    -- in exactly the case the fallback existed for. Test the value, not nil.
    local level = tonumber(cp_info_level) or 0
    if level <= 0 then
        level = tonumber(gmcp("char.status.level")) or 0
    end
    if level <= 0 then return end

    local db  = db_open()
    local row = nil
    for r in db:nrows(
        "SELECT COUNT(*) AS n, " ..
        "ROUND(AVG(end_time - start_time)) AS avg_dur, " ..
        "MIN(end_time - start_time) AS min_dur, " ..
        "MAX(end_time - start_time) AS max_dur " ..
        "FROM history " ..
        "WHERE char_id = " .. char_id ..
        " AND type = "     .. HISTORY_TYPE_CP ..
        " AND status = "   .. HISTORY_STATUS_COMPLETE ..
        " AND level_taken = " .. level
    ) do
        row = r
    end
    db_close(db)

    if not row or (row.n or 0) < 3 then return end

    InfoNote(string.format(
        "SnD: Level %d CP history — Avg: %s  Best: %s  Worst: %s  (%d CPs)",
        level,
        format_duration(row.avg_dur or 0),
        format_duration(row.min_dur or 0),
        format_duration(row.max_dur or 0),
        row.n
    ))
end
