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
            for _, field in ipairs({ "excluded", "schedule", "timed", "groupOf" }) do
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
    Changes.syncAttached(panel)
    Sync.changed(panel.id)
    return true
end

-- Each box's zone kept to the floors it reaches (Panels.zoneInReach), as the world starts and when the sandbox's reach
-- changed in play (Changes.applyShape): one saved before the limit, or with a smaller one in the sandbox, loses the
-- rooms beyond and says so.
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

-- Everything a panel's lines took: its producers', its units' and its outside devices'. For giving back a share when
-- it is taken down.
function Changes.paidFor(panel)
    local total = {}
    for _, utility in ipairs(BU.UTILITIES) do
        for _, producer in ipairs(panel[utility].producers) do addPaid(total, producer.paid) end
        for _, paid in pairs(panel[utility].included) do addPaid(total, paid) end
    end
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do addPaid(total, unit.paid) end
    return total
end

-- Takes a panel away: its networks go, its producers are the game's again, its units are wired to nothing.
function Changes.remove(panel)
    local object = Panels.object(panel)
    if object then object:getSquare():transmitRemoveItemFromSquare(object) end
    Networks.remove(panel)
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do Changes.unwire(unit) end
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
        if BU.objectName(objects:get(i)) == sprite then return true end
    end
    return false
end

-- What a panel keeps about devices gone from their loaded squares (destroyed or picked up) goes, and their rules go
-- from the networks: an object put there later is another device. One it connected outside goes with its line.
local DEVICE_FIELDS = { "excluded", "included", "attached", "schedule", "timed", "groupOf" }
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

-- A unit put down; kept: what its item carried of the unit it was (Units.keep), or nil.
function Changes.installUnit(kind, square, sprite, kept)
    local object = IsoObject.new(square, sprite, nil, false)
    local unit = Store.newUnit(kind, square:getX(), square:getY(), square:getZ(), sprite)
    object:getModData()[Units.MODDATA] = unit.id
    local definition = Units.definition(kind)
    if definition.create then definition.create(unit, object, kept) end
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

-- A unit wired to nothing now: no panel, nothing paid, and nothing of how it last ran (a pump's running, a booster's
-- boosting, why it idled), so that its look and a later panel start from stopped.
function Changes.unwire(unit)
    unit.panel, unit.paid = nil, nil
    unit.running, unit.boosting, unit.idle = nil, nil, nil
end

-- A part of the load the box adds to its devices' (the API's extra load): "pumps", its water pumps running. The
-- network gets their sum when that differs from what it has.
function Changes.setExtraLoad(panel, part, load)
    panel.extraLoads = panel.extraLoads or {}
    panel.extraLoads[part] = load > 0 and load or nil
    local total = Networks.extraLoad(panel)
    local state = Networks.state(panel, "power")
    if state and math.abs(total - (state.extraLoad or 0)) > 0.0005 then Networks.setExtraLoad(panel, total) end
end

-- A panel's units changed: its network has the units' source or not. Without a bank nothing flows in or out of it.
function Changes.unitsChanged(panel)
    Networks.setProducers(panel, "power")
    if not BU.Energy.bank(panel) then panel.bankFlow = nil end
end

-- "Switch to solar", checked by the caller (BU.Energy.sourceOffer): the units' source takes the load, and the API
-- switches the generator in use off, on standby. The API tells the change ("producer"), and players hear of it.
function Changes.useSource(panel)
    Networks.setSource(panel, true, true)
    panel.sourceOn = true
    Sync.changed(panel.id)
end

-- Wired to a panel.
function Changes.connectUnit(unit, panel, paid)
    unit.panel, unit.paid = panel.id, paid or {}
    Changes.unitsChanged(panel)
    Sync.changed(panel.id)
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

-- Producers. A new one is used after those connected before.

function Changes.connectProducer(panel, utility, x, y, z, paid)
    table.insert(panel[utility].producers, { x = x, y = y, z = z, paid = paid })
    Networks.setProducers(panel, utility)
    Sync.changed(panel.id)
end

-- Disconnects the producer on a square; returns what its line took, or nil when it was none of the panel's.
function Changes.disconnectProducer(panel, utility, x, y, z)
    local list = panel[utility].producers
    for index, at in ipairs(list) do
        if at.x == x and at.y == y and at.z == z then
            table.remove(list, index)
            Networks.setProducers(panel, utility)
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

