-- What a mission is worth and when it counts (NUMBERS 9, DESIGN 9). Pure arithmetic, no game objects: the level of a
-- mission, its distance band, its reward, the deadline judged at sealing, and the sample cooler's warming.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Rewards = {}
OA.Rewards = Rewards

-- By level: 1 to 5 are the trust stages, 6 is a milestone passed (milestone and contract missions). The band is in
-- squares from the terminal; credits and trust are the regular mission's reward.
Rewards.LEVELS = {
    { lo = 150, hi = 600, credits = 10000, trust = 60 },
    { lo = 300, hi = 1200, credits = 20000, trust = 120 },
    { lo = 600, hi = 2000, credits = 35000, trust = 200 },
    { lo = 1000, hi = 3500, credits = 50000, trust = 300 },
    { lo = 1500, hi = 5000, credits = 70000, trust = 400 },
    { lo = 2000, hi = 8000, credits = 90000, trust = 500 },
}
Rewards.STORY_MULTIPLIER = 1.5
-- A mission item delivered after the deadline is a plain item: this much, no penalty (NUMBERS 1, 9). The economy
-- values every mission item at this, so a mission in time pays the rest on top.
Rewards.EXPIRED_CREDITS = 1000
Rewards.EXPIRED_TRUST = 5
-- The story missions' inner edge: a candidate this close to the terminal is the base itself (NUMBERS 9).
Rewards.BASE_EXCLUSION = 50

-- The level of a player: the trust stage (1 to 5), or 6 once a milestone has passed. Stage 0 has no missions (nil).
function Rewards.level(stage, milestones)
    stage = stage or 0
    if stage < 1 then return nil end
    if (milestones or 0) >= 1 then return 6 end
    return math.min(stage, 5)
end

function Rewards.band(level)
    local row = Rewards.LEVELS[level]
    if not row then return nil end
    return row.lo, row.hi
end

-- The reward of a mission of this level: integers. A story mission pays 1.5 times; `quality` (0 to 1, the sample cooler's
-- 0.6 to 1.0) scales both; the credits follow the economy's credit multiplier (an option), the trust does not.
function Rewards.reward(level, story, quality, creditScale)
    local row = Rewards.LEVELS[level]
    if not row then return 0, 0 end
    local m = (story and Rewards.STORY_MULTIPLIER or 1) * (quality or 1)
    return OA.round(row.credits * m * (creditScale or 1)), OA.round(row.trust * m)
end

-- What a mission in time pays beyond the plain item value that the sealed item is settled at anyway, never below 0.
function Rewards.extra(credits, trust)
    return math.max(0, credits - Rewards.EXPIRED_CREDITS), math.max(0, trust - Rewards.EXPIRED_TRUST)
end

-- Judged when the box is sealed (not when the helicopter comes): "ok" in time, "late" after the deadline (world age,
-- hours). The mission item then counts as a plain item.
function Rewards.judge(deadline, sealedAt)
    if sealedAt <= deadline then return "ok" end
    return "late"
end

-- Days to hours.
function Rewards.hours(days)
    return days * 24
end

-- The sample cooler (DESIGN 9, LORE 7): 4 degrees Celsius when picked up, warming by the hour, and it matters at
-- sealing: up to GOOD_AT it is in good shape, from BAD_AT worst (x0.6), between the reward slides. No failure.
Rewards.COOLER_START = 4
Rewards.COOLER_RATE = 0.5
Rewards.COOLER_MAX = 30
Rewards.COOLER_GOOD = 8
Rewards.COOLER_BAD = 16
Rewards.COOLER_WORST = 0.6

function Rewards.coolerTemp(hoursCarried)
    local h = math.max(0, hoursCarried or 0)
    return math.min(Rewards.COOLER_MAX, Rewards.COOLER_START + Rewards.COOLER_RATE * h)
end

function Rewards.coolerQuality(temp)
    if temp <= Rewards.COOLER_GOOD then return 1.0 end
    if temp >= Rewards.COOLER_BAD then return Rewards.COOLER_WORST end
    local t = (temp - Rewards.COOLER_GOOD) / (Rewards.COOLER_BAD - Rewards.COOLER_GOOD)
    return 1.0 - t * (1.0 - Rewards.COOLER_WORST)
end

-- Which receipt note fits: "good", "warm" or "bad".
function Rewards.coolerGrade(temp)
    if temp <= Rewards.COOLER_GOOD then return "good" end
    if temp < Rewards.COOLER_BAD then return "warm" end
    return "bad"
end

return Rewards
