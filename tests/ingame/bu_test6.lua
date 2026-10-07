-- Building Utilities, what a tier unlocks and how far it reaches: one check in a running game. Results are "[bu6]"
-- lines in console.txt. Takes its boxes away again at the end.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU6TEST")
local player = getPlayer()

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu6] " .. table.concat(parts, " "))
end

local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local steps, current, waitTicks = {}, 1, 0
local function square(at) return getCell():getGridSquare(at[1], at[2], at[3]) end
local function main() return BU.Store.get(MD.main) end
local function child() return BU.Store.get(MD.child) end
local function pause(ticks) waitTicks = ticks end

local function freeSquareIn(building)
    for _, room in ipairs(BU.Panels.rooms(building)) do
        for _, rect in ipairs(room.rects) do
            for x = rect.x, rect.x + rect.w - 1 do for y = rect.y, rect.y + rect.h - 1 do
                local q = getCell():getGridSquare(x, y, room.level)
                if q and q:getObjects():size() == 1 and q:isFree(false) then return q end
            end end
        end
    end
    return nil
end

-- Another building near the gas station, for a sub-panel.
local function otherBuilding(own)
    local best, bestSteps
    for dx = -70, 70, 3 do for dy = -70, 70, 3 do
        local b = BU.Panels.buildingAt(GAS_STATION[1] + dx, GAS_STATION[2] + dy, 0)
        if b and b.key ~= own.key then
            local steps = math.abs(dx) + math.abs(dy)
            if not bestSteps or steps < bestSteps then best, bestSteps = b, steps end
        end
    end end
    return best
end

local function connectedDevice(panel)
    for _, device in ipairs(BU.Panels.devices(panel, "power")) do
        if device.inside and device.state == "on" then return device end
    end
end

local function outsideCount(panel)
    local n = 0
    for _, device in ipairs(BU.Panels.devices(panel, "power")) do
        if not device.inside then n = n + 1 end
    end
    return n
end