-- A device the box reaches (of its building, or outside with its line) supplied (the default) or cut (excluded): a
-- switch at the box, free. Kept under its key; a part's key a save may have is cleared.
local function setInside(panel, utility, device, connected)
    local data = panel[utility]
    for _, key in ipairs(device.keys) do
        if key ~= device.key and data.excluded[key] then
            data.excluded[key] = nil
            Networks.apply(panel, utility, key)
        end
    end
    data.excluded[device.key] = (not connected) or nil
    Networks.apply(panel, utility, device.key)
end

function Changes.setInside(panel, utility, device, connected)
    setInside(panel, utility, device, connected)
    Sync.changed(panel.id)
end

function Changes.setAllInside(panel, utility, connected)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        if device.inside and (device.state == "on") ~= connected and device.state ~= "other" then
            setInside(panel, utility, device, connected)
        end
    end
    Sync.changed(panel.id)
end

-- Every device of one room of the building at once ("" for those in no room).
function Changes.setRoomInside(panel, utility, roomId, connected)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        if device.inside and device.roomId == roomId and (device.state == "on") ~= connected and device.state ~= "other" then
            setInside(panel, utility, device, connected)
        end
    end
    Sync.changed(panel.id)
end

-- Devices in rooms built onto the panel's building (Panels.attached) are the box's as its building's are: connected
-- unless excluded, with no line. The API has them as single objects, so each is added to the networks (Networks.rule)
-- and kept in attached. One that is in no such room of the box's zone any more (the room was taken down, or left the
-- zone) is let go with what the box kept about it: at once when it is gone from its square, else when it has been
-- missing from the rooms for a while, as the game's region data of a world that has just loaded may lag. Asked each
-- minute, as the world starts, when the zone changes and by a window that sees one not added yet. Returns whether
-- anything changed.
local LET_GO = { "excluded", "schedule", "timed", "groupOf" }
local ATTACHED_GRACE_MS = 20000
local missingSince = {}

