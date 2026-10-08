-- Every change to the boxes, where the world is decided: the server, or the game alone. Called from the server's
-- command handler and from the timed actions' complete, which run there. Each goes to the save, then to the API,
-- then to the players (BU.Sync). Callers have checked the rules (BU.Panels) and taken the costs (BU.Costs).
require "BuildingUtilities/Panels"
require "BuildingUtilities/Energy"
require "BuildingUtilities/Sync"
require "BuildingUtilities/Solar"
require "BuildingUtilities/Rack"
require "BuildingUtilities/WaterUnits"
require "BuildingUtilities/Networks"
local BU = BuildingUtilities
local Store, Networks, Panels, Units, Sync, Water = BU.Store, BU.Networks, BU.Panels, BU.Units, BU.Sync, BU.Water
local Changes = {}
BU.Changes = Changes

-- Puts a box on the square and starts its networks. In a large building, or one with boxes already, it takes the
-- free rooms of its floor, in a small one with more floors than it reaches those it reaches (Panels.defaultZone), and
-- says so.
function Changes.install(square, sprite)
    local building = Panels.buildingAt(square:getX(), square:getY(), square:getZ())
    local zone, reach
    if building then zone, reach = Panels.defaultZone(building, square:getZ()) end
    local object = IsoObject.new(square, sprite, nil, false)
    -- The mouse over it shows a summary (client/BuildingUtilities/Main.lua).
    object:setSpecialTooltip(true)
    local panel = Store.newPanel(square:getX(), square:getY(), square:getZ(), sprite)
    panel.rooms = zone
    object:getModData()[Panels.MODDATA] = panel.id
    square:AddTileObject(object)
    if isServer() then object:transmitCompleteItemToClients() end
    Networks.define(panel)
    BU.log("installed", panel.id, "at", panel.x, panel.y, panel.z)
    Sync.changed(panel.id)
    if zone then
        local count = 0
        for _ in pairs(zone) do count = count + 1 end
        if reach then
            local low, high = Panels.floorsInReach(panel, building)
            Sync.notice(panel, "IGUI_BU_Notice_ZonedReach", Panels.name(panel), count, BU.floorName(low), BU.floorName(high))
        else
            Sync.notice(panel, "IGUI_BU_Notice_Zoned", Panels.name(panel), count)
        end
    end
    return panel
end

-- The rooms a box takes: a list of room ids of its building, or nil for all of it (only for the building's one
-- box; the rooms of the floors it reaches where it does not reach them all). Rooms of another box's zone and of
-- floors it does not reach (Panels.reachesLevel) are left out; a zone keeps one room at least. Returns whether it
-- changed.
function Changes.setZone(panel, ids)
    local building = Panels.building(panel)
    if not building then return false end
    local zone
    if ids then
        local known, boxes = {}, Panels.ofBuilding(building.key)
        for _, room in ipairs(Panels.rooms(building)) do
            if Panels.reachesLevel(panel, room.level) then known[room.id] = true end
        end
        zone = {}
        local any = false
        for _, id in ipairs(ids) do
            if known[id] and not Panels.roomOwner(building.key, id, panel, boxes) then zone[id] = true; any = true end
        end
        if not any then return false end
    elseif #Panels.ofBuilding(building.key) > 1 then
        return false
    elseif not Panels.canTakeWhole(panel, building) then
        zone = {}
        for _, room in ipairs(Panels.rooms(building)) do
            if Panels.reachesLevel(panel, room.level) then zone[room.id] = true end
        end
    end
    return Changes.applyZone(panel, building, zone)
end

