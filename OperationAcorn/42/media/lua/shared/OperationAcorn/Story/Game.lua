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
local OA = OperationAcorn
local Data, Missions = OA.StoryData, OA.Missions
local Game = {}
OA.StoryGame = Game

-- ---------------------------------------------------------------------------------------------------------------
-- The map's buildings.

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
    local ok = b:getArea() >= 30 and not b:isBasement()
    return x, y, ok
end

function Game.buildingInfo(i)
    local b = buildings():get(i - 1)
    local z1, z2 = b:getMinLevel(), b:getMaxLevel()
    local z = 0
    if z1 > 0 then z = z1 elseif z2 < 0 then z = z2 end
    return {
        x = math.floor((b:getX() + b:getX2()) / 2), y = math.floor((b:getY() + b:getY2()) / 2), z = z,
        x1 = b:getX(), y1 = b:getY(), x2 = b:getX2() - 1, y2 = b:getY2() - 1, z1 = z1, z2 = z2,
    }
end

-- Is there a building at the square (the bunker's cellar may not be one the map data gives us).
function Game.buildingExists(x, y, z)
    local ok, def = pcall(function() return getWorld():getMetaGrid():getBuildingAt(x, y, z) end)
    return ok and def ~= nil
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

local function predicateMission(item, id)
    return missionMatch(item, id)
end

function Game.findItem(record, missionId)
    local p = Game.character(record)
    if not p then return nil end
    return p:getInventory():getFirstEvalArgRecurse(predicateMission, missionId)
end

function Game.hasItem(record, name)
    local p = Game.character(record)
    return p ~= nil and p:getInventory():containsTypeRecurse(Data.fullType(name))
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
    local item = character:getInventory():getFirstEvalArgRecurse(predicateMission, missionId)
    if not item then return false end
    removeFrom(item:getContainer(), item)
    return true
end

-- A new item with the mission's marks on it (OA_Mission is what the economy reads), its name made specific when it
-- carries a serial.
local function newItem(record, m, it)
    local item = InventoryItemFactory.CreateItem(it.type)
    if not item then
        OA.log("cannot make", it.type)
        return nil
    end
    local md = item:getModData()
    if not it.plain then
        md.OA_Mission = Missions.itemId(m, it.key)
        md.OA_Owner = record.id
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

function Game.giveMissionItem(character, fullType, missionId, mods)
    local item = InventoryItemFactory.CreateItem(fullType)
    if not item then return nil end
    local md = item:getModData()
    md.OA_Mission = missionId
    for k, v in pairs(mods or {}) do md[k] = v end
    local inv = character:getInventory()
    inv:AddItem(item)
    if isServer() then sendAddItemToContainer(inv, item) end
    return item
end

-- The cooler's warmth where the player can see it: its tooltip.
function Game.setCoolerText(item, temp)
    item:setTooltip(getText("Tooltip_OA_Story_CoolerTemp", string.format("%.1f", temp)))
end

-- The helicopter's noise, as the economy's option says how far it carries.
function Game.noise(record, x, y, z)
    local radius = OA.option("HelicopterNoiseRadius") or 100
    if radius <= 0 then return end
    addSound(Game.character(record), math.floor(x), math.floor(y), math.floor(z or 0), radius, radius)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Placing.

-- The pieces still waiting for a container as they fill: { { mission = id, key = key } }.
local waiting = {}
local seen = {}

local function findPiece(missionId, key)
    for _, record in pairs(OA.Store.players()) do
        local m = record.missions and record.missions.active
        if m and m.id == missionId then
            for _, it in ipairs(m.items) do
                if it.key == key then return record, m, it end
            end
        end
    end
    return nil
end

local function cell()
    return getCell()
end

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
    local c = cell()
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

-- Every container with room for the piece in the loaded part of the building: { { container, square, room } }.
local function containersFor(it)
    local found = {}
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
                        found[#found + 1] = { container = c, square = sq, room = room and room:getName() or nil }
                    end
                end
            end
        end
    end)
    return found
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
    local c = cell()
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

local function dropOnFloor(sq, item)
    local wi = sq:AddWorldInventoryItem(item, 0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), 0)
    if wi and wi.getWorldItem and wi:getWorldItem() then
        pcall(function() wi:getWorldItem():setIgnoreRemoveSandbox(true) end)
    end
    return wi
