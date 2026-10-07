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

local function positions(list)
    local result = {}
    for index, at in ipairs(list) do result[index] = { x = at.x, y = at.y, z = at.z } end
    return result
end

local function eachThing(set, action)
    for key in pairs(set) do
        local x, y, z, sprite = BU.parseThing(key)
        if x then action(x, y, z, sprite) end
    end
end

-- Defines both networks of a panel from the save. Its parent is set by Networks.link, once every panel exists.
function Networks.define(panel)
    for _, utility in ipairs(BU.UTILITIES) do
        local id = BU.networkId(panel.id, utility)
        change("define", id, utility, BU.POLICY[utility])
        if not panel.parent then change("setProducers", id, positions(panel[utility].producers)) end
        change("addBuilding", id, panel.x, panel.y, panel.z)
        eachThing(panel[utility].excluded, function(x, y, z, sprite) change("exclude", id, x, y, z, sprite) end)
        eachThing(panel[utility].included, function(x, y, z, sprite) change("include", id, x, y, z, sprite) end)
    end
    if panel.tripped then Networks.setEnabled(panel, false) end
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
    change("setProducers", BU.networkId(panel.id, utility), positions(panel[utility].producers))
end

-- "exclude", "include" or "reset" for one object.
function Networks.device(panel, utility, how, x, y, z, sprite)
    change(how, BU.networkId(panel.id, utility), x, y, z, sprite)
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
