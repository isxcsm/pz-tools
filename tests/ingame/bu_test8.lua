-- The window's panes: the list and the plan share the window, the divider moves the share, a resize keeps it; the
-- plan's floor strip, legend and wheel; plan hover marks list rows. "[bu8]" lines. BU8_CLEANUP takes the box away.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU8TEST")
local player = getPlayer()
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu8] " .. table.concat(parts, " "))
end
local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local steps, current, waitTicks = {}, 1, 0
local function pause(ticks) waitTicks = ticks end
local function panel() return BU.Store.get(MD.panel) end

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

local w
local function panes(label)
    say(label, "window", w.width, "list", w.tabs:getWidth(), w.lists.power:getWidth(), "splitter", w.splitter:getX(),
        w.splitter:getIsVisible(), "plan", w.plan:getIsVisible(), w.plan:getX(), w.plan:getWidth(), "share",
        string.format("%.2f", BU.PanelWindow.planShare), "options", w.loadSortButton:getX() + w.loadSortButton:getWidth())
end

if BU8_CLEANUP then
    steps[#steps + 1] = function()
        if BU.PanelWindow.isOpen(MD.panel) then BU.PanelWindow.open(player, panel()):close() end
        if panel() then BU.Changes.remove(panel()) end
        local g = getCell():getGridSquare(GENERATOR[1], GENERATOR[2], 0):getGenerator()
        g:setFuel(MD.fuel or g:getFuel())
        g:setActivated(MD.wasOn == true)
        ModData.remove("BU8TEST")
        say("cleaned", #BU.Store.list())
    end
else
    steps[#steps + 1] = function()
        player:setGodMod(true)
        player:setInvisible(true)
        player:teleportTo(GAS_STATION[1] + 0.5, GAS_STATION[2] + 0.5, 0)
        pause(60)
    end
    steps[#steps + 1] = function()
        if not panel() then
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
        end
        BU.PanelWindow.planShown = true
        BU.PanelWindow.planShare = 0.5
        if BU.PanelWindow.isOpen(MD.panel) then BU.PanelWindow.open(player, panel()):close() end
        w = BU.PanelWindow.open(player, panel())
        pause(10)
    end
    steps[#steps + 1] = function()
        panes("opened")
        say("plan", "levels", #w.plan.levels, "strip", #w.plan.strip, "legend", #w.plan.legend, "cells", #w.plan.cells, "dots", #w.plan.dots)
        w:dragDivider(400)
        pause(5)
    end
    steps[#steps + 1] = function()
        panes("dragged to 400 (clamped to the list's least)")
        w:dragDivider(math.floor(w.width * 0.6))
        pause(5)
    end
    steps[#steps + 1] = function()
        panes("dragged to 60 percent")
        w:setWidth(w.width + 200)
        pause(5)
    end
    steps[#steps + 1] = function()
        panes("window 200 wider")
        w:onPlan()
        pause(5)
    end
    steps[#steps + 1] = function()
        panes("plan hidden")
        w:onPlan()
        pause(5)
    end
    steps[#steps + 1] = function()
        panes("plan shown again")
        -- Hover a dot on the plan: its row is marked in the list.
        local dot = w.plan.dots[1]
        if dot then
            w.plan:setHover(dot.key, dot.room)
            local marked
            for index, item in ipairs(w.lists.power.items) do
                if item.item.device and item.item.device.key == w.planHoverKey then marked = index end
            end
            say("plan hover", dot.key, "row", marked)
            w.plan:setHover(nil, nil)
        end
        local before = w.plan.floor
        w.plan:onMouseWheel(-1)
        say("wheel", before, "->", w.plan.floor, "levels", table.concat(w.plan.levels, ","))
        BU.PanelWindow.legendShown = false
        w.plan:layout()
        say("legend hidden", #w.plan.legend)
        BU.PanelWindow.legendShown = true
        w.plan:layout()
        w.plan:showFloor(panel().z)
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
