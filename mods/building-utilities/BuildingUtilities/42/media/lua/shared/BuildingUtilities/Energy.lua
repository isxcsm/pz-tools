-- A panel's units as one power source of its network, named Energy.SOURCE (the API's setSource): this mod
-- works out what its solar panels make and says whether that carries the load. The API does the rest as for a
-- generator: the source switched on last carries the load, and when it cannot, the next producer takes over.
-- Snow lies on panels while it snows and melts when it is warm (Energy.snowOf); a player can brush it off.
-- The panel's racks are its bank: what the panels make over the load charges it, and it carries the load when they
-- make too little. The batteries wear by how deep they are drawn, worn ones drain the bank, and cold
-- locks part of it.
require "BuildingUtilities/Units"
local BU = BuildingUtilities
local Store, Units = BU.Store, BU.Units
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

-- What a solar panel makes in a sun (now's if none); now: the minute, if the caller has it.
function Energy.panelOutput(unit, sun, now)
    return Energy.rated() * (sun or Energy.sunlight()) * (1 - Energy.snowOf(unit, now))
end

-- Whether a panel's network has the source: a panel with power units.
function Energy.hasSource(panel)
    return #Units.of(panel.id, "power") > 0
end

-- What a panel's solar panels make in a sun (now's if none), how many there are and how much snow lies on them on
-- average (0 to 1). None while they are off (BU.enabled).
function Energy.output(panel, sun)
    sun = sun or Energy.sunlight()
    local rated, now, clean, count = Energy.rated(), Energy.minute(), 0, 0
    for _, unit in ipairs(Units.working(panel, "solar")) do
        clean = clean + 1 - Energy.snowOf(unit, now)
        count = count + 1
    end
    return rated * sun * clean, count, count > 0 and 1 - clean / count or 0
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

-- Whether the source can carry the load: what the panels make against it, with the margin to start.
function Energy.canCarry(output, load, available)
    if output <= 0 then return false end
    return output >= (load or 0) * (available and 1 or Energy.START_MARGIN)
end

-- Snow is the same weather on every solar panel, so it is kept as a log of the weather's spells (Store.data().snowLog:
-- { m = the minute it began, r = snow an hour, s = it settles }, the newest last, the last SNOW_SPELLS of them), and a
-- panel's snow is worked out of it when asked (Energy.snowOf), from what lay on it at the minute it was last asked
-- (unit.snow, unit.snowAt). No panel is gone through each minute.
local SNOW_SPELLS = 200

-- The minute of the world now.
function Energy.minute() return math.floor(getGameTime():getWorldAgeHours() * 60 + 0.5) end

-- The daylight and the air outside are kept too, for the boxes far from the players that run now and then (Server):
-- each minute's summed by ten minutes (Store.data().sunLog: by the ten minutes since the world began { daylight,
-- minutes, air }), the last SUN_TENS of them, so that such a box works its hours out of the weather they had
-- (Energy.weatherSteps).
local SUN_TEN, SUN_TENS = 10, 72
Energy.WEATHER_HOURS = SUN_TEN * SUN_TENS / 60

