-- What the mod keeps in the save: the breaker boxes and what is connected to them. The API keeps nothing; the
-- networks are defined again from this each time a world loads.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Store = {}
BU.Store = Store

local KEY = "BuildingUtilities"

-- { version, next, panels = { [id] = panel } }. A panel:
--   id, x, y, z (the box's square), sprite, name (set by the player, or nil), tier (1 to BU.TIERS), tripped (its
--   breaker is down), parent (a panel id, or nil) and parentPaid (what linking it cost), rooms (its zone: a set of
--   the building's room ids it takes, or nil for the whole building),
--   log (what happened to it, oldest first: { hour, key, args }, at most Store.LOG_SIZE),
--   and per utility (power, water): producers (a list of { x, y, z, paid }, in order), excluded (a set of
--   BU.thingKey) and included (BU.thingKey to what connecting it cost); for power also essential (a set: the box
--   never sheds them), schedule (BU.thingKey to a timer of BU.SCHEDULES), and what the box keeps off on its own:
--   shed (a set, under overload), saving (a set, keeping a low battery bank), blackout (a set: its lights, off by
--   the player at the box) and timed (a set, by their timers).
--   For water also groups (the player's water groups, BU.Water: a list of { id, name, reserve (the percent its
--   tanks keep from sprinklers, or nil), overflow (the group its pumps fill once it is full, or nil) }, the first
--   always there),
--   nextGroup, groupOf (BU.thingKey to the group of a fixture not in the first) and levelLog (by group, what its
--   tanks held hour by hour, oldest first, at most Store.ENERGY_HOURS: { hour, amount, capacity }); a water producer
--   may have group (nil for the first). With the freezing risk: frozen (its pipes are), coldHours and warmHours
--   (how long it has been below freezing or above thawing at the box).
--   energyLog: what the panel's power did hour by hour, oldest first, at most Store.ENERGY_HOURS: { hour (world age,
--   whole), made (what its solar panels made, on average), used (the load supplied), charge (its bank's at the end,
--   or nil) }; energyNow is the hour being summed { hour, made, used, n, charge }.
--   A panel with units may keep controller (the charge controller's settings, BU.Energy.settings), quietCut (its
--   power is off because the bank ran empty in quiet hours) and sourceOn (its units' source carried the load when last
--   seen: a world loaded again defines the source off, and the server switches it back on). extraLoads: what the box
--   adds to its devices' load, by part (BU.Changes.setExtraLoad).
-- units = { [id] = unit }: the solar panels, battery racks, pumps, sprinklers and filters this mod put down (BU.Units).
-- A unit:
--   id, kind (BU.Units.KINDS), x, y, z (its square), sprite, panel (the main panel it is wired to, or nil) and
--   paid (what that line took); a solar panel also snow (0 to 1, nil for none); a rack also batteries, a record of
--   each car battery in its container (BU.Rack.sync): { id (the item's), type, charge 0 to 1, condition 0 to
--   100, revived: how often it was reconditioned }. A water unit may have group (the panel's water group it works
--   for; nil for the first); a pump has fluid ("Water" from a well, "TaintedWater" from a river or lake) and
--   running (it lifted water at the last minute); a sprinkler sprayedAt (the world age it last watered at); a filter
--   media (hours of use left in its charge) and working (it purified its group's water at the last minute).
-- energyHour: the world age the units were last worked out at (Server). A panel with a bank keeps bankFlow, what
-- went into its batteries per hour at the last minute (out of them when below 0), for its window.
-- "paid" is { [item type] = count }. On a client in multiplayer this is the server's, received; only the server
-- changes it (BU.Changes).
Store.KEY = KEY
Store.LOG_SIZE = 30
Store.ENERGY_HOURS = 48
-- 3: four tiers; a box of tier 3, which shed load, is tier 4 now (shedding moved there). 4: units. 5: saving and
-- blackout. 6: water groups.
local VERSION = 6

local function utilityData()
    return { producers = {}, excluded = {}, included = {}, essential = {}, schedule = {}, shed = {}, saving = {}, blackout = {},
        timed = {} }
end

-- What water keeps besides: one group, every tank and fixture in it.
local function waterData(data)
    data.groups = data.groups or { { id = 1 } }
    data.nextGroup = data.nextGroup or 2
    data.groupOf = data.groupOf or {}
    data.levelLog = data.levelLog or {}
end

-- A panel saved by an older version gets what this one keeps.
local function migrate(panel, from)
    panel.tier = panel.tier or 1
    if from < 3 and panel.tier == 3 then panel.tier = 4 end
    panel.tripped = panel.tripped == true
    panel.log = panel.log or {}
    for _, utility in ipairs(BU.UTILITIES) do
        local data = panel[utility]
        for name, empty in pairs(utilityData()) do
            if data[name] == nil then data[name] = empty end
        end
    end
    waterData(panel.water)
end

function Store.data()
    local data = ModData.getOrCreate(KEY)
    if not data.version then
        data.version = VERSION
        data.next = 1
        data.panels = {}
    elseif data.version < VERSION then
        for _, panel in pairs(data.panels) do migrate(panel, data.version) end
        data.version = VERSION
    end
    if not data.units then
        data.units = {}
        data.nextUnit = 1
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
    return panel
end

-- Forgets a panel. Its sub-panels become main panels again, without producers until the player connects some.
function Store.remove(id)
    local panels = Store.panels()
    panels[id] = nil
    for _, other in pairs(panels) do
        if other.parent == id then other.parent = nil end
    end
end

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
function Store.inclusionOwner(utility, key)
    for _, panel in pairs(Store.panels()) do
        if panel[utility].included[key] then return panel end
    end
    return nil
end

-- The panels whose parent is this one.
function Store.children(id)
    local result = {}
    for _, panel in pairs(Store.panels()) do
        if panel.parent == id then result[#result + 1] = panel end
    end
    table.sort(result, function(a, b) return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2)) end)
    return result
end

-- Remembers what happened to a panel, for its window: a translation key and its arguments (strings or numbers).
function Store.record(panel, key, args)
    panel.log = panel.log or {}
    table.insert(panel.log, { hour = getGameTime():getWorldAgeHours(), key = key, args = args or {} })
    while #panel.log > Store.LOG_SIZE do table.remove(panel.log, 1) end
end

-- All panels, in the order they were made.
function Store.list()
    local result = {}
    for _, panel in pairs(Store.panels()) do result[#result + 1] = panel end
    table.sort(result, function(a, b) return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2)) end)
    return result
