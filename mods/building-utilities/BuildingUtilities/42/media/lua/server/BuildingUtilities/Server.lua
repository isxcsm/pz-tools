-- Where the world is decided (the server, or the game alone): the networks from the save as the world starts, the
-- players' commands, breakers under overload (BU.Overload), what players near a box should hear, and each minute the
-- units (solar panels and the bank) and the water units (BU.WaterRun), with the records the
-- window shows.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Moveables"
require "BuildingUtilities/WaterRun"
require "BuildingUtilities/Overload"
require "BuildingUtilities/Nearby"
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


-- Pipes: by their ids, checked by Changes; a fixture only while the panel connects it. A pipe put in
-- or taken out is a timed action (ISBUAddPipe, ISBURemovePipe), not a command.
function commands.renamePipe(player, panel, args) Changes.renamePipe(panel, tonumber(args.pipe), args.name) end

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

-- A tank shut or opened at the box, as a fixture's tick (the tier that cuts devices, Panels.cuts).
function commands.setProducerOn(player, panel, args)
    if Panels.cuts(panel) then Changes.setProducerOn(panel, tonumber(args.index) or 0, args.on == true) end
end

-- A water unit of the panel switched off or on at the box, as a fixture's tick.
function commands.setUnitOn(player, panel, args)
    local unit = BU.Store.unit(args.unit)
    if Panels.cuts(panel) and unit and unit.panel == panel.id then Changes.setUnitOn(unit, args.on == true) end
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
local NEEDS = { setSchedule = "power", renamePipe = "water", setProducerOn = "water", setUnitOn = "water",
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
-- and the solar panels came to this minute, by panel, for the energy record and the schedule: { bank, output, rules }.
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
    thisMinute[panel.id] = { bank = bank, output = output, rules = rules }
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

-- Freezing pipes (a risk): a panel's cold or warm hours at its box, counted as its minute's work runs over the hours
-- since it last ran, in the air they had (Energy.weatherSteps; its box as much warmer than outside as now); past the
-- hours its water freezes or thaws. Without the risk, frozen pipes thaw.
local function checkFreezing(panel, hours)
    local water = panel.water
    if not BU.Water.freezeEnabled() then
        water.coldHours, water.warmHours = nil, nil
        if water.frozen then Changes.setFrozen(panel, false) end
        return
    end
    local warmth = BU.Water.pipeTemperature(panel) - getClimateManager():getTemperature()
    local steps, first, firstHours = Energy.weatherSteps(hours)
    for i = first, #steps do
        local spell = i == first and firstHours or steps[i][1]
        local temperature = steps[i][3] + warmth
        water.coldHours = temperature < BU.Water.FREEZE_BELOW and (water.coldHours or 0) + spell or nil
        water.warmHours = temperature > BU.Water.THAW_ABOVE and (water.warmHours or 0) + spell or nil
        if not water.frozen and (water.coldHours or 0) >= BU.Water.FREEZE_HOURS then Changes.setFrozen(panel, true) end
        if water.frozen and (water.warmHours or 0) >= BU.Water.THAW_HOURS then Changes.setFrozen(panel, false) end
    end
end

-- The minute's work of a box, over the hours since it last ran (BU.Nearby: every minute near a player, now and then
-- far from them, Server's schedule below): its source and bank, the devices of rooms built onto its building (near
-- only: they are seen loaded), its breaker, fuel and records while power is on; its water machines, records,
-- freezing, and every ten minutes or more its sprinklers. Returns whether its energy record's hour ended.
local function runPanel(panel, hours, near, now)
    local hourEnded = false
    checkSource(panel, hours)
    if near then Changes.syncAttached(panel) end
    if BU.enabled("power") then
        local ran = thisMinute[panel.id]
        Overload.check(panel, hours, ran and (ran.bank or false))
        checkFuel(panel)
        checkResumed(panel)
        hourEnded = recordEnergy(panel)
        recordStats(panel, hours)
    end
    if hours > 0 then BU.WaterRun.machines(panel, hours * 60) end
    recordWater(panel)
    if BU.enabled("water") and hours > 0 then checkFreezing(panel, hours) end
    if now - (panel.sprinkledAt or 0) >= 1 / 6 then
        panel.sprinkledAt = now
        BU.WaterRun.sprinklers(panel)
    end
    return hourEnded
