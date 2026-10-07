-- Every change to the boxes, where the world is decided: the server, or the game alone. Called from the server's
-- command handler and from the timed actions' complete, which run there. Each goes to the save, then to the API,
-- then to the players (BU.Sync). Callers have checked the rules (BU.Panels) and taken the costs (BU.Costs).
require "BuildingUtilities/Panels"
require "BuildingUtilities/Sync"
local BU = BuildingUtilities
local Store, Networks, Panels, Sync = BU.Store, BU.Networks, BU.Panels, BU.Sync
local Changes = {}
BU.Changes = Changes

-- Puts a box on the square and starts its networks.
function Changes.install(square, sprite)
    local object = IsoObject.new(square, sprite, nil, false)
    local panel = Store.newPanel(square:getX(), square:getY(), square:getZ(), sprite)
    object:getModData()[Panels.MODDATA] = panel.id
    square:AddTileObject(object)
    if isServer() then object:transmitCompleteItemToClients() end
    Networks.define(panel)
    BU.log("installed", panel.id, "at", panel.x, panel.y, panel.z)
    Sync.changed(panel.id)
    return panel
end

-- Everything a panel's lines took: its producers', its outside devices', its own link's and its sub-panels' links,
-- which go with it. For giving back a share when it is taken down.
function Changes.paidFor(panel)
    local total = {}
    local function add(paid)
        if type(paid) ~= "table" then return end
        for itemType, count in pairs(paid) do total[itemType] = (total[itemType] or 0) + count end
    end
    for _, utility in ipairs(BU.UTILITIES) do
        for _, producer in ipairs(panel[utility].producers) do add(producer.paid) end
        for _, paid in pairs(panel[utility].included) do add(paid) end
    end
    add(panel.parentPaid)
    for _, child in ipairs(Store.children(panel.id)) do add(child.parentPaid) end
    return total
end

-- Takes a panel away: its networks go, its producers are the game's again, its sub-panels become main panels.
function Changes.remove(panel)
    local object = Panels.object(panel)
    if object then object:getSquare():transmitRemoveItemFromSquare(object) end
    Networks.remove(panel)
    for _, child in ipairs(Store.children(panel.id)) do
        child.parent, child.parentPaid = nil, nil
        Networks.link(child)
    end
    Store.remove(panel.id)
    BU.log("removed", panel.id)
    Sync.changed(panel.id)
end

-- A panel whose box is gone from its loaded square (destroyed, or taken by other means) is removed too.
function Changes.checkObjects()
    for _, panel in ipairs(Store.list()) do
        local square = getCell():getGridSquare(panel.x, panel.y, panel.z)
        if square and not Panels.object(panel) then
            BU.log("the box of", panel.id, "is gone")
            Changes.remove(panel)
        end
    end
end

-- Producers. A new one is used after those connected before.

function Changes.connectProducer(panel, utility, x, y, z, paid)
    table.insert(panel[utility].producers, { x = x, y = y, z = z, paid = paid })
    Networks.setProducers(panel, utility)
    Sync.changed(panel.id)
end

-- Disconnects the producer on a square; returns what its line took, or nil when it was none of the panel's.
function Changes.disconnectProducer(panel, utility, x, y, z)
    local list = panel[utility].producers
    for index, at in ipairs(list) do
        if at.x == x and at.y == y and at.z == z then
            table.remove(list, index)
            Networks.setProducers(panel, utility)
            Sync.changed(panel.id)
            return at.paid or {}
        end
    end
    return nil
end

-- Moves a producer up (-1) or down (+1) the order.
function Changes.moveProducer(panel, utility, index, delta)
    local list = panel[utility].producers
    local other = index + delta
    if not list[index] or other < 1 or other > #list then return end
    list[index], list[other] = list[other], list[index]
    Networks.setProducers(panel, utility)
    Sync.changed(panel.id)
end

-- Devices.

-- A device of the panel's building connected (the default) or excluded: a switch at the box, free.
function Changes.setInside(panel, utility, device, connected)
    local entry = device.entry
    panel[utility].excluded[device.key] = (not connected) or nil
    Networks.device(panel, utility, connected and "reset" or "exclude", entry.x, entry.y, entry.z, entry.sprite)
    Sync.changed(panel.id)
end

function Changes.setAllInside(panel, utility, connected)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        if device.inside and (device.state == "on") ~= connected then
            local entry = device.entry
            panel[utility].excluded[device.key] = (not connected) or nil
            Networks.device(panel, utility, connected and "reset" or "exclude", entry.x, entry.y, entry.z, entry.sprite)
        end
    end
    Sync.changed(panel.id)
end

-- A device outside any building wired or piped to the panel.
function Changes.includeOutside(panel, utility, device, paid)
    local entry = device.entry
    panel[utility].included[device.key] = paid or {}
    Networks.device(panel, utility, "include", entry.x, entry.y, entry.z, entry.sprite)
    Sync.changed(panel.id)
end

-- Its line taken away; returns what it took, or nil when the panel had not connected it.
function Changes.excludeOutside(panel, utility, key)
    local paid = panel[utility].included[key]
    if not paid then return nil end
    panel[utility].included[key] = nil
    local x, y, z, sprite = BU.parseThing(key)
    Networks.device(panel, utility, "reset", x, y, z, sprite)
    Sync.changed(panel.id)
    return type(paid) == "table" and paid or {}
end

-- Sub-panels.

function Changes.link(child, parent, paid)
    child.parent, child.parentPaid = parent.id, paid or {}
    Networks.link(child)
    Sync.changed(child.id)
end

-- Its lines to the main panel taken away; returns what they took.
function Changes.unlink(child)
    local paid = child.parentPaid or {}
    child.parent, child.parentPaid = nil, nil
    Networks.link(child)
    Sync.changed(child.id)
    return paid
end

-- The box itself.

function Changes.rename(panel, name)
    name = name and tostring(name):sub(1, 40) or nil
    panel.name = name ~= "" and name or nil
    Sync.changed(panel.id)
end

function Changes.upgrade(panel)
    panel.tier = math.min(BU.TIERS, (panel.tier or 1) + 1)
    Sync.changed(panel.id)
end

-- The breaker: down by overload, up by a player at the box.
function Changes.trip(panel)
    panel.tripped = true
    Networks.setEnabled(panel, false)
    BU.log("tripped", panel.id)
    Sync.changed(panel.id)
    Sync.notice(panel, "IGUI_BU_Notice_Tripped", Panels.name(panel))
end

function Changes.resetBreaker(panel)
    panel.tripped = false
    Networks.setEnabled(panel, true)
    Sync.changed(panel.id)
end

return Changes
