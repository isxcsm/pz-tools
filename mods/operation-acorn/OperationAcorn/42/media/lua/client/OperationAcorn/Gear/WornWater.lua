-- A worn bag that holds water (the research team backpack, the game's hydration pack) in the game's fluid actions,
-- which take a fluid item as if it were in the hand. Pouring it into a barrel or a trough equips it first, and
-- equipping a worn bag takes it off the back; drinking from it and emptying it draw the bag in the hand while it stays
-- on the back. A worn bag is poured from the back, and these actions leave the hands empty for it.
require "ISUI/ISWorldObjectContextMenu"
require "TimedActions/ISAddFluidFromItemAction"
require "TimedActions/ISDrinkFluidAction"
require "Fluids/ISFluidEmptyAction"

local function worn(character, item)
    return item ~= nil and instanceof(item, "InventoryItem") and character:isEquippedClothing(item)
end

local onAddFluidFromItem = ISWorldObjectContextMenu.onAddFluidFromItem
ISWorldObjectContextMenu.onAddFluidFromItem = function(worldobjects, fluidObject, fluidItem, playerObj, ...)
    if not worn(playerObj, fluidItem) then
        return onAddFluidFromItem(worldobjects, fluidObject, fluidItem, playerObj, ...)
    end
    -- the game's own steps, without the equip
    if fluidItem:canStoreWater() and fluidObject:canTransferFluidFrom(fluidItem:getFluidContainer()) then
        if not luautils.walkAdjObject(playerObj, fluidObject, true, true) then return end
        ISTimedActionQueue.add(ISAddFluidFromItemAction:new(playerObj, fluidItem, fluidObject))
    end
end

local drinkStart = ISDrinkFluidAction.start
local function drinkStarted(self, ...)
    if worn(self.character, self.item) then self:setOverrideHandModels(nil, nil) end
    return ...
end

function ISDrinkFluidAction:start(...)
    return drinkStarted(self, drinkStart(self, ...))
end

local emptyStart = ISFluidEmptyAction.start
local function emptyStarted(self, ...)
    local owner = ISFluidUtil.validateContainer(self.container) and self.container:getOwner()
    if worn(self.character, owner) then self:setOverrideHandModels(nil, nil) end
    return ...
end

function ISFluidEmptyAction:start(...)
    return emptyStarted(self, emptyStart(self, ...))
end
