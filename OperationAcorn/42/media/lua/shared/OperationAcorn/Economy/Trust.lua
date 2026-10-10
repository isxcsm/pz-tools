-- Trust (NUMBERS 5 and 6): the stage thresholds, the milestones after the last stage, and the rewards each brings.
-- A reward's number is the total at that stage and replaces the earlier one (NUMBERS 5: +5% then +10% is +10%).
-- The record's `trade` section holds trust (with decimals), stage (0..5), milestones, and the shared serums waiting
-- for the next supply drop; this file changes those and nothing else.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
local OA = OperationAcorn
local Trust = {}
OA.Trust = Trust

Trust.STAGES = 5
-- Trust needed to enter stages 1..5 (NUMBERS 5), before TrustThresholdMultiplier.
Trust.STAGE_BASE = { 700, 2300, 5500, 11500, 23000 }
-- Milestone k comes (14,000 + 7,000 * (k - 1)) trust after the one before it, the first after stage 5.
Trust.MILESTONE_FIRST, Trust.MILESTONE_STEP = 14000, 7000

local function multiplier()
    return OA.option("TrustThresholdMultiplier") or 1.0
end

-- Trust needed to enter a stage (1..5).
function Trust.stageThreshold(stage)
    return OA.round(Trust.STAGE_BASE[stage] * multiplier())
end

-- Trust needed for milestone k (1, 2 ...): 37,000 / 58,000 / 86,000 / 121,000 / 163,000 ...
function Trust.milestoneThreshold(k)
    local base = Trust.STAGE_BASE[Trust.STAGES]
        + Trust.MILESTONE_FIRST * k + Trust.MILESTONE_STEP * k * (k - 1) / 2
    return OA.round(base * multiplier())
end

-- The stage and the milestones a trust amount makes.
function Trust.levelFor(trust)
    local stage = 0
    for s = 1, Trust.STAGES do
        if trust >= Trust.stageThreshold(s) then stage = s else break end
    end
    local milestones = 0
    if stage >= Trust.STAGES then
        while trust >= Trust.milestoneThreshold(milestones + 1) do milestones = milestones + 1 end
    end
    return stage, milestones
end

-- The trade section of a record, with the fields this file owns.
function Trust.section(record)
    local t = OA.Store.section(record, "trade")
    if t.credits == nil then t.credits = 0 end
    if t.trust == nil then t.trust = 0 end
    if t.stage == nil then t.stage = 0 end
    if t.milestones == nil then t.milestones = 0 end
    if t.bonus == nil then t.bonus = 0 end
    if t.sharedSerums == nil then t.sharedSerums = 0 end
    return t
end

-- Shop tier: 0 at the start, 1..5 the stages, then 5 plus the milestones. What a shop item or reward waits for.
function Trust.tier(record)
    local t = record.trade
    if not t then return 0 end
    return (t.stage or 0) + (t.milestones or 0)
end

-- The translation key of a stage's name (0 is the start), and of a milestone's ("Milestone %1").
function Trust.stageNameKey(stage)
    return "IGUI_OA_Econ_Stage_" .. tostring(stage)
end

Trust.MILESTONE_NAME_KEY = "IGUI_OA_Econ_Stage_Milestone"

-- The name a record's level goes by: the stage's, or "Milestone n" once past the last stage.
function Trust.label(record)
    local t = record.trade or {}
    if (t.milestones or 0) > 0 then return getText(Trust.MILESTONE_NAME_KEY, t.milestones) end
    return getText(Trust.stageNameKey(t.stage or 0))
end

-- Where the trust bar stands: { trust, from, to, kind = "stage"|"milestone", number } (to = the next threshold).
function Trust.progress(record)
    local t = Trust.section(record)
    local from, to, kind, number
    if t.stage < Trust.STAGES then
        number = t.stage + 1
        kind = "stage"
        to = Trust.stageThreshold(number)
        from = t.stage > 0 and Trust.stageThreshold(t.stage) or 0
    else
        number = t.milestones + 1
        kind = "milestone"
        to = Trust.milestoneThreshold(number)
        from = t.milestones > 0 and Trust.milestoneThreshold(t.milestones) or Trust.stageThreshold(Trust.STAGES)
    end
    return { trust = t.trust, from = from, to = to, kind = kind, number = number }
end

-- Shared serums a stage or a milestone brings (NUMBERS 6): stages 2..5 one each, every milestone one (or one in
-- SharedSerumMilestones milestones).
function Trust.stageSerums(stage)
    return stage >= 2 and 1 or 0
end

function Trust.milestoneSerums(k)
    local every = math.max(1, math.floor(OA.option("SharedSerumMilestones") or 1))
    return OA.remainder(k, every) == 0 and 1 or 0
end

