-- The machines are the game's own multi-tile furniture (their tiles are IsMoveAble, tools/tile_art.py): the furniture
-- tool takes one up as a piece a tile, dropped on its squares the way the game takes up a couch, and puts the pieces
-- down whole, turned with R, from the inventory or the floor nearby. This file adds what the game does not know:
--   - taking up is refused, with the reason in the tool's panel, while a part is fitted or something is inside (a part
--     is taken out first, as the contents of a cupboard are);
--   - the registry entry goes with the machine, and the pieces keep nothing of its state;
--   - putting down obeys the machine's own rules (Machines.canPlace: the rain storage outside...) and makes the
--     machine as Machines.place makes it, with no parts: the game's plain objects are swapped for the machine's.
-- The lure is not furniture: it is put down from its item's menu (Menu.lua).
require "Moveables/ISMoveableSpriteProps"
require "Fluids/ISFluidEmptyAction"
require "OperationAcorn/Sprites"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data, Logic = Machines.Data, Machines.Logic
local Sprites = OA.Sprites

local SHEET = Sprites.MACHINES .. "_"

-- sprite name -> machine kind (Machines.kindOfSprite).
local kindOf = Machines.kindOfSprite

-- The machine (its anchor) a tile of the furniture tool belongs to: the object it was made from, or the one on the
-- square.
local function machineOf(square, object)
    if object and Machines.isMachineObject(object) then return Machines.anchorOf(object) end
    return square and Machines.at(square) or nil
end

-- The square of the grid's anchor (position 0,0, the machine's anchor) when the props' tile is at a square.
local function anchorSquare(props, square)
    local grid = props.sprite and props.sprite:getSpriteGrid()
    if not grid or not square then return square end
    return getCell():getGridSquare(square:getX() - grid:getSpriteGridPosX(props.sprite),
        square:getY() - grid:getSpriteGridPosY(props.sprite), square:getZ())
end

local new = ISMoveableSpriteProps.new
function ISMoveableSpriteProps.new(sprite)
    local s = new(sprite)
    local name = s and s.isMoveable and s.spriteName
    if name and string.sub(name, 1, #SHEET) == SHEET then s.oaMachine = kindOf(name) end
    return s
end

-- Why a machine cannot be taken up now: nil when it can.
local function pickUpProblem(square, object)
    local anchor = machineOf(square, object)
    if not anchor then return "notMachine" end
    local ok, reason = Machines.canPickUp(anchor)
    if ok then return nil end
    return reason
end

local canPickUp = ISMoveableSpriteProps.canPickUpMoveable
function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    if self.oaMachine and pickUpProblem(square, object) then return false end
    return canPickUp(self, character, square, object)
end

local pickUp = ISMoveableSpriteProps.pickUpMoveable
function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    if not self.oaMachine then return pickUp(self, character, square, createItem, forceAllow) end
    local anchor = machineOf(square, self.object)
    local items = pickUp(self, character, square, createItem, forceAllow)
    -- taken: the game removed the tiles; the registry entry goes too. The game copies an object's modData onto its
    -- piece (for its own furniture's name and health): the machine's state is not the piece's to carry.
    if anchor and anchor:getObjectIndex() < 0 then
        Machines.forget(anchor)
        if type(items) == "table" then
            for _, item in pairs(items) do
                local md = item and item:hasModData() and item:getModData()
                if md and type(md.modData) == "table" then md.modData = nil end
            end
        end
    end
    return items
end

-- Why a machine cannot be put down where the props' tile is at a square: nil when it can.
local function placeProblem(props, square)
    local ok, reason = Machines.canPlace(props.oaMachine, anchorSquare(props, square), props.facing or "S")
    if ok then return nil end
    return reason
end

local canPlace = ISMoveableSpriteProps.canPlaceMoveable
function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    if self.oaMachine and placeProblem(self, square) then return false end
    return canPlace(self, character, square, item)
end

local place = ISMoveableSpriteProps.placeMoveable
function ISMoveableSpriteProps:placeMoveable(character, square, origSpriteName, forceAllow)
    if not self.oaMachine then return place(self, character, square, origSpriteName, forceAllow) end
    local kind, dir = self.oaMachine, self.facing or "S"
    local at = anchorSquare(self, square)
    if not at or placeProblem(self, square) then return false end
    -- the game finds the pieces (inventory or the floor nearby), uses them up and puts its plain objects down; they
    -- are swapped for the machine's own
    local result = place(self, character, square, origSpriteName, forceAllow)
    local placed = false
    for _, entry in ipairs(Machines.footprintSquares(kind, at, dir) or {}) do
        local objects = entry.square:getObjects()
        for i = objects:size() - 1, 0, -1 do
            local object = objects:get(i)
            local sprite = object:getSprite()
            if sprite and kindOf(sprite:getName()) == kind and not Machines.isMachineObject(object) then
                entry.square:transmitRemoveItemFromSquare(object)
                placed = true
            end
        end
    end
    if placed then Machines.place(kind, at, character, nil, dir, true) end
    return result
end

-- The tool's panel says why a machine cannot be taken up or put down (the game's own lines say the rest: items in a
-- container, water in the rain storage).
local SAID_BY_GAME = { notEmpty = true, notMachine = true }
local describe = ISMoveableSpriteProps.getInfoPanelDescription
function ISMoveableSpriteProps:getInfoPanelDescription(square, object, player, mode)
    local info = describe(self, square, object, player, mode)
    if not self.oaMachine or type(info) ~= "table" then return info end
    local reason
    if mode == "pickup" then reason = pickUpProblem(square, object)
    elseif mode == "place" then reason = placeProblem(self, square) end
    if reason and not SAID_BY_GAME[reason] then
        local c = ISMoveableSpriteProps.bhc
        ISMoveableSpriteProps.addLineToInfoTable(info, "- " .. getText("IGUI_OA_Machine_Reason_" .. reason),
            c:getR() * 255, c:getG() * 255, c:getB() * 255)
    end
    return info
end

-- Pouring the rain storage out (the game's 비우기, needed before it is taken up) at Data.RAIN_POUR_SPEED: the game reads
-- a FluidContainer's TransferRate only for an item, a world object always pours at 1.
local pourDuration = ISFluidEmptyAction.getDuration
function ISFluidEmptyAction:getDuration()
    local time = pourDuration(self)
    local owner = self.container and self.container:getOwner()
    local state = owner and instanceof(owner, "IsoObject") and Machines.isMachineObject(owner) and Machines.state(owner)
    if state and state.kind == "rainStorage" and time > 1 then
        time = math.max(ISFluidUtil.getMinTransferActionTime(), time / Data.RAIN_POUR_SPEED)
    end
    return time
end

-- What a machine bought is delivered as: the game's furniture pieces of it facing south (one a tile, "Name (1/2)"...)
-- and the parts a new machine has (Logic.newParts), as items. nil for a type that is not a furniture machine.
function Machines.deliveryItems(fullType)
    local itemType = string.match(fullType or "", "^[^.]+%.(.+)$") or fullType
    local kind = Data.ITEM_KINDS[itemType]
    if not kind or kind == "lure" then return nil end
    local items = {}
    for _, t in ipairs(Sprites.machineTiles(kind, "S", false) or {}) do
        local props = ISMoveableSpriteProps.new(getSprite(t.sprite))
        local piece = props and props:instanceItem(t.sprite)
        if piece then items[#items + 1] = piece end
    end
    for slot, part in pairs(Logic.newParts(kind)) do
        local item = instanceItem(Data.MODULE .. "." .. Data.partItem(Data.partKind(kind, slot), part.tier))
        if item then items[#items + 1] = item end
    end
    return items
end
