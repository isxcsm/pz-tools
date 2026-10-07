-- The panels' networks in the PZ Tools extension API: each panel has a power network over its building, and its
-- water as a network per water group and floor (BU.Water). Defined from the save as the world starts; changed call
-- by call afterwards, so the API keeps what it has worked out (which producer runs, when supply stopped, what tanks
-- held when last seen).
require "BuildingUtilities/Store"
require "BuildingUtilities/Water"
local BU = BuildingUtilities
local Store, Water = BU.Store, BU.Water
local Networks = {}
BU.Networks = Networks

-- The utility of one of this mod's network ids ("bu-p3-power", "bu-p3-water-g1-L0"), or nil.
local function utilityOf(id) return tostring(id):match("^bu%-p%d+%-(%a+)") end

-- Calls a function of PZToolsAPI.networks with this mod's handle first, on the network id. Without the API it does
-- nothing; a utility turned off in the sandbox (BU.enabled) has no networks, and nothing is asked of them but to go.
local function change(name, id, ...)
    local api = BU.api()
    if not api then return nil end
    if name ~= "remove" and not BU.enabled(utilityOf(id)) then return nil end
    local ok, result = pcall(api.networks[name], BU.handle(), id, ...)
    if not ok then BU.log("networks." .. name .. " failed:", result); return nil end
    return result
end

local function powerId(panel) return BU.networkId(panel.id, "power") end

