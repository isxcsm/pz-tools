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

local buildingList

local function buildings()
    if not buildingList then buildingList = getWorld():getMetaGrid():getBuildings() end
    return buildingList
end

function Game.buildingCount()
    buildingList = nil
    return buildings():size()
end

-- Centre of the i-th building and whether a mission may use it: not a cellar, not a shed.
function Game.building(i)
    local b = buildings():get(i - 1)
    local x = math.floor((b:getX() + b:getX2()) / 2)
    local y = math.floor((b:getY() + b:getY2()) / 2)
    local ok = b:getArea() >= MIN_AREA and not b:isBasement()
    return x, y, ok
end

local function infoOf(b)
    local z1, z2 = b:getMinLevel(), b:getMaxLevel()
    local z = 0
    if z1 > 0 then z = z1 elseif z2 < 0 then z = z2 end
    return {
        x = math.floor((b:getX() + b:getX2()) / 2), y = math.floor((b:getY() + b:getY2()) / 2), z = z,
        x1 = b:getX(), y1 = b:getY(), x2 = b:getX2() - 1, y2 = b:getY2() - 1, z1 = z1, z2 = z2,
    }
end

function Game.buildingInfo(i)
    return infoOf(buildings():get(i - 1))
end

-- A building's key for the world's story (the corner of its def): the sites used, the buildings searched.
local function keyOf(def)
    return tostring(def:getX()) .. "," .. tostring(def:getY())
end

-- The key of the building at a square (or touching it), or nil: the one with a room on the ground floor there first (a
-- basement under a house is a building of its own, and getBuildingAtRelax gives whichever comes first).
function Game.buildingKeyAt(x, y)
    local grid = getWorld():getMetaGrid()
    x, y = math.floor(x), math.floor(y)
    local def = grid:getBuildingAt(x, y, 0) or grid:getBuildingAtRelax(x, y)
    return def and keyOf(def) or nil
end

-- A building's facts that never change, kept once looked at: its centre, and when it could ever be a story site (no
-- cellar, no shed, plain: Places.plain on its rooms' names) where it is (infoOf), its key, area, rooms, whether a home
-- and mostly lock-ups (Places.mostlyStores). Looked at a few each tick from the start (warmFacts), so picking a site later
-- costs little more than the distances.
local facts, factsFor = {}, nil

-- By the building's place in the map's list; kept while the list is as long (a building a player made goes in, or
-- out, and the places move: all are looked at again).
local function factsList()
    local all = buildings()
    if all:size() ~= factsFor then facts, factsFor = {}, all:size() end
    return all
end

