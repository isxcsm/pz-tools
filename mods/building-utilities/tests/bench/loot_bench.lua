-- The first fill of each kind of vehicle container (Loot.generatorChance): the game's vehicle tables read for its
-- chance of a generator, every vehicle, container type and three skins, as a town's cars load. The game's own
-- VehicleDistributions.lua is read; its junk lists (ClutterTables) stand in as lists of 40 items. Run:
--   java -cp projectzomboid.jar tools/LuaTest.java loot bench
-- Prints a "[bench] loot ..." line.
local GAME = "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/lua/server/Vehicles/VehicleDistributions.lua"

test("the first fill of every vehicle container", function()
    local junk = { rolls = 1, items = {} }
    for i = 1, 40 do junk.items[#junk.items + 1] = "Base.Junk" .. i; junk.items[#junk.items + 1] = 2 end
    ClutterTables = setmetatable({}, { __index = function() return junk end })
    local text = readfile(GAME)
    if not text then print("[bench] loot: the game's VehicleDistributions.lua is not there"); return end
    VehicleDistributions = nil
    loadstring(text)()
    ItemPickerJava = { getLootModifier = function() return 0.6 end }
    require "BuildingUtilities/Loot"
    local Loot = BuildingUtilities.Loot
    local calls = 0
    local started = nanotime()
    for name, distribution in pairs(VehicleDistributions[1]) do
        if type(distribution) == "table" and type(distribution.Normal) == "table" then
            for containerType in pairs(distribution.Normal) do
                for skin = 0, 2 do
                    local vehicle = { getSkinIndex = function() return skin end, getScript = function() return nil end }
                    local part = { getVehicle = function() return vehicle end }
                    Loot.generatorChance(name, containerType, { getVehiclePart = function() return part end })
                    calls = calls + 1
                end
            end
        end
    end
    print(string.format("[bench] loot: %d first fills, %.1f ms in all, %.3f ms each", calls, nanotime() - started,
        (nanotime() - started) / calls))
end)