-- The power producers as the API takes them: the units' source first (BU.Energy), so it is the first to take over
-- when a generator stops, then the squares in the player's order.
local function powerProducers(panel)
    local result = {}
    if BU.Energy.hasSource(panel) then result[1] = { source = BU.Energy.SOURCE } end
    for _, at in ipairs(panel.power.producers) do result[#result + 1] = { x = at.x, y = at.y, z = at.z } end
    return result
end

-- What the network does with one device of a panel: "exclude", "include" or "reset" (the building's rule). A
-- device of the building is connected unless the player excluded it; one outside only when this panel connected it
-- (it is in included; any other the panel names is of its building); either is off while the box sheds it, keeps it
-- off for its bank, has it off for a blackout or its timer has it off.
function Networks.rule(panel, utility, key)
    local data = panel[utility]
    local off = data.shed and data.shed[key] or data.saving and data.saving[key] or data.blackout and data.blackout[key]
        or data.timed and data.timed[key]
    if not data.included[key] then return (data.excluded[key] or off) and "exclude" or "reset" end
    return off and "exclude" or "include"
end

local function applyRule(id, rule, key)
    local x, y, z, sprite = BU.parseThing(key)
    if x and id then change(rule, id, x, y, z, sprite) end
end

-- A room's square, for the API's addRoom and removeRoom.
local function setRoom(id, room, on)
    local rect = room and room.rects[1]
    if rect then change(on and "addRoom" or "removeRoom", id, rect.x, rect.y, room.level) end
end

-- A room of the panel's building by its id, as Panels.rooms has it, or nil.
local function roomOf(panel, roomId)
    for _, room in ipairs(BU.Panels.rooms(BU.Panels.building(panel))) do
        if room.id == roomId then return room end
    end
    return nil
end

-- Power: the building, or the rooms of the panel's zone.
local function addPowerMembers(panel)
    local id = powerId(panel)
    if not panel.rooms then
        change("addBuilding", id, panel.x, panel.y, panel.z)
        return
    end
    for roomId in pairs(panel.rooms) do setRoom(id, roomOf(panel, roomId), true) end
end

-- The power network's rules for every device the panel names.
local function applyPowerRules(panel)
    local data, keys = panel.power, {}
    for _, set in ipairs({ data.excluded, data.included, data.shed or {}, data.saving or {}, data.blackout or {}, data.timed or {} }) do
        for key in pairs(set) do keys[key] = true end
    end
    for key in pairs(keys) do
        local rule = Networks.rule(panel, "power", key)
        if rule ~= "reset" then applyRule(powerId(panel), rule, key) end
    end
end

-- Water.

-- Whether the panels' water can be networks: water is on (BU.enabled) and in this game (BU.waterAvailable).
local function waterOn() return BU.enabled("water") and BU.waterAvailable() end

-- The water networks defined for each panel now, by id: { parent, producers, rooms (a set of room ids) }. Not saved:
-- the networks are defined anew as a world loads.
local defined = {}
-- Whether every panel's power networks, and water networks, are defined now: as the features were when the world
-- started or Networks.applyFeatures last ran.
local powerDefined, waterDefined = false, false

-- Every water device key a panel names, as a set.
local function waterKeys(panel)
    local data, keys = panel.water, {}
    for _, set in ipairs({ data.excluded, data.included, data.groupOf or {} }) do
        for key in pairs(set) do keys[key] = true end
    end
    return keys
end

-- One water device's rules in each group's network for its floor. In the first group it is as the panel's rule has
-- it (Networks.rule). Moved to another group, it is included there unless the player switched it off, and a fixture
-- of the building is excluded from the first group's network, which has its room. Elsewhere the building's rule; on
-- a group's other floors, none (reset), so that a rule left where the device mapped before goes.
local function applyWaterRule(panel, key, floors)
    local x, y, z = BU.parseThing(key)
    if not x or not waterOn() then return end
    local mine = Water.deviceGroup(panel, { key })
    local rule = Networks.rule(panel, "water", key)
    local inside = not panel.water.included[key]
    for _, group in ipairs(Water.groups(panel)) do
        local each = "reset"
        if mine == Water.FIRST then
            if group.id == Water.FIRST then each = rule end
        elseif group.id == mine then
            each = rule == "exclude" and "reset" or "include"
        elseif group.id == Water.FIRST and inside then
            each = "exclude"
        end
        local target = Water.networkFor(panel, group.id, z, floors)
        for _, level in ipairs(Water.levels(panel, group.id, floors)) do
            local id = Water.networkId(panel, group.id, level)
            applyRule(id, id == target and each or "reset", key)
        end
    end
end

-- Defines a water network. A game whose API cannot take water networks refuses it (an API that predates hooks()
-- does not tell before): water is then off for this world (BU.waterAvailable), and nothing else is tried.
local function defineWaterNetwork(id)
    local ok, failure = pcall(BU.api().networks.define, BU.handle(), id, "water", BU.POLICY.water)
    if not ok then BU.hookFault("water", failure) end
    return ok
end

-- Brings the API's water networks of a panel to its data now: networks no longer wanted go, new ones are defined,
-- each gets its parent, producers and rooms, and the devices' rules: every device's where a network came or went (a
-- device may map to another floor's network now), else the keys given (all when none are). Networks that stay keep
-- what the API saw of their tanks. Sub-panels hang from the first group's lowest network, so theirs follow too.
function Networks.defineWater(panel, keys)
    if not waterOn() then return end
    local layout, floors = Water.layout(panel)
    local before = defined[panel.id] or {}
    local now, floorsChanged = {}, false
    local wanted = {}
    for _, network in ipairs(layout) do wanted[network.id] = network end
    -- In an order the API takes: every network exists before one hangs from it; the children of one going away hang
    -- from their new parents first; a tank leaves its old network before it joins another. A sub-panel's water is
    -- cut with its main panel's when that freezes, never on its own.
    for _, network in ipairs(layout) do
        if not before[network.id] then
            if not defineWaterNetwork(network.id) then return end
            if panel.water.frozen and not panel.parent then change("setEnabled", network.id, false) end
            floorsChanged = true
        end
    end
    for _, network in ipairs(layout) do
        local old = before[network.id]
        if not old or old.parent ~= network.parent then change("setParent", network.id, network.parent) end
    end
    for id in pairs(before) do
        if not wanted[id] then
            change("remove", id)
            floorsChanged = true
        end
    end
    local tanks = {}
    for _, network in ipairs(layout) do
        local list = {}
        for _, at in ipairs(network.producers) do list[#list + 1] = at.x .. "," .. at.y .. "," .. at.z end
        table.sort(list)
        tanks[network.id] = table.concat(list, ";")
        local old = before[network.id]
        if old and old.tanks ~= tanks[network.id] then change("setProducers", network.id, {}) end
    end
    for _, network in ipairs(layout) do
        local old = before[network.id]
        if not old or old.tanks ~= tanks[network.id] then change("setProducers", network.id, network.producers) end
    end
    for _, network in ipairs(layout) do
        local old = before[network.id]
        local rooms = {}
        for _, room in ipairs(network.rooms) do rooms[room.id] = room end
        for roomId, room in pairs(rooms) do
            if not (old and old.rooms[roomId]) then setRoom(network.id, room, true) end
        end
        for roomId, room in pairs(old and old.rooms or {}) do
            if not rooms[roomId] then setRoom(network.id, room, false) end
        end
        now[network.id] = { parent = network.parent, rooms = rooms, tanks = tanks[network.id] }
    end
    defined[panel.id] = now
    for key in pairs((floorsChanged or not keys) and waterKeys(panel) or keys) do applyWaterRule(panel, key, floors) end
    if panel.parent == nil then
        for _, child in ipairs(Store.children(panel.id)) do
            if defined[child.id] then Networks.defineWater(child, {}) end
        end
    end
end

-- A panel's water on or off: its pipes thawed or frozen. Its sub-panels' hang from its networks and go with them.
function Networks.setWaterEnabled(panel, on)
    for id in pairs(defined[panel.id] or {}) do change("setEnabled", id, on) end
end

-- Takes a panel's water networks away.
local function removeWater(panel)
    for id in pairs(defined[panel.id] or {}) do change("remove", id) end
    defined[panel.id] = nil
end

-- What the box adds to its devices' load, all its parts together (BU.Changes.setExtraLoad).
function Networks.extraLoad(panel)
    local total = 0
    for _, each in pairs(panel.extraLoads or {}) do total = total + each end
    return total
end

-- Defines a panel's networks from the save. A power sub-panel's parent is set by Networks.link, once every panel
-- exists; its water hangs from its main panel's on its own. The network gets the extra load the box had (charging,
-- pumps) at once, as the charge controller reads its load with it, until the first minute works it out again; none
-- while the breaker is down.
function Networks.define(panel)
    local id = powerId(panel)
    change("define", id, "power", BU.POLICY.power)
    if not panel.parent then change("setProducers", id, powerProducers(panel)) end
    addPowerMembers(panel)
    applyPowerRules(panel)
    if panel.tripped or panel.quietCut then Networks.setEnabled(panel, false) end
    Networks.applyLoss(panel)
    local extra = panel.tripped and 0 or Networks.extraLoad(panel)
    if extra > 0 then Networks.setExtraLoad(panel, extra) end
    if not panel.parent then Networks.defineWater(panel) end
end

-- The panel's zone changed from before (a set of room ids, or nil for the whole building) to what it has now.
function Networks.setZone(panel, before)
    local id, now = powerId(panel), panel.rooms
    if not before then change("removeBuilding", id, panel.x, panel.y, panel.z) end
    if not now then
        for roomId in pairs(before or {}) do setRoom(id, roomOf(panel, roomId), false) end
        change("addBuilding", id, panel.x, panel.y, panel.z)
    else
        for roomId in pairs(before or {}) do
            if not now[roomId] then setRoom(id, roomOf(panel, roomId), false) end
        end
        for roomId in pairs(now) do
            if not (before and before[roomId]) then setRoom(id, roomOf(panel, roomId), true) end
        end
    end
    Networks.defineWater(panel)
end

-- The power network's load factor: what its line loses on the way (Panels.powerLine).
function Networks.applyLoss(panel)
    if not BU.api() or not BU.enabled("power") then return end
    local _, percent = BU.Panels.powerLine(panel, Networks.state(panel, "power"))
    change("setLoadFactor", powerId(panel), 1 + (percent or 0) / 100)
end

-- The power network on or off: a box's breaker.
function Networks.setEnabled(panel, on)
    change("setEnabled", powerId(panel), on)
end

-- A panel joined or left a main panel: its power network's parent, and its water anew (as a sub-panel it has the
-- first group only, hanging from the main panel's).
function Networks.link(panel)
    change("setParent", powerId(panel), panel.parent and BU.networkId(panel.parent, "power") or nil)
    removeWater(panel)
    Networks.defineWater(panel)
end

-- Every panel of the save, as the world starts: main panels first, so that sub-panels' water hangs from theirs. Only
-- the utilities that are on (BU.enabled).
function Networks.defineAll()
    if not BU.api() then return end
    defined = {}
    powerDefined, waterDefined = BU.enabled("power"), waterOn()
    local panels = Store.list()
    for _, panel in ipairs(panels) do Networks.define(panel) end
    for _, panel in ipairs(panels) do
        if panel.parent then
            change("setParent", powerId(panel), BU.networkId(panel.parent, "power"))
            Networks.defineWater(panel)
        end
    end
end

function Networks.remove(panel)
    change("remove", powerId(panel))
    removeWater(panel)
end

-- A utility turned on or off in the sandbox since the networks were defined (BU.Changes.applyFeatures): turned off,
-- every panel's networks of it go, which gives their producers back to the game; turned on, they are defined from the
-- save, main panels first, as the world starts.
function Networks.applyFeatures()
    if not BU.api() then return end
    local panels = Store.list()
    local power, water = BU.enabled("power"), waterOn()
    if power ~= powerDefined then
        powerDefined = power
        for _, panel in ipairs(panels) do
            if power then Networks.define(panel) else change("remove", powerId(panel)) end
        end
        for _, panel in ipairs(power and panels or {}) do
            if panel.parent then change("setParent", powerId(panel), BU.networkId(panel.parent, "power")) end
        end
    end
    if water ~= waterDefined then
        waterDefined = water
        for _, panel in ipairs(panels) do
            if not water then removeWater(panel) elseif not panel.parent then Networks.defineWater(panel) end
        end
        for _, panel in ipairs(water and panels or {}) do
            if panel.parent then Networks.defineWater(panel) end
        end
    end
end

function Networks.setProducers(panel, utility)
    if utility == "water" then return Networks.defineWater(panel, {}) end
    change("setProducers", powerId(panel), powerProducers(panel))
end

-- What the bank takes to charge from the producer in use (the charge controller).
function Networks.setExtraLoad(panel, load)
    change("setExtraLoad", powerId(panel), load)
end

-- The units' source: whether it carries the load, and switched on (true) or left (nil).
function Networks.setSource(panel, available, switchOn)
    change("setSource", powerId(panel), BU.Energy.SOURCE, available, switchOn)
end

-- One device as the panel's data has it now (Networks.rule; for water in each group, applyWaterRule).
function Networks.apply(panel, utility, key)
    if utility == "water" then
        if waterOn() then applyWaterRule(panel, key, select(2, Water.layout(panel))) end
        return
    end
    applyRule(powerId(panel), Networks.rule(panel, utility, key), key)
end

-- A network's state; nil for a utility that is off (BU.enabled).
local function stateOf(id)
    local api = BU.api()
    return api and id and BU.enabled(utilityOf(id)) and api.networks.state(id) or nil
end

-- The water calls below take floors, Water.layout's second result, when the caller has it for the panel: working
-- the layout out reads the building's rooms. Without water (off, or not in this game: waterOn) they do nothing.

-- A water group's state: its lowest network's, which reaches every tank of the group's tree.
function Networks.groupState(panel, group, floors)
    if not waterOn() then return nil end
    return stateOf(Water.lowestId(panel, group, floors))
end

-- Litres of a fluid into a group's tanks: its lowest floor's network draws from every floor above, so it reaches them
-- all. The litres they took.
function Networks.fill(panel, group, litres, fluid, floors)
    local id = waterOn() and Water.lowestId(panel, group, floors)
    return id and change("fill", id, litres, fluid) or 0
end

-- Litres out of a group's tanks for something on a floor, as a fixture there draws. The litres drawn.
function Networks.draw(panel, group, z, litres, floors)
    local id = waterOn() and Water.networkFor(panel, group, z, floors)
    return id and change("draw", id, litres) or 0
end

-- A group's water purified as its fixtures take it (as the game's pipes do, and the API by default), or left as its
-- tanks hold it. Each of its floors' networks; only those that differ are changed. A game without the hooks that
-- keep the taint refuses false: the pipes purify then (BU.purifyAvailable), and the callers stop asking.
function Networks.setGroupPurify(panel, group, on, floors)
    if not waterOn() then return end
    for _, level in ipairs(Water.levels(panel, group, floors)) do
        local id = Water.networkId(panel, group, level)
        local state = stateOf(id)
        if state and state.purify ~= on then
            local ok, failure = pcall(BU.api().networks.setPurify, BU.handle(), id, on)
            if not ok and not on then BU.hookFault("purify", failure); return end
            if not ok then BU.log("networks.setPurify failed:", failure) end
        end
    end
end

-- The power network's state, or for water the panel's groups together: { supplied (any group), enabled, amount and
-- capacity (summed), producers (every tank as the networks last saw it), groups (by id, each group's state) }; nil
-- for a utility that is off, or without water in this game.
function Networks.state(panel, utility)
    if utility ~= "water" then return stateOf(powerId(panel)) end
    if not waterOn() then return nil end
    local result = { supplied = false, enabled = true, amount = 0, capacity = 0, producers = {}, groups = {} }
    local layout, floors = Water.layout(panel)
    for _, group in ipairs(Water.groups(panel)) do
        local state = stateOf(Water.lowestId(panel, group.id, floors))
        result.groups[group.id] = state
        if state then
            result.supplied = result.supplied or state.supplied == true
            result.amount = result.amount + (state.amount or 0)
            result.capacity = result.capacity + (state.capacity or 0)
        end
    end
    -- A sub-panel's lowest network reaches its main panel's tanks: its own lists none.
    for _, network in ipairs(layout) do
        local state = #network.producers > 0 and stateOf(network.id)
        for _, producer in ipairs(state and state.producers or {}) do result.producers[#result.producers + 1] = producer end
    end
    return result
end

-- The panel, utility and, for water, group and floor of one of this mod's network ids, or nil.
function Networks.owner(networkId)
    local text = tostring(networkId)
    local id, group, level = text:match("^bu%-(p%d+)%-water%-g(%d+)%-L(%-?%d+)$")
    if id then return Store.get(id), "water", tonumber(group), tonumber(level) end
    id = text:match("^bu%-(p%d+)%-power$")
    if id then return Store.get(id), "power" end
    return nil
end

return Networks
