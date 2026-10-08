-- Timed actions: putting a box or a unit down and taking it up, laying and taking away lines, upgrading a box,
-- throwing its main switch, brushing snow off a solar panel, replacing a filter's media, reconditioning a battery.
-- Each names panels and squares, not objects, and checks again as it completes, where the world is decided
-- (BU.Changes).
require "TimedActions/ISBaseTimedAction"
require "BuildingUtilities/Changes"
require "BuildingUtilities/Costs"
local BU = BuildingUtilities
local Store, Panels, Units, Changes, Costs = BU.Store, BU.Panels, BU.Units, BU.Changes, BU.Costs
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
-- utility), "outside" (a device, x, y, z and its sprite), "link" (the panel as a sub-panel of the one named by extra),
-- "unit" (a unit at x, y, z, its id extra; priced as a producer's line of its utility).
function Actions.lineCost(kind, panel, utility, x, y, z, extra)
    if not panel then return nil, "noPanel" end
    if kind == "producer" then
        local ok, reason = Panels.canConnectProducer(panel, utility, x, y, z)
        if not ok then return nil, reason end
        return Costs.producer(utility, Panels.wire(panel, x, y, z))
    elseif kind == "outside" then
        return Actions.outsideCost(panel, utility, Panels.device(panel, utility, BU.thingKey(x, y, z, extra)))
    elseif kind == "link" then
        local parent = Store.get(extra)
        if not parent then return nil, "noPanel" end
        local ok, reason = Panels.canLink(panel, parent)
        if not ok then return nil, reason end
        return Costs.link(Panels.linkWire(panel, parent)), parent
    elseif kind == "unit" then
        local unit = Store.unit(extra)
        if not unit then return nil, "noUnit" end
        local ok, reason = Units.canConnect(unit, panel)
        if not ok then return nil, reason end
        return Costs.producer(Units.utility(unit), Panels.wire(panel, x, y, z)), unit
    end
    return nil, "noPanel"
end

-- What the line of a device outside costs, from the device as Panels.devices gives it (a menu or a window that has
-- the panel's devices already does not ask the API for them again); nil with a reason when it cannot be laid.
function Actions.outsideCost(panel, utility, device)
    if not device or device.inside then return nil, "noDevice" end
    if device.state == "other" then return nil, "connectedElsewhere" end
    if device.state == "on" then return nil, "connected" end
    return Costs.outside(utility, Panels.wire(panel, device.entry.x, device.entry.y, device.entry.z)), device
end

-- How long laying a line takes: longer the farther it goes.
local function lineDuration(character, steps)
    if character:isTimedActionInstant() then return 1 end
    return math.min(1000, 100 + 15 * (steps or 0))
end

-- A getDuration of so many ticks; one for a character whose actions are instant.
local function fixedDuration(ticks)
    return function(self)
        if self.character:isTimedActionInstant() then return 1 end
        return ticks
    end
end

-- The common part: the character faces the square the action is at, and loots low; it takes so many ticks, when
-- given (else the action has its own getDuration).
local function base(name, ticks)
    local action = ISBaseTimedAction:derive(name)
    if ticks then action.getDuration = fixedDuration(ticks) end
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
ISBUInstallPanel = base("ISBUInstallPanel", 200)

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

function ISBUInstallPanel:new(character, square, item)
    local o = ISBaseTimedAction.new(self, character)
    o.square, o.item = square, item
    o.x, o.y = square:getX(), square:getY()
    o.maxTime = o:getDuration()
    return o
end

-- Taking a box down: the box back, and a share of what its lines took.
ISBURemovePanel = base("ISBURemovePanel", 200)

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
    if self.kind == "unit" then
        local unit = Store.unit(self.extra)
        return unit ~= nil and unit.panel == nil
    end
    return panel.parent == nil and Store.get(self.extra) ~= nil
end

function ISBUConnect:complete()
    local panel = Store.get(self.panelId)
    local cost, other = self:cost()
    if not cost or not Costs.affords(self.character, cost) then return false end
    local paid = Costs.take(self.character, cost)
    if self.kind == "producer" then Changes.connectProducer(panel, self.utility, self.x, self.y, self.z, paid)
    elseif self.kind == "outside" then Changes.includeOutside(panel, self.utility, other, paid)
    elseif self.kind == "unit" then Changes.connectUnit(other, panel, paid)
    else Changes.link(panel, other, paid) end
    -- Wiring teaches; plumbing has no skill of its own. Two for each piece of wire the line takes.
    if self.kind == "link" or self.utility == "power" then BU.giveXp(self.character, 2 * Costs.count(cost, Costs.WIRE)) end
    return true
end

function ISBUConnect:getDuration() return lineDuration(self.character, self.steps) end

function ISBUConnect:new(character, kind, panel, utility, x, y, z, extra)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.panelId, o.utility, o.x, o.y, o.z, o.extra = kind, panel.id, utility, x, y, z, extra
    o.steps = kind == "link" and Panels.linkWire(panel, Store.get(extra)) or Panels.wire(panel, x, y, z)
    o.costNow = o:cost()
    o.maxTime = o:getDuration()
    return o
end

-- Taking a line away, with a share of what it took back.
ISBUDisconnect = base("ISBUDisconnect", 80)

function ISBUDisconnect:connected()
    local panel = Store.get(self.panelId)
    if not panel then return false end
    if self.kind == "producer" then
        local owner, utility = Store.producerOwner(self.x, self.y, self.z)
        return owner == panel and utility == self.utility
    elseif self.kind == "outside" then
        local device = Panels.device(panel, self.utility, BU.thingKey(self.x, self.y, self.z, self.extra))
        return device ~= nil and not device.inside and device.state == "on"
    elseif self.kind == "unit" then
        local unit = Store.unit(self.extra)
        return unit ~= nil and unit.panel == panel.id
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
    elseif self.kind == "unit" then paid = Changes.disconnectUnit(Store.unit(self.extra))
    else paid = Changes.unlink(panel) end
    Costs.refund(self.character, paid)
    return true
end

function ISBUDisconnect:new(character, kind, panel, utility, x, y, z, extra)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.panelId, o.utility, o.x, o.y, o.z, o.extra = kind, panel.id, utility, x, y, z, extra
    o.maxTime = o:getDuration()
    return o
end

-- Upgrading a box to carry more.
ISBUUpgradePanel = base("ISBUUpgradePanel", 400)

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

function ISBUUpgradePanel:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.x, o.y = panel.id, panel.x, panel.y
    o.maxTime = o:getDuration()
    return o
end

-- The box's main switch thrown, off (off true) or on: a moment at the box (Changes.setSwitchedOff).
ISBUMainSwitch = base("ISBUMainSwitch", 50)

function ISBUMainSwitch:isValid()
    local panel = Store.get(self.panelId)
    return panel ~= nil and (panel.switchedOff == true) ~= self.off
end

function ISBUMainSwitch:complete()
    local panel = Store.get(self.panelId)
    if not panel then return false end
    Changes.setSwitchedOff(panel, self.off)
    return true
end

function ISBUMainSwitch:new(character, panel, off)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.x, o.y, o.off = panel.id, panel.x, panel.y, off == true
    o.maxTime = o:getDuration()
    return o
end

-- Putting a unit down (Units.canInstall).
ISBUInstallUnit = base("ISBUInstallUnit", 250)

function ISBUInstallUnit:isValid()
    return self.character:getInventory():contains(self.item) and Units.canInstall(self.kind, self.square) ~= nil
end

function ISBUInstallUnit:complete()
    if not Units.canInstall(self.kind, self.square) then return false end
    local container = self.item:getContainer()
    if container then
        container:DoRemoveItem(self.item)
        sendRemoveItemFromContainer(container, self.item)
    end
    Changes.installUnit(self.kind, self.square, Units.spriteFor(self.kind, self.square, self.character))
    BU.giveXp(self.character, 5)
    return true
end

function ISBUInstallUnit:new(character, kind, square, item)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.square, o.item = kind, square, item
    o.x, o.y = square:getX(), square:getY()
    o.maxTime = o:getDuration()
    return o
end

-- Taking a unit down: the unit back, and a share of what its line took. A rack is emptied first.
ISBURemoveUnit = base("ISBURemoveUnit", 200)

function ISBURemoveUnit:isValid()
    local unit = Store.unit(self.unitId)
    return unit ~= nil and Units.isEmpty(unit) and Units.object(unit) ~= nil
end

function ISBURemoveUnit:complete()
    local unit = Store.unit(self.unitId)
    if not unit or not Units.isEmpty(unit) then return false end
    local kind = unit.kind
    Costs.refund(self.character, Changes.removeUnit(unit))
    giveItem(self.character, Units.definition(kind).item)
    return true
end

function ISBURemoveUnit:new(character, unit)
    local o = ISBaseTimedAction.new(self, character)
    o.unitId, o.x, o.y = unit.id, unit.x, unit.y
    o.maxTime = o:getDuration()
    return o
end

-- Brushing the snow off a solar panel.
ISBUClearSnow = base("ISBUClearSnow", 120)

function ISBUClearSnow:isValid()
    local unit = Store.unit(self.unitId)
    return unit ~= nil and (unit.snow or 0) > 0
end

function ISBUClearSnow:complete()
    local unit = Store.unit(self.unitId)
    if unit then
        Changes.clearSnow(unit)
        Units.show(unit)
    end
    return unit ~= nil
end

function ISBUClearSnow:new(character, unit)
    local o = ISBaseTimedAction.new(self, character)
    o.unitId, o.x, o.y = unit.id, unit.x, unit.y
    o.maxTime = o:getDuration()
    return o
end

-- A filter's media replaced: the charcoal and cloth a charge takes (BU.WaterUnits.MEDIA) used up.
ISBUReplaceMedia = base("ISBUReplaceMedia", 200)

function ISBUReplaceMedia:isValid()
    local unit = Store.unit(self.unitId)
    return unit ~= nil and BU.WaterUnits.mediaLeft(unit) < 1 and BU.WaterUnits.hasMedia(self.character)
end

function ISBUReplaceMedia:complete()
    local unit = Store.unit(self.unitId)
    if not unit or not BU.WaterUnits.hasMedia(self.character) then return false end
    local inventory = self.character:getInventory()
    for _, need in ipairs(BU.WaterUnits.MEDIA) do
        for _ = 1, need.count do
            local item = inventory:getFirstTypeRecurse(need.type)
            if item then
                local container = item:getContainer()
                container:DoRemoveItem(item)
                sendRemoveItemFromContainer(container, item)
            end
        end
    end
    Changes.replaceMedia(unit)
    Units.show(unit)
    return true
end

function ISBUReplaceMedia:new(character, unit)
    local o = ISBaseTimedAction.new(self, character)
    o.unitId, o.x, o.y = unit.id, unit.x, unit.y
    o.maxTime = o:getDuration()
    return o
end

-- Reconditioning a worn battery with baking soda (Rack.canRevive): better by Rack.REVIVE_GAIN, a few times.
ISBUReviveBattery = ISBaseTimedAction:derive("ISBUReviveBattery")
ISBUReviveBattery.getDuration = fixedDuration(400)

function ISBUReviveBattery:isValid()
    return self.character:getInventory():contains(self.item) and BU.Rack.canRevive(self.character, self.item)
end

function ISBUReviveBattery:start()
    self:setActionAnim(CharacterActionAnims.Craft)
end

function ISBUReviveBattery:perform() ISBaseTimedAction.perform(self) end

function ISBUReviveBattery:complete()
    if not BU.Rack.canRevive(self.character, self.item) then return false end
    -- The uses it takes (Rack.REVIVE_SODA), from one box after another.
    local left = BU.Rack.REVIVE_SODA
    for _, box in ipairs((BU.Rack.bakingSoda(self.character:getInventory()))) do
        local take = math.min(left, box:getCurrentUses())
        for _ = 1, take do box:UseAndSync() end
        left = left - take
        if left <= 0 then break end
    end
    local item = self.item
    item:setCondition(math.min(item:getConditionMax(), item:getCondition() + BU.Rack.REVIVE_GAIN))
    item:getModData()[BU.Rack.REVIVED] = (item:getModData()[BU.Rack.REVIVED] or 0) + 1
    item:syncItemFields()
    BU.giveXp(self.character, 10)
    return true
end

function ISBUReviveBattery:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.maxTime = o:getDuration()
    return o
end

return Actions
