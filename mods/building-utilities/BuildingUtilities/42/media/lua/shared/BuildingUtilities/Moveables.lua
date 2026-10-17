-- A breaker box and the units (solar panels, battery racks, pumps, filters, boosters, sprinklers) are the game's
-- furniture: their items are Moveables, put down with the game's furniture cursor (the inventory's 배치하기), turned
-- with its rotate key through the looks a kind has, and taken up with its pick up mode. This file adds what the game
-- does not know:
--   - taking up: the object's lines and its record go, a share of what its lines took comes back, and its item goes
--     into the inventory, when it fits as the game asks of its own furniture of one tile; a rack holding batteries, or
--     a unit that is not empty, is not taken up (Units.isEmpty);
--   - putting down obeys the kind's rules (Panels.canInstall, Units.canInstall: the tool's panel says why not) and
--     makes the box or the unit as this mod does (BU.Changes), facing as the cursor was turned;
--   - the faces: each kind's looks for the sides (a box's tier's: BU.panelSprite, the units' sprite(nil, side)) as the
--     tool's offsets;
--   - a unit whose look depends on its square (lookBySquare: a fire sprinkler hangs or stands) shows under the cursor
--     as it would be put down there.
-- A box's item is its tier's (BU.PANEL_ITEMS): taken up, a box gives its tier's, and puts its tier's down.
-- A placed one is not turned with the tool (its record keeps how it faces), nor scrapped.
require "Moveables/ISMoveableSpriteProps"
require "BuildingUtilities/Units"
require "BuildingUtilities/Panels"
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/Changes"
require "BuildingUtilities/Costs"
local BU = BuildingUtilities
local Moveables = {}
BU.Moveables = Moveables

-- This mod's tiles that are objects to take up: "panel" or a unit's kind, by sprite name; worked out once the units
-- are defined (the first time the tool asks).
local kinds
local function kindOf(spriteName)
    if not kinds then
        kinds = {}
        -- every look a box shows (its tier, its place, its lamps)
        for _, name in ipairs(BU.PanelLook.ALL) do kinds[name] = "panel" end
        for _, kind in ipairs(BU.Units.KINDS) do
            for _, name in ipairs(BU.Units.definition(kind).sprites or {}) do kinds[name] = kind end
        end
    end
    return spriteName and kinds[spriteName]
end

-- The item a kind is taken up as: a box's of its tier.
local function itemType(kind, tier)
    return kind == "panel" and BU.PANEL_ITEMS[tier or 1] or BU.Units.definition(kind).item
end

-- The tier of a box's sprite (1 for any other).
local function spriteTier(spriteName)
    local shown = BU.PanelLook.ofSprite(spriteName)
    return shown and shown.tier or 1
end

-- An item of the type, made once, for the tool's name and weight.
local items = {}
local function itemOf(kind, tier)
    local fullType = itemType(kind, tier)
    local item = items[fullType]
    if item == nil then
        item = instanceItem(fullType) or false
        items[fullType] = item
    end
    return item or nil
end

-- The box or the unit of the kind on the square: { panel } or { unit }, from the object the tool names or the
-- square's objects.
local function recordOf(kind, object)
    if kind == "panel" then
        local panel = object and BU.Panels.ofObject(object)
        return panel and { panel = panel } or nil
    end
    local unit = object and BU.Units.ofObject(object)
    return unit and unit.kind == kind and { unit = unit } or nil
end

local function find(kind, square, object)
    local found = recordOf(kind, object)
    if found or not square then return found end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        found = recordOf(kind, objects:get(i))
        if found then return found end
    end
    return nil
end

-- The kind's tile on the square with no record of this mod's: a spawned box (BU.Spawned), or a box or unit whose
-- record the save lost. It is taken up as its look says, a unit holding nothing (a rack's batteries are in its
-- container); nil when there is none.
local function bare(kind, object)
    local sprite = object and object:getSprite()
    if not sprite or kindOf(sprite:getName()) ~= kind then return nil end
    if BU.Panels.ofObject(object) or BU.Units.ofObject(object) then return nil end
    local container = object:getContainer()
    if container and not container:isEmpty() then return nil end
    return object
