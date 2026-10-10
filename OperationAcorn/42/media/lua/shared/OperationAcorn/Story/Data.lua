-- The story's data: the places the missions can send the player to, the story missions with their kinds and
-- documents, the mission items, and the order of the lines each stage tells. Text lives in the translation files
-- (IGUI_OA_Story_*), named by the ids here; only ids and numbers are kept in a save (DESIGN 12, LORE 4 and 7).
require "OperationAcorn/Core"
local OA = OperationAcorn
local Data = {}
OA.StoryData = Data

Data.ITEM_MODULE = "OperationAcorn"

-- Places. Every coordinate comes from the map's lot headers (checked 2026-10-09): x, y, z is a square inside the key
-- room, x1, y1, x2, y2 the building's bounding box (inclusive), z1 and z2 its levels. `room` is the room name a
-- container is preferred in. Text keys: IGUI_OA_Story_Place_<id> (the name, as the map labels write it) and
-- IGUI_OA_Story_PlaceNote_<id> (where in the building the documents say it was).
local function place(id, x, y, z, x1, y1, x2, y2, z1, z2, room)
    Data.PLACES[id] = { id = id, x = x, y = y, z = z, x1 = x1, y1 = y1, x2 = x2, y2 = y2, z1 = z1, z2 = z2, room = room }
end
Data.PLACES = {}
-- Police: the evidence room of Muldraugh (ground floor), West Point (first floor) and Riverside (cellar); Rosewood's
-- station has none, its locked gun storage stands in.
place("muldraugh_pd", 10631, 10418, 0, 10630, 10398, 10665, 10420, 0, 1, "evidenceroom")
place("westpoint_pd", 11815, 6812, 1, 11799, 6800, 11824, 6822, 0, 1, "evidenceroom")
place("rosewood_pd", 8066, 11723, 0, 8048, 11722, 8089, 11754, 0, 2, "policegunstorage")
place("riverside_pd", 6088, 5258, -1, 6077, 5236, 6090, 5264, -1, -1, "evidenceroom")
-- Clinics.
place("westpoint_clinic", 11871, 6916, 0, 11854, 6910, 11890, 6935, 0, 1, "medclinic")
place("marchridge_clinic", 10156, 12750, 0, 10125, 12748, 10172, 12760, 0, 1, "medclinic")
place("fallas_clinic", 5504, 9580, 0, 5493, 9577, 5506, 9588, 0, 0, "medclinic")
-- The observation records: the Brandenburg airfield's hangars (the office one), and farmhouses.
place("brandenburg_airfield", 923, 6134, 0, 914, 6129, 931, 6147, 0, 1, "office")
place("riverside_farm", 6961, 5587, 0, 6957, 5575, 6969, 5591, 0, 1, "livingroom")
place("riverside_farm2", 5411, 5445, 0, 5409, 5444, 5419, 5452, 0, 0, "kitchen")
place("fallas_farm", 7339, 8533, 0, 7337, 8531, 7347, 8539, 0, 1, "livingroom")
place("fallas_farm2", 7305, 8498, 0, 7301, 8490, 7310, 8499, 0, 1, "livingroom")
-- The camp store of Valley Station and the eastern camp's.
place("valley_camp", 12480, 4310, 0, 12465, 4298, 12497, 4327, 0, 0, "armystorage")
place("east_camp", 15630, 3921, 0, 15617, 3917, 15643, 3926, 0, 1, "armystorage")
-- The cold war bunker at March Ridge (4 levels down, the complex at the bottom), and a shed near it for the case where
-- the bunker cannot be used.
place("marchridge_bunker", 9964, 12615, -4, 9921, 12600, 9980, 12650, -4, -1, "oldarmy")
place("marchridge_shed", 10016, 12625, 0, 10015, 12624, 10018, 12627, 0, 0, "garagestorage")
-- Schools with a gym (Rosewood's has none; the gym of its sports block is not a school's).
place("riverside_school", 6491, 5435, 1, 6480, 5412, 6515, 5460, 0, 2, "gym")
place("westpoint_school", 11376, 6782, 0, 11304, 6763, 11382, 6802, 0, 1, "gym")
place("marchridge_school", 10051, 12719, 0, 10004, 12713, 10061, 12752, 0, 1, "gym")
-- Milestone places: the wards of Louisville's hospitals, Rosewood's prison.
place("louisville_hospital", 12431, 3674, 2, 12353, 3603, 12457, 3721, 0, 4, "hospitalroom")
place("louisville_hospital2", 12953, 2057, 1, 12921, 1996, 12990, 2089, 0, 3, "hospitalroom")
place("rosewood_prison", 7627, 11752, 4, 7512, 11701, 7693, 11869, 0, 6, "prisoncells")
place("rosewood_cells", 7376, 11716, 0, 7351, 11702, 7391, 11718, 0, 2, "prisoncells")
place("brandenburg_prison", 1363, 5853, 0, 1349, 5835, 1423, 5912, 0, 1, "prisoncells")
-- Far places for the handover (the farthest band): Louisville's airport terminal and the eastern camp.
place("louisville_airport", 15494, 2903, 1, 15325, 2842, 15597, 2997, 0, 3, "baggageroom")
place("louisville_police", 12464, 1602, 3, 12404, 1528, 12560, 1691, 0, 7, "evidenceroom")
place("echo_surface", 5560, 12470, 0, 5537, 12440, 5583, 12504, 0, 1, "communications")

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

