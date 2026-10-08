-- Floors in a tall building, at the tower panel (ModData BUTOWER: a tier 4 box on the ground floor of a building of
-- many floors): how many floors a tier's zone reaches (BU.floorReach, 0 for no limit); a zone saved whole kept to them
-- as the world starts (Changes.fitZones, with its notice); the whole building asked for and a list with far rooms
-- both kept to them; the rooms beyond "far" on the plan. Then a sub-panel put down on the 13th floor (its own floor
-- first, its zone kept to what tier 1 reaches), linked with a line a floor's tiles longer each floor (Panels.linkWire),
-- and a generator and a solar panel two floors up wired through it: the sub-panel offered first with the shorter
-- line, the cost one wire, the producer and the unit its main panel's through it, and the main panel's line as long
-- as both together. Its water by height: each floor from the main panel's at that height or the nearest above, none
-- above every tank. The link taken away takes the lines wired through it, given back; a sub-panel taken down too.
-- "[bufloors]" lines, each "ok" or "BAD", ending with "done". What it put down is taken away, the sandbox values put
-- back, and the tower panel's zone left as the floors it reaches.
local BU = BuildingUtilities
local Store, Panels, Changes, Costs, Actions, Energy, Networks, Solar, Water = BU.Store, BU.Panels, BU.Changes,
    BU.Costs, BU.Actions, BU.Energy, BU.Networks, BU.Solar, BU.Water
local function say(...) print("[bufloors]", ...) end
local function check(what, got, want) say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want)) end

local main = Store.get(ModData.getOrCreate("BUTOWER").panel)
if not main then say("BAD no tower panel"); return end
local building = Panels.building(main)
if not building then say("BAD the tower panel's building is not known"); return end
local page = SandboxVars.BuildingUtilities
local was = { FloorReach = page.FloorReach, TilesPerFloor = page.TilesPerFloor, TilesPerPiece = page.TilesPerPiece,
    tier = main.tier }
page.FloorReach, page.TilesPerFloor, page.TilesPerPiece = 2, 3, 5
main.tier = 4
say("building floors", building.minLevel, building.maxLevel, "box floor", main.z)

