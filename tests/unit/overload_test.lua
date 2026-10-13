-- Overload: a box's limit (its own share and what its bank's batteries add while they have charge), the breaker's
-- gauge draining over the limit and filling under it (BU.Overload), the lever, and the bank paying what goes over the
-- box's share while a generator carries the load (Energy.run), and the fixed rules by which the bank hands the load
-- to a generator and takes it back (Energy.rules, Energy.sourceOffer).
require "BuildingUtilities/Changes"
require "BuildingUtilities/Rack"
require "BuildingUtilities/Solar"
require "BuildingUtilities/Overload"
local BU = BuildingUtilities
local Store, Panels, Changes, Energy, Overload = BU.Store, BU.Panels, BU.Changes, BU.Energy, BU.Overload

TEST.temperature = 10
getClimateManager = function()
    return { getTemperature = function() return TEST.temperature end, getDayLightStrength = function() return 0 end,
        getAirTemperatureForSquare = function() return TEST.temperature end }
end

-- The power network's state as the API tells it, for every panel: { load, supplied, producers }.
local function network(state)
    PZExtAPI.networks.state = function() return state end
    return state
end

-- A panel of a tier with a rack of batteries (each { type, charge, condition }) wired to it.
local function box(tier, batteries)
    local panel = Store.newPanel(10, 10, 0, BU.PANEL_SPRITES[1])
    panel.tier = tier
    if batteries then
        local rack = Store.newUnit("rack", 11, 10, 0, BU.Rack.SPRITE)
        rack.batteries = batteries
        Changes.connectUnit(rack, panel, {})
    end
    return panel
end

