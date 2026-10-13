-- The scale the mod is to bear (tier rework spec, 2e): 1000 boxes and 10,000 units over the map, each box a one-room
-- building with a generator, four solar panels, two racks of four batteries, a pump, two sprinklers and a filter.
-- Times the server's minute (EveryOneMinute) and ten minutes (EveryTenMinutes) on the game's Kahlua VM, the API's
-- answers stubbed (their own cost is the API's bench), one player beside the first box (the rest are far: they run now
-- and then, Server.lua). The goal: the minute under 1 ms, on average over six hours (2026-10-13: 2.3 ms; the table is in
-- DESIGN.md, section 9). Run:
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

-- The steady minutes timed: as long as a far box waits at most (Server), so that each runs in them.
local MINUTES = 360

getClimateManager = function()
    return { getTemperature = function() return 5 end, getDayLightStrength = function() return 0.6 end,
        getAirTemperatureForSquare = function() return 5 end, getSnowStrength = function() return 0 end,
        getPrecipitationIntensity = function() return 0 end, isSnowing = function() return false end,
        getSeason = function() return { getDawn = function() return 6 end, getDusk = function() return 20 end } end }
end

local function sprite(kind) return BU.Units.definition(kind).sprites[1] end

-- A box at a place of a 40-wide grid, so many squares apart (100: over the map; 30: a city, where a player has some
-- 25 boxes about), with its building, generator and units.
local function scene(boxes, apart)
    local api = TEST.api
    for i = 0, boxes - 1 do
        local x, y = 1000 + math.floor(BU.remainder(i, 40)) * apart, 1000 + math.floor(i / 40) * apart
        local key = x .. "," .. y .. ",0"
        api.buildingsByKey[key] = {
            building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = x, minY = y, maxX = x + 9,
                maxY = y + 9, room = "kitchen", roomId = "r" .. i },
            rooms = { { id = "r" .. i, name = "kitchen", level = 0, rects = { { x = x, y = y, w = 10, h = 10 } } } },
            attached = {},
            attachedObjects = { power = {}, water = {} },
        }
        api.squares[(x + 1) .. "," .. (y + 1) .. ",0"] = key
        for dx = 0, 9 do
            for dy = 0, 9 do api.squares[(x + dx) .. "," .. (y + dy) .. ",0"] = key end
        end
        local panel = Store.newPanel(x + 1, y + 1, 0, BU.panelSprite("S"))
        panel.tier = 4
        -- Wired as a player wires them, each on its line (BU.Links) from the nearest wall square, so that it works; the
        -- lines written straight into the save (laying each through BU.Changes asks the whole map again each time).
        local data = Store.data()
        local function lay(ref, utility, lx, ly)
            local wx, wy = math.max(x, math.min(x + 9, lx)), math.max(y, math.min(y + 9, ly))
            data.lines[ref] = { ref = ref, panel = panel.id, utility = utility, wall = BU.placeKey(wx, wy, 0),
                length = math.max(math.abs(lx - wx), math.abs(ly - wy)), paid = {}, x = lx, y = ly, z = 0, seq = data.nextLine }
            data.nextLine = data.nextLine + 1
        end
        panel.power.producers = { { x = x + 12, y = y, z = 0 } }
        lay(BU.Links.producerRef(x + 12, y, 0), "power", x + 12, y)
        local function unit(kind, dx, dy, prepare)
            local made = Store.newUnit(kind, x + dx, y + dy, 0, sprite(kind))
            if prepare then prepare(made) end
            made.panel = panel.id
            lay(BU.Links.unitRef(made), BU.Units.utility(made), x + dx, y + dy)
            return made
        end
        for s = 0, 3 do unit("solar", 11, s) end
        for r = 0, 1 do
            unit("rack", 2 + r, 1, function(rack)
                rack.batteries = {}
                for b = 1, 4 do
                    rack.batteries[b] = { id = i * 10 + r * 4 + b, type = "Base.CarBattery1", charge = 0.6, condition = 90 }
                end
            end)
        end
        unit("pump", 12, 4, function(pump) pump.fluid = "TaintedWater" end)
        unit("sprinkler", 13, 5)
        unit("sprinkler", 13, 7)
        unit("filter", 3, 3)
    end
    Store.unitsChanged()
    -- One player, beside the first box.
    local player = { getX = function() return 1005 end, getY = function() return 1005 end, getZ = function() return 0 end }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function(i) return i == 0 and player or nil end
    -- Every network supplied by its generator, the load a house's.
    api.table.networks.state = function(id)
        return { load = 0.3, supplied = true, enabled = true, producers = {}, hoursLeft = 20, amount = 400,
            capacity = 800, fuelPerHour = 0.2 }
    end
end

-- An event fired so many times, the world's time going on by step hours before each: the average and the longest.
local function timeEvent(name, times, step)
    local total, longest = 0, 0
    for _ = 1, times do
        TEST.hours = TEST.hours + step
        local started = nanotime()
        TEST.fire(name)
        local spent = nanotime() - started
        total, longest = total + spent, math.max(longest, spent)
    end
    return total / times, longest
end

