-- The bank of a panel's units (BU.Energy, from tier 2): its racks' batteries side by side, what they hold by kind and
-- condition, how they wear, how cold locks part of them, and the source's run over a time: the bank charged by what
-- the solar panels make over the load and drawn when they make too little.
local BU = BuildingUtilities
local Store = BU.Store
local Energy = BU.Energy

-- A battery's share of the sandbox's capacity by its kind (Rack.batteryKind: standard, heavy-duty, sports). Vanilla
-- holds them alike; this mod tells them apart.
Energy.KIND_SHARE = { 1, 1.5, 0.75 }
-- Wear: condition lost per full bank drawn, by the charge it is drawn at; a worn battery (below WEAK) takes so much
-- of the bank a day; cold below 0 degrees locks so much of it per degree, at most COLD_MOST (these two by options).
Energy.WEAK, Energy.WEAK_PER_DAY = 30, 0.02
Energy.COLD_PER_DEGREE, Energy.COLD_MOST = 0.015, 0.3
-- The bank starts carrying the load again with this share of it usable, so that an empty bank charging from a weak
-- sun does not switch the power on and off every minute. At tier 4 it is never drawn below CUTOFF.
Energy.BANK_START, Energy.CUTOFF = 0.10, 0.05

function Energy.efficiency() return math.max(0, math.min(100, BU.sandbox("ChargeEfficiency", 85))) / 100 end
function Energy.wearRate() return math.max(0, BU.sandbox("WearRate", 1)) end
-- Cold locking part of the bank, and worn batteries draining it: each a sandbox option, on by default.
function Energy.coldLockEnabled() return BU.sandbox("BatteryColdLock", true) == true end
function Energy.weakDrainEnabled() return BU.sandbox("WornBatteryDrain", true) == true end

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

-- The share of a bank cold locks at its racks: the coldest of them that is loaded, else the air outside. None
-- without the option.
function Energy.coldShare(racks)
    if not Energy.coldLockEnabled() then return 0 end
    local climate, coldest = getClimateManager(), nil
    for _, rack in ipairs(racks) do
        local square = getCell():getGridSquare(rack.x, rack.y, rack.z)
        local temperature = square and climate:getAirTemperatureForSquare(square) or nil
        if temperature and (not coldest or temperature < coldest) then coldest = temperature end
    end
    coldest = coldest or climate:getTemperature()
    if coldest >= 0 then return 0 end
    return math.min(Energy.COLD_MOST, -coldest * Energy.COLD_PER_DEGREE)
end

