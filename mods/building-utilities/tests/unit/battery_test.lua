-- The bank's batteries (Energy.bank, Energy.run): heat at the racks wears them faster, the worst holds the bank back
-- by how far it is below the best, and a box of the bypass tier leaves worn ones out.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Rack"
require "BuildingUtilities/Solar"
local BU = BuildingUtilities
local Store, Changes, Energy = BU.Store, BU.Changes, BU.Energy

TEST.temperature = 20
getClimateManager = function()
    return { getTemperature = function() return TEST.temperature end, getDayLightStrength = function() return 0 end,
        getAirTemperatureForSquare = function() return TEST.temperature end }
end

local STANDARD = "Base.CarBattery1"

-- A box of a tier at x with a rack of batteries at conditions, all at a charge.
local function box(x, tier, conditions, charge)
    local panel = Store.newPanel(x, 10, 0, BU.panelSprite("S"))
    panel.tier = tier
    local rack = Store.newUnit("rack", x + 1, 10, 0, BU.Rack.SPRITE)
    rack.batteries = {}
    for i, condition in ipairs(conditions) do
        rack.batteries[i] = { type = STANDARD, charge = charge, condition = condition }
    end
    Changes.connectUnit(rack, panel, {})
    return panel, rack
end

local function near(actual, expected, what)
    if math.abs(actual - expected) > 1e-6 then
        error((what and what .. ": " or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

-- The state of a network the bank carries alone (no generator), at a load.
local function carried(load)
    return { load = load, supplied = true, enabled = true, producer = { source = Energy.SOURCE }, producers = {} }
end

test("above 30 degrees the batteries wear 10 percent faster a degree, at most three times", function()
    local cool = box(10, 4, { 100, 100 }, 0.8)
    TEST.temperature = 20
    Energy.run(cool, carried(0.5), 1, true)
    local lost = 100 - Energy.bank(cool).batteries[1].condition
    truthy(lost > 0, "drawn, they wear")
    local hot = box(30, 4, { 100, 100 }, 0.8)
    TEST.temperature = 40
    near(Energy.bank(hot).heat, 2, "ten degrees over")
    Energy.run(hot, carried(0.5), 1, true)
    near(100 - Energy.bank(hot).batteries[1].condition, lost * 2, "twice the wear")
    TEST.temperature = 80
    near(Energy.bank(hot).heat, 3, "at most three times")
    TEST.temperature = 20
end)

test("the worst battery holds the bank back by how far it is below the best", function()
    local even = box(10, 3, { 60, 60 }, 0.5)
    local bank = Energy.bank(even)
    eq(bank.drag, 0, "alike: nothing held back")
    eq(bank.worst, nil)
    local mixed, rack = box(30, 3, { 100, 20 }, 0.5)
    bank = Energy.bank(mixed)
    near(bank.drag, 0.4, "half of the 80 between them")
    eq(bank.worst, rack.batteries[2])
    near(bank.usable, bank.energy - bank.capacity * 0.4)
    -- Drawn, it stops where the worst battery holds it.
    Energy.run(mixed, carried(1), 24, true)
    near(Energy.bank(mixed).charge, 0.4, "drawn down to what is held back")
    SandboxVars.BuildingUtilities = { WeakBatteryDrag = false }
    eq(Energy.bank(mixed).drag, 0, "without the option")
end)

test("a box of the bypass tier leaves worn batteries out of its bank; they keep their charge", function()
    local panel, rack = box(10, 3, { 90, 20 }, 0.5)
    eq(#Energy.bank(panel).batteries, 2, "below the tier, all count")
    panel.tier = Energy.BYPASS_TIER
    local bank = Energy.bank(panel)
    eq(#bank.batteries, 1)
    eq(bank.bypassed[1], rack.batteries[2])
    eq(bank.drag, 0, "the one left out holds nothing back")
    truthy(Energy.bypassed(panel, rack.batteries[2]))
    Energy.run(panel, carried(0.2), 2, true)
    eq(rack.batteries[2].charge, 0.5, "left out: as it was")
    truthy(rack.batteries[1].charge < 0.5, "the other was drawn")
end)

test("a rack turned each way shows its own look and its batteries in its own block of the sheet", function()
    local Rack = BU.Rack
    local definition = BU.Units.definition("rack")
    eq(definition.sprite(nil, "E"), "bu_solar_01_0", "its front to the E: the first look")
    eq(definition.sprite(nil, "S"), "bu_solar_01_40")
    eq(definition.sprite(nil, "W"), "bu_solar_01_80")
    eq(definition.sprite(nil, "N"), "bu_solar_01_120")
    local rack = Store.newUnit("rack", 30, 10, 0, Rack.SPRITES.N)
    rack.batteries = {}
    for i = 1, 6 do rack.batteries[i] = { type = STANDARD, charge = 1, condition = 100 } end
    -- two shelves, full: 16 + 3 + 4 in the block from 120
    eq(Rack.overlay(rack), "bu_solar_01_" .. (120 + 16 + 3 + 4))
    rack.sprite = Rack.SPRITE
    eq(Rack.overlay(rack), "bu_solar_01_" .. (16 + 3 + 4), "the first look's overlays as before")
end)
