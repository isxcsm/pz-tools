-- What the mod keeps up as changes are told, so that nothing is scanned on a tick, a second, a minute or a menu: the
-- save's table, who has which device, the networks' states, the tripped boxes and spraying sprinklers, the lights, the
-- lines' squares looked at again.
require "BuildingUtilities/Changes"
require "BuildingUtilities/PanelBlink"
require "BuildingUtilities/SprinklerSpray"
require "BuildingUtilities/Lights"
require "BuildingUtilities/FloorLines"
local BU = BuildingUtilities
local Store, Panels, Changes, Networks, Links = BU.Store, BU.Panels, BU.Changes, BU.Networks, BU.Links

-- A one-room house at (x, y), 5 by 5, on one level.
local function building(api, key, x, y)
    api.buildingsByKey[key] = {
        building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = x, minY = y, maxX = x + 4,
            maxY = y + 4, room = "room", roomId = key .. "-0" },
        rooms = { { id = key .. "-0", name = "room", level = 0, rects = { { x = x, y = y, w = 5, h = 5 } } } },
    }
    for dx = 0, 4 do
        for dy = 0, 4 do api.squares[(x + dx) .. "," .. (y + dy) .. ",0"] = key end
    end
end

-- A world object of a box or a unit, on its square.
local function thing(markKey, id, sprite, x, y, z)
    local square = { getX = function() return x end, getY = function() return y end, getZ = function() return z or 0 end }
    return { hasModData = function() return true end, getModData = function() return { [markKey] = id } end,
        getSquare = function() return square end, getSprite = function() return { getName = function() return sprite end } end }
end

local function playerAt(x, y)
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return { getX = function() return x end, getY = function() return y end,
        isDead = function() return false end } end
end

local function tick(times) for _ = 1, times or 1 do TEST.fire("OnTick") end end

test("the save's table is read once, and again when the game's mod data is", function()
    local count, getOrCreate = 0, ModData.getOrCreate
    ModData.getOrCreate = function(key) count = count + 1; return getOrCreate(key) end
    Store.newPanel(1, 1, 0, "box")
    for _ = 1, 20 do Store.get("p1") end
    eq(count, 1)
    Store.reload()
    Store.get("p1")
    eq(count, 2, "read again when asked to")
    TEST.fire("OnInitGlobalModData")
    Store.get("p1")
    eq(count, 3, "and as a world's mod data starts")
end)

test("who connected or has a device is an index, kept until a box's sets change", function()
    local api = TEST.api
    building(api, "A", 100, 100)
    local panel, other = Store.newPanel(102, 102, 0, "box"), Store.newPanel(500, 500, 0, "box")
    local TAP = "106,102,0,tap"
    local device = { key = TAP, keys = { TAP }, inside = false, entry = { x = 106, y = 102, z = 0, sprite = "tap" } }
    eq(Store.includedOwner("water", TAP), nil)
    Changes.includeOutside(panel, "water", device, {})
    eq(Store.includedOwner("water", TAP), panel, "a line laid")
    eq(Store.inclusionOwner("water", TAP), panel)
    eq(Store.includedOwner("power", TAP), nil, "of its utility")
    truthy(Changes.excludeOutside(panel, "water", device))
    eq(Store.includedOwner("water", TAP), nil, "the line taken up")
    -- Rooms built onto a building.
    other.power.attached["1,1,0,lamp"] = true
    Store.ownersChanged()
    eq(Store.attachedOwner("power", "1,1,0,lamp"), other)
    eq(Store.attachedOwner("power", "1,1,0,lamp", other), nil, "other than one")
    Store.remove(other.id)
    eq(Store.attachedOwner("power", "1,1,0,lamp"), nil, "a box taken away")
end)

