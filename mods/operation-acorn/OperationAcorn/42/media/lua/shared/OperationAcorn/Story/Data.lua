-- The story's data: the temporary facilities the story places are taken for, the story missions with their kinds and
-- documents, the mission items, and the order of the lines each stage tells. Text lives in the translation files
-- (IGUI_OA_Story_*), named by the ids here; only ids and numbers are kept in a save (DESIGN 12, LORE 4 and 7).
require "OperationAcorn/Core"
local OA = OperationAcorn
local Data = {}
OA.StoryData = Data

Data.ITEM_MODULE = "OperationAcorn"

-- The temporary facilities (LORE 4: the authorities took any building for a post, a clinic, a shelter). A story place
-- is a site picked in the band (Missions.pickSite), named by its facility: IGUI_OA_Story_Facility_<id> in the mission
-- card and the documents. The staging (Story/Scene) is by facility too.
Data.FACILITIES = { "police", "medical", "farm", "army", "shelter", "hospital", "prison" }

-- The mission items: the full type of each is OperationAcorn.<name>. `docs` is what reading the item shows (document
-- ids, with the place's variant in the text); `note` means a regular mission item may carry a field note (OA_Note).
-- `weight` is only for placing (the script has the real one).
Data.ITEMS = {
    -- Regular missions (and the contract pool).
    MissionEnvelope = { note = true, weight = 0.3 },
    MissionSampleTin = { note = true, weight = 0.6 },
    MissionLogbook = { note = true, weight = 0.5 },
    MissionFilterCase = { note = true, weight = 1.5 },
    MissionTape = { note = true, weight = 0.2 },
    MissionFabricRoll = { note = true, weight = 1.0 },
    MissionHeavyCase = { note = true, weight = 15 },
    -- Story missions.
    EvidenceEnvelope = { docs = { "police_card" }, weight = 0.3 },
    ClinicRecord = { docs = { "clinic_log" }, weight = 0.5 },
    WeatherLog = { docs = { "weather_log" }, weight = 0.8 },
    FarmJournal = { docs = { "farm_journal" }, weight = 0.5 },
    SampleCooler = { docs = { "cooler_front", "cooler_back" }, weight = 25 },
    RosterPage = { docs = { "roster_page" }, weight = 0.1 },
    HandoverPages = { docs = { "handover_pages" }, weight = 0.1 },
    ReviewMemo = { docs = { "review_memo" }, weight = 0.1 },
    WardRecord = { docs = { "ward_record" }, weight = 0.5 },
    CellLog = { docs = { "cell_log" }, weight = 0.6 },
    SoilSample = { docs = { "soil_slip" }, weight = 0.8 },
    -- Contract missions.
    StakeTag = { docs = { "con_stake" }, weight = 0.1 },
    RosterLostPage = { docs = { "con_roster" }, weight = 0.1 },
    FilterBundle = { docs = { "con_filters" }, weight = 3 },
    PharmacyLedger = { docs = { "con_ledger" }, weight = 0.8 },
    CopyOriginal = { docs = { "con_compare" }, weight = 0.3 },
    -- What the research team sends: the sealed case for the dead drop, the container left at the drop, the field call
    -- device. Documents it sends (the document is named by the item's OA_Doc, or the next one waiting for its type).
    SampleCase = { weight = 3 },
    DeadDropCase = { weight = 1 },
    FieldCallDevice = { weight = 3 },
    AnalysisReply = { supply = true, weight = 0.1 },
    Appendix = { supply = true, weight = 0.2 },
    SerumSheet = { supply = true, docs = { "serum_sheet" }, weight = 0.1 },
    UnresolvedList = { supply = true, weight = 0.1 },
    HandoverFile = { supply = true, docs = { "handover_notice", "status_table" }, weight = 0.2 },
    KitVoucher = { weight = 0.05 },
    MeteorFragment = { weight = 0.5 },
    MeteorFragmentIron = { weight = 0.8 },
    MeteorFragmentStonyIron = { weight = 0.6 },
}

function Data.fullType(name)
    return Data.ITEM_MODULE .. "." .. name
end

-- Item name from a full type, or nil when it is not this mod's.
function Data.itemName(fullType)
    if type(fullType) ~= "string" then return nil end
    local name = string.match(fullType, "^" .. Data.ITEM_MODULE .. "%.(%w+)$")
    return name
end

-- The regular missions' kinds: how heavy the pick is, and what is made. Without a `kind` it is one item in one building
-- (text: IGUI_OA_Story_RegTitle_<item> and _RegBrief_). The others (DESIGN-terminal 7.2): `compare` (two copies in two
-- buildings, one the original), `soil` (a sample of bare ground), `scatter` (a piece of `item` in each of two or three
-- buildings of the area), `heavy` (one item that weighs about 15: a car or a cart carries it), `clear` and `target` (a
-- group of zombies in an open area, Data.ZOMBIES). Their text is
-- IGUI_OA_Story_RegTitle_<id> and _RegBrief_<id>, the compare one the contract's.
Data.REGULAR = {
    { item = "MissionEnvelope", weight = 3 },
    { item = "MissionSampleTin", weight = 2 },
    { item = "MissionLogbook", weight = 2 },
    { item = "MissionFilterCase", weight = 2 },
    { item = "MissionTape", weight = 2 },
    { item = "MissionFabricRoll", weight = 2 },
    { id = "compare", kind = "compare", item = "CopyOriginal", weight = 1 },
    { id = "soil", kind = "soil", weight = 1 },
    { id = "scatter", kind = "scatter", item = "MissionSampleTin", weight = 2 },
    { item = "MissionHeavyCase", kind = "heavy", weight = 1 },
    { id = "clear", kind = "clear", weight = 3 },
    { id = "target", kind = "target", weight = 3 },
}

-- The zombie missions (NUMBERS 9 '좀비 임무'): an area clear (kill the whole group) and a target sample (a mission sample
-- from each target). The group is known by the API's mark of its mission's id (Story/Game); it looks as the game's own
-- (a vanilla outfit: a crowd of passers-by, targets from a hospital); its size by level (1 to 6). The circle's radius; the player within NEAR of it brings the group, at squares more than AWAY from the
-- player; the group stays within MARGIN of the circle (the API's hold); LEAVE squares beyond NEAR the player has gone.
Data.ZOMBIES = {
    clear = { outfit = "Generic01", counts = { 12, 18, 24, 30, 40, 50 } },
    target = { outfit = "HospitalPatient", counts = { 2, 2, 3, 3, 4, 4 } },
}
Data.ZOMBIE_RADIUS, Data.ZOMBIE_NEAR, Data.ZOMBIE_AWAY, Data.ZOMBIE_MARGIN, Data.ZOMBIE_LEAVE = 15, 40, 20, 20, 30

-- The scattered samples: how many pieces there can be, and the weight of the heavy sample (the card tells it).
Data.SCATTER_PIECES = { 2, 3 }
Data.HEAVY_WEIGHT = 15

-- The field notes a regular mission item may carry (document ids note_1 .. note_N), and the chance it does.
Data.FIELD_NOTES = 12
Data.FIELD_NOTE_CHANCE = 60

-- Story missions. `kind`: fetch (find an item in a building), swap (leave the sealed case, wait, take the record),
-- choice (the terminal offers two, the other closes for good), carry (the sample cooler), field (seal on the spot
-- with the field call device), soil (take a soil sample). `trigger`: a stage, or a milestone count. `facility`: what
-- the site was taken for (Data.FACILITIES); `site`: how it is picked (Missions.pickSite: want "public", "largest",
-- "near", "far"; ground = open ground; up = of more than one floor first). `condition`: "locked" (the key room is locked, the key lies in the same
-- building). `optional`: not offered again when missed.
Data.STORIES = {
    evidence = {
        trigger = { stage = 1 }, kind = "fetch", item = "EvidenceEnvelope", condition = "locked",
        facility = "police", site = { want = "public" },
    },
    clinic = {
        trigger = { stage = 2 }, kind = "swap", item = "ClinicRecord", case = true,
        facility = "medical", site = { want = "public" },
    },
    observation = {
        trigger = { stage = 3 }, kind = "choice", facility = "farm",
        options = {
            a = { item = "WeatherLog", site = { want = "far", up = true } },
            b = { item = "FarmJournal", site = { want = "near" } },
        },
    },
    cooler = {
        trigger = { stage = 4 }, kind = "carry", item = "SampleCooler",
        facility = "army", site = { ground = true },
    },
    gym = {
        trigger = { stage = 5 }, kind = "field", item = "RosterPage",
        facility = "shelter", site = { want = "largest" },
    },
    ward = {
        trigger = { milestone = 1 }, kind = "fetch", item = "WardRecord",
        facility = "hospital", site = { want = "public" },
    },
    cells = {
        trigger = { milestone = 2 }, kind = "fetch", item = "CellLog",
        facility = "prison", site = { want = "public" },
    },
    soil = {
        trigger = { milestone = 2 }, kind = "soil", item = "SoilSample", optional = true, late = true,
    },
    handover = {
        trigger = { milestone = 3 }, kind = "field", item = "HandoverPages", handover = true,
        facility = "army", site = { ground = true },
    },
}
-- After the handover (the 4th milestone on) each milestone has one story mission, a new purpose at a place the
-- player knew: these in turn. `from` is the story whose site it goes back to (a new one of the facility when that story
-- had none); `doc` is the paper the item carries (the new office's form: it takes the place of the item's own old
-- paper).
Data.REVISITS = {
    revisit_ledger = { kind = "fetch", item = "PharmacyLedger", doc = "revisit_ledger", from = "clinic",
        facility = "medical", site = { want = "public" } },
    revisit_roster = { kind = "fetch", item = "RosterLostPage", doc = "revisit_roster", from = "gym",
        facility = "shelter", site = { want = "largest" } },
    revisit_police = { kind = "fetch", item = "EvidenceEnvelope", doc = "revisit_police", from = "evidence",
        facility = "police", site = { want = "public" } },
}
Data.REVISIT_ORDER = { "revisit_ledger", "revisit_roster", "revisit_police" }

-- The contract missions after the handover (at least six kinds): `weight` is the share of the pick. Their text:
-- IGUI_OA_Story_ConTitle_<id>, IGUI_OA_Story_ConBrief_<id>.
Data.CONTRACTS = {
    { id = "compare", kind = "compare", item = "CopyOriginal", weight = 2 },
    { id = "stake", kind = "stake", item = "StakeTag", weight = 2 },
    { id = "roster", kind = "place", item = "RosterLostPage", facility = "shelter", site = { want = "largest" }, weight = 2 },
    { id = "filters", kind = "random", item = "FilterBundle", weight = 2 },
    { id = "ledger", kind = "place", item = "PharmacyLedger", facility = "medical", site = { want = "public" }, weight = 2 },
    { id = "tapes", kind = "random", item = "MissionTape", weight = 2 },
}

-- The last numbered stage: the milestones after it count on as stages 6, 7, 8 ... (DESIGN-terminal 2.3).
Data.LAST_STAGE = 5

-- What each stage tells (LORE 4, 6, 7). Notes are the manifest notes that go out one per supply crate in this order (the rest of the crates get the story's filler lines,
-- Story.fillNoteKey); supply is the 2반 papers of the stage: { item, document, when, first }. They wait on entering and
-- go one to a crate, in this order, when `when` holds ("done:<story id>" the story mission was delivered, "sent:<document>"
-- that paper has gone, "fragment" a meteorite fragment has been on a receipt; none: at once). `first` ones go before the
-- others. The story ids are queued first (the next mission slot).
Data.STAGES = {
    [1] = { stories = { "evidence" }, notes = { "battery", "appendix_missing", "leave_site" },
            supply = { { "SerumSheet", "serum_sheet" } } },
    [2] = { stories = { "clinic" }, notes = { "bedding_back", "socks", "box_corner" },
            supply = { { "AnalysisReply", "reply_first" }, { "AnalysisReply", "reply_correction", "sent:reply_first" },
                       { "AnalysisReply", "reply_evidence", "done:evidence" } } },
    [3] = { stories = { "observation" }, notes = { "cards", "count_off", "dunnigan_pen" },
            supply = { { "AnalysisReply", "reply_nomatch" }, { "AnalysisReply", "reply_fragment", "fragment" },
                       { "AnalysisReply", "reply_relapse" } } },
    [4] = { stories = { "cooler" }, notes = { "proxy_signature", "old_form", "short_notice" },
            supply = { { "Appendix", "pending_list" } } },
    [5] = { stories = { "gym" }, notes = { "late_appendix", "no_greeting", "empty_slot" },
            supply = { { "Appendix", "appendix_2", nil, true } } },
}
-- Milestones 1 and 2: the unresolved items list grows by a sheet each.
Data.MILESTONES = {
    [1] = { stories = { "ward" }, notes = { "m1_a", "m1_b", "m1_c" },
            supply = { { "UnresolvedList", "unresolved_1", nil, true } } },
    [2] = { stories = { "cells" }, notes = { "m2_a", "m2_b", "m2_c" },
            supply = { { "UnresolvedList", "unresolved_2", nil, true } } },
    [3] = { stories = { "handover" }, notes = { "last_a", "last_b" },
            supply = { { "UnresolvedList", "unresolved_3", nil, true } } },
}
-- What a manifest remark encloses (it says "2 batteries enclosed": the crate has them), by note id: { { item, count } }.
-- A lighter stands for the lighter flints the notes used to name (the game has none).
local BATTERY = { { "Base.Battery", 2 } }
local SOCKS = { { "Base.Socks_Ankle", 1 } }
local CARDS = { { "Base.CardDeck", 1 } }
local OPENER = { { "Base.TinOpener", 1 } }
local LIGHTER = { { "Base.Lighter", 1 } }
Data.NOTE_ITEMS = {
    battery = BATTERY, socks = SOCKS, cards = CARDS, dunnigan_pen = { { "Base.Pencil", 2 } },
    m1_b = CARDS, m1_c = LIGHTER, m2_b = OPENER,
    after3_2 = BATTERY, after3_4 = SOCKS, after3_6 = OPENER, after3_8 = CARDS, after3_11 = LIGHTER,
    after4_2 = BATTERY, after4_4 = SOCKS, after4_6 = CARDS, after4_8 = OPENER, after4_10 = LIGHTER,
    after5_2 = BATTERY, after5_4 = SOCKS, after5_6 = CARDS, after5_8 = OPENER, after5_10 = LIGHTER,
}
-- Notes that are said only when the crate bears them out: "gap" the manifest number is not the one after the last
-- (count_off says it is not), "orders" an order was loaded (the note counts them: %2).
Data.NOTE_WHEN = { count_off = "gap", after3_2 = "orders", after4_1 = "orders" }

-- The handover's last crate: the file, a kit voucher, and the note.
Data.HANDOVER_SUPPLY = { { "HandoverFile", nil }, { "KitVoucher", nil } }

-- After the handover each milestone has a pool, from the 3rd milestone (index 3) on; further milestones use the last
-- pool again. The manifest notes of each.
Data.AFTER = {
    [3] = { notes = 12 },
    [4] = { notes = 12 },
    [5] = { notes = 12 },
}
Data.AFTER_LAST = 5

-- Temporary refusals (LORE 7): the line when a category stops being taken and when it comes back as a request.
-- Categories are the economy's letters. Text IGUI_OA_Story_Refuse_<A|F|any>_<start|back>.
Data.REFUSALS = { A = true, F = true }

-- Small numbers.
Data.MISSION_RADIUS_BASE = 50
Data.SWAP_WAIT_HOURS = 2
Data.SWAP_SLACK_DAYS = 3
Data.FIELD_ARRIVAL_HOURS = { 2, 3 }
Data.FIELD_RANGE = 60
Data.CASE_RANGE = 120
Data.SEALED_LOST_DAYS = 14
Data.STATUS_ROWS = 18
Data.HALLUCINATION_LONG = 3
Data.MANIFESTS_KEPT = 12

-- The special requests (DESIGN-terminal 6.3): what the field terminal offers, two at a time. Each is one of the three
-- forms the story missions already have: `exchange` (leave the sealed case at the place, wait, take what turns up),
-- `fetch` (take the item from the container left there), `field` (find the item and call the helicopter on the spot).
-- `item` is a regular mission item, `facility` and `site` as a story mission's (the site picked in the band of the
-- level above), and `request` the 2반 request copy sent with it. Text: IGUI_OA_Story_SpecialTitle_<id>.
Data.SPECIALS = {
    { id = "can", form = "exchange", item = "MissionSampleTin", request = "dunnigan_can",
      facility = "farm", site = { want = "near" } },
    { id = "cold", form = "exchange", item = "MissionSampleTin", request = "ashdown_cold",
      facility = "medical", site = { want = "public" } },
    { id = "stock", form = "fetch", item = "MissionLogbook", request = "kiesling_stock",
      facility = "army", site = { ground = true } },
    { id = "filters", form = "fetch", item = "MissionFilterCase", request = "dunnigan_filters",
      facility = "farm", site = { want = "far" } },
    { id = "handover", form = "field", item = "MissionEnvelope", request = "branscomb_test",
      facility = "shelter", site = { want = "largest" } },
    { id = "records", form = "field", item = "MissionLogbook", request = "ashdown_seal",
      facility = "medical", site = { want = "public" } },
}
Data.SPECIAL_BY_ID = {}
for _, entry in ipairs(Data.SPECIALS) do Data.SPECIAL_BY_ID[entry.id] = entry end

-- The 2반 request copies a special request brings to the folder (DESIGN-terminal 6.3.1): by form (exchange, fetch,
-- field), the ids of the texts (IGUI_OA_Story_Request_<id>), each sent once. The first copy's number is R-0117.
Data.REQUEST_FIRST = 117
Data.REQUESTS = {
    exchange = { "dunnigan_can", "ashdown_cold" },
    fetch = { "kiesling_stock", "dunnigan_filters" },
    field = { "branscomb_test", "ashdown_seal" },
}

return Data
