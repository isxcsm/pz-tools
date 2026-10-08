-- What a delivery is worth (NUMBERS 1). `info` (ARCHITECTURE 5) is an item as a plain table; Value.info makes one
-- from a game item and is the only part here that touches the game. The rest is arithmetic on tables:
--   credits = weight * unit * index * state * (request) * (new region) * rate
--   trust   = weight * unit / 100 * state * accel
-- state is 0.5 + 0.5 * condition (food: fresh 1, stale 0.5). The market index, the request bonus, the new-region
-- bonus and the exchange rate never touch trust, so no one can farm trust through them. Cash and this mod's goods
-- have fixed values. A whole flight is rounded once, in settle (DESIGN 9).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Market"
require "OperationAcorn/Economy/Requests"
local OA = OperationAcorn
local Value = {}
OA.Value = Value
local Categories = OA.Categories

Value.CELL_SIZE = 256            -- B42's cell, in squares
Value.NEW_REGION_WEIGHT = 30     -- weight per cell that earns the premium
Value.NEW_REGION_BONUS = 0.25
Value.REQUEST_FIRST = 20         -- units per item per week that earn the request bonus
Value.CASH_CREDITS = 100         -- credits per dollar
Value.CASH_TRUST = 0.02          -- trust per dollar ...
Value.CASH_TRUST_CAP = 50        -- ... at most this much per flight
Value.HIGH, Value.LOW = 1.10, 0.90   -- index marks "high" / "low" past these

-- Cash, in dollars (a bundle counts as the 100 bills it unfolds into).
Value.CASH = { ["Base.Money"] = 1, ["Base.MoneyBundle"] = 100 }

-- The mod's own goods that are taken: credits and trust for one, no market. Other goods of the mod (serums, kits,
-- machines, parts, gear) are shop goods and not taken. "MissionItem" is worth what its mission pays (the story
-- part settles it); "ExpiredMission" is a mission item past its time.
Value.OWN = {
    SampleBundle = { credits = 60, trust = 0.6 },
    MeteorFragment = { credits = 30000, trust = 10 },
    ExpiredMission = { credits = 1000, trust = 5 },
    MissionItem = { credits = 0, trust = 0 },
}

-- The item's name as the codex counts kinds (see Categories.baseType).
Value.baseType = Categories.baseType

-- The cell a square belongs to, as the key items carry (OA_Cell).
function Value.cellKey(x, y)
    return tostring(math.floor(x / Value.CELL_SIZE)) .. "," .. tostring(math.floor(y / Value.CELL_SIZE))
end

local function ownKind(fullType)
    local module, name = string.match(tostring(fullType), "^([^%.]+)%.(.+)$")
    if module == OA.MOD then return name end
    return nil
end

-- info of an item type from its script (no item exists): weight, category, furniture. Used for the loot tables
-- and for items found without an item in hand.
function Value.infoFromScript(script)
    local fullType = script:getFullName()
    local info = {
        fullType = fullType,
        baseType = Value.baseType(fullType),
        weight = script:getActualWeight(),
        displayCategory = script:getDisplayCategory(),
        moveable = script:isItemType(ItemType.MOVEABLE) and true or false,
        cash = Value.CASH[fullType],
        own = ownKind(fullType),
    }
    return info
end

local function clamp01(x)
    return OA.clamp(x, 0, 1)
end

-- info of a game item (InventoryItem). Reads the item once; its weight is its own, a drink's container is
-- counted empty, and a bag with things in it only says it is filled.
function Value.info(item)
    local fullType = item:getFullType()
    local script = item:getScriptItem()
    local weight
    if script and item:isFluidContainer() then
        weight = script:getActualWeight()
    else
        weight = item:getActualWeight()
    end
    local info = {
        fullType = fullType,
        baseType = Value.baseType(fullType),
        weight = weight,
        displayCategory = item:getDisplayCategory() or item:getCategory(),
        moveable = item:isItemType(ItemType.MOVEABLE) and true or false,
        cash = Value.CASH[fullType],
        own = ownKind(fullType),
    }
    if instanceof(item, "Food") then
        info.food = item:isRotten() and "rotten" or (item:isFresh() and "fresh" or "stale")
    elseif instanceof(item, "DrainableComboItem") then
        info.condition = clamp01(item:getCurrentUsesFloat())
    else
        local max = item:getConditionMax()
        if max and max > 0 then info.condition = clamp01(item:getCondition() / max) end
    end
    if instanceof(item, "InventoryContainer") then
        info.filled = item:getInventory():getItems():size() > 0
    end
    if item:hasModData() then
        local data = item:getModData()
        info.bought = data.OA_Bought and true or nil
        info.cell = data.OA_Cell
        info.mission = data.OA_Mission
    end
    if info.mission and info.own then
        local story = OA.Story
        local expired = story and story.missionExpired and story.missionExpired(info.mission)
        info.own = expired and "ExpiredMission" or "MissionItem"
    end
    return info
