-- Helpers the P10 (round 3) checks share (P10T). Each check runs RUN("p10_lib.lua") first; the state it keeps (the
-- running task, the queue of p10_all) survives running it again.
--
-- An area is one check file: P10T.start("p10x", function(a) ... end) makes it (a.say, a.check, a.cleanup), runs the
-- body, and ends it with "[p10x] done: N BAD" (pzdev check follows a file until a "done: " line; under p10_all the
-- line says "end: N BAD" and p10_all prints the one "done: "). A body that needs the game to run on (a teleport, a
-- minute passing) hands its steps to P10T.run(a, steps): each step is { after = ms after the one before, ready =
-- function(a) -> true when the step may run (polled each frame, optional), within = ms to wait for it (5000), run =
-- function(a, timedOut) }. The steps run from the frames (also while the game is paused); the area ends after the last
-- one, and what a.cleanup registered runs then, last registered first, whatever failed before.
P10T = P10T or {}
P10T.titleKeys = P10T.titleKeys or {}

local OA = OperationAcorn

local function join(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end
P10T.join = join

-- ---- areas ---------------------------------------------------------------------------------------------------

function P10T.area(tag)
    local a = { tag = tag, bad = 0, cleanups = {}, finished = false, inAll = P10T.fromQueue == true }
    function a.say(...) print("[" .. tag .. "] " .. join(...)) end
    -- Prints "<label> ok|BAD <detail>"; returns the condition.
    function a.check(label, condition, detail)
        if not condition then a.bad = a.bad + 1 end
        a.say(label, condition and "ok" or "BAD", detail ~= nil and tostring(detail) or "")
        return condition and true or false
    end
    function a.cleanup(fn) a.cleanups[#a.cleanups + 1] = fn end
    function a.finish()
        if a.finished then return end
        a.finished = true
        for i = #a.cleanups, 1, -1 do
            local ok, err = pcall(a.cleanups[i], a)
            if not ok then
                a.bad = a.bad + 1
                a.say("cleanup", "BAD", tostring(err))
            end
        end
        a.say((a.inAll and "end: " or "done: ") .. a.bad .. " BAD")
        local q = P10T.queue
        if q and a.inAll then
            q.bad = q.bad + a.bad
            q.n = q.n + 1
        end
    end
    return a
end

-- Makes an area, runs body(a), and ends it unless the body started steps (P10T.run).
function P10T.start(tag, body)
    local a = P10T.area(tag)
    P10T.current = a
    -- the titles any area shows are noted, so that the titles check can wait for them to go (taken off again at the end
    -- of a standalone area, or of p10_all)
    local installed = not P10T.tapped and P10T.tap()
    if installed and not a.inAll then a.cleanup(P10T.untap) end
    local ok, err = pcall(body, a)
    if not ok then a.check("script error", false, err) end
    if not a.finished and not (P10T.task and P10T.task.a == a) then a.finish() end
    return a
end

-- ---- steps, run from the frames ------------------------------------------------------------------------------

local function stepRun(t, now, timedOut)
    local step = t.steps[t.i]
    local ok, err = pcall(step.run, t.a, timedOut)
    if not ok then t.a.check("step error " .. tostring(step.name or t.i), false, err) end
    t.i = t.i + 1
    t.began = nil
    local nxt = t.steps[t.i]
    if nxt then
        t.due = now + (nxt.after or 0)
    else
        P10T.task = nil
        t.a.finish()
    end
end

-- The queue of p10_all: the next file is started when the area before it ended.
function P10T.pump()
    local q = P10T.queue
    if not q then return end
    if P10T.current and not P10T.current.finished then return end
    if q.i >= #q.files then
        P10T.queue = nil
        P10T.untap()
        print("[p10all] done: " .. q.bad .. " BAD in " .. q.n .. " areas")
        return
    end
    q.i = q.i + 1
    local file = q.files[q.i]
    print("[p10all] ---- " .. file)
    P10T.fromQueue = true
    local ok, err = pcall(RUN, file)
    P10T.fromQueue = false
    if not ok then
        print("[p10all] ERROR in " .. file .. ": " .. tostring(err))
        q.bad = q.bad + 1
        if P10T.current and not P10T.current.finished then P10T.current.finish() end
    end
end

function P10T.tick()
    local now = getTimestampMs()
    local t = P10T.task
    if not t then
        P10T.pump()
        return
    end
    if now < t.due then return end
    local step = t.steps[t.i]
    if not step.ready then
        stepRun(t, now, false)
        return
    end
    if not t.began then t.began = now end
    local ok, ready = pcall(step.ready, t.a)
    if ok and ready then
        stepRun(t, now, false)
    elseif now - t.began >= (step.within or 5000) then
        stepRun(t, now, true)
    end
end

if not P10T.hooked then
    P10T.hooked = true
    Events.OnTickEvenPaused.Add(function() P10T.tick() end)
    Events.OnPostUIDraw.Add(function() if P10T.onFrame then P10T.onFrame() end end)
end

function P10T.run(a, steps)
    if #steps == 0 then return end
    if P10T.task then error("p10: a task is running already", 2) end
    P10T.task = { a = a, steps = steps, i = 1, due = getTimestampMs() + (steps[1].after or 0) }
end

-- Starts the files one after another (p10_all). Each file ends its area; the next starts when it has.
function P10T.runAll(files)
    P10T.queue = { files = files, i = 0, bad = 0, n = 0 }
    P10T.titleKeys = {}
    print("[p10all] " .. #files .. " areas")
end

-- ---- the world ---------------------------------------------------------------------------------------------

function P10T.near(x, y, eps)
    return type(x) == "number" and type(y) == "number" and math.abs(x - y) <= (eps or 1e-6)
end

-- The character and its record (made by the first hello), or nil.
function P10T.record()
    local player = getPlayer()
    local id = player and player:getModData().OA_Id
    return id and OA.Store.player(id), player
end

-- PZ Extension API Dev's environment (time, speed, teleport, god mode), or nil.
function P10T.env()
    return PZExtDev and PZExtDev.Env or nil
end

-- Deep copy of plain tables (a section of the save).
function P10T.copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = P10T.copy(v) end
    return c
end

-- Puts the copy's contents back into the same table (other code holds it).
function P10T.restoreInto(target, copy)
    local keys = {}
    for k in pairs(target) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do target[k] = nil end
    for k, v in pairs(copy) do target[k] = P10T.copy(v) end
end

-- Moves the character to a square of the ground floor (the chunk loads next).
function P10T.tp(x, y, z)
    local env = P10T.env()
    if env and env.teleport then
        env.teleport(x, y, z or 0)
    else
        local p = getPlayer()
        p:setX(x + 0.5); p:setY(y + 0.5); p:setZ(z or 0)
        p:setLastX(x + 0.5); p:setLastY(y + 0.5); p:setLastZ(z or 0)
    end
end

-- The character where it stands: x, y, z (whole squares).
function P10T.where()
    local p = getPlayer()
    return math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
end

-- God mode on for a check that goes to far places and to crowds; back as it was when the area ends.
function P10T.god(a)
    local p = getPlayer()
    local was, wasInvisible = p:isGodMod(), p:isInvisible()
    p:setGodMod(true)
    p:setInvisible(true)
    a.cleanup(function()
        p:setGodMod(was)
        p:setInvisible(wasInvisible)
    end)
end

-- The hour of the day set (0..24), put back as it was when the area ends.
function P10T.hourBack(a)
    local was = getGameTime():getTimeOfDay()
    a.cleanup(function() getGameTime():setTimeOfDay(was) end)
    return was
end

-- ---- scratch records -----------------------------------------------------------------------------------------

-- Takes a scratch record away (and the numbers that point at it).
function P10T.drop(id)
    local root = OA.Store.root()
    local r = root.players[id]
    if r then
        -- (a check may have changed the record's number: every number that points at it goes)
        local numbers = {}
        for number, owner in pairs(root.numbers) do
            if owner == id then numbers[#numbers + 1] = number end
        end
        for _, number in ipairs(numbers) do root.numbers[number] = nil end
        root.players[id] = nil
    end
    if OA.Trust and OA.Trust.reset then OA.Trust.reset() end
end

-- A record of its own for a check (a character that never lived): the real one is left alone. Its trade section has the
-- stage and milestones that make its tier. Taken away again when the area ends; with `keep` it stays under the id
-- "p10_<name>" (for a check that goes on after a reload; that one takes it away).
function P10T.scratch(a, name, stage, milestones, keep)
    P10T.count = (P10T.count or 0) + 1
    local id = keep and ("p10_" .. name) or ("p10_" .. name .. "_" .. P10T.count)
    P10T.drop(id)
    local r = OA.Store.ensure(id, "P10 " .. name)
    r.trade = { credits = 0, trust = 0, stage = stage or 3, milestones = milestones or 0, bonus = 0, sharedSerums = 0,
        levels = {} }
    OA.Trust.reset()
    -- The story section is made now, as a character that started the world: a record made after another one has been
    -- handed over (the real one in an E2E save, a scratch one of this run) would join the world after the handover.
    local Story = OA.Story
    if Story and Story.section and Story.worldClock then
        local clock = Story.worldClock
        Story.worldClock = function() return 0, false end
        local ok, err = pcall(Story.section, r)
        Story.worldClock = clock
        if not ok then a.say("the story section of", id, "could not be made:", tostring(err)) end
    end
    if not keep then a.cleanup(function() P10T.drop(id) end) end
    return r
end

function P10T.isScratch(id)
    return type(id) == "string" and string.sub(id, 1, 4) == "p10_"
end

-- Records what OA.Sync.<what> is told for a scratch record (a title, a notice, a sound): nothing of it reaches the
-- screen; what is told for any other record goes on to the real function. With `watch` every call is recorded, the
-- real record's too, and all go on to the real function. Put back when the area ends. Returns the list of
-- { id = , detail = } (a notice's detail is { key, args }, a sound's the cue).
function P10T.capture(a, what, watch)
    local list = {}
    local real = OA.Sync[what]
    OA.Sync[what] = function(id, first, second)
        local scratch = P10T.isScratch(id)
        if scratch or watch then
            local detail = first
            if what == "notice" then detail = { key = first, args = second } end
            list[#list + 1] = { id = id, detail = detail }
        end
        if scratch then return end
        return real(id, first, second)
    end
    a.cleanup(function() OA.Sync[what] = real end)
    return list
end

function P10T.keys(list)
    local out = {}
    for _, e in ipairs(list) do
        local d = e.detail
        out[#out + 1] = type(d) == "table" and (d.key or "?") or tostring(d)
    end
    return table.concat(out, ",")
end

-- ---- titles --------------------------------------------------------------------------------------------------

-- Notes each title the API is given (its key, the real time, its text and style), so that a check can ask whether it is
-- still on the screen. The function is only wrapped, never changed. P10T.untap() puts the API's own back.
function P10T.tap()
    if P10T.tapped then return true end
    local api = OA.api()
    local text = api and api.text
    if type(text) ~= "table" or type(text.title) ~= "function" then return false end
    local orig = text.title
    local ok = pcall(function()
        text.title = function(handle, spec)
            local key = orig(handle, spec)
            P10T.titleKeys[#P10T.titleKeys + 1] = { key = key, at = getTimestampMs(), text = spec and spec.text,
                style = spec and spec.style, now = spec and spec.now }
            return key
        end
    end)
    if not ok then return false end
    P10T.tapped = { text = text, orig = orig }
    return true
end

function P10T.untap()
    local t = P10T.tapped
    if not t then return end
    P10T.tapped = nil
    pcall(function() t.text.title = t.orig end)
end

-- Whether the API still has a title it was given through the tap on the screen or waiting.
function P10T.shown(key)
    local api = OA.api()
    local handle = OA.handle()
    if not (api and handle and key) then return false end
    local ok, res = pcall(api.text.shown, handle, key)
    return ok and res == true
end

-- How many titles given through the tap are on the screen or waiting.
function P10T.titlesPending()
    local n = 0
    for _, t in ipairs(P10T.titleKeys) do
        if P10T.shown(t.key) then n = n + 1 end
    end
    return n
end

-- ---- items ---------------------------------------------------------------------------------------------------

function P10T.give(fullType)
    return getPlayer():getInventory():AddItem(fullType)
end

-- Writes lines to a file under Zomboid/Lua (a check that survives a reload); the old file is replaced.
function P10T.write(path, lines)
    local w = getFileWriter(path, true, false)
    for _, line in ipairs(lines) do w:write(line .. "\n") end
    w:close()
end

-- The lines of a file under Zomboid/Lua, or nil.
function P10T.read(path)
    local r = getFileReader(path, false)
    if not r then return nil end
    local lines = {}
    local line = r:readLine()
    while line do
        lines[#lines + 1] = line
        line = r:readLine()
    end
    r:close()
    return lines
end
