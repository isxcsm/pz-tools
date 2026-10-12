-- The battery rack (a unit, BU.Units): inside a building, wired to a panel of tier 2 or more, whose bank it is part of
-- (BU.Energy). It is a container players put car batteries in and take them out of, as any other; the save keeps a
-- record of each (Rack.sync), which the bank works on while the rack is not loaded. Also reconditioning a battery.
require "BuildingUtilities/Units"
require "BuildingUtilities/Energy"
require "BuildingUtilities/Sync"
local BU = BuildingUtilities
local Units, Panels, Sync, Energy = BU.Units, BU.Panels, BU.Sync, BU.Energy
local Rack = {}
BU.Rack = Rack

-- It stands against a W wall.
Rack.SPRITE = "bu_solar_01_0"
-- What it holds: its container takes car batteries only (Rack.acceptBattery), by weight up to WEIGHT (a battery of the
-- game weighs 5; another mod's may weigh otherwise).
Rack.WEIGHT = 100
Rack.CONTAINER = "BuildingUtilitiesRack"
Rack.ACCEPT = "BuildingUtilities.Rack.acceptBattery"
-- Reconditioning: a battery below this condition, so much better, so many times (counted in the item's modData under
-- REVIVED), taking so many uses of baking soda, from one box or several.
Rack.REVIVE_BELOW, Rack.REVIVE_GAIN, Rack.REVIVE_TIMES = 50, 25, 3
Rack.REVIVE_SKILL = 4
Rack.REVIVED = "BuildingUtilitiesRevived"
Rack.REVIVE_SODA = 2

function Rack.isBattery(item) return item ~= nil and item:hasTag(ItemTag.CAR_BATTERY) end

-- A battery's kind, as vanilla's vehicles tell them apart: 1 standard, 2 heavy-duty, 3 sports (IGUI_VehicleType_N).
-- Car batteries of other mods count as standard.
local KIND_OF = { ["Base.CarBattery1"] = 1, ["Base.CarBattery2"] = 2, ["Base.CarBattery3"] = 3 }
function Rack.batteryKind(fullType) return KIND_OF[fullType] or 1 end

-- The rack's container (made when missing). The game does not keep what a container accepts in the save, so this
-- runs again whenever the rack is loaded or shown.
function Rack.container(object)
    local container = object:getContainer()
    if not container then
        container = ItemContainer.new(Rack.CONTAINER, object:getSquare(), object)
        container:setCapacity(Rack.WEIGHT)
        container:setExplored(true)
        object:setContainer(container)
    end
    if container:getAcceptItemFunction() ~= Rack.ACCEPT then container:setAcceptItemFunction(Rack.ACCEPT) end
    return container
end

-- What a rack's container takes: car batteries (its capacity is the weight it holds).
function Rack.acceptBattery(container, item)
    return Rack.isBattery(item)
end

-- The record the save keeps of a battery in a rack: the item's id, type, charge and condition.
function Rack.batteryRecord(item)
    return { id = item:getID(), type = item:getFullType(), charge = item:getCurrentUsesFloat(),
        condition = item:getCondition() }
end

-- A battery item takes its record's charge and condition, when they differ by enough to be seen (each change goes to
-- the clients in multiplayer).
function Rack.writeBattery(item, record)
    local charge = math.max(0, math.min(1, record.charge or 0))
    local condition = math.max(0, math.min(item:getConditionMax(), math.floor((record.condition or 100) + 0.5)))
    if math.abs(item:getCurrentUsesFloat() - charge) < 0.005 and item:getCondition() == condition then return end
    item:setUsedDelta(charge)
    item:setCondition(condition)
    if isServer() then sendItemStats(item) end
end

-- A battery as players read it: "Car Battery (Heavy-Duty) 82%, condition 64, holds 2.4".
function Rack.batteryText(record)
    return getText("IGUI_BU_BatteryLine", getItemNameFromFullType(record.type),
        getText("IGUI_VehicleType_" .. Rack.batteryKind(record.type)), BU.percent((record.charge or 0) * 100),
        math.floor((record.condition or 0) + 0.5), string.format("%.1f", Energy.batteryCapacity(record)))
end

-- A rack's charge as a share of what its batteries hold full, for its look; 0 without batteries.
function Rack.charge(unit)
    local sum = 0
    for _, battery in ipairs(unit.batteries or {}) do sum = sum + (battery.charge or 0) end
    return #(unit.batteries or {}) > 0 and sum / #unit.batteries or 0
end