local function near(actual, expected, what)
    if math.abs(actual - expected) > 1e-6 then
        error((what and what .. ": " or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local STANDARD, SPORTS = "Base.CarBattery1", "Base.CarBattery3"

test("the gauge drains by the square of what is over: two hours at 105%, half an hour at 110%, at once from 200%", function()
    eq(Panels.breakerDrain(1), 0)
    eq(Panels.breakerDrain(0.5), 0)
    near(Panels.breakerHoursLeft(1, 1.05), 2)
    near(Panels.breakerHoursLeft(1, 1.10), 0.5)
    near(Panels.breakerHoursLeft(0.5, 1.10), 0.25, "from half full")
    eq(Panels.breakerHoursLeft(1, 1), nil, "under the limit it does not drain")
    eq(Panels.breakerDrain(2), math.huge)
end)

test("the limit is the box's own share and what its batteries give while they have charge", function()
    local panel = box(2, { { type = STANDARD, charge = 0.5, condition = 100 }, { type = SPORTS, charge = 0.5, condition = 100 } })
    local capacity = Panels.capacity(panel)
    near(Panels.limit(panel), capacity + 0.15 + 0.225, "a standard battery 0.15, a sports one 1.5 times")
    -- worn: 0.3 of it at condition 0 (the worst holding the bank back is battery_test's)
    SandboxVars.BuildingUtilities = { WeakBatteryDrag = false }
    Store.unitList("rack", panel.id)[1].batteries[1].condition = 0
    near(Panels.limit(panel), capacity + 0.15 * 0.3 + 0.225)
    -- empty: nothing
    for _, battery in ipairs(Store.unitList("rack", panel.id)[1].batteries) do battery.charge = 0 end
    near(Panels.limit(panel), capacity, "an empty bank adds nothing")
end)

test("cold takes its share of the output, and the bank gives down to empty at any tier", function()
    local panel = box(1, { { type = STANDARD, charge = 0.5, condition = 100 } })
    TEST.temperature = -10
    near(Panels.limit(panel), Panels.capacity(panel) + 0.15 * (1 - 0.15), "15% locked at -10")
    TEST.temperature = 10
    Store.unitList("rack", panel.id)[1].batteries[1].charge = 0.01
    near(Panels.limit(panel), Panels.capacity(panel) + 0.15, "a little charge still gives")
    Store.unitList("rack", panel.id)[1].batteries[1].charge = 0
    near(Panels.limit(panel), Panels.capacity(panel), "empty: nothing")
end)

test("the tiers' limits are 0.5, 1, 2 and 4", function()
    for tier, limit in ipairs({ 0.5, 1, 2, 4 }) do near(BU.capacity(tier), limit, "tier " .. tier) end
end)

test("over the limit the gauge drains, trips at empty, and cools back while tripped", function()
    local panel = box(1)
    local limit = Panels.limit(panel)
    network({ load = limit * 1.1, supplied = true })
    Overload.check(panel, 0.25)
    near(Panels.breaker(panel), 0.5, "half an hour lasts, a quarter gone")
    eq(panel.tripped, false)
    Overload.check(panel, 0.25)
    eq(panel.tripped, true, "empty: tripped")
    eq(Panels.breaker(panel), 0)
    Overload.check(panel, 1)
    near(Panels.breaker(panel), 0.5, "fills in two hours while tripped")
    Overload.check(panel, 1)
    eq(panel.power.breaker, nil, "full: nothing kept")
end)

test("twice the limit trips at once", function()
    local panel = box(1)
    network({ load = Panels.limit(panel) * 2, supplied = true })
    Overload.check(panel, 0)
    eq(panel.tripped, true, "no time needed")
end)

test("without supply or with overload off nothing drains", function()
    local panel = box(1)
    network({ load = Panels.limit(panel) * 1.5, supplied = false })
    Overload.check(panel, 1)
    eq(Panels.breaker(panel), 1)
    panel.power.breaker = 0.4
    SandboxVars.BuildingUtilities = { OverloadEnabled = false }
    network({ load = Panels.limit(panel) * 1.5, supplied = true })
    Overload.check(panel, 1)
    eq(panel.power.breaker, nil, "off: the gauge is full")
    eq(panel.tripped, false)
end)

test("the lever: down switches the power off, up resets a tripped breaker and switches it on", function()
    local panel = box(1)
    eq(Panels.leverUp(panel), true)
    Changes.setLever(panel, false)
    eq(panel.switchedOff, true)
    eq(Panels.leverUp(panel), false)
    Changes.setLever(panel, true)
    eq(panel.switchedOff, nil)
    panel.power.breaker = 0.3
    Changes.trip(panel)
    eq(Panels.leverUp(panel), false, "tripped: the lever is down")
    Changes.setLever(panel, true)
    eq(panel.tripped, false)
    eq(Panels.breaker(panel), 0.3, "the gauge goes on from where it cooled to")
end)

test("the gauge is told to players by steps, not each minute", function()
    local panel = box(1)
    local told = 0
    BU.onChanged = function() told = told + 1 end
    Changes.setBreaker(panel, 0.995)
    Changes.setBreaker(panel, 0.99)
    eq(told, 0, "under a step")
    Changes.setBreaker(panel, 0.97)
    eq(told, 1)
    Changes.setBreaker(panel, 1)
    eq(told, 2, "full again")
end)

test("while a generator carries the load, the bank gives what goes over the box's share, down to empty", function()
    local panel = box(2, { { type = STANDARD, charge = 0.5, condition = 100 }, { type = STANDARD, charge = 0.5, condition = 100 } })
    local capacity = Panels.capacity(panel)
    local state = network({ load = capacity + 0.2, supplied = true, producers = {} })
    local before = Energy.bank(panel).energy
    Energy.run(panel, state, 1, false)
    near(panel.bankFlow, -0.2, "the part over the share")
    truthy(Energy.bank(panel).energy < before - 0.19, "drawn (and worn a little)")
    -- under the share it gives nothing
    state.load = capacity * 0.5
    Energy.run(panel, state, 1, false)
    eq(panel.bankFlow, 0)
end)

-- A generator of the panel on a loaded square, with fuel, as the network's state lists it.
local function generatorAt(panel)
    TEST.squares["30,30,0"] = { objects = {} }
    panel.power.producers[1] = { x = 30, y = 30, z = 0 }
    return { x = 30, y = 30, z = 0, fuel = 5, condition = 100 }
end

test("the bank hands the load to a generator at 20% and takes it back at 80%; without one it is drawn empty", function()
    local panel = box(1, { { type = STANDARD, charge = 0.5, condition = 100 } })
    local state = network({ load = 0.3, supplied = true, producers = { generatorAt(panel) } })
    local rules = Energy.rules(panel, state)
    near(rules.floor, 0.2, "a generator can take over: drawn to 20%")
    near(rules.restart, 0.8, "and the bank takes the load back at 80%")
    state.producers = {}
    rules = Energy.rules(panel, state)
    near(rules.floor, 0, "no generator: drawn empty")
    near(rules.restart, Energy.BANK_START, "and carries again from 10%")
end)

test("the bank takes the load back once it holds 80%, or the sun makes 110% of the load", function()
    local panel = box(1, { { type = STANDARD, charge = 0.7, condition = 100 } })
    local state = network({ load = 0.3, supplied = true, producers = { generatorAt(panel) } })
    local rules = Energy.rules(panel, state)
    eq(Energy.ready(rules, 0, Energy.bank(panel)), false, "70%: not yet")
    Store.unitList("rack", panel.id)[1].batteries[1].charge = 0.85
    eq(Energy.ready(rules, 0, Energy.bank(panel)), true, "85%")
    Store.unitList("rack", panel.id)[1].batteries[1].charge = 0.1
    eq(Energy.ready(rules, 0.3 * 1.1, Energy.bank(panel)), true, "the sun with the margin")
    eq(Energy.ready(rules, 0.3, Energy.bank(panel)), false, "the sun without it")
end)

test("a generator charges nothing: while it runs only the sun fills the bank", function()
    local panel = box(1, { { type = STANDARD, charge = 0.5, condition = 100 } })
    local state = network({ load = 0.2, supplied = true, producer = { x = 30, y = 30, z = 0 },
        producers = { generatorAt(panel) } })
    Energy.run(panel, state, 1, false)
    eq(panel.bankFlow, 0, "no sun: nothing goes in")
end)

test("switching to solar by hand needs the bank 10% over where it would hand back", function()
    local panel = box(1, { { type = STANDARD, charge = 0.25, condition = 100 } })
    TEST.squares["40,40,0"] = { objects = {} }
    local solar = Store.newUnit("solar", 40, 40, 0, "panel")
    Changes.connectUnit(solar, panel, {})
    local state = network({ load = 0.3, supplied = true, enabled = true, producer = { x = 30, y = 30, z = 0 },
        producers = { generatorAt(panel) } })
    local offered, ready = Energy.sourceOffer(panel, state)
    eq(offered, true)
    eq(ready, false, "25%: it would hand straight back at 20%")
    Store.unitList("rack", panel.id)[1].batteries[1].charge = 0.35
    offered, ready = Energy.sourceOffer(panel, state)
    eq(ready, true, "35%")
end)
