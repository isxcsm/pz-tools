-- The one timer the upgrade effects share (FEASIBILITY: throttled timers, never per tick). A single OnTick handler that
-- is added only while the character has a node that needs it, and that does nothing but compare the clock until a
-- job is due. Jobs: Pulse.job(name, period in ms, function(now)).
local OA = OperationAcorn
OA.Upgrades = OA.Upgrades or {}
local Pulse = {}
OA.Upgrades.Pulse = Pulse

local jobs = {}
local wake = 0
local added = false

function Pulse.job(name, period, fn)
    jobs[#jobs + 1] = { name = name, period = period, fn = fn, due = 0 }
end

local function onTick()
    local now = getTimestampMs()
    if now < wake then return end
    local nextWake = now + 1000
    for _, job in ipairs(jobs) do
        if now >= job.due then
            job.due = now + job.period
            local ok, err = pcall(job.fn, now)
            if not ok then OA.log("pulse job", job.name, "failed:", tostring(err)) end
        end
        if job.due < nextWake then nextWake = job.due end
    end
    wake = nextWake
end

-- Turns the timer on or off (on while some node needs it).
function Pulse.enable(on)
    if on and not added then
        added = true
        wake = 0
        Events.OnTick.Add(onTick)
    elseif not on and added then
        added = false
        Events.OnTick.Remove(onTick)
    end
end

function Pulse.enabled()
    return added
end

return Pulse
