-- Building Utilities, connection costs, overload and the command path: one combined check in a running game. Every
-- result is a line starting with "[bu2]" in console.txt. BU2_PHASE 1 (default) sets up and checks; 2 runs after a save
-- and reload; BU2_CLEANUP undoes everything. What later phases need is kept in the save's global mod data.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU2TEST")
local player = getPlayer()
local inventory = player:getInventory()

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu2] " .. table.concat(parts, " "))
end

local GAS_STATION, SHACK, GENERATOR = { 3570, 10891, 0 }, { 3578, 10907, 0 }, { 3573, 10908, 0 }
local GIVE = { { "Base.Screwdriver", 1 }, { "Base.PipeWrench", 1 }, { "Base.ElectricWire", 30 }, { "Base.Pipe", 30 },
    { "Base.ElectronicsScrap", 20 }, { "Base.SmallSheetMetal", 4 }, { BU.PANEL_ITEM, 2 } }
local steps, current, waitTicks, waitUntil, waitLimit = {}, 1, 0, nil, 0

local function square(at) return getCell():getGridSquare(at[1], at[2], at[3]) end
local function count(itemType) return inventory:getCountTypeRecurse(itemType) end
local function counts() return "wire " .. count("Base.ElectricWire") .. " pipe " .. count("Base.Pipe") .. " part " .. count("Base.ElectronicsScrap") end
local function panelOf(id) return BU.Store.get(id) end
local function power(id) return BU.Networks.state(panelOf(id), "power") end
local function wait(condition, ticks) waitUntil, waitLimit = condition, ticks or 3000 end

-- Notices the client would show, also printed.
local shown = BU.onNotice
function BU.onNotice(panelId, key, args)
    say("notice", panelId, key, args and args[1], args and args[2])
    MD.notices = MD.notices or {}
    MD.notices[key] = true
    if shown then shown(panelId, key, args) end
end

local function freeSquareIn(at)
    local building = BU.Panels.buildingAt(at[1], at[2], at[3])
    for r = 0, 6 do for dx = -r, r do for dy = -r, r do
        local q = getCell():getGridSquare(at[1] + dx, at[2] + dy, at[3])
        local b = q and BU.Panels.buildingAt(q:getX(), q:getY(), q:getZ())
        if b and building and b.key == building.key and q:getObjects():size() == 1 and q:isFree(false) then return q end
    end end end
    return nil
end

-- The player is put beside the place first: the game's own path finding is not what this checks.
local function queueAt(x, y, z, action)
    for dx = -1, 1 do for dy = -1, 1 do
        local q = getCell():getGridSquare(x + dx, y + dy, z)
        if (dx ~= 0 or dy ~= 0) and q and q:isFree(false) and not q:isBlockedTo(getCell():getGridSquare(x, y, z)) then
            player:teleportTo(x + dx + 0.5, y + dy + 0.5, z)
            BU.ContextMenu.queueAt(player, x, y, z, action)
            return
        end
    end end
    BU.ContextMenu.queueAt(player, x, y, z, action)
end

