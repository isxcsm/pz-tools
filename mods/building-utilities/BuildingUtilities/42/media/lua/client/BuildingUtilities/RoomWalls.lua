-- Rooms that follow the walls. A map building's rooms are the map's whatever happens to its walls (the game remakes the
-- rooms of the buildings players build, never a map building's): a wall taken down left two rooms where one stands, a
-- wall built across a room left one. The map building the player is in is watched (PZExtAPI.squares); when a wall
-- between its squares is taken down or built, its rooms are worked out again and given to it
-- (PZExtAPI.buildings.setRooms, which the game keeps with the save). Two rooms a wall taken down opens to each other
-- become one; a room a new wall cuts in two becomes two. What the map has stays: an open kitchen beside the living room
-- stays the kitchen, and a room with a wall of its own inside stays one room.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local RoomWalls = {}
BU.RoomWalls = RoomWalls

-- A square's walls as a code: its north side (to the square north of it) 1, its west side 2.
local NORTH, WEST = 1, 2
-- The most squares one watch holds (the API's limit), and the most a building watched has (two watches).
local WATCH_MAX = 16384
RoomWalls.MAX_SQUARES = 2 * WATCH_MAX
-- Ticks between looks at where the player is, and the squares beyond the building's box the watch is kept.
local LOOK_EVERY, LEAVE = 30, 4

local function hasNorth(code) return code == 1 or code == 3 end
local function hasWest(code) return code >= 2 end

-- A square's place as one number (exact in a double): its level, row and column.
function RoomWalls.place(x, y, z) return ((z + 64) * 65536 + y) * 65536 + x end

-- Which sides of a square have a wall, as the game's regions tell the walls of a room (IsoRegions.calculateSquareFlags):
-- a wall or a window's, a door frame. A corner post (WallSE) leaves the west side open, as there.
function RoomWalls.sides(square)
    local code = 0
    if square:has(IsoFlagType.cutN) or square:has(IsoObjectType.doorFrN) then code = NORTH end
    if not square:has(IsoFlagType.WallSE) and (square:has(IsoFlagType.cutW) or square:has(IsoObjectType.doorFrW)) then
        code = code + WEST
    end
    return code
end

-- The squares of a building's rooms (the API's rooms(key)): { [place] = room index }, with each square's x, y, z, and
-- each room's size; nil past MAX_SQUARES.
function RoomWalls.footprint(rooms)
    local owner, squares, sizes = {}, {}, {}
    for index, room in ipairs(rooms) do
        local z = room.level
        sizes[index] = 0
        for _, rect in ipairs(room.rects) do
            for y = rect.y, rect.y + rect.h - 1 do
                for x = rect.x, rect.x + rect.w - 1 do
                    local place = RoomWalls.place(x, y, z)
                    if not owner[place] then
                        owner[place] = index
                        sizes[index] = sizes[index] + 1
                        squares[#squares + 1] = { x = x, y = y, z = z, place = place }
                        if #squares > RoomWalls.MAX_SQUARES then return nil end
                    end
                end
            end
        end
    end
    return { owner = owner, squares = squares, sizes = sizes }
end

-- Squares of one level as rectangles: runs along x, each grown down while the next row has the same run.
function RoomWalls.rects(squares)
    local rows, minY, maxY = {}, nil, nil
    for _, square in ipairs(squares) do
        local row = rows[square.y]
        if not row then
            row = {}
            rows[square.y] = row
        end
        row[#row + 1] = square.x
        minY = minY and math.min(minY, square.y) or square.y
        maxY = maxY and math.max(maxY, square.y) or square.y
    end
    local result, open = {}, {}
    for y = minY, maxY do
        local row, now = rows[y], {}
        if row then
            table.sort(row)
            local start, last = row[1], row[1]
            for i = 2, #row + 1 do
                local x = row[i]
                if x ~= last + 1 then
                    local runKey = start .. ":" .. (last - start + 1)
                    local rect = open[runKey]
                    if rect and rect.y + rect.h == y then
                        rect.h = rect.h + 1
                    else
                        rect = { x = start, y = y, w = last - start + 1, h = 1 }
                        result[#result + 1] = rect
                    end
                    now[runKey] = rect
                    start = x
                end
                last = x
            end
        end
        open = now
    end
    return result
end

-- The rooms the walls make of the building's squares, as setRooms takes them, or nil when they are the rooms it has.
-- now[place] and before[place] are each square's walls now and when last seen. Two squares side by side are one room
-- when of the same room, unless a wall was built between them since; or of two rooms when the wall between them was
-- taken down since.
function RoomWalls.partition(rooms, shape, now, before)
    local owner, squares, sizes = shape.owner, shape.squares, shape.sizes
    local parent = {}
    local function find(place)
        local root = place
        while parent[root] and parent[root] ~= root do root = parent[root] end
        while place ~= root do
            local up = parent[place]
            parent[place] = root
            place = up
        end
        return root
    end
    local function join(a, b)
        local ra, rb = find(a), find(b)
        if ra ~= rb then parent[ra] = rb end
    end
    local function joined(place, other, wallNow, wallBefore)
        if owner[place] == owner[other] then return not (wallNow and not wallBefore) end
        return wallBefore and not wallNow
    end
    for _, square in ipairs(squares) do
        local place = square.place
        parent[place] = parent[place] or place
        local code, was = now[place] or 0, before[place] or 0
        local north, west = place - 65536, place - 1
        if owner[north] and joined(place, north, hasNorth(code), hasNorth(was)) then join(place, north) end
        if owner[west] and joined(place, west, hasWest(code), hasWest(was)) then join(place, west) end
    end
    local groups, order = {}, {}
    for _, square in ipairs(squares) do
        local root = find(square.place)
        local group = groups[root]
        if not group then
            group = { squares = {}, room = owner[square.place], same = true }
            groups[root] = group
            order[#order + 1] = group
        end
        group.squares[#group.squares + 1] = square
        if owner[square.place] ~= group.room then group.same = false end
    end
    local changed = #order ~= #rooms
    for _, group in ipairs(order) do
        if not group.same or #group.squares ~= sizes[group.room] then changed = true end
    end
    if not changed then return nil end
    local result = {}
    for _, group in ipairs(order) do
        result[#result + 1] = { level = rooms[group.room].level, rects = RoomWalls.rects(group.squares) }
    end
    return result
end

-- The building watched: { key, version, rooms, shape, before = walls when last seen, now = walls as told, watches,
-- box }; or one waiting for its squares to load ({ key, waiting = true, box }).
local watched, dirty, anyDirty, ticks, seenBuilding = nil, {}, false, 0, nil

local function api()
    local found = BU.api()
    if found and found.squares and found.buildings.setRooms then return found end
    return nil
end

local function onChanged(_, x, y, z)
    dirty[RoomWalls.place(x, y, z)] = { x = x, y = y, z = z }
    anyDirty = true
end

local function unwatch(found, handle)
    if watched and watched.watches then
        for _, id in ipairs(watched.watches) do found.squares.unwatch(handle, id) end
    end
    watched, dirty, anyDirty = nil, {}, false
end

-- The building's rooms and walls read again (all its squares loaded), or false.
local function read(found, key)
    local rooms = found.buildings.rooms(key)
    local shape = rooms and RoomWalls.footprint(rooms)
    if not shape then return false end
    local cell, walls = getCell(), {}
    for _, square in ipairs(shape.squares) do
        local loaded = cell:getGridSquare(square.x, square.y, square.z)
        if not loaded then return false end
        walls[square.place] = RoomWalls.sides(loaded)
    end
    return rooms, shape, walls
end

local function copy(walls)
    local result = {}
    for place, code in pairs(walls) do result[place] = code end
    return result
end

local function start(found, handle, info)
    unwatch(found, handle)
    local box = { info.minX - LEAVE, info.minY - LEAVE, info.maxX + LEAVE, info.maxY + LEAVE }
    local rooms, shape, walls = read(found, info.key)
    if not rooms then
        watched = { key = info.key, waiting = true, box = box }
        return
    end
    watched = { key = info.key, version = found.buildings.version(), rooms = rooms, shape = shape, before = walls,
        now = copy(walls), watches = {}, box = box }
    local list = {}
    local function flush()
        if #list > 0 then watched.watches[#watched.watches + 1] = found.squares.watch(handle, list, onChanged) end
        list = {}
    end
    for _, square in ipairs(shape.squares) do
        list[#list + 1] = square.x
        list[#list + 1] = square.y
        list[#list + 1] = square.z
        if #list >= WATCH_MAX * 3 then flush() end
    end
    flush()
end

-- The walls of the squares told changed; when one differs from what was last seen, the rooms worked out again.
local function settle(found)
    local cell, differs = getCell(), false
    for place, at in pairs(dirty) do
        local loaded = cell:getGridSquare(at.x, at.y, at.z)
        if loaded and watched.now[place] ~= nil then
            local code = RoomWalls.sides(loaded)
            watched.now[place] = code
            if code ~= watched.before[place] then differs = true end
        end
    end
    dirty, anyDirty = {}, false
    if not differs then return end
    if found.buildings.version() ~= watched.version then
        -- the building changed otherwise (another mod, the game's editor): its rooms as they are now
        local rooms = found.buildings.rooms(watched.key)
        local shape = rooms and RoomWalls.footprint(rooms)
        if not shape then return unwatch(found, BU.handle()) end
        watched.rooms, watched.shape = rooms, shape
    end
    local wanted = RoomWalls.partition(watched.rooms, watched.shape, watched.now, watched.before)
    if wanted then
        local done, why = found.buildings.setRooms(watched.key, wanted)
        if not done then BU.log("rooms not set for", watched.key, why) end
        local rooms = found.buildings.rooms(watched.key)
        local shape = rooms and RoomWalls.footprint(rooms)
        if not shape then return unwatch(found, BU.handle()) end
        watched.rooms, watched.shape = rooms, shape
    end
    watched.before = copy(watched.now)
    watched.version = found.buildings.version()
end

-- Where the player is: the map building they are in is watched; one they left far behind is not.
local function look(found, handle)
    local player = getPlayer()
    local square = player and player:getCurrentSquare()
    if not square then return end
    local building = square:getBuilding()
    if building and building ~= seenBuilding then
        seenBuilding = building
        local info = found.buildings.at(square:getX(), square:getY(), square:getZ())
        if info and not info.playerBuilt and not (watched and watched.key == info.key and not watched.waiting) then
            start(found, handle, info)
        end
        return
    end
    if watched and watched.waiting and building then
        local info = found.buildings.at(square:getX(), square:getY(), square:getZ())
        if info and info.key == watched.key then start(found, handle, info) end
        return
    end
    if watched and not building then
        local x, y, box = square:getX(), square:getY(), watched.box
        if x < box[1] or y < box[2] or x > box[3] or y > box[4] then
            unwatch(found, handle)
            seenBuilding = nil
        end
    end
end

local function onTick()
    ticks = ticks + 1
    if not anyDirty and ticks < LOOK_EVERY then return end
    local found = api()
    local handle = found and BU.handle()
    if not handle then return end
    if anyDirty and watched and not watched.waiting then settle(found) end
    if ticks >= LOOK_EVERY then
        ticks = 0
        look(found, handle)
    end
end

Events.OnTick.Add(onTick)

return RoomWalls
