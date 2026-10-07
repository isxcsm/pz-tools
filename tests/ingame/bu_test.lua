-- Building Utilities, stage 4: one combined check in a running game. Every result is a line starting with "[butest]"
-- in console.txt. Loaded from the debug console. BUTEST_PHASE 1 (default) sets up and checks; 2 runs after a save and
-- reload, checks what came back, and undoes everything. What phase 2 needs is kept in the save's global mod data.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BUTEST")

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[butest] " .. table.concat(parts, " "))
end

local GAS_STATION, SHACK, GENERATOR = { 3570, 10891, 0 }, { 3578, 10907, 0 }, { 3573, 10908, 0 }
local player = getPlayer()
local steps, current, waitTicks, waitUntil = {}, 1, 0, nil

local function square(at) return getCell():getGridSquare(at[1], at[2], at[3]) end

local function consumerKeys(panel, utility)
    local keys, list = {}, BU.Networks.consumers(panel, utility) or {}
    for i = 1, #list do keys[BU.thingKey(list[i].x, list[i].y, list[i].z, list[i].sprite)] = true end
    return keys, #list
end

-- A free floor square of a building, near a point in it, with nothing but its floor.
local function freeSquareIn(at)
    local building = BU.Panels.buildingAt(at[1], at[2], at[3])
    for r = 0, 6 do for dx = -r, r do for dy = -r, r do
        local q = getCell():getGridSquare(at[1] + dx, at[2] + dy, at[3])
        local b = q and BU.Panels.buildingAt(q:getX(), q:getY(), q:getZ())
        if b and building and b.key == building.key and q:getObjects():size() == 1 and q:isFree(false) then return q end
    end end end
    return nil
end

