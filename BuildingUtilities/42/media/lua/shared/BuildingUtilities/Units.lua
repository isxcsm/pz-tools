-- Solar panels and battery racks ("units"): objects this mod puts down and wires to a main panel like a generator.
-- They are kept in the save (Store.units), not only on their squares, because they count while those are not
-- loaded. A rack keeps its car batteries in the save too; they go in and come out as items.
require "BuildingUtilities/Panels"
local BU = BuildingUtilities
local Store, Panels = BU.Store, BU.Panels
local Units = {}
BU.Units = Units

Units.KINDS = { "solar", "rack" }
Units.MODDATA = "BuildingUtilitiesUnit"
Units.ITEMS = { solar = "BuildingUtilities.SolarPanel", rack = "BuildingUtilities.BatteryRack" }
-- A panel on the ground stands on a frame facing W or N; on a roof it lies flat. A rack stands against a W wall.
Units.SPRITES = { flat = "bu_solar_01_8", W = "bu_solar_01_9", N = "bu_solar_01_10", rack = "bu_solar_01_0" }
Units.RACK_SIZE = 20
-- Reconditioning: a battery below this condition, so much better, so many times.
Units.REVIVE_BELOW, Units.REVIVE_GAIN, Units.REVIVE_TIMES = 50, 25, 3
Units.REVIVE_SKILL = 4
Units.REVIVED = "BuildingUtilitiesRevived"

function Units.name(unit) return getText("IGUI_BU_Unit_" .. unit.kind) end

-- The unit's object on its loaded square, or nil.
function Units.object(unit)
    local square = getCell():getGridSquare(unit.x, unit.y, unit.z)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:getModData()[Units.MODDATA] == unit.id then return object end
    end
    return nil
end

function Units.ofObject(object)
    local id = object and object:getModData()[Units.MODDATA]
    return id and Store.unit(id) or nil
end

local function blocked(square)
    if Store.unitAt(square:getX(), square:getY(), square:getZ()) then return true end
    if Store.panelAt(square:getX(), square:getY(), square:getZ()) then return true end
    local properties = square:getProperties()
    if properties and properties:has(IsoFlagType.water) then return true end
    return not square:getFloor() or not square:isFree(false)
end

-- Whether a unit of a kind can go on a square: a solar panel outside under the sky (on the ground or a flat roof),
-- a rack inside a building, on a free floor. True, or nil and a reason.
function Units.canInstall(kind, square)
    if not square then return nil, "noSquare" end
    if not BU.api() then return nil, "noApi" end
    if kind == "solar" then
        if not square:isOutside() then return nil, "notOutside" end
    elseif not Panels.buildingAt(square:getX(), square:getY(), square:getZ()) then
        return nil, "notInBuilding"
    end
    if blocked(square) then return nil, "blocked" end
    return true
end

-- The sprite for a unit put on a square by a character: a panel above the ground lies flat; on the ground its
-- frame faces the side the character stands on more (W or N, the frames the tiles have).
function Units.spriteFor(kind, square, character)
    if kind == "rack" then return Units.SPRITES.rack end
    if square:getZ() > 0 then return Units.SPRITES.flat end
    local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
    return math.abs(dx) > math.abs(dy) and Units.SPRITES.W or Units.SPRITES.N
end

-- The main panels a unit could be wired to, as for a generator (Panels.producerCandidates).
function Units.candidates(unit) return Panels.producerCandidates(unit.x, unit.y, unit.z) end

-- Whether a unit can be wired to a panel. True, or false and a reason. A rack only to a panel of the tier that
-- keeps a bank.
function Units.canConnect(unit, panel)
    if panel.parent then return false, "isSubPanel" end
    if unit.panel then return false, "connectedElsewhere" end
    if unit.kind == "rack" and (panel.tier or 1) < BU.BANK_TIER then return false, "rackTier" end
    for _, candidate in ipairs(Panels.inProducerRange(unit.x, unit.y, unit.z)) do
        if candidate.panel == panel then return true end
    end
    return false, "tooFar"
end

-- Batteries.

function Units.isBattery(item) return item ~= nil and item:hasTag(ItemTag.CAR_BATTERY) end

-- A battery item as a rack keeps it, and the other way.
function Units.batteryRecord(item)
    return { type = item:getFullType(), charge = item:getCurrentUsesFloat(), condition = item:getCondition(),
        revived = item:getModData()[Units.REVIVED] or 0 }
end

function Units.batteryItem(record)
    local item = instanceItem(record.type)
    if not item then return nil end
    item:setUsedDelta(math.max(0, math.min(1, record.charge or 0)))
    item:setCondition(math.floor((record.condition or 100) + 0.5))
    if (record.revived or 0) > 0 then item:getModData()[Units.REVIVED] = record.revived end
    return item
end

-- A battery as players read it: "Car Battery 82% (condition 64)".
function Units.batteryText(record)
    return getText("IGUI_BU_BatteryLine", getItemNameFromFullType(record.type), math.floor((record.charge or 0) * 100 + 0.5),
        math.floor((record.condition or 0) + 0.5))
end

-- A rack's charge as a share of what its batteries hold full, for its look; 0 without batteries.
function Units.rackCharge(unit)
    local sum = 0
    for _, battery in ipairs(unit.batteries or {}) do sum = sum + (battery.charge or 0) end
    return #(unit.batteries or {}) > 0 and sum / #unit.batteries or 0
end

-- The rack's overlay: batteries on one to five shelves (1-4, 5-8, 9-12, 13-16, 17 or more), lit for five levels of
-- charge. nil when empty.
function Units.rackOverlay(unit)
    local count = #(unit.batteries or {})
    if count == 0 then return nil end
    local shelf = math.min(4, math.floor((count - 1) / 4))
    local charge, level = Units.rackCharge(unit), 4
    if charge < 0.10 then level = 0 elseif charge < 0.35 then level = 1 elseif charge < 0.65 then level = 2
    elseif charge < 0.95 then level = 3 end
    if level == 0 then return "bu_solar_01_" .. (1 + shelf) end
    return "bu_solar_01_" .. (16 + (level - 1) + 4 * shelf)
end

-- Whether a character can recondition a battery: true, or false and a reason.
function Units.canRevive(character, item)
    if not Units.isBattery(item) then return false, "notBattery" end
    if (item:getModData()[Units.REVIVED] or 0) >= Units.REVIVE_TIMES then return false, "revivedOut" end
    if item:getCondition() >= Units.REVIVE_BELOW then return false, "notWorn" end
    if character:getPerkLevel(Perks.Electricity) < Units.REVIVE_SKILL then return false, "skill" end
    local inventory = character:getInventory()
    if not inventory:getFirstTagEvalRecurse(ItemTag.SCREWDRIVER, function(tool) return not tool:isBroken() end) then
        return false, "screwdriver"
    end
    if not inventory:getFirstTypeRecurse("Base.BakingSoda") then return false, "bakingSoda" end
    return true
end

return Units
