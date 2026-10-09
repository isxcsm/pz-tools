-- The game's furniture tool takes the trade objects up (its 떼어내기, pick up mode) the way this mod's own taking
-- does (Things.takeTerminal / takeBox / takeCrate): the terminal always, a delivery box or a supply crate when it is
-- not sealed and is empty, each into the hands as its heavy item with what it carries (the box's id and owner). Left
-- to itself the tool would not offer them (their tiles have no IsMoveAble property) or would make a generic Moveable;
-- the trade sheet's object tiles are told they move and the tool's check and pick-up are this mod's. Its other modes
-- leave them alone (no faces to rotate, nothing to scrap; a crate is broken down from its own menu).
require "Moveables/ISMoveableSpriteProps"
require "OperationAcorn/Sprites"
require "OperationAcorn/Trade/Objects"
require "OperationAcorn/Trade/Things"
local OA = OperationAcorn
local Sprites = OA.Sprites
local Objects, Things = OA.Trade.Objects, OA.Trade.Things

-- The trade sheet's tiles that are objects to take up, by their kind (the parachute crate is sealed: never taken).
local KIND = {}
for dir = 0, 7 do KIND[Sprites.TRADE .. "_" .. dir] = Objects.TERMINAL end
KIND[Sprites.deliveryBox(false)], KIND[Sprites.deliveryBox(true)] = Objects.DELIVERY_BOX, Objects.DELIVERY_BOX
KIND[Sprites.supplyCrate(false)], KIND[Sprites.supplyCrate(true)] = Objects.CRATE, Objects.CRATE
local NAME = { [Objects.TERMINAL] = "CommTerminal", [Objects.DELIVERY_BOX] = "DeliveryBox", [Objects.CRATE] = "SupplyCrate" }

local items = {}
local function itemOf(kind)
    local item = items[kind]
    if item == nil then
        item = instanceItem("OperationAcorn." .. NAME[kind]) or false
        items[kind] = item
    end
    return item or nil
end

local function objectOf(square, kind, object)
    if object and Objects.kindOf(object) == kind then return object end
    return square and Objects.find(square, kind) or nil
end

local new = ISMoveableSpriteProps.new
function ISMoveableSpriteProps.new(sprite)
    local s = new(sprite)
    local kind = s and s.spriteName and KIND[s.spriteName]
    if kind then
        s.oaTrade = kind
        s.isMoveable = true
        s.canScrap = false
        s.type = "Object"
        s.isMultiSprite = false
        s.customItem, s.pickUpTool, s.placeTool, s.pickUpLevel = nil, nil, nil, 0
        -- what the tool sets for its own moveables from tile properties these tiles do not have: no other faces (they
        -- have a Facing property), nothing linked, no wall overlay, one item
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
    local kind = self.oaTrade
    if not kind then return canPickUp(self, character, square, object) end
    local thing = objectOf(square, kind, object)
    if not thing then return false end
    if kind == Objects.TERMINAL then return true end
    if thing:getModData()[Objects.SEALED] then return false end
    local container = thing:getContainer()
    return container == nil or container:isEmpty()
end

local pickUp = ISMoveableSpriteProps.pickUpMoveable
function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    local kind = self.oaTrade
    if not kind then return pickUp(self, character, square, createItem, forceAllow) end
    local thing = objectOf(square, kind, self.object)
    if thing then
        if kind == Objects.TERMINAL then Things.takeTerminal(character, thing)
        elseif kind == Objects.DELIVERY_BOX then Things.takeBox(character, thing)
        else Things.takeCrate(character, thing) end
    end
    return {}
end

-- The tool's panel says the thing is too heavy for the inventory when it does not fit there; it is carried in the
-- hands instead (OA.carry), so that line is not shown for it.
local flagsPerTile = ISMoveableSpriteProps.getInfoPanelFlagsPerTile
function ISMoveableSpriteProps:getInfoPanelFlagsPerTile(square, object, player, mode)
    flagsPerTile(self, square, object, player, mode)
    if self.oaTrade then InfoPanelFlags.tooHeavy = false end
end
