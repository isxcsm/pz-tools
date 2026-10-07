-- A main panel's units as one power source of its network, named Energy.SOURCE (the API's setSource): this mod
-- works out what its solar panels make and says whether that carries the load. The API does the rest as for a
-- generator: the source switched on last carries the load, and when it cannot, the next producer takes over.
-- Snow lies on panels outside while it snows and melts when it is warm; a player can brush it off.
-- From tier 2 the panel's racks are its bank: what the panels make over the load charges it, and it carries the
-- load when they make too little. The batteries wear by how deep they are drawn, worn ones drain the bank, and cold
-- locks part of it.
require "BuildingUtilities/Units"
local BU = BuildingUtilities
local Store, Panels, Units = BU.Store, BU.Panels, BU.Units
local Energy = {}
BU.Energy = Energy

Energy.SOURCE = "solar"
-- The source starts carrying the load only with this much over it, and stops below the load itself, so a cloud
-- passing does not switch it back and forth.
Energy.START_MARGIN = 1.1
-- Snow: it settles while it snows at least this hard, covering a panel in two hours, and melts above 2 degrees in
-- four. Below a trace it is none.
Energy.SNOW_FROM, Energy.SNOW_PER_HOUR, Energy.MELT_ABOVE, Energy.MELT_PER_HOUR = 0.2, 0.5, 2, 0.25
Energy.SNOW_TRACE = 0.05

-- What one clean panel makes in full sun, in load (a fridge draws 0.13).
function Energy.rated() return math.max(0, BU.sandbox("SolarOutput", 0.08)) end
function Energy.snowEnabled() return BU.sandbox("SnowOnPanels", true) == true end

-- The game's daylight, 0 at night to 1; storms and the season darken it already.
function Energy.sunlight()
    return math.max(0, math.min(1, getClimateManager():getDayLightStrength()))
end

function Energy.panelOutput(unit, sun)
    return Energy.rated() * (sun or Energy.sunlight()) * (1 - (unit.snow or 0))
end

-- Whether a panel's network has the source: a main panel with units.
function Energy.hasSource(panel)
    return not panel.parent and #Store.unitList(nil, panel.id) > 0
end

-- What a panel's solar panels make now, how many there are and how much snow lies on them on average (0 to 1).
function Energy.output(panel)
    local sun, total, count, snow = Energy.sunlight(), 0, 0, 0
    for _, unit in ipairs(Store.unitList("solar", panel.id)) do
        total = total + Energy.panelOutput(unit, sun)
        count = count + 1
        snow = snow + (unit.snow or 0)
    end
    return total, count, count > 0 and snow / count or 0
end

-- The source's entry in the network's state (its available and running), or nil.
function Energy.sourceState(state)
    for _, producer in ipairs(state and state.producers or {}) do
        if producer.source == Energy.SOURCE then return producer end
    end
    return nil
end

function Energy.inUse(state)
    return state ~= nil and state.producer ~= nil and state.producer.source == Energy.SOURCE
end

-- Steps of the source's line: from its nearest unit to the building, or nil.
function Energy.lineSteps(panel)
    local best
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do
        local steps = Panels.steps(panel, unit.x, unit.y)
        if steps and (not best or steps < best) then best = steps end
    end
    return best
end

-- Whether the source can carry the load: what the panels make against it, with the margin to start.
function Energy.canCarry(output, load, available)
    if output <= 0 then return false end
    return output >= (load or 0) * (available and 1 or Energy.START_MARGIN)
end

-- Snow on every solar panel outside over so many hours of the weather now; returns whether any changed much.
function Energy.weather(hours)
    if not Energy.snowEnabled() then return false end
    local climate = getClimateManager()
    local settles = climate:isSnowing() and climate:getSnowIntensity() >= Energy.SNOW_FROM
    local melts = climate:getTemperature() > Energy.MELT_ABOVE
    local changed = false
    for _, unit in ipairs(Store.unitList("solar")) do
        local before = unit.snow or 0
        local snow = before
        if settles then snow = snow + Energy.SNOW_PER_HOUR * hours
        elseif melts then snow = snow - Energy.MELT_PER_HOUR * hours end
        snow = math.max(0, math.min(1, snow))
        if snow < Energy.SNOW_TRACE and not settles then snow = 0 end
        unit.snow = snow > 0 and snow or nil
        if math.floor(before * 10) ~= math.floor(snow * 10) then changed = true end
    end
    return changed
