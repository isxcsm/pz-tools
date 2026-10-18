-- R3 performance, before and after (E2E.md 10.1): the same paths driven the same way on c0 (the last dev commit before
-- the world-query work, a4692230) and on c1 (dev now), each printing
--   [perf] <path> calls=<n> total_ms=<..> mean_us=<..> p95_us=<..> max_us=<..>
-- and "[perf] <path> n/a (<why>)" where a path is not there on that build. The harness works out which build it is in
-- (OA.Trade.Objects.isClear is c1's), prints it with the mods' folders and what the API has, and drives each path by its
-- own name on that build. What each line measures on c0 / on c1:
--   cursor.hover / cursor.frames  ISOAPlaceCursor:isValid + blockersAround: isValid asks Objects.clearSquare(sq, nil, cache)
--                                 (a Lua walk of the box's surroundings, cache per cursor) / Objects.isClear(sq) (squares.nearest)
--   objects.clearSquare           Objects.clearSquare(sq) / the same name, now the reasons after one squares.nearest
--   objects.isClear               n/a / Objects.isClear (the yes or no alone)
--   machines.tick, machines.update  Machines.tick: per machine getGridSquare + findOnSquare / one objects.byData (OA_MachineId)
--   bu.lookup.panels, .units      a Panels.object / Units.object per box and unit / one BU.objectsByData (objects.byData)
--   bu.lights_everyMinute, bu.checkObjects  the same functions, those lookups inside
--   bu.spawned_places             Spawned.places: room:getSquares loop with floor and stairs tests / squares.list
--   bu.links_walk, bu.route       Links.walk: Dijkstra in Lua / squares.path (the same costs; bu.route lines tell if the ways match)
--   bu.floorlines_wanted, bu.connect  the same functions over routes found by the above
--   alarm.job                     the Senses alarm job (Pulse "alarms") as that build has it: vehicles from OA.vehicles + a grid of
--                                 getSpecialObjects / vehicles.near + objects.find
--   alarm.vehicles, alarm.entries  those two scans alone, as that build does them
--   dense.look.*, towns.enter.*, api.*  n/a / OA.Dense.look, OA.Towns.enter, PZExtAPI.zombies.dense, zones.clusters
--   heavy.findClear               Objects.findClear: rings of Objects.search with clearSquare / rings of squares.nearest
--   heavy.settleGround            StoryGame.settleGround: campFits Lua loops / squares.fit
--   heavy.pickSite                Missions.pickSite: Game.sitesInBand and groundInBand (Lua, 5 args) / buildings.list and zones.points
--   heavy.meteor_onChunk          Sites.onChunk: a Lua walk of the chunk's squares / squares.fit
--   heavy.stage_build             Dev.buildScene: Scene.build with StageGame's Lua loops / its objects.edges, remove, fit, nearest
--
-- How it times: Lua has only a millisecond clock (getTimestampMs is System.currentTimeMillis; os.time is the same
-- clock), so no single call of tens of microseconds can be timed. A batch of g calls is timed and divided (g grows until
-- a batch takes a few milliseconds; one batch a frame, so the game stays alive). The mean is exact over a run (the
-- clock's rounding averages out); the p95 is the 95th percentile of the batches' per-call means (a path of 1 ms or more
-- has g = 1 and is one call's time to the millisecond). A one-off (heavy.*) is timed call by call, the first one cold.
-- "frames" lines are the frames' own times (a frame is the gap between two OnPostUIDraw): p50, p95, p99, max, and
-- how many were over 50 ms.
--
-- Setup: single player, the game running and not paused, the Dev sub-mods on (OperationAcornDev, BuildingUtilitiesDev),
-- the same save at the same state for both builds (put it back from a snapshot between builds). Two places are marked
-- once; both builds use the same two (they are kept in Zomboid\Lua\perf_r3_spots.txt):
--   open: open ground, no building within 30 squares, a patch 20 x 20 east and south of the spot clear (machines).
--   town: the middle of a town with cars and houses, a building within 10 squares (alarms, the BU boxes and lines).
-- Stand on the spot and run:  pzdev run "PERF_NAME='open' RUN('perf_r3.lua')"   (then 'town')
-- Then:  pzdev check perf_r3.lua --follow 900
-- The harness puts the character at the spots itself. It sets up what it needs (10 machines, BU boxes and units, alarms on
-- houses and cars, the alarm research node) and takes it away at the end, whatever fails. The save should be put back
-- all the same (the one-offs of the stage and the meteor site build in the world).
-- PERF_R3_CFG (a table set before) changes: skip = { cursor = true, ... } (groups: frames cursor machines bu alarms
-- dense heavy), cursorSeconds (30), idleSeconds (10), routes (a list of { x, y, ex, ey, z, intoX, intoY } for the BU
-- routes), minuteEvent = true (also times the whole EveryOneMinute event: it runs every handler of every mod).
-- "[perf] done: N BAD" ends the run (BAD: a path that failed, not a slow one).
local OA = OperationAcorn
local BU = BuildingUtilities

if PERF_R3 then
    -- an earlier run: its frame hook off, what it set up taken away
    pcall(function() Events.OnPostUIDraw.Remove(PERF_R3.onFrame) end)
    pcall(PERF_R3.unwindAll)
    PERF_R3 = nil
end

local SPOTS_FILE = "perf_r3_spots.txt"

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[perf] " .. table.concat(parts, " "))
end

local function readSpots()
    local spots = {}
    local reader = getFileReader(SPOTS_FILE, false)
    if not reader then return spots end
    local line = reader:readLine()
    while line do
        local name, x, y, z = string.match(line, "^(%S+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+)$")
        if name then spots[name] = { x = math.floor(tonumber(x)), y = math.floor(tonumber(y)), z = math.floor(tonumber(z)) } end
        line = reader:readLine()
    end
    reader:close()
    return spots
end

local function writeSpots(spots)
    local writer = getFileWriter(SPOTS_FILE, true, false)
    for name, s in pairs(spots) do writer:write(name .. " " .. s.x .. " " .. s.y .. " " .. s.z .. "\n") end
    writer:close()
end

-- PERF_NAME='open': marks where the character stands, and ends.
if PERF_NAME then
    local name = PERF_NAME
    PERF_NAME = nil
    local p = getPlayer()
    local spots = readSpots()
    spots[name] = { x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()) }
    writeSpots(spots)
    say("spot", name, "=", spots[name].x, spots[name].y, spots[name].z)
    return
end

local cfg = PERF_R3_CFG or {}
local P = { tasks = {}, undo = {}, failed = {}, bad = 0, index = 0 }
PERF_R3 = P

-- ---- numbers -----------------------------------------------------------------------------------------------------

local function percentile(sorted, q)
    local n = #sorted
    if n == 0 then return 0 end
    local i = math.ceil(q * n)
    if i < 1 then i = 1 end
    return sorted[i]
end

local function f1(x) return string.format("%.1f", x) end

-- A number made from a list of numbers, to tell whether two builds found the same thing.
local function hashOf(list)
    local h = 7
    for _, v in ipairs(list) do
        h = h * 31 + v
        h = h - math.floor(h / 1000003) * 1000003
    end
    return h
end

-- ---- the frames ----------------------------------------------------------------------------------------------------

local last, bucket = nil, nil

local function frameLine(id, frames)
    local sorted = {}
    local over = 0
    for i, dt in ipairs(frames) do
        sorted[i] = dt
        if dt > 50 then over = over + 1 end
    end
    table.sort(sorted)
    say("frames " .. id, "n=" .. #sorted, "p50_ms=" .. percentile(sorted, 0.50), "p95_ms=" .. percentile(sorted, 0.95),
        "p99_ms=" .. percentile(sorted, 0.99), "max_ms=" .. (sorted[#sorted] or 0), "over50=" .. over)
end

-- ---- the tasks -----------------------------------------------------------------------------------------------------

-- A task is run once a frame until it returns true. A setup task failing skips the group's other tasks (not its
-- cleanups); another failing is a BAD line.
function P.add(group, name, fn, kind)
    P.tasks[#P.tasks + 1] = { group = group, name = name, fn = fn, kind = kind }
end

local function fail(task, err)
    P.bad = P.bad + 1
    if task.kind == "setup" then P.failed[task.group] = true end
    say(task.name, "BAD", tostring(err))
end

function P.na(id, why) say(id, "n/a (" .. why .. ")") end

-- Things set up, to take away (last first) at the end of a group or when a run is stopped.
function P.pushUndo(group, fn) P.undo[#P.undo + 1] = { group = group, fn = fn } end

function P.unwind(group)
    for i = #P.undo, 1, -1 do
        local u = P.undo[i]
        if u and (not group or u.group == group) then
            table.remove(P.undo, i)
            local ok, err = pcall(u.fn)
            if not ok then
                P.bad = P.bad + 1
                say("cleanup " .. tostring(u.group), "BAD", tostring(err))
            end
        end
    end
end

function P.unwindAll() P.unwind(nil) end

-- Puts the character at a marked spot (unless there) and waits for its square to load.
function P.go(group, name)
    P.add(group, "go " .. name, function(t)
        local s = P.spots[name]
        local now = getTimestampMs()
        local p = getPlayer()
        if not t.t0 then
            t.t0 = now
            if math.abs(p:getX() - s.x) < 1.5 and math.abs(p:getY() - s.y) < 1.5 and math.abs(p:getZ() - s.z) < 0.5 then
                t.here = true
                return true
            end
            p:teleportTo(s.x + 0.5, s.y + 0.5, s.z)
            return false
        end
        if now - t.t0 < 2500 then return false end
        if getCell():getGridSquare(s.x, s.y, s.z) and math.abs(p:getX() - s.x) < 3 and math.abs(p:getY() - s.y) < 3 then
            t.t1 = t.t1 or now
            return now - t.t1 >= 2500
        end
        if now - t.t0 > 40000 then error("the spot " .. name .. " did not load in 40 s") end
        return false
    end, "setup")
end

-- A batch-timed path (see the head). op(i) is one call; opts: n (calls to make) or seconds, g (a fixed batch), warm
-- (batches not counted, 2), frames (also the frames' line), targetMs (a batch's aim, 4), maxg, note, skipIf (a function:
-- true to leave it out).
function P.bench(group, id, op, opts)
    opts = opts or {}
    P.add(group, id, function(t)
        if opts.skipIf and opts.skipIf() then return true end
        local now = getTimestampMs()
        if not t.init then
            t.init, t.g, t.i, t.calls, t.total, t.max = true, opts.g or 1, 0, 0, 0, 0
            t.samples, t.t0, t.warm = {}, now, opts.warm or 2
            t.frames = {}
            if opts.frames then
                bucket = t.frames
                say("start", id, "(pzdev profile 30 now, in another terminal, for the hot methods of this stretch)")
            end
        end
        local g = t.g
        local ok, err = pcall(function()
            for k = 1, g do op(t.i + k) end
        end)
        local dt = getTimestampMs() - now
        if not ok then
            bucket = nil
            fail({ group = group, name = id }, err)
            return true
        end
        t.i = t.i + g
        if t.warm > 0 then
            t.warm = t.warm - 1
        else
            t.calls, t.total = t.calls + g, t.total + dt
            local per = dt / g
            t.samples[#t.samples + 1] = per
            if per > t.max then t.max = per end
        end
        if not opts.g and dt < (opts.targetMs or 4) / 2 and g < (opts.maxg or 2048) then t.g = g * 2 end
        local done = (opts.n and t.i >= opts.n) or (opts.seconds and getTimestampMs() - t.t0 >= opts.seconds * 1000)
        if not done then return false end
        bucket = nil
        table.sort(t.samples)
        local calls = math.max(t.calls, 1)
        say(id, "calls=" .. t.calls, "total_ms=" .. f1(t.total), "mean_us=" .. f1(t.total / calls * 1000),
            "p95_us=" .. f1(percentile(t.samples, 0.95) * 1000), "max_us=" .. f1(t.max * 1000), opts.note or "")
        if opts.frames then frameLine(id, t.frames) end
        return true
    end)
end

-- A one-off, timed call by call (the first one cold): fn(i) for i = 1..n, one a frame; the frames' line follows (its
-- max is the pause the player sees). skipIf as in bench.
function P.once(group, id, n, fn, note, skipIf)
    P.add(group, id, function(t)
        if skipIf and skipIf() then return true end
        if not t.init then
            t.init, t.i, t.times, t.total, t.frames = true, 0, {}, 0, {}
            bucket = t.frames
            return false
        end
        t.i = t.i + 1
        local start = getTimestampMs()
        local ok, err = pcall(fn, t.i)
        local dt = getTimestampMs() - start
        if not ok then
            bucket = nil
            fail({ group = group, name = id }, err)
            return true
        end
        t.times[#t.times + 1] = dt
        t.total = t.total + dt
        if t.i < n then return false end
        bucket = nil
        local sorted = {}
        for i, v in ipairs(t.times) do sorted[i] = v end
        table.sort(sorted)
        say(id, "calls=" .. #sorted, "total_ms=" .. f1(t.total), "mean_us=" .. f1(t.total / #sorted * 1000),
            "p95_us=" .. f1(percentile(sorted, 0.95) * 1000), "max_us=" .. f1((sorted[#sorted] or 0) * 1000),
            "first_ms=" .. (t.times[1] or 0), note or "")
        frameLine(id, t.frames)
        return true
    end)
end

-- ---- the loop: one task a frame ----------------------------------------------------------------------------------

local function finish()
    P.unwind(nil)
    Events.OnPostUIDraw.Remove(P.onFrame)
    say("done: " .. P.bad .. " BAD")
    PERF_R3 = nil
end

function P.onFrame()
    local now = getTimestampMs()
    if last and bucket then bucket[#bucket + 1] = now - last end
    last = now
    if not P.current then
        -- the next task that is not skipped
        while true do
            P.index = P.index + 1
            local task = P.tasks[P.index]
            if not task then return finish() end
            if P.failed[task.group] and task.kind ~= "cleanup" then
                say(task.name, "skipped (the setup of " .. task.group .. " failed)")
            else
                P.current, P.state = task, {}
                break
            end
        end
    end
    local task = P.current
    local ok, done = pcall(task.fn, P.state)
    if not ok then
        fail(task, done)
        done = true
    end
    if done then P.current = nil end
end

-- ---- what build this is --------------------------------------------------------------------------------------------

local Objects = OA.Trade and OA.Trade.Objects
local isC1 = Objects ~= nil and Objects.isClear ~= nil
local api = type(PZExtAPI) == "table" and PZExtAPI or nil
local function has(...)
    local t = api
    for _, k in ipairs({ ... }) do
        if type(t) ~= "table" then return false end
        t = t[k]
    end
    return t ~= nil
end
local function modDir(id)
    local ok, dir = pcall(function() return getModInfoByID(id):getDir() end)
    return ok and tostring(dir) or "?"
end
P.build = isC1 and "c1" or "c0"

local function header()
    say("build=" .. P.build, "OperationAcorn=" .. modDir("OperationAcorn"))
    say("BuildingUtilities=" .. modDir("BuildingUtilities"), "PZUIKit=" .. modDir("PZUIKit"))
    say("api", api and ("version " .. tostring(api.version)) or "missing", "objects.byData=" .. tostring(has("objects", "byData")),
        "squares.nearest=" .. tostring(has("squares", "nearest")), "squares.path=" .. tostring(has("squares", "path")),
        "vehicles.near=" .. tostring(has("vehicles", "near")), "zones.clusters=" .. tostring(has("zones", "clusters")),
        "zombies.dense=" .. tostring(has("zombies", "dense")))
    if isC1 and not has("objects", "byData") then
        P.bad = P.bad + 1
        say("c1 mods with an API that lacks the world queries", "BAD")
    elseif not isC1 and has("objects", "byData") then
        say("note: c0 mods with the c1 API (the baseline is the c0 API: E2E.md 10.1)")
    end
    local p = getPlayer()
    say("player", math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ()), "paused=" .. tostring(isGamePaused()),
        "zombies loaded=" .. getCell():getZombieList():size())
end

-- ---- the groups ----------------------------------------------------------------------------------------------------

local function player() return getPlayer() end
local function square(x, y, z) return getCell():getGridSquare(x, y, z or 0) end
-- the i-th of a list, round and round
local function nth(list, i) return list[i - math.floor((i - 1) / #list) * #list] end

-- frames.idle: the game's frames with nothing of ours running.
local function groupFrames()
    P.bench("frames", "frames.idle", function() end, { g = 1, seconds = cfg.idleSeconds or 10, frames = true, warm = 0 })
end

-- cursor.* (the delivery box's placing cursor, Objects.clearSquare / isClear):
--   cursor.hover        ISOAPlaceCursor isValid, blockersAround, isValid, isValid on a square (one hover; c0 asks
--                       Objects.clearSquare with the cursor's cache, c1 Objects.isClear)
--   objects.clearSquare Objects.clearSquare(sq) alone, no cache (both)
--   objects.isClear     c1 only
--   cursor.frames       one hover's logic over two frames a square, for cursorSeconds: the frames' line is the point
local function groupCursor()
    P.go("cursor", "open")
    P.add("cursor", "cursor setup", function()
        local s = P.spots.open
        local list = {}
        for dx = -10, 10 do
            for dy = -10, 10 do
                local sq = square(s.x + dx, s.y + dy, 0)
                if sq then list[#list + 1] = sq end
            end
        end
        if #list < 100 then error("only " .. #list .. " squares loaded round the open spot") end
        P.squares = list
        local item = player():getInventory():AddItem(Objects.ITEMS.box)
        if not item then error("no delivery box item") end
        P.pushUndo("cursor", function() if item:getContainer() then item:getContainer():Remove(item) end end)
        P.cursor = ISOAPlaceCursor:new(player(), Objects.DELIVERY_BOX, item)
        say("cursor squares=" .. #list)
        return true
    end, "setup")
    P.bench("cursor", "cursor.hover", function(i)
        local sq, c = nth(P.squares, i), P.cursor
        c:isValid(sq)
        c:blockersAround(sq)
        c:isValid(sq)
        c:isValid(sq)
    end, { n = 441 * 3, warm = 1 })
    P.bench("cursor", "objects.clearSquare", function(i) Objects.clearSquare(nth(P.squares, i)) end, { n = 441 * 3, warm = 1 })
    if Objects.isClear then
        P.bench("cursor", "objects.isClear", function(i) Objects.isClear(nth(P.squares, i)) end, { n = 441 * 3, warm = 1 })
    else
        P.na("objects.isClear", "c1 only")
    end
    P.bench("cursor", "cursor.frames", function(i)
        local sq, c = nth(P.squares, math.floor((i - 1) / 2) + 1), P.cursor
        if i - math.floor(i / 2) * 2 == 1 then
            c:isValid(sq)
            c:blockersAround(sq)
        end
        c:isValid(sq)
    end, { g = 1, seconds = cfg.cursorSeconds or 30, frames = true, warm = 0, note = "one cursor render's logic a frame" })
    P.add("cursor", "cursor cleanup", function() P.unwind("cursor") P.cursor = nil return true end, "cleanup")
end

-- machines.tick: Machines.tick() on the 10 machines the harness puts down (both builds; c1 finds them by OA_MachineId
-- through objects.byData, c0 square by square). machines.update: Machines.update of each one alone, so that
-- tick minus the machines' updates is the finding.
local function groupMachines()
    P.go("machines", "open")
    P.add("machines", "machines setup", function()
        local M = OA.Machines
        local Data = M.Data
        local s = P.spots.open
        local before = 0
        for _ in pairs(M.list()) do before = before + 1 end
        local placed = {}
        local half = math.ceil(#Data.ORDER / 2)
        for i, kind in ipairs(Data.ORDER) do
            local column = i <= half and 3 or 6
            local row = 2 + ((i - 1) - math.floor((i - 1) / half) * half) * 3
            local sq = square(s.x + column, s.y + row, s.z)
            if sq and M.canPlace(kind, sq, "S") then
                local item = player():getInventory():AddItem(M.itemFullType(kind))
                local object = M.place(kind, sq, player(), item, "S")
                item:getContainer():Remove(item)
                if object then placed[#placed + 1] = object end
            end
        end
        P.pushUndo("machines", function()
            for _, object in ipairs(placed) do
                if M.state(object) then M.remove(object) end
            end
        end)
        P.machines = placed
        if #placed == 0 then error("no machine could be put down at the open spot") end
        say("machines placed=" .. #placed .. "/" .. #Data.ORDER, "in the registry before=" .. before)
        return true
    end, "setup")
    P.bench("machines", "machines.tick", function() OA.Machines.tick() end, { n = 60, warm = 3 })
    P.bench("machines", "machines.update", function(i) OA.Machines.update(nth(P.machines, i)) end, { n = 600, warm = 3 })
    P.add("machines", "machines cleanup", function() P.unwind("machines") P.machines = nil return true end, "cleanup")
end

-- bu.*:
--   bu.lights_everyMinute   BU.Lights.everyMinute() (both)
--   bu.checkObjects         BU.Changes.checkObjects() (both)
--   bu.lookup.panels/units  the objects of every box / unit in the store: c0 one Panels.object / Units.object each,
--                           c1 one BU.objectsByData call (objects.byData)
--   bu.spawned_places       BU.Spawned.places(room) over rooms round the town spot (c1 squares.list)
--   bu.links_walk           Links.walk over fixed routes (c1 squares.path); bu.route lines give each route's length
--                           and a hash of its squares, to tell the same way on both builds
--   bu.floorlines_wanted    BU.FloorLines.wanted() with the lines laid
--   bu.connect              Changes.connectUnit of each unit laid, a route found each (a one-off, set up)
--   bu.event_EveryOneMinute the whole event (cfg.minuteEvent only)
local function groupBU()
    P.go("bu", "town")
    P.add("bu", "bu setup", function()
        if not BU or not BU.Changes then error("Building Utilities is not on") end
        if not BU.api() then error("BU.api() is nil: the API is missing or lacks what BU asks of it") end
        local s = P.spots.town
        local Panels, Units, Changes, Links = BU.Panels, BU.Units, BU.Changes, BU.Links
        -- boxes in rooms near the spot, spaced
        local cands = {}
        for dx = -25, 25 do
            for dy = -25, 25 do
                local sq = square(s.x + dx, s.y + dy, 0)
                if sq and sq:getRoom() and sq:isFree(false) and Panels.canInstall(sq) then
                    cands[#cands + 1] = { sq = sq, d = dx * dx + dy * dy }
                end
            end
        end
        table.sort(cands, function(a, b) return a.d < b.d end)
        local panels, units, picked = {}, {}, {}
        P.pushUndo("bu", function()
            for _, unit in ipairs(units) do pcall(Changes.removeUnit, unit) end
            for _, panel in ipairs(panels) do pcall(Changes.remove, panel) end
        end)
        for _, c in ipairs(cands) do
            local far = true
            for _, o in ipairs(picked) do
                if math.abs(o:getX() - c.sq:getX()) + math.abs(o:getY() - c.sq:getY()) < 10 then far = false break end
            end
            if far and #panels < 3 then
                local okp, panel = pcall(Changes.install, c.sq, "S")
                if okp and panel then
                    panels[#panels + 1] = panel
                    picked[#picked + 1] = c.sq
                end
            end
        end
        if #panels == 0 then error("no box could be put down near the town spot") end
        -- a junction box (power) and a sprinkler (water) in the yard of each box, wired, as bu_floor.lua does
        local connectTimes = {}
        local function yard(panel, from, to, test)
            for r = from, to do
                for dx = -r, r do
                    for dy = -r, r do
                        if math.abs(dx) == r or math.abs(dy) == r then
                            local q = square(panel.x + dx, panel.y + dy, 0)
                            if q and q:isOutside() and q:isFree(false) and not Panels.buildingAt(q:getX(), q:getY(), 0) and test(q) then
                                return q
                            end
                        end
                    end
                end
            end
        end
        local function wire(kind, sq, sprite, panel)
            local ok, unit = pcall(Changes.installUnit, kind, sq, sprite)
            if not (ok and unit) then return end
            units[#units + 1] = unit
            local t0 = getTimestampMs()
            pcall(Changes.connectUnit, unit, panel, {})
            connectTimes[#connectTimes + 1] = getTimestampMs() - t0
        end
        for _, panel in ipairs(panels) do
            if BU.Dev and BU.Dev.setTier then pcall(BU.Dev.setTier, panel, 3) end
            local jsq = yard(panel, 6, 14, function(q)
                local place = Links.placeOn(panel, "power", q:getX(), q:getY(), 0, true)
                return Units.canInstall("junction", q) and place ~= nil and place.from == "wall" and place.length >= 4
            end)
            if jsq then wire("junction", jsq, BU.Relays.SPRITES.junction, panel) end
            local ssq = yard(panel, 8, 16, function(q)
                local place = Links.placeOn(panel, "water", q:getX(), q:getY(), 0)
                return Units.canInstall("sprinkler", q) and place ~= nil and place.length >= 4
            end)
            if ssq then wire("sprinkler", ssq, BU.WaterUnits.SPRINKLER_SPRITES.idle, panel) end
        end
        local total, lines = 0, 0
        for _ in pairs(Links.all()) do lines = lines + 1 end
        for _, v in ipairs(connectTimes) do total = total + v end
        say("bu panels=" .. #panels, "units=" .. #units, "lines in the store=" .. lines, "boxes in the store=" .. #BU.Store.list())
        say("bu.connect", "calls=" .. #connectTimes, "total_ms=" .. total, "mean_us=" .. f1(#connectTimes > 0 and total / #connectTimes * 1000 or 0),
            "(a one-off per unit, its route found; ms: " .. table.concat(connectTimes, ",") .. ")")
        -- rooms round the spot, for Spawned.places
        local rooms, seen = {}, {}
        for dx = -30, 30, 2 do
            for dy = -30, 30, 2 do
                local sq = square(s.x + dx, s.y + dy, 0)
                local room = sq and sq:getRoom()
                local key = room and (room:getName() .. sq:getX() .. "," .. sq:getY())
                if room and not seen[key] and #rooms < 12 then
                    seen[key] = true
                    rooms[#rooms + 1] = room
                end
            end
        end
        P.rooms = rooms
        -- fixed routes: straight legs of set lengths, and across and round the buildings nearest the spot
        local routes = {}
        for _, leg in ipairs({ { 6, 0 }, { 0, 10 }, { 14, 14 }, { -20, 6 }, { 25, -12 }, { 30, 0 } }) do
            routes[#routes + 1] = { s.x, s.y, s.x + leg[1], s.y + leg[2], 0, nil, nil }
        end
        local list = ArrayList.new()
        getWorld():getMetaGrid():getBuildingsIntersecting(s.x - 25, s.y - 25, 50, 50, list)
        local defs = {}
        for i = 0, list:size() - 1 do defs[#defs + 1] = list:get(i) end
        table.sort(defs, function(a, b) return a:getX() * 10000 + a:getY() < b:getX() * 10000 + b:getY() end)
        for i = 1, math.min(3, #defs) do
            local d = defs[i]
            local cy = d:getY() + math.floor(d:getH() / 2)
            routes[#routes + 1] = { d:getX() - 3, cy, d:getX() + d:getW() + 3, cy, 0, 1, 0 }
            if defs[i + 1] then
                routes[#routes + 1] = { d:getX() - 2, d:getY() - 2, defs[i + 1]:getX() + 1, defs[i + 1]:getY() - 2, 0, 0, 1 }
            end
        end
        P.routes = cfg.routes or routes
        P.panels, P.units = panels, units
        say("bu rooms=" .. #rooms, "routes=" .. #P.routes)
        return true
    end, "setup")
    P.bench("bu", "bu.lights_everyMinute", function() BU.Lights.everyMinute() end, { n = 400, warm = 3 })
    P.bench("bu", "bu.checkObjects", function() BU.Changes.checkObjects() end, { n = 400, warm = 3 })
    P.bench("bu", "bu.lookup.panels", function()
        local list = BU.Store.list()
        if BU.objectsByData then
            BU.objectsByData(BU.Panels.MODDATA, list)
        else
            for _, panel in ipairs(list) do BU.Panels.object(panel) end
        end
    end, { n = 2000, warm = 3, note = BU.objectsByData and "impl=objects.byData" or "impl=Panels.object each" })
    P.bench("bu", "bu.lookup.units", function()
        local list = BU.Store.unitList()
        if BU.objectsByData then
            BU.objectsByData(BU.Units.MODDATA, list)
        else
            for _, unit in ipairs(list) do BU.Units.object(unit) end
        end
    end, { n = 2000, warm = 3, note = BU.objectsByData and "impl=objects.byData" or "impl=Units.object each" })
    P.bench("bu", "bu.spawned_places", function(i) BU.Spawned.places(nth(P.rooms, i)) end,
        { n = 240, warm = 3, note = BU.objectsByData and "impl=squares.list" or "impl=room:getSquares loop" })
    P.bench("bu", "bu.links_walk", function(i)
        local a = nth(P.routes, i)
        BU.Links.walk(a[1], a[2], a[3], a[4], a[5], a[6], a[7])
    end, { n = 200, warm = 3, note = BU.objectsByData and "impl=squares.path" or "impl=Lua dijkstra" })
    P.add("bu", "bu routes", function()
        for i, a in ipairs(P.routes) do
            local path = BU.Links.walk(a[1], a[2], a[3], a[4], a[5], a[6], a[7])
            local flat = {}
            for _, q in ipairs(path or {}) do
                flat[#flat + 1] = q.x
                flat[#flat + 1] = q.y
            end
            say("bu.route " .. i, "from=" .. a[1] .. "," .. a[2], "to=" .. a[3] .. "," .. a[4],
                "into=" .. tostring(a[6]) .. "," .. tostring(a[7]), "len=" .. (path and #path or "none"), "hash=" .. hashOf(flat))
        end
        return true
    end)
    P.bench("bu", "bu.floorlines_wanted", function() BU.FloorLines.wanted() end, { n = 400, warm = 3 })
    if cfg.minuteEvent then
        P.bench("bu", "bu.event_EveryOneMinute", function() triggerEvent("EveryOneMinute") end, { n = 20, g = 1, warm = 1 })
    end
    P.add("bu", "bu cleanup", function() P.unwind("bu") P.panels, P.units = nil, nil return true end, "cleanup")
end

-- alarm.*: the Senses alarm job (a Pulse job, once a second in the game), its closure taken from the Pulse's timer and
-- run in batches here, with alarms on the 6 nearest houses and cars of the town spot and the alarm research node at
-- rank 1. And the two scans in it, each as that build does it: alarm.vehicles (c0 OA.vehicles and a distance loop, c1
-- vehicles.near) and alarm.entries (c0 a grid of getSpecialObjects, c1 objects.find).
local function groupAlarms()
    P.go("alarms", "town")
    P.add("alarms", "alarms setup", function()
        local Sense = OA.Upgrades.Sense
        local Dev = OA.Dev
        if not Dev then error("OperationAcornDev is not on") end
        local px, py = player():getX(), player():getY()
        local list = ArrayList.new()
        getWorld():getMetaGrid():getBuildingsIntersecting(math.floor(px - 30), math.floor(py - 30), 60, 60, list)
        local defs = {}
        for i = 0, list:size() - 1 do
            local def = list:get(i)
            local dx, dy = def:getX() + def:getW() / 2 - px, def:getY() + def:getH() / 2 - py
            defs[#defs + 1] = { def = def, d = dx * dx + dy * dy }
        end
        table.sort(defs, function(a, b) return a.d < b.d end)
        local houses, cars = 0, 0
        for i = 1, math.min(6, #defs) do
            local def = defs[i].def
            local was = def:isAlarmed()
            def:setAlarmed(true)
            houses = houses + 1
            P.pushUndo("alarms", function() def:setAlarmed(was) end)
        end
        local vehicles = OA.vehicles()
        local near = {}
        for i = 0, vehicles:size() - 1 do
            local v = vehicles:get(i)
            local dx, dy = v:getX() - px, v:getY() - py
            if dx * dx + dy * dy <= 900 then near[#near + 1] = { v = v, d = dx * dx + dy * dy } end
        end
        table.sort(near, function(a, b) return a.d < b.d end)
        for i = 1, math.min(6, #near) do
            local v = near[i].v
            local was, entered = v:isAlarmed(), v:isPreviouslyEntered()
            v:setAlarmed(true)
            v:setPreviouslyEntered(false)
            cars = cars + 1
            P.pushUndo("alarms", function()
                v:setAlarmed(was)
                v:setPreviouslyEntered(entered)
            end)
        end
        say("alarms houses=" .. houses .. "/" .. #defs .. " within 30", "cars=" .. cars .. "/" .. #near .. " within 30",
            "vehicles in the cell=" .. vehicles:size())
        -- the research node
        local record = Dev.record()
        if not record then error("no record") end
        local was = OA.Upgrades.Rules.rank(OA.Upgrades.Rules.section(record), "alarm") or 0
        Dev.ranks({ alarm = 1 })
        P.pushUndo("alarms", function() Dev.ranks({ alarm = was }) end)
        -- the job: Pulse.enable asks OA.timerOn for a timer of each job; the closure given for the 1000 ms one is the job
        local realOn = OA.timerOn
        local caught
        OA.timerOn = function(slot, opts, fn)
            if opts and opts.ms == 1000 then caught = fn end
            return realOn(slot, opts, fn)
        end
        local okEnable, errEnable = pcall(OA.Upgrades.Pulse.enable, true)
        OA.timerOn = realOn
        if not okEnable then error(errEnable) end
        P.alarmJob = caught
        P.carReach = Sense.ALARM_CAR + math.max(Sense.ALARM_LEAVE, Sense.ALARM_NEAR)
        P.entry = Sense.ALARM_NEAR
        P.vlist = ArrayList.new()
        return true
    end, "setup")
    P.bench("alarms", "alarm.job", function()
        if not P.alarmJob then error("no job captured (no API timers: the Pulse runs on an OnTick handler)") end
        P.alarmJob()
    end, { n = 2000, warm = 3, note = "the whole alarmJob; the game runs it once a second" })
    P.bench("alarms", "alarm.vehicles", function()
        local p = player()
        local px, py, pz = p:getX(), p:getY(), math.floor(p:getZ())
        local reach2 = P.carReach * P.carReach
        local n = 0
        if isC1 then
            for _, v in ipairs(PZExtAPI.vehicles.near(px, py, pz, P.carReach)) do
                local dx, dy = v:getX() - px, v:getY() - py
                if dx * dx + dy * dy <= reach2 then n = n + 1 end
            end
        else
            local list = OA.vehicles(P.vlist)
            for i = 0, list:size() - 1 do
                local v = list:get(i)
                local dx, dy = v:getX() - px, v:getY() - py
                if dx * dx + dy * dy <= reach2 then n = n + 1 end
            end
        end
        P.carsInReach = n
    end, { n = 4000, warm = 3, note = isC1 and "impl=vehicles.near" or "impl=OA.vehicles + loop" })
    P.bench("alarms", "alarm.entries", function()
        local p = player()
        local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
        local e = P.entry
        if isC1 then
            P.entries = #PZExtAPI.objects.find({ x1 = px - e, y1 = py - e, x2 = px + e, y2 = py + e, z = pz },
                { class = { "IsoDoor", "IsoWindow" } })
        else
            local cell = getCell()
            local n = 0
            for x = px - e, px + e do
                for y = py - e, py + e do
                    local sq = cell:getGridSquare(x, y, pz)
                    local special = sq and sq:getSpecialObjects()
                    if special then
                        for i = 0, special:size() - 1 do
                            local obj = special:get(i)
                            if instanceof(obj, "IsoDoor") or instanceof(obj, "IsoWindow") then n = n + 1 end
                        end
                    end
                end
            end
            P.entries = n
        end
    end, { n = 4000, warm = 3, note = isC1 and "impl=objects.find" or "impl=getSpecialObjects grid" })
    P.add("alarms", "alarm what", function()
        say("alarm.scene", "cars in reach=" .. tostring(P.carsInReach), "doors and windows in the entry box=" .. tostring(P.entries))
        return true
    end)
    P.add("alarms", "alarms cleanup", function() P.unwind("alarms") P.alarmJob = nil return true end, "cleanup")
end

-- api.* and dense/towns (c1 only): the API's map reads (kept in memory after the first; this run's first may already be
-- the second, the mod asked at its world start), Dense.look and Towns.enter on fake records (a record of its own each
-- call, so Dense.look's one-a-second throttle does not hide the work).
local function groupDense()
    local ids = { "api.zombies.dense", "api.zones.clusters", "dense.look.far", "dense.look.near", "towns.enter.idle",
        "towns.enter.out", "towns.enter.town", "towns.enter.done" }
    if not isC1 or not has("zombies", "dense") then
        for _, id in ipairs(ids) do P.na(id, "c1 only") end
        return
    end
    P.go("dense", "town")
    P.add("dense", "dense first calls", function()
        local t0 = getTimestampMs()
        local dense = PZExtAPI.zombies.dense({ min = 160, minChunks = 6 })
        local t1 = getTimestampMs()
        local clusters = PZExtAPI.zones.clusters("TownZone", { buildings = true })
        local t2 = getTimestampMs()
        say("api.first", "zombies.dense ms=" .. (t1 - t0), "places=" .. #dense, "zones.clusters ms=" .. (t2 - t1),
            "clusters=" .. #clusters, "(this run's first calls; the mods asked at the world's start: memory already)")
        return true
    end)
    P.bench("dense", "api.zombies.dense", function() PZExtAPI.zombies.dense({ min = 160, minChunks = 6 }) end, { n = 400, warm = 3 })
    P.bench("dense", "api.zones.clusters", function() PZExtAPI.zones.clusters("TownZone", { buildings = true }) end,
        { n = 400, warm = 3 })
    P.add("dense", "dense setup", function()
        local record = OA.Dev and OA.Dev.record()
        if not record then error("no record") end
        local list = OA.Dense.ensure() or {}
        local realTier = OA.Trust.tier
        OA.Trust.tier = function() return 99 end
        P.pushUndo("dense", function() OA.Trust.tier = realTier end)
        P.fakes = 0
        P.fake = function(extra)
            P.fakes = P.fakes + 1
            local f = setmetatable({ id = "perf_r3_" .. P.fakes, dense = { got = {} } }, { __index = record })
            for k, v in pairs(extra or {}) do f[k] = v end
            return f
        end
        local s = P.spots
        P.far = { s.open.x, s.open.y }
        P.nearPlace = nil
        for _, p in ipairs(list) do
            if not OA.Dense.cleared(p.id) then
                P.nearPlace = p
                break
            end
        end
        if P.nearPlace then
            local w = OA.Store.world("dense")
            local id = P.nearPlace.id
            local was = w.baseline and w.baseline[id]
            P.pushUndo("dense", function() if w.baseline then w.baseline[id] = was end end)
        end
        say("dense places=" .. #list, "near place=" .. (P.nearPlace and P.nearPlace.id or "none"))
        local w = OA.Towns.index()
        P.townsW = w
        if w then
            local at = OA.Towns.at(w, s.town.x, s.town.y)
            P.townAt = at
            local ndone, doneWas = w.ndone, at and w.done[at]
            P.pushUndo("dense", function()
                w.ndone = ndone
                if at then w.done[at] = doneWas end
            end)
            say("towns indexed=" .. #w.list, "town at the town spot=" .. tostring(at), "towns done in the world=" .. tostring(w.ndone))
        end
        return true
    end, "setup")
    P.bench("dense", "dense.look.far", function() OA.Dense.look(P.fake(), P.far[1], P.far[2]) end,
        { n = 4000, warm = 3, note = "no place within 20: distances only" })
    P.bench("dense", "dense.look.near", function()
        local p = P.nearPlace
        OA.Dense.look(P.fake(), p.x + 3, p.y + 3)
    end, { n = 600, warm = 3, note = "a place within 20: its zombies.near count",
        skipIf = function() if P.nearPlace then return false end P.na("dense.look.near", "no uncleared dense place") return true end })
    P.bench("dense", "towns.enter.idle", function()
        OA.Towns.enter(P.fake({ shop = { restock = { towns = {} } } }), P.spots.town.x, P.spots.town.y)
    end, { n = 4000, warm = 3, note = "the world's real state (no town done: returns at once)" })
    P.add("dense", "towns patch", function()
        if not P.townsW then error("towns not indexed") end
        P.townsW.ndone = 1
        return true
    end, "setup")
    P.bench("dense", "towns.enter.out", function()
        OA.Towns.enter(P.fake({ shop = { restock = { towns = {} } } }), P.far[1], P.far[2])
    end, { n = 4000, warm = 3, note = "a town is done in the world, the record is out of town: Towns.at" })
    P.bench("dense", "towns.enter.town", function()
        OA.Towns.enter(P.fake({ shop = { restock = { towns = {} } } }), P.spots.town.x, P.spots.town.y)
    end, { n = 4000, warm = 3, note = "in a town that is not done" })
    P.add("dense", "towns patch 2", function()
        if P.townAt then
            P.townsW.done[P.townAt] = true
        else
            P.na("towns.enter.done", "the town spot is in no town of 20 buildings")
        end
        return true
    end)
    P.bench("dense", "towns.enter.done", function()
        local towns = {}
        towns[P.townAt] = true
        OA.Towns.enter(P.fake({ shop = { restock = { towns = towns } } }), P.spots.town.x, P.spots.town.y)
    end, { n = 4000, warm = 3, note = "in a done town the record has the share of: Towns.at and the record's list",
        skipIf = function() return not P.townAt end })
    P.add("dense", "dense cleanup", function() P.unwind("dense") return true end, "cleanup")
end

-- heavy.* (one-offs, call by call, the first one cold; each with a frames line whose max is the pause the player sees):
--   heavy.findClear      Objects.findClear from 10 fixed points, 5 at the open spot, 5 in town (both)
--   heavy.settleGround   StoryGame.settleGround on 5 open sites near the open spot and 1 in town (both)
--   heavy.pickSite       Missions.pickSite for levels 1 to 4, a building and open ground twice each (both; random picks)
--   heavy.meteor_onChunk Sites.onChunk on a temporary site in 3 chunks round the open spot (both; it builds there)
--   heavy.stage_build    Dev.buildScene() of the live mission, 3 times (both; needs a mission with a building piece)
local function groupHeavy()
    P.go("heavy", "open")
    P.add("heavy", "heavy setup", function()
        P.points = {}
        local s = P.spots
        local offs = { { 0, 0 }, { 12, 6 }, { -14, 9 }, { 8, -15 }, { -9, -12 } }
        for _, o in ipairs(offs) do P.points[#P.points + 1] = { s.open.x + o[1], s.open.y + o[2] } end
        for _, o in ipairs(offs) do P.points[#P.points + 1] = { s.town.x + o[1], s.town.y + o[2] } end
        P.record = OA.Dev and OA.Dev.record()
        P.found, P.settled, P.siteStates = {}, {}, ""
        return true
    end, "setup")
    P.once("heavy", "heavy.findClear", 10, function(i)
        local pt = P.points[i]
        local sq, clearance = OA.Trade.Objects.findClear(pt[1], pt[2], 30, false)
        P.found[#P.found + 1] = sq and (sq:getX() * 10000 + sq:getY()) or -1
        P.found[#P.found + 1] = clearance or -1
    end, "(5 points at the open spot, 5 in town)")
    P.add("heavy", "findClear result", function()
        say("heavy.findClear.result", "hash=" .. hashOf(P.found), "(the squares and clearances found: the same on both builds when the same squares are loaded)")
        return true
    end)
    P.once("heavy", "heavy.settleGround", 6, function(i)
        if not P.record then error("no record") end
        local pt = i <= 5 and P.points[i] or P.points[6]
        local m = { site = { x = pt[1], y = pt[2], z = 0, ground = true, key = "g:perf" .. i }, items = {} }
        local done = OA.StoryGame.settleGround(P.record, m)
        P.settled[#P.settled + 1] = math.floor(m.site.x)
        P.settled[#P.settled + 1] = math.floor(m.site.y)
        P.settled[#P.settled + 1] = done and 1 or 0
    end, "(5 sites at the open spot, 1 in town)")
    P.add("heavy", "settle result", function()
        say("heavy.settleGround.result", "hash=" .. hashOf(P.settled), "(where the sites settled)")
        return true
    end)
    P.once("heavy", "heavy.pickSite", 16, function(i)
        if not P.record then error("no record") end
        local level = math.floor((i - 1) / 4) + 1
        local spec = (i - math.floor(i / 2) * 2 == 1) and { want = "public" } or { ground = true }
        if not OA.Missions.pickSite(P.record, level, spec) then error("no site (no base known for the record?)") end
    end, "(levels 1 to 4, a building and open ground, twice each; random picks)")
    P.add("heavy", "meteor setup", function()
        local sec = OA.Store.world("sites")
        local hadList = sec.list
        sec.list = sec.list or {}
        local added = {}
        P.sites = { sec = sec, added = added }
        P.pushUndo("heavy", function()
            for _, site in ipairs(added) do
                for i = #sec.list, 1, -1 do
                    if sec.list[i] == site then table.remove(sec.list, i) end
                end
            end
            if not hadList then sec.list = nil end
        end)
        return true
    end, "setup")
    P.once("heavy", "heavy.meteor_onChunk", 3, function(i)
        local s = P.spots.open
        local x, y = s.x + (i - 2) * 16, s.y + 3
        local sq = square(x, y, 0)
        if not sq then error("square not loaded") end
        local n = 9000 + i
        local site = { n = n, x = x, y = y, kind = "stony", stake = 555, date = 1, state = "pending", tries = 0 }
        local list = P.sites.sec.list
        list[#list + 1] = site
        P.sites.added[#P.sites.added + 1] = site
        OA.Sites.onChunk({ kind = "oa_site", site = n, x = x, y = y, z = 0 }, sq:getChunk())
        P.siteStates = P.siteStates .. site.state .. " "
    end, "(3 chunks round the open spot; it builds objects there)")
    P.add("heavy", "meteor result", function()
        say("heavy.meteor.states", P.siteStates, "(placed: a land square was found in the chunk)")
        return true
    end)
    P.add("heavy", "stage setup", function(t)
        local Dev = OA.Dev
        if not (Dev and Dev.missionPlace and Dev.missionPlace()) then
            P.na("heavy.stage_build", "no live mission with a building piece in the save")
            P.noStage = true
            return true
        end
        if not t.went then
            t.went, t.t0 = true, getTimestampMs()
            Dev.gotoMission()
            return false
        end
        return getTimestampMs() - t.t0 >= 9000
    end, "setup")
    P.once("heavy", "heavy.stage_build", 3, function()
        if not OA.Dev.buildScene() then error("the scene was not built (the building not loaded?)") end
    end, "(the live mission's stage; each comes on top of the one before)", function() return P.noStage end)
    P.add("heavy", "heavy cleanup", function() P.unwind("heavy") return true end, "cleanup")
end

-- ---- run -----------------------------------------------------------------------------------------------------------

P.spots = readSpots()
header()
local missing = {}
for _, name in ipairs({ "open", "town" }) do
    if not P.spots[name] then missing[#missing + 1] = name end
end
if #missing > 0 then
    say("BAD no spot marked: " .. table.concat(missing, ", ") .. " (stand there and run: pzdev run \"PERF_NAME='" .. missing[1]
        .. "' RUN('perf_r3.lua')\")")
    PERF_R3 = nil
    say("done: 1 BAD")
    return
end
if isGamePaused() then
    say("BAD the game is paused (the frames stand still)")
    PERF_R3 = nil
    say("done: 1 BAD")
    return
end
say("spot open=" .. P.spots.open.x .. "," .. P.spots.open.y, "town=" .. P.spots.town.x .. "," .. P.spots.town.y)

-- the machines, the BU lines and the alarms are set up and taken away by their groups; the one-offs come last (they
-- build in the world)
local groups = { { "frames", groupFrames }, { "cursor", groupCursor }, { "machines", groupMachines }, { "bu", groupBU },
    { "alarms", groupAlarms }, { "dense", groupDense }, { "heavy", groupHeavy } }
for _, g in ipairs(groups) do
    if not (cfg.skip and cfg.skip[g[1]]) then g[2]() end
end
say("tasks=" .. #P.tasks)
Events.OnPostUIDraw.Add(P.onFrame)
