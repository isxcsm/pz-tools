-- Outside devices: plan outlines and lines, hollow dots, several chosen and connected in one walk. "[bu10]" lines.
-- BU10_CLEANUP takes the box away and gives back what the test added.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU10TEST")
local player = getPlayer()
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu10] " .. table.concat(parts, " "))
end
local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local steps, current, waitTicks = {}, 1, 0
local function pause(ticks) waitTicks = ticks end
local function panel() return BU.Store.get(MD.panel) end
local w

local function freeSquareIn(building)
    for _, room in ipairs(BU.Panels.rooms(building)) do
        for _, rect in ipairs(room.rects) do
            for x = rect.x, rect.x + rect.w - 1 do for y = rect.y, rect.y + rect.h - 1 do
                local q = getCell():getGridSquare(x, y, room.level)
                if q and q:getObjects():size() == 1 and q:isFree(false) then return q end
            end end
        end
    end
end

local function count(set) local n = 0 for _ in pairs(set) do n = n + 1 end return n end
local function inv(t) return player:getInventory():getCountTypeRecurse(t) end

if BU10_CLEANUP then
    steps[#steps + 1] = function()
        if BU.PanelWindow.isOpen(MD.panel) then BU.PanelWindow.open(player, panel()):close() end
        if panel() then BU.Changes.remove(panel()) end
        local g = getCell():getGridSquare(GENERATOR[1], GENERATOR[2], 0):getGenerator()
        if MD.fuel then g:setFuel(MD.fuel) end
        g:setActivated(MD.wasOn == true)
        local inventory = player:getInventory()
        for _, t in ipairs({ "Base.ElectricWire", "Base.ElectronicsScrap" }) do
            local extra = inv(t) - (MD["had" .. t] or 0)
            for _ = 1, extra do inventory:RemoveOneOf(t) end
        end
        if MD.addedScrewdriver then inventory:RemoveOneOf("Base.Screwdriver") end
        ModData.remove("BU10TEST")
        say("cleaned", #BU.Store.list(), "wire", inv("Base.ElectricWire"), "scrap", inv("Base.ElectronicsScrap"))
    end
else
    steps[#steps + 1] = function()
        player:setGodMod(true)
        player:setInvisible(true)
        player:teleportTo(GAS_STATION[1] + 0.5, GAS_STATION[2] + 0.5, 0)
        pause(60)
    end
    steps[#steps + 1] = function()
        local own = BU.Panels.buildingAt(GAS_STATION[1], GAS_STATION[2], 0)
        local p = BU.Changes.install(freeSquareIn(own), BU.PANEL_SPRITES[1])
        MD.panel = p.id
        local g = getCell():getGridSquare(GENERATOR[1], GENERATOR[2], 0):getGenerator()
        MD.fuel, MD.wasOn = g:getFuel(), g:isActivated()
        g:setFuel(10)
        g:setActivated(true)
        BU.Changes.connectProducer(p, "power", GENERATOR[1], GENERATOR[2], 0, {})
        BU.Changes.upgrade(p)
        BU.Changes.upgrade(p)
        local inventory = player:getInventory()
        MD["hadBase.ElectricWire"], MD["hadBase.ElectronicsScrap"] = inv("Base.ElectricWire"), inv("Base.ElectronicsScrap")
        for _ = 1, 20 do inventory:AddItem("Base.ElectricWire"); inventory:AddItem("Base.ElectronicsScrap") end
        if inv("Base.Screwdriver") == 0 then inventory:AddItem("Base.Screwdriver"); MD.addedScrewdriver = true end
        BU.PanelWindow.planShown = true
        w = BU.PanelWindow.open(player, panel())
        pause(10)
    end
    steps[#steps + 1] = function()
        local plan = w.plan
        local hollow = 0
        for _, dot in ipairs(plan.dots) do if dot.hollow then hollow = hollow + 1 end end
        say("plan before range: edges", #plan.edges, "lines", #plan.lines, "dots", #plan.dots, "hollow", hollow, "scale", string.format("%.2f", plan.scale))
        w:onRange()
        say("plan with range: edges", #plan.edges, "lines", #plan.lines, "legend", #plan.legend, "scale", string.format("%.2f", plan.scale),
            "ranges", plan.data.ranges and plan.data.ranges.exterior, plan.data.ranges and plan.data.ranges.producer)
        local t0 = getTimestampMs()
        plan.rangeCache = {}
        plan:layout()
        say("layout with fresh range outlines ms", getTimestampMs() - t0)
        t0 = getTimestampMs()
        for _ = 1, 20 do plan:layout() end
        say("cached layout ms x20", getTimestampMs() - t0)
        -- Choosing: the outside group gets the button, the chosen row its total.
        w:setChoosing("power", true)
        w:chooseAll("power", true)
        local n, cost = w:chosenCost("power")
        say("chosen", n, "cost", w:costShort(cost), "affords", BU.Costs.affords(player, cost))
        local batch, choosable
        for _, item in ipairs(w.lists.power.items) do
            if item.item.kind == "batch" then batch = item.item.text end
            if item.item.choosable and item.item.kind == "device" then choosable = (choosable or 0) + 1 end
        end
        say("batch row", batch, "choosable rows", choosable)
        local ringed = 0
        for _, dot in ipairs(plan.dots) do if dot.chosen then ringed = ringed + 1 end end
        say("plan chosen dots", ringed, "choosing", plan.data.choosing)
        -- Keep three, the nearest ones, to keep the walk short.
        local keep = {}
        local outside = {}
        for _, device in ipairs(w.views.power.devices) do
            if not device.inside and device.state == "off" then outside[#outside + 1] = device end
        end
        table.sort(outside, function(a, b) return BU.Panels.steps(panel(), a.entry.x, a.entry.y) < BU.Panels.steps(panel(), b.entry.x, b.entry.y) end)
        w:chooseAll("power", false)
        for i = 1, math.min(3, #outside) do w:toggleChosen(outside[i].key); keep[#keep + 1] = outside[i].key end
        n, cost = w:chosenCost("power")
        say("three chosen", n, w:costShort(cost))
        MD.wireBefore, MD.included = inv("Base.ElectricWire"), count(panel().power.included)
        w:connectChosen("power")
        say("queued", #ISTimedActionQueue.getTimedActionQueue(player).queue, "choosing after", w.choosing.power)
        pause(60)
    end
    local waited = 0
    steps[#steps + 1] = function()
        local queue = ISTimedActionQueue.getTimedActionQueue(player).queue
        if #queue > 0 and waited < 150 then
            waited = waited + 1
            current = current - 1
            pause(60)
            return
        end
        say("queue left", #queue, "included", MD.included, "->", count(panel().power.included), "wire", MD.wireBefore, "->", inv("Base.ElectricWire"))
        w:refresh()
        say("lines now", #w.plan.lines)
        say("done")
    end
end

local function tick()
    if waitTicks > 0 then waitTicks = waitTicks - 1; return end
    local step = steps[current]
    if not step then Events.OnTick.Remove(tick); return end
    current = current + 1
    local ok, problem = pcall(step)
    if not ok then say("FAIL in step", current - 1, problem) end
end
Events.OnTick.Add(tick)
