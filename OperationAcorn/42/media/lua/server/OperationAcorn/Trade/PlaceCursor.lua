-- The cursor for putting down the terminal, a delivery box or a supply crate: a ghost of the tile, green where it can
-- stand and red where it cannot, and for a box the squares around it that have a building or a tree in the way. The
-- terminal faces the player. Clicking queues the walk and the timed action that does it.
require "BuildingObjects/ISBuildingObject"
require "OperationAcorn/Trade/Actions"
local OA = OperationAcorn
local Trade, Sprites = OA.Trade, OA.Sprites
local Objects = Trade.Objects

ISOAPlaceCursor = ISBuildingObject:derive("ISOAPlaceCursor")

-- The side of a square the character stands on, which a terminal faces: S, E, N or W.
local function facingToward(character, x, y)
    local dx, dy = character:getX() - (x + 0.5), character:getY() - (y + 0.5)
    if math.abs(dx) > math.abs(dy) then return dx > 0 and "E" or "W" end
    return dy > 0 and "S" or "N"
end

local function spriteFor(kind, facing, item)
    if kind == Objects.TERMINAL then
        return Sprites.terminal(facing or "S", false, item ~= nil and item:getFullType() == Objects.ITEMS.field)
    end
    if kind == Objects.DELIVERY_BOX then return Sprites.deliveryBox(false) end
    return Sprites.supplyCrate(false)
end

function ISOAPlaceCursor:getSprite()
    local square = self.square
    local facing = square and facingToward(self.character, square:getX(), square:getY()) or "S"
    self.facing = facing
    self.chosenSprite = spriteFor(self.kind, facing, self.item)
    return self.chosenSprite
end

function ISOAPlaceCursor:isValid(square)
    if not square or not self.character:getInventory():contains(self.item) then return false end
    if self.kind == Objects.DELIVERY_BOX then return Objects.clearSquare(square, nil, self.cache) end
    return Objects.free(square)
end

-- The squares around the box's that hold a building or a tree (the clearance a helicopter needs), found once for each
-- square the cursor stops on.
function ISOAPlaceCursor:blockersAround(square)
    if self.blockerKey == square then return self.blockers end
    self.blockerKey = square
    self.cache = {}
    local blockers = {}
    local x0, y0 = square:getX(), square:getY()
    local r = Objects.CLEAR_RADIUS
    for dx = -r, r do
        for dy = -r, r do
            local s = Objects.square(x0 + dx, y0 + dy, 0)
            if s and (s:getBuilding() ~= nil or s:getRoom() ~= nil or s:HasTree()) then
                blockers[#blockers + 1] = { x0 + dx, y0 + dy }
            end
        end
    end
    self.blockers = blockers
    return blockers
end

function ISOAPlaceCursor:render(x, y, z, square)
    if not square then return end
    local valid = self:isValid(square)
    local sprite = self:getSprite()
    if not self.ghost then self.ghost = IsoSprite.new() end
    if self.ghostName ~= sprite then
        self.ghost:LoadSingleTexture(sprite)
        self.ghostName = sprite
    end
    if valid then self.ghost:RenderGhostTile(x, y, z) else self.ghost:RenderGhostTileRed(x, y, z) end
    if self.kind == Objects.DELIVERY_BOX and z == 0 then
        local floor = self:getFloorCursorSprite()
        for _, spot in ipairs(self:blockersAround(square)) do
            floor:RenderGhostTileColor(spot[1], spot[2], 0, 0.85, 0.2, 0.2, 0.55)
        end
    end
end

-- A click: the walk has been queued by the cursor; the action follows.
function ISOAPlaceCursor:create(x, y, z, north, sprite)
    local square = getCell():getGridSquare(x, y, z)
    if not square or not self:isValid(square) then return end
    ISTimedActionQueue.add(ISOAPlaceThing:new(self.character, self.kind, self.item, square, self.facing or "S"))
end

function ISOAPlaceCursor:new(character, kind, item)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    o.character = character
    o.player = character:getPlayerNum()
    o.kind = kind
    o.item = item
    o.facing = "S"
    o.cache = {}
    o.skipBuildAction = true
    o.noNeedHammer = true
    o.dragNilAfterPlace = true
    o.canBeAlwaysPlaced = false
    o:setSprite(spriteFor(kind, "S"))
    o:setNorthSprite(spriteFor(kind, "N"))
    return o
end

-- Starts the placing for a character.
function ISOAPlaceCursor.start(character, kind, item)
    getCell():setDrag(ISOAPlaceCursor:new(character, kind, item), character:getPlayerNum())
end
