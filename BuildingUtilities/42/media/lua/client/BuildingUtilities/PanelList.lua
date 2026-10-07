-- The breaker box window's list (one per tab) and the divider between the list and the plan. Each row is a table
-- with a kind; the list draws it and passes clicks on to the window (ISBUPanelWindow:onRow).
require "ISUI/ISScrollingListBox"
require "BuildingUtilities/PanelUi"
local BU = BuildingUtilities
local Store, Panels, Networks, Costs, Actions, Sync, Geometry, Energy, Units = BU.Store, BU.Panels, BU.Networks, BU.Costs,
    BU.Actions, BU.Sync, BU.Geometry, BU.Energy, BU.Units
local Ui = BU.PanelUi
local FONT_HGT_SMALL, ROW, PAD, SCROLLBAR, ROOM_TICK_X, CHOOSE_W, BATCH_BUTTONS, BATCH_W, rowObjects, outline,
    unoutline = Ui.FONT_HGT_SMALL, Ui.ROW, Ui.PAD, Ui.SCROLLBAR, Ui.ROOM_TICK_X, Ui.CHOOSE_W, Ui.BATCH_BUTTONS,
    Ui.BATCH_W, Ui.rowObjects, Ui.outline, Ui.unoutline

-- One tab's list. Each item is a row table with a kind; clicks act on the row and the part of it clicked.
ISBUPanelList = ISScrollingListBox:derive("ISBUPanelList")

local BUTTONS = { "Up", "Down", "Remove" }
local BUTTON_W = 60
local TIMER_W, ESSENTIAL_W, GROUP_W = 64, 48, 90
-- Water groups' colours, by their place in the panel's list.
local GROUP_COLOURS = { { 0.35, 0.65, 1 }, { 0.3, 0.9, 0.85 }, { 0.75, 0.55, 1 }, { 1, 0.6, 0.8 } }

function ISBUPanelList:new(x, y, width, height, window, utility)
    local o = ISScrollingListBox.new(self, x, y, width, height)
    o.window = window
    o.utility = utility
    o.itemheight = ROW
    o.font = UIFont.Small
    o.drawBorder = true
    o.highlighted = {}
    return o
end

