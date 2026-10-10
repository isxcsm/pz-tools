-- The cursor for putting the lure down from its item: the lure's tile as a ghost on the square under the mouse, green
-- where Machines.canPlace says it can stand and red where it cannot. A click walks to the square and queues the timed
-- action that puts it down (ISOAMachinePlace); a right-click ends the cursor, as it does the game's own. The machines
-- that are furniture are put down by the game's furniture cursor (Menu.lua opens it), not this one. The lure looks the
-- same from every side, so there is nothing to turn.
-- The cursor derives from ISBuildingObject, which the game loads with the server folder after the client one, so the
-- menu looks the class up when it is used and does not require it.
require "BuildingObjects/ISBuildingObject"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
local OA = OperationAcorn
local Machines = OA.Machines

ISOAMachineCursor = ISBuildingObject:derive("ISOAMachineCursor")

-- The sprite of the item's machine as it stands (a lure works at once, so it shows its working look).
local function spriteFor(kind)
    return Machines.spriteName(kind, "S", kind == "lure")
end

function ISOAMachineCursor:getSprite()
    self.chosenSprite = spriteFor(self.kind)
    return self.chosenSprite
end

-- Whether the machine can stand with its anchor on a square, and, if not, why (IGUI_OA_Machine_Reason_<reason>). The
-- item must still be somewhere: dropped into the world or used up, the cursor offers nothing.
function ISOAMachineCursor:check(square)
    if not square then return nil, "noSquare" end
    if not self.item:getContainer() then return nil, "noItem" end
    return Machines.canPlace(self.kind, square, Machines.facing(square, self.character))
end

function ISOAMachineCursor:isValid(square)
    return self:check(square) == true
end

function ISOAMachineCursor:render(x, y, z, square)
    if not square then return end
    local sprite = self:getSprite()
    if not self.ghost then self.ghost = IsoSprite.new() end
    if self.ghostName ~= sprite then
        self.ghost:LoadSingleTexture(sprite)
        self.ghostName = sprite
    end
    if self:isValid(square) then self.ghost:RenderGhostTile(x, y, z) else self.ghost:RenderGhostTileRed(x, y, z) end
end

-- A click on a square where it can stand: the game's building cursor has queued the walk next to it; the item is
-- fetched if it is in a container nearby and not in the inventory, and the action follows.
function ISOAMachineCursor:create(x, y, z, north, sprite)
    local square = getCell():getGridSquare(x, y, z)
    if not square or not self:isValid(square) then return end
    local dir = Machines.facing(square, self.character)
    ISInventoryPaneContextMenu.transferIfNeeded(self.character, self.item)
    ISTimedActionQueue.add(ISOAMachinePlace:new(self.character, square, self.item, self.kind, dir))
end

function ISOAMachineCursor:new(character, kind, item)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    o.character = character
    o.player = character:getPlayerNum()
    o.kind = kind
    o.item = item
    -- the building cursor's own steps that need a hammer, a build action or materials do not apply
    o.skipBuildAction = true
    o.noNeedHammer = true
    o.dragNilAfterPlace = true
    o.canBeAlwaysPlaced = false
    o:setSprite(spriteFor(kind))
    return o
end

-- Starts the placing for a character, from the item that was clicked.
function ISOAMachineCursor.start(character, kind, item)
    getCell():setDrag(ISOAMachineCursor:new(character, kind, item), character:getPlayerNum())
end