end

-- Locks the doors of the room a piece went into, with the building's key: and places the key in another container
-- of the building, so that a way in always exists.
local function lockRoom(record, m, it, sq)
    local room = sq:getRoom()
    if not room then return end
    local locked = 0
    local squares = room:getSquares()
    local c = cell()
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
                    o:setLockedByKey(true)
                    locked = locked + 1
                end
            end
        end
    end
    if locked == 0 then return end
    local building = sq:getBuilding()
    local keyIt = {
        key = "KEY", type = "Base.Key1", mode = "container", plain = true, placed = false,
        x = it.x, y = it.y, z = it.z, x1 = it.x1, y1 = it.y1, x2 = it.x2, y2 = it.y2, z1 = it.z1, z2 = it.z2,
        avoidRoom = room:getName(), keyId = building:getKeyId(), mods = {},
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
            local inner = InventoryItemFactory.CreateItem(Data.fullType(it.inside))
            if inner then
                local md = inner:getModData()
                md.OA_Mission = Missions.itemId(m, "A")
                md.OA_Owner = record.id
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

-- Asks for the piece to be placed: now if its place is loaded, otherwise when it loads or its containers fill.
function Game.request(record, m, it)
    if it.placed then return end
    if Game.tryPlace(record, m, it) then return end
    if it.mode == "container" then
        waiting[#waiting + 1] = { mission = m.id, key = it.key }
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
        if waiting[i].mission == missionId and (key == nil or waiting[i].key == key) then table.remove(waiting, i) end
    end
    OA.Chunks.remove(function(e)
        return e.kind == "oa_place" and e.mission == missionId and (key == nil or e.key == key)
    end)
end

-- The mission is over (or sealed): nothing of it waits any more. Items already placed stay in the world.
function Game.release(m)
    Game.unregisterPiece(m.id, nil)
end

-- Memory of what waits for containers is not saved: rebuilt from the records when the world starts.
function Game.rebuildWaiting()
    waiting = {}
    for _, record in pairs(OA.Store.players()) do
        local m = record.missions and record.missions.active
        if m then
            for _, it in ipairs(m.items) do
                if not it.placed and it.mode == "container" then waiting[#waiting + 1] = { mission = m.id, key = it.key } end
            end
        end
    end
end

-- OnFillContainer: a container of a building a piece waits for is filling. The first containers are taken with a
-- small chance (the room the piece prefers with a large one), later ones with a larger, so the item lies somewhere in
-- the building and not always in the first.
function Game.onFill(roomName, containerType, container)
    if #waiting == 0 or not container then return end
    local sq = container:getSourceGrid()
    if not sq or not sq:getBuilding() then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for i = #waiting, 1, -1 do
        local w = waiting[i]
        local record, m, it = findPiece(w.mission, w.key)
        if not it or it.placed then
            table.remove(waiting, i)
        elseif inBox(it, x, y, z) then
            local n = (seen[w.mission .. w.key] or 0) + 1
            seen[w.mission .. w.key] = n
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
-- The record in the drop case.

-- The record appears in the case at the drop (or in the player's hands when the case is gone).
function Game.deliverInside(record, m, it)
    local caseIt
    for _, p in ipairs(m.items) do
        if p.key == "CASE" then caseIt = p end
    end
    local item
    if caseIt and caseIt.at then
        local sq = cell():getGridSquare(caseIt.at.x, caseIt.at.y, caseIt.at.z)
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
            Game.giveMissionItem(character, it.type, Missions.itemId(m, it.key), it.mods)
        end
    end
    it.placed = true
end

return Game
