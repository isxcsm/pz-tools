-- Where the world is decided (the server, or the game alone): the networks from the save as the world starts, the
-- players' commands, breakers that trip under overload, and what players near a box should hear.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Moveables"
local BU = BuildingUtilities
local Store, Panels, Networks, Changes, Sync, Energy = BU.Store, BU.Panels, BU.Networks, BU.Changes, BU.Sync, BU.Energy

local function defineAll()
    local api, reason = BU.api()
    if not api then
        BU.log("the PZ Tools extension API is", reason == "version" and "another version" or "missing", "- boxes do nothing")
        return
    end
    Networks.defineAll()
    for _, panel in ipairs(Store.list()) do Changes.applyTimers(panel) end
    BU.log("defined the networks of", #Store.list(), "panels")
end

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

-- The charge controller's settings, from its choices (Energy.CHOICES).
function commands.setController(player, panel, args)
    if (panel.tier or 1) < BU.CONTROLLER_TIER then return end
    local settings = Energy.settings(panel)
    for name in pairs(Energy.DEFAULTS) do
        if type(args[name]) == "number" then settings[name] = args[name] end
    end
    if Energy.validSettings(settings) then Changes.setController(panel, settings) end
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
-- devices that are not essential, if that is enough, and turns them on again when there is room.
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
        local keys = Panels.sheds(panel) and Panels.shedPlan(panel, (state.load - capacity) / factor)
        if keys then Changes.shed(panel, keys) else Changes.trip(panel) end
    elseif any(shed) then
        local keys = Panels.restorePlan(panel, (capacity - state.load) / factor)
        if #keys > 0 then Changes.restore(panel, keys) end
    end
end

-- What players hear: the generator in use changed, power or water ran out, fuel runs low.
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
-- essential are off ("saving"), until it is 5% above it or something else carries the load.
local function checkSaving(panel, state, bank, output, rules)
    local onBank = bank ~= nil and Energy.inUse(state) and state.supplied
    local protect = rules.settings.protect / 100
    if (panel.tier or 1) >= BU.SMART_TIER and onBank and output < rules.load and bank.charge < protect then
        local keys = {}
        for _, device in ipairs(Panels.devices(panel, "power")) do
            if device.state == "on" and not device.held and not device.essential and (device.power or 0) > 0 then
                keys[#keys + 1] = device.key
            end
        end
        if #keys > 0 then Changes.save(panel, keys) end
    elseif any(panel.power.saving) and (not onBank or bank.charge >= protect + 0.05) then
        Changes.unsave(panel)
    end
end

-- The units' source of a main panel over so many hours (Energy.run): available while its solar panels or its bank
-- carry the load. It is switched on when it can and the network has no supply: nothing ran, or the player switched
-- the generator in use off. Below tier 3 a generator the player runs keeps running; a charge controller (tier 3)
-- takes the load back from it once the bank is charged to its stop setting, charges the bank from it meanwhile, and
-- in quiet hours switches the power off rather than let a generator start.
local function checkSource(panel, hours)
    if not Energy.hasSource(panel) then return end
    local state = Networks.state(panel, "power")
    if not state then return end
    local source = Energy.sourceState(state)
    local available = source ~= nil and source.available == true
    local rules = Energy.rules(panel, state)
    local can, bank, output = Energy.run(panel, state, hours, available, rules)
    for _, rack in ipairs(Store.unitList("rack", panel.id)) do Changes.showRack(rack) end
    if panel.tripped then return end
    local inUse = Energy.inUse(state)
    local controller = (panel.tier or 1) >= BU.CONTROLLER_TIER
    if panel.quietCut then
        if not rules.quiet or can then Changes.setQuietCut(panel, false) end
        return
    end
    if controller and rules.quiet and rules.generators and inUse and state.supplied and not can then
        Changes.setQuietCut(panel, true)
        return
    end
    local charging = 0
    if controller and bank and state.supplied and not inUse then
        charging = math.min(Energy.CHARGE_RATE * #bank.batteries, (bank.capacity - bank.energy) / math.max(0.01, Energy.efficiency()))
        if charging < 0.001 then charging = 0 end
    end
    if math.abs(charging - (state.extraLoad or 0)) > 0.0005 then Networks.setExtraLoad(panel, charging) end
    local ready = Energy.canCarry(output, rules.load, false) or (bank ~= nil and bank.usable > bank.capacity * rules.restart)
    local switchOn = can and state.enabled and (not state.supplied or (controller and not inUse and ready)) or nil
    if available and not can and inUse and bank then
        Sync.notice(panel, rules.generators and "IGUI_BU_Notice_BankLow" or "IGUI_BU_Notice_BankEmpty", Panels.name(panel))
    end
    if can ~= available or switchOn then Networks.setSource(panel, can, switchOn) end
    checkSaving(panel, state, bank, output, rules)
end

-- The units over the time since they were last worked out: snow on the panels, then each panel's source.
local function updateUnits()
    local data = Store.data()
    local now = getGameTime():getWorldAgeHours()
    local hours = data.energyHour and math.max(0, math.min(1, now - data.energyHour)) or 0
    data.energyHour = now
    if Energy.weather(hours) then Sync.changed(nil) end
    for _, panel in ipairs(Store.list()) do checkSource(panel, hours) end
end

local function onNetworkChange(id, what)
    local panel, utility = Networks.owner(id)
    if not panel then return end
    local state = Networks.state(panel, utility)
    -- Another producer carries it: its line is another length.
    if utility == "power" and what == "producer" and not panel.parent then Networks.applyLoss(panel) end
    if utility == "power" then checkLoad(panel) end
    if panel.parent or not state then return end
    if what == "producer" and Energy.inUse(state) then
        Sync.notice(panel, "IGUI_BU_Notice_SolarOn", Panels.name(panel))
    elseif what == "producer" and state.producer then
        for index, at in ipairs(panel.power.producers) do
            if at.x == state.producer.x and at.y == state.producer.y and at.z == state.producer.z then
                Sync.notice(panel, "IGUI_BU_Notice_Switched", Panels.name(panel), index)
            end
        end
    elseif what == "supply" and not state.supplied and state.enabled then
        Sync.notice(panel, utility == "power" and "IGUI_BU_Notice_PowerLost" or "IGUI_BU_Notice_WaterEmpty", Panels.name(panel))
    end
end

local function everyMinute()
    if not BU.api() then return end
    updateUnits()
    for _, panel in ipairs(Store.list()) do
        checkLoad(panel)
        checkFuel(panel)
    end
end

-- Timers turn with dusk and dawn; ten minutes is near enough.
local function everyTenMinutes()
    if not BU.api() then return end
    Changes.checkObjects()
    for _, panel in ipairs(Store.list()) do Changes.applyTimers(panel) end
end

-- A rack's look follows its batteries (Changes.showRack), also for those that changed while it was not loaded.
MapObjects.OnLoadWithSprite(BU.Units.SPRITES.rack, function(object)
    local unit = BU.Units.ofObject(object)
    if unit then Changes.showRack(unit, object) end
end, 5)

Events.OnClientCommand.Add(onClientCommand)
Events.OnGameStart.Add(function() if not isClient() then defineAll() end end)
if Events.OnServerStarted then Events.OnServerStarted.Add(defineAll) end
Events.EveryOneMinute.Add(everyMinute)
Events.EveryTenMinutes.Add(everyTenMinutes)
if Events.OnPZToolsNetworkChange then Events.OnPZToolsNetworkChange.Add(onNetworkChange) end
