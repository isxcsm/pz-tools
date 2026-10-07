-- What the mod keeps in the save: the breaker boxes and what is connected to them. The API keeps nothing; the
-- networks are defined again from this each time a world loads.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Store = {}
BU.Store = Store

local KEY = "BuildingUtilities"

-- { version, next, panels = { [id] = panel } }. A panel:
--   id, x, y, z (the box's square), sprite, name (set by the player, or nil), tier (1 to BU.TIERS), tripped (its
--   breaker is down), parent (a panel id, or nil) and parentPaid (what linking it cost),
--   log (what happened to it, oldest first: { hour, key, args }, at most Store.LOG_SIZE),
--   and per utility (power, water): producers (a list of { x, y, z, paid }, in order), excluded (a set of
--   BU.thingKey) and included (BU.thingKey to what connecting it cost); for power also essential (a set: the box
--   never sheds them), schedule (BU.thingKey to a timer of BU.SCHEDULES), and what the box keeps off on its own:
--   shed (a set, under overload) and timed (a set, by their timers).
-- "paid" is { [item type] = count }. On a client in multiplayer this is the server's, received; only the server
-- changes it (BU.Changes).
Store.KEY = KEY
Store.LOG_SIZE = 30
local VERSION = 2

local function utilityData()
    return { producers = {}, excluded = {}, included = {}, essential = {}, schedule = {}, shed = {}, timed = {} }
end

-- A panel saved by an older version gets what this one keeps.
local function migrate(panel)
    panel.tier = panel.tier or 1
    panel.tripped = panel.tripped == true
    panel.log = panel.log or {}
    for _, utility in ipairs(BU.UTILITIES) do
        local data = panel[utility]
        for name, empty in pairs(utilityData()) do
            if data[name] == nil then data[name] = empty end
        end
    end
end

function Store.data()
    local data = ModData.getOrCreate(KEY)
    if not data.version then
        data.version = VERSION
        data.next = 1
        data.panels = {}
    elseif data.version < VERSION then
        for _, panel in pairs(data.panels) do migrate(panel) end
        data.version = VERSION
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

return Store
