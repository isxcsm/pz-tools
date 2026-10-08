-- The story: what each stage and milestone tells and sends, the order of the manifest notes, the radio greeting, the
-- documents the player has read, the handover. The record's `story` section holds only ids and counters (DESIGN 12);
-- all text is in the translation files (IGUI_OA_Story_*). The missions (Story/Missions) ask this for what to start.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Data"
local OA = OperationAcorn
local Data = OA.StoryData
local Story = {}
OA.Story = Story

local PREFIX = "IGUI_OA_Story_"

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
        s.missed = {}        -- story ids missed, offered again at the next stage
        s.done = {}          -- story id -> "done" | "missed" | "closed"
        s.chosen = {}        -- the choice missions: story id -> option
        s.supply = {}        -- sent to the next supply crate, not yet taken by the trade part: { type =, doc = }
        s.noteQueue = {}     -- manifest notes that come before the order: ids
        s.noteIndex = {}     -- pool key -> notes used
        s.radioIndex = 0     -- after the handover: lines used
        s.radioDay = -100
        s.hallucinations = 0
        s.strangeWeek = nil  -- the week the strange request item is for
        s.sitesSeen = {}     -- drop sites the player has been near: site number -> true
        s.sitesSearched = {} -- stake numbers read
        s.manifests = {}     -- the latest manifests, { serial =, text = }
        s.regularsSince = 0
    end
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

-- A radio log line for the terminal, by translation key (the radio log translates it when it is shown).
function Story.radioKey(record, key, args)
    if OA.Trade and OA.Trade.radio then
        OA.Trade.radio(record, key, args)
        return true
    end
    return false
end

-- A story radio line by id.
function Story.radio(record, id, args)
    local number = Story.number(record)
    return Story.radioKey(record, PREFIX .. "Radio_" .. id, args or { number })
end

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

-- Adds trust and credits to a record at a settlement (or a field trade). The trade part's own function does the
-- debt and the stage-up handling when it has one.
function Story.addTrust(record, trust)
    if trust <= 0 then return end
    if OA.Trade and OA.Trade.addTrust then
        OA.Trade.addTrust(record, trust)
    elseif OA.Trust and OA.Trust.add then
        OA.Trust.add(record, trust)
    else
        local t = trade(record)
        t.trust = (t.trust or 0) + trust
    end
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

-- The missed story missions come back (not the optional ones), after the new stage's own.
local function requeueMissed(record)
    local s = Story.section(record)
    for _, id in ipairs(s.missed) do
        Story.queueStory(record, id, false)
    end
    s.missed = {}
end

local function enterEvents(record, def)
    for _, id in ipairs(def.stories or {}) do Story.queueStory(record, id, true) end
    for _, id in ipairs(def.radio or {}) do Story.radio(record, id) end
    for _, entry in ipairs(def.supply or {}) do Story.queueSupply(record, entry[1], entry[2]) end
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
    for _, id in ipairs(def.radio or {}) do Story.radio(record, id) end
    for _, entry in ipairs(def.supply or {}) do Story.queueSupply(record, entry[1], entry[2]) end
    requeueMissed(record)
    s.noteIndex = s.noteIndex or {}
end

function Story.enterMilestone(record, k)
    local def = Data.MILESTONES[k]
    local s = Story.section(record)
    if def then
        enterEvents(record, def)
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
function Story.onStage(record, stage, milestones)
    local s = Story.section(record)
    stage = stage or (record.trade and record.trade.stage) or 0
    milestones = milestones or (record.trade and record.trade.milestones) or 0
    for st = s.seenStage + 1, stage do
        s.seenStage = st
        Story.enterStage(record, st)
        OA.log("story: stage", st, "entered by", record.number)
    end
    for k = s.seenMilestones + 1, milestones do
        s.seenMilestones = k
        Story.enterMilestone(record, k)
        OA.log("story: milestone", k, "reached by", record.number)
    end
    OA.Sync.changed("story", record.id)
end

