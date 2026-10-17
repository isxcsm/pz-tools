-- The one timer the upgrade effects share (FEASIBILITY: throttled timers, never per tick). With the extension API each
-- job is a timer of its own period (PZExtAPI.timers.every: counted in Java, so no frame wakes Lua until a job is due);
-- without its timers a single OnTick handler does the same, comparing the clock until a job is due. Either way it runs
-- only while the character has a node that needs it. Jobs: Pulse.job(name, period in ms, function(now)). The jobs look
-- and tell and draw; none changes the world (the timers go on while the game is paused, an OnTick does not).
local OA = OperationAcorn
OA.Upgrades = OA.Upgrades or {}
local Pulse = {}
OA.Upgrades.Pulse = Pulse

local jobs = {}
local wake = 0
local added = false
-- Whether the jobs run on the API's timers (else on the OnTick handler). The handler, once added, stays (`hooked`: one
-- taken off inside its event makes the game skip the next one that tick) and returns at once while it is not used.
local timed, hooked = false, false

function Pulse.job(name, period, fn)
    local job = { name = name, period = period, fn = fn, due = 0, slot = {} }
    jobs[#jobs + 1] = job
end

local function runJob(job, now)
    local ok, err = pcall(job.fn, now)
    if not ok then OA.log("pulse job", job.name, "failed:", tostring(err)) end
end

local function onTick()
    if not added or timed then return end
    local now = getTimestampMs()
    if now < wake then return end
    local nextWake = now + 1000
    for _, job in ipairs(jobs) do
        if now >= job.due then
            job.due = now + job.period
            runJob(job, now)
        end
        if job.due < nextWake then nextWake = job.due end
    end
    wake = nextWake
end

-- Every job's first run, at the next frame as the handler's (each is due at once).
local function firstRuns()
    if not added then return end
    local now = getTimestampMs()
    for _, job in ipairs(jobs) do runJob(job, now) end
end

-- A timer for each job (the ones of this world that are running are kept); false, with none left running, when the API
-- has no timers.
local function startTimers()
    local fresh = false
    for _, job in ipairs(jobs) do
        local ok, made = OA.timerOn(job.slot, { ms = job.period }, function() runJob(job, getTimestampMs()) end)
        if not ok then
            for _, other in ipairs(jobs) do OA.timerOff(other.slot) end
            return false
        end
        fresh = fresh or made
    end
    if fresh then OA.timerAfter(1, firstRuns) end
    return true
end

local function stopTimers()
    for _, job in ipairs(jobs) do OA.timerOff(job.slot) end
end

-- Turns the timer on or off (on while some node needs it). Called again while on, it sees that the timers are there (a
-- world left drops them, and the game started again calls this again). Every job is there before this is first called.
function Pulse.enable(on)
    if on then
        if added and not timed then return end
        if OA.canTimer() and startTimers() then
            added, timed = true, true
            return
        end
        if added then return end
        added, timed = true, false
        wake = 0
        if not hooked then
            hooked = true
            Events.OnTick.Add(onTick)
        end
    elseif added then
        added = false
        if timed then stopTimers() end
        timed = false
    end
end

function Pulse.enabled()
    return added
end

return Pulse
