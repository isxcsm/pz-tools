-- Where the world is decided (the server, or the game alone): the networks from the save as the world starts, the
-- players' commands, breakers that trip under overload, and what players near a box should hear.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Moveables"
local BU = BuildingUtilities
local Store, Panels, Networks, Changes, Sync = BU.Store, BU.Panels, BU.Networks, BU.Changes, BU.Sync

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

function commands.moveProducer(player, panel, args)
    Changes.moveProducer(panel, args.utility, tonumber(args.index) or 0, args.delta == -1 and -1 or 1)
end

function commands.rename(player, panel, args) Changes.rename(panel, args.name) end

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
    if known and connectedDevice(panel, args.key) then Changes.setSchedule(panel, args.key, args.schedule) end
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
    local capacity = Panels.capacity(panel)
    if state.load > capacity + 1e-6 then
        local keys = Panels.sheds(panel) and Panels.shedPlan(panel, state.load - capacity)
        if keys then Changes.shed(panel, keys) else Changes.trip(panel) end
    elseif any(shed) then
        local keys = Panels.restorePlan(panel, capacity - state.load)
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

local function onNetworkChange(id, what)
    local panel, utility = Networks.owner(id)
    if not panel then return end
    local state = Networks.state(panel, utility)
    if utility == "power" then checkLoad(panel) end
    if panel.parent or not state then return end
    if what == "producer" and state.producer then
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

Events.OnClientCommand.Add(onClientCommand)
Events.OnGameStart.Add(function() if not isClient() then defineAll() end end)
if Events.OnServerStarted then Events.OnServerStarted.Add(defineAll) end
Events.EveryOneMinute.Add(everyMinute)
Events.EveryTenMinutes.Add(everyTenMinutes)
if Events.OnPZToolsNetworkChange then Events.OnPZToolsNetworkChange.Add(onNetworkChange) end