end

-- The bank.

-- A battery's share of the sandbox's capacity by its kind (Units.batteryKind: standard, heavy-duty, sports). Vanilla
-- holds them alike; this mod tells them apart.
Energy.KIND_SHARE = { 1, 1.5, 0.75 }
-- Wear: condition lost per full bank drawn, by the charge it is drawn at; a worn battery (below WEAK) takes so much
-- of the bank a day; cold below 0 degrees locks so much of it per degree, at most COLD_MOST.
Energy.WEAK, Energy.WEAK_PER_DAY = 30, 0.02
Energy.COLD_PER_DEGREE, Energy.COLD_MOST = 0.015, 0.3
-- The bank starts carrying the load again with this share of it usable. At tier 4 it is never drawn below CUTOFF.
-- A charge controller charges it from a generator at most CHARGE_RATE an hour a battery.
Energy.BANK_START, Energy.CUTOFF, Energy.CHARGE_RATE = 0.02, 0.05, 0.1

-- The charge controller's settings, in percent of the bank and hours of the day: below start it hands the load to a
-- generator, above stop it takes it back; in quiet hours (from quietFrom to quietTo; none when equal) it starts no
-- generator; at tier 4, below protect it keeps the devices that are not essential off.
Energy.DEFAULTS = { start = 30, stop = 90, quietFrom = 22, quietTo = 6, protect = 20 }
Energy.CHOICES = { start = { 10, 20, 30, 40, 50 }, stop = { 60, 70, 80, 90, 100 }, protect = { 10, 20, 30, 40 },
    quiet = { { 0, 0 }, { 21, 6 }, { 22, 6 }, { 23, 7 }, { 0, 5 } } }

function Energy.settings(panel)
    local saved, result = panel.controller or {}, {}
    for name, value in pairs(Energy.DEFAULTS) do
        result[name] = type(saved[name]) == "number" and saved[name] or value
    end
    return result
end

-- Whether settings are ones the controller takes: from its choices, start below stop.
function Energy.validSettings(settings)
    local function among(list, value)
        for _, choice in ipairs(list) do if choice == value then return true end end
        return false
    end
    local quiet = false
    for _, pair in ipairs(Energy.CHOICES.quiet) do quiet = quiet or (pair[1] == settings.quietFrom and pair[2] == settings.quietTo) end
    return quiet and among(Energy.CHOICES.start, settings.start) and among(Energy.CHOICES.stop, settings.stop)
        and among(Energy.CHOICES.protect, settings.protect) and settings.start < settings.stop
end

function Energy.isQuiet(settings)
    local from, to = settings.quietFrom, settings.quietTo
    if from == to then return false end
    local hour = getGameTime():getTimeOfDay()
    if from < to then return hour >= from and hour < to end
    return hour >= from or hour < to
end

function Energy.efficiency() return math.max(0, math.min(100, BU.sandbox("ChargeEfficiency", 85))) / 100 end
function Energy.wearRate() return math.max(0, BU.sandbox("WearRate", 1)) end

-- What a battery holds full, in load-hours: its kind's share of BatteryCapacity, less as it wears.
function Energy.batteryCapacity(record)
    local base = math.max(0, BU.sandbox("BatteryCapacity", 2.0)) * Energy.KIND_SHARE[Units.batteryKind(record.type)]
    return base * (0.3 + 0.7 * math.max(0, math.min(100, record.condition or 100)) / 100)
end

-- Condition lost per full bank drawn at a charge (0 to 1): 1 above half, 2 at a fifth, 6 when empty.
function Energy.wearAt(charge)
    if charge >= 0.5 then return 1 end
    if charge >= 0.2 then return 1 + (0.5 - charge) / 0.3 end
    return 2 + 4 * (0.2 - math.max(0, charge)) / 0.2
end

-- The share of a bank cold locks at its racks: the coldest of them that is loaded, else the air outside.
function Energy.coldShare(racks)
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

