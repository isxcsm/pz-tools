-- What this mod adds to the world's loot, each rolled as a container fills (OnFillContainer, where the world is
-- decided: the server, or the game alone), not merged into the game's distributions: the game merges those
-- (OnPreDistributionMerge to OnPostDistributionMerge) and reads them (ItemPickerJava.Parse) while a world starts, before
-- it loads that world's sandbox options (IsoWorld.init), so what is on and how rare it is is known only by the time
-- containers fill.
--   - finished solar panels, so a player can start on solar before learning glassmaking (the recipe takes glass
--     panels);
--   - used water machines where a farm or a shop would have kept one: pumps and sprinklers, and filters with part of
--     their media spent (it rides on the item: Units' keep); fire sprinkler heads where a plumber or a warehouse kept
--     spares;
--   - the two volumes of the water systems magazine, which teach the water machines' recipes (a player with the
--     skill learns them without: the recipes' AutoLearnAny);
--   - control boards in the stock of electronics and tool stores, warehouses and factories;
--   - utility panels where the game keeps generators (Loot.fillBox), the only way to a first one: its recipe is
--     learned from one (ISBUReverseEngineer).
require "BuildingUtilities/Core"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Loot = {}
BU.Loot = Loot

-- Where stock is kept: crates, cardboard boxes and metal shelves, which hold 20 to 80 and so a machine of a few kilos
-- while not full. Small boxes (10) are left out: a machine is too big for one.
local STOCK = { crate = true, cardboardbox = true, metal_shelves = true }
-- Where a control board is kept: the stock containers and a store's shelves and counters.
local PARTS = { crate = true, cardboardbox = true, metal_shelves = true, shelves = true, counter = true }
-- Where a magazine lies: the stock containers and the shelves, counters and small boxes of shops and libraries.
local PRINT = { crate = true, cardboardbox = true, metal_shelves = true, shelves = true, counter = true,
    smallbox = true, desk = true }

-- A filter found used: some of its media left (a share of a charge, at random between these).
local USED_MEDIA = { 0.1, 0.5 }

local function usedFilter(item)
    local share = USED_MEDIA[1] + ZombRandFloat(0, 1) * (USED_MEDIA[2] - USED_MEDIA[1])
    BU.Units.keepOnItem("filter", item, { media = BU.WaterUnits.FILTER_HOURS * share })
end

-- Each: the item; features (any of them on lets it be found); the option that scales it; and by room name, as the map
-- names it (tools/room_names.py lists them), the weight of one in each container of the kinds there, on the scale of
-- the game's own distribution weights (one roll: weight 1 is a 1 percent chance at loot rarity 1); onAdd(item) as it
-- is added. Stores that would have sold one keep most in their storerooms. For comparison, the game's generator crate
-- (CrateGenerator) is about 0.4 percent of an electronics store's crates.
Loot.TABLES = {
    { item = "BuildingUtilities.SolarPanel", features = { "solar" }, option = "SolarPanelLoot", containers = STOCK,
      rooms = { toolstorestorage = 2, toolstorage = 2, electronicsstorage = 2, outdoorsupply_storage = 2,
                toolstore = 1, outdoorsupply = 1, electronicstore = 0.5, electronicsstore = 0.5, farmstorage = 0.5,
                warehouse = 0.2 } },
    { item = "BuildingUtilities.WaterPump", features = { "pump" }, option = "WaterLoot", containers = STOCK,
      rooms = { farmstorage = 1, gardeningstorage = 1, plumber = 1, toolstorestorage = 0.5, toolstorage = 0.5,
                barn = 0.4, shed = 0.2, garagestorage = 0.05 } },
    { item = "BuildingUtilities.Sprinkler", features = { "sprinkler" }, option = "WaterLoot", containers = STOCK,
      rooms = { gardenstore = 2, gardeningstorage = 2, greenhouse = 1.5, farmstorage = 1.5, barn = 0.8, shed = 0.4,
                garagestorage = 0.05 } },
    { item = "BuildingUtilities.FireSprinkler", features = { "firesprinkler" }, option = "WaterLoot", containers = STOCK,
      rooms = { plumber = 2, toolstorestorage = 0.6, toolstorage = 0.6, warehouse = 0.4, factorystorage = 0.4,
                garagestorage = 0.03 } },
    { item = "BuildingUtilities.WaterFilter", features = { "filter" }, option = "WaterLoot", containers = STOCK,
      onAdd = usedFilter,
      rooms = { plumber = 2, toolstorestorage = 0.5, toolstorage = 0.5, outdoorsupply_storage = 0.5,
                farmstorage = 0.3, garagestorage = 0.03 } },
    { item = "BuildingUtilities.WaterSystemsMag1", features = { "pump", "sprinkler" }, option = "WaterLoot",
      containers = PRINT,
      rooms = { bookstore = 1.5, bookstorage = 1.5, bookstorestorage = 1.5, gardenstore = 1.5, library = 0.6,
                toolstore = 1, toolstorestorage = 0.6, farmstorage = 0.8, barn = 0.4, shed = 0.3,
                garagestorage = 0.05 } },
    { item = "BuildingUtilities.WaterSystemsMag2", features = { "booster", "filter", "firesprinkler" }, option = "WaterLoot",
      containers = PRINT,
      rooms = { plumber = 3, bookstore = 0.8, bookstorage = 0.8, bookstorestorage = 0.8, library = 0.4,
                universitylibrary = 0.6, toolstore = 0.6, toolstorestorage = 0.6, outdoorsupply = 0.6,
                garagestorage = 0.03 } },
    -- Some four to six in a town's stores, storerooms and warehouses.
    { item = "BuildingUtilities.ControlBoard", features = { "panel" }, option = "BreakerBoxLoot", containers = PARTS,
      rooms = { electronicsstorage = 15, electronicstore = 5, electronicsstore = 5, radioshipping = 10,
                wirefactory = 10, toolstorestorage = 6, toolstorage = 6, factorystorage = 3, factory = 1.5,
                warehouse = 1.5, mechanic = 0.5 } },
}
-- The solar panel's table: what Loot.chance asks about when told no other.
Loot.SOLAR = Loot.TABLES[1]
Loot.ITEM = Loot.SOLAR.item

local weights = {}
local function weight(item)
    local w = weights[item]
    if not w then
        local script = getScriptManager():FindItem(item)
        w = script and script:getActualWeight() or 8
        weights[item] = w
    end
    return w
end

local function anyOn(features)
    for _, feature in ipairs(features) do
        if BU.enabled(feature) then return true end
    end
    return false
end

-- The chance, 0 to 1, that a container of this type in a room of this name gets one of a table's item (the solar
-- panel's without a table) as it fills: the room's weight times the table's option and the game's own loot settings
-- for the item (its rarity, and the removal list; and loot that thins out as the world ages). 0 while its features are
-- off.
function Loot.chance(roomName, containerType, square, entry)
    entry = entry or Loot.SOLAR
    local roomWeight = roomName and entry.rooms[roomName]
    if not roomWeight or not entry.containers[containerType] or not anyOn(entry.features) then return 0 end
    local scale = math.max(0, BU.sandbox(entry.option, 1))
    if scale <= 0 then return 0 end
    local options = getSandboxOptions()
    local thinning = square and options:getCurrentLootMultiplier(square) or options:getCurrentLootMultiplier()
    return math.max(0, math.min(1, roomWeight / 100 * scale * ItemPickerJava.getLootModifier(entry.item) * thinning))
end

-- Utility panels where the game keeps generators: BOX_SHARE of the game's own chance of one in a container, new and
-- of tier 1. A building's container goes by its room's distribution, a vehicle's by the vehicle's (its normal lists,
-- or as often as its script says one of its special ones). The chance is worked out of the game's tables the first
-- time a kind of container fills, the way the game's loot tool reckons it: each roll an item comes at its weight
-- times its loot modifier, a hundredth; junk at 1.4 times its weight, unmodified. Where one is put, the container's
-- owner (its object, or the vehicle's part) is marked (BU.BOX_MARK), so that the loot window looks only at those
-- (Finds.lua). As often as a generator: the box opens the mod's content, it is not a rarity to hold the start back.
Loot.BOX_SHARE = 1

-- The game's generators: Generator and its colours (Generator_Blue, ...).
local function isGenerator(name)
    local short = type(name) == "string" and name:match("([^%.]+)$") or nil
    return short == "Generator" or short ~= nil and short:sub(1, 10) == "Generator_"
end

-- The chance a list of a distribution ({ rolls, items, junk }) puts a generator in.
local function listChance(list)
    if type(list) ~= "table" then return 0 end
    local miss = 1
    local function roll(part, junk)
        if type(part) ~= "table" or type(part.items) ~= "table" then return end
        local rolls = part.rolls or 1
        for i = 1, #part.items - 1, 2 do
            local name, weight = part.items[i], part.items[i + 1]
            if isGenerator(name) and type(weight) == "number" then
                local each = junk and weight * 1.4 / 100 or weight * ItemPickerJava.getLootModifier(name) / 100
                miss = miss * (1 - math.max(0, math.min(1, each))) ^ rolls
            end
        end
    end
    roll(list, false)
    roll(list.junk, true)
    return 1 - miss
end

-- A container's distribution: a list, or procedural (each list it may take, by its weight; alike without weights).
local function distributionChance(distribution)
    if type(distribution) ~= "table" then return 0 end
    if not distribution.procedural then return listChance(distribution) end
    local lists = ProceduralDistributions and ProceduralDistributions.list or {}
    local total, weighted, count, plain = 0, 0, 0, 0
    for _, entry in ipairs(distribution.procList or {}) do
        local chance = listChance(lists[entry.name])
        local each = entry.weightChance or 0
        total, weighted = total + each, weighted + each * chance
        count, plain = count + 1, plain + chance
    end
    if total > 0 then return weighted / total end
    return count > 0 and plain / count or 0
end

-- A vehicle's container: its distribution by its script's name and skin, the normal lists most of the time and one
-- of its special ones as often as its script says (8 percent without).
local function vehicleChance(vehicleName, containerType, vehicle)
    local tables = VehicleDistributions and VehicleDistributions[1]
    if not tables then return 0 end
    local distribution = tables[vehicleName .. vehicle:getSkinIndex()] or tables[vehicleName]
    if type(distribution) ~= "table" then return 0 end
    local normal = listChance(distribution.Normal and distribution.Normal[containerType])
    local special, count = 0, 0
    for _, each in ipairs(distribution.Specific or {}) do
        special, count = special + listChance(each[containerType]), count + 1
    end
    if count == 0 then return normal end
    local script = vehicle:getScript()
    local share = script and script:getSpecialLootChance() or 0
    if share <= 0 then share = 8 end
    share = math.min(100, share) / 100
    return (1 - share) * normal + share * special / count
end

-- The game's own chance of a generator in a container as it fills, kept by its kind (room and container type, or
-- vehicle, skin and container type). roomName: a vehicle's script name for one of its containers.
local generatorChances = {}
function Loot.generatorChance(roomName, containerType, container)
    local part = container and container:getVehiclePart()
    local vehicle = part and part:getVehicle()
    local key = vehicle and roomName .. vehicle:getSkinIndex() .. "/" .. containerType or roomName .. "/" .. containerType
    local chance = generatorChances[key]
    if chance == nil then
        if vehicle then
            chance = vehicleChance(roomName, containerType, vehicle)
        else
            local rooms = SuburbsDistributions
            local room = rooms and rooms[roomName]
            chance = distributionChance(type(room) == "table" and room[containerType] or nil)
        end
        generatorChances[key] = chance
    end
    return chance
end

-- Its chance in a container, its option and the game's loot thinning out with the world's age over it. 0 while
-- neither utility is on.
function Loot.boxChance(roomName, containerType, container)
    if not BU.enabled("panel") then return 0 end
    local scale = math.max(0, BU.sandbox("BreakerBoxLoot", 1))
    if scale <= 0 then return 0 end
    local generator = Loot.generatorChance(roomName, containerType, container)
    if generator <= 0 then return 0 end
    local square = container:getSourceGrid()
    local options = getSandboxOptions()
    local thinning = square and options:getCurrentLootMultiplier(square) or options:getCurrentLootMultiplier()
    return math.max(0, math.min(1, generator * Loot.BOX_SHARE * scale * thinning))
end

-- A utility panel into a container by its chance, its owner marked.
function Loot.fillBox(roomName, containerType, container)
    local chance = Loot.boxChance(roomName, containerType, container)
    if chance <= 0 or ZombRandFloat(0, 1) >= chance or not container:hasRoomFor(nil, weight(BU.PANEL_ITEM)) then return end
    if not container:AddItem(BU.PANEL_ITEM) then return end
    local part = container:getVehiclePart()
    local owner = part or container:getParent()
    if owner then owner:getModData()[BU.BOX_MARK] = true end
end

-- As a container fills: each table's item by its chance, if the container has room for it; a utility panel where
-- the game keeps generators. A zombie's inventory fills with no container type (roomName "Zombie"): nothing of ours.
-- A bag rolled inside a container fires the event with its loot table (an ItemPickerContainer) for the container: skipped.
function Loot.fill(roomName, containerType, container)
    if not roomName or not containerType or not instanceof(container, "ItemContainer") then return end
    local square = container:getSourceGrid()
    for _, entry in ipairs(Loot.TABLES) do
        if entry.rooms[roomName] then
            local chance = Loot.chance(roomName, containerType, square, entry)
            if chance > 0 and ZombRandFloat(0, 1) < chance and container:hasRoomFor(nil, weight(entry.item)) then
                local item = container:AddItem(entry.item)
                if item and entry.onAdd then entry.onAdd(item) end
            end
        end
    end
    Loot.fillBox(roomName, containerType, container)
end

-- A multiplayer client fills nothing: the server does.
if isClient() then return Loot end

Events.OnFillContainer.Add(Loot.fill)

return Loot
