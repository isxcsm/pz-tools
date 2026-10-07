-- Solar panels and battery racks ("units"): objects this mod puts down and wires to a main panel like a generator.
-- They are kept in the save (Store.units), not only on their squares, because they count while those are not
-- loaded. A rack is a container players put car batteries in and take them out of, as any other; the save keeps a
-- record of each (Changes.syncRack), which the bank works on while the rack is not loaded.
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
-- A rack holds this many batteries: its container takes car batteries only (Units.acceptBattery), by weight up to
-- RACK_WEIGHT (a battery weighs 5).
Units.RACK_SIZE, Units.RACK_WEIGHT = 20, 100
Units.CONTAINER = "BuildingUtilitiesRack"
Units.ACCEPT = "BuildingUtilities.Units.acceptBattery"
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

-- A battery's kind, as vanilla's vehicles tell them apart: 1 standard, 2 heavy-duty, 3 sports (IGUI_VehicleType_N).
-- Car batteries of other mods count as standard.
local KIND_OF = { ["Base.CarBattery1"] = 1, ["Base.CarBattery2"] = 2, ["Base.CarBattery3"] = 3 }
function Units.batteryKind(fullType) return KIND_OF[fullType] or 1 end

-- The rack's container (made when missing). The game does not keep what a container accepts in the save, so this
-- runs again whenever the rack is loaded or shown.
function Units.rackContainer(object)
    local container = object:getContainer()
    if not container then
        container = ItemContainer.new(Units.CONTAINER, object:getSquare(), object)
        container:setCapacity(Units.RACK_WEIGHT)
        container:setExplored(true)
        object:setContainer(container)
    end
    if container:getAcceptItemFunction() ~= Units.ACCEPT then container:setAcceptItemFunction(Units.ACCEPT) end
    return container
end

-- What a rack's container takes: car batteries, RACK_SIZE of them.
function Units.acceptBattery(container, item)
    return Units.isBattery(item) and container:getCountTag(ItemTag.CAR_BATTERY) < Units.RACK_SIZE
end

-- The record the save keeps of a battery in a rack: the item's id, type, charge, condition and reconditionings.
function Units.batteryRecord(item)
    return { id = item:getID(), type = item:getFullType(), charge = item:getCurrentUsesFloat(),
        condition = item:getCondition(), revived = item:getModData()[Units.REVIVED] or 0 }
end

-- A battery item takes its record's charge and condition, when they differ by enough to be seen (each change goes to
-- the clients in multiplayer).
function Units.writeBattery(item, record)
    local charge = math.max(0, math.min(1, record.charge or 0))
    local condition = math.max(0, math.min(item:getConditionMax(), math.floor((record.condition or 100) + 0.5)))
    if math.abs(item:getCurrentUsesFloat() - charge) < 0.005 and item:getCondition() == condition then return end
    item:setUsedDelta(charge)
    item:setCondition(condition)
    if isServer() then sendItemStats(item) end
end

-- A battery as players read it: "Car Battery (Heavy-Duty) 82%, condition 64, holds 2.4".
function Units.batteryText(record)
    return getText("IGUI_BU_BatteryLine", getItemNameFromFullType(record.type),
        getText("IGUI_VehicleType_" .. Units.batteryKind(record.type)), BU.percent((record.charge or 0) * 100),
        math.floor((record.condition or 0) + 0.5), string.format("%.1f", BU.Energy.batteryCapacity(record)))
end

-- Whether a unit holds nothing, so that it can be taken down: a rack's container empty (its records while it is
-- not loaded); a solar panel always.
function Units.isEmpty(unit)
    if unit.kind ~= "rack" then return true end
    local object = Units.object(unit)
    local container = object and object:getContainer()
    if container then return container:isEmpty() end
    return #(unit.batteries or {}) == 0
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
