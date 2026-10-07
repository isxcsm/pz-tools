-- Misc window parts: load breakdown, links to other boxes, new devices, search, plan zoom and drag, the box's hover
-- summary flag. A takes the ground floor, B (a sub-panel of A) the floor above. "[bu11]" lines. BU11_CLEANUP takes
-- the boxes away.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU11TEST")
local player = getPlayer()
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu11] " .. table.concat(parts, " "))
end
local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local steps, current, waitTicks = {}, 1, 0
local function pause(ticks) waitTicks = ticks end
local function A() return BU.Store.get(MD.a) end
local function B() return BU.Store.get(MD.b) end
local w

local function freeSquareOn(rooms, level)
    for _, room in ipairs(rooms) do
        if room.level == level then
            for _, rect in ipairs(room.rects) do
                for x = rect.x, rect.x + rect.w - 1 do for y = rect.y, rect.y + rect.h - 1 do
                    local q = getCell():getGridSquare(x, y, room.level)
                    if q and q:getObjects():size() == 1 and q:isFree(false) then return q end
                end end
            end
        end
    end
end

local function rows(kind)
    local n = 0
    for _, item in ipairs(w.lists.power.items) do if item.item.kind == kind then n = n + 1 end end
    return n
end

if BU11_CLEANUP then
    steps[#steps + 1] = function()
        for _, id in ipairs({ MD.a, MD.b }) do
            if id and BU.PanelWindow.isOpen(id) then BU.PanelWindow.open(player, BU.Store.get(id)):close() end
        end
        if B() then BU.Changes.remove(B()) end
        if A() then BU.Changes.remove(A()) end
        local g = getCell():getGridSquare(GENERATOR[1], GENERATOR[2], 0):getGenerator()
        if MD.fuel then g:setFuel(MD.fuel) end
        g:setActivated(MD.wasOn == true)
        ModData.remove("BU11TEST")
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
        local building = BU.Panels.buildingAt(GAS_STATION[1], GAS_STATION[2], 0)
        local rooms = BU.Panels.rooms(building)
        local a = BU.Changes.install(freeSquareOn(rooms, 0), BU.PANEL_SPRITES[1])
        MD.a = a.id
        local ground = {}
        for _, room in ipairs(rooms) do if room.level == 0 then ground[#ground + 1] = room.id end end
        BU.Changes.setZone(a, ground)
        local g = getCell():getGridSquare(GENERATOR[1], GENERATOR[2], 0):getGenerator()
        MD.fuel, MD.wasOn = g:getFuel(), g:isActivated()
        g:setFuel(10)
        g:setActivated(true)
        BU.Changes.connectProducer(a, "power", GENERATOR[1], GENERATOR[2], 0, {})
        BU.Changes.upgrade(a)
        BU.Changes.upgrade(a)
        local b = BU.Changes.install(freeSquareOn(rooms, 1), BU.PANEL_SPRITES[1])
        MD.b = b.id
        BU.Changes.link(b, a, {})
        local object = BU.Panels.object(a)
        say("A box special tooltip", object and object:haveSpecialTooltip(), "B zone rooms", (function() local n = 0 for _ in pairs(b.rooms or {}) do n = n + 1 end return n end)())
        -- A's devices seen before, but one: it shows as new.
        ModData.getOrCreate("BuildingUtilitiesSeen")[a.id .. "|power"] = nil
        BU.PanelWindow.planShown = true
        w = BU.PanelWindow.open(player, a)
        w:close()
        local seen = ModData.getOrCreate("BuildingUtilitiesSeen")[a.id .. "|power"]
        local dropped
        for key in pairs(seen) do if not dropped and key:find("lighting_outdoor") == nil then dropped = key end end
        seen[dropped] = nil
        MD.dropped = dropped
        pause(90)
    end
    steps[#steps + 1] = function()
        w = BU.PanelWindow.open(player, A())
        local fresh = 0
        for _, item in ipairs(w.lists.power.items) do if item.item.fresh then fresh = fresh + 1 end end
        local dots = 0
        for _, dot in ipairs(w.plan.dots) do if dot.fresh then dots = dots + 1 end end
        say("new rows", fresh, "new dots", dots, "dropped", MD.dropped)
        say("links", rows("link"))
        say("breakdown", (w.loadArea.tooltip or "nil"):gsub("\n", " | "))
        say("load area", w.loadArea:getIsVisible(), w.loadArea:getWidth())
        -- Search.
        local before = rows("device")
        w.search:setText("스위치")
        w:onSearch()
        say("search", "'" .. tostring(w.query) .. "'", "device rows", before, "->", rows("device"), "rooms", rows("room"))
        w.search:setText("")
        w:onSearch()
        say("search cleared rows", rows("device"), "search box", w.search:getIsVisible(), w.search:getX(), w.search:getWidth())
        -- Zoom and drag on the plan.
        local plan = w.plan
        local map = plan.map
        local s0 = map.scale
        plan:zoomAt(map.left + map.w / 2, map.top + map.h / 2, 2)
        say("zoom 2: scale", string.format("%.1f -> %.1f", s0, plan.map.scale), "zoom", plan.zoom)
        local px = plan.panX
        plan.pressed, plan.moved = true, 0
        plan:drag(30, 0)
        plan.pressed = false
        say("dragged 30px: pan", string.format("%.2f -> %.2f", px, plan.panX), "dragged", plan.dragged)
        say("fit button at", plan:fitToggleX(), "toggle there", plan:toggleAt(plan:fitToggleX() + 2, 10))
        -- The link to B opens B's window.
        for _, item in ipairs(w.lists.power.items) do
            if item.item.kind == "link" then w:onRow("power", item.item, 20, w.lists.power:getWidth()) end
        end
        say("B window open", BU.PanelWindow.isOpen(MD.b))
        if BU.PanelWindow.isOpen(MD.b) then
            local wb = BU.PanelWindow.open(player, B())
            local headerLink = 0
            for _, item in ipairs(wb.lists.power.items) do if item.item.kind == "link" and item.item.header then headerLink = headerLink + 1 end end
            say("B's main link rows", headerLink)
            wb:close()
        end
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
