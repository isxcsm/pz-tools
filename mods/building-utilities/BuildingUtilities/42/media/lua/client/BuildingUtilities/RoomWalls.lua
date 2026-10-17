-- Rooms that follow the walls. A map building's rooms are the map's whatever happens to its walls (the game remakes the
-- rooms of the buildings players build, never a map building's): a wall taken down left two rooms where one stands, a
-- wall built across a room left one. The map building the player is in is watched (PZExtAPI.buildings.watchWalls:
-- its walls read and its squares watched in Java, nothing of them in Lua); when a wall between its squares is taken
-- down or built so that its rooms are not the ones the walls make, the API tells the rooms they make, and they are
-- given to it (PZExtAPI.buildings.setRooms, which the game keeps with the save). Two rooms a wall taken down opens to
-- each other become one; a room a new wall cuts in two becomes two. What the map has stays: an open kitchen beside the
-- living room stays the kitchen, and a room with a wall of its own inside stays one room.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local RoomWalls = {}
BU.RoomWalls = RoomWalls

-- Ticks between looks at where the player is, and the squares beyond the building's box the watch is kept.
local LOOK_EVERY, LEAVE = 30, 4

-- The building watched: { key, id (none when the API would not watch it), box { minX, minY, maxX, maxY } }.
local watched, ticks, seenBuilding = nil, 0, nil

local function api()
    local found = BU.api()
    if found and found.buildings and found.buildings.watchWalls and found.buildings.setRooms then return found end
    return nil
end

local function unwatch(found, handle)
    if watched and watched.id then found.buildings.unwatchWalls(handle, watched.id) end
    watched = nil
end

-- The API told the rooms the walls of the building make now.
function RoomWalls.onWalls(key, rooms)
    local found = api()
    if not found or not watched or watched.key ~= key then return end
    local done, why = found.buildings.setRooms(key, rooms)
    if not done then BU.log("rooms not set for", key, why) end
end

local function start(found, handle, info)
    unwatch(found, handle)
    local id, why = found.buildings.watchWalls(handle, info.key, RoomWalls.onWalls)
    if not id then BU.log("walls not watched for", info.key, why) end
    watched = { key = info.key, id = id, box = { info.minX - LEAVE, info.minY - LEAVE, info.maxX + LEAVE, info.maxY + LEAVE } }
end

-- Where the player is: the map building they are in is watched; one they left far behind is not.
local function look(found, handle)
    local player = getPlayer()
    local square = player and player:getCurrentSquare()
    if not square then return end
    local building = square:getBuilding()
    if building and building ~= seenBuilding then
        seenBuilding = building
        local info = found.buildings.at(square:getX(), square:getY(), square:getZ())
        if info and not info.playerBuilt and not (watched and watched.key == info.key) then start(found, handle, info) end
        return
    end
    if watched and not building then
        local x, y, box = square:getX(), square:getY(), watched.box
        if x < box[1] or y < box[2] or x > box[3] or y > box[4] then
            unwatch(found, handle)
            seenBuilding = nil
        end
    end
end

local function onTick()
    ticks = ticks + 1
    if ticks < LOOK_EVERY then return end
    ticks = 0
    local found = api()
    local handle = found and BU.handle()
    if handle then look(found, handle) end
end

-- Another world: its watches are its own (the API let the last world's go).
local function onGameStart()
    watched, ticks, seenBuilding = nil, 0, nil
end

Events.OnTick.Add(onTick)
Events.OnGameStart.Add(onGameStart)

return RoomWalls
