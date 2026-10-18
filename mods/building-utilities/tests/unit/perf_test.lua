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

-- A building of 5 by 5 at (100, 100) and a box in it, with a floor decal API that counts what it is given.
local function floorScene()
    local api = TEST.api
    twoRooms(api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 3
    local sets, watches, unwatches, onChanged = {}, 0, 0, nil
    api.table.floor = { clear = function() end, set = function(_, x, y, z, list) sets[x .. "," .. y .. "," .. z] = list end }
    api.table.squares.watch = function(_, _, fn) watches = watches + 1; onChanged = fn; return watches end
    api.table.squares.unwatch = function() unwatches = unwatches + 1 end
    for x = 100, 130 do
        for y = 95, 125 do TEST.squares[x .. "," .. y .. ",0"] = { objects = {}, floor = "blends_natural_01_0" } end
    end
    return panel, sets, function() return watches, unwatches end, function(...) onChanged(...) end
end

local function setCount(sets)
    local n = 0
    for _ in pairs(sets) do n = n + 1 end
    return n
end

test("a bump of the link version that changes no line sends no square and watches nothing again", function()
    require "BuildingUtilities/FloorLines"
    local panel, sets, watched = floorScene()
    local a = solarAt(panel, 118, 102)
    local b = solarAt(panel, 118, 108)
    TEST.fire("OnTick")
    local first = setCount(sets)
    truthy(first > 10, "the squares of both lines")
    local watchesBefore = watched()
    local calls = {}
    TEST.api.table.floor.set = function(_, x, y, z, list) calls[x .. "," .. y .. "," .. z] = list or false end
    -- a toggle that changes no geometry
    Store.linksChanged()
    TEST.fire("OnTick")
    eq(setCount(calls), 0, "nothing sent")
    eq(watched(), watchesBefore, "nothing watched again")
    -- one line gone: only its squares are taken away, and the other stays
    local routeA = BU.Links.route(BU.Links.get("u:" .. a.id))
    Changes.removeUnit(b)
    TEST.fire("OnTick")
    local gone = 0
    for key, list in pairs(calls) do
        eq(list, false, "taken away: " .. key)
        gone = gone + 1
    end
    truthy(gone > 0 and gone < first, "the squares of the line taken away only")
    eq(BU.Links.route(BU.Links.get("u:" .. a.id)), routeA, "the other line's route is the same table")
    truthy(watched() > watchesBefore, "the squares are fewer: watched again")
end)

test("a line that lies another way sends its squares only", function()
    require "BuildingUtilities/FloorLines"
    local panel, sets = floorScene()
    local a = solarAt(panel, 118, 102)
    local b = solarAt(panel, 118, 108)
    TEST.fire("OnTick")
    local before = BU.Links.get("u:" .. b.id).path
    sets = nil
    local sent = {}
    TEST.api.table.floor.set = function(_, x, y, z, list) sent[x .. "," .. y .. "," .. z] = list end
    -- b laid another way round: a corner elsewhere
    local line = BU.Links.get("u:" .. b.id)
    local path = {}
    for i = 1, #line.path do path[i] = line.path[i] end
    truthy(#path >= 4, "a way of corners")
    local fx, fy = path[1], path[2]
    line.path = { fx, fy, fx, fy - 2, path[#path - 1], fy - 2, path[#path - 1], path[#path] }
    Store.linksChanged()
    TEST.fire("OnTick")
    local n = setCount(sent)
    truthy(n > 0, "its new squares")
    for key in pairs(sent) do
        local x = tonumber(key:match("^(-?%d+),"))
        truthy(x >= 105, "only squares round the second line: " .. key)
    end
    local lineA = BU.Links.get("u:" .. a.id)
    local wanted = BU.FloorLines.wanted()
    local route = BU.Links.route(lineA)
    for _, square in ipairs(route) do
        truthy(wanted[square.x .. "," .. square.y .. ",0"], "the first line's squares stay wanted")
    end
    truthy(before ~= line.path)
end)

test("squares told changed are looked at a few a tick, and again twice (about 1 s and 10 s) unless they changed", function()
    require "BuildingUtilities/FloorLines"
    local panel, sets, watched, changed = floorScene()
    solarAt(panel, 118, 102)
    TEST.fire("OnTick")
    local wanted = BU.FloorLines.wanted()
    local keys = {}
    for key, square in pairs(wanted) do keys[#keys + 1] = square end
    truthy(#keys > 8, "a line of squares")
    local looks = 0
    local madeFloor = BU.FloorLines.madeFloor
    BU.FloorLines.madeFloor = function(...) looks = looks + 1; return madeFloor(...) end
    for _, square in ipairs(keys) do changed(1, square.x, square.y, square.z) end
    -- the same square told twice before it is looked at is one look
    changed(1, keys[1].x, keys[1].y, keys[1].z)
    TEST.fire("OnTick")
    eq(looks, #keys, "each square once, in the first tick")
    looks = 0
    for _ = 1, 59 do TEST.fire("OnTick") end
    eq(looks, 0, "nothing before the first look again")
    TEST.fire("OnTick")
    eq(looks, #keys, "the first look again, at about a second")
    looks = 0
    for _ = 1, 560 do TEST.fire("OnTick") end
    eq(looks, #keys, "the second, at about ten")
    looks = 0
    for _ = 1, 1200 do TEST.fire("OnTick") end
    eq(looks, 0, "and no more")
    -- a floor that changed between the looks starts them over
    changed(1, keys[1].x, keys[1].y, keys[1].z)
    TEST.fire("OnTick")
    TEST.squares[keys[1].x .. "," .. keys[1].y .. ",0"].floor = "floors_interior_tilesandwood_01_0"
    looks = 0
    for _ = 1, 60 do TEST.fire("OnTick") end
    eq(looks, 1, "its look again saw it")
    looks = 0
    for _ = 1, 60 do TEST.fire("OnTick") end
    eq(looks, 1, "and looks once more after a second, then the ten")
    BU.FloorLines.madeFloor = madeFloor
end)

test("a crowd of squares told changed is looked at 64 a tick", function()
    require "BuildingUtilities/FloorLines"
    local panel, sets, watched, changed = floorScene()
    panel.tier = 6
    for y = 94, 122, 3 do solarAt(panel, 125, y) end
    TEST.fire("OnTick")
    local squares = {}
    for _, square in pairs(BU.FloorLines.wanted()) do squares[#squares + 1] = square end
    truthy(#squares > 128, "many squares: " .. #squares)
    local looks = 0
    local madeFloor = BU.FloorLines.madeFloor
    BU.FloorLines.madeFloor = function(...) looks = looks + 1; return madeFloor(...) end
    for _, square in ipairs(squares) do changed(1, square.x, square.y, square.z) end
    TEST.fire("OnTick")
    eq(looks, 64, "64 in the first tick")
    TEST.fire("OnTick")
    eq(looks, 128, "64 more in the next")
    for _ = 1, 10 do TEST.fire("OnTick") end
    eq(looks, #squares, "all of them, once each")
    BU.FloorLines.madeFloor = madeFloor
end)

test("a line's route is the same squares while its way and ends are, and walked once for each end it has", function()
    local api = TEST.api
    twoRooms(api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 3
    local unit = solarAt(panel, 118, 102)
    local line = BU.Links.get("u:" .. unit.id)
    local route = BU.Links.route(line)
    eq(BU.Links.route(line), route, "the same table")
    -- a way replaced
    line.path = BU.Links.pathFor(line)
    local again = BU.Links.route(line)
    truthy(again ~= route, "another way, other squares")
    eq(#again, #route)
    eq(BU.Links.route(line), again)
    -- no way kept: walked once, then the memo
    line.path = nil
    local before = api.calls["squares.path"] or 0
    local walked = BU.Links.route(line)
    eq(BU.Links.route(line), walked)
    eq((api.calls["squares.path"] or 0) - before, 1, "walked once")
    -- taken away and laid again: walked afresh
    Changes.removeUnit(unit)
    local other = solarAt(panel, 118, 103)
    truthy(BU.Links.get("u:" .. other.id) ~= nil)
end)

test("taking a line away checks the tool when it is queued and completed, not each tick", function()
    TEST.gameFile("TimedActions/ISBaseTimedAction")
    ISBaseTimedAction = {}
    function ISBaseTimedAction:derive() local class = {}; class.__index = class; return setmetatable(class, { __index = ISBaseTimedAction }) end
    function ISBaseTimedAction.new(self, character) return setmetatable({ character = character }, self) end
    require "BuildingUtilities/Actions"
    twoRooms(TEST.api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 3
    local unit = solarAt(panel, 118, 102)
    local checks, can = 0, true
    local affords = BU.Costs.affords
    BU.Costs.affords = function(...) checks = checks + 1; return can end
    local character = { isTimedActionInstant = function() return false end }
    local action = ISBUDisconnect:new(character, "unit", panel, "power", 118, 102, 0, unit.id)
    for _ = 1, 50 do truthy(action:isValid()) end
    eq(checks, 0, "isValid does not look at the inventory")
    can = false
    truthy(action:isValid(), "and does not mind the tool")
    eq(action:complete(), false, "completing does")
    eq(checks, 1)
    truthy(BU.Links.get("u:" .. unit.id), "the line stays")
    BU.Costs.affords = affords
end)

test("a box's devices by part key are read once for what asks within a second, and again when anything they come of changes", function()
    local api = TEST.api
    twoRooms(api, "A")
    api.buildingsByKey.A.objects = { power = { { x = 101, y = 101, z = 0, sprite = "lamp", type = "IsoObject", power = 0.01,
        room = "west", roomId = "A-w" } } }
    TEST.squares["101,101,0"] = { objects = {} }
    local panel = Store.newPanel(102, 102, 0, "box")
    local now = 5000000
    getTimestampMs = function() return now end
    local key = BU.thingKey(101, 101, 0, "lamp")
    local function listings() return api.calls.objects or 0 end
    local device = Panels.device(panel, "power", key)
    truthy(device, "the lamp is the box's")
    eq(Panels.device(panel, "power", key), device, "the same device")
    Panels.device(panel, "power", "nothing")
    eq(listings(), 1, "listed once")
    -- told changed
    Store.dataChanged()
    Panels.device(panel, "power", key)
    eq(listings(), 2, "a change told")
    Store.ownersChanged()
    Panels.device(panel, "power", key)
    eq(listings(), 3, "an owner changed")
    Store.linksChanged()
    Panels.device(panel, "power", key)
    eq(listings(), 4, "a link version")
    panel.zone = { ["101,101,0"] = true }
    Panels.device(panel, "power", key)
    eq(listings(), 5, "a zone")
    panel.tier = 2
    Panels.device(panel, "power", key)
    eq(listings(), 6, "a tier")
    api.buildingsVersion = 2
    Panels.device(panel, "power", key)
    eq(listings(), 7, "the buildings")
    Panels.device(panel, "power", key)
    eq(listings(), 7, "and kept again")
    -- and not past a second
    now = now + 1000
    Panels.device(panel, "power", key)
    eq(listings(), 8, "a second later")
    -- a device on a utility the box does not have is another list
    Panels.device(panel, "water", key)
    eq(Panels.device(panel, "power", key), Panels.device(panel, "power", key))
end)
