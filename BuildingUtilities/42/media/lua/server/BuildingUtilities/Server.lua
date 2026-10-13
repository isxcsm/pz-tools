-- Where the world is decided (the server, or the game alone): the networks from the save as the world starts, the
-- players' commands, breakers under overload (BU.Overload), what players near a box should hear, and each minute the
-- units (solar panels and the bank) and the water units (BU.WaterRun), with the records the
-- window shows.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Moveables"
require "BuildingUtilities/WaterRun"
require "BuildingUtilities/Overload"
local BU = BuildingUtilities
local Store, Panels, Networks, Changes, Sync, Energy = BU.Store, BU.Panels, BU.Networks, BU.Changes, BU.Sync, BU.Energy
local Overload = BU.Overload

-- Commands: the free changes a player makes at a box. Each names the panel; the rest is checked here.
local commands = {}

-- A device the box reaches switched at the box (connected or excluded), free: one, a room's or all; from the tier
-- that cuts devices (Panels.cuts).
function commands.setInside(player, panel, args)
    if not Panels.cuts(panel) then return end
    local device = Panels.device(panel, args.utility, args.key)
    if device and device.wired then Changes.setInside(panel, args.utility, device, args.on == true) end
end

function commands.setAllInside(player, panel, args)
    if Panels.cuts(panel) then Changes.setAllInside(panel, args.utility, args.on == true) end
end

-- The box's lever thrown from its window, at once like a device's tick there: down switches the power off, up resets
-- a tripped breaker and switches it on (Changes.setLever). Thrown the way it already is, nothing.
function commands.setLever(player, panel, args)
    local up = args.up == true
    if Panels.leverUp(panel) ~= up then Changes.setLever(panel, up) end
end

function commands.setRoomInside(player, panel, args)
    if Panels.cuts(panel) and type(args.room) == "string" then Changes.setRoomInside(panel, args.utility, args.room, args.on == true) end
end

-- A window saw devices in a room built onto the building that the networks do not have yet.
function commands.syncAttached(player, panel, args) Changes.syncAttached(panel) end

-- The box's zone: a list of room keys (Panels.rooms), or the whole building.
function commands.setZone(player, panel, args)
    if args.whole == true then Changes.setZone(panel, nil); return end
    if type(args.rooms) ~= "table" then return end
    local keys = {}
    for _, key in ipairs(args.rooms) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    Changes.setZone(panel, keys)
end

function commands.moveProducer(player, panel, args)
    Changes.moveProducer(panel, args.utility, tonumber(args.index) or 0, args.delta == -1 and -1 or 1)
end

function commands.rename(player, panel, args) Changes.rename(panel, args.name) end


-- Pipes: by their ids, checked by Changes; a fixture only while the panel connects it. A new pipe is a timed action
-- (ISBUAddPipe), not a command.
function commands.renamePipe(player, panel, args) Changes.renamePipe(panel, tonumber(args.pipe), args.name) end
function commands.removePipe(player, panel, args) Changes.removePipe(panel, tonumber(args.pipe)) end

function commands.setPipeReserve(player, panel, args)
    Changes.setPipeReserve(panel, tonumber(args.pipe), tonumber(args.percent))
end

-- A room of the zone, by its key, onto a pipe.
function commands.setRoomPipe(player, panel, args)
    for _, room in ipairs(Panels.zoneRooms(panel)) do
        if room.key == args.room then return Changes.setRoomPipe(panel, room.key, tonumber(args.pipe)) end
    end
end

function commands.setProducerPipe(player, panel, args)
    Changes.setProducerPipe(panel, tonumber(args.index) or 0, tonumber(args.pipe))
end

-- A fixture onto a pipe; none (args.pipe nil) puts it back on its room's.
function commands.setDevicePipe(player, panel, args)
    local device = type(args.key) == "string" and Panels.device(panel, "water", args.key)
    if device and device.state == "on" then Changes.setDevicePipe(panel, device, tonumber(args.pipe)) end
end

