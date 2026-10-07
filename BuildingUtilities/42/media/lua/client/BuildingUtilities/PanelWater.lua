-- The breaker box window's water groups (BU.Water): at the top of the water tab a row per group with what its tanks
-- hold, renamed and removed there, a row to add one, and the groups' level graph; the group button of a tank's and a
-- fixture's row, and the menu it opens.
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities
local Water, Sync = BU.Water, BU.Sync
local Ui = BU.PanelUi
local PanelWindow = BU.PanelWindow

-- A group's colour, by its place in the panel's list.
function PanelWindow.groupColour(panel, id)
    for index, group in ipairs(Water.groups(panel)) do
        if group.id == id then return Ui.GROUP_COLOURS[index] or Ui.GROUP_COLOURS[1] end
    end
    return Ui.GROUP_COLOURS[1]
end

-- How many of the panel's tanks and connected fixtures a group has.
local function groupCounts(panel, devices, id)
    local tanks, fixtures = 0, 0
    for _, at in ipairs(panel.water.producers) do
        if Water.producerGroup(at) == id then tanks = tanks + 1 end
    end
    for _, device in ipairs(devices) do
        if device.state == "on" and device.group == id then fixtures = fixtures + 1 end
    end
    return tanks, fixtures
end

-- The group rows, for a main panel: each group, adding one, the level graph.
function ISBUPanelWindow:waterGroupRows(add, state, devices)
    local panel = self.panel
    local groups = Water.groups(panel)
    add({ kind = "header", text = getText("IGUI_BU_WaterGroups") })
    for _, group in ipairs(groups) do
        local each = state and state.groups and state.groups[group.id]
        local right = each and getText("IGUI_BU_Left_Water", string.format("%.0f", each.amount or 0),
            string.format("%.0f", each.capacity or 0)) or "-"
        local tanks, fixtures = groupCounts(panel, devices, group.id)
        add({ kind = "waterGroup", group = group.id, text = Water.groupName(panel, group.id), right = right,
            colour = PanelWindow.groupColour(panel, group.id), removable = group.id ~= Water.FIRST },
            getText("IGUI_BU_WaterGroupTip", tanks, fixtures))
    end
    if #groups < Water.MAX_GROUPS then add({ kind = "addGroup", text = getText("IGUI_BU_AddGroup") }, getText("IGUI_BU_AddGroupTip")) end
    local lines = {}
    for _, group in ipairs(groups) do
        local log = panel.water.levelLog[group.id]
        if log and #log > 0 then lines[#lines + 1] = { colour = PanelWindow.groupColour(panel, group.id), hours = log } end
    end
    if #lines > 0 then add({ kind = "levels", lines = lines }) end
end

-- A menu of the groups at the mouse; the current one is not offered.
function ISBUPanelWindow:groupMenu(current, choose)
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    for _, group in ipairs(Water.groups(self.panel)) do
        local option = menu:addOption(Water.groupName(self.panel, group.id), nil, function() choose(group.id) end)
        if group.id == current then option.notAvailable = true end
    end
end

-- A name asked for, then sent: a new group's (id nil) or a group's new name.
function ISBUPanelWindow:askGroupName(id)
    local group = id and Water.group(self.panel, id)
    local box = ISTextBox:new(self:getAbsoluteX() + (self.width - 280) / 2, self:getAbsoluteY() + 40, 280, 180,
        getText("IGUI_BU_GroupNamePrompt"), group and group.name or "", self, function(window, button)
            if button.internal ~= "OK" then return end
            local name = button.parent.entry:getText()
            if id then
                Sync.send(window.playerObj, "renameWaterGroup", { panel = window.panel.id, group = id, name = name })
            else
                Sync.send(window.playerObj, "addWaterGroup", { panel = window.panel.id, name = name })
            end
        end, self.playerObj:getPlayerNum())
    box:initialise()
    box:addToUIManager()
end

-- A click on a group's row or the row adding one.
function ISBUPanelWindow:onGroupRow(row, x, width)
    if row.kind == "addGroup" then return self:askGroupName(nil) end
    for _, button in ipairs(Ui.groupButtons(width, row)) do
        if x >= button.x and x <= button.x + button.w then
            if button.name == "Rename" then return self:askGroupName(row.group) end
            return Sync.send(self.playerObj, "removeWaterGroup", { panel = self.panel.id, group = row.group })
        end
    end
end

-- A tank's group button.
function ISBUPanelWindow:producerGroupMenu(row)
    self:groupMenu(row.group, function(id)
        Sync.send(self.playerObj, "setProducerGroup", { panel = self.panel.id, utility = "water", index = row.index, group = id })
    end)
end

-- A fixture's group button.
function ISBUPanelWindow:deviceGroupMenu(device)
    self:groupMenu(device.group, function(id)
        Sync.send(self.playerObj, "setDeviceGroup", { panel = self.panel.id, utility = "water", key = device.key, group = id })
    end)
end
