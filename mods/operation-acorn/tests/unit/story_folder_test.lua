-- The terminal's document folder and the missions tab's data (DESIGN-terminal 6.4, 11.1): the groups and their order,
-- the same-title split, what is new and the tab's dot, the request copies, the manifest numbers (the folder once showed
-- one number three times), and what a mission card is made of.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Heli"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Folder"
local OA = OperationAcorn
local Story, Data, Docs, Folder, Missions, Terminal = OA.Story, OA.StoryData, OA.StoryDocs, OA.StoryFolder, OA.Missions, OA.Terminal

-- The Korean texts as the game would give them (the stub gives the key), with %1 .. %9 filled in. A test compares with
-- texts made from the same keys, not with Hangul literals: the test VM keeps only the low byte of each literal's letters.
local function korean()
    local map = {}
    local text = readfile("OperationAcorn/42/media/lua/shared/Translate/KO/IG_UI.json") or ""
    for line in string.gmatch(text, "[^\n]+") do
        local k, v = string.match(line, '^%s*"([^"]+)":%s*"(.*)",?%s*$')
        if k then
            v = string.gsub(v, "\\(.)", function(c) if c == "n" then return "\n" end return c end)
            map[k] = v
        end
    end
    getText = function(key, ...)
        local v = map[key]
        if not v then return key end
        local args = { ... }
        v = string.gsub(v, "%%%%", "\1")
        v = string.gsub(v, "%%(%d)", function(n)
            local a = args[tonumber(n)]
            if a == nil then return "" end
            return tostring(a)
        end)
        return (string.gsub(v, "\1", function() return "%" end))
    end
end

local function T(...) return getText(...) end

local function setup(stage, milestones)
    local record = OA.Store.ensure("p1", "P")
    record.number = 347
    record.trade = { stage = stage or 0, milestones = milestones or 0, credits = 0, trust = 0 }
    OA.Trade = OA.Trade or {}
    OA.Trade.addToDrop = function() end
    return record
end

