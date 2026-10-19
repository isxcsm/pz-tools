-- A new character in a world where another has gone before (CANON S19): the story clock of the world, the team's
-- one-time events not told again, the start with 관리 7 after the handover, the papers that keep the number they were
-- issued to, the dead numbers in the status table, the terminal before the first supply.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/CommsScript"
require "OperationAcorn/Trade/Trade"
local OA = OperationAcorn
local Story, Data, Docs, Comms, Missions, Script = OA.Story, OA.StoryData, OA.StoryDocs, OA.Comms, OA.Missions,
    OA.CommsScript

-- The character before: its record got to `stage` and `milestones` (the handover with `handover`), then it died.
local function before(stage, milestones, handover)
    local old = OA.Store.ensure("old", "Old")
    old.trade = { stage = stage, milestones = milestones or 0, credits = 0, trust = 0 }
    local s = Story.section(old)
    s.seenStage, s.seenMilestones = stage, milestones or 0
    if handover then s.handover = true end
    OA.Store.retire(old)
    return old
end

local function newcomer(stage, milestones)
    local record = OA.Store.ensure("new", "New")
    record.trade = { stage = stage or 0, milestones = milestones or 0, credits = 0, trust = 0 }
    TEST.drop = {}
    OA.Trade = OA.Trade or {}
    OA.Trade.addToDrop = function(_, items) for _, it in ipairs(items) do TEST.drop[#TEST.drop + 1] = it end end
    Story.section(record) -- (the server's hello: the story section is made when the record is first seen)
    return record
end

local function playAll(r)
    local ids = {}
    local e = Comms.next(r, "terminal")
    while e do
        ids[#ids + 1] = e.id
        Comms.played(r, e.id, Comms.section(r).tier)
        e = Comms.next(r, "terminal")
    end
    return table.concat(ids, " ")
end

test("the first character of a world starts it: nothing is passed", function()
    local record = newcomer()
    eq(Story.joinedTier(record), 0)
    eq(Story.joinedAfterHandover(record), false)
    eq(Story.section(record).joined, nil)
    eq(Story.greets(record), true)
    eq(Story.oldForm(record), false)
end)

test("the world's clock is the furthest any character got, the dead ones' too", function()
    before(3, 0)
    local other = OA.Store.ensure("x", "X")
    Story.section(other).seenStage = 2
    local tier, handover = Story.worldClock()
    eq(tier, 3)
    eq(handover, false)
end)

test("after the 4th tier: no line going dead, no Ordway leaving; the old form, the deputy's seal from the start", function()
    before(4, 0)
    local record = newcomer()
    eq(Story.joinedTier(record), 4)
    truthy(Comms.done(record, "S4"))
    truthy(Comms.done(record, "S4B"))
    eq(Comms.done(record, "S5"), false)
    eq(Comms.done(record, "S0"), false)
    eq(Story.oldForm(record), true, "the old form at the first crate")
    eq(Story.proxySigned(record, "reply_first"), true)
    eq(Story.greets(record), true, "the greeting was cut at the 5th")
    -- the record plays its first calls as anyone does
    Story.firstContact(record, false)
    eq(playAll(record), "S0")
end)

test("the notes of a change the newcomer never saw are left out, the others go in turn", function()
    before(5, 0)
    local record = newcomer(4)
    local s = Story.section(record)
    s.seenStage = 4
    local _, _, id = Story.manifestNoteKey(record, {})
    eq(id, nil, "every 4th-stage note tells of a change (seal, form, remarks)")
    record.trade.stage = 5
    s.seenStage = 5
    _, _, id = Story.manifestNoteKey(record, {})
    eq(id, "late_appendix")
    _, _, id = Story.manifestNoteKey(record, {})
    eq(id, "empty_slot", "no_greeting is left out")
end)

test("after the 5th tier the team's calls never greet: the line is the number alone", function()
    before(5, 0)
    local record = newcomer(1)
    eq(Story.greets(record), false)
    truthy(Comms.done(record, "S5"))
    local text = function(key) return key == "IGUI_OA_Story_Greeting_1" and "G1" or key end
    eq(Script.greeted("0347, line.", { text = text, number = "0347", tier = 1, greet = false }), "0347, line.")
    eq(Script.greeted("0347, line.", { text = text, number = "0347", tier = 1 }), "G1 0347, line.")
end)

test("after the 7th tier the radio operator's flashlight call is not told", function()
    before(5, 2)
    local record = newcomer()
    truthy(Comms.done(record, "S7"))
    eq(Comms.done(record, "S7F"), false, "a story mission's call is the record's own")
end)

test("a request copy of a newcomer after Ordway left carries the deputy's approval", function()
    before(4, 0)
    local record = newcomer(2)
    local req = Story.addRequestCopy(record, "exchange")
    eq(req.proxy, true)
end)

test("a paper that went out at the 4th tier or later is signed by the deputy", function()
    local record = newcomer(3)
    eq(Story.proxySigned(record, "reply_fragment"), false)
    Story.queuePaper(record, { "AnalysisReply", "reply_fragment" })
    record.trade.stage = 4
    Story.takePaper(record)
    eq(Story.proxySigned(record, "reply_fragment"), true)
end)

test("the reply's signature is Ordway's or the deputy's", function()
    local texts = {
        IGUI_OA_Story_Doc_reply_first = "> Signed: {sign}  19 AUG (%1)",
        IGUI_OA_Story_Sign_Ordway = "ORDWAY, LTC.",
        IGUI_OA_Story_Sign_Proxy = "proxy (per transfer orders) [seal: ORDWAY]",
    }
    local plain = getText
    getText = function(key, a) return (string.gsub(texts[key] or key, "%%1", tostring(a))) end
    local record = newcomer()
    record.number = 1234
    eq(Docs.body(record, "reply_first"), "> Signed: ORDWAY, LTC.  19 AUG (1234)")
    Story.section(record).sentTier.reply_first = 4
    eq(Docs.body(record, "reply_first"), "> Signed: proxy (per transfer orders) [seal: ORDWAY]  19 AUG (1234)")
    getText = plain
end)

test("after the handover the newcomer has Control 7 from the first call, and none of Team 2", function()
    before(5, 3, true)
    local record = newcomer()
    eq(Story.joinedAfterHandover(record), true)
    eq(Story.handedOver(record), true)
    eq(Story.callSignKey(record), "IGUI_OA_Story_CallSign_Handover")
    eq(Story.firstCall(record), "K0")
    Story.firstContact(record, false)
    eq(Comms.section(record).fired.S0, nil)
    eq(Missions.opened(record), false, "no mission before Control 7 has told of them")
    eq(playAll(record), "K0")
    Story.call(record, "settled")
    eq(playAll(record), "K0M")
    eq(Missions.opened(record), true)
    -- the stages and the first three milestones bring nothing of Team 2
    record.trade.stage, record.trade.milestones = 5, 3
    Story.onStage(record)
    local s = Story.section(record)
    eq(#s.queue, 0)
    eq(#s.papers, 0)
    eq(playAll(record), "")
    -- the 4th milestone: a revisit, and Control 7's scheduled call
    record.trade.milestones = 4
    Story.onStage(record)
    eq(s.queue[1].id, "revisit_ledger")
    eq(playAll(record), "K1")
    -- the after-handover notes
    local _, _, id = Story.manifestNoteKey(record, { orders = { { delivered = 1 } } })
    eq(id, "after4_1")
end)

test("a character of the team's time never gets Control 7's first calls", function()
    local record = newcomer()
    Story.firstContact(record, false)
    Story.call(record, "settled")
    eq(playAll(record), "S0 S1")
    eq(Comms.section(record).fired.K0, nil)
    eq(Comms.section(record).fired.K0M, nil)
end)

test("a paper keeps the number it was issued to and reads with it", function()
    local old = before(2, 0)
    old.number = 4321
    OA.Store.root().numbers[4321] = old.id
    local record = newcomer()
    record.number = 1234
    Story.queuePaper(old, { "AnalysisReply", "reply_first" })
    local spec = Story.takePaper(old)
    eq(spec.mod.OA_No, 4321)
    local list = Docs.forItem(record, "AnalysisReply", spec.mod)
    eq(list[1].no, 4321)
    truthy(string.find(Docs.body(record, "reply_first", nil, nil, list[1].no), "4321", 1, true))
    eq(string.find(Docs.body(record, "reply_first", nil, nil, list[1].no), "1234", 1, true), nil)
    -- a mission's item: the owner's number
    list = Docs.forItem(record, "EvidenceEnvelope", { OA_Owner = old.id, OA_Variant = "police" })
    eq(list[1].no, 4321)
    -- read, it stays in the folder with that number; one of its own keeps none
    Story.markRead(record, "reply_first", nil, nil, 4321)
    Story.markRead(record, "serum_sheet", nil, nil, 1234)
    local read = Story.readDocuments(record)
    eq(read[1].id, "reply_first")
    eq(read[1].no, 4321)
    eq(read[2].no, nil)
end)

test("the status table and the roster read as the issuer's", function()
    local old = before(5, 3, true)
    old.number = 4321
    OA.Store.root().numbers[4321] = old.id
    local record = newcomer()
    record.number = 1234
    local body = Docs.body(record, "status_table", nil, nil, 4321)
    truthy(string.find(body, "IGUI_OA_Story_Doc_status_table_head 4321", 1, true))
    eq(Story.section(record).status, nil, "the reader's own table is not made")
end)

test("the numbers of the world's dead characters are in the status table, 'no response', off the roster", function()
    local old = before(3, 0)
    old.number = 4321
    local record = newcomer(5, 3)
    record.number = 1234
    local st = Story.statusTable(record)
    eq(#st.rows, Data.STATUS_ROWS)
    local found
    for i, row in ipairs(st.rows) do
        if row.n == 4321 then found = i end
    end
    truthy(found, "the dead number is a row")
    eq(st.rows[found].c, "none")
    for _, idx in ipairs(st.roster) do truthy(idx ~= found, "not next to a name") end
end)

test("a terminal does not answer a character before its first supply has brought its number", function()
    local record = newcomer()
    eq(OA.Trade.registered(record), false, "no plan yet")
    record.first = { mode = "window", done = false }
    eq(OA.Trade.registered(record), false)
    record.first.done = true
    eq(OA.Trade.registered(record), true)
    local greeted = newcomer()
    greeted.first = nil
    OA.Store.section(greeted, "heli").greeted = true
    eq(OA.Trade.registered(greeted), true, "a record the team has answered keeps its number")
end)
