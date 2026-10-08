-- The story's documents (LORE 2, 4, 6, 7): the registry of ids, which item shows which, and the text of each, made
-- from the translation files (IGUI_OA_Story_Doc_<id>, IGUI_OA_Story_DocTitle_<id>). A save keeps only ids
-- (the folder in the terminal lists the ones read); a place's variant changes the place name and where in the
-- building the document says it was, nothing else (LORE 4). Dates are in documents only (LORE: 날짜는 서류에만).
require "OperationAcorn/Core"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Story"
local OA = OperationAcorn
local Data, Story = OA.StoryData, OA.Story
local Docs = {}
OA.StoryDocs = Docs

local PREFIX = "IGUI_OA_Story_"

-- Document ids by kind. "found" ones come with a mission item, "supply" ones in a supply crate, "note" ones are
-- the short field notes of regular missions, "stake" is a drop site's survey stake.
Docs.FOUND = { "police_card", "clinic_log", "weather_log", "farm_journal", "cooler_front", "cooler_back", "review_memo",
               "roster_page", "ward_record", "cell_log", "soil_slip", "con_stake", "con_roster", "con_filters",
               "con_ledger", "con_compare" }
Docs.SUPPLY = { "serum_sheet", "reply_first", "reply_evidence", "reply_correction", "reply_nomatch", "reply_fragment",
                "reply_relapse", "appendix_2", "unresolved_1", "unresolved_2", "unresolved_3", "handover_notice",
                "status_table" }
Docs.STAKE = "stake"

local known = {}
for _, id in ipairs(Docs.FOUND) do known[id] = "found" end
for _, id in ipairs(Docs.SUPPLY) do known[id] = "supply" end
known[Docs.STAKE] = "stake"
for i = 1, Data.FIELD_NOTES do known["note_" .. i] = "note" end

function Docs.kind(id)
    return known[id]
end

-- Every document id (for the folder's order and for checks).
function Docs.all()
    local list = {}
    for id in pairs(known) do list[#list + 1] = id end
    table.sort(list)
    return list
end

function Docs.titleKey(id)
    return PREFIX .. "DocTitle_" .. id
end

-- The names printed on the shelter roster (Latin, as in a Kentucky roster of 1993): the ones next to the numbers.
Docs.ROSTER_NAMES = { "HARGROVE, D.", "PRUITT, R.", "LINDQVIST, M.", "OKONKWO, T.", "BAYLESS, E.", "TREVINO, A." }

local function placeTexts(variant)
    if variant and Data.PLACES[variant] then
        return getText(PREFIX .. "Place_" .. variant), getText(PREFIX .. "PlaceNote_" .. variant)
    end
    return "", ""
end

local function statusText(code)
    return getText(PREFIX .. "Status_" .. code)
end

-- The roster page: names with four-digit numbers in the 'conversion' column; three numbers are ones of the status
-- table, one is the player's own with the name smeared (LORE clue 18).
local function rosterBody(record, variant, extra)
    local st = Story.statusTable(record)
    local place, note = placeTexts(variant)
    local lines = { getText(PREFIX .. "Doc_roster_page_head", Story.number(record), place, note) }
    local names = Docs.ROSTER_NAMES
    local used = 0
    for _, idx in ipairs(st.roster) do
        used = used + 1
        lines[#lines + 1] = getText(PREFIX .. "Doc_roster_page_row", names[used], string.format("%04d", st.rows[idx].n))
    end
    lines[#lines + 1] = getText(PREFIX .. "Doc_roster_page_smeared", Story.number(record))
    lines[#lines + 1] = getText(PREFIX .. "Doc_roster_page_foot", Story.number(record), place, note)
    return table.concat(lines, "\n")
end

-- The state table of the handover (LORE clue 20).
local function statusBody(record)
    local st = Story.statusTable(record)
    local lines = { getText(PREFIX .. "Doc_status_table_head", Story.number(record)) }
    for _, row in ipairs(st.rows) do
        if row.c == "keep" then
            local date = Story.registeredLate() and getText(PREFIX .. "Doc_status_before_first") or getText(PREFIX .. "Doc_status_date")
            lines[#lines + 1] = getText(PREFIX .. "Doc_status_row_keep", string.format("%04d", row.n), statusText("keep"), date,
                getText(PREFIX .. "Doc_status_basis"))
        else
            lines[#lines + 1] = getText(PREFIX .. "Doc_status_row", string.format("%04d", row.n), statusText(row.c))
        end
    end
    lines[#lines + 1] = getText(PREFIX .. "Doc_status_table_foot", Story.number(record))
    return table.concat(lines, "\n")
end

local DYNAMIC = { roster_page = rosterBody, status_table = statusBody }

-- The text of a document for a record. `variant` is a place id (changes the place wording), `extra` a number the
-- text uses (a stake number, a serial).
function Docs.body(record, id, variant, extra)
    local dynamic = DYNAMIC[id]
    if dynamic then return dynamic(record, variant, extra) end
    local place, note = placeTexts(variant)
    return getText(PREFIX .. "Doc_" .. id, Story.number(record), place, note, extra and tostring(extra) or "")
end

-- The survey stake's own text: its number and the date on it (a document, as every date is).
function Docs.stakeBody(stakeNo, dateIndex)
    return getText(PREFIX .. "Doc_stake", tostring(stakeNo), getText(PREFIX .. "StakeDate_" .. tostring(dateIndex or 1)))
end

-- What reading an item shows: { { id =, variant =, extra = }, ... } from the item's name (without module) and its
-- modData table (a supply item names its document in OA_Doc; the others have theirs in the data).
function Docs.forItem(record, itemName, md)
    md = md or {}
    local def = Data.ITEMS[itemName]
    local list = {}
    local extra = md.OA_Stake or md.OA_Serial
    if md.OA_Doc then
        list[#list + 1] = { id = md.OA_Doc }
    end
    if def and def.docs then
        for _, id in ipairs(def.docs) do list[#list + 1] = { id = id, variant = md.OA_Variant, extra = extra } end
    end
    if md.OA_Note and known[md.OA_Note] then list[#list + 1] = { id = md.OA_Note } end
    return list
end

return Docs
