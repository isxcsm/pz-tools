-- The breaker box window: devices outside chosen several at a time and registered together; each is then connected
-- at itself (its world menu), what the chosen ones take told before.
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
    if on and utility == "power" and not BU.exteriorPower() then
        HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_Reason_exteriorOff"))
        return
    end
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

-- The chosen devices registered at the box, to be connected each at itself.
function ISBUPanelWindow:connectChosen(utility)
    local keys = {}
    for _, device in ipairs(self.views[utility].devices) do
        if self.chosen[utility][device.key] then keys[#keys + 1] = BU.registerKey("outside", utility, device.key) end
    end
    if #keys == 0 then return end
    BU.Sync.send(self.playerObj, "register", { panel = self.panel.id, keys = keys, on = true })
    self:setChoosing(utility, false)
end