function Changes.syncAttached(panel)
    local building = Panels.building(panel)
    local spaces = building and Panels.attached(building)
    if not spaces then return false end
    local changed, now = false, getTimestampMs()
    for _, utility in ipairs(BU.utilities()) do
        local data = panel[utility]
        data.attached = data.attached or {}
        local found = {}
        if #spaces > 0 then
            -- From the built-on rooms' objects alone, as a rule; the building's devices for an object with a part
            -- elsewhere (Panels.attachedKeys).
            found = Panels.attachedKeys(panel, utility, building)
            if not found then
                found = {}
                for _, device in ipairs(Panels.devices(panel, utility)) do
                    if device.attached then found[device.key] = true end
                end
            end
        end
        for key in pairs(found) do
            missingSince[panel.id .. "|" .. utility .. "|" .. key] = nil
            if not data.attached[key] then
                data.attached[key] = true
                Networks.apply(panel, utility, key)
                changed = true
            end
        end
        local gone = {}
        for key in pairs(data.attached) do
            if not found[key] then
                local here = present(key)
                local slot = panel.id .. "|" .. utility .. "|" .. key
                if here == false then
                    gone[#gone + 1] = key
                elseif here then
                    missingSince[slot] = missingSince[slot] or now
                    if now - missingSince[slot] >= ATTACHED_GRACE_MS then gone[#gone + 1] = key end
                end
            end
        end
        for _, key in ipairs(gone) do
            missingSince[panel.id .. "|" .. utility .. "|" .. key] = nil
            data.attached[key] = nil
            for _, field in ipairs(LET_GO) do
                if data[field] then data[field][key] = nil end
            end
            Networks.apply(panel, utility, key)
            changed = true
        end
    end
    if changed then Sync.changed(panel.id) end
    return changed
end

-- A device outside any building wired or piped to the panel, supplied as its line is laid.
function Changes.includeOutside(panel, utility, device, paid)
    panel[utility].included[device.key] = paid or {}
    panel[utility].excluded[device.key] = nil
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
    for _, name in ipairs({ "excluded", "schedule", "timed", "groupOf" }) do
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

-- A new group, named (nil for its number); none past Water.MAX_GROUPS.
function Changes.addWaterGroup(panel, name)
    local data = panel.water
    if #data.groups >= Water.MAX_GROUPS then return nil end
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
            -- Its units work for the first group, those that are off too.
            for _, unit in ipairs(Store.unitList(nil, panel.id)) do
                if unit.group == id then unit.group = nil end
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

-- Features turned on or off in the sandbox (BU.enabled).

-- The features (BU.featureKey) the world was last brought to; nil before it started.
local appliedFeatures = nil

-- Brings the world to the features on now, once the sandbox changed them: the networks of a utility turned off go
-- (their producers are the game's again) and those of one turned on are defined from the save (Networks.applyFeatures);
-- each panel's power takes its units that are on as its source, and what is left of its bank (Changes.unitsChanged);
-- timers turn again; the boxes show it. What the save keeps stays, for when a
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
        if power then Changes.unitsChanged(panel) end
        if power then Changes.applyTimers(panel) end
        if BU.PanelLook then BU.PanelLook.show(panel) end
    end
    Sync.changed(nil)
    return true
end

-- The sandbox's values that shape where things reach and which floors water reaches (FloorReach and RangePerTier for
-- the zones' floors, WaterFromAboveOnly for the tanks' floors), and whether generators power things outside (the game's
-- AllowExteriorGenerator), as the world was last brought to them; nil before it started.
local appliedShape = nil

-- Brings the world to those values once the sandbox changed them in play: each box's zone kept to the floors it
-- reaches now (Changes.fitZones), each panel's water networks to the floors its tanks reach now, the devices whose
-- network changed with them (Networks.floorsChanged), the power devices connected outside given or refused power
-- (Networks.rule). Checked each minute, a text compared. The world's start, which fits the zones and defines
-- the networks as the values are, only takes them as applied (defined). Returns whether they changed.
function Changes.applyShape(defined)
    local key = BU.sandbox("FloorReach", 2) .. "/" .. BU.sandbox("RangePerTier", 50) .. "/" .. tostring(Water.aboveOnly())
        .. "/" .. tostring(BU.exteriorPower())
    if key == appliedShape then return false end
    appliedShape = key
    if defined then return false end
    BU.log("reach, water floors and outside power now:", key)
    Changes.fitZones()
    if BU.enabled("water") then
        for _, panel in ipairs(Store.list()) do Networks.floorsChanged(panel) end
    end
    if BU.enabled("power") then
        for _, panel in ipairs(Store.list()) do
            for thing in pairs(panel.power.included) do Networks.apply(panel, "power", thing) end
        end
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
    Sync.changed(panel.id)
end

-- The breaker: down by overload, up by a player at the box. Reset, it lets the power through unless the main switch
-- keeps it off.
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
-- again, and nothing switches it on; either way a tripped breaker stays down
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

-- The lever: the breaker and the main switch in one. Down, the box's power is off (Changes.setSwitchedOff); up, a
-- tripped breaker is reset and the power switched on again. The breaker's gauge stays where it cooled to.
function Changes.setLever(panel, up)
    if not up then
        Changes.setSwitchedOff(panel, true)
        return
    end
    local tripped = panel.tripped
    if tripped then
        panel.tripped = false
        Store.record(panel, "IGUI_BU_Log_Reset")
    end
    if panel.switchedOff then
        Changes.setSwitchedOff(panel, false)
    elseif tripped then
        Networks.applyEnabled(panel)
        Sync.changed(panel.id)
        Sync.sound(panel, "LightSwitch")
    end
end

-- The breaker's gauge (BU.Panels.breaker): told to players by steps of BREAKER_STEP, and as it is full or empty.
Changes.BREAKER_STEP = 0.02
local breakerTold = {}

function Changes.setBreaker(panel, gauge)
    gauge = math.max(0, math.min(1, gauge))
    panel.power.breaker = gauge < 1 and gauge or nil
    local told = breakerTold[panel.id] or 1
    if math.abs(told - gauge) >= Changes.BREAKER_STEP or (gauge >= 1 or gauge <= 0) and told ~= gauge then
        breakerTold[panel.id] = gauge
        Sync.changed(panel.id)
    end
end

return Changes
