-- The story's hands in the game world (server side, and alone): the map's buildings, the player's position and
-- inventory, and putting mission items in place. Missions.game points here. The logic never touches a game object
-- itself; this is the thin part that is checked in the game (tests/ingame/p4_*.lua).
--
-- Putting an item in a building (DESIGN 12): if the building's containers have not been filled yet, OnFillContainer
-- puts it in one of them as they fill (the game fills a chunk's containers when it first loads, not when they are
-- opened); if they were, the chunk's LoadChunk event does it (OA.Chunks, never LoadGridsquare). When the place is
-- loaded as the mission starts it is done at once. Once placed a piece is marked, so loot respawn cannot add a second.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Chunks"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Zombies"
local OA = OperationAcorn
local Data, Missions = OA.StoryData, OA.Missions
local Game = {}
OA.StoryGame = Game

-- ---------------------------------------------------------------------------------------------------------------
-- The map's buildings.

-- The least area (squares) of a building a mission may use: no cellar, no shed.
local MIN_AREA = 30

-- The buildings a mission may use; a story site's also none a player made, none visited (the game marks so a building
-- its own stories set up when it loaded: a survivors' safehouse, a burnt one, and one a player was in) and none of a
-- stash (an annotated map leads there), with the names of its rooms.
local PLACES = { minArea = MIN_AREA, basement = false }
local SITES = { minArea = MIN_AREA, basement = false, playerBuilt = false, visited = false, stash = false,
    roomNames = true }

-- A building of the API's list as a place: its middle, the level its floor is on (z 0, or the lowest level when the
-- building lies wholly above it, the highest when wholly below), its box and its levels.
local function infoOf(b)
    local z1, z2 = b.minLevel, b.maxLevel
    local z = 0
    if z1 > 0 then z = z1 elseif z2 < 0 then z = z2 end
    return { x = math.floor(b.x), y = math.floor(b.y), z = z, x1 = b.minX, y1 = b.minY, x2 = b.maxX, y2 = b.maxY,
        z1 = z1, z2 = z2 }
end

-- A building's key for the world's story (the corner of its box): the sites used, the buildings searched.
local function keyOf(x, y)
    return tostring(x) .. "," .. tostring(y)
end