-- A water unit of the panel onto its pipes: inlet (a pump's outlet) and, for a filter or a booster pump, outlet.
function commands.setUnitPipes(player, panel, args)
    local unit = BU.Store.unit(args.unit)
    if unit and unit.panel == panel.id then Changes.setUnitPipes(unit, tonumber(args.inlet), tonumber(args.outlet)) end
end

-- "Switch to solar" (Energy.sourceOffer): the source takes the load over from the generator in use, which the API
-- switches off, on standby.
function commands.useSource(player, panel, args)
    local offered, ready = Energy.sourceOffer(panel, Networks.state(panel, "power"))
    if offered and ready then Changes.useSource(panel) end
end

-- A power device of the panel that it connects (its building's, or one it wired outside).
local function connectedDevice(panel, key)
    local device = type(key) == "string" and Panels.device(panel, "power", key)
    return device and device.state == "on" and device or nil
end

function commands.setSchedule(player, panel, args)
    local known = false
    for _, schedule in ipairs(BU.SCHEDULES) do known = known or schedule == args.schedule end
    if known and (panel.tier or 1) >= BU.TIMER_TIER and connectedDevice(panel, args.key) then
        Changes.setSchedule(panel, args.key, args.schedule)
    end
end

-- The feature a command needs on (BU.enabled), besides its utility's; one of a feature that is off is ignored, as
-- the window no longer offers it.
local NEEDS = { setSchedule = "power", renamePipe = "water", removePipe = "water", setPipeReserve = "water",
    setRoomPipe = "water", setProducerPipe = "water", setDevicePipe = "water", setUnitPipes = "water" }

local function onClientCommand(module, command, player, args)
    if module ~= BU.MOD or not commands[command] or type(args) ~= "table" then return end
    if args.utility ~= nil and args.utility ~= "power" and args.utility ~= "water" then return end
    if not BU.enabled(args.utility) or not BU.enabled(NEEDS[command]) then return end
    local panel = Store.get(args.panel)
    if panel then commands[command](player, panel, args) end
end

-- What players hear: the generator in use changed (and the relay's click), power or water ran out, fuel runs low.
-- While a network is switched off (breaker, main switch) its generators stop: what was told about it
-- stands until it is on again, so the low fuel is not told again as it restarts.
local lowFuel = {}

local function checkFuel(panel)
    local state = Networks.state(panel, "power")
    local hours = state and state.supplied and state.hoursLeft
    if hours and hours < BU.lowFuelHours() then
        if not lowFuel[panel.id] then
            lowFuel[panel.id] = true
            Sync.notice(panel, "IGUI_BU_Notice_LowFuel", Panels.name(panel), math.floor(hours + 0.5))
        end
    elseif state and state.enabled and (not hours or hours > BU.lowFuelHours() + 1) then
        lowFuel[panel.id] = nil
    end
end

-- The units' source of a panel over so many hours (Energy.run): available while its solar panels or its bank carry
-- the load. The API hands the load to it, first in order, when the one in use stops and it is available; it is
-- switched on here when it can and the network has no supply. The bank hands the load to a generator at
-- Energy.HANDOVER, and takes it back from one once it is ready by its rules (Energy.ready: Energy.TAKE_BACK, or the
-- solar panels with the margin to start); a player may switch to solar earlier (commands.useSource). What the bank
-- and the solar panels came to this minute, by panel, for the energy record: { bank, output }.
local thisMinute = {}

local function checkSource(panel, hours)
    if not Energy.hasSource(panel) then return end
    local state = Networks.state(panel, "power")
    if not state then return end
    local source = Energy.sourceState(state)
    local inUse = Energy.inUse(state)
    -- The source carried the load when last seen and nothing does now, the network switched on: the world was loaded
    -- again (the source is defined off). It counts as available, and goes on again below; if it cannot carry the
    -- load, it is switched on for this minute so that the API hands over to a generator in the next.
    local lost = panel.sourceOn and not inUse and not state.supplied and state.enabled
    -- While the box keeps its power off (breaker, main switch) the network runs no producer, and the source
    -- counts as available if it carried the load before.
    local held = not Networks.powerAllowed(panel)
    local available = source ~= nil and source.available == true or (lost or held and panel.sourceOn) == true
    local rules = Energy.rules(panel, state)
    local can, bank, output = Energy.run(panel, state, hours, available, rules)
    thisMinute[panel.id] = { bank = bank, output = output }
    local ready = Energy.ready(rules, output, bank)
    if held then
        -- Whether the source can carry the load goes on being told, so that as the network is switched on the API
        -- starts the right producer by its own order: a generator switched on by hand meanwhile, or the one in use
        -- before; else the source, if it can; else the first on standby.
        if source and can ~= (source.available == true) then Networks.setSource(panel, can, nil) end
        if not can then panel.sourceOn = nil end
        return
    end
    if lost then
        if can or rules.generators then Networks.setSource(panel, true, true) else panel.sourceOn = nil end
        return
    end
    local switchOn = can and state.enabled and (not state.supplied or (not inUse and ready)) or nil
    if available and not can and inUse and bank then
        Sync.notice(panel, rules.generators and "IGUI_BU_Notice_BankLow" or "IGUI_BU_Notice_BankEmpty", Panels.name(panel))
    end
    if can ~= available or switchOn then Networks.setSource(panel, can, switchOn) end
    -- Carrying the load as it goes on: taken off because it cannot, it was not lost, and comes back only by its
    -- rules (rules.restart), not as after a load.
    panel.sourceOn = (inUse or switchOn) and can or nil
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
    local panel, utility, pipe, _, _, kind = Networks.owner(id)
    if not panel then return end
    -- Water: what a pipe's tanks hold together tells for it, as a floor's tanks change (its use networks follow).
    if utility == "water" and kind ~= "T" then return end
    local state = Networks.state(panel, utility)
    if utility == "water" then
        state = state and state.pipes[pipe]
        if state then state.enabled = not panel.water.frozen end
    end
    if utility == "power" then Overload.check(panel) end
    if not state then return end
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
        if BU.Water.shown(panel) then
            Sync.notice(panel, "IGUI_BU_Notice_WaterEmptyPipe", Panels.name(panel), BU.Water.pipeName(panel, pipe))
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

-- What each panel did for its player over so many hours, for the log: hours its units' source carried the load,
-- the generator fuel that spared (litres, from the API's fuelPerHour at the load), and when its power was last cut
-- (not for the main switch, nor while the grid runs; a cut of a minute is the source handed on as the
-- world loads).
local function recordStats(panel, hours)
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
    if wanted and not state.supplied and not panel.switchedOff and not getWorld():isHydroPowerOn() then
        stats.dark = (stats.dark or 0) + 1
        if stats.dark >= 2 then stats.outage = now end
    else
        stats.dark = nil
    end
end

-- What each pipe's tanks held this minute, for its level graph.
local function recordWater(panel)
    if not BU.enabled("water") or not BU.waterAvailable() then return end
    local state = Networks.state(panel, "water")
    for id, pipe in pairs(state and state.pipes or {}) do Store.recordWater(panel, id, pipe.amount, pipe.capacity) end
end

-- A network switched on again (breaker reset, main switch) with nothing that can run raises no event:
-- the power stays out without a word. Told once it has had a minute to start: by panel, "held" while the box keeps
-- its power off, then "resumed" for the minute after.
local resuming = {}

local function checkResumed(panel)
    local held, was = not Networks.powerAllowed(panel), resuming[panel.id]
    resuming[panel.id] = held and "held" or was == "held" and "resumed" or nil
    if was ~= "resumed" or held then return end
    local state = Networks.state(panel, "power")
    local wanted = #panel.power.producers > 0 or Energy.hasSource(panel)
    if wanted and state and state.enabled and not state.supplied then
        Sync.notice(panel, "IGUI_BU_Notice_PowerLost", Panels.name(panel))
    end
end

-- Each minute, over the hours since the last (none as the units' time starts: the water units wait a minute), after
-- what the sandbox turned on or off (Changes.applyFeatures) and changed of the zones' and the water's floors
-- (Changes.applyShape). Each box first takes the devices of rooms built onto its building into its networks
-- (Changes.syncAttached). Power's checks and records only while it is on.
local function everyMinute()
    if not BU.api() then return end
    Changes.applyFeatures()
    Changes.applyShape()
    local hours = updateUnits()
    local hourEnded = false
    local power = BU.enabled("power")
    for _, panel in ipairs(Store.list()) do
        Changes.syncAttached(panel)
        if power then
            Overload.check(panel, hours)
            checkFuel(panel)
            checkResumed(panel)
            hourEnded = recordEnergy(panel) or hourEnded
            recordStats(panel, hours)
        end
        if hours > 0 then BU.WaterRun.machines(panel, hours * 60) end
        recordWater(panel)
    end
    -- The bank and the energy record change every minute; clients get them hourly (alone, the window reads them).
    if hourEnded and isServer() then ModData.transmit(Store.KEY) end
end

-- Freezing pipes (a risk): a panel's cold or warm hours at its box, counted every ten minutes; past the hours its
-- water freezes or thaws. Without the risk, frozen pipes thaw.
local function checkFreezing(panel)
    local water = panel.water
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

-- Timers turn with dusk and dawn; ten minutes is near enough. Timers only while power is on, freezing while water is.
local function everyTenMinutes()
    if not BU.api() then return end
    Changes.applyFeatures()
    Changes.checkObjects()
    local power, water = BU.enabled("power"), BU.enabled("water")
    for _, panel in ipairs(Store.list()) do
        if power then Changes.applyTimers(panel) end
        if water then checkFreezing(panel) end
        BU.WaterRun.sprinklers(panel)
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
        BU.log("the PZ Extension API is", reason == "version" and "another version" or "missing", "- boxes do nothing")
        return
    end
    if not listening and Events.OnPZExtNetworkChange then
        Events.OnPZExtNetworkChange.Add(onNetworkChange)
        listening = true
    end
    local water, why = BU.waterAvailable()
    if not water then BU.log("water networks are not in this game - boxes give no water:", why) end
    local purify, notPurify = BU.purifyAvailable()
    if water and not purify and BU.sandbox("RiskPlumbingUnpurified", false) == true then
        BU.log("water that keeps its taint is not in this game - the pipes purify:", notPurify)
    end
    Networks.defineAll()
    Changes.fitZones()
    Changes.applyFeatures(true)
    Changes.applyShape(true)
    if BU.enabled("power") then
        for _, panel in ipairs(Store.list()) do Changes.applyTimers(panel) end
    end
    for _, panel in ipairs(Store.list()) do Changes.syncAttached(panel) end
    BU.log("defined the networks of", #Store.list(), "panels, features on:", BU.featureKey())
end

-- A multiplayer client loads this file too; the world is not decided there.
if isClient() then return end
Events.OnClientCommand.Add(onClientCommand)
Events.OnGameStart.Add(defineAll)
if Events.OnServerStarted then Events.OnServerStarted.Add(defineAll) end
Events.EveryOneMinute.Add(everyMinute)
Events.EveryTenMinutes.Add(everyTenMinutes)