-- A panel's bank, or nil (below BU.BANK_TIER, or no batteries): racks, batteries, capacity and energy (load-hours),
-- charge (0 to 1), weak (how many are worn), cold (the share locked) and usable (energy above what cold locks).
function Energy.bank(panel)
    if panel.parent or (panel.tier or 1) < BU.BANK_TIER then return nil end
    local racks = Store.unitList("rack", panel.id)
    local bank = { racks = racks, batteries = {}, capacity = 0, energy = 0, weak = 0 }
    for _, rack in ipairs(racks) do
        for _, battery in ipairs(rack.batteries) do
            local capacity = Energy.batteryCapacity(battery)
            bank.batteries[#bank.batteries + 1] = battery
            bank.capacity = bank.capacity + capacity
            bank.energy = bank.energy + capacity * (battery.charge or 0)
            if (battery.condition or 100) < Energy.WEAK then bank.weak = bank.weak + 1 end
        end
    end
    if #bank.batteries == 0 or bank.capacity <= 0 then return nil end
    bank.charge = bank.energy / bank.capacity
    bank.cold = Energy.coldShare(racks)
    bank.usable = math.max(0, bank.energy - bank.capacity * bank.cold)
    return bank
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

-- How the source runs for a panel this minute, by its tier and settings: load (what its devices draw, without what
-- the bank takes to charge), charging (that), floor (the share of the bank it is not drawn below: the cutoff at
-- tier 4; with a charge controller and a generator to hand over to, its start setting, but in quiet hours), restart
-- (the share it needs to carry the load again: 2% over the floor, or the stop setting), quiet, generators (whether
-- a generator of the panel could take over: on a loaded square, as the API hands over only to those, with fuel and
-- not broken) and settings.
function Energy.rules(panel, state)
    local settings = Energy.settings(panel)
    local tier = panel.tier or 1
    local generators = false
    for _, producer in ipairs(state.producers or {}) do
        if not producer.source and getCell():getGridSquare(producer.x, producer.y, producer.z)
                and (producer.fuel == nil or producer.fuel > 0) and (producer.condition == nil or producer.condition > 0) then
            generators = true
        end
    end
    local quiet = tier >= BU.CONTROLLER_TIER and Energy.isQuiet(settings)
    local floor = tier >= BU.SMART_TIER and Energy.CUTOFF or 0
    local restart = floor + Energy.BANK_START
    if tier >= BU.CONTROLLER_TIER and generators and not quiet then
        floor = math.max(floor, settings.start / 100)
        restart = math.max(restart, settings.stop / 100)
    end
    local charging = state.extraLoad or 0
    return { load = math.max(0, (state.load or 0) - charging * (state.loadFactor or 1)), charging = charging,
        floor = floor, restart = restart, quiet = quiet, generators = generators, settings = settings }
end

-- The panel's units over so many hours, as its network is now (state) and by its rules (Energy.rules): the bank
-- takes what the solar panels make over the load while the source carries it, or all of it and what the controller
-- charges while another producer does, and gives what they lack down to the floor; worn batteries drain it.
-- Returns whether the source can carry the load now (available is whether it could), the bank and the output.
function Energy.run(panel, state, hours, available, rules)
    rules = rules or Energy.rules(panel, state)
    local output = Energy.output(panel)
    local bank = Energy.bank(panel)
    if not bank then
        panel.bankFlow = nil
        return Energy.canCarry(output, rules.load, available), nil, output
    end
    local carrying = Energy.inUse(state) and state.supplied
    local flow
    if carrying then flow = output - rules.load
    else flow = output + (state.supplied and rules.charging or 0) end
    local energy = bank.energy
    if flow > 0 then
        energy = energy + flow * Energy.efficiency() * hours
    elseif flow < 0 then
        local drawn = math.min(-flow * hours, math.max(0, bank.usable - bank.capacity * rules.floor))
        wear(bank, drawn)
        energy = energy - drawn
    end
    energy = energy - bank.weak * Energy.WEAK_PER_DAY * bank.capacity * hours / 24
    setEnergy(bank, energy)
    panel.bankFlow = flow > 0 and flow * Energy.efficiency() or flow
    if Energy.canCarry(output, rules.load, available) then return true, bank, output end
    return bank.usable > bank.capacity * (available and rules.floor or rules.restart), bank, output
end

return Energy
