-- Timed actions: putting a box down and taking it up, laying and taking away lines, upgrading a box. Each names
-- panels and squares, not objects, and checks again as it completes, where the world is decided (BU.Changes).
require "TimedActions/ISBaseTimedAction"
require "BuildingUtilities/Changes"
require "BuildingUtilities/Costs"
local BU = BuildingUtilities
local Store, Panels, Changes, Costs = BU.Store, BU.Panels, BU.Changes, BU.Costs
local Actions = {}
BU.Actions = Actions

-- The box faces the player who puts it down: S, E, N or W.
function BU.panelSpriteFacing(square, character)
    local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
    if math.abs(dx) > math.abs(dy) then
        return dx > 0 and BU.PANEL_SPRITES[2] or BU.PANEL_SPRITES[4]
    end
    return dy > 0 and BU.PANEL_SPRITES[1] or BU.PANEL_SPRITES[3]
end

local function giveItem(character, itemType)
    local inventory = character:getInventory()
    local item = inventory:AddItem(itemType)
    if item then sendAddItemToContainer(inventory, item) end
end

-- What a line costs, or nil with a reason when it cannot be laid. kind: "producer" (a square of the panel's
-- utility), "outside" (a device, x, y, z and its sprite), "link" (the panel as a sub-panel of the one named by extra).
function Actions.lineCost(kind, panel, utility, x, y, z, extra)
    if not panel then return nil, "noPanel" end
    if kind == "producer" then
        local ok, reason = Panels.canConnectProducer(panel, utility, x, y, z)
        if not ok then return nil, reason end
        return Costs.producer(utility, Panels.steps(panel, x, y))
    elseif kind == "outside" then
        local device = Panels.device(panel, utility, BU.thingKey(x, y, z, extra))
        if not device or device.inside then return nil, "noDevice" end
        if device.state == "other" then return nil, "connectedElsewhere" end
        if device.state == "on" then return nil, "connected" end
        return Costs.outside(utility, Panels.steps(panel, x, y)), device
    elseif kind == "link" then
        local parent = Store.get(extra)
        if not parent then return nil, "noPanel" end
        local ok, reason = Panels.canLink(panel, parent)
        if not ok then return nil, reason end
        return Costs.link(Panels.linkSteps(panel, parent)), parent
    end
    return nil, "noPanel"
end

-- How long laying a line takes: longer the farther it goes.
local function lineDuration(character, steps)
    if character:isTimedActionInstant() then return 1 end
    return math.min(1000, 100 + 15 * (steps or 0))
end

-- The common part: the character faces the square the action is at, and loots low.
local function base(name)
    local action = ISBaseTimedAction:derive(name)
    function action:waitToStart()
        self.character:faceLocation(self.x, self.y)
        return self.character:shouldBeTurning()
    end
    function action:update() self.character:faceLocation(self.x, self.y) end
    function action:start()
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Low")
    end
    function action:perform() ISBaseTimedAction.perform(self) end
    return action
end

-- Putting a box down.
ISBUInstallPanel = base("ISBUInstallPanel")

function ISBUInstallPanel:isValid()
    return self.character:getInventory():contains(self.item) and Panels.canInstall(self.square) ~= nil
end

function ISBUInstallPanel:complete()
    if not Panels.canInstall(self.square) then return false end
    local container = self.item:getContainer()
    if container then
        container:DoRemoveItem(self.item)
        sendRemoveItemFromContainer(container, self.item)
    end
    Changes.install(self.square, BU.panelSpriteFacing(self.square, self.character))
    BU.giveXp(self.character, 5)
    return true
end

function ISBUInstallPanel:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 200
end

function ISBUInstallPanel:new(character, square, item)
    local o = ISBaseTimedAction.new(self, character)
    o.square, o.item = square, item
    o.x, o.y = square:getX(), square:getY()
    o.maxTime = o:getDuration()
    return o
end

-- Taking a box down: the box back, and a share of what its lines took.
ISBURemovePanel = base("ISBURemovePanel")

function ISBURemovePanel:isValid()
    local panel = Store.get(self.panelId)
    return panel ~= nil and Panels.object(panel) ~= nil
end

function ISBURemovePanel:complete()
    local panel = Store.get(self.panelId)
    if not panel then return false end
    local paid = Changes.paidFor(panel)
    Changes.remove(panel)
    Costs.refund(self.character, paid)
    giveItem(self.character, BU.PANEL_ITEM)
    return true
end

function ISBURemovePanel:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 200
end

function ISBURemovePanel:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.x, o.y = panel.id, panel.x, panel.y
    o.maxTime = o:getDuration()
    return o
