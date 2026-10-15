-- The story's documents (LORE 2, 4, 6, 7): the registry of ids, which item shows which, and the text of each, made
-- from the translation files (IGUI_OA_Story_Doc_<id>, IGUI_OA_Story_DocTitle_<id>). A save keeps only ids
-- (the folder in the terminal lists the ones read); the facility it was found at (its variant) names the place and
-- where in it the document says it was, nothing else (LORE 4). Dates are in documents only (LORE: 날짜는 서류에만).
require "OperationAcorn/Core"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Story"
local OA = OperationAcorn
local Data, Story = OA.StoryData, OA.Story
local Docs = {}
OA.StoryDocs = Docs


-- Document ids by kind. "found" ones come with a mission item, "supply" ones in a supply crate, "note" ones are
-- the short field notes of regular missions, "stake" is a drop site's survey stake.
Docs.FOUND = { "police_card", "clinic_log", "weather_log", "farm_journal", "cooler_front", "cooler_back", "review_memo",
               "roster_page", "ward_record", "cell_log", "soil_slip", "handover_pages", "con_stake", "con_roster",
               "con_filters", "con_ledger", "con_compare", "revisit_ledger", "revisit_roster", "revisit_police" }
Docs.SUPPLY = { "serum_sheet", "reply_first", "reply_evidence", "reply_correction", "reply_nomatch", "reply_fragment",
                "reply_relapse", "pending_list", "appendix_2", "unresolved_1", "unresolved_2", "unresolved_3",
                "handover_notice", "status_table" }
