-- What a delivery is worth (NUMBERS 1). `info` (ARCHITECTURE 5) is an item as a plain table; Value.info makes one
-- from a game item and is the only part here that touches the game. The rest is arithmetic on tables:
--   credits = weight * unit * index * state * (new region) * rate
--   trust   = weight * unit / 100 * state * accel
-- state is 0.5 + 0.5 * condition (food: fresh 1, stale 0.5). The market index, the new-region bonus and the
-- exchange rate never touch trust, so no one can farm trust through them. Cash and this mod's goods have fixed
-- values. So does an item of a group on this week's request list, for the first units of the week: its line's price,
-- or the item's own worth by weight when that is more (Requests.priceOf; never less than the unit's own value at the
-- day's index) times state and rate, no new-region bonus, and a bonus of trust when the line is full. A whole flight
-- is rounded once, in settle (DESIGN 9).
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
Value.CASH_CREDITS = 100         -- credits per dollar
Value.CASH_TRUST = 0.02          -- trust per dollar ...
Value.CASH_TRUST_CAP = 50        -- ... at most this much per flight
Value.HIGH, Value.LOW = 1.10, 0.90   -- index marks "high" / "low" past these

-- Cash, in dollars (a bundle counts as the 100 bills it unfolds into).
Value.CASH = { ["Base.Money"] = 1, ["Base.MoneyBundle"] = 100 }