end

local function bareOf(kind, square, object)
    local found = bare(kind, object)
    if found or not square then return found end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        found = bare(kind, objects:get(i))
        if found then return found end
    end
    return nil
end

-- A kind's look for each side it can face, by side (BU.SIDES), each look once (a box's of its tier, indoors): worked
-- out once a kind and tier.
local facesByKind = {}
local function facesOf(kind, tier)
    local key = kind == "panel" and kind .. (tier or 1) or kind
    local faces = facesByKind[key]
    if faces then return faces end
    faces = {}
    local seen = {}
    for _, side in ipairs(BU.SIDES) do
        local sprite = kind == "panel" and BU.panelSprite(side, tier) or BU.Units.spriteFacing(kind, nil, side)
        if sprite and not seen[sprite] then
            seen[sprite] = true
            faces[side] = sprite
        end
    end
    facesByKind[key] = faces
    return faces
end

-- The side a look of a kind faces, or nil.
local function sideOf(kind, spriteName, tier)
    for side, sprite in pairs(facesOf(kind, tier)) do
        if sprite == spriteName then return side end
    end
    return nil
end

-- The tool turns a tile through its faces by offsets in its sheet (the game reads them from the tile's properties).
local OFFSET = { N = "Noffset", E = "Eoffset", S = "Soffset", W = "Woffset" }
local function setFaces(s, kind)
    local own = sideOf(kind, s.spriteName, s.buTier)
    if not own or not s.sheetName or not s.spriteID then return end
    local any = false
    for side, sprite in pairs(facesOf(kind, s.buTier)) do
        local id = string.sub(sprite, 1, #s.sheetName) == s.sheetName and tonumber(string.sub(sprite, #s.sheetName + 1))
        if side ~= own and id then
            s[OFFSET[side]] = id - s.spriteID
            any = true
        end
    end
    if any then s.facing = own end
end

local new = ISMoveableSpriteProps.new
function ISMoveableSpriteProps.new(sprite)
    local s = new(sprite)
    local kind = s and kindOf(s.spriteName)
    if kind then
        s.buKind = kind
        s.buTier = kind == "panel" and spriteTier(s.spriteName) or nil
        s.isMoveable = true
        s.canScrap = false
        s.type = "Object"
        s.isMultiSprite = false
        s.customItem, s.pickUpTool, s.placeTool, s.pickUpLevel = nil, nil, nil, 0
        -- what the tool sets for its own moveables from tile properties these tiles do not have: no other faces, nothing
        -- linked, no wall overlay, one item
        s.Noffset, s.Soffset, s.Woffset, s.Eoffset = 0, 0, 0, 0
        s.linkedOffset, s.linkedLoc, s.isClosedState, s.wallOverlay = 0, nil, false, false
        s.ignoreSurfaceSnap, s.isGridExtensionTile, s.allowDoorFrame, s.isForceSingleItem = false, false, false, false
        local item = itemOf(kind, s.buTier)
        if item then
            s.name = item:getName()
            s.weight = item:getActualWeight()
            s.rawWeight = s.weight * 10
        end
        setFaces(s, kind)
    end
    return s
end

-- A box is a heavy item carried in both hands, as a generator is (its script: RequiresEquippedBothHands, heavyitem):
-- taken up, it is held; put down or taken apart, the hands are let go. The game drops a heavy item that leaves the
-- hands on the floor, and its own tool looks for an item to put down in the inventory but not the hands: a box is
-- looked for in the hands too.
function Moveables.hold(character, item)
    character:setPrimaryHandItem(item)
    character:setSecondaryHandItem(item)
    if isServer() then sendEquip(character) end
end

function Moveables.letGo(character, item)
    if character:getPrimaryHandItem() ~= item and character:getSecondaryHandItem() ~= item then return end
    character:removeFromHands(item)
    if isServer() then sendEquip(character) end
end

-- A box let go of where it lands stands there as a generator does, not lying as an item: put down as on install,
-- facing the character (turned to none), or bare (Spawned's look, to activate: ISBUActivateBox) when the square
-- cannot have a box now (Panels.canInstall). One where a box stands already stays an item.
local function hasBox(square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local sprite = objects:get(i):getSprite()
        if sprite and kindOf(sprite:getName()) == "panel" then return true end
    end
    return false
end

-- The side a box set down on a square faces: the character's, from a square beside it, or back the way they look.
local BACK = { N = "S", S = "N", E = "W", W = "E" }
local function facingCharacter(square, character)
    if not character then return "S" end
    if character:getCurrentSquare() ~= square then return BU.sideOf(square, character) end
    local forward = character:getForwardDirection()
    local fx, fy = forward:getX(), forward:getY()
    local ahead = math.abs(fx) > math.abs(fy) and (fx > 0 and "E" or "W") or (fy > 0 and "S" or "N")
    return BACK[ahead]
end

-- The square a box lying as an item is on, its item taken off it (as the game does taking an item off the floor).
local function takeOffFloor(item)
    local world = item:getWorldItem()
    local square = world and world:getSquare()
    if not square then return nil end
    square:transmitRemoveItemFromSquare(world)
    square:removeWorldObject(world)
    item:setWorldItem(nil)
    return square
end

function Moveables.settle(item, character)
    if not item or not BU.PANEL_ITEM_TIER[item:getFullType()] then return end
    local world = item:getWorldItem()
    local square = world and world:getSquare()
    if not square or hasBox(square) then return end
    takeOffFloor(item)
    local floor = item:getContainer()
    if floor then floor:DoRemoveItem(item) end
    local side = facingCharacter(square, character)
    local tier = BU.Panels.itemTier(item)
    if BU.Panels.canInstall(square) then
        BU.Changes.install(square, side, { tier = tier })
    else
        local object = IsoObject.new(square, BU.panelSprite(side, tier, square:getRoom() == nil), nil, false)
        square:AddTileObject(object)
        if isServer() then object:transmitCompleteItemToClients() end
    end
    if not isServer() and ISInventoryPage then ISInventoryPage.renderDirty = true end
end

-- Where the game lets an item go to the floor: dropped or moved there (ISTransferAction), a heavy item let go
-- (forceDropHeavyItems, ISUnequipAction but to drop or place), out of a vehicle (ISDropVehicleItemAction). They are
-- the game's, loaded after this file: wrapped once a game is on.
local function wrapDrops()
    if Moveables.dropsWrapped then return end
    Moveables.dropsWrapped = true
    local transfer = ISTransferAction and ISTransferAction.transferItem
    if transfer then
        function ISTransferAction:transferItem(character, item, srcContainer, destContainer, dropSquare)
            local moved = transfer(self, character, item, srcContainer, destContainer, dropSquare)
            if destContainer:getType() == "floor" then Moveables.settle(moved or item, character) end
            return moved
        end
    end
    local forceDrop = forceDropHeavyItems
    if forceDrop then
        function forceDropHeavyItems(character)
            local primary = character and character:getPrimaryHandItem()
            local secondary = character and character:getSecondaryHandItem()
            forceDrop(character)
            Moveables.settle(primary, character)
            if secondary ~= primary then Moveables.settle(secondary, character) end
        end
    end
    local unequip = ISUnequipAction and ISUnequipAction.complete
    if unequip then
        function ISUnequipAction:complete()
            local done = unequip(self)
            if self.reason ~= "drop" and self.reason ~= "place" then Moveables.settle(self.item, self.character) end
            return done
        end
    end
    -- The game's taking up of a heavy item moves it into the hands but leaves it lying too (its own lie as objects):
    -- a box lying as an item is taken off the floor.
    local takeUp = ISEquipHeavyItem and ISEquipHeavyItem.complete
    if takeUp then
        function ISEquipHeavyItem:complete()
            if self.item and BU.PANEL_ITEM_TIER[self.item:getFullType()] then takeOffFloor(self.item) end
            return takeUp(self)
        end
    end
    local outOfVehicle = ISDropVehicleItemAction and ISDropVehicleItemAction.complete
    if outOfVehicle then
        function ISDropVehicleItemAction:complete()
            local done = outOfVehicle(self)
            Moveables.settle(self.item, self.character)
            return done
        end
    end
end
Events.OnGameStart.Add(wrapDrops)

local findItem = ISMoveableSpriteProps.findInInventory
function ISMoveableSpriteProps:findInInventory(character, spriteName)
    if self.buKind == "panel" and character and spriteName then
        local held = character:getPrimaryHandItem()
        if instanceof(held, "Moveable") and held:getWorldSprite() == spriteName then return held end
    end
    return findItem(self, character, spriteName)
end

local canPickUp = ISMoveableSpriteProps.canPickUpMoveable
function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    local kind = self.buKind
    if not kind then return canPickUp(self, character, square, object) end
    local found = find(kind, square, object)
    if not found and not bareOf(kind, square, object) then return false end
    -- the game's rule for a piece of furniture of one tile: it must fit the inventory; a box is carried in both hands
    -- (a heavy item: Moveables.hold), as a generator is, whatever else is carried
    if kind ~= "panel" and not character:getInventory():hasRoomFor(character, self.weight) then return false end
    return not found or found.panel ~= nil or BU.Units.isEmpty(found.unit)
end

local pickUp = ISMoveableSpriteProps.pickUpMoveable
function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    local kind = self.buKind
    if not kind then return pickUp(self, character, square, createItem, forceAllow) end
    local found = find(kind, square, self.object)
    local kept
    if found and found.panel then
        -- Its lines stay laid, cut: the box carries its tier to where it is put down again.
        kept = BU.Changes.keepPanel(found.panel)
        BU.Changes.remove(found.panel)
    elseif found and BU.Units.isEmpty(found.unit) then
        kept = BU.Units.keep(found.unit)
        BU.Costs.refund(character, BU.Changes.removeUnit(found.unit))
    elseif not found and bareOf(kind, square, self.object) then
        -- no record: a box's tier read off its look, a unit's state as spent (Units.lost)
        local object = bareOf(kind, square, self.object)
        kept = kind == "panel" and { tier = spriteTier(object:getSprite():getName()) } or BU.Units.lost(kind)
        square:transmitRemoveItemFromSquare(object)
    else
        return {}
    end
    local inventory = character:getInventory()
    -- (a heavy item held already is put down first, as the game does before a generator is taken up)
    if kind == "panel" and forceDropHeavyItems then forceDropHeavyItems(character) end
    local item = inventory:AddItem(itemType(kind, kind == "panel" and kept.tier or nil))
    if item then
        if kind ~= "panel" then BU.Units.keepOnItem(kind, item, kept) end
        sendAddItemToContainer(inventory, item)
        if kind == "panel" then Moveables.hold(character, item) end
    end
    return {}
end

-- Why the kind cannot be put down on a square: nil when it can (a reason of IGUI_BU_Reason_).
local function placeProblem(kind, square)
    local ok, reason
    if kind == "panel" then ok, reason = BU.Panels.canInstall(square)
    else ok, reason = BU.Units.canInstall(kind, square) end
    if ok then return nil end
    return reason or "blocked"
end

local canPlace = ISMoveableSpriteProps.canPlaceMoveable
function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    if self.buKind and placeProblem(self.buKind, square) then return false end
    return canPlace(self, character, square, item)
end

-- Put down: the item goes and the box or the unit is made, facing the side the cursor was turned to (the look the
-- props are of; else the character).
local place = ISMoveableSpriteProps.placeMoveable
function ISMoveableSpriteProps:placeMoveable(character, square, origSpriteName, forceAllow)
    local kind = self.buKind
    if not kind then return place(self, character, square, origSpriteName, forceAllow) end
    if not square or placeProblem(kind, square) then return end
    local item = self:findInInventory(character, origSpriteName)
    if not item then return end
    local side = sideOf(kind, self.spriteName, self.buTier) or BU.sideOf(square, character)
    local kept = kind == "panel" and { tier = BU.Panels.itemTier(item) } or BU.Units.keptOnItem(item)
    local inventory = character:getInventory()
    Moveables.letGo(character, item)
    inventory:Remove(item)
    sendRemoveItemFromContainer(inventory, item)
    if kind == "panel" then BU.Changes.install(square, side, kept)
    else BU.Changes.installUnit(kind, square, BU.Units.spriteFacing(kind, square, side), kept) end
    BU.giveXp(character, 5)
    if ISMoveableCursor then ISMoveableCursor.clearCacheForAllPlayers() end
end

local canRotate = ISMoveableSpriteProps.canRotateMoveable
function ISMoveableSpriteProps:canRotateMoveable(square, object, origProps)
    if self.buKind or origProps and origProps.buKind then return false end
    return canRotate(self, square, object, origProps)
end

-- The tool's panel says why it cannot be put down here.
local describe = ISMoveableSpriteProps.getInfoPanelDescription
function ISMoveableSpriteProps:getInfoPanelDescription(square, object, player, mode)
    local info = describe(self, square, object, player, mode)
    if not self.buKind or mode ~= "place" or type(info) ~= "table" then return info end
    local reason = square and placeProblem(self.buKind, square)
    if reason then
        local c = ISMoveableSpriteProps.bhc
        ISMoveableSpriteProps.addLineToInfoTable(info, "- " .. getText("IGUI_BU_Reason_" .. reason),
            c:getR() * 255, c:getG() * 255, c:getB() * 255)
    end
    return info
end

-- The game gives a furniture item its tile (what the cursor puts down, and how the tool finds the item in the
-- inventory) only when the tile is IsMoveAble: the tiles get it once they are loaded. CustomItem, the item that keeps
-- its own name, icon and weight, is in the tile files (tools/tile_art.py, solar_art.py): set here it would read as
-- another item, the game knowing only the values its tile files name.
Events.OnLoadedTileDefinitions.Add(function()
    kindOf(nil)
    for name, kind in pairs(kinds) do
        local sprite = getSprite(name)
        if sprite then
            local props = sprite:getProperties()
            props:set("IsMoveAble", "true")
        end
    end
end)

-- The cursor draws the tile it would put down (objectSprite); a unit of lookBySquare is drawn as the square under it
-- makes it, for the side it is turned to. Only while putting one down; the cursor is the game's, there once a game is on.
local function wrapCursor()
    if not ISMoveableCursor or ISMoveableCursor.buLookBySquare then return end
    ISMoveableCursor.buLookBySquare = true
    local render = ISMoveableCursor.render
    function ISMoveableCursor:render(x, y, z, square)
        local props, shown = self.currentMoveProps, self.objectSprite
        local kind = props and props.buKind
        if shown and kind and kind ~= "panel" and BU.Units.definition(kind).lookBySquare
            and ISMoveableCursor.mode[self.player] == "place" then
            local name = BU.Units.spriteFacing(kind, square or getCell():getGridSquare(x, y, z),
                sideOf(kind, props.spriteName))
            local sprite = name ~= shown:getName() and getSprite(name)
            if sprite then
                self.objectSprite = sprite
                render(self, x, y, z, square)
                self.objectSprite = shown
                return
            end
        end
        return render(self, x, y, z, square)
    end
end
Events.OnGameStart.Add(wrapCursor)

-- An item made before its tile was IsMoveAble has no tile: it takes its script's.
function BU.giveTile(item)
    if instanceof(item, "Moveable") and (item:getWorldSprite() or "") == "" then
        item:ReadFromWorldSprite(item:getScriptItem():getWorldObjectSprite())
    end
end
