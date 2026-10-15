-- The stages of the story sites (SCENES.md 5), by facility (Data.FACILITIES): what Story/Stage puts in the building a
-- story took. Vanilla sprites, items, outfits and vehicles only: without the mod they stay a plain body, a tent, a
-- barricade.
--
-- A stage is { pieces = { ... } }, put in order. A piece has `kind` and, but for a barricade, `at`: a role of
-- Stage.roles ("big", "inner", "other", "hall" rooms; "entrance" the outer door). By kind:
--   tile      { sprite, on } on a free square of the room, against a wall when `wall`; at the entrance on the wall
--             beside the door (a wall object: `sprite` is { north =, west = }, Facing S for a north wall, E for a west one)
--   set       { tiles = { { dx, dy, sprite }, ... }, more, on } sprites placed together where all their squares are free
--             in the room (a desk of two squares, a radio on it); `more` (as tiles) goes with them where it fits too
--             (`on`: a radio among the tiles is left on, its static playing while nothing is on air)
--   item      { type, count } on the floor of the room
--   vehicle   { script, open = a door part id, battery = 0 to 1 } outside by the entrance
--   barricade { planks = { least, most } } boards on the inside of each ground floor window
--   lock      locks the room's doors with the building's key: the key goes to the next corpse with `key = true`
--   corpse    { outfit, key } a body in the room
--   blood     { count } splats on the room's floor
--   piece     { key } the mission's own item (its piece `key`) in a container of the room, else on its floor
--   zombies   { outfit, female, count, look = "fakeDead" | "sitting" | nil, wake = an event (Stage.event) } in the
--             room, made once the player is near
require "OperationAcorn/Core"
local OA = OperationAcorn
local StageData = {}
OA.StageData = StageData

-- The tiles (newtiledefinitions): a paper notice on a wall (papernotices_01_6 Facing S, _5 Facing E, WallObject); the
-- light wood desk of two squares facing south (furniture_tables_high_01_26 and _27, SpriteGridPos 0,0 and 1,0); the army
-- walkie-talkie on a table facing south (appliances_com_01_50, IsTableTop, IsoType IsoRadio); folding chairs facing north
-- (furniture_seating_indoor_01_62).
local NOTICE = { north = "papernotices_01_6", west = "papernotices_01_5" }
local CHAIR_N = "furniture_seating_indoor_01_62"

-- 1: the temporary police post (SCENES.md 5). The keepers in Police outfits walk the inside (Story/Scene); one lies
-- fake dead in the hall and gets up when the evidence envelope is taken.
StageData.police = { pieces = {
    { kind = "tile", at = "entrance", sprite = NOTICE },
    { kind = "vehicle", at = "entrance", script = "Base.CarLightsPolice", open = "DoorFrontLeft", battery = 0 },
    { kind = "barricade", planks = { 2, 3 } },
    -- the desk and its radio, left on; the row of chairs facing it when the room has space for it too
    { kind = "set", at = "big", on = true, tiles = {
        { 0, 0, "furniture_tables_high_01_26" }, { 1, 0, "furniture_tables_high_01_27" }, { 0, 0, "appliances_com_01_50" } },
        more = { { -1, 3, CHAIR_N }, { 0, 3, CHAIR_N }, { 1, 3, CHAIR_N }, { 2, 3, CHAIR_N } } },
    { kind = "lock", at = "inner" },
    { kind = "corpse", at = "other", outfit = "Police", key = true },
    { kind = "piece", at = "inner", key = "A" },
    { kind = "blood", at = "hall", count = 2 },
    { kind = "zombies", at = "hall", outfit = "Police", look = "fakeDead", wake = "pickup" },
} }

return StageData
