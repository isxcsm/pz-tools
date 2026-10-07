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

-- Calls a function of PZToolsAPI.networks with this mod's handle first. Without the API it does nothing.
local function change(name, ...)
    local api = BU.api()
    if not api then return nil end
    local ok, result = pcall(api.networks[name], BU.handle(), ...)
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
-- device of the building is connected unless the player excluded it; one outside only when this panel connected it;
-- either is off while the box sheds it, keeps it off for its bank, has it off for a blackout or its timer has it off. A device the panel connected outside is in
-- included; any other it names is of its building.
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

-- The water networks defined for each panel now, by id: { parent, producers, rooms (a set of room ids) }. Not saved:
-- the networks are defined anew as a world loads.
local defined = {}

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
-- of the building is excluded from the first group's network, which has its room. Elsewhere the building's rule.
local function applyWaterRule(panel, key, floors)
    local x, y, z = BU.parseThing(key)
    if not x then return end
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
        applyRule(Water.networkFor(panel, group.id, z, floors), each, key)
    end
end

-- Brings the API's water networks of a panel to its data now: networks no longer wanted go, new ones are defined,
-- each gets its parent, producers and rooms, and the devices' rules where networks are new or a device's group or
-- floor network changed (all keys when given). Networks that stay keep what the API saw of their tanks. Sub-panels
-- hang from the first group's lowest network, so theirs follow too.
function Networks.defineWater(panel, keys)
    if not BU.api() then return end
    local layout, floors = Water.layout(panel)
    local before = defined[panel.id] or {}
    local now, fresh = {}, false
    local wanted = {}
    for _, network in ipairs(layout) do wanted[network.id] = network end
    -- In an order the API takes: every network exists before one hangs from it; the children of one going away hang
    -- from their new parents first; a tank leaves its old network before it joins another.
    for _, network in ipairs(layout) do
        if not before[network.id] then
            change("define", network.id, "water", BU.POLICY.water)
            if panel.water.frozen then change("setEnabled", network.id, false) end
            fresh = true
        end
    end
    for _, network in ipairs(layout) do
        local old = before[network.id]
        if not old or old.parent ~= network.parent then change("setParent", network.id, network.parent) end
    end
    for id in pairs(before) do
        if not wanted[id] then change("remove", id) end
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
    for key in pairs((fresh or not keys) and waterKeys(panel) or keys) do applyWaterRule(panel, key, floors) end
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

-- Defines a panel's networks from the save. A power sub-panel's parent is set by Networks.link, once every panel
-- exists; its water hangs from its main panel's on its own.
function Networks.define(panel)
    local id = powerId(panel)
    change("define", id, "power", BU.POLICY.power)
    if not panel.parent then change("setProducers", id, powerProducers(panel)) end
    addPowerMembers(panel)
    applyPowerRules(panel)
    if panel.tripped or panel.quietCut then Networks.setEnabled(panel, false) end
    Networks.applyLoss(panel)
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

-- The power network's load factor: what its line loses on the way (Panels.powerLine). An API from before load
-- factors has no loss.
function Networks.applyLoss(panel)
    local api = BU.api()
    if not (api and api.networks.setLoadFactor) then return end
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

-- Every panel of the save, as the world starts: main panels first, so that sub-panels' water hangs from theirs.
function Networks.defineAll()
    if not BU.api() then return end
    defined = {}
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
    if utility == "water" then return applyWaterRule(panel, key, select(2, Water.layout(panel))) end
    applyRule(powerId(panel), Networks.rule(panel, utility, key), key)
end

local function stateOf(id)
    local api = BU.api()
    return api and id and api.networks.state(id) or nil
end

-- A water group's state: its lowest network's, which reaches every tank of the group's tree.
function Networks.groupState(panel, group)
    return stateOf(Water.lowestId(panel, group))
end

-- The power network's state, or for water the panel's groups together: { supplied (any group), enabled, amount and
-- capacity (summed), producers (every tank as the networks last saw it), groups (by id, each group's state) }.
function Networks.state(panel, utility)
    if utility ~= "water" then return stateOf(powerId(panel)) end
    if not BU.api() then return nil end
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
