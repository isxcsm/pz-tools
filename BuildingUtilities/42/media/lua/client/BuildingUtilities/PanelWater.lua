-- The breaker box window's water groups (BU.Water): at the top of the water tab a row per group with what its tanks
-- hold, set up, renamed and removed there, a row to add one, and the groups' level graph; the group button of a
-- tank's, a fixture's and a water unit's row, and the menu it opens; the water units' rows (BU.WaterUnits).
require "BuildingUtilities/PanelWindow"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Water, Sync, Units, WaterUnits, Panels = BU.Water, BU.Sync, BU.Units, BU.WaterUnits, BU.Panels
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

-- A group's settings in a menu: how full its tanks stay for its people (sprinklers stop there), and where its pumps
-- send water once it is full.
function ISBUPanelWindow:groupSettingsMenu(id)
    local panel = self.panel
    local group = Water.group(panel, id)
    if not group then return end
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    local function send(command, args)
        args.panel, args.group = panel.id, id
        Sync.send(self.playerObj, command, args)
    end
    local reserve = menu:addOption(getText("IGUI_BU_GroupReserve", group.reserve and BU.percent(group.reserve)
        or getText("IGUI_BU_ReserveNone")))
    local reserves = ISContextMenu:getNew(menu)
    menu:addSubMenu(reserve, reserves)
    for _, percent in ipairs({ 0, 10, 25, 50, 75 }) do
        local option = reserves:addOption(percent == 0 and getText("IGUI_BU_ReserveNone") or BU.percent(percent), nil,
            function() send("setGroupReserve", { percent = percent }) end)
        if (group.reserve or 0) == percent then option.notAvailable = true end
    end
    local overflow = menu:addOption(getText("IGUI_BU_GroupOverflow", group.overflow and Water.groupName(panel, group.overflow)
        or getText("IGUI_BU_OverflowStop")))
    local targets = ISContextMenu:getNew(menu)
    menu:addSubMenu(overflow, targets)
    local stop = targets:addOption(getText("IGUI_BU_OverflowStop"), nil, function() send("setGroupOverflow", {}) end)
    if not group.overflow then stop.notAvailable = true end
    for _, other in ipairs(Water.groups(panel)) do
        if other.id ~= id then
            local option = targets:addOption(Water.groupName(panel, other.id), nil,
                function() send("setGroupOverflow", { target = other.id }) end)
            if group.overflow == other.id then option.notAvailable = true end
        end
    end
end

-- A click on a group's row or the row adding one.
function ISBUPanelWindow:onGroupRow(row, x, width)
    if row.kind == "addGroup" then return self:askGroupName(nil) end
    for _, button in ipairs(Ui.groupButtons(width, row)) do
        if x >= button.x and x <= button.x + button.w then
            if button.name == "Settings" then return self:groupSettingsMenu(row.group) end
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

-- What a water unit does now, in a few words.
function ISBUPanelWindow:waterUnitStatus(unit)
    if unit.kind == "pump" then
        if unit.running and unit.idle == "noWater" then return getText("IGUI_BU_Pump_noWater") end
        if unit.running then return getText("IGUI_BU_Pump_running", WaterUnits.PUMP_RATE) end
        return getText("IGUI_BU_Pump_" .. (unit.idle or "noPower"))
    elseif unit.kind == "booster" then
        if unit.boosting then
            return getText("IGUI_BU_Booster_running", BU.floorName(unit.z + 1), BU.floorName(unit.z + Water.boostFloors()))
        end
        return getText("IGUI_BU_Booster_" .. (unit.idle or "noPower"))
    elseif unit.kind == "sprinkler" then
        return getText(WaterUnits.spraying(unit) and "IGUI_BU_Sprinkler_watering" or "IGUI_BU_Sprinkler_waiting")
    end
    local media = getText("IGUI_BU_FilterMedia", BU.percent(WaterUnits.mediaLeft(unit) * 100))
    if WaterUnits.unpurifiedPipes() then return media end
    -- The option asks for unpurified pipes, but this game's API cannot keep the taint: say so, not just "resting".
    local purify, why = BU.purifyAvailable()
    if BU.sandbox("RiskPlumbingUnpurified", false) == true and not purify then
        return media .. ", " .. getText("IGUI_BU_Filter_restingNoRisk", why)
    end
    return media .. ", " .. getText("IGUI_BU_Filter_resting")
end

-- The water units' rows, after the tanks: what each does, its group (with more than one) and its line.
function ISBUPanelWindow:waterUnitRows(add)
    local panel = self.panel
    local groups = #Water.groups(panel) > 1
    for _, unit in ipairs(Units.of(panel.id, "water")) do
        local text = getText("IGUI_BU_WaterUnitRow", Units.name(unit), Panels.where(panel, unit.x, unit.y),
            self:waterUnitStatus(unit))
        local row = { kind = "producer", unit = unit, text = text, water = true, inUse = unit.running == true }
        if groups then
            row.group = WaterUnits.group(unit)
            row.groupText, row.groupColour = Water.groupName(panel, row.group), PanelWindow.groupColour(panel, row.group)
        end
        add(row, getText("IGUI_BU_UnitTip_" .. unit.kind))
    end
end

-- A click on a water unit's row: its group, or its line taken away.
function ISBUPanelWindow:onWaterUnitRow(row, x, width)
    local unit = row.unit
    for _, button in ipairs(Ui.producerButtons(width, row)) do
        if x >= button.x and x <= button.x + button.w then
            if button.name == "Group" then
                self:groupMenu(row.group, function(id)
                    Sync.send(self.playerObj, "setUnitGroup", { panel = self.panel.id, unit = unit.id, group = id })
                end)
            else
                BU.ContextMenu.queueAt(self.playerObj, unit.x, unit.y, unit.z,
                    ISBUDisconnect:new(self.playerObj, "unit", self.panel, "water", unit.x, unit.y, unit.z, unit.id))
            end
        end
    end
end