end

-- Laying a line: a producer, an outside device or a sub-panel's link (see Actions.lineCost). The cost is worked out
-- as the action is made; each tick only checks that nothing took the place meanwhile, and complete checks it all.
ISBUConnect = base("ISBUConnect")

function ISBUConnect:cost()
    return Actions.lineCost(self.kind, Store.get(self.panelId), self.utility, self.x, self.y, self.z, self.extra)
end

function ISBUConnect:isValid()
    local panel = Store.get(self.panelId)
    if not panel or not self.costNow or not Costs.affords(self.character, self.costNow) then return false end
    if self.kind == "producer" then return Store.producerOwner(self.x, self.y, self.z) == nil end
    if self.kind == "outside" then return Store.inclusionOwner(self.utility, BU.thingKey(self.x, self.y, self.z, self.extra)) == nil end
    return panel.parent == nil and Store.get(self.extra) ~= nil
end

function ISBUConnect:complete()
    local panel = Store.get(self.panelId)
    local cost, other = self:cost()
    if not cost or not Costs.affords(self.character, cost) then return false end
    local paid = Costs.take(self.character, cost)
    if self.kind == "producer" then Changes.connectProducer(panel, self.utility, self.x, self.y, self.z, paid)
    elseif self.kind == "outside" then Changes.includeOutside(panel, self.utility, other, paid)
    else Changes.link(panel, other, paid) end
    -- Wiring teaches; plumbing has no skill of its own. Two for each piece of wire the line takes.
    if self.kind == "link" or self.utility == "power" then BU.giveXp(self.character, 2 * Costs.count(cost, Costs.WIRE)) end
    return true
end

function ISBUConnect:getDuration() return lineDuration(self.character, self.steps) end

function ISBUConnect:new(character, kind, panel, utility, x, y, z, extra)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.panelId, o.utility, o.x, o.y, o.z, o.extra = kind, panel.id, utility, x, y, z, extra
    o.steps = kind == "link" and Panels.linkSteps(panel, Store.get(extra)) or Panels.steps(panel, x, y)
    o.costNow = o:cost()
    o.maxTime = o:getDuration()
    return o
end

-- Taking a line away, with a share of what it took back.
ISBUDisconnect = base("ISBUDisconnect")

function ISBUDisconnect:connected()
    local panel = Store.get(self.panelId)
    if not panel then return false end
    if self.kind == "producer" then
        local owner, utility = Store.producerOwner(self.x, self.y, self.z)
        return owner == panel and utility == self.utility
    elseif self.kind == "outside" then
        local device = Panels.device(panel, self.utility, BU.thingKey(self.x, self.y, self.z, self.extra))
        return device ~= nil and not device.inside and device.state == "on"
    end
    return panel.parent ~= nil
end

function ISBUDisconnect:isValid() return self:connected() end

function ISBUDisconnect:complete()
    if not self:connected() then return false end
    local panel = Store.get(self.panelId)
    local paid
    if self.kind == "producer" then paid = Changes.disconnectProducer(panel, self.utility, self.x, self.y, self.z)
    elseif self.kind == "outside" then
        paid = Changes.excludeOutside(panel, self.utility, Panels.device(panel, self.utility, BU.thingKey(self.x, self.y, self.z, self.extra)))
    else paid = Changes.unlink(panel) end
    Costs.refund(self.character, paid)
    return true
end

function ISBUDisconnect:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 80
end

function ISBUDisconnect:new(character, kind, panel, utility, x, y, z, extra)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.panelId, o.utility, o.x, o.y, o.z, o.extra = kind, panel.id, utility, x, y, z, extra
    o.maxTime = o:getDuration()
    return o
end

-- Upgrading a box to carry more.
ISBUUpgradePanel = base("ISBUUpgradePanel")

function ISBUUpgradePanel:cost()
    local panel = Store.get(self.panelId)
    return panel and Costs.upgrade((panel.tier or 1) + 1) or nil
end

function ISBUUpgradePanel:isValid()
    local cost = self:cost()
    return cost ~= nil and Costs.affords(self.character, cost)
end

function ISBUUpgradePanel:complete()
    local cost = self:cost()
    if not cost or not Costs.affords(self.character, cost) then return false end
    Costs.take(self.character, cost)
    local panel = Store.get(self.panelId)
    Changes.upgrade(panel)
    BU.giveXp(self.character, 15 * (panel.tier - 1))
    return true
end

function ISBUUpgradePanel:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 400
end

function ISBUUpgradePanel:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.x, o.y = panel.id, panel.x, panel.y
    o.maxTime = o:getDuration()
    return o
end

return Actions
