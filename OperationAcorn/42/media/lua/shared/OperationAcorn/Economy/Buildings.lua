-- The building a character stands in, and how many of its containers were searched (DESIGN 12, "털이 기록").
-- A container counts as searched when the player has opened it (ItemContainer:isExplored). The containers of a
-- building are counted once when the character comes into it and kept; after that a visit only asks each of them
-- whether it was opened. Nothing runs per tick: the server wiring calls Buildings.tick for each player once a game
-- minute, and a window may call it as it likes.
--
-- With the PZ Tools API the building and its rooms come from it (buildings.at, buildings.rooms: a stable key and
-- the squares of every room, player-built buildings known as such); without it, from the game's BuildingDef and
-- rooms (the dev fallback; the mod itself needs the API). A building with a square not loaded is not judged. A
-- player-built building is never counted, nor is a container the player made.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Buildings = {}
OA.Buildings = Buildings

local states = {}      -- by player number: { key, containers, complete }

-- The containers of the objects on a square, into `into`. Containers the player built (IsoThumpable) are left out.
local function collect(square, into)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local count = object:getContainerCount()
        if count > 0 and not instanceof(object, "IsoThumpable") then
            for j = 0, count - 1 do
                local container = object:getContainerByIndex(j)
                if container then table.insert(into, container) end
            end
        end
    end
end

-- The building at a square: { key, containers, complete }, or nil outside any building or in one the player built.
-- `room` is the square's vanilla room (the caller has it), used when the API is missing.
function Buildings.scan(square, room)
    local containers = {}
    local complete = true
    local api = OA.api()
    if api and api.buildings then
        local b = api.buildings.at(square:getX(), square:getY(), square:getZ())
        if not b or b.playerBuilt then return nil end
        local rooms = api.buildings.rooms(b.key)
        if not rooms then return nil end
        local cell = getCell()
        for _, r in ipairs(rooms) do
            for _, rect in ipairs(r.rects) do
                for x = rect.x, rect.x + rect.w - 1 do
                    for y = rect.y, rect.y + rect.h - 1 do
                        local sq = cell:getGridSquare(x, y, r.level)
                        if sq then collect(sq, containers) else complete = false end
                    end
                end
            end
        end
        return { key = tostring(b.key), containers = containers, complete = complete }
    end
    if not room then return nil end
    local building = room:getBuilding()
    local def = building and building:getDef()
    if not def then return nil end
    if not def:isFullyStreamedIn() then complete = false end
    local roomDefs = def:getRooms()
    for i = 0, roomDefs:size() - 1 do
        local iso = roomDefs:get(i):getIsoRoom()
        if iso then
            local squares = iso:getSquares()
            for j = 0, squares:size() - 1 do collect(squares:get(j), containers) end
        else
            complete = false
        end
    end
    return { key = "v:" .. tostring(def:getX()) .. "," .. tostring(def:getY()), containers = containers,
        complete = complete }
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
-- whether every square of the building is loaded; nil when the character is outside. The first look in a building
-- counts its containers; the next ones only ask them.
function Buildings.tick(character)
    local number = character:getPlayerNum()
    local square = character:getCurrentSquare()
    local room = square and square:getRoom()
    local key = room and Buildings.keyAt(square, room) or nil
    if not key then
        states[number] = nil
        return nil
    end
    local state = states[number]
    if not state or state.key ~= key then
        local scanned = Buildings.scan(square, room)
        if not scanned then
            states[number] = nil
            return nil
        end
        state = { key = scanned.key, containers = scanned.containers, complete = scanned.complete }
        states[number] = state
    elseif not state.complete then
        -- A building that was not all loaded is counted again until it is.
        local scanned = Buildings.scan(square, room)
        if scanned and scanned.key == state.key then
            state.containers, state.complete = scanned.containers, scanned.complete
        end
    end
    return state.key, Buildings.searched(state.containers), #state.containers, state.complete
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
