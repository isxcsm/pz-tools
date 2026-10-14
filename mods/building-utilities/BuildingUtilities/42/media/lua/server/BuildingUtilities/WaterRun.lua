-- What the water units (BU.WaterUnits) do, on the server: each minute a panel's machines move water from their inlet
-- to their outlet (BU.Water.unitPipes) — its booster pumps up the floors, its filters through their media, its pumps
-- from the river or well beside them — and each ten minutes its sprinklers water the crops around them; each minute
-- the fire sprinklers put out the fires they reach (WaterRun.fires). A machine
-- fills the tanks of its outlet pipe in its own building (Water.fillTargets), the highest floor it reaches first: a
-- pump or a filter its own floor and below, a booster pump up to Water.boostFloors() above its own. Server.lua calls
-- these with the panel's water layout (Networks.waterLayout).
require "BuildingUtilities/Changes"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Store, Networks, Changes, Water, Sync, WaterUnits = BU.Store, BU.Networks, BU.Changes, BU.Water, BU.Sync,
    BU.WaterUnits
local WaterRun = {}
BU.WaterRun = WaterRun

-- What a machine shows of its last run (WaterUnits): cleared while it rests.
local SHOWN = { "running", "idle", "moved" }

-- A panel's units of a kind that work (BU.Units.working), after the others (of a kind that is off, or whose line is
-- cut) rested: what they show of their last run cleared. Returns those that work and whether any rested.
local function working(panel, kind)
    local result, live, changed = BU.Units.working(panel, kind), {}, false
    for _, unit in ipairs(result) do live[unit] = true end
    for _, unit in ipairs(Store.unitList(kind, panel.id)) do
        if not live[unit] then
            for _, field in ipairs(SHOWN) do
                if unit[field] then unit[field], changed = nil, true end
            end
        end
    end
    return result, changed
end

-- Whether a panel's power is on for its units: the box lets it through (Networks.powerAllowed) and it is supplied.
local function powered(panel)
    if not Networks.powerAllowed(panel) then return false end
    local state = Networks.state(panel, "power")
    return state ~= nil and state.supplied == true
end

-- Where a unit is for its water: its building and floor (Water.placeOf, by its line).
local function placeOf(panel, unit)
    return Water.placeOf(panel, unit.x, unit.y, unit.z, BU.Links.unitRef(unit))
end

-- How much more tank networks take, as the API last saw them.
local function roomIn(ids)
    local free = 0
    for _, id in ipairs(ids) do
        local state = Networks.waterState(id)
        if state then free = free + math.max(0, (state.capacity or 0) - (state.amount or 0)) end
    end
    return free
end

-- Litres into tank networks, each fluid as it is (a filter's tainted water as water, purify).
local function fillMix(panel, ids, mix, purify)
    local filled = 0
    for fluid, litres in pairs(mix) do
        if purify and fluid == "TaintedWater" then fluid = "Water" end
        filled = filled + Networks.fillInto(panel, ids, litres, fluid)
    end
    return filled
end

-- Draws litres from networks in turn, as far as the targets have room: what was drawn, by fluid, and how much.
local function drawFor(panel, sources, targets, litres)
    if #targets == 0 then return 0, {}, "noTanks" end
    local free = roomIn(targets)
    if free < 0.05 then return 0, {}, "full" end
    local drawn, mix = Networks.drawFrom(panel, sources, math.min(litres, free))
    if drawn <= 0 then return 0, {}, "noWater" end
    return drawn, mix
end

-- A machine's new state: running (nil or true), why it idles, litres an hour it moved. Returns whether it changed.
local function show(unit, running, why, moved)
    moved = moved and moved > 0 and math.floor(moved + 0.5) or nil
    if running == unit.running and why == unit.idle and moved == unit.moved then return false end
    unit.running, unit.idle, unit.moved = running, why, moved
    return true
end

-- A pump: water from beside it into its outlet pipe's tanks on its floor and below. Returns running (it draws power:
-- also running dry, with no water beside it), why it idles, litres an hour.
local function pump(panel, layout, unit, minutes, on)
    if not on then return nil, "noPower" end
    if panel.water.frozen then return nil, "frozen" end
    if not unit.fluid then return true, "noWater" end
    local _, outlet = Water.unitPipes(panel, unit)
    local building, level = placeOf(panel, unit)
    local targets = building and Water.fillTargets(panel, layout, outlet, building, level) or {}
    if #targets == 0 then return nil, "noTanks" end
    local free = roomIn(targets)
    if free < 0.05 then return nil, "full" end
    local filled = Networks.fillInto(panel, targets, math.min(WaterUnits.PUMP_RATE * minutes / 60, free), unit.fluid)
    if filled <= 0 then return nil, "full" end
    return true, nil, filled * 60 / minutes
