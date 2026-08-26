local hunting_path = arg[1]
assert(hunting_path, "usage: lua hunting_input_cancel_test.lua <hunting.lua>")

local captures = {}
local sent = {}
local found_room

function EnableTrigger() end
function EnableTriggerGroup() end
function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function split(s)
    local out = {}
    for word in s:gmatch("%S+") do out[#out+1] = word end
    return out
end
function ErrorNote() end
function InfoNote() end
function DebugNote() end
function Send(s) sent[#sent+1] = s end
function SendNoEcho(s) sent[#sent+1] = s end
function has_target() return true end
function has_activity_target() return true end
function snd_target_keyword() return current_target.keyword end
function snd_target_label() return current_target.name end
function mob_has_tag() return false end
function lookup_not_found_mob() return {} end
function gmcp(path) if path == "room.info.zone" then return "test-zone" end end
function set_target_from_quest() end
function set_target_from_main_target_list() end
function search_rooms_exact(room) found_room = room end

Capture = {}
function Capture.untagged_output(command, no_echo, omit, no_prompt, callback, via_execute, timeout)
    captures[#captures+1] = {
        command=command,
        callback=callback,
        timeout=timeout
    }
end

current_target = {
    name="the target mob",
    keyword="target",
    area="test-zone"
}
quest_target = {qstat="0"}
main_target_list = {}

assert(loadfile(hunting_path))()

local function line(text)
    return {{text=text, textcolour=0, backcolour=0}}
end

local function where_line(mob, room)
    return line(string.format("%-30s %s", mob, room))
end

-- A later exact match in one multi-line response must win without a retry.
qw.exact = true
qw.match = current_target.name
do_quick_where(1, current_target.keyword)
assert(#captures == 1 and captures[1].command == "where target")
captures[1].callback({
    where_line("a different target", "Wrong Room"),
    where_line("the target mob", "Right Room")
})
assert(#captures == 1)
assert(found_room == "Right Room")
assert(not qw.active)

-- A complete nonmatching response produces exactly one numbered retry.
found_room = nil
qw.exact = true
qw.match = current_target.name
do_quick_where(1, current_target.keyword)
captures[#captures].callback({
    where_line("a different target", "Wrong Room")
})
local numbered = captures[#captures]
assert(numbered.command == "where 2.target")
numbered.callback({where_line("the target mob", "Numbered Room")})
assert(found_room == "Numbered Room")

-- Old callbacks and timeouts must not disturb a newer search.
found_room = nil
qw.exact = true
qw.match = current_target.name
do_quick_where(1, current_target.keyword)
local old_capture = captures[#captures]
do_quick_where(1, current_target.keyword)
local new_capture = captures[#captures]
old_capture.callback({where_line("the target mob", "Old Room")})
old_capture.timeout()
assert(qw.active and found_room == nil)
new_capture.callback({where_line("the target mob", "New Room")})
assert(found_room == "New Room" and not qw.active)

-- Normal failure responses end only SnD's local search state.
qw.exact = true
qw.match = current_target.name
do_quick_where(1, current_target.keyword)
captures[#captures].callback({line("There is no target around here.")})
assert(not qw.active)

qw.exact = true
qw.match = current_target.name
do_quick_where(1, current_target.keyword)
captures[#captures].callback({
    line("There are too many doors and fences to see who is in this area.")
})
assert(not qw.active)

-- Hunt Trick can hand off a numbered target without issuing global STOP.
ht = {index=4, first_target=false, active=true}
ht_complete()
assert(captures[#captures].command == "where 4.target")

-- Late Hunt Trick responses must not restart a completed search.
local capture_count = #captures
local sent_count = #sent
ht_continue()
ht_complete()
ht_fail()
ht_abort()
assert(#captures == capture_count, "stale Hunt Trick response restarted QuickWhere")
assert(#sent == sent_count, "stale Hunt Trick response sent another command")

-- A live capture timeout clears only SnD's local search state.
captures[#captures].timeout()
assert(not qw.active)

for _, command in ipairs(sent) do
    assert(command ~= "stop", "hotfix sent Aardwolf's global stop")
end

print("SnD input-cancellation regression checks passed")
