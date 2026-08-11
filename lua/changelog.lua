-- changelog.lua
-- Version-aware changelog display.
--
-- changelog.md is divided into version sections by level-1 headings ("# v6.0").
-- Everything below a heading, until the next one, belongs to that version, and
-- sections appear newest-first in the file.  Level 1 is used deliberately: the
-- document's own structure starts at level 2, so version headings can be added
-- without renumbering a line of existing content.
--
-- This module parses that file, decides which sections a given user has not
-- seen, and renders the markdown to the output window.
--
-- Depends on: util.lua (InfoNote/ErrorNote/DebugNote), constants.lua
--             (NOTE_COLORS), and download_file + snd_get/set_setting from the
--             XML script block.

local COL = 76      -- content width, matching the help system

-- The running version, as a string.
--
-- snd_version() lives in the plugin preamble and is the authority: MUSHclient
-- stores the plugin's `version` attribute as a number, so PLUGIN_VERSION comes
-- back as 6 for "6.0.1". The fallback keeps this module loadable on its own,
-- which is how it is tested.
local function running_version()
    if type(snd_version) == "function" then return snd_version() end
    return tostring(PLUGIN_VERSION or "?")
end

-- ─── VERSION COMPARISON ──────────────────────────────────────────────────────

-- Parse "6.1" or "v6.1" into { 6, 1 }.  Returns nil for anything that is not a
-- dotted number -- "alpha-8", "", a hand-edited setting.  Callers must treat
-- nil as "cannot tell" rather than "oldest": the previous implementation ran
-- tonumber() on these and compared nil with nil, which raises outright.
function cl_version_parse(s)
    if type(s) ~= "string" then
        if s == nil then return nil end
        s = tostring(s)
    end
    local body = s:match("^%s*[Vv]?([%d%.]+)%s*$")
    if not body then return nil end
    local parts = {}
    for n in body:gmatch("(%d+)") do parts[#parts + 1] = tonumber(n) end
    if #parts == 0 then return nil end
    return parts
end

-- Componentwise compare of two parsed versions; missing components are 0, so
-- 6.1 and 6.1.0 are equal and 6.1 is newer than 6.0.9.
function cl_version_compare(a, b)
    local n = math.max(#a, #b)
    for i = 1, n do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return (x < y) and -1 or 1 end
    end
    return 0
end

-- true / false when both versions parse, nil when either does not.
function cl_version_newer(a, b)
    local pa, pb = cl_version_parse(a), cl_version_parse(b)
    if not pa or not pb then return nil end
    return cl_version_compare(pa, pb) > 0
end

-- ─── PARSING ─────────────────────────────────────────────────────────────────

-- Split raw changelog markdown into version sections, in file order.
-- Anything before the first version heading is discarded.
function cl_split_sections(text)
    local sections, cur, in_fence = {}, nil, false
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*```") then in_fence = not in_fence end
        -- A heading only counts outside a fenced block: code samples in this
        -- changelog contain MUD output, and a '#' there is not a heading.
        local version = (not in_fence) and line:match("^#%s+[Vv]?([%d][%w%.%-]*)%s*$")
        if version then
            cur = { version = version, lines = {} }
            sections[#sections + 1] = cur
        elseif cur then
            cur.lines[#cur.lines + 1] = line
        end
    end
    return sections
end

-- Which sections a user on `since` has not seen yet.
-- Returns the list plus a status:
--   "ok"      -- there are newer sections
--   "current" -- the user is up to date
--   "unknown" -- `since` is unparseable, so only the newest section is shown
--                rather than replaying the entire history at someone
function cl_sections_since(sections, since)
    if not cl_version_parse(since) then
        return (sections[1] and { sections[1] }) or {}, "unknown"
    end
    local out = {}
    for _, s in ipairs(sections) do
        if cl_version_newer(s.version, since) then out[#out + 1] = s end
    end
    return out, (#out == 0) and "current" or "ok"
end

-- ─── RENDERING ───────────────────────────────────────────────────────────────

-- Markdown emphasis has no inline equivalent in a MUD output window, so the
-- markers are removed and color carries the emphasis instead.  Links keep
-- their text and drop the URL.
local function strip_inline(s)
    s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
    s = s:gsub("%*%*", "")
    -- Single-asterisk italics, after the bold markers are gone so the two
    -- cannot be confused. Requires a matched pair around non-space text, which
    -- leaves a stray '*' in a code sample alone.
    s = s:gsub("%*([^%*%s][^%*]-)%*", "%1")
    s = s:gsub("`", "")
    return (s:gsub("%s+$", ""))
end

-- Greedy wrap. Unlike helpWrap this returns a table and accepts a narrower
-- budget for the first line, so text can continue after a colored lead-in
-- without the first line running past the column.
local function wrap_lines(text, width, first_width)
    first_width = first_width or width
    if width < 20 then width = 20 end
    if first_width < 10 then first_width = 10 end
    local lines, cur, budget = {}, "", first_width
    for word in text:gmatch("%S+") do
        if cur == "" then
            cur = word
        elseif #cur + 1 + #word <= budget then
            cur = cur .. " " .. word
        else
            lines[#lines + 1] = cur
            cur, budget = word, width
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

local function blank() ColourNote("", "", "") end

-- ─── BLOCK ASSEMBLY ──────────────────────────────────────────────────────────
--
-- Markdown wraps prose across several source lines, and a bullet's
-- continuation lines are simply indented under it.  Rendering line by line
-- therefore re-wraps each source line on its own and leaves a ragged edge with
-- stray one-word lines.  Lines are gathered into blocks first, so a bullet and
-- its continuations wrap together as the single paragraph they are.

local function is_boundary(line)
    return line:match("^%s*$")                    -- blank
        or line:match("^#+%s")                    -- heading
        or line:match("^%s*|")                    -- table row
        or line:match("^%s*```")                  -- fence
        or line:match("^%s*%-%-%-+%s*$")          -- rule
        or line:match("^%s*[%-%*]%s")             -- new bullet
        or line:match("^%s*%d+%.%s")              -- new numbered item
end

-- Turn a section's raw lines into blocks ready to render.
local function to_blocks(lines)
    local blocks, cur = {}, nil
    local in_fence, fence = false, nil

    local function flush()
        if cur then blocks[#blocks + 1] = cur end
        cur = nil
    end

    for _, line in ipairs(lines) do
        if line:match("^%s*```") then
            if in_fence then
                blocks[#blocks + 1] = fence
                fence, in_fence = nil, false
            else
                flush()
                fence = { kind = "code", lines = {},
                          lead = #(line:match("^(%s*)")) }
                in_fence = true
            end
        elseif in_fence then
            fence.lines[#fence.lines + 1] = line

        elseif line:match("^%s*$") then
            flush()
            blocks[#blocks + 1] = { kind = "blank" }

        elseif line:match("^%s*%-%-%-+%s*$") then
            flush()
            blocks[#blocks + 1] = { kind = "rule" }

        elseif line:match("^#+%s") then
            flush()
            local hashes, text = line:match("^(#+)%s+(.*)$")
            blocks[#blocks + 1] = { kind = "head", level = #hashes, text = text }

        elseif line:match("^%s*|") then
            if not (cur and cur.kind == "table") then
                flush()
                cur = { kind = "table", lines = {},
                        lead = #(line:match("^(%s*)")) }
            end
            cur.lines[#cur.lines + 1] = (line:gsub("^%s+", ""))

        else
            local lead, marker, rest =
                line:match("^(%s*)([%-%*])%s+(.*)$")
            if not rest then
                local l2, num, r2 = line:match("^(%s*)(%d+%.)%s+(.*)$")
                lead, marker, rest = l2, num, r2
            end
            if rest then
                flush()
                cur = {
                    kind   = "bullet",
                    depth  = math.floor(#lead / 2),
                    marker = (#marker > 1) and marker or "-",
                    text   = rest,
                }
            elseif cur and (cur.kind == "bullet" or cur.kind == "para") then
                -- Lazy continuation of the block above.
                cur.text = cur.text .. " " .. (line:gsub("^%s+", ""))
            else
                flush()
                cur = { kind = "para", text = (line:gsub("^%s+", "")),
                        lead = #(line:match("^(%s*)")) }
            end
        end
    end
    if in_fence and fence then blocks[#blocks + 1] = fence end
    flush()
    return blocks
end

-- ─── BLOCK RENDERING ─────────────────────────────────────────────────────────

-- A bullet very often opens with a bolded feature name; coloring that lead-in
-- is what makes a long changelog skimmable.
local function split_lead(text)
    local title, tail = text:match("^%*%*(.-)%*%*(.*)$")
    if not title then return "", strip_inline(text) end
    local head = strip_inline(title)
    local body = strip_inline((tail:gsub("^%s+", "")))
    -- The space between the two is re-added here: wrapping works on words, so
    -- a leading space on the tail would otherwise be lost and the lead-in
    -- would run straight into the text after it.
    if head ~= "" and body ~= "" then head = head .. " " end
    return head, body
end

-- Emit one run of prose: `prefix` opens the first line, `hang` indents the
-- rest, and a bolded lead-in is colored.  When that lead-in is long enough
-- that little of the first line is left, the body starts on the next line
-- instead of being crammed past the column.
local function emit_text(prefix, hang, text)
    local head, body = split_lead(text)
    local budget = COL - #prefix - #head
    if head ~= "" and budget < 24 then
        -- The lead-in itself has to wrap here: some entries are bolded end to
        -- end, so an unwrapped head is the whole line and runs well past the
        -- column.
        local hl = wrap_lines(head, COL - #hang, COL - #prefix)
        ColourTell(NOTE_COLORS.INFO, "", prefix)
        ColourNote(NOTE_COLORS.INFO_HIGHLIGHT, "", hl[1] or "")
        for i = 2, #hl do
            ColourNote(NOTE_COLORS.INFO_HIGHLIGHT, "", hang .. hl[i])
        end
        for _, l in ipairs(wrap_lines(body, COL - #hang)) do
            ColourNote(NOTE_COLORS.INFO, "", hang .. l)
        end
        return
    end
    local lines = wrap_lines(body, COL - #hang, budget)
    ColourTell(NOTE_COLORS.INFO, "", prefix)
    if head ~= "" then ColourTell(NOTE_COLORS.INFO_HIGHLIGHT, "", head) end
    ColourNote(NOTE_COLORS.INFO, "", lines[1] or "")
    for i = 2, #lines do
        ColourNote(NOTE_COLORS.INFO, "", hang .. lines[i])
    end
end

local function render_block(b)
    if b.kind == "blank" then
        blank()

    elseif b.kind == "rule" then
        ColourNote(NOTE_COLORS.INFO, "", string.rep("-", COL))

    elseif b.kind == "head" then
        local indent = (b.level >= 3) and "  " or ""
        ColourNote(NOTE_COLORS.INFO_HIGHLIGHT, "", indent .. strip_inline(b.text))

    elseif b.kind == "code" then
        local pad = string.rep(" ", 4 + (b.lead or 0))
        for _, l in ipairs(b.lines) do
            ColourNote(NOTE_COLORS.DEBUG, "", pad .. l)
        end

    elseif b.kind == "table" then
        -- Passed through untouched: re-wrapping destroys the column alignment
        -- that makes a table readable in the first place.
        local pad = string.rep(" ", 3 + (b.lead or 0))
        for _, l in ipairs(b.lines) do
            ColourNote(NOTE_COLORS.DEBUG, "", pad .. l)
        end

    elseif b.kind == "bullet" then
        local prefix = string.rep("  ", b.depth + 1) .. b.marker .. " "
        emit_text(prefix, string.rep(" ", #prefix), b.text)

    else   -- para
        -- A paragraph indented in the source is a bullet's continuation; the
        -- indent is what says which bullet it belongs to, so it is preserved
        -- rather than flattened back to the margin.
        local pad = string.rep(" ", 2 + (b.lead or 0))
        emit_text(pad, pad, b.text)
    end
end

function cl_render_sections(sections)
    for _, sec in ipairs(sections) do
        local head = string.format(" Version %s ", sec.version)
        blank()
        ColourTell(NOTE_COLORS.INFO, "", "===")
        ColourTell(NOTE_COLORS.INFO_HIGHLIGHT, "", head)
        ColourNote(NOTE_COLORS.INFO, "", string.rep("=", math.max(3, COL - #head - 3)))
        for _, block in ipairs(to_blocks(sec.lines)) do
            render_block(block)
        end
    end
end

-- ─── COMMANDS ────────────────────────────────────────────────────────────────

-- Set by cl_show, read by cl_receive: download_file takes no user data, so the
-- request parameters have to survive on the side.
local pending = nil

-- Records that the user has now seen everything up to the running version.
-- Only ever called after a successful render, so a failed fetch leaves the
-- setting alone and the notice reappears on the next load.
local function stamp_seen()
    last_installed_version = running_version()
    snd_set_setting("last_installed_version", running_version(), true)
end

function cl_receive(retval, page, status, headers, full_status, request_url)
    local req = pending or { mode = "new" }
    pending = nil

    if status ~= 200 or not page or page == "" then
        DebugNote("cl_receive got status ", tostring(status))
        if not req.quiet then
            ErrorNote("SnD: Could not fetch the changelog (status ",
                      tostring(status), ").")
        end
        return
    end

    local sections = cl_split_sections(page)
    if #sections == 0 then
        if not req.quiet then
            ErrorNote("SnD: The changelog has no version sections to show.")
        end
        return
    end

    if req.mode == "all" then
        cl_render_sections(sections)
        stamp_seen()
        return
    end

    local since = req.since or last_installed_version
    local show, status_word = cl_sections_since(sections, since)

    if status_word == "current" then
        -- Nothing to show. On an automatic check that is the normal case and
        -- should stay silent; when the user asked, silence looks like a bug.
        if not req.quiet then
            InfoNote("SnD: You are up to date (v", running_version(),
                     ") -- nothing new since v", tostring(since), ".")
        end
        stamp_seen()
        return
    end

    if status_word == "unknown" and not req.quiet then
        InfoNote("SnD: No record of which version you were on, so this is ",
                 "just the newest release. Use 'snd changelog all' for the ",
                 "full history.")
    end

    cl_render_sections(show)
    blank()
    InfoNote("SnD: 'snd changelog all' shows every version; ",
             "'snd changelog since <version>' shows a specific range.")
    stamp_seen()
end

-- mode: "new" (since the user's version), "all", or "since" with req_version.
function cl_show(mode, req_version, quiet)
    pending = {
        mode  = mode or "new",
        since = req_version,
        quiet = quiet and true or false,
    }
    if mode == "since" and not cl_version_parse(req_version) then
        pending = nil
        ErrorNote("SnD: '", tostring(req_version),
                  "' is not a version number. Try: snd changelog since 6.0")
        return
    end
    DebugNote("Fetching changelog (mode ", tostring(mode), ")")
    download_file(CHANGELOG_URL, cl_receive)
end

-- Called during startup. Shows what changed only when the running version
-- differs from the one last seen, and says nothing at all otherwise -- including
-- when the download fails, since an unreachable server is not the user's
-- problem to read about on every load.
function cl_check_new_version()
    local seen = last_installed_version
    if seen and tostring(seen) == running_version() then return end

    if not seen or seen == "" or not cl_version_parse(seen) then
        -- No usable record of what came before. Two situations land here and
        -- they cannot be told apart: a first-time install, and an upgrade from
        -- a release that never recorded its version. The latter is the common
        -- one -- before 6.0 the setting was only written if the user happened
        -- to run 'snd changelog' by hand, so most people upgrading arrive with
        -- nothing stored.
        --
        -- Printing the release notes would be a wall of text either way (v6.0
        -- alone is the better part of a thousand lines), and printing nothing
        -- loses the one moment the feature exists for. So this points at the
        -- command rather than running it.
        InfoNote("SnD: Welcome to v", running_version(),
                 " -- run 'snd changelog all' to see what is in it.")
        stamp_seen()
        return
    end
    cl_show("new", nil, true)
end
