-- What the mod keeps in the save: the breaker boxes and what is connected to them. The API keeps nothing; the
-- networks are defined again from this each time a world loads.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Store = {}
BU.Store = Store

local KEY = "BuildingUtilities"

-- { version, next, panels = { [id] = panel } }. A panel:
--   id, x, y, z (the box's square), sprite, name (set by the player, or nil), tier (1 to BU.TIERS), tripped (its
--   breaker is down), switchedOff (true while a player has its main switch off, else nil), zone (the rooms it takes: a
--   set of a square of each, BU.placeKey, Panels.zoneIds; or nil for the whole building),
--   warmth (its square's air above the air outside, last seen loaded: BU.airAt),
--   outdoor (true for one put down outside any building: no zone, its square its only wall),
--   log (what happened to it, oldest first: { hour, key, args }, at most Store.LOG_SIZE),
--   and per utility (power, water): producers (a list of { x, y, z }, in order: those whose lines are the box's,
--   BU.Links), excluded (a set of BU.thingKey), included (a set: the devices outside whose lines are the box's, by
--   BU.thingKey) and attached (a set: devices in rooms built onto
--   the building, which the box takes as its building's though the API has them as single objects, BU.Panels.attached);
--   for power also schedule (BU.thingKey to a timer of BU.SCHEDULES), breaker (its breaker's gauge under overload, 0
--   to 1, nil while full: BU.Panels.breaker) and timed (a set: what the box keeps off by their timers).
--   For water also pipes (BU.Water: a list of { id (its colour, 1 to Water.MAX_PIPES), name (set by the player, or
--   nil), reserve (the percent its tanks keep from sprinklers, or nil) }, the first, blue, always there), roomPipe (a
--   room's square, BU.placeKey, to its pipe when not the first), pipeOf (BU.thingKey to the pipe the player chose for
--   a fixture) and levelLog (by pipe, what its tanks held hour by hour, oldest first, at most Store.ENERGY_HOURS:
--   { hour, amount, capacity }); a water producer may have pipe (nil for the first). With the freezing risk: frozen
--   (its pipes are), coldHours and warmHours (how long it has been below freezing or above thawing at the box).
--   energyLog: what the panel's power did hour by hour, oldest first, at most Store.ENERGY_HOURS: { hour (world age,
--   whole), made (what its solar panels made, on average), used (the load supplied), charge (its bank's at the end,
--   or nil) }; energyNow is the hour being summed { hour, made, used, n, charge }.
--   A panel with units may keep sourceOn (its units' source carried the load when last seen: a world loaded again
--   defines the source off, and the server switches it back on). extraLoads: what the box adds to its devices' load,
--   by part (BU.Changes.setExtraLoad).
--   A panel keeps stats, for its log (Server): since (the world age it began), carried (hours its units' source
--   carried the load), saved (generator fuel that spared, litres), outage (the world age its power was last cut) and
--   dark (minutes it has been without power, while it is).
-- units = { [id] = unit }: the solar panels, battery racks, pumps, sprinklers and filters this mod put down (BU.Units).
-- A unit:
--   id, kind (BU.Units.KINDS), x, y, z (its square), sprite, panel (the panel its line is of, or nil: BU.Links); a
--   solar panel also snow (0 to 1, nil for none, as at snowAt, the minute it was last worked out: Energy.snowOf); a
--   rack also warmth (as a panel's) and batteries, a record of each car battery in its container (BU.Rack.sync):
--   { id (the item's), type, charge 0 to 1, condition 0 to
--   100 } (how often one was reconditioned is the item's own, BU.Rack.REVIVED). A water unit may have pipe (its
--   inlet's, a pump's outlet's; nil for the first) and a filter or booster pump out (its outlet's pipe, nil for its
--   inlet's: BU.Water.unitPipes); a pump has fluid ("Water" from a well, "TaintedWater" from a river or lake); a
--   pump, filter or booster pump running (it moved water at the last minute; a pump also while it runs dry), idle
--   (why it moved none: "noPower", "frozen", "noWater", "noTanks", "full") and moved (litres an hour it moved at the
--   last minute); a sprinkler sprayedAt (the world age it last watered at); a filter media (hours of use left in its
--   charge).
-- lines = { [ref] = line }: every line laid, kept apart from the boxes so that one cut stays (BU.Links); nextLine
-- numbers them in the order they were laid.
-- snowLog: the weather's spells for the snow on solar panels; sunLog and sunAt: the daylight and the air by ten minutes,
-- and the minute last recorded (Energy.weather). A panel keeps ranAt, the world age its
-- minute's work last ran at (Server: a box far from the players runs now and then); one with a bank bankFlow, what
-- went into its batteries per hour at its last run (out of them when below 0), for its window; sprinkledAt, the world
-- age its sprinklers last looked at the crops.
-- "paid" is { [item type] = count }. On a client in multiplayer this is the server's, received; only the server
-- changes it (BU.Changes).
Store.KEY = KEY
Store.LOG_SIZE = 30
Store.ENERGY_HOURS = 48
-- The save's layout. The mod is not released: a save of another layout is not carried over.
local VERSION = 9

local function utilityData()
    return { producers = {}, excluded = {}, included = {}, attached = {}, schedule = {}, timed = {} }
end

-- What water keeps besides: one pipe, every tank and fixture on it.
local function waterData(data)
    data.pipes = data.pipes or { { id = 1 } }
    data.roomPipe = data.roomPipe or {}
    data.pipeOf = data.pipeOf or {}
    data.levelLog = data.levelLog or {}
end

function Store.data()
    local data = ModData.getOrCreate(KEY)
    if not data.version then
        data.version = VERSION
        data.next = 1
        data.panels = {}
    end
    if not data.units then
        data.units = {}
        data.nextUnit = 1
    end
    if not data.lines then
        data.lines = {}
        data.nextLine = 1
    end
    return data
end

function Store.panels() return Store.data().panels end

function Store.get(id) return id and Store.panels()[id] or nil end

function Store.newPanel(x, y, z, sprite)
    local data = Store.data()
    local id = "p" .. data.next
    data.next = data.next + 1
    local panel = { id = id, x = x, y = y, z = z, sprite = sprite, tier = 1, tripped = false, log = {} }
    for _, utility in ipairs(BU.UTILITIES) do panel[utility] = utilityData() end
    waterData(panel.water)
    data.panels[id] = panel
    Store.linksChanged()
    return panel
end

function Store.remove(id)
    Store.panels()[id] = nil
    Store.linksChanged()
end

-- What the lines, the boxes and the units' boxes are changes the count (not saved): what is worked out of them
-- (BU.Links, the zones' buildings) is kept while it holds.
local linkVersion = 0
function Store.linksChanged() linkVersion = linkVersion + 1 end
function Store.linkVersion() return linkVersion end

function Store.panelAt(x, y, z)
    for _, panel in pairs(Store.panels()) do
        if panel.x == x and panel.y == y and panel.z == z then return panel end
    end
    return nil
end

-- The panel and utility a producer square is connected to, or nil.
function Store.producerOwner(x, y, z)
    for _, panel in pairs(Store.panels()) do
        for _, utility in ipairs(BU.UTILITIES) do
            for index, at in ipairs(panel[utility].producers) do
                if at.x == x and at.y == y and at.z == z then return panel, utility, index end
            end
        end
    end
    return nil
end

-- The panel that connected an outside device of a utility on its own, or nil.
function Store.includedOwner(utility, key)
    for _, panel in pairs(Store.panels()) do
        if panel[utility].included[key] then return panel end
    end
    return nil
end

-- The panel, other than one, that has a device of a utility in a room built onto its building, or nil.
function Store.attachedOwner(utility, key, except)
    for _, panel in pairs(Store.panels()) do
        local attached = panel[utility].attached
        if panel ~= except and attached and attached[key] then return panel end
    end
    return nil
end

-- The panel that takes a device as a single object of its own: one it connected outside, or one in a room built onto
-- its building. Nil when none does.
function Store.inclusionOwner(utility, key)
    return Store.includedOwner(utility, key) or Store.attachedOwner(utility, key)
end

-- Remembers what happened to a panel, for its window: a translation key and its arguments (strings or numbers).
function Store.record(panel, key, args)
    panel.log = panel.log or {}
    table.insert(panel.log, { hour = getGameTime():getWorldAgeHours(), key = key, args = args or {} })
    while #panel.log > Store.LOG_SIZE do table.remove(panel.log, 1) end
end

-- All panels, in the order they were made.
-- Every panel in the order they were made; kept while the boxes are the same (Store.linkVersion: a box added or taken
-- away) and the panels are the same table (a multiplayer client received the server's). A copy is handed out.
local listToken, listOf, listKept = nil, nil, nil

function Store.list()
    local panels = Store.panels()
    if listToken ~= Store.linkVersion() or listOf ~= panels then
        listKept = Store.inOrder(panels, "p", Store.data().next)
        listToken, listOf = Store.linkVersion(), panels
    end
    local result = {}
    for i = 1, #listKept do result[i] = listKept[i] end
    return result
end

-- Units.

function Store.units() return Store.data().units end

function Store.unit(id) return id and Store.units()[id] or nil end

-- Every unit in the order they were made, kept until one is added or taken away, or the units are another table (a
-- multiplayer client received the server's): the minute's work asks for them many times. By panel too, kept until a
-- unit's panel changes (Store.unitsChanged).
local sorted, sortedOf, byPanel = nil, nil, nil

-- Things numbered as they were made ("u1", "u2" ...; "p1" ...) in that order: by their numbers up to the next one,
-- with no sort (a save of many thousand units sorted takes seconds in the game's Lua); sorted only if some are not
-- numbered so.
local function inOrder(things, prefix, next)
    local list, count = {}, 0
    for _ in pairs(things) do count = count + 1 end
    for number = 1, (next or 1) - 1 do
        local thing = things[prefix .. number]
        if thing then list[#list + 1] = thing end
    end
    if #list == count then return list end
    list = {}
    local order = {}
    for id, thing in pairs(things) do
        list[#list + 1] = thing
        order[thing] = tonumber(tostring(id):sub(2)) or 0
    end
    table.sort(list, function(a, b) return order[a] < order[b] end)
    return list
end
Store.inOrder = inOrder

local function sortedUnits()
    local units = Store.units()
    if sorted and sortedOf == units then return sorted end
    sorted, sortedOf, byPanel = inOrder(units, "u", Store.data().nextUnit), units, nil
    return sorted
end

-- A unit added, taken away, or wired to another panel (unit.panel).
function Store.unitsChanged()
    sorted, byPanel = nil, nil
    Store.linksChanged()
end

function Store.newUnit(kind, x, y, z, sprite)
    local data = Store.data()
    local id = "u" .. data.nextUnit
    data.nextUnit = data.nextUnit + 1
    local unit = { id = id, kind = kind, x = x, y = y, z = z, sprite = sprite }
    data.units[id] = unit
    Store.unitsChanged()
    return unit
end

function Store.removeUnit(id)
    Store.units()[id] = nil
    Store.unitsChanged()
end

function Store.unitAt(x, y, z)
    for _, unit in pairs(Store.units()) do
        if unit.x == x and unit.y == y and unit.z == z then return unit end
    end
    return nil
end

-- All units, in the order they were made; of one kind, or wired to one panel, when given.
function Store.unitList(kind, panelId)
    local list = sortedUnits()
    if panelId then
        if not byPanel then
            byPanel = {}
            for _, unit in ipairs(list) do
                if unit.panel then
                    byPanel[unit.panel] = byPanel[unit.panel] or {}
                    table.insert(byPanel[unit.panel], unit)
                end
            end
        end
        list = byPanel[panelId] or {}
    end
    local result = {}
    for _, unit in ipairs(list) do
        if not kind or unit.kind == kind then result[#result + 1] = unit end
    end
    return result
end

-- What a panel's power did this minute: summed into its hour, the hour into energyLog once it is over.
function Store.recordEnergy(panel, made, used, charge)
    local hour = math.floor(getGameTime():getWorldAgeHours())
    local now = panel.energyNow
    if not now or now.hour ~= hour then
        if now and now.n > 0 then
            panel.energyLog = panel.energyLog or {}
            -- A far box is run now and then (Server.lua): the hours between were as the last one.
            local first = math.max(now.hour, hour - Store.ENERGY_HOURS)
            for each = first, hour - 1 do
                table.insert(panel.energyLog, { hour = each, made = now.made / now.n, used = now.used / now.n,
                    charge = now.charge })
            end
            while #panel.energyLog > Store.ENERGY_HOURS do table.remove(panel.energyLog, 1) end
        end
        now = { hour = hour, made = 0, used = 0, n = 0 }
        panel.energyNow = now
    end
    now.made, now.used, now.n, now.charge = now.made + made, now.used + used, now.n + 1, charge
end

-- What a pipe's tanks held this minute: kept as the hour's last, the hour into levelLog once it is over.
function Store.recordWater(panel, pipe, amount, capacity)
    local hour = math.floor(getGameTime():getWorldAgeHours())
    local logs = panel.water.levelLog
    local log = logs[pipe] or {}
    logs[pipe] = log
    local last = log[#log]
    if last and last.hour == hour then
        last.amount, last.capacity = amount, capacity
    else
        -- A far box is run now and then (Server.lua): the hours between held what the last one did.
        if last then
            for each = math.max(last.hour + 1, hour - Store.ENERGY_HOURS), hour - 1 do
                log[#log + 1] = { hour = each, amount = last.amount, capacity = last.capacity }
            end
        end
        log[#log + 1] = { hour = hour, amount = amount, capacity = capacity }
        while #log > Store.ENERGY_HOURS do table.remove(log, 1) end
    end
end

return Store
