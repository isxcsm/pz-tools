-- What Panels keeps of buildings: a square's building, a building's rooms and the rooms built onto it, kept for the
-- API's version of the buildings (buildings.version) and read again only when it changes; and each minute's sync of
-- the devices in built-on rooms, which reads only those rooms' objects.
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Panels, Changes, Store = BU.Panels, BU.Changes, BU.Store

-- A map building: a hall and a store; a shed built onto the store, 3 by 2, with a lamp in it.
local KEY = "200,200,0"
local LAMP = "207,201,0,lamp"
local function house(api)
    api.buildingsByKey[KEY] = {
        building = { key = KEY, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 200, minY = 200, maxX = 205,
            maxY = 203, room = "hall", roomId = "700" },
        rooms = {
            { id = "700", name = "hall", level = 0, rects = { { x = 200, y = 200, w = 4, h = 4 } } },
            { id = "701", name = "store", level = 0, rects = { { x = 204, y = 200, w = 2, h = 4 } } },
        },
        attached = { { level = 0, host = "701", count = 6, extent = 3, rects = { { x = 206, y = 200, w = 3, h = 2 } } } },
        attachedObjects = {
            power = { { x = 207, y = 201, z = 0, sprite = "lamp", type = "IsoObject", power = 0.01, room = "store",
                roomId = "701" } },
            water = {},
        },
    }
    for x = 200, 205 do
        for y = 200, 203 do api.squares[x .. "," .. y .. ",0"] = KEY end
    end
end

local function calls(name) return TEST.api.calls[name] or 0 end

test("a building and its rooms are read once while the API's version holds", function()
    house(TEST.api)
    local building = Panels.buildingAt(201, 201, 0)
    eq(building.key, KEY)
    eq(Panels.buildingAt(201, 201, 0), building, "the same building")
    eq(calls("at"), 1, "the square asked once")
    local rooms = Panels.rooms(building)
    eq(Panels.rooms(building), rooms, "the same rooms")
    Panels.attached(building)
    Panels.attachedSize(building)
    eq(calls("rooms"), 1, "the rooms read once")
    eq(calls("attached"), 1, "the built-on rooms found once")
    eq(Panels.buildingAt(0, 0, 0), nil)
    eq(Panels.buildingAt(0, 0, 0), nil)
    eq(calls("at"), 2, "a square of no building asked once too")
end)