-- The rack's overlay: batteries on one to five shelves (1-4, 5-8, 9-12, 13-16, 17 or more), lit for five levels of
-- charge. nil when empty.
function Rack.overlay(unit)
    local count = #(unit.batteries or {})
    if count == 0 then return nil end
    local shelf = math.min(4, math.floor((count - 1) / 4))
    local charge, level = Rack.charge(unit), 4
    if charge < 0.10 then level = 0 elseif charge < 0.35 then level = 1 elseif charge < 0.65 then level = 2
    elseif charge < 0.95 then level = 3 end
    if level == 0 then return "bu_solar_01_" .. (1 + shelf) end
    return "bu_solar_01_" .. (16 + (level - 1) + 4 * shelf)
end

-- A rack shows its batteries and their charge (Rack.overlay) while its square is loaded.
function Rack.show(unit, object)
    object = object or Units.object(unit)
    if not object then return end
    Units.setOverlay(object, Rack.overlay(unit))
end

-- A rack's records follow the batteries in its container: one put in gets a record from the item, one taken out
-- loses its record, and the others' items take what the bank made of their records (Rack.writeBattery), so a
-- battery taken out has the charge and condition it had in the rack.
function Rack.sync(unit, object)
    object = object or Units.object(unit)
    if not object then return end
    local items = Rack.container(object):getAllTag(ItemTag.CAR_BATTERY, ArrayList.new())
    local known = {}
    for _, record in ipairs(unit.batteries) do
        if record.id then known[record.id] = record end
    end
    local batteries, changed = {}, #unit.batteries ~= items:size()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local record = known[item:getID()]
        if record then
            Rack.writeBattery(item, record)
        else
            record = Rack.batteryRecord(item)
            changed = true
        end
        batteries[#batteries + 1] = record
    end
    unit.batteries = batteries
    Rack.show(unit, object)
    if changed then Sync.changed(unit.panel) end
end

-- Whether a character can recondition a battery: true, or false and a reason.
function Rack.canRevive(character, item)
    if not Rack.isBattery(item) then return false, "notBattery" end
    if (item:getModData()[Rack.REVIVED] or 0) >= Rack.REVIVE_TIMES then return false, "revivedOut" end
    if item:getCondition() >= Rack.REVIVE_BELOW then return false, "notWorn" end
    if character:getPerkLevel(Perks.Electricity) < Rack.REVIVE_SKILL then return false, "skill" end
    local inventory = character:getInventory()
    if not inventory:getFirstTagEvalRecurse(ItemTag.SCREWDRIVER, function(tool) return not tool:isBroken() end) then
        return false, "screwdriver"
    end
    if select(2, Rack.bakingSoda(inventory)) < Rack.REVIVE_SODA then return false, "bakingSoda" end
    return true
end

-- The boxes of baking soda a character carries that have some left, and how many uses they have together.
function Rack.bakingSoda(inventory)
    local boxes, uses = {}, 0
    local items = inventory:getAllTypeRecurse("Base.BakingSoda")
    for i = 0, items:size() - 1 do
        local box = items:get(i)
        if box:getCurrentUses() > 0 then
            boxes[#boxes + 1] = box
            uses = uses + box:getCurrentUses()
        end
    end
    return boxes, uses
end

Units.define("rack", {
    item = "BuildingUtilities.BatteryRack",
    sprites = { Rack.SPRITE },
    utility = "power",
    minTier = BU.BANK_TIER,
    tierReason = "rackTier",
    colour = { 0.4, 0.75, 1 },
    canPlace = function(square)
        if not Panels.buildingAt(square:getX(), square:getY(), square:getZ()) then return nil, "notInBuilding" end
        return true
    end,
    sprite = function() return Rack.SPRITE end,
    create = function(unit, object)
        unit.batteries = {}
        Rack.container(object)
    end,
    -- Its container empty while it is loaded, else its records.
    isEmpty = function(unit)
        local object = Units.object(unit)
        local container = object and object:getContainer()
        if container then return container:isEmpty() end
        return #(unit.batteries or {}) == 0
    end,
    notEmptyReason = "IGUI_BU_Reason_rackNotEmpty",
    -- Loaded: what the container takes, set again; on the server its batteries and look too. A multiplayer client
    -- only sets what the container takes.
    onLoad = function(unit, object)
        if not isClient() then return Rack.sync(unit, object) end
        if object:getContainer() then Rack.container(object) end
    end,
    sync = Rack.sync,
    title = function(unit, text)
        text = getText("IGUI_BU_RackTitle", text, #unit.batteries)
        if #unit.batteries > 0 then text = text .. "  " .. BU.percent(Rack.charge(unit) * 100) end
        return text
    end,
})

return Rack
