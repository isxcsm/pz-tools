-- The breaker box window: devices outside chosen several at a time and connected in one walk.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Costs, Actions = BU.Costs, BU.Actions

-- Devices outside, chosen to connect in one go.

-- What connecting the chosen devices takes together: how many, and one cost (Costs.sum), priced from the devices the
-- window has.
function ISBUPanelWindow:chosenCost(utility)
    local costs = {}
    local view = self.views[utility]
    for _, device in ipairs(view and view.devices or {}) do
        if self.chosen[utility][device.key] then costs[#costs + 1] = Actions.outsideCost(self.panel, utility, device) end
    end
    return #costs, Costs.sum(costs)
end

-- A cost in a few words: "wire 4, electronics scrap 3".
function ISBUPanelWindow:costShort(cost)
    local parts = {}
    for _, item in ipairs(cost.items) do parts[#parts + 1] = getItemNameFromFullType(item[1]) .. " " .. item[2] end
    return table.concat(parts, ", ")
end

function ISBUPanelWindow:setChoosing(utility, on)
    self.choosing[utility] = on or nil
    if not on then self.chosen[utility] = {} end
    self:refill(utility)
    self:updatePlan()
end

function ISBUPanelWindow:toggleChosen(key)
    local utility = self:activeUtility()
    local chosen = self.chosen[utility]
    chosen[key] = (not chosen[key]) or nil
    self:refill(utility)
    self:updatePlan()
end

function ISBUPanelWindow:chooseAll(utility, on)
    local view = self.views[utility]
    for _, device in ipairs(view and view.devices or {}) do
        if not device.inside and device.state == "off" then self.chosen[utility][device.key] = on or nil end
    end
    self:refill(utility)
    self:updatePlan()
end

-- The chosen devices connected: the player walks to each in turn, the nearest next, laying its line there.
function ISBUPanelWindow:connectChosen(utility)
    local playerObj, panel = self.playerObj, self.panel
    local count, cost = self:chosenCost(utility)
    if count == 0 then return end
    if not Costs.affords(playerObj, cost) then
        HaloTextHelper.addBadText(playerObj, getText("IGUI_BU_Reason_cantAfford"))
        return
    end
    local left = {}
    for _, device in ipairs(self.views[utility].devices) do
        if self.chosen[utility][device.key] then left[#left + 1] = device end
    end
    local x, y = playerObj:getX(), playerObj:getY()
    while #left > 0 do
        local best, bestDistance
        for index, device in ipairs(left) do
            local dx, dy = device.entry.x - x, device.entry.y - y
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then best, bestDistance = index, distance end
        end
        local entry = table.remove(left, best).entry
        BU.ContextMenu.queueAt(playerObj, entry.x, entry.y, entry.z,
            ISBUConnect:new(playerObj, "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite))
        x, y = entry.x, entry.y
    end
    self:setChoosing(utility, false)
end
