-- The combined check of the plan's batches 3 and 4 (DESIGN 12), set up for a player to go through by hand: noon, the
-- water units' items, the pipe and tools their lines take, filter media, a well beside where the pump goes, two
-- seeded crops beside where the sprinkler goes, and a fuelled generator wired to the test panel. Prints where the
-- squares are on the screen ("[bucombo]" lines). BUCOMBO_CLEAN() takes away what it put down (the crops, the well, the
-- generator's line); units installed by hand are taken down by hand.
local BU = BuildingUtilities
local Store, Changes = BU.Store, BU.Changes
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bucombo] " .. table.concat(parts, " "))
end
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
local function free(q) return q and q:isOutside() and q:getObjects():size() == 1 and q:isFree(false) and q:getMovingObjects():size() == 0 end
local function row(fromX, y, count)
    for i = 0, count - 1 do
        if not free(cell:getGridSquare(fromX + i, y, 0)) then return false end
    end
    return true
end
local p = player:getSquare()
local baseX, baseY
for r = 2, 10 do
    for dy = -r, r do
        for dx = -r, r do
            local x, y = p:getX() + dx, p:getY() + dy
            if not baseX and row(x, y, 6) and row(x + 2, y + 1, 2) then baseX, baseY = x, y end
        end
    end
end
if not baseX then say("no free squares"); return end
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
local generatorSquare
for r = 3, 12 do
    for dy = -r, r do
        for dx = -r, r do
            local q = cell:getGridSquare(p:getX() + dx, p:getY() + dy, 0)
            if not generatorSquare and q and q:getGenerator() then generatorSquare = q end
        end
    end
end
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
