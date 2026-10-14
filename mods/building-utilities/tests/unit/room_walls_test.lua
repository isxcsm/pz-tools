-- The rooms a map building's walls make (BU.RoomWalls): two rooms a wall taken down opens to each other become one, a
-- room a new wall cuts becomes two, and what the map has stays.
require "BuildingUtilities/RoomWalls"
local BU = BuildingUtilities
local RoomWalls = BU.RoomWalls

local function room(name, x, y, w, h, level)
    return { name = name, level = level or 0, rects = { { x = x, y = y, w = w, h = h } } }
end

-- Walls by square: { { x, y, code }, ... } on level 0 (1 north, 2 west, 3 both).
local function walls(list)
    local result = {}
    for _, wall in ipairs(list) do result[RoomWalls.place(wall[1], wall[2], wall[3] or 0)] = wall[4] or wall[3] end
    return result
end

local function wall(x, y, code) return { x, y, 0, code } end

local function partition(rooms, now, before)
    return RoomWalls.partition(rooms, RoomWalls.footprint(rooms), walls(now), walls(before))
end

-- The kitchen (x 0-2) and the living room (x 3-5), three rows, a wall between them on the living room's west side.
local KITCHEN, LIVING = room("kitchen", 0, 0, 3, 3), room("livingroom", 3, 0, 3, 3)
local BETWEEN = { wall(3, 0, 2), wall(3, 1, 2), wall(3, 2, 2) }

test("the rooms the building has: nothing to set", function()
    eq(partition({ KITCHEN, LIVING }, BETWEEN, BETWEEN), nil)
end)

test("a piece of the wall between two rooms taken down: one room", function()
    local result = partition({ KITCHEN, LIVING }, { wall(3, 0, 2), wall(3, 2, 2) }, BETWEEN)
    eq(#result, 1)
    eq(result[1].level, 0)
    eq(#result[1].rects, 1, "one rectangle")
    local rect = result[1].rects[1]
    eq(rect.x .. "," .. rect.y .. "," .. rect.w .. "," .. rect.h, "0,0,6,3")
end)

test("two rooms open to each other on the map stay two, whatever is built between them", function()
    eq(partition({ KITCHEN, LIVING }, {}, {}), nil, "nothing changed")
    eq(partition({ KITCHEN, LIVING }, { wall(3, 1, 2) }, {}), nil, "a wall built on the line between them")
end)

test("a wall built across a room: two rooms", function()
    local hall = room("hall", 0, 0, 6, 1)
    local result = partition({ hall }, { wall(3, 0, 2) }, {})
    eq(#result, 2)
    local widths = {}
    for _, made in ipairs(result) do widths[#widths + 1] = made.rects[1].x .. ":" .. made.rects[1].w end
    table.sort(widths)
    eq(table.concat(widths, " "), "0:3 3:3")
end)

test("a room with a wall of its own on the map stays one room", function()
    local hall = room("hall", 0, 0, 6, 1)
    eq(partition({ hall }, { wall(3, 0, 2) }, { wall(3, 0, 2) }), nil, "the map's own wall")
    local result = partition({ hall }, { wall(3, 0, 2), wall(1, 0, 2) }, { wall(3, 0, 2) })
    local widths = {}
    for _, made in ipairs(result) do widths[#widths + 1] = made.rects[1].x .. ":" .. made.rects[1].w end
    table.sort(widths)
    eq(table.concat(widths, " "), "0:1 1:5", "a new wall cuts; the map's own still does not")
end)

test("a north wall taken down between rooms stacked north and south; other levels kept as they are", function()
    local north, south, upstairs = room("bedroom", 0, 0, 2, 2), room("bathroom", 0, 2, 2, 2), room("attic", 0, 0, 2, 4, 1)
    local result = partition({ north, south, upstairs }, {}, { wall(0, 2, 1), wall(1, 2, 1) })
    eq(#result, 2)
    local levels = {}
    for _, made in ipairs(result) do levels[#levels + 1] = made.level .. ":" .. #made.rects .. ":" .. made.rects[1].h end
    table.sort(levels)
    eq(table.concat(levels, " "), "0:1:4 1:1:4")
end)

test("an L-shaped room made rectangles", function()
    local squares = {}
    for _, at in ipairs({ { 0, 0 }, { 1, 0 }, { 2, 0 }, { 0, 1 }, { 0, 2 }, { 1, 2 } }) do
        squares[#squares + 1] = { x = at[1], y = at[2] }
    end
    local rects = RoomWalls.rects(squares)
    local seen = {}
    for _, rect in ipairs(rects) do seen[#seen + 1] = rect.x .. "," .. rect.y .. "," .. rect.w .. "," .. rect.h end
    eq(table.concat(seen, " "), "0,0,3,1 0,1,1,1 0,2,2,1")
end)
