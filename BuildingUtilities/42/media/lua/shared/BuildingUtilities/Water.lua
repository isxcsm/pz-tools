-- A panel's water as networks of the API: the player's water groups (one at first), each a tree of one network per
-- floor. A floor's network is the child of the floor's above, so a fixture takes water from tanks on its floor and
-- the floors above it (the API gives a child its own producers and its ancestors'). Tanks join their floor's
-- network, or the one below with the sandbox's "water from above only" (as vanilla plumbing). The building's rooms
-- are in the first group's networks; a fixture moved to another group is included there and excluded from the first.
-- Booster pumps (Water.boostPlan) lift a group's water up from their floor: the floors they lift to take
-- the water of the tanks at the booster's height and above, their rooms joining that height's network.
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Store = BU.Store
local Water = {}
BU.Water = Water

Water.FIRST = 1
-- At most so many groups a panel: the window lists each.
Water.MAX_GROUPS = 4

function Water.aboveOnly() return BU.sandbox("WaterFromAboveOnly", false) == true end

-- Freezing (a risk, off by default): pipes freeze after FREEZE_HOURS below FREEZE_BELOW degrees at the box, and thaw
-- after THAW_HOURS above THAW_ABOVE.
Water.FREEZE_BELOW, Water.FREEZE_HOURS, Water.THAW_ABOVE, Water.THAW_HOURS = -5, 6, 0, 2
function Water.freezeEnabled() return BU.sandbox("RiskPipesFreeze", false) == true end

-- The temperature the box's pipes have: its square's air when loaded (a heated building is warmer), else outside.
function Water.pipeTemperature(panel)
    local climate = getClimateManager()
    local square = getCell():getGridSquare(panel.x, panel.y, panel.z)
    return square and climate:getAirTemperatureForSquare(square) or climate:getTemperature()
end

-- Floors a booster pump lifts water above its own (the sandbox's BoosterLift).
function Water.boostFloors() return BU.sandbox("BoosterLift", 10) end

-- The highest floor of a panel's group's tanks (Water.producerLevel), or nil without any.
local function topTank(panel, group)
    local top
    for _, at in ipairs(panel.water.producers) do
        if Water.producerGroup(at) == group then
            local level = Water.producerLevel(at)
            if not top or level > top then top = level end
        end
    end
    return top
end

-- What a panel's booster pumps of a group do: may(unit) tells whether one may run (the server asks whether it
-- may now, the layout whether it runs: unit.boosting). Lowest first, each that may runs where water reaches its floor (a tank of the group at its height or above,
-- or a lower booster lifting to it) and lifts that water the Water.boostFloors floors above its own. By floor, the
-- lowest height whose tanks reach it (only the floors a booster lifts to); by unit id, "running" or "dry" (it may run
-- but no water reaches it). Boosters that are off (BU.enabled) do nothing.
function Water.boostPlan(panel, group, may)
    local sources, states = {}, {}
    if not BU.enabled("booster") then return sources, states end
    local units = {}
    for _, unit in ipairs(Store.unitList("booster", panel.id)) do
        local own = unit.group
        if not (own and Water.group(panel, own)) then own = Water.FIRST end
        if own == group then units[#units + 1] = unit end
    end
    table.sort(units, function(a, b)
        if a.z ~= b.z then return a.z < b.z end
        return tostring(a.id) < tostring(b.id)
    end)
    local top, lift = topTank(panel, group), Water.boostFloors()
    for _, unit in ipairs(units) do
        if may(unit) then
            local from = sources[unit.z] or unit.z
            if top and top >= from then
                states[unit.id] = "running"
                for level = unit.z + 1, unit.z + lift do
                    if from < (sources[level] or level) then sources[level] = from end
                end
            else
                states[unit.id] = "dry"
            end
        end
    end
    return sources, states
end

-- What a panel's water networks take of its boosters: the running ones (unit.boosting) with their floors and
-- groups, and how far they lift, as one text; "" with none running.
function Water.boostKey(panel)
    local parts = {}
    if BU.enabled("booster") then
        for _, unit in ipairs(Store.unitList("booster", panel.id)) do
            if unit.boosting then
                parts[#parts + 1] = tostring(unit.id) .. "@" .. unit.z .. "g" .. tostring(unit.group or Water.FIRST)
            end
        end
    end
    if #parts == 0 then return "" end
    table.sort(parts)
    return table.concat(parts, ",") .. "+" .. Water.boostFloors()
end

-- The lowest of the levels at a height or above, or nil.
local function levelAbove(levels, z)
    for _, level in ipairs(levels) do
        if level >= z then return level end
    end
end

function Water.networkId(panel, group, level)
    return BU.networkId(panel.id, "water") .. "-g" .. group .. "-L" .. level
end

-- The panel's groups, in order.
function Water.groups(panel)
    return panel.water.groups
end

function Water.group(panel, id)
    for _, group in ipairs(Water.groups(panel)) do
        if group.id == id then return group end
    end
    return nil
end

function Water.groupName(panel, id)
    local group = Water.group(panel, id)
    if group and group.name and group.name ~= "" then return group.name end
    return getText("IGUI_BU_WaterGroup", id)
end

-- A tank's group, and the floor whose network it joins.
function Water.producerGroup(at) return at.group or Water.FIRST end
function Water.producerLevel(at) return Water.aboveOnly() and at.z - 1 or at.z end

-- A fixture's group, by any of its parts' keys.
function Water.deviceGroup(panel, keys)
    for _, key in ipairs(keys) do
        local group = panel.water.groupOf and panel.water.groupOf[key]
        if group and Water.group(panel, group) then return group end
    end
    return Water.FIRST
end

-- The networks the panel's water takes now: { id, group, level, parent (an id or nil), producers (a list of
-- { x, y, z }), rooms (the zone's rooms of that floor, in the first group) }, and by group the floors lowest first.
-- The floors hang each from the one above, so a fixture uses the tanks at its height and above; the rooms of a floor
-- its running boosters (unit.boosting) lift to join the network at the height the water comes from. The floors'
-- second result also has, by group, its boosters' heights by floor (boost).
function Water.layout(panel)
    -- Looked up here: BU.Panels requires the networks, which require this.
    local Panels = BU.Panels
    local building = Panels.building(panel)
    local roomsByLevel = {}
    for _, room in ipairs(Panels.rooms(building)) do
        if Panels.inZone(panel, room.id) then
            roomsByLevel[room.level] = roomsByLevel[room.level] or {}
            table.insert(roomsByLevel[room.level], room)
        end
    end
    -- The zone's floors, lowest first.
    local base = {}
    for level in pairs(roomsByLevel) do base[#base + 1] = level end
    if #base == 0 then base[1] = panel.z end
    local result, floors = {}, { boost = {} }
    for _, group in ipairs(Water.groups(panel)) do
        local seen, levels = {}, {}
        local function addLevel(level)
            if not seen[level] then seen[level] = true; levels[#levels + 1] = level end
        end
        for _, level in ipairs(base) do addLevel(level) end
        local producersByLevel = {}
        for _, at in ipairs(panel.water.producers) do
            if Water.producerGroup(at) == group.id then
                local level = Water.producerLevel(at)
                addLevel(level)
                producersByLevel[level] = producersByLevel[level] or {}
                table.insert(producersByLevel[level], { x = at.x, y = at.y, z = at.z })
            end
        end
        table.sort(levels)
        floors[group.id] = levels
        local sources = Water.boostPlan(panel, group.id, function(unit) return unit.boosting == true end)
        floors.boost[group.id] = sources
        -- The first group's rooms by the network they join: their floor's, or where boosters lift to it, the one at the
        -- height the water comes from.
        local roomsAt = {}
        if group.id == Water.FIRST then
            for level, rooms in pairs(roomsByLevel) do
                local from = sources[level]
                local at = from and from < level and levelAbove(levels, from) or level
                roomsAt[at] = roomsAt[at] or {}
                for _, room in ipairs(rooms) do table.insert(roomsAt[at], room) end
            end
        end
        for index, level in ipairs(levels) do
            local above = levels[index + 1]
            local parent = above and Water.networkId(panel, group.id, above) or nil
            result[#result + 1] = { id = Water.networkId(panel, group.id, level), group = group.id, level = level,
                parent = parent, producers = producersByLevel[level] or {}, rooms = roomsAt[level] or {} }
        end
    end
    return result, floors
end

-- The floors of a group's tree, lowest first; floors is Water.layout's second result when the caller has it.
function Water.levels(panel, group, floors)
    if not floors then floors = select(2, Water.layout(panel)) end
    return floors[group] or {}
end

-- The network at the lowest floor of a group: its tree's every tank is in its reach.
function Water.lowestId(panel, group, floors)
    local levels = Water.levels(panel, group, floors)
    return levels[1] and Water.networkId(panel, group, levels[1]) or nil
end

-- The network of a group at a height or the nearest above: its tree has the tanks at that height and above. Nil
-- when the group has no floor that high.
function Water.networkAbove(panel, group, z, floors)
    for _, level in ipairs(Water.levels(panel, group, floors)) do
        if level >= z then return Water.networkId(panel, group, level) end
    end
end

-- How water reaches a panel's floors (its first group's): those no
-- tank reaches (dry: none at their height or above, and no booster lifting to them) and those boosters lift to, each
-- as ranges { low, high } of floors next to each other, then the same by floor ("dry" or "boosted"). only: a set of
-- floors to tell of (the others are left out); all of them when nil. One layout of the panel.
function Water.floorSupply(panel, only)
    local _, floors = Water.layout(panel)
    local sources = floors.boost[Water.FIRST] or {}
    local top = topTank(panel, Water.FIRST)
    local dry, boosted, byLevel = {}, {}, {}
    local function add(ranges, level)
        local last = ranges[#ranges]
        if last and last[2] == level - 1 then last[2] = level else ranges[#ranges + 1] = { level, level } end
    end
    for _, level in ipairs(Water.levels(panel, Water.FIRST, floors)) do
        if not only or only[level] then
            local from = sources[level] or level
            if not top or from > top then
                add(dry, level)
                byLevel[level] = "dry"
            elseif from < level then
                add(boosted, level)
                byLevel[level] = "boosted"
            end
        end
    end
    return dry, boosted, byLevel
end

-- The network of a group a fixture on a floor joins: that floor's, else the nearest below, else the lowest; where a
-- booster lifts to the floor, the one at the height the water comes from.
function Water.networkFor(panel, group, z, floors)
    if not floors then floors = select(2, Water.layout(panel)) end
    local from = floors.boost and floors.boost[group] and floors.boost[group][z]
    if from and from < z then
        local id = Water.networkAbove(panel, group, from, floors)
        if id then return id end
    end
    local levels = Water.levels(panel, group, floors)
    local best = levels[1]
    for _, level in ipairs(levels) do
        if level <= z then best = level end
    end
    return best and Water.networkId(panel, group, best) or nil
end

return Water