Docs.STAKE = "stake"
-- The stakes the player has read, kept in the folder as one record (the folder makes its text: Folder.stakeLog).
Docs.STAKE_LOG = "stake_log"
-- What the research team sends to the terminal's folder itself, with no item to read (the research guide, the tree
-- memos, the infection handling notice, the cure certificate): the guide documents add their ids with Docs.addGuide
-- (Story.deliverDocument puts one in a record's folder, new until opened).
Docs.GUIDE = {}
-- A guide document that is made from the record when it is read (the cure certificate tells the days it took) has its
-- text made by a function: Docs.GUIDE_BODY[id](record, variant, extra).
Docs.GUIDE_BODY = {}

local known = {}
for _, id in ipairs(Docs.FOUND) do known[id] = "found" end
for _, id in ipairs(Docs.SUPPLY) do known[id] = "supply" end
known[Docs.STAKE] = "stake"
for i = 1, Data.FIELD_NOTES do known["note_" .. i] = "note" end

function Docs.kind(id)
    return known[id]
end

-- A guide document's id, added to the ones the folder knows; `body` (optional) makes its text.
function Docs.addGuide(id, body)
    if known[id] then return end
    Docs.GUIDE[#Docs.GUIDE + 1] = id
    known[id] = "guide"
    Docs.GUIDE_BODY[id] = body
end

-- Every document id (for the folder's order and for checks).
function Docs.all()
    local list = {}
    for id in pairs(known) do list[#list + 1] = id end
    table.sort(list)
    return list
end

function Docs.titleKey(id)
    return "IGUI_OA_Story_DocTitle_" .. id
end

-- The names printed on the shelter roster (Latin, as in a Kentucky roster of 1993): the ones next to the numbers.
Docs.ROSTER_NAMES = { "HARGROVE, D.", "PRUITT, R.", "LINDQVIST, M.", "OKONKWO, T.", "BAYLESS, E.", "TREVINO, A." }

-- The facility a document was found at (the item's OA_Variant): its name and where in it, or nothing.
local facilities = {}
for _, id in ipairs(Data.FACILITIES) do facilities[id] = true end

local function placeTexts(variant)
    if variant and facilities[variant] then
        return getText("IGUI_OA_Story_Facility_" .. variant), getText("IGUI_OA_Story_FacilityNote_" .. variant)
    end
    return "", ""
end

local function statusText(code)
    return getText("IGUI_OA_Story_Status_" .. code)
end

-- The roster page: names with four-digit numbers in the 'conversion' column; three numbers are ones of the status
-- table, one is the player's own with the name smeared (LORE clue 18).
local function rosterBody(record, variant, extra)
    local st = Story.statusTable(record)
    local place, note = placeTexts(variant)
    local lines = { getText("IGUI_OA_Story_Doc_roster_page_head", Story.number(record), place, note) }
    local names = Docs.ROSTER_NAMES
    local used = 0
    for _, idx in ipairs(st.roster) do
        used = used + 1
        lines[#lines + 1] = getText("IGUI_OA_Story_Doc_roster_page_row", names[used], string.format("%04d", st.rows[idx].n))
    end
    lines[#lines + 1] = getText("IGUI_OA_Story_Doc_roster_page_smeared", Story.number(record))
    lines[#lines + 1] = getText("IGUI_OA_Story_Doc_roster_page_foot", Story.number(record), place, note)
    return table.concat(lines, "\n")
end

-- The state table of the handover (LORE clue 20).
local function statusBody(record)
    local st = Story.statusTable(record)
    local lines = { getText("IGUI_OA_Story_Doc_status_table_head", Story.number(record)) }
    for _, row in ipairs(st.rows) do
        if row.c == "keep" then
            local date = Story.registeredLate() and getText("IGUI_OA_Story_Doc_status_before_first") or getText("IGUI_OA_Story_Doc_status_date")
            lines[#lines + 1] = getText("IGUI_OA_Story_Doc_status_row_keep", string.format("%04d", row.n), statusText("keep"), date,
                getText("IGUI_OA_Story_Doc_status_basis"))
        else
            lines[#lines + 1] = getText("IGUI_OA_Story_Doc_status_row", string.format("%04d", row.n), statusText(row.c))
        end
    end
    lines[#lines + 1] = getText("IGUI_OA_Story_Doc_status_table_foot", Story.number(record))
    return table.concat(lines, "\n")
end

local DYNAMIC = { roster_page = rosterBody, status_table = statusBody }
-- Documents that read differently when there is no number to print (the soil slip of a plain ground sample).
local NO_EXTRA = { soil_slip = "soil_slip_plain" }

-- The text of a document for a record. `variant` is a facility id (the place's wording), `extra` a number the
-- text uses (a stake number, a serial).
function Docs.body(record, id, variant, extra)
    local dynamic = DYNAMIC[id] or Docs.GUIDE_BODY[id]
    if dynamic then return dynamic(record, variant, extra) end
    local place, note = placeTexts(variant)
    local text = id
    if NO_EXTRA[id] and (extra == nil or extra == "") then text = NO_EXTRA[id] end
    return getText("IGUI_OA_Story_Doc_" .. text, Story.number(record), place, note, extra and tostring(extra) or "")
end

-- The survey stake's own text: its number and the date on it (a document, as every date is).
function Docs.stakeBody(stakeNo, dateIndex)
    return getText("IGUI_OA_Story_Doc_stake", tostring(stakeNo), getText("IGUI_OA_Story_StakeDate_" .. tostring(dateIndex or 1)))
end

-- What reading an item shows: { { id =, variant =, extra = }, ... } from the item's name (without module) and its
-- modData table (a supply item names its document in OA_Doc; the others have theirs in the data; a mission item
-- with OA_Only shows its OA_Doc alone, in the place of the item's own paper).
function Docs.forItem(record, itemName, md)
    md = md or {}
    local def = Data.ITEMS[itemName]
    local list = {}
    local extra = md.OA_Stake or md.OA_Serial
    if md.OA_Doc then
        list[#list + 1] = { id = md.OA_Doc, variant = md.OA_Only and md.OA_Variant or nil, extra = md.OA_Only and extra or nil }
    end
    if def and def.docs and not (md.OA_Doc and md.OA_Only) then
        for _, id in ipairs(def.docs) do
            if id ~= md.OA_Doc then list[#list + 1] = { id = id, variant = md.OA_Variant, extra = extra } end
        end
    end
    if md.OA_Note and known[md.OA_Note] then list[#list + 1] = { id = md.OA_Note } end
    return list
end

return Docs
