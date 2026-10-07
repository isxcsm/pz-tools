-- Building Utilities, UI and gameplay improvements: one combined check in a running game. Results are "[bu3]" lines
-- in console.txt. BU3_PHASE 1 (default) sets up and checks; 2 runs after a save and reload; BU3_CLEANUP undoes it.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU3TEST")
local player = getPlayer()
local inventory = player:getInventory()

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu3] " .. table.concat(parts, " "))
end

local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local GIVE = { { "Base.Screwdriver", 1 }, { "Base.ElectricWire", 30 }, { "Base.ElectronicsScrap", 20 },
    { "Base.SmallSheetMetal", 4 }, { BU.PANEL_ITEM, 1 } }
local steps, current, waitTicks, waitUntil, waitLimit = {}, 1, 0, nil, 0

local function square(at) return getCell():getGridSquare(at[1], at[2], at[3]) end
local function count(itemType) return inventory:getCountTypeRecurse(itemType) end
local function panel() return BU.Store.get(MD.panel) end
local function power() return BU.Networks.state(panel(), "power") end
local function xp() return player:getXp():getXP(Perks.Electricity) end
local function wait(condition, ticks) waitUntil, waitLimit = condition, ticks or 3000 end
local function pause(ticks) waitTicks = ticks end
local function size(set) local n = 0; for _ in pairs(set or {}) do n = n + 1 end; return n end
local function lastLog() local log = panel().log; return log[#log] and log[#log].key end

local function freeSquareIn(at)
    local building = BU.Panels.buildingAt(at[1], at[2], at[3])
    for r = 0, 6 do for dx = -r, r do for dy = -r, r do
        local q = getCell():getGridSquare(at[1] + dx, at[2] + dy, at[3])
        local b = q and BU.Panels.buildingAt(q:getX(), q:getY(), q:getZ())
        if b and building and b.key == building.key and q:getObjects():size() == 1 and q:isFree(false) then return q end
    end end end
    return nil
end

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

local function send(command, args)
    args.panel = MD.panel
    BU.Sync.send(player, command, args)
end

-- The connected power devices of the box, largest first.
local function devices()
    local result = {}
    for _, device in ipairs(BU.Panels.devices(panel(), "power")) do
        if device.state == "on" then result[#result + 1] = device end
    end
    table.sort(result, function(a, b) return (a.power or 0) > (b.power or 0) end)
    return result
end

local function phase1()
    steps[#steps + 1] = function()
        player:setGodMod(true)
        player:setInvisible(true)
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
        say("text", getText("IGUI_BU_RefundNote", 50), "|", getText("IGUI_BU_BannerNear", 85), "|", getText("Sandbox_BuildingUtilities_RefundPercent_tooltip"))
        say("refund of 1 at 50", BU.Costs.refundCount(1), "of 3", BU.Costs.refundCount(3), "xpMultiplier", BU.xpMultiplier())
        MD.xp = xp()
        local target = freeSquareIn(GAS_STATION)
        queueAt(target:getX(), target:getY(), 0, ISBUInstallPanel:new(player, target, inventory:getFirstTypeRecurse(BU.PANEL_ITEM)))
        wait(function() return #BU.Store.list() > 0 end)
    end

    steps[#steps + 1] = function()
        local p = BU.Store.list()[#BU.Store.list()]
        MD.panel = p.id
        say("installed", p.id, "xp gained", xp() - MD.xp, "log", #p.log, "power keys", size(p.power.essential), size(p.power.schedule))
        MD.xp = xp()
        queueAt(GENERATOR[1], GENERATOR[2], 0, ISBUConnect:new(player, "producer", p, "power", GENERATOR[1], GENERATOR[2], 0))
        wait(function() return #panel().power.producers == 1 end)
    end

    steps[#steps + 1] = function()
        say("generator connected", "xp gained", xp() - MD.xp, "tripped", panel().tripped, "last log", lastLog())
        MD.xp = xp()
        local p = panel()
        queueAt(p.x, p.y, p.z, ISBUUpgradePanel:new(player, p))
        ISTimedActionQueue.add(ISBUUpgradePanel:new(player, p))
        wait(function() return panel().tier == 3 end)
    end

    steps[#steps + 1] = function()
        say("upgraded", "tier", panel().tier, "xp gained", xp() - MD.xp, "last log", lastLog(), "sheds", BU.Panels.sheds(panel()))
        send("resetBreaker", {})
        wait(function() local s = power(); return not panel().tripped and s and s.supplied end)
    end

    steps[#steps + 1] = function()
        local list = devices()
        local state = power()
        say("reset", "load", state.load, "capacity", BU.Panels.capacity(panel()), "devices on", #list, "last log", lastLog())
        MD.essential = list[1].key
        say("largest", list[1].key, list[1].power, "next", list[2] and list[2].key, list[2] and list[2].power)
        send("setEssential", { key = MD.essential, on = true })
        wait(function() return panel().power.essential[MD.essential] == true end)
    end

    steps[#steps + 1] = function()
        MD.capacity3 = SandboxVars.BuildingUtilities.Capacity3
        SandboxVars.BuildingUtilities.Capacity3 = 0.5
        wait(function() return size(panel().power.shed) > 0 or panel().tripped end)
    end

    steps[#steps + 1] = function()
        local p = panel()
        say("shed", "count", size(p.power.shed), "tripped", p.tripped, "essential kept", p.power.shed[MD.essential] == nil,
            "last log", lastLog())
        pause(120)
    end

    steps[#steps + 1] = function()
        local state = power()
        say("after shed", "load", state.load, "within", state.load <= 0.5 + 1e-6, "supplied", state.supplied)
        local window = BU.PanelWindow.open(player, panel())
        window:refresh()
        say("window", "banner", window.banner and window.banner.text, "log rows", #window.lists.log.items,
            "first log", window.lists.log.items[1] and window.lists.log.items[1].item.text)
        local shownHeld, preview = 0, nil
        for _, item in ipairs(window.lists.power.items) do
            local row = item.item
            if row.held == "shed" then shownHeld = shownHeld + 1 end
            if row.kind == "device" and row.device.key == MD.essential then preview = item.tooltip end
        end
        say("window rows", "held shown", shownHeld, "preview of essential", preview)
        window:onRange()
        say("range on", "objects", #window.rangeObjects, "button", window.rangeButton:getTitle())
        window:onRange()
        say("range off", "objects", #window.rangeObjects)
        SandboxVars.BuildingUtilities.Capacity3 = MD.capacity3
        wait(function() return size(panel().power.shed) == 0 end)
    end

    steps[#steps + 1] = function()
        say("restored", "shed", size(panel().power.shed), "last log", lastLog())
        SandboxVars.BuildingUtilities.Capacity3 = 0.01
        wait(function() return panel().tripped end)
    end

    steps[#steps + 1] = function()
        say("not enough to shed", "tripped", panel().tripped, "shed", size(panel().power.shed), "last log", lastLog())
        SandboxVars.BuildingUtilities.Capacity3 = MD.capacity3
        send("resetBreaker", {})
        wait(function() local s = power(); return not panel().tripped and s and s.supplied end)
    end

    steps[#steps + 1] = function()
        local list = devices()
        local night = not BU.scheduleOn("day")
        -- A timer that has the device off now.
        MD.schedule = night and "day" or "night"
        for _, device in ipairs(list) do
            if device.key ~= MD.essential and (device.power or 0) > 0 then MD.timed = device.key; MD.timedPower = device.power; break end
        end
        MD.loadBefore = power().load
        say("timer", "night now", night, "device", MD.timed, MD.timedPower, "schedule", MD.schedule)
        send("setSchedule", { key = MD.timed, schedule = MD.schedule })
        wait(function() return panel().power.timed[MD.timed] == true end)
    end

    steps[#steps + 1] = function()
        pause(120)
    end

    steps[#steps + 1] = function()
        local held
        for _, device in ipairs(BU.Panels.devices(panel(), "power")) do
            if device.key == MD.timed then held = device.held end
        end
        say("timer applied", "held", held, "load", MD.loadBefore, "->", power().load)
        say("phase 1 done")
    end
end

local function phase2()
    steps[#steps + 1] = function()
        local p = panel()
        if not p then say("FAIL panel lost"); return end
        say("after reload", "tier", p.tier, "essential", p.power.essential[MD.essential] == true, "schedule", p.power.schedule[MD.timed],
            "timed", p.power.timed[MD.timed] == true, "log", #p.log, "last log", lastLog())
        pause(120)
    end
    steps[#steps + 1] = function()
        local held
        for _, device in ipairs(BU.Panels.devices(panel(), "power")) do
            if device.key == MD.timed then held = device.held end
        end
        say("networks after reload", "supplied", power().supplied, "load", power().load, "timer held", held)
        -- An object on several squares is one device, drawing what its parts draw.
        local multi, rows = {}, 0
        for _, device in ipairs(BU.Panels.devices(panel(), "power")) do
            rows = rows + 1
            if #device.keys > 1 then multi[#multi + 1] = device.key .. "=" .. tostring(device.power) .. "x" .. #device.keys end
        end
        say("devices", rows, "multi", table.concat(multi, " "))
        MD.logBefore = #panel().log
        MD.capacity3 = SandboxVars.BuildingUtilities.Capacity3
        SandboxVars.BuildingUtilities.Capacity3 = 0.5
        wait(function() return size(panel().power.shed) > 0 or panel().tripped end)
    end
    steps[#steps + 1] = function()
        say("shed again", "count", size(panel().power.shed), "tripped", panel().tripped, "load", power().load)
        pause(600)
    end
    steps[#steps + 1] = function()
        local sheds, restores = 0, 0
        local log = panel().log
        for index = MD.logBefore + 1, #log do
            if log[index].key == "IGUI_BU_Notice_Shed" then sheds = sheds + 1 end
            if log[index].key == "IGUI_BU_Log_Restored" then restores = restores + 1 end
        end
        say("steady", "sheds", sheds, "restores", restores, "load", power().load, "shed now", size(panel().power.shed))
        SandboxVars.BuildingUtilities.Capacity3 = MD.capacity3
        wait(function() return size(panel().power.shed) == 0 end)
    end
    steps[#steps + 1] = function()
        say("restored again", "load", power().load, "last log", lastLog())
        say("phase 2 done")
    end
end

local function cleanup()
    steps[#steps + 1] = function()
        player:setGodMod(true)
        if MD.capacity3 then SandboxVars.BuildingUtilities.Capacity3 = MD.capacity3 end
        local p = panel()
        if p then queueAt(p.x, p.y, p.z, ISBURemovePanel:new(player, p)) end
        wait(function() return panel() == nil end)
    end
    steps[#steps + 1] = function()
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
        say("cleaned", "panels", #BU.Store.list(), "wire", count("Base.ElectricWire"), "boxes", count(BU.PANEL_ITEM))
        ModData.remove("BU3TEST")
    end
end

if BU3_CLEANUP then cleanup() elseif (BU3_PHASE or 1) == 1 then phase1() else phase2() end

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
