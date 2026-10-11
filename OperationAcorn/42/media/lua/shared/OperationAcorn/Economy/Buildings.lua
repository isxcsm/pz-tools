-- The building a character stands in, and how many of its containers were searched (DESIGN 12, "털이 기록").
-- A container counts as searched when the player's loot window has shown it: the mod marks its object then
-- (Buildings.mark, OA_Searched in its mod data). Not the game's ItemContainer:isExplored, which the game sets when it
-- rolls the loot, in single player as soon as the square first loads: a house reached for the first time would read as
-- all searched. The containers of a building are counted when the character comes into it, a part at a time
-- (Buildings.BUDGET squares a look), and kept; after that a look only asks the ones not opened yet. Nothing runs per
-- tick or on a clock: the search watch (client/OperationAcorn/Economy/Searched.lua) calls Buildings.tick when the
-- character comes into a building and when the loot window marks a container, both told by the loot window's own
-- refresh.
--
-- With the PZ Tools API the building comes from it (buildings.at: a stable key, player-built buildings known as such)
-- and so do its containers (buildings.containers: the squares walked in Java in one call, which lists only the
-- containers whose item count or opened flag changed since the last look, so a look makes next to no tables and a
-- counted building costs no call into the game for each container). An API without that call gives the rooms'
-- squares (buildings.rooms), walked in Lua a part at a time; without the API they come from the game's BuildingDef and
-- rooms (the dev fallback; the mod itself needs the API). A building with a square not loaded is not judged. A
-- player-built building is never counted, nor is a container the player made.
--
-- A basement is a building of its own to the game (Build 42 places it under a house as another BuildingDef, all of it
-- below ground) and so to the API. Here it is part of the house above it: with the API, the key of either is the
-- house's and the walk goes over both (one part each, Buildings.group), so going down the stairs is another floor of
-- the same building.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Buildings = {}
OA.Buildings = Buildings

-- The modData key the mod's own objects carry (Objects.KIND): their containers are not the building's.
local MOD_KIND = "OA_Kind"
-- The modData key an object gets once the player's loot window has shown its containers (Buildings.mark).
local SEARCHED = "OA_Searched"
Buildings.SEARCHED = SEARCHED

-- Whether the player has looked into a container: its object carries the mark (all the containers of one object, such
-- as a fridge and its freezer, are shown together).
function Buildings.opened(container)
    local object = container:getParent()
    return object ~= nil and object:hasModData() and object:getModData()[SEARCHED] ~= nil
end

-- Marks a container's object as looked into, when it is a world object (not a car, a body, a bag): true when it was
-- not marked before. The loot window calls it for each container it shows; an object marked already is left as it is
-- (its mod data not touched).
function Buildings.mark(container)
    local object = container:getParent()
    if not object or not instanceof(object, "IsoObject") or instanceof(object, "IsoMovingObject") then return false end
    if object:hasModData() and object:getModData()[SEARCHED] ~= nil then return false end
    object:getModData()[SEARCHED] = true
    return true
end

-- Takes the mark away (the dev tools' search reset).
function Buildings.unmark(container)
    local object = container:getParent()
    if object and object:hasModData() then object:getModData()[SEARCHED] = nil end
end

local states = {}      -- by player number: the walk over the building the character is in (see newWalk)
local left = {}        -- by player number: the walk of the building the character was in before (Buildings.counts)

-- Squares one look visits at most. A big building (an office of some 20,000 squares and 1,900 containers) is counted
-- over several minutes instead of in one long frame: found in game, 120 ms for a look, and every minute while part of
-- it was not loaded, because the whole building was counted again.
Buildings.BUDGET = 200

-- What the API's containers are asked for every look: not a player-built object (IsoThumpable), nor one of the mod's
-- own (MOD_KIND). `since` and `into` change from look to look.
local function apiOptions()
    return { skipClasses = "IsoThumpable", skipData = MOD_KIND, openedData = SEARCHED, into = {} }
end

-- Buildings (by key) the API's containers could not be used for, and whether the call itself failed: the Lua walk.
local noContainers, containersFailed = {}, false

-- ---- a house and its basements ----------------------------------------------------------------------------------

local groups = {}      -- the API's key (as a string) -> { key = the house's, raws = the API keys of the house and its basements }
local nearDefs = nil   -- an ArrayList used again for the game's buildings around a def

-- The vanilla buildings that touch a def or lie within a square of it.
local function defsAround(def)
    nearDefs = nearDefs or ArrayList.new()
    nearDefs:clear()
    getWorld():getMetaGrid():getBuildingsIntersecting(def:getX() - 1, def:getY() - 1, def:getW() + 2, def:getH() + 2,
        nearDefs)
    return nearDefs
