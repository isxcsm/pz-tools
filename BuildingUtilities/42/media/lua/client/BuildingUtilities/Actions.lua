-- Timed actions: putting a breaker box down and taking it up.
require "TimedActions/ISBaseTimedAction"
require "BuildingUtilities/Panels"
local BU = BuildingUtilities

-- The box faces the player who puts it down: S, E, N or W.
function BU.panelSpriteFacing(square, character)
    local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
    if math.abs(dx) > math.abs(dy) then
        return dx > 0 and BU.PANEL_SPRITES[2] or BU.PANEL_SPRITES[4]
    end
    return dy > 0 and BU.PANEL_SPRITES[1] or BU.PANEL_SPRITES[3]
end

ISBUInstallPanel = ISBaseTimedAction:derive("ISBUInstallPanel")

function ISBUInstallPanel:isValid()
    return self.character:getInventory():contains(self.item) and BU.Panels.canInstall(self.square) ~= nil
end

function ISBUInstallPanel:waitToStart()
    self.character:faceLocation(self.square:getX(), self.square:getY())
    return self.character:shouldBeTurning()
end

function ISBUInstallPanel:update()
    self.character:faceLocation(self.square:getX(), self.square:getY())
end

function ISBUInstallPanel:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
end

function ISBUInstallPanel:perform()
    ISBaseTimedAction.perform(self)
end

function ISBUInstallPanel:complete()
    self.character:getInventory():Remove(self.item)
    BU.Panels.install(self.square, BU.panelSpriteFacing(self.square, self.character))
    return true
end

function ISBUInstallPanel:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 200
end

function ISBUInstallPanel:new(character, square, item)
    local o = ISBaseTimedAction.new(self, character)
    o.square = square
    o.item = item
    o.maxTime = o:getDuration()
    return o
end

ISBURemovePanel = ISBaseTimedAction:derive("ISBURemovePanel")

function ISBURemovePanel:isValid()
    return BU.Store.get(self.panel.id) ~= nil and BU.Panels.object(self.panel) ~= nil
end

function ISBURemovePanel:waitToStart()
    self.character:faceLocation(self.panel.x, self.panel.y)
    return self.character:shouldBeTurning()
end

function ISBURemovePanel:update()
    self.character:faceLocation(self.panel.x, self.panel.y)
end

function ISBURemovePanel:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
end

function ISBURemovePanel:perform()
    ISBaseTimedAction.perform(self)
end

function ISBURemovePanel:complete()
    BU.Panels.remove(self.panel)
    self.character:getInventory():AddItem(BU.PANEL_ITEM)
    return true
end

function ISBURemovePanel:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 200
end

function ISBURemovePanel:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panel = panel
    o.maxTime = o:getDuration()
    return o
end
