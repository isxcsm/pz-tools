-- What the player's side asks every half second, second and minute with many boxes (the scale bench's map, 1000 boxes
-- 100 apart, one player beside the first): a box's name for its tooltip and the windows' lists, the lights each game
-- minute, the tripped boxes' blink each tick, a right-click's devices. The API's answers stubbed. Run:
--   java -cp projectzomboid.jar ../tools/LuaTest.java "" bench
-- Prints "[bench] client ..." lines.
require "BuildingUtilities/Changes"
require "BuildingUtilities/PanelBlink"
require "BuildingUtilities/Lights"
local BU = BuildingUtilities
local Store, Panels = BU.Store, BU.Panels

local function timed(times, fn)
    local started = nanotime()
    for _ = 1, times do fn() end
    return (nanotime() - started) / times
end

test("the player's side with 1000 boxes", function()
    local api = TEST.api
    local boxes = 1000
    local lit = BU.PanelLook.SPRITES[1].on[1]
    local panels = {}
    for i = 0, boxes - 1 do
        local x, y = 1000 + BU.remainder(i, 40) * 100, 1000 + math.floor(i / 40) * 100
        local key = x .. "," .. y .. ",0"
        api.buildingsByKey[key] = {
            building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = 0, minX = x, minY = y, maxX = x + 9,
                maxY = y + 9, room = "kitchen", roomId = "r" .. i },
            rooms = { { id = "r" .. i, name = "kitchen", level = 0, rects = { { x = x, y = y, w = 10, h = 10 } } } },
            attached = {}, attachedObjects = { power = {}, water = {} },
            objects = { power = { { x = x + 3, y = y + 3, z = 0, sprite = "lamp", roomId = "r" .. i, power = 0.01 } },
                water = {} },
        }
        for dx = 0, 9 do
            for dy = 0, 9 do api.squares[(x + dx) .. "," .. (y + dy) .. ",0"] = key end
        end
        local panel = Store.newPanel(x + 1, y + 1, 0, lit)
        panel.tier = 4
        panel.tripped = BU.remainder(i, 10) == 0
        panels[#panels + 1] = panel
        local id = panel.id
        local square = { getX = function() return x + 1 end, getY = function() return y + 1 end, getZ = function() return 0 end }
        local object = { hasModData = function() return true end,
            getModData = function() return { [Panels.MODDATA] = id } end, getSquare = function() return square end,
            getSprite = function() return { getName = function() return lit end } end }
        TEST.squares[(x + 1) .. "," .. (y + 1) .. ",0"] = { objects = { object } }
    end
    local base = getCell
    getCell = function()
        local cell = base()
        cell.addLamppost = function() return {} end
        cell.removeLamppost = function() end
        cell.getLamppostPositions = function() return { contains = function() return true end } end
        return cell
    end
    local player = { getX = function() return 1005 end, getY = function() return 1005 end, getZ = function() return 0 end,
        isDead = function() return false end }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return player end
    getGameSpeed = function() return 1 end
    if BU.PanelBlink then BU.PanelBlink.changed(nil) end
    local first = panels[1]
    local function report(what, ms) print(string.format("[bench] client %-52s %8.3f ms", what, ms)) end
    Panels.name(first)
    report("a box's name (the tooltip, every 500 ms)", timed(200, function() Panels.name(first) end))
    report("every box's name (a window's lists)", timed(5, function() for _, p in ipairs(panels) do Panels.name(p) end end))
    report("a box's name after the buildings' version changed", timed(20, function()
        api.buildingsVersion = api.buildingsVersion + 1
        Panels.name(first)
    end))
    TEST.hours = 1
    report("the lights, each game minute", timed(20, function() TEST.fire("EveryOneMinute") end))
    report("the blink, each tick", timed(100, function() TEST.fire("OnTick") end))
    local lamp = { getSquare = function() return { getX = function() return 1004 end, getY = function() return 1004 end,
        getZ = function() return 0 end } end, getSpriteName = function() return "lamp" end }
    report("a right-click's panels and devices (one object)", timed(20, function() Panels.deviceOf(lamp, "power", {}) end))
end)