end

-- Whether a delivery box takes the item: true, or false and the translation key of why not.
function Value.accepts(info)
    if info.cash then return true end
    if info.own then
        if Value.OWN[info.own] then return true end
        return false, Categories.reasonKey("Own")
    end
    local cat, why = Categories.of(info)
    if not cat then return false, Categories.reasonKey(why) end
    if info.food == "rotten" then return false, Categories.reasonKey("Rotten") end
    if info.filled then return false, Categories.reasonKey("Filled") end
    return true
end

-- The state factor of a thing: 0.5 + 0.5 * condition, or 1 / 0.5 for fresh / stale food.
function Value.state(info)
    if info.food then
        return info.food == "fresh" and 1.0 or 0.5
    end
    return 0.5 + 0.5 * (info.condition or 1.0)
end

-- A table whose missing keys are asked of a function: the context reads the market live.
local function live(fn)
    return setmetatable({}, { __index = function(_, key) return fn(key) end })
end

-- The unrounded value of `count` of one kind of item, as one line of a receipt. ctx as Value.context makes it;
-- `taken` (optional) carries what earlier lines of the same flight used up: { requests = {}, cells = {} }.
--   { fullType, baseType, count, weight (total), category, credits, trust, cashTrust, marks, requestUnits, regionWeight }
function Value.appraiseLine(info, count, ctx, taken)
    count = count or 1
    local line = {
        fullType = info.fullType, baseType = info.baseType, count = count, credits = 0, trust = 0, cashTrust = 0,
        weight = 0, marks = { request = false, newRegion = false, high = false, low = false, refused = false },
        requestUnits = 0, regionWeight = 0,
    }
    local rate = ctx.rate or 1.0
    if info.cash then
        line.credits = info.cash * Value.CASH_CREDITS * count * rate
        line.cashTrust = info.cash * Value.CASH_TRUST * count
        return line
    end
    if info.own then
        local def = Value.OWN[info.own]
        if def then
            line.credits = def.credits * count * rate
            line.trust = def.trust * count * (ctx.trustAccel or 1.0)
        end
        line.own = info.own
        return line
    end
    local cat = Categories.of(info)
    if not cat then return line end
    line.category = cat
    local w = math.max(info.weight or 0, 0)
    line.weight = w * count
    local unit = Categories.UNIT[cat]
    local index = ctx.index and ctx.index[cat] or 1.0
    local state = Value.state(info)
    line.marks.high = index >= Value.HIGH
    line.marks.low = index <= Value.LOW
    line.marks.refused = ctx.refused and ctx.refused[cat] and true or false
    line.trust = w * unit / 100 * state * (ctx.trustAccel or 1.0) * count
    -- How many units earn each premium.
    local bonus = ctx.requestBonus or 0
    local nReq = 0
    if ctx.requests and ctx.requests[info.fullType] then
        local used = (ctx.requestUsed and ctx.requestUsed[info.fullType] or 0)
            + (taken and taken.requests and taken.requests[info.fullType] or 0)
        nReq = math.max(0, math.min(count, Value.REQUEST_FIRST - used))
    end
    local full, partial, consumed = 0, 0, 0
    if info.cell and w > 0 then
        local used = (ctx.cellUsed and ctx.cellUsed[info.cell] or 0)
            + (taken and taken.cells and taken.cells[info.cell] or 0)
        local room = math.max(0, Value.NEW_REGION_WEIGHT - used)
        if room > 0 then
            full = math.min(count, math.floor(room / w))
            if full < count then partial = (room - full * w) / w end
            if partial > 1 then partial = 1 end
            consumed = math.min(room, w * count)
        end
    end
    -- The sum over the units of (request factor) * (1 + premium * share in the new region); the units taken as
    -- requests and as new region come first.
    local sumG = count + bonus * nReq
    local sumGF = full + bonus * math.min(full, nReq)
    if partial > 0 then
        sumGF = sumGF + partial * ((full + 1 <= nReq) and (1 + bonus) or 1)
    end
    local sum = sumG + Value.NEW_REGION_BONUS * sumGF
    line.credits = w * unit * index * state * rate * sum
    line.marks.request = nReq > 0
    line.marks.newRegion = consumed > 0
    line.requestUnits = nReq
    line.regionWeight = consumed
    return line