test("a network's state is kept for the millisecond; a change drops only that box's utility", function()
    local asked = {}
    TEST.api.table.networks.state = function(id) asked[id] = (asked[id] or 0) + 1; return { load = 1 } end
    getTimestampMs = function() return 5000 end
    local a, b = Store.newPanel(1, 1, 0, "box"), Store.newPanel(2, 2, 0, "box")
    Networks.state(a, "power")
    Networks.state(a, "power")
    Networks.state(b, "power")
    eq(asked["bu-p1-power"], 1)
    eq(asked["bu-p2-power"], 1)
    Networks.applyEnabled(b)
    Networks.state(a, "power")
    Networks.state(b, "power")
    eq(asked["bu-p1-power"], 1, "the other box's kept")
    eq(asked["bu-p2-power"], 2, "this box's asked again")
    local idA, idB = "bu-p1-water-c1-b1_1_0-L0-T", "bu-p2-water-c1-b1_1_0-L0-T"
    Networks.waterState(idA)
    Networks.waterState(idB)
    Networks.drawFrom(a, { idA }, 1)
    Networks.waterState(idA)
    Networks.waterState(idB)
    eq(asked[idA], 2, "a draw drops the box's water states")
    eq(asked[idB], 1, "not another box's")
    Networks.waterState("bu-p1-power")
    eq(asked["bu-p1-power"], 1, "nor its power's")
end)

test("a network's state is kept while the API's revision of it is the same, whatever other networks do", function()
    local asked, revision = {}, { ["bu-p1-power"] = 1, ["bu-p2-power"] = 1 }
    TEST.api.table.networks.state = function(id) asked[id] = (asked[id] or 0) + 1; return { load = 1 } end
    TEST.api.table.networks.revision = function(id) return revision[id] end
    local a, b = Store.newPanel(1, 1, 0, "box"), Store.newPanel(2, 2, 0, "box")
    for _ = 1, 3 do
        Networks.state(a, "power")
        Networks.state(b, "power")
    end
    eq(asked["bu-p1-power"], 1, "kept across milliseconds")
    Networks.applyEnabled(b)
    Networks.state(a, "power")
    Networks.state(b, "power")
    eq(asked["bu-p2-power"], 1, "a call of this mod does not drop it: the revision tells")
    revision["bu-p2-power"] = 5
    Networks.state(a, "power")
    Networks.state(b, "power")
    eq(asked["bu-p1-power"], 1, "the other box's kept")
    eq(asked["bu-p2-power"], 2, "this box's asked again as its revision moved")
    revision["bu-p2-power"] = nil
    Networks.state(b, "power")
    Networks.state(b, "power")
    eq(asked["bu-p2-power"], 4, "a network without a revision is asked each millisecond")
end)

test("devices set together bring the water networks to the data once", function()
    local api = TEST.api
    building(api, "A", 100, 100)
    api.buildingsByKey.A.objects = { water = {
        { x = 101, y = 101, z = 0, sprite = "tap1", roomId = "A-0", water = true },
        { x = 102, y = 101, z = 0, sprite = "tap2", roomId = "A-0", water = true },
        { x = 103, y = 101, z = 0, sprite = "tap3", roomId = "A-0", water = true } } }
    local panel = Store.newPanel(102, 102, 0, "box")
    local layouts, layout = 0, BU.Water.layout
    BU.Water.layout = function(...) layouts = layouts + 1; return layout(...) end
    Changes.setAllInside(panel, "water", false)
    eq(layouts, 1, "one layout for the three")
    local excluded = 0
    for _ in pairs(panel.water.excluded) do excluded = excluded + 1 end
    eq(excluded, 3)
end)