-- The regular missions' kinds: the item, how heavy the pick is. Text: IGUI_OA_Story_RegTitle_<item> and _RegBrief_.
Data.REGULAR = {
    { item = "MissionEnvelope", weight = 3 },
    { item = "MissionSampleTin", weight = 2 },
    { item = "MissionLogbook", weight = 2 },
    { item = "MissionFilterCase", weight = 2 },
    { item = "MissionTape", weight = 2 },
    { item = "MissionFabricRoll", weight = 2 },
}

-- The field notes a regular mission item may carry (document ids note_1 .. note_N), and the chance it does.
Data.FIELD_NOTES = 12
Data.FIELD_NOTE_CHANCE = 60

-- Story missions. `kind`: fetch (find an item in a building), swap (leave the sealed case, wait, take the record),
-- choice (the terminal offers two, the other closes for good), carry (the sample cooler), field (seal on the spot
-- with the field call device), dropfetch (take the item from the container left at a place), soil (take a soil
-- sample), compare (two copies, only one is the original). `trigger`: a stage, or a milestone count.
-- `condition`: "locked" (the key room is locked, the key lies in the same building). `optional`: not offered again
-- when missed. `ignoreBand`: the places are chosen without the distance band (the far choice).
Data.STORIES = {
    evidence = {
        trigger = { stage = 1 }, kind = "fetch", item = "EvidenceEnvelope", condition = "locked",
        places = { "muldraugh_pd", "westpoint_pd", "rosewood_pd", "riverside_pd" },
    },
    clinic = {
        trigger = { stage = 2 }, kind = "swap", item = "ClinicRecord", case = true,
        places = { "westpoint_clinic", "marchridge_clinic", "fallas_clinic" },
    },
    observation = {
        trigger = { stage = 3 }, kind = "choice",
        options = {
            a = { item = "WeatherLog", places = { "brandenburg_airfield" }, ignoreBand = true },
            b = { item = "FarmJournal", places = { "riverside_farm", "fallas_farm", "fallas_farm2", "riverside_farm2" } },
        },
    },
    cooler = {
        trigger = { stage = 4 }, kind = "carry", item = "SampleCooler",
        places = { "valley_camp", "east_camp" },
    },
    bunker = {
        trigger = { stage = 4 }, kind = "dropfetch", item = "ReviewMemo", optional = true,
        places = { "marchridge_bunker" }, fallback = "marchridge_shed",
    },
    gym = {
        trigger = { stage = 5 }, kind = "field", item = "RosterPage",
        places = { "riverside_school", "westpoint_school", "marchridge_school" },
    },
    ward = {
        trigger = { milestone = 1 }, kind = "fetch", item = "WardRecord",
        places = { "louisville_hospital", "louisville_hospital2" },
    },
    cells = {
        trigger = { milestone = 2 }, kind = "fetch", item = "CellLog",
        places = { "rosewood_prison", "rosewood_cells", "brandenburg_prison" },
    },
    soil = {
        trigger = { milestone = 2 }, kind = "soil", item = "SoilSample", optional = true, late = true,
    },
    handover = {
        trigger = { milestone = 3 }, kind = "field", item = "HandoverPages", handover = true, far = true,
        places = { "louisville_airport", "louisville_police", "east_camp", "echo_surface" },
    },
}
-- After the handover (the 4th milestone on) each milestone has one story mission, a new purpose at a place the
-- player knew: these in turn. `doc` is the paper the item carries (the new office's form: it takes the place of the
-- item's own old paper).
Data.REVISITS = {
    revisit_ledger = { kind = "fetch", item = "PharmacyLedger", doc = "revisit_ledger",
        places = { "westpoint_clinic", "marchridge_clinic", "fallas_clinic" } },
    revisit_roster = { kind = "fetch", item = "RosterLostPage", doc = "revisit_roster",
        places = { "riverside_school", "westpoint_school", "marchridge_school" } },
    revisit_police = { kind = "fetch", item = "EvidenceEnvelope", doc = "revisit_police",
        places = { "muldraugh_pd", "westpoint_pd", "rosewood_pd", "riverside_pd" } },
}
Data.REVISIT_ORDER = { "revisit_ledger", "revisit_roster", "revisit_police" }

-- The contract missions after the handover (at least six kinds): `weight` is the share of the pick. Their text:
-- IGUI_OA_Story_ConTitle_<id>, IGUI_OA_Story_ConBrief_<id>.
Data.CONTRACTS = {
    { id = "compare", kind = "compare", item = "CopyOriginal", weight = 2 },
    { id = "stake", kind = "stake", item = "StakeTag", weight = 2 },
    { id = "roster", kind = "place", item = "RosterLostPage", places = { "riverside_school", "westpoint_school", "marchridge_school" }, weight = 2 },
    { id = "filters", kind = "random", item = "FilterBundle", weight = 2 },
    { id = "ledger", kind = "place", item = "PharmacyLedger", places = { "westpoint_clinic", "marchridge_clinic", "fallas_clinic" }, weight = 2 },
    { id = "tapes", kind = "random", item = "MissionTape", weight = 2 },
}

-- The last numbered stage: the milestones after it count on as stages 6, 7, 8 ... (DESIGN-terminal 2.3).
Data.LAST_STAGE = 5

-- What each stage tells (LORE 4, 6, 7). Radio lines are in order (the stage's radio copy); notes are the manifest
-- notes that go out one per supply crate in this order (the rest of the crates get the story's filler lines,
-- Story.fillNoteKey); supply is the 2반 papers of the stage: { item, document, when, first }. They wait on entering and
-- go one to a crate, in this order, when `when` holds ("done:<story id>" the story mission was delivered, "sent:<document>"
-- that paper has gone, "fragment" a meteorite fragment has been on a receipt; none: at once). `first` ones go before the
-- others. The story ids are queued first (the next mission slot).
Data.STAGES = {
    [1] = { stories = { "evidence" }, radio = { "s1_a", "s1_b" }, notes = { "battery", "appendix_missing", "leave_site" },
            supply = { { "SerumSheet", "serum_sheet" } } },
    [2] = { stories = { "clinic" }, radio = { "s2_a", "s2_b" }, notes = { "bedding_back", "socks", "box_corner" },
            supply = { { "AnalysisReply", "reply_first" }, { "AnalysisReply", "reply_correction", "sent:reply_first" },
                       { "AnalysisReply", "reply_evidence", "done:evidence" } } },
    [3] = { stories = { "observation" }, radio = { "s3_a", "s3_b", "s3_c" }, notes = { "cards", "count_off", "dunnigan_pen" },
            supply = { { "AnalysisReply", "reply_nomatch" }, { "AnalysisReply", "reply_fragment", "fragment" },
                       { "AnalysisReply", "reply_relapse" } } },
    [4] = { stories = { "cooler", "bunker" }, radio = { "s4_a" }, notes = { "proxy_signature", "old_form", "short_notice" },
            supply = { { "Appendix", "pending_list" } } },
    [5] = { stories = { "gym" }, radio = { "s5_first" }, notes = { "late_appendix", "no_greeting", "empty_slot" },
            supply = { { "Appendix", "appendix_2", nil, true } } },
}
-- Milestones 1 and 2: the unresolved items list grows by a sheet each.
Data.MILESTONES = {
    [1] = { stories = { "ward" }, radio = { "m1_a", "m1_b" }, notes = { "m1_a", "m1_b", "m1_c" },
            supply = { { "UnresolvedList", "unresolved_1", nil, true } } },
    [2] = { stories = { "cells" }, radio = { "m2_a", "m2_b" }, notes = { "m2_a", "m2_b", "m2_c" },
            supply = { { "UnresolvedList", "unresolved_2", nil, true } } },
    [3] = { stories = { "handover" }, radio = { "m3_a" }, notes = { "last_a", "last_b" },
            supply = { { "UnresolvedList", "unresolved_3", nil, true } } },
}
-- Radio lines that tell of a paper before it is there are left out of the stage's copy until the paper has gone: the
-- line's id -> { doc = the paper, copy = the folder key of the copy that gains the line }. (The correction is told
-- of when the first reply has been sent, the fragment reply when it has.)
Data.RADIO_AFTER = {
    s2_b = { doc = "reply_first", copy = "c:s2" },
    s3_b = { doc = "reply_fragment", copy = "c:s3" },
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

-- The first radio line after the handover is the 12th of the sample lines.
Data.HANDOVER_RADIO = "handover"
-- The handover's last crate: the file, a kit voucher, and the note.
Data.HANDOVER_SUPPLY = { { "HandoverFile", nil }, { "KitVoucher", nil } }

-- After the handover each milestone has a pool, from the 3rd milestone (index 3) on; further milestones use the last
-- pool again, shorter lines the further they are. Sizes: notes 12, questions 3, radio 6.
Data.AFTER = {
    [3] = { notes = 12, questions = 3, radio = 6 },
    [4] = { notes = 12, questions = 3, radio = 6 },
    [5] = { notes = 12, questions = 3, radio = 6 },
}
Data.AFTER_LAST = 5

-- Greetings by stage (LORE 6): the stages 1 to 4 and "H" after the handover have one (IGUI_OA_Story_Greeting_<n>); before
-- the first stage (the first-contact lines carry their own) and at the 5th stage (no greeting) there is none.
Data.GREETING_STAGES = { [1] = true, [2] = true, [3] = true, [4] = true }

-- Temporary refusals (LORE 7): the line when a category stops being taken and when it comes back as a request.
-- Categories are the economy's letters. Text IGUI_OA_Story_Refuse_<A|F|any>_<start|back>.
Data.REFUSALS = { A = true, F = true }

-- How many broadcast lines each stage has (IGUI_OA_Story_Broadcast_<stage|H>_<n>).
Data.BROADCAST_LINES = { ["0"] = 2, ["1"] = 3, ["2"] = 3, ["3"] = 3, ["4"] = 3, ["5"] = 2, H = 4 }

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

-- The 2반 request copies a special request brings to the folder (DESIGN-terminal 6.3.1): by form (exchange, fetch,
-- field), the ids of the texts (IGUI_OA_Story_Request_<id>), each sent once. The first copy's number is R-0117.
Data.REQUEST_FIRST = 117
Data.REQUESTS = {
    exchange = { "dunnigan_can" },
}

return Data