-- Missions end: the story hears of it. result: "done" | "expired" | "lost".
function Story.missionEnded(record, m, result)
    local s = Story.section(record)
    if m.story then
        local def = Data.STORIES[m.story] or Data.REVISITS[m.story]
        if result == "done" then
            s.done[m.story] = "done"
        elseif def and not def.optional and not def.handover then
            s.done[m.story] = "missed"
            s.missed[#s.missed + 1] = m.story
        else
            s.done[m.story] = def and def.optional and "closed" or s.done[m.story]
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
    s.noteQueue[#s.noteQueue + 1] = "last_b"
    Story.queueSupply(record, "HandoverFile", nil)
    Story.queueSupply(record, "KitVoucher", nil)
    Story.radio(record, Data.HANDOVER_RADIO)
    OA.log("story: handover for", record.number)
    OA.Sync.changed("story", record.id)
end

-- The call sign the team goes by now, as a translation key.
function Story.callSignKey(record)
    return PREFIX .. (Story.handedOver(record) and "CallSign_Handover" or "CallSign_Oak")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Radio and notes.

-- Which greeting the radio opens with, as a translation key: the stage's (1 to 4) or "H" after the handover; nil when
-- there is none (before the first stage, and at the 5th stage).
function Story.greetingKeyFor(stage, handedOver)
    if handedOver then return PREFIX .. "Greeting_H" end
    if Data.GREETING_STAGES[stage] then return PREFIX .. "Greeting_" .. tostring(stage) end
    return nil
end

function Story.greetingKey(record)
    return Story.greetingKeyFor((Story.progress(record)), Story.handedOver(record))
end

-- The greeting text with the collection point number ("" when there is none).
function Story.greeting(record)
    local key = Story.greetingKey(record)
    if not key then return "" end
    return Story.text(key, Story.number(record))
end

-- The first radio line when the terminal is first used: 'late' when the first crate came late or without a helicopter.
function Story.firstContact(record, late)
    local s = Story.section(record)
    if s.firstContact then return false end
    s.firstContact = true
    Story.radio(record, late and "first_late" or "first")
    return true
end

-- The refusal story beats (LORE 7). Returns the radio key for a category that is not taken for a while (`phase`
-- "start") or has come back as a request ("back"), or the general line. The market part (P1) decides which category
-- and when; this only gives the words.
function Story.refusalKey(category, phase)
    local cat = Data.REFUSALS[category] and category or "any"
    return PREFIX .. "Refuse_" .. cat .. "_" .. (phase == "back" and "back" or "start")
end

-- The big meteorite's receipt line and radio line (the economy marks it 'not taken').
Story.BIG_METEORITE_RECEIPT = PREFIX .. "Receipt_BigMeteorite"
Story.BIG_METEORITE_RADIO = PREFIX .. "Radio_big_meteorite"
Story.FRAGMENT_RECEIPT = PREFIX .. "Receipt_Fragment"

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

-- The next manifest note, by the order pool: the special ones first (a receipt remark waiting), then the stage's
-- own lines one per crate. nil when the story has nothing now (the trade part uses its general lines). Returns the
-- text and the id.
function Story.manifestNoteKey(record)
    local s = Story.section(record)
    local id = table.remove(s.noteQueue, 1)
    if not id then
        local key, ids = notePool(record)
        local used = s.noteIndex[key] or 0
        if used >= #ids then return nil end
        s.noteIndex[key] = used + 1
        id = ids[used + 1]
    end
    return PREFIX .. "Note_" .. id, { Story.number(record) }, id
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

-- The serum remark (manifest note 6 of the sample lines) for crates that carry a serum.
function Story.serumNote(record)
    return Story.text(PREFIX .. "Note_serum", Story.number(record))
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
        return Story.text(PREFIX .. "Form_" .. id)
    end
    return default
end

-- Keeps a manifest's text in the document folder (the latest few). The trade part gives the serial and the finished text.
function Story.addManifest(record, serial, text)
    local s = Story.section(record)
    s.manifests[#s.manifests + 1] = { serial = serial, text = text }
    while #s.manifests > Data.MANIFESTS_KEPT do table.remove(s.manifests, 1) end
end

-- After the handover the radio carries a line now and then: six lines and three questions per milestone pool, in
-- order, one every few days. Returns true when it posted one.
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
    Story.radioKey(record, PREFIX .. key, { Story.number(record) })
    return true
end

-- Called when a new milestone pool starts (the counter restarts).
function Story.resetRadioPool(record)
    local s = Story.section(record)
    s.radioIndex = 0
end

-- ---------------------------------------------------------------------------------------------------------------
-- Documents.

-- Marks a document as read (kept by id). `variant` is the place id its text was for.
function Story.markRead(record, docId, variant)
    local s = Story.section(record)
    if s.docs[docId] == nil then
        s.docs[docId] = variant or true
        OA.Sync.changed("story", record.id)
        return true
    end
    return false
end

-- The documents the record has read, in a stable order: { { id =, variant = }, ... }.
function Story.readDocuments(record)
    local s = Story.section(record)
    local list = {}
    for id, v in pairs(s.docs) do
        list[#list + 1] = { id = id, variant = v ~= true and v or nil }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
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

return Story
