-- Building Utilities Dev: what the "BU" section of the PZExtDev debug window (F8) does, as plain functions on
-- BuildingUtilities.Dev. They change the save the way the mod's own changes do (BU.Changes, BU.Sync), skipping the
-- costs, tools, ranges and tiers a player goes through, so each part of the mod can be brought to the state a test
-- needs. The game's environment (time, weather, temperature, the character) is the window's own (PZExtDev.Env).
-- The game alone is its own server: the window calls these directly (the server files, BU.WaterRun, are loaded by the
-- time a control is used). Debug mode only.
if not isDebugEnabled() then return end
require "BuildingUtilities/Changes"
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/Spawned"
local BU = BuildingUtilities
local Store, Panels, Changes, Sync, Networks = BU.Store, BU.Panels, BU.Changes, BU.Sync, BU.Networks
local Dev = {}
BU.Dev = Dev

local function say(...)
    print("[BU dev] " .. table.concat({ ... }, " "))
end
Dev.say = say

local function player() return getPlayer() end

-- ---- the panel the pages work on ------------------------------------------------------------------------------------

Dev.REACH = 60          -- the nearest panel is sought this far
Dev.selectedId = nil    -- the panel chosen on the panel page; nil: the nearest

-- The panels by their distance from the character, nearest first: { panel, distance }.
function Dev.panels()
    local p = player()
    local list = {}
    if not p then return list end
    for _, panel in ipairs(Store.list()) do
        local dx, dy = panel.x - p:getX(), panel.y - p:getY()
        list[#list + 1] = { panel = panel, distance = math.sqrt(dx * dx + dy * dy) + math.abs(panel.z - p:getZ()) * 3 }
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    return list
end

-- The panel chosen, or the nearest within Dev.REACH.
function Dev.selected()
    local chosen = Store.get(Dev.selectedId)
    if chosen then return chosen end
    local nearest = Dev.panels()[1]
    return nearest and nearest.distance <= Dev.REACH and nearest.panel or nil
end

function Dev.select(id) Dev.selectedId = id end

function Dev.name(panel)
    return panel and (Panels.name(panel) .. " #" .. tostring(panel.id)) or "-"
end

-- ---- give -----------------------------------------------------------------------------------------------------------

-- Items into the character's inventory: { { type, count }, ... }.
function Dev.give(list)
    local inv = player():getInventory()
    for _, entry in ipairs(list) do
        for _ = 1, entry[2] or 1 do inv:AddItem(entry[1]) end
    end
    say("gave", #list, "kinds")
end

-- A car battery worn down: low charge, poor condition (the rack's weak drain, reconditioning with baking soda).
function Dev.giveWornBattery()
    local item = player():getInventory():AddItem("Base.CarBattery2")
    item:setUsedDelta(0.2)
    item:setCondition(30)
end

-- A petrol can, full.
function Dev.giveFuelCan()
    local item = player():getInventory():AddItem("Base.PetrolCan")
    local fluid = item and item:getFluidContainer()
    if fluid then fluid:addFluid(Fluid.Petrol, fluid:getFreeCapacity()) end
end

-- ---- the panel ------------------------------------------------------------------------------------------------------

function Dev.setTier(panel, tier)
    local before = panel.tier or 1
    panel.tier = math.max(1, math.min(BU.TIERS, tier))
    if panel.tier > before then Store.record(panel, "IGUI_BU_Log_Upgraded", { panel.tier }) end
    Changes.applyTimers(panel)
    Changes.unitsChanged(panel)
    Sync.changed(panel.id)
end

function Dev.trip(panel) Changes.trip(panel) end
function Dev.resetBreaker(panel) Changes.resetBreaker(panel) end
function Dev.mainSwitch(panel, off) Changes.setLever(panel, not off) end

-- A load added at the box that brings the panel's to so many times its limit (Panels.limit; twice by default): with
-- overload on, twice trips the breaker at the next minute, a little over drains its gauge.
function Dev.overload(panel, on, ratio)
    local extra = 0
    if on then
        -- what the breaker counts without this load
        local state = BU.Networks.state(panel, "power")
        local extras = panel.extraLoads or {}
        local base = state and state.load and state.load - (extras.dev or 0) or 0
        extra = math.max(0.01, BU.Panels.limit(panel) * (ratio or 2) - math.max(0, base))
    end
    Changes.setExtraLoad(panel, "dev", extra)
    Sync.changed(panel.id)
end

function Dev.overloaded(panel)
    return panel.extraLoads ~= nil and panel.extraLoads.dev ~= nil
end

-- One of each kind of line the log shows, with notices on screen.
function Dev.logSample(panel)
    Store.record(panel, "IGUI_BU_Log_Upgraded", { panel.tier or 1 })
    Store.record(panel, "IGUI_BU_Log_Reset")
    Sync.notice(panel, "IGUI_BU_Notice_Tripped", Panels.name(panel))
    Sync.notice(panel, "IGUI_BU_Notice_SwitchedOff", Panels.name(panel))
    Sync.notice(panel, "IGUI_BU_Notice_SwitchedOn", Panels.name(panel))
    Sync.changed(panel.id)
end

function Dev.clearLog(panel)
    panel.log = {}
    Sync.changed(panel.id)
end

function Dev.openWindow(panel)
    if BU.PanelWindow then BU.PanelWindow.open(player(), panel) end
end

function Dev.goTo(panel)
    PZExtDev.Env.teleport(panel.x + 1, panel.y + 1, panel.z)
end

-- ---- spawned boxes --------------------------------------------------------------------------------------------------

-- The character has found no box yet: the first find's line and outline (BU.Finds) come again.
function Dev.resetFind()
    player():getModData()[BU.Finds.FOUND] = nil
end

-- The spawned boxes the save keeps (BU.Spawned: the ones in the areas loaded so far), in a fixed order.
local function spawnedPlaces()
    local list = {}
    for _, places in pairs(BU.Store.data().spawned or {}) do
        for _, place in ipairs(places) do list[#list + 1] = place end
    end
    table.sort(list, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    return list
end

-- The box nearest the character on their floor, within RESPAWN_REACH squares: its object and square, or nil.
local RESPAWN_REACH = 15
local function nearestBox()
    local p = player()
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local best, bestSquare, bestDistance
    for dx = -RESPAWN_REACH, RESPAWN_REACH do
        for dy = -RESPAWN_REACH, RESPAWN_REACH do
            local square = getCell():getGridSquare(px + dx, py + dy, pz)
            local objects = square and square:getObjects()
            for i = 0, objects and objects:size() - 1 or -1 do
                local object = objects:get(i)
                local sprite = object:getSprite()
                local distance = dx * dx + dy * dy
                if sprite and BU.PanelLook.ofSprite(sprite:getName()) and (not best or distance < bestDistance) then
                    best, bestSquare, bestDistance = object, square, distance
                end
            end
        end
    end
    return best, bestSquare
end

-- The box nearest the character made a spawned one again, as the map leaves it (bare, of tier 1, facing as it does,
-- kept: BU.Spawned), and the first find reset: walking up to it shows the find again. Returns its square, or nil.
local SIDES = { "S", "E", "N", "W" }
function Dev.respawnNearest()
    local object, square = nearestBox()
    if not object then return nil end
    local shown = BU.PanelLook.ofSprite(object:getSprite():getName())
    local panel = BU.Panels.ofObject(object)
    local outdoor = shown.variant > BU.TIERS
    if panel then
        outdoor = panel.outdoor == true
        BU.Changes.remove(panel)
    else
        square:transmitRemoveItemFromSquare(object)
    end
    local bare = IsoObject.new(square, BU.panelSprite(SIDES[shown.facing] or "S", 1, outdoor), nil, false)
    square:AddTileObject(bare)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local kept = false
    for _, place in ipairs(BU.Spawned.near(x, y, z, 0)) do
        if place.x == x and place.y == y then kept = true end
    end
    if not kept then BU.Spawned.keep(x, y, z) end
    Dev.resetFind()
    return square
end

Dev.spawnedIndex = 0
-- Beside the next spawned box (a step takes the first find, when it is reset); returns its number and how many.
function Dev.nextSpawned()
    local list = spawnedPlaces()
    if #list == 0 then return 0, 0 end
    Dev.spawnedIndex = Dev.spawnedIndex % #list + 1
    local place = list[Dev.spawnedIndex]
    PZExtDev.Env.teleport(place.x + 1, place.y + 1, place.z)
    return Dev.spawnedIndex, #list
end

-- ---- power ----------------------------------------------------------------------------------------------------------

local function freeSquareNear(dx)
    local p = player()
    local cell = getCell()
    for d = dx, dx + 6 do
        for _, off in ipairs({ { d, 0 }, { 0, d }, { -d, 0 }, { 0, -d } }) do
            local sq = cell:getGridSquare(math.floor(p:getX()) + off[1], math.floor(p:getY()) + off[2], math.floor(p:getZ()))
            if sq and sq:isFree(false) and not sq:isSolid() then return sq end
        end
    end
    return nil
end

-- A generator beside the character, connected and switched off, its tank filled to a share (0 to 1).
function Dev.spawnGenerator(share)
    local sq = freeSquareNear(2)
    if not sq then say("no free square near") return nil end
    local gen = IsoGenerator.new(instanceItem("Base.Generator"), getCell(), sq)
    gen:setConnected(true)
    gen:setCondition(100)
    gen:setFuel(gen:getMaxFuel() * share)
    say("generator at", sq:getX(), sq:getY(), sq:getZ())
    return gen
end

-- The generators within so many squares on the character's floor: { generator, ... } (a button's call: it reads the
-- squares).
function Dev.generatorsNear(radius)
    local p = player()
    local cell = getCell()
    local x0, y0, z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local found = {}
    for y = y0 - radius, y0 + radius do
        for x = x0 - radius, x0 + radius do
            local sq = cell:getGridSquare(x, y, z)
            local gen = sq and sq:getGenerator()
            if gen then found[#found + 1] = gen end
        end
    end
    return found
end

function Dev.setFuel(share, radius)
    local list = Dev.generatorsNear(radius or 20)
    for _, gen in ipairs(list) do gen:setFuel(gen:getMaxFuel() * share) end
    say("fuel", share, "in", #list, "generators")
    return #list
end

-- A sandbox option set in play (its name as the sandbox file has it: "BuildingUtilities.WearRate", "ElecShutModifier")
-- and SandboxVars made again from the options; the mod brings the world to it (features, reach) at once.
function Dev.setOption(name, value)
    local options = getSandboxOptions()
    local option = options:getOptionByName(name)
    if not option then error("no sandbox option " .. tostring(name)) end
    option:asConfigOption():parse(tostring(value))
    options:toLua()
    Changes.applyFeatures()
    Changes.applyShape()
    Sync.changed(nil)
    say("option", name, "=", tostring(value))
end

function Dev.option(name, default)
    return BU.sandbox(name, default)
end

-- The grid's power or water, on or off: the shutoff day moved past or before today. On, it stays on.
local NEVER = 99999
function Dev.gridPower(on)
    Dev.setOption("ElecShutModifier", on and NEVER or -1)
    getWorld():setHydroPowerOn(on)
end

function Dev.gridWater(on)
    Dev.setOption("WaterShutModifier", on and NEVER or -1)
end

function Dev.gridPowerOn() return getWorld():isHydroPowerOn() end

-- ---- solar panels and batteries -------------------------------------------------------------------------------------

function Dev.units(panel, kind)
    return Store.unitList(kind, panel.id)
end

-- Snow on the panel's solar panels: 0 to 1, or nil for none.
function Dev.snow(panel, amount)
    for _, unit in ipairs(Dev.units(panel, "solar")) do
        if amount then unit.snow, unit.snowAt = amount, BU.Energy.minute() else Changes.clearSnow(unit) end
        BU.Units.show(unit)
    end
    Sync.changed(panel.id)
end

-- Every battery of the panel's racks at a charge (0 to 1) and, when given, a condition (0 to 100); the items in the
-- racks follow (BU.Rack.sync).
function Dev.setBatteries(panel, charge, condition)
    for _, unit in ipairs(Dev.units(panel, "rack")) do
        BU.Rack.sync(unit)
        for _, battery in ipairs(unit.batteries) do
            if charge then battery.charge = charge end
            if condition then battery.condition = condition end
        end
        BU.Rack.sync(unit)
    end
    Sync.changed(panel.id)
end

-- The window's graphs filled with a made-up day and night, two days long: what the solar panels made, the load and
-- the bank's charge, and each water group's level.
function Dev.fillGraphs(panel)
    local now = math.floor(getGameTime():getWorldAgeHours())
    local log = {}
    local capacity = BU.capacity(panel.tier or 1)
    for i = Store.ENERGY_HOURS, 1, -1 do
        local hour = now - i
        local h = hour - math.floor(hour / 24) * 24
        local sun = math.max(0, math.sin((h - 6) / 12 * math.pi))
        log[#log + 1] = { hour = hour, made = capacity * 0.6 * sun, used = capacity * (0.25 + 0.1 * math.cos(h / 4)),
            charge = 0.3 + 0.5 * sun }
    end
    panel.energyLog = log
    panel.water.levelLog = {}
    for _, pipe in ipairs(BU.Water.pipes(panel)) do
        local levels = {}
        for i = Store.ENERGY_HOURS, 1, -1 do
            levels[#levels + 1] = { hour = now - i, amount = 400 + 300 * math.cos(i / 7), capacity = 800 }
        end
        panel.water.levelLog[pipe.id] = levels
    end
    Sync.changed(panel.id)
end

-- ---- water ----------------------------------------------------------------------------------------------------------

-- Each tank network filled to a share of what it holds (0 empties it).
function Dev.setWater(panel, share)
    for _, network in ipairs(Networks.waterLayout(panel).networks) do
        local state = network.kind == "T" and Networks.waterState(network.id)
        if state and (state.capacity or 0) > 0 then
            local want = state.capacity * share - (state.amount or 0)
            if want > 0 then
                Networks.fillInto(panel, { network.id }, want, "Water")
            elseif want < 0 then
                Networks.drawFrom(panel, { network.id }, -want)
            end
        end
    end
    Sync.changed(panel.id)
end

-- A new pipe, free.
function Dev.addPipe(panel) Changes.addPipe(panel) end

-- The panel's filters with no media left, or a fresh charge.
function Dev.filterMedia(panel, empty)
    for _, unit in ipairs(Dev.units(panel, "filter")) do
        if empty then unit.media = 0 else Changes.replaceMedia(unit) end
    end
    Sync.changed(panel.id)
end

-- The sprinklers spray now (their look), and water the plants in reach as the minute would.
function Dev.spray(panel)
    local now = getGameTime():getWorldAgeHours()
    for _, unit in ipairs(Dev.units(panel, "sprinkler")) do unit.sprayedAt = now end
    BU.WaterRun.sprinklers(panel)
    Sync.changed(panel.id)
end

function Dev.freeze(panel, on) Changes.setFrozen(panel, on) end

-- The water units' state as lines.
function Dev.waterLines(panel)
    local lines = {}
    for _, kind in ipairs({ "pump", "booster", "filter", "sprinkler" }) do
        for _, unit in ipairs(Dev.units(panel, kind)) do
            local inlet, outlet = BU.WaterUnits.pipes(unit)
            local parts = { kind, tostring(unit.x) .. "," .. tostring(unit.y) .. "," .. tostring(unit.z),
                "pipe " .. tostring(inlet or "-") .. ">" .. tostring(outlet or "-") }
            if kind ~= "sprinkler" then
                parts[#parts + 1] = "running " .. tostring(unit.running == true)
                if unit.idle then parts[#parts + 1] = "idle " .. unit.idle end
                if unit.moved then parts[#parts + 1] = tostring(unit.moved) .. " L/h" end
                if unit.fluid then parts[#parts + 1] = unit.fluid end
                if kind == "filter" then
                    parts[#parts + 1] = "media " .. string.format("%.0f", BU.WaterUnits.mediaLeft(unit) * 100) .. "%"
                end
            else
                parts[#parts + 1] = "sprayed " .. (unit.sprayedAt and string.format("%.1f", getGameTime():getWorldAgeHours() - unit.sprayedAt) .. "h ago" or "never")
            end
            lines[#lines + 1] = table.concat(parts, "  ")
        end
    end
    return lines
end

-- ---- devices --------------------------------------------------------------------------------------------------------

-- The panel's devices of a utility (a button's call: it reads the building and around it).
function Dev.devices(panel, utility)
    return Panels.devices(panel, utility)
end

function Dev.deviceLine(device)
    local e = device.entry
    local where = device.inside and (device.attached and "attached" or "inside") or "outside"
    local parts = { BU.displayName(e.x, e.y, e.z, e.sprite), where, device.state }
    if device.schedule and device.schedule ~= "always" then parts[#parts + 1] = device.schedule end
    if device.held then parts[#parts + 1] = "held:" .. device.held end
    if device.pending then parts[#parts + 1] = "pending" end
    return table.concat(parts, "  ")
end

-- Every device of a utility connected (inside, and outside for free) or none.
function Dev.connectAll(panel, utility, on)
    Changes.setAllInside(panel, utility, on)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        if not device.inside then
            if on and device.state == "off" then
                Changes.includeOutside(panel, utility, device, {})
            elseif not on and device.state == "on" then
                Changes.excludeOutside(panel, utility, device)
            end
        end
    end
    Sync.changed(panel.id)
end

-- Every connected power device on a timer (BU.SCHEDULES).
function Dev.scheduleAll(panel, schedule)
    for _, device in ipairs(Panels.devices(panel, "power")) do
        if device.state == "on" then Changes.setSchedule(panel, device.key, schedule) end
    end
    Changes.applyTimers(panel)
end

function Dev.syncAttached(panel) Changes.syncAttached(panel) end

return Dev
