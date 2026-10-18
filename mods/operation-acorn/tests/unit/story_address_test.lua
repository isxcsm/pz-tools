-- How the team names the collection point (Story.address, designation, grade): the full name at the first stage,
-- the bare number while Branscomb keeps the line, the grade 관리 7 gives after the handover, stamped as it changes.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Story"
local OA = OperationAcorn
local Story = OA.Story

local n = 0
local function record(stage, milestones)
    n = n + 1
    local r = OA.Store.ensure("addr" .. n, "A")
    r.number = 347
    r.trade = r.trade or {}
    r.trade.stage, r.trade.milestones = stage, milestones or 0
    return r
end

test("Branscomb names the point in full at the first stage, then by its number", function()
    local r = record(1)
    eq(Story.grade(r), nil)
    eq(Story.address(r), "IGUI_OA_Story_Grade_none 0347")
    r.trade.stage = 3
    eq(Story.address(r), "0347")
    eq(Story.designation(r), "IGUI_OA_Story_Grade_none 0347", "the terminal keeps the full name")
end)

test("after the handover the grade climbs with the levels and the calls use it", function()
    local r = record(5, 3)
    Story.section(r).handover = true
    eq(Story.grade(r), "handed")
    eq(Story.address(r), "IGUI_OA_Story_Grade_handed 0347")
    r.trade.milestones = 5
    eq(Story.grade(r), "regular")
    r.trade.milestones = 6
    eq(Story.grade(r), "designated")
    r.trade.milestones = 7
    eq(Story.grade(r), "priority")
    local late = record(2)
    Story.section(late).joined = { tier = 9, handover = true }
    eq(Story.grade(late), "new", "a character that came after the handover starts as a new point")
end)

test("a new grade is stamped once; the first comes unstamped", function()
    local titles = {}
    OA.Sync.title = function(_, spec) titles[#titles + 1] = spec end
    local r = record(5, 3)
    Story.section(r).handover = true
    Story.onStage(r)
    local stamped = 0
    for _, t in ipairs(titles) do if t.key == "IGUI_OA_Title_Grade" then stamped = stamped + 1 end end
    eq(stamped, 0, "the handover's grade is not stamped")
    r.trade.milestones = 5
    Story.onStage(r)
    Story.onStage(r)
    local last
    stamped = 0
    for _, t in ipairs(titles) do
        if t.key == "IGUI_OA_Title_Grade" then stamped = stamped + 1; last = t end
    end
    eq(stamped, 1)
    eq(last.sub, "IGUI_OA_Story_Grade_regular")
    eq(last.style, "stamp")
end)

test("past priority come special and top; past the top every level is a designation again, counted and stamped", function()
    local titles = {}
    OA.Sync.title = function(_, spec) titles[#titles + 1] = spec end
    local r = record(5, 7)
    Story.section(r).handover = true
    Story.onStage(r)
    r.trade.milestones = 9
    eq(Story.grade(r), "special")
    r.trade.milestones = 11
    eq(Story.grade(r), "top")
    Story.onStage(r)
    eq(Story.redesignations(r), 0)
    eq(Story.designation(r, true), "IGUI_OA_Story_Grade_top 0347", "no count at the top grade itself")
    r.trade.milestones = 13
    eq(Story.redesignations(r), 2)
    eq(Story.address(r), "IGUI_OA_Story_Grade_top 0347", "the calls never say the count")
    eq(Story.designation(r, true), "IGUI_OA_Story_GradeAgain IGUI_OA_Story_Grade_top 0347 2")
    Story.onStage(r)
    Story.onStage(r)
    local again = {}
    for _, t in ipairs(titles) do if t.key == "IGUI_OA_Title_GradeAgain" then again[#again + 1] = t end end
    eq(#again, 1, "stamped once for the count reached")
    eq(again[1].subArgs[2], 2)
end)