-- The buttons at the end of a device's row, from the right: a water fixture's group (with more than one); for power,
-- whether the box may shed it (where it sheds), and its timer. Also where the row's own text on the right ends.
local function deviceButtons(width, row)
    local right = width - PAD - SCROLLBAR
    local result = {}
    if row.groupText then
        right = right - GROUP_W
        result[#result + 1] = { name = "group", x = right, w = GROUP_W }
        right = right - 4
    end
    if not row.controls then return result, right end
    if row.sheds then
        right = right - ESSENTIAL_W
        result[#result + 1] = { name = "essential", x = right, w = ESSENTIAL_W }
        right = right - 4
    end
    right = right - TIMER_W
    result[#result + 1] = { name = "timer", x = right, w = TIMER_W }
    return result, right - 8
end

-- The buttons at the end of a producer's row, left to right: for power Up, Down and Remove; for water the tank's
-- group (with more than one) and Remove.
local function producerButtons(width, row)
    local names = not row.water and BUTTONS or row.groupText and { "Group", "Remove" } or { "Remove" }
    local result, x = {}, width - PAD
    for index = #names, 1, -1 do
        local w = names[index] == "Group" and GROUP_W or BUTTON_W
        x = x - w - 4
        result[index] = { name = names[index], x = x, w = w }
    end
    return result
end

-- A water group's row's buttons, left to right: Settings, Rename, and Remove but for the first group.
local function groupButtons(width, row)
    local names = row.removable and { "Settings", "Rename", "Remove" } or { "Settings", "Rename" }
    local result, x = {}, width - PAD - SCROLLBAR
    for index = #names, 1, -1 do
        x = x - BUTTON_W - 4
        result[index] = { name = names[index], x = x, w = BUTTON_W }
    end
    return result
end

local function smallButton(list, x, y, w, text, r, g, b)
    list:drawRectBorder(x, y + 2, w, ROW - 4, 1, 0.6, 0.6, 0.6)
    list:drawTextCentre(text, x + w / 2, y + (ROW - FONT_HGT_SMALL) / 2, r, g, b, 1, UIFont.Small)
end

-- The Choose button of the outside group, right of its title.
local function chooseButtonX(row)
    return ROOM_TICK_X + getTextManager():MeasureStringX(UIFont.Small, row.text) + 12
end

-- The buttons of the chosen row, from the right.
local function batchButtonX(width, index)
    return width - PAD - SCROLLBAR - (#BATCH_BUTTONS - index + 1) * (BATCH_W + 4)
end

-- A box for choosing a device: empty, or chosen.
local function chooseBox(list, x, y, chosen)
    list:drawRectBorder(x, y + 3, ROW - 6, ROW - 6, 1, 0.4, 0.8, 1)
    if chosen then list:drawTextCentre("v", x + (ROW - 6) / 2, y + (ROW - FONT_HGT_SMALL) / 2, 0.4, 0.8, 1, 1, UIFont.Small) end
end

-- A tick: "on", "off", or "some" for a room whose devices are partly connected.
local function tick(list, x, y, state)
    list:drawRectBorder(x, y + 3, ROW - 6, ROW - 6, 1, 0.8, 0.8, 0.8)
    if state == "on" then
        list:drawRect(x + 3, y + 6, ROW - 12, ROW - 12, 1, 0.4, 0.9, 0.4)
    elseif state == "some" then
        list:drawRect(x + 4, y + ROW / 2 - 2, ROW - 14, 4, 1, 0.4, 0.9, 0.4)
    end
end

-- The energy graph: a column an hour, the last Store.ENERGY_HOURS of them and the hour going on; what the solar
-- panels made (yellow) and the load supplied (grey) against the largest of them, and the bank's charge (green, of
-- the full height).
local GRAPH_H = 96
local function drawGraph(list, y, width, row)
    local hours = row.hours
    local left, right = PAD, width - PAD - SCROLLBAR
    local top, bottom = y + FONT_HGT_SMALL + 6, y + GRAPH_H - 6
    local plotH = bottom - top
    local most = 0.05
    for _, hour in ipairs(hours) do most = math.max(most, hour.made or 0, hour.used or 0) end
    list:drawText(getText("IGUI_BU_GraphTitle", #hours, string.format("%.2f", most)), left, y + 2, 0.9, 0.9, 0.9, 1, UIFont.Small)
    list:drawRectBorder(left, top, right - left, plotH, 0.6, 0.5, 0.5, 0.5)
    local columns = Store.ENERGY_HOURS + 1
    local w = (right - left) / columns
    local first = columns - #hours
    for index, hour in ipairs(hours) do
        local x = left + (first + index - 1) * w
        local made = (hour.made or 0) / most * plotH
        local used = (hour.used or 0) / most * plotH
        if made > 0 then list:drawRect(x + 1, bottom - made, math.max(1, w / 2 - 1), made, 0.85, 1, 0.85, 0.2) end
        if used > 0 then list:drawRect(x + w / 2, bottom - used, math.max(1, w / 2 - 1), used, 0.7, 0.75, 0.75, 0.75) end
        if hour.charge then
            list:drawRect(x, bottom - hour.charge * plotH - 1, math.max(2, w), 3, 1, 0.3, 0.9, 0.4)
        end
    end
end

-- The water level graph: a column an hour, each group's tanks as a share of their capacity, in the group's colour.
local function drawLevels(list, y, width, row)
    local left, right = PAD, width - PAD - SCROLLBAR
    local top, bottom = y + FONT_HGT_SMALL + 6, y + GRAPH_H - 6
    local plotH = bottom - top
    list:drawText(getText("IGUI_BU_LevelTitle", Store.ENERGY_HOURS), left, y + 2, 0.9, 0.9, 0.9, 1, UIFont.Small)
    list:drawRectBorder(left, top, right - left, plotH, 0.6, 0.5, 0.5, 0.5)
    local columns = Store.ENERGY_HOURS
    local w = (right - left) / columns
    local now = math.floor(getGameTime():getWorldAgeHours())
    for _, line in ipairs(row.lines) do
        local c = line.colour
        for _, hour in ipairs(line.hours) do
            local column = columns - 1 - (now - hour.hour)
            if column >= 0 and (hour.capacity or 0) > 0 then
                local share = math.max(0, math.min(1, hour.amount / hour.capacity))
                list:drawRect(left + column * w, bottom - share * plotH - 1, math.max(2, w), 3, 1, c[1], c[2], c[3])
            end
        end
    end
end

function ISBUPanelList:doDrawItem(y, item, alt)
    local row = item.item
    if row.kind == "graph" or row.kind == "levels" then
        item.height = GRAPH_H
        if row.kind == "graph" then drawGraph(self, y, self:getWidth(), row) else drawLevels(self, y, self:getWidth(), row) end
        return y + GRAPH_H
    end
    item.height = ROW
    local width = self:getWidth()
    local textY = y + (ROW - FONT_HGT_SMALL) / 2
    if (self.hovered == item.index and (row.device or row.at or row.kind == "link")) or self.selected == item.index and row.device then
        self:drawRect(0, y, width, ROW, 0.15, 1, 1, 1)
    end
    -- What the mouse is over on the plan.
    local window = self.window
    local planned = row.device and row.device.key == window.planHoverKey
        or row.kind == "room" and window.planHoverRoom ~= nil and row.id == window.planHoverRoom
    if planned then self:drawRectBorder(1, y, width - SCROLLBAR - 2, ROW, 1, 1, 1, 0.6) end
    if row.kind == "header" then
        self:drawRect(0, y, width, ROW, 0.3, 0.3, 0.3, 0.3)
        self:drawText(row.text, PAD, textY, 1, 0.85, 0.5, 1, UIFont.Small)
    elseif row.kind == "room" then
        self:drawRect(0, y, width, ROW, 0.3, 0.3, 0.3, 0.3)
        self:drawText(row.folded and "+" or "-", PAD, textY, 1, 0.85, 0.5, 1, UIFont.Small)
        local x = ROOM_TICK_X
        if row.state then
            tick(self, x, y, row.state)
            x = x + ROW + 4
        end
        self:drawText(row.text, x, textY, 1, 0.85, 0.5, 1, UIFont.Small)
        if row.choosable then
            local on = row.choosing
            self:drawRect(chooseButtonX(row), y + 2, CHOOSE_W, ROW - 4, on and 0.8 or 0, 0.15, 0.35, 0.5)
            smallButton(self, chooseButtonX(row), y, CHOOSE_W, getText(on and "IGUI_BU_ChooseDone" or "IGUI_BU_Choose"), 0.6, 0.85, 1)
        end
        if row.right then self:drawTextRight(row.right, width - PAD - SCROLLBAR, textY, 0.9, 0.85, 0.6, 1, UIFont.Small) end
    elseif row.kind == "batch" then
        self:drawRect(0, y, width, ROW, 0.25, 0.15, 0.35, 0.5)
        self:drawText(row.text, PAD * 2, textY, row.affords and 0.7 or 1, row.affords and 0.9 or 0.55, row.affords and 1 or 0.5, 1, UIFont.Small)
        for index, name in ipairs(BATCH_BUTTONS) do
            local enabled = name ~= "Connect" or (row.count > 0 and row.affords)
            smallButton(self, batchButtonX(width, index), y, BATCH_W, getText("IGUI_BU_Batch" .. name),
                enabled and 1 or 0.5, enabled and 1 or 0.5, enabled and 1 or 0.5)
        end
    elseif row.kind == "link" then
        if row.header then self:drawRect(0, y, width, ROW, 0.3, 0.3, 0.3, 0.3) end
        local r, g, b = 0.75, 0.85, 1
        if row.header then r, g, b = 1, 0.85, 0.5 end
        self:drawText(row.text, row.header and PAD or PAD * 2, textY, r, g, b, 1, UIFont.Small)
        self:drawTextRight(getText("IGUI_BU_Open"), width - PAD - SCROLLBAR, textY, 0.5, 0.75, 1, 1, UIFont.Small)
    elseif row.kind == "note" or row.kind == "filter" then
        local shade = row.kind == "filter" and 1 or 0.7
        self:drawText(row.text, PAD * 2, textY, shade, shade, row.kind == "filter" and 0.6 or shade, 1, UIFont.Small)
    elseif row.kind == "log" then
        local r, g, b = 0.9, 0.9, 0.9
        if row.bad then r, g, b = 1, 0.55, 0.5 elseif row.good then r, g, b = 0.6, 1, 0.6 end
        self:drawText(row.text, PAD, textY, r, g, b, 1, UIFont.Small)
        self:drawTextRight(row.right, width - PAD - SCROLLBAR, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    elseif row.kind == "source" then
        self:drawText(row.text, PAD * 2, textY, row.inUse and 0.5 or 0.9, row.inUse and 1 or 0.9, row.inUse and 0.5 or 0.9, 1, UIFont.Small)
        if row.settings then smallButton(self, width - (BUTTON_W + 4) - PAD, y, BUTTON_W, getText("IGUI_BU_Settings"), 1, 1, 1) end
    elseif row.kind == "producer" then
        self:drawText(row.text, PAD * 2, textY, row.inUse and 0.5 or 0.9, row.inUse and 1 or 0.9, row.inUse and 0.5 or 0.9, 1, UIFont.Small)
        for _, button in ipairs(producerButtons(width, row)) do
            if button.name == "Group" then
                local c = row.groupColour
                smallButton(self, button.x, y, button.w, row.groupText, c[1], c[2], c[3])
            else
                smallButton(self, button.x, y, button.w, getText("IGUI_BU_" .. button.name), 1, 1, 1)
            end
        end
    elseif row.kind == "waterGroup" then
        local c = row.colour
        self:drawRect(PAD * 2, y + 6, ROW - 12, ROW - 12, 1, c[1], c[2], c[3])
        self:drawText(row.text, PAD * 2 + ROW - 6, textY, 1, 1, 1, 1, UIFont.Small)
        local buttons = groupButtons(width, row)
        for _, button in ipairs(buttons) do
            smallButton(self, button.x, y, button.w, getText("IGUI_BU_" .. button.name), 1, 1, 1)
        end
        if row.right then self:drawTextRight(row.right, buttons[1].x - 8, textY, 0.8, 0.85, 1, 1, UIFont.Small) end
    elseif row.kind == "addGroup" then
        self:drawText(row.text, PAD * 2, textY, 0.5, 0.75, 1, 1, UIFont.Small)
    elseif row.kind == "device" or row.kind == "all" or row.kind == "blackout" then
        local indent = row.kind == "device" and PAD * 3 or PAD * 2
        if row.choosable then chooseBox(self, indent, y, row.chosen) else tick(self, indent, y, row.state == "on" and "on" or "off") end
        local shade = row.state ~= "other" and 1 or 0.5
        self:drawText(row.text, indent + ROW + 4, textY, shade, shade, shade, 1, UIFont.Small)
        if row.fresh then
            local x = indent + ROW + 4 + getTextManager():MeasureStringX(UIFont.Small, row.text) + 6
            self:drawText(getText("IGUI_BU_New"), x, textY, 0.3, 0.9, 1, 1, UIFont.Small)
        end
        local buttons, textRight = deviceButtons(width, row)
        for _, button in ipairs(buttons) do
            if button.name == "group" then
                local c = row.groupColour
                smallButton(self, button.x, y, button.w, row.groupText, c[1], c[2], c[3])
            elseif button.name == "timer" then
                local timed = row.device.schedule ~= "always"
                smallButton(self, button.x, y, button.w, getText("IGUI_BU_Schedule_" .. row.device.schedule),
                    timed and 0.6 or 0.8, timed and 0.8 or 0.8, timed and 1 or 0.8)
            else
                local on = row.device.essential
                smallButton(self, button.x, y, button.w, getText("IGUI_BU_Essential"), on and 1 or 0.45, on and 0.85 or 0.45, on and 0.3 or 0.45)
            end
        end
        if row.right then
            local r, g, b = 0.8, 0.8, 0.8
            if row.held then r, g, b = 1, 0.65, 0.3 elseif row.dim then r, g, b = 0.55, 0.55, 0.55 end
            self:drawTextRight(row.right, textRight, textY, r, g, b, 1, UIFont.Small)
        end
    end
    return y + ROW
end

-- The row under the mouse outlines its objects in the world and marks them on the plan, until the mouse leaves it.
function ISBUPanelList:prerender()
    local index = self:isVisible() and self:isMouseOver() and self.mouseoverselected or nil
    local row = index and self.items[index] and self.items[index].item
    self.window.listHoverKey = row and row.device and row.device.key or nil
    self.window.listHoverRoom = row and (row.device and row.device.roomId or row.kind == "room" and row.id) or nil
    if not (row and (row.device or row.at)) then index = nil end
    if index ~= self.hovered then
        self:unhighlight()
        self.hovered = index
        if row then outline(self.window.playerObj:getPlayerNum(), rowObjects(row), getCore():getGoodHighlitedColor(), self.highlighted) end
    end
    ISScrollingListBox.prerender(self)
    -- The list's tooltip does not wrap; the units' explanations are long.
    if self.tooltipUI then self.tooltipUI.maxLineWidth = 460 end
end

function ISBUPanelList:unhighlight()
    unoutline(self.window.playerObj:getPlayerNum(), self.highlighted)
    self.highlighted = {}
end

function ISBUPanelList:hideTooltip()
    if self.tooltipUI and self.tooltipUI:getIsVisible() then
        self.tooltipUI:setVisible(false)
        self.tooltipUI:removeFromUIManager()
    end
end

function ISBUPanelList:onMouseDown(x, y)
    local index = self:rowAt(x, y)
    local item = index and index > 0 and self.items[index]
    if item then self.window:onRow(self.utility, item.item, x, self:getWidth()) end
    return true
end

-- The divider between the list and the plan: dragged, it moves the share of the window the plan takes.
ISBUSplitter = ISPanel:derive("ISBUSplitter")

function ISBUSplitter:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = false
    return o
end

function ISBUSplitter:render()
    local shade = (self.dragging or self:isMouseOver()) and 0.9 or 0.45
    local middle = self.height / 2
    for i = -2, 2 do self:drawRect(self.width / 2 - 1, middle + i * 6, 2, 3, 1, shade, shade, shade) end
end

function ISBUSplitter:onMouseDown(x, y) self.dragging = true; return true end

function ISBUSplitter:drag()
    if self.dragging then self.window:dragDivider(self.window:getMouseX() - self.width / 2) end
end

function ISBUSplitter:onMouseMove(dx, dy) self:drag() end
function ISBUSplitter:onMouseMoveOutside(dx, dy) self:drag() end
function ISBUSplitter:onMouseUp(x, y) self.dragging = false; return true end
function ISBUSplitter:onMouseUpOutside(x, y) self.dragging = false end

Ui.deviceButtons = deviceButtons
Ui.producerButtons = producerButtons
Ui.groupButtons = groupButtons
Ui.GROUP_COLOURS = GROUP_COLOURS
Ui.chooseButtonX = chooseButtonX
Ui.batchButtonX = batchButtonX
