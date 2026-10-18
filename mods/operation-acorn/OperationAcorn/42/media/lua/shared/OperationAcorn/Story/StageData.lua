-- The stages of the story sites (SCENES.md 5), by story (a choice's by option: <story>_<option>; Story/Stage): what
-- Story/Stage puts in the building a story took, or on its open ground. Vanilla sprites, items, outfits and vehicles
-- only: without the mod they stay a plain body, a tent, a barricade.
--
-- A stage is { pieces = { ... }, ground = true for open ground }, put in order. A piece has `kind` and, but for a
-- barricade and a lockout, `at`: a role of Stage.roles ("big", "inner", "other", "hall" rooms; "entrance", "back" outer
-- doors), "yard" (the ground outside the entrance) or, on open ground, "ground" (the site's middle moved by `dx`, `dy`;
-- `reach`: how far about it). A room piece may ask for its room instead: `up` (the largest on the floor above the
-- ground, of `names` first), `names` alone (the largest so named on any floor, else its role's). By kind:
--   tile      { sprite, on } on a free square of the room, against a wall when `wall`; at the entrance on the wall beside
--             the door (a wall object: `sprite` is { north =, west = }, Facing S for a north wall, E for a west one;
--             each a sprite or a list to pick from; `count` of them, one to a square)
--   set       { tiles = { { dx, dy, sprite }, ... }, more, fewer, on, count } sprites placed together where all their
--             squares are free in the room (a desk of two squares, a radio on it); `more` (as tiles) goes with them
--             where it fits too; `fewer` (a row): its first tiles down to that many where the row does not fit (`on`: a
--             radio among the tiles is left on, its static playing while nothing is on air); `count` copies, each
--             where it fits; `top`: its first tile's top takes the room's `piece` with `top` (a desk). A room a set goes
--             to is cleared of its furniture first (the team made room).
--   line      { sprite, step = { x, y }, length } on open ground: a row of one sprite (a sandbag wall), gaps where taken
--   item      { type | types, count } on the floor of the room (outdoors: about the spot)
--   vehicle   { script, zones, open = a door part id or a list, battery = 0 to 1, fuel = 0 to 1, key (in the glove
--             box), load = item types } `zones`: the game's vehicle zone lists (VehicleZoneDistribution) it may be one
--             of: the first's while the world spawns `script`, else (a mod's vehicles in place of vanilla's) the first
--             of them with one that has the parts asked for
--             outside by the entrance (or the role's door), or about the spot on open ground (`across`: east to west)
--   barricade { planks = { least, most } } boards on the inside of each ground floor window
--   board     { planks, drop = { during, at }, last } boards on the outside of the room's doors; with `drop`, one
--             plank falls at that point of the span (Stage.progress); with `last` (an event), the player taking the
--             last plank off one of them makes that event and the story's monologue for it (Stage.unboarded)
--   block     blocks the room's ways in (to the outside or a hall) but one from inside with a hospital bed
--   lockout   locks the outer doors but the entrance (no key)
--   lock      locks the room's doors with the building's key: the key goes to the next corpse with `key = true`
--   window    { chair } opens one of the room's windows; with `chair` ({ N, S, W, E }) a chair inside it, turned to it
--   generator { fuel = 0 to 1 } a generator, not running
--   call      { sprite, on = an event (Stage.event), sound, secs } the set's thing of that sprite near the spot sounds
--             once on the event, for that long (the camp's radio calling as the circle is entered); not a world
--             sound: zombies do not hear it
--   corpse    { outfit, key, count } bodies in the room
--   blood     { count } splats on the room's floor
--   piece     { key, floor, top } the mission's own item (its piece `key`) in a container of the room (`floor`: on its
--             floor; `top`: on the top of the room's set with `top`), else on its floor; outdoors on the ground
--   zombies   { outfit, female, count, look = "fakeDead" | "sitting" | nil, wake = an event (Stage.event), stagger
--             = seconds between the ones it wakes, during = a span (Stage.progress) they wake across } in the room,
--             made once the player is near
require "OperationAcorn/Core"
local OA = OperationAcorn
local StageData = {}
OA.StageData = StageData

-- The tiles (newtiledefinitions): paper notices on a wall (papernotices_01: Facing S 2, 6, 7, 9; Facing E 1, 4, 5, 8;
-- WallObject); medical notices (location_community_medical_01: Facing S 156 to 159, Facing E 160 to 163); the light
-- wood desk of two squares facing south (furniture_tables_high_01_26 and _27, SpriteGridPos 0,0 and 1,0); the army
-- walkie-talkie on a table facing south (appliances_com_01_50, IsTableTop, IsoType IsoRadio) and the army ham radio
-- (appliances_com_01_8, the same); folding chairs facing north (furniture_seating_indoor_01_62) and plastic garden
-- chairs facing south (furniture_seating_outdoor_01_17); the hospital bed facing south (location_community_medical_01
-- _17 and _16, SpriteGridPos 0,0 and 0,1); the stretcher facing south (furniture_bedding_01_57 and _56, the same); the
-- green tent facing east (camping_04: 99, 98, 97, 96 down its west half, 103, 102, 101, 100 down its east, SpriteGridPos
-- 0,0 to 1,3); the tarp shelter facing south (camping_03_38 and _39, 0,0 and 1,0); sandbag walls on a square's west
-- and north edges (carpentry_02_12, _13); the "Army Property" sign facing south (location_military_generic_01_16 and
-- _17, 0,0 and 1,0); military crates (location_military_generic_01_0, 1, 8, 9).
local NOTICE = { north = "papernotices_01_6", west = "papernotices_01_5" }
local NOTICES = { north = { "papernotices_01_2", "papernotices_01_6", "papernotices_01_7", "papernotices_01_9" },
    west = { "papernotices_01_1", "papernotices_01_4", "papernotices_01_5", "papernotices_01_8" } }
local MEDICAL = { north = { "location_community_medical_01_156", "location_community_medical_01_157",
    "location_community_medical_01_158", "location_community_medical_01_159" },
    west = { "location_community_medical_01_160", "location_community_medical_01_161",
    "location_community_medical_01_162", "location_community_medical_01_163" } }
local CHAIR_N = "furniture_seating_indoor_01_62"
local CHAIR = { N = CHAIR_N, S = "furniture_seating_indoor_01_60", W = "furniture_seating_indoor_01_63",
    E = "furniture_seating_indoor_01_61" }   -- the same chair by the way it faces
local GARDEN_CHAIR_S = "furniture_seating_outdoor_01_17"
local DESK = { { 0, 0, "furniture_tables_high_01_26" }, { 1, 0, "furniture_tables_high_01_27" } }
local CHAIR_ROW = { { -1, 3, CHAIR_N }, { 0, 3, CHAIR_N }, { 1, 3, CHAIR_N }, { 2, 3, CHAIR_N } }
local BED = { { 0, 0, "location_community_medical_01_17" }, { 0, 1, "location_community_medical_01_16" } }
local STRETCHER = { { 0, 0, "furniture_bedding_01_57" }, { 0, 1, "furniture_bedding_01_56" } }
local TENT = { { 0, 0, "camping_04_99" }, { 0, 1, "camping_04_98" }, { 0, 2, "camping_04_97" }, { 0, 3, "camping_04_96" },
    { 1, 0, "camping_04_103" }, { 1, 1, "camping_04_102" }, { 1, 2, "camping_04_101" }, { 1, 3, "camping_04_100" } }
local TARP = { { 0, 0, "camping_03_38" }, { 1, 0, "camping_03_39" } }
local DRIP = "location_community_medical_01_25"   -- a drip stand (Mobile Bloodbag, Facing S)
local CURTAIN = { { 0, 0, "location_community_medical_01_40" }, { 1, 0, "location_community_medical_01_41" } }

-- 1: the temporary police post. The keepers in Police outfits walk the inside (Story/Scene); one lies fake dead in the
-- hall and gets up when the evidence envelope is taken.
StageData.evidence = { pieces = {
    { kind = "tile", at = "entrance", sprite = NOTICE },
    { kind = "vehicle", at = "entrance", script = "Base.CarLightsPolice", zones = { "police" }, open = "DoorFrontLeft",
      battery = 0 },
    { kind = "barricade", planks = { 2, 3 } },
    -- the desk and its radio, left on; the row of chairs facing it when the room has space for it too
    { kind = "set", at = "big", on = true, tiles = { DESK[1], DESK[2], { 0, 0, "appliances_com_01_50" } }, more = CHAIR_ROW },
    { kind = "lock", at = "inner" },
    { kind = "corpse", at = "other", outfit = "Police", key = true },
    { kind = "piece", at = "inner", key = "A" },
    { kind = "blood", at = "hall", count = 2 },
    { kind = "zombies", at = "hall", outfit = "Police", look = "fakeDead", wake = "pickup" },
} }

-- 2: the temporary clinic. The case is left at the reception (the hall, where people waited); while the player waits
-- the patients lying fake dead in the ward get up one by one, and near the end a plank falls from the exam room the
-- nurses are boarded in. (The record is swapped in out of the player's sight: Story/Missions.)
StageData.clinic = { pieces = {
    { kind = "tile", at = "entrance", sprite = MEDICAL },
    { kind = "vehicle", at = "back", script = "Base.VanAmbulance", zones = { "ambulance" }, open = "DoorRear",
      battery = 0 },
    { kind = "set", at = "hall", fewer = 2, tiles = { { 0, 0, CHAIR_N }, { 1, 0, CHAIR_N }, { 2, 0, CHAIR_N }, { 3, 0, CHAIR_N } } },
    { kind = "item", at = "hall", count = 3,
      types = { "Base.UmbrellaBlack", "Base.UmbrellaRed", "Base.Jacket_Black", "Base.JacketLong_Random" } },
    { kind = "piece", at = "hall", key = "CASE", floor = true },
    { kind = "set", at = "big", count = 3, tiles = BED },
    { kind = "set", at = "big", count = 2, tiles = STRETCHER },
    { kind = "corpse", at = "big", outfit = "HospitalPatient", count = 3 },
    { kind = "blood", at = "big", count = 1 },
    { kind = "board", at = "inner", planks = { 2, 3 }, drop = { during = "wait", at = 0.85 } },
    { kind = "zombies", at = "big", outfit = "HospitalPatient", count = 3, look = "fakeDead", during = "wait" },
    { kind = "zombies", at = "inner", outfit = "Nurse", count = 2 },
} }

-- 3 (a): the far house of the weather log. Upstairs a chair at the window, a sheet with a barometer drawn on it, the
-- log in the room's desk; a window open; the owner shut in a bedroom upstairs.
StageData.observation_a = { pieces = {
    { kind = "item", at = "big", up = true, names = { "office", "livingroom", "bedroom" }, type = "Base.SheetPaper2" },
    { kind = "piece", at = "big", up = true, names = { "office", "livingroom", "bedroom" }, key = "A" },
    { kind = "window", at = "big", up = true, names = { "office", "livingroom", "bedroom" }, chair = CHAIR },
    { kind = "lock", at = "other", up = true, names = { "bedroom", "kidsbedroom" } },
    { kind = "zombies", at = "other", up = true, names = { "bedroom", "kidsbedroom" }, outfit = "Farmer" },
} }

-- 3 (b): the near house of the farm journal. Garden chairs turned to the fields; a pickup loaded and left with no fuel,
-- its door open and its key in the glove box; a window open upstairs; one lying fake dead in the garage or the shed. The journal is
-- in any container of the house (the usual placing).
StageData.observation_b = { pieces = {
    { kind = "set", at = "yard", tiles = { { 0, 0, GARDEN_CHAIR_S }, { 1, 0, GARDEN_CHAIR_S }, { 2, 0, GARDEN_CHAIR_S } } },
    { kind = "vehicle", at = "entrance", script = "Base.PickUpTruck", zones = { "farm", "trades" }, open = "DoorFrontLeft",
      fuel = 0, key = true, load = { "Base.Suitcase", "Base.Bag_DuffelBag", "Base.Suitcase" } },
    { kind = "window", at = "big", up = true },
    { kind = "zombies", at = "other", names = { "garage", "garagestorage", "shed", "barn" }, outfit = "Farmer",
      look = "fakeDead" },
} }

-- 4: the field camp left in a hurry, on open ground. Sandbags half round it, the sign at the gap and a soldier lying
-- fake dead there; three tents and a tarp; the radio desk; the cooler by the stretchers at the tarp, a generator with
-- no fuel beside it; the crates; a camouflaged pickup with a flat battery; soldiers about, one in a hazard suit sitting
-- against the crates.
StageData.cooler = { ground = true, pieces = {
    { kind = "line", at = "ground", dx = -6, dy = -6, step = { 1, 0 }, length = 8, sprite = "carpentry_02_13" },
    { kind = "line", at = "ground", dx = -6, dy = -5, step = { 0, 1 }, length = 9, sprite = "carpentry_02_12" },
    { kind = "set", at = "ground", dx = -1, dy = -6, reach = 0, tiles = {
        { 0, 0, "location_military_generic_01_16" }, { 1, 0, "location_military_generic_01_17" } } },
    { kind = "set", at = "ground", dx = -4, dy = -4, reach = 1, tiles = TENT },
    { kind = "set", at = "ground", dx = -1, dy = -4, reach = 1, tiles = TENT },
    { kind = "set", at = "ground", dx = 2, dy = -4, reach = 1, tiles = TENT },
    { kind = "set", at = "ground", dx = -4, dy = 2, reach = 1, tiles = TARP },
    { kind = "set", at = "ground", dx = 3, dy = 1, reach = 1, tiles = { DESK[1], DESK[2], { 0, 0, "appliances_com_01_8" } },
      more = { { 0, 1, "furniture_seating_indoor_01_60" } } },
    { kind = "call", at = "ground", dx = 3, dy = 1, reach = 1, sprite = "appliances_com_01_8", on = "enter",
      sound = "oa.stage.radio", secs = 6 },
    { kind = "set", at = "ground", dx = -4, dy = 4, reach = 1, count = 2, tiles = STRETCHER },
    { kind = "piece", at = "ground", dx = -1, dy = 3, key = "A" },
    { kind = "generator", at = "ground", dx = -1, dy = 5, fuel = 0 },
    { kind = "set", at = "ground", dx = 4, dy = 4, reach = 2, count = 4, tiles = { { 0, 0, "location_military_generic_01_0" } } },
    { kind = "set", at = "ground", dx = 4, dy = 4, reach = 2, count = 2, tiles = { { 0, 0, "location_military_generic_01_8" } } },
    { kind = "vehicle", at = "ground", dx = 7, dy = 2, script = "Base.PickUpTruck_Camo",
      zones = { "military", "farm", "trades" }, open = "DoorFrontLeft", battery = 0 },
    { kind = "zombies", at = "ground", dx = 3, dy = -7, reach = 1, outfit = "ArmyCamoGreen", look = "fakeDead",
      wake = "pickup" },
    { kind = "zombies", at = "ground", dx = 0, dy = 0, reach = 5, outfit = "ArmyCamoGreen", count = 3 },
    { kind = "zombies", at = "ground", dx = 4, dy = 3, reach = 1, outfit = "HazardSuit", look = "sitting" },
} }

-- 5: the temporary reception in the largest building. Notices at the door, bags left in the yard; two outer doors of
-- three locked; the reception desk with the roll on it; the beds of the sleeping room with bodies and many lying fake
-- dead, who get up one by one as the helicopter comes.
StageData.gym = { pieces = {
    { kind = "tile", at = "entrance", sprite = NOTICES, count = 3 },
    { kind = "item", at = "yard", count = 4, types = { "Base.Suitcase", "Base.Bag_DuffelBag", "Base.Suitcase" } },
    { kind = "item", at = "yard", count = 3, types = { "Base.Jacket_Black", "Base.JacketLong_Random", "Base.Notebook" } },
    { kind = "lockout" },
    { kind = "set", at = "big", tiles = DESK, more = CHAIR_ROW, top = true },
    { kind = "piece", at = "big", key = "A", top = true },
    { kind = "set", at = "other", count = 4, tiles = STRETCHER },
    { kind = "item", at = "other", count = 4,
      types = { "Base.SleepingBag_Green", "Base.SleepingBag_BluePlaid", "Base.SleepingBag_Cheap_Blue" } },
    { kind = "corpse", at = "other", count = 3 },
    { kind = "blood", at = "other", count = 1 },
    { kind = "zombies", at = "other", count = 4, look = "fakeDead", wake = "heli", stagger = 8 },
} }

-- 6: the temporary isolation ward. The outer doors but the entrance locked, the ward's doors but one blocked from inside
-- with beds; rows of beds with drip stands, curtains half drawn, bodies in gowns and some lying fake dead, who get up
-- when the filter is taken; the air handling room (the inner one) locked, its key on a doctor's body.
StageData.ward = { pieces = {
    { kind = "tile", at = "entrance", sprite = MEDICAL },
    { kind = "lockout" },
    { kind = "block", at = "big" },
    { kind = "set", at = "big", count = 4, tiles = BED, more = { { 1, 0, DRIP } } },
    { kind = "set", at = "big", count = 2, fewer = 1, tiles = CURTAIN },
    { kind = "corpse", at = "big", outfit = "HospitalPatient", count = 3 },
    { kind = "blood", at = "big", count = 1 },
    { kind = "lock", at = "inner" },
    { kind = "corpse", at = "other", outfit = "Doctor", key = true },
    { kind = "piece", at = "inner", key = "A" },
    { kind = "zombies", at = "big", outfit = "HospitalPatient", count = 2, look = "fakeDead", wake = "pickup" },
    { kind = "zombies", at = "big", outfit = "HospitalPatient", count = 2 },
} }

-- 7: the temporary holding facility. The rooms off the hall locked and boarded from the hall, one shut in each (taking
-- the last plank off a door is the moment of the monologue), a guard's body with the key; the intake filter in the
-- inner one.
StageData.cells = { pieces = {
    { kind = "tile", at = "entrance", sprite = NOTICE },
    { kind = "board", at = "other", planks = { 2, 3 }, last = "plank" },
    { kind = "board", at = "inner", planks = { 2, 3 }, last = "plank" },
    { kind = "lock", at = "other" },
    { kind = "lock", at = "inner" },
    { kind = "corpse", at = "big", outfit = "PrisonGuard", key = true },
    { kind = "piece", at = "inner", key = "A" },
    { kind = "blood", at = "hall", count = 1 },
    { kind = "zombies", at = "other", outfit = "Inmate", count = 2 },
    { kind = "zombies", at = "inner", outfit = "InmateKhaki" },
} }

-- 8: the handover, on open ground at the far band: as the reception's trade on the spot, a small stage, one tent and
-- a few crates.
StageData.handover = { ground = true, pieces = {
    { kind = "set", at = "ground", dx = -2, dy = -3, reach = 1, tiles = TENT },
    { kind = "set", at = "ground", dx = 3, dy = 2, reach = 2, count = 3, tiles = { { 0, 0, "location_military_generic_01_0" } } },
    { kind = "set", at = "ground", dx = 3, dy = 2, reach = 2, tiles = { { 0, 0, "location_military_generic_01_8" } } },
} }

return StageData
