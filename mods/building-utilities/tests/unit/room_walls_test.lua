-- Rooms that follow the walls (BU.RoomWalls), as the mod asks for them: the map building the player is in is watched
-- by the API (buildings.watchWalls) once, not again while they stay in it; the rooms the API tells are given to it
-- (setRooms); leaving it past its box lets the watch go; one the API will not watch, or one players built, is not asked
-- for again; another world starts afresh. (The rooms the walls make are the API's, tested there.)
require "BuildingUtilities/RoomWalls"
local BU = BuildingUtilities
local RoomWalls = BU.RoomWalls

local function tick(times) for _ = 1, times or 1 do TEST.fire("OnTick") end end

-- A map building at (500, 500), 4 by 2, the player at (px, py) (in it unless moved), and the API's walls as BU calls
-- them: what was watched, let go and set.
local function world(playerBuilt, refuse)
    local api = TEST.api
    local key = "500,500,0"
    api.buildingsByKey[key] = {
        building = { key = key, playerBuilt = playerBuilt or false, minLevel = 0, maxLevel = 0, minX = 500, minY = 500,
            maxX = 503, maxY = 501, room = "hall", roomId = "1" },
        rooms = { { id = "1", name = "hall", level = 0, rects = { { x = 500, y = 500, w = 4, h = 2 } } } },
    }
    for x = 500, 503 do
        for y = 500, 501 do api.squares[x .. "," .. y .. ",0"] = key end
    end
    local log = { watched = {}, unwatched = {}, set = {} }
    api.table.buildings.watchWalls = function(_, watchKey, fn)
        log.watched[#log.watched + 1] = watchKey
        log.fn = fn
        if refuse then return nil, "the building is larger than the game loads at once" end
        return #log.watched
    end
    api.table.buildings.unwatchWalls = function(_, id) log.unwatched[#log.unwatched + 1] = id; return true end
    api.table.buildings.setRooms = function(setKey, rooms) log.set[#log.set + 1] = { setKey, rooms }; return true end
    local home = { object = true }
    local at = { x = 501, y = 500 }
    getPlayer = function()
        return { getCurrentSquare = function()
            local inside = at.x >= 500 and at.x <= 503 and at.y >= 500 and at.y <= 501
            return { getBuilding = function() return inside and home or nil end, getX = function() return at.x end,
                getY = function() return at.y end, getZ = function() return 0 end }
        end }
    end
    return log, at, key
end

test("the building the player is in is watched once, and the rooms the API tells are given to it", function()
    local log, _, key = world()
    tick(30)
    eq(#log.watched, 1)
    eq(log.watched[1], key)
    tick(300)
    eq(#log.watched, 1, "not again while the player stays in it")
    local rooms = { { level = 0, rects = { { x = 500, y = 500, w = 2, h = 2 } } } }
    log.fn(key, rooms)
    eq(#log.set, 1)
    eq(log.set[1][1], key)
    eq(log.set[1][2], rooms)
    log.fn("1,1,0", rooms)
    eq(#log.set, 1, "rooms of a building not watched are not set")
end)

test("leaving past the building's box lets the watch go; coming back watches it again", function()
    local log, at = world()
    tick(30)
    at.x = 506
    tick(30)
    eq(#log.unwatched, 0, "within the box and its margin")
    at.x = 510
    tick(30)
    eq(#log.unwatched, 1)
    eq(log.unwatched[1], 1)
    at.x = 501
    tick(30)
    eq(#log.watched, 2)
end)

test("a building the API will not watch, or one players built, is not asked for again", function()
    local log = world(false, true)
    tick(300)
    eq(#log.watched, 1, "refused once, not asked again while the player stays")
    TEST.fire("OnGameStart")
    local built = world(true)
    tick(300)
    eq(#built.watched, 0, "the game remakes the rooms of a building players built")
end)

test("another world starts afresh: the same building is watched again", function()
    local log = world()
    tick(30)
    eq(#log.watched, 1)
    TEST.fire("OnGameStart")
    tick(30)
    eq(#log.watched, 2)
end)
