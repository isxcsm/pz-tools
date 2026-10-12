-- The game's furniture tool takes a breaker box and the units (solar panels, battery racks, pumps, filters, boosters,
-- sprinklers) up (its 떼어내기, pick up mode) the way this mod's own taking down did: the object's lines and its
-- record go, a share of what its lines took comes back, and its item goes into the hands, when it fits the inventory
-- as the game asks of its own furniture of one tile. A rack holding batteries, or a unit that is not empty, is not
-- taken up (Units.isEmpty). Left to itself the tool would make a generic Moveable of the tile, or scrap it, and lose
-- the item and the record: this mod's tiles are told they move, and the tool's check and pick-up are this mod's. Its
-- other modes leave them alone (no faces to rotate, nothing to scrap).
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
    if found and found.panel then
        local paid = BU.Changes.paidFor(found.panel)
        BU.Changes.remove(found.panel)
        BU.Costs.refund(character, paid)
    elseif found and BU.Units.isEmpty(found.unit) then
        BU.Costs.refund(character, BU.Changes.removeUnit(found.unit))
    else
        return {}
    end
    local inventory = character:getInventory()
    local item = inventory:AddItem(itemType(kind))
    if item then sendAddItemToContainer(inventory, item) end
    return {}
end
