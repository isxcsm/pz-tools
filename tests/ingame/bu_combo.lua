-- The combined check of the plan's batches 3 and 4 (DESIGN 12), set up for a player to go through by hand: noon, the
-- water units' items, the pipe and tools their lines take, filter media, a well beside where the pump goes, two
-- seeded crops beside where the sprinkler goes, and a fuelled generator wired to the test panel. Prints where the
-- squares are on the screen ("[bucombo]" lines). BUCOMBO_CLEAN() takes away what it put down (the crops, the well, the
-- generator's line); units installed by hand are taken down by hand.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Changes = BU.Store, BU.Changes
local say = BUT.say("bucombo")
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local player = getPlayer()
local cell = getCell()
getGameTime():setTimeOfDay(10)

-- What the hands need.
local inventory = player:getInventory()
local function give(fullType, count)
    local have = inventory:getCountTypeRecurse(fullType)
    for _ = have + 1, count do inventory:AddItem(fullType) end
end
for _, need in ipairs({ { "BuildingUtilities.WaterPump", 1 }, { "BuildingUtilities.Sprinkler", 1 },
        { "BuildingUtilities.WaterFilter", 1 }, { "Base.PipeWrench", 1 }, { "Base.Screwdriver", 1 }, { "Base.Pipe", 6 },
        { "Base.Charcoal", 2 }, { "Base.RippedSheets", 1 } }) do
    give(need[1], need[2])
end
for _, name in ipairs({ "MakeWaterPump", "MakeSprinkler", "MakeWaterFilter" }) do
    local recipe = getScriptManager():getCraftRecipe("BuildingUtilities." .. name)
    say("recipe", name, recipe ~= nil, recipe and getText(recipe:getTranslationName()) or "")
end
for _, item in ipairs({ "WaterPump", "Sprinkler", "WaterFilter" }) do
    local instance = instanceItem("BuildingUtilities." .. item)
    say("item", item, instance:getDisplayName(), instance:getTex() and instance:getTex():getName())
end

-- Squares outside near the player, free, in a row of four along x: the pump's (the well east of it), the
-- sprinkler's (the crops south of it), the filter's.
local function row(fromX, y, count)
    for i = 0, count - 1 do
        local q = cell:getGridSquare(fromX + i, y, 0)
        if not (q and BUT.freeOutside(q)) then return false end
    end
    return true
end
local base = BUT.squareNear(2, 10, function(q) return row(q:getX(), q:getY(), 6) and row(q:getX() + 2, q:getY() + 1, 2) end)
if not base then say("no free squares"); return end
local baseX, baseY = base:getX(), base:getY()
local pumpAt, wellAt = { baseX, baseY }, { baseX + 1, baseY }
local sprinklerAt, cropsAt = { baseX + 3, baseY }, { { baseX + 2, baseY + 1 }, { baseX + 3, baseY + 1 } }
local filterAt = { baseX + 5, baseY }

local well = IsoObject.new(cell:getGridSquare(wellAt[1], wellAt[2], 0), "camping_01_16", nil, false)
cell:getGridSquare(wellAt[1], wellAt[2], 0):AddTileObject(well)
local system = SFarmingSystem.instance
for _, at in ipairs(cropsAt) do
    local square = cell:getGridSquare(at[1], at[2], 0)
    system:plow(square)
    local plant = system:getLuaObjectOnSquare(square)
    plant:seed("Carrots")
    say("crop at", at[1], at[2], "state", plant.state, "water", plant.waterLvl, "needs", plant.waterNeeded)
end

-- A generator with fuel, wired to the box: the panel's power and the noise.
local generatorSquare = BUT.squareNear(3, 12, function(q) return q:getGenerator() ~= nil end)
local placed = false
if not generatorSquare then
    generatorSquare = cell:getGridSquare(baseX, baseY + 2, 0)
    IsoGenerator.new(instanceItem("Base.Generator"), cell, generatorSquare)
    placed = true
end
local generator = generatorSquare:getGenerator()
generator:setConnected(true)
generator:setFuel(generator:getMaxFuel())
generator:setCondition(100)
local gx, gy = generatorSquare:getX(), generatorSquare:getY()
if not Store.producerOwner(gx, gy, 0) then Changes.connectProducer(panel, "power", gx, gy, 0, true) end
say("generator at", gx, gy, "placed", placed, "fuel", generator:getFuel(), "owner", Store.producerOwner(gx, gy, 0))

-- Where the squares are on the game's screen (the window's client area).
local zoom = getCore():getZoom(0)
for _, at in ipairs({ { "pump", pumpAt }, { "sprinkler", sprinklerAt }, { "filter", filterAt }, { "generator", { gx, gy } },
        { "player", { player:getX() - 0.5, player:getY() - 0.5 } } }) do
    local x = (IsoUtils.XToScreen(at[2][1] + 0.5, at[2][2] + 0.5, 0, 0) - IsoCamera.getOffX()) / zoom
    local y = (IsoUtils.YToScreen(at[2][1] + 0.5, at[2][2] + 0.5, 0, 0) - IsoCamera.getOffY()) / zoom
    say("screen", at[1], at[2][1], at[2][2], math.floor(x), math.floor(y))
end

function BUCOMBO_CLEAN()
    for _, at in ipairs(cropsAt) do
        local plant = system:getLuaObjectOnSquare(cell:getGridSquare(at[1], at[2], 0))
        if plant then system:removePlant(plant) end
    end
    well:getSquare():transmitRemoveItemFromSquare(well)
    Changes.disconnectProducer(panel, "power", gx, gy, 0)
    if placed then generator:remove() end
    say("cleaned")
end
