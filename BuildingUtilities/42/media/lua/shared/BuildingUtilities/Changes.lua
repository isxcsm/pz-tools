-- Every change to the boxes, where the world is decided: the server, or the game alone. Called from the server's
-- command handler and from the timed actions' complete, which run there. Each goes to the save, then to the API,
-- then to the players (BU.Sync). Callers have checked the rules (BU.Panels) and taken the costs (BU.Costs).
require "BuildingUtilities/Panels"
require "BuildingUtilities/Energy"
require "BuildingUtilities/Sync"
local BU = BuildingUtilities
local Store, Networks, Panels, Units, Sync = BU.Store, BU.Networks, BU.Panels, BU.Units, BU.Sync
local Changes = {}
BU.Changes = Changes

-- Puts a box on the square and starts its networks. In a large building, or one with boxes already, it takes the
-- free rooms of its floor (Panels.defaultZone), and says so.
function Changes.install(square, sprite)
    local building = Panels.buildingAt(square:getX(), square:getY(), square:getZ())
    local zone = building and Panels.defaultZone(building, square:getZ())
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
        Sync.notice(panel, "IGUI_BU_Notice_Zoned", Panels.name(panel), count)
    end
    return panel
end

-- The rooms a box takes: a list of room ids of its building, or nil for all of it (only for the building's one
-- box). Rooms of another box's zone are left out; a zone keeps one room at least. Returns whether it changed.
function Changes.setZone(panel, ids)
    local building = Panels.building(panel)
    if not building then return false end
    local zone
    if ids then
        local known, boxes = {}, Panels.ofBuilding(building.key)
        for _, room in ipairs(Panels.rooms(building)) do known[room.id] = true end
        zone = {}
        local any = false
        for _, id in ipairs(ids) do
            if known[id] and not Panels.roomOwner(building.key, id, panel, boxes) then zone[id] = true; any = true end
        end
        if not any then return false end
    elseif #Panels.ofBuilding(building.key) > 1 then
        return false
    end
    local before = panel.rooms
    panel.rooms = zone
    Networks.setZone(panel, before)
    -- The box forgets what it set for devices of rooms that left the zone: another box may take them, and an
    -- exclusion of any network keeps a device off.
    if zone then
        for _, utility in ipairs(BU.UTILITIES) do
            local data = panel[utility]
            local left = {}
            for _, field in ipairs({ "excluded", "essential", "schedule", "shed", "saving", "blackout", "timed" }) do
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

-- Everything a panel's lines took: its producers', its units', its outside devices', its own link's and its
-- sub-panels' links, which go with it. For giving back a share when it is taken down.
function Changes.paidFor(panel)
    local total = {}
    local function add(paid)
        if type(paid) ~= "table" then return end
        for itemType, count in pairs(paid) do total[itemType] = (total[itemType] or 0) + count end
    end
    for _, utility in ipairs(BU.UTILITIES) do
        for _, producer in ipairs(panel[utility].producers) do add(producer.paid) end
        for _, paid in pairs(panel[utility].included) do add(paid) end
    end
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do add(unit.paid) end
    add(panel.parentPaid)
    for _, child in ipairs(Store.children(panel.id)) do add(child.parentPaid) end
    return total
end

-- Takes a panel away: its networks go, its producers are the game's again, its units are wired to nothing, its
-- sub-panels become main panels.
function Changes.remove(panel)
    local object = Panels.object(panel)
    if object then object:getSquare():transmitRemoveItemFromSquare(object) end
    Networks.remove(panel)
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do unit.panel, unit.paid = nil, nil end
    for _, child in ipairs(Store.children(panel.id)) do
        child.parent, child.parentPaid = nil, nil
        Networks.link(child)
    end
    Store.remove(panel.id)
    BU.log("removed", panel.id)
    Sync.changed(panel.id)
end

-- A panel or unit whose object is gone from its loaded square (destroyed, or taken by other means) is removed too.
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
end

-- Units.

-- A rack shows its batteries and their charge (Units.rackOverlay) while its square is loaded.
function Changes.showRack(unit, object)
    object = object or Units.object(unit)
    if not object or unit.kind ~= "rack" then return end
    local overlay = Units.rackOverlay(unit)
    local current = object:getOverlaySprite() and object:getOverlaySprite():getName() or nil
    if current ~= overlay then
        object:setOverlaySprite(overlay or "", isServer())
    end
end