end

-- The translation keys of the marks an item shows in a tooltip or the estimate window, in the order to show them.
function Value.markKeys(marks)
    local keys = {}
    if marks.refused then table.insert(keys, "IGUI_OA_Econ_Mark_Refused") end
    if marks.request then table.insert(keys, "IGUI_OA_Econ_Mark_Request") end
    if marks.newRegion then table.insert(keys, "IGUI_OA_Econ_Mark_NewRegion") end
    if marks.high then table.insert(keys, "IGUI_OA_Econ_Mark_High") end
    if marks.low then table.insert(keys, "IGUI_OA_Econ_Mark_Low") end
    return keys
end

-- One item: { credits, trust, category, marks } before rounding (ARCHITECTURE 5).
function Value.appraise(info, ctx)
    local line = Value.appraiseLine(info, 1, ctx)
    return { credits = line.credits, trust = line.trust, category = line.category, marks = line.marks,
        cashTrust = line.cashTrust, own = line.own }
end

-- The table values are read from, made once a day for a record (a tooltip reads it, never recomputes):
--   rate (the exchange rate: the reward and CreditMultiplier), trustAccel, requestBonus, index (live), refused (live),
--   requests (a set of this week's request items), requestUsed, cellUsed, rewards.
-- Everything that moves within the day (the index, what the request counters and cells have used) is a live table.
local contexts = {}

function Value.buildContext(record)
    local rewards = OA.Trust.rewards(record)
    local codex = OA.Store.section(record, "codex")
    local requests = {}
    if OA.Requests then
        for _, fullType in ipairs(OA.Requests.list(record)) do requests[fullType] = true end
    end
    codex.cells = codex.cells or {}
    return {
        day = OA.day(), tier = rewards.tier, rewards = rewards, record = record,
        rate = (1 + rewards.rate) * (OA.option("CreditMultiplier") or 1.0),
        trustAccel = rewards.trustAccel,
        requestBonus = rewards.requestBonus,
        index = live(OA.Market.index),
        refused = live(OA.Market.refused),
        requests = requests,
        requestUsed = OA.Requests and OA.Requests.used(record) or {},
        cellUsed = codex.cells,
    }
end

function Value.context(record)
    local rewards = OA.Trust.rewards(record)
    local ctx = contexts[record.id]
    if ctx and ctx.day == OA.day() and ctx.tier == rewards.tier and ctx.record == record then return ctx end
    ctx = Value.buildContext(record)
    contexts[record.id] = ctx
    return ctx
end

-- Forgets the made contexts (a new request list, a test).
function Value.reset()
    contexts = {}
end

-- One flight's settlement: `entries` is the sealed boxes' records, { info = ..., count = n } in any order. Values
-- every line at the market as it is now, sends the weight shipped to the market, uses up the request counters and
-- the new-region weights, and returns { credits (rounded once), trust, cashTrust, lines }. The record's credits and
-- trust are not changed: the trade part adds them with the debt.
function Value.settle(record, entries)
    local ctx = Value.buildContext(record)
    local taken = { requests = {}, cells = {} }
    local lines = {}
    local credits, trust, cashTrust = 0, 0, 0
    local shipped = {}
    for _, entry in ipairs(entries) do
        local line = Value.appraiseLine(entry.info, entry.count or 1, ctx, taken)
        table.insert(lines, line)
        credits = credits + line.credits
        trust = trust + line.trust
        cashTrust = cashTrust + line.cashTrust
        if line.requestUnits > 0 then
            taken.requests[line.fullType] = (taken.requests[line.fullType] or 0) + line.requestUnits
        end
        if line.regionWeight > 0 and entry.info.cell then
            taken.cells[entry.info.cell] = (taken.cells[entry.info.cell] or 0) + line.regionWeight
        end
        if line.category and line.weight > 0 then
            shipped[line.category] = (shipped[line.category] or 0) + line.weight
        end
    end
    -- Cash is not a sample: its trust is capped per flight.
    cashTrust = math.min(cashTrust, Value.CASH_TRUST_CAP)
    for fullType, n in pairs(taken.requests) do
        OA.Requests.consume(record, fullType, n)
    end
    local codex = OA.Store.section(record, "codex")
    codex.cells = codex.cells or {}
    for cell, w in pairs(taken.cells) do
        codex.cells[cell] = (codex.cells[cell] or 0) + w
    end
    for cat, w in pairs(shipped) do
        OA.Market.ship(cat, w, record)
    end
    return { credits = OA.round(credits), trust = trust + cashTrust, cashTrust = cashTrust, lines = lines,
        shipped = shipped }
end

return Value
