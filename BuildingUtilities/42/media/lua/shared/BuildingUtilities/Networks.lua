-- The panels' networks in the PZ Tools extension API: each panel has a power network and a water network over its
-- building. Defined from the save as the world starts; changed call by call afterwards, so the API keeps what it
-- has worked out (which producer runs, when supply stopped).
require "BuildingUtilities/Store"
local BU = BuildingUtilities
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

-- The producers as the API takes them: the units' source first (BU.Energy), so it is the first to take over when a
-- generator stops, then the squares in the player's order.
local function producerList(panel, utility)
    local result = {}
    if utility == "power" and BU.Energy.hasSource(panel) then result[1] = { source = BU.Energy.SOURCE } end
    for _, at in ipairs(panel[utility].producers) do result[#result + 1] = { x = at.x, y = at.y, z = at.z } end
    return result
end

-- What the network does with one device of a panel: "exclude", "include" or "reset" (the building's rule). A
-- device of the building is connected unless the player excluded it; one outside only when this panel connected it;
-- either is off while the box sheds it, keeps it off for its bank or its timer has it off. A device the panel connected outside is in
-- included; any other it names is of its building.
function Networks.rule(panel, utility, key)
    local data = panel[utility]
    local off = data.shed and data.shed[key] or data.saving and data.saving[key] or data.timed and data.timed[key]
    if not data.included[key] then return (data.excluded[key] or off) and "exclude" or "reset" end
    return off and "exclude" or "include"
end

local function apply(id, rule, key)
    local x, y, z, sprite = BU.parseThing(key)
    if x then change(rule, id, x, y, z, sprite) end
end

-- A room of the panel's building by its id, as Panels.rooms has it, or nil.
local function roomOf(panel, roomId)
    for _, room in ipairs(BU.Panels.rooms(BU.Panels.building(panel))) do
        if room.id == roomId then return room end
    end
    return nil
end

-- Takes a room in or out of a network, named by a square of it.
local function setRoom(id, room, on)
    local rect = room and room.rects[1]
    if rect then change(on and "addRoom" or "removeRoom", id, rect.x, rect.y, room.level) end
end

-- What the networks take of the building: all of it, or the rooms of the panel's zone.
local function addMembers(panel, id)
    if not panel.rooms then
        change("addBuilding", id, panel.x, panel.y, panel.z)
        return
    end
    for roomId in pairs(panel.rooms) do setRoom(id, roomOf(panel, roomId), true) end
end

-- The panel's zone changed from before (a set of room ids, or nil for the whole building) to what it has now.
function Networks.setZone(panel, before)
    local now = panel.rooms
    for _, utility in ipairs(BU.UTILITIES) do
        local id = BU.networkId(panel.id, utility)
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
    end
end

-- Defines both networks of a panel from the save. Its parent is set by Networks.link, once every panel exists.
function Networks.define(panel)
    for _, utility in ipairs(BU.UTILITIES) do
        local id = BU.networkId(panel.id, utility)
        change("define", id, utility, BU.POLICY[utility])
        if not panel.parent then change("setProducers", id, producerList(panel, utility)) end
        addMembers(panel, id)
        local data, keys = panel[utility], {}
        for _, set in ipairs({ data.excluded, data.included, data.shed or {}, data.saving or {}, data.timed or {} }) do
            for key in pairs(set) do keys[key] = true end
        end
        for key in pairs(keys) do
            local rule = Networks.rule(panel, utility, key)
            if rule ~= "reset" then apply(id, rule, key) end
        end
    end
    if panel.tripped or panel.quietCut then Networks.setEnabled(panel, false) end
    Networks.applyLoss(panel)
end

-- The power network's load factor: what its line loses on the way (Panels.powerLine). An API from before load
-- factors has no loss.
function Networks.applyLoss(panel)
    local api = BU.api()
    if not (api and api.networks.setLoadFactor) then return end
    local _, percent = BU.Panels.powerLine(panel, Networks.state(panel, "power"))
    change("setLoadFactor", BU.networkId(panel.id, "power"), 1 + (percent or 0) / 100)
end

-- The power network on or off: a box's breaker.
function Networks.setEnabled(panel, on)
    change("setEnabled", BU.networkId(panel.id, "power"), on)
end

function Networks.link(panel)
    for _, utility in ipairs(BU.UTILITIES) do
        change("setParent", BU.networkId(panel.id, utility), panel.parent and BU.networkId(panel.parent, utility) or nil)
    end
end

-- Every panel of the save, as the world starts.
function Networks.defineAll()
    if not BU.api() then return end
    local panels = BU.Store.list()
    for _, panel in ipairs(panels) do Networks.define(panel) end
    for _, panel in ipairs(panels) do if panel.parent then Networks.link(panel) end end
end

function Networks.remove(panel)
    for _, utility in ipairs(BU.UTILITIES) do change("remove", BU.networkId(panel.id, utility)) end
end

function Networks.setProducers(panel, utility)
    change("setProducers", BU.networkId(panel.id, utility), producerList(panel, utility))
end

-- What the bank takes to charge from the producer in use (the charge controller).
function Networks.setExtraLoad(panel, load)
    change("setExtraLoad", BU.networkId(panel.id, "power"), load)
end

-- The units' source: whether it carries the load, and switched on (true) or left (nil).
function Networks.setSource(panel, available, switchOn)
    change("setSource", BU.networkId(panel.id, "power"), BU.Energy.SOURCE, available, switchOn)
end

-- One device as the panel's data has it now (Networks.rule).
function Networks.apply(panel, utility, key)
    apply(BU.networkId(panel.id, utility), Networks.rule(panel, utility, key), key)
end

function Networks.state(panel, utility)
    local api = BU.api()
    return api and api.networks.state(BU.networkId(panel.id, utility)) or nil
end

-- The objects the network supplies on loaded squares, and whether every square was loaded.
function Networks.consumers(panel, utility)
    local api = BU.api()
    if not api then return nil, false end
    return api.networks.consumers(BU.networkId(panel.id, utility))
end

-- The panel and utility of one of this mod's network ids, or nil.
function Networks.owner(networkId)
    local id, utility = tostring(networkId):match("^bu%-(p%d+)%-(%a+)$")
    if not id then return nil end
    return BU.Store.get(id), utility
end

return Networks
