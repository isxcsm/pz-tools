-- The relays (BU.Units, BU.RELAY_KINDS): a junction box for power and a yard hydrant for water, each a place a box's line goes on from
-- (BU.Links). A relay is one utility's: power only where power is needed (a far generator), water only where water is
-- (a field). Each is one box's, counted toward its relays (BU.relayLimit). One standing in a building lets its box's
-- zone take the rooms of the floors about it (Panels.reaches), and those rooms are its box's: no other box nor another
-- box's relay goes there. Their art is in the bu_water_01 sheet (tools/tile_art.py).
require "BuildingUtilities/Units"
local BU = BuildingUtilities
local Units, Panels = BU.Units, BU.Panels
local Relays = {}
BU.Relays = Relays

Relays.SPRITES = { junction = "bu_water_01_54", hydrant = "bu_water_01_55" }

-- Whether a relay's line can be hung on a box: in a room of a building, only one no other box has. True, or nil and
-- a reason.
function Relays.canHang(unit, panel)
    local building = Panels.buildingAt(unit.x, unit.y, unit.z)
    if not building then return true end
    local owner = Panels.roomOwner(building.key, building.roomId, panel)
    if owner then return nil, "roomTaken" end
    return true
end

Units.define("junction", {
    item = "BuildingUtilities.JunctionBox",
    sprites = { Relays.SPRITES.junction },
    utility = "power",
    colour = { 0.85, 0.65, 0.4 },
    canPlace = function() return true end,
    sprite = function() return Relays.SPRITES.junction end,
})

Units.define("hydrant", {
    item = "BuildingUtilities.YardHydrant",
    sprites = { Relays.SPRITES.hydrant },
    utility = "water",
    colour = { 0.4, 0.8, 0.85 },
    canPlace = function() return true end,
    sprite = function() return Relays.SPRITES.hydrant end,
})

return Relays