end

-- Units.

function Store.units() return Store.data().units end

function Store.unit(id) return id and Store.units()[id] or nil end

function Store.newUnit(kind, x, y, z, sprite)
    local data = Store.data()
    local id = "u" .. data.nextUnit
    data.nextUnit = data.nextUnit + 1
    local unit = { id = id, kind = kind, x = x, y = y, z = z, sprite = sprite }
    data.units[id] = unit
    return unit
end

function Store.removeUnit(id) Store.units()[id] = nil end

function Store.unitAt(x, y, z)
    for _, unit in pairs(Store.units()) do
        if unit.x == x and unit.y == y and unit.z == z then return unit end
    end
    return nil
end

-- All units, in the order they were made; of one kind, or wired to one panel, when given.
function Store.unitList(kind, panelId)
    local result = {}
    for _, unit in pairs(Store.units()) do
        if (not kind or unit.kind == kind) and (not panelId or unit.panel == panelId) then result[#result + 1] = unit end
    end
    table.sort(result, function(a, b) return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2)) end)
    return result
end

-- What a panel's power did this minute: summed into its hour, the hour into energyLog once it is over.
function Store.recordEnergy(panel, made, used, charge)
    local hour = math.floor(getGameTime():getWorldAgeHours())
    local now = panel.energyNow
    if not now or now.hour ~= hour then
        if now and now.n > 0 then
            panel.energyLog = panel.energyLog or {}
            table.insert(panel.energyLog, { hour = now.hour, made = now.made / now.n, used = now.used / now.n, charge = now.charge })
            while #panel.energyLog > Store.ENERGY_HOURS do table.remove(panel.energyLog, 1) end
        end
        now = { hour = hour, made = 0, used = 0, n = 0 }
        panel.energyNow = now
    end
    now.made, now.used, now.n, now.charge = now.made + made, now.used + used, now.n + 1, charge
end

-- What a water group's tanks held this minute: kept as the hour's last, the hour into levelLog once it is over.
function Store.recordWater(panel, group, amount, capacity)
    local hour = math.floor(getGameTime():getWorldAgeHours())
    local logs = panel.water.levelLog
    local log = logs[group] or {}
    logs[group] = log
    local last = log[#log]
    if last and last.hour == hour then
        last.amount, last.capacity = amount, capacity
    else
        log[#log + 1] = { hour = hour, amount = amount, capacity = capacity }
        while #log > Store.ENERGY_HOURS do table.remove(log, 1) end
    end
end

return Store