-- A zone checked as Changes.setZone does, to the save, the API and the players.
function Changes.applyZone(panel, building, zone)
    local before = panel.rooms
    panel.rooms = zone
    Networks.setZone(panel, before)
    -- The box forgets what it set for devices of rooms that left the zone: another box may take them, and an
    -- exclusion of any network keeps a device off (a fixture moved to another group is excluded from the first's).
    if zone then
        for _, utility in ipairs(BU.UTILITIES) do
            local data = panel[utility]
            local left = {}
            for _, field in ipairs({ "excluded", "essential", "schedule", "shed", "saving", "blackout", "timed", "groupOf" }) do
                for key in pairs(data[field] or {}) do
                    if not data.included[key] then
                        local x, y, z = BU.parseThing(key)
                        local at = x and Panels.buildingAt(x, y, z)
                        if at and at.key == building.key and not zone[at.roomId] then
                            data[field][key] = nil
                            left[key] = true
                        end
                    end
                end
            end
            for key in pairs(left) do Networks.apply(panel, utility, key) end
        end
    end
    Sync.changed(panel.id)
    return true
end

-- Each box's zone kept to the floors it reaches (Panels.zoneInReach), as the world starts: one saved before the limit,
-- or with a smaller one in the sandbox, loses the rooms beyond and says so.
function Changes.fitZones()
    for _, panel in ipairs(Store.list()) do
        local zone, changed = Panels.zoneInReach(panel)
        if changed then
            local building = Panels.building(panel)
            Changes.applyZone(panel, building, zone)
            local low, high = Panels.floorsInReach(panel, building)
            BU.log("zone of", panel.id, "kept to the floors it reaches")
            Sync.notice(panel, "IGUI_BU_Notice_ZoneReach", Panels.name(panel), BU.floorName(low), BU.floorName(high))
        end
    end
end

-- What lines took, added to a total.
local function addPaid(total, paid)
    if type(paid) ~= "table" then return end
    for itemType, count in pairs(paid) do total[itemType] = (total[itemType] or 0) + count end
end

-- The producers and units of other panels wired through a sub-panel (Panels.passesThrough): each { owner, utility,
-- producer } or { owner, unit }.
local function routesThrough(panel)
    local result = {}
    for _, owner in ipairs(Store.list()) do
        if owner ~= panel then
            for _, utility in ipairs(BU.UTILITIES) do
                for _, producer in ipairs(owner[utility].producers) do
                    if producer.via and Panels.passesThrough(producer.via, panel) then
                        result[#result + 1] = { owner = owner, utility = utility, producer = producer }
                    end
                end
            end
            for _, unit in ipairs(Store.unitList(nil, owner.id)) do
                if unit.via and Panels.passesThrough(unit.via, panel) then result[#result + 1] = { owner = owner, unit = unit } end
            end
        end
    end
    return result
end

-- Takes away the lines wired through a sub-panel that leaves its main panel: they no longer reach it. Returns what
-- they took.
local function cutRoutes(panel)
    local paid, owners = {}, {}
    local routes = routesThrough(panel)
    for _, route in ipairs(routes) do
        local owner = route.owner
        owners[owner] = owners[owner] or {}
        if route.unit then
            addPaid(paid, route.unit.paid)
            Changes.unwire(route.unit)
            owners[owner].units = true
        else
            addPaid(paid, route.producer.paid)
            local list = owner[route.utility].producers
            for index = #list, 1, -1 do
                if list[index] == route.producer then table.remove(list, index) end
            end
            owners[owner][route.utility] = true
        end
    end
    for owner, changed in pairs(owners) do
        for _, utility in ipairs(BU.UTILITIES) do
            if changed[utility] then Networks.setProducers(owner, utility) end
        end
        if changed.units then Changes.unitsChanged(owner) end
        Networks.applyLoss(owner)
        Sync.changed(owner.id)
    end
    if #routes > 0 then Sync.notice(panel, "IGUI_BU_Notice_RoutesCut", Panels.name(panel), #routes) end
    return paid
end

-- Everything a panel's lines took: its producers', its units', its outside devices', its own link's, its
-- sub-panels' links and the lines wired through it, which go with it. For giving back a share when it is taken down.
function Changes.paidFor(panel)
    local total = {}
    for _, utility in ipairs(BU.UTILITIES) do
        for _, producer in ipairs(panel[utility].producers) do addPaid(total, producer.paid) end
        for _, paid in pairs(panel[utility].included) do addPaid(total, paid) end
    end
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do addPaid(total, unit.paid) end
    addPaid(total, panel.parentPaid)
    for _, child in ipairs(Store.children(panel.id)) do addPaid(total, child.parentPaid) end
    for _, route in ipairs(routesThrough(panel)) do addPaid(total, (route.unit or route.producer).paid) end
    return total
end

-- Takes a panel away: its networks go, its producers are the game's again, its units are wired to nothing, the lines
-- wired through it go (Changes.paidFor gave them back), its sub-panels become main panels.
function Changes.remove(panel)
    local object = Panels.object(panel)
    if object then object:getSquare():transmitRemoveItemFromSquare(object) end
    cutRoutes(panel)
    Networks.remove(panel)
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do Changes.unwire(unit) end
    for _, child in ipairs(Store.children(panel.id)) do
        child.parent, child.parentPaid = nil, nil
        Networks.link(child)
    end
    Store.remove(panel.id)
    BU.log("removed", panel.id)
    Sync.changed(panel.id)
end

-- Whether the object a device key names is on its square; nil while the square is not loaded.
local function present(key)
    local x, y, z, sprite = BU.parseThing(key)
    local square = x and getCell():getGridSquare(x, y, z)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:getSpriteName() == sprite or (object:getSprite() and object:getSprite():getName() == sprite) then
            return true
        end
    end
    return false
end

-- What a panel keeps about devices gone from their loaded squares (destroyed or picked up) goes, and their rules go
-- from the networks: an object put there later is another device. One it connected outside goes with its line.
local DEVICE_FIELDS = { "excluded", "included", "essential", "schedule", "shed", "saving", "blackout", "timed", "groupOf" }
local function forgetGone(panel)
    local count = 0
    for _, utility in ipairs(BU.UTILITIES) do
        local data, gone = panel[utility], {}
        for _, field in ipairs(DEVICE_FIELDS) do
            for key in pairs(data[field] or {}) do
                if gone[key] == nil then gone[key] = present(key) == false end
            end
        end
        for key, isGone in pairs(gone) do
            if isGone then
                for _, field in ipairs(DEVICE_FIELDS) do
                    if data[field] then data[field][key] = nil end
                end
                Networks.apply(panel, utility, key)
                count = count + 1
            end
        end
    end
    if count > 0 then
        BU.log(panel.id, "forgot", count, "devices that are gone")
        Sync.changed(panel.id)
    end
end

-- A panel or unit whose object is gone from its loaded square (destroyed, or taken by other means) is removed too;
-- so are the panels' settings for devices that are gone.
function Changes.checkObjects()
    for _, panel in ipairs(Store.list()) do
        local square = getCell():getGridSquare(panel.x, panel.y, panel.z)
        if square and not Panels.object(panel) then
            BU.log("the box of", panel.id, "is gone")
            Changes.remove(panel)
        end
    end
    for _, unit in ipairs(Store.unitList()) do
        local square = getCell():getGridSquare(unit.x, unit.y, unit.z)
        if square and not Units.object(unit) then
            BU.log("unit", unit.id, "is gone")
            Changes.removeUnit(unit)
        end
    end
    for _, panel in ipairs(Store.list()) do forgetGone(panel) end
end

-- Units.

function Changes.installUnit(kind, square, sprite)
    local object = IsoObject.new(square, sprite, nil, false)
    local unit = Store.newUnit(kind, square:getX(), square:getY(), square:getZ(), sprite)
    object:getModData()[Units.MODDATA] = unit.id
    local definition = Units.definition(kind)
    if definition.create then definition.create(unit, object) end
    square:AddTileObject(object)
    if isServer() then object:transmitCompleteItemToClients() end
    BU.log("installed", kind, unit.id, "at", unit.x, unit.y, unit.z)
    Sync.changed(nil)
    return unit
end

-- Takes a unit away; returns what its line took (nil when it was wired to nothing). Players empty a rack first;
-- one destroyed takes its batteries with it.
function Changes.removeUnit(unit)
    local object = Units.object(unit)
    if object then object:getSquare():transmitRemoveItemFromSquare(object) end
    local panel, paid = Store.get(unit.panel), unit.paid
    Store.removeUnit(unit.id)
    BU.log("removed", unit.kind, unit.id)
    if panel then Changes.unitsChanged(panel) end
    Sync.changed(panel and panel.id)
    return paid
end

-- A part of the load the box adds to its devices' (the API's extra load): "charging" its bank from a generator,
-- "pumps" its water pumps running. The network gets their sum when that differs from what it has.
-- A unit wired to nothing now: no panel, nothing paid, no route, and nothing of how it last ran (a pump's running, a
-- booster's boosting, why it idled), so that its look and a later panel start from stopped.
function Changes.unwire(unit)
    unit.panel, unit.paid, unit.via = nil, nil, nil
    unit.running, unit.boosting, unit.idle = nil, nil, nil
end

function Changes.setExtraLoad(panel, part, load)
    panel.extraLoads = panel.extraLoads or {}
    panel.extraLoads[part] = load > 0 and load or nil
    local total = Networks.extraLoad(panel)
    local state = Networks.state(panel, "power")
    if state and math.abs(total - (state.extraLoad or 0)) > 0.0005 then Networks.setExtraLoad(panel, total) end
end

-- A panel's units changed: its network has the units' source or not, and its line may be another. Without a bank
-- nothing charges it, nothing flows in or out of it, and nothing is kept off for it.
function Changes.unitsChanged(panel)
    Networks.setProducers(panel, "power")
    Networks.applyLoss(panel)
    if not BU.Energy.bank(panel) then
        panel.bankFlow = nil
        Changes.setExtraLoad(panel, "charging", 0)
        if panel.quietCut then
            panel.quietCut = nil
            Networks.applyEnabled(panel)
        end
        Changes.unsave(panel)
    end
end

-- The bank low at tier 4: these devices off until it has charge again (Changes.unsave).
function Changes.save(panel, keys)
    local first = true
    for _ in pairs(panel.power.saving) do first = false end
    for _, key in ipairs(keys) do
        panel.power.saving[key] = true
        Networks.apply(panel, "power", key)
    end
    Sync.changed(panel.id)
    if first then Sync.notice(panel, "IGUI_BU_Notice_Saving", Panels.name(panel), #keys) end
end

function Changes.unsave(panel)
    local keys = {}
    for key in pairs(panel.power.saving) do keys[#keys + 1] = key end
    if #keys == 0 then return end
    panel.power.saving = {}
    for _, key in ipairs(keys) do Networks.apply(panel, "power", key) end
    Store.record(panel, "IGUI_BU_Log_Unsaved", { #keys })
    Sync.changed(panel.id)
end

-- A blackout: the panel's lights off (Panels.blackoutLights), or on again as they were.
function Changes.setBlackout(panel, on)
    local data = panel.power
    local keys = {}
    if on then
        for _, key in ipairs(Panels.blackoutLights(panel)) do
            data.blackout[key] = true
            keys[#keys + 1] = key
        end
    else
        for key in pairs(data.blackout) do keys[#keys + 1] = key end
        data.blackout = {}
    end
    for _, key in ipairs(keys) do Networks.apply(panel, "power", key) end
    Store.record(panel, on and "IGUI_BU_Log_Blackout" or "IGUI_BU_Log_BlackoutEnd", { #keys })
    Sync.changed(panel.id)
    Sync.sound(panel, "LightSwitch")
end

-- The charge controller's settings (BU.Energy.settings), checked by the caller.
function Changes.setController(panel, settings)
    panel.controller = settings
    Sync.changed(panel.id)
end

-- "Switch to solar", checked by the caller (BU.Energy.sourceOffer): the units' source takes the load, and the API
-- switches the generator in use off, on standby. The API tells the change ("producer"), and players hear of it.
function Changes.useSource(panel)
    Networks.setSource(panel, true, true)
    panel.sourceOn = true
    Sync.changed(panel.id)
end

-- Quiet hours with the bank empty: the panel's power off rather than a generator heard, and on again (unless its
-- breaker or main switch keeps it off).
function Changes.setQuietCut(panel, cut)
    panel.quietCut = cut or nil
    Networks.applyEnabled(panel)
    Sync.changed(panel.id)
    if cut then Sync.notice(panel, "IGUI_BU_Notice_QuietCut", Panels.name(panel)) end
end

-- Wired to a panel; to a sub-panel, it is its main panel's (Panels.root) through that one.
function Changes.connectUnit(unit, panel, paid)
    local root = Panels.root(panel)
    unit.panel, unit.paid, unit.via = root.id, paid or {}, root ~= panel and panel.id or nil
    Changes.unitsChanged(root)
    Sync.changed(root.id)
end

-- Its line taken away; returns what it took.
function Changes.disconnectUnit(unit)
    local panel, paid = Store.get(unit.panel), unit.paid or {}
    Changes.unwire(unit)
    if panel then Changes.unitsChanged(panel) end
    Sync.changed(panel and panel.id)
    return paid
end

function Changes.clearSnow(unit)
    unit.snow = nil
    Sync.changed(unit.panel)
end

-- Producers. A new one is used after those connected before. One connected to a sub-panel is its main panel's
-- (Panels.root), wired through the sub-panel (via, its id).

function Changes.connectProducer(panel, utility, x, y, z, paid)
    local root = Panels.root(panel)
    table.insert(root[utility].producers, { x = x, y = y, z = z, paid = paid, via = root ~= panel and panel.id or nil })
    Networks.setProducers(root, utility)
    Networks.applyLoss(root)
    Sync.changed(root.id)
end

-- Disconnects the producer on a square; returns what its line took, or nil when it was none of the panel's.
function Changes.disconnectProducer(panel, utility, x, y, z)
    local list = panel[utility].producers
    for index, at in ipairs(list) do
        if at.x == x and at.y == y and at.z == z then
            table.remove(list, index)
            Networks.setProducers(panel, utility)
            Networks.applyLoss(panel)
            Sync.changed(panel.id)
            return at.paid or {}
        end
    end
    return nil
end

-- Moves a producer up (-1) or down (+1) the order.
function Changes.moveProducer(panel, utility, index, delta)
    local list = panel[utility].producers
    local other = index + delta
    if not list[index] or other < 1 or other > #list then return end
    list[index], list[other] = list[other], list[index]
    Networks.setProducers(panel, utility)
    Sync.changed(panel.id)
end

-- Devices.

-- A device of the panel's building connected (the default) or excluded: a switch at the box, free. Kept under its
-- key; a part's key a save may have is cleared. Switched on by the player, the box no longer keeps it off for an
-- overload (it sheds again if it must).
local function setInside(panel, utility, device, connected)
    local data = panel[utility]
    for _, key in ipairs(device.keys) do
        if key ~= device.key and data.excluded[key] then
            data.excluded[key] = nil
            Networks.apply(panel, utility, key)
        end
    end
    data.excluded[device.key] = (not connected) or nil
    if connected and data.shed then data.shed[device.key] = nil end
    if connected and data.saving then data.saving[device.key] = nil end
    Networks.apply(panel, utility, device.key)
end

function Changes.setInside(panel, utility, device, connected)
    setInside(panel, utility, device, connected)
    Sync.changed(panel.id)
end

function Changes.setAllInside(panel, utility, connected)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        if device.inside and (device.state == "on") ~= connected then setInside(panel, utility, device, connected) end
    end
    Sync.changed(panel.id)
end

-- Every device of one room of the building at once ("" for those in no room).
function Changes.setRoomInside(panel, utility, roomId, connected)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        if device.inside and device.roomId == roomId and (device.state == "on") ~= connected then
            setInside(panel, utility, device, connected)
        end
    end
    Sync.changed(panel.id)
end

-- A device outside any building wired or piped to the panel.
function Changes.includeOutside(panel, utility, device, paid)
    panel[utility].included[device.key] = paid or {}
    Networks.apply(panel, utility, device.key)
    Sync.changed(panel.id)
end

-- Its line taken away; returns what it took, or nil when the panel had not connected it. What the panel kept about
-- it goes too, under any of its parts' keys: it is no device of the panel any longer.
function Changes.excludeOutside(panel, utility, device)
    local data = panel[utility]
    local paid
    for _, key in ipairs(device.keys) do
        if data.included[key] then
            paid = paid or data.included[key]
            data.included[key] = nil
            Networks.apply(panel, utility, key)
        end
    end
    if not paid then return nil end
    for _, name in ipairs({ "essential", "schedule", "shed", "saving", "blackout", "timed", "groupOf" }) do
        if data[name] then data[name][device.key] = nil end
    end
    Networks.apply(panel, utility, device.key)
    Sync.changed(panel.id)
    return type(paid) == "table" and paid or {}
end

-- Water groups (BU.Water): made, named and taken away by the player at the box; each tank and fixture in one.

local function groupName(name)
    name = name and tostring(name):sub(1, 30) or nil
    return name ~= "" and name or nil
end

-- A new group, named (nil for its number); none past Water.MAX_GROUPS, nor at a sub-panel.
function Changes.addWaterGroup(panel, name)
    local data = panel.water
    if panel.parent or #data.groups >= Water.MAX_GROUPS then return nil end
    local group = { id = data.nextGroup, name = groupName(name) }
    data.nextGroup = data.nextGroup + 1
    data.groups[#data.groups + 1] = group
    Networks.defineWater(panel, {})
    Sync.changed(panel.id)
    return group
end

function Changes.renameWaterGroup(panel, id, name)
    local group = Water.group(panel, id)
    if not group then return end
    group.name = groupName(name)
    Sync.changed(panel.id)
end

-- A group taken away: its tanks and fixtures go back to the first. The first stays.
function Changes.removeWaterGroup(panel, id)
    local data = panel.water
    if id == Water.FIRST then return end
    for index, group in ipairs(data.groups) do
        if group.id == id then
            table.remove(data.groups, index)
            for _, at in ipairs(data.producers) do
                if at.group == id then at.group = nil end
            end
            local keys = {}
            for key, group in pairs(data.groupOf) do
                if group == id then data.groupOf[key] = nil; keys[key] = true end
            end
            -- Its units work for the first group, those that are off too; no group overflows into it.
            for _, unit in ipairs(Store.unitList(nil, panel.id)) do
                if unit.group == id then unit.group = nil end
            end
            for _, other in ipairs(data.groups) do
                if other.overflow == id then other.overflow = nil end
            end
            data.levelLog[id] = nil
            Networks.defineWater(panel, keys)
            Sync.changed(panel.id)
            return
        end
    end
end

-- A water unit to work for a group of its panel.
function Changes.setUnitGroup(unit, id)
    local panel = Store.get(unit.panel)
    if not panel or not Water.group(panel, id) then return end
    unit.group = id ~= Water.FIRST and id or nil
    Sync.changed(panel.id)
end

-- How full a group's tanks stay for its people: sprinklers stop at this percent (0 for none).
function Changes.setGroupReserve(panel, id, percent)
    local group = Water.group(panel, id)
    if not group then return end
    percent = math.max(0, math.min(90, math.floor(tonumber(percent) or 0)))
    group.reserve = percent > 0 and percent or nil
    Sync.changed(panel.id)
end

-- Where a group's pumps send water once its tanks are full: another group, or nil to stop.
function Changes.setGroupOverflow(panel, id, target)
    local group = Water.group(panel, id)
    if not group or target == id or (target and not Water.group(panel, target)) then return end
    group.overflow = target
    Sync.changed(panel.id)
end

-- A filter's media replaced: a fresh charge.
function Changes.replaceMedia(unit)
    unit.media = BU.WaterUnits.FILTER_HOURS
    Sync.changed(unit.panel)
end

-- A tank into a group.
function Changes.setProducerGroup(panel, index, id)
    local at = panel.water.producers[index]
    if not at or not Water.group(panel, id) then return end
    at.group = id ~= Water.FIRST and id or nil
    Networks.defineWater(panel, {})
    Sync.changed(panel.id)
end

-- A fixture into a group, kept under its key; a part's key a save may have is cleared.
function Changes.setDeviceGroup(panel, device, id)
    if not Water.group(panel, id) then return end
    local groupOf = panel.water.groupOf
    for _, key in ipairs(device.keys) do
        if groupOf[key] then
            groupOf[key] = nil
            Networks.apply(panel, "water", key)
        end
    end
    groupOf[device.key] = id ~= Water.FIRST and id or nil
    Networks.apply(panel, "water", device.key)
    Sync.changed(panel.id)
end

-- The panel's pipes frozen or thawed: its water stops or flows again.
function Changes.setFrozen(panel, frozen)
    if (panel.water.frozen == true) == frozen then return end
    panel.water.frozen = frozen or nil
    Networks.setWaterEnabled(panel, not frozen)
    Sync.notice(panel, frozen and "IGUI_BU_Notice_Frozen" or "IGUI_BU_Notice_Thawed", Panels.name(panel))
end

-- A power device the box never sheds under overload, or one it may.
function Changes.setEssential(panel, key, essential)
    local data = panel.power
    data.essential[key] = essential or nil
    if essential and (data.shed[key] or data.saving[key]) then
        data.shed[key], data.saving[key] = nil, nil
        Networks.apply(panel, "power", key)
    end
    Sync.changed(panel.id)
end

-- A power device's timer (BU.SCHEDULES); applied at once.
function Changes.setSchedule(panel, key, schedule)
    panel.power.schedule[key] = schedule ~= "always" and schedule or nil
    Changes.applyTimers(panel)
    Sync.changed(panel.id)
end

-- Devices whose timer turned: off or on as their timer says now (always on below the tier with timers). Returns
-- how many changed.
function Changes.applyTimers(panel)
    local data, changed = panel.power, 0
    local timers = (panel.tier or 1) >= BU.TIMER_TIER
    local keys = {}
    for key in pairs(data.schedule) do keys[key] = true end
    for key in pairs(data.timed) do keys[key] = true end
    for key in pairs(keys) do
        local off = timers and not BU.scheduleOn(data.schedule[key])
        if (data.timed[key] == true) ~= off then
            data.timed[key] = off or nil
            Networks.apply(panel, "power", key)
            changed = changed + 1
        end
    end
    if changed > 0 then Sync.changed(panel.id) end
    return changed
end

-- Overload at a box that sheds: these devices off until there is room for them again. Each is kept with what it
-- drew (powers, by key), so that restoring them needs no look at the building's devices.
function Changes.shed(panel, keys, powers)
    for _, key in ipairs(keys) do
        panel.power.shed[key] = powers and powers[key] or true
        Networks.apply(panel, "power", key)
    end
    Sync.changed(panel.id)
    Sync.notice(panel, "IGUI_BU_Notice_Shed", Panels.name(panel), #keys)
end

function Changes.restore(panel, keys)
    for _, key in ipairs(keys) do
        panel.power.shed[key] = nil
        Networks.apply(panel, "power", key)
    end
    Store.record(panel, "IGUI_BU_Log_Restored", { #keys })
    Sync.changed(panel.id)
end

-- Sub-panels. A sub-panel's water hangs from its main panel's and freezes with it: pipes frozen before it was linked
-- thaw, and its cold or warm hours start again once it is a main panel again.

function Changes.link(child, parent, paid)
    child.parent, child.parentPaid = parent.id, paid or {}
    local water = child.water
    water.frozen, water.coldHours, water.warmHours = nil, nil, nil
    Networks.link(child)
    Networks.applyLoss(child)
    Sync.changed(child.id)
end

-- Its lines to the main panel taken away, and those wired through it; returns what they took.
function Changes.unlink(child)
    local paid = {}
    addPaid(paid, child.parentPaid)
    addPaid(paid, cutRoutes(child))
    child.parent, child.parentPaid = nil, nil
    Networks.link(child)
    Networks.applyLoss(child)
    Sync.changed(child.id)
    return paid
end

-- Features turned on or off in the sandbox (BU.enabled).

-- The features (BU.featureKey) the world was last brought to; nil before it started.
local appliedFeatures = nil

-- Brings the world to the features on now, once the sandbox changed them: the networks of a utility turned off go
-- (their producers are the game's again) and those of one turned on are defined from the save (Networks.applyFeatures);
-- each main panel's power takes its units that are on as its source, and what is left of its bank and charge
-- controller (Changes.unitsChanged); timers turn again; the boxes show it. What the save keeps stays, for when a
-- feature is on again. The world's start, which defines the networks as the features are, only takes them as applied
-- (defined). Returns whether they changed.
function Changes.applyFeatures(defined)
    local key = BU.featureKey()
    if key == appliedFeatures then return false end
    appliedFeatures = key
    if defined then return false end
    BU.log("features on:", key ~= "" and key or "none")
    Networks.applyFeatures()
    local power = BU.enabled("power")
    for _, panel in ipairs(Store.list()) do
        if power and not panel.parent then Changes.unitsChanged(panel) end
        if power then Changes.applyTimers(panel) end
        if BU.PanelLook then BU.PanelLook.show(panel) end
    end
    Sync.changed(nil)
    return true
end

-- The box itself.

function Changes.rename(panel, name)
    name = name and tostring(name):sub(1, 40) or nil
    panel.name = name ~= "" and name or nil
    Sync.changed(panel.id)
end

function Changes.upgrade(panel)
    panel.tier = math.min(BU.TIERS, (panel.tier or 1) + 1)
    Store.record(panel, "IGUI_BU_Log_Upgraded", { panel.tier })
    Changes.applyTimers(panel)
    Networks.applyLoss(panel)
    Sync.changed(panel.id)
end

-- The breaker: down by overload, up by a player at the box. Reset, it lets the power through unless the main switch
-- or a quiet-hours cut keeps it off.
function Changes.trip(panel)
    panel.tripped = true
    Networks.applyEnabled(panel)
    BU.log("tripped", panel.id)
    Sync.changed(panel.id)
    Sync.sound(panel, "GeneratorStopping")
    Sync.notice(panel, "IGUI_BU_Notice_Tripped", Panels.name(panel))
end

function Changes.resetBreaker(panel)
    panel.tripped = false
    Networks.applyEnabled(panel)
    Store.record(panel, "IGUI_BU_Log_Reset")
    Sync.changed(panel.id)
    Sync.sound(panel, "LightSwitch")
end

-- The main switch: all the box's power off or on, by a player at the box. Off, its generators stop until it is on
-- again, and nothing switches it on (quiet hours, the charge controller); either way a tripped breaker stays down
-- until it is reset.
function Changes.setSwitchedOff(panel, off)
    if (panel.switchedOff == true) == off then return end
    panel.switchedOff = off or nil
    Networks.applyEnabled(panel)
    BU.log(off and "switched off" or "switched on", panel.id)
    Sync.changed(panel.id)
    Sync.sound(panel, "LightSwitch")
    Sync.notice(panel, off and "IGUI_BU_Notice_SwitchedOff" or "IGUI_BU_Notice_SwitchedOn", Panels.name(panel))
end

return Changes
