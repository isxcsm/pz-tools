-- Floors in a tall building, at the tower panel (ModData BUTOWER: a tier 4 box on the ground floor of a building of
-- many floors): how many floors a tier's zone reaches (BU.floorReach, 0 for no limit); a zone saved whole kept to them
-- as the world starts (Changes.fitZones, with its notice); the whole building asked for and a list with far rooms
-- both kept to them; the rooms beyond "far" on the plan. Last, "water only from above" changed in play and back,
-- taken once each (Changes.applyShape).
-- "[bufloors]" lines, each "ok" or "BAD", ending with "done". What it put down is taken away, the sandbox values put
-- back, and the tower panel's zone left as the floors it reaches.
local BU = BuildingUtilities
local Store, Panels, Changes, Networks, Water = BU.Store, BU.Panels, BU.Changes, BU.Networks, BU.Water
local function say(...) print("[bufloors]", ...) end
local function check(what, got, want) say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want)) end

local main = Store.get(ModData.getOrCreate("BUTOWER").panel)
if not main then say("BAD no tower panel"); return end
local building = Panels.building(main)
if not building then say("BAD the tower panel's building is not known"); return end
local page = SandboxVars.BuildingUtilities
local was = { FloorReach = page.FloorReach, TilesPerFloor = page.TilesPerFloor, TilesPerPiece = page.TilesPerPiece,
    BoosterLift = page.BoosterLift, tier = main.tier }
page.FloorReach, page.TilesPerFloor, page.TilesPerPiece, page.BoosterLift = 2, 3, 5, 10
main.tier = 4
say("building floors", building.minLevel, building.maxLevel, "box floor", main.z)

local function lastLog(panel)
    local log = panel.log or {}
    return log[#log] and log[#log].key
end
local function zoneLevels(panel)
    local low, high, count = nil, nil, 0
    local ids = Panels.zoneIds(panel)
    for _, room in ipairs(Panels.rooms(building)) do
        if ids and ids[room.id] then
            count = count + 1
            low, high = math.min(low or room.level, room.level), math.max(high or room.level, room.level)
        end
    end
    return low, high, count
end
local function roomsBetween(low, high)
    local keys, count = {}, 0
    for _, room in ipairs(Panels.rooms(building)) do
        if room.level >= low and room.level <= high then keys[#keys + 1] = room.key; count = count + 1 end
    end
    return keys, count
end

-- How far each tier reaches.
for tier, want in ipairs({ 2, 3, 4, 5 }) do check("reach at tier " .. tier, BU.floorReach(tier), want) end
page.FloorReach = 0
check("no limit at 0", BU.floorReach(4), nil)
page.FloorReach = 2
check("ranges text tells the floors", Panels.rangesText(4):find(getText("IGUI_BU_FloorReach", BU.floorReach(4)), 1, true) ~= nil, true)

-- A zone saved whole (before the limit) kept to the floors it reaches.
local before = main.zone
main.zone = nil
Networks.setZone(main, before)
Changes.fitZones()
local _, inReach = roomsBetween(main.z - 5, main.z + 5)
local low, high, count = zoneLevels(main)
check("whole zone kept: a list", main.zone ~= nil, true)
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
local states = Panels.zoneStates(main, Panels.rooms(building))
check("a room 8 floors up is far", farRoom and states[farRoom.id].state, "far")
check("the floor 8 up is not reached", Panels.reachesLevel(main, main.z + 8), false)

-- Put back.
page.FloorReach, page.TilesPerFloor, page.TilesPerPiece, page.BoosterLift = was.FloorReach, was.TilesPerFloor,
    was.TilesPerPiece, was.BoosterLift
main.tier = was.tier
Changes.setZone(main, nil)

-- "Water only from above" changed in play: the minute's check (Changes.applyShape) takes it once and the main panels'
-- networks follow (a tank then waters the floor below its own); changed back, they follow again.
local aboveWas = page.WaterFromAboveOnly
check("shape: nothing new", Changes.applyShape(), false)
page.WaterFromAboveOnly = not Water.aboveOnly()
check("shape: a changed option taken", Changes.applyShape(), true)
check("shape: once", Changes.applyShape(), false)
check("shape: a tank's floor", Water.producerLevel({ z = 5 }), Water.aboveOnly() and 4 or 5)
page.WaterFromAboveOnly = aboveWas
check("shape: changed back", Changes.applyShape(), true)
say("done")
