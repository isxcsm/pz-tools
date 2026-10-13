-- A breaker box and the units (solar panels, battery racks, pumps, filters, boosters, sprinklers) are the game's
-- furniture: their items are Moveables, put down with the game's furniture cursor (the inventory's 배치하기), turned
-- with its rotate key through the looks a kind has, and taken up with its pick up mode. This file adds what the game
-- does not know:
--   - taking up: the object's lines and its record go, a share of what its lines took comes back, and its item goes
--     into the inventory, when it fits as the game asks of its own furniture of one tile; a rack holding batteries, or
--     a unit that is not empty, is not taken up (Units.isEmpty);
--   - putting down obeys the kind's rules (Panels.canInstall, Units.canInstall: the tool's panel says why not) and
--     makes the box or the unit as this mod does (BU.Changes), facing as the cursor was turned;
--   - the faces: each kind's looks for the sides (BU.panelSprite, the units' sprite(nil, side)) as the tool's offsets.
-- A placed one is not turned with the tool (its record keeps how it faces), nor scrapped.
require "Moveables/ISMoveableSpriteProps"
require "BuildingUtilities/Units"
require "BuildingUtilities/Panels"
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/Changes"
require "BuildingUtilities/Costs"
local BU = BuildingUtilities

-- This mod's tiles that are objects to take up: "panel" or a unit's kind, by sprite name; worked out once the units
-- are defined (the first time the tool asks).
local kinds
local function kindOf(spriteName)
    if not kinds then
        kinds = {}
        -- every look a box shows (its lamps), an old box's vanilla terminal but for those tiles elsewhere
        for _, name in ipairs(BU.PanelLook.ALL) do
            if not BU.OLD_PANEL_SPRITE_SET[name] then kinds[name] = "panel" end
        end
        for _, kind in ipairs(BU.Units.KINDS) do
            for _, name in ipairs(BU.Units.definition(kind).sprites or {}) do kinds[name] = kind end
        end
    end
    return spriteName and kinds[spriteName]
end

local function itemType(kind)
    return kind == "panel" and BU.PANEL_ITEM or BU.Units.definition(kind).item
end

-- An item of the type, made once, for the tool's name and weight.
local items = {}
local function itemOf(kind)
    local fullType = itemType(kind)
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

-- A kind's look for each side it can face, by side (BU.SIDES), each look once: worked out once a kind.
local facesByKind = {}
local function facesOf(kind)
    local faces = facesByKind[kind]
    if faces then return faces end
    faces = {}
    local seen = {}
    for _, side in ipairs(BU.SIDES) do
        local sprite = kind == "panel" and BU.panelSprite(side) or BU.Units.spriteFacing(kind, nil, side)
        if sprite and not seen[sprite] then
            seen[sprite] = true
            faces[side] = sprite
        end
    end
    facesByKind[kind] = faces
    return faces
end

-- The side a look of a kind faces, or nil.
local function sideOf(kind, spriteName)
    for side, sprite in pairs(facesOf(kind)) do
        if sprite == spriteName then return side end
    end
    return nil
end

-- The tool turns a tile through its faces by offsets in its sheet (the game reads them from the tile's properties).
local OFFSET = { N = "Noffset", E = "Eoffset", S = "Soffset", W = "Woffset" }
local function setFaces(s, kind)
    local own = sideOf(kind, s.spriteName)
    if not own or not s.sheetName or not s.spriteID then return end
    local any = false
    for side, sprite in pairs(facesOf(kind)) do
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
        local item = itemOf(kind)
        if item then
            s.name = item:getName()
            s.weight = item:getActualWeight()
            s.rawWeight = s.weight * 10
        end
        setFaces(s, kind)
    end
    return s
end

local canPickUp = ISMoveableSpriteProps.canPickUpMoveable
function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    local kind = self.buKind
    if not kind then return canPickUp(self, character, square, object) end
    local found = find(kind, square, object)
    if not found then return false end
    -- the game's rule for a piece of furniture of one tile: it must fit the inventory
    if not character:getInventory():hasRoomFor(character, self.weight) then return false end
    return found.panel ~= nil or BU.Units.isEmpty(found.unit)
end

local pickUp = ISMoveableSpriteProps.pickUpMoveable
function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    local kind = self.buKind
    if not kind then return pickUp(self, character, square, createItem, forceAllow) end
    local found = find(kind, square, self.object)
    local kept
    if found and found.panel then
        local paid = BU.Changes.paidFor(found.panel)
        BU.Changes.remove(found.panel)
        BU.Costs.refund(character, paid)
    elseif found and BU.Units.isEmpty(found.unit) then
        kept = BU.Units.keep(found.unit)
        BU.Costs.refund(character, BU.Changes.removeUnit(found.unit))
    else
        return {}
    end
    local inventory = character:getInventory()
    local item = inventory:AddItem(itemType(kind))
    if item then
        BU.Units.keepOnItem(kind, item, kept)
        sendAddItemToContainer(inventory, item)
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
    local side = sideOf(kind, self.spriteName) or BU.sideOf(square, character)
    local kept = BU.Units.keptOnItem(item)
    local inventory = character:getInventory()
    inventory:Remove(item)
    sendRemoveItemFromContainer(inventory, item)
    if kind == "panel" then BU.Changes.install(square, BU.panelSprite(side))
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
-- inventory) only when the tile is IsMoveAble; CustomItem names the item, so that it keeps its own name, icon and weight.
-- The tiles get both once they are loaded.
Events.OnLoadedTileDefinitions.Add(function()
    kindOf(nil)
    for name, kind in pairs(kinds) do
        local sprite = getSprite(name)
        if sprite then
            local props = sprite:getProperties()
            props:set("IsMoveAble", "true")
            props:set("CustomItem", itemType(kind))
        end
    end
end)

-- An item made before its tile was IsMoveAble has no tile: it takes its script's.
function BU.giveTile(item)
    if instanceof(item, "Moveable") and (item:getWorldSprite() or "") == "" then
        item:ReadFromWorldSprite(item:getScriptItem():getWorldObjectSprite())
    end
end
