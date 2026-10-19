-- The game's furniture tool takes the trade objects up (its 떼어내기, pick up mode) the way this mod's own taking
-- does (Things.takeTerminal / takeBox): the terminal always, a delivery box when it is not sealed and is empty, each
-- into the hands as its item with what it carries (the box's id and owner), when it fits the inventory as the game
-- asks of its own furniture of one tile. (A supply crate is not taken up: it breaks once it is emptied.) Left
-- to itself the tool would not offer them (their tiles have no IsMoveAble property) or would make a generic Moveable;
-- the trade sheet's object tiles are told they move and the tool's check and pick-up are this mod's. Its other modes
-- leave them alone (no faces to rotate, nothing to scrap).
require "Moveables/ISMoveableSpriteProps"
require "OperationAcorn/Sprites"
require "OperationAcorn/Trade/Objects"
require "OperationAcorn/Trade/Things"
require "OperationAcorn/Trade/Actions"
require "PZUIKit/Heavy"
require "PZUIKit/Furniture"
local OA = OperationAcorn
local Sprites = OA.Sprites
local Objects, Things = OA.Trade.Objects, OA.Trade.Things

-- The trade sheet's tiles that are objects to take up, by their kind.
local KIND, FIELD = {}, {}
for dir = 0, 7 do
    KIND[Sprites.TRADE .. "_" .. dir] = Objects.TERMINAL          -- the field terminal
    FIELD[Sprites.TRADE .. "_" .. dir] = true
    KIND[Sprites.TRADE .. "_" .. (16 + dir)] = Objects.TERMINAL   -- as assembled
end
KIND[Sprites.deliveryBox(false)], KIND[Sprites.deliveryBox(true)] = Objects.DELIVERY_BOX, Objects.DELIVERY_BOX
local NAME = { [Objects.TERMINAL] = Objects.ITEMS.terminal, [Objects.DELIVERY_BOX] = Objects.ITEMS.box }

-- An item of the kind (the field terminal's for its tiles), made once, for the tool's name and weight.
local items = {}
local function itemOf(kind, field)
    local fullType = field and Objects.ITEMS.field or NAME[kind]
    local item = items[fullType]
    if item == nil then
        item = instanceItem(fullType) or false
        items[fullType] = item
    end
    return item or nil
end

local function objectOf(square, kind, object)
    if object and Objects.kindOf(object) == kind then return object end
    return square and Objects.find(square, kind) or nil
end

-- The game's functions below are left as they are while the mod is off (OA.off).
if not OA.off then
    local new = ISMoveableSpriteProps.new
    function ISMoveableSpriteProps.new(sprite)
        local s = new(sprite)
        local kind = s and s.spriteName and KIND[s.spriteName]
        if kind then
            s.oaTrade = kind
            -- a one-tile object the tool takes up as this mod does (no other faces: they have a Facing property)
            PZUIKit.Furniture.oneTile(s, itemOf(kind, FIELD[s.spriteName]))
        end
        return s
    end

    local canPickUp = ISMoveableSpriteProps.canPickUpMoveable
    function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
        local kind = self.oaTrade
        if not kind then return canPickUp(self, character, square, object) end
        local thing = objectOf(square, kind, object)
        if not thing then return false end
        -- the game's rule for a piece of furniture of one tile: it must fit the inventory
        if not character:getInventory():hasRoomFor(character, self.weight) then return false end
        if kind == Objects.TERMINAL then return true end
        if thing:getModData()[Objects.SEALED] then return false end
        -- another's box, or an abandoned one (that is dismantled instead), is not taken up
        if Things.boxSide(character, thing:getModData()) ~= "own" then return false end
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
            else Things.takeBox(character, thing) end
        end
        return {}
    end
end

-- Their items are the UI kit's heavy things (PZUIKit.Heavy): let go to the floor, a terminal stands up on any free
-- square, facing the one who let it go (turned as wanted when put down with the cursor), and a delivery box where it
-- may be put down (open ground: Objects.clearSquare), else it lies as the item.
local Heavy, Actions = PZUIKit.Heavy, OA.Trade.Actions
Heavy.register({ Objects.ITEMS.terminal, Objects.ITEMS.field }, {
    canStand = function(item, character, square) return (Objects.free(square)) end,
    stand = function(item, character, square, facing)
        Things.placeTerminal(character, square, facing, item, Actions.recordOf(character))
    end,
})
Heavy.register(Objects.ITEMS.box, {
    -- (what placeBox would refuse, asked before the item is taken off the floor)
    canStand = function(item, character, square)
        if Things.boxSide(character, item:getModData()) ~= "own" or not Objects.clearSquare(square) then return false end
        local id = item:getModData()[Objects.BOX]
        local box = id and OA.Trade.Boxes.get(Actions.recordOf(character), id)
        return not (box and box.state == "sealed")
    end,
    stand = function(item, character, square)
        Things.placeBox(character, Actions.recordOf(character), square, item)
    end,
})
