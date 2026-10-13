-- Far boxes (Server.lua): the weather kept by ten minutes (Energy.weather, Energy.weatherSteps), a box's run catching
-- up hours in the weather they had (Energy.run), and the schedule: a box far from the players runs only before its
-- bank could reach a share its rules turn at, or as the daylight passes the sun its solar panels carry the load in.
ISMoveableSpriteProps = {
    new = function() return {} end,
    canPickUpMoveable = function() end, pickUpMoveable = function() end, canPlaceMoveable = function() end,
    placeMoveable = function() end, canRotateMoveable = function() end, getInfoPanelDescription = function() end,
}
TEST.gameFile("Moveables/ISMoveableSpriteProps")
MapObjects = { OnLoadWithSprite = function() end }
require "BuildingUtilities/Server"
local BU = BuildingUtilities
local Store, Changes, Energy = BU.Store, BU.Changes, BU.Energy

TEST.sun, TEST.temperature = 0, 10
getClimateManager = function()
    return { getTemperature = function() return TEST.temperature end,
        getDayLightStrength = function() return TEST.sun end,
        getAirTemperatureForSquare = function() return TEST.temperature end, getSnowIntensity = function() return 0 end,
        getPrecipitationIntensity = function() return 0 end, isSnowing = function() return false end }
end

local function near(actual, expected, tolerance, what)
    if math.abs(actual - expected) > tolerance then
        error((what and what .. ": " or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

-- A box with four solar panels (0.32 in full sun) and, when charge is given, a rack of four standard batteries at it
-- (8 load-hours), its network carried by them at a load.
local function box(x, charge, load)
    local panel = Store.newPanel(x, 10, 0, BU.PANEL_SPRITES[1])
    panel.tier = 4
    for i = 1, 4 do
        Changes.connectUnit(Store.newUnit("solar", x + i, 12, 0, BU.Units.definition("solar").sprites[1]), panel, {})
    end
    if charge then
        local rack = Store.newUnit("rack", x, 11, 0, BU.Rack.SPRITE)
        rack.batteries = {}
        for b = 1, 4 do rack.batteries[b] = { type = "Base.CarBattery1", charge = charge, condition = 100 } end
        Changes.connectUnit(rack, panel, {})
    end
    PZExtAPI.networks.state = function()
        return { load = load, supplied = true, enabled = true, producer = { source = Energy.SOURCE },
            producers = { { source = Energy.SOURCE, available = true } } }
    end
    return panel
end

-- The minute goes on: the clock, then the weather recorded (as the server's minute does first).
local function minute()
    TEST.hours = TEST.hours + 1 / 60
    Energy.weather()
end

test("the weather is kept by ten minutes and read back as steps, those alike as one", function()
    TEST.hours = 100
    for m = 1, 120 do
        TEST.sun = m <= 60 and 1 or 0
        minute()
    end
    local steps, first, firstHours = Energy.weatherSteps(2)
    local hours, sunHours = 0, 0
    for i = first, #steps do
        local spell = i == first and firstHours or steps[i][1]
        hours, sunHours = hours + spell, sunHours + spell * steps[i][2]
    end
    near(hours, 2, 1e-6, "the steps make the hours asked")
    near(sunHours, 1, 2 / 60, "an hour of sun, to the ten minutes")
    truthy(#steps - first + 1 <= 4, "an hour of sun and one of night as few steps")
    local one, at, oneHours = Energy.weatherSteps(1 / 60)
    eq(#one, 1)
    eq(at, 1)
    eq(oneHours, 1 / 60)
    eq(one[1][2], 0, "a minute: the sun now")
end)

test("a far box catching up six hours ends where running every minute would, full by day and drawn by night", function()
    TEST.hours = 200
    local everyMinute, caughtUp = box(10, 0.98, 0.2), box(30, 0.98, 0.2)
    local state = BU.Networks.state(everyMinute, "power")
    for m = 1, 360 do
        TEST.sun = m <= 180 and 1 or 0
        minute()
        Energy.run(everyMinute, state, 1 / 60, true)
    end
    Energy.run(caughtUp, state, 6, true)
    local a, b = Energy.bank(everyMinute), Energy.bank(caughtUp)
    near(b.charge, a.charge, 0.002, "the charge")
    near(a.charge, (8 - 0.6) / 8, 0.005, "full by noon, then three hours of 0.2 drawn")
    near(b.batteries[1].condition, a.batteries[1].condition, 0.01, "the wear")
end)

-- The minutes at which a box ran (its ranAt changed) over so many of them, the sun given by minute.
local function runs(panel, minutes, sunAt)
    local ran, seen = {}, nil
    for m = 1, minutes do
        TEST.sun = sunAt and sunAt(m) or 0
        TEST.hours = TEST.hours + 1 / 60
        TEST.fire("EveryOneMinute")
        if panel.ranAt ~= seen then
            seen = panel.ranAt
            ran[#ran + 1] = m
        end
    end
    return ran
end

test("a far box runs only before its bank could reach a share its rules turn at", function()
    TEST.hours = 300
    TEST.fire("OnGameStart")
    -- At 75% and drawn at night, 80% (the share the bank takes the load back at) is the nearest turn: 0.4 load-hours
    -- away, which four panels in full sun (0.272 an hour after what charging loses) fill in 88 minutes at the most.
    local panel = box(10, 0.75, 0.2)
    local ran = runs(panel, 200)
    truthy(#ran >= 2, "it ran twice")
    eq(ran[2] - ran[1], 88, "the second run, minutes after the first")
    near(Energy.bank(panel).charge, 0.75 - 0.2 * (ran[#ran] - ran[1]) / 60 / 8, 1e-6, "drawn all the while, to its last run")
end)

test("a far box whose source the sun turns runs as the daylight passes the sun it carries the load in", function()
    TEST.hours = 400
    TEST.fire("OnGameStart")
    -- No bank: four panels (0.32) carry 0.2 from a daylight of 0.625, start to with the margin from 0.6875.
    local panel = box(10, nil, 0.2)
    local ran = runs(panel, 300, function(m) return m >= 150 and 0.7 or 0.3 end)
    truthy(#ran >= 2, "it ran twice")
    eq(ran[2], 150, "woken as the sun came up past it")
end)
