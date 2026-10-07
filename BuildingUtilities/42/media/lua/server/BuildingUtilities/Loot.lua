-- Finished solar panels as rare loot, so a player can start on solar before learning glassmaking (the recipe takes
-- glass panels). A panel is rolled as a container fills (OnFillContainer, where the world is decided: the server, or
-- the game alone), not merged into the game's distributions: the game merges those (OnPreDistributionMerge to
-- OnPostDistributionMerge) and reads them (ItemPickerJava.Parse) while a world starts, before it loads that world's
-- sandbox options (IsoWorld.init), so whether solar panels are on and how rare they are is known only by the time
-- containers fill.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Loot = {}
BU.Loot = Loot

Loot.ITEM = "BuildingUtilities.SolarPanel"
-- By room name, as the map names it (with the names the game takes for the same distribution): the weight of a panel
-- in each stock container there, on the scale of the game's own distribution weights (one roll: weight 1 is a 1
-- percent chance at loot rarity 1). Stores that would have sold one keep most in their storerooms. For comparison, the
-- game's generator crate (CrateGenerator) is about 0.4 percent of an electronics store's crates.
Loot.ROOMS = {
    toolstorestorage = 2, toolstorage = 2,
    electronicsstorage = 2,
    outdoorsupply_storage = 2,
    toolstore = 1, outdoorsupply = 1,
    electronicstore = 0.5, electronicsstore = 0.5,
    farmstorage = 0.5,
    warehouse = 0.2,
}
-- Where stock is kept: crates, cardboard boxes and metal shelves, which hold 20 to 80 and so the panel's 8 kg while not
-- full. Small boxes (10) are left out: a panel is too big for one.
Loot.CONTAINERS = { crate = true, cardboardbox = true, metal_shelves = true }

local itemWeight
local function weight()
    if not itemWeight then
        local item = getScriptManager():FindItem(Loot.ITEM)
        itemWeight = item and item:getActualWeight() or 8
    end
    return itemWeight
end

-- The chance, 0 to 1, that a container of this type in a room of this name gets a panel as it fills: the room's
-- weight times the option (SolarPanelLoot) and the game's own loot settings for the panel (its rarity, Other, and the
-- removal list; and loot that thins out as the world ages). 0 while solar panels are off.
function Loot.chance(roomName, containerType, square)
    local roomWeight = roomName and Loot.ROOMS[roomName]
    if not roomWeight or not Loot.CONTAINERS[containerType] or not BU.enabled("solar") then return 0 end
    local scale = math.max(0, BU.sandbox("SolarPanelLoot", 1))
    if scale <= 0 then return 0 end
    local options = getSandboxOptions()
    local thinning = square and options:getCurrentLootMultiplier(square) or options:getCurrentLootMultiplier()
    return math.max(0, math.min(1, roomWeight / 100 * scale * ItemPickerJava.getLootModifier(Loot.ITEM) * thinning))
end

-- As a container fills: a panel by its chance, if the container has room for it. The panel, or nil.
function Loot.fill(roomName, containerType, container)
    if not container then return nil end
    local chance = Loot.chance(roomName, containerType, container:getSourceGrid())
    if chance <= 0 or ZombRandFloat(0, 1) >= chance then return nil end
    if not container:hasRoomFor(nil, weight()) then return nil end
    return container:AddItem(Loot.ITEM)
end

-- A multiplayer client fills nothing: the server does.
if isClient() then return Loot end

Events.OnFillContainer.Add(Loot.fill)

return Loot
