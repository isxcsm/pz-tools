-- Shredding (NUMBERS 3): what a thing yields in sample bundles. The machines (the hand bench, the bulk shredder)
-- ask here: they never keep their own formula. The yield is a count with a fraction; what is not a whole bundle yet is
-- kept on the record and adds up (Shred.carry), so every bit of weight counts.
--   base  = weight * 0.5 / (1 + c / ShredDecay)       c: shreds of this kind lately (x0.9 a day)
--   extra = the upgrades' added bundles + base * (blade multiplier - 1)
--   final = base + min(extra, base)                   so never more than twice the base
-- Rotten food gives half the base. A kind shredded for the first time pays 200 credits (and enters the codex).
-- The record's `shred` section: counts { [base type] = { c, day } }, first { [base type] = true }, rest (the part of a
-- bundle made and not given yet).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Codex"
local OA = OperationAcorn
local Shred = {}
OA.Shred = Shred

Shred.PER_WEIGHT = 0.5      -- a bundle is 600 credits at weight 1: half a bundle a weight is 300 credits
Shred.FIRST_BONUS = 200
Shred.DAILY = 0.9
Shred.ROTTEN = 0.5
Shred.FORGET_BELOW = 0.05    -- counts decayed to less than this are dropped

function Shred.section(record)
    local s = OA.Store.section(record, "shred")
    s.counts = s.counts or {}
    s.first = s.first or {}
    return s
end

local function reason(why)
    return OA.Categories.reasonKey(why)
end

-- Whether a thing can be shredded: true, or false and the translation key of why not. Material (K), ammunition,
-- furniture, bodies, animal parts, cash, shop goods and this mod's goods cannot; a bag only when empty.
function Shred.can(info)
    if info.cash then return false, reason("Cash") end
    local cat, why = OA.Categories.of(info)
    if not cat then return false, reason(why) end
    if cat == "K" then return false, reason("Material") end
    if info.filled then return false, reason("Filled") end
    return true
end

-- Recent shreds of a kind (c), decayed to today.
function Shred.count(record, baseType)
    local entry = Shred.section(record).counts[baseType]
    if not entry then return 0 end
    return entry.c * Shred.DAILY ^ math.max(0, OA.day() - entry.day)
end

local function decay()
    return OA.scaled(50, "ShredDecayMultiplier")
end

-- The expected sample bundles one thing of this kind gives now, and the first-shred bonus it would pay (0 if the
-- kind was shredded before). `extras` = { bundles = the upgrades' added bundles,
-- blade = the blade's multiplier (1.0, 1.1, 1.2) }, either may be missing. `c` overrides the record's count
-- (batches).
function Shred.yield(info, record, extras, c)
    local weight = math.max(info.weight or 0, 0)
    c = c or Shred.count(record, info.baseType)
    local base = weight * Shred.PER_WEIGHT / (1 + c / decay())
    if info.food == "rotten" then base = base * Shred.ROTTEN end
    extras = extras or {}
    local extra = (extras.bundles or 0) + base * ((extras.blade or 1.0) - 1.0)
    if extra < 0 then extra = 0 end
    if extra > base then extra = base end
    local bonus = 0
    if not Shred.section(record).first[info.baseType] then bonus = Shred.FIRST_BONUS end
    return base + extra, bonus
end

-- The whole bundles a yield gives now: it is added to what the record kept from before, the whole bundles are given and
-- the rest stays for the next shred.
function Shred.carry(record, amount)
    local s = Shred.section(record)
    local total = (s.rest or 0) + math.max(0, amount or 0)
    local whole = math.floor(total + 1e-9)
    s.rest = math.max(0, total - whole)
    return whole
end

-- Records `n` things of a kind shredded: the count goes up, the first-shred bonus (BonusMultiplier) is paid into
-- trade.bonus and the kind enters the codex. Returns the bonus paid (credits, 0 if none).
function Shred.commit(record, info, n)
    n = n or 1
    local s = Shred.section(record)
    local key = info.baseType
    local c = Shred.count(record, key)
    s.counts[key] = { c = c + n, day = OA.day() }
    local paid = 0
    if not s.first[key] then
        s.first[key] = true
        paid = Shred.FIRST_BONUS * (OA.option("BonusMultiplier") or 1.0)
        local t = OA.Trust.section(record)
        t.bonus = t.bonus + paid
        OA.Codex.acquire(record, info)
    end
    return paid
end

-- The daily upkeep: counts decayed away are dropped so the save does not keep every kind ever shredded.
function Shred.daily(record)
    local s = Shred.section(record)
    for key, entry in pairs(s.counts) do
        if entry.c * Shred.DAILY ^ math.max(0, OA.day() - entry.day) < Shred.FORGET_BELOW then s.counts[key] = nil end
    end
end

return Shred
