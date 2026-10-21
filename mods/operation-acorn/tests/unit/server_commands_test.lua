-- What the server takes from a client's command: a record answers to the account that made it, and the story's commands
-- take only ids the story has, a building near the character, a choice made at a terminal.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Server"
local OA = OperationAcorn

local function account(name, x, y)
    return { getUsername = function() return name end, getX = function() return x or 0 end,
        getY = function() return y or 0 end }
end

test("a record answers to the account that made it: another account naming its id is refused", function()
    local seen = {}
    OA.Server.on("probe", function(character, record, args) seen[#seen + 1] = record.id end)
    local alice, bob = account("alice"), account("bob")
    local print0 = print
    print = function() end
    sendClientCommand(alice, OA.MOD, "probe", { id = "p1" })
    eq(OA.Store.player("p1").user, "alice")
    sendClientCommand(bob, OA.MOD, "probe", { id = "p1" })
    eq(#seen, 1, "bob names alice's record: nothing runs")
    sendClientCommand(alice, OA.MOD, "probe", { id = "p1" })
    eq(#seen, 2, "alice goes on")
    sendClientCommand(bob, OA.MOD, "probe", { id = "p2" })
    print = print0
    eq(#seen, 3, "bob's own record is made for him")
    eq(OA.Store.player("p2").user, "bob")
    eq(OA.Store.player("p1").user, "alice")
end)

local function story()
    require "OperationAcorn/Story/Init"
    local record = OA.Store.ensure("p1", "P")
    OA.Store.player("p1").user = "P"
    return record
end

test("a document is read only when the story has it, and its place only when it is a facility", function()
    local record = story()
    local P = account("P")
    sendClientCommand(P, OA.MOD, "story_read", { id = "p1", doc = "no_such_paper" })
    eq(OA.Story.section(record).docs["no_such_paper"], nil)
    sendClientCommand(P, OA.MOD, "story_read", { id = "p1", doc = "police_card", variant = "nowhere" })
    eq(OA.Story.section(record).docs["police_card"], true, "read, the unknown place dropped")
    sendClientCommand(P, OA.MOD, "story_read", { id = "p1", doc = "clinic_log", variant = "medical" })
    eq(OA.Story.section(record).docs["clinic_log"], "medical")
end)

test("a building is noted as touched only when it is near the character", function()
    local record = story()
    local P = account("P", 1000, 2000)
    sendClientCommand(P, OA.MOD, "story_touched", { id = "p1", key = "1010,2015" })
    eq(OA.Story.world().touched["1010,2015"], true)
    sendClientCommand(P, OA.MOD, "story_touched", { id = "p1", key = "9000,9000" })
    eq(OA.Story.world().touched["9000,9000"], nil, "a building the character is not at")
    sendClientCommand(P, OA.MOD, "story_touched", { id = "p1", key = "x,y" })
    sendClientCommand(P, OA.MOD, "story_touched", { id = "p1", key = 5 })
end)

test("a mission is started at a terminal, like the other terminal commands", function()
    local record = story()
    local started = 0
    OA.Missions.launch = function() started = started + 1 end
    OA.Trade = { Handlers = { terminalFor = function() return nil, "far" end }, Objects = {} }
    local P = account("P")
    sendClientCommand(P, OA.MOD, "story_launch", { id = "p1" })
    eq(started, 0, "no terminal near: nothing started")
    OA.Trade.Handlers.terminalFor = function() return {} end
    sendClientCommand(P, OA.MOD, "story_launch", { id = "p1" })
    eq(started, 1)
end)
