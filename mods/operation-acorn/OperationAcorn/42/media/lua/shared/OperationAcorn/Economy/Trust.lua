-- Trust (NUMBERS 5 and 6): the stage thresholds, the milestones after the last stage (the levels 6, 7, 8 ... the
-- player sees), and what they open. The numbers trust used to raise by itself are flight support upgrades bought
-- with credits (Economy/Support); the rewards below put both together.
-- The record's `trade` section holds trust (with decimals), stage (1..5, 0 before the first contact), milestones, and
-- the shared serums waiting for the next supply drop; this file changes those and nothing else.
-- The first stage opens with the first contact (the first time a terminal is used, Trust.open), not with trust: stage 0
-- is only "no terminal used yet" and nothing shows it.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Support"
require "OperationAcorn/Economy/Eggs"
local OA = OperationAcorn
local Trust = {}
OA.Trust = Trust

Trust.STAGES = 5
-- Trust needed to enter stages 1..5 (NUMBERS 5), before TrustThresholdMultiplier. The first is the start.
Trust.STAGE_BASE = { 0, 400, 900, 1500, 2300 }
-- The first milestone (level 6) at 3,400; milestone k comes (1,400 + 700 * (k - 1)) trust after the one before it.
Trust.MILESTONE_AT, Trust.MILESTONE_FIRST, Trust.MILESTONE_STEP = 3400, 1400, 700

local function multiplier()
    return OA.option("TrustThresholdMultiplier") or 1.0
end

-- Trust needed to enter a stage (1..5).
function Trust.stageThreshold(stage)
    return OA.round(Trust.STAGE_BASE[stage] * multiplier())
end

-- Trust needed for milestone k (1, 2 ...): 3,400 / 5,500 / 8,300 / 11,800 / 16,000 ...
function Trust.milestoneThreshold(k)
    local base = Trust.MILESTONE_AT
        + Trust.MILESTONE_FIRST * (k - 1) + Trust.MILESTONE_STEP * k * (k - 1) / 2
    return OA.round(base * multiplier())
end

-- The stage and the milestones a trust amount makes, once in contact (1 at the least).
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

-- Whether the record's character has met the team: the terminal used once (the first contact opens the first stage,
-- Trade.openContact). Before it nothing of the trade shows or pays: no worth or "not seen" lines on the tooltips, no
-- bonuses (the codex and the search still count), no kill count.
function Trust.contacted(record)
    local t = record and record.trade
    return t ~= nil and (t.stage or 0) >= 1
end

-- Shop tier: 1..5 the stages (1 the start, and before the first contact too), then 5 plus the milestones. What a shop
-- item or reward waits for.
function Trust.tier(record)
    local t = record.trade
    if not t then return 1 end
    return math.max(1, t.stage or 1) + (t.milestones or 0)
end

-- The translation key of a stage's name, and of a level past the last stage ("%1단계").
function Trust.stageNameKey(stage)
    return "IGUI_OA_Econ_Stage_" .. tostring(math.max(1, stage))
end

Trust.MILESTONE_NAME_KEY = "IGUI_OA_Econ_Stage_Milestone"

-- The name a record's level goes by: the stage's, or its number once past the last stage (milestone k is level 5 + k).
function Trust.label(record)
    local t = record.trade or {}
    if (t.milestones or 0) > 0 then return getText(Trust.MILESTONE_NAME_KEY, Trust.STAGES + t.milestones) end
    return getText(Trust.stageNameKey(t.stage or 1))
end

-- Where the trust bar stands: { trust, from, to, kind = "stage"|"milestone", number } (to = the next threshold).
function Trust.progress(record)
    local t = Trust.section(record)
    local from, to, kind, number
    if t.stage < Trust.STAGES then
        local stage = math.max(1, t.stage)
        number = stage + 1
        kind = "stage"
        to = Trust.stageThreshold(number)
        from = Trust.stageThreshold(stage)
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
local catchUp

function Trust.add(record, amount)
    local t = Trust.section(record)
    if not amount or amount <= 0 then return {} end
    t.trust = t.trust + amount
    return catchUp(t)
end

-- The first contact: stage 0 becomes the first stage (and whatever the trust already makes). The events as Trust.add
-- gives them; none when the record was already in contact.
function Trust.open(record)
    local t = Trust.section(record)
    if t.stage >= 1 then return {} end
    return catchUp(t)
end

catchUp = function(t)
    local events = {}
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

-- What trust raises by itself (NUMBERS 5). Each is { from = the first tier it applies at, value }, the last one
-- reached wins; the tier is stage + milestones.
local ACCEL = { { 0, 1.0 }, { 6, 1.1 }, { 8, 1.2 } }

local function at(line, tier)
    local value = line[1][2]
    for i = 1, #line do
        if tier >= line[i][1] then value = line[i][2] end
    end
    return value
end

-- The easter eggs' effects (Eggs.bonuses) when there are none: nothing added, and the arrival as it is.
local NO_EGGS = { rate = 0, box = 0, discount = 0, arrive = 1 }

-- The rewards of a stage and a number of milestones with the flight support levels { id = level } (none: all at
-- the start). No record needed; the sandbox options at the time scale the starting values, and later values keep
-- their proportion to them. `eggs` (as Eggs.bonuses gives them) go on top of the levels' values, whatever the level:
-- the conversion rate, the capacity and the discount are added to, both ends of the arrival hours are multiplied.
function Trust.rewardsFor(stage, milestones, levels, eggs)
    milestones = milestones or 0
    levels = levels or {}
    eggs = eggs or NO_EGGS
    local tier = stage + milestones
    local function value(id) return OA.Support.step(id, levels[id] or 0).value end
    local call = OA.scaled(1, "CallIntervalMultiplier")
    local arriveScale = OA.scaled(1, "HelicopterArrivalMultiplier")
    local priceRatio = (OA.option("RequestPrice") or 100) / 100
    local arrive = value("arrive")
    local lo, hi = arrive[1] * arriveScale * eggs.arrive, arrive[2] * arriveScale * eggs.arrive
    return {
        stage = stage, milestones = milestones, tier = tier,
        boxCapacity = value("box") + eggs.box,
        callInterval = value("call") * call,
        arrival = { min = lo, max = hi },
        nightDrop = value("night"),
        rate = value("rate") + eggs.rate,
        requestPrice = value("reqprice") * priceRatio,
        requestCount = value("reqcount"),
        discount = value("discount") + eggs.discount,
        trustAccel = at(ACCEL, tier),
        softerSupply = value("softer"),
        marketForecast = value("forecast"),
        backpack = stage >= 5,
        kits = milestones >= 1,
        transferred = milestones >= 3,
    }
end

-- The record's rewards: the table above for its stage, milestones and levels, and its easter eggs (worked out again
-- when one of them changes; Support bumps trade.levelsRev with each level, and Eggs with each egg).
local cache = {}
function Trust.rewards(record)
    local t = record.trade
    local stage = t and t.stage or 0
    local milestones = t and t.milestones or 0
    local rev = t and t.levelsRev or 0
    local key = record.id or record
    local hit = cache[key]
    if not hit or hit.stage ~= stage or hit.milestones ~= milestones or hit.rev ~= rev then
        hit = { stage = stage, milestones = milestones, rev = rev,
            value = Trust.rewardsFor(stage, milestones, t and t.levels, OA.Eggs.bonuses(record)) }
        cache[key] = hit
    end
    return hit.value
end

-- Drops the cache (a test that changes the options).
function Trust.reset()
    cache = {}
end

return Trust
