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

test("squares told changed are looked at a few a tick, and again at about 1, 3, 6 and 10 s unless they changed", function()
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
    for _ = 1, 119 do TEST.fire("OnTick") end
    eq(looks, 0, "nothing before the second look")
    TEST.fire("OnTick")
    eq(looks, #keys, "the second, at about three")
    looks = 0
    for _ = 1, 179 do TEST.fire("OnTick") end
    eq(looks, 0)
    TEST.fire("OnTick")
    eq(looks, #keys, "the third, at about six")
    looks = 0
    for _ = 1, 239 do TEST.fire("OnTick") end
    eq(looks, 0)
    TEST.fire("OnTick")
    eq(looks, #keys, "the fourth, at about ten")
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

test("taking a line away looks at its tool alone each tick (dropping it stops the action) and through the inventory when completed", function()
    TEST.gameFile("TimedActions/ISBaseTimedAction")
    ISBaseTimedAction = {}
    function ISBaseTimedAction:derive() local class = {}; class.__index = class; return setmetatable(class, { __index = ISBaseTimedAction }) end
    function ISBaseTimedAction.new(self, character) return setmetatable({ character = character }, self) end
    require "BuildingUtilities/Actions"
    twoRooms(TEST.api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 3
    local unit = solarAt(panel, 118, 102)
    ItemTag = { SCREWDRIVER = "screwdriver", PIPE_WRENCH = "wrench", PLIERS = "pliers" }
    local carried, searches = true, 0
    local container = { isInCharacterInventory = function() return carried end }
    local tool = { getContainer = function() return carried and container or nil end }
    local inventory = { getFirstTagEvalRecurse = function() searches = searches + 1; return tool end }
    local checks, can = 0, true
    local affords = BU.Costs.affords
    BU.Costs.affords = function(...) checks = checks + 1; return can end
    local character = { isTimedActionInstant = function() return false end, getInventory = function() return inventory end }
    local action = ISBUDisconnect:new(character, "unit", panel, "power", 118, 102, 0, unit.id)
    eq(searches, 1, "the tool found once, as the action is made")
    for _ = 1, 50 do truthy(action:isValid()) end
    eq(searches, 1, "a tick does not search the inventory")
    eq(checks, 0, "nor ask what the cost needs")
    carried = false
    eq(action:isValid(), false, "the tool dropped: the action stops")
    carried = true
    can = false
    truthy(action:isValid(), "and does not mind what the cost asks of the rest")
    eq(action:complete(), false, "completing looks through the inventory")
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
    -- a key the kept devices lack is looked for in fresh ones, once (a device put down meanwhile)
    eq(Panels.device(panel, "power", "nothing"), nil)
    eq(listings(), 9, "a miss reads fresh")
    Panels.device(panel, "power", key)
    eq(listings(), 9, "and what it read is kept")
    -- a device on a utility the box does not have is another list
    Panels.device(panel, "water", key)
    eq(Panels.device(panel, "power", key), Panels.device(panel, "power", key))
end)

test("a costs snapshot looks through the inventory once for what a menu's options ask, and not past a quarter second", function()
    require "BuildingUtilities/Costs"
    local Costs = BU.Costs
    ItemTag = { SCREWDRIVER = "screwdriver", PIPE_WRENCH = "wrench", PLIERS = "pliers" }
    Perks = { Electricity = 1 }
    getItemNameFromFullType = function(itemType) return itemType end
    local looks = 0
    local wire = 5
    local inventory = {
        getFirstTagEvalRecurse = function(_, tag) looks = looks + 1; return tag == "screwdriver" and {} or nil end,
        getCountTypeEvalArgRecurse = function(_, itemType) looks = looks + 1; return itemType == Costs.WIRE and wire or 0 end,
    }
    local character = { getInventory = function() return inventory end, getPlayerNum = function() return 0 end,
        getPerkLevel = function() return 5 end }
    local now = 9000000
    getTimestampMs = function() return now end
    local cost = Costs.sum({ Costs.outside("power", 4), Costs.addPipe() })
    local snapshot = Costs.snapshot(character)
    -- a menu of many options asking the same: each tool and item looked for once
    for _ = 1, 10 do
        Costs.affords(character, cost, snapshot)
        Costs.describe(character, cost, false, snapshot)
    end
    local first = looks
    eq(Costs.affords(character, cost, snapshot), false, "no wrench")
    eq(looks, first, "asked again: no look")
    -- without a snapshot, each is looked for again, as an action checks it
    Costs.affords(character, cost)
    truthy(looks > first, "no snapshot, a look")
    -- the same snapshot within a quarter second, a new one after
    eq(Costs.snapshot(character), snapshot)
    now = now + 249
    eq(Costs.snapshot(character), snapshot)
    wire = 0
    now = now + 2
    local later = Costs.snapshot(character)
    truthy(later ~= snapshot)
    eq(Costs.snapshot(character, true) ~= later, true, "fresh asks for a new one")
    -- its text tells what it counted
    local text = Costs.describe(character, { tools = {}, items = { { Costs.WIRE, 2 } } }, true, later)
    truthy(text:find("IGUI_BU_NeedItem", 1, true))
end)

test("each minute's sync of the built-on rooms looks again only when something it comes of changed, or after five minutes", function()
    local api = TEST.api
    local KEY = "200,200,0"
    api.buildingsByKey[KEY] = {
        building = { key = KEY, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 200, minY = 200, maxX = 205,
            maxY = 203, room = "hall", roomId = "700" },
        rooms = { { id = "700", name = "hall", level = 0, rects = { { x = 200, y = 200, w = 4, h = 4 } } },
            { id = "701", name = "store", level = 0, rects = { { x = 204, y = 200, w = 2, h = 4 } } } },
        attached = { { level = 0, host = "701", count = 6, extent = 3, rects = { { x = 206, y = 200, w = 3, h = 2 } } } },
        attachedObjects = { power = { { x = 207, y = 201, z = 0, sprite = "lamp", type = "IsoObject", power = 0.01,
            room = "store", roomId = "701" } }, water = {} },
    }
    for x = 200, 205 do
        for y = 200, 203 do api.squares[x .. "," .. y .. ",0"] = KEY end
    end
    local panel = Store.newPanel(201, 201, 0, "box")
    local now = 7000000
    getTimestampMs = function() return now end
    local function looks() return api.calls.attachedObjects or 0 end
    eq(Changes.syncAttached(panel), true, "the lamp taken in")
    local first = looks()
    truthy(first > 0)
    eq(Changes.syncAttached(panel), false)
    eq(looks(), first, "the next minute: not looked at")
    now = now + 60000
    Changes.syncAttached(panel)
    eq(looks(), first, "nor a minute on")
    -- the API's buildings changed
    api.buildingsVersion = 2
    Changes.syncAttached(panel)
    truthy(looks() > first, "a new buildings version")
    local second = looks()
    -- told changed
    BU.Sync.changed(panel.id)
    Changes.syncAttached(panel)
    truthy(looks() > second, "a change told of the box")
    local third = looks()
    BU.Sync.changed("someone else")
    Changes.syncAttached(panel)
    eq(looks(), third, "a change of another box does not")
    -- zone, owners
    panel.zone = { ["201,201,0"] = true }
    Changes.syncAttached(panel)
    truthy(looks() > third, "a zone")
    local fourth = looks()
    Store.ownersChanged()
    Changes.syncAttached(panel)
    truthy(looks() > fourth, "an owner")
    local fifth = looks()
    -- a thing put down in a room (a lamp), not one outside
    local outside = { getSquare = function() return { getRoom = function() return nil end } end }
    local inRoom = { getSquare = function() return { getRoom = function() return {} end } end }
    TEST.fire("OnObjectAdded", outside)
    Changes.syncAttached(panel)
    eq(looks(), fifth, "a thing put down outside")
    TEST.fire("OnObjectAdded", inRoom)
    Changes.syncAttached(panel)
    truthy(looks() > fifth, "a thing put down in a room")
    fifth = looks()
    TEST.fire("OnObjectAboutToBeRemoved", inRoom)
    Changes.syncAttached(panel)
    truthy(looks() > fifth, "a thing taken from a room")
    fifth = looks()
    -- forced, and after five minutes
    Changes.syncAttached(panel, true)
    truthy(looks() > fifth, "forced")
    local sixth = looks()
    now = now + 5 * 60 * 1000 - 1
    Changes.syncAttached(panel)
    eq(looks(), sixth)
    now = now + 2
    Changes.syncAttached(panel)
    truthy(looks() > sixth, "five minutes on")
end)

test("a rack's minute keeps its records and writes nothing to the items when they are the same", function()
    require "BuildingUtilities/Rack"
    ItemTag = { CAR_BATTERY = "battery" }
    local writes = 0
    local function battery(id, charge, condition)
        local item = { id = id, charge = charge, condition = condition }
        function item:getID() return self.id end
        function item:getFullType() return "Base.CarBattery1" end
        function item:getCurrentUsesFloat() return self.charge end
        function item:getCondition() return self.condition end
        function item:getConditionMax() return 100 end
        function item:setUsedDelta(v) writes = writes + 1; self.charge = v end
        function item:setCondition(v) writes = writes + 1; self.condition = v end
        return item
    end
    local items = { battery(1, 0.5, 80), battery(2, 0.25, 60) }
    local container = { getAcceptItemFunction = function() return BU.Rack.ACCEPT end,
        getAllTag = function() return TEST_javaList(items) end }
    local overlay
    local object = { getContainer = function() return container end, getOverlaySprite = function() return nil end,
        setOverlaySprite = function(_, name) overlay = name end }
    local unit = Store.newUnit("rack", 10, 10, 0, BU.Rack.SPRITE)
    unit.batteries = {}
    BU.Rack.sync(unit, object)
    eq(#unit.batteries, 2, "records made")
    local records = unit.batteries
    BU.Rack.sync(unit, object)
    eq(unit.batteries, records, "the same records")
    eq(writes, 0, "nothing written to items that match")
    -- the bank spent charge: the item takes it, once
    records[1].charge = 0.4
    BU.Rack.sync(unit, object)
    eq(writes, 2, "charge and condition set on the one item")
    BU.Rack.sync(unit, object)
    eq(writes, 2)
    -- a battery taken out
    table.remove(items, 1)
    BU.Rack.sync(unit, object)
    eq(#unit.batteries, 1)
    eq(unit.batteries[1], records[2], "the other keeps its record")
end)

test("the reserves' zone key is made once while the zone and its rooms are the same", function()
    local api = TEST.api
    twoRooms(api, "A")
    local panel = Store.newPanel(102, 102, 0, "box")
    local made = 0
    local zoneRooms = Panels.zoneRooms
    Panels.zoneRooms = function(...) made = made + 1; return zoneRooms(...) end
    Changes.syncReserves(panel)
    local first = made
    truthy(first >= 1)
    Changes.syncReserves(panel)
    Changes.syncReserves(panel)
    eq(made, first, "kept")
    panel.zone = { ["101,101,0"] = true }
    Changes.syncReserves(panel)
    truthy(made > first, "a new zone makes it again")
    Panels.zoneRooms = zoneRooms
end)

test("boxes and units are found by their square from an index kept with them", function()
    local panel = Store.newPanel(10, 20, 0, "box")
    local upstairs = Store.newPanel(10, 20, 1, "box")
    local unit = Store.newUnit("solar", 11, 20, 0, "solar")
    eq(Store.panelAt(10, 20, 0), panel)
    eq(Store.panelAt(10, 20, 1), upstairs, "another floor")
    eq(Store.panelAt(11, 20, 0), nil)
    eq(Store.unitAt(11, 20, 0), unit)
    eq(Store.unitAt(10, 20, 0), nil)
    -- taken away
    Store.remove(panel.id)
    eq(Store.panelAt(10, 20, 0), nil)
    eq(Store.panelAt(10, 20, 1), upstairs, "the others stay")
    Store.removeUnit(unit.id)
    eq(Store.unitAt(11, 20, 0), nil)
    -- put down again on the same square
    local again = Store.newPanel(10, 20, 0, "box")
    eq(Store.panelAt(10, 20, 0), again)
    local second = Store.newUnit("solar", 11, 20, 0, "solar")
    eq(Store.unitAt(11, 20, 0), second)
    -- the save's data read again (a client receiving the server's): the index follows the tables
    local data = Store.data()
    local copy = { next = data.next, nextUnit = data.nextUnit, nextLine = data.nextLine, lines = {}, panels = {}, units = {} }
    copy.panels[again.id] = { id = again.id, x = 30, y = 30, z = 0 }
    ModData.add(Store.KEY, copy)
    Store.reload()
    eq(Store.panelAt(10, 20, 0), nil, "the old table's box is not found")
    eq(Store.panelAt(30, 30, 0), copy.panels[again.id])
    eq(Store.unitAt(11, 20, 0), nil)
    -- an entry that is not there any more is not handed out
    Store.units()[second.id] = nil
    eq(Store.unitAt(11, 20, 0), nil)
end)

test("a device missing from the built-on rooms but still on its square is let go after the 20 s grace, not after five minutes", function()
    local api = TEST.api
    local KEY = "200,200,0"
    local LAMP = "207,201,0,lamp"
    api.buildingsByKey[KEY] = {
        building = { key = KEY, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 200, minY = 200, maxX = 205,
            maxY = 203, room = "hall", roomId = "700" },
        rooms = { { id = "700", name = "hall", level = 0, rects = { { x = 200, y = 200, w = 4, h = 4 } } },
            { id = "701", name = "store", level = 0, rects = { { x = 204, y = 200, w = 2, h = 4 } } } },
        attached = { { level = 0, host = "701", count = 6, extent = 3, rects = { { x = 206, y = 200, w = 3, h = 2 } } } },
        attachedObjects = { power = { { x = 207, y = 201, z = 0, sprite = "lamp", type = "IsoObject", power = 0.01,
            room = "store", roomId = "701" } }, water = {} },
    }
    for x = 200, 205 do
        for y = 200, 203 do api.squares[x .. "," .. y .. ",0"] = KEY end
    end
    local panel = Store.newPanel(201, 201, 0, "box")
    local now = 9000000
    getTimestampMs = function() return now end
    eq(Changes.syncAttached(panel), true, "the lamp taken in")
    eq(panel.power.attached[LAMP], true)
    -- the lamp is still on its square, but the rooms no longer have it (the region data changed)
    local lamp = { getSpriteName = function() return "lamp" end }
    TEST.squares["207,201,0"] = { objects = { lamp } }
    api.buildingsByKey[KEY].attachedObjects.power = {}
    api.buildingsVersion = 2
    eq(Changes.syncAttached(panel), false, "missing now: the grace begins")
    eq(panel.power.attached[LAMP], true, "kept")
    now = now + 19000
    Changes.syncAttached(panel)
    eq(panel.power.attached[LAMP], true, "kept inside the grace")
    now = now + 2000
    eq(Changes.syncAttached(panel), true, "the grace is over: the next look lets it go, not five minutes on")
    eq(panel.power.attached[LAMP], nil)
end)

test("a command naming a device put down within the last second finds it", function()
    local api = TEST.api
    local KEY = "200,200,0"
    local LAMP = "207,201,0,lamp"
    api.buildingsByKey[KEY] = {
        building = { key = KEY, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 200, minY = 200, maxX = 205,
            maxY = 203, room = "hall", roomId = "700" },
        rooms = { { id = "700", name = "hall", level = 0, rects = { { x = 200, y = 200, w = 4, h = 4 } } },
            { id = "701", name = "store", level = 0, rects = { { x = 204, y = 200, w = 2, h = 4 } } } },
        attached = { { level = 0, host = "701", count = 6, extent = 3, rects = { { x = 206, y = 200, w = 3, h = 2 } } } },
        attachedObjects = { power = {}, water = {} },
    }
    for x = 200, 205 do
        for y = 200, 203 do api.squares[x .. "," .. y .. ",0"] = KEY end
    end
    local panel = Store.newPanel(201, 201, 0, "box")
    local now = 11000000
    getTimestampMs = function() return now end
    eq(Panels.device(panel, "power", LAMP), nil, "no lamp yet; the devices are kept")
    -- a lamp put down in the shed 300 ms later, with nothing telling the mod
    now = now + 300
    api.buildingsByKey[KEY].attachedObjects.power = { { x = 207, y = 201, z = 0, sprite = "lamp", type = "IsoObject",
        power = 0.01, room = "store", roomId = "701" } }
    local device = Panels.device(panel, "power", LAMP)
    truthy(device ~= nil, "found on the miss, from fresh devices")
    eq(device.key, LAMP)
    -- a key nobody has is looked for fresh once, and the answer is nil
    eq(Panels.device(panel, "power", "1,1,0,none"), nil)
end)
