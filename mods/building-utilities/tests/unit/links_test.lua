-- The lines of the boxes (BU.Links): hung on a wall, a relay or a device already on a line; what supplies worked out
-- from the shape now (relays by tier, devices by head, the first line's reach); a branch cut and hung on again on
-- another box; relays in a building taking rooms; outdoor boxes.
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Panels, Changes, Store, Links = BU.Panels, BU.Changes, BU.Store, BU.Links

-- A one-room house at (100, 100), 5 by 5, and a second at (200, 100); each its own key.
local function building(api, key, x, y, levels)
    local rooms = {}
    for level = 0, (levels or 1) - 1 do
        rooms[#rooms + 1] = { id = key .. "-" .. level, name = "room", level = level,
            rects = { { x = x, y = y, w = 5, h = 5 } } }
    end
    api.buildingsByKey[key] = {
        building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = (levels or 1) - 1, minX = x, minY = y,
            maxX = x + 4, maxY = y + 4, room = "room", roomId = key .. "-0" },
        rooms = rooms,
    }
    for level = 0, (levels or 1) - 1 do
        for dx = 0, 4 do
            for dy = 0, 4 do api.squares[(x + dx) .. "," .. (y + dy) .. "," .. level] = key end
        end
    end
end

local function lamp(x, y)
    local key = BU.thingKey(x, y, 0, "lamp")
    return { key = key, keys = { key }, inside = false, entry = { x = x, y = y, z = 0, sprite = "lamp" } }
end

local function junction(x, y, z)
    return Store.newUnit("junction", x, y, z or 0, BU.Relays.SPRITES.junction)
end