end

-- When a far box runs next. Its run works out the time since in the weather it had (Energy.weatherSteps), so it needs
-- to run only before a rule could turn: COLD_MOST on, sooner when its bank could reach a share its rules turn at
-- (empty, BANK_START, HANDOVER, TAKE_BACK, full) charged by its solar panels in full sun or drawn by the whole load;
-- within COLD_MINUTES while its breaker is down from full, or while snow settles or melts on panels the sun turns its
-- source by; but not before COLD_LEAST. A box whose source the sun turns (no bank to carry the load, or one at its
-- restart or below) is watched besides: it runs as the daylight passes the sun its solar panels carry the load in
-- (and in with the margin to start).
local COLD_MOST, COLD_MINUTES, COLD_LEAST = 360, 60, 10
local TURNS = { 0, Energy.BANK_START, Energy.HANDOVER, Energy.TAKE_BACK, 1 }

-- The watched boxes by id: { the sun it carries the load in, whether the daylight was at it or over, the same with
-- the margin }; the daylight they were last looked at in.
local watched, watchedSun = {}, nil

local function watch(panel, rules, bank, sunny)
    watched[panel.id] = nil
    if sunny <= 0 or sunny < rules.load or bank and bank.usable > bank.capacity * rules.restart then return false end
    local sun = Energy.sunlight()
    local carries, starts = rules.load / sunny, rules.load * Energy.START_MARGIN / sunny
    watched[panel.id] = { carries, sun >= carries, starts, sun >= starts }
    return true
end

local function coldMinutes(panel)
    watched[panel.id] = nil
    if Panels.breaker(panel) < 1 then return COLD_MINUTES end
    local ran = thisMinute[panel.id]
    if not ran then return COLD_MOST end
    local bank, rules = ran.bank, ran.rules
    local sunny, _, snow = Energy.output(panel, 1)
    local minutes = COLD_MOST
    local snowRate = Energy.snowRate()
    if watch(panel, rules, bank, sunny) and (snowRate > 0 or snowRate < 0 and snow > 0) then minutes = COLD_MINUTES end
    if not bank or bank.capacity <= 0 then return minutes end
    local up, down = sunny * Energy.efficiency(), rules.load
    -- Its charge for full, what it can give (above what cold and the worst battery hold back) for the rest.
    for _, share in ipairs({ bank.charge, bank.usable / bank.capacity }) do
        for _, turn in ipairs(TURNS) do
            local gap = (turn - share) * bank.capacity
            local flow = gap > 0 and up or down
            if math.abs(gap) > 1e-6 and flow > 1e-9 then minutes = math.min(minutes, math.abs(gap) / flow * 60) end
        end
    end
    return math.max(COLD_LEAST, math.floor(minutes))
end