end

-- A booster pump: water from its inlet pipe's tanks on its floor and below (and, on another pipe than its outlet's,
-- from its inlet's use network there, which reaches higher tanks and other buildings) up to its outlet pipe's tanks:
-- on the same pipe the floors above its own as far as it lifts, on another up to there from the lowest.
local function boost(panel, layout, unit, minutes, on)
    if not on then return nil, "noPower" end
    if panel.water.frozen then return nil, "frozen" end
    local inlet, outlet = Water.unitPipes(panel, unit)
    local building, level = placeOf(panel, unit)
    if not building then return nil, "noTanks" end
    local top = level + Water.boostFloors()
    local targets = Water.fillTargets(panel, layout, outlet, building, top, inlet == outlet and level + 1 or nil)
    local sources = Water.belowTargets(panel, layout, inlet, building, level)
    if inlet ~= outlet then sources[#sources + 1] = Water.useId(layout, inlet, building, level) end
    local drawn, mix, why = drawFor(panel, sources, targets, WaterUnits.BOOSTER_RATE * minutes / 60)
    if drawn <= 0 then return nil, why end
    fillMix(panel, targets, mix, false)
    return true, nil, drawn * 60 / minutes
end

-- A filter on two pipes: water from its inlet's use network into its outlet pipe's tanks on its floor and below,
-- tainted water made clean while the pipes leave water unpurified (the risk option), which takes media: spent, it
-- passes nothing then. Without the option it only passes water on (the pipes purify). It needs no power. Returns
-- running, why it idles, litres an hour, and the hours of media it used.
local function pass(panel, layout, unit, minutes, unpurified)
    if panel.water.frozen then return nil, "frozen" end
    if unpurified and (unit.media or 0) <= 0 then return nil, nil end
    local inlet, outlet = Water.unitPipes(panel, unit)
    local building, level = placeOf(panel, unit)
    if not building then return nil, "noTanks" end
    local targets = Water.fillTargets(panel, layout, outlet, building, level)
    local source = Water.useId(layout, inlet, building, level)
    local drawn, mix, why = drawFor(panel, { source }, targets, WaterUnits.FILTER_RATE * minutes / 60)
    if drawn <= 0 then return nil, why end
    fillMix(panel, targets, mix, unpurified)
    return true, nil, drawn * 60 / minutes, unpurified and minutes / 60 or 0
end

-- A filter's media used: its charge less so many hours; spent, the players are told.
local function wear(panel, unit, hours, pipe)
    if hours <= 0 then return false end
    local before = math.floor(WaterUnits.mediaLeft(unit) * 100)
    unit.media = math.max(0, (unit.media or 0) - hours)
    if unit.media <= 0 then Sync.notice(panel, "IGUI_BU_Notice_FilterSpent", BU.Panels.name(panel), Water.pipeName(panel, pipe)) end
    return math.floor(WaterUnits.mediaLeft(unit) * 100) ~= before
end

-- Each minute (so many of them): a panel's machines that work (BU.Units.working) move water, booster pumps first
-- (their outlets feed the floors above), then filters, then pumps. Pumps and booster pumps need the panel's power and
-- add to its load while they run (BU.Changes.setExtraLoad); its frozen pipes stop all three. A filter on one pipe
-- moves nothing: while the pipes leave water unpurified, that pipe's water is purified as long as one of its filters
-- has media, which wears by the hour (its other filters wait their turn); without the option the pipes purify and
-- filters rest. While a pump's square is loaded the water beside it is looked at again. Kinds that are off
-- (BU.enabled) stand still and draw nothing.
function WaterRun.machines(panel, minutes)
    local boosters, restedB = working(panel, "booster")
    local filters, restedF = working(panel, "filter")
    local pumps, restedP = working(panel, "pump")
    local changed = restedB or restedF or restedP
    local water = BU.enabled("water") and BU.waterAvailable()
    local loads = panel.extraLoads or {}
    if not water or (#boosters == 0 and #filters == 0 and #pumps == 0) then
        if loads.pumps then Changes.setExtraLoad(panel, "pumps", 0) end
        if loads.boosters then Changes.setExtraLoad(panel, "boosters", 0) end
        if changed then Sync.changed(panel.id) end
        return
    end
    local layout = Networks.waterLayout(panel)
    local on = powered(panel)
    local unpurified = WaterUnits.unpurifiedPipes()

    local lifting = 0
    local boosting = BU.enabled("booster")
    for _, unit in ipairs(boosters) do
        local running, why, moved = nil, nil, nil
        if boosting then running, why, moved = boost(panel, layout, unit, minutes, on) end
        changed = show(unit, running, why, moved) or changed
        if running then lifting = lifting + 1 end
    end
    Changes.setExtraLoad(panel, "boosters", lifting * WaterUnits.BOOSTER_LOAD)

    local purifying = {}
    local filtering = BU.enabled("filter")
    for _, unit in ipairs(filters) do
        local running, why, moved, used = nil, nil, nil, 0
        local inlet, outlet = Water.unitPipes(panel, unit)
        if filtering and inlet == outlet then
            running = unpurified and not purifying[inlet] and (unit.media or 0) > 0 and not panel.water.frozen or nil
            if running then purifying[inlet], used = true, minutes / 60 end
        elseif filtering then
            running, why, moved, used = pass(panel, layout, unit, minutes, unpurified)
        end
        changed = show(unit, running, why, moved) or changed
        changed = wear(panel, unit, used or 0, inlet) or changed
    end
    for _, pipe in ipairs(Water.pipes(panel)) do
        Networks.setPipePurify(panel, pipe.id, not unpurified or purifying[pipe.id] == true)
    end

    local pumping = 0
    local pumpsOn = BU.enabled("pump")
    local cell = getCell()
    for _, unit in ipairs(pumps) do
        local square = cell and cell:getGridSquare(unit.x, unit.y, unit.z)
        if square then
            local fluid = WaterUnits.waterBeside(square)
            if fluid ~= unit.fluid then unit.fluid, changed = fluid, true end
        end
        local running, why, moved = nil, nil, nil
        if pumpsOn then running, why, moved = pump(panel, layout, unit, minutes, on) end
        changed = show(unit, running, why, moved) or changed
        if running then pumping = pumping + 1 end
    end
    Changes.setExtraLoad(panel, "pumps", pumping * WaterUnits.PUMP_LOAD)
    if changed then Sync.changed(panel.id) end
end

-- Whether a plant is out in the open, where a sprinkler outside reaches it (and the rain does): its square as it is
-- when loaded, else as the farming system last saw it. One under a roof is beyond a wall from the sprinkler.
local function inTheOpen(plant)
    local square = plant.x and getCell():getGridSquare(plant.x, plant.y, plant.z)
    if square then return square:isOutside() end
    return plant.exterior ~= false
end

-- The water a plant wants now: none unless it grows out in the open and is below what it needs; then enough to bring
-- it to the middle of what it likes (as many uses of a watering can as that takes).
local function usesWanted(plant)
    if plant.state ~= "seeded" or not plant.waterLvl or not plant.waterNeeded then return 0 end
    if not inTheOpen(plant) then return 0 end
    if plant.waterLvl >= plant.waterNeeded then return 0 end
    local target = plant.waterNeededMax and (plant.waterNeeded + plant.waterNeededMax) / 2 or plant.waterNeeded + 10
    return math.ceil((math.min(100, target) - plant.waterLvl) / 10)
end

-- Each ten minutes: a panel's sprinklers water the growing crops out in the open around them that need it, from their pipe's use
-- network where they are, unless it rains or the tanks it reaches are empty. The farming system
-- keeps its plants whether or not their squares are loaded. Sprinklers that are off (BU.enabled) water nothing.
function WaterRun.sprinklers(panel)
    if not BU.enabled("sprinkler") or not BU.enabled("water") or not BU.waterAvailable() then return end
    local sprinklers = BU.Units.working(panel, "sprinkler")
    local system = SFarmingSystem and SFarmingSystem.instance
    if #sprinklers == 0 or not system or RainManager.isRaining() or panel.water.frozen then return end
    local now, changed = getGameTime():getWorldAgeHours(), false
    local layout = Networks.waterLayout(panel)
    for _, unit in ipairs(sprinklers) do
        local pipe = Water.unitPipes(panel, unit)
        local building, level = placeOf(panel, unit)
        local id = Water.useId(layout, pipe, building, level)
        local state = id and Networks.waterState(id)
        if state and (state.amount or 0) > 0 then
            local watered = false
            local reach = WaterUnits.SPRINKLER_RADIUS
            for dy = -reach, reach do
                for dx = -reach, reach do
                    local plant = system:getLuaObjectAt(unit.x + dx, unit.y + dy, unit.z)
                    local uses = plant and usesWanted(plant) or 0
                    if uses > 0 then
                        local drawn = Networks.drawFrom(panel, { id }, uses * WaterUnits.LITRES_PER_USE)
                        uses = math.floor(drawn / WaterUnits.LITRES_PER_USE + 1e-6)
                        if uses > 0 then
                            plant:water(nil, uses)
                            watered = true
                        end
                    end
                end
            end
            if watered then unit.sprayedAt, changed = now, true end
        end
    end
    if changed then Sync.changed(panel.id) end
end

-- Whether a fire sprinkler reaches a burning square: on its floor, within FIRE_RADIUS, in its room (a head in no room,
-- on a roof or in the open, reaches the squares of no room). The rooms themselves are compared: a room's id (a long)
-- comes to Lua as a double that two rooms of a cell can share.
local function reaches(unit, square)
    if square:getZ() ~= unit.z then return false end
    local radius = WaterUnits.FIRE_RADIUS
    if math.abs(square:getX() - unit.x) > radius or math.abs(square:getY() - unit.y) > radius then return false end
    local head = getCell():getGridSquare(unit.x, unit.y, unit.z)
    return head ~= nil and head:getRoom() == square:getRoom()
end

-- The square's fire goes, and that of whoever burns on it, as a fire extinguisher puts it out (ISPutOutFire).
local function putOut(square)
    if isServer() then stopFire(square) else square:stopFire() end
    local movers = square:getMovingObjects()
    for i = 0, movers:size() - 1 do
        local character = movers:get(i)
        if instanceof(character, "IsoGameCharacter") and character:isOnFire() then
            if isServer() then stopFire(character) else character:StopBurning() end
        end
    end
end

-- A fire sprinkler lets out FIRE_LITRES from its pipe's use network where it is onto a burning square: false while
-- that network holds less.
local function douse(panel, unit, square)
    local pipe = Water.unitPipes(panel, unit)
    local building, level = placeOf(panel, unit)
    local id = Water.useId(Networks.waterLayout(panel), pipe, building, level)
    local state = id and Networks.waterState(id)
    if not state or (state.amount or 0) < WaterUnits.FIRE_LITRES then return false end
    if Networks.drawFrom(panel, { id }, WaterUnits.FIRE_LITRES) <= 0 then return false end
    putOut(square)
    return true
end

-- Each minute (Server): the burning squares a working fire sprinkler reaches are put out, each by the first that has
-- the water, and those sprinklers spray a while (WaterUnits.spraying). Fires are only on loaded squares, and the game
-- keeps the burning ones in IsoFireManager.FireStack: with none, nothing is looked at. A fire sprinkler needs no power
-- (its heads open by the heat); its frozen pipes, or the feature off, put out nothing.
function WaterRun.fires()
    local stack = IsoFireManager.FireStack
    if not stack or stack:isEmpty() then return end
    if not BU.enabled("firesprinkler") or not BU.waterAvailable() then return end
    local heads = Store.unitList("firesprinkler")
    if #heads == 0 then return end
    local burning, seen = {}, {}
    for i = 0, stack:size() - 1 do
        local square = stack:get(i):getSquare()
        if square and square:has(IsoFlagType.burning) then
            local key = square:getX() .. "," .. square:getY() .. "," .. square:getZ()
            if not seen[key] then
                seen[key] = true
                burning[#burning + 1] = square
            end
        end
    end
    local working, now, changed = {}, getGameTime():getWorldAgeHours(), {}
    local function works(panel, unit)
        local set = working[panel.id]
        if not set then
            set = {}
            for _, each in ipairs(BU.Units.working(panel, "firesprinkler")) do set[each] = true end
            working[panel.id] = set
        end
        return set[unit] == true
    end
    for _, square in ipairs(burning) do
        for _, unit in ipairs(heads) do
            local panel = Store.get(unit.panel)
            if panel and reaches(unit, square) and not panel.water.frozen and works(panel, unit)
                and douse(panel, unit, square) then
                unit.sprayedAt, changed[panel.id] = now, true
                break
            end
        end
    end
    for id in pairs(changed) do Sync.changed(id) end
end

return WaterRun
