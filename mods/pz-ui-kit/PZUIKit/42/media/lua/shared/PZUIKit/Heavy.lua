-- Heavy things: items carried in both hands as a generator is (their script's RequiresEquippedBothHands) that stand in
-- the world as their mod's object. A mod registers its item types with how one stands up (Heavy.register); the kit
-- does the rest the same way for every mod:
--   - let go to the floor, one stands up where it falls, not lying there as an item: dropped or moved to the floor
--     (ISTransferAction), let go from the hands (forceDropHeavyItems, ISUnequipAction but to drop or place), out of a
--     vehicle (ISDropVehicleItemAction); where its mod says it cannot stand, it lies as the item;
--   - one lying taken up is taken off the floor: the game's taking up of a heavy item (ISEquipHeavyItem) moves it into
--     the hands but leaves it lying too;
--   - the game's own "equip in both hands" is taken off its menu: it would say the same as the mod's taking up, and a
--     generator shows only its take option (Heavy.carryOption is that option).
-- Taking any heavy item up also refreshes the loot window when alone: the game's ISEquipHeavyItem does it only in
-- multiplayer, so a container's view (and what a mod does when one goes empty) lagged until the character moved.
-- The game's functions load after this file: wrapped once a game is on.
PZUIKit = PZUIKit or {}
local Heavy = {}
PZUIKit.Heavy = Heavy

-- item full type -> { canStand = function(item, character, square) (optional), stand = function(item, character,
-- square, facing) }
local defs = {}

-- Registers item types (a full type or a list) as heavy things of a mod. `def.stand(item, character, square, facing)`
-- makes the object of an item let go on a square (the item is off the floor by then: the mod uses it up);
-- `def.canStand(item, character, square)` says whether it can stand there (else it lies as the item); `facing` is
-- Heavy.facing's.
function Heavy.register(fullTypes, def)
    if type(fullTypes) ~= "table" then fullTypes = { fullTypes } end
    for _, fullType in ipairs(fullTypes) do defs[fullType] = def end
end

-- Whether an item is a registered heavy thing.
function Heavy.isHeavy(item)
    return item ~= nil and defs[item:getFullType()] ~= nil
end

-- The side of a square a character stands on: S, E, N or W.
function Heavy.side(square, character)
    local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
    if math.abs(dx) > math.abs(dy) then return dx > 0 and "E" or "W" end
    return dy > 0 and "S" or "N"
end

-- The side a thing set down on a square faces: the character's, from a square beside it, or back the way they look
-- from on it.
local BACK = { N = "S", S = "N", E = "W", W = "E" }
function Heavy.facing(square, character)
    if not character then return "S" end
    if character:getCurrentSquare() ~= square then return Heavy.side(square, character) end
    local forward = character:getForwardDirection()
    local fx, fy = forward:getX(), forward:getY()
    local ahead = math.abs(fx) > math.abs(fy) and (fx > 0 and "E" or "W") or (fy > 0 and "S" or "N")
    return BACK[ahead]
end

-- Into both hands, as the game holds a generator.
function Heavy.hold(character, item)
    character:setPrimaryHandItem(item)
    character:setSecondaryHandItem(item)
    if isServer() then sendEquip(character) end
end

-- Out of the hands, when it is in them.
function Heavy.letGo(character, item)
    if character:getPrimaryHandItem() ~= item and character:getSecondaryHandItem() ~= item then return end
    character:removeFromHands(item)
    if isServer() then sendEquip(character) end
end

-- A new item of the type into the inventory and both hands (a heavy item held already let go first, as the game does
-- before a generator is taken up), with `mod` written into its modData. Returns the item.
function Heavy.give(character, fullType, mod)
    forceDropHeavyItems(character)
    local item = instanceItem(fullType)
    if not item then return nil end
    if mod then
        local md = item:getModData()
        for k, v in pairs(mod) do md[k] = v end
    end
    local inventory = character:getInventory()
    inventory:AddItem(item)
    sendAddItemToContainer(inventory, item)
    Heavy.hold(character, item)
    inventory:setDrawDirty(true)
    return item
end

-- The square an item lying on the floor is on, its world item taken off it (as the game does taking an item off the
-- floor); nil when it is not lying anywhere.
function Heavy.takeOffFloor(item)
    local world = item:getWorldItem()
    local square = world and world:getSquare()
    if not square then return nil end
    square:transmitRemoveItemFromSquare(world)
    square:removeWorldObject(world)
    item:setWorldItem(nil)
    return square
end

local function refreshLoot()
    if not isServer() and ISInventoryPage then ISInventoryPage.renderDirty = true end
end

-- Stands a registered item lying on the floor up as its mod's object. Returns whether it did.
function Heavy.settle(item, character)
    local def = item and character and defs[item:getFullType()]
    if not def then return false end
    local world = item:getWorldItem()
    local square = world and world:getSquare()
    if not square then return false end
    if def.canStand and not def.canStand(item, character, square) then return false end
    Heavy.takeOffFloor(item)
    local floor = item:getContainer()
    if floor then floor:DoRemoveItem(item) end
    def.stand(item, character, square, Heavy.facing(square, character))
    refreshLoot()
    return true
end

local function wrap()
    if Heavy.wrapped then return end
    Heavy.wrapped = true
    local transfer = ISTransferAction and ISTransferAction.transferItem
    if transfer then
        function ISTransferAction:transferItem(character, item, srcContainer, destContainer, dropSquare)
            local moved = transfer(self, character, item, srcContainer, destContainer, dropSquare)
            if destContainer and destContainer:getType() == "floor" then Heavy.settle(moved or item, character) end
            return moved
        end
    end
    local forceDrop = forceDropHeavyItems
    if forceDrop then
        function forceDropHeavyItems(character)
            local primary = character and character:getPrimaryHandItem()
            local secondary = character and character:getSecondaryHandItem()
            forceDrop(character)
            Heavy.settle(primary, character)
            if secondary ~= primary then Heavy.settle(secondary, character) end
        end
    end
    local unequip = ISUnequipAction and ISUnequipAction.complete
    if unequip then
        function ISUnequipAction:complete()
            local done = unequip(self)
            if self.reason ~= "drop" and self.reason ~= "place" then Heavy.settle(self.item, self.character) end
            return done
        end
    end
    local takeUp = ISEquipHeavyItem and ISEquipHeavyItem.complete
    if takeUp then
        function ISEquipHeavyItem:complete()
            if Heavy.isHeavy(self.item) then Heavy.takeOffFloor(self.item) end
            local done = takeUp(self)
            if not isClient() then refreshLoot() end
            return done
        end
    end
    local outOfVehicle = ISDropVehicleItemAction and ISDropVehicleItemAction.complete
    if outOfVehicle then
        function ISDropVehicleItemAction:complete()
            local done = outOfVehicle(self)
            Heavy.settle(self.item, self.character)
            return done
        end
    end
end
Heavy.wrap = wrap
Events.OnGameStart.Add(wrap)

-- The mod's taking up into both hands, on top of an item's menu: not while it is held, and not in a vehicle (shown,
-- unavailable, with `vehicleTip` as its tooltip when given). Returns the option, or nil.
function Heavy.carryOption(context, character, item, text, vehicleTip)
    if character:isItemInBothHands(item) then return nil end
    local option = context:addOptionOnTop(text, character, ISInventoryPaneContextMenu.equipHeavyItem, item)
    option.itemForTexture = item
    if character:getVehicle() then
        option.notAvailable = true
        if vehicleTip then
            local tip = ISInventoryPaneContextMenu.addToolTip()
            tip.description = vehicleTip
            option.toolTip = tip
        end
    end
    return option
end

-- The game's "equip in both hands" off a registered item's menu.
Events.OnFillInventoryObjectContextMenu.Add(function(player, context, items)
    for _, entry in ipairs(items or {}) do
        local item = entry
        if type(item) == "table" and item.items then item = item.items[1] end
        if Heavy.isHeavy(item) then
            context:removeOptionByName(getText("ContextMenu_Equip_Two_Hands"))
            return
        end
    end
end)

return Heavy
