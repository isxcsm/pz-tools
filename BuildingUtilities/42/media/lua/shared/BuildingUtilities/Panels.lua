-- The mod's rules, as questions: one breaker box per building; producers outside within a range of its outline; the
-- devices of its building connected unless excluded; devices near it, outside any building, connected only on their
-- own; another building's box as a sub-panel. Nothing here changes anything: BU.Changes does.
require "BuildingUtilities/Networks"
require "BuildingUtilities/Geometry"
local BU = BuildingUtilities
local Store, Networks, Geometry = BU.Store, BU.Networks, BU.Geometry
local Panels = {}
BU.Panels = Panels

Panels.MODDATA = "BuildingUtilitiesPanel"

-- The building of a square now, as the API describes it, or nil.
function Panels.buildingAt(x, y, z)
    local api = BU.api()
    return api and api.buildings.at(x, y, z) or nil
end

function Panels.building(panel) return Panels.buildingAt(panel.x, panel.y, panel.z) end

-- A building's rooms as plain tables: { name, level, rects = { { x, y, w, h } } }.
function Panels.rooms(building)
    local api = BU.api()
    local list = api and building and api.buildings.rooms(building.key)
    local result = {}
    if not list then return result end
    for i = 1, #list do
        local room = list[i]
        local rects = {}
        for j = 1, #room.rects do
            local rect = room.rects[j]
            rects[#rects + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        end
        result[#result + 1] = { name = room.name, level = room.level, rects = rects }
    end
    return result
end

-- The panel of a building, by its key, or nil.
function Panels.ofBuilding(key)
    for _, panel in ipairs(Store.list()) do
        local building = Panels.building(panel)
        if building and building.key == key then return panel end
    end
    return nil
end

-- The box object of a panel on its loaded square, or nil.
function Panels.object(panel)
    local square = getCell():getGridSquare(panel.x, panel.y, panel.z)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:getModData()[Panels.MODDATA] == panel.id then return object end
    end
    return nil
end

-- The panel a world object is the box of, or nil.
function Panels.ofObject(object)
    local id = object and object:getModData()[Panels.MODDATA]
    return id and Store.get(id) or nil
end

-- Whether a box can go on a square: inside a building that has none. Returns the building, or nil and a reason.
function Panels.canInstall(square)
    if not square then return nil, "noSquare" end
    if not BU.api() then return nil, "noApi" end
    local building = Panels.buildingAt(square:getX(), square:getY(), square:getZ())
    if not building then return nil, "notInBuilding" end
    if Panels.ofBuilding(building.key) then return nil, "hasPanel" end
    return building
end

-- What a box carries before its breaker trips.
function Panels.capacity(panel) return BU.capacity(panel.tier) end

-- Producers.

-- What a square can produce: "power" for a generator, "water" for a water container; with the object.
function Panels.producerOn(square)
    if not square then return nil end
    local generator = square:getGenerator()
    if generator then return "power", generator end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if BU.isWaterContainer(object) then return "water", object end
    end
    return nil
end

-- Steps from a square to a panel's building outline, or nil when the building is not known now.
function Panels.steps(panel, x, y)
    local building = Panels.building(panel)
    return building and Geometry.toBuilding(x, y, Panels.rooms(building)) or nil
end

-- The main panels a producer square can be connected to: within the producer range of their building's outline,
-- on a level of it or on the ground. Each with its distance.
function Panels.inProducerRange(x, y, z)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        if not panel.parent then
            local building = Panels.building(panel)
            if building and (z == 0 or z >= building.minLevel and z <= building.maxLevel) then
                local steps = Geometry.toBuilding(x, y, Panels.rooms(building))
                if steps and steps <= BU.producerRange() then
                    result[#result + 1] = { panel = panel, steps = steps, building = building }
                end
            end
        end
    end
    table.sort(result, function(a, b) return a.steps < b.steps end)
    return result
end

-- Whether a producer can be connected to a panel. True, or false and a reason.
function Panels.canConnectProducer(panel, utility, x, y, z)
    if panel.parent then return false, "isSubPanel" end
    if Store.producerOwner(x, y, z) then return false, "connectedElsewhere" end
    local square = getCell():getGridSquare(x, y, z)
    if square and Panels.producerOn(square) ~= utility then return false, "noProducer" end
    for _, candidate in ipairs(Panels.inProducerRange(x, y, z)) do
        if candidate.panel == panel then return true end
    end
    return false, "tooFar"
end

-- Devices.

-- The devices of a panel for one utility: those of its building (connected unless excluded) and those near it
-- outside any building (connected only when this panel added them; "other" when another panel did). An object that
-- covers several squares is one device, as the API switches it whole: its entry is that of its listed part with the
-- smallest key, which is its key; keys are all its parts'; power is what its parts draw together. Each has entry,
-- key, keys, power, inside and state ("on", "off" or "other": the player's choice), and for power: essential,
-- schedule (BU.SCHEDULES) and held ("shed" or "timer" while the box keeps it off on its own, or nil).
local function anyKey(set, keys)
    for _, key in ipairs(keys) do
        if set[key] then return set[key] end
    end
    return nil
end

local function inclusionOwner(utility, keys)
    for _, key in ipairs(keys) do
        local owner = Store.inclusionOwner(utility, key)
        if owner then return owner end
    end
    return nil
end

function Panels.devices(panel, utility)
    local api = BU.api()
    local building = Panels.building(panel)
    local result = {}
    if not api or not building then return result, false end
    local data = panel[utility]
    -- The listed parts by object: each part's key leads to its object's group.
    local groups, order, groupOf = {}, {}, {}
    local function collect(list, inside)
        for i = 1, list and #list or 0 do
            local entry = list[i]
            local key = BU.thingKey(entry.x, entry.y, entry.z, entry.sprite)
            local group = groupOf[key]
            if not group then
                local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
                local keys = object and BU.partKeys(object) or { key }
                group = { keys = keys, entries = {}, inside = inside }
                for _, part in ipairs(keys) do groupOf[part] = group end
                groupOf[key] = group
                order[#order + 1] = group
            end
            group.entries[#group.entries + 1] = { entry = entry, key = key }
        end
    end
    local inside, insideComplete = api.buildings.objects(building.key, utility)
    local outside, outsideComplete = api.buildings.near(building.key, BU.exteriorRange(), utility)
    collect(inside, true)
    collect(outside, false)
    for _, group in ipairs(order) do
        table.sort(group.entries, function(a, b) return a.key < b.key end)
        local first = group.entries[1]
        local power
        for _, part in ipairs(group.entries) do
            if part.entry.power then power = (power or 0) + part.entry.power end
        end
        local device = { entry = first.entry, key = first.key, keys = group.keys, power = power, inside = group.inside }
        if group.inside then
            device.state = anyKey(data.excluded, group.keys) and "off" or "on"
        else
            local owner = inclusionOwner(utility, group.keys)
            device.state = owner == panel and "on" or owner and "other" or "off"
        end
        if utility == "power" and device.state == "on" then
            device.essential = data.essential[device.key] == true
            device.schedule = data.schedule[device.key] or "always"
            device.held = data.shed[device.key] and "shed" or data.timed[device.key] and "timer" or nil
        end
        result[#result + 1] = device
    end
    return result, insideComplete and outsideComplete
end

-- Overload.

-- Whether a box sheds devices under overload before its breaker trips.
function Panels.sheds(panel) return BU.overloadEnabled() and (panel.tier or 1) >= BU.SMART_TIER end

-- Which devices a box sheds to draw less by at least excess: connected and on, not essential, the largest first, so
-- that few go off. Nil when shedding all it may does not do.
function Panels.shedPlan(panel, excess)
    local candidates = {}
    for _, device in ipairs(Panels.devices(panel, "power")) do
        local power = device.power or 0
        if device.state == "on" and not device.held and not device.essential and power > 0 then
            candidates[#candidates + 1] = { key = device.key, power = power }
        end
    end
    table.sort(candidates, function(a, b) return a.power > b.power end)
    local keys, total = {}, 0
    for _, candidate in ipairs(candidates) do
        if total >= excess - 1e-6 then break end
        keys[#keys + 1] = candidate.key
        total = total + candidate.power
    end
    if total < excess - 1e-6 then return nil end
    return keys
end

-- Which shed devices fit again within room: the smallest first.
function Panels.restorePlan(panel, room)
    local candidates = {}
    for _, device in ipairs(Panels.devices(panel, "power")) do
        if device.held == "shed" then candidates[#candidates + 1] = { key = device.key, power = device.power or 0 } end
    end
    table.sort(candidates, function(a, b) return a.power < b.power end)
    local keys, total = {}, 0
    for _, candidate in ipairs(candidates) do
        if total + candidate.power > room + 1e-6 then break end
        keys[#keys + 1] = candidate.key
        total = total + candidate.power
    end
    return keys
end

-- One device of a panel by the key of any of its parts, or nil.
function Panels.device(panel, utility, key)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        for _, part in ipairs(device.keys) do
            if part == key then return device end
        end
    end
    return nil
end

-- The panel and device entry for a world object, for the context menu: the panel of its building, or a panel in
-- whose outside range it stands. Nil when it is no device of a panel.
function Panels.deviceOf(object, utility)
    local square = object:getSquare()
    if not square then return nil end
    local sprite = object:getSprite() and object:getSprite():getName()
    if not sprite then return nil end
    local key = BU.thingKey(square:getX(), square:getY(), square:getZ(), sprite)
    for _, panel in ipairs(Store.list()) do
        local device = Panels.device(panel, utility, key)
        if device then return panel, device end
    end
    return nil
end

-- Sub-panels.

-- Steps between two panels' buildings, or nil when one is not known now.
function Panels.linkSteps(child, parent)
    local childBuilding, parentBuilding = Panels.building(child), Panels.building(parent)
    if not childBuilding or not parentBuilding then return nil end
    return Geometry.betweenBuildings(Panels.rooms(childBuilding), Panels.rooms(parentBuilding))
end

-- Whether a panel can take its supply from another: a main panel in another building within the sub-panel range
-- of its own, with no producers of its own, and not one of its own sub-panels. Returns true, or false and a reason.
function Panels.canLink(child, parent)
    if child == parent then return false, "self" end
    if child.parent then return false, "isSubPanel" end
    for _, utility in ipairs(BU.UTILITIES) do
        if #child[utility].producers > 0 then return false, "hasProducers" end
    end
    local above = parent
    while above do
        if above == child then return false, "cycle" end
        above = Store.get(above.parent)
    end
    local steps = Panels.linkSteps(child, parent)
    if not steps then return false, "noBuilding" end
    if steps > BU.subPanelRange() then return false, "tooFar" end
    return true
end

-- The panels a panel could take its supply from, nearest first, with their distances.
function Panels.linkCandidates(child)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        if panel ~= child and Panels.canLink(child, panel) then
            result[#result + 1] = { panel = panel, steps = Panels.linkSteps(child, panel) }
        end
    end
    table.sort(result, function(a, b) return a.steps < b.steps end)
    return result
end

-- Names.

-- The panel's name: the player's, or its building's largest room and a number among panels of the same name.
function Panels.name(panel)
    if panel.name and panel.name ~= "" then return panel.name end
    local base = Panels.autoName(panel)
    local count = 0
    for _, other in ipairs(Store.list()) do
        if not (other.name and other.name ~= "") and Panels.autoName(other) == base then
            count = count + 1
            if other == panel then break end
        end
    end
    return count > 1 and (base .. " " .. count) or base
end

function Panels.autoName(panel)
    local building = Panels.building(panel)
    local best, area = nil, 0
    for _, room in ipairs(Panels.rooms(building)) do
        local size = 0
        for _, rect in ipairs(room.rects) do size = size + rect.w * rect.h end
        if room.name and room.name ~= "" and size > area then best, area = room.name, size end
    end
    if best then return getText("IGUI_BU_PanelOf", BU.roomName(best)) end
    return getText("IGUI_BU_PanelDefault")
end

-- A place relative to a panel's building: "12 NE".
function Panels.where(panel, x, y)
    local building = Panels.building(panel)
    if not building then return "" end
    local steps = Geometry.toBuilding(x, y, Panels.rooms(building)) or 0
    local cx, cy = Geometry.centre(building)
    local point = Geometry.direction(cx, cy, x, y)
    return getText("IGUI_BU_Where", steps, point and getText("IGUI_BU_Dir_" .. point) or "")
end

return Panels