test("the units near a place are found by the grid, in the order they were made", function()
    local a = Store.newUnit("sprinkler", 100, 100, 0, "s")
    local b = Store.newUnit("firesprinkler", 102, 99, 0, "f")
    local c = Store.newUnit("firesprinkler", 101, 101, 0, "f")
    Store.newUnit("firesprinkler", 400, 400, 0, "f")
    local list = BU.Nearby.unitsAt(101, 100, 3)
    eq(#list, 3)
    eq(list[1], a)
    eq(list[2], b)
    eq(list[3], c)
    eq(#BU.Nearby.unitsAt(101, 100, 3, "firesprinkler"), 2)
    eq(#BU.Nearby.unitsAt(101, 101, 0, "firesprinkler"), 1, "within the radius only")
end)

test("the tripped boxes are kept as changes are told, not found by a scan each second", function()
    local PanelBlink, PanelLook = BU.PanelBlink, BU.PanelLook
    local near, far, whole = Store.newPanel(10, 10, 0, "box"), Store.newPanel(500, 500, 0, "box"),
        Store.newPanel(12, 10, 0, "box")
    near.tripped, far.tripped = true, true
    local boxes = {}
    for _, panel in ipairs({ near, far, whole }) do
        boxes[panel] = thing(Panels.MODDATA, panel.id, "x", panel.x, panel.y)
        TEST.squares[panel.x .. "," .. panel.y .. ",0"] = { objects = { boxes[panel] } }
    end
    playerAt(10, 10)
    getGameSpeed = function() return 1 end
    local blinked = {}
    PanelLook.blink = function(object) blinked[#blinked + 1] = object end
    local lists, list = 0, Store.list
    Store.list = function() lists = lists + 1; return list() end
    PanelBlink.changed(nil)
    eq(lists, 1, "every box looked at once, for a change of none in particular")
    tick(5)
    eq(lists, 1, "none after")
    truthy(#blinked > 0, "the near tripped box blinks")
    for _, object in ipairs(blinked) do eq(object, boxes[near], "only the near one") end
    near.tripped = false
    PanelBlink.changed(near.id)
    blinked = {}
    tick(5)
    eq(#blinked, 0, "reset: no more")
    near.tripped = true
    PanelBlink.changed(near.id)
    tick(5)
    truthy(#blinked > 0, "tripped again")
    eq(lists, 1)
end)

test("the sprinklers that spray are kept as changes are told, and drop out as their spray ends", function()
    local WaterUnits, SprinklerSpray = BU.WaterUnits, BU.SprinklerSpray
    local frames = WaterUnits.SPRINKLER_SPRITES.spraying
    local spraying = Store.newUnit("sprinkler", 10, 10, 0, frames[1])
    local resting = Store.newUnit("sprinkler", 12, 10, 0, WaterUnits.SPRINKLER_SPRITES.idle)
    TEST.hours = 1
    spraying.sprayedAt = 1
    local sets = {}
    for _, unit in ipairs({ spraying, resting }) do
        local object = thing(BU.Units.MODDATA, unit.id, frames[1], unit.x, unit.y)
        object.setSprite = function(_, sprite) sets[#sets + 1] = unit.id end
        TEST.squares[unit.x .. "," .. unit.y .. ",0"] = { objects = { object } }
    end
    getSprite = function(name) return name end
    playerAt(10, 10)
    getGameSpeed = function() return 1 end
    local lists, list = 0, Store.unitList
    Store.unitList = function(...) lists = lists + 1; return list(...) end
    SprinklerSpray.changed(nil)
    local before = lists
    tick(12)
    eq(lists, before, "the units not listed on a tick")
    truthy(#sets > 0, "the spraying one turns")
    for _, id in ipairs(sets) do eq(id, spraying.id, "not the resting one") end
    TEST.hours = 5
    sets = {}
    tick(12)
    eq(#sets, 0, "its spray over")
end)

test("a thing's light is set as its square loads and when it takes a look; the game's list only when verified", function()
    local Lights, PanelLook = BU.Lights, BU.PanelLook
    local added, contains, kept = 0, 0, true
    local base = getCell
    getCell = function()
        local cell = base()
        cell.addLamppost = function() added = added + 1; return { n = added } end
        cell.removeLamppost = function() end
        cell.getLamppostPositions = function() return { contains = function() contains = contains + 1; return kept end } end
        return cell
    end
    local near, far = Store.newPanel(10, 10, 0, "box"), Store.newPanel(900, 900, 0, "box")
    local lit = PanelLook.SPRITES[1].on[1]
    local boxes = {}
    for _, panel in ipairs({ near, far }) do
        boxes[panel] = thing(Panels.MODDATA, panel.id, lit, panel.x, panel.y)
        TEST.squares[panel.x .. "," .. panel.y .. ",0"] = { objects = { boxes[panel] } }
    end
    Lights.refresh(boxes[near])
    eq(added, 1)
    Lights.refresh(boxes[near])
    eq(contains, 0, "a thing already lit: the game's list not looked at")
    eq(added, 1)
    Lights.refresh(boxes[near], true)
    eq(contains, 1, "verified")
    eq(added, 1)
    kept = false
    Lights.refresh(boxes[near], true)
    eq(added, 2, "the game dropped it: given again")
    -- Each minute: the boxes near a player only.
    playerAt(10, 10)
    kept = true
    Lights.everyMinute()
    eq(added, 2, "the near box checked, not changed")
    truthy(contains >= 3, "and looked at in the list")
    eq(boxes[far] ~= nil, true)
    TEST.fire("EveryOneMinute")
    eq(added, 2, "the far box is not lit by the minute")
end)

test("a square looked at again after a change is not worked out again while nothing about it changed", function()
    local api = TEST.api
    building(api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    local lamp = "109,102,0,lamp"
    Changes.includeOutside(panel, "power", { key = lamp, keys = { lamp }, inside = false,
        entry = { x = 109, y = 102, z = 0, sprite = "lamp" } }, {})
    local sets, onChanged = 0, nil
    api.table.floor = { clear = function() end, set = function() sets = sets + 1 end }
    api.table.squares.watch = function(_, _, fn) onChanged = fn; return 1 end
    api.table.squares.unwatch = function() end
    for x = 100, 112 do
        TEST.squares[x .. ",102,0"] = { objects = {}, floor = "blends_natural_01_0" }
    end
    local FloorLines = BU.FloorLines
    local made = 0
    local madeFloor = FloorLines.madeFloor
    FloorLines.madeFloor = function(...) made = made + 1; return madeFloor(...) end
    tick(1)
    truthy(onChanged, "its squares watched")
    local first = sets
    made = 0
    onChanged(1, 107, 102, 0)
    tick(1)
    local immediate = made
    made = 0
    tick(120)
    truthy(made <= 2, "each look after the first costs one look at the floor, not two")
    -- The floor laid over meanwhile: the next look sees it and the decal changes.
    TEST.squares["107,102,0"].floor = "floors_interior_tilesandwood_01_0"
    sets = 0
    tick(480)
    truthy(sets >= 1, "a change seen by a look after the first")
    eq(immediate, 1, "a change looks at the floor once: the decal is chosen from that look")
    truthy(first >= 1)
end)

test("boxes and units gone from their loaded squares are removed, in one lookup; those on squares not loaded stay", function()
    local api = TEST.api
    local here, gone, away = Store.newPanel(10, 10, 0, "box"), Store.newPanel(20, 10, 0, "box"), Store.newPanel(900, 900, 0, "box")
    local unitHere, unitGone, unitAway = Store.newUnit("sprinkler", 11, 10, 0, "s"), Store.newUnit("sprinkler", 21, 10, 0, "s"),
        Store.newUnit("sprinkler", 901, 900, 0, "s")
    TEST.squares["10,10,0"] = { objects = { thing(Panels.MODDATA, here.id, "box", 10, 10) } }
    TEST.squares["20,10,0"] = { objects = { thing(Panels.MODDATA, "someone else", "box", 20, 10) } }
    TEST.squares["11,10,0"] = { objects = { thing(BU.Units.MODDATA, unitHere.id, "s", 11, 10) } }
    TEST.squares["21,10,0"] = { objects = {} }
    api.calls = {}
    Changes.checkObjects({ here, gone, away }, { unitHere, unitGone, unitAway })
    eq(api.calls["objects.byData"], 2, "one lookup for the boxes, one for the units")
    truthy(Store.get(here.id), "its object there")
    eq(Store.get(gone.id), nil, "its square loaded, its object not on it")
    truthy(Store.get(away.id), "its square not loaded")
    truthy(Store.unit(unitHere.id))
    eq(Store.unit(unitGone.id), nil)
    truthy(Store.unit(unitAway.id))
end)
