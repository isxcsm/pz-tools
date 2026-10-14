-- The story: what each stage and milestone tells and sends, the order of the manifest notes, the radio copies and
-- greeting, the documents the player has read, the handover. The record's `story` section holds only ids and counters (DESIGN 12);
-- all text is in the translation files (IGUI_OA_Story_*). The missions (Story/Missions) ask this for what to start.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Say"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Markup"
require "PZUIKit/Typing"
local OA = OperationAcorn
local Data = OA.StoryData
local Story = {}
OA.Story = Story


-- Text by key and arguments (a function, so that tests can see the keys).
function Story.text(key, ...)
    return getText(key, ...)
end

-- The player's `story` section, with its fields made.
function Story.section(record)
    local s = OA.Store.section(record, "story")
    if not s.version then
        s.version = 1
        s.seenStage = 0
        s.seenMilestones = 0
        s.handover = false
        s.docs = {}          -- read documents: id -> true (or the place variant it was read at)
        s.queue = {}         -- story missions waiting: { id =, fresh =, option = }
        s.missed = {}        -- a save from before: story ids missed, kept for the next stage (see requeueMissed)
        s.done = {}          -- story id -> "done" | "missed" ("closed" in a save from before)
        s.chosen = {}        -- the choice missions: story id -> option
        s.supply = {}        -- sent to the next supply crate, not yet taken by the trade part: { type =, doc = }
        s.noteQueue = {}     -- manifest notes that come before the order: ids
        s.noteIndex = {}     -- pool key -> notes used
        s.radioIndex = 0     -- after the handover: the frequency's lines used
        s.radioDay = -100    -- the day the latest of them went on the air
        s.hallucinations = 0
        s.strangeWeek = nil  -- the week the strange request item is for
        s.sitesSeen = {}     -- drop sites the player has been near: site number -> true
        s.sitesSearched = {} -- stake numbers read
        s.manifests = {}     -- the latest manifests, { serial =, text =, tier = }
        s.regularsSince = 0
        s.unread = {}        -- what arrived in the folder and is not opened yet: key -> arrival number (Story.markNew)
        s.newSeq = 0         -- the arrivals counted
        s.docStage = {}      -- the trust tier a document was read at: id -> tier (for the ones the data cannot place)
        s.typed = {}         -- how far the terminal's folder has shown each text: key -> state (Story.markNew, Typing)
        s.requests = {}      -- request copies kept (Story.addRequestCopy): { no =, form =, id =, tier =, day =, month = }
        s.requestNo = Data.REQUEST_FIRST - 1
    end
    -- Fields added later (a record made before has none).
    s.papers = s.papers or {}       -- the 2반 papers waiting for a crate: { type =, doc =, when =, first = }
    s.sent = s.sent or {}           -- the papers that have gone in a crate: document id -> true
    s.copies = s.copies or {}       -- documents that came back as copies of what was delivered: id -> true
    s.docExtra = s.docExtra or {}   -- the number a read document was read with (a stake, a serial): id -> value
    s.noted = s.noted or {}         -- one-off remarks said: "serum", "region"
    return s
end

local function trade(record)
    return OA.Store.section(record, "trade")
end

-- The trust stage (0 to 5) and milestones passed of a record.
function Story.progress(record)
    local t = record.trade or {}
    return t.stage or 0, t.milestones or 0
end

function Story.number(record)
    return string.format("%04d", record.number or 0)
end

-- Has the 3rd milestone's handover happened.
function Story.handedOver(record)
    return Story.section(record).handover == true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talking to the trade part (it may not be there yet: every call checks).