local function phase1()
    steps[#steps + 1] = function()
        say("load", "Changes", BU.Changes ~= nil, "Costs", BU.Costs ~= nil, "Sync", BU.Sync ~= nil, "api", BU.api() ~= nil,
            "setEnabled", PZToolsAPI.networks.setEnabled ~= nil)
        say("sandbox", "costs", BU.costsEnabled(), "tiles", BU.tilesPerPiece(), "refund", BU.refundPercent(), "overload",
            BU.overloadEnabled(), "capacity", BU.capacity(1), BU.capacity(2), BU.capacity(3), "lowFuel", BU.lowFuelHours())
        say("text", getText("ContextMenu_BU_Upgrade", 2), getText("IGUI_BU_Notice_Tripped", "X"))
        MD.level = player:getPerkLevel(Perks.Electricity)
        player:setPerkLevelDebug(Perks.Electricity, 6)
        MD.given = {}
        for _, give in ipairs(GIVE) do
            MD.given[give[1]] = count(give[1])
            for _ = 1, give[2] do inventory:AddItem(give[1]) end
        end
        local g = square(GENERATOR):getGenerator()
        MD.fuel, MD.wasOn = g:getFuel(), g:isActivated()
        g:setFuel(10)
        g:setActivated(true)
        say("given", counts(), "electricity", player:getPerkLevel(Perks.Electricity))
        local target = freeSquareIn(GAS_STATION)
        MD.box = { target:getX(), target:getY(), 0 }
        queueAt(target:getX(), target:getY(), 0, ISBUInstallPanel:new(player, target, inventory:getFirstTypeRecurse(BU.PANEL_ITEM)))
        wait(function() return #BU.Store.list() > 0 end)
    end

    -- The generator's line: a wire a piece of five tiles, laid at the generator.
    steps[#steps + 1] = function()
        local panel = BU.Store.list()[1]
        MD.main = panel.id
        say("installed", panel.id, "tier", panel.tier, "tripped", panel.tripped)
        local cost = BU.Actions.lineCost("producer", panel, "power", GENERATOR[1], GENERATOR[2], GENERATOR[3])
        say("generator cost", cost and cost.items[1][1], cost and cost.items[1][2], "affords", BU.Costs.affords(player, cost))
        MD.before = count("Base.ElectricWire")
        queueAt(GENERATOR[1], GENERATOR[2], GENERATOR[3], ISBUConnect:new(player, "producer", panel, "power", GENERATOR[1], GENERATOR[2], GENERATOR[3]))
        wait(function() return #panelOf(MD.main).power.producers > 0 end)
    end

    -- Overload: the gas station draws about 0.65, past tier 1's 0.3.
    steps[#steps + 1] = function()
        local panel = panelOf(MD.main)
        local paid = panel.power.producers[1].paid
        say("generator connected", "wire used", MD.before - count("Base.ElectricWire"), "paid", paid and paid["Base.ElectricWire"])
        wait(function() return panelOf(MD.main).tripped end, 600)
    end

    steps[#steps + 1] = function()
        local panel, state = panelOf(MD.main), power(MD.main)
        say("overload", "tripped", panel.tripped, "enabled", state.enabled, "supplied", state.supplied, "load", state.load,
            "capacity", BU.Panels.capacity(panel), "notice", MD.notices and MD.notices.IGUI_BU_Notice_Tripped)
        -- Reset while still over: trips again.
        BU.Sync.send(player, "resetBreaker", { panel = panel.id })
        MD.resetAt = getTimestampMs()
        waitTicks = 120
    end

    steps[#steps + 1] = function()
        say("reset while over", "tripped again", panelOf(MD.main).tripped)
        -- Two upgrades at the box.
        local panel = panelOf(MD.main)
        MD.before = counts()
        queueAt(panel.x, panel.y, panel.z, ISBUUpgradePanel:new(player, panel))
        queueAt(panel.x, panel.y, panel.z, ISBUUpgradePanel:new(player, panel))
        wait(function() return panelOf(MD.main).tier == 3 end)
    end

    steps[#steps + 1] = function()
        local panel = panelOf(MD.main)
        say("upgraded", "tier", panel.tier, "capacity", BU.Panels.capacity(panel), "before", MD.before, "after", counts(),
            "sheet", count("Base.SmallSheetMetal"))
        BU.Sync.send(player, "resetBreaker", { panel = panel.id })
        waitTicks = 120
    end

    steps[#steps + 1] = function()
        local panel, state = panelOf(MD.main), power(MD.main)
        say("reset", "tripped", panel.tripped, "enabled", state.enabled, "supplied", state.supplied, "load", state.load)
        -- A command: a device inside switched off and on.
        local device
        for _, d in ipairs(BU.Panels.devices(panel, "power")) do if d.inside and not device then device = d end end
        MD.device = device.key
        BU.Sync.send(player, "setInside", { panel = panel.id, utility = "power", key = device.key, on = false })
        waitTicks = 30
    end

    steps[#steps + 1] = function()
        local panel = panelOf(MD.main)
        say("command setInside off", "excluded", panel.power.excluded[MD.device] == true)
        BU.Sync.send(player, "setInside", { panel = panel.id, utility = "power", key = MD.device, on = true })
        BU.Sync.send(player, "rename", { panel = panel.id, name = "Shop" })
        -- A rain barrel outside, as the game makes a map's, piped in.
        local p = square(GENERATOR)
        local found
        for r = 2, 8 do for dx = -r, r do for dy = -r, r do
            local q = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, 0)
            if not found and q and not q:getBuilding() and q:getObjects():size() == 1 and q:isFree(false)
                and q:getMovingObjects():size() == 0 then found = q end
        end end end
        local barrel = IsoThumpable.new(getCell(), found, "carpentry_02_54", false, {})
        local info = SpriteConfigManager.getObjectInfoFromSprite("carpentry_02_54")
        GameEntityFactory.CreateIsoObjectEntity(barrel, info:getScript():getParent(), true)
        found:AddSpecialObject(barrel)
        local fc = barrel:getFluidContainer()
        fc:addFluid(FluidType.Water, fc:getCapacity() - fc:getAmount())
        MD.barrel = { found:getX(), found:getY(), 0 }
        MD.before = count("Base.Pipe")
        queueAt(found:getX(), found:getY(), 0, ISBUConnect:new(player, "producer", panel, "water", found:getX(), found:getY(), 0))
        wait(function() return #panelOf(MD.main).water.producers > 0 end)
    end

    steps[#steps + 1] = function()
        local panel = panelOf(MD.main)
        say("command after", "excluded", panel.power.excluded[MD.device] == true, "name", panel.name)
        say("barrel connected", "pipe used", MD.before - count("Base.Pipe"), "producers", #panel.water.producers)
        -- An outside lamp: wire and a part.
        local device
        for _, d in ipairs(BU.Panels.devices(panel, "power")) do if not d.inside and d.state == "off" and not device then device = d end end
        local e = device.entry
        MD.outside = { e.x, e.y, e.z, e.sprite }
        MD.before = counts()
        queueAt(e.x, e.y, e.z, ISBUConnect:new(player, "outside", panel, "power", e.x, e.y, e.z, e.sprite))
        wait(function() return panelOf(MD.main).power.included[BU.thingKey(e.x, e.y, e.z, e.sprite)] ~= nil end)
    end

    steps[#steps + 1] = function()
        local panel, o = panelOf(MD.main), MD.outside
        local keys = {}
        for _, c in ipairs(BU.Networks.consumers(panel, "power") or {}) do keys[BU.thingKey(c.x, c.y, c.z, c.sprite)] = true end
        say("outside connected", "before", MD.before, "after", counts(), "consumer", keys[BU.thingKey(o[1], o[2], o[3], o[4])] == true)
        -- Taken away with everything given back, to see the refund.
        SandboxVars.BuildingUtilities.RefundPercent = 100
        MD.before = counts()
        queueAt(o[1], o[2], o[3], ISBUDisconnect:new(player, "outside", panel, "power", o[1], o[2], o[3], o[4]))
        wait(function() return panelOf(MD.main).power.included[BU.thingKey(o[1], o[2], o[3], o[4])] == nil end)
    end

    steps[#steps + 1] = function()
        SandboxVars.BuildingUtilities.RefundPercent = 50
        say("outside taken away", "before", MD.before, "after", counts())
        -- The shack's box, linked as a sub-panel at its box.
        local target = freeSquareIn(SHACK)
        queueAt(target:getX(), target:getY(), 0, ISBUInstallPanel:new(player, target, inventory:getFirstTypeRecurse(BU.PANEL_ITEM)))
        wait(function() return #BU.Store.list() > 1 end)
    end

    steps[#steps + 1] = function()
        local child = BU.Store.list()[2]
        MD.child = child.id
        local cost = BU.Costs.link(BU.Panels.linkSteps(child, panelOf(MD.main)))
        say("shack box", child.id, "link steps", BU.Panels.linkSteps(child, panelOf(MD.main)), "cost", cost.items[1][2], cost.items[2][2])
        MD.before = counts()
        queueAt(child.x, child.y, child.z, ISBUConnect:new(player, "link", child, nil, child.x, child.y, child.z, MD.main))
        wait(function() return panelOf(MD.child).parent ~= nil end)
    end

    steps[#steps + 1] = function()
        local child = panelOf(MD.child)
        local state = power(MD.child)
        say("linked", "parent", child.parent, "before", MD.before, "after", counts(), "supplied", state and state.supplied)
        -- Low fuel: a little left makes it a few hours.
        square(GENERATOR):getGenerator():setFuel(0.3)
        local main = panelOf(MD.main)
        BU.PanelWindow.open(player, main)
        wait(function() return MD.notices and MD.notices.IGUI_BU_Notice_LowFuel end, 1800)
    end

    steps[#steps + 1] = function()
        say("low fuel notice", MD.notices and MD.notices.IGUI_BU_Notice_LowFuel, "hoursLeft", power(MD.main).hoursLeft)
        square(GENERATOR):getGenerator():setFuel(10)
        say("phase 1 done")
    end
end

local function phase2()
    steps[#steps + 1] = function()
        local main, child = panelOf(MD.main), panelOf(MD.child)
        if not main or not child then say("FAIL panels lost"); return end
        say("after reload", "tier", main.tier, "tripped", main.tripped, "name", main.name, "paid", main.power.producers[1].paid
            and main.power.producers[1].paid["Base.ElectricWire"], "child parent", child.parent, "child paid", child.parentPaid
            and child.parentPaid["Base.ElectricWire"])
        waitTicks = 120
    end

    steps[#steps + 1] = function()
        local state = power(MD.main)
        say("networks", "enabled", state.enabled, "supplied", state.supplied, "load", state.load,
            "child supplied", power(MD.child).supplied, "water", BU.Networks.state(panelOf(MD.main), "water").supplied)
    end
end

local function cleanup()
    steps[#steps + 1] = function()
        SandboxVars.BuildingUtilities.RefundPercent = 50
        MD.before = counts()
        local child = panelOf(MD.child)
        if child then queueAt(child.x, child.y, child.z, ISBURemovePanel:new(player, child)) end
        local main = panelOf(MD.main)
        if main then queueAt(main.x, main.y, main.z, ISBURemovePanel:new(player, main)) end
        wait(function() return #BU.Store.list() == 0 end)
    end

    steps[#steps + 1] = function()
        say("taken down", "before", MD.before, "after", counts(), "boxes", count(BU.PANEL_ITEM))
        local b = MD.barrel and square(MD.barrel)
        if b then
            local objects = b:getObjects()
            for i = objects:size() - 1, 0, -1 do
                local o = objects:get(i)
                if instanceof(o, "IsoThumpable") and o:getFluidContainer() then b:transmitRemoveItemFromSquare(o) end
            end
        end
        local g = square(GENERATOR):getGenerator()
        g:setFuel(MD.fuel or g:getFuel())
        g:setActivated(MD.wasOn == true)
        for itemType, had in pairs(MD.given or {}) do
            while count(itemType) > had do
                local item = inventory:getFirstTypeRecurse(itemType)
                item:getContainer():DoRemoveItem(item)
            end
        end
        if MD.level then player:setPerkLevelDebug(Perks.Electricity, MD.level) end
        say("cleaned", counts(), "electricity", player:getPerkLevel(Perks.Electricity), "panels", #BU.Store.list())
        ModData.remove("BU2TEST")
    end
end

if BU2_CLEANUP then cleanup() elseif (BU2_PHASE or 1) == 1 then phase1() else phase2() end

local function tick()
    if waitTicks > 0 then waitTicks = waitTicks - 1; return end
    if waitUntil then
        waitLimit = waitLimit - 1
        if not waitUntil() and waitLimit > 0 then return end
        if waitLimit <= 0 then say("TIMEOUT in step", current - 1) end
        waitUntil = nil
    end
    local step = steps[current]
    if not step then Events.OnTick.Remove(tick); return end
    current = current + 1
    local ok, problem = pcall(step)
    if not ok then say("FAIL in step", current - 1, problem) end
end
Events.OnTick.Add(tick)
