-- The lines on the ground: each line laid (BU.Links) lies on the floor where it runs (Links.route), a cable for power
-- and a pipe for water, as the API's floor decals (PZExtAPI.floor): no object of the world, nothing saved. They lie
-- as laid whatever they supply; the window's overlay tells that. On soil and grass a line lies half sunk in it, on a
-- made floor (tiles, paving, boards) on top of it, held down. Looked at again when the lines change
-- (Store.linkVersion): only a line that lies otherwise than it did is worked out again, and only its squares are sent
-- (when their pieces are not the ones shown). Their squares are watched (PZExtAPI.squares): when
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
-- The most squares one watch holds (the API's limit).
local WATCH_MAX = 16384

local function bit(dx, dy) return SIDE[dx] and SIDE[dx][dy] or 0 end

-- Two sets of sides or'd (0 to 15 each): OR[a][b], worked out once (Kahlua has no bit operators).
local SIDE_BITS = { 1, 2, 4, 8 }
local OR = {}
for a = 0, 15 do
    OR[a] = {}
    for b = 0, 15 do
        local sum = a
        for _, each in ipairs(SIDE_BITS) do
            if BU.remainder(b, each * 2) >= each and BU.remainder(a, each * 2) < each then sum = sum + each end
        end
        OR[a][b] = sum
    end
end

-- What each square shows: { [key] = { x, y, z, power = sides, water = sides, lines = { ref, ... } } }, kept between
-- the lines' changes: a line that lies as it did is not worked out again, only the squares of the lines that changed.
-- infos: by ref, how a line lay when its squares were last worked out ({ route (Links.route's squares: the same table
-- while the line lies so), z, intoX, intoY, utility, sides = { [key] = the sides its run leaves the square by } });
-- touching: by square, the refs of the lines lying on it. pending: the squares to send, since the last send.
local wanted, infos, touching, pending = {}, {}, {}, {}
-- Whether the set of squares wanted changed since they were watched.
local watchDirty = true

local function linkLine(ref, line, route, z, intoX, intoY)
    local sides = {}
    local function add(x, y, bits)
        local key = x .. "," .. y .. "," .. z
        sides[key] = OR[sides[key] or 0][bits]
    end
    for i = 1, #route - 1 do
        local a, b = route[i], route[i + 1]
        add(a.x, a.y, bit(b.x - a.x, b.y - a.y))
        add(b.x, b.y, bit(a.x - b.x, a.y - b.y))
    end
    if intoX then
        local last = route[#route]
        add(last.x, last.y, bit(intoX, intoY))
    end
    infos[ref] = { route = route, z = z, intoX = intoX, intoY = intoY, utility = line.utility, sides = sides }
    for key in pairs(sides) do
        local on = touching[key]
        if not on then
            on = {}
            touching[key] = on
        end
        on[ref] = true
        pending[key] = true
    end
end

local function unlinkLine(ref)
    local info = infos[ref]
    if not info then return end
    infos[ref] = nil
    for key in pairs(info.sides) do
        local on = touching[key]
        if on then
            on[ref] = nil
            -- (no next() in Kahlua: an emptied set is seen by looking for any ref)
            local any = false
            for _ in pairs(on) do any = true break end
            if not any then touching[key] = nil end
        end
        pending[key] = true
    end
end

-- The lines now against the lines worked out: the lines that changed (a new way, other ends, another utility), came or
-- went are linked or unlinked, and the squares they lie on worked out again from the lines on them.
local function sync()
    local lines = Links.all()
    for ref in pairs(infos) do
        if not lines[ref] then unlinkLine(ref) end
    end
    for ref, line in pairs(lines) do
        local route, z, intoX, intoY = Links.route(line)
        local info = infos[ref]
        if route and (#route > 1 or intoX) then
            if not info or info.route ~= route or info.z ~= z or info.intoX ~= intoX or info.intoY ~= intoY
                    or info.utility ~= line.utility then
                unlinkLine(ref)
                linkLine(ref, line, route, z, intoX, intoY)
            end
        elseif info then
            unlinkLine(ref)
        end
    end
    for key in pairs(pending) do
        local on = touching[key]
        local had = wanted[key]
        if on then
            local x, y, z = BU.parsePlace(key)
            local fresh = { x = x, y = y, z = z, lines = {} }
            for ref in pairs(on) do
                local info = infos[ref]
                fresh[info.utility] = OR[fresh[info.utility] or 0][info.sides[key]]
                fresh.lines[#fresh.lines + 1] = ref
            end
            wanted[key] = fresh
            if not had then watchDirty = true end
        elseif had then
            wanted[key] = nil
            watchDirty = true
        end
    end
end

-- The squares the lines lie on now: sides and lines of each.
function FloorLines.wanted()
    sync()
    return wanted
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

-- What the floor shows now, by square: the sides of each utility and whether the floor is made, as last sent (a number;
-- the pieces follow from them).
local shown = {}
local seen, cleared = nil, false
-- The squares watched (the API's watch ids), and what each was last seen as (looked: its floor made or not, its
-- ground open or not): a square the game works out again only because it loaded, or for a change that came to nothing,
-- is soon looked at again for nothing.
local watches, looked = {}, {}
-- The squares told changed, waiting to be looked at (a queue by head and tail, keys in `queued` once each), and the
-- looks to come at them after: the stages of RECHECK_AFTER, each that many ticks after the change (a room the game
-- makes of what was built there comes a little later, and when is not known: the looks thin out, with no long gap). A
-- look that finds the square changed starts them over. At most PER_TICK squares are looked at in a tick. A look belongs
-- to the latest change of its square (turns), an older one is dropped.
local RECHECK_AFTER = { 60, 180, 360, 600 }
local STAGES = #RECHECK_AFTER
local PER_TICK = 64
local function newQueue() return { head = 1, tail = 0, keys = {}, dues = {}, turns = {} } end
local events, queued = newQueue(), {}
local later = {}
for stage = 1, STAGES do later[stage] = newQueue() end
local turns, turn, clock = {}, 0, 0

local function push(queue, key, due, own)
    local at = queue.tail + 1
    queue.tail = at
    queue.keys[at], queue.dues[at], queue.turns[at] = key, due, own
end

local function pop(queue)
    local at = queue.head
    queue.keys[at], queue.dues[at], queue.turns[at] = nil, nil, nil
    if at >= queue.tail then queue.head, queue.tail = 1, 0 else queue.head = at + 1 end
end

local function waiting(queue) return queue.head <= queue.tail end

local function anyWaiting()
    if waiting(events) then return true end
    for stage = 1, STAGES do
        if waiting(later[stage]) then return true end
    end
    return false
end

local function decals(square, laid)
    local list = {}
    for _, utility in ipairs(UTILITIES) do
        local sides = square[utility]
        if sides and sides > 0 then
            local detail = (laid and FloorLines.DETAIL_LAID or FloorLines.DETAIL)[utility][sides]
            local index = detail and BU.remainder(square.x * 7 + square.y * 13, 4) == 0 and detail
                or (laid and FloorLines.FIRST_LAID or FloorLines.FIRST)[utility] + sides - 1
            list[#list + 1] = SHEET .. index
            list[#list + 1] = 1
            list[#list + 1] = 1
            list[#list + 1] = 1
            list[#list + 1] = 1
        end
    end
    return list
end

-- The pieces a square shows, sent when they are not the ones it shows already; made: whether its floor is made, when
-- the caller has looked.
local function send(api, handle, key, square, made)
    if made == nil then made = FloorLines.madeFloor(square.x, square.y, square.z) end
    local look = ((square.power or 0) * 16 + (square.water or 0)) * 2 + (made and 1 or 0)
    if shown[key] == look then return end
    api.floor.set(handle, square.x, square.y, square.z, decals(square, made))
    shown[key] = look
end

local function onChanged(_, x, y, z)
    local key = x .. "," .. y .. "," .. z
    if queued[key] then return end
    queued[key] = true
    push(events, key)
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
    watchDirty = false
end

-- Sends the squares that changed since the last time (those of the lines that changed); the first time, what an earlier
-- load sent is taken away first. The squares are watched again only when the squares wanted are not the same.
function FloorLines.refresh()
    seen = Store.linkVersion()
    local api, handle = BU.api(), BU.handle()
    if not (api and api.floor and handle) then return end
    if not cleared then
        api.floor.clear(handle)
        shown, cleared = {}, true
        wanted, infos, touching, pending = {}, {}, {}, {}
        watchDirty = true
    end
    sync()
    for key in pairs(pending) do
        looked[key] = nil
        local square = wanted[key]
        if square then
            send(api, handle, key, square)
        elseif shown[key] then
            local x, y, z = BU.parsePlace(key)
            api.floor.set(handle, x, y, z, nil)
            shown[key] = nil
        end
    end
    pending = {}
    if watchDirty then watch(api, handle) end
end

-- A square of the lines that changed, or one looked at again: its look chosen again; the lines that can no longer lie
-- there laid again round it. True when a line was. again: a look after the change (not the change itself), which
-- does nothing while the floor and the ground are as they were seen. The second result is true when it found them not
-- as they were seen.
local function recheck(api, handle, key, again)
    local square = wanted[key]
    if not square then return false, false end
    local made = FloorLines.madeFloor(square.x, square.y, square.z)
    local open = Links.groundOpen(square.x, square.y, square.z)
    local seenAs = (made and 2 or 0) + (open and 1 or 0)
    if again and looked[key] == seenAs then return false, false end
    local differs = looked[key] ~= seenAs
    looked[key] = seenAs
    send(api, handle, key, square, made)
    if open then return false, differs end
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
    return moved, differs
end

-- Each tick, one comparison: the lines changed since the floor was last worked out; else the squares told changed
-- (a few at a time), and the looks to come at them.
local function onTick()
    if seen ~= Store.linkVersion() then FloorLines.refresh() return end
    if not anyWaiting() then return end
    local api, handle = BU.api(), BU.handle()
    if not (api and api.floor and handle) then return end
    clock = clock + 1
    local moved, budget = false, PER_TICK
    while budget > 0 and waiting(events) do
        local key = events.keys[events.head]
        pop(events)
        queued[key] = nil
        budget = budget - 1
        turn = turn + 1
        turns[key] = turn
        if recheck(api, handle, key, false) then moved = true end
        push(later[1], key, clock + RECHECK_AFTER[1], turn)
    end
    for stage = 1, STAGES do
        local queue = later[stage]
        while budget > 0 and waiting(queue) and queue.dues[queue.head] <= clock do
            local key, due, own = queue.keys[queue.head], queue.dues[queue.head], queue.turns[queue.head]
            pop(queue)
            if turns[key] == own then
                budget = budget - 1
                local did, differs = recheck(api, handle, key, true)
                if did then moved = true end
                if differs then
                    turn = turn + 1
                    turns[key] = turn
                    push(later[1], key, clock + RECHECK_AFTER[1], turn)
                elseif stage < STAGES then
                    push(later[stage + 1], key, due - RECHECK_AFTER[stage] + RECHECK_AFTER[stage + 1], own)
                else
                    turns[key] = nil
                end
            end
        end
    end
    if moved then Store.linksChanged() end
end

Events.OnTick.Add(onTick)

return FloorLines
