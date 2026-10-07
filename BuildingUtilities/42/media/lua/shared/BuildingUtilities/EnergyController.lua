-- The charge controller of a panel's units (BU.Energy, from tier 3): its settings, quiet hours, and the rules the
-- source runs by each minute.
local BU = BuildingUtilities
local Energy = BU.Energy

-- The charge controller's settings, in percent of the bank and hours of the day: below start it hands the load to a
-- generator, above stop it takes it back; in quiet hours (from quietFrom to quietTo; none when equal) it starts no
-- generator; at tier 4, below protect it keeps the devices that are not essential off.
Energy.DEFAULTS = { start = 30, stop = 90, quietFrom = 22, quietTo = 6, protect = 20 }
Energy.CHOICES = { start = { 10, 20, 30, 40, 50 }, stop = { 60, 70, 80, 90, 100 }, protect = { 10, 20, 30, 40 },
    quiet = { { 0, 0 }, { 21, 6 }, { 22, 6 }, { 23, 7 }, { 0, 5 } } }

-- Whether a panel's bank has a charge controller: from its tier, while the controller is on (BU.enabled). Without one
-- the bank runs as at tier 2.
function Energy.hasController(panel)
    return (panel.tier or 1) >= BU.CONTROLLER_TIER and BU.enabled("controller")
end

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

-- How the source runs for a panel this minute, by its tier and settings: load (what its devices draw, without what
-- the bank takes to charge), charging (that), floor (the share of the bank it is not drawn below: the cutoff at
-- tier 4; with a charge controller and a generator to hand over to, its start setting, but in quiet hours), restart
-- (the share it needs to carry the load again: BANK_START over the floor, or the stop setting), quiet, generators (whether
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
    local controller = Energy.hasController(panel)
    local quiet = controller and Energy.isQuiet(settings)
    local floor = tier >= BU.SMART_TIER and Energy.CUTOFF or 0
    local restart = floor + Energy.BANK_START
    if controller and generators and not quiet then
        floor = math.max(floor, settings.start / 100)
        restart = math.max(restart, settings.stop / 100)
    end
    local charging = Energy.charging(panel)
    return { load = math.max(0, (state.load or 0) - charging * (state.loadFactor or 1)), charging = charging,
        floor = floor, restart = restart, quiet = quiet, generators = generators, settings = settings }
end
