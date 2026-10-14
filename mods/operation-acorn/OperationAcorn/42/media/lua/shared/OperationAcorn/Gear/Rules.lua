-- The numbers of the modification kits and the improved gear (NUMBERS 7, REWARDS), as pure functions of plain
-- numbers, so that they can be tested outside the game. The game side (Gear.lua) reads the objects, calls these and
-- writes the results back.
--
-- A kit is counted per target: a bag's count lives in the bag's modData, a vehicle's in the modData of the vehicle
-- part the kit changes (the trunk part, the engine part). The effect is always worked out again from the count and
-- the target's original value, never added to the value it has now, so that a rounding never builds up and the
-- same count always gives the same bag or vehicle.
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
OA.Gear = OA.Gear or {}
local Rules = {}
OA.Gear.Rules = Rules

-- The modData keys. All start with OA_ (ARCHITECTURE 4).
Rules.KEY = {
    CAPACITY = "OA_Capacity",       -- the key the extension API reads: a number added to the raw capacity of the holder
    BAG_CAP = "OA_KitCap",          -- on a bag: capacity kits fitted
    BAG_WEIGHT = "OA_KitWeight",    -- on a bag: weight kits fitted
    BAG_BASE_CAP = "OA_KitBaseCap", -- on a bag: its capacity before the first kit
    BAG_BASE_RED = "OA_KitBaseRed", -- on a bag: its weight reduction before the first kit
    RAW = "OA_KitRaw",              -- the raw capacity the kits code last set (to see whether it must set it again)
    TRUNK = "OA_KitTrunk",          -- on a trunk part: kits fitted
    TRUNK_BASE = "OA_KitBase",      -- on a trunk part: its capacity before the first kit
    ENGINE = "OA_KitEngine",        -- on the engine part: kits fitted
    ENGINE_POWER = "OA_KitPower",   -- on the engine part: the engine power before the first kit
    ENGINE_LOUD = "OA_KitLoud",     -- on the engine part: the engine loudness before the first kit
}

-- What a kit changes, per kit (NUMBERS 7).
Rules.CAPACITY_STEP = 0.10      -- bag and trunk: of the original capacity
Rules.REDUCTION_CAP = 95        -- bag weight reduction, in percent: the end value it approaches
Rules.REDUCTION_FILL = 0.20     -- of the gap that is left to the end value
Rules.POWER_STEP = 0.10         -- engine power, of the original
Rules.LOUDNESS_STEP = 0.05      -- engine loudness, of the original

-- The vanilla limits (ItemContainer.MAX_CAPACITY_BAG and _VEHICLE, found with javap): a bag holds at most 50 less its
-- own weight, a vehicle's container at most 1000. The extension API lifts them for a holder with the OA_Capacity key.
Rules.BAG_LIMIT = 50
Rules.VEHICLE_LIMIT = 1000
-- VehicleEngine.setFeatures stores the loudness it is given times this (float 0.37037036 in the game's bytecode).
Rules.LOUDNESS_SCALE = 0.37037036

-- The work of fitting a kit, in ticks (a tick is about 1/30 s): a bag kit; a trunk kit and an engine kit before the
-- mechanic's skill, which takes this share off per level of mechanics, down to the least share.
Rules.TICKS = { bag = 240, trunk = 500, engine = 700 }
Rules.SKILL_SHARE = 0.04
Rules.LEAST_SHARE = 0.4

-- The kit kinds are P1's (Shop.KITS); this part adds which kind of target each one has.
Rules.SCOPE = { bagCapacity = "bag", bagWeight = "bag", trunk = "vehicle", engine = "vehicle" }

-- Ticks of work on a kit of a kind ("bag" for both bag kits) at a mechanics level; only a vehicle kit gets faster.
function Rules.workTicks(kind, level)
    if kind == "bag" or kind == "bagCapacity" or kind == "bagWeight" then return Rules.TICKS.bag end
    local share = math.max(Rules.LEAST_SHARE, 1 - Rules.SKILL_SHARE * (level or 0))
    return math.floor((Rules.TICKS[kind] or Rules.TICKS.trunk) * share)
end

-- The item type of a kind's kit ("OperationAcorn.KitBagCapacity").
function Rules.kitType(kind)
    local k = OA.Shop.KITS[kind]
    return k and OA.Shop.TYPES[k.type] or nil
end

-- The kind a kit item type belongs to, or nil.
function Rules.kindOf(fullType)
    for _, kind in ipairs(OA.Shop.KIT_ORDER) do
        if Rules.kitType(kind) == fullType then return kind end
    end
    return nil
end

-- A whole number of a value: rounded half up (these values are positive).
local function round(x)
    return math.floor(x + 0.5)
end

-- The capacity of a bag or a trunk with `n` capacity kits fitted: +10% of the original per kit, rounded once.
function Rules.capacity(base, n)
    return round(base * (1 + Rules.CAPACITY_STEP * n))
end

-- What the kits add to the original capacity: the number the API adds to the raw capacity.
function Rules.extra(base, n)
    return Rules.capacity(base, n) - base
end

-- The most a bag of this own weight holds under the vanilla rule (InventoryContainer.getCapacity cuts a bag at 50
-- less its weight, truncated).
function Rules.bagLimit(weight)
    return math.floor(Rules.BAG_LIMIT - (weight or 0))
end

-- The raw capacity to give a container. With the API the raw capacity stays the original and OA_Capacity adds the
-- kits; without it the kits are written into the raw capacity itself, cut at the vanilla `limit` (never below the
-- original: a bag that is already above the limit keeps what it has).
function Rules.raw(base, total, limit, lifted)
    if lifted then return base end
    return math.max(base, math.min(total, limit))
end

-- Whether the vanilla limit cuts a capacity (then the tooltip says the API is needed for the rest).
function Rules.cut(total, limit, lifted)
    return not lifted and total > math.max(limit, 0)
end

-- A bag's weight reduction with `n` weight kits: each kit fills 20% of what is left to 95 (85 -> 87 -> 88.6 ...). A
-- bag already at or above 95 is not changed.
function Rules.reduction(base, n)
    if base >= Rules.REDUCTION_CAP or n <= 0 then return base end
    return Rules.REDUCTION_CAP - (Rules.REDUCTION_CAP - base) * (1 - Rules.REDUCTION_FILL) ^ n
end

-- The same as the whole percent the game stores (InventoryContainer.setWeightReduction takes an int).
function Rules.reductionInt(base, n)
    return round(Rules.reduction(base, n))
end

-- An engine value (power, loudness) with `n` kits: the original times 1 + step per kit, a whole number.
function Rules.engine(base, n, step)
    return round(base * (1 + step * n))
end

-- What to give BaseVehicle.setEngineFeature as the loudness so that the stored loudness is `stored`: the game stores
-- (int)(given x 0.37037036), so the smallest whole number whose product passes `stored` is used.
function Rules.loudnessArgument(stored)
    return math.floor(stored / Rules.LOUDNESS_SCALE) + 1
end

return Rules