local function titles(group)
    local list = {}
    for _, entry in ipairs(group.entries) do list[#list + 1] = entry.title end
    return list
end

local function groupOf(groups, id)
    for _, group in ipairs(groups) do
        if group.id == id then return group end
    end
    return nil
end

local function keysOf(groups)
    local list = {}
    for _, entry in ipairs(Folder.flat(groups)) do list[#list + 1] = entry.key end
    return list
end

-- The groups and their order -------------------------------------------------------------------------------------

test("an empty folder has no groups", function()
    local record = setup(0)
    eq(#Folder.entries(record), 0)
    eq(Folder.unreadCount(record), 0)
end)

test("the groups come in the list's order, the newest of each on top", function()
    korean()
    local record = setup(3)
    Story.onStage(record)
    Story.firstContact(record, false)
    for _, id in ipairs({ "police_card", "clinic_log", "reply_first", "serum_sheet", "note_3" }) do Story.markRead(record, id) end
    Story.addManifest(record, 1, "one")
    Story.addManifest(record, 2, "two")
    Story.addRequestCopy(record, "exchange")
    local groups = Folder.entries(record)
    local ids = {}
    for _, group in ipairs(groups) do ids[#ids + 1] = group.id end
    eq(table.concat(ids, ","), "request,research,field,manifest")
    eq(table.concat(titles(groupOf(groups, "research")), "|"),
        T("IGUI_OA_Story_DocTitle_reply_first") .. "|" .. T("IGUI_OA_Story_DocTitle_serum_sheet"), "story order, newest on top")
    eq(table.concat(titles(groupOf(groups, "field")), "|"),
        T("IGUI_OA_Story_DocTitle_clinic_log") .. "|" .. T("IGUI_OA_Story_DocTitle_police_card") .. "|" .. T("IGUI_OA_Story_DocTitle_note_3"),
        "the papers of missions, the field notes after them")
    eq(table.concat(titles(groupOf(groups, "manifest")), "|"),
        T("IGUI_OA_Story_UI_ManifestTitle", 2) .. "|" .. T("IGUI_OA_Story_UI_ManifestTitle", 1))
    eq(groupOf(groups, "request").entries[1].title, T("IGUI_OA_Story_Request_Title", "0117"))
    truthy(string.find(groupOf(groups, "request").entries[1].title, "R-0117", 1, true))
end)

test("a title that two papers share is split with (1) and (2) in the order they were received", function()
    korean()
    local record = setup(3)
    -- the 2nd stage's first analysis reply and the 3rd stage's reply carry the same title
    Story.markRead(record, "reply_relapse")
    Story.markRead(record, "reply_first")
    Story.markRead(record, "reply_nomatch")
    local research = groupOf(Folder.entries(record), "research")
    local plain = T("IGUI_OA_Story_DocTitle_reply_first")
    eq(plain, T("IGUI_OA_Story_DocTitle_reply_relapse"), "the two share a title")
    eq(table.concat(titles(research), "|"),
        plain .. " (2)|" .. T("IGUI_OA_Story_DocTitle_reply_nomatch") .. "|" .. plain .. " (1)")
    local first = research.entries[3]
    eq(first.ref.id, "reply_first")
    eq(first.same, 1)
    eq(research.entries[1].same, 2)
    eq(research.entries[2].same, nil, "a title of its own is left as it is")
end)

test("a paper's tier is the stage that sends it or starts its mission, else the one it was read at", function()
    local record = setup(2)
    eq(Folder.docTier(record, "reply_relapse"), 3)
    eq(Folder.docTier(record, "police_card"), 1)
    eq(Folder.docTier(record, "ward_record"), Data.LAST_STAGE + 1)
    eq(Folder.docTier(record, "note_5"), nil)
    Story.markRead(record, "note_5")
    eq(Folder.docTier(record, "note_5"), 2, "the tier it was read at")
    eq(Folder.tierLabel(1), "IGUI_OA_Story_Copy_Stage 1")
    eq(Folder.tierLabel(3), "IGUI_OA_Story_Copy_Stage 3")
    eq(Folder.tierLabel(nil), "")
end)

test("the manifests are listed by their serial with the tier they came at", function()
    local record = setup(2)
    Story.addManifest(record, 7, "seven")
    Story.addManifest(record, 9, "nine")
    Story.addManifest(record, 8, "eight")
    local entries = groupOf(Folder.entries(record), "manifest").entries
    eq(entries[1].ref.manifest.serial, 9)
    eq(entries[3].ref.manifest.serial, 7)
    eq(entries[1].tier, 2)
    eq(Folder.content(record, entries[1]).body, "nine")
end)

test("what an entry says: its title, a line about it, its text", function()
    korean()
    local record = setup(2)
    Story.onStage(record)
    Story.markRead(record, "reply_first")
    Story.markRead(record, "reply_relapse")
    local groups = Folder.entries(record)
    local reply = Folder.content(record, groupOf(groups, "research").entries[2])
    eq(reply.title, T("IGUI_OA_Story_DocTitle_reply_first") .. " (1)")
    local dot = T("IGUI_OA_Story_UI_Dot")
    eq(reply.meta, T("IGUI_OA_Story_Copy_StageNamed", 2, T("IGUI_OA_Econ_Stage_2")) .. dot .. T("IGUI_OA_Story_Meta_supply")
        .. dot .. T("IGUI_OA_Story_Meta_Same", 1))
    truthy(string.find(reply.body, "0347", 1, true), "the number goes in")
    truthy(string.find(reply.body, "\n", 1, true), "real line ends")
    eq(reply.kind, "document", "the research group's papers are documents (typed only if new: a supply paper never is)")
    eq(Story.typedState(record, "d:reply_first"), nil)
end)

-- What is new -----------------------------------------------------------------------------------------------------

test("the same arrival is new once, and the numbers rise", function()
    local record = setup(1)
    truthy(Story.markNew(record, "c:a"))
    eq(Story.markNew(record, "c:a"), false)
    Story.markNew(record, "c:b")
    truthy(record.story.unread["c:b"] > record.story.unread["c:a"])
end)

test("a guide document handed to the folder is there at once, new until opened, the newest first", function()
    korean()
    local record = setup(2)
    Docs.addGuide("guide_one")
    Docs.addGuide("guide_two")
    eq(Docs.kind("guide_one"), "guide")
    eq(Folder.newGuide(record), nil)
    truthy(Story.deliverDocument(record, "guide_one"))
    eq(Story.deliverDocument(record, "guide_one"), false, "not twice")
    Story.deliverDocument(record, "guide_two")
    eq(Folder.unreadCount(record), 2)
    local newest = Folder.newGuide(record)
    eq(newest.id, "guide_two")
    eq(newest.key, "d:guide_two")
    local research = groupOf(Folder.entries(record), "research")
    eq(#research.entries, 2)
    Story.clearNew(record, "d:guide_two")
    eq(Folder.newGuide(record).id, "guide_one")
    Story.clearNew(record, "d:guide_one")
    eq(Folder.newGuide(record), nil)
end)

test("a paper read from an item is not new", function()
    local record = setup(2)
    Story.markRead(record, "police_card")
    eq(Folder.unreadCount(record), 0)
end)

test("the missions tab's dot: a mission not seen yet (what is new in the folder is the comms tab's)", function()
    local record = setup(1)
    eq(Folder.missionMark(record), nil)
    local s = Missions.state(record)
    s.active = { id = "M347-3", seq = 3, kind = "regular", title = "MissionEnvelope", state = "open", deadline = 100, items = {} }
    eq(Folder.missionSeq(record), 3)
    eq(Folder.missionMark(record), "new", "a mission nobody has looked at")
    local key, value = Folder.seen(record)
    eq(key, "mission")
    eq(value, 3)
    truthy(Terminal.setSeen(record, key, value))
    eq(Folder.missionMark(record), nil)
    eq(Folder.seen(record), nil)
    -- the next mission has a higher number
    s.active = { id = "M347-4", seq = 4, kind = "regular", title = "MissionTape", state = "open", deadline = 100, items = {} }
    eq(Folder.missionMark(record), "new")
    Terminal.setSeen(record, "mission", 4)
    eq(Folder.missionMark(record), nil)
    -- a paper in the folder is the folder's news, not the mission's
    Story.markNew(record, "c:s1")
    eq(Folder.missionMark(record), nil)
    eq(Folder.unreadCount(record), 1)
    Story.clearNew(record, "c:s1")
    eq(Folder.unreadCount(record), 0)
    s.active = nil
    eq(Folder.missionSeq(record), 0)
end)

test("a guide document is on the helicopter card and new in the folder; reading it puts both out", function()
    korean()
    local record = setup(2)
    Docs.addGuide("guide_one")
    truthy(Story.deliverDocument(record, "guide_one"))
    eq(Folder.unreadCount(record), 1, "it is new in the folder")
    eq(Folder.newGuide(record).key, "d:guide_one", "the card has it")
    Story.clearNew(record, "d:guide_one")
    eq(Folder.newGuide(record), nil, "read: the card goes")
    eq(Folder.unreadCount(record), 0, "and the folder's news (the comms tab's dot)")
end)

test("a mission not looked at yet is one rule for the dot and what is seen", function()
    local record = setup(1)
    eq(Folder.freshMission(record), false)
    Missions.state(record).active = { id = "M347-3", seq = 3, kind = "regular", title = "MissionEnvelope", state = "open", deadline = 100, items = {} }
    eq(Folder.freshMission(record), true)
    local key, value = Folder.seen(record)
    eq(key, "mission"); eq(value, 3)
    Terminal.setSeen(record, "mission", 3)
    eq(Folder.freshMission(record), false)
    eq(Folder.missionMark(record), nil)
end)

test("the opened entry's server command clears it", function()
    local ok = pcall(require, "OperationAcorn/Story/Init")
    if not ok then return end
    local record = setup(1)
    Story.markNew(record, "c:s1")
    local character = { getUsername = function() return "P" end }
    sendClientCommand(character, OA.MOD, "story_seen", { id = "p1", key = "c:s1" })
    eq(Folder.unreadCount(record), 0)
    Story.markNew(record, "d:police_card")
    sendClientCommand(character, OA.MOD, "story_read", { id = "p1", doc = "police_card", variant = "muldraugh_pd" })
    eq(Folder.unreadCount(record), 0, "a paper read from its item is cleared too")
end)

-- The request copies --------------------------------------------------------------------------------------------

test("a request copy is numbered from R-0117, one more each, with its text sent once", function()
    korean()
    local record = setup(3)
    getGameTime = function()
        return { getDay = function() return 23 end, getMonth = function() return 8 end }
    end
    local first = Story.addRequestCopy(record, "exchange")
    eq(first.no, 117)
    eq(first.id, "dunnigan_can")
    eq(first.day, 24)
    eq(first.month, 9)
    eq(first.tier, 3)
    truthy(record.story.unread["r:117"], "new")
    local entry = groupOf(Folder.entries(record), "request").entries[1]
    eq(entry.key, "r:117")
    local content = Folder.content(record, entry)
    eq(content.title, T("IGUI_OA_Story_Request_Title", "0117"))
    local lines = {}
    for line in string.gmatch(content.body .. "\n", "(.-)\n") do lines[#lines + 1] = line end
    eq(#lines, 6)
    eq(lines[1], T("IGUI_OA_Story_Request_Head", "0117"))
    truthy(string.find(lines[1], "AC-0041 ", 1, true) == nil and string.find(lines[1], "R-0117", 1, true))
    eq(table.concat({ lines[2], lines[3], lines[4], lines[5] }, string.char(10)), T("IGUI_OA_Story_Request_dunnigan_can"))
    eq(lines[6], T("IGUI_OA_Story_Request_Approval_a", "24 SEP"))
    truthy(string.find(lines[6], "ORDWAY, LTC.  24 SEP   ", 1, true), "Ordway's approval with the date in military form")
    eq(Story.addRequestCopy(record, "exchange").id, "ashdown_cold", "the form's next text")
    eq(Story.addRequestCopy(record, "exchange"), nil, "every text of the form has been sent")
    eq(Story.addRequestCopy(record, "nonsense"), nil)
    eq(record.story.requestNo, 118, "no number is used by a copy not made")
end)

test("a request copy goes by the text the request is for, then by the form's next", function()
    local record = setup(3)
    eq(Story.addRequestCopy(record, "fetch", "dunnigan_filters").id, "dunnigan_filters")
    eq(Story.addRequestCopy(record, "fetch", "dunnigan_filters").id, "kiesling_stock", "the preferred one is used")
    eq(Story.addRequestCopy(record, "field", "no_such_text").id, "branscomb_test", "an unknown one: the form's next")
    for form, ids in pairs(Data.REQUESTS) do
        truthy(#ids >= 1 and #ids <= 3, form .. " has one to three texts")
    end
end)

test("a request copy from the 4th tier on is approved by the deputy", function()
    korean()
    local record = setup(4)
    getGameTime = function() return {} end
    local req = Story.addRequestCopy(record, "exchange")
    eq(req.day, nil, "no calendar, no date")
    local body = Folder.requestBody(req)
    truthy(string.find(body, T("IGUI_OA_Story_Request_Approval_b", ""), 1, true))
    eq(string.find(body, "ORDWAY", 1, true), nil)
end)

test("the next request copy is numbered after the last one, per record", function()
    local a = setup(2)
    local b = OA.Store.ensure("p2", "Q")
    b.trade = { stage = 2, milestones = 0, credits = 0, trust = 0 }
    Data.REQUESTS.exchange = { "dunnigan_can", "second" }
    eq(Story.addRequestCopy(a, "exchange").no, 117)
    eq(Story.addRequestCopy(a, "exchange").no, 118)
    eq(Story.addRequestCopy(b, "exchange").no, 117, "each record counts its own")
end)

-- The manifest numbers ---------------------------------------------------------------------------------------------

test("the same serial is kept once: it replaces its entry", function()
    local record = setup(1)
    Story.addManifest(record, 1042, "first run")
    Story.addManifest(record, 1042, "second run")
    Story.addManifest(record, 1042, "third run")
    local list = record.story.manifests
    eq(#list, 1)
    eq(list[1].text, "third run")
end)

test("each helicopter arrival keeps one manifest, numbered by the ledger and none twice", function()
    korean()
    local record = setup(1)
    local Heli = OA.Trade.Heli
    local real = { deliver = Heli.deliver, refresh = Heli.refreshBoxes }
    Heli.deliver, Heli.refreshBoxes = function() end, function() end
    record.trade.credits = 500
    for _ = 1, 3 do
        OA.Trade.heli(record).call = { at = 0, arrive = 1, kind = "normal", orders = {} }
        truthy(Heli.arrive(record))
    end
    Heli.deliver, Heli.refreshBoxes = real.deliver, real.refresh
    -- The numbers are a middle one and two steps on (1 to 5 each), the ledger's, each once.
    local one = OA.Trade.Ledger.serialAfter(record, nil)
    local two = OA.Trade.Ledger.serialAfter(record, one)
    local three = OA.Trade.Ledger.serialAfter(record, two)
    eq(record.trade.serial, three)
    local serials = {}
    for _, mf in ipairs(record.story.manifests) do serials[#serials + 1] = mf.serial end
    eq(table.concat(serials, ","), one .. "," .. two .. "," .. three)
    local entries = groupOf(Folder.entries(record), "manifest").entries
    eq(table.concat(titles(groupOf(Folder.entries(record), "manifest")), "|"),
        T("IGUI_OA_Story_UI_ManifestTitle", three) .. "|" .. T("IGUI_OA_Story_UI_ManifestTitle", two) .. "|" .. T("IGUI_OA_Story_UI_ManifestTitle", one))
    eq(#entries, 3)
end)

-- The mission card ------------------------------------------------------------------------------------------------

test("what the card shows of a mission: its number, what its reward is made of, the swap offer", function()
    local record = setup(3)
    local s = Missions.state(record)
    s.active = { id = "M347-5", seq = 5, kind = "regular", title = "MissionFilterCase", state = "open", deadline = 130, level = 3,
        credits = 45500, trust = 200, base = 35000, danger = 0.15, streak = 3, urgent = true,
        area = { x = 100, y = 200, r = 80 }, items = { { type = "OperationAcorn.MissionFilterCase" } } }
    TEST.hours = 100
    local info = Missions.describe(record)
    eq(info.seq, 5)
    eq(info.base, 35000)
    eq(info.danger, 0.15)
    eq(info.streak, 3)
    eq(info.urgent, true)
    eq(info.credits, 45500)
    eq(info.left, 30)
    eq(info.item, "MissionFilterCase")
    eq(info.reroll.trust, 20, "a tenth of the level's trust")
    eq(info.reroll.left, 1)
    eq(info.special, nil, "no field line, no special request")
end)

test("the streak bonus is a tenth a mission, at most three tenths", function()
    local Rewards = OA.Rewards
    near(Rewards.streakBonus(0), 0, 1e-9)
    near(Rewards.streakBonus(2), 0.2, 1e-9)
    near(Rewards.streakBonus(3), 0.3, 1e-9)
    near(Rewards.streakBonus(9), 0.3, 1e-9)
    near(Rewards.streakBonus(nil), 0, 1e-9)
end)

test("a new record's folder fields are made with its story section", function()
    local record = setup(0)
    local s = Story.section(record)
    eq(type(s.unread), "table")
    eq(s.newSeq, 0)
    eq(s.requestNo, Data.REQUEST_FIRST - 1)
end)

-- The folder after the story improvements: the numbers a document was read with, the copies, the stake record -----------

test("a document read with a number is shown with it again, not as the plain one", function()
    korean()
    local record = setup(5, 1)
    Story.markRead(record, "soil_slip", nil, 412)
    local entry = groupOf(Folder.entries(record), "field").entries[1]
    eq(entry.ref.extra, 412)
    local body = Folder.content(record, entry).body
    truthy(string.find(body, "412", 1, true), "the stake number is on the slip")
    truthy(not string.find(body, T("IGUI_OA_Story_Doc_soil_slip_plain"), 1, true))
end)

test("a delivered paper's copy says where it came from", function()
    korean()
    local record = setup(2)
    Story.markRead(record, "police_card", "muldraugh_pd")
    Story.returnCopies(record, { { id = "police_card" }, { id = "clinic_log", variant = "westpoint_clinic" } })
    local metas = {}
    for _, entry in ipairs(groupOf(Folder.entries(record), "field").entries) do
        metas[entry.key] = Folder.content(record, entry).meta
    end
    truthy(string.find(metas["d:clinic_log"], T("IGUI_OA_Story_Meta_copy"), 1, true))
    truthy(string.find(metas["d:police_card"], T("IGUI_OA_Story_Meta_found"), 1, true), "the one read on the spot says so")
    eq(Folder.unreadCount(record), 1, "the copy is new, the read paper is not")
end)

test("the stakes read are one record in the field papers, a line each with the date on the stake", function()
    korean()
    local record = setup(2)
    eq(groupOf(Folder.entries(record), "field"), nil)
    Story.noteStake(record, 412, 3)
    Story.noteStake(record, 87, 6)
    local entries = groupOf(Folder.entries(record), "field").entries
    eq(#entries, 1)
    eq(entries[1].title, T("IGUI_OA_Story_DocTitle_stake_log"))
    eq(entries[1].key, "d:stake_log")
    local content = Folder.content(record, entries[1])
    eq(content.meta, T("IGUI_OA_Story_Meta_stakes"))
    eq(content.body, T("IGUI_OA_Story_StakeLog_Line", "87", T("IGUI_OA_Story_StakeDate_6")) .. "\n"
        .. T("IGUI_OA_Story_StakeLog_Line", "412", T("IGUI_OA_Story_StakeDate_3")))
    Story.markRead(record, "clinic_log")
    eq(#groupOf(Folder.entries(record), "field").entries, 2, "among the other field papers")
    -- once the first analysis reply came, the date it puts the fall on heads the record; then its correction
    local lines = T("IGUI_OA_Story_StakeLog_Line", "87", T("IGUI_OA_Story_StakeDate_6")) .. "\n"
        .. T("IGUI_OA_Story_StakeLog_Line", "412", T("IGUI_OA_Story_StakeDate_3"))
    Story.section(record).sent.reply_first = true
    eq(Folder.content(record, entries[1]).body, T("IGUI_OA_Story_StakeLog_Base") .. "\n\n" .. lines)
    Story.section(record).sent.reply_correction = true
    eq(Folder.content(record, entries[1]).body, T("IGUI_OA_Story_StakeLog_BaseFixed") .. "\n\n" .. lines)
end)

test("a manifest with the story's remark stays in the folder after the usual few have gone", function()
    korean()
    local record = setup(1)
    Story.addManifest(record, 100, "remarked", true)
    for i = 1, Data.MANIFESTS_KEPT + 2 do Story.addManifest(record, 100 + i, "plain", false) end
    local entries = groupOf(Folder.entries(record), "manifest").entries
    eq(#entries, Data.MANIFESTS_KEPT + 1)
    eq(entries[#entries].key, "m:100")
end)

-- A crate from the first stage to the next: the paper, what the remark encloses, the manifest kept -------------------------

test("a crate carries one paper and what its remark encloses; the manifest with the story's remark is kept", function()
    korean()
    local loaded, err = pcall(require, "OperationAcorn/Story/Init")
    if not loaded then error("the story server part does not load: " .. tostring(err)) end
    TEST.fire("EveryTenMinutes")  -- the story subscribes to the trade part
    local record = setup(1)
    Story.onStage(record)
    local Heli = OA.Trade.Heli
    local plans = {}
    local real = { deliver = Heli.deliver, refresh = Heli.refreshBoxes }
    Heli.deliver, Heli.refreshBoxes = function() end, function() end
    record.trade.credits = 500
    local function arrive()
        local box = OA.Trade.Boxes.add(record, { x = 10, y = 0, z = 0, active = true })
        OA.Trade.Boxes.seal(record, box.id, { { info = { fullType = "Base.Rag" }, count = 1 } })
        OA.Trade.heli(record).call = { at = 0, arrive = 1, kind = "normal", orders = {} }
        local plan = Heli.arrive(record)
        plans[#plans + 1] = plan
        return plan
    end
    local first = arrive()
    local types = {}
    for _, spec in ipairs(first.cargo) do types[spec.type] = spec end
    truthy(types["OperationAcorn.SerumSheet"], "the serum sheet is the paper of this crate")
    eq(types["OperationAcorn.SerumSheet"].mod.OA_Doc, "serum_sheet")
    truthy(types["Base.Battery"], "the remark says two batteries are enclosed")
    eq(types["Base.Battery"].count, 2)
    eq(first.receipt.note.key, "IGUI_OA_Story_Note_battery")
    eq(first.receipt.bonusNote, nil)
    local second = arrive()
    for _, spec in ipairs(second.cargo) do
        eq(spec.type ~= "OperationAcorn.SerumSheet", true, "the paper went once")
    end
    eq(second.receipt.note.key, "IGUI_OA_Story_Note_appendix_missing")
    Heli.deliver, Heli.refreshBoxes = real.deliver, real.refresh
    local kept = 0
    for _, mf in ipairs(record.story.manifests) do if mf.keep then kept = kept + 1 end end
    eq(kept, 2, "both manifests carry a remark of the story's own")
    truthy(first.receipt.id > 0 and second.receipt.id > first.receipt.id and second.receipt.id <= first.receipt.id + 5)
end)