local function phase1()
    steps[#steps + 1] = function()
        local api, reason = BU and BU.api()
        say("load", "mod", BU ~= nil, "api", api ~= nil, reason or "", "window", BU and BU.PanelWindow ~= nil)
        say("item", getScriptManager():getItem(BU.PANEL_ITEM) ~= nil, "name", getItemNameFromFullType(BU.PANEL_ITEM))
        local ok, recipe = pcall(function() return getScriptManager():getCraftRecipe("MakeBreakerBox") end)
        say("recipe", ok and recipe ~= nil, "text", getText("IGUI_BU_WindowTitle"), getText("ContextMenu_BU_Install"))
        say("sandbox", BU.producerRange(), BU.exteriorRange(), BU.subPanelRange(), "vars", SandboxVars.BuildingUtilities ~= nil)
        say("panels before", #BU.Store.list())
        local g = square(GENERATOR):getGenerator()
        MD.fuel, MD.wasOn = g:getFuel(), g:isActivated()
        if g:getFuel() < 5 then g:setFuel(10) end
        if not g:isActivated() then g:setActivated(true) end
        say("generator fuel", g:getFuel(), "on", g:isActivated())
        local target = freeSquareIn(GAS_STATION)
        if not target then say("FAIL no free square in the gas station"); return end
        MD.box = { target:getX(), target:getY(), target:getZ() }
        local item = player:getInventory():AddItem(BU.PANEL_ITEM)
        say("install at", target:getX(), target:getY(), "can", BU.Panels.canInstall(target) ~= nil, "item", item ~= nil)
        if luautils.walkAdj(player, target) then ISTimedActionQueue.add(ISBUInstallPanel:new(player, target, item)) end
        waitUntil = function() return #BU.Store.list() > 0 end
    end

    steps[#steps + 1] = function()
        local panel = BU.Store.list()[1]
        if not panel then say("FAIL the action placed no box"); return end
        MD.main = panel.id
        local object = BU.Panels.object(panel)
        say("installed", panel.id, panel.x, panel.y, panel.sprite, "object", object ~= nil, "name", BU.Panels.name(panel))
        local _, reason = BU.Panels.canInstall(square(GAS_STATION))
        say("second box in the building refused", reason)
        say("item gone", player:getInventory():getFirstTypeRecurse(BU.PANEL_ITEM) == nil)
        local state = BU.Networks.state(panel, "power")
        say("power before producers", "supplied", state and state.supplied)
        -- The generator.
        local inRange = BU.Panels.inProducerRange(GENERATOR[1], GENERATOR[2], GENERATOR[3])
        say("generator in range of", #inRange, inRange[1] and inRange[1].panel.id, "steps", inRange[1] and inRange[1].steps)
        say("connect generator", BU.Panels.connectProducer(panel, "power", GENERATOR[1], GENERATOR[2], GENERATOR[3]))
        say("connect it again refused", select(2, BU.Panels.connectProducer(panel, "power", GENERATOR[1], GENERATOR[2], GENERATOR[3])))
        -- A rain barrel outside, as the game makes a map's.
        local p = square(GENERATOR)
        local found
        for r = 2, 8 do for dx = -r, r do for dy = -r, r do
            local q = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, 0)
            if not found and q and not q:getBuilding() and q:getObjects():size() == 1 and q:isFree(false)
                and q:getMovingObjects():size() == 0 then found = q end
        end end end
        if not found then say("FAIL no free square outside"); return end
        local sprite = "carpentry_02_54"
        local barrel = IsoThumpable.new(getCell(), found, sprite, false, {})
        local info = SpriteConfigManager.getObjectInfoFromSprite(sprite)
        GameEntityFactory.CreateIsoObjectEntity(barrel, info:getScript():getParent(), true)
        found:AddSpecialObject(barrel)
        local fc = barrel:getFluidContainer()
        fc:addFluid(FluidType.Water, fc:getCapacity() - fc:getAmount())
        MD.barrel = { found:getX(), found:getY(), 0 }
        local utility = BU.Panels.producerOn(found)
        say("barrel", found:getX(), found:getY(), "amount", fc:getAmount(), "producerOn", utility)
        say("connect barrel", BU.Panels.connectProducer(panel, "water", found:getX(), found:getY(), 0))
        waitTicks = 120
    end

    steps[#steps + 1] = function()
        local panel = BU.Store.get(MD.main)
        local power, water = BU.Networks.state(panel, "power"), BU.Networks.state(panel, "water")
        say("power", "supplied", power.supplied, "hoursLeft", power.hoursLeft, "load", power.load, "running",
            power.producers[1] and power.producers[1].running)
        say("water", "supplied", water.supplied, "amount", water.amount, "capacity", water.capacity)
        for _, utility in ipairs(BU.UTILITIES) do
            local devices, complete = BU.Panels.devices(panel, utility)
            local inside, outside = 0, 0
            for _, d in ipairs(devices) do if d.inside then inside = inside + 1 else outside = outside + 1 end end
            local _, consumers = consumerKeys(panel, utility)
            say(utility, "devices inside", inside, "outside", outside, "complete", complete, "consumers", consumers)
        end
        -- Exclude a device inside, then connect it again.
        local devices = BU.Panels.devices(panel, "power")
        local device
        for _, d in ipairs(devices) do if d.inside and not device then device = d end end
        BU.Panels.setDevice(panel, "power", device, false)
        local keys, count = consumerKeys(panel, "power")
        say("excluded", device.key, "gone from consumers", not keys[device.key], "consumers", count)
        MD.excluded = device.key
        -- An outside device, if there is one: connected on its own.
        local outsideDevice
        for _, d in ipairs(devices) do if not d.inside and not outsideDevice then outsideDevice = d end end
        if outsideDevice then
            BU.Panels.setDevice(panel, "power", outsideDevice, true)
            keys = consumerKeys(panel, "power")
            say("included outside", outsideDevice.key, "in consumers", keys[outsideDevice.key] == true)
            MD.included = outsideDevice.key
        else
            say("no outside device near the gas station")
        end
        -- The shack's box as a sub-panel.
        local shack = freeSquareIn(SHACK)
        local child = BU.Panels.install(shack, BU.PANEL_SPRITES[1])
        MD.child = child.id
        say("shack box", child.id, "name", BU.Panels.name(child), "candidates", #BU.Panels.linkCandidates(child))
        say("link", BU.Panels.link(child, panel))
        say("link back refused", select(2, BU.Panels.link(panel, child)))
        waitTicks = 120
    end

    steps[#steps + 1] = function()
        local panel, child = BU.Store.get(MD.main), BU.Store.get(MD.child)
        local cs, ps = BU.Networks.state(child, "power"), BU.Networks.state(panel, "power")
        say("child power", "supplied", cs.supplied, "parent", cs.parent, "load", cs.load)
        say("main power", "load", ps.load, "ownLoad", ps.ownLoad)
        local cw = BU.Networks.state(child, "water")
        say("child water", "supplied", cw.supplied, "parent", cw.parent, "amount", cw.amount)
        BU.PanelWindow.open(player, panel)
        say("window open; phase 1 done")
    end
end

local function phase2()
    steps[#steps + 1] = function()
        local panels = BU.Store.list()
        say("after reload", "panels", #panels)
        local panel, child = BU.Store.get(MD.main), BU.Store.get(MD.child)
        if not panel or not child then say("FAIL panels lost"); return end
        say("main", panel.id, "object", BU.Panels.object(panel) ~= nil, "producers", #panel.power.producers, #panel.water.producers,
            "excluded kept", panel.power.excluded[MD.excluded] == true)
        say("child", child.id, "object", BU.Panels.object(child) ~= nil, "parent", child.parent)
        waitTicks = 120
    end

    steps[#steps + 1] = function()
        local panel, child = BU.Store.get(MD.main), BU.Store.get(MD.child)
        local power, water = BU.Networks.state(panel, "power"), BU.Networks.state(panel, "water")
        say("power", "supplied", power and power.supplied, "hoursLeft", power and power.hoursLeft)
        say("water", "supplied", water and water.supplied, "amount", water and water.amount)
        local cs = BU.Networks.state(child, "power")
        say("child", "supplied", cs and cs.supplied, "parent", cs and cs.parent)
        local keys = consumerKeys(panel, "power")
        say("excluded still out", not keys[MD.excluded], "included still in", MD.included == nil or keys[MD.included] == true)
    end
end

local function cleanup()
    steps[#steps + 1] = function()
        for _, id in ipairs({ MD.child, MD.main }) do
            local panel = BU.Store.get(id)
            if panel then BU.Panels.remove(panel) end
        end
        say("panels left", #BU.Store.list(), "networks", BU.Networks.state({ id = MD.main }, "power") == nil)
        local b = MD.barrel and square(MD.barrel)
        if b then
            local objects = b:getObjects()
            for i = objects:size() - 1, 0, -1 do
                local o = objects:get(i)
                if instanceof(o, "IsoThumpable") and o:getFluidContainer() then b:transmitRemoveItemFromSquare(o) end
            end
        end
        local g = square(GENERATOR):getGenerator()
        g:setFuel(MD.fuel); g:setActivated(MD.wasOn)
        local inventory = player:getInventory()
        while inventory:getFirstTypeRecurse(BU.PANEL_ITEM) do inventory:Remove(inventory:getFirstTypeRecurse(BU.PANEL_ITEM)) end
        say("cleaned; generator fuel", g:getFuel(), "on", g:isActivated())
    end
end

if (BUTEST_PHASE or 1) == 1 then phase1() else phase2() end
if BUTEST_CLEANUP then steps = {}; cleanup() end

local function tick()
    if waitTicks > 0 then waitTicks = waitTicks - 1; return end
    if waitUntil then
        if not waitUntil() then return end
        waitUntil = nil
    end
    local step = steps[current]
    if not step then Events.OnTick.Remove(tick); return end
    current = current + 1
    local ok, problem = pcall(step)
    if not ok then say("FAIL in step", current - 1, problem) end
end
Events.OnTick.Add(tick)
