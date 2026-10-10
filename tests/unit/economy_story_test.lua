-- The economy's seams with the story part: the refusal title and lines, the meteorite receipt notes, and the strange
-- request after a hallucination. The story part is faked.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Requests"
local OA = OperationAcorn

local function info(fullType, display, weight, extra)
    local t = { fullType = fullType, baseType = OA.Categories.baseType(fullType), weight = weight or 1,
        displayCategory = display or "Junk" }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

local function fakeStory(extra)
    OA.Story = {
        refusalKey = function(category, phase) return "STORY_" .. category .. "_" .. phase end,
        BIG_METEORITE_RECEIPT = "STORY_BIG_RECEIPT", FRAGMENT_RECEIPT = "STORY_FRAGMENT_RECEIPT",
    }
    for k, v in pairs(extra or {}) do OA.Story[k] = v end
end

local function boot()
    require "OperationAcorn/Economy"
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
end

local function make(count)
    local data = { version = 1, types = {}, score = {}, kinds = {}, total = {}, n = count }
    for i = 1, count do
        data.types[i] = "Base.Item" .. i
        data.score[i] = 2.0
        data.kinds["Item" .. i] = (i % 2 == 0) and "A" or "B"
    end
    OA.Requests.install(data)
end

-- 1. The refusal lines.

