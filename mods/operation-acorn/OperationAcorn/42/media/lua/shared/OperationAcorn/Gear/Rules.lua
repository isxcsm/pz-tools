-- The numbers of the modification kits and the team's gear (NUMBERS 7, REWARDS), as pure functions of plain numbers,
-- so that they can be tested outside the game. The game side (Gear.lua) reads the objects, calls these and writes the
-- results back.
--
-- There is a kit per thing it improves: the expansion kit (what a thing holds), the lightening kit (what it weighs),
-- the reinforcement kit (how long a tool lasts) and the engine tuning kit. A kit is counted on its target: an item's
-- count in the item's modData, a vehicle's in the modData of the part the kit changes (a storage part, the engine). The
-- effect is always worked out again from the count and the target's original value, never added to the value it has
-- now, so that a rounding never builds up and the same count always gives the same thing.
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
OA.Gear = OA.Gear or {}
local Rules = {}
OA.Gear.Rules = Rules

-- The modData keys. All start with OA_ (ARCHITECTURE 4).
Rules.KEY = {
    CAPACITY = "OA_Capacity",       -- the key the extension API reads: a number added to the raw capacity of the holder
    CARRY = "OA_Carry",             -- the key the extension API reads: the item's own carrying efficiency
    USES = "OA_Uses",               -- the key the extension API reads: what the item's uses are multiplied by
    TEAM = "OA_Team",               -- on a vanilla item the team issued (the welder): true
    NAME = "OA_Name",               -- the key the extension API reads: the translation key a team item is named by
    ICON = "customInventoryIcon",   -- the game's own key: the texture a single item is drawn with in place of its type's
    KIT_CAP = "OA_KitCap",          -- on an item or a vehicle storage part: expansion kits fitted
    KIT_LIGHT = "OA_KitWeight",     -- on an item: lightening kits fitted
    KIT_TOUGH = "OA_KitTough",      -- on a field tool: reinforcement kits fitted
    BAG_BASE_CAP = "OA_KitBaseCap", -- on a bag: its capacity before the first kit
    BAG_BASE_RED = "OA_KitBaseRed", -- on a bag: its weight reduction before the first kit
    BAG_ID = "OA_KitBag",           -- on a bag: the id of the item the kits were last written into (a waist bag moved
                                    -- to the other side is a new item, its capacity the script's again)
    RAW = "OA_KitRaw",              -- the raw capacity the kits code last set (to see whether it must set it again)
    STORAGE_BASE = "OA_KitBase",    -- on a vehicle storage part: its capacity before the first kit
    ENGINE = "OA_KitEngine",        -- on the engine part: kits fitted
    ENGINE_POWER = "OA_KitPower",   -- on the engine part: the engine power before the first kit
    ENGINE_LOUD = "OA_KitLoud",     -- on the engine part: the engine loudness before the first kit
}

-- What a kit changes, per kit (NUMBERS 7).
Rules.CAPACITY_STEP = 0.10      -- a bag and a vehicle storage: of the original capacity
Rules.CAN_STEP = 2              -- the fuel can: litres
Rules.USES_BASE = 1.2           -- the welder: its uses, times the vanilla torch's, with no kit
Rules.USES_STEP = 0.2           -- and more per kit
Rules.REDUCTION_CAP = 95        -- a bag's weight reduction, in percent: the end value it approaches
Rules.REDUCTION_FILL = 0.20     -- of the gap that is left to the end value
Rules.LIGHT_FLOOR = 0.4         -- a team item's weight: the share of its script weight it approaches
Rules.LIGHT_KEEP = 0.8          -- of what is left above that share, kept per kit
Rules.TOUGH_STEP = 0.25         -- a field tool's most condition: of its script's, per kit
Rules.TOUGH_MOST = 4            -- reinforcement kits a tool takes
Rules.POWER_STEP = 0.10         -- engine power, of the original
Rules.LOUDNESS_STEP = 0.05      -- engine loudness, of the original

-- The vanilla limits (ItemContainer.MAX_CAPACITY_BAG and _VEHICLE, found with javap): a bag holds at most 50 less its
-- own weight, a vehicle's container at most 1000. The extension API lifts them for a holder with the OA_Capacity key.
Rules.BAG_LIMIT = 50
Rules.VEHICLE_LIMIT = 1000
-- VehicleEngine.setFeatures stores the loudness it is given times this (float 0.37037036 in the game's bytecode).
Rules.LOUDNESS_SCALE = 0.37037036

-- The work of fitting a kit, in ticks (a tick is about 1/30 s): to an item; to a vehicle's storage and engine before
-- the mechanic's skill, which takes this share off per level of mechanics, down to the least share.
Rules.TICKS = { item = 240, storage = 500, engine = 700 }
Rules.SKILL_SHARE = 0.04
Rules.LEAST_SHARE = 0.4

-- The kit kinds are P1's (Shop.KITS); this part adds what each fits: kinds of items ("bag", "can", "welder", "tool")
-- and of vehicle parts ("storage", "engine").
Rules.TARGETS = {
    capacity = { bag = true, can = true, welder = true, storage = true },
    lightening = { bag = true, can = true, welder = true, tool = true },
    reinforcement = { tool = true },
    engine = { engine = true },
}
Rules.VEHICLE_TARGETS = { storage = true, engine = true }

-- Whether a kit of a kind fits a target of a kind.
function Rules.fits(kind, target)
    local t = Rules.TARGETS[kind]
    return t ~= nil and target ~= nil and t[target] == true
end

-- Whether a kind of kit is fitted to an item (from the inventory) rather than to a vehicle (from its mechanics window).
function Rules.onItems(kind)
    for target in pairs(Rules.TARGETS[kind] or {}) do
        if not Rules.VEHICLE_TARGETS[target] then return true end
    end
    return false
end

-- Ticks of work on a kit for a target ("item", "storage", "engine") at a mechanics level; only a vehicle kit gets faster.
function Rules.workTicks(target, level)
    if not Rules.VEHICLE_TARGETS[target] then return Rules.TICKS.item end
    local share = math.max(Rules.LEAST_SHARE, 1 - Rules.SKILL_SHARE * (level or 0))
    return math.floor(Rules.TICKS[target] * share)
end

-- The item type of a kind's kit ("OperationAcorn.KitCapacity").
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

-- The capacity of a bag or a vehicle storage with `n` expansion kits fitted: +10% of the original per kit, rounded once.
function Rules.capacity(base, n)
    return round(base * (1 + Rules.CAPACITY_STEP * n))
end

-- What the kits add to the original capacity: the number the API adds to the raw capacity.
function Rules.extra(base, n)
    return Rules.capacity(base, n) - base
end

-- The fuel can's litres with `n` expansion kits.
function Rules.canLitres(base, n)
    return base + Rules.CAN_STEP * n
end

-- The welder's use multiplier with `n` expansion kits (1.2 with none: 12 uses of a torch's 10).
function Rules.uses(n)
    return Rules.USES_BASE + Rules.USES_STEP * n
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

-- A bag's weight reduction with `n` lightening kits: each kit fills 20% of what is left to 95 (85 -> 87 -> 88.6 ...). A
-- bag already at or above 95 is not changed.
function Rules.reduction(base, n)
    if base >= Rules.REDUCTION_CAP or n <= 0 then return base end
    return Rules.REDUCTION_CAP - (Rules.REDUCTION_CAP - base) * (1 - Rules.REDUCTION_FILL) ^ n
end

-- The same as the whole percent the game stores (InventoryContainer.setWeightReduction takes an int).
function Rules.reductionInt(base, n)
    return round(Rules.reduction(base, n))
end

-- The share of its script weight a team item weighs with `n` lightening kits: 0.4 + 0.6 x 0.8^n (1, 0.88, 0.784 ...).
function Rules.lightness(n)
    return Rules.LIGHT_FLOOR + (1 - Rules.LIGHT_FLOOR) * Rules.LIGHT_KEEP ^ n
end

-- The carrying efficiency that makes an item weigh that share (the game divides a weight by 1 plus the efficiency).
function Rules.efficiency(n)
    return 1 / Rules.lightness(n) - 1
end

-- A field tool's most condition with `n` reinforcement kits: +25% of its script's per kit, rounded once.
function Rules.toughness(base, n)
    return round(base * (1 + Rules.TOUGH_STEP * math.min(n, Rules.TOUGH_MOST)))
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
