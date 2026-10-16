-- Spawned boxes: utility panels the map puts down beside its generators. As the game turns a map's generator tile
-- into a generator (MOGenerator.lua, a chunk loaded the first time: server/BuildingUtilities/MapBoxes.lua), a box is
-- rolled for on its own, as often as the generator is there (always: a map's generator is no roll) times
-- BreakerBoxLoot, and stands beside it as a bare box (Panels.isBare): a box's tile with no record, nothing running for
-- it, learned from and taken up like any box. It takes a square next to the generator, reached from it, of the same
-- room (an outdoor one outdoors) with nothing on it but its floor and plain walls, not a doorway nor before a door;
-- indoors with a wall behind it, which it faces away from. The generator keeps another such side: with fewer than two,
-- there is no box. Where each stands is kept in the save by the cell (CELL squares) it is in, so that a character
-- coming near finds it (Finds) by looking at the cells around them only.
require "BuildingUtilities/Core"
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Spawned = {}
BU.Spawned = Spawned

Spawned.CELL = 10
local CELL = Spawned.CELL

-- The sides of the generator looked at, the straight ones first.
local OFFSETS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 } }
local WALLS = { "WallN", "WallW", "WallNW", "WallNTrans", "WallWTrans" }
local OPENINGS = { "DoorWallN", "DoorWallW", "WindowN", "WindowW", "doorN", "doorW", "windowN", "windowW", "HoppableN",
    "HoppableW" }

local function cellKey(cx, cy) return cx .. "," .. cy end

-- The kept places, by cell: "cx,cy" -> a list of { x, y, z }.
local function places()
    local data = BU.Store.data()
    data.spawned = data.spawned or {}
    return data.spawned
end

function Spawned.keep(x, y, z)
    local all = places()
    local key = cellKey(math.floor(x / CELL), math.floor(y / CELL))
    all[key] = all[key] or {}
    table.insert(all[key], { x = x, y = y, z = z })
end

-- The kept places on z within reach squares of x, y each way.
function Spawned.near(x, y, z, reach)
    local all, result = places(), {}
    for cx = math.floor((x - reach) / CELL), math.floor((x + reach) / CELL) do
        for cy = math.floor((y - reach) / CELL), math.floor((y + reach) / CELL) do
            for _, place in ipairs(all[cellKey(cx, cy)] or {}) do
                if place.z == z and math.abs(place.x - x) <= reach and math.abs(place.y - y) <= reach then
                    result[#result + 1] = place
                end
            end
        end
    end
    return result
end

-- A kept place whose box is gone (taken up, broken, burnt).
function Spawned.forget(place)
    local list = places()[cellKey(math.floor(place.x / CELL), math.floor(place.y / CELL))]
    for index = #(list or {}), 1, -1 do
        local each = list[index]
        if each.x == place.x and each.y == place.y and each.z == place.z then table.remove(list, index) end
    end
end

local function hasAny(props, names)
    for _, name in ipairs(names) do
        local flag = IsoFlagType[name]
        if flag and props:has(flag) then return true end
    end
    return false
end

-- A wall with no door, window or opening in it.
local function plainWall(object)
    local props = object and object:getProperties()
    return props ~= nil and hasAny(props, WALLS) and not hasAny(props, OPENINGS)
end

-- Nothing on it but its floor and plain walls, nothing lying there, not stairs nor a doorway.
local function clear(square)
    if not square:getFloor() or square:HasStairs() or square:isDoorSquare() then return false end
    local lying = square:getWorldObjects()
    if lying and lying:size() > 0 then return false end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if not (object:isFloor() or plainWall(object)) then return false end
    end
    return true
end

-- Whether a door opens off the square to a side: a box there would stand in the way in.
local function beforeDoor(square)
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for _, offset in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
        local other = cell:getGridSquare(x + offset[1], y + offset[2], z)
        if other and (square:isDoorTo(other) or other:isDoorSquare()) then return true end
    end
    return false
end

-- The side a box against the square's wall faces (away from it), or nil with no plain wall at its edges.
local function wallFacing(square)
    if square:getWall(true) then return "S" end
    if square:getWall(false) then return "E" end
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local south, east = cell:getGridSquare(x, y + 1, z), cell:getGridSquare(x + 1, y, z)
    if south and plainWall(south:getWall(true)) then return "N" end
    if east and plainWall(east:getWall(false)) then return "W" end
    return nil
end

-- The squares beside the generator's a box may take, each { square, side }.
function Spawned.places(generator)
    local cell = getCell()
    local x, y, z = generator:getX(), generator:getY(), generator:getZ()
    local room = generator:getRoom()
    local result = {}
    for _, offset in ipairs(OFFSETS) do
        local square = cell:getGridSquare(x + offset[1], y + offset[2], z)
        if square and square:getRoom() == room and not generator:isWallTo(square) and not generator:isDoorTo(square)
            and not generator:isWindowTo(square) and clear(square) and not beforeDoor(square) then
            local side = wallFacing(square)
            if room == nil then side = side or "S" end
            if side then result[#result + 1] = { square = square, side = side } end
        end
    end
    return result
end

-- How often a map's generator has a box: as often as the generator stands there (always), by the option.
function Spawned.chance()
    if not BU.enabled("panel") then return 0 end
    return math.min(1, math.max(0, BU.sandbox("BreakerBoxLoot", 1)))
end

-- A box beside the generator on the square, by its chance and room; the box's square, or nil.
function Spawned.beside(generator)
    local chance = Spawned.chance()
    if chance <= 0 or ZombRandFloat(0, 1) >= chance then return nil end
    local choices = Spawned.places(generator)
    if #choices < 2 then return nil end
    local choice = choices[ZombRand(#choices) + 1]
    local square = choice.square
    local sprite = BU.panelSprite(choice.side, 1, square:getBuilding() == nil)
    local object = IsoObject.new(square, sprite, nil, false)
    square:AddTileObject(object)
    if isServer() then object:transmitCompleteItemToClients() end
    Spawned.keep(square:getX(), square:getY(), square:getZ())
    return square
end

return Spawned
