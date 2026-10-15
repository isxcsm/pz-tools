-- The story core: what a stage queues and sends, the order of the manifest notes, the old form, the status table, the
-- strange item.
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

test("entering the first stage queues its story first and sends its serum sheet", function()
    local record = setup(1)
    Story.onStage(record)
    local s = Story.section(record)
    eq(#s.queue, 1)
    eq(s.queue[1].id, "evidence")
    eq(s.queue[1].fresh, true)
    eq(#TEST.drop, 0, "the papers wait for a crate: the trade part's drop gets none")
    eq(#s.papers, 1)
    local spec = Story.takePaper(record)
    eq(spec.type, "OperationAcorn.SerumSheet")
    eq(spec.mod.OA_Doc, "serum_sheet")
    eq(#s.papers, 0)
    eq(s.sent.serum_sheet, true)
end)

test("the same stage is entered once, however often it is called", function()
    local record = setup(2)
    Story.onStage(record, 2, 0)
    Story.onStage(record, 2, 0)
    local s = Story.section(record)
    eq(s.seenStage, 2)
    eq(#Story.section(record).papers, 1 + 3, "serum sheet and the three replies, once")
    eq(#TEST.drop, 0)
end)

test("the fourth stage queues the cooler, fresh", function()
    local record = setup(4)
    Story.section(record).seenStage = 3
    Story.onStage(record)
    local s = Story.section(record)
    eq(s.queue[1].id, "cooler")
    eq(s.queue[1].fresh, true)
    eq(Story.nextStory(record).id, "cooler")
end)

test("an optional story mission waits for a regular one before it", function()
    local record = setup(5, 2)
    Story.section(record).seenStage = 5
    Story.section(record).seenMilestones = 1
    Story.onStage(record)
    local s = Story.section(record)
    local soil
    for _, q in ipairs(s.queue) do if q.id == "soil" then soil = q end end
    truthy(soil, "the soil sample is queued")
    eq(soil.fresh, false, "after a regular")
end)

test("a story mission is done once; a missed one, optional or not, is queued again at once behind a regular", function()
    local record = setup(3)
    Story.onStage(record)
    local s = Story.section(record)
    s.queue = {}  -- the mission was started: it left the queue
    Story.missionEnded(record, { story = "observation" }, "expired")
    eq(s.done.observation, "missed")
    eq(s.queue[1].id, "observation")
    eq(s.queue[1].fresh, false, "a regular comes between")
    eq(Story.nextStory(record), nil, "not before a regular")
    Story.missionEnded(record, { kind = "regular" }, "done")
    eq(Story.nextStory(record).id, "observation", "after a regular")
    Story.missionEnded(record, { story = "soil" }, "lost")
    eq(s.done.soil, "missed")
    eq(s.queue[1].id, "soil", "an optional one comes back too")
    Story.missionEnded(record, { story = "observation" }, "done")
    Story.queueStory(record, "observation", false)
    eq(#s.queue, 1, "a done one is not offered again")
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
    local other = setup(0)
    Story.section(other).firstContact = nil
    truthy(Story.firstContact(other, false))
    eq(Story.section(other).firstContact, true)
    eq(Story.firstContact(other, true), false)
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

test("without the trade part the supply waits in the record", function()
    local record = setup(1)
    OA.Trade = nil
    Story.onStage(record)
    Story.queueSupply(record, "FieldCallDevice", nil)
    eq(#Story.section(record).supply, 1)
    eq(#Story.section(record).papers, 1, "the paper needs no trade part to wait")
end)

-- The papers: one to a crate, when their time has come -------------------------------------------------------------

test("a crate takes one paper, the first that is ready, and none when none is", function()
    local record = setup(2)
    Story.onStage(record)
    local s = Story.section(record)
    eq(#s.papers, 4, "the serum sheet and the three replies")
    local order = {}
    local function take()
        local spec = Story.takePaper(record)
        order[#order + 1] = spec and spec.mod.OA_Doc or "-"
        return spec
    end
    take()
    take()
    take()
    eq(table.concat(order, ","), "serum_sheet,reply_first,reply_correction", "the evidence reply waits for the evidence")
    eq(#s.papers, 1)
    eq(take(), nil)
    s.done.evidence = "done"
    eq(take().mod.OA_Doc, "reply_evidence")
    eq(take(), nil)
    eq(Story.crateSpecs(record), nil)
end)

test("the evidence reply goes only when the evidence was delivered; a missed one does not send it", function()
    local record = setup(2)
    Story.onStage(record)
    Story.missionEnded(record, { story = "evidence" }, "expired")
    local docs = {}
    for _ = 1, 6 do
        local spec = Story.takePaper(record)
        if spec then docs[#docs + 1] = spec.mod.OA_Doc end
    end
    eq(table.concat(docs, ","), "serum_sheet,reply_first,reply_correction")
    Story.missionEnded(record, { story = "evidence" }, "done")
    eq(Story.takePaper(record).mod.OA_Doc, "reply_evidence", "delivered at last")
end)

test("the correction does not go before the first reply, even if it is queued in front", function()
    local record = setup(2)
    Story.onStage(record)
    local s = Story.section(record)
    local byDoc = {}
    for _, p in ipairs(s.papers) do byDoc[p.doc] = p end
    s.papers = { byDoc.reply_correction, byDoc.reply_first }  -- the correction in front of the first reply
    eq(s.papers[1].doc, "reply_correction")
    eq(s.papers[2].doc, "reply_first")
    eq(Story.takePaper(record).mod.OA_Doc, "reply_first", "the correction is not ready yet")
    eq(Story.takePaper(record).mod.OA_Doc, "reply_correction")
end)

test("the fragment reply goes after a fragment has been on a receipt", function()
    local record = setup(3)
    Story.section(record).seenStage = 2
    Story.onStage(record)
    local docs = {}
    for _ = 1, 4 do
        local spec = Story.takePaper(record)
        if spec then docs[#docs + 1] = spec.mod.OA_Doc end
    end
    eq(table.concat(docs, ","), "reply_nomatch,reply_relapse", "no fragment yet")
    Story.onSettled(record, { lines = { { marks = { newRegion = true } } } })
    eq(Story.takePaper(record), nil)
    Story.onSettled(record, { lines = { { marks = { fragment = true } } } })
    eq(Story.takePaper(record).mod.OA_Doc, "reply_fragment")
end)

test("each fragment on a receipt goes to the upgrades by its kind", function()
    local record = setup(3)
    local was, got = OA.Upgrades, {}
    OA.Upgrades = { fragmentReceived = function(rec, fullType) got[#got + 1] = fullType end }
    Story.onSettled(record, { lines = {
        { marks = { fragment = true }, fullType = "OperationAcorn.MeteorFragmentIron" },
        { marks = { newRegion = true }, fullType = "Base.Hammer" },
        { marks = { fragment = true }, fullType = "OperationAcorn.MeteorFragment" },
    } })
    OA.Upgrades = was
    eq(table.concat(got, ","), "OperationAcorn.MeteorFragmentIron,OperationAcorn.MeteorFragment")
    eq(Story.section(record).fragmentSeen, true)
end)

test("the fifth stage's appendix and the milestones' lists go before the others", function()
    local record = setup(5)
    Story.section(record).seenStage = 4
    local s = Story.section(record)
    Story.queuePaper(record, { "AnalysisReply", "reply_relapse" })
    Story.onStage(record)
    eq(Story.takePaper(record).mod.OA_Doc, "appendix_2", "the first crate after entering has it")
    eq(Story.takePaper(record).mod.OA_Doc, "reply_relapse")
    Story.queuePaper(record, { "AnalysisReply", "reply_relapse" })
    eq(#s.papers, 0, "a paper that has gone is not queued again")
end)

test("the fourth stage has a paper of its own", function()
    local record = setup(4)
    Story.section(record).seenStage = 3
    Story.onStage(record)
    local spec = Story.takePaper(record)
    eq(spec.type, "OperationAcorn.Appendix")
    eq(spec.mod.OA_Doc, "pending_list")
end)

-- The remarks: what they enclose, when they are true, the filler lines ----------------------------------------------

local function fillLanguage(counts)
    getTextOrNull = function(key)
        local id, n = string.match(key, "^IGUI_OA_Story_Fill_(%w+)_(%d+)$")
        if id and counts[id] and tonumber(n) <= counts[id] then return key end
        return nil
    end
end

test("a remark tells what it encloses, and the items are the ones its words name", function()
    local record = setup(1)
    Story.onStage(record)
    local key, args, id, fx = Story.manifestNoteKey(record)
    eq(id, "battery")
    eq(fx.items[1].type, "Base.Battery")
    eq(fx.items[1].count, 2)
    eq(select(4, Story.manifestNoteKey(record)), nil, "the missing appendix encloses nothing")
    -- Every remark that says something is enclosed has its items.
    for noteId, list in pairs(Data.NOTE_ITEMS) do
        for _, entry in ipairs(list) do truthy(entry[1] and entry[2] > 0, noteId) end
    end
    local ids = {}
    for _, stage in pairs(Data.STAGES) do for _, n in ipairs(stage.notes) do ids[n] = true end end
    for _, n in ipairs({ "battery", "socks", "cards", "dunnigan_pen" }) do truthy(ids[n] and Data.NOTE_ITEMS[n], n) end
    for m = 3, 5 do
        local last = m == 3 and 11 or 10   -- the pool of the third milestone has its lighter at the eleventh place
        for _, i in ipairs({ 2, 4, 6, 8, last }) do truthy(Data.NOTE_ITEMS["after" .. m .. "_" .. i], "after" .. m .. "_" .. i) end
    end
    truthy(Data.NOTE_ITEMS.m1_c and Data.NOTE_ITEMS.m2_b)
end)

test("the serial remark waits for a manifest number that does not follow the last", function()
    local record = setup(3)
    Story.section(record).seenStage = 2
    Story.onStage(record)
    eq(select(3, Story.manifestNoteKey(record, { serial = 10, lastSerial = 9 })), "cards")
    eq(Story.manifestNoteKey(record, { serial = 10, lastSerial = 9 }), nil, "the next is count_off: 10 follows 9")
    eq(Story.manifestNoteKey(record), nil, "and with no crate to bear it out")
    eq(select(3, Story.manifestNoteKey(record, { serial = 12, lastSerial = 9 })), "count_off")
    eq(select(3, Story.manifestNoteKey(record, { serial = 15, lastSerial = 12 })), "dunnigan_pen")
end)

test("a remark that counts the orders is said when an order was loaded, and tells how many", function()
    local record = setup(5, 3)
    Story.section(record).handover = true
    local none = { orders = { { ordered = 2, delivered = 0, reason = "credits" } } }
    eq(select(3, Story.manifestNoteKey(record, {})), "after3_1")
    eq(Story.manifestNoteKey(record, none), nil, "after3_2 counts orders loaded")
    local ctx = { orders = { { ordered = 2, delivered = 2 }, { ordered = 1, delivered = 0 }, { ordered = 1, delivered = 1 } } }
    local key, args, id = Story.manifestNoteKey(record, ctx)
    eq(id, "after3_2")
    eq(args[2], 2, "two lines loaded")
    eq(args[3], 3, "of three")
end)

test("a manifest with a remark of the story's own stays in the folder past the usual few", function()
    local record = setup(1)
    for i = 1, 3 do Story.addManifest(record, i, "story " .. i, true) end
    for i = 4, 4 + Data.MANIFESTS_KEPT + 3 do Story.addManifest(record, i, "plain " .. i, false) end
    local list = Story.section(record).manifests
    local keep, plain = 0, 0
    for _, mf in ipairs(list) do if mf.keep then keep = keep + 1 else plain = plain + 1 end end
    eq(keep, 3)
    eq(plain, Data.MANIFESTS_KEPT)
    eq(list[1].serial, 1, "the story's are the oldest and are still there")
    eq(list[4].serial, 4 + 4, "the plain ones are the latest")
    Story.addManifest(record, 2, "story 2 again", true)
    eq(#list, 3 + Data.MANIFESTS_KEPT, "the same number replaces its entry")
    truthy(Story.keepsManifest("IGUI_OA_Story_Note_battery"))
    eq(Story.keepsManifest("IGUI_OA_Story_Fill_s1_1"), false)
    eq(Story.keepsManifest(nil), false)
end)

test("the filler remark: the stage's bundle in turn, resting between, then the milestone's and the new office's", function()
    fillLanguage({ s1 = 5, s2 = 5, m = 4, a = 4, partial = 4, serum = 2 })
    local record = setup(1)
    Story.onStage(record)
    local seen = {}
    for i = 1, 5 do
        TEST.hours = i * 100
        local key = Story.fillNoteKey(record, {})
        truthy(key and string.find(key, "^IGUI_OA_Story_Fill_s1_%d$"), tostring(key))
        eq(seen[key], nil, "no line twice in a round")
        seen[key] = true
    end
    TEST.hours = 501
    eq(Story.fillNoteKey(record, {}), nil, "it rests after a line")
    record.trade.stage = 2
    TEST.hours = 700
    truthy(string.find(Story.fillNoteKey(record, {}), "Fill_s2_", 1, true))
    record.trade.milestones = 1
    TEST.hours = 900
    truthy(string.find(Story.fillNoteKey(record, {}), "Fill_m_", 1, true))
    Story.section(record).handover = true
    TEST.hours = 1100
    truthy(string.find(Story.fillNoteKey(record, {}), "Fill_a_", 1, true))
    eq(Story.fillNoteKey(setup(0), {}), nil, "none before the first stage")
end)

test("the filler remark for what the crate is: orders cut short by their reason, a serum, a new region", function()
    fillLanguage({ s3 = 5, partial = 4, serum = 2 })
    local record = setup(3)
    Story.onStage(record)
    local credits = { orders = { { ordered = 3, delivered = 1, reason = "credits" }, { ordered = 1, delivered = 1 } } }
    local key, args = Story.fillNoteKey(record, credits)
    truthy(key == "IGUI_OA_Story_Fill_partial_1" or key == "IGUI_OA_Story_Fill_partial_2", key)
    eq(args[2], 2, "orders loaded")
    eq(args[3], 2, "of orders")
    TEST.hours = 1000
    local limit = { orders = { { ordered = 3, delivered = 1, reason = "limit" } } }
    eq(Story.fillNoteKey(record, limit), "IGUI_OA_Story_Fill_partial_3")
    TEST.hours = 2000
    local other = { orders = { { ordered = 3, delivered = 0, reason = "unavailable" } } }
    eq(Story.fillNoteKey(record, other), "IGUI_OA_Story_Fill_partial_4")
    -- The first serum has the remark that was waiting for one; after it a bundle of its own, resting long.
    TEST.hours = 3000
    local serum = { cargo = { { type = "OperationAcorn.UpgradeSerum", count = 1 } } }
    eq(Story.fillNoteKey(record, serum), "IGUI_OA_Story_Note_serum")
    TEST.hours = 3100
    truthy(string.find(Story.fillNoteKey(record, serum), "Fill_serum_", 1, true))
    TEST.hours = 3200
    truthy(string.find(Story.fillNoteKey(record, serum), "Fill_s3_", 1, true), "the serum bundle rests: the stage's goes")
    -- A new region's first sample.
    TEST.hours = 4000
    local region = { lines = { { marks = { newRegion = true } } } }
    eq(Story.fillNoteKey(record, region), "IGUI_OA_Story_Note_region")
    TEST.hours = 4100
    truthy(string.find(Story.fillNoteKey(record, region), "Fill_s3_", 1, true), "said once")
end)

test("the filler remark is nothing in a language that has no lines for the bundle", function()
    fillLanguage({})
    local record = setup(2)
    eq(Story.fillNoteKey(record, {}), nil)
end)

-- Documents: the numbers they were read with, the copies that come back, the stake record ----------------------------

test("a document is kept with the number it was read with", function()
    local record = setup(1)
    Story.markRead(record, "soil_slip", nil, 412)
    Story.markRead(record, "con_compare", nil, "A-7")
    Story.markRead(record, "con_stake", nil, { 1 })
    Story.markRead(record, "clinic_log", "westpoint_clinic")
    local byId = {}
    for _, d in ipairs(Story.readDocuments(record)) do byId[d.id] = d end
    eq(byId.soil_slip.extra, 412)
    eq(byId.con_compare.extra, "A-7")
    eq(byId.con_stake.extra, nil, "only a number or a short text")
    eq(byId.clinic_log.extra, nil)
    eq(byId.clinic_log.variant, "westpoint_clinic")
end)

test("the delivered papers come back as copies, the ones already read stay as read", function()
    local record = setup(2)
    Story.markRead(record, "police_card", "muldraugh_pd")
    Story.returnCopies(record, {
        { id = "police_card", variant = "westpoint_pd" },
        { id = "soil_slip", extra = 412 },
        { id = "note_3" },
    })
    local s = Story.section(record)
    eq(s.docs.police_card, "muldraugh_pd", "the read one keeps its place")
    eq(s.copies.police_card, nil)
    eq(s.copies.soil_slip, true)
    eq(s.copies.note_3, true)
    truthy(s.unread["d:soil_slip"], "new until it is opened")
    eq(s.unread["d:police_card"], nil)
    eq(s.docExtra.soil_slip, 412)
    eq(s.docStage.soil_slip, 2)
    Story.returnCopies(record, nil)
end)

test("a stake read is kept with its date, once, and the record lists them by number", function()
    local record = setup(1)
    truthy(Story.noteStake(record, 412, 3))
    eq(Story.noteStake(record, 412, 3), false)
    truthy(Story.noteStake(record, 87, 6))
    eq(Story.noteStake(record, "x", 1), false)
    local log = Story.stakeLog(record)
    eq(#log, 2)
    eq(log[1].stake, 87)
    eq(log[1].date, 6)
    eq(log[2].stake, 412)
    Story.section(record).sitesSearched[999] = true
    eq(#Story.stakeLog(record), 2, "an old yes without a date is not a line")
end)

test("the correction is the crate after the first reply, then the evidence reply", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    Story.onStage(record)
    Story.section(record).done.evidence = "done"
    local docs = {}
    for _ = 1, 4 do
        local spec = Story.takePaper(record)
        docs[#docs + 1] = spec and spec.mod.OA_Doc or "-"
    end
    eq(table.concat(docs, ","), "reply_first,reply_correction,reply_evidence,-", "one a crate, the radio's 'next drop' holds")
end)
