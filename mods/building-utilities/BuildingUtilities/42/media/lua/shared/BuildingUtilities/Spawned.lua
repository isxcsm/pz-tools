-- Spawned boxes: utility panels the world puts down as it does its generators. The game rolls for a generator in a
-- room of a few kinds (sheds, garages, storage units, farm storage) the first time a character sees it (IsoCell's
-- spotted rooms: OnSeeNewRoom, then one in N): a box is rolled for in the same rooms, as often, on its own
-- (server/BuildingUtilities/RoomBoxes.lua), so a room may get either, both or none. It stands there as a bare box
-- (Panels.isBare): a box's tile with no record, nothing running for it, learned from and taken up like any box. It
-- takes a free square of the room (nothing on it but its floor and plain walls, nothing lying there, not stairs nor a
-- doorway) that is not before a door, on the floor (its indoor look): against a wall and facing away from it where a
-- free square has one, else on any (shelves and bins along the walls). Where each stands is kept in the save by the
-- cell (CELL squares) it is in, so that a character coming near finds it (Finds) by looking at the cells around them
-- only.
require "BuildingUtilities/Core"
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Spawned = {}
BU.Spawned = Spawned

Spawned.CELL = 10
local CELL = Spawned.CELL

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
local NONE = {}
function Spawned.near(x, y, z, reach)
    local all, result = places(), {}
    for cx = math.floor((x - reach) / CELL), math.floor((x + reach) / CELL) do
        for cy = math.floor((y - reach) / CELL), math.floor((y + reach) / CELL) do
            for _, place in ipairs(all[cellKey(cx, cy)] or NONE) do
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

-- The game's one in N for a generator in a room it is rolled for in, by the room's kind; and how its option
-- (GeneratorSpawning: none, very rare .. very common) moves N.
Spawned.ONE_IN = { garage = 7, storageunit = 7, shed = 4, garagestorage = 4, farmstorage = 4 }
local BY_OPTION = { [2] = 20, [3] = 3, [4] = 2, [6] = -2, [7] = -3 }

-- The game's N for a room of the kind, nil for a kind it rolls none for (or with its option at none).
function Spawned.oneIn(kind)
    local n = Spawned.ONE_IN[kind or ""]
    if not n then return nil end
    local option = tonumber(SandboxVars.GeneratorSpawning) or 5
    if option == 1 then return nil end
    n = n + (BY_OPTION[option] or 0)
    return n > 0 and n or nil
end

-- BreakerBoxLoot's default (the game's loot options'), at which a room gets a box as often as a generator.
Spawned.LOOT_DEFAULT = 0.6

-- How often a room of the kind gets a box: as often as the game gives it a generator, scaled by BreakerBoxLoot (twice
-- at twice its default, none at 0), as the box's loot is.
function Spawned.chance(kind)
    if not BU.enabled("panel") then return 0 end
    local n = Spawned.oneIn(kind)
    if not n then return 0 end
    local scale = math.max(0, BU.sandbox("BreakerBoxLoot", Spawned.LOOT_DEFAULT)) / Spawned.LOOT_DEFAULT
    return math.min(1, scale / n)
end

-- The squares of the room a box may take, each { square, side }: the ones against a wall where there are any.
function Spawned.places(room)
    local squares = room and room:getSquares()
    local walled, any = {}, {}
    for i = 0, squares and squares:size() - 1 or -1 do
        local square = squares:get(i)
        if clear(square) and not beforeDoor(square) then
            local side = wallFacing(square)
            local place = { square = square, side = side or "S" }
            if side then walled[#walled + 1] = place end
            any[#any + 1] = place
        end
    end
    return #walled > 0 and walled or any
end

-- A box in the room, by its kind's chance; the box's square, or nil.
function Spawned.inRoom(room)
    local chance = Spawned.chance(room and room:getName())
    if chance <= 0 or ZombRandFloat(0, 1) >= chance then return nil end
    local choices = Spawned.places(room)
    if #choices == 0 then return nil end
    local choice = choices[ZombRand(#choices) + 1]
    local square = choice.square
    local object = IsoObject.new(square, BU.panelSprite(choice.side, 1, false), nil, false)
    square:AddTileObject(object)
    if isServer() then object:transmitCompleteItemToClients() end
    Spawned.keep(square:getX(), square:getY(), square:getZ())
    return square
end

return Spawned