local function lastLog(panel)
    local log = panel.log or {}
    return log[#log] and log[#log].key
end
local function zoneLevels(panel)
    local low, high, count = nil, nil, 0
    for _, room in ipairs(Panels.rooms(building)) do
        if panel.rooms and panel.rooms[room.id] then
            count = count + 1
            low, high = math.min(low or room.level, room.level), math.max(high or room.level, room.level)
        end
    end
    return low, high, count
end
local function roomsBetween(low, high)
    local ids, count = {}, 0
    for _, room in ipairs(Panels.rooms(building)) do
        if room.level >= low and room.level <= high then ids[#ids + 1] = room.id; count = count + 1 end
    end
    return ids, count
end
local function wires(cost) return cost and Costs.count(cost, Costs.WIRE) end

-- How far each tier reaches.
for tier, want in ipairs({ 2, 3, 4, 5 }) do check("reach at tier " .. tier, BU.floorReach(tier), want) end
page.FloorReach = 0
check("no limit at 0", BU.floorReach(4), nil)
page.FloorReach = 2
check("ranges text tells the floors", Panels.rangesText(4):find("5", 1, true) ~= nil, true)

-- A zone saved whole (before the limit) kept to the floors it reaches.
local before = main.rooms
main.rooms = nil
Networks.setZone(main, before)
Changes.fitZones()
local _, inReach = roomsBetween(main.z - 5, main.z + 5)
local low, high, count = zoneLevels(main)
check("whole zone kept: a list", main.rooms ~= nil, true)
check("whole zone kept: lowest floor", low, math.max(building.minLevel, main.z - 5))
check("whole zone kept: highest floor", high, main.z + 5)
check("whole zone kept: rooms", count, inReach)
check("whole zone kept: notice", lastLog(main), "IGUI_BU_Notice_ZoneReach")
check("cannot take the whole building", Panels.canTakeWhole(main, building), false)

-- The whole building asked for, and a list with far rooms.
Changes.setZone(main, roomsBetween(main.z, main.z)) -- first a smaller one, so that the next changes it
Changes.setZone(main, nil)
low, high, count = zoneLevels(main)
check("whole asked: rooms in reach", count, inReach)
Changes.setZone(main, roomsBetween(building.minLevel, building.maxLevel))
low, high, count = zoneLevels(main)
check("all rooms asked: highest floor", high, main.z + 5)
check("all rooms asked: rooms in reach", count, inReach)
local farRoom
for _, room in ipairs(Panels.rooms(building)) do
    if room.level == main.z + 8 then farRoom = room break end
end
local states = Panels.zoneStates(main, building, Panels.rooms(building))
check("a room 8 floors up is far", farRoom and states[farRoom.id].state, "far")
check("the floor 8 up is not reached", Panels.reachesLevel(main, main.z + 8), false)

-- A sub-panel on the 13th floor.
local subLevel = main.z + 12
Changes.setZone(main, roomsBetween(main.z, main.z + 5))
local function free(q) return q:getRoom() ~= nil and q:isFree(false) and q:getObjects():size() == 1 end
local subSquare
for _, room in ipairs(Panels.rooms(building)) do
    if room.level == subLevel and not subSquare then
        local rect = room.rects[1]
        for x = rect.x, rect.x + rect.w - 1 do
            for y = rect.y, rect.y + rect.h - 1 do
                local q = getCell():getGridSquare(x, y, subLevel)
                if not subSquare and q and free(q) and Panels.canInstall(q) then subSquare = q end
            end
        end
    end
end
if not subSquare then say("BAD no square for a sub-panel on floor", subLevel); return end
local sub = Changes.install(subSquare, BU.PANEL_SPRITES[1])
low, high = zoneLevels(sub)
check("sub-panel takes its floor: lowest", low, subLevel)
check("sub-panel takes its floor: highest", high, subLevel)
check("sub-panel notice", lastLog(sub), "IGUI_BU_Notice_Zoned")
Changes.setZone(sub, roomsBetween(subLevel - 4, subLevel + 4))
low, high = zoneLevels(sub)
check("tier 1 sub-panel reaches 2 down", low, subLevel - 2)
check("tier 1 sub-panel reaches 2 up", high, subLevel + 2)

-- Its link: 12 floors of 3 tiles.
check("can link", Panels.canLink(sub, main), true)
check("link line length", Panels.linkWire(sub, main), 36)
check("link cost", wires(Actions.lineCost("link", sub, nil, 0, 0, 0, main.id)), 8)
Changes.link(sub, main, { [Costs.WIRE] = 8, [Costs.PIPE] = 8 })
check("sub-panel's line pieces", Panels.powerLine(sub, nil), 8)

-- A generator two floors up from the sub-panel, wired through it.
local genLevel = subLevel + 1
local genSquare
for _, room in ipairs(Panels.rooms(building)) do
    if room.level == genLevel and not genSquare then
        local rect = room.rects[1]
        for x = rect.x, rect.x + rect.w - 1 do
            for y = rect.y, rect.y + rect.h - 1 do
                local q = getCell():getGridSquare(x, y, genLevel)
                if not genSquare and q and free(q) then genSquare = q end
            end
        end
    end
end
if not genSquare then say("BAD no square for a generator on floor", genLevel); Changes.remove(sub); return end
local generator = IsoGenerator.new(instanceItem("Base.Generator"), getCell(), genSquare)
local gx, gy, gz = genSquare:getX(), genSquare:getY(), genSquare:getZ()
local candidates = Panels.producerCandidates(gx, gy, gz)
check("first offered: the sub-panel", candidates[1] and candidates[1].panel == sub, true)
check("its line", candidates[1] and candidates[1].wire, 3)
local mainCandidate
for _, candidate in ipairs(candidates) do
    if candidate.panel == main then mainCandidate = candidate end
end
check("the main panel's line", mainCandidate and mainCandidate.wire, 39)
check("cost through the sub-panel", wires(Actions.lineCost("producer", sub, "power", gx, gy, gz)), 1)
check("cost straight to the main panel", wires(Actions.lineCost("producer", main, "power", gx, gy, gz)), 8)
local producersBefore = #main.power.producers
Changes.connectProducer(sub, "power", gx, gy, gz, { [Costs.WIRE] = 1 })
local at = main.power.producers[#main.power.producers]
check("the main panel's producer", #main.power.producers, producersBefore + 1)
check("through the sub-panel", at and at.via, sub.id)
check("owner", Store.producerOwner(gx, gy, gz), main)
check("the sub-panel lists none", #sub.power.producers, 0)
check("main panel's line through it", Panels.routeWire(main, gx, gy, gz, sub.id), 39)
check("main panel's line pieces", Panels.powerLine(main, { producer = { x = gx, y = gy, z = gz } }), 8)

-- A solar panel on the floor above, wired through it.
local solarSquare
for dx = -3, 3 do
    for dy = -3, 3 do
        local q = getCell():getGridSquare(gx + dx, gy + dy, gz + 1)
        if not solarSquare and q and free(q) then solarSquare = q end
    end
end
local solar = solarSquare and Changes.installUnit("solar", solarSquare, Solar.SPRITES.W)
if solar then
    Changes.connectUnit(solar, sub, { [Costs.WIRE] = 1 })
    check("solar panel: the main panel's", solar.panel, main.id)
    check("solar panel: through the sub-panel", solar.via, sub.id)
    check("solar panel: source line", Energy.lineSteps(main), 6 + 36)
else
    say("BAD no square for a solar panel on floor", gz + 1)
end

-- Its water by height, with a tank of the main panel's on the sub-panel's floor (in the data only, for the layout).
local tanks = main.water.producers
main.water.producers = { { x = main.x, y = main.y, z = subLevel } }
local parents = {}
for _, network in ipairs(Water.layout(sub)) do
    if network.group == Water.FIRST then parents[network.level] = network.parent or "none" end
end
local atTank = Water.networkId(main, Water.FIRST, subLevel)
check("water: a floor down hangs at the tank's height", parents[subLevel - 1], atTank)
check("water: the tank's floor", parents[subLevel], atTank)
check("water: a floor up has none", parents[subLevel + 1], "none")
local dryLow, dryHigh = Water.dryFloors(sub)
check("water: dry from", dryLow, subLevel + 1)
check("water: dry to", dryHigh, subLevel + 2)
main.water.producers = {}
dryLow, dryHigh = Water.dryFloors(sub)
check("water: no tank above the main panel's floors, all dry from", dryLow, subLevel - 2)
main.water.producers = tanks
check("water: the main panel's own floors not dry", Water.dryFloors(main), nil)

-- What the sub-panel's lines took, then its link taken away with them.
local paid = Changes.paidFor(sub)
check("paid for the sub-panel's lines", paid[Costs.WIRE], 8 + 1 + (solar and 1 or 0))
local back = Changes.unlink(sub)
check("unlinked: given back", back[Costs.WIRE], 8 + 1 + (solar and 1 or 0))
check("unlinked: the generator no longer the main panel's", Store.producerOwner(gx, gy, gz), nil)
check("unlinked: producers", #main.power.producers, producersBefore)
if solar then check("unlinked: solar panel wired to nothing", solar.panel, nil) end
check("unlinked: notice", lastLog(sub), "IGUI_BU_Notice_RoutesCut")

-- Linked again with the generator through it, then taken down.
Changes.link(sub, main, { [Costs.WIRE] = 8 })
Changes.connectProducer(sub, "power", gx, gy, gz, { [Costs.WIRE] = 1 })
check("again: through the sub-panel", Store.producerOwner(gx, gy, gz), main)
Changes.remove(sub)
check("taken down: the generator no longer the main panel's", Store.producerOwner(gx, gy, gz), nil)
check("taken down: producers", #main.power.producers, producersBefore)

-- Put back.
if solar then Changes.removeUnit(solar) end
generator:remove()
page.FloorReach, page.TilesPerFloor, page.TilesPerPiece = was.FloorReach, was.TilesPerFloor, was.TilesPerPiece
main.tier = was.tier
Changes.setZone(main, nil)
say("done")
