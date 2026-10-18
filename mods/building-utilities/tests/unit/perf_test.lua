-- What is kept for speed stays right when its inputs change: the working units follow a box's tier, zone and
-- buildings (not only the link version), the reach index follows the tiers.
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Panels, Changes, Store, Links, Units = BU.Panels, BU.Changes, BU.Store, BU.Links, BU.Units

-- A building of two rooms side by side, 5 by 5 each, at (100, 100): "west" and "east".
local function twoRooms(api, key)
    api.buildingsByKey[key] = {
        building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 100, minY = 100, maxX = 109,
            maxY = 104, room = "room", roomId = key .. "-w" },
        rooms = {
            { id = key .. "-w", name = "west", level = 0, rects = { { x = 100, y = 100, w = 5, h = 5 } } },
            { id = key .. "-e", name = "east", level = 0, rects = { { x = 105, y = 100, w = 5, h = 5 } } },
        },
    }
    for dx = 0, 9 do
        for dy = 0, 4 do api.squares[(100 + dx) .. "," .. (100 + dy) .. ",0"] = key end
    end
end

local function solarAt(panel, x, y)
    local unit = Store.newUnit("solar", x, y, 0, "solar")
    Changes.connectUnit(unit, panel, {})
    return unit
end

test("the working units follow a box's tier, kept while it holds", function()
    twoRooms(TEST.api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 3
    local unit = solarAt(panel, 118, 102)
    eq(Links.get("u:" .. unit.id).panel, panel.id, "hung on the box")
    local working = Units.working(panel)
    eq(#working, 1, "a tier 3 box reaches 10 squares")
    eq(Units.working(panel), working, "the same list while nothing changed")
    eq(Units.count(panel.id, "power"), 1)
    -- A lower tier (no link version counted): the line is past its reach now.
    panel.tier = 1
    eq(#Units.working(panel), 0, "tier 1 does not reach")
    eq(Units.count(panel.id, "power"), 0)
    panel.tier = 3
    eq(#Units.working(panel), 1, "back with the tier")
    eq(Units.count(panel.id, "power"), 1)
    eq(Units.count(panel.id, "water"), 0)
end)

test("the working units follow the box's zone", function()
    twoRooms(TEST.api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    local unit = solarAt(panel, 101, 101)
    local wall = Links.get("u:" .. unit.id).wall
    truthy(wall, "hung on a wall")
    eq(#Units.working(panel), 1)
    -- The zone moved to the east room only: the wall of the west room is not its own any more.
    panel.zone = { ["108,102,0"] = true }
    eq(#Units.working(panel), 0, "cut")
    panel.zone = nil
    eq(#Units.working(panel), 1, "the whole building again")
end)

test("the working units follow a change of the buildings", function()
    local api = TEST.api
    twoRooms(api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    solarAt(panel, 101, 101)
    eq(#Units.working(panel), 1)
    -- The walls taken down so that the box's room is none: the line's wall is not a room's of the box.
    api.buildingsByKey.A.rooms = { { id = "A-x", name = "west", level = 0, rects = { { x = 100, y = 100, w = 1, h = 1 } } } }
    api.buildingsVersion = 2
    eq(#Units.working(panel), 0, "cut")
end)

test("the reach index follows the boxes' tiers", function()
    local api = TEST.api
    -- A building to x = 120: a square at 130 is in the next grid cell of 32, which only a higher tier's range covers.
    api.buildingsByKey.W = {
        building = { key = "W", playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 100, minY = 100, maxX = 120,
            maxY = 104, room = "room", roomId = "W-0" },
        rooms = { { id = "W-0", name = "room", level = 0, rects = { { x = 100, y = 100, w = 21, h = 5 } } } },
    }
    for dx = 0, 20 do
        for dy = 0, 4 do api.squares[(100 + dx) .. "," .. (100 + dy) .. ",0"] = "W" end
    end
    local panel = Store.newPanel(102, 102, 0, "box")
    eq(#Panels.panelsReaching(130, 102, 0), 0, "tier 1 does not reach")
    panel.tier = 4
    eq(#Panels.panelsReaching(130, 102, 0), 1, "tier 4 does (range " .. BU.connectRange(4) .. ")")
    panel.tier = 1
    eq(#Panels.panelsReaching(130, 102, 0), 0, "and not again at tier 1")
    SandboxVars.BuildingUtilities = { ConnectRange = 12 }
    eq(#Panels.panelsReaching(130, 102, 0), 1, "a range from the sandbox counts too")
end)
