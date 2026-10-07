-- The mod's rules: one breaker box per building; producers outside within a range of its outline; the devices of its
-- building connected unless excluded; devices near it, outside any building, connected only on their own; another
-- building's box as a sub-panel. Each change goes to the save, then to the API.
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

-- A building's rooms as plain tables: { level, rects = { { x, y, w, h } } }.
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

-- Puts a box on the square and starts its networks. The caller has checked Panels.canInstall.
function Panels.install(square, sprite)
    local object = IsoObject.new(square, sprite, nil, false)
    local panel = Store.newPanel(square:getX(), square:getY(), square:getZ(), sprite)
    object:getModData()[Panels.MODDATA] = panel.id
    square:AddTileObject(object)
    Networks.define(panel)
    BU.log("installed", panel.id, "at", panel.x, panel.y, panel.z)
    return panel
end

-- Takes a panel away: its networks go, its producers are the game's again, its sub-panels become main panels.
function Panels.remove(panel)
    local object = Panels.object(panel)
    if object then object:getSquare():transmitRemoveItemFromSquare(object) end
    Networks.remove(panel)
    for _, child in ipairs(Store.children(panel.id)) do child.parent = nil end
    Store.remove(panel.id)
    BU.log("removed", panel.id)
end

-- A panel whose box is gone from its loaded square (destroyed, or taken by other means) is removed too.
function Panels.checkObjects()
    for _, panel in ipairs(Store.list()) do
        local square = getCell():getGridSquare(panel.x, panel.y, panel.z)
        if square and not Panels.object(panel) then
            BU.log("the box of", panel.id, "is gone")
            Panels.remove(panel)
        end
    end
end

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

-- Connects a producer; it is used after those connected before. False with a reason when it cannot be.
function Panels.connectProducer(panel, utility, x, y, z)
    if panel.parent then return false, "isSubPanel" end
    if Store.producerOwner(x, y, z) then return false, "connectedElsewhere" end
    table.insert(panel[utility].producers, { x = x, y = y, z = z })
    Networks.setProducers(panel, utility)
    return true
end

function Panels.disconnectProducer(panel, utility, index)
    table.remove(panel[utility].producers, index)
    Networks.setProducers(panel, utility)
end

-- Moves a producer up (-1) or down (+1) the order.
function Panels.moveProducer(panel, utility, index, delta)
    local list = panel[utility].producers
    local other = index + delta
    if other < 1 or other > #list then return end
    list[index], list[other] = list[other], list[index]
    Networks.setProducers(panel, utility)
end

-- Devices.

-- The devices of a panel for one utility: those of its building (connected unless excluded) and those near it
-- outside any building (connected only when this panel added them; "other" when another panel did). Each is an
-- entry of buildings.objects or buildings.near with key, inside and state ("on", "off" or "other").
function Panels.devices(panel, utility)
    local api = BU.api()
    local building = Panels.building(panel)
    local result, complete = {}, true
    if not api or not building then return result, false end
    local inside, insideComplete = api.buildings.objects(building.key, utility)
    local outside, outsideComplete = api.buildings.near(building.key, BU.exteriorRange(), utility)
    complete = insideComplete and outsideComplete
    for i = 1, inside and #inside or 0 do
        local entry = inside[i]
        local key = BU.thingKey(entry.x, entry.y, entry.z, entry.sprite)
        result[#result + 1] = { entry = entry, key = key, inside = true,
            state = panel[utility].excluded[key] and "off" or "on" }
    end
    for i = 1, outside and #outside or 0 do
        local entry = outside[i]
        local key = BU.thingKey(entry.x, entry.y, entry.z, entry.sprite)
        local owner = Store.inclusionOwner(utility, key)
        local state = owner == panel and "on" or owner and "other" or "off"
        result[#result + 1] = { entry = entry, key = key, inside = false, state = state }
    end
    return result, complete
end

-- Connects or disconnects one device. An outside device connected to another panel is refused.
function Panels.setDevice(panel, utility, device, connected)
    local x, y, z, sprite = device.entry.x, device.entry.y, device.entry.z, device.entry.sprite
    local lists = panel[utility]
    if device.inside then
        lists.excluded[device.key] = (not connected) or nil
        Networks.device(panel, utility, connected and "reset" or "exclude", x, y, z, sprite)
    else
        local owner = Store.inclusionOwner(utility, device.key)
        if connected and owner and owner ~= panel then return false, "connectedElsewhere" end
        lists.included[device.key] = connected or nil
        Networks.device(panel, utility, connected and "include" or "reset", x, y, z, sprite)
    end
    device.state = connected and "on" or "off"
    return true
end

-- Connects or disconnects every device of its building.
function Panels.setAllInside(panel, utility, connected)
    local devices = Panels.devices(panel, utility)
    for _, device in ipairs(devices) do
        if device.inside and (device.state == "on") ~= connected then Panels.setDevice(panel, utility, device, connected) end
    end
end

-- The panel and device entry for a world object, for the context menu: the panel of its building, or a panel in
-- whose outside range it stands. Nil when it is no device of a panel.
function Panels.deviceOf(object, utility)
    local square = object:getSquare()
    if not square then return nil end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local sprite = object:getSprite() and object:getSprite():getName()
    if not sprite then return nil end
    local key = BU.thingKey(x, y, z, sprite)
    for _, panel in ipairs(Store.list()) do
        for _, device in ipairs(Panels.devices(panel, utility)) do
            if device.key == key then return panel, device end
        end
    end
    return nil
end

-- Sub-panels.

-- Whether a panel can take its supply from another: a main panel in another building within the sub-panel range
-- of its own, with no producers of its own, and not one of its own sub-panels. Returns true, or false and a reason.
function Panels.canLink(child, parent)
    if child == parent then return false, "self" end
    for _, utility in ipairs(BU.UTILITIES) do
        if #child[utility].producers > 0 then return false, "hasProducers" end
    end
    local above = parent
    while above do
        if above == child then return false, "cycle" end
        above = Store.get(above.parent)
    end
    local childBuilding, parentBuilding = Panels.building(child), Panels.building(parent)
    if not childBuilding or not parentBuilding then return false, "noBuilding" end
    local steps = Geometry.betweenBuildings(Panels.rooms(childBuilding), Panels.rooms(parentBuilding))
    if not steps or steps > BU.subPanelRange() then return false, "tooFar" end
    return true
end

-- The panels a panel could take its supply from, nearest first, with their distances.
function Panels.linkCandidates(child)
    local result = {}
    local childBuilding = Panels.building(child)
    if not childBuilding then return result end
    local childRooms = Panels.rooms(childBuilding)
    for _, panel in ipairs(Store.list()) do
        if panel ~= child and Panels.canLink(child, panel) then
            local building = Panels.building(panel)
            result[#result + 1] = { panel = panel, building = building,
                steps = Geometry.betweenBuildings(childRooms, Panels.rooms(building)) }
        end
    end
    table.sort(result, function(a, b) return a.steps < b.steps end)
    return result
end

function Panels.link(child, parent)
    local ok, reason = Panels.canLink(child, parent)
    if not ok then return false, reason end
    child.parent = parent.id
    Networks.link(child)
    return true
end

function Panels.unlink(child)
    child.parent = nil
    Networks.link(child)
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