local function factsOf(i, b)
    local f = facts[i]
    if f then return f end
    f = { cx = (b:getX() + b:getX2()) / 2, cy = (b:getY() + b:getY2()) / 2 }
    if not b:isBasement() and b:getArea() >= MIN_AREA then
        local names = {}
        local rooms = b:getRooms()
        for k = 0, rooms:size() - 1 do names[#names + 1] = rooms:get(k):getName() or "" end
        if OA.Places.plain(names) then
            f.site = infoOf(b)
            f.key, f.area, f.rooms, f.home = keyOf(b), b:getArea(), b:getRoomsNumber(), b:containsRoom("bedroom")
            f.stores = OA.Places.mostlyStores(names)
        end
    end
    facts[i] = f
    return f
end

Game.WARM_PER_TICK = 40
local warmed = 0
local function warmFacts()
    local all = factsList()
    local n = all:size()
    if warmed > n then warmed = 0 end
    for i = warmed, math.min(warmed + Game.WARM_PER_TICK, n) - 1 do factsOf(i, all:get(i)) end
    warmed = math.min(warmed + Game.WARM_PER_TICK, n)
    if warmed >= n then Events.OnTick.Remove(warmFacts) end
end
-- (where the story runs: not on a client of a server)
local warming = false
local function startWarming()
    if warming or isClient() then return end
    warming = true
    Events.OnTick.Add(warmFacts)
end
Events.OnGameStart.Add(startWarming)
Events.OnServerStarted.Add(startWarming)

-- The buildings in the band around ax, ay that a story site may be (Places.pickSite): one that could (factsOf), none of
-- `skip` (keys), not a stash's (an annotated map leads there), not one a player made, not one visited (the game marks
-- so a building its own stories set up when it loaded: a survivors' safehouse, a burnt one, and one a player was in).
-- The whole map's list, unloaded parts too (its rooms are known). Once for each story site.
function Game.sitesInBand(ax, ay, lo, hi, skip)
    local list = {}
    local all = factsList()
    for i = 0, all:size() - 1 do
        local f = facts[i] or factsOf(i, all:get(i))
        local site = f.site
        local dx, dy = f.cx - ax, f.cy - ay
        local d = site and math.sqrt(dx * dx + dy * dy)
        local b = d and d >= lo and d <= hi and not skip[f.key] and all:get(i)
        if b and not (b:isUserDefined() or b:isHasBeenVisited()) then
            local ok, stash = pcall(StashSystem.isStashBuilding, b)
            if not (ok and stash) then
                list[#list + 1] = { x = site.x, y = site.y, z = site.z, x1 = site.x1, y1 = site.y1, x2 = site.x2,
                    y2 = site.y2, z1 = site.z1, z2 = site.z2, key = f.key, dist = d, area = f.area, rooms = f.rooms,
                    home = f.home, stores = f.stores }
            end
        end
    end
    return list
end

-- Open ground a camp may stand on (SCENES.md 5): a field, a farm, a ranch, thin or mixed woods (Forest, the Mix
-- forests); by the map's zones none of a road, a town, water, a car park, thick woods or a place the game's own stories
-- use (ZoneStory), with no building on it. Whether its squares are free is seen when they load (a prop that finds its
-- square taken is left out). B42's woods: the forage zones (forageZones.lua).
Game.CLOSED_ZONES = { Nav = true, ForagingNav = true, TownZone = true, WaterFlow = true, WaterZone = true, Water = true,
    ParkingStall = true, TrailerPark = true, DeepForest = true, OrganicForest = true, PHForest = true, PRForest = true,
    BirchForest = true, FarmForest = true, Basement = true, ZoneStory = true }

-- Whether x, y is open ground, and whether it is in woods (a Forest zone of any kind, Vegitation).
local function openAt(grid, x, y)
    if grid:getBuildingAt(x, y) then return false end
    local zones = grid:getZonesAt(x, y, 0)
    local woods = false
    for i = 0, zones:size() - 1 do
        local t = zones:get(i):getType()
        if Game.CLOSED_ZONES[t] then return false end
        if t == "Vegitation" or string.find(t, "Forest", 1, true) then woods = true end
    end
    return true, woods
end

-- Whether a road (the map's Nav zone) passes within `far` squares of x, y and none within `near`: a camp is set up off
-- a road a truck came along, not on its shoulder nor deep in the woods. Looked for on rings of eight points.
Game.ROAD_NEAR, Game.ROAD_FAR = 8, 40
local function roadAt(grid, x, y)
    local zones = grid:getZonesAt(x, y, 0)
    for i = 0, zones:size() - 1 do
        if zones:get(i):getType() == "Nav" then return true end
    end
    return false
end
local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } }
local function offRoad(grid, x, y)
    for r = 4, Game.ROAD_NEAR, 4 do
        for _, d in ipairs(DIRS) do
            if roadAt(grid, math.floor(x + d[1] * r), math.floor(y + d[2] * r)) then return false end
        end
    end
    for r = Game.ROAD_NEAR + 4, Game.ROAD_FAR, 4 do
        for _, d in ipairs(DIRS) do
            if roadAt(grid, math.floor(x + d[1] * r), math.floor(y + d[2] * r)) then return true end
        end
    end
    return false
end

-- A point of open ground in the band around ax, ay, off a road (offRoad), tried at random: a field first, else the
-- first in woods; nil when none was found.
function Game.groundInBand(ax, ay, lo, hi, tries)
    local grid = getWorld():getMetaGrid()
    local wx, wy
    for _ = 1, tries or 300 do
        local angle = OA.randomFloat(0, 2 * math.pi)
        local r = OA.randomFloat(lo, hi)
        local x, y = math.floor(ax + math.cos(angle) * r), math.floor(ay + math.sin(angle) * r)
        local open, woods = openAt(grid, x, y)
        if open and (not woods or not wx) and offRoad(grid, x, y) then
            if not woods then return x, y end
            wx, wy = x, y
        end
    end
    return wx, wy
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

local function anyMission(item)
    return item:hasModData() and item:getModData().OA_Mission ~= nil
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
    -- oa-scan: ok (a new signature, or no item kept)
    item = inventory:getFirstEvalArgRecurse(missionMatch, missionId)
    mem.item, mem.miss = item, (not item) and key or nil
    return item
