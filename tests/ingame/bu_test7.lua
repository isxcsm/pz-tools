-- Building Utilities, line loss: the power line into a box multiplies its load by the API's load factor, less at
-- higher tiers. One check in a running game; "[bu7]" lines in console.txt. Takes its boxes away again at the end.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU7TEST")
local player = getPlayer()

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu7] " .. table.concat(parts, " "))
end

local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local steps, current, waitTicks = {}, 1, 0
local function square(at) return getCell():getGridSquare(at[1], at[2], at[3]) end
local function main() return BU.Store.get(MD.main) end
local function child() return BU.Store.get(MD.child) end
local function pause(ticks) waitTicks = ticks end
local function near(a, b) return a and b and math.abs(a - b) < 1e-4 end

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

local function report(label, p)
    local state = BU.Networks.state(p, "power")
    local pieces, loss = BU.Panels.powerLine(p, state)
    local expected = 1 + (loss or 0) / 100
    say(label, "tier", p.tier, "pieces", pieces, "loss", loss, "factor", state.loadFactor, "expected", expected,
        "match", near(state.loadFactor, expected), "load", state.load, "own", state.ownLoad,
        "load = own x factor", p.parent == nil and not MD.linked and near(state.load, state.ownLoad * state.loadFactor) or "-")
    return state
end

steps[#steps + 1] = function()
    say("api has setLoadFactor", BU.api() ~= nil and BU.api().networks.setLoadFactor ~= nil, "loss per piece",
        BU.lossPerPiece(1), BU.lossPerPiece(2), BU.lossPerPiece(3))
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
    if other then MD.child = BU.Changes.install(freeSquareIn(other), BU.PANEL_SPRITES[1]).id end
    pause(30)
end

steps[#steps + 1] = function()
    local p = main()
    local state = report("tier1", p)
    local w = BU.PanelWindow.open(player, p)
    w:refresh()
    say("load text", w.loadText)
    say("upgrade tip", w.upgradeButton.tooltip)
    -- A device's preview counts the loss.
    local device
    for _, d in ipairs(BU.Panels.devices(p, "power")) do
        if d.state == "on" and (d.power or 0) > 0 and not d.held then device = d; break end
    end
    if device then say("preview", device.key, device.power, w:preview(device), "expected after", state.load - device.power * state.loadFactor) end
    BU.Changes.upgrade(p)
    pause(5)
end

steps[#steps + 1] = function()
    report("tier2", main())
    local c = child()
    if c then
        BU.Changes.link(c, main(), {})
        MD.linked = true
    end
    pause(5)
end

steps[#steps + 1] = function()
    local p, c = main(), child()
    if c then
        local cs = report("child", c)
        local ps = BU.Networks.state(p, "power")
        say("parent load", ps.load, "expected", (ps.ownLoad + cs.load) * ps.loadFactor, "match", near(ps.load, (ps.ownLoad + cs.load) * ps.loadFactor))
        BU.Changes.unlink(c)
        MD.linked = false
    end
    BU.Changes.upgrade(p)
    pause(5)
end

steps[#steps + 1] = function()
    local p = main()
    report("tier3", p)
    local w = BU.PanelWindow.open(player, p)
    w:refresh()
    say("load text tier3", w.loadText)
    w:close()
    -- A sandbox without losses.
    MD.lossPerWire = SandboxVars.BuildingUtilities.LossPerWire
    SandboxVars.BuildingUtilities.LossPerWire = 0
    p.tier = 1
    BU.Networks.applyLoss(p)
    pause(5)
end

steps[#steps + 1] = function()
    local p = main()
    report("no loss", p)
    SandboxVars.BuildingUtilities.LossPerWire = MD.lossPerWire
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
    ModData.remove("BU7TEST")
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
