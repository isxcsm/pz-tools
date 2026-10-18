-- The story's game adapter (Story/Game) where it reads plain item tables: whether an item is a mission's piece.
require "OperationAcorn/Core"
require "OperationAcorn/Story/Game"
local OA = OperationAcorn
local Game = OA.StoryGame

function instanceof(object, class)
    return object ~= nil and object.classes ~= nil and object.classes[class] == true
end

-- The API's item search (items.find) over the fakes below: the first item of a container or a bag whose OA_Mission is the
-- id or starts with it and "#" (dataPrefix), through the container's recursive search with a predicate.
local function itemsApi()
    PZExtAPI = { version = OA.API_VERSION, client = function() return {} end, items = { find = function(source, match)
        local id = match.dataPrefix.OA_Mission
        local inv = source.getInventory and source:getInventory() or source
        local found = inv:getFirstEvalArgRecurse(function(it)
            local mine = it:getModData().OA_Mission
            return mine ~= nil and (mine == id or string.sub(mine, 1, #id + 1) == id .. "#")
        end)
        return { found }, {}
    end } }
end

-- A fake item: modData, and for a bag its inventory's recursive search with a predicate.
local function item(data, contents)
    local it = { data = data or {}, classes = {} }
    it.getModData = function() return it.data end
    if contents then
        it.classes.InventoryContainer = true
        it.getInventory = function()
            local inv = {}
            function inv:getFirstEvalArgRecurse(predicate, arg)
                local function walk(list)
                    for _, inner in ipairs(list) do
                        if predicate(inner, arg) then return inner end
                        if inner.contents then
                            local found = walk(inner.contents)
                            if found then return found end
                        end
                    end
                    return nil
                end
                return walk(contents)
            end
            return inv
        end
        it.contents = contents
    end
    return it
end

test("an item holds a mission's piece when it is one, or has one inside", function()
    itemsApi()
    eq(Game.holds(item({ OA_Mission = "M1-1" }), "M1-1"), true)
    eq(Game.holds(item({ OA_Mission = "M1-1#A" }), "M1-1"), true, "a keyed piece")
    eq(Game.holds(item({ OA_Mission = "M1-10" }), "M1-1"), false, "another mission's id that starts the same")
    eq(Game.holds(item({}), "M1-1"), false)
    local deep = item({}, { item({}, { item({ OA_Mission = "M1-1" }) }) })
    eq(Game.holds(deep, "M1-1"), true, "inside bags")
    eq(Game.holds(item({}, { item({ OA_Mission = "M2-1" }) }), "M1-1"), false)
    PZExtAPI = nil
end)

-- A mission item put into the hands is marked as newItem marks one: the mission, the record it was issued to (the one given,
-- else the character's own), and the keep mark. Made from the game's item factory, which the test stands in for.
test("an item given to a character carries the record it was issued to", function()
    local made = {}
    instanceItem = function(fullType)
        local it = item({})
        it.type = fullType
        made[#made + 1] = it
        return it
    end
    isServer = function() return false end
    local added = {}
    local inv = { AddItem = function(self, it) added[#added + 1] = it end }
    local character = { getInventory = function() return inv end, getModData = function() return { OA_Id = "p1" } end }
    local given = Game.giveMissionItem(character, "OperationAcorn.SoilSample", "M1-1", { OA_Stake = 3 }, { id = "p1" })
    eq(given.data.OA_Mission, "M1-1")
    eq(given.data.OA_Owner, "p1", "the record's id")
    eq(given.data.OA_Stake, 3, "the extra marks")
    eq(given.data.PZExtKeep, true)
    eq(added[1], given, "in the inventory")
    -- the record given wins over the character's own id; without one the character's is the record's
    eq(Game.giveMissionItem(character, "OperationAcorn.SoilSample", "M1-2", nil, { id = "p9" }).data.OA_Owner, "p9")
    eq(Game.giveMissionItem(character, "OperationAcorn.SoilSample", "M1-3").data.OA_Owner, "p1", "a pickup the harvest or a test gives")
    -- an item the factory cannot make is nothing
    instanceItem = function() return nil end
    eq(Game.giveMissionItem(character, "No.Such", "M1-4", nil, { id = "p1" }), nil)
    instanceItem, isServer = nil, nil
end)

-- A character whose inventory counts its searches. The items know their container, which is the inventory.
local function carrier(items)
    local searches = 0
    local weight = 1
    local inv = {}
    function inv:getFirstEvalArgRecurse(predicate, arg)
        searches = searches + 1
        for _, it in ipairs(items) do
            if predicate(it, arg) then return it end
        end
        return nil
    end
    function inv:getItems() return { size = function() return #items end } end
    function inv:getContentsWeight() return weight end
    for _, it in ipairs(items) do it.getContainer = function() return inv end end
    local p = { getInventory = function() return inv end, getModData = function() return { OA_Id = "p1" } end }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return p end
    return p, function() return searches end, function(w) weight = w end, inv
end

test("the mission's item is searched for once, then kept, and a miss is not searched again until the inventory changes", function()
    itemsApi()
    local cooler = item({ OA_Mission = "M1-1" })
    local items = { item({}), cooler }
    local p, searches, setWeight = carrier(items)
    local record = { id = "p1" }
    eq(Game.findItem(record, "M1-1"), cooler)
    eq(searches(), 1)
    eq(Game.findItem(record, "M1-1"), cooler)
    eq(Game.findItem(record, "M1-1"), cooler)
    eq(searches(), 1, "the item kept is checked in a few steps")
    -- it leaves the inventory: searched, not found
    cooler.getContainer = function() return nil end
    items[2] = item({})
    eq(Game.findItem(record, "M1-1"), nil)
    eq(searches(), 2)
    eq(Game.findItem(record, "M1-1"), nil)
    eq(Game.findItem(record, "M1-1"), nil)
    eq(searches(), 2, "a miss under the same signature: not searched again")
    -- something changed in the inventory: searched again
    setWeight(2)
    eq(Game.findItem(record, "M1-1"), nil)
    eq(searches(), 3)
    PZExtAPI = nil
end)

-- The API's map lists, as a fake: what a call was asked is kept in `asked`.
local function fakeApi(fields)
    local asked = {}
    PZExtAPI = { version = OA.API_VERSION, client = function() return {} end }
    for area, calls in pairs(fields) do
        PZExtAPI[area] = {}
        for name, fn in pairs(calls) do
            PZExtAPI[area][name] = function(...)
                asked[#asked + 1] = { area = area, name = name, ... }
                return fn(...)
            end
        end
    end
    return asked
end

local function building(minX, minY, rooms, more)
    local b = { x = minX + 2, y = minY + 3, distance = 50, area = 40, minX = minX, minY = minY, maxX = minX + 4,
        maxY = minY + 6, minLevel = 0, maxLevel = 1, rooms = rooms }
    for k, v in pairs(more or {}) do b[k] = v end
    return b
end

test("a mission's buildings and a story site's come from the API's list, the site's only the plain ones not skipped", function()
    local asked = fakeApi({ buildings = { list = function()
        return { building(10, 10, { "bedroom", "kitchen", "livingroom" }), building(30, 30, { "restaurant" }),
            building(50, 50, { "office", "office" }, { minLevel = -1, maxLevel = -1 }) }
    end } })
    local places = Game.buildingsIn(0, 0, 40, 80)
    eq(#places, 3)
    eq(places[1].x, 12); eq(places[1].y, 13); eq(places[1].x1, 10); eq(places[1].x2, 14); eq(places[1].y2, 16)
    eq(places[1].z, 0); eq(places[1].z2, 1)
    eq(places[3].z, -1, "a building wholly below ground is on its level")
    eq(asked[1][5].minArea, 30)
    eq(asked[1][5].basement, false)
    eq(asked[1][5].roomNames, nil)
    local sites = Game.sitesInBand(0, 0, 40, 80, { ["50,50"] = true })
    eq(#sites, 1, "the restaurant is not plain, the office is skipped")
    local s = sites[1]
    eq(s.key, "10,10"); eq(s.dist, 50); eq(s.area, 40); eq(s.rooms, 3); eq(s.home, true); eq(s.stores, false)
    eq(s.x, 12); eq(s.x2, 14)
    eq(asked[2][5].playerBuilt, false); eq(asked[2][5].visited, false); eq(asked[2][5].stash, false)
    eq(asked[2][5].roomNames, true)
    PZExtAPI = nil
end)

test("open ground in a band is a field first, else the first in woods", function()
    local points = { { x = 5, y = 6, zones = { "Vegitation" } }, { x = 7, y = 8, zones = { "Farm" } },
        { x = 9, y = 10, zones = {} } }
    local asked = fakeApi({ zones = { points = function() return points end } })
    local x, y = Game.groundInBand(0, 0, 100, 200)
    eq(x, 7); eq(y, 8)
    local options = asked[1][5]
    eq(options.road.type, "Nav"); eq(options.road.none, Game.ROAD_NEAR); eq(options.road.some, Game.ROAD_FAR)
    truthy(options["not"] == Game.CLOSED_ZONES)
    points = { { x = 5, y = 6, zones = { "Forest" } }, { x = 9, y = 10, zones = { "Vegitation" } } }
    x, y = Game.groundInBand(0, 0, 100, 200)
    eq(x, 5); eq(y, 6)
    points = {}
    eq(Game.groundInBand(0, 0, 100, 200), nil)
    PZExtAPI = nil
end)

test("a camp that does not fit where it is moves to the nearest ground that does, inside the mission's circle", function()
    local square = function(x, y) return { getX = function() return x end, getY = function() return y end } end
    getCell = function() return { getGridSquare = function(_, x, y) return square(x, y) end } end
    local fits = {}
    local asked = fakeApi({ squares = { fit = function(anchors, parts)
        fits[#fits + 1] = { anchors = anchors, parts = parts }
        if #fits == 2 then return square(107, 100) end
    end } })
    local record = OA.Store.ensure("p1", "P")
    local m = { id = "M7", site = { x = 100, y = 100, z = 0, ground = true, key = "g:100,100" }, area = { x = 100, y = 100, r = 60 },
        items = {} }
    eq(Game.settleGround(record, m), true)
    eq(#fits, 2, "first where it is, then round it")
    local here, ring = fits[1], fits[2]
    eq(here.anchors.x1, 100); eq(here.anchors.x2, 100)
    eq(here.parts[1].filter.free, true); eq(here.parts[1].filter.building, "none"); eq(here.parts[1].filter.waterFlag, false)
    eq(here.parts[2].box[1], -Game.CAMP_REACH); eq(here.parts[2].box[5], 2)
    truthy(here.parts[2].filter == Game.GROUND)
    eq(ring.anchors.from, 2); eq(ring.anchors.to, Game.SETTLE_REACH); eq(ring.anchors.step, 2)
    near(ring.parts[1].filter.distance.max, 51, 1e-9)
    eq(m.site.x, 107); eq(m.site.key, "g:107,100")
    getCell, PZExtAPI = nil, nil
end)