-- Documents and items for the next supply crate. The trade part takes them with OA.Trade.addToDrop; when it is not
-- there (or not yet) they wait in the record.
function Story.queueSupply(record, itemName, doc)
    local s = Story.section(record)
    s.supply[#s.supply + 1] = { type = itemName, doc = doc }
    Story.flushSupply(record)
end

-- Hands the waiting supply to the trade part. Items go as tables { type = full type, mod = {...} } (the trade part
-- accepts those or plain full type names).
function Story.flushSupply(record)
    local s = Story.section(record)
    if #s.supply == 0 then return end
    if not (OA.Trade and OA.Trade.addToDrop) then return end
    local items = {}
    for _, entry in ipairs(s.supply) do
        local mods = nil
        if entry.doc then mods = { OA_Doc = entry.doc } end
        items[#items + 1] = { type = Data.fullType(entry.type), count = 1, mod = mods }
    end
    local ok, err = pcall(OA.Trade.addToDrop, record, items)
    if ok then
        s.supply = {}
    else
        OA.log("story supply failed:", tostring(err))
    end
end

-- The 2반 papers (replies, appendices, lists) go one to a crate, and only when their time has come (Data.STAGES): they
-- wait here, in the record, and the trade part asks for them as it loads a crate (Trade.addCrateProvider). entry =
-- { item, document, when, first }.
function Story.queuePaper(record, entry)
    local s = Story.section(record)
    local doc = entry[2]
    if s.sent[doc] then return end
    for _, p in ipairs(s.papers) do
        if p.doc == doc then return end
    end
    s.papers[#s.papers + 1] = { type = entry[1], doc = doc, when = entry[3], first = entry[4] or nil }
end

-- Whether a paper's time has come: "done:<story id>" the story mission was delivered, "sent:<document>" that paper has
-- gone, "fragment" a meteorite fragment has been on a receipt. No condition: at once.
function Story.paperReady(record, paper)
    local s = Story.section(record)
    if not paper.when then return true end
    local kind, arg = string.match(paper.when, "^(%a+):?(.*)$")
    if kind == "done" then return s.done[arg] == "done" end
    if kind == "sent" then return s.sent[arg] == true end
    if kind == "fragment" then return s.fragmentSeen == true end
    return true
end

-- The paper for the crate being loaded: the first one that is ready, the ones marked `first` before the others.
-- Takes it out of the queue and notes it as sent (the radio lines that tell of it come into their copy). Returns
-- an item spec, or nil.
function Story.takePaper(record)
    local s = Story.section(record)
    local at
    for i, p in ipairs(s.papers) do
        if p.first and Story.paperReady(record, p) then at = i; break end
    end
    if not at then
        for i, p in ipairs(s.papers) do
            if Story.paperReady(record, p) then at = i; break end
        end
    end
    if not at then return nil end
    local p = table.remove(s.papers, at)
    s.sent[p.doc] = true
    for _, held in pairs(Data.RADIO_AFTER) do
        if held.doc == p.doc then Story.markNew(record, held.copy) end
    end
    OA.Sync.changed("story", record.id)
    return { type = Data.fullType(p.type), count = 1, mod = { OA_Doc = p.doc } }
end

-- What the story puts in a crate (the trade part's crate provider): one paper, when one is ready.
function Story.crateSpecs(record)
    local spec = Story.takePaper(record)
    return spec and { spec } or nil
end

-- The trade part tells the story what a settlement settled: a meteorite fragment on a receipt has reached the
-- research team (its capstone opens: Upgrades.fragmentReceived), and the first one lets the fragment reply go in a
-- later crate.
function Story.onSettled(record, result)
    local s = Story.section(record)
    for _, line in ipairs(result and result.lines or {}) do
        if line.marks and line.marks.fragment then
            s.fragmentSeen = true
            if OA.Upgrades and OA.Upgrades.fragmentReceived then OA.Upgrades.fragmentReceived(record, line.fullType) end
        end
    end
end

-- Adds trust and credits to a record at a settlement (or a field trade). The trade part's own function does the
-- debt and the stage-up handling when it has one.
function Story.addTrust(record, trust)
    if trust <= 0 then return end
    if OA.Trade and OA.Trade.addTrust then
        OA.Trade.addTrust(record, trust, "mission")
    elseif OA.Trust and OA.Trust.add then
        OA.Trust.add(record, trust)
    else
        local t = trade(record)
        t.trust = (t.trust or 0) + trust
    end
end

-- Takes trust away (taking another mission costs some): never below where the stage or milestone the record is at
-- begins, so that a level once reached stays. Returns what was taken.
function Story.loseTrust(record, trust)
    if not trust or trust <= 0 then return 0 end
    local t = trade(record)
    local floor = 0
    if OA.Trust and OA.Trust.progress then floor = OA.Trust.progress(record).from or 0 end
    local before = t.trust or 0
    t.trust = math.max(math.min(before, floor), before - trust)
    return before - t.trust
end

function Story.addCredits(record, credits)
    if credits == 0 then return end
    local t = trade(record)
    t.credits = (t.credits or 0) + credits
end

-- ---------------------------------------------------------------------------------------------------------------
-- Stages.

-- Queues a story mission for the next mission slot. `fresh` ones come before anything else (a stage just entered);
-- the others wait for a regular mission between.
function Story.queueStory(record, id, fresh, option)
    local s = Story.section(record)
    if s.done[id] == "done" or s.done[id] == "closed" then return end
    for _, q in ipairs(s.queue) do
        if q.id == id then return end
    end
    if fresh then
        table.insert(s.queue, 1, { id = id, fresh = true, option = option })
    else
        s.queue[#s.queue + 1] = { id = id, fresh = false, option = option }
    end
end

-- A save from before missed missions were queued again at once: the ones it kept for the next stage, and the optional
-- ones it closed for good, come back after the new stage's own.
local function requeueMissed(record)
    local s = Story.section(record)
    for _, id in ipairs(s.missed) do
        Story.queueStory(record, id, false)
    end
    s.missed = {}
    for id, state in pairs(s.done) do
        local def = Data.STORIES[id] or Data.REVISITS[id]
        if state == "closed" and def and def.optional then
            s.done[id] = "missed"
            Story.queueStory(record, id, false)
        end
    end
end

local function enterEvents(record, def)
    for _, id in ipairs(def.stories or {}) do Story.queueStory(record, id, true) end
    for _, entry in ipairs(def.supply or {}) do Story.queuePaper(record, entry) end
end

function Story.enterStage(record, stage)
    local def = Data.STAGES[stage]
    if not def then return end
    local s = Story.section(record)
    -- A stage's own missions are fresh; two in one stage (the cooler and the optional bunker) keep their order.
    local fresh, rest = {}, {}
    for _, id in ipairs(def.stories or {}) do
        local story = Data.STORIES[id]
        if story and story.optional then rest[#rest + 1] = id else fresh[#fresh + 1] = id end
    end
    for i = #fresh, 1, -1 do Story.queueStory(record, fresh[i], true) end
    for _, id in ipairs(rest) do Story.queueStory(record, id, false) end
    for _, entry in ipairs(def.supply or {}) do Story.queuePaper(record, entry) end
    requeueMissed(record)
    s.noteIndex = s.noteIndex or {}
    if def.radio and #def.radio > 0 then Story.markNew(record, "c:s" .. stage) end
end

function Story.enterMilestone(record, k)
    local def = Data.MILESTONES[k]
    local s = Story.section(record)
    if def then
        enterEvents(record, def)
        if def.radio and #def.radio > 0 then Story.markNew(record, "c:m" .. k) end
        if k == 2 then Story.queueStory(record, "soil", false) end
    else
        -- From the 4th milestone on: one revisit story per milestone, in turn, and a new radio pool.
        local order = Data.REVISIT_ORDER
        local id = order[OA.remainder(k - 4, #order) + 1]
        Story.queueStory(record, id, true)
        Story.resetRadioPool(record)
    end
    requeueMissed(record)
end

-- The trade part calls this when the trust stage has gone up (and for milestones, with the milestone count); the
-- mission tick also calls it when it sees the numbers move, so a missed call costs nothing.
function Story.onStage(record, stage, milestones, announce)
    local s = Story.section(record)
    stage = stage or (record.trade and record.trade.stage) or 0
    milestones = milestones or (record.trade and record.trade.milestones) or 0
    local last
    for st = s.seenStage + 1, stage do
        s.seenStage = st
        Story.enterStage(record, st)
        last = "s" .. st
        OA.log("story: stage", st, "entered by", record.number)
    end
    for k = s.seenMilestones + 1, milestones do
        s.seenMilestones = k
        Story.enterMilestone(record, k)
        last = "m" .. k
        OA.log("story: milestone", k, "reached by", record.number)
    end
    OA.Sync.changed("story", record.id)
    -- The stage title is shown by whoever raised the trust (`announce`); the scene of the last stage entered comes
    -- after it.
    if announce and last then Story.scene(record, last) end
end

-- Missions end: the story hears of it. result: "done" | "expired" | "lost".
function Story.missionEnded(record, m, result)
    local s = Story.section(record)
    if m.story then
        local def = Data.STORIES[m.story] or Data.REVISITS[m.story]
        if result == "done" then
            s.done[m.story] = "done"
        elseif def and not def.handover then
            -- Missed (an optional one too): offered again once a regular mission has come between. Doing it again is
            -- what it costs; a wait for the next stage, or a story part lost for good, would be more.
            s.done[m.story] = "missed"
            Story.queueStory(record, m.story, false)
        end
        s.regularsSince = 0
        if def and def.handover then Story.completeHandover(record) end
    else
        s.regularsSince = (s.regularsSince or 0) + 1
    end
end

-- The next story mission to start: the queue's first fresh one, or the first other one once a regular mission has
-- come between. Removes it. Returns the queue entry or nil.
function Story.nextStory(record)
    local s = Story.section(record)
    for i, q in ipairs(s.queue) do
        if q.fresh or (s.regularsSince or 0) >= 1 then
            table.remove(s.queue, i)
            return q
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- The handover (LORE 5): at the 3rd milestone. The handover mission ends (in any way), then the last crate comes, the
-- call sign changes, the trade goes on.
function Story.completeHandover(record)
    local s = Story.section(record)
    if s.handover then return end
    s.handover = true
    Story.markNew(record, "c:handover")
    s.noteQueue[#s.noteQueue + 1] = "last_b"
    Story.queueSupply(record, "HandoverFile", nil)
    Story.queueSupply(record, "KitVoucher", nil)
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_Handover", sub = "IGUI_OA_Title_HandoverSub",
        subArgs = { { key = Story.callSignKey(record) } }, style = "type" })
    Story.scene(record, "handover")
    OA.log("story: handover for", record.number)
    OA.Sync.changed("story", record.id)
end

-- The call sign the team goes by now, as a translation key.
function Story.callSignKey(record)
    return "IGUI_OA_Story_" .. (Story.handedOver(record) and "CallSign_Handover" or "CallSign_Oak")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Radio and notes.

-- Which greeting the radio opens with, as a translation key: the stage's (1 to 4) or "H" after the handover; nil when
-- there is none (before the first stage, and at the 5th stage).
function Story.greetingKeyFor(stage, handedOver)
    if handedOver then return "IGUI_OA_Story_Greeting_H" end
    if Data.GREETING_STAGES[stage] then return "IGUI_OA_Story_Greeting_" .. tostring(stage) end
    return nil
end

function Story.greetingKey(record)
    return Story.greetingKeyFor((Story.progress(record)), Story.handedOver(record))
end

-- The greeting text with the collection point number ("" when there is none).
function Story.greetingText(record)
    local key = Story.greetingKey(record)
    if not key then return "" end
    return Story.text(key, Story.number(record))
end

-- The first radio line when the terminal is first used, filed as a radio copy: 'late' when the first crate came late
-- or without a helicopter. It is also a scene over the screen, unless `quiet` (a record that is found past the first
-- stage without one).
function Story.firstContact(record, late, quiet)
    local s = Story.section(record)
    if s.firstContact then return false end
    s.firstContact = late and "late" or true
    Story.markNew(record, "c:first")
    OA.Sync.changed("story", record.id)
    if not quiet then Story.scene(record, "first") end
    return true
end

-- The radio copies in the document folder (DESIGN-terminal 11): the first contact, the lines of each stage entered
-- (milestones count on as stages 6, 7 and 8), the handover. Worked out from the story's counters, so nothing is kept
-- for them. { { id, stage (nil for the first contact and the handover), keys = { line ids } } }, oldest first.
-- The lines of a copy that can be shown: the ones that tell of a paper wait until that paper has been sent.
local function shownLines(s, keys)
    local shown = {}
    for _, key in ipairs(keys) do
        local held = Data.RADIO_AFTER[key]
        if not held or s.sent[held.doc] then shown[#shown + 1] = key end
    end
    return shown
end

function Story.radioCopies(record)
    local s = Story.section(record)
    local list = {}
    if s.firstContact then
        list[1] = { id = "first", keys = { s.firstContact == "late" and "first_late" or "first" } }
    end
    for st = 1, s.seenStage or 0 do
        local def = Data.STAGES[st]
        if def and def.radio and #def.radio > 0 then
            list[#list + 1] = { id = "s" .. st, stage = st, keys = shownLines(s, def.radio) }
        end
    end
    for k = 1, s.seenMilestones or 0 do
        local def = Data.MILESTONES[k]
        if def and def.radio and #def.radio > 0 then
            list[#list + 1] = { id = "m" .. k, stage = Data.LAST_STAGE + k, keys = shownLines(s, def.radio) }
        end
    end
    if s.handover then list[#list + 1] = { id = "handover", keys = { Data.HANDOVER_RADIO } } end
    return list
end

-- A trust tier in words (DESIGN-terminal 2.3): the number and the stage's name up to the 5th stage, the handover's
-- name at the 8th, the bare number between.
function Story.tierText(tier)
    if tier <= Data.LAST_STAGE then
        return Story.text("IGUI_OA_Story_Copy_StageNamed", tier, Story.text("IGUI_OA_Econ_Stage_" .. tier))
    end
    if tier == Data.LAST_STAGE + 3 then
        return Story.text("IGUI_OA_Story_Copy_StageNamed", tier, Story.text("IGUI_OA_Terminal_LevelHandover"))
    end
    return Story.text("IGUI_OA_Story_Copy_Stage", tier)
end

-- How wide (ems, Markup.width) the radio line under a stage's title may be: some twenty Hangul syllables.
Story.TITLE_LEAD = 24

-- The title of a trust level reached (what Sync.title takes): "Trust stage 3 · Cross-check" with the stage's name (the
-- first five and the handover's 8th have one, the others only the number), and under it the first line of the radio
-- copy the stage brings (Titles cuts it to its first sentences); the shop's new items where the level has no copy.
function Story.stageTitle(record, level)
    local nameKey
    if level >= 1 and level <= Data.LAST_STAGE then
        nameKey = "IGUI_OA_Econ_Stage_" .. level
    elseif level == Data.LAST_STAGE + 3 then
        nameKey = "IGUI_OA_Terminal_LevelHandover"
    end
    local detail = { key = "IGUI_OA_Title_Stage", args = { level }, sub = "IGUI_OA_Title_NewItems", style = "dust",
        fallback = "good" }
    if nameKey then
        detail.key = "IGUI_OA_Title_StageNamed"
        detail.args = { level, { key = nameKey } }
    end
    local def = level <= Data.LAST_STAGE and Data.STAGES[level] or Data.MILESTONES[level - Data.LAST_STAGE]
    local first = def and def.radio and def.radio[1]
    if first then
        detail.sub = "IGUI_OA_Story_Radio_" .. first
        detail.subArgs = { Story.number(record) }
        detail.subLead = Story.TITLE_LEAD
    end
    return detail
end

-- A radio copy's scene on the player's screen: its lines typed over the game (client/RadioScene.lua), for the first
-- contact, a stage or milestone entered, the handover. The copy is in the folder in any case.
function Story.scene(record, id)
    for _, copy in ipairs(Story.radioCopies(record)) do
        if copy.id == id then
            OA.Sync.scene(record.id, { id = id, keys = copy.keys, number = Story.number(record) })
            return true
        end
    end
    return false
end

-- A radio copy's title and text.
function Story.copyTitle(copy)
    local what
    if copy.stage then
        what = Story.tierText(copy.stage)
    else
        what = Story.text("IGUI_OA_Story_Copy_" .. copy.id)
    end
    return Story.text("IGUI_OA_Story_Copy_Title", what)
end

-- The text of a copy as the radio lines say it, with their markup (pauses) for a place that types it.
function Story.copyMarked(record, copy)
    local number = Story.number(record)
    local lines = {}
    for _, key in ipairs(copy.keys) do lines[#lines + 1] = Story.text("IGUI_OA_Story_Radio_" .. key, number) end
    return table.concat(lines, "\n\n")
end

-- The same plain, for the places that show a copy whole.
function Story.copyText(record, copy)
    return OA.Markup.strip(Story.copyMarked(record, copy))
end

-- The refusal story beats (LORE 7). Returns the radio key for a category that is not taken for a while (`phase`
-- "start") or has come back as a request ("back"), or the general line. The market part (P1) decides which category
-- and when; this only gives the words.
function Story.refusalKey(category, phase)
    local cat = Data.REFUSALS[category] and category or "any"
    return "IGUI_OA_Story_Refuse_" .. cat .. "_" .. (phase == "back" and "back" or "start")
end

-- The big meteorite's receipt line (the economy marks it 'not taken').
Story.BIG_METEORITE_RECEIPT = "IGUI_OA_Story_Receipt_BigMeteorite"
Story.FRAGMENT_RECEIPT = "IGUI_OA_Story_Receipt_Fragment"

-- The pool a record's notes come from: the stage's, or after the handover the milestone's.
local function notePool(record)
    local stage, milestones = Story.progress(record)
    if Story.handedOver(record) then
        local m = math.min(math.max(milestones, 3), Data.AFTER_LAST)
        local pool = Data.AFTER[m]
        local ids = {}
        for i = 1, pool.notes do ids[i] = "after" .. m .. "_" .. i end
        return "after" .. m, ids
    end
    if milestones >= 1 then
        local k = math.min(milestones, 3)
        local def = Data.MILESTONES[k]
        return "m" .. k, def and def.notes or {}
    end
    local def = Data.STAGES[stage]
    return "s" .. stage, def and def.notes or {}
end

-- What a crate shows of the settlement (the trade part's draft): how many order lines there were and how many had
-- something loaded, and the reason the first one that was cut short was cut short ("credits", "limit", "other"; nil
-- when no order was cut short).
local CUT_REASON = { credits = "credits", debt = "credits", limit = "limit" }
local function orderCounts(ctx)
    local total, loaded, cut = 0, 0, nil
    for _, order in ipairs(ctx and ctx.orders or {}) do
        total = total + 1
        if (order.delivered or 0) > 0 then loaded = loaded + 1 end
        if (order.delivered or 0) < (order.ordered or 0) and not cut then cut = CUT_REASON[order.reason] or "other" end
    end
    return total, loaded, cut
end

-- Is the remark true of this crate: some are said only when it bears them out (Data.NOTE_WHEN).
local function noteFits(id, ctx)
    local when = Data.NOTE_WHEN[id]
    if not when then return true end
    if not ctx then return false end
    if when == "gap" then
        return (ctx.lastSerial or 0) > 0 and (ctx.serial or 0) - ctx.lastSerial >= 2
    elseif when == "orders" then
        local _, loaded = orderCounts(ctx)
        return loaded > 0
    end
    return true
end

-- What the remark encloses: { items = { { type, count } } } (Data.NOTE_ITEMS), or nil. The trade part puts them in
-- the crate.
local function noteItems(id)
    local list = Data.NOTE_ITEMS[id]
    if not list then return nil end
    local items = {}
    for i, entry in ipairs(list) do items[i] = { type = entry[1], count = entry[2] } end
    return { items = items }
end

-- A remark's arguments: the collection point number, and the order lines loaded of the lines there were.
local function noteArgs(record, ctx)
    local total, loaded = orderCounts(ctx)
    return { Story.number(record), loaded, total }
end

-- The next manifest note, by the order pool: the special ones first (a receipt remark waiting), then the stage's
-- own lines one per crate. nil when the story has nothing now (the filler lines, Story.fillNoteKey, then the trade
-- part's). `ctx` is the crate (the trade part's draft): a line that needs the crate to bear it out waits for one that
-- does. Returns the text key, its arguments, the note id and what it encloses.
function Story.manifestNoteKey(record, ctx)
    local s = Story.section(record)
    local id = s.noteQueue[1]
    if id then
        table.remove(s.noteQueue, 1)
    else
        local key, ids = notePool(record)
        local used = s.noteIndex[key] or 0
        if used >= #ids then return nil end
        if not noteFits(ids[used + 1], ctx) then return nil end
        s.noteIndex[key] = used + 1
        id = ids[used + 1]
    end
    return "IGUI_OA_Story_Note_" .. id, noteArgs(record, ctx), id, noteItems(id)
end

function Story.manifestNote(record)
    local key, args, id = Story.manifestNoteKey(record)
    if not key then return nil end
    return Story.text(key, args[1]), id
end

-- A remark the next crate's manifest should carry first (a receipt note: the sample case taken back, the cooler's
-- state). `id` is a note id (IGUI_OA_Story_Note_<id>).
function Story.queueNote(record, id)
    local s = Story.section(record)
    s.noteQueue[#s.noteQueue + 1] = id
end

-- The filler remarks (DESIGN-terminal 18, story improvement 9): in the crates the ordered notes leave, Kiesling still
-- has a line now and then, so that the weeks between the story's events are not silent. The stage's own bundle
-- (Fill s1 to s5, m for the milestones, a after the handover), and lines for what the crate is: orders cut short
-- (by the reason), a serum aboard. Each bundle is drawn from in turn (Say) and rests for a while after a line (game
-- hours); the first serum and the first new-region sample have a remark of their own, said once.
local FILL = "IGUI_OA_Story_Fill_"
for stage = 1, Data.LAST_STAGE do OA.Say.define("s" .. stage, { prefix = FILL, cooldown = 72 }) end
OA.Say.define("m", { prefix = FILL, cooldown = 72 })
OA.Say.define("a", { prefix = FILL, cooldown = 72 })
OA.Say.define("partial", { prefix = FILL, cooldown = 144, tags = {
    [1] = { reason = "credits" }, [2] = { reason = "credits" }, [3] = { reason = "limit" }, [4] = { reason = "other" } } })
OA.Say.define("serum", { prefix = FILL, cooldown = 336 })

local function hasSerum(ctx)
    for _, spec in ipairs(ctx and ctx.cargo or {}) do
        if string.find(spec.type or "", "Serum", 1, true) then return true end
    end
    return false
end

local function hasNewRegion(ctx)
    for _, line in ipairs(ctx and ctx.lines or {}) do
        if line.marks and line.marks.newRegion then return true end
    end
    return false
end

-- The filler remark for a crate: the text key and its arguments, or nil (none now, or the language has no lines).
function Story.fillNoteKey(record, ctx)
    local stage, milestones = Story.progress(record)
    if stage < 1 then return nil end
    local s = Story.section(record)
    local say = OA.Store.section(record, "say")
    local args = noteArgs(record, ctx)
    local function line(id, c)
        local key = OA.Say.line(say, id, c)
        if key then return key, args end
        return nil
    end
    if ctx then
        if not s.noted.region and hasNewRegion(ctx) then
            s.noted.region = true
            return "IGUI_OA_Story_Note_region", args
        end
        local serum = hasSerum(ctx)
        if serum and not s.noted.serum then
            s.noted.serum = true
            return "IGUI_OA_Story_Note_serum", args
        end
        local _, _, cut = orderCounts(ctx)
        if cut then
            local key = line("partial", { reason = cut })
            if key then return key, args end
        end
        if serum then
            local key = line("serum")
            if key then return key, args end
        end
    end
    local id = "s" .. math.min(stage, Data.LAST_STAGE)
    if Story.handedOver(record) then id = "a" elseif milestones >= 1 then id = "m" end
    return line(id)
end

-- Does a manifest remark mean the manifest is kept in the folder past the usual few: the story's own ordered notes
-- do, the filler lines do not.
function Story.keepsManifest(key)
    return type(key) == "string" and string.find(key, "^IGUI_OA_Story_Note_") ~= nil
end

-- The old form (from the 4th stage): the manifest keeps its fixed form with a few other column names. The trade part
-- asks with the column's id and the text it would use. Ids: serial, remarks, receivers, dropcheck, signed.
Story.OLD_LABELS = { serial = true, remarks = true, receivers = true, dropcheck = true, signed = true }
function Story.oldForm(record)
    local stage = Story.progress(record)
    return stage >= 4
end

function Story.formLabel(record, id, default)
    if Story.oldForm(record) and Story.OLD_LABELS[id] then
        return Story.text("IGUI_OA_Story_Form_" .. id)
    end
    return default
end

-- Keeps a manifest's text in the document folder (the latest few, and all that carry a remark of the story's own), with the trust tier it came at. The trade part gives
-- the serial and the finished text. A serial is kept once: the same one again replaces its entry (a number seen three
-- times in the folder was an in-game test adding 1042 on every run, not the helicopter: the receipts are numbered by
-- Ledger.add and each arrival keeps one).
function Story.addManifest(record, serial, text, keep)
    local s = Story.section(record)
    local stage, milestones = Story.progress(record)
    local entry = { serial = serial, text = text, tier = stage + milestones, keep = keep or nil }
    for i, mf in ipairs(s.manifests) do
        if mf.serial == serial then
            s.manifests[i] = entry
            return
        end
    end
    s.manifests[#s.manifests + 1] = entry
    -- Only the latest few are kept, but not the ones that carry a remark of the story's own: they stay.
    local plain = 0
    for _, mf in ipairs(s.manifests) do
        if not mf.keep then plain = plain + 1 end
    end
    local i = 1
    while plain > Data.MANIFESTS_KEPT and i <= #s.manifests do
        if s.manifests[i].keep then
            i = i + 1
        else
            table.remove(s.manifests, i)
            plain = plain - 1
        end
    end
end

-- After the handover the team's frequency carries a line of its own now and then: six lines and three questions per
-- milestone pool, in order, one every few days, on the air for that day (Story/Radio). Returns true when it took one.
function Story.dailyRadio(record, day)
    local s = Story.section(record)
    if not s.handover then return false end
    if day - (s.radioDay or -100) < 5 then return false end
    local _, milestones = Story.progress(record)
    local m = math.min(math.max(milestones, 3), Data.AFTER_LAST)
    local pool = Data.AFTER[m]
    local total = pool.radio + pool.questions
    local used = s.radioIndex or 0
    if used >= total then return false end
    -- r r q r r q r r q: every third line is a question.
    local n = used + 1
    local key
    if OA.remainder(n, 3) == 0 then
        key = "Question_after" .. m .. "_" .. math.floor(n / 3)
    else
        local ri = n - math.floor(n / 3)
        key = "Radio_after" .. m .. "_" .. ri
    end
    s.radioIndex = n
    s.radioDay = day
    s.radioLine = key
    return true
end

-- The frequency's own line for a day (a translation key), or nil.
function Story.airLine(record, day)
    local s = Story.section(record)
    if s.radioLine and s.radioDay == day then return "IGUI_OA_Story_" .. s.radioLine end
    return nil
end

-- Called when a new milestone pool starts (the counter restarts).
function Story.resetRadioPool(record)
    local s = Story.section(record)
    s.radioIndex = 0
end

-- ---------------------------------------------------------------------------------------------------------------
-- Documents.

-- The number a document is read with (a stake's, a serial) as it is kept: a number or a short text.
local function cleanExtra(extra)
    if type(extra) == "number" then return extra end
    if type(extra) == "string" and #extra > 0 and #extra <= 24 then return extra end
    return nil
end

-- Marks a document as read (kept by id). `variant` is the place id its text was for, `extra` the number its text uses
-- (the folder shows the text again with them).
function Story.markRead(record, docId, variant, extra)
    local s = Story.section(record)
    if s.docs[docId] == nil then
        s.docs[docId] = variant or true
        s.docExtra[docId] = cleanExtra(extra)
        local stage, milestones = Story.progress(record)
        s.docStage = s.docStage or {}
        s.docStage[docId] = stage + milestones
        OA.Sync.changed("story", record.id)
        return true
    end
    return false
end

-- The documents the record has read, in a stable order: { { id =, variant =, extra = }, ... }.
function Story.readDocuments(record)
    local s = Story.section(record)
    local list = {}
    for id, v in pairs(s.docs) do
        list[#list + 1] = { id = id, variant = v ~= true and v or nil, extra = s.docExtra[id] }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- ---------------------------------------------------------------------------------------------------------------
-- What is new in the folder (DESIGN-terminal 11.1). Keys: "c:<radio copy id>", "d:<document id>", "r:<request number>";
-- the value is the arrival's number, so that the newest is the highest. The terminal's folder shows them with a mark
-- and the missions tab's dot and badge count them; opening one clears it.
function Story.markNew(record, key)
    local s = Story.section(record)
    s.unread = s.unread or {}
    if s.unread[key] then return false end
    s.newSeq = (s.newSeq or 0) + 1
    s.unread[key] = s.newSeq
    -- New content is typed by the terminal when the folder first shows it: nothing of it is seen yet, so a click on it
    -- brings nothing forward (Typing).
    s.typed = s.typed or {}
    s.typed[key] = { seen = 0 }
    OA.Sync.changed("story", record.id)
    return true
end

-- What the terminal has shown of a folder entry (Typing): { seen = the furthest character, done = seen to the end,
-- t = seconds typed of a first presentation left half way }; `true` in a record from before (seen to the end), or
-- { start, t } (the clock only; `start` is not read any more); nil for an entry it has not kept anything of, which was
-- shown whole.
function Story.typedState(record, key)
    local s = Story.section(record)
    return s.typed and s.typed[key] or nil
end

-- The window kept how far a showing of a text got: `seen` characters came on (the furthest only grows), `done` when that
-- is the whole text, `clock` the seconds typed when the showing was left before the end (nil when it ran to the end; not
-- kept for a text seen to its end before). An entry that was never kept anything of takes a state; the key must be a
-- folder key.
function Story.saveTyped(record, key, seen, done, clock)
    if type(key) ~= "string" or #key > 64 or not string.find(key, "^[cdrm]:[%w_%.%-]+$") then return false end
    if seen ~= nil and not (type(seen) == "number" and seen >= 0 and seen < 100000) then return false end
    if clock ~= nil and not (type(clock) == "number" and clock >= 0 and clock < 100000) then return false end
    if seen == nil and clock == nil and not done then return false end
    local s = Story.section(record)
    s.typed = s.typed or {}
    s.typed[key] = PZUIKit.Typing.keep(s.typed[key], seen, done, clock)
    OA.Sync.changed("story", record.id)
    return true
end

function Story.clearNew(record, key)
    local s = Story.section(record)
    if not (s.unread and s.unread[key]) then return false end
    s.unread[key] = nil
    OA.Sync.changed("story", record.id)
    return true
end

-- A document handed to the folder without being read from an item (a guide the team sends to the terminal): it is in
-- the folder at once and new until opened. false when the folder has it already.
function Story.deliverDocument(record, docId, variant, extra)
    local s = Story.section(record)
    if s.docs[docId] ~= nil then return false end
    s.docs[docId] = variant or true
    s.docExtra[docId] = cleanExtra(extra)
    local stage, milestones = Story.progress(record)
    s.docStage = s.docStage or {}
    s.docStage[docId] = stage + milestones
    Story.markNew(record, "d:" .. docId)
    OA.Sync.changed("story", record.id)
    return true
end

-- The papers of a delivered mission come back as copies (LORE: the 2반 sends a copy back once it has taken the paper): the
-- ones the player has not read are in the folder from the settlement on, new until opened, with a note of where they
-- came from. `docs` is { { id =, variant =, extra = } } (Missions.documentsOf).
function Story.returnCopies(record, docs)
    local s = Story.section(record)
    for _, doc in ipairs(docs or {}) do
        if Story.deliverDocument(record, doc.id, doc.variant, doc.extra) then s.copies[doc.id] = true end
    end
end

-- The survey stakes the player has read, as one record: the stake number and the date on it (an index of the dates
-- the stakes carry), by number. The server notes a stake when it is read (the site's own date).
function Story.noteStake(record, stake, date)
    if OA.Sites then OA.Sites.seenOf(record) end
    local s = Story.section(record)
    if type(stake) ~= "number" or type(date) ~= "number" then return false end
    if s.sitesSearched[stake] == date then return false end
    s.sitesSearched[stake] = date
    OA.Sync.changed("story", record.id)
    return true
end

function Story.stakeLog(record)
    local list = {}
    for stake, date in pairs(Story.section(record).sitesSearched) do
        if type(date) == "number" then list[#list + 1] = { stake = stake, date = date } end
    end
    table.sort(list, function(a, b) return a.stake < b.stake end)
    return list
end

-- ---------------------------------------------------------------------------------------------------------------
-- The special request's copy (DESIGN-terminal 6.3.1): the staff's internal request, kept in the folder when a special
-- request is accepted. Numbered per record (R-0117 first, then one more each); a text (Data.REQUESTS[form]) is never
-- sent twice to a record. Military date from the game's calendar. Returns the copy { no, form, id, tier, day, month },
-- or nil when every text of the form has been sent.
local function gameDate()
    local ok, day, month = pcall(function()
        local time = getGameTime()
        return time:getDay() + 1, time:getMonth() + 1
    end)
    if ok then return day, month end
    return nil, nil
end

function Story.addRequestCopy(record, form, prefer)
    local ids = Data.REQUESTS[form]
    if not ids then return nil end
    local s = Story.section(record)
    s.requests = s.requests or {}
    local used = {}
    for _, req in ipairs(s.requests) do used[req.id] = true end
    -- The text the request itself is for goes first (a request for a sample can sends the can's); else the form's next.
    local id
    for _, candidate in ipairs(ids) do
        if candidate == prefer and not used[candidate] then id = candidate; break end
    end
    if not id then
        for _, candidate in ipairs(ids) do
            if not used[candidate] then id = candidate; break end
        end
    end
    if not id then return nil end
    local stage, milestones = Story.progress(record)
    local day, month = gameDate()
    s.requestNo = (s.requestNo or Data.REQUEST_FIRST - 1) + 1
    local req = { no = s.requestNo, form = form, id = id, tier = stage + milestones, day = day, month = month }
    s.requests[#s.requests + 1] = req
    Story.markNew(record, "r:" .. req.no)
    return req
end

-- ---------------------------------------------------------------------------------------------------------------
-- The status table (clue 20): other collection point numbers, sparse, made once. The player's number alone is
-- 'kept'; the roster page (clue 18) shares three of the numbers.
local STATUS_CODES = { "none", "nodata", "excluded" }

function Story.statusTable(record)
    local s = Story.section(record)
    if s.status then return s.status end
    local rows, taken = {}, { [record.number or 0] = true }
    local count = Data.STATUS_ROWS
    while #rows < count - 1 do
        local n = OA.random(1000, 9999)
        if not taken[n] then
            taken[n] = true
            rows[#rows + 1] = { n = n, c = STATUS_CODES[OA.random(1, #STATUS_CODES)] }
        end
    end
    rows[#rows + 1] = { n = record.number or 0, c = "keep" }
    table.sort(rows, function(a, b) return a.n < b.n end)
    -- Which rows the roster page shows next to names.
    local roster = {}
    local idx = 0
    for i, row in ipairs(rows) do
        if row.c ~= "keep" then
            idx = idx + 1
            if idx % 5 == 2 and #roster < 3 then roster[#roster + 1] = i end
        end
    end
    s.status = { rows = rows, roster = roster }
    return s.status
end

-- Is the world's start month the one the setting is written for (July): else the table's date column says so.
function Story.registeredLate()
    local vars = SandboxVars
    if vars and vars.StartMonth and vars.StartMonth ~= 7 then return true end
    return false
end

-- The strange item of next week's requests after a hallucination: nil when there is none this week.
Story.STRANGE = { "Base.Harmonica", "Base.Whistle", "Base.Thimble", "Base.Yoyo", "Base.Doll" }
function Story.strangeItem(record)
    local s = Story.section(record)
    if s.strangeWeek and s.strangeWeek == OA.week() then
        local i = OA.remainder(record.number or 0, #Story.STRANGE) + 1
        return Story.STRANGE[i]
    end
    return nil
end

-- A save from before: the papers the stages sent on entering went to the crate at once, so they are sent.
OA.Store.addUpgrade("story.papers", function(record)
    local s = record.story
    if not s then return end
    s = Story.section(record)
    for st = 1, s.seenStage or 0 do
        local def = Data.STAGES[st]
        for _, entry in ipairs(def and def.supply or {}) do s.sent[entry[2]] = true end
    end
    for k = 1, s.seenMilestones or 0 do
        local def = Data.MILESTONES[k]
        for _, entry in ipairs(def and def.supply or {}) do s.sent[entry[2]] = true end
    end
end)

-- A save from before: the terminal's radio log goes; whether the first line was the late one stays for its copy.
OA.Store.addUpgrade("story.radio", function(record)
    local log = record.radio
    if not log then return end
    for _, entry in ipairs(log) do
        if entry.key == "IGUI_OA_Story_Radio_first_late" then Story.section(record).firstContact = "late" end
    end
    record.radio = nil
end)

return Story
