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
-- The streak bonus (DESIGN-terminal 7.2): each mission finished in time in a row adds a tenth to the next one's credits,
-- up to three tenths. The card shows it; the number of the streak is the record's.
Rewards.STREAK_STEP = 0.10
Rewards.STREAK_MAX = 3

-- The streak's bonus as a fraction (0 to 0.3, or to `cap`: the flight support's raised limit) for a streak of n missions.
function Rewards.streakBonus(n, cap)
    local bonus = Rewards.STREAK_STEP * math.max(n or 0, 0)
    return math.min(bonus, cap or Rewards.STREAK_STEP * Rewards.STREAK_MAX)
end

-- Danger pay (DESIGN-terminal 7.2): the zombie density of the mission's area (the average of the chunks read there) over
-- DANGER_BASE, in per cent, in steps of 5, from 0 to 0.3 of the credits. Returns the fraction (0 to 0.3).
Rewards.DANGER_BASE, Rewards.DANGER_STEP, Rewards.DANGER_MAX = 0.05, 5, 0.3
function Rewards.dangerPay(density)
    local percent = ((density or 0) - Rewards.DANGER_BASE) * 100
    local steps = math.floor(percent / Rewards.DANGER_STEP + 0.5 + 1e-9)
    return OA.clamp(steps * Rewards.DANGER_STEP / 100, 0, Rewards.DANGER_MAX)
end

-- Distance pay: how far into its level's band the mission lies (0 at the near edge, 1 at the far one), in steps of 5 per
-- cent, up to FAR_MAX. Returns the fraction (0 to 0.3).
Rewards.FAR_MAX, Rewards.FAR_STEP = 0.3, 5
function Rewards.farPay(distance, lo, hi)
    if not (distance and lo and hi) or hi <= lo then return 0 end
    local share = OA.clamp((distance - lo) / (hi - lo), 0, 1)
    local steps = math.floor(share * Rewards.FAR_MAX * 100 / Rewards.FAR_STEP + 0.5 + 1e-9)
    return steps * Rewards.FAR_STEP / 100
end

-- The credits of a mission with its bonuses on top of the base: the danger pay, the streak's (capped at `streakCap`, else
-- 0.3), the distance pay and the flight support's mission pay: 30,000 at 15 per cent danger and a streak of 2 is 40,500.
function Rewards.withBonus(base, danger, streak, far, support, streakCap)
    return OA.round(base * (1 + (danger or 0) + Rewards.streakBonus(streak, streakCap) + (far or 0) + (support or 0)))
end

-- The trust of a mission: the danger pay and the distance pay go on the trust too (the streak and the flight support,
-- bought with credits, do not: trust is not bought).
function Rewards.trustWithBonus(base, danger, far)
    return OA.round(base * (1 + (danger or 0) + (far or 0)))
end

-- The urgent mission (7.2): one regular mission in URGENT_CHANCE (per cent), URGENT_HOURS to do it, MULTIPLIER the pay.
Rewards.URGENT_CHANCE, Rewards.URGENT_HOURS, Rewards.URGENT_MULTIPLIER = 10, 24, 1.5

-- The scattered samples (7.2): the whole set pays SCATTER_BONUS more; a part pays the share found of the price without
-- it. `found` and `total` count the pieces.
Rewards.SCATTER_BONUS = 0.2
function Rewards.scatterShare(found, total)
    if total <= 0 then return 0 end
    if found >= total then return 1 + Rewards.SCATTER_BONUS end
    return found / total
end

-- Taking another mission (7.2): once a week, for this share of the level's trust.
Rewards.REROLL_SHARE = 0.10
function Rewards.rerollCost(level)
    local row = Rewards.LEVELS[level]
    if not row then return 0 end
    return OA.round(row.trust * Rewards.REROLL_SHARE)
end

-- The special request (6.3): the level's regular credits twice over and its trust once, fourteen days, the next offer
-- seven days after one ends. The distance band is the next level's.
Rewards.SPECIAL_CREDITS = 2
Rewards.SPECIAL_DAYS, Rewards.SPECIAL_GAP_DAYS = 14, 7
function Rewards.specialReward(level, creditScale)
    local credits, trust = Rewards.reward(level, false, 1, creditScale)
    return credits * Rewards.SPECIAL_CREDITS, trust
end

function Rewards.specialBandLevel(level)
    return math.min((level or 1) + 1, #Rewards.LEVELS)
end

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