-- The buildings a regular mission may use whose middle lies lo to hi squares from x, y: { { x, y, z, x1, y1, x2, y2,
-- z1, z2 } } (infoOf).
function Game.buildingsIn(x, y, lo, hi)
    local list = {}
    for _, b in ipairs(OA.api().buildings.list(x, y, lo, hi, PLACES)) do list[#list + 1] = infoOf(b) end
    return list
end

-- The key of the building at a square (or touching it), or nil: the one with a room on the ground floor there first (a
-- basement under a house is a building of its own, and getBuildingAtRelax gives whichever comes first).
function Game.buildingKeyAt(x, y)
    local grid = getWorld():getMetaGrid()
    x, y = math.floor(x), math.floor(y)
    local def = grid:getBuildingAt(x, y, 0) or grid:getBuildingAtRelax(x, y)
    return def and keyOf(def:getX(), def:getY()) or nil
end

-- The buildings in the band around ax, ay that a story site may be (Places.pickSite): a plain one (Places.plain on its
-- rooms' names), none of `skip` (keys), as SITES says. With its key, area, rooms (Places.mainRooms), whether a home
-- (Places.home), mostly lock-ups (Places.mostlyStores) and its distance (dist). The whole map's list, unloaded parts
-- too (its rooms are known). Once for each story site.
function Game.sitesInBand(ax, ay, lo, hi, skip)
    local list = {}
    for _, b in ipairs(OA.api().buildings.list(ax, ay, lo, hi, SITES)) do
        local key = keyOf(b.minX, b.minY)
        local names = b.roomNames
        if not skip[key] and OA.Places.plain(names) then
            local site = infoOf(b)
            site.key, site.dist, site.area = key, b.distance, b.area
            site.rooms, site.home, site.stores = OA.Places.mainRooms(names), OA.Places.home(names),
                OA.Places.mostlyStores(names)
            list[#list + 1] = site
        end
    end
    return list
end

-- Open ground a camp may stand on (SCENES.md 5): a field, a farm, a ranch, thin or mixed woods (Forest, the Mix
-- forests); by the map's zones none of a road, a town, water, a car park, thick woods or a place the game's own stories
-- use (ZoneStory), with no building on it. Whether its squares are free is seen when they load (a prop that finds its
-- square taken is left out). B42's woods: the forage zones (forageZones.lua).
Game.CLOSED_ZONES = { "Nav", "ForagingNav", "TownZone", "WaterFlow", "WaterZone", "Water", "ParkingStall", "TrailerPark",
    "DeepForest", "OrganicForest", "PHForest", "PRForest", "BirchForest", "FarmForest", "Basement", "ZoneStory" }

-- A road (the map's Nav zone) passes within ROAD_FAR squares of a point and none within ROAD_NEAR: a camp is set up off
-- a road a truck came along, not on its shoulder nor deep in the woods. The points are drawn round the roads (the API's
-- `near`): a ring with no road gives none at once.
Game.ROAD_NEAR, Game.ROAD_FAR = 8, 40
local GROUND_POINTS = { count = 16, tries = 300, ["not"] = Game.CLOSED_ZONES,
    near = { type = "Nav", min = Game.ROAD_NEAR, max = Game.ROAD_FAR } }
-- `roadside`: by the road, as a wreck towed off it is left (off the carriageway, a road in sight). Its camp is smaller
-- (ROADSIDE_REACH), so that the ground about it never reaches the road.
Game.ROADSIDE_NEAR, Game.ROADSIDE_FAR, Game.ROADSIDE_REACH = 5, 14, 4
local ROADSIDE_POINTS = { count = 16, tries = 300, ["not"] = Game.CLOSED_ZONES,
    near = { type = "Nav", min = Game.ROADSIDE_NEAR, max = Game.ROADSIDE_FAR } }

-- Whether a point's zone types (a list) say woods (a Forest zone of any kind, Vegitation).
local function woodsIn(zones)
    for _, t in ipairs(zones) do
        if t == "Vegitation" or string.find(t, "Forest", 1, true) then return true end
    end
    return false
end

-- Open ground with no road asked for: the last of the map's zones to try.
local LOOSE_POINTS = { count = 16, tries = 300, ["not"] = Game.CLOSED_ZONES }
-- The band's outer edge, times these in turn, when it has no open ground (a base in a city's middle).
Game.GROUND_WIDER = { 1.5, 2 }

-- A point of the zones' list: a field first, else the first in woods; nil for none.
local function groundOf(ax, ay, lo, hi, wanted)
    local wx, wy
    for _, p in ipairs(OA.api().zones.points(ax, ay, lo, hi, wanted)) do
        local x, y = math.floor(p.x), math.floor(p.y)
        if not woodsIn(p.zones) then return x, y end
        wx, wy = wx or x, wy or y
    end
    return wx, wy
end

-- A point of the band as it is, on the map (its chunk's data known), for when its zones give none: the site settles on
-- the nearest open ground once it loads (Game.settleGround). The anchor itself at the very last.
local function ringPoint(ax, ay, lo, hi)
    local grid = getWorld():getMetaGrid()
    for _ = 1, 64 do
        local a, r = OA.randomFloat(0, 2 * math.pi), OA.randomFloat(lo, hi)
        local x, y = math.floor(ax + math.cos(a) * r), math.floor(ay + math.sin(a) * r)
        if grid:getChunkDataFromTile(x, y) and not grid:getBuildingAt(x, y, 0) then return x, y end
    end
    return math.floor(ax), math.floor(ay)
end

-- A point of open ground in the band around ax, ay, off a road, tried at random: a field first, else the first in
-- woods. `roadside`: by a road first (ROADSIDE), else as any open ground. None in the band: further out
-- (GROUND_WIDER), then with no road near asked, then a point of the band as it is. Never nil: a story mission must
-- have its site.
function Game.groundInBand(ax, ay, lo, hi, roadside)
    local x, y
    if roadside then x, y = groundOf(ax, ay, lo, hi, ROADSIDE_POINTS) end
    if not x then x, y = groundOf(ax, ay, lo, hi, GROUND_POINTS) end
    for _, wider in ipairs(Game.GROUND_WIDER) do
        if x then break end
        x, y = groundOf(ax, ay, lo, hi * wider, GROUND_POINTS)
    end
    if not x then x, y = groundOf(ax, ay, lo, hi * Game.GROUND_WIDER[#Game.GROUND_WIDER], LOOSE_POINTS) end
    if not x then
        x, y = ringPoint(ax, ay, lo, hi)
        OA.log("open ground: none in the zones about", ax, ay, "; a point of the band as it is,", x, y)
    end
    return x, y
end

-- Open natural ground, as a square condition: outdoors, no building, its floor natural ground (grass, dirt, sand: the
-- API's `natural`, as the game's own digging asks it), not water, a road, a pavement or a floor someone laid. A camp and
-- a meteor site stand on it (Game.settleGround, Sites.onChunk).
Game.GROUND = { building = "none", outside = true, wet = false, natural = true }

-- A new condition table: open ground (Game.GROUND) and more. The API keeps what it read of a table with it, so one used
-- again is made once.
function Game.groundWith(more)
    local f = {}
    for k, v in pairs(Game.GROUND) do f[k] = v end
    for k, v in pairs(more) do f[k] = v end
    return f
end

-- The camp's middle: free open ground.
local CAMP_MIDDLE = Game.groundWith({ free = true })

-- The parts of a camp that fits with its middle at an anchor: the middle (`middle` is its condition), and open ground on
-- every other square out to Game.CAMP_REACH (its tents, sandbags and truck; trees and bushes are cleared for it).
Game.CAMP_REACH = 7
local function campParts(middle)
    local R = Game.CAMP_REACH
    return { { offsets = { 0, 0 }, filter = middle }, { box = { -R, -R, R, R, 2 }, filter = Game.GROUND } }
end
-- (the API reads a parts table once and keeps the shape with it: the one for the camp's own middle is a constant)
local CAMP_PARTS = campParts(CAMP_MIDDLE)
-- A roadside camp: its middle with the road in sight and not within ROADSIDE_NEAR (the API's zoneNear), its ground out to
-- ROADSIDE_REACH.
local ROAD_NEAR = { type = "Nav", none = Game.ROADSIDE_NEAR, some = Game.ROADSIDE_FAR }
local function roadsideParts(middle)
    local R = Game.ROADSIDE_REACH
    return { { offsets = { 0, 0 }, filter = middle }, { box = { -R, -R, R, R, 2 }, filter = Game.GROUND } }
end
local ROADSIDE_PARTS = roadsideParts(Game.groundWith({ free = true, zoneNear = ROAD_NEAR }))

-- An open-ground site is picked from the map's zones, which the game keeps only for the cells it has loaded: one far
-- off may be water or a road. Once its camp is loaded, it is checked once: not open ground for a camp, it moves to
-- the nearest loaded spot that is (out to Game.SETTLE_REACH, inside the mission's circle), its pieces with it. None
-- found, it stays. Its pieces waiting for their squares are asked for again (their chunks may have loaded while it was
-- not settled). True when the site is settled (checked now or before); false while its camp's squares are not all
-- loaded.
Game.SETTLE_REACH = 40
local function moveTo(record, m, nx, ny)
    local site = m.site
    local old = site.key
    local sx, sy = nx - math.floor(site.x), ny - math.floor(site.y)
    site.x, site.y = site.x + sx, site.y + sy
    site.key = "g:" .. tostring(math.floor(site.x)) .. "," .. tostring(math.floor(site.y))
    for _, it in ipairs(m.items or {}) do
        if not it.placed then
            it.x, it.y, it.x1, it.y1, it.x2, it.y2 = it.x + sx, it.y + sy, it.x1 + sx, it.y1 + sy, it.x2 + sx, it.y2 + sy
        end
    end
    -- the story keeps the site for a revisit
    for _, s in pairs(OA.Story.section(record).sites or {}) do
        if s.key == old then s.x, s.y, s.key, s.settled = site.x, site.y, site.key, true end
    end
    OA.Story.useSite(site.key)
    OA.log("ground site", old, "moved to", site.key)
end

function Game.settleGround(record, m)
    local site = m.site
    if not (site and site.ground) or site.settled then return true end
    local c = getCell()
    local x0, y0, z = math.floor(site.x), math.floor(site.y), site.z or 0
    local R = site.roadside and Game.ROADSIDE_REACH or Game.CAMP_REACH
    local shape = site.roadside and roadsideParts or campParts
    if not (c:getGridSquare(x0 - R, y0 - R, z) and c:getGridSquare(x0 + R, y0 + R, z)
        and c:getGridSquare(x0 - R, y0 + R, z) and c:getGridSquare(x0 + R, y0 - R, z)) then
        return false
    end
    site.settled = true
    local squares = OA.api().squares
    local here = squares.fit({ x1 = x0, y1 = y0, x2 = x0, y2 = y0, z = z },
        site.roadside and ROADSIDE_PARTS or CAMP_PARTS) ~= nil
    local nx, ny
    if not here then
        local area = m.area
        local middle = site.roadside and ROADSIDE_PARTS[1].filter or CAMP_MIDDLE
        if area then
            middle = Game.groundWith({ free = true, distance = { x = area.x, y = area.y, max = area.r * 0.85 },
                zoneNear = site.roadside and ROAD_NEAR or nil })
        end
        -- on every other ring: a camp a square off makes no difference, and the search is a quarter as long
        local a = squares.fit({ x = x0, y = y0, z = z, from = 2, to = Game.SETTLE_REACH, step = 2 }, shape(middle))
        -- no camp fits near: its middle on the nearest open ground at least (not in water, on a road or in a house)
        if not a then a = squares.nearest({ x = x0, y = y0, z = z, to = Game.SETTLE_REACH }, middle) end
        if a and not (a:getX() == x0 and a:getY() == y0) then nx, ny = a:getX(), a:getY() end
    end
    if nx then moveTo(record, m, nx, ny)
    elseif not here then OA.log("ground site", site.key, "fits no camp, nor anything near: kept") end
    for _, it in ipairs(m.items or {}) do
        if not (it.placed or it.staged) then
            Game.unregisterPiece(m.id, it.key)
            Game.request(record, m, it)
        end
    end
    OA.Sync.changed("missions", record.id)
    return true
end

-- The zombie density of the map at a square (DESIGN-terminal 7.2): the metagrid's chunk there, as the game's own spawning
-- reads it (it follows the zombie count option). nil when the square is off the map or the game cannot say.
function Game.zombieIntensity(x, y)
    local ok, value = OA.try("game: the zombie intensity", function()
        local chunk = getWorld():getMetaGrid():getChunkDataFromTile(x, y)
        return chunk and chunk:getZombieIntensity(false) or nil
    end)
    if ok and type(value) == "number" then return value end
    return nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Characters.

-- The character of a record, if it is in the game now (alone, the one player; on a server by the id they carry).
function Game.character(record)
    local n = getNumActivePlayers and getNumActivePlayers() or 1
    for i = 0, n - 1 do
        local p = getSpecificPlayer(i)
        if p and p:getModData().OA_Id == record.id then return p end
    end
    if isServer() and getOnlinePlayers then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do
            local p = list:get(i)
            if p:getModData().OA_Id == record.id then return p end
        end
    end
    return nil
end

function Game.playerPosition(record)
    local p = Game.character(record)
    if not p then return nil end
    return p:getX(), p:getY(), p:getZ()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Items.

local function missionMatch(item, id)
    local md = item:getModData()
    local mine = md and md.OA_Mission
    if not mine then return false end
    return mine == id or string.sub(mine, 1, #id + 1) == id .. "#"
end

-- How many bags in bags an item search looks into; the match of any mission's piece.
local ITEM_DEPTH = 8
local FIRST_ITEM = { depth = ITEM_DEPTH, limit = 1 }
local ALL_ITEMS = { depth = ITEM_DEPTH }
local ANY_MISSION = { data = "OA_Mission" }

-- The first piece of a mission (its id, or a keyed piece's: id#key) in a container, a bag or an object, or nil.
local function firstPiece(source, id)
    return OA.api().items.find(source, { dataPrefix = { OA_Mission = id } }, FIRST_ITEM)[1]
end

-- The API's mark on what the sandbox's world item removal must leave on the floor (PZExtAPI "World items"): a mission
-- piece dropped by hand is not flagged by the game, as a placed one is.
local KEEP = "PZExtKeep"

-- What the last look for a mission's item found, by record id: { mission, item (found, or nil), miss (the inventory's
-- signature when it was not found) }.
local looked = {}

-- The mission's item in a character's things, or nil. Asked every few seconds by the sample cooler's look, and the
-- inventory may hold thousands of items: the item found is kept, and checked in a few steps (it is still in the
-- inventory and still the mission's); a search of the inventory is made only when it is not, and, when it found nothing,
-- not again until the inventory's signature (OA.signature: how many items, what they weigh) has changed.
function Game.findItem(record, missionId)
    local p = Game.character(record)
    if not p then return nil end
    local mem = looked[record.id]
    if not mem or mem.mission ~= missionId then
        mem = { mission = missionId }
        looked[record.id] = mem
    end
    local item = mem.item
    if item and OA.inInventory(item, p) and missionMatch(item, missionId) then return item end
    mem.item = nil
    local inventory = p:getInventory()
    local key = OA.signature(inventory)
    if mem.miss == key then return nil end
    item = firstPiece(inventory, missionId)
    mem.item, mem.miss = item, (not item) and key or nil
    return item
end

-- Whether an item is a mission's piece or holds one (a bag with it inside).
function Game.holds(item, missionId)
    if missionMatch(item, missionId) then return true end
    return instanceof(item, "InventoryContainer") and firstPiece(item, missionId) ~= nil
end

local function removeFrom(container, item)
    container:Remove(item)
    if isServer() then sendRemoveItemFromContainer(container, item) end
end

-- Takes one of a kind from the character (the sealed case, the field device). True when it was there.
function Game.takeItem(character, name)
    local item = character:getInventory():getFirstTypeRecurse(Data.fullType(name))
    if not item then return false end
    removeFrom(item:getContainer(), item)
    return true
end

function Game.takeMissionItem(character, missionId)
    local item = firstPiece(character:getInventory(), missionId)
    if not item then return false end
    removeFrom(item:getContainer(), item)
    return true
end

-- A new item with the mission's marks on it (OA_Mission is what the economy reads), its name made specific when it
-- carries a serial.
local function newItem(record, m, it)
    local item = instanceItem(it.type)
    if not item then
        OA.log("cannot make", it.type)
        return nil
    end
    local md = item:getModData()
    if not it.plain then
        md.OA_Mission = Missions.itemId(m, it.key)
        md.OA_Owner = record.id
        md[KEEP] = true
    end
    for k, v in pairs(it.mods or {}) do
        if v ~= "" then md[k] = v end
    end
    if it.mods and it.mods.OA_Serial then
        item:setName(item:getDisplayName() .. " " .. string.format("AC-%04d", it.mods.OA_Serial))
        item:setCustomName(true)
    end
    if it.mods and it.mods.OA_Drop ~= nil then md.OA_Drop = m.id end
    return item
end

-- A mission item put into a character's hands (a pickup, a sample): marked as newItem marks one, with the id of the record
-- it was issued to (`record`; else the character's own, which is the record's id).
function Game.giveMissionItem(character, fullType, missionId, mods, record)
    local item = instanceItem(fullType)
    if not item then return nil end
    local md = item:getModData()
    md.OA_Mission = missionId
    md.OA_Owner = record and record.id or character:getModData().OA_Id
    md[KEEP] = true
    for k, v in pairs(mods or {}) do md[k] = v end
    local inv = character:getInventory()
    inv:AddItem(item)
    if isServer() then sendAddItemToContainer(inv, item) end
    return item
end

-- The cooler's warmth where the player can see it: its tooltip.
function Game.setCoolerText(item, temp)
    item:setTooltip(OA.tooltipText(getText("Tooltip_OA_Story_CoolerTemp", string.format("%.1f", temp))))
end

-- The helicopter's noise, as the economy's option says how far it carries.
function Game.noise(record, x, y, z)
    local radius = OA.scaled(OA.BALANCE.noiseRadius, "HelicopterNoiseMultiplier")
    if radius <= 0 then return end
    addSound(Game.character(record), math.floor(x), math.floor(y), math.floor(z or 0), radius, radius)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Placing.

-- The pieces still waiting for a container as they fill: { { mission = id, key = key, id = "mission/key", x1..z2 = the
-- building's box } }. The box is kept here so that a fill outside it costs a few comparisons, not a search of the
-- records.
local waiting = {}
-- id -> how many containers of its building filled without taking the piece (the chance grows with it)
local seen = {}

local function waitEntry(m, it)
    return { mission = m.id, key = it.key, id = m.id .. "/" .. tostring(it.key),
        x1 = it.x1, y1 = it.y1, z1 = it.z1, x2 = it.x2, y2 = it.y2, z2 = it.z2 }
end

local function findPiece(missionId, key)
    for _, record in pairs(OA.Store.players()) do
        for _, m in ipairs(Missions.live(record)) do
            if m.id == missionId then
                for _, it in ipairs(m.items) do
                    if it.key == key then return record, m, it end
                end
            end
        end
    end
    return nil
end

-- Whether (x, y, z) lies in the box of a piece or of its waiting entry.
local function inBox(it, x, y, z)
    return x >= it.x1 and x <= it.x2 and y >= it.y1 and y <= it.y2 and z >= it.z1 and z <= it.z2
end

-- The boxes to look in for a piece's building, one for each level: its box, round its key square when large (a large
-- building is not scanned whole). What the API finds there is the loaded part of it.
local function boxesOf(it)
    local R = 24
    local x1, y1, x2, y2 = it.x1, it.y1, it.x2, it.y2
    if x2 - x1 > 2 * R then x1, x2 = math.max(x1, it.x - R), math.min(x2, it.x + R) end
    if y2 - y1 > 2 * R then y1, y2 = math.max(y1, it.y - R), math.min(y2, it.y + R) end
    local boxes = {}
    for z = it.z1, math.min(it.z2, it.z1 + 7) do boxes[#boxes + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z } end
    return boxes
end

-- The objects with a container, a dead body's left out; on the squares of a building; the free squares of its rooms.
local CONTAINERS = { container = true, notClass = { "IsoDeadBody" } }
local IN_BUILDING = { squares = { building = "any" } }
local FREE_ROOM = { free = true, room = "any" }

local function weightOf(it)
    local item = Data.ITEMS[Data.itemName(it.type) or ""]
    return item and item.weight or 0.5
end

-- The containers a piece is put in only when no other has room (the game's container types): what cooks, cools or
-- washes, and the bins.
Game.LAST_CONTAINERS = { fridge = true, freezer = true, stove = true, microwave = true, toaster = true,
    dishwasher = true, clothingwasher = true, clothingdryer = true, clothingdryerbasic = true, barbecue = true,
    barbecuepropane = true, fireplace = true, woodstove = true, bin = true, dumpster = true }

-- Every container with room for the piece in the loaded part of the building: { { container, square, room } }
-- (the LAST_CONTAINERS when no other).
local function containersFor(it)
    local found, last = {}, {}
    local w = weightOf(it)
    for _, box in ipairs(boxesOf(it)) do
        for _, o in ipairs(OA.api().objects.find(box, CONTAINERS, IN_BUILDING)) do
            for k = 0, o:getContainerCount() - 1 do
                local c = o:getContainerByIndex(k)
                if c and c:hasRoomFor(nil, w) then
                    local sq = o:getSquare()
                    local room = sq:getRoom()
                    local list = Game.LAST_CONTAINERS[c:getType()] and last or found
                    list[#list + 1] = { container = c, square = sq, room = room and room:getName() or nil }
                end
            end
        end
    end
    return #found > 0 and found or last
end

local function pick(list, int)
    return list[(int or OA.random)(1, #list)]
end

local function addToContainer(container, item)
    container:AddItem(item)
    if isServer() then sendAddItemToContainer(container, item) end
end

-- A free square in a room of the piece's building (the preferred room first), for what lies on the floor.
local function floorSquare(it)
    local rooms, preferred = {}, {}
    for _, box in ipairs(boxesOf(it)) do
        for _, sq in ipairs(OA.api().squares.list(box, FREE_ROOM)) do
            rooms[#rooms + 1] = sq
            if sq:getRoom():getName() == it.room then preferred[#preferred + 1] = sq end
        end
    end
    if #preferred > 0 then return pick(preferred) end
    if #rooms > 0 then return pick(rooms) end
    return nil
end

-- The nearest free square to a point outdoors (a stake tag lies by its stake).
local FREE = { free = true }
local function nearFreeSquare(x, y, z)
    local sq = OA.api().squares.nearest({ x = x, y = y, z = z, to = 3 }, FREE)
    return sq or getCell():getGridSquare(x, y, z)
end

local function dropOnFloor(sq, item, z)
    local wi = sq:AddWorldInventoryItem(item, 0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), z or 0)
    if wi and wi.getWorldItem and wi:getWorldItem() then
        OA.try("game: keeping the item in the world", function() wi:getWorldItem():setIgnoreRemoveSandbox(true) end)
    end
    return wi
end

-- The doors on the edges of a room.
local DOORS = { class = { "IsoDoor" } }

-- Locks the doors of the room a piece went into, with the building's key: and places the key in another container
-- of the building, so that a way in always exists.
local function lockRoom(record, m, it, sq)
    local room = sq:getRoom()
    -- the key opens a door of the same id: the game gives one only to a building's outer doors (IsoDoor.checkKeyId),
    -- so these take the building def's here; IsoBuilding has no key id in B42
    local def = sq:getBuilding() and sq:getBuilding():getDef()
    if not (room and def) then return end
    local locked = 0
    for _, e in ipairs(OA.api().objects.edges({ room = room }, DOORS)) do
        e.object:setKeyId(def:getKeyId())
        e.object:setLockedByKey(true)
        locked = locked + 1
    end
    if locked == 0 then return end
    local keyIt = {
        key = "KEY", type = "Base.Key1", mode = "container", plain = true, placed = false,
        x = it.x, y = it.y, z = it.z, x1 = it.x1, y1 = it.y1, x2 = it.x2, y2 = it.y2, z1 = it.z1, z2 = it.z2,
        avoidRoom = room:getName(), keyId = def:getKeyId(), mods = {},
    }
    m.items[#m.items + 1] = keyIt
    Game.request(record, m, keyIt)
end

local function finish(record, m, it, sq)
    it.placed = true
    it.at = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
    Game.unregisterPiece(m.id, it.key)
    OA.Sync.changed("missions", record.id)
end

-- Puts the piece where it belongs now, if enough of its place is loaded. True when done.
function Game.tryPlace(record, m, it, forceFloor)
    if it.placed then return true end
    if it.mode == "inside" then return false end
    if it.mode == "floor" and not it.inBuilding then
        -- A drop site's stake tag: by the stake. An open-ground site's piece: once the site is settled.
        if not Game.settleGround(record, m) then return false end
        if it.placed then return true end
        local sq = nearFreeSquare(it.x, it.y, it.z)
        if not sq then return false end
        local item = newItem(record, m, it)
        if not item then return true end
        dropOnFloor(sq, item)
        finish(record, m, it, sq)
        return true
    end
    if it.mode == "case" or it.mode == "floor" then
        local sq = floorSquare(it) or (forceFloor and nearFreeSquare(it.x, it.y, it.z or 0))
        if not sq then return false end
        local item = newItem(record, m, it)
        if not item then return true end
        if it.inside then
            local inner = instanceItem(Data.fullType(it.inside))
            if inner then
                local md = inner:getModData()
                md.OA_Mission = Missions.itemId(m, "A")
                md.OA_Owner = record.id
                md[KEEP] = true
                md.OA_Variant = it.mods and it.mods.OA_Variant
                addToContainer(item:getInventory(), inner)
            end
        end
        dropOnFloor(sq, item)
        finish(record, m, it, sq)
        return true
    end
    local list = containersFor(it)
    if it.avoidRoom then
        local rest = {}
        for _, e in ipairs(list) do if e.room ~= it.avoidRoom then rest[#rest + 1] = e end end
        list = rest
    end
    if #list == 0 then
        if not forceFloor then return false end
        local sq = floorSquare(it) or (forceFloor and nearFreeSquare(it.x, it.y, it.z or 0))
        if not sq then return false end
        local item = newItem(record, m, it)
        if not item then return true end
        dropOnFloor(sq, item)
        finish(record, m, it, sq)
        return true
    end
    local preferred = {}
    for _, e in ipairs(list) do if e.room == it.room then preferred[#preferred + 1] = e end end
    local e = pick(#preferred > 0 and preferred or list)
    local item = newItem(record, m, it)
    if not item then return true end
    if it.keyId then item:setKeyId(it.keyId) end
    addToContainer(e.container, item)
    finish(record, m, it, e.square)
    if it.lock then lockRoom(record, m, it, e.square) end
    return true
end

-- Puts the piece on a square's floor (a story site's stage chose it). True when done.
function Game.placeOnSquare(record, m, it, sq)
    if not sq then return false end
    local item = newItem(record, m, it)
    if not item then return true end
    dropOnFloor(sq, item)
    finish(record, m, it, sq)
    return true
end

-- Puts the piece in a container a stage chose (a vehicle's glove box), `sq` where it stands. True when done.
function Game.placeInContainer(record, m, it, container, sq)
    if not (container and sq) then return false end
    local item = newItem(record, m, it)
    if not item then return true end
    addToContainer(container, item)
    finish(record, m, it, sq)
    return true
end

-- Puts the piece on an object's top (a desk a stage set), as the game lays a thing put on a table. True when done.
function Game.placeOnSurface(record, m, it, object)
    local sq = object and object:getSquare()
    if not sq then return false end
    local item = newItem(record, m, it)
    if not item then return true end
    dropOnFloor(sq, item, object:getSurfaceOffsetNoTable() / 96)
    finish(record, m, it, sq)
    return true
end

-- Puts the piece in a container of a room (a RoomDef of the loaded building; a story site's stage chose it), else on
-- the room's floor (`floorOnly`: there in any case). True when done.
function Game.placeInRoom(record, m, it, roomDef, floorOnly)
    local room = roomDef and roomDef:getIsoRoom()
    if not room then return false end
    local w = weightOf(it)
    local found, last = {}, {}
    for _, o in ipairs(floorOnly and {} or OA.api().objects.find({ room = room }, CONTAINERS)) do
        for k = 0, o:getContainerCount() - 1 do
            local c = o:getContainerByIndex(k)
            if c and c:hasRoomFor(nil, w) then
                local list = Game.LAST_CONTAINERS[c:getType()] and last or found
                list[#list + 1] = { container = c, square = o:getSquare() }
            end
        end
    end
    if #found == 0 then found = last end
    local item = newItem(record, m, it)
    if not item then return true end
    if it.keyId then item:setKeyId(it.keyId) end
    if #found > 0 then
        local e = pick(found)
        addToContainer(e.container, item)
        finish(record, m, it, e.square)
        return true
    end
    local sq = room:getRandomFreeSquare()
    if not sq then return false end
    dropOnFloor(sq, item)
    finish(record, m, it, sq)
    return true
end

-- The chunks a piece's building covers (up to 24, nearest to the key square first), as chunk keys with a point in them;
-- `reach` squares round its square instead (an open-ground site's camp).
local function chunksOf(it, reach)
    local S = OA.Chunks.SIZE
    local list = {}
    local x1, y1, x2, y2 = it.x1, it.y1, it.x2, it.y2
    if reach then x1, y1, x2, y2 = it.x - reach, it.y - reach, it.x + reach, it.y + reach end
    local cx1, cx2 = math.floor(x1 / S), math.floor(x2 / S)
    local cy1, cy2 = math.floor(y1 / S), math.floor(y2 / S)
    for cx = cx1, cx2 do
        for cy = cy1, cy2 do
            local px, py = cx * S + 1, cy * S + 1
            local dx, dy = px - it.x, py - it.y
            list[#list + 1] = { x = px, y = py, d = dx * dx + dy * dy }
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    while #list > 24 do table.remove(list) end
    return list
end

-- Asks for the piece to be placed: now if its place is loaded, otherwise when it loads or its containers fill. A piece
-- a story site's stage puts (it.staged, Story/Stage) waits for the stage. Its chunks loaded already will not load
-- again while the player is about: only the others are waited for, and with none left (the whole place is loaded and
-- has no container for it) it goes on a floor now.
function Game.request(record, m, it)
    if it.placed or it.staged then return end
    if Game.tryPlace(record, m, it) then return end
    local chunks = chunksOf(it, m.site and m.site.ground and not m.site.settled and Game.CAMP_REACH or nil)
    local c = getCell()
    local unloaded = 0
    for _, ch in ipairs(chunks) do
        if not c:getGridSquare(ch.x, ch.y, 0) then unloaded = unloaded + 1 end
    end
    if unloaded == 0 and Game.tryPlace(record, m, it, true) then return end
    if it.mode == "container" then
        waiting[#waiting + 1] = waitEntry(m, it)
    end
    it.chunks = math.max(unloaded, 1)
    it.misses = 0
    for _, ch in ipairs(chunks) do
        OA.Chunks.add({ kind = "oa_place", mission = m.id, key = it.key, x = ch.x, y = ch.y, z = 0 })
    end
end

function Game.unregisterPiece(missionId, key)
    for i = #waiting, 1, -1 do
        if waiting[i].mission == missionId and (key == nil or waiting[i].key == key) then
            seen[waiting[i].id] = nil
            table.remove(waiting, i)
        end
    end
    OA.Chunks.remove(function(e)
        return e.kind == "oa_place" and e.mission == missionId and (key == nil or e.key == key)
    end)
end

-- The mission is over (or sealed): nothing of it waits any more. Items already placed stay in the world.
function Game.release(m)
    Game.unregisterPiece(m.id, nil)
    for _, it in ipairs(m.items or {}) do Game.untrack(m, it) end
    if m.zombies and OA.ZombieMissions then OA.ZombieMissions.release(m) end
end

-- Memory of what waits for containers is not saved: rebuilt from the records when the world starts.
function Game.rebuildWaiting()
    waiting, seen = {}, {}
    for _, record in pairs(OA.Store.players()) do
        for _, m in ipairs(Missions.live(record)) do
            for _, it in ipairs(m.items) do
                if not it.placed and it.mode == "container" then waiting[#waiting + 1] = waitEntry(m, it) end
            end
        end
    end
end

-- OnFillContainer: a container of a building a piece waits for is filling. The first containers are taken with a
-- small chance (the room the piece prefers with a large one), later ones with a larger, so the item lies somewhere in
-- the building and not always in the first. (A bag rolled inside a container fires it with its loot table, an
-- ItemPickerContainer, for the container: skipped.)
function Game.onFill(roomName, containerType, container)
    if #waiting == 0 or not instanceof(container, "ItemContainer") then return end
    local sq = container:getSourceGrid()
    if not sq or not sq:getBuilding() then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for i = #waiting, 1, -1 do
        local w = waiting[i]
        if inBox(w, x, y, z) then
            local record, m, it = findPiece(w.mission, w.key)
            if not it or it.placed then
                seen[w.id] = nil
                table.remove(waiting, i)
            else
                local n = (seen[w.id] or 0) + 1
                seen[w.id] = n
                local chance = 0.12 + 0.12 * n
                if roomName and it.room and roomName == it.room then chance = 0.7 end
                if it.avoidRoom and roomName == it.avoidRoom then chance = 0 end
                if OA.randomFloat(0, 1) < chance and container:hasRoomFor(nil, weightOf(it)) then
                    local item = newItem(record, m, it)
                    if item then
                        if it.keyId then item:setKeyId(it.keyId) end
                        addToContainer(container, item)
                        finish(record, m, it, sq)
                        if it.lock then lockRoom(record, m, it, sq) end
                    end
                end
            end
        end
    end
end

-- LoadChunk: one of the chunks of a building a piece waits for has loaded. By now its containers are filled.
OA.Chunks.handle("oa_place", function(entry, chunk)
    local record, m, it = findPiece(entry.mission, entry.key)
    if not it or it.placed then return true end
    it.misses = (it.misses or 0) + 1
    local forceFloor = it.misses >= (it.chunks or 1)
    local ok, done = pcall(Game.tryPlace, record, m, it, forceFloor)
    if not ok then
        OA.log("placing", m.id, "failed:", tostring(done))
        return false
    end
    -- Placed: all its chunk entries go (unregisterPiece did it); this entry goes too.
    return done == true
end)

-- ---------------------------------------------------------------------------------------------------------------
-- The items of the pieces found, followed for the maps (Missions.found). Not saved: a world loaded since follows an
-- item again once the player carries it or picks it up.

local followed = {}  -- "mission/key" -> the item
local missed = {}    -- "mission/key" -> the inventory's signature when a search for it in the player's things failed

local function pieceKey(m, it)
    return m.id .. "/" .. tostring(it.key)
end

function Game.track(m, it, item)
    local key = pieceKey(m, it)
    followed[key], missed[key] = item, nil
end

function Game.untrack(m, it)
    local key = pieceKey(m, it)
    followed[key], missed[key] = nil, nil
end

-- Where an item is: the square it lies on, the object or vehicle whose container holds it (through the bags it is in),
-- or the character who carries it (carried true). Nil when it is nowhere in the world (sealed away, burnt).
function Game.whereIs(item)
    for _ = 1, 16 do
        local world = item:getWorldItem()
        if world then
            local sq = world:getSquare()
            if not sq then return nil end
            return sq:getX(), sq:getY(), sq:getZ(), false
        end
        local container = item:getContainer()
        if not container then return nil end
        local holder = container:getContainingItem()
        if holder then
            item = holder
        else
            local parent = container:getParent()
            if parent and instanceof(parent, "IsoGameCharacter") then
                return math.floor(parent:getX()), math.floor(parent:getY()), math.floor(parent:getZ()), true
            end
            local part = container:getVehiclePart()
            local vehicle = part and part:getVehicle()
            if vehicle then return math.floor(vehicle:getX()), math.floor(vehicle:getY()), math.floor(vehicle:getZ()), false end
            local sq = container:getSourceGrid()
            if not sq then return nil end
            return sq:getX(), sq:getY(), sq:getZ(), false
        end
    end
    return nil
end

-- Where a found piece is now: its item followed, or, when none is (a world loaded since), the player's things are
-- searched for it, and again only once they changed (OA.signature). Nil when it is not known.
function Game.whereNow(record, m, it)
    local key = pieceKey(m, it)
    local item = followed[key]
    if item then
        local x, y, z, carried = Game.whereIs(item)
        if x then return x, y, z, carried end
        followed[key] = nil
    end
    local p = Game.character(record)
    if not p then return nil end
    local inventory = p:getInventory()
    local signature = OA.signature(inventory)
    if missed[key] == signature then return nil end
    item = firstPiece(inventory, Missions.itemId(m, it.key))
    if not item then
        missed[key] = signature
        return nil
    end
    followed[key] = item
    return Game.whereIs(item)
end

-- The piece of a mission in a bag the player picked up, or nil.
function Game.pieceIn(bag, missionId)
    return firstPiece(bag, missionId)
end

-- ---------------------------------------------------------------------------------------------------------------
-- A piece destroyed (Missions.replacePiece).

-- Lays the piece out again: now where its place is loaded (on the floor of its building when no container is left),
-- otherwise when it loads.
function Game.placeAgain(record, m, it)
    if Game.tryPlace(record, m, it, true) then return end
    Game.request(record, m, it)
end

-- OnPZExtContainerBurning: a fire is about to empty a container (and take it away). It is looked into only while a
-- mission is running; a fire is rare, and the look is one search of the container. Each piece found is replaced once,
-- however many of its items (a case and the record in it) burn.
function Game.onBurning(container, object)
    if not container or container:isEmpty() then return end
    local running = false
    for _, record in pairs(OA.Store.players()) do
        for _, m in ipairs(Missions.live(record)) do
            if m.state == "open" then running = true end
        end
    end
    if not running then return end
    local found = OA.api().items.find(container, ANY_MISSION, ALL_ITEMS)
    local done = {}
    for _, item in ipairs(found) do
        local id = item:getModData().OA_Mission
        for _, record in pairs(OA.Store.players()) do
            local m, it = Missions.pieceOf(record, id)
            if it and not done[it] then
                done[it] = true
                Missions.replacePiece(record, m, it)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The record in the drop case.

-- Whether the player may see a swap's drop now: they are within a few squares of it or in its room, or its square is
-- in their sight. False when they are away, or the drop's square is not loaded.
function Game.dropSeen(record, m)
    local character = Game.character(record)
    local caseIt
    for _, p in ipairs(m.items) do
        if p.key == "CASE" then caseIt = p end
    end
    local at = caseIt and caseIt.at
    if not (character and at) then return false end
    local sq = getCell():getGridSquare(at.x, at.y, at.z)
    if not sq then return false end
    local dx, dy = character:getX() - (at.x + 0.5), character:getY() - (at.y + 0.5)
    if math.floor(character:getZ()) == at.z and dx * dx + dy * dy <= 9 then return true end
    local mine = character:getCurrentSquare()
    if sq:getRoom() and mine and mine:getRoom() == sq:getRoom() then return true end
    return sq:isCanSee(character:getPlayerNum())
end

-- The record appears in the case at the drop (or in the player's hands when the case is gone).
function Game.deliverInside(record, m, it)
    local caseIt
    for _, p in ipairs(m.items) do
        if p.key == "CASE" then caseIt = p end
    end
    local item
    if caseIt and caseIt.at then
        local sq = getCell():getGridSquare(caseIt.at.x, caseIt.at.y, caseIt.at.z)
        if sq then
            local objs = sq:getWorldObjects()
            for i = 0, objs:size() - 1 do
                local held = objs:get(i):getItem()
                if held and held:getModData().OA_Drop == m.id and instanceof(held, "InventoryContainer") then
                    item = newItem(record, m, it)
                    if item then addToContainer(held:getInventory(), item) end
                    break
                end
            end
        end
    end
    if not item then
        local character = Game.character(record)
        if character then
            local given = Game.giveMissionItem(character, it.type, Missions.itemId(m, it.key), it.mods, record)
            if given then Missions.found(record, m, it, given) end
        end
    end
    it.placed = true
end

-- ---------------------------------------------------------------------------------------------------------------
-- A zombie mission's group (Story/Zombies).

-- The API's zombie calls (PZExtAPI.zombies) and this mod's handle, or nil when the API lacks the zombie marks.
local function zombieApi()
    local api, handle = OA.api(), OA.handle()
    local zombies = api and api.zombies
    if not (handle and zombies and zombies.mark and zombies.hold) then return nil end
    return zombies, handle
end

-- Whether a zombie mission can be given: its group is known by the API's marks.
function Game.canMarkZombies()
    return zombieApi() ~= nil
end

-- The key a zombie or a corpse carries (a zombie mission's id, Game.spawnZombies), or nil.
function Game.markOf(object)
    local zombies, handle = zombieApi()
    if not zombies then return nil end
    local ok, key = OA.try("game: the mark of a zombie", zombies.markOf, handle, object)
    return ok and key or nil
end

-- The API holds the group to its circle (zombies.hold): idle wandering stays inside, far sounds are not heard, and one
-- whose chunk unloads goes instead of staying virtual.
function Game.holdZombies(m)
    local zombies, handle = zombieApi()
    if not zombies then return end
    local ok, err = pcall(zombies.hold, handle, m.id, { x = m.area.x + 0.5, y = m.area.y + 0.5, radius = m.area.r,
        margin = OA.StoryData.ZOMBIE_MARGIN, dissolve = true })
    if not ok then OA.log("zombie hold failed:", tostring(err)) end
end

-- The loaded living zombies marked with the key.
local function markedZombies(key)
    local zombies, handle = zombieApi()
    if not zombies then return {} end
    local ok, list = OA.try("game: the marked zombies", zombies.marked, handle, key)
    return ok and list or {}
end

function Game.countMarked(key)
    return #markedZombies(key)
end

-- The hold goes, the loaded zombies of the group with it (one that strayed out of the circle too), and the world forgets
-- the mark (its virtual ones too).
function Game.releaseZombies(m)
    local zombies, handle = zombieApi()
    if not zombies then return end
    OA.try("game: releasing the zombies", zombies.release, handle, m.id)
    for _, z in ipairs(markedZombies(m.id)) do
        z:removeFromWorld()
        z:removeFromSquare()
    end
    OA.try("game: forgetting the zombies", zombies.forget, handle, m.id)
end

-- Whether the circle's middle and its four edges are loaded.
function Game.areaLoaded(area)
    local c = getCell()
    local x, y, r = area.x, area.y, area.r
    for _, p in ipairs({ { x, y }, { x + r, y }, { x - r, y }, { x, y + r }, { x, y - r } }) do
        if not c:getGridSquare(p[1], p[2], 0) then return false end
    end
    return true
end

-- The squares a zombie may stand on: free, with a floor, not water or stairs; outdoors unless `indoors`.
local OPEN_OUTSIDE = { floor = true, free = true, water = false, stairs = false, outside = true }
local OPEN_INSIDE = { floor = true, free = true, water = false, stairs = false }

-- The open squares of the circle that are joined to the one nearest its middle (a walled yard or a roof is not part of
-- it), outdoors first: { square, ... }.
local function openSquares(area, indoors)
    return OA.api().squares.list({ x = area.x, y = area.y, z = 0, r = area.r }, indoors and OPEN_INSIDE or OPEN_OUTSIDE,
        { connected = { x = area.x, y = area.y } })
end

-- Brings `count` of the group into the circle in the outfit, marked with `key`, each on its own square more than
-- ZOMBIE_AWAY from the player when there are squares enough (else squares are shared). Returns how many came.
function Game.spawnZombies(area, outfit, key, count, px, py)
    local zombies, handle = zombieApi()
    if not zombies then return 0 end
    local squares = openSquares(area, false)
    if #squares == 0 then squares = openSquares(area, true) end
    local away = OA.StoryData.ZOMBIE_AWAY
    local far = {}
    for _, sq in ipairs(squares) do
        local dx, dy = sq:getX() + 0.5 - px, sq:getY() + 0.5 - py
        if dx * dx + dy * dy > away * away then far[#far + 1] = sq end
    end
    if #far == 0 then return 0 end
    local made = 0
    for i = 1, count do
        local n = #far
        if n == 0 then break end
        local j = OA.random(1, n)
        local sq = far[j]
        if n > count - i + 1 then far[j] = far[n]; far[n] = nil end
        local list = addZombiesInOutfit(sq:getX(), sq:getY(), sq:getZ(), 1, outfit, 50)
        for k = 0, (list and list:size() or 0) - 1 do
            if OA.try("game: marking a zombie", zombies.mark, handle, list:get(k), key) then made = made + 1 end
        end
    end
    return made
end

return Game