test("a refusal sends a title to every record", function()
    fakeStory()
    boot()
    OA.Economy.start()
    OA.Store.ensure("a", "A")
    OA.Store.ensure("b", "B")
    OA.Store.player("a").trade = { stage = 1 }
    local st = OA.Market.state()
    st.nextRefusal = 0
    local titles, notices = {}, {}
    OA.Sync.listen("title", function(id, detail) titles[#titles + 1] = { id = id, detail = detail } end)
    OA.Sync.listen("notice", function(id, detail) notices[#notices + 1] = { id = id, detail = detail } end)
    OA.Market.update(OA.day() + 1)
    eq(#titles, 2, "a title for each record")
    eq(#notices, 0, "and nothing else is sent")
    eq(titles[1].detail.key, "IGUI_OA_Title_Refusal")
    eq(titles[1].detail.sub, "IGUI_OA_Title_RefusalSub")
    eq(titles[1].detail.style, "notice")
    local cat = titles[1].detail.subArgs[1].key
    truthy(string.find(cat, "^IGUI_"), "the category, translated on the player's side")
    eq(titles[2].detail.subArgs[1].key, cat)
    eq(titles[1].detail.subArgs[2], 7)
    truthy(titles[1].id ~= titles[2].id)
end)

test("refusalLine gives the story key for either phase", function()
    fakeStory()
    local key = OA.Market.refusalLine("A", "start")
    eq(key, "STORY_A_start")
    eq((OA.Market.refusalLine("F", "back")), "STORY_F_back")
    OA.Story = nil
    local fallback, args = OA.Market.refusalLine("A", "back")
    eq(fallback, "IGUI_OA_Econ_Radio_RefuseBack")
    eq(#args, 1)
end)

-- 2. The meteorites.

test("a refused big meteorite carries the story receipt note and a mark", function()
    fakeStory()
    local rock = info("Base.LargeMeteorite", "Memento", 5)
    local ok, why = OA.Value.accepts(rock)
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Meteor")
    local line = OA.Value.appraiseLine(rock, 1, { rate = 1 })
    eq(line.credits, 0)
    eq(line.note, "STORY_BIG_RECEIPT")
    eq(line.marks.bigMeteorite, true)
    eq(OA.Value.markKeys(line.marks)[1], "STORY_BIG_RECEIPT")
end)

test("a drop site fragment carries the fragment note and pays its own rate", function()
    fakeStory()
    local fragment = info("OperationAcorn.MeteorFragment", "Junk", 0.5, { own = "MeteorFragment" })
    local line = OA.Value.appraiseLine(fragment, 2, { rate = 1, trustAccel = 1 })
    eq(line.credits, 60000)
    eq(line.note, "STORY_FRAGMENT_RECEIPT")
    eq(OA.Value.markKeys(line.marks)[1], "STORY_FRAGMENT_RECEIPT")
end)

test("the notes fall back to this part's keys without the story part", function()
    OA.Story = nil
    local line = OA.Value.appraiseLine(info("Base.LargeMeteorite", "Memento", 5), 1, { rate = 1 })
    eq(line.note, "IGUI_OA_Econ_Receipt_BigMeteorite")
    local fragment = OA.Value.appraiseLine(info("OperationAcorn.MeteorFragment", "Junk", 0.5, { own = "MeteorFragment" }), 1,
        { rate = 1 })
    eq(fragment.note, "IGUI_OA_Econ_Receipt_Fragment")
end)

test("an ordinary line has no meteorite note", function()
    fakeStory()
    local line = OA.Value.appraiseLine(info("Base.Hammer", "Tool", 1), 1, { rate = 1 })
    eq(line.note, nil)
    eq(line.marks.bigMeteorite, nil)
    eq(#OA.Value.markKeys(line.marks), 0)
end)

test("the receipt keeps the mark and the note when the trade part copies the line", function()
    fakeStory()
    local line = OA.Value.appraiseLine(info("Base.LargeMeteorite", "Memento", 5), 1, { rate = 1 })
    -- What the trade part's receiptLines keeps: numbers, strings, booleans and the true marks.
    local kept = {}
    for k, v in pairs(line) do
        if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then kept[k] = v end
    end
    kept.marks = {}
    for k, v in pairs(line.marks) do if v then kept.marks[k] = true end end
    eq(kept.note, "STORY_BIG_RECEIPT")
    eq(OA.Value.markKeys(kept.marks)[1], "STORY_BIG_RECEIPT")
end)

test("the settlement turns a big meteorite away with no credits and no word of its own", function()
    fakeStory()
    local record = OA.Store.ensure("a", "A")
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    local rock = info("Base.LargeMeteorite", "Memento", 5)
    local titles, notices = {}, {}
    OA.Sync.listen("title", function(id, detail) titles[#titles + 1] = detail end)
    OA.Sync.listen("notice", function(id, detail) notices[#notices + 1] = detail end)
    local result = OA.Value.settle(record, { { info = rock, count = 1 }, { info = rock, count = 2 } })
    eq(result.credits, 0)
    eq(#result.lines, 2)
    eq(result.lines[1].note, "STORY_BIG_RECEIPT", "the receipt line carries the note")
    eq(#titles, 0)
    eq(#notices, 0)
    eq(OA.Store.section(record, "codex").meteorRadio, nil, "nothing is kept for a radio line any more")
    eq(record.radio, nil)
end)

-- 3. The strange request.

test("the week after a hallucination the list holds the strange item besides the usual count", function()
    fakeStory({ strangeItem = function(record) return "Base.Harmonica" end })
    make(40)
    local record = OA.Store.ensure("a", "A")
    local list = OA.Requests.list(record)
    eq(#list, 7, "the usual 6 and the strange one")
    local found = 0
    for _, t in ipairs(list) do if t == "Base.Harmonica" then found = found + 1 end end
    eq(found, 1)
    local bonus = OA.Requests.bonusFor(record, "Base.Harmonica")
    truthy(bonus >= 0)
    eq(#OA.Requests.list(record), 7, "still 7 when asked again")
end)

test("no strange item in an ordinary week", function()
    fakeStory({ strangeItem = function() return nil end })
    make(40)
    local record = OA.Store.ensure("a", "A")
    eq(#OA.Requests.list(record), 6)
    OA.Story = nil
    TEST.hours = 24 * 7
    eq(#OA.Requests.list(record), 6, "and without the story part")
end)

test("the strange item is on the list once even if it was drawn as a candidate", function()
    fakeStory({ strangeItem = function() return "Base.Item3" end })
    make(40)
    local record = OA.Store.ensure("a", "A")
    local list = OA.Requests.list(record)
    local found = 0
    for _, t in ipairs(list) do if t == "Base.Item3" then found = found + 1 end end
    eq(found, 1)
    eq(list[1], "Base.Item3", "it comes first, drawn before the others")
    eq(#list, 7)
end)

test("the strange item earns the request bonus like any listed item", function()
    fakeStory({ strangeItem = function() return "Base.Harmonica" end })
    make(10)
    local record = OA.Store.ensure("a", "A")
    OA.Store.section(record, "trade").stage = 2
    OA.Trust.section(record).stage = 2
    local bonus, left = OA.Requests.bonusFor(record, "Base.Harmonica")
    truthy(bonus > 0, "stage 2 has a request bonus")
    eq(left, 20)
end)

-- 4. Mission items against the story part's rule.

test("a mission item is worth nothing while its mission is open and in time, 1000 and 5 trust when it has expired", function()
    local open = info("OperationAcorn.Note", "Junk", 0.1, { own = "MissionItem" })
    local late = info("OperationAcorn.Note", "Junk", 0.1, { own = "ExpiredMission" })
    local c = { rate = 1, trustAccel = 1 }
    eq(OA.Value.appraiseLine(open, 1, c).credits, 0)
    local expired = OA.Value.appraiseLine(late, 1, c)
    eq(expired.credits, 1000)
    eq(expired.trust, 5)
    eq(OA.Value.accepts(open), true)
    eq(OA.Value.accepts(late), true)
end)
