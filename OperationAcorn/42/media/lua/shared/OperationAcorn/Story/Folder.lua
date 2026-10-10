-- The document folder in the terminal's missions tab (DESIGN-terminal 6.4): what the record keeps there, in groups with
-- the newest on top, which of it is new, what each says, and the missions tab's dot and badge (11.1). Only data: the
-- window (client/Story/TabFolder) draws it. Nothing here is saved: the folder is worked out from the story's counters,
-- the documents read, the manifests and the request copies, and the arrivals not opened yet (Story.markNew).
require "OperationAcorn/Core"
require "OperationAcorn/Trade/Terminal"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/Typing"
local OA = OperationAcorn
local Data, Story, Docs, Terminal, Typing = OA.StoryData, OA.Story, OA.StoryDocs, OA.Terminal, OA.Typing
local Folder = {}
OA.StoryFolder = Folder

-- The groups, in the order the list shows them: the staff's request copies, the radio copies, the research team's
-- papers, the field papers, the supply manifests. Texts: IGUI_OA_Story_Group_<id>.
Folder.GROUPS = { "request", "radio", "research", "field", "manifest" }
local RANK = {}
for i, id in ipairs(Folder.GROUPS) do RANK[id] = i end

-- Which group a document's kind goes to.
local GROUP_OF = { supply = "research", guide = "research", found = "field", note = "field" }

-- Military months for the request copies' dates (a date is written in the paper's own form, not translated).
Folder.MONTHS = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }

-- Where the stake record sits among the field papers (above the mission papers, below nothing that is new).
local STAKE_LOG_ORDER = 50

-- Where a document sits in the story's order: the newest has the highest number (the definition order of the lists
-- in Story/Docs); the field notes are the oldest of the field papers.
local ORDER
local function orderOf(id)
    if not ORDER then
        ORDER = {}
        for i, doc in ipairs(Docs.FOUND) do ORDER[doc] = i end
        for i, doc in ipairs(Docs.SUPPLY) do ORDER[doc] = i end
        for n = 1, Data.FIELD_NOTES do ORDER["note_" .. n] = n - 100 end
    end
    if ORDER[id] then return ORDER[id] end
    for i, doc in ipairs(Docs.GUIDE) do
        if doc == id then return 100 + i end
    end
    return 0
end

