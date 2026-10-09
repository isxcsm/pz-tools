-- The game's furniture tool takes a machine up (its 떼어내기, pick up mode) the way this mod's own pick-up does: the
-- machine's item with its parts and their condition in its modData, every tile of the machine gone, refused while
-- something is inside or a lure is still armed. Left to itself the tool would make a generic Moveable of each tile and
-- lose the state, so for the machine sheet's tiles it is told they move (they have no IsMoveAble property) and its
-- check and pick-up are this mod's. Its other modes leave machines alone: no faces to rotate (no Noffset/Soffset...
-- properties), nothing to scrap, and its place mode lists only Moveable items (machines are put down from their own
-- items' menu, Menu.lua).
require "Moveables/ISMoveableSpriteProps"
require "OperationAcorn/Sprites"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data
local Sprites = OA.Sprites

local SHEET = Sprites.MACHINES .. "_"

-- sprite name -> machine kind, every look of every kind (made the first time it is asked).
local kinds = nil
local function kindOf(spriteName)
    if not kinds then
        kinds = {}
        for _, kind in ipairs(Data.ORDER) do
            if kind == "lure" then
                kinds[Sprites.lure(true)], kinds[Sprites.lure(false)] = kind, kind
            else
                for _, dir in ipairs({ "S", "E", "N", "W" }) do
                    for _, running in ipairs({ false, true }) do
                        for _, t in ipairs(Sprites.machineTiles(kind, dir, running) or {}) do kinds[t.sprite] = kind end
                    end
                end
            end
        end
    end
    return kinds[spriteName]
end

-- The machine (its anchor) a tile of the furniture tool belongs to: the object it was made from, or the one on the
-- square.
local function machineOf(square, object)
    if object and Machines.isMachineObject(object) then return Machines.anchorOf(object) end
    return Machines.at(square)
end

local new = ISMoveableSpriteProps.new
function ISMoveableSpriteProps.new(sprite)
    local s = new(sprite)
    local name = s and s.spriteName
    if name and string.sub(name, 1, #SHEET) == SHEET then
        s.oaMachine = true
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
        local kind = kindOf(name)
        if kind then
            s.name = Machines.name(kind)
            s.weight = Data.KINDS[kind].weight
            s.rawWeight = s.weight * 10
        end
    end
    return s
end

local canPickUp = ISMoveableSpriteProps.canPickUpMoveable
function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    if not self.oaMachine then return canPickUp(self, character, square, object) end
    local anchor = machineOf(square, object)
    return anchor ~= nil and Machines.canPickUp(anchor) == true
end

local pickUp = ISMoveableSpriteProps.pickUpMoveable
function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    if not self.oaMachine then return pickUp(self, character, square, createItem, forceAllow) end
    local anchor = machineOf(square, self.object)
    if anchor then Machines.pickUp(anchor, character) end
    return {}
end

-- The tool's panel says the thing is too heavy for the inventory when it does not fit there; it is carried in the
-- hands instead (OA.carry), so that line is not shown for it.
local flagsPerTile = ISMoveableSpriteProps.getInfoPanelFlagsPerTile
function ISMoveableSpriteProps:getInfoPanelFlagsPerTile(square, object, player, mode)
    flagsPerTile(self, square, object, player, mode)
    if self.oaMachine then InfoPanelFlags.tooHeavy = false end
end
