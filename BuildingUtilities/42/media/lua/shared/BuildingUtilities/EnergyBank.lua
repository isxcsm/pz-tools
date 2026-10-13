-- The bank of a panel's units (BU.Energy): its racks' batteries side by side, what they hold by kind and
-- condition, how they wear (faster in heat), how cold and the worst of them hold part of it back, which a box of the
-- bypass tier leaves out, and the source's run over a time: the bank charged by what the solar panels make over the
-- load and drawn when they make too little.
local BU = BuildingUtilities
local Store = BU.Store
local Energy = BU.Energy

-- A battery's share of the sandbox's capacity by its kind (Rack.batteryKind: standard, heavy-duty, sports). Vanilla
-- holds them alike; this mod tells them apart.
Energy.KIND_SHARE = { 1, 1.5, 0.75 }
-- Wear: condition lost per full bank drawn, by the charge it is drawn at; above HEAT_FROM degrees at its racks so
-- much more per degree, at most HEAT_MOST times. Cold below 0 degrees locks so much of the bank per degree, at most
-- COLD_MOST. Its worst battery holds back DRAG_MOST of it by the condition between its best and its worst (a new one
-- beside a dead one: the most), so that batteries alike are kept together. Heat, cold and the worst battery by
-- options. A worn battery is one below WEAK: a box of BYPASS_TIER leaves it out of its bank.
Energy.WEAK = 30
Energy.HEAT_FROM, Energy.HEAT_PER_DEGREE, Energy.HEAT_MOST = 30, 0.1, 3
Energy.COLD_PER_DEGREE, Energy.COLD_MOST = 0.015, 0.3
Energy.DRAG_MOST = 0.5
Energy.BYPASS_TIER = 4
-- The bank starts carrying the load again with this share of it usable, so that an empty bank charging from a weak
-- sun does not switch the power on and off every minute.
Energy.BANK_START = 0.10

function Energy.efficiency() return math.max(0, math.min(100, BU.sandbox("ChargeEfficiency", 85))) / 100 end
function Energy.wearRate() return math.max(0, BU.sandbox("WearRate", 1)) end
-- Cold locking part of the bank, heat wearing it, its worst battery holding it back: each a sandbox option, on by
-- default.
function Energy.coldLockEnabled() return BU.sandbox("BatteryColdLock", true) == true end
function Energy.heatWearEnabled() return BU.sandbox("BatteryHeatWear", true) == true end
function Energy.dragEnabled() return BU.sandbox("WeakBatteryDrag", true) == true end

-- Whether a box leaves a battery out of its bank: it is of the bypass tier and the battery is worn.
function Energy.bypassed(panel, record)
    return panel ~= nil and (panel.tier or 1) >= Energy.BYPASS_TIER and (record.condition or 100) < Energy.WEAK
end

-- What a battery gives at once by its kind (Rack.batteryKind), a share of BatteryOutput: the sports battery gives
-- more and holds less (KIND_SHARE), the heavy-duty one holds more.
Energy.KIND_OUTPUT = { 1, 1, 1.5 }

-- What is left of a battery as it wears (0.3 when worn out).
local function wornShare(record)
    return 0.3 + 0.7 * math.max(0, math.min(100, record.condition or 100)) / 100
end

-- What a battery holds full, in load-hours: its kind's share of BatteryCapacity, less as it wears.
function Energy.batteryCapacity(record)
    local base = math.max(0, BU.sandbox("BatteryCapacity", 2.0)) * Energy.KIND_SHARE[BU.Rack.batteryKind(record.type)]
    return base * wornShare(record)
end

-- What a battery adds to its box's limit (Panels.limit) while the bank has charge: its kind's share of BatteryOutput,
-- less as it wears.
function Energy.batteryOutput(record)
    local base = math.max(0, BU.sandbox("BatteryOutput", 0.15)) * Energy.KIND_OUTPUT[BU.Rack.batteryKind(record.type)]
    return base * wornShare(record)
end

-- Condition lost per full bank drawn at a charge (0 to 1): 1 above half, 2 at a fifth, 6 when empty.
function Energy.wearAt(charge)
    if charge >= 0.5 then return 1 end
    if charge >= 0.2 then return 1 + (0.5 - charge) / 0.3 end
    return 2 + 4 * (0.2 - math.max(0, charge)) / 0.2
end

