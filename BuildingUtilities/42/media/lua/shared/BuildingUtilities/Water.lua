-- A panel's water as networks of the API: the player's water groups (one at first), each a tree of one network per
-- floor. A floor's network is the child of the floor's above, so a fixture takes water from tanks on its floor and
-- the floors above it (the API gives a child its own producers and its ancestors'). Tanks join their floor's
-- network, or the one below with the sandbox's "water from above only" (as vanilla plumbing). The building's rooms
-- are in the first group's networks; a fixture moved to another group is included there and excluded from the first.
-- A sub-panel has the first group only, and its top floor's network is the child of its main panel's first group at
-- the lowest floor, so it takes all of that group's water.
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

function Water.networkId(panel, group, level)
    return BU.networkId(panel.id, "water") .. "-g" .. group .. "-L" .. level
end

-- The panel's groups, in order.
function Water.groups(panel)
    if panel.parent then return { { id = Water.FIRST } } end
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
-- A main panel's floors hang each from the one above, so a fixture uses the tanks at its height and above. A
-- sub-panel has no tanks of its own (those wired through it are its main panel's): each of its floors hangs from its
-- main panel's first group at that height or the nearest above (Water.networkAbove), in whichever building; a floor
-- above all of them hangs from none and has no water (Water.dryFloors).
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
    local result, floors = {}, {}
    for _, group in ipairs(Water.groups(panel)) do
        local seen, levels = {}, {}
        local function addLevel(level)
            if not seen[level] then seen[level] = true; levels[#levels + 1] = level end
        end
        for _, level in ipairs(base) do addLevel(level) end
        local producersByLevel = {}
        if not panel.parent then
            for _, at in ipairs(panel.water.producers) do
                if Water.producerGroup(at) == group.id then
                    local level = Water.producerLevel(at)
                    addLevel(level)
                    producersByLevel[level] = producersByLevel[level] or {}
                    table.insert(producersByLevel[level], { x = at.x, y = at.y, z = at.z })
                end
            end
        end
        table.sort(levels)
        floors[group.id] = levels
        local main = panel.parent and Panels.root(panel)
        local mainFloors = main and main ~= panel and select(2, Water.layout(main)) or nil
        for index, level in ipairs(levels) do
            local above = levels[index + 1]
            local parent = above and Water.networkId(panel, group.id, above) or nil
            if panel.parent then
                parent = mainFloors and Water.networkAbove(main, Water.FIRST, level, mainFloors) or nil
            end
            result[#result + 1] = { id = Water.networkId(panel, group.id, level), group = group.id, level = level,
                parent = parent, producers = producersByLevel[level] or {},
                rooms = group.id == Water.FIRST and roomsByLevel[level] or {} }
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

-- A sub-panel's floors with no tank of its main panel at their height or above, so no water: the lowest and highest,
-- or nil when there are none (or the panel is a main panel).
function Water.dryFloors(panel)
    if not panel.parent then return nil end
    local main = BU.Panels.root(panel)
    if main == panel then return nil end
    local mainLevels = Water.levels(main, Water.FIRST)
    local top = mainLevels[#mainLevels]
    local low, high
    for _, level in ipairs(Water.levels(panel, Water.FIRST)) do
        if not top or level > top then
            low = low or level
            high = level
        end
    end
    return low, high
end

-- The network of a group a fixture on a floor joins: that floor's, else the nearest below, else the lowest.
function Water.networkFor(panel, group, z, floors)
    local levels = Water.levels(panel, group, floors)
    local best = levels[1]
    for _, level in ipairs(levels) do
        if level <= z then best = level end
    end
    return best and Water.networkId(panel, group, best) or nil
end

return Water