-- Adds trust and returns the events it made, in order:
--   { kind = "stage", stage = n, sharedSerums = 0|1 }
--   { kind = "milestone", index = k, sharedSerums = 0|1, transfer = (k == 3) }
-- The shared serums are already added to trade.sharedSerums (the supply drop takes them from there): the trade part
-- must not add them again. It tells the player, opens the new shop items and calls the story's stage hook.
function Trust.add(record, amount)
    local events = {}
    local t = Trust.section(record)
    if not amount or amount <= 0 then return events end
    t.trust = t.trust + amount
    local stage, milestones = Trust.levelFor(t.trust)
    while t.stage < stage do
        t.stage = t.stage + 1
        local serums = Trust.stageSerums(t.stage)
        t.sharedSerums = t.sharedSerums + serums
        table.insert(events, { kind = "stage", stage = t.stage, sharedSerums = serums })
        if OA.Market then OA.Market.stageEvent(t.stage) end
    end
    while t.milestones < milestones do
        t.milestones = t.milestones + 1
        local serums = Trust.milestoneSerums(t.milestones)
        t.sharedSerums = t.sharedSerums + serums
        table.insert(events, { kind = "milestone", index = t.milestones, sharedSerums = serums,
            transfer = t.milestones == 3 })
    end
    return events
end

-- Rewards (NUMBERS 5). Each is { from = the first tier it applies at, value }, the last one reached wins; the tier
-- is stage + milestones. Values are the defaults of the sandbox options; the options scale them (below).
local BOX = { { 0, 50 }, { 3, 100 }, { 5, 200 }, { 6, 250 }, { 7, 300 }, { 8, 350 } }
local CALL = { { 0, 3 }, { 2, 2 }, { 4, 1.5 }, { 7, 1 } }
local ARRIVE_MIN = { { 0, 4 }, { 3, 3 }, { 8, 2 } }
local ARRIVE_MAX = { { 0, 6 }, { 3, 4 }, { 8, 3 } }
local RATE = { { 0, 0 }, { 3, 0.05 }, { 5, 0.10 }, { 7, 0.15 } }
local REQUEST_BONUS = { { 0, 0.50 }, { 3, 0.65 }, { 5, 0.80 }, { 7, 1.00 } }
local REQUEST_COUNT = { { 0, 6 }, { 2, 8 }, { 5, 10 }, { 7, 12 } }
local DISCOUNT = { { 0, 0 }, { 4, 0.05 }, { 7, 0.10 } }
local ACCEL = { { 0, 1.0 }, { 6, 1.1 }, { 8, 1.2 } }
local CURE_INTERVAL = { { 0, 14 }, { 2, 12 }, { 3, 10 }, { 4, 8 }, { 5, 7 } }
local CURE_COUNT = { { 0, 1 }, { 6, 2 } }
local DELAY_INTERVAL = { { 0, 3 }, { 3, 2 }, { 5, 1 } }
local DELAY_COUNT = { { 0, 1 }, { 7, 3 } }

local function at(line, tier)
    local value = line[1][2]
    for i = 1, #line do
        if tier >= line[i][1] then value = line[i][2] end
    end
    return value
end

-- The rewards of a stage and a number of milestones (no record needed; the options at the time scale them).
function Trust.rewardsFor(stage, milestones)
    milestones = milestones or 0
    local tier = stage + milestones
    local box = at(BOX, tier)
    if milestones > 3 then box = box + 50 * (milestones - 3) end
    -- The options set the starting values; later values keep their proportion to them.
    local call = (OA.option("CallInterval") or 3.0) / 3.0
    local arriveMin = (OA.option("HelicopterArrivalMin") or 4) / 4
    local arriveMax = (OA.option("HelicopterArrivalMax") or 6) / 6
    local requestBonus = (OA.option("RequestBonus") or 50) / 50
    local cure = (OA.option("CureSerumInterval") or 14) / 14
    local delay = (OA.option("DelayDrugInterval") or 3) / 3
    local lo, hi = at(ARRIVE_MIN, tier) * arriveMin, at(ARRIVE_MAX, tier) * arriveMax
    if lo > hi then lo = hi end
    return {
        stage = stage, milestones = milestones, tier = tier,
        boxCapacity = box,
        callInterval = at(CALL, tier) * call,
        arrival = { min = lo, max = hi },
        nightDrop = stage >= 5,
        rate = at(RATE, tier),
        requestBonus = at(REQUEST_BONUS, tier) * requestBonus,
        requestCount = at(REQUEST_COUNT, tier),
        discount = at(DISCOUNT, tier),
        trustAccel = at(ACCEL, tier),
        cureInterval = at(CURE_INTERVAL, tier) * cure,
        cureCount = at(CURE_COUNT, tier),
        delayInterval = at(DELAY_INTERVAL, tier) * delay,
        delayCount = at(DELAY_COUNT, tier),
        softerSupply = stage >= 4,
        marketForecast = stage >= 3,
        backpack = stage >= 5,
        kits = milestones >= 1,
        transferred = milestones >= 3,
    }
end

-- The record's rewards: the table above for its stage and milestones (cached until either changes).
local cache = {}
function Trust.rewards(record)
    local t = record.trade
    local stage = t and t.stage or 0
    local milestones = t and t.milestones or 0
    local key = stage * 10000 + milestones
    local hit = cache[key]
    if not hit then
        hit = Trust.rewardsFor(stage, milestones)
        cache[key] = hit
    end
    return hit
end

-- Drops the cache (a test that changes the options).
function Trust.reset()
    cache = {}
end

return Trust
