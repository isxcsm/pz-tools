-- A box's zone saved by a square of each room, not by room ids: the game numbers a cell's rooms again whenever a
-- player's building there changes. The zone follows the squares: renumbered rooms, two rooms made one, one split.
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Panels, Changes, Store = BU.Panels, BU.Changes, BU.Store

local KEY = "300,300,0"

-- A player's cabin of three rooms in a row, 3 by 3 each, numbered as given.
local function cabin(api, rooms)
    api.buildingsByKey[KEY] = {
        building = { key = KEY, playerBuilt = true, minLevel = 0, maxLevel = 0, minX = 300, minY = 300, maxX = 308,
            maxY = 302, room = "room", roomId = rooms[1].id },
        rooms = rooms,
    }
    for x = 300, 308 do
        for y = 300, 302 do api.squares[x .. "," .. y .. ",0"] = KEY end
    end
    api.buildingsVersion = api.buildingsVersion + 1
end

local function three(a, b, c)
    return {
        { id = a, name = "room", level = 0, rects = { { x = 300, y = 300, w = 3, h = 3 } } },
        { id = b, name = "room", level = 0, rects = { { x = 303, y = 300, w = 3, h = 3 } } },
        { id = c, name = "room", level = 0, rects = { { x = 306, y = 300, w = 3, h = 3 } } },
    }
end

local function zoneOf(panel)
    local ids, list = Panels.zoneIds(panel), {}
    for id in pairs(ids or {}) do list[#list + 1] = id end
    table.sort(list)
    return table.concat(list, " ")
end

test("a zone keeps its rooms by their squares", function()
    cabin(TEST.api, three("1", "2", "3"))
    local panel = Store.newPanel(301, 301, 0, "box")
    local building = Panels.building(panel)
    local rooms = Panels.rooms(building)
    eq(rooms[2].key, "303,300,0", "a room's key: its north-west square")
    eq(Changes.setZone(panel, { rooms[1].key, rooms[2].key }), true)
    eq(panel.zone["300,300,0"], true, "saved by square")
    eq(zoneOf(panel), "1 2")
    eq(Panels.inZone(panel, "3"), false)

    -- The player builds elsewhere in the cell: the rooms are numbered again.
    cabin(TEST.api, three("7", "8", "9"))
    eq(zoneOf(panel), "7 8", "the same rooms under their new ids")
    eq(Panels.inZone(panel, "9"), false)

    -- A wall taken down: the second and third rooms are one, keeping the zone's square.
    cabin(TEST.api, {
        { id = "4", name = "room", level = 0, rects = { { x = 300, y = 300, w = 3, h = 3 } } },
        { id = "5", name = "room", level = 0, rects = { { x = 303, y = 300, w = 6, h = 3 } } },
    })
    eq(zoneOf(panel), "4 5", "the merged room in the zone")

    -- A wall put up in the first room: the part with the square stays, the other is free.
    cabin(TEST.api, {
        { id = "6", name = "room", level = 0, rects = { { x = 300, y = 300, w = 3, h = 1 } } },
        { id = "10", name = "room", level = 0, rects = { { x = 300, y = 301, w = 3, h = 2 } } },
        { id = "11", name = "room", level = 0, rects = { { x = 303, y = 300, w = 6, h = 3 } } },
    })
    eq(zoneOf(panel), "11 6", "the part with the square")
    eq(Panels.zoneStates(panel, Panels.building(panel), Panels.rooms(Panels.building(panel)))["10"].state, "free")

    -- The first room gone: its square leaves the zone.
    cabin(TEST.api, {
        { id = "12", name = "room", level = 0, rects = { { x = 303, y = 300, w = 6, h = 3 } } },
    })
    eq(zoneOf(panel), "12")
end)

test("the zone's rooms join the power network by their squares", function()
    cabin(TEST.api, three("1", "2", "3"))
    local panel = Store.newPanel(301, 301, 0, "box")
    local rooms = Panels.rooms(Panels.building(panel))
    TEST.api.calls = {}
    Changes.setZone(panel, { rooms[3].key })
    eq(TEST.api.calls["networks.removeBuilding"], 1, "the whole building left")
    eq(TEST.api.calls["networks.addRoom"], 2, "one room joined, to power and to water")
    eq(Changes.setZone(panel, { "1" }), false, "a room id is not a key")
end)
