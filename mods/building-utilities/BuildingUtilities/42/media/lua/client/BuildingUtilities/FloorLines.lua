-- The lines on the ground: each line laid (BU.Links) lies on the floor where it runs (Links.route), a cable for power
-- and a pipe for water, as the API's floor decals (PZExtAPI.floor): no object of the world, nothing saved. They lie
-- as laid whatever they supply; the window's overlay tells that. On soil and grass a line lies half sunk in it, on a
-- made floor (tiles, paving, boards) on top of it, held down. Worked out again when the lines change
-- (Store.linkVersion), and only the squares that changed are sent. Their squares are watched (PZExtAPI.squares): when
-- one changes (something built on it or taken away, its floor changed, or it loaded) its look is chosen again, and a
-- line that can no longer lie there (water, no floor, stairs, a room built over it) is laid again round it.
require "BuildingUtilities/Links"
local BU = BuildingUtilities
local Store, Links = BU.Store, BU.Links
local FloorLines = {}
BU.FloorLines = FloorLines

-- The pieces in the sheet (tools/tile_art.py): for each utility, one for each set of sides a square's run leaves by
-- (N, E, S, W as the bits 1, 2, 4, 8), from its first; sunk in soil, and laid on a made floor.
local SHEET = "bu_water_01_"
FloorLines.FIRST = { power = 184, water = 199 }
FloorLines.FIRST_LAID = { power = 218, water = 233 }
-- A straight run's second look (sunk: the cable pinned by a staple, the pipe joined by a coupling; laid: a cable clip,
-- a pipe strap), by its sides (N-S 5, E-W 10), on one square in four along a line.
FloorLines.DETAIL = { power = { [5] = 214, [10] = 215 }, water = { [5] = 216, [10] = 217 } }
FloorLines.DETAIL_LAID = { power = { [5] = 248, [10] = 249 }, water = { [5] = 250, [10] = 251 } }
local SIDE = { [0] = { [-1] = 1, [1] = 4 }, [1] = { [0] = 2 }, [-1] = { [0] = 8 } }
local UTILITIES = { "power", "water" }
-- The most squares one watch holds (the API's limit), and how long a changed square is looked at again for a room the
-- game makes of what was built there a little later (ticks, every RECHECK_EVERY).
local WATCH_MAX = 16384
local RECHECK_TICKS, RECHECK_EVERY = 600, 60

local function bit(dx, dy) return SIDE[dx] and SIDE[dx][dy] or 0 end

-- What each square shows: { [key] = { x, y, z, power = sides, water = sides, lines = { ref, ... } } }.
function FloorLines.wanted()
    local squares = {}
    local function add(x, y, z, line, sides)
        local key = x .. "," .. y .. "," .. z
        local square = squares[key]
        if not square then
            square = { x = x, y = y, z = z, lines = {} }
            squares[key] = square
        end
        local utility = line.utility
        local had = square[utility] or 0
        -- the sides' bits or'd in (Kahlua has no bit operators)
        for _, b in ipairs({ 1, 2, 4, 8 }) do
            if BU.remainder(sides, b * 2) >= b and BU.remainder(had, b * 2) < b then had = had + b end
        end
        square[utility] = had
        local lines = square.lines
        if lines[#lines] ~= line.ref then lines[#lines + 1] = line.ref end
    end
    for _, line in pairs(Links.all()) do
        local route, z, intoX, intoY = Links.route(line)
        if route and (#route > 1 or intoX) then
            for i = 1, #route - 1 do
                local a, b = route[i], route[i + 1]
                add(a.x, a.y, z, line, bit(b.x - a.x, b.y - a.y))
                add(b.x, b.y, z, line, bit(a.x - b.x, a.y - b.y))
            end
            if intoX then
                local last = route[#route]
                add(last.x, last.y, z, line, bit(intoX, intoY))
            end
        end
    end
    return squares
end

-- Whether a square's floor is made (tiles, paving, boards): a line lies on it, not in it. Soil, grass and sand are
-- the game's natural blends; a square not loaded counts as soil until it loads.
function FloorLines.madeFloor(x, y, z)
    local square = getCell():getGridSquare(x, y, z)
    local floor = square and square:getFloor()
    local sprite = floor and floor:getSprite()
    local name = sprite and sprite:getName()
    return name ~= nil and string.sub(name, 1, 14) ~= "blends_natural"
end

-- What the floor shows now, by square: the pieces' names joined, as last sent; what is wanted, by square.
local shown, wanted = {}, {}
local seen, cleared = nil, false
-- The squares watched (the API's watch ids), the squares told changed since, and the squares looked at again for a
-- while ({ key = ticks left }, nil when none). And what each was last seen as (looked: its floor made or not, its ground
-- open or not): a square the game works out again only because it loaded, or for a change that came to nothing, is
-- soon looked at again for nothing.
local watches, changed, rechecks, anyChanged, ticks, looked = {}, {}, nil, false, 0, {}

local function decals(square)
    local list, names = {}, {}
    local laid = FloorLines.madeFloor(square.x, square.y, square.z)
    for _, utility in ipairs(UTILITIES) do
        local sides = square[utility]
        if sides and sides > 0 then
            local detail = (laid and FloorLines.DETAIL_LAID or FloorLines.DETAIL)[utility][sides]
            local index = detail and BU.remainder(square.x * 7 + square.y * 13, 4) == 0 and detail
                or (laid and FloorLines.FIRST_LAID or FloorLines.FIRST)[utility] + sides - 1
            local name = SHEET .. index
            names[#names + 1] = name
            list[#list + 1] = name
            list[#list + 1] = 1
            list[#list + 1] = 1
            list[#list + 1] = 1
            list[#list + 1] = 1
        end
    end
    return list, table.concat(names, " ")
end

local function send(api, handle, key, square)
    local list, name = decals(square)
    if shown[key] ~= name then
        api.floor.set(handle, square.x, square.y, square.z, list)
        shown[key] = name
    end
end

local function onChanged(_, x, y, z)
    changed[x .. "," .. y .. "," .. z] = true
    anyChanged = true
end

-- The squares of the lines watched again: those wanted now, in watches of at most WATCH_MAX.
local function watch(api, handle)
    if not api.squares then return end
    for _, id in ipairs(watches) do api.squares.unwatch(handle, id) end
    watches = {}
    local list = {}
    local function flush()
        if #list > 0 then watches[#watches + 1] = api.squares.watch(handle, list, onChanged) end
        list = {}
    end
    for _, square in pairs(wanted) do
        list[#list + 1] = square.x
        list[#list + 1] = square.y
        list[#list + 1] = square.z
        if #list >= WATCH_MAX * 3 then flush() end
    end
    flush()
end

-- Sends the squares that changed since the last time; the first time, what an earlier load sent is taken away first.
function FloorLines.refresh()
    seen = Store.linkVersion()
    local api, handle = BU.api(), BU.handle()
    if not (api and api.floor and handle) then return end
    if not cleared then
        api.floor.clear(handle)
        shown, cleared = {}, true
    end
    wanted, looked = FloorLines.wanted(), {}
    for key, square in pairs(wanted) do send(api, handle, key, square) end
    for key in pairs(shown) do
        if not wanted[key] then
            local x, y, z = BU.parsePlace(key)
            api.floor.set(handle, x, y, z, nil)
            shown[key] = nil
        end
    end
    watch(api, handle)
end

-- A square of the lines that changed, or one looked at again: its look chosen again; the lines that can no longer lie
-- there laid again round it. True when a line was. again: a look after the change (not the change itself), which
-- does nothing while the floor and the ground are as they were seen.
local function recheck(api, handle, key, again)
    local square = wanted[key]
    if not square then return false end
    local made = FloorLines.madeFloor(square.x, square.y, square.z)
    local open = Links.groundOpen(square.x, square.y, square.z)
    local seenAs = (made and 2 or 0) + (open and 1 or 0)
    if again and looked[key] == seenAs then return false end
    looked[key] = seenAs
    send(api, handle, key, square)
    if open then return false end
    local moved = false
    for _, ref in ipairs(square.lines) do
        local line = Links.get(ref)
        local route = line and Links.route(line)
        local last = route and route[#route]
        -- its own square and its last stay, whatever is there; a way no better than the one it has is not taken
        if last and not (line.x == square.x and line.y == square.y) and not (last.x == square.x and last.y == square.y) then
            local path, old = Links.pathFor(line), line.path
            local same = path and old and #path == #old
            if same then
                for i = 1, #path do
                    if path[i] ~= old[i] then same = false break end
                end
            end
            if path and not same then
                line.path = path
                moved = true
            end
        end
    end
    return moved
end

-- Each tick, one comparison: the lines changed since the floor was last worked out; else the squares told changed,
-- and now and then those looked at again.
local function onTick()
    if seen ~= Store.linkVersion() then FloorLines.refresh() return end
    if not anyChanged and not rechecks then return end
    local api, handle = BU.api(), BU.handle()
    if not (api and api.floor and handle) then return end
    local moved = false
    if anyChanged then
        local keys = changed
        changed, anyChanged = {}, false
        rechecks = rechecks or {}
        for key in pairs(keys) do
            if recheck(api, handle, key, false) then moved = true end
            rechecks[key] = RECHECK_TICKS
        end
    end
    ticks = ticks + 1
    if rechecks and ticks >= RECHECK_EVERY then
        ticks = 0
        local still = nil
        for key, left in pairs(rechecks) do
            if recheck(api, handle, key, true) then moved = true end
            if left > RECHECK_EVERY then
                still = still or {}
                still[key] = left - RECHECK_EVERY
            end
        end
        rechecks = still
    end
    if moved then Store.linksChanged() end
end

Events.OnTick.Add(onTick)

return FloorLines
