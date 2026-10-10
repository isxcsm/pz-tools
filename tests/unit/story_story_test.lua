-- The story core: what a stage queues and sends, the order of the manifest notes, greetings, the old form, the radio
-- copies and the frequency's own lines after the handover, the status table, the strange item.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Story"
local OA = OperationAcorn
local Story, Data = OA.Story, OA.StoryData

local function setup(stage, milestones)
    local record = OA.Store.ensure("p1", "P")
    record.number = 347
    record.trade = { stage = stage or 0, milestones = milestones or 0, credits = 0, trust = 0 }
    TEST.drop = {}
    OA.Trade = {
        addToDrop = function(rec, items) for _, it in ipairs(items) do TEST.drop[#TEST.drop + 1] = it end end,
    }
    return record
end

test("entering the first stage queues its story first, files its radio copy and sends its serum sheet", function()
    local record = setup(1)
    Story.onStage(record)
    local s = Story.section(record)
    eq(#s.queue, 1)
    eq(s.queue[1].id, "evidence")
    eq(s.queue[1].fresh, true)
    local copies = Story.radioCopies(record)
    eq(#copies, 1)
    eq(copies[1].id, "s1")
    eq(copies[1].keys[1], "s1_a")
    eq(copies[1].keys[2], "s1_b")
    eq(record.radio, nil, "no radio log is kept")
    eq(#TEST.drop, 1)
    eq(TEST.drop[1].type, "OperationAcorn.SerumSheet")
    eq(TEST.drop[1].mod.OA_Doc, "serum_sheet")
    eq(#s.supply, 0, "handed to the trade part")
end)

test("the same stage is entered once, however often it is called", function()
    local record = setup(2)
    Story.onStage(record, 2, 0)
    Story.onStage(record, 2, 0)
    local s = Story.section(record)
    eq(s.seenStage, 2)
    local count = 0
    for _, copy in ipairs(Story.radioCopies(record)) do if copy.id == "s1" then count = count + 1 end end
    eq(count, 1)
    eq(#Story.radioCopies(record), 2, "one copy for each stage entered")
    eq(#TEST.drop, 1 + 3, "serum sheet and the three replies, once")
end)

test("the fourth stage queues the cooler first and the optional bunker after it", function()
    local record = setup(4)
    Story.section(record).seenStage = 3
    Story.onStage(record)
    local s = Story.section(record)
    local ids = {}
    for _, q in ipairs(s.queue) do ids[#ids + 1] = q.id .. (q.fresh and "!" or "") end
    local text = table.concat(ids, ",")
    truthy(string.find(text, "cooler!", 1, true), text)
    truthy(string.find(text, "bunker", 1, true), text)
    eq(Story.nextStory(record).id, "cooler")
    eq(Story.nextStory(record), nil, "the bunker waits for a regular mission")
    s.regularsSince = 1
    eq(Story.nextStory(record).id, "bunker")
end)

test("a story mission is done once, a missed one comes back, an optional one closes", function()
    local record = setup(3)
    Story.onStage(record)
    local s = Story.section(record)
    s.queue = {}  -- the mission was started: it left the queue
    Story.missionEnded(record, { story = "observation" }, "expired")
    eq(s.done.observation, "missed")
    eq(s.missed[1], "observation")
    record.trade.stage = 4
    Story.onStage(record)
    local found = false
    for _, q in ipairs(s.queue) do if q.id == "observation" then found = true; eq(q.fresh, false) end end
    truthy(found, "queued again")
    s.queue = {}
    Story.missionEnded(record, { story = "bunker" }, "expired")
    eq(s.done.bunker, "closed")
    Story.queueStory(record, "bunker", false)
    eq(#s.queue, 0, "not offered again")
end)

test("milestones: the unresolved list, the soil mission at the second, the handover at the third", function()
    local record = setup(5, 2)
    Story.onStage(record)
    local s = Story.section(record)
    local ids = {}
    for _, q in ipairs(s.queue) do ids[q.id] = q end
    truthy(ids.gym and ids.ward and ids.cells and ids.soil, "gym, ward, cells and the optional soil")
    eq(ids.soil.fresh, false)
    record.trade.milestones = 3
    Story.onStage(record)
    local hand = false
    for _, q in ipairs(s.queue) do if q.id == "handover" then hand = true end end
    truthy(hand)
    eq(Story.handedOver(record), false, "not before the mission ends")
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    Story.missionEnded(record, { story = "handover" }, "expired")
    eq(Story.handedOver(record), true, "any ending completes it")
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_Handover")
    eq(told[1].subArgs[1].key, "IGUI_OA_Story_CallSign_Handover", "the new call sign under it")
    eq(s.noteQueue[#s.noteQueue], "last_b")
    local types = {}
    for _, it in ipairs(TEST.drop) do types[it.type] = true end
    truthy(types["OperationAcorn.HandoverFile"] and types["OperationAcorn.KitVoucher"], "the last crate")
    local copies = Story.radioCopies(record)
    eq(copies[#copies].id, "handover", "the handover's copy is the last")
    eq(Story.callSignKey(record), "IGUI_OA_Story_CallSign_Handover")
end)

test("from the fourth milestone each milestone has one revisit story, in turn", function()
    local record = setup(5, 4)
    Story.section(record).seenStage = 5
    Story.section(record).seenMilestones = 3
    Story.section(record).handover = true
    Story.onStage(record)
    eq(Story.section(record).queue[1].id, "revisit_ledger")
    record.trade.milestones = 5
    Story.onStage(record)
    local ids = {}
    for _, q in ipairs(Story.section(record).queue) do ids[#ids + 1] = q.id end
    truthy(string.find(table.concat(ids, ","), "revisit_roster", 1, true))
end)

test("the manifest notes go out in the stage's order, one per crate, queued remarks first", function()
    local record = setup(1)
    Story.onStage(record)
    local key, args, id = Story.manifestNoteKey(record)
    eq(id, "battery")
    eq(key, "IGUI_OA_Story_Note_battery")
    eq(select(3, Story.manifestNoteKey(record)), "appendix_missing")
    Story.queueNote(record, "case_confirmed")
    eq(select(3, Story.manifestNoteKey(record)), "case_confirmed")
    eq(select(3, Story.manifestNoteKey(record)), "leave_site")
    eq(Story.manifestNoteKey(record), nil, "the pool is used up: the trade part's general lines")
    local text, nid = Story.manifestNote(setup(2))
    eq(nid, "bedding_back")
    truthy(string.find(text, "IGUI_OA_Story_Note_bedding_back", 1, true))
end)

test("after the handover the notes come from the milestone's pool, shorter the further", function()
    local record = setup(5, 3)
    Story.section(record).handover = true
    local first = select(3, Story.manifestNoteKey(record))
    eq(first, "after3_1")
    record.trade.milestones = 5
    eq(select(3, Story.manifestNoteKey(record)), "after5_1")
    local n = 0
    while Story.manifestNoteKey(record) do n = n + 1 end
    eq(n, 11, "twelve notes in a pool")
end)

test("greetings shorten with the stage, none at the fifth, long again after the handover", function()
    eq(Story.greetingKeyFor(0, false), nil)
    eq(Story.greetingKeyFor(1, false), "IGUI_OA_Story_Greeting_1")
    eq(Story.greetingKeyFor(4, false), "IGUI_OA_Story_Greeting_4")
    eq(Story.greetingKeyFor(5, false), nil)
    eq(Story.greetingKeyFor(5, true), "IGUI_OA_Story_Greeting_H")
    local record = setup(5)
    eq(Story.greetingKey(record), nil)
    eq(Story.greetingText(record), "")
    record.trade.stage = 2
    eq(Story.greetingKey(record), "IGUI_OA_Story_Greeting_2")
    truthy(string.find(Story.greetingText(record), "Greeting_2", 1, true))
end)

test("the old form comes at the fourth stage", function()
    local record = setup(3)
    eq(Story.oldForm(record), false)
    eq(Story.formLabel(record, "serial", "No."), "No.")
    record.trade.stage = 4
    eq(Story.oldForm(record), true)
    eq(Story.formLabel(record, "serial", "No."), "IGUI_OA_Story_Form_serial")
    eq(Story.formLabel(record, "other", "x"), "x")
end)

test("the first contact is filed once, a late one for a late first crate", function()
    local record = setup(0)
    eq(Story.section(record).firstContact, nil)
    truthy(Story.firstContact(record, true))
    eq(Story.section(record).firstContact, "late")
    eq(Story.firstContact(record, false), false, "once")
    eq(Story.section(record).firstContact, "late", "and it stays late")
    eq(record.radio, nil, "no radio line is written")
    local other = setup(0)
    Story.section(other).firstContact = nil
    truthy(Story.firstContact(other, false))
    eq(Story.section(other).firstContact, true)
    eq(Story.firstContact(other, true), false)
end)

test("the radio copies are worked out from the counters, oldest first", function()
    local record = setup(0)
    eq(#Story.radioCopies(record), 0, "nothing before the first contact")
    Story.firstContact(record, true)
    local copies = Story.radioCopies(record)
    eq(#copies, 1)
    eq(copies[1].id, "first")
    eq(copies[1].stage, nil)
    eq(copies[1].keys[1], "first_late")
    local plain = setup(0)
    Story.section(plain).firstContact = nil
    Story.firstContact(plain, false)
    eq(Story.radioCopies(plain)[1].keys[1], "first")
    local s = Story.section(record)
    s.seenStage = 5
    s.seenMilestones = 2
    copies = Story.radioCopies(record)
    eq(#copies, 1 + 5 + 2, "the first contact, five stages, two milestones")
    local ids = {}
    for i, c in ipairs(copies) do ids[i] = c.id end
    eq(table.concat(ids, ","), "first,s1,s2,s3,s4,s5,m1,m2")
    eq(copies[2].stage, 1)
    eq(copies[2].keys, Data.STAGES[1].radio)
    eq(copies[7].stage, 6, "the first milestone counts on as the sixth stage")
    eq(copies[8].stage, 7)
    eq(copies[7].keys, Data.MILESTONES[1].radio)
    s.seenMilestones = 3
    s.handover = true
    copies = Story.radioCopies(record)
    eq(copies[#copies].id, "handover")
    eq(copies[#copies].keys[1], Data.HANDOVER_RADIO)
    eq(#copies, 1 + 5 + 3 + 1)
end)

test("a radio copy has its title and its text from the translations", function()
    local record = setup(0)
    record.number = 347
    local s = Story.section(record)
    s.firstContact = "late"
    s.seenStage = 2
    s.handover = true
    local byId = {}
    for _, c in ipairs(Story.radioCopies(record)) do byId[c.id] = c end
    eq(Story.copyTitle(byId.first), "IGUI_OA_Story_Copy_Title IGUI_OA_Story_Copy_first")
    eq(Story.copyTitle(byId.handover), "IGUI_OA_Story_Copy_Title IGUI_OA_Story_Copy_handover")
    eq(Story.copyTitle(byId.s2), "IGUI_OA_Story_Copy_Title IGUI_OA_Story_Copy_Stage 2")
    eq(Story.copyText(record, byId.first), "IGUI_OA_Story_Radio_first_late 0347", "the number goes in")
    local text = Story.copyText(record, byId.s1)
    local a = string.find(text, "IGUI_OA_Story_Radio_s1_a", 1, true)
    local b = string.find(text, "IGUI_OA_Story_Radio_s1_b", 1, true)
    truthy(a and b and a < b, "the lines in order")
    truthy(string.find(text, "\n\n", 1, true), "a blank line between them")
end)

test("after the handover a line of its own is on the air every few days: two lines, a question, in order", function()
    local record = setup(5, 3)
    local s = Story.section(record)
    eq(Story.dailyRadio(record, 10), false, "not before the handover")
    eq(s.radioLine, nil)
    s.handover = true
    local function day(d) return Story.dailyRadio(record, d) end
    truthy(day(10))
    eq(s.radioLine, "Radio_after3_1")
    eq(s.radioDay, 10)
    eq(s.radioIndex, 1)
    eq(Story.airLine(record, 10), "IGUI_OA_Story_Radio_after3_1", "on the air that day")
    eq(Story.airLine(record, 11), nil, "and only that day")
    eq(Story.airLine(record, 9), nil)
    eq(day(12), false, "too soon")
    eq(s.radioIndex, 1)
    eq(Story.airLine(record, 12), nil)
    truthy(day(15))
    eq(s.radioLine, "Radio_after3_2")
    truthy(day(20))
    eq(s.radioLine, "Question_after3_1")
    eq(Story.airLine(record, 20), "IGUI_OA_Story_Question_after3_1")
    for d = 25, 25 + 5 * 20, 5 do Story.dailyRadio(record, d) end
    eq(s.radioIndex, 9, "six lines and three questions, then it is quiet")
    eq(record.radio, nil, "nothing is written in a log")
end)

test("refusal lines: a category with its own, the rest with the general one", function()
    eq(Story.refusalKey("A", "start"), "IGUI_OA_Story_Refuse_A_start")
    eq(Story.refusalKey("F", "back"), "IGUI_OA_Story_Refuse_F_back")
    eq(Story.refusalKey("C", "start"), "IGUI_OA_Story_Refuse_any_start")
end)

test("documents read are kept by id, once", function()
    local record = setup(1)
    truthy(Story.markRead(record, "police_card", "muldraugh_pd"))
    eq(Story.markRead(record, "police_card", "westpoint_pd"), false, "the first variant stays")
    Story.markRead(record, "clinic_log")
    local docs = Story.readDocuments(record)
    eq(#docs, 2)
    eq(docs[1].id, "clinic_log")
    eq(docs[1].variant, nil)
    eq(docs[2].variant, "muldraugh_pd")
end)

test("the manifests kept are the latest few", function()
    local record = setup(1)
    for i = 1, Data.MANIFESTS_KEPT + 4 do Story.addManifest(record, i, "text " .. i) end
    local list = Story.section(record).manifests
    eq(#list, Data.MANIFESTS_KEPT)
    eq(list[1].serial, 5)
end)

test("the status table has sparse numbers, only the player's kept, and three on the roster page", function()
    local record = setup(5, 3)
    local st = Story.statusTable(record)
    eq(#st.rows, Data.STATUS_ROWS)
    local keep = 0
    local last = -1
    for _, row in ipairs(st.rows) do
        if row.c == "keep" then keep = keep + 1; eq(row.n, 347) end
        truthy(row.n > last, "ascending")
        last = row.n
    end
    eq(keep, 1)
    eq(#st.roster, 3)
    for _, idx in ipairs(st.roster) do truthy(st.rows[idx].c ~= "keep") end
    eq(Story.statusTable(record), st, "made once")
end)

test("the registration date reads 'before the first drop' when the world did not start in July", function()
    SandboxVars.StartMonth = 7
    eq(Story.registeredLate(), false)
    SandboxVars.StartMonth = 9
    eq(Story.registeredLate(), true)
end)

test("the strange item is for the week after a hallucination only", function()
    local record = setup(3)
    eq(Story.strangeItem(record), nil)
    Story.section(record).strangeWeek = OA.week()
    truthy(Story.strangeItem(record))
    Story.section(record).strangeWeek = OA.week() + 1
    eq(Story.strangeItem(record), nil)
end)

test("without the trade part the supply waits in the record, the radio copy stays", function()
    local record = setup(1)
    OA.Trade = nil
    Story.onStage(record)
    eq(#Story.section(record).supply, 1)
    eq(#Story.radioCopies(record), 1, "the radio copy needs no trade part")
end)

-- The upgrade of a save from before: the terminal's radio log goes, the late first line is kept as the story's.

local function upgrade(record, name)
    record.upgrades = record.upgrades or {}
    record.upgrades[name] = nil
    OA.Store.upgrade(record)
end

test("the radio log upgrade is registered and a new record has it done", function()
    local found = false
    for _, step in ipairs(OA.Store.UPGRADES) do if step.name == "story.radio" then found = true end end
    truthy(found, "registered")
    eq(setup(0).upgrades["story.radio"], true)
end)

test("an old radio log goes, and a late first line is kept as the late first contact", function()
    local record = setup(0)
    record.radio = {
        { at = 1, key = "IGUI_OA_Story_Radio_first_late", args = { "0347" } },
        { at = 5, key = "IGUI_OA_Trade_Radio_Dropped" },
    }
    upgrade(record, "story.radio")
    eq(record.radio, nil)
    eq(Story.section(record).firstContact, "late")
    eq(Story.radioCopies(record)[1].keys[1], "first_late")
    eq(record.upgrades["story.radio"], true)

    local plain = OA.Store.ensure("p2", "P2")
    plain.radio = { { at = 1, key = "IGUI_OA_Story_Radio_first", args = { "0347" } } }
    upgrade(plain, "story.radio")
    eq(plain.radio, nil)
    eq(Story.section(plain).firstContact, nil, "the plain first line leaves it to the next first contact")
end)

test("the radio log upgrade leaves a record without a log alone", function()
    local record = setup(0)
    upgrade(record, "story.radio")
    eq(record.radio, nil)
    eq(Story.section(record).firstContact, nil)
end)