test("a line hangs on the nearest wall within the tier's range; past it, it waits for a tier", function()
    building(TEST.api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    local place = Links.placeOn(panel, "power", 108, 102, 0)
    eq(place.from, "wall")
    eq(place.length, 4, "to the east wall, (104, 102)")
    eq(place.wall, "104,102,0")
    local none, reason, tier = Links.placeOn(panel, "power", 112, 102, 0)
    eq(none, nil)
    eq(reason, "needsTier")
    eq(tier, 3, "8 squares: tier 3 reaches 10")
    eq(Links.placeOn(panel, "power", 102, 102, 1).length, 0, "on the roof: the room below, no line")
    eq(Links.placeOn(panel, "power", 105, 102, 0).length, 0, "on the outer wall's ring: the room beside")
end)

test("of walls as near in steps, the straightest; a line stops at the wall's face", function()
    -- Two rooms, the southern one listed first: from the west, both are 3 steps away.
    local api = TEST.api
    api.buildingsByKey.B = {
        building = { key = "B", playerBuilt = false, minLevel = 0, maxLevel = 0, minX = 100, minY = 100, maxX = 104,
            maxY = 109, room = "room", roomId = "B-1" },
        rooms = { { id = "B-2", name = "room", level = 0, rects = { { x = 100, y = 105, w = 5, h = 5 } } },
            { id = "B-1", name = "room", level = 0, rects = { { x = 100, y = 100, w = 5, h = 5 } } } },
    }
    for dx = 0, 4 do
        for dy = 0, 9 do api.squares[(100 + dx) .. "," .. (100 + dy) .. ",0"] = "B" end
    end
    local panel = Store.newPanel(102, 102, 0, "box")
    local place = Links.placeOn(panel, "power", 97, 103, 0)
    eq(place.length, 3)
    eq(place.wall, "100,103,0", "straight east, not down to the southern room")
    local x, y = Links.endOf({ x = 97, y = 103, wall = place.wall })
    eq(x, 99.5, "at the wall's west face")
    eq(y, 103)
end)

test("a line hangs from its room's wall, or from the relay above it however far down the chain", function()
    building(TEST.api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 2
    local onWall = lamp(107, 102)
    Changes.includeOutside(panel, "power", onWall, {})
    local below = lamp(110, 102)
    Changes.includeOutside(panel, "power", below, {}, { via = "t:" .. onWall.key, length = 3 })
    eq(Links.hangsOn(panel, "t:" .. onWall.key), "A-0")
    eq(Links.hangsOn(panel, "t:" .. below.key), "A-0", "down the chain: the head's wall")
    local a = junction(104, 108)
    Changes.connectUnit(a, panel, {})
    local first = lamp(104, 113)
    Changes.includeOutside(panel, "power", first, {}, { via = "u:" .. a.id, length = 5 })
    local second = lamp(104, 116)
    Changes.includeOutside(panel, "power", second, {}, { via = "t:" .. first.key, length = 3 })
    eq(Links.hangsOn(panel, "t:" .. second.key), "u:" .. a.id, "below a relay: the relay")
    eq(Links.hangsOn(panel, "u:" .. a.id), "A-0", "the relay itself on the wall")
end)

test("relays by tier, devices by head, and what comes back with an upgrade", function()
    building(TEST.api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 2
    eq(BU.relayLimit(2), 2)
    local junctions = {}
    for i = 1, 3 do
        junctions[i] = junction(104 + i * 6, 102)
        -- The third as laid by a box of a higher tier: hung on the second all the same.
        local place = i == 3 and { via = "u:" .. junctions[2].id, length = 6 } or nil
        Changes.connectUnit(junctions[i], panel, {}, place)
    end
    eq(Links.get("u:" .. junctions[2].id).via, "u:" .. junctions[1].id, "the second on the first, nearer than the wall")
    local state = Links.state(panel)
    eq(state.live["u:" .. junctions[1].id], true)
    eq(state.live["u:" .. junctions[2].id], true)
    eq(state.reason["u:" .. junctions[3].id], "relays", "the third past tier 2's two")
    eq(select(2, Links.placeOn(panel, "power", 125, 102, 0, true)), "relays", "no fourth offered")
    -- Lamps in a row from the second junction: its head, then eight more; the tenth is past.
    local first = lamp(117, 104)
    Changes.includeOutside(panel, "power", first, {})
    eq(Links.get("t:" .. first.key).via, "u:" .. junctions[2].id, "the first lamp on the junction")
    local last
    for i = 1, 9 do
        last = lamp(117 + i * 2, 104)
        Changes.includeOutside(panel, "power", last, {}, { via = "t:" .. lamp(117 + (i - 1) * 2, 104).key, length = 2 })
    end
    state = Links.state(panel)
    eq(state.chained["t:" .. first.key], 9)
    eq(state.reason["t:" .. last.key], "chain", "the ninth below the head is past eight")
    eq(BU.Networks.rule(panel, "power", last.key), "reset", "past: not supplied")
    Changes.upgrade(panel)
    eq(Links.live(panel, "u:" .. junctions[3].id), true, "tier 3 has four relays")
end)

test("a relay taken up cuts what hangs on it; hung on again on another box, the branch is that box's", function()
    building(TEST.api, "A", 100, 100)
    building(TEST.api, "B", 100, 115)
    local mine = Store.newPanel(102, 102, 0, "box")
    mine.tier = 2
    local other = Store.newPanel(102, 117, 0, "box")
    other.tier = 2
    local a = junction(110, 102)
    Changes.connectUnit(a, mine, { ["Base.ElectricWire"] = 2 })
    local b = junction(110, 113)
    Changes.connectUnit(b, mine, {}, { via = "u:" .. a.id, length = 11 })
    Changes.connectProducer(mine, "power", 110, 120, 0, {}, { via = "u:" .. b.id, length = 7 })
    eq(#mine.power.producers, 1)
    eq(Changes.removeUnit(a)["Base.ElectricWire"], 2, "its own line's back")
    eq(Links.reason(mine, "u:" .. b.id), "cut")
    eq(Links.reason(mine, "p:110,120,0"), "cut", "what hangs below is cut too")
    eq(Links.cutHead("p:110,120,0").ref, "u:" .. b.id, "the branch's first line")
    local offers = Links.offers("power", 110, 113, 0, true, { ["u:" .. b.id] = true, ["p:110,120,0"] = true })
    eq(offers[1].panel, other, "the other box's wall within reach first")
    eq(offers[2].reason, "needsTier", "the first box's wall is past its tier")
    Changes.rehang("u:" .. b.id, other, Links.placeOn(other, "power", 110, 113, 0, true), {})
    eq(b.panel, other.id)
    eq(#mine.power.producers, 0, "the generator left the first box")
    eq(other.power.producers[1].x, 110)
    eq(Links.live(other, "p:110,120,0"), true)
end)

test("a box taken down leaves its lines cut; its tier goes with its item", function()
    building(TEST.api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 3
    local p = junction(110, 102)
    Changes.connectUnit(p, panel, {})
    eq(Changes.keepPanel(panel).tier, 3)
    Changes.remove(panel)
    local line = Links.get("u:" .. p.id)
    eq(line.panel, nil)
    eq(p.panel, nil)
    eq(Links.cutHead("u:" .. p.id), line, "its own line is the one to hang on again")
end)

test("a relay in a building takes its rooms; no other box goes there", function()
    building(TEST.api, "A", 100, 100)
    building(TEST.api, "T", 106, 100, 10)
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 4
    local relay = junction(107, 102, 2)
    Changes.connectUnit(relay, panel, {})
    eq(Links.live(panel, "u:" .. relay.id), true)
    local ids = Panels.zoneIds(panel)
    eq(ids["A-0"], true, "its own room kept")
    eq(ids["T-2"], true, "a large building: its own floor's room")
    eq(ids["T-1"], nil)
    eq(Panels.reaches(panel, "T", 0), true, "two floors below can be taken")
    eq(Panels.reaches(panel, "T", 4), true, "two above")
    eq(Panels.reaches(panel, "T", 5), false)
    local keys = { "100,100,0", "106,100,2", "106,100,4", "106,100,5" }
    eq(Changes.setZone(panel, keys), true)
    ids = Panels.zoneIds(panel)
    eq(ids["T-4"], true, "taken on the plan")
    eq(ids["T-5"], nil, "past the relay's floors: left out")
    TEST.api.buildingsByKey.T.building.roomId = "T-4" -- the fake tells one room for every square
    local square = { getX = function() return 107 end, getY = function() return 102 end, getZ = function() return 4 end }
    eq(select(2, Panels.canInstall(square)), "roomTaken", "a room its relay took")
    Changes.removeUnit(relay)
    eq(Panels.zoneIds(panel)["T-2"], nil, "the rooms go with it")
end)

test("an outdoor box: its square is its wall", function()
    local panel = Changes.install and Store.newPanel(300, 300, 0, "box")
    panel.outdoor = true
    local place = Links.placeOn(panel, "water", 304, 300, 0)
    eq(place.from, "wall")
    eq(place.length, 4)
    eq(place.wall, "300,300,0")
    local square = { getX = function() return 300 end, getY = function() return 310 end, getZ = function() return 0 end }
    eq(Panels.canInstall(square), true, "outside any building: an outdoor box")
end)

test("each line runs to what it hangs on; the branches that supply nothing are listed by their first line", function()
    building(TEST.api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 2
    local a = junction(110, 102)
    Changes.connectUnit(a, panel, {})
    local first = lamp(116, 102)
    Changes.includeOutside(panel, "power", first, {}, { via = "u:" .. a.id, length = 6 })
    local line = Links.get("u:" .. a.id)
    eq(select(1, Links.endOf(line)), 104.5, "the junction to its wall square's east face")
    eq(select(1, Links.endOf(Links.get("t:" .. first.key))), 110, "the lamp to the junction")
    eq(#Links.deadHeads(panel), 0)
    eq(Links.reasonText(panel, "u:" .. a.id), nil, "it supplies")
    Changes.removeUnit(a)
    local heads = Links.deadHeads(panel)
    eq(#heads, 1, "only the branch's first line")
    eq(heads[1].ref, "t:" .. first.key)
    eq(Links.endOf(heads[1]), nil, "what it hung on is gone")
    eq(Links.reasonText(panel, "t:" .. first.key), "IGUI_BU_LineCut_here")
end)

test("a line lies on the ground one axis then the other, to the square outside its wall and into it", function()
    building(TEST.api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 3
    local a = junction(110, 106)
    Changes.connectUnit(a, panel, {})
    local route, z, intoX, intoY = Links.route(Links.get("u:" .. a.id))
    eq(z, 0)
    eq(route[1].x .. "," .. route[1].y, "110,106", "from its own square")
    local last = route[#route]
    eq(last.x .. "," .. last.y, "105,104", "the square east of the nearest wall square (104, 104): further out")
    eq(intoX, -1, "into the wall to the west")
    eq(intoY, 0)
    eq(#route, 8, "two along, five across, and its own square")
    eq(route[2].x .. "," .. route[2].y, "110,105", "along first: then straight into the wall")
    -- A lamp hung on it: to the junction's square, nothing into a wall.
    local hung = lamp(110, 110)
    Changes.includeOutside(panel, "power", hung, {}, { via = "u:" .. a.id, length = 4 })
    route, z, intoX = Links.route(Links.get("t:" .. hung.key))
    eq(#route, 5)
    eq(route[5].x .. "," .. route[5].y, "110,106")
    eq(intoX, nil)
    -- A thing in a room of the zone lies nowhere.
    eq(Links.route({ x = 102, y = 103, z = 0, length = 0, wall = "102,103,0" }), nil)
    -- Beside the wall: its own square, into the wall.
    route, z, intoX, intoY = Links.route({ x = 105, y = 102, z = 0, length = 0, wall = "104,102,0" })
    eq(#route, 1)
    eq(intoX, -1)
    -- Far out past the wall's end: the short leg first, the long one straight into the wall, one turn.
    route, z, intoX, intoY = Links.route({ x = 106, y = 112, z = 0, length = 10, wall = "104,104,0" })
    eq(intoY, -1, "into the wall to the north, the side it is further out from")
    eq(route[2].x .. "," .. route[2].y, "105,112", "across first, the short leg")
    eq(route[#route].x .. "," .. route[#route].y, "104,105")
    eq(route[#route - 1].x .. "," .. route[#route - 1].y, "104,106", "straight on into the wall")
end)

test("a line goes round water, a square with no floor and stairs, and is laid again when one comes over it", function()
    building(TEST.api, "A", 100, 100)
    local panel = Store.newPanel(102, 102, 0, "box")
    -- A pond across the straight way out from (110, 104) to the wall's square outside (105, 104).
    for y = 102, 106 do TEST.squares["107," .. y .. ",0"] = { flags = { water = true } } end
    TEST.squares["108,101,0"] = { noFloor = true }
    TEST.squares["106,101,0"] = { stairs = true }
    local line = { ref = "t:pond", x = 110, y = 104, z = 0, length = 6, wall = "104,104,0", utility = "water" }
    local route = Links.route(line)
    local wet = 0
    for _, square in ipairs(route) do
        if square.x == 107 and square.y >= 102 and square.y <= 106 or square.x == 108 and square.y == 101
                or square.x == 106 and square.y == 101 then
            wet = wet + 1
        end
    end
    eq(wet, 0, "round the pond, the hole and the stairs")
    eq(route[#route].x .. "," .. route[#route].y, "105,104", "and still into the wall")
    eq(Links.groundOpen(107, 104, 0), false)
    eq(Links.groundOpen(109, 104, 0), true)
    -- Laid as it was found, and kept so.
    line.path = Links.pathFor(line)
    eq(line.path[1] .. "," .. line.path[2], "110,104")
    TEST.squares = {}
    eq(#Links.route(line), #route, "the way kept, though the pond is gone")
end)

test("of the two ways round, a line lies through fewer squares of buildings", function()
    building(TEST.api, "A", 100, 100)
    building(TEST.api, "B", 108, 108)
    local panel = Store.newPanel(102, 102, 0, "box")
    -- From (112, 114): across first would run along y = 114 through B (x 108-112); along first runs up x = 112
    -- through B too; from (114, 112) across first crosses B, along first (x = 114) passes beside it.
    local route = Links.route({ x = 114, y = 112, z = 0, length = 10, wall = "104,104,0" })
    local through = 0
    for _, square in ipairs(route) do
        if square.x >= 108 and square.x <= 112 and square.y >= 108 and square.y <= 112 then through = through + 1 end
    end
    eq(through, 0, "round B, not through it")
    eq(route[2].x .. "," .. route[2].y, "114,111", "along first, though across is longer")
end)