-- The coldest and the hottest air at racks (BU.airAt, loaded or not; outside with none).
local function rackAir(racks)
    local coldest, hottest
    for _, rack in ipairs(racks) do
        local temperature = BU.airAt(rack)
        if not coldest or temperature < coldest then coldest = temperature end
        if not hottest or temperature > hottest then hottest = temperature end
    end
    if not coldest then
        coldest = getClimateManager():getTemperature()
        hottest = coldest
    end
    return coldest, hottest
end

local function coldOf(coldest)
    if not Energy.coldLockEnabled() or coldest >= 0 then return 0 end
    return math.min(Energy.COLD_MOST, -coldest * Energy.COLD_PER_DEGREE)
end

local function heatOf(hottest)
    if not Energy.heatWearEnabled() or hottest <= Energy.HEAT_FROM then return 1 end
    return math.min(Energy.HEAT_MOST, 1 + (hottest - Energy.HEAT_FROM) * Energy.HEAT_PER_DEGREE)
end

-- The share of a bank cold locks at its racks: by the coldest air of them. None without the option.
function Energy.coldShare(racks) return coldOf((rackAir(racks))) end

-- How many times faster the batteries at racks wear: by the hottest air of them. 1 without the option.
function Energy.heatWear(racks)
    local _, hottest = rackAir(racks)
    return heatOf(hottest)
end