end

-- The one building above ground a basement (a building all below ground) lies under; nil when there is none or more.
local function houseOf(def)
    local found = nil
    local around = defsAround(def)
    for i = 0, around:size() - 1 do
        local d = around:get(i)
        if d:getMinLevel() >= 0 then
            if found then return nil end
            found = d
        end
    end
    return found
end

-- The API's key of a vanilla building, from a square of its first room; nil for one the player built.
local function rawOf(api, def)
    local rooms = def:getRooms()
    if rooms:size() == 0 then return nil end
    local room = rooms:get(0)
    local rects = room:getRects()
    if rects:size() == 0 then return nil end
    local rect = rects:get(0)
    local b = api.buildings.at(rect:getX(), rect:getY(), room:getZ())
    return b and not b.playerBuilt and b.key or nil
end

-- The group of a house (its def and API key): the house and the basements that lie under it alone.
local function houseGroup(api, house, raw)
    local g = { key = tostring(raw), raws = { raw } }
    local around = defsAround(house)
    local basements = {}
    for i = 0, around:size() - 1 do
        local d = around:get(i)
        if d:getMaxLevel() < 0 then basements[#basements + 1] = d end
    end
    for _, d in ipairs(basements) do
        if houseOf(d) == house then
            local r = rawOf(api, d)
            if r then g.raws[#g.raws + 1] = r end
        end
    end
    for _, r in ipairs(g.raws) do groups[tostring(r)] = g end
    return g
end

-- The group of the building the API named at a square (b: its answer to buildings.at): a basement goes with the house
-- above it, a house brings its basements. Worked out once a building (the game's buildings around it asked then).
function Buildings.group(api, b, square)
    local k = tostring(b.key)
    local g = groups[k]
    if g then return g end
    local building = square:getBuilding()
    local def = building and building:getDef()
    if def and def:getMaxLevel() < 0 then
        local house = houseOf(def)
        local raw = house and rawOf(api, house)
        if raw then
            g = houseGroup(api, house, raw)
            if groups[k] == g then return g end
        end
    elseif def then
        return houseGroup(api, def, b.key)
    end
    g = { key = k, raws = { b.key } }
    groups[k] = g
    return g
end

-- A walk over the squares of the building at a square, counted a part at a time (stepWalk): nil outside any building
-- or in one the player built. `room` is the square's vanilla room (the caller has it), used when the API is missing.
-- With the API's containers the walk is one call a look (stepApi) and keeps the unopened containers with the square
-- each stands on (open, ox, oy, oz; `index` finds a container's place). With only the API's rooms (rects) the walk goes
-- square by square; without the API it goes over the vanilla rooms' squares.
local function newWalk(square, room)
    -- floorTotal and floorOpen: the containers and the unopened ones by floor (z), zOf each known container's floor
    local walk = { seen = {}, list = {}, open = {}, total = 0, explored = 0, complete = false, part = 1, at = 0,
        floorTotal = {}, floorOpen = {}, zOf = {} }
    local api = OA.api()
    if api and api.buildings then
        local b = api.buildings.at(square:getX(), square:getY(), square:getZ())
        if not b or b.playerBuilt then return nil end
        local g = Buildings.group(api, b, square)
        if type(api.buildings.containers) == "function" and not containersFailed and not noContainers[g.key] then
            -- a part for each building of the group, each walked by the API as a building alone would be
            walk.key, walk.api, walk.parts = g.key, true, {}
            for i, raw in ipairs(g.raws) do
                walk.parts[i] = { raw = raw, opts = apiOptions(), open = {}, ox = {}, oy = {}, oz = {}, index = {},
                    floorTotal = {}, floorOpen = {}, zOf = {}, total = 0, explored = 0, complete = false }
            end
            return walk
        end
        local rooms = api.buildings.rooms(b.key)
        if not rooms then return nil end
        local rects = {}
        for _, r in ipairs(rooms) do
            for _, rect in ipairs(r.rects) do
                rects[#rects + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h, z = r.level }
            end
        end
        walk.key, walk.rects, walk.missing, walk.keep, walk.mAt = g.key, rects, {}, {}, 1
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
                    local z = square:getZ()
                    walk.zOf[container] = z
                    walk.floorTotal[z] = (walk.floorTotal[z] or 0) + 1
                    if Buildings.opened(container) then
                        walk.explored = walk.explored + 1
                    else
                        walk.open[#walk.open + 1] = container
                        walk.floorOpen[z] = (walk.floorOpen[z] or 0) + 1
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

-- The unopened containers by index (walk.open, with the square of each in ox, oy, oz): one is put in or has its square
-- noted, one is taken out (the last takes its place).
local function openAdd(walk, container, x, y, z)
    local i = walk.index[container]
    if not i then
        i = #walk.open + 1
        walk.open[i] = container
        walk.index[container] = i
        walk.floorOpen[z] = (walk.floorOpen[z] or 0) + 1
    end
    walk.ox[i], walk.oy[i], walk.oz[i] = x, y, z
end

local function openDrop(walk, container)
    local i = walk.index[container]
    if not i then return end
    local z = walk.oz[i]
    walk.floorOpen[z] = (walk.floorOpen[z] or 1) - 1
    local last = #walk.open
    local moved = walk.open[last]
    walk.open[i], walk.ox[i], walk.oy[i], walk.oz[i] = moved, walk.ox[last], walk.oy[last], walk.oz[last]
    walk.index[moved] = i
    walk.open[last], walk.ox[last], walk.oy[last], walk.oz[last] = nil, nil, nil, nil
    walk.index[container] = nil
end

-- Takes in what the API listed: the containers whose count or opened flag changed since the walk's last look (all of
-- them at the first look, and when the API let its stamp go). Seven values each: the container, the square's x, y
-- and z, the type, the item count and whether it was opened.
local STRIDE = 7
local function takeList(walk, list, total)
    if #list >= total * STRIDE then
        -- every container is listed: any kept that is not in the building now (its object was taken away) goes
        walk.open, walk.ox, walk.oy, walk.oz, walk.index = {}, {}, {}, {}, {}
        walk.floorTotal, walk.floorOpen, walk.zOf = {}, {}, {}
    end
    for i = 1, #list, STRIDE do
        local container = list[i]
        if not walk.zOf[container] then
            local z = list[i + 3]
            walk.zOf[container] = z
            walk.floorTotal[z] = (walk.floorTotal[z] or 0) + 1
        end
        if list[i + 6] then
            openDrop(walk, container)
        else
            openAdd(walk, container, list[i + 1], list[i + 2], list[i + 3])
        end
    end
end

-- A look through the API's containers at one part of a walk (a building walked in Java): its counts and its unopened
-- ones. A part counted whole with every container opened has nothing left to look at. False when the API cannot do
-- this look (it failed, or knows no such building): the walk is made in Lua from then on (see tick).
local function stepPart(walk, part)
    if part.complete and part.looked and #part.open == 0 then return true end
    local api = OA.api()
    local fn = api and api.buildings and api.buildings.containers
    if type(fn) ~= "function" then
        containersFailed = true
        return false
    end
    local opts = part.opts
    opts.since = part.stamp
    local ok, list, complete, stamp, total, opened = pcall(fn, part.raw, opts)
    if not ok then
        OA.log("building containers:", tostring(list))
        containersFailed = true
        return false
    end
    if type(list) ~= "table" then
        noContainers[walk.key] = true
        return false
    end
    part.looked = true
    part.stamp, part.total, part.explored, part.complete = stamp, total, opened, complete and true or false
    takeList(part, list, total)
    return true
end

-- A look at every part of an API walk, the walk's counts their sums.
local function stepApi(walk)
    local total, explored, complete = 0, 0, true
    for _, part in ipairs(walk.parts) do
        if not stepPart(walk, part) then return false end
        total, explored, complete = total + part.total, explored + part.explored, complete and part.complete
    end
    walk.total, walk.explored, walk.complete = total, explored, complete
    return true
end

-- The building at a square, counted whole in one go: { key, containers, complete }, or nil (see newWalk). For checks
-- and tools; the watch itself counts a part at a time (Buildings.tick).
function Buildings.scan(square, room)
    local walk = newWalk(square, room)
    if not walk then return nil end
    if walk.api then
        local api = OA.api()
        local found, whole = {}, true
        for _, part in ipairs(walk.parts) do
            part.opts.since = nil
            local ok, list, complete = pcall(api.buildings.containers, part.raw, part.opts)
            if not ok or type(list) ~= "table" then
                -- the Lua walk instead
                if ok then noContainers[walk.key] = true else containersFailed = true end
                return Buildings.scan(square, room)
            end
            for i = 1, #list, STRIDE do found[#found + 1] = list[i] end
            whole = whole and complete and true or false
        end
        return { key = walk.key, containers = found, complete = whole }
    end
    stepWalk(walk, math.huge)
    return { key = walk.key, containers = walk.list, complete = walk.complete }
end

-- How many of a list of containers were opened.
function Buildings.searched(containers)
    local n = 0
    for i = 1, #containers do
        if Buildings.opened(containers[i]) then n = n + 1 end
    end
    return n
end

-- One look at the building a character stands in: returns key, searched, total and
-- whether every square of the building has been counted; nil when the character is outside. A square under a roof
-- with no room (a stairwell, a doorway) is still the building of the walk in hand. A look counts up to
-- BUDGET more squares of the building and asks the containers not opened yet whether they are now (an opened one
-- stays opened, so it is not asked again).
function Buildings.tick(character)
    local number = character:getPlayerNum()
    local square = character:getCurrentSquare()
    local room = square and square:getRoom()
    local key = room and Buildings.keyAt(square, room) or nil
    if not key and not room and square and not square:isOutside() and states[number] then key = states[number].key end
    if not key then
        if states[number] then left[number] = states[number] end
        states[number] = nil
        return nil
    end
    local walk = states[number]
    if not walk or walk.key ~= key then
        if walk then left[number] = walk end
        walk = newWalk(square, room)
        states[number] = walk
        if not walk then return nil end
    end
    if walk.api then
        if not stepApi(walk) then
            -- the API cannot walk this building: the Lua walk takes over (newWalk leaves the API's containers out now)
            walk = newWalk(square, room)
            states[number] = walk
            if not walk then return nil end
            stepWalk(walk, Buildings.BUDGET)
        end
    else
        stepWalk(walk, Buildings.BUDGET)
    end
    if not walk.api then
        -- (the API's walk lists the containers that were opened since the last look itself)
        local open = walk.open
        for i = #open, 1, -1 do
            if Buildings.opened(open[i]) then
                local z = walk.zOf[open[i]]
                if z then walk.floorOpen[z] = (walk.floorOpen[z] or 1) - 1 end
                open[i] = open[#open]
                open[#open] = nil
                walk.explored = walk.explored + 1
            end
        end
    end
    return walk.key, walk.explored, walk.total, walk.complete
end

-- What the last look at the building `key` found for the character: searched, total and whether it was counted
-- whole; nil when its walk is neither the one in hand nor the one before (the character went on to another). Asks
-- nothing of the game: the economy's check of a building all searched, which the watch sends as the character steps
-- away from the last containers, maybe out of the building.
function Buildings.counts(character, key)
    local number = character:getPlayerNum()
    local walk = states[number]
    if not walk or walk.key ~= key then walk = left[number] end
    if not walk or walk.key ~= key then return nil end
    return walk.explored, walk.total, walk.complete
end

-- The containers of the character's building not opened yet as the last look found them (a list kept by the walk:
-- read it, do not change it), or nil outside a building. The search ledger outlines the near ones. With the API's
-- containers three more lists come with it: the x, y and z of the square each stands on (the first the walk found it
-- on), so that the near ones are picked without asking the game about each.
function Buildings.unopened(character)
    local walk = states[character:getPlayerNum()]
    if not walk then return nil end
    if walk.parts then
        -- the part the character's floor is in (a house's floors and its basement's do not meet)
        local z = math.floor(character:getZ())
        for _, part in ipairs(walk.parts) do
            if part.floorTotal[z] then return part.open, part.ox, part.oy, part.oz end
        end
        local first = walk.parts[1]
        return first.open, first.ox, first.oy, first.oz
    end
    return walk.open, walk.ox, walk.oy, walk.oz
end

-- The containers of the character's building on floor `z` not opened yet and all of them, as the last look found
-- them (0, 0 outside a building or on a floor with none).
function Buildings.floor(character, z)
    local walk = states[character:getPlayerNum()]
    if not walk then return 0, 0 end
    if walk.parts then
        local open, total = 0, 0
        for _, part in ipairs(walk.parts) do
            open, total = open + (part.floorOpen[z] or 0), total + (part.floorTotal[z] or 0)
        end
        return open, total
    end
    return walk.floorOpen[z] or 0, walk.floorTotal[z] or 0
end

-- The key of the building at a square (the room is its vanilla room, or nil), or nil outside a building or in one
-- the player built.
function Buildings.keyAt(square, room)
    local api = OA.api()
    if api and api.buildings then
        local b = api.buildings.at(square:getX(), square:getY(), square:getZ())
        if not b or b.playerBuilt then return nil end
        return Buildings.group(api, b, square).key
    end
    room = room or square:getRoom()
    local building = room and room:getBuilding()
    local def = building and building:getDef()
    return def and ("v:" .. tostring(def:getX()) .. "," .. tostring(def:getY())) or nil
end

-- Forget what is cached (a new character, a test).
function Buildings.reset()
    states = {}
    left = {}
    noContainers, containersFailed = {}, false
    groups = {}
end

return Buildings