end

-- Whether an item is a mission's piece or holds one (a bag with it inside).
function Game.holds(item, missionId)
    if missionMatch(item, missionId) then return true end
    return instanceof(item, "InventoryContainer")
        and item:getInventory():getFirstEvalArgRecurse(missionMatch, missionId) ~= nil
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
    local item = character:getInventory():getFirstEvalArgRecurse(missionMatch, missionId)
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

-- The squares of the piece's building that are loaded, around its key square (a large building is not scanned
-- whole): calls fn(square) for each.
local function eachLoadedSquare(it, fn)
    local R = 24
    local x1, y1, x2, y2 = it.x1, it.y1, it.x2, it.y2
    if x2 - x1 > 2 * R then x1, x2 = math.max(x1, it.x - R), math.min(x2, it.x + R) end
    if y2 - y1 > 2 * R then y1, y2 = math.max(y1, it.y - R), math.min(y2, it.y + R) end
    local c = getCell()
    for z = it.z1, math.min(it.z2, it.z1 + 7) do
        for x = x1, x2 do
            for y = y1, y2 do
                local sq = c:getGridSquare(x, y, z)
                if sq and sq:getBuilding() then fn(sq) end
            end
        end
    end
end

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
    eachLoadedSquare(it, function(sq)
        local objects = sq:getObjects()
        for j = 0, objects:size() - 1 do
            local o = objects:get(j)
            if not instanceof(o, "IsoDeadBody") then
                for k = 0, o:getContainerCount() - 1 do
                    local c = o:getContainerByIndex(k)
                    if c and c:hasRoomFor(nil, w) then
                        local room = sq:getRoom()
                        local list = Game.LAST_CONTAINERS[c:getType()] and last or found
                        list[#list + 1] = { container = c, square = sq, room = room and room:getName() or nil }
                    end
                end
            end
        end
    end)
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
    eachLoadedSquare(it, function(sq)
        if sq:isFree(false) and sq:getRoom() then
            rooms[#rooms + 1] = sq
            if sq:getRoom():getName() == it.room then preferred[#preferred + 1] = sq end
        end
    end)
    if #preferred > 0 then return pick(preferred) end
    if #rooms > 0 then return pick(rooms) end
    return nil
end

-- The nearest free square to a point outdoors (a stake tag lies by its stake).
local function nearFreeSquare(x, y, z)
    local c = getCell()
    for r = 0, 3 do
        for dx = -r, r do
            for dy = -r, r do
                local sq = c:getGridSquare(x + dx, y + dy, z)
                if sq and sq:isFree(false) then return sq end
            end
        end
    end
    return c:getGridSquare(x, y, z)
end

local function dropOnFloor(sq, item, z)
    local wi = sq:AddWorldInventoryItem(item, 0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), z or 0)
    if wi and wi.getWorldItem and wi:getWorldItem() then
        OA.try("game: keeping the item in the world", function() wi:getWorldItem():setIgnoreRemoveSandbox(true) end)
    end
    return wi
end

-- Locks the doors of the room a piece went into, with the building's key: and places the key in another container
-- of the building, so that a way in always exists.
local function lockRoom(record, m, it, sq)
    local room = sq:getRoom()
    -- the key opens a door of the same id: the game gives one only to a building's outer doors (IsoDoor.checkKeyId),
    -- so these take the building def's here; IsoBuilding has no key id in B42
    local def = sq:getBuilding() and sq:getBuilding():getDef()
    if not (room and def) then return end
    local locked = 0
    local squares = room:getSquares()
    local c = getCell()
    for i = 0, squares:size() - 1 do
        local s2 = squares:get(i)
        local objects = s2:getObjects()
        for j = 0, objects:size() - 1 do
            local o = objects:get(j)
            if instanceof(o, "IsoDoor") then
                local other
                if o:getNorth() then other = c:getGridSquare(s2:getX(), s2:getY() - 1, s2:getZ())
                else other = c:getGridSquare(s2:getX() - 1, s2:getY(), s2:getZ()) end
                local r1, r2 = s2:getRoom(), other and other:getRoom()
                if (r1 == room) ~= (r2 == room) then
                    o:setKeyId(def:getKeyId())
                    o:setLockedByKey(true)
                    locked = locked + 1
                end
            end
        end
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
        -- A drop site's stake tag: by the stake.
        local sq = nearFreeSquare(it.x, it.y, it.z)
        if not sq then return false end
        local item = newItem(record, m, it)
        if not item then return true end
        dropOnFloor(sq, item)
        finish(record, m, it, sq)
        return true
    end
    if it.mode == "case" or it.mode == "floor" then
        local sq = floorSquare(it)
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
        local sq = floorSquare(it)
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
    local squares = room:getSquares()
    for i = 0, floorOnly and -1 or squares:size() - 1 do
        local sq = squares:get(i)
        local objects = sq:getObjects()
        for j = 0, objects:size() - 1 do
            local o = objects:get(j)
            if not instanceof(o, "IsoDeadBody") then
                for k = 0, o:getContainerCount() - 1 do
                    local c = o:getContainerByIndex(k)
                    if c and c:hasRoomFor(nil, w) then
                        local list = Game.LAST_CONTAINERS[c:getType()] and last or found
                        list[#list + 1] = { container = c, square = sq }
                    end
                end
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

-- The chunks a piece's building covers (up to 24, nearest to the key square first), as chunk keys with a point in them.
local function chunksOf(it)
    local S = OA.Chunks.SIZE
    local list = {}
    local cx1, cx2 = math.floor(it.x1 / S), math.floor(it.x2 / S)
    local cy1, cy2 = math.floor(it.y1 / S), math.floor(it.y2 / S)
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
-- a story site's stage puts (it.staged, Story/Stage) waits for the stage.
function Game.request(record, m, it)
    if it.placed or it.staged then return end
    if Game.tryPlace(record, m, it) then return end
    if it.mode == "container" then
        waiting[#waiting + 1] = waitEntry(m, it)
    end
    local chunks = chunksOf(it)
    it.chunks = #chunks
    it.misses = 0
    for _, c in ipairs(chunks) do
        OA.Chunks.add({ kind = "oa_place", mission = m.id, key = it.key, x = c.x, y = c.y, z = 0 })
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
    -- oa-scan: ok (a found piece not followed, once for each change of the player's things)
    item = inventory:getFirstEvalArgRecurse(missionMatch, Missions.itemId(m, it.key))
    if not item then
        missed[key] = signature
        return nil
    end
    followed[key] = item
    return Game.whereIs(item)
end

-- The piece of a mission in a bag the player picked up, or nil.
function Game.pieceIn(bag, missionId)
    -- oa-scan: ok (a bag picked up while a piece is still to be found)
    return bag:getInventory():getFirstEvalArgRecurse(missionMatch, missionId)
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
    -- oa-scan: ok (a burning container, while a mission runs)
    local found = container:getAllEvalRecurse(anyMission, ArrayList.new())
    local done = {}
    for i = 0, found:size() - 1 do
        local id = found:get(i):getModData().OA_Mission
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

-- A square a zombie may stand on: free, with a floor, not water or stairs; outdoors unless `indoors`.
local function openSquare(sq, indoors)
    return sq ~= nil and sq:getFloor() ~= nil and sq:isFree(false) and not sq:isWaterSquare() and not sq:HasStairs()
        and (indoors or sq:isOutside())
end

local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- The open squares of the circle that are joined to the one nearest its middle (a walled yard or a roof is not part of
-- it), outdoors first: { square, ... }. Every open square of the circle when none is joined.
local function openSquares(area, indoors)
    local c = getCell()
    local open, nearest, nearestD = {}, nil, nil
    local r = area.r
    for dx = -r, r do
        for dy = -r, r do
            local d = dx * dx + dy * dy
            if d <= r * r then
                local sq = c:getGridSquare(area.x + dx, area.y + dy, 0)
                if openSquare(sq, indoors) then
                    local key = dx .. "," .. dy
                    open[key] = sq
                    if not nearestD or d < nearestD then nearest, nearestD = key, d end
                end
            end
        end
    end
    local list = {}
    if not nearest then return list end
    local seen, queue, head = { [nearest] = true }, { nearest }, 1
    while head <= #queue do
        local key = queue[head]
        head = head + 1
        local sq = open[key]
        list[#list + 1] = sq
        local dx, dy = sq:getX() - area.x, sq:getY() - area.y
        for _, s in ipairs(STEPS) do
            local k2 = (dx + s[1]) .. "," .. (dy + s[2])
            local next2 = open[k2]
            if next2 and not seen[k2] and not sq:isBlockedTo(next2) then
                seen[k2] = true
                queue[#queue + 1] = k2
            end
        end
    end
    return list
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