test("a room built onto the building is rectangles of the room it touches most, after its own", function()
    house(TEST.api)
    local building = Panels.buildingAt(201, 201, 0)
    local rooms = Panels.rooms(building)
    eq(#rooms[1].rects, 1, "the hall")
    eq(rooms[1].own, nil, "the hall has nothing built onto it")
    eq(#rooms[2].rects, 2, "the store with the shed")
    eq(rooms[2].own, 1)
    eq(rooms[2].rects[2].x, 206)
    local spaces = Panels.attached(building)
    eq(#spaces, 1)
    eq(Panels.attachedAt(spaces, 208, 201, 0), spaces[1], "a square of the shed")
    eq(Panels.attachedAt(spaces, 208, 201, 1), nil, "the floor above")
    eq(Panels.attachedAt(spaces, 209, 201, 0), nil, "past the shed")
    eq(Panels.attachedSize(building), 6)
end)

test("a new version (a wall built or taken down) makes the next ask read again", function()
    local api = TEST.api
    house(api)
    local building = Panels.buildingAt(201, 201, 0)
    Panels.rooms(building)
    -- The shed's roof taken away: the API's region data changes with a new version, never without.
    api.buildingsByKey[KEY].attached = {}
    eq(#Panels.attached(building), 1, "kept while the version holds")
    api.buildingsVersion = 2
    building = Panels.buildingAt(201, 201, 0)
    eq(calls("at"), 2, "the square asked again")
    eq(#Panels.attached(building), 0, "the shed is gone")
    eq(#Panels.rooms(building)[2].rects, 1, "the store is its own again")
    eq(calls("rooms"), 2)
    eq(calls("attached"), 2)
end)

test("a building players built has no built-on rooms, and the API is not asked for them", function()
    local api = TEST.api
    house(api)
    api.buildingsByKey[KEY].building.playerBuilt = true
    local building = Panels.buildingAt(201, 201, 0)
    eq(#Panels.attached(building), 0)
    eq(#Panels.rooms(building)[2].rects, 1)
    eq(calls("attached"), 0)
end)

test("built-on rooms the API cannot find are nil, and the rooms are still listed", function()
    local api = TEST.api
    house(api)
    api.buildingsByKey[KEY].attached = nil
    local building = Panels.buildingAt(201, 201, 0)
    eq(Panels.attached(building), nil)
    eq(#Panels.rooms(building), 2)
    eq(Panels.attachedSize(building), 0)
end)

test("a box's automatic name is kept while the version holds", function()
    local api = TEST.api
    house(api)
    local panel = Store.newPanel(201, 201, 0, "box")
    local name = Panels.autoName(panel)
    eq(name, "IGUI_BU_PanelOf Hall", "the largest room of the map's, the shed not counted")
    eq(Panels.autoName(panel), name)
    eq(calls("rooms"), 1)
    api.buildingsVersion = 2
    eq(Panels.autoName(panel), name)
    eq(calls("rooms"), 2, "read again for the new version")
end)

test("each minute's sync reads only the built-on rooms' objects, and the building once", function()
    house(TEST.api)
    local panel = Store.newPanel(201, 201, 0, "box")
    eq(Changes.syncAttached(panel), true, "the lamp taken in")
    eq(panel.power.attached[LAMP], true)
    eq(calls("networks.include"), 1, "the lamp included in the power network")
    eq(Changes.syncAttached(panel), false, "nothing changed the next minute")
    eq(calls("objects"), 0, "the building's objects not read")
    eq(calls("near"), 0, "its surroundings not read")
    eq(calls("at"), 1)
    eq(calls("rooms"), 1)
    eq(calls("attached"), 1)
    -- Not in the box's zone: let go once missing past the grace (its square is not loaded: not known gone).
    panel.zone = { ["700,700,0"] = true }
    eq(Changes.syncAttached(panel), false, "kept while it may be the region data lagging")
end)

test("a device in a built-on room with a part elsewhere goes by the building's devices", function()
    house(TEST.api)
    -- The lamp has a second part past the shed, at (209, 201): the building's devices decide.
    local function square(x, y)
        return { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end }
    end
    local second = { getSquare = function() return square(209, 201) end, getSpriteName = function() return "lamp" end }
    local lamp = {
        getSquare = function() return square(207, 201) end,
        getSpriteName = function() return "lamp" end,
        hasSpriteGrid = function() return true end,
        getSpriteGridObjectsIncludingSelf = function(self, list) list:add(self); list:add(second); return list end,
    }
    TEST.squares["207,201,0"] = { objects = { lamp } }
    local panel = Store.newPanel(201, 201, 0, "box")
    eq(Panels.attachedKeys(panel, "power", Panels.building(panel)), nil, "not from the rooms' objects alone")
    eq(Changes.syncAttached(panel), true)
    eq(panel.power.attached[LAMP], true, "the lamp's own key, its first part's")
    eq(calls("objects"), 1, "the building's devices read")
end)

test("a device another box connected outside before the room was built stays outside", function()
    house(TEST.api)
    local other = Store.newPanel(500, 500, 0, "box")
    other.power.included[LAMP] = true
    local panel = Store.newPanel(201, 201, 0, "box")
    eq(Changes.syncAttached(panel), false)
    eq(panel.power.attached[LAMP], nil)
end)

test("a device outside with its line is supplied unless cut, and the line taken up takes the cut with it", function()
    local Networks = BU.Networks
    local panel = Store.newPanel(201, 201, 0, "box")
    local data = panel.water
    local TAP = "204,201,0,tap"
    local device = { key = TAP, keys = { TAP }, inside = false, entry = { x = 204, y = 201, z = 0, sprite = "tap" } }
    eq(Networks.rule(panel, "water", TAP), "reset", "no line: the building's rule")
    Changes.includeOutside(panel, "water", device, {})
    eq(Networks.rule(panel, "water", TAP), "include", "its line laid")
    data.excluded[TAP] = true
    eq(Networks.rule(panel, "water", TAP), "exclude", "its supply cut at the box, the line kept")
    truthy(Changes.excludeOutside(panel, "water", device), "the line taken up")
    eq(data.excluded[TAP], nil, "its cut gone with it")
    data.excluded[TAP] = true
    Changes.includeOutside(panel, "water", device, {})
    eq(Networks.rule(panel, "water", TAP), "include", "a line laid again supplies it")
end)

test("a box lists what it could take and no box has: producers in reach, units in reach", function()
    require "BuildingUtilities/Solar"
    house(TEST.api)
    TEST.api.buildingsByKey[KEY].producers = { power = {
        { x = 208, y = 201, z = 0, sprite = "near generator", type = "IsoGenerator", utility = "power" },
        { x = 230, y = 201, z = 0, sprite = "far generator", type = "IsoGenerator", utility = "power" },
        { x = 209, y = 202, z = 0, sprite = "taken generator", type = "IsoGenerator", utility = "power" },
    } }
    local panel = Store.newPanel(201, 201, 0, "box")
    local other = Store.newPanel(500, 500, 0, "box")
    Changes.connectProducer(other, "power", 209, 202, 0, {})
    local free = Store.newUnit("solar", 207, 203, 0, "panel")
    local wired = Store.newUnit("solar", 207, 202, 0, "panel")
    Changes.connectUnit(wired, other, {})
    Store.newUnit("solar", 240, 240, 0, "panel")
    local found = Panels.unwiredProducers(panel, "power")
    eq(#found, 2, "the near generator and the free solar panel")
    eq(found[1].sprite, "near generator")
    eq(found[2].unit, free)
    eq(#Panels.unwiredProducers(panel, "water"), 0, "no water storage")
end)

test("a box cuts devices one by one from tier 2; its upgrade notes tell what each tier adds", function()
    local panel = Store.newPanel(201, 201, 0, "box")
    eq(Panels.cuts(panel), false, "tier 1 supplies all it reaches")
    panel.tier = 2
    eq(Panels.cuts(panel), true)
    truthy(Panels.upgradeNote(2, true):find("IGUI_BU_CutNote", 1, true), "tier 2: cutting")
    truthy(Panels.upgradeNote(3, true):find("IGUI_BU_TimerNote", 1, true), "tier 3: timers")
    eq(Panels.upgradeNote(4, true):find("IGUI_BU_TimerNote", 1, true), nil)
end)


test("a device's own switch is read, never thrown: the game's kinds and other mods' through the global list", function()
    require "BuildingUtilities/Switches"
    local machine = { kind = "machine", on = false }
    table.insert(BuildingUtilitiesSwitches, { state = function(object)
        if object.kind ~= "machine" then return nil end
        return object.on
    end })
    eq(BU.Switches.state(machine), false)
    machine.on = true
    eq(BU.Switches.state(machine), true)
    eq(BU.Switches.state({ kind = "fridge" }), nil, "no switch")
    eq(BU.Switches.set, nil, "nothing to throw it with")
    table.remove(BuildingUtilitiesSwitches)
end)
