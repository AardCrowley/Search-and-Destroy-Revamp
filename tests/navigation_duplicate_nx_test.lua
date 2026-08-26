local navigation_path = assert(arg[1],
    "usage: lua navigation_duplicate_nx_test.lua <navigation.lua>")

local room = "100"
local executed = {}
local debug_notes = {}

local env = setmetatable({}, {__index = _G})
env.Execute = function(command)
    executed[#executed + 1] = command
end
env.gmcp = function(path)
    if path == "room.info.num" then return room end
    return nil
end
env.InfoNote = function() end
env.is_vidblain_area = function() return false end
env.DebugNote = function(message)
    debug_notes[#debug_notes + 1] = message
end

local chunk
if setfenv then
    chunk = assert(loadfile(navigation_path))
    setfenv(chunk, env)
else
    chunk = assert(loadfile(navigation_path, "t", env))
end
chunk()

env.current_character_state = "3"
env.current_target = nil
env.main_target_list = {}

local function reset_route(destination)
    executed = {}
    debug_notes = {}
    env.gotoList = {destination}
    env.gotoIndex = 1
    env.next_room = destination
end

-- Reproduce the live race: XCP has just sent mapper goto, then queued nx runs
-- before the character state changes from ready to running.
reset_route("500")
env.do_mapper_goto("500")
env.goto_next("goto_next", "nx", {})
assert(#executed == 1, "immediate nx resent the same mapper route")
assert(#debug_notes == 1, "suppressed nx did not leave a debug trace")

-- A deliberate go command remains available to retry a stopped or failed
-- route; only nx/nx- are prevented from resending their active destination.
env.goto_number("goto_number", "go 1", {index="1"})
assert(#executed == 2, "explicit go retry was incorrectly blocked")
assert(executed[2] == "mapper goto 500")

-- A different room ID is a real cycle even when it has the same display name.
-- It must proceed immediately while the original route is still in flight.
room = "100"
executed = {}
debug_notes = {}
env.gotoList = {"600", "500"}
env.gotoIndex = 1
env.next_room = "500"
env.do_mapper_goto("500")
env.goto_next("goto_next", "nx", {})
assert(#executed == 2, "nx did not cycle to a different room ID")
assert(executed[2] == "mapper goto 600")
assert(#debug_notes == 0, "different room ID was treated as a duplicate")

-- Arriving at the current room and advancing to a different room is always
-- legitimate.
room = "500"
executed = {}
debug_notes = {}
env.gotoList = {"500", "600"}
env.gotoIndex = 1
env.next_room = "500"
env.do_mapper_goto("500")
env.goto_next("goto_next", "nx", {})
assert(#executed == 2, "nx did not advance to a different destination")
assert(executed[2] == "mapper goto 600")

-- nx- has the same resend shape and should receive the same protection.
room = "100"
reset_route("700")
env.do_mapper_goto("700")
env.goto_previous("goto_previous", "nx-", {})
assert(#executed == 1, "immediate nx- resent the same mapper route")
assert(#debug_notes == 1, "suppressed nx- did not leave a debug trace")

print("SnD duplicate nx route regression checks passed")