-- A rack's records follow the batteries in its container: one put in gets a record from the item, one taken out
-- loses its record, and the others' items take what the bank made of their records (Units.writeBattery), so a
-- battery taken out has the charge and condition it had in the rack.
function Changes.syncRack(unit, object)
    object = object or Units.object(unit)
    if not object or unit.kind ~= "rack" then return end
    local items = Units.rackContainer(object):getAllTag(ItemTag.CAR_BATTERY, ArrayList.new())
    local known = {}
    for _, record in ipairs(unit.batteries) do
        if record.id then known[record.id] = record end
    end
    local batteries, changed = {}, #unit.batteries ~= items:size()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local record = known[item:getID()]
        if record then
            record.revived = item:getModData()[Units.REVIVED] or 0
            Units.writeBattery(item, record)
        else
            record = Units.batteryRecord(item)
            changed = true
        end
        batteries[#batteries + 1] = record
    end
    unit.batteries = batteries
    Changes.showRack(unit, object)
    if changed then Sync.changed(unit.panel) end
end

function Changes.installUnit(kind, square, sprite)
    local object = IsoObject.new(square, sprite, nil, false)
    local unit = Store.newUnit(kind, square:getX(), square:getY(), square:getZ(), sprite)
    object:getModData()[Units.MODDATA] = unit.id
    if kind == "rack" then Units.rackContainer(object) end
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

-- A panel's units changed: its network has the units' source or not, and its line may be another. Without a bank
-- nothing charges it, and nothing is kept off for it.
function Changes.unitsChanged(panel)
    Networks.setProducers(panel, "power")
    Networks.applyLoss(panel)
    if not BU.Energy.bank(panel) then
        Networks.setExtraLoad(panel, 0)
        if panel.quietCut then
            panel.quietCut = nil
            Networks.setEnabled(panel, not panel.tripped)
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

-- Quiet hours with the bank empty: the panel's power off rather than a generator heard, and on again.
function Changes.setQuietCut(panel, cut)
    panel.quietCut = cut or nil
    Networks.setEnabled(panel, not cut and not panel.tripped)
    Sync.changed(panel.id)
    if cut then Sync.notice(panel, "IGUI_BU_Notice_QuietCut", Panels.name(panel)) end
end

function Changes.connectUnit(unit, panel, paid)
    unit.panel, unit.paid = panel.id, paid or {}
    Changes.unitsChanged(panel)
    Sync.changed(panel.id)
end

-- Its line taken away; returns what it took.
function Changes.disconnectUnit(unit)
    local panel, paid = Store.get(unit.panel), unit.paid or {}
    unit.panel, unit.paid = nil, nil
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
    Networks.applyLoss(panel)
    Sync.changed(panel.id)
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
    for _, name in ipairs({ "essential", "schedule", "shed", "saving", "blackout", "timed" }) do
        if data[name] then data[name][device.key] = nil end
    end
    Networks.apply(panel, utility, device.key)
    Sync.changed(panel.id)
    return type(paid) == "table" and paid or {}
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

-- Overload at a box that sheds: these devices off until there is room for them again.
function Changes.shed(panel, keys)
    for _, key in ipairs(keys) do
        panel.power.shed[key] = true
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

-- Sub-panels.

function Changes.link(child, parent, paid)
    child.parent, child.parentPaid = parent.id, paid or {}
    Networks.link(child)
    Networks.applyLoss(child)
    Sync.changed(child.id)
end

-- Its lines to the main panel taken away; returns what they took.
function Changes.unlink(child)
    local paid = child.parentPaid or {}
    child.parent, child.parentPaid = nil, nil
    Networks.link(child)
    Networks.applyLoss(child)
    Sync.changed(child.id)
    return paid
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

-- The breaker: down by overload, up by a player at the box.
function Changes.trip(panel)
    panel.tripped = true
    Networks.setEnabled(panel, false)
    BU.log("tripped", panel.id)
    Sync.changed(panel.id)
    Sync.sound(panel, "GeneratorStopping")
    Sync.notice(panel, "IGUI_BU_Notice_Tripped", Panels.name(panel))
end

function Changes.resetBreaker(panel)
    panel.tripped = false
    Networks.setEnabled(panel, not panel.quietCut)
    Store.record(panel, "IGUI_BU_Log_Reset")
    Sync.changed(panel.id)
    Sync.sound(panel, "LightSwitch")
end

return Changes
