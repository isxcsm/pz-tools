-- The scale the mod is to bear (tier rework spec, 2e): 1000 boxes and 10,000 units over the map, each box a one-room
-- building with a generator, four solar panels, two racks of four batteries, a pump, two sprinklers and a filter.
-- Times the server's minute (EveryOneMinute) and ten minutes (EveryTenMinutes) on the game's Kahlua VM, the API's
-- answers stubbed (their own cost is the API's bench). The goal: the minute under 1 ms. Run:
--   java -cp projectzomboid.jar tools/LuaTest.java "" bench
-- Prints "[bench] ..." lines; fails only if the minute throws.
ISMoveableSpriteProps = {
    new = function() return {} end,
    canPickUpMoveable = function() end, pickUpMoveable = function() end, canPlaceMoveable = function() end,
    placeMoveable = function() end, canRotateMoveable = function() end, getInfoPanelDescription = function() end,
}
TEST.gameFile("Moveables/ISMoveableSpriteProps")
MapObjects = { OnLoadWithSprite = function() end }
require "BuildingUtilities/Server"
local BU = BuildingUtilities
local Store = BU.Store

local MINUTES = 30

getClimateManager = function()
    return { getTemperature = function() return 5 end, getDayLightStrength = function() return 0.6 end,
        getAirTemperatureForSquare = function() return 5 end, getSnowStrength = function() return 0 end,
        getPrecipitationIntensity = function() return 0 end, isSnowing = function() return false end }
end

local function sprite(kind) return BU.Units.definition(kind).sprites[1] end

-- A box at a place of a 40-wide grid, 30 squares apart, with its building, generator and units.
local function scene(boxes)
    local api = TEST.api
    for i = 0, boxes - 1 do
        local x, y = 1000 + math.floor(BU.remainder(i, 40)) * 30, 1000 + math.floor(i / 40) * 30
        local key = x .. "," .. y .. ",0"
        api.buildingsByKey[key] = {
            building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = x, minY = y, maxX = x + 9,
                maxY = y + 9, room = "kitchen", roomId = "r" .. i },
            rooms = { { id = "r" .. i, name = "kitchen", level = 0, rects = { { x = x, y = y, w = 10, h = 10 } } } },
            attached = {},
            attachedObjects = { power = {}, water = {} },
        }
        api.squares[(x + 1) .. "," .. (y + 1) .. ",0"] = key
        local panel = Store.newPanel(x + 1, y + 1, 0, BU.PANEL_SPRITES[1])
        panel.tier = 4
        panel.power.producers = { { x = x + 12, y = y, z = 0 } }
        local function unit(kind, dx, dy)
            local made = Store.newUnit(kind, x + dx, y + dy, 0, sprite(kind))
            made.panel = panel.id
            return made
        end
        for s = 0, 3 do unit("solar", 11, s) end
        for r = 0, 1 do
            local rack = unit("rack", 2 + r, 1)
            rack.batteries = {}
            for b = 1, 4 do
                rack.batteries[b] = { id = i * 10 + r * 4 + b, type = "Base.CarBattery1", charge = 0.6, condition = 90 }
            end
        end
        unit("pump", 12, 4)
        unit("sprinkler", 13, 5)
        unit("sprinkler", 13, 7)
        unit("filter", 3, 3)
    end
    -- Every network supplied by its generator, the load a house's.
    api.table.networks.state = function(id)
        return { load = 0.3, supplied = true, enabled = true, producers = {}, hoursLeft = 20, amount = 400,
            capacity = 800, fuelPerHour = 0.2 }
    end
end

local function timeEvent(name, times, step)
    local started = nanotime()
    for _ = 1, times do
        TEST.hours = TEST.hours + step
        TEST.fire(name)
    end
    return (nanotime() - started) / times
end

-- Where the minute goes: every function of the mod's modules wrapped to add up its time (with what it calls) and its
-- calls; the most costly printed.
local function profiled(run)
    local spent, calls, wrapped = {}, {}, {}
    for moduleName, module in pairs(BU) do
        if type(module) == "table" then
            for name, fn in pairs(module) do
                if type(fn) == "function" then
                    local label = moduleName .. "." .. name
                    wrapped[#wrapped + 1] = { module, name, fn }
                    module[name] = function(...)
                        local started = nanotime()
                        calls[label] = (calls[label] or 0) + 1
                        local a, b, c, d, e = fn(...)
                        spent[label] = (spent[label] or 0) + nanotime() - started
                        return a, b, c, d, e
                    end
                end
            end
        end
    end
    run()
    for _, entry in ipairs(wrapped) do entry[1][entry[2]] = entry[3] end
    local list = {}
    for label, ms in pairs(spent) do list[#list + 1] = { label, ms } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(25, #list) do
        print(string.format("[bench]   %-40s %9.1f ms %8d calls", list[i][1], list[i][2], calls[list[i][1]]))
    end
end

if TEST_SUITE == "profile" then
    test("where a minute of 100 boxes goes", function()
        scene(100)
        TEST.fire("OnGameStart")
        TEST.hours = 100
        timeEvent("EveryOneMinute", 2, 1 / 60)
        profiled(function() timeEvent("EveryOneMinute", 3, 1 / 60) end)
    end)
    return
end

-- Smaller first: how the time grows with the boxes shows. The goal's scale, 1000, joins once the minute no longer grows
-- with the square of the boxes (at 200 it took 2 s, 2026-10-13: 1000 would take half an hour to time).
for _, boxes in ipairs({ 50, 100, 200 }) do
    test("the minute and ten minutes of " .. boxes .. " boxes", function()
        local started = nanotime()
        scene(boxes)
        TEST.fire("OnGameStart")
        local start = nanotime() - started
        TEST.hours = 100
        -- The first minutes warm the caches and the VM up.
        timeEvent("EveryOneMinute", 3, 1 / 60)
        local minute = timeEvent("EveryOneMinute", MINUTES, 1 / 60)
        local ten = timeEvent("EveryTenMinutes", 3, 1 / 6)
        print(string.format("[bench] %d boxes, %d units: start %.0f ms, minute %.2f ms (goal 1 at 1000), ten minutes %.2f ms",
            #Store.list(), #Store.unitList(), start, minute, ten))
    end)
end
