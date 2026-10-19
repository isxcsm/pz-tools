-- The grades as a player meets them (E2E.md 11.1): after the handover, trust added the way a settlement adds it
-- (Trade.addTrust) one tier at a time, U_GRADES_GAP real seconds apart so each stamp is seen; each step prints the
-- tier, the grade, the designation and the terminal's title, and the titles come as [st] lines (story_lib).
-- Changes the record (its trust). Lines are tagged "[ugrades]".
local OA = OperationAcorn
local r = OA.Dev.record()
local function say(...) print("[ugrades]", ...) end
local steps = U_GRADES_STEPS or 9
local gap = (U_GRADES_GAP or 16) * 1000
local done, next = 0, getTimestampMs()

local function threshold(tier)
    -- tier = 5 + milestones past the last stage
    return OA.Trust.milestoneThreshold(tier - OA.Trust.STAGES)
end

local function tick()
    if getTimestampMs() < next then return end
    if done >= steps then
        Events.OnTick.Remove(tick)
        say("done")
        return
    end
    done = done + 1
    local tier = OA.Trust.tier(r)
    local need = threshold(tier + 1) - (r.trade.trust or 0)
    OA.Trade.addTrust(r, math.max(1, need), "e2e")
    local win = OATerminalWindow and OATerminalWindow.instances[0]
    say("tier", OA.Trust.tier(r), "grade", tostring(OA.Story.grade(r)), "designation", OA.Story.designation(r),
        "terminal", win and win.title or "-")
    next = getTimestampMs() + gap
end
Events.OnTick.Add(tick)