-- The trust tier a document comes at, from the data: a supply sheet at the stage that sends it, a mission's paper at
-- the stage or milestone that starts the mission (milestones count on as tiers 6, 7, 8). The others (the contract
-- papers, the field notes, what the handover sends) have none here: the tier they were read at is kept instead.
local TIERS
local function tierMap()
    if TIERS then return TIERS end
    TIERS = {}
    local function put(doc, tier)
        if doc and tier and (not TIERS[doc] or tier < TIERS[doc]) then TIERS[doc] = tier end
    end
    for stage, def in pairs(Data.STAGES) do
        for _, entry in ipairs(def.supply or {}) do put(entry[2], stage) end
    end
    for k, def in pairs(Data.MILESTONES) do
        for _, entry in ipairs(def.supply or {}) do put(entry[2], Data.LAST_STAGE + k) end
    end
    for _, story in pairs(Data.STORIES) do
        local trigger = story.trigger or {}
        local tier = trigger.stage or (trigger.milestone and Data.LAST_STAGE + trigger.milestone) or nil
        local items = { story.item }
        for _, option in pairs(story.options or {}) do items[#items + 1] = option.item end
        for _, item in ipairs(items) do
            local def = Data.ITEMS[item]
            for _, doc in ipairs(def and def.docs or {}) do put(doc, tier) end
        end
    end
    return TIERS
end

function Folder.docTier(record, id)
    local tier = tierMap()[id]
    if tier then return tier end
    local kept = Story.section(record).docStage
    return kept and kept[id] or nil
end

-- A tier as the list's right-hand label: "2단계", "시작" for the start; "" when it is not known.
function Folder.tierLabel(tier)
    if tier == nil then return "" end
    if tier <= 0 then return Story.text("IGUI_OA_Econ_Stage_0") end
    return Story.text("IGUI_OA_Story_Copy_Stage", tier)
end

-- A text whose line ends may be the two characters \n (the file reader keeps them): real line ends.
function Folder.lines(text)
    return (string.gsub(text or "", "\\n", "\n"))
end

-- The date a request copy was received, in the military form ("24 SEP"); "" when the game's calendar was not there.
local function dateText(req)
    if not (req.day and req.month and Folder.MONTHS[req.month]) then return "" end
    return string.format("%d %s", req.day, Folder.MONTHS[req.month])
end

local function requestNumber(no)
    return string.format("%04d", no)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The entries.

local function add(list, group, key, title, tier, order, ref, s)
    local seq = s.unread and s.unread[key] or nil
    list[#list + 1] = { key = key, group = group, title = title, tier = tier, order = order, ref = ref,
        isNew = seq ~= nil, seq = seq }
end

-- Newest first: by order, the highest on top.
local function newestFirst(a, b)
    return a.order > b.order
end

-- A title shared by more than one entry gets (1), (2) ... in the order they were received (the tier, then the story's
-- order). `same` on each one is its number, for the line under the title.
local function splitSameTitles(all)
    local byTitle = {}
    for _, entry in ipairs(all) do
        local list = byTitle[entry.title]
        if not list then list = {}; byTitle[entry.title] = list end
        list[#list + 1] = entry
    end
    for _, list in pairs(byTitle) do
        if #list > 1 then
            table.sort(list, function(a, b)
                local ta, tb = a.tier or 0, b.tier or 0
                if ta ~= tb then return ta < tb end
                if RANK[a.group] ~= RANK[b.group] then return RANK[a.group] < RANK[b.group] end
                return a.order < b.order
            end)
            for i, entry in ipairs(list) do
                entry.same = i
                entry.title = Story.text("IGUI_OA_Story_UI_SameTitle", entry.title, i)
            end
        end
    end
end

-- The folder: { { id =, entries = { { key, group, title, tier, order, ref, isNew, seq, same } } } } for the groups that
-- have something, in the list's order. `ref` says what an entry is: { kind = "copy", copy }, { kind = "doc", id,
-- variant }, { kind = "manifest", manifest }, { kind = "request", request }.
function Folder.entries(record)
    local s = Story.section(record)
    local by = {}
    for _, id in ipairs(Folder.GROUPS) do by[id] = {} end
    local all = {}
    local function put(group, ...)
        add(by[group], group, ...)
        all[#all + 1] = by[group][#by[group]]
    end
    for _, req in ipairs(s.requests or {}) do
        put("request", "r:" .. req.no, Story.text("IGUI_OA_Story_Request_Title", requestNumber(req.no)), req.tier, req.no,
            { kind = "request", request = req }, s)
    end
    for i, copy in ipairs(Story.radioCopies(record)) do
        local tier = copy.stage
        if copy.id == "first" then tier = 0 end
        if copy.id == "handover" then tier = Data.LAST_STAGE + 3 end
        put("radio", "c:" .. copy.id, Story.copyTitle(copy), tier, i, { kind = "copy", copy = copy }, s)
    end
    for _, doc in ipairs(Story.readDocuments(record)) do
        local group = GROUP_OF[Docs.kind(doc.id)]
        if group then
            put(group, "d:" .. doc.id, Story.text(Docs.titleKey(doc.id)), Folder.docTier(record, doc.id), orderOf(doc.id),
                { kind = "doc", id = doc.id, variant = doc.variant, extra = doc.extra }, s)
        end
    end
    if #Story.stakeLog(record) > 0 then
        put("field", "d:" .. Docs.STAKE_LOG, Story.text(Docs.titleKey(Docs.STAKE_LOG)), nil, STAKE_LOG_ORDER,
            { kind = "stakes" }, s)
    end
    for _, mf in ipairs(s.manifests or {}) do
        put("manifest", "m:" .. mf.serial, Story.text("IGUI_OA_Story_UI_ManifestTitle", tostring(mf.serial)), mf.tier,
            mf.serial, { kind = "manifest", manifest = mf }, s)
    end
    splitSameTitles(all)
    local groups = {}
    for _, id in ipairs(Folder.GROUPS) do
        local list = by[id]
        if #list > 0 then
            table.sort(list, newestFirst)
            groups[#groups + 1] = { id = id, entries = list }
        end
    end
    return groups
end

-- The entries one after another as the list shows them (for 'previous' and 'next' and the position).
function Folder.flat(groups)
    local list = {}
    for _, group in ipairs(groups) do
        for _, entry in ipairs(group.entries) do list[#list + 1] = entry end
    end
    return list
end

-- ---------------------------------------------------------------------------------------------------------------
-- What an entry says: the title, the dim line under it (who, when, how it came) and the text.

local function metaOf(record, entry)
    local parts = {}
    local ref = entry.ref
    local named = entry.tier and entry.tier > 0 and Story.tierText(entry.tier) or nil
    if ref.kind == "copy" then
        local copy = ref.copy
        if copy.id == "first" then
            parts[1] = Story.text("IGUI_OA_Story_Meta_CopyFirst", Story.text("IGUI_OA_Story_CallSign_Oak"))
        elseif copy.id == "handover" then
            parts[1] = Story.text("IGUI_OA_Story_Meta_CopyHandover", Story.text("IGUI_OA_Story_CallSign_Handover"))
        else
            parts[1] = Story.text("IGUI_OA_Story_Meta_Copy", Story.text("IGUI_OA_Story_CallSign_Oak"),
                Story.tierText(copy.stage), #copy.keys)
        end
    elseif ref.kind == "request" then
        parts[1] = Story.text("IGUI_OA_Story_Meta_Request")
    elseif ref.kind == "stakes" then
        parts[1] = Story.text("IGUI_OA_Story_Meta_stakes")
    elseif ref.kind == "manifest" then
        if named then parts[#parts + 1] = named end
        parts[#parts + 1] = Story.text("IGUI_OA_Story_Meta_Manifest")
    else
        if named then parts[#parts + 1] = named end
        local copy = Story.section(record).copies[ref.id]
        parts[#parts + 1] = Story.text("IGUI_OA_Story_Meta_" .. (copy and "copy" or Docs.kind(ref.id)))
    end
    if entry.same then parts[#parts + 1] = Story.text("IGUI_OA_Story_Meta_Same", entry.same) end
    return table.concat(parts, Story.text("IGUI_OA_Story_UI_Dot"))
end

-- The approval line of a request copy: Ordway's own up to the 3rd tier, then the deputy's (LORE 3).
local function approvalOf(req)
    local key = (req.tier or 0) >= 4 and "IGUI_OA_Story_Request_Approval_b" or "IGUI_OA_Story_Request_Approval_a"
    return Story.text(key, dateText(req))
end

-- A request copy's text: the header with its number, the form's own lines (who asks, what, why, the margin), and the
-- approval with the date.
function Folder.requestBody(request)
    local no = requestNumber(request.no)
    return Story.text("IGUI_OA_Story_Request_Head", no) .. "\n"
        .. Folder.lines(Story.text("IGUI_OA_Story_Request_" .. request.id, no)) .. "\n" .. approvalOf(request)
end

-- The survey stake record's text: a line for each stake read, by number, with the date on it.
function Folder.stakeLog(record)
    local lines = {}
    for _, row in ipairs(Story.stakeLog(record)) do
        lines[#lines + 1] = Story.text("IGUI_OA_Story_StakeLog_Line", tostring(row.stake),
            Story.text("IGUI_OA_Story_StakeDate_" .. tostring(row.date)))
    end
    return table.concat(lines, "\n")
end

-- { title =, meta =, body =, marked =, styles =, kind = } of an entry for the reader: `body` is the text plain, `marked`
-- the same with its markup (pauses, colours) for the panel that types it, `styles` the look of the lines a paper's own
-- marks gave (Typing.marks: the marks are out of `body` and `marked`; a radio copy has none), and `kind` how it comes
-- on (Typing).
function Folder.content(record, entry)
    local ref = entry.ref
    local marked
    if ref.kind == "copy" then
        marked = Story.copyMarked(record, ref.copy)
    elseif ref.kind == "request" then
        marked = Folder.requestBody(ref.request)
    elseif ref.kind == "manifest" then
        marked = ref.manifest.text
    elseif ref.kind == "stakes" then
        marked = Folder.stakeLog(record)
    else
        marked = Docs.body(record, ref.id, ref.variant, ref.extra)
    end
    marked = Folder.lines(marked)
    local styles
    if ref.kind ~= "copy" then marked, styles = Typing.marks(marked) end
    return { title = entry.title, meta = metaOf(record, entry), body = OA.Markup.strip(marked), marked = marked,
        styles = styles, kind = Typing.KIND_OF_GROUP[entry.group] }
end

-- ---------------------------------------------------------------------------------------------------------------
-- What is new, and the tab's dot (DESIGN-terminal 1.1, 11.1).

-- How many things in the folder are not opened yet.
function Folder.unreadCount(record)
    local unread = record and record.story and record.story.unread
    local n = 0
    if unread then
        for _ in pairs(unread) do n = n + 1 end
    end
    return n
end

-- The id of a guide document a folder key stands for ("d:<id>" of a guide kind), or nil.
local function guideId(key)
    local id = string.match(key, "^d:(.+)$")
    if id and Docs.kind(id) == "guide" then return id end
    return nil
end

-- The newest guide document (the team's own notices for the terminal) not opened yet: { key, id, title } or nil. The
-- status tab's 'new document' card shows it (11.1 priority 2).
function Folder.newGuide(record)
    local unread = record and record.story and record.story.unread
    local best
    if unread then
        for key, seq in pairs(unread) do
            local id = guideId(key)
            if id and (not best or seq > best.seq) then best = { key = key, id = id, seq = seq } end
        end
    end
    if not best then return nil end
    best.title = Story.text(Docs.titleKey(best.id))
    return best
end

-- The number of the mission on show, which the tab's dot compares with ui.seen.mission (0 when there is none). A new
-- mission has a higher number than any before it; so has a special request offered (or taken) in the slot beside it.
function Folder.missionSeq(record)
    local missions = record and record.missions
    local active = missions and missions.active
    local special = missions and missions.special
    local seq = active and active.seq or 0
    local other = special and ((special.offer and special.offer.seq) or (special.mission and special.mission.seq)) or 0
    return math.max(seq, other)
end

-- Whether the mission on show has not been looked at yet.
function Folder.freshMission(record)
    return Folder.missionSeq(record) > (Terminal.seenValue(record, "mission") or 0)
end

-- The dot of the missions tab: amber for a mission not looked at yet or anything new in the folder. A guide document
-- lights it too, beside the status tab's card: opening it either way marks it read, and both go out.
function Folder.mark(record)
    if Folder.freshMission(record) then return "new" end
    if Folder.unreadCount(record) > 0 then return "new" end
    return nil
end

-- What the tab keeps as seen once it has been looked at: the mission, while the mission screen (sub-tab "missions") is
-- on show. The folder's news is kept per entry, as each is opened. Returns the ui.seen key and value, or nil.
function Folder.seen(record, sub)
    if sub ~= "missions" then return nil end
    if Folder.freshMission(record) then return "mission", Folder.missionSeq(record) end
    return nil
end

return Folder