-- Where the minute goes: every function of the mod's modules wrapped to add up its time (with what it calls) and its
-- calls, and its own time without them; the most costly printed.
local function profiled(run)
    local spent, own, calls, wrapped = {}, {}, {}, {}
    -- The time of the calls under the one running now, to take from its own.
    local under = { 0 }
    for moduleName, module in pairs(BU) do
        if type(module) == "table" then
            for name, fn in pairs(module) do
                if type(fn) == "function" then
                    local label = moduleName .. "." .. name
                    wrapped[#wrapped + 1] = { module, name, fn }
                    module[name] = function(...)
                        calls[label] = (calls[label] or 0) + 1
                        under[#under + 1] = 0
                        local started = nanotime()
                        local a, b, c, d, e = fn(...)
                        local took = nanotime() - started
                        local inner = table.remove(under)
                        under[#under] = under[#under] + took
                        spent[label] = (spent[label] or 0) + took
                        own[label] = (own[label] or 0) + took - inner
                        return a, b, c, d, e
                    end
                end
            end
        end
    end
    local started = nanotime()
    run()
    local total = nanotime() - started
    for _, entry in ipairs(wrapped) do entry[1][entry[2]] = entry[3] end
    local function top(by, title)
        local list = {}
        for label, ms in pairs(by) do list[#list + 1] = { label, ms } end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        print("[bench]   " .. title)
        for i = 1, math.min(25, #list) do
            print(string.format("[bench]   %-40s %9.1f ms %8d calls", list[i][1], list[i][2], calls[list[i][1]]))
        end
    end
    print(string.format("[bench]   all %.1f ms, outside the mod's modules %.1f ms", total, total - under[1]))
    top(spent, "with what they call")
    top(own, "their own")
end

if TEST_SUITE == "profile" then
    test("where the steady minutes of 1000 boxes go", function()
        scene(1000, 100)
        profiled(function() TEST.fire("OnGameStart") end)
        print("[bench] ---- the minutes")
        TEST.hours = 100
        timeEvent("EveryOneMinute", 60, 1 / 60)
        profiled(function() timeEvent("EveryOneMinute", MINUTES, 1 / 60) end)
        -- A far box's run over six hours, by part, unwrapped: each part over the boxes but the first, its average.
        print("[bench] ---- a far box's run by part")
        local panels = {}
        for i, panel in ipairs(Store.list()) do
            if i > 1 then panels[#panels + 1] = panel end
        end
        local function timed(name, part)
            local started = nanotime()
            for _, panel in ipairs(panels) do part(panel) end
            print(string.format("[bench]   %-40s %7.3f ms", name, (nanotime() - started) / #panels))
        end
        local Energy, Networks = BU.Energy, BU.Networks
        timed("Networks.state power", function(panel) Networks.state(panel, "power") end)
        timed("Networks.state water", function(panel) Networks.state(panel, "water") end)
        timed("Energy.weatherSteps 6 h", function() Energy.weatherSteps(6) end)
        timed("Energy.bank", function(panel) Energy.bank(panel) end)
        timed("Energy.output", function(panel) Energy.output(panel) end)
        timed("Energy.run 6 h", function(panel)
            local state = Networks.state(panel, "power")
            Energy.run(panel, state, 6, true, Energy.rules(panel, state))
        end)
        timed("Energy.run a minute", function(panel)
            local state = Networks.state(panel, "power")
            Energy.run(panel, state, 1 / 60, true, Energy.rules(panel, state))
        end)
        timed("Overload.check, its bank given", function(panel) BU.Overload.check(panel, 6, false) end)
        timed("WaterRun.machines 6 h", function(panel) BU.WaterRun.machines(panel, 360) end)
        timed("WaterRun.sprinklers", function(panel) BU.WaterRun.sprinklers(panel) end)
        timed("Store.recordEnergy", function(panel) Store.recordEnergy(panel, 0.2, 0.3, 0.5) end)
    end)
    return
end

-- Smaller first: how the time grows with the boxes shows; the goal's scale over the map, then as a city.
for _, case in ipairs({ { 100, 100 }, { 300, 100 }, { 1000, 100 }, { 1000, 30 } }) do
    local boxes, apart = case[1], case[2]
    test("the minute and ten minutes of " .. boxes .. " boxes " .. apart .. " apart", function()
        local started = nanotime()
        scene(boxes, apart)
        TEST.fire("OnGameStart")
        local start = nanotime() - started
        TEST.hours = 100
        -- The first minute after the world loaded, then the rest of the hour: every far box runs once, its caches made.
        local once = timeEvent("EveryOneMinute", 1, 1 / 60)
        local first, firstLongest = timeEvent("EveryOneMinute", 59, 1 / 60)
        local minute, longest = timeEvent("EveryOneMinute", MINUTES, 1 / 60)
        local ten = timeEvent("EveryTenMinutes", 3, 1 / 6)
        local working = 0
        for _, panel in ipairs(Store.list()) do working = working + #BU.Units.working(panel) end
        print(string.format("[bench] %d boxes %d apart, %d units (%d working): start %.0f ms; first minute %.0f ms; the hour's rest %.2f ms (longest %.2f); then %.2f ms (longest %.2f; goal 1 at 1000); ten minutes %.2f ms",
            #Store.list(), apart, #Store.unitList(), working, start, once, first, firstLongest, minute, longest, ten))
    end)
end
