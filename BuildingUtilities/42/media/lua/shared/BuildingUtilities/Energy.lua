-- A main panel's units as one power source of its network, named Energy.SOURCE (the API's setSource): this mod
-- works out what its solar panels make and says whether that carries the load. The API does the rest as for a
-- generator: the source switched on last carries the load, and when it cannot, the next producer takes over.
-- Snow lies on panels outside while it snows and melts when it is warm; a player can brush it off.
-- From tier 2 the panel's racks are its bank: what the panels make over the load charges it, and it carries the
-- load when they make too little. The batteries wear by how deep they are drawn, worn ones drain the bank, and cold
-- locks part of it.
require "BuildingUtilities/Units"
local BU = BuildingUtilities
local Store, Panels = BU.Store, BU.Panels
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

require "BuildingUtilities/EnergyBank"
require "BuildingUtilities/EnergyController"

return Energy