-- A panel's bank, or nil (no batteries, or racks off: BU.enabled): racks, batteries (those it counts), bypassed (the
-- worn ones a box of the bypass tier leaves out: they keep their charge), capacity and energy (load-hours), charge
-- (0 to 1), weak (how many it counts are worn), cold (the share locked), drag (the share its worst battery holds back,
-- worst), heat (how many times faster they wear), usable (energy above what cold and the worst battery hold back) and
-- output (what its batteries give at once, less what cold locks).
function Energy.bank(panel)
    if not BU.enabled("rack") then return nil end
    local racks = BU.Units.working(panel, "rack")
    local bank = { racks = racks, batteries = {}, bypassed = {}, capacity = 0, energy = 0, weak = 0, output = 0 }
    local bypass = (panel.tier or 1) >= Energy.BYPASS_TIER
    local best, worst = nil, nil
    -- As Energy.batteryCapacity and Energy.batteryOutput, worked out here at once (a far box's run counts them all).
    local full, gives = math.max(0, BU.sandbox("BatteryCapacity", 2.0)), math.max(0, BU.sandbox("BatteryOutput", 0.15))
    local kindOf, shares, outputs = BU.Rack.batteryKind, Energy.KIND_SHARE, Energy.KIND_OUTPUT
    for _, rack in ipairs(racks) do
        for _, battery in ipairs(rack.batteries) do
            local condition = battery.condition or 100
            if bypass and condition < Energy.WEAK then
                bank.bypassed[#bank.bypassed + 1] = battery
            else
                local kind, worn = kindOf(battery.type), wornShare(battery)
                local capacity = full * shares[kind] * worn
                bank.batteries[#bank.batteries + 1] = battery
                bank.capacity = bank.capacity + capacity
                bank.energy = bank.energy + capacity * (battery.charge or 0)
                bank.output = bank.output + gives * outputs[kind] * worn
                if condition < Energy.WEAK then bank.weak = bank.weak + 1 end
                if not best or condition > (best.condition or 100) then best = battery end
                if not worst or condition < (worst.condition or 100) then worst = battery end
            end
        end
    end
    if #bank.batteries == 0 or bank.capacity <= 0 then return nil end
    bank.charge = bank.energy / bank.capacity
    local coldest, hottest = rackAir(racks)
    bank.cold, bank.heat = coldOf(coldest), heatOf(hottest)
    bank.drag = 0
    if Energy.dragEnabled() then
        bank.drag = Energy.DRAG_MOST * math.max(0, (best.condition or 100) - (worst.condition or 100)) / 100
    end
    bank.worst = bank.drag > 0 and worst or nil
    bank.usable = math.max(0, bank.energy - bank.capacity * (bank.cold + bank.drag))
    bank.output = bank.output * (1 - bank.cold)
    return bank
end

-- What a panel's bank adds to its limit now: its output while it holds usable charge, else 0. Handing the load to a
-- generator leaves the bank to carry what goes over the box's own share.
function Energy.boost(panel, bank)
    if not bank or bank.usable <= 0 then return 0 end
    return bank.output
end

-- The bank holds so much energy: its batteries, side by side, all at the same charge.
local function setEnergy(bank, energy)
    bank.energy = math.max(0, math.min(bank.capacity, energy))
    bank.charge = bank.energy / bank.capacity
    bank.usable = math.max(0, bank.energy - bank.capacity * (bank.cold + bank.drag))
    for _, battery in ipairs(bank.batteries) do battery.charge = bank.charge end
end

-- Each battery of the bank wears by so much condition.
local function wear(bank, loss)
    if loss <= 0 then return end
    for _, battery in ipairs(bank.batteries) do battery.condition = math.max(0, (battery.condition or 100) - loss) end
end

-- What the bank gives while another producer carries the load: what goes over the box's own share (Panels.capacity),
-- which its output stands for (Panels.limit); none while it has nothing above its floor.
function Energy.overDraw(panel, state, rules, bank)
    if not (bank and state.supplied) or Energy.inUse(state) then return 0 end
    if Energy.boost(panel, bank) <= 0 then return 0 end
    return math.max(0, rules.load - BU.Panels.capacity(panel))
end

-- The panel's units over so many hours, as its network is now (state) and by its rules (Energy.rules), in the weather
-- they had (Energy.weatherSteps: a box far from the players runs now and then): the bank takes what the solar panels
-- make over the load while the source carries it, or all of it while another producer does, and gives what they lack
-- down to the floor; while another producer carries the load, it gives what goes over the box's own share
-- (Energy.overDraw) down to empty; drawn, its batteries wear (faster in heat). bankFlow is what went in or out an hour
-- at the end: what it took, full at its capacity, or gave, empty at its floor. Returns whether the source can carry the load
-- now (available is whether it could), the bank and the output now.
function Energy.run(panel, state, hours, available, rules)
    rules = rules or Energy.rules(panel, state)
    local sun = Energy.sunlight()
    local output = Energy.output(panel, sun)
    local bank = Energy.bank(panel)
    if not bank then
        panel.bankFlow = nil
        return Energy.canCarry(output, rules.load, available), nil, output
    end
    local carrying = Energy.inUse(state) and state.supplied
    local over, floor = 0, rules.floor
    if not carrying then
        over = Energy.overDraw(panel, state, rules, bank)
        if over > 0 then floor = 0 end
    end
    -- What the solar panels make in full sun (their snow as now).
    local made = sun > 0 and output / sun or Energy.output(panel, 1)
    local efficiency, wearRate = Energy.efficiency(), Energy.wearRate() * bank.heat
    -- Step by step in plain numbers, the batteries set once at the end: energy, the least it is drawn to (its floor
    -- and what cold and the worst battery hold back), and the condition each battery lost (by the share of a full bank drawn, at the charge it
    -- is drawn at).
    local capacity, energy, rate, loss = bank.capacity, bank.energy, 0, 0
    local least = capacity * (bank.cold + bank.drag + floor)
    local steps, first, firstHours = Energy.weatherSteps(hours)
    for i = first, #steps do
        local spell = i == first and firstHours or steps[i][1]
        local flow = made * steps[i][2] - (carrying and rules.load or over)
        -- The rate it moves at, limited by its room (or what it has above its floor) over the time; with no time, by
        -- whether it has any.
        rate = 0
        if flow > 0 then
            local room = math.max(0, capacity - energy)
            rate = flow * efficiency
            if spell > 0 then rate = math.min(rate, room / spell) elseif room <= 0 then rate = 0 end
        elseif flow < 0 then
            local above = math.max(0, energy - least)
            rate = flow
            if spell > 0 then rate = math.max(rate, -above / spell) elseif above <= 0 then rate = 0 end
            loss = loss - rate * spell / capacity * Energy.wearAt(energy / capacity) * wearRate
        end
        energy = math.max(0, math.min(capacity, energy + rate * spell))
    end
    wear(bank, loss)
    setEnergy(bank, energy)
    panel.bankFlow = rate
    if Energy.canCarry(output, rules.load, available) then return true, bank, output end
    return bank.usable > bank.capacity * (available and rules.floor or rules.restart), bank, output
end

-- What the bank holds usable above the floor its rules keep (a share of its capacity).
function Energy.aboveFloor(bank, floor) return math.max(0, bank.usable - bank.capacity * floor) end

-- How many hours the bank lasts drawn at a flow (below 0, load an hour) down to that floor; nil when it is not drawn.
function Energy.bankHoursLeft(bank, floor, flow)
    if not bank or flow >= 0 then return nil end
    return Energy.aboveFloor(bank, floor) / -flow
end
