-- What the water units (BU.WaterUnits) do, on the server: each minute a panel's boosters lift its water up the
-- floors, its pumps lift water into their groups while its power is on, and its filters wear while they purify; each
-- ten minutes its sprinklers water the crops around them. Server.lua calls these, with the panel's water layout
-- worked out once a minute (floors, Water.layout's second result) after the boosters, which may change it.
require "BuildingUtilities/Changes"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Store, Networks, Changes, Water, Sync, WaterUnits = BU.Store, BU.Networks, BU.Changes, BU.Water, BU.Sync,
    BU.WaterUnits
local WaterRun = {}
BU.WaterRun = WaterRun

-- Clears what a kind of unit that is off (BU.enabled) shows of its last run (a pump's running, a filter's working);
-- returns whether any had it.
local function rest(units, field)
    local changed = false
    for _, unit in ipairs(units) do
        if unit[field] then unit[field], changed = nil, true end
    end
    return changed
end

-- Whether a panel's power is on for its units: the box lets it through (Networks.powerAllowed) and it is supplied.
local function powered(panel)
    if not Networks.powerAllowed(panel) then return false end
    local state = Networks.state(panel, "power")
    return state ~= nil and state.supplied == true
end

-- How much more a group's tanks take, as last seen; nil while none is seen.
local function room(panel, group, floors)
    local state = Networks.groupState(panel, group, floors)
    if not state or (state.capacity or 0) <= 0 then return nil end
    return math.max(0, state.capacity - (state.amount or 0))
end

-- A pump's water: into its group, until that is full. The litres lifted, or 0 and why not ("noTanks", "full").
local function lift(panel, unit, litres, floors)
    local group = WaterUnits.group(unit)
    local free = room(panel, group, floors)
    if free == nil then return 0, "noTanks" end
    if free < 0.5 then return 0, "full" end
    local lifted = Networks.fill(panel, group, math.min(litres, free), unit.fluid, floors) or 0
    if lifted > 0 then return lifted end
    return 0, "full"
end

-- Each minute (so many of them): a panel's pumps run while it has power and their water has somewhere to go; running,
-- they add to its load (BU.Changes.setExtraLoad). Its frozen pipes stop them ("frozen"). A pump with no water beside
-- it cannot tell: it runs dry whenever it has power, drawing it and lifting nothing ("noWater"). While its square is
-- loaded the water beside it is looked at again. Pumps that are off (BU.enabled) stand still and draw nothing.
function WaterRun.pumps(panel, minutes, floors)
    local pumps = Store.unitList("pump", panel.id)
    if #pumps == 0 and not (panel.extraLoads and panel.extraLoads.pumps) then return end
    if not BU.enabled("pump") then
        Changes.setExtraLoad(panel, "pumps", 0)
        if rest(pumps, "running") then Sync.changed(panel.id) end
        return
    end
    local on = powered(panel)
    local running, changed = 0, false
    local cell = getCell()
    floors = floors or #pumps > 0 and select(2, Water.layout(panel)) or nil
    for _, unit in ipairs(pumps) do
        local square = cell and cell:getGridSquare(unit.x, unit.y, unit.z)
        if square then
            local fluid = WaterUnits.waterBeside(square)
            if fluid ~= unit.fluid then unit.fluid, changed = fluid, true end
        end
        local lifted, why, now = 0, "noPower", nil
        if on and panel.water.frozen then
            why = "frozen"
        elseif on and not unit.fluid then
            why, now = "noWater", true
        elseif on then
            lifted, why = lift(panel, unit, WaterUnits.PUMP_RATE * minutes / 60, floors)
            now = lifted > 0 or nil
        end
        if now ~= unit.running or why ~= unit.idle then unit.running, unit.idle, changed = now, why, true end
        if now then running = running + 1 end
    end
    Changes.setExtraLoad(panel, "pumps", running * WaterUnits.PUMP_LOAD)
    if changed then Sync.changed(panel.id) end
end

-- Each minute: a panel's boosters (Water.boostPlan) run while it has power and its pipes are not frozen, each
-- where water reaches its floor ("noWater" else); running, they add to its load. When what runs differs from what its
-- water networks were defined with (Networks.boostDefined: also after a booster was wired or taken away, or as the
-- world loaded), they follow (Networks.floorsChanged). Boosters that are off (BU.enabled) stand
-- still and draw nothing.
function WaterRun.boosters(panel)
    local boosters = Store.unitList("booster", panel.id)
    if #boosters == 0 and (Networks.boostDefined(panel) or "") == "" and not (panel.extraLoads and panel.extraLoads.boosters) then
        return
    end
    local enabled = BU.enabled("booster")
    local on = enabled and powered(panel)
    local frozen = panel.water.frozen == true
    local states = {}
    if on and not frozen then
        for _, group in ipairs(Water.groups(panel)) do
            local _, each = Water.boostPlan(panel, group.id, function() return true end)
            for id, state in pairs(each) do states[id] = state end
        end
    end
    local running, changed = 0, false
    for _, unit in ipairs(boosters) do
        local now = states[unit.id] == "running" or nil
        local why = nil
        if enabled and not now then why = (not on and "noPower") or (frozen and "frozen") or "noWater" end
        if now ~= unit.boosting or why ~= unit.idle then unit.boosting, unit.idle, changed = now, why, true end
        if now then running = running + 1 end
    end
    if Water.boostKey(panel) ~= (Networks.boostDefined(panel) or "") then Networks.floorsChanged(panel) end
    Changes.setExtraLoad(panel, "boosters", running * WaterUnits.BOOSTER_LOAD)
    if changed then Sync.changed(panel.id) end
end

-- The water a plant wants now: none unless it grows and is below what it needs; then enough to bring it to the middle
-- of what it likes (as many uses of a watering can as that takes).
local function usesWanted(plant)
    if plant.state ~= "seeded" or not plant.waterLvl or not plant.waterNeeded then return 0 end
    if plant.waterLvl >= plant.waterNeeded then return 0 end
    local target = plant.waterNeededMax and (plant.waterNeeded + plant.waterNeededMax) / 2 or plant.waterNeeded + 10
    return math.ceil((math.min(100, target) - plant.waterLvl) / 10)
end

-- Each ten minutes: a panel's sprinklers water the growing crops around them that need it, from their group, unless
-- it rains or the group is down to its reserve. The farming system keeps its plants whether or not their squares
-- are loaded. Sprinklers that are off (BU.enabled) water nothing.
function WaterRun.sprinklers(panel)
    if not BU.enabled("sprinkler") then return end
    local sprinklers = Store.unitList("sprinkler", panel.id)
    local system = SFarmingSystem and SFarmingSystem.instance
    if #sprinklers == 0 or not system or RainManager.isRaining() then return end
    local now, changed = getGameTime():getWorldAgeHours(), false
    local floors = select(2, Water.layout(panel))
    for _, unit in ipairs(sprinklers) do
        local group = WaterUnits.group(unit)
        local state = Networks.groupState(panel, group, floors)
        local reserve = Water.group(panel, group).reserve or 0
        if state and (state.capacity or 0) > 0 and (state.amount or 0) / state.capacity * 100 > reserve then
            local watered = false
            local reach = WaterUnits.SPRINKLER_RADIUS
            for dy = -reach, reach do
                for dx = -reach, reach do
                    local plant = system:getLuaObjectAt(unit.x + dx, unit.y + dy, unit.z)
                    local uses = plant and usesWanted(plant) or 0
                    if uses > 0 then
                        local drawn = Networks.draw(panel, group, unit.z, uses * WaterUnits.LITRES_PER_USE, floors) or 0
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

-- Each minute (so many of them): while the pipes leave water unpurified (the risk option), a group's water is purified
-- as long as one of its filters has media, and that one wears by the hour (a group's other filters wait their turn).
-- Without the option the pipes purify and filters rest. Filters that are off (BU.enabled) rest and purify nothing: with the option, the water stays as
-- the tanks hold it.
function WaterRun.filters(panel, minutes)
    local filters = Store.unitList("filter", panel.id)
    local changed = false
    if not BU.enabled("filter") then
        changed = rest(filters, "working")
        filters = {}
    end
    if not BU.enabled("water") or not BU.waterAvailable() then
        if changed then Sync.changed(panel.id) end
        return
    end
    local unpurified = WaterUnits.unpurifiedPipes()
    local filtering = {}
    for _, unit in ipairs(filters) do
        local group = WaterUnits.group(unit)
        local working = unpurified and not filtering[group] and (unit.media or 0) > 0
        -- For its look (WaterUnits.filterLook).
        unit.working = working or nil
        if working then
            filtering[group] = true
            local before = math.floor(WaterUnits.mediaLeft(unit) * 100)
            unit.media = math.max(0, unit.media - minutes / 60)
            if math.floor(WaterUnits.mediaLeft(unit) * 100) ~= before then changed = true end
            if unit.media <= 0 then Sync.notice(panel, "IGUI_BU_Notice_FilterSpent", BU.Water.groupName(panel, group)) end
        end
    end
    for _, group in ipairs(Water.groups(panel)) do
        local on = not unpurified or filtering[group.id] == true
        Networks.setGroupPurify(panel, group.id, on)
    end
    if changed then Sync.changed(panel.id) end
end

return WaterRun