-- The mod's own goods that are taken: credits and trust for one, no market. Other goods of the mod (serums, kits,
-- machines, parts, gear) are shop goods and not taken. A selected sample (시료 감별) is a sample bundle of a better
-- grade. "MissionItem" is worth what its mission pays (the story part settles it); "ExpiredMission" is a mission item
-- past its time. A meteorite fragment is not sold: it goes to the research team and opens a capstone (the story part
-- tells the upgrades when it settles: Story.onSettled).
Value.OWN = {
    SampleBundle = { credits = 600, trust = 6 },
    SelectedSample = { credits = 1200, trust = 12 },
    MeteorFragment = { credits = 0, trust = 10, fragment = true },
    MeteorFragmentIron = { credits = 0, trust = 10, fragment = true },
    MeteorFragmentStonyIron = { credits = 0, trust = 10, fragment = true },
    ExpiredMission = { credits = 1000, trust = 5 },
    MissionItem = { credits = 0, trust = 0 },
    -- Zombie samples by grade (NUMBERS 4 '좀비 시료'). A target mission's sample is its mission's while that runs; after,
    -- it is a common sample like any other.
    TissueCommon = { credits = 200, trust = 2 },
    TissueInfected = { credits = 400, trust = 4 },
    TissueNeural = { credits = 1000, trust = 10 },
    TissueAnomalous = { credits = 3000, trust = 30 },
    TissueTarget = { credits = 200, trust = 2 },
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

-- What an item type fixes, for the session (an item type's name, cash value, own kind and furniture flag do not change
-- under a running game): by full type { baseType, cash, own, moveable }. `moveable` is added by the first read of an
-- item or script of the type. A type is parsed once; Value.info then reads only what is the item's own.
local kinds = {}
local function kindOf(fullType)
    local kind = kinds[fullType]
    if not kind then
        kind = { baseType = Value.baseType(fullType), cash = Value.CASH[fullType], own = ownKind(fullType) }
        kinds[fullType] = kind
    end
    return kind
end

-- info of an item type from its script (no item exists): weight, category, furniture. Used for the loot tables
-- and for items found without an item in hand.
function Value.infoFromScript(script)
    local fullType = script:getFullName()
    local kind = kindOf(fullType)
    if kind.moveable == nil then kind.moveable = script:isItemType(ItemType.MOVEABLE) and true or false end
    local info = {
        fullType = fullType,
        baseType = kind.baseType,
        weight = script:getActualWeight(),
        displayCategory = script:getDisplayCategory(),
        moveable = kind.moveable,
        cash = kind.cash,
        own = kind.own,
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
    local kind = kindOf(fullType)
    if kind.moveable == nil then kind.moveable = item:isItemType(ItemType.MOVEABLE) and true or false end
    local info = {
        fullType = fullType,
        baseType = kind.baseType,
        weight = weight,
        displayCategory = item:getDisplayCategory() or item:getCategory(),
        moveable = kind.moveable,
        cash = kind.cash,
        own = kind.own,
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
        -- (past its time, one of the mod's own goods is worth what that good is: a target's sample is a sample)
        if not expired then
            info.own = "MissionItem"
        elseif not Value.OWN[info.own] then
            info.own = "ExpiredMission"
        end
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
--   { fullType, baseType, count, weight (total), category, credits, trust, cashTrust, marks, requestUnits,
--     requestCredits (what the request units fetch), requestPrice (a request unit's price before the index, state
--     and rate; nil off the list), requestKey (the item's request group), marketWeight (the
--     weight that goes to the market: not the request units), regionWeight }
function Value.appraiseLine(info, count, ctx, taken)
    count = count or 1
    local line = {
        fullType = info.fullType, baseType = info.baseType, count = count, credits = 0, trust = 0, cashTrust = 0,
        weight = 0, marks = { request = false, newRegion = false, high = false, low = false, refused = false },
        requestUnits = 0, requestCredits = 0, regionWeight = 0,
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
        if def and def.fragment then
            line.marks.fragment = true
            line.note = Value.FRAGMENT_NOTE()
        end
        return line
    end
    local cat, why = Categories.of(info)
    if not cat then
        if why == "Meteor" then
            line.marks.bigMeteorite = true
            line.note = Value.BIG_METEORITE_NOTE()
        end
        return line
    end
    line.category = cat
    local w = math.max(info.weight or 0, 0)
    line.weight = w * count
    local unit = Categories.unitOf(cat, info.displayCategory)
    local index = ctx.index and ctx.index[cat] or 1.0
    local state = Value.state(info)
    line.marks.high = index >= Value.HIGH
    line.marks.low = index <= Value.LOW
    line.marks.refused = ctx.refused and ctx.refused[cat] and true or false
    line.trust = w * unit / 100 * state * (ctx.trustAccel or 1.0) * count
    -- The units of this week's request come first, at the group's fixed price; the others are valued by weight. The
    -- line's counters are its group's (key), shared by every type the group takes.
    local key = OA.Requests.keyOf(info.fullType)
    local request = ctx.requests and ctx.requests[key]
    local nReq = 0
    if request then
        local used = (ctx.requestUsed and ctx.requestUsed[key] or 0)
            + (taken and taken.requests and taken.requests[key] or 0)
        nReq = math.max(0, math.min(count, request.qty - used))
    end
    line.requestKey = key
    local rest = count - nReq
    -- How many of the others earn the new-region premium.
    local full, partial, consumed = 0, 0, 0
    if info.cell and w > 0 and rest > 0 then
        local used = (ctx.cellUsed and ctx.cellUsed[info.cell] or 0)
            + (taken and taken.cells and taken.cells[info.cell] or 0)
        local room = math.max(0, Value.NEW_REGION_WEIGHT - used)
        if room > 0 then
            full = math.min(rest, math.floor(room / w))
            if full < rest then partial = (room - full * w) / w end
            if partial > 1 then partial = 1 end
            consumed = math.min(room, w * rest)
        end
    end
    local sum = rest + Value.NEW_REGION_BONUS * (full + partial)
    -- A request unit fetches its line's price, or its own worth by weight when that is more (each kind of a group at
    -- its own, Requests.priceOf), and never less than it would unrequested at today's index (the new-region premium
    -- is never a request unit's: NUMBERS 2).
    if request then
        line.requestPrice = OA.Requests.priceOf(request, w * unit)
        line.requestCredits = nReq * math.max(line.requestPrice, w * unit * index) * state * rate
    end
    line.credits = w * unit * index * state * rate * sum + line.requestCredits
    line.marketWeight = w * rest
    line.marks.request = nReq > 0
    line.marks.newRegion = consumed > 0
    line.requestUnits = nReq
    line.regionWeight = consumed
    return line
end

-- The receipt notes of the two meteorite goods: the story part's words when it is there, else this part's own.
-- A line carries the key as `note`, and as a mark so that the trade part's receipt shows it after the item.
function Value.BIG_METEORITE_NOTE()
    return OA.Story and OA.Story.BIG_METEORITE_RECEIPT or "IGUI_OA_Econ_Receipt_BigMeteorite"
end
function Value.FRAGMENT_NOTE()
    return OA.Story and OA.Story.FRAGMENT_RECEIPT or "IGUI_OA_Econ_Receipt_Fragment"
end

-- The translation keys of the marks an item shows in a tooltip or the estimate window, in the order to show them.
function Value.markKeys(marks)
    local keys = {}
    if marks.bigMeteorite then table.insert(keys, Value.BIG_METEORITE_NOTE()) end
    if marks.fragment then table.insert(keys, Value.FRAGMENT_NOTE()) end
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
--   rate (the exchange rate: the reward and CreditMultiplier), trustAccel, index (live), refused (live),
--   requests (this week's request lines by group key, as Requests.entries gives them), requestUsed (live), cellUsed,
--   rewards.
-- Everything that moves within the day (the index, what the request counters and cells have used) is a live table.
local contexts = {}

function Value.buildContext(record)
    local rewards = OA.Trust.rewards(record)
    local codex = OA.Store.section(record, "codex")
    local requests = {}
    if OA.Requests then
        for _, line in ipairs(OA.Requests.entries(record)) do requests[line.fullType] = line end
    end
    codex.cells = codex.cells or {}
    return {
        day = OA.day(), tier = rewards.tier, rewards = rewards, record = record,
        rate = (1 + rewards.rate) * (OA.option("CreditMultiplier") or 1.0),
        trustAccel = rewards.trustAccel,
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
    -- The rewards table is made again when a level, stage or milestone changes (the prices, the rate, the list).
    if ctx and ctx.day == OA.day() and ctx.rewards == rewards and ctx.record == record then return ctx end
    ctx = Value.buildContext(record)
    contexts[record.id] = ctx
    return ctx
end

-- Forgets the made contexts (a new request list, a test).
function Value.reset()
    contexts = {}
end

-- The request lines a flight fills to their quantity: { fills = { { fullType (the group's key), band, trust } ... },
-- trust }. `taken` is what the flight settles of each group as requests ({ requests = { key = units } }); the units
-- earlier flights settled this week (ctx.requestUsed) are already counted. A line gives its trust once, as it becomes
-- full.
function Value.requestFills(ctx, taken)
    local fills, total = {}, 0
    for key, n in pairs(taken.requests or {}) do
        local request = ctx.requests and ctx.requests[key]
        if request and n > 0 then
            local used = ctx.requestUsed and ctx.requestUsed[key] or 0
            if used < request.qty and used + n >= request.qty then
                fills[#fills + 1] = { fullType = key, band = request.band, trust = request.trust }
                total = total + request.trust
            end
        end
    end
    table.sort(fills, function(a, b) return a.fullType < b.fullType end)
    return { fills = fills, trust = total }
end

-- Entries ({ info, count }) valued as one flight at a context, changing nothing: { credits (not rounded), trust (with
-- the cash's capped and the filled request lines'), cashTrust (capped), lines (one for each entry), taken (what the
-- flight settles of each request group and region: { requests, cells }), shipped (category -> weight sent to the
-- market), fills (the request lines the flight makes full) }. Value.settle uses it up; the estimate only shows it.
function Value.flight(ctx, entries)
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
            taken.requests[line.requestKey] = (taken.requests[line.requestKey] or 0) + line.requestUnits
        end
        if line.regionWeight > 0 and entry.info.cell then
            taken.cells[entry.info.cell] = (taken.cells[entry.info.cell] or 0) + line.regionWeight
        end
        -- The request units are bought at a fixed price and leave the market alone.
        local marketWeight = line.marketWeight or line.weight
        if line.category and marketWeight > 0 then
            shipped[line.category] = (shipped[line.category] or 0) + marketWeight
        end
    end
    -- Cash is not a sample: its trust is capped per flight.
    cashTrust = math.min(cashTrust, Value.CASH_TRUST_CAP)
    local fills = Value.requestFills(ctx, taken)
    return { credits = credits, trust = trust + cashTrust + fills.trust, cashTrust = cashTrust, lines = lines,
        taken = taken, shipped = shipped, fills = fills.fills }
end

-- One flight's settlement: `entries` is the sealed boxes' records, { info = ..., count = n } in any order. Values
-- every line at the market as it is now, sends the weight shipped to the market, uses up the request counters and
-- the new-region weights, and returns { credits (rounded once), trust, cashTrust, lines, shipped, filled }. `filled`
-- are the request lines this flight made full ({ fullType (the key), band, trust }); their trust is in `trust`. The
-- record's credits and trust are not changed: the trade part adds them with the debt.
function Value.settle(record, entries)
    local flight = Value.flight(Value.buildContext(record), entries)
    for key, n in pairs(flight.taken.requests) do
        OA.Requests.consume(record, key, n)
    end
    local codex = OA.Store.section(record, "codex")
    codex.cells = codex.cells or {}
    for cell, w in pairs(flight.taken.cells) do
        codex.cells[cell] = (codex.cells[cell] or 0) + w
    end
    for cat, w in pairs(flight.shipped) do
        OA.Market.ship(cat, w, record)
    end
    return { credits = OA.round(flight.credits), trust = flight.trust, cashTrust = flight.cashTrust, lines = flight.lines,
        shipped = flight.shipped, filled = flight.fills }
end

return Value
