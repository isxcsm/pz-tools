-- The stages of the story sites (SCENES.md 5), by facility (Data.FACILITIES): what Story/Stage puts in the building a
-- story took. Vanilla sprites, items, outfits and vehicles only: without the mod they stay a plain body, a tent, a
-- barricade.
--
-- A stage is { pieces = { ... } }, put in order. A piece has `kind` and, but for a barricade, `at`: a role of
-- Stage.roles ("big", "inner", "other", "hall" rooms; "entrance" the outer door). By kind:
--   tile      { sprite } on a free square of the room, against a wall when `wall`; at the entrance on a free square
--             outside beside the door, `sprite` then { north =, west = } by the door's side
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

return StageData
