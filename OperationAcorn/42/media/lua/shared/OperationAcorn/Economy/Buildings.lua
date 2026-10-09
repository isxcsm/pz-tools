-- The building a character stands in, and how many of its containers were searched (DESIGN 12, "털이 기록").
-- A container counts as searched when the player has opened it (ItemContainer:isExplored). The containers of a
-- building are counted when the character comes into it, a part at a time (Buildings.BUDGET squares a look), and
-- kept; after that a look only asks the ones not opened yet. Nothing runs per tick: the server wiring calls
-- Buildings.tick for each player once a game minute, and a window may call it as it likes.
--
-- With the PZ Tools API the building and its rooms come from it (buildings.at, buildings.rooms: a stable key and
-- the squares of every room, player-built buildings known as such); without it, from the game's BuildingDef and
-- rooms (the dev fallback; the mod itself needs the API). A building with a square not loaded is not judged. A
-- player-built building is never counted, nor is a container the player made.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Buildings = {}
OA.Buildings = Buildings

-- The modData key the mod's own objects carry (Objects.KIND): their containers are not the building's.
local MOD_KIND = "OA_Kind"

local states = {}      -- by player number: the walk over the building the character is in (see newWalk)

-- Squares one look visits at most. A big building (an office of some 20,000 squares and 1,900 containers) is counted
-- over several minutes instead of in one long frame: found in game, 120 ms for a look, and every minute while part of
-- it was not loaded, because the whole building was counted again.
Buildings.BUDGET = 200

