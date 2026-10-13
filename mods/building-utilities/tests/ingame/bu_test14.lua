-- Batch 3: solar output, the source in the network, snow. "[bu14]" lines. Leaves nothing behind.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Units, Changes, Networks, Energy = BU.Store, BU.Panels, BU.Units, BU.Changes, BU.Networks, BU.Energy
local say = BUT.say("bu14")
local f = BUT.f
local player = getPlayer()
local climate = getClimateManager()
say("sun", f(Energy.sunlight()), "snowing", climate:isSnowing(), f(climate:getSnowIntensity()), "temp", f(climate:getTemperature()),
    "hour", f(getGameTime():getTimeOfDay()))
say("canCarry", Energy.canCarry(0.3, 0.28, false), Energy.canCarry(0.3, 0.28, true), Energy.canCarry(0.27, 0.28, true), Energy.canCarry(0, 0, false),
    Energy.canCarry(0.1, 0, false))

local panel = BUT.nearPanel()
say("panel", panel and panel.id or "none", "generators", panel and #panel.power.producers)
if not panel then return end
local squares = {}
local function untaken(sq)
    for _, other in ipairs(squares) do if other == sq then return false end end
    return Units.canInstall("solar", sq)
end
for _ = 1, 4 do squares[#squares + 1] = BUT.square(panel.x, panel.y, 0, 1, 12, untaken) end
local units = {}
for _, sq in ipairs(squares) do
    local unit = Changes.installUnit("solar", sq, Units.spriteFor("solar", sq, player))
    Changes.connectUnit(unit, panel, {})
    units[#units + 1] = unit
end
local state = Networks.state(panel, "power")
local source = Energy.sourceState(state)
say("units", #units, "hasSource", Energy.hasSource(panel), "first producer", state.producers[1] and state.producers[1].source,
    "available", source and source.available, "running", source and source.running, "supplied", state.supplied, "load", f(state.load))
local output, count, snow = Energy.output(panel)
say("output", f(output), count, "snow", f(snow), "per panel", f(Energy.panelOutput(units[1])))

-- The source switched on by hand: it carries the load, generators off; then not available: the next takes over.
Networks.setSource(panel, true, true)
state = Networks.state(panel, "power")
say("on: in use", Energy.inUse(state), "supplied", state.supplied, "hoursLeft", tostring(state.hoursLeft))
Networks.setSource(panel, false, nil)
state = Networks.state(panel, "power")
say("off: producer", state.producer and (state.producer.source or (state.producer.x .. "," .. state.producer.y)) or "none", "supplied", state.supplied)

-- Snow: half a panel's worth, worked out as the weather is now for an hour, brushed off.
units[1].snow = 0.5
units[2].snow = 1
output, count, snow = Energy.output(panel)
say("snowy output", f(output), "avg snow", f(snow), "panel 2", f(Energy.panelOutput(units[2])))
local before = units[1].snow
Energy.weather(1)
say("an hour of weather", f(before), "->", f(units[1].snow))
Changes.clearSnow(units[1])
say("brushed", tostring(units[1].snow))

for _, unit in ipairs(units) do Changes.removeUnit(unit) end
state = Networks.state(panel, "power")
say("removed: hasSource", Energy.hasSource(panel), "producers", #state.producers, "first", state.producers[1] and (state.producers[1].source or "square") or "none")