-- A panel's bank, or nil (below BU.BANK_TIER, no batteries, or racks off: BU.enabled): racks, batteries, capacity and
-- energy (load-hours), charge (0 to 1), weak (how many are worn), cold (the share locked), usable (energy above what
-- cold locks) and output (what its batteries give at once, less what cold locks).
function Energy.bank(panel)
    if panel.parent or (panel.tier or 1) < BU.BANK_TIER or not BU.enabled("rack") then return nil end
    local racks = Store.unitList("rack", panel.id)
    local bank = { racks = racks, batteries = {}, capacity = 0, energy = 0, weak = 0, output = 0 }
    for _, rack in ipairs(racks) do
        for _, battery in ipairs(rack.batteries) do
            local capacity = Energy.batteryCapacity(battery)
            bank.batteries[#bank.batteries + 1] = battery
            bank.capacity = bank.capacity + capacity
            bank.energy = bank.energy + capacity * (battery.charge or 0)
            bank.output = bank.output + Energy.batteryOutput(battery)
            if (battery.condition or 100) < Energy.WEAK then bank.weak = bank.weak + 1 end
        end
    end
    if #bank.batteries == 0 or bank.capacity <= 0 then return nil end
    bank.charge = bank.energy / bank.capacity
    bank.cold = Energy.coldShare(racks)
    bank.usable = math.max(0, bank.energy - bank.capacity * bank.cold)
    bank.output = bank.output * (1 - bank.cold)
    return bank
end

-- The share of a bank it gives its output down to (the cutoff at tier 4, else empty): a charge controller's start
-- setting hands the load to a generator but leaves the bank to carry what goes over the box's own share.
function Energy.boostFloor(panel) return (panel.tier or 1) >= BU.SMART_TIER and Energy.CUTOFF or 0 end

-- What a main panel's bank adds to its limit now: its output while it holds usable charge above its floor, else 0.
function Energy.boost(panel, bank)
    if not bank then return 0 end
    if Energy.aboveFloor(bank, Energy.boostFloor(panel)) <= 0 then return 0 end
    return bank.output
end

-- The bank holds so much energy: its batteries, side by side, all at the same charge.
local function setEnergy(bank, energy)
    bank.energy = math.max(0, math.min(bank.capacity, energy))
    bank.charge = bank.energy / bank.capacity
    bank.usable = math.max(0, bank.energy - bank.capacity * bank.cold)
    for _, battery in ipairs(bank.batteries) do battery.charge = bank.charge end
end

-- So much drawn from the bank at its charge now: each battery wears by that share of a full bank.
local function wear(bank, drawn)
    local loss = drawn / bank.capacity * Energy.wearAt(bank.charge) * Energy.wearRate()
    for _, battery in ipairs(bank.batteries) do battery.condition = math.max(0, (battery.condition or 100) - loss) end
end

-- What the bank gives while another producer carries the load: what goes over the box's own share (Panels.capacity),
-- which its output stands for (Panels.limit); none while it has nothing above its floor.
function Energy.overDraw(panel, state, rules, bank)
    if not (bank and state.supplied) or Energy.inUse(state) then return 0 end
    if Energy.boost(panel, bank) <= 0 then return 0 end
    return math.max(0, rules.load - BU.Panels.capacity(panel))
end

-- The panel's units over so many hours, as its network is now (state) and by its rules (Energy.rules): the bank
-- takes what the solar panels make over the load while the source carries it, or all of it and what the controller
-- charges while another producer does, and gives what they lack down to the floor; while another producer carries
-- the load, it gives what goes over the box's own share (Energy.overDraw) down to its output's floor. Worn batteries
-- drain it (an option). bankFlow is what went in or out an hour: what it took, full at its capacity, or gave, empty at
-- its floor. Returns whether the source can carry the load now (available is whether it could), the bank and the
-- output.
function Energy.run(panel, state, hours, available, rules)
    rules = rules or Energy.rules(panel, state)
    local output = Energy.output(panel)
    local bank = Energy.bank(panel)
    if not bank then
        panel.bankFlow = nil
        return Energy.canCarry(output, rules.load, available), nil, output
    end
    local carrying = Energy.inUse(state) and state.supplied
    local flow, floor = 0, rules.floor
    if carrying then
        flow = output - rules.load
    else
        local over = Energy.overDraw(panel, state, rules, bank)
        flow = output + (state.supplied and rules.charging or 0) - over
        if over > 0 then floor = Energy.boostFloor(panel) end
    end
    local energy = bank.energy
    -- The rate it moves at, limited by its room (or what it has above its floor) over the time; with no time, by
    -- whether it has any.
    local rate = 0
    if flow > 0 then
        local room = math.max(0, bank.capacity - energy)
        rate = flow * Energy.efficiency()
        if hours > 0 then rate = math.min(rate, room / hours) elseif room <= 0 then rate = 0 end
    elseif flow < 0 then
        local above = Energy.aboveFloor(bank, floor)
        rate = flow
        if hours > 0 then rate = math.max(rate, -above / hours) elseif above <= 0 then rate = 0 end
        wear(bank, -rate * hours)
    end
    energy = energy + rate * hours
    if Energy.weakDrainEnabled() then
        energy = energy - bank.weak * Energy.WEAK_PER_DAY * bank.capacity * hours / 24
    end
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