-- The minutes since the last recorded (as many as the log keeps) count with the weather now.
local function recordSun(data, now)
    local log = data.sunLog or {}
    data.sunLog = log
    local from = math.max(data.sunAt or now - 1, now - SUN_TEN * SUN_TENS)
    if from >= now then return end
    local sun, air = Energy.sunlight(), getClimateManager():getTemperature()
    for minute = from + 1, now do
        local ten = math.floor(minute / SUN_TEN)
        local entry = log[ten]
        if not entry then
            entry = { 0, 0, 0 }
            log[ten] = entry
            local old = {}
            for key in pairs(log) do
                if key <= ten - SUN_TENS then old[#old + 1] = key end
            end
            for _, key in ipairs(old) do log[key] = nil end
        end
        entry[1], entry[2], entry[3] = entry[1] + sun, entry[2] + 1, entry[3] + air
    end
    data.sunAt = now
end

-- The weather over the whole log up to now as steps { hours, daylight, air outside }, the oldest first, by the ten
-- minutes of the log (now's where it has none: before it, or the minute now), those alike as one; kept while the
-- clock, the log and the weather now are the same (the far boxes of a minute ask for it each).
local kept, minuteStep = {}, { { 0, 0, 0 } }

local function allSteps(now)
    local sun, air = Energy.sunlight(), getClimateManager():getTemperature()
    local log = Store.data().sunLog or {}
    if kept.at == now and kept.log == log and kept.sun == sun and kept.air == air then return kept.steps end
    local at, steps, last = now - Energy.WEATHER_HOURS * 60, {}, nil
    while at < now - 1e-6 do
        local ten = math.floor(at / SUN_TEN)
        local ends = math.min(now, (ten + 1) * SUN_TEN)
        local entry = log[ten]
        local stepSun, stepAir = sun, air
        if entry and entry[2] > 0 then stepSun, stepAir = entry[1] / entry[2], entry[3] / entry[2] end
        if last and last[2] == stepSun and last[3] == stepAir then
            last[1] = last[1] + (ends - at) / 60
        else
            last = { (ends - at) / 60, stepSun, stepAir }
            steps[#steps + 1] = last
        end
        at = ends
    end
    kept = { at = now, log = log, sun = sun, air = air, steps = steps }
    return steps
end

-- The weather over the last so many hours (at most WEATHER_HOURS): steps as above, kept (not to be changed), the
-- index of the first of them and the hours of it that count. A minute or less is one step, now's. Read as
--   for i = first, #steps do local hours = i == first and firstHours or steps[i][1] ... end
function Energy.weatherSteps(hours)
    if hours <= 1 / 60 + 1e-6 then
        local step = minuteStep[1]
        step[1], step[2], step[3] = hours, Energy.sunlight(), getClimateManager():getTemperature()
        return minuteStep, 1, hours
    end
    local steps = allSteps(getGameTime():getWorldAgeHours() * 60)
    local left = math.min(hours, Energy.WEATHER_HOURS)
    for i = #steps, 1, -1 do
        if steps[i][1] >= left - 1e-9 or i == 1 then return steps, i, math.min(left, steps[i][1]) end
        left = left - steps[i][1]
    end
    return steps, 1, 0
end

-- The weather now: the minute's daylight and air (above), and as a spell for the snow: it settles while it snows
-- hard enough, melts while it is warm; none while snow on panels or the solar panels are off (those that are off
-- keep what lies on them). A spell begins as it changes.
function Energy.weather()
    local data = Store.data()
    recordSun(data, Energy.minute())
    local rate, settles = 0, false
    if Energy.snowEnabled() and BU.enabled("solar") then
        local climate = getClimateManager()
        settles = climate:isSnowing() and climate:getSnowIntensity() >= Energy.SNOW_FROM
        if settles then rate = Energy.SNOW_PER_HOUR
        elseif climate:getTemperature() > Energy.MELT_ABOVE then rate = -Energy.MELT_PER_HOUR end
    end
    local log = data.snowLog or {}
    data.snowLog = log
    local last = log[#log]
    if last and last.r == rate and (last.s == true) == settles then return end
    log[#log + 1] = { m = Energy.minute(), r = rate, s = settles or nil }
    while #log > SNOW_SPELLS do table.remove(log, 1) end
end

-- How fast snow settles on the panels now (an hour, below 0 as it melts), by the weather's spell.
function Energy.snowRate()
    local log = Store.data().snowLog
    local last = log and log[#log]
    return last and last.r or 0
end

-- The snow on a solar panel now (0 to 1), its weather since it was last asked worked in: each spell over the time it
-- overlaps, settling to 1 at most and melting to none (below a trace, none, but while it settles). now: the minute,
-- if the caller has it.
function Energy.snowOf(unit, now)
    now = now or Energy.minute()
    local from = unit.snowAt
    if from == now then return unit.snow or 0 end
    local log = Store.data().snowLog or {}
    local snow = unit.snow or 0
    if from and #log > 0 then
        -- The first spell still going at from.
        local first = #log
        while first > 1 and log[first].m > from do first = first - 1 end
        for i = first, #log do
            local spell = log[i]
            local starts = math.max(spell.m, from)
            local ends = i < #log and log[i + 1].m or now
            if ends > starts and spell.r ~= 0 then
                snow = math.max(0, math.min(1, snow + spell.r * (ends - starts) / 60))
                if snow < Energy.SNOW_TRACE and not spell.s then snow = 0 end
            end
        end
    end
    unit.snow, unit.snowAt = snow > 0 and snow or nil, now
    return snow
end

require "BuildingUtilities/EnergyBank"
require "BuildingUtilities/EnergyController"

return Energy