steps[#steps + 1] = function()
    say("ranges", "producer", BU.producerRange(1), BU.producerRange(2), BU.producerRange(3),
        "exterior", BU.exteriorRange(1), BU.exteriorRange(2), BU.exteriorRange(3),
        "sub", BU.subPanelRange(1), BU.subPanelRange(2), BU.subPanelRange(3), "nil tier", BU.producerRange(nil))
    say("note2", BU.Panels.upgradeNote(2, true))
    say("note3", BU.Panels.upgradeNote(3))
    player:setGodMod(true)
    player:setInvisible(true)
    player:teleportTo(GAS_STATION[1] + 0.5, GAS_STATION[2] + 0.5, 0)
    pause(60)
end

steps[#steps + 1] = function()
    local own = BU.Panels.buildingAt(GAS_STATION[1], GAS_STATION[2], 0)
    local p = BU.Changes.install(freeSquareIn(own), BU.PANEL_SPRITES[1])
    MD.main = p.id
    local g = square(GENERATOR):getGenerator()
    MD.fuel, MD.wasOn = g:getFuel(), g:isActivated()
    g:setFuel(10)
    g:setActivated(true)
    BU.Changes.connectProducer(p, "power", GENERATOR[1], GENERATOR[2], 0, {})
    local other = otherBuilding(own)
    if other then
        local c = BU.Changes.install(freeSquareIn(other), BU.PANEL_SPRITES[1])
        MD.child = c.id
    end
    say("main", p.id, "tier", p.tier, "child", MD.child)
    pause(30)
end

-- Tier 1: no timers, no sub-panels, the base ranges.
steps[#steps + 1] = function()
    local p = main()
    local device = connectedDevice(p)
    MD.key = device and device.key
    say("tier1", "device", MD.key, "outside", outsideCount(p))
    BU.Sync.send(player, "setSchedule", { panel = p.id, key = MD.key, schedule = "night" })
    local c = child()
    if c then
        local ok, reason, steps, tier = BU.Panels.canLink(c, p)
        local listed
        for _, candidate in ipairs(BU.Panels.linkCandidates(c)) do
            if candidate.panel == p then listed = tostring(candidate.steps) .. "/" .. tostring(candidate.tier) end
        end
        local cost, why = BU.Actions.lineCost("link", c, nil, c.x, c.y, c.z, p.id)
        say("tier1 link", ok, reason, steps, tier, "listed", listed, "lineCost", cost, why)
        MD.linkSteps, MD.linkTier = steps, tier
    end
    -- A square straight west of the building at 25 steps: past tier 1, within tier 2.
    local building = BU.Panels.building(p)
    local rooms = BU.Panels.rooms(building)
    local cx, cy = BU.Geometry.centre(building)
    cy = math.floor(cy)
    local x = math.floor(cx)
    while (BU.Geometry.toBuilding(x, cy, rooms) or 0) < 25 do x = x - 1 end
    MD.far = { x, cy }
    local found
    for _, candidate in ipairs(BU.Panels.producerCandidates(x, cy, 0)) do
        if candidate.panel == p then found = candidate end
    end
    local inRange = 0
    for _, candidate in ipairs(BU.Panels.inProducerRange(x, cy, 0)) do if candidate.panel == p then inRange = inRange + 1 end end
    say("far square", x, cy, "steps", BU.Geometry.toBuilding(x, cy, rooms), "candidate tier", found and found.tier,
        "inRange", found and found.inRange, "inProducerRange", inRange)
    pause(10)
end

steps[#steps + 1] = function()
    local p = main()
    say("tier1 schedule after send", p.power.schedule[MD.key])
    local w = BU.PanelWindow.open(player, p)
    w:refresh()
    local controls = 0
    for _, item in ipairs(w.lists.power.items) do if item.item.controls then controls = controls + 1 end end
    say("tier1 rows with controls", controls, "range tip", w.rangeButton.tooltip, "upgrade tip", w.upgradeButton.tooltip)
    w:showRange(true)
    MD.rangeMarks1 = #w.rangeObjects
    w:showRange(false)
    -- A timer left in the save from before: ignored below tier 2.
    p.power.schedule[MD.key] = BU.scheduleOn("night") and "day" or "night"
    BU.Changes.applyTimers(p)
    say("tier1 stale timer", p.power.schedule[MD.key], "timed", p.power.timed[MD.key])
    BU.Changes.upgrade(p)
    say("tier2", p.tier, "timed after upgrade", p.power.timed[MD.key], "rule", BU.Networks.rule(p, "power", MD.key))
    p.power.schedule[MD.key] = nil
    BU.Changes.applyTimers(p)
    BU.Sync.send(player, "setSchedule", { panel = p.id, key = MD.key, schedule = "day" })
    pause(10)
end

steps[#steps + 1] = function()
    local p = main()
    say("tier2 schedule after send", p.power.schedule[MD.key])
    BU.Sync.send(player, "setSchedule", { panel = p.id, key = MD.key, schedule = "always" })
    local w = BU.PanelWindow.open(player, p)
    w:refresh()
    local controls = 0
    for _, item in ipairs(w.lists.power.items) do if item.item.controls then controls = controls + 1 end end
    w:showRange(true)
    say("tier2 rows with controls", controls, "range marks", MD.rangeMarks1, "->", #w.rangeObjects, "outside", outsideCount(p))
    w:showRange(false)
    local c = child()
    if c then
        local ok, reason, steps, tier = BU.Panels.canLink(c, p)
        say("tier2 link", ok, reason, steps, tier)
    end
    local inRange = 0
    for _, candidate in ipairs(BU.Panels.inProducerRange(MD.far[1], MD.far[2], 0)) do if candidate.panel == p then inRange = inRange + 1 end end
    say("tier2 far square inProducerRange", inRange)
    BU.Changes.upgrade(p)
    say("tier3", p.tier, "outside", outsideCount(p), "sheds", BU.Panels.sheds(p))
    if c then
        local ok, reason = BU.Panels.canLink(c, p)
        say("tier3 link", ok, reason)
        if ok then
            BU.Changes.link(c, p, {})
            say("linked", c.parent == p.id)
        end
    end
    pause(10)
end

steps[#steps + 1] = function()
    local p = main()
    say("schedule back to always", p.power.schedule[MD.key])
    local w = BU.PanelWindow.isOpen(p.id) and BU.PanelWindow.open(player, p)
    if w then w:close() end
    local c = child()
    if c then BU.Changes.remove(c) end
    pause(10)
end

steps[#steps + 1] = function()
    BU.Changes.remove(main())
    local g = square(GENERATOR):getGenerator()
    g:setFuel(MD.fuel or g:getFuel())
    g:setActivated(MD.wasOn == true)
    say("cleaned", "panels", #BU.Store.list())
    ModData.remove("BU6TEST")
    say("done")
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
