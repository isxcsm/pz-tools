-- What fires the team's calls (Story: the first contact, a settlement, a serum, the tiers, a story mission's box, a
-- crate, a paper, the handover) and the comms tab's command that keeps one as played.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Story"
local OA = OperationAcorn
local Story, Comms = OA.Story, OA.Comms

local function setup(id, stage, milestones)
    local record = OA.Store.ensure(id, "P")
    record.number = 347
    record.trade = { stage = stage or 0, milestones = milestones or 0, credits = 0, trust = 0 }
    OA.Trade = { addToDrop = function() end }
    return record
end

local function changes()
    local list = {}
    OA.Sync.listen("comms", function(playerId) list[#list + 1] = playerId end)
    return list
end

test("the first contact fires the first call, the late one keeps its lines; the quiet one fires none", function()
    local told = changes()
    local record = setup("w1")
    truthy(Story.firstContact(record, true))
    truthy(Comms.section(record).fired.S0)
    truthy(Story.lateContact(record))
    eq(told[#told], "w1")
    local quiet = setup("w2", 1)
    Story.firstContact(quiet, false, true)
    eq(Comms.section(quiet).fired.S0, nil)
    eq(Story.lateContact(quiet), false)
end)

test("the tiers entered fire their calls and drop the ones of the tiers passed", function()
    local record = setup("w3")
    Story.firstContact(record, false)
    record.trade.stage = 1
    Story.onStage(record)
    eq(Comms.section(record).tier, 1)
    record.trade.stage = 3
    Story.onStage(record)
    eq(Comms.section(record).tier, 3)
    truthy(Comms.section(record).fired.S3)
    truthy(Comms.section(record).dropped.S1, "the first settlement's scene never came")
    truthy(Comms.section(record).dropped.S2)
    eq(Comms.section(record).dropped.S0, nil, "it came")
    record.trade.milestones = 1
    Story.onStage(record)
    eq(Comms.section(record).tier, 4, "a milestone counts as a tier")
end)

test("a settlement, a serum, a story mission's box, a crate at its tier and a paper sent each fire theirs", function()
    local record = setup("w4", 1)
    Story.onSettled(record, { lines = {} })
    truthy(Comms.section(record).fired.S1, "S1")
    Story.onInjected(record)
    truthy(Comms.section(record).fired.S2, "S2")
    Story.missionEnded(record, { story = "evidence" }, "done")
    truthy(Comms.section(record).fired.S1F, "S1F")
    local other = setup("w5", 1)
    Story.missionEnded(other, { story = "evidence" }, "expired")
    eq(Comms.section(other).fired.S1F, nil, "not when it was missed")
    local s = Story.section(record)
    s.papers = { { type = "Paper", doc = "reply_first" } }
    Story.takePaper(record)
    truthy(Comms.section(record).fired.s2_correction, "s2_correction")
    record.trade.stage, record.trade.milestones = 5, 1
    Story.onStage(record)
    Story.crateSpecs(record)
    truthy(Comms.section(record).fired.S6, "S6")
    eq(Comms.section(record).fired.S7, nil)
end)

test("the handover mission's call comes however it ended; the scene after the handover once its last crate is opened", function()
    local record = setup("w6", 5, 3)
    Story.section(record).seenStage, Story.section(record).seenMilestones = 5, 3
    Story.missionEnded(record, { story = "handover" }, "expired")
    truthy(Comms.section(record).fired.S8)
    eq(Comms.section(record).fired.S9, nil)
    Story.onOpened(record, { { type = "OperationAcorn.HandoverFile", count = 1 } })
    truthy(Comms.section(record).fired.S9)
    truthy(Story.handedOver(record))
end)

test("the first crate of tier 7 brings S7's named torch, once", function()
    local record = setup("w8", 5, 2)
    Story.onStage(record)
    local specs = Story.crateSpecs(record)
    truthy(Comms.section(record).fired.S7, "S7")
    eq(specs[1].type, "Base.HandTorch")
    eq(specs[1].name, "IGUI_OA_Story_Item_QuarlesTorch")
    for _, spec in ipairs(Story.crateSpecs(record) or {}) do
        eq(spec.name == nil or spec.name ~= "IGUI_OA_Story_Item_QuarlesTorch", true, "not with the next crate")
    end
end)

test("the half day after the test serum's scene brings the next", function()
    local record = setup("w7", 1)
    Comms.fire(record, "first", 0)
    Comms.played(record, "S0", 0, 0)
    Story.onInjected(record)
    Comms.played(record, "S2", 1, 10)
    OA.hours = function() return 15 end
    Story.callsDue(record)
    eq(Comms.section(record).fired.S2B, nil)
    OA.hours = function() return 23 end
    Story.callsDue(record)
    truthy(Comms.section(record).fired.S2B)
end)

test("a story monologue is said once and kept; the after-handover ones run out", function()
    local said, delays = {}, {}
    OA.Sync.listen("storySay", function(playerId, detail)
        said[#said + 1] = detail.key
        delays[#delays + 1] = detail.delay or 0
    end)
    local record = setup("w8", 1)
    eq(Story.monologue(record, "evidence", "pickup"), "S1F_pickup")
    eq(said[#said], "IGUI_OA_Comms_S1F_pickup")
    eq(delays[#delays], 0, "at once")
    eq(Story.monologue(record, "evidence", "pickup"), nil, "once")
    eq(Story.monologue(record, "evidence", "nothing"), nil)
    for _, item in ipairs(Comms.section(record).log) do truthy(item.id ~= "S1F_pickup", "not in the comms record") end
    eq(Story.monologue(record, "evidence", "enter", 5) ~= nil, true)
    eq(delays[#delays], 5, "after the wait it is given")
    local after = setup("w9", 5, 4)
    local ids = {}
    for _ = 1, 4 do ids[#ids + 1] = Story.afterMonologue(after) or "-" end
    eq(table.concat(ids, " "), "A1 A2 A3 -")
end)
