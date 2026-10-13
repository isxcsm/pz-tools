-- What this mod adds to the world's loot, each rolled as a container fills (OnFillContainer, where the world is
-- decided: the server, or the game alone), not merged into the game's distributions: the game merges those
-- (OnPreDistributionMerge to OnPostDistributionMerge) and reads them (ItemPickerJava.Parse) while a world starts, before
-- it loads that world's sandbox options (IsoWorld.init), so what is on and how rare it is is known only by the time
-- containers fill.
--   - finished solar panels, so a player can start on solar before learning glassmaking (the recipe takes glass
--     panels);
--   - used water machines where a farm or a shop would have kept one: pumps and sprinklers, and filters with part of
--     their media spent (it rides on the item: Units' keep);
--   - the two volumes of the water systems magazine, which teach the water machines' recipes (a player with the
--     skill learns them without: the recipes' AutoLearnAny).
require "BuildingUtilities/Core"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Loot = {}
BU.Loot = Loot

-- Where stock is kept: crates, cardboard boxes and metal shelves, which hold 20 to 80 and so a machine of a few kilos
-- while not full. Small boxes (10) are left out: a machine is too big for one.
local STOCK = { crate = true, cardboardbox = true, metal_shelves = true }
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
    { item = "BuildingUtilities.WaterFilter", features = { "filter" }, option = "WaterLoot", containers = STOCK,
      onAdd = usedFilter,
      rooms = { plumber = 2, toolstorestorage = 0.5, toolstorage = 0.5, outdoorsupply_storage = 0.5,
                farmstorage = 0.3, garagestorage = 0.03 } },
    { item = "BuildingUtilities.WaterSystemsMag1", features = { "pump", "sprinkler" }, option = "WaterLoot",
      containers = PRINT,
      rooms = { bookstore = 1.5, bookstorage = 1.5, bookstorestorage = 1.5, gardenstore = 1.5, library = 0.6,
                toolstore = 1, toolstorestorage = 0.6, farmstorage = 0.8, barn = 0.4, shed = 0.3,
                garagestorage = 0.05 } },
    { item = "BuildingUtilities.WaterSystemsMag2", features = { "booster", "filter" }, option = "WaterLoot",
      containers = PRINT,
      rooms = { plumber = 3, bookstore = 0.8, bookstorage = 0.8, bookstorestorage = 0.8, library = 0.4,
                universitylibrary = 0.6, toolstore = 0.6, toolstorestorage = 0.6, outdoorsupply = 0.6,
                garagestorage = 0.03 } },
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

-- As a container fills: each table's item by its chance, if the container has room for it.
function Loot.fill(roomName, containerType, container)
    if not container or not roomName then return end
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
end

-- A multiplayer client fills nothing: the server does.
if isClient() then return Loot end

Events.OnFillContainer.Add(Loot.fill)

return Loot
