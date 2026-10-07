-- Where the world is decided (the server, or the game alone): the networks from the save as the world starts, the
-- players' commands, breakers that trip under overload, what players near a box should hear, and each minute the
-- units (solar panels, the bank and its charge controller) and the water units (BU.WaterRun), with the records the
-- window shows.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Moveables"
require "BuildingUtilities/WaterRun"
local BU = BuildingUtilities
local Store, Panels, Networks, Changes, Sync, Energy = BU.Store, BU.Panels, BU.Networks, BU.Changes, BU.Sync, BU.Energy

-- Commands: the free changes a player makes at a box. Each names the panel; the rest is checked here.
local commands = {}

function commands.setInside(player, panel, args)
    local device = Panels.device(panel, args.utility, args.key)
    if device and device.inside then Changes.setInside(panel, args.utility, device, args.on == true) end
end

function commands.setAllInside(player, panel, args) Changes.setAllInside(panel, args.utility, args.on == true) end

-- The box's zone: a list of room ids, or the whole building.
function commands.setZone(player, panel, args)
    if args.whole == true then Changes.setZone(panel, nil); return end
    if type(args.rooms) ~= "table" then return end
    local ids = {}
    for _, id in ipairs(args.rooms) do
        if type(id) == "string" then ids[#ids + 1] = id end
    end
    Changes.setZone(panel, ids)
end

function commands.setRoomInside(player, panel, args)
    if type(args.room) == "string" then Changes.setRoomInside(panel, args.utility, args.room, args.on == true) end
end

function commands.moveProducer(player, panel, args)
    Changes.moveProducer(panel, args.utility, tonumber(args.index) or 0, args.delta == -1 and -1 or 1)
end

function commands.rename(player, panel, args) Changes.rename(panel, args.name) end

function commands.setBlackout(player, panel, args) Changes.setBlackout(panel, args.on == true) end

-- The charge controller's settings, from its choices (Energy.CHOICES).
function commands.setController(player, panel, args)
    if (panel.tier or 1) < BU.CONTROLLER_TIER then return end
    local settings = Energy.settings(panel)
    for name in pairs(Energy.DEFAULTS) do
        if type(args[name]) == "number" then settings[name] = args[name] end
    end
    if Energy.validSettings(settings) then Changes.setController(panel, settings) end
end

-- Water groups: by their ids, checked by Changes; a fixture only while the panel connects it.
function commands.addWaterGroup(player, panel, args) Changes.addWaterGroup(panel, args.name) end
function commands.renameWaterGroup(player, panel, args) Changes.renameWaterGroup(panel, tonumber(args.group), args.name) end
function commands.removeWaterGroup(player, panel, args) Changes.removeWaterGroup(panel, tonumber(args.group)) end

function commands.setProducerGroup(player, panel, args)
    Changes.setProducerGroup(panel, tonumber(args.index) or 0, tonumber(args.group))
end

function commands.setDeviceGroup(player, panel, args)
    local device = type(args.key) == "string" and Panels.device(panel, "water", args.key)
    if device and device.state == "on" then Changes.setDeviceGroup(panel, device, tonumber(args.group)) end
end

-- A water unit of the panel to work for one of its groups; a group's reserve and overflow.
function commands.setUnitGroup(player, panel, args)
    local unit = BU.Store.unit(args.unit)
    if unit and unit.panel == panel.id then Changes.setUnitGroup(unit, tonumber(args.group)) end
end

function commands.setGroupReserve(player, panel, args)
    Changes.setGroupReserve(panel, tonumber(args.group), tonumber(args.percent))
end

function commands.setGroupOverflow(player, panel, args)
    Changes.setGroupOverflow(panel, tonumber(args.group), tonumber(args.target))
end

function commands.resetBreaker(player, panel, args)
    if panel.tripped then Changes.resetBreaker(panel) end
end

-- A power device of the panel that it connects (its building's, or one it wired outside).
local function connectedDevice(panel, key)
    local device = type(key) == "string" and Panels.device(panel, "power", key)
    return device and device.state == "on" and device or nil
end

function commands.setEssential(player, panel, args)
    if connectedDevice(panel, args.key) then Changes.setEssential(panel, args.key, args.on == true) end
end

function commands.setSchedule(player, panel, args)
    local known = false
    for _, schedule in ipairs(BU.SCHEDULES) do known = known or schedule == args.schedule end
    if known and (panel.tier or 1) >= BU.TIMER_TIER and connectedDevice(panel, args.key) then
        Changes.setSchedule(panel, args.key, args.schedule)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= BU.MOD or not commands[command] or type(args) ~= "table" then return end
    if args.utility ~= nil and args.utility ~= "power" and args.utility ~= "water" then return end
    local panel = Store.get(args.panel)
    if panel then commands[command](player, panel, args) end
end

-- Whether a set has anything in it. (Kahlua has no next.)
local function any(set)
    for _ in pairs(set) do return true end
    return false
end

-- Overload: a box whose power network draws more than it carries trips its breaker; one that sheds first turns off
-- devices that are not essential, if that is enough, and turns them on again when there is room. The room last
-- tried, by panel: restoring is tried again once it is another.
local restoreTried = {}

local function checkLoad(panel)
    local shed = panel.power.shed
    if not Panels.sheds(panel) and any(shed) then
        local keys = {}
        for key in pairs(shed) do keys[#keys + 1] = key end
        Changes.restore(panel, keys)
    end
    if not BU.overloadEnabled() or panel.tripped then return end
    local state = Networks.state(panel, "power")
    if not (state and state.supplied and state.load) then return end
    -- The load counts what the line loses; a device takes that much more of it.
    local capacity, factor = Panels.capacity(panel), math.max(state.loadFactor or 1, 1e-6)
    if state.load > capacity + 1e-6 then
        local keys, powers
        if Panels.sheds(panel) then keys, powers = Panels.shedPlan(panel, (state.load - capacity) / factor) end
        if keys then Changes.shed(panel, keys, powers) else Changes.trip(panel) end
    elseif any(shed) then
        local room = (capacity - state.load) / factor
        local tried = restoreTried[panel.id]
        if tried == nil or math.abs(tried - room) > 1e-6 then
            restoreTried[panel.id] = room
            local keys = Panels.restorePlan(panel, room)
            if #keys > 0 then Changes.restore(panel, keys) end
        end
    end
end

-- What players hear: the generator in use changed (and the relay's click), power or water ran out, fuel runs low.
local lowFuel = {}

local function checkFuel(panel)
    if panel.parent then return end
    local state = Networks.state(panel, "power")
    local hours = state and state.supplied and state.hoursLeft
    if hours and hours < BU.lowFuelHours() then
        if not lowFuel[panel.id] then
            lowFuel[panel.id] = true
            Sync.notice(panel, "IGUI_BU_Notice_LowFuel", Panels.name(panel), math.floor(hours + 0.5))
        end
    elseif not hours or hours > BU.lowFuelHours() + 1 then
        lowFuel[panel.id] = nil
    end
end

-- Tier 4 keeps its bank: while the bank carries the load and is below the protect setting, the devices that are not
-- essential are off ("saving"), until it is 5% above it or something else carries the load. The devices are looked
-- at once, and again only after the network's load changed (a device switched on: onNetworkChange).
local savingLooked = {}

local function checkSaving(panel, state, bank, output, rules)
    local onBank = bank ~= nil and Energy.inUse(state) and state.supplied
    local protect = rules.settings.protect / 100
    if (panel.tier or 1) >= BU.SMART_TIER and onBank and output < rules.load and bank.charge < protect then
        if savingLooked[panel.id] then return end
        savingLooked[panel.id] = true
        local keys = {}
        for _, device in ipairs(Panels.devices(panel, "power")) do
            if device.state == "on" and not device.held and not device.essential and (device.power or 0) > 0 then
                keys[#keys + 1] = device.key
            end
        end
        if #keys > 0 then Changes.save(panel, keys) end
        return
    end
    savingLooked[panel.id] = nil
    if any(panel.power.saving) and (not onBank or bank.charge >= protect + 0.05) then Changes.unsave(panel) end
end

-- The units' source of a main panel over so many hours (Energy.run): available while its solar panels or its bank
-- carry the load. It is switched on when it can and the network has no supply: nothing ran, or the player switched
-- the generator in use off. Below tier 3 a generator the player runs keeps running; a charge controller (tier 3)
-- takes the load back from it once the bank is charged to its stop setting, charges the bank from it meanwhile, and
-- in quiet hours switches the power off rather than let a generator start. What the bank and the solar panels came to
-- this minute, by panel, for the energy record: { bank, output }.
local thisMinute = {}

local function checkSource(panel, hours)
    if not Energy.hasSource(panel) then return end
    local state = Networks.state(panel, "power")
    if not state then return end
    local source = Energy.sourceState(state)
    local inUse = Energy.inUse(state)
    -- The source carried the load when last seen and nothing does now: the world was loaded again (the source is
    -- defined off), or a quiet cut ended. It counts as available, and goes on again below; if it cannot carry the
    -- load, it is switched on for this minute so that the API hands over to a generator in the next.
    local lost = panel.sourceOn and not inUse and not state.supplied and state.enabled and not panel.tripped
    local available = source ~= nil and source.available == true or lost == true
    local rules = Energy.rules(panel, state)
    local can, bank, output = Energy.run(panel, state, hours, available, rules)
    thisMinute[panel.id] = { bank = bank, output = output }
    if panel.tripped then
        -- Charging would count in the load the breaker carries: none while it is down.
        Changes.setExtraLoad(panel, "charging", 0)
        return
    end
    local controller = (panel.tier or 1) >= BU.CONTROLLER_TIER
    local ready = Energy.canCarry(output, rules.load, false) or (bank ~= nil and bank.usable > bank.capacity * rules.restart)
    if panel.quietCut then
        if not rules.quiet or ready then Changes.setQuietCut(panel, false) end
        return
    end
    if controller and rules.quiet and rules.generators and inUse and state.supplied and not can then
        Changes.setQuietCut(panel, true)
        return
    end
    if lost then
        if can or rules.generators then Networks.setSource(panel, true, true) else panel.sourceOn = nil end
        return
    end
    -- Charging from a generator (tier 3): what the bank lacks, at most CHARGE_RATE a battery, and within what the box
    -- carries over its devices' load, since charging counts toward overload.
    local charging = 0
    if controller and bank and state.supplied and not inUse then
        charging = math.min(Energy.CHARGE_RATE * #bank.batteries, (bank.capacity - bank.energy) / math.max(0.01, Energy.efficiency()))
        if BU.overloadEnabled() then
            charging = math.min(charging, math.max(0, Panels.capacity(panel) * 0.9 - rules.load) / math.max(state.loadFactor or 1, 1e-6))
        end
        if charging < 0.001 then charging = 0 end
    end
    Changes.setExtraLoad(panel, "charging", charging)
    local switchOn = can and state.enabled and (not state.supplied or (controller and not inUse and ready)) or nil
    if available and not can and inUse and bank then
        Sync.notice(panel, rules.generators and "IGUI_BU_Notice_BankLow" or "IGUI_BU_Notice_BankEmpty", Panels.name(panel))
    end
    if can ~= available or switchOn then Networks.setSource(panel, can, switchOn) end
    -- Carrying the load as it goes on: taken off because it cannot, it was not lost, and comes back only by its
    -- rules (rules.restart), not as after a load.
    panel.sourceOn = (inUse or switchOn) and can or nil
    checkSaving(panel, state, bank, output, rules)
end

-- The units over the time since they were last worked out: snow on the panels, then each panel's source; then each
-- loaded unit whose kind keeps something in step with its object (a rack's batteries: the bank counts those put in
-- from the next minute). Returns the hours: the minute's work goes by them, as the game may skip minutes when time
-- runs fast.
local function updateUnits()
    local data = Store.data()
    local now = getGameTime():getWorldAgeHours()
    local hours = data.energyHour and math.max(0, math.min(1, now - data.energyHour)) or 0
    data.energyHour = now
    if Energy.weather(hours) then Sync.changed(nil) end
    thisMinute = {}
    for _, panel in ipairs(Store.list()) do checkSource(panel, hours) end
    for _, unit in ipairs(Store.unitList()) do
        local sync = BU.Units.definition(unit.kind).sync
        local object = sync and BU.Units.object(unit)
        if object then sync(unit, object) end
    end
    return hours
end

local function onNetworkChange(id, what)
    local panel, utility, group = Networks.owner(id)
    if not panel then return end
    -- A device switched on or off: the saving looks at the devices again.
    if utility == "power" and what == "load" then savingLooked[panel.id] = nil end
    -- Water: a group's networks change together; its lowest tells for it.
    local floors = utility == "water" and select(2, BU.Water.layout(panel)) or nil
    if utility == "water" and id ~= BU.Water.lowestId(panel, group, floors) then return end
    local state = utility == "water" and Networks.groupState(panel, group, floors) or Networks.state(panel, utility)
    -- Another producer carries it: its line is another length.
    if utility == "power" and what == "producer" and not panel.parent then Networks.applyLoss(panel) end
    if utility == "power" then checkLoad(panel) end
    if panel.parent or not state then return end
    -- The relay clicks over to another producer, or as power comes or goes: heard at the box.
    if (what == "producer" or what == "supply") and utility == "power" then Sync.sound(panel, "LightSwitch") end
    if what == "producer" and Energy.inUse(state) then
        Sync.notice(panel, "IGUI_BU_Notice_SolarOn", Panels.name(panel))
    elseif what == "producer" and state.producer then
        for index, at in ipairs(panel.power.producers) do
            if at.x == state.producer.x and at.y == state.producer.y and at.z == state.producer.z then
                Sync.notice(panel, "IGUI_BU_Notice_Switched", Panels.name(panel), index)
            end
        end
    elseif what == "supply" and not state.supplied and state.enabled and utility == "power" then
        Sync.notice(panel, "IGUI_BU_Notice_PowerLost", Panels.name(panel))
    elseif what == "supply" and not state.supplied and state.enabled then
        if #BU.Water.groups(panel) > 1 then
            Sync.notice(panel, "IGUI_BU_Notice_WaterEmptyGroup", Panels.name(panel), BU.Water.groupName(panel, group))
        else
            Sync.notice(panel, "IGUI_BU_Notice_WaterEmpty", Panels.name(panel))
        end
    end
end

-- What each panel's power did this minute, for its energy graph: what its solar panels made, the load supplied,
-- its bank's charge (as the units' run left them, else worked out here). Returns whether its hour ended.
local function recordEnergy(panel)
    local state = Networks.state(panel, "power")
    if not state then return false end
    local made, bank
    local ran = thisMinute[panel.id]
    if ran then
        made, bank = ran.output, ran.bank
    else
        made, bank = Energy.hasSource(panel) and Energy.output(panel) or 0, Energy.bank(panel)
    end
    local hour = panel.energyNow and panel.energyNow.hour
    Store.recordEnergy(panel, made, state.supplied and state.load or 0, bank and bank.charge or nil)
    return hour ~= panel.energyNow.hour
end

-- What each main panel did for its player over so many hours, for the log: hours its units' source carried the load,
-- the generator fuel that spared (litres, from the API's fuelPerHour at the load), and when its power was last cut
-- (not for quiet hours, nor while the grid runs; a cut of a minute is the source handed on as the world loads).
local function recordStats(panel, hours)
    if panel.parent then return end
    local state = Networks.state(panel, "power")
    if not state then return end
    local now = getGameTime():getWorldAgeHours()
    local stats = panel.stats or { since = now }
    panel.stats = stats
    if state.supplied and Energy.inUse(state) then
        stats.carried = (stats.carried or 0) + hours
        stats.saved = (stats.saved or 0) + (state.fuelPerHour or 0) * hours
    end
    local wanted = #panel.power.producers > 0 or Energy.hasSource(panel)
    if wanted and not state.supplied and not panel.quietCut and not getWorld():isHydroPowerOn() then
        stats.dark = (stats.dark or 0) + 1
        if stats.dark >= 2 then stats.outage = now end
    else
        stats.dark = nil
    end
end

-- What each water group's tanks held this minute, for its level graph.
local function recordWater(panel)
    if panel.parent or not BU.waterAvailable() then return end
    local floors = select(2, BU.Water.layout(panel))
    for _, group in ipairs(BU.Water.groups(panel)) do
        local state = Networks.groupState(panel, group.id, floors)
        if state then Store.recordWater(panel, group.id, state.amount or 0, state.capacity or 0) end
    end
end

-- Each minute, over the hours since the last (none as the units' time starts: the water units wait a minute).
local function everyMinute()
    if not BU.api() then return end
    local hours = updateUnits()
    local hourEnded = false
    for _, panel in ipairs(Store.list()) do
        checkLoad(panel)
        checkFuel(panel)
        hourEnded = recordEnergy(panel) or hourEnded
        recordStats(panel, hours)
        recordWater(panel)
        if not panel.parent and hours > 0 then
            BU.WaterRun.pumps(panel, hours * 60)
            BU.WaterRun.filters(panel, hours * 60)
        end
    end
    -- The bank and the energy record change every minute; clients get them hourly (alone, the window reads them).
    if hourEnded and isServer() then ModData.transmit(Store.KEY) end
end

-- Freezing pipes (a risk): a main panel's cold or warm hours at its box, counted every ten minutes; past the hours
-- its water freezes or thaws. Without the risk, frozen pipes thaw. A sub-panel's water freezes with its main panel's
-- (BU.Changes.link); one a save has frozen from before it was linked is not.
local function checkFreezing(panel)
    local water = panel.water
    if panel.parent then
        if water.frozen or water.coldHours or water.warmHours then
            water.frozen, water.coldHours, water.warmHours = nil, nil, nil
            Sync.changed(panel.id)
        end
        return
    end
    if not BU.Water.freezeEnabled() then
        water.coldHours, water.warmHours = nil, nil
        if water.frozen then Changes.setFrozen(panel, false) end
        return
    end
    local temperature = BU.Water.pipeTemperature(panel)
    local step = 10 / 60
    water.coldHours = temperature < BU.Water.FREEZE_BELOW and (water.coldHours or 0) + step or nil
    water.warmHours = temperature > BU.Water.THAW_ABOVE and (water.warmHours or 0) + step or nil
    if not water.frozen and (water.coldHours or 0) >= BU.Water.FREEZE_HOURS then Changes.setFrozen(panel, true) end
    if water.frozen and (water.warmHours or 0) >= BU.Water.THAW_HOURS then Changes.setFrozen(panel, false) end
end

-- Timers turn with dusk and dawn; ten minutes is near enough.
local function everyTenMinutes()
    if not BU.api() then return end
    Changes.checkObjects()
    for _, panel in ipairs(Store.list()) do
        Changes.applyTimers(panel)
        checkFreezing(panel)
        if not panel.parent then BU.WaterRun.sprinklers(panel) end
    end
end

-- A unit's square loaded: its kind catches up with what changed while it was not (a rack's batteries and look). This
-- runs on a multiplayer client too.
for _, kind in ipairs(BU.Units.KINDS) do
    local definition = BU.Units.definition(kind)
    if definition.onLoad then
        for _, sprite in ipairs(definition.sprites) do
            MapObjects.OnLoadWithSprite(sprite, function(object)
                local unit = BU.Units.ofObject(object)
                if unit then definition.onLoad(unit, object) end
            end, 5)
        end
    end
end

-- As the world starts: the API checked, what this game's API lacks said once, every panel's networks defined, and the
-- networks' changes heard from now (the API sets its event up as it starts, which may be after this file loaded).
local listening = false

local function defineAll()
    BU.resetHooks()
    local api, reason = BU.api()
    if not api then
        BU.log("the PZ Tools extension API is", reason == "version" and "another version" or "missing", "- boxes do nothing")
        return
    end
    if not listening and Events.OnPZToolsNetworkChange then
        Events.OnPZToolsNetworkChange.Add(onNetworkChange)
        listening = true
    end
    local water, why = BU.waterAvailable()
    if not water then BU.log("water networks are not in this game - boxes give no water:", why) end
    local purify, notPurify = BU.purifyAvailable()
    if water and not purify and BU.sandbox("RiskPlumbingUnpurified", false) == true then
        BU.log("water that keeps its taint is not in this game - the pipes purify:", notPurify)
    end
    Networks.defineAll()
    for _, panel in ipairs(Store.list()) do Changes.applyTimers(panel) end
    BU.log("defined the networks of", #Store.list(), "panels")
end

-- A multiplayer client loads this file too; the world is not decided there.
if isClient() then return end
Events.OnClientCommand.Add(onClientCommand)
Events.OnGameStart.Add(defineAll)
if Events.OnServerStarted then Events.OnServerStarted.Add(defineAll) end
Events.EveryOneMinute.Add(everyMinute)
Events.EveryTenMinutes.Add(everyTenMinutes)
