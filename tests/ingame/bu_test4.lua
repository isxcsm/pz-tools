-- Building Utilities, the device list overhaul and the floor plan: one check in a running game. Results are "[bu4]"
-- lines in console.txt. BU4_CLEANUP takes the box away again.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU4TEST")
local player = getPlayer()

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu4] " .. table.concat(parts, " "))
end

local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local steps, current, waitTicks, waitUntil, waitLimit = {}, 1, 0, nil, 0
local function square(at) return getCell():getGridSquare(at[1], at[2], at[3]) end
local function panel() return BU.Store.get(MD.panel) end
local function wait(condition, ticks) waitUntil, waitLimit = condition, ticks or 3000 end
local function pause(ticks) waitTicks = ticks end
local function send(command, args) args.panel = MD.panel; BU.Sync.send(player, command, args) end
local function window() return BU.PanelWindow.open(player, panel()) end
local function rows(list, kind)
    local n = 0
    for _, item in ipairs(list.items) do if not kind or item.item.kind == kind then n = n + 1 end end
    return n
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

local function setup()
    steps[#steps + 1] = function()
        player:setGodMod(true)
        player:setInvisible(true)
        player:teleportTo(GAS_STATION[1] + 0.5, GAS_STATION[2] + 0.5, 0)
        local g = square(GENERATOR):getGenerator()
        MD.fuel, MD.wasOn = g:getFuel(), g:isActivated()
        g:setFuel(10)
        g:setActivated(true)
        local target = freeSquareIn(GAS_STATION)
        local p = BU.Changes.install(target, BU.PANEL_SPRITES[1])
        MD.panel = p.id
        BU.Changes.connectProducer(p, "power", GENERATOR[1], GENERATOR[2], 0, {})
        BU.Changes.upgrade(p)
        BU.Changes.upgrade(p)
        say("box", p.id, "tier", p.tier, "screen", getCore():getScreenWidth(), getCore():getScreenHeight())
        pause(120)
    end
end

local function checks()
    steps[#steps + 1] = function()
        if panel().tripped then send("resetBreaker", {}) end
        local building = BU.Panels.building(panel())
        local titles, names = BU.Panels.roomTitles(building), {}
        local rooms = BU.Panels.rooms(building)
        for _, room in ipairs(rooms) do names[#names + 1] = titles[room.id] end
        table.sort(names)
        say("rooms", #rooms, "titles", table.concat(names, " | "))
        local w = window()
        w:refresh()
        local view = w.views.power
        local groups = 0
        for _ in pairs(view.totals) do groups = groups + 1 end
        say("list", "rows", rows(w.lists.power), "room rows", rows(w.lists.power, "room"), "device rows", rows(w.lists.power, "device"), "groups", groups)
        local light
        for _, device in ipairs(view.devices) do
            if device.entry.type == "IsoLightSwitch" then light = view.names[device.key]; break end
        end
        say("names", "a light", light)
        local plan = w.plan
        say("plan", "shown", plan:getIsVisible(), "window", w.width, "x", w:getX(), "levels", #plan.levels, "floor", plan.floor,
            "cells", #plan.cells, "labels", #plan.labels, "dots", #plan.dots, "squares", #plan.squares, "scale", plan.scale)
        -- What a frame of each costs, drawn many times over in one tick.
        local function cost(element, times)
            local started = getTimestampMs()
            for _ = 1, times do element:render() end
            return (getTimestampMs() - started) * 1000 / times
        end
        say("cost per frame in microseconds", "plan", cost(plan, 500), "list", cost(w.lists.power, 200))
        -- A room switched off at once, then on again.
        for id, totals in pairs(view.totals) do
            if id ~= "outside" and totals.on >= 2 then MD.room, MD.roomCount = id, totals.count; break end
        end
        say("room switch", MD.room, view.totals[MD.room].title, "devices", MD.roomCount)
        send("setRoomInside", { utility = "power", room = MD.room, on = false })
        wait(function()
            for _, device in ipairs(BU.Panels.devices(panel(), "power")) do
                if device.inside and device.roomId == MD.room and device.state == "on" then return false end
            end
            return true
        end, 600)
    end
    steps[#steps + 1] = function()
        local w = window()
        w:refresh()
        say("room off", "totals", w.views.power.totals[MD.room].on, "/", w.views.power.totals[MD.room].count)
        send("setRoomInside", { utility = "power", room = MD.room, on = true })
        wait(function()
            for _, device in ipairs(BU.Panels.devices(panel(), "power")) do
                if device.inside and device.roomId == MD.room and device.state ~= "on" then return false end
            end
            return true
        end, 600)
    end
    steps[#steps + 1] = function()
        local w = window()
        w:refresh()
        say("room on", "totals", w.views.power.totals[MD.room].on, "/", w.views.power.totals[MD.room].count)
        -- The plan shows only a room; the list follows.
        w:filterRoom(MD.room)
        local list = w.lists.power
        local others = 0
        for _, item in ipairs(list.items) do
            if item.item.kind == "room" and item.item.id ~= MD.room then others = others + 1 end
        end
        say("filter", "filter rows", rows(list, "filter"), "other rooms", others, "plan filter", w.plan.data.filter)
        w:filterRoom(nil)
        -- Folding a room hides its devices.
        local before = rows(list, "device")
        for _, item in ipairs(list.items) do
            if item.item.kind == "room" and item.item.id == MD.room then w:onRow("power", item.item, 300, list:getWidth()); break end
        end
        local folded = rows(list, "device")
        for _, item in ipairs(list.items) do
            if item.item.kind == "room" and item.item.id == MD.room then w:onRow("power", item.item, 300, list:getWidth()); break end
        end
        say("fold", "devices", before, "folded", folded, "unfolded", rows(list, "device"))
        -- A dot clicked: its row.
        local dot = w.plan.dots[1]
        if dot then
            w:showDevice(dot.key)
            local selected = list.items[list.selected]
            say("show device", dot.key, "selected", selected and selected.item.device and selected.item.device.key == dot.key)
        end
        -- In use only.
        w:onActiveOnly()
        local active = rows(list, "device")
        w:onActiveOnly()
        say("active only", "devices", active, "all", rows(list, "device"))
        -- The plan hidden and shown again: the window shrinks and grows by it.
        local width = w.width
        w:onPlan()
        local hidden = w.width
        w:onPlan()
        say("plan toggle", width, "->", hidden, "->", w.width, "list", w.tabs:getWidth())
        MD.capacity3 = SandboxVars.BuildingUtilities.Capacity3
        SandboxVars.BuildingUtilities.Capacity3 = 0.01
        wait(function() return panel().tripped end)
    end
    steps[#steps + 1] = function()
        pause(60)
    end
    steps[#steps + 1] = function()
        local object = BU.Panels.object(panel())
        say("tripped", panel().tripped, "box highlighted", object and object:isHighlighted(0), "blink", object and object:isBlink(0))
        SandboxVars.BuildingUtilities.Capacity3 = MD.capacity3
        say("checks done")
    end
end

local function cleanup()
    steps[#steps + 1] = function()
        local w = BU.PanelWindow.isOpen(MD.panel) and window()
        if w then w:close() end
        if MD.capacity3 then SandboxVars.BuildingUtilities.Capacity3 = MD.capacity3 end
        local p = panel()
        if p then BU.Changes.remove(p) end
        local g = square(GENERATOR):getGenerator()
        g:setFuel(MD.fuel or g:getFuel())
        g:setActivated(MD.wasOn == true)
        say("cleaned", "panels", #BU.Store.list())
        ModData.remove("BU4TEST")
    end
end

if BU4_CLEANUP then cleanup() else setup(); checks() end

local function tick()
    if waitTicks > 0 then waitTicks = waitTicks - 1; return end
    if waitUntil then
        waitLimit = waitLimit - 1
        local ok, done = pcall(waitUntil)
        if ok and not done and waitLimit > 0 then return end
        if not ok then say("FAIL in wait", done) elseif waitLimit <= 0 then say("TIMEOUT in step", current - 1) end
        waitUntil = nil
    end
    local step = steps[current]
    if not step then Events.OnTick.Remove(tick); return end
    current = current + 1
    local ok, problem = pcall(step)
    if not ok then say("FAIL in step", current - 1, problem) end
end
Events.OnTick.Add(tick)