-- A walk over the squares of the building at a square, counted a part at a time (stepWalk): nil outside any building
-- or in one the player built. `room` is the square's vanilla room (the caller has it), used when the API is missing.
-- The API gives the rooms as rects; without it the walk goes over the vanilla rooms' squares.
local function newWalk(square, room)
    local walk = { seen = {}, list = {}, open = {}, total = 0, explored = 0, complete = false, part = 1, at = 0 }
    local api = OA.api()
    if api and api.buildings then
        local b = api.buildings.at(square:getX(), square:getY(), square:getZ())
        if not b or b.playerBuilt then return nil end
        local rooms = api.buildings.rooms(b.key)
        if not rooms then return nil end
        local rects = {}
        for _, r in ipairs(rooms) do
            for _, rect in ipairs(r.rects) do
                rects[#rects + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h, z = r.level }
            end
        end
        walk.key, walk.rects, walk.missing, walk.keep, walk.mAt = tostring(b.key), rects, {}, {}, 1
        return walk
    end
    if not room then return nil end
    local building = room:getBuilding()
    local def = building and building:getDef()
    if not def then return nil end
    walk.key = "v:" .. tostring(def:getX()) .. "," .. tostring(def:getY())
    walk.def, walk.defs, walk.part = def, def:getRooms(), 0
    return walk
end

-- The containers of the objects on a square, into the walk (each once). Containers the player built (IsoThumpable)
-- are left out.
local function collect(walk, square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local count = object:getContainerCount()
        -- not a player-built one (IsoThumpable), nor one of the mod's own (a delivery box or a crate, OA_Kind)
        if count > 0 and not instanceof(object, "IsoThumpable") and not (object:hasModData() and object:getModData()[MOD_KIND]) then
            for j = 0, count - 1 do
                local container = object:getContainerByIndex(j)
                if container and not walk.seen[container] then
                    walk.seen[container] = true
                    walk.list[#walk.list + 1] = container
                    walk.total = walk.total + 1
                    if container:isExplored() then
                        walk.explored = walk.explored + 1
                    else
                        walk.open[#walk.open + 1] = container
                    end
                end
            end
        end
    end
end

-- The API walk: the rects square by square, then the squares that were not loaded, again and again until none is
-- left (only those: a loaded square is never looked at twice).
local function stepRects(walk, budget)
    local cell = getCell()
    local rects = walk.rects
    while budget > 0 and walk.part <= #rects do
        local r = rects[walk.part]
        local n = r.w * r.h
        while budget > 0 and walk.at < n do
            local row = math.floor(walk.at / r.w)
            local x, y = r.x + (walk.at - row * r.w), r.y + row
            local sq = cell:getGridSquare(x, y, r.z)
            if sq then
                collect(walk, sq)
            else
                local m = walk.missing
                m[#m + 1] = x; m[#m + 1] = y; m[#m + 1] = r.z
            end
            walk.at = walk.at + 1
            budget = budget - 1
        end
        if walk.at >= n then walk.part, walk.at = walk.part + 1, 0 end
    end
    if walk.part <= #rects then return end
    if not walk.walked then
        -- the walk ended in this look: what was not loaded is looked at again from the next one
        walk.walked = true
        walk.complete = #walk.missing == 0
        return
    end
    local m, keep = walk.missing, walk.keep
    while budget > 0 and walk.mAt <= #m do
        local x, y, z = m[walk.mAt], m[walk.mAt + 1], m[walk.mAt + 2]
        local sq = cell:getGridSquare(x, y, z)
        if sq then
            collect(walk, sq)
        else
            keep[#keep + 1] = x; keep[#keep + 1] = y; keep[#keep + 1] = z
        end
        walk.mAt = walk.mAt + 3
        budget = budget - 1
    end
    if walk.mAt > #m then
        walk.missing, walk.keep, walk.mAt = keep, {}, 1
    end
    walk.complete = #walk.missing == 0
end

-- The vanilla walk: room by room. A room not loaded, or a building the game says is not all streamed in, makes the
-- walk start over (what was found stays found).
local function stepRooms(walk, budget)
    local defs = walk.defs
    while budget > 0 and walk.part < defs:size() do
        local iso = defs:get(walk.part):getIsoRoom()
        if iso then
            local squares = iso:getSquares()
            for j = 0, squares:size() - 1 do collect(walk, squares:get(j)) end
            budget = budget - math.max(1, squares:size())
        else
            walk.roomMissing = true
            budget = budget - 1
        end
        walk.part = walk.part + 1
    end
    if walk.part < defs:size() then return end
    if not walk.roomMissing and walk.def:isFullyStreamedIn() then
        walk.complete = true
        return
    end
    walk.complete = false
    walk.part, walk.roomMissing = 0, false
end

local function stepWalk(walk, budget)
    if walk.complete then return end
    if walk.rects then stepRects(walk, budget) else stepRooms(walk, budget) end
end

-- The building at a square, counted whole in one go: { key, containers, complete }, or nil (see newWalk). For checks
-- and tools; the watch itself counts a part at a time (Buildings.tick).
function Buildings.scan(square, room)
    local walk = newWalk(square, room)
    if not walk then return nil end
    stepWalk(walk, math.huge)
    return { key = walk.key, containers = walk.list, complete = walk.complete }
end

-- How many of a list of containers were opened.
function Buildings.searched(containers)
    local n = 0
    for i = 1, #containers do
        if containers[i]:isExplored() then n = n + 1 end
    end
    return n
end

-- One look at the building a character stands in (call it about once a minute): returns key, searched, total and
-- whether every square of the building has been counted; nil when the character is outside. A look counts up to
-- BUDGET more squares of the building and asks the containers not opened yet whether they are now (an opened one
-- stays opened, so it is not asked again).
function Buildings.tick(character)
    local number = character:getPlayerNum()
    local square = character:getCurrentSquare()
    local room = square and square:getRoom()
    local key = room and Buildings.keyAt(square, room) or nil
    if not key then
        states[number] = nil
        return nil
    end
    local walk = states[number]
    if not walk or walk.key ~= key then
        walk = newWalk(square, room)
        states[number] = walk
        if not walk then return nil end
    end
    stepWalk(walk, Buildings.BUDGET)
    local open = walk.open
    for i = #open, 1, -1 do
        if open[i]:isExplored() then
            open[i] = open[#open]
            open[#open] = nil
            walk.explored = walk.explored + 1
        end
    end
    return walk.key, walk.explored, walk.total, walk.complete
end

-- The key of the building at a square (the room is its vanilla room, or nil), or nil outside a building or in one
-- the player built.
function Buildings.keyAt(square, room)
    local api = OA.api()
    if api and api.buildings then
        local b = api.buildings.at(square:getX(), square:getY(), square:getZ())
        return b and not b.playerBuilt and tostring(b.key) or nil
    end
    room = room or square:getRoom()
    local building = room and room:getBuilding()
    local def = building and building:getDef()
    return def and ("v:" .. tostring(def:getX()) .. "," .. tostring(def:getY())) or nil
end

-- Forget what is cached (a new character, a test).
function Buildings.reset()
    states = {}
end

return Buildings