-- The watched boxes the daylight passed the sun of since they were last looked at.
local function sunTurned(runs, taken)
    local sun = Energy.sunlight()
    if sun == watchedSun then return end
    watchedSun = sun
    for id, at in pairs(watched) do
        if not taken[id] and ((sun >= at[1]) ~= at[2] or (sun >= at[3]) ~= at[4]) then
            local panel = Store.get(id)
            if panel then
                runs[#runs + 1] = panel
                taken[id] = true
            end
        end
    end
end

-- The schedule: by panel id the minute it runs next (not saved: as the world loads, every box runs within the hour),
-- and by minute the ids due then (an id whose due minute moved since is passed over); made again for another save.
local dueAt, wheel, scheduled, lastMinute, scheduledSave = {}, {}, nil, nil, nil

local function schedule(id, minute)
    dueAt[id] = minute
    wheel[minute] = wheel[minute] or {}
    table.insert(wheel[minute], id)
end

-- Boxes not scheduled yet: spread over the next COLD_MINUTES so that they do not all run at once.
local function scheduleNew(minute)
    if scheduledSave ~= Store.data() then
        dueAt, wheel, scheduled, lastMinute, watched, watchedSun = {}, {}, nil, nil, {}, nil
        scheduledSave = Store.data()
    end
    if scheduled == Store.linkVersion() then return end
    scheduled = Store.linkVersion()
    for index, panel in ipairs(Store.list()) do
        if not dueAt[panel.id] then schedule(panel.id, minute + BU.remainder(index, COLD_MINUTES)) end
    end
end

-- Each minute, after what the sandbox turned on or off (Changes.applyFeatures) and changed of the zones' and the
-- water's floors (Changes.applyShape), and the weather's spell for the snow (Energy.weather): the boxes near a player
-- run, and the far ones due or woken by the sun. Each runs over the hours since it last ran (at most what the
-- weather's log keeps; none as the world starts: the water units wait a minute), so a far one catches up as it runs.
-- Then the units near a player whose kind keeps something in step with its object (a rack's batteries: the bank
-- counts those put in from the next minute).
local function everyMinute()
    if not BU.api() then return end
    Changes.applyFeatures()
    Changes.applyShape()
    Energy.weather()
    local now = getGameTime():getWorldAgeHours()
    local minute = Energy.minute()
    scheduleNew(minute)
    local players = BU.Nearby.players()
    local _, near = BU.Nearby.hotPanels(players)
    local runs, isNear, taken = {}, {}, {}
    for _, panel in ipairs(near) do
        runs[#runs + 1] = panel
        isNear[panel.id], taken[panel.id] = true, true
    end
    -- The far boxes due since the last minute; after a jump of time longer than any wait, every one.
    local from = lastMinute and lastMinute + 1 or minute
    if minute - from > COLD_MOST then
        for _, panel in ipairs(Store.list()) do
            if not taken[panel.id] then
                runs[#runs + 1] = panel
                taken[panel.id] = true
            end
        end
        wheel = {}
    else
        for each = from, minute do
            for _, id in ipairs(wheel[each] or {}) do
                local panel = dueAt[id] == each and not taken[id] and Store.get(id)
                if panel then
                    runs[#runs + 1] = panel
                    taken[id] = true
                end
            end
            wheel[each] = nil
        end
    end
    sunTurned(runs, taken)
    lastMinute = minute
    thisMinute = {}
    local hourEnded = false
    for _, panel in ipairs(runs) do
        local hours = panel.ranAt and math.max(0, math.min(Energy.WEATHER_HOURS, now - panel.ranAt)) or 0
        panel.ranAt = now
        hourEnded = runPanel(panel, hours, isNear[panel.id], now) or hourEnded
        if isNear[panel.id] then
            watched[panel.id] = nil
            schedule(panel.id, minute + COLD_LEAST)
        else
            schedule(panel.id, minute + coldMinutes(panel))
        end
    end
    BU.WaterRun.fires()
    for _, unit in ipairs(BU.Nearby.units(players)) do
        local sync = BU.Units.definition(unit.kind).sync
        local object = sync and BU.Units.object(unit)
        if object then sync(unit, object) end
    end
    -- The bank and the energy record change every minute; clients get them hourly (alone, the window reads them).
    if hourEnded and isServer() then ModData.transmit(Store.KEY) end
end

-- Timers turn with dusk and dawn; ten minutes is near enough; only while power is on. They are gone through as night
-- falls or ends (wasNight); what changes a box's timers otherwise applies them at once (Changes.applyTimers). What is
-- gone from the squares near the players is let go.
local wasNight = nil

local function everyTenMinutes()
    if not BU.api() then return end
    Changes.applyFeatures()
    local players = BU.Nearby.players()
    local _, near = BU.Nearby.hotPanels(players)
    Changes.checkObjects(near, BU.Nearby.units(players))
    local night = BU.scheduleOn("night")
    if BU.enabled("power") and night ~= wasNight then
        wasNight = night
        for _, panel in ipairs(Store.list()) do Changes.applyTimers(panel) end
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
