-- The breaker box window: its name and supply, its load against what it carries and a banner when the breaker is
-- down or devices are shed, then a tab per utility with its producers (or the main panel that supplies it), its
-- sub-panels, and its devices room by room, and a tab with what happened to the box; beside them the floor plan
-- (BuildingUtilities/PanelPlan). A row under the mouse outlines its objects in the world, marks them on the plan and
-- tells what switching it would do to the load. Free changes go to the server as commands; lines are laid and taken
-- away by the player at the place, as timed actions. Devices outside can be chosen several at a time (the Choose
-- button on their group) and connected in one walk, with what they all take shown first. The search box keeps the
-- rows whose device or room has the words; devices new since the window was last closed are marked. The load bar
-- tells what makes the load; a main or sub-panel row opens that box's window.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTabPanel"
require "ISUI/ISButton"
require "ISUI/ISTextBox"
require "ISUI/ISTextEntryBox"
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/PanelPlan"
local BU = BuildingUtilities
local Store, Panels, Networks, Costs, Actions, Sync, Geometry, Energy, Units = BU.Store, BU.Panels, BU.Networks, BU.Costs,
    BU.Actions, BU.Sync, BU.Geometry, BU.Energy, BU.Units

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local ROW = FONT_HGT_SMALL + 6
local PAD = 8
local REFRESH_MS = 5000
local BAR_W = 220
local SCROLLBAR = 16
local LOG = "log"
-- The list's width alone; with the plan, the plan takes its share of the window beside it (at least so wide each).
local LIST_W, MIN_LIST, MIN_PLAN = 560, 470, 260
local OPTION_W = 84
local SEEN = "BuildingUtilitiesSeen"
local OUTSIDE = "outside"
local ROOM_TICK_X = PAD + 14
local CHOOSE_W = 90
local BATCH_BUTTONS = { "Connect", "All", "None" }
local BATCH_W = 70

local PanelWindow = {}
BU.PanelWindow = PanelWindow
local open = {}
-- What the player chose, kept while the game runs: view options, folded rooms, the plan shown, its share of the
-- window and its legend.
PanelWindow.options = { activeOnly = false, byLoad = false }
PanelWindow.folded = {}
PanelWindow.planShare = 0.5

local function load2(value) return string.format("%.2f", value) end

local function percent(value, most)
    if not value or not most or most <= 0 then return "-" end
    local share = value * 100 / most
    if share > 0 and share < 0.5 then return "<1%" end
    return string.format("%.0f%%", share)
end

-- The objects of a device, every part of it.
local function deviceObjects(device)
    local entry = device.entry
    local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
    return object and BU.objectParts(object) or {}
end

-- The objects a row stands for: a device's, or what is on a producer's square.
local function rowObjects(row)
    if row.device then return deviceObjects(row.device) end
    if row.at then
        local square = getCell():getGridSquare(row.at.x, row.at.y, row.at.z)
        local _, object = Panels.producerOn(square)
        return object and { object } or {}
    end
    return {}
end

-- Outlines objects for a player, and takes the outlines away again.
local function outline(playerNum, objects, colour, into)
    for _, object in ipairs(objects) do
        object:setHighlightColor(playerNum, colour)
        object:setHighlighted(playerNum, true, false)
        object:setOutlineHighlightCol(playerNum, colour)
        object:setOutlineHighlight(playerNum, true)
        into[#into + 1] = object
    end
end

local function unoutline(playerNum, objects)
    for _, object in ipairs(objects) do
        object:setHighlighted(playerNum, false, false)
        object:setOutlineHighlight(playerNum, false)
    end
end

-- One tab's list. Each item is a row table with a kind; clicks act on the row and the part of it clicked.
ISBUPanelList = ISScrollingListBox:derive("ISBUPanelList")

local BUTTONS = { "Up", "Down", "Remove" }
local BUTTON_W = 60
local TIMER_W, ESSENTIAL_W = 64, 48

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

-- The buttons at the end of a power device's row, from the right: whether the box may shed it (where it sheds),
-- and its timer. Also where the row's own text on the right ends.
local function deviceButtons(width, row)
    local right = width - PAD - SCROLLBAR
    local result = {}
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

function ISBUPanelList:doDrawItem(y, item, alt)
    local row = item.item
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
        for index, name in ipairs(BUTTONS) do
            local bx = width - (#BUTTONS - index + 1) * (BUTTON_W + 4) - PAD
            smallButton(self, bx, y, BUTTON_W, getText("IGUI_BU_" .. name), 1, 1, 1)
        end
    elseif row.kind == "device" or row.kind == "all" then
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
            if button.name == "timer" then
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

-- The window.
ISBUPanelWindow = ISCollapsableWindow:derive("ISBUPanelWindow")

-- Shown at first on a screen wide enough for the window and the game beside it.
local function planByDefault() return getCore():getScreenWidth() >= 1500 end

-- The window's width for a list so wide, with the plan or without.
local function windowWidth(listW, shown)
    if not shown then return listW end
    return math.floor(listW / (1 - PanelWindow.planShare)) + PAD
end

local function minimumWidth(shown) return MIN_LIST + (shown and PAD + MIN_PLAN or 0) end

function ISBUPanelWindow:new(x, y, playerObj, panel)
    local shown = PanelWindow.planShown
    if shown == nil then shown = planByDefault() end
    local width = math.min(windowWidth(LIST_W, shown), getCore():getScreenWidth())
    local o = ISCollapsableWindow.new(self, x, y, math.max(width, minimumWidth(shown)), 610)
    o.playerObj = playerObj
    o.panel = panel
    o.planWanted = shown
    o.resizable = true
    o.minimumWidth = minimumWidth(shown)
    o.minimumHeight = 340
    o.rangeObjects = {}
    o.planOutlined = {}
    o.views = {}
    -- Devices outside being chosen to connect together, by utility.
    o.choosing, o.chosen = {}, { power = {}, water = {} }
    o:setTitle(getText("IGUI_BU_WindowTitle"))
    return o
end

local function button(window, x, y, width, height, onclick)
    local b = ISButton:new(x, y, width, height, "", window, onclick)
    b:initialise()
    window:addChild(b)
    return b
end

local function anchorRight(element)
    element:setAnchorLeft(false)
    element:setAnchorRight(true)
end

function ISBUPanelWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD
    self.summaryY = top
    self.loadY = top + FONT_HGT_SMALL + 4
    self.bannerY = self.loadY + ROW + 4
    local buttonsY = self.bannerY + ROW + 4
    self.rangeButton = button(self, self.width - PAD - 130, self.loadY, 130, ROW, ISBUPanelWindow.onRange)
    anchorRight(self.rangeButton)
    self.planButton = button(self, self.width - PAD - 130 - 4 - 110, self.loadY, 110, ROW, ISBUPanelWindow.onPlan)
    anchorRight(self.planButton)
    self.renameButton = button(self, PAD, buttonsY, 100, ROW, ISBUPanelWindow.onRename)
    self.renameButton:setTitle(getText("IGUI_BU_Rename"))
    self.mainButton = button(self, PAD + 106, buttonsY, 200, ROW, ISBUPanelWindow.onMainPanel)
    self.resetButton = button(self, PAD + 312, buttonsY, 110, ROW, ISBUPanelWindow.onReset)
    self.resetButton:setTitle(getText("ContextMenu_BU_ResetBreaker"))
    self.upgradeButton = button(self, PAD + 428, buttonsY, 160, ROW, ISBUPanelWindow.onUpgrade)
    local tabsY = buttonsY + ROW + PAD
    local listW = self.width
    local height = self.height - tabsY - self:resizeWidgetHeight()
    -- The list and the plan are placed by layoutPanes, not by anchors: across, only their heights follow the window.
    self.tabs = ISTabPanel:new(0, tabsY, listW, height)
    self.tabs:initialise()
    self.tabs:setAnchorBottom(true)
    self.tabs:setEqualTabWidth(false)
    self:addChild(self.tabs)
    self.lists = {}
    local views = {}
    for _, utility in ipairs(BU.UTILITIES) do views[#views + 1] = utility end
    views[#views + 1] = LOG
    for _, view in ipairs(views) do
        local list = ISBUPanelList:new(0, 0, listW, self.tabs.height - self.tabs.tabHeight, self, view)
        list:initialise()
        list:setAnchorBottom(true)
        self.tabs:addView(getText("IGUI_BU_Tab_" .. view), list)
        self.lists[view] = list
    end
    -- View options on the tab strip, at the right end of the list.
    local optionH = self.tabs.tabHeight - 2
    self.activeButton = button(self, 0, tabsY, OPTION_W, optionH, ISBUPanelWindow.onActiveOnly)
    self.activeButton:setTitle(getText("IGUI_BU_ActiveOnly"))
    self.loadSortButton = button(self, 0, tabsY, OPTION_W, optionH, ISBUPanelWindow.onByLoad)
    self.loadSortButton:setTitle(getText("IGUI_BU_ByLoad"))
    -- The search, between the tabs and the options.
    self.search = ISTextEntryBox:new("", 0, tabsY + 1, 100, optionH - 2)
    self.search:initialise()
    self.search:instantiate()
    self.search:setClearButton(true)
    self.search.onTextChangeFunction = ISBUPanelWindow.onSearch
    self.search.target = self
    self:addChild(self.search)
    -- Over the load bar and its text: what makes the load, as a tooltip.
    self.loadArea = ISButton:new(PAD, self.loadY, BAR_W, ROW, "", self, nil)
    self.loadArea:initialise()
    self.loadArea.displayBackground = false
    self.loadArea.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self:addChild(self.loadArea)
    -- Placed by placeOptions as the list's width changes: an anchor would move them again a frame later.
    self.splitter = ISBUSplitter:new(listW, tabsY, PAD, height, self)
    self.splitter:initialise()
    self.splitter:setAnchorBottom(true)
    self:addChild(self.splitter)
    self.plan = ISBUPlan:new(listW, tabsY, MIN_PLAN, height, self)
    self.plan:initialise()
    self.plan:setAnchorBottom(true)
    self:addChild(self.plan)
    self.plan:setVisible(self.planWanted)
    self.splitter:setVisible(self.planWanted)
    self:layoutPanes()
    if PanelWindow.lastTab then self.tabs:activateView(PanelWindow.lastTab) end
    self:refresh()
end

-- The list and, beside it, the plan with its share of the window, each at least so wide; the divider between them.
function ISBUPanelWindow:layoutPanes()
    if not (self.tabs and self.plan) then return end
    local shown = self.plan:getIsVisible()
    local listW = self.width
    if shown then
        local planW = math.floor((self.width - PAD) * PanelWindow.planShare)
        planW = math.max(MIN_PLAN, math.min(planW, self.width - PAD - MIN_LIST))
        listW = self.width - PAD - planW
        self.splitter:setX(listW)
        self.plan:setX(listW + PAD)
        if self.plan:getWidth() ~= planW then self.plan:setWidth(planW) end
    end
    if self.tabs:getWidth() ~= listW then
        self.tabs:setWidth(listW)
        for _, list in pairs(self.lists) do list:setWidth(listW) end
    end
    self:placeOptions()
end

-- The window resized by the player: the panes share the new width.
function ISBUPanelWindow:onResize()
    if ISCollapsableWindow.onResize then ISCollapsableWindow.onResize(self) end
    self:layoutPanes()
end

-- The divider dragged: the plan's share of the window.
function ISBUPanelWindow:dragDivider(x)
    local listW = math.max(MIN_LIST, math.min(x, self.width - PAD - MIN_PLAN))
    PanelWindow.planShare = (self.width - PAD - listW) / (self.width - PAD)
    self:layoutPanes()
end

function ISBUPanelWindow:placeOptions()
    local right = self.tabs:getX() + self.tabs:getWidth() - PAD
    self.loadSortButton:setX(right - OPTION_W)
    self.activeButton:setX(right - OPTION_W * 2 - 4)
    if self.search then
        local x = self.tabs:getX() + self.tabs:getWidthOfAllTabs() + PAD
        local w = right - OPTION_W * 2 - 4 - PAD - x
        self.search:setX(x)
        self.search:setWidth(math.max(10, w))
        self.search:setVisible(w >= 60)
    end
    local function mark(b, on)
        b.backgroundColor = on and { r = 0.25, g = 0.45, b = 0.25, a = 1 } or { r = 0, g = 0, b = 0, a = 1 }
    end
    mark(self.activeButton, PanelWindow.options.activeOnly)
    mark(self.loadSortButton, PanelWindow.options.byLoad)
end

-- The plan beside the list, or not: the window grows or shrinks by it and the list keeps its width. The window's
-- width is set silently: a resize moves anchored children by the difference a frame later, over where they are put
-- here.
function ISBUPanelWindow:setPlanShown(shown)
    PanelWindow.planShown = shown
    if self.plan:getIsVisible() == shown then return end
    local listW = self.tabs:getWidth()
    self.plan:setVisible(shown)
    self.splitter:setVisible(shown)
    self.minimumWidth = minimumWidth(shown)
    self.width = math.max(self.minimumWidth, math.min(windowWidth(listW, shown), getCore():getScreenWidth()))
    self.javaObject:setWidthSilent(self.width)
    self.rangeButton:setX(self.width - PAD - 130)
    self.planButton:setX(self.width - PAD - 130 - 4 - 110)
    self:layoutPanes()
    if shown then
        local overflow = self:getX() + self.width - getCore():getScreenWidth()
        if overflow > 0 then self:setX(math.max(0, self:getX() - overflow)) end
        self:updatePlan()
    else
        self:outlineDevice(nil)
    end
    self.planButton:setTitle(getText(shown and "IGUI_BU_PlanHide" or "IGUI_BU_PlanShow"))
end

function ISBUPanelWindow:onPlan() self:setPlanShown(not self.plan:getIsVisible()) end

function ISBUPanelWindow:onActiveOnly()
    PanelWindow.options.activeOnly = not PanelWindow.options.activeOnly
    self:placeOptions()
    self:refresh()
end

function ISBUPanelWindow:onByLoad()
    PanelWindow.options.byLoad = not PanelWindow.options.byLoad
    self:placeOptions()
    self:refresh()
end

-- The utility the list shows now: the plan follows it (power while the log is shown).
function ISBUPanelWindow:activeUtility()
    local view = self.tabs and self.tabs.activeView and self.tabs.activeView.view
    local utility = view and view.utility
    if utility == nil or utility == LOG then return "power" end
    return utility
end

function ISBUPanelWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.tabs and self.tabs.activeView then PanelWindow.lastTab = self.tabs.activeView.name end
    if self.plan and self.plan:getIsVisible() and self.planUtility ~= self:activeUtility() then self:updatePlan() end
end

function ISBUPanelWindow:render()
    ISCollapsableWindow.render(self)
    if self.summary then self:drawText(self.summary, PAD, self.summaryY, 1, 1, 1, 1, UIFont.Small) end
    if self.load then
        local barY = self.loadY + (ROW - FONT_HGT_SMALL) / 2
        local share = math.min(1, self.load / math.max(self.capacity, 1e-6))
        local r, g = 0.3, 0.8
        if self.panel.tripped or self.load > self.capacity then r, g = 0.9, 0.2 elseif share > 0.8 then r, g = 0.9, 0.8 end
        self:drawRect(PAD, barY, BAR_W, FONT_HGT_SMALL, 0.6, 0.1, 0.1, 0.1)
        self:drawRect(PAD, barY, BAR_W * share, FONT_HGT_SMALL, 0.8, r, g, 0.2)
        self:drawRectBorder(PAD, barY, BAR_W, FONT_HGT_SMALL, 1, 0.6, 0.6, 0.6)
        self:drawText(self.loadText, PAD + BAR_W + 8, barY, 1, 1, 1, 1, UIFont.Small)
    end
    local search = self.search
    if search and search:getIsVisible() and search:getText() == "" and not search:isFocused() then
        self:drawText(getText("IGUI_BU_Search"), search:getX() + 6, search:getY() + (search:getHeight() - FONT_HGT_SMALL) / 2,
            0.5, 0.5, 0.5, 1, UIFont.Small)
    end
    local banner = self.banner
    if banner then
        self:drawRect(PAD, self.bannerY, self.width - PAD * 2, ROW, 0.85, banner.r, banner.g, banner.b)
        self:drawText(banner.text, PAD * 2, self.bannerY + (ROW - FONT_HGT_SMALL) / 2, 1, 1, 1, 1, UIFont.Small)
    end
end

function ISBUPanelWindow:update()
    ISCollapsableWindow.update(self)
    if not Store.get(self.panel.id) then self:close(); return end
    if getTimestampMs() - (self.refreshedAt or 0) > REFRESH_MS then self:refresh() end
end

function ISBUPanelWindow:close()
    -- What the window listed is no longer new.
    local store = ModData.getOrCreate(SEEN)
    for utility, view in pairs(self.views or {}) do
        local set = {}
        for _, device in ipairs(view.devices or {}) do set[device.key] = true end
        store[self.panel.id .. "|" .. utility] = set
    end
    for _, list in pairs(self.lists or {}) do
        list:unhighlight()
        list:hideTooltip()
    end
    self:showRange(false)
    self:outlineDevice(nil)
    open[self.panel.id] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

local function count(set)
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    return n
end

-- What the panel and its networks are now, as rows, and the plan.
function ISBUPanelWindow:refresh()
    self.refreshedAt = getTimestampMs()
    -- On a client in multiplayer the data is received anew: the panel by its id.
    local panel = Store.get(self.panel.id)
    if not panel then return end
    self.panel = panel
    local power, water = Networks.state(panel, "power"), Networks.state(panel, "water")
    local powerText = getText("IGUI_BU_SummaryPower", power and power.supplied and "*" or "-",
        power and power.hoursLeft and string.format("%.0f", power.hoursLeft) or "-")
    local waterText = getText("IGUI_BU_SummaryWater", water and water.supplied and "*" or "-",
        water and string.format("%.0f", water.amount or 0) or "-", water and string.format("%.0f", water.capacity or 0) or "-")
    self.summary = getText("IGUI_BU_TierName", Panels.name(panel), panel.tier or 1) .. "   " .. powerText .. "   " .. waterText
    self.capacity = Panels.capacity(panel)
    self.load = power and power.load or nil
    self.loadFactor = power and power.loadFactor or 1
    self.loadText = self.load and getText(panel.tripped and "IGUI_BU_LoadTripped" or "IGUI_BU_Load", load2(self.load),
        load2(self.capacity)) or ""
    -- What the line into the box loses, counted in the load.
    local pieces, loss = Panels.powerLine(panel, power)
    if self.load and pieces and loss > 0 and power.loadFactor then
        self.loadText = self.loadText .. "   " .. getText("IGUI_BU_LineLoss", string.format("%.1f", loss), pieces)
    end
    self.loadArea:setVisible(self.load ~= nil)
    self.loadArea:setWidth(BAR_W + 8 + getTextManager():MeasureStringX(UIFont.Small, self.loadText))
    -- The banner: the breaker down, devices shed, or the load near what the box carries.
    local shed = count(panel.power.shed)
    if panel.tripped then
        self.banner = { text = getText("IGUI_BU_BannerTripped", load2(self.capacity)), r = 0.6, g = 0.1, b = 0.1 }
    elseif shed > 0 then
        self.banner = { text = getText("IGUI_BU_BannerShed", shed), r = 0.6, g = 0.35, b = 0.05 }
    elseif self.load and BU.overloadEnabled() and self.load > self.capacity * 0.8 then
        self.banner = { text = getText("IGUI_BU_BannerNear", string.format("%.0f", self.load * 100 / self.capacity)), r = 0.45, g = 0.4, b = 0.05 }
    else
        self.banner = nil
    end
    self.rangeButton:setTitle(getText(self.rangeShown and "IGUI_BU_RangeHide" or "IGUI_BU_RangeShow"))
    self.rangeButton:setTooltip(getText("IGUI_BU_RangeNote") .. "\n" .. Panels.rangesText(panel.tier))
    self.planButton:setTitle(getText(self.plan:getIsVisible() and "IGUI_BU_PlanHide" or "IGUI_BU_PlanShow"))
    local parent = Store.get(panel.parent)
    self.mainButton:setTitle(parent and getText("IGUI_BU_LeaveMain", Panels.name(parent)) or getText("IGUI_BU_JoinMain"))
    self.resetButton:setVisible(panel.tripped == true)
    local tier = panel.tier or 1
    self.upgradeButton:setVisible(tier < BU.TIERS)
    if tier < BU.TIERS then
        self.upgradeButton:setTitle(getText("ContextMenu_BU_Upgrade", tier + 1))
        local cost = Costs.upgrade(tier + 1)
        self.upgradeButton:setTooltip(Panels.upgradeNote(tier + 1, true) .. "\n" .. Costs.describe(self.playerObj, cost, true))
        self.upgradeButton:setEnable(Costs.affords(self.playerObj, cost))
    end
    local building = Panels.building(panel)
    self.building = building
    self.rooms = Panels.rooms(building)
    self.titles = Panels.roomTitles(building)
    for _, utility in ipairs(BU.UTILITIES) do self:fill(utility, utility == "power" and power or water) end
    self:fillLog()
    self.loadArea:setTooltip(self:loadBreakdown())
    self:updatePlan()
end

-- What makes the load, for the load bar's tooltip: the rooms that draw most, devices outside, sub-panels, what
-- the line loses, and the total against what the box carries.
function ISBUPanelWindow:loadBreakdown()
    if not self.load then return nil end
    local view = self.views.power
    local lines = { getText("IGUI_BU_Breakdown") }
    local groups = {}
    for id, totals in pairs(view and view.totals or {}) do
        if totals.total > 0 then groups[#groups + 1] = { id = id, title = totals.title, total = totals.total } end
    end
    table.sort(groups, function(a, b) return a.total > b.total end)
    local SHOWN, rest, restTotal = 6, 0, 0
    for index, group in ipairs(groups) do
        if index <= SHOWN then lines[#lines + 1] = "  " .. group.title .. "  " .. load2(group.total)
        else rest, restTotal = rest + 1, restTotal + group.total end
    end
    if rest > 0 then lines[#lines + 1] = "  " .. getText("IGUI_BU_BreakdownMore", rest) .. "  " .. load2(restTotal) end
    for _, child in ipairs(Store.children(self.panel.id)) do
        local childState = Networks.state(child, "power")
        if childState and childState.load then
            lines[#lines + 1] = "  " .. getText("IGUI_BU_BreakdownSub", Panels.name(child)) .. "  " .. load2(childState.load)
        end
    end
    local factor = self.loadFactor or 1
    if factor > 1 then
        lines[#lines + 1] = "  " .. getText("IGUI_BU_BreakdownLoss") .. "  " .. load2(self.load - self.load / factor)
    end
    lines[#lines + 1] = getText("IGUI_BU_BreakdownTotal", load2(self.load), load2(self.capacity))
    return table.concat(lines, "\n")
end

-- Search.
function ISBUPanelWindow:onSearch()
    local text = self.search:getText() or ""
    self.query = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    self:refresh()
end

-- The devices of a window's list the player has not seen: those not listed when its window last closed. The first
-- time a box is looked at, everything counts as seen.
function ISBUPanelWindow:seenSet(utility, devices)
    local store = ModData.getOrCreate(SEEN)
    local key = self.panel.id .. "|" .. utility
    if not store[key] then
        local set = {}
        for _, device in ipairs(devices) do set[device.key] = true end
        store[key] = set
    end
    return store[key]
end

-- What switching a power device would make of the load, for its row's tooltip; nil when it would not change it.
function ISBUPanelWindow:preview(device)
    local power = (device.power or 0) * (self.loadFactor or 1)
    if power <= 0 or not self.load or device.state == "other" or device.held then return nil end
    local after, key
    if device.state == "on" then
        after, key = self.load - power, "IGUI_BU_PreviewOff"
    else
        after, key = self.load + power, device.inside and "IGUI_BU_PreviewOn" or "IGUI_BU_PreviewConnect"
    end
    local text = getText(key, load2(after), load2(self.capacity))
    if device.state ~= "on" and BU.overloadEnabled() and after > self.capacity + 1e-6 then
        text = text .. " <LINE> <RGB:1,0.4,0.4> " .. getText(Panels.sheds(self.panel) and "IGUI_BU_PreviewShed" or "IGUI_BU_PreviewTrip")
    end
    return text
end

-- What a device does now, in words, for its row and the plan.
function ISBUPanelWindow:deviceStatus(utility, device)
    local text, dim = "", false
    if device.state == "other" then
        local other
        for _, key in ipairs(device.keys) do other = other or Store.inclusionOwner(utility, key) end
        return getText("IGUI_BU_ConnectedTo", other and Panels.name(other) or ""), false
    end
    if utility == "power" then
        local power = device.power or 0
        if device.state ~= "on" then
            text, dim = power > 0 and string.format("%.3f", power) or "", true
        elseif device.held then
            text = getText(device.held == "shed" and "IGUI_BU_HeldShed" or device.held == "saving" and "IGUI_BU_HeldSaving"
                or "IGUI_BU_HeldTimer")
        elseif power > 0 then
            text = string.format("%.3f", power) .. " (" .. percent(power, self.capacity) .. ")"
        else
            text, dim = getText("IGUI_BU_Idle"), true
        end
    end
    if device.state == "on" then
        local missing = self:missingOther(utility, device)
        if missing then text = (text ~= "" and text .. "  " or "") .. missing end
    end
    return text, dim
end

-- A producer square as the network's state last saw it, or nil.
function PanelWindow.seenProducer(state, at)
    for _, producer in ipairs(state and state.producers or {}) do
        if producer.x == at.x and producer.y == at.y and producer.z == at.z then return producer end
    end
    return nil
end

-- The units' source, a row each for { row, tooltip }: the solar panels (how many, what they make, whether they carry
-- the load, snow on them) and the bank (its charge, charging or drawn, worn batteries, cold).
function ISBUPanelWindow:sourceRows(state)
    local panel, rows = self.panel, {}
    local output, count, snow = Energy.output(panel)
    local seen = Energy.sourceState(state)
    local inUse = Energy.inUse(state)
    local bank = Energy.bank(panel)
    if count > 0 then
        local status
        if inUse then status = getText("IGUI_BU_Running")
        elseif seen and seen.available then status = getText("IGUI_BU_Standby")
        elseif Energy.sunlight() <= 0 then status = getText("IGUI_BU_SolarNight")
        else status = getText("IGUI_BU_SolarShort") end
        local text = getText("IGUI_BU_SolarRow", count, load2(output), status)
        if snow >= Energy.SNOW_TRACE then text = text .. "  " .. getText("IGUI_BU_SolarSnow", math.floor(snow * 100 + 0.5)) end
        local tooltip = getText(bank and "IGUI_BU_SolarBankTip" or "IGUI_BU_SolarTip", load2(Energy.rated()),
            math.floor(Energy.sunlight() * 100 + 0.5), load2(state and state.load or 0))
        rows[#rows + 1] = { row = { kind = "source", text = text, inUse = inUse and not bank }, tooltip = tooltip }
    end
    local racks = Store.unitList("rack", panel.id)
    if #racks > 0 then
        local text, tooltip
        if bank then
            local flow = panel.bankFlow or 0
            local status = getText("IGUI_BU_Standby")
            if flow > 0.0005 then status = getText("IGUI_BU_BankCharging", load2(flow))
            elseif flow < -0.0005 then status = getText("IGUI_BU_BankDrawn", load2(-flow)) end
            text = getText("IGUI_BU_BankRow", math.floor(bank.charge * 100 + 0.5), string.format("%.1f", bank.energy),
                string.format("%.1f", bank.capacity), status)
            if bank.weak > 0 then text = text .. "  " .. getText("IGUI_BU_BankWeak", bank.weak) end
            if panel.quietCut then text = text .. "  " .. getText("IGUI_BU_QuietCut") end
            if bank.cold > 0.005 then text = text .. "  " .. getText("IGUI_BU_BankCold", math.floor(bank.cold * 100 + 0.5)) end
            tooltip = getText("IGUI_BU_BankTip", #bank.batteries, #racks, math.floor(Energy.efficiency() * 100 + 0.5))
        else
            text = getText("IGUI_BU_BankEmpty", #racks)
        end
        local controller = (panel.tier or 1) >= BU.CONTROLLER_TIER
        if controller then tooltip = (tooltip and tooltip .. " " or "") .. self:controllerText() end
        rows[#rows + 1] = { row = { kind = "source", text = text, inUse = inUse and bank ~= nil, settings = controller }, tooltip = tooltip }
    end
    return rows
end

-- The charge controller's settings in words, for the bank's tooltip.
function ISBUPanelWindow:controllerText()
    local settings = Energy.settings(self.panel)
    local quiet = settings.quietFrom == settings.quietTo and getText("IGUI_BU_QuietNone")
        or getText("IGUI_BU_QuietHours", settings.quietFrom, settings.quietTo)
    local text = getText("IGUI_BU_ControllerTip", settings.start, settings.stop, quiet)
    if (self.panel.tier or 1) >= BU.SMART_TIER then text = text .. " " .. getText("IGUI_BU_ProtectTip", settings.protect) end
    return text
end

-- The charge controller's menu: each setting from its choices.
function ISBUPanelWindow:controllerMenu()
    local panel, playerObj = self.panel, self.playerObj
    local settings = Energy.settings(panel)
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    local function send(changes)
        local args = { panel = panel.id }
        for name, value in pairs(changes) do args[name] = value end
        Sync.send(playerObj, "setController", args)
    end
    local function submenu(title, choices, current, label, changes)
        local sub = ISContextMenu:getNew(menu)
        menu:addSubMenu(menu:addOption(title, nil, nil), sub)
        for _, choice in ipairs(choices) do
            local option = sub:addOption(label(choice), nil, function() send(changes(choice)) end)
            if current(choice) then option.notAvailable = true end
        end
        return sub
    end
    local function percentLabel(value) return value .. "%" end
    submenu(getText("IGUI_BU_SetStart", settings.start), Energy.CHOICES.start, function(v) return v == settings.start or v >= settings.stop end,
        percentLabel, function(v) return { start = v } end)
    submenu(getText("IGUI_BU_SetStop", settings.stop), Energy.CHOICES.stop, function(v) return v == settings.stop or v <= settings.start end,
        percentLabel, function(v) return { stop = v } end)
    submenu(getText("IGUI_BU_SetQuiet"), Energy.CHOICES.quiet,
        function(pair) return pair[1] == settings.quietFrom and pair[2] == settings.quietTo end,
        function(pair)
            if pair[1] == pair[2] then return getText("IGUI_BU_QuietNone") end
            return getText("IGUI_BU_QuietHours", pair[1], pair[2])
        end,
        function(pair) return { quietFrom = pair[1], quietTo = pair[2] } end)
    if (panel.tier or 1) >= BU.SMART_TIER then
        submenu(getText("IGUI_BU_SetProtect", settings.protect), Energy.CHOICES.protect, function(v) return v == settings.protect end,
            percentLabel, function(v) return { protect = v } end)
    end
end

function ISBUPanelWindow:fill(utility, state)
    local list = self.lists[utility]
    local scroll = list:getYScroll()
    list:unhighlight()
    list.hovered = nil
    list.selected = -1
    list:clear()
    local panel, playerObj = self.panel, self.playerObj
    local function add(row, tooltip) list:addItem(row.text or "", row, tooltip) end
    local view = { state = state, devices = {}, names = {}, status = {}, totals = {}, producerText = {}, fresh = {} }
    self.views[utility] = view
    local parent = Store.get(panel.parent)
    if parent then
        add({ kind = "link", header = true, text = getText("IGUI_BU_SuppliedBy", Panels.name(parent)), target = parent.id },
            getText("IGUI_BU_OpenTip"))
    else
        add({ kind = "header", text = getText("IGUI_BU_Producers") })
        local producers = panel[utility].producers
        local source = utility == "power" and Energy.hasSource(panel)
        if #producers == 0 and not source then add({ kind = "note", text = getText("IGUI_BU_NoProducers_" .. utility) }) end
        if source then
            local rows = self:sourceRows(state)
            view.sourceText = rows[1] and rows[1].row.text
            for _, entry in ipairs(rows) do add(entry.row, entry.tooltip) end
        end
        for index, at in ipairs(producers) do
            local seen = PanelWindow.seenProducer(state, at)
            local inUse = state and state.producer and state.producer.x == at.x and state.producer.y == at.y and state.producer.z == at.z
            local where = Panels.where(panel, at.x, at.y)
            local text
            if utility == "power" then
                local square = getCell():getGridSquare(at.x, at.y, at.z)
                local generator = square and square:getGenerator()
                local fuel = seen and seen.fuel and (generator and percent(seen.fuel, generator:getMaxFuel()) or string.format("%.1f", seen.fuel)) or "-"
                text = getText("IGUI_BU_GeneratorRow", index, where,
                    getText(inUse and "IGUI_BU_Running" or "IGUI_BU_Standby"), fuel, seen and seen.condition and string.format("%.0f%%", seen.condition) or "-")
            else
                text = getText("IGUI_BU_TankRow", index, where, seen and seen.amount and string.format("%.0f", seen.amount) or "-",
                    seen and seen.capacity and string.format("%.0f", seen.capacity) or "-")
            end
            view.producerText[index] = text
            add({ kind = "producer", text = text, index = index, at = at, inUse = inUse })
        end
    end
    local children = Store.children(panel.id)
    if #children > 0 then
        add({ kind = "header", text = getText("IGUI_BU_SubPanels") })
        for _, child in ipairs(children) do
            local childState = Networks.state(child, utility)
            local right = utility == "power" and childState and childState.load and load2(childState.load) or ""
            if child.tripped and utility == "power" then right = right .. "  " .. getText("IGUI_BU_Tripped") end
            add({ kind = "link", text = Panels.name(child) .. "   " .. right, target = child.id }, getText("IGUI_BU_OpenTip"))
        end
    end
    local devices, complete = Panels.devices(panel, utility)
    view.devices = devices
    local seen = self:seenSet(utility, devices)
    for _, device in ipairs(devices) do
        if not seen[device.key] then view.fresh[device.key] = true end
    end
    local query = self.query or ""
    -- Devices outside chosen to connect: only those still not connected stay chosen.
    local choosing = self.choosing[utility] == true
    local chosen = self.chosen[utility]
    local stillOff = {}
    for _, device in ipairs(devices) do
        if not device.inside and device.state == "off" then stillOff[device.key] = device end
    end
    for key in pairs(chosen) do
        if not stillOff[key] then chosen[key] = nil end
    end
    -- Switching on every device of the building that is off: what the load would be.
    local allTip, offPower = nil, 0
    for _, device in ipairs(devices) do
        if device.inside and device.state == "off" then offPower = offPower + (device.power or 0) end
    end
    if utility == "power" and self.load and offPower > 0 then
        allTip = getText("IGUI_BU_PreviewAll", load2(self.load + offPower), load2(self.capacity))
    end
    add({ kind = "all", text = getText("IGUI_BU_AllInside"), state = self:allInside(devices) and "on" or "off" }, allTip)
    if not complete then add({ kind = "note", text = getText("IGUI_BU_NotAllLoaded") }) end
    -- Rooms by their id (rooms of one name stay apart), devices in no room after them, then those outside.
    local options = PanelWindow.options
    local groups, order = {}, {}
    for _, device in ipairs(devices) do
        local entry = device.entry
        local name = BU.displayName(entry.x, entry.y, entry.z, entry.sprite)
        if not device.inside then name = name .. "  (" .. Panels.where(panel, entry.x, entry.y) .. ")" end
        view.names[device.key] = name
        local status, dim = self:deviceStatus(utility, device)
        view.status[device.key] = status
        local group = device.inside and device.roomId or OUTSIDE
        if not groups[group] then
            groups[group] = { id = group, devices = {}, total = 0, on = 0, off = 0 }
            order[#order + 1] = groups[group]
        end
        local g = groups[group]
        if device.state == "on" then
            g.on = g.on + 1
            if not device.held then g.total = g.total + (device.power or 0) end
        elseif device.state == "off" then
            g.off = g.off + 1
        end
        local shown = not options.activeOnly or utility ~= "power" or (device.power or 0) > 0 or device.held ~= nil
        if shown then table.insert(g.devices, { device = device, name = name, status = status, dim = dim }) end
    end
    local function title(id)
        if id == OUTSIDE then return getText("IGUI_BU_Outside") end
        if id == "" then return getText("IGUI_BU_NoRoom") end
        return self.titles[id] or getText("IGUI_BU_NoRoom")
    end
    local function rank(group) return group.id == OUTSIDE and 2 or group.id == "" and 1 or 0 end
    table.sort(order, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        if options.byLoad and a.total ~= b.total then return a.total > b.total end
        return title(a.id) < title(b.id)
    end)
    if self.roomFilter then
        add({ kind = "filter", text = getText("IGUI_BU_FilterNote", title(self.roomFilter)) })
    end
    local sheds = Panels.sheds(panel)
    local timers = (panel.tier or 1) >= BU.TIMER_TIER
    for _, group in ipairs(order) do
        view.totals[group.id] = { title = title(group.id), total = group.total, on = group.on, count = group.on + group.off }
        -- Searching: a room whose name has the words keeps all its rows, any other only the devices that have them.
        if query ~= "" and not title(group.id):lower():find(query, 1, true) then
            local kept = {}
            for _, shown in ipairs(group.devices) do
                if shown.name:lower():find(query, 1, true) then kept[#kept + 1] = shown end
            end
            group.devices = kept
        end
        if #group.devices > 0 and (not self.roomFilter or self.roomFilter == group.id) then
            local foldKey = panel.id .. "|" .. utility .. "|" .. group.id
            local folded = PanelWindow.folded[foldKey] == true and query == ""
            local roomState
            if group.id ~= OUTSIDE then
                roomState = group.off == 0 and "on" or group.on == 0 and "off" or "some"
            end
            local right = utility == "power" and load2(group.total) or (group.on .. " / " .. (group.on + group.off))
            local choosable = group.id == OUTSIDE and group.off > 0
            add({ kind = "room", id = group.id, text = title(group.id), right = right, state = roomState, folded = folded, foldKey = foldKey,
                choosable = choosable, choosing = choosable and choosing })
            if choosable and choosing and not folded then
                local count, cost = self:chosenCost(utility)
                local affords = count > 0 and Costs.affords(playerObj, cost)
                local text = count > 0 and getText("IGUI_BU_BatchText", count, self:costShort(cost)) or getText("IGUI_BU_BatchEmpty")
                add({ kind = "batch", text = text, count = count, affords = affords, utility = utility },
                    count > 0 and Costs.describe(playerObj, cost) or getText("IGUI_BU_BatchHint"))
            end
            if not folded then
                table.sort(group.devices, function(a, b)
                    if options.byLoad and (a.device.power or 0) ~= (b.device.power or 0) then return (a.device.power or 0) > (b.device.power or 0) end
                    return a.name < b.name
                end)
                for _, shown in ipairs(group.devices) do
                    local device, entry = shown.device, shown.device.entry
                    local tooltip = utility == "power" and self:preview(device) or nil
                    if not device.inside and device.state == "off" then
                        local cost = Actions.lineCost("outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
                        if cost then tooltip = (tooltip and tooltip .. " <LINE> " or "") .. Costs.describe(playerObj, cost) end
                    end
                    local controls = timers and utility == "power" and device.state == "on"
                    if controls then
                        tooltip = (tooltip and tooltip .. " <LINE> " or "") .. " <RGB:0.7,0.7,0.7> "
                            .. getText(sheds and "IGUI_BU_ControlsNoteSmart" or "IGUI_BU_ControlsNote")
                    end
                    local choosableDevice = choosing and not device.inside and device.state == "off"
                    add({ kind = "device", text = shown.name, right = shown.status, dim = shown.dim, device = device,
                        state = device.state, held = device.held, controls = controls, sheds = sheds,
                        choosable = choosableDevice, chosen = choosableDevice and chosen[device.key] == true,
                        fresh = view.fresh[device.key] }, tooltip)
                end
            end
        end
    end
    list:setYScroll(scroll)
end

-- What happened to the box, newest first, with how long ago.
local BAD = { IGUI_BU_Notice_Tripped = true, IGUI_BU_Notice_PowerLost = true, IGUI_BU_Notice_WaterEmpty = true,
    IGUI_BU_Notice_LowFuel = true, IGUI_BU_Notice_Shed = true }
local GOOD = { IGUI_BU_Log_Reset = true, IGUI_BU_Log_Restored = true, IGUI_BU_Log_Upgraded = true }

local function ago(hours)
    if hours < 1 / 60 then return getText("IGUI_BU_AgoNow") end
    if hours < 1 then return getText("IGUI_BU_AgoMinutes", math.floor(hours * 60)) end
    if hours < 24 then return getText("IGUI_BU_AgoHours", math.floor(hours)) end
    return getText("IGUI_BU_AgoDays", math.floor(hours / 24))
end

function ISBUPanelWindow:fillLog()
    local list = self.lists[LOG]
    local scroll = list:getYScroll()
    list:clear()
    local log = self.panel.log or {}
    if #log == 0 then list:addItem("", { kind = "note", text = getText("IGUI_BU_LogEmpty") }) end
    local now = getGameTime():getWorldAgeHours()
    for index = #log, 1, -1 do
        local entry = log[index]
        local args = entry.args or {}
        local text = getText(entry.key, args[1] ~= nil and tostring(args[1]) or "", args[2] ~= nil and tostring(args[2]) or "")
        list:addItem(text, { kind = "log", text = text, right = ago(math.max(0, now - (entry.hour or now))),
            bad = BAD[entry.key], good = GOOD[entry.key] })
    end
    list:setYScroll(scroll)
end

function ISBUPanelWindow:allInside(devices)
    for _, device in ipairs(devices) do
        if device.inside and device.state ~= "on" then return false end
    end
    return true
end

-- For a device that uses both power and water: what it lacks of the other.
function ISBUPanelWindow:missingOther(utility, device)
    local entry = device.entry
    if not (entry.power and entry.water) then return nil end
    local other = utility == "power" and "water" or "power"
    local otherState = Networks.state(self.panel, other)
    local excluded, included = false, false
    for _, key in ipairs(device.keys) do
        excluded = excluded or device.inside and self.panel[other].excluded[key] ~= nil
        included = included or not device.inside and self.panel[other].included[key] ~= nil
    end
    if excluded or (not device.inside and not included) or not (otherState and otherState.supplied) then
        return getText("IGUI_BU_Missing_" .. other)
    end
    return nil
end

-- The plan.

function ISBUPanelWindow:updatePlan()
    if not (self.plan and self.plan:getIsVisible()) then return end
    local utility = self:activeUtility()
    local view = self.views[utility]
    if not view then return end
    self.planUtility = utility
    local panel = self.panel
    local rooms = {}
    for _, room in ipairs(self.rooms or {}) do
        rooms[#rooms + 1] = { id = room.id, title = self.titles[room.id] or BU.roomName(room.name or ""), level = room.level, rects = room.rects }
    end
    local devices = {}
    for _, device in ipairs(view.devices) do
        local entry = device.entry
        local choosable = self.choosing[utility] == true and not device.inside and device.state == "off"
        devices[#devices + 1] = { key = device.key, x = entry.x, y = entry.y, z = entry.z, roomId = device.roomId, inside = device.inside,
            state = device.state, held = device.held, power = device.power, utility = utility,
            name = view.names[device.key] or "", status = view.status[device.key],
            choosable = choosable, chosen = choosable and self.chosen[utility][device.key] == true,
            fresh = view.fresh[device.key] }
    end
    local producers = {}
    if not panel.parent then
        local state = view.state
        for index, at in ipairs(panel[utility].producers) do
            local inUse = state and state.producer and state.producer.x == at.x and state.producer.y == at.y and state.producer.z == at.z
            producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, inUse = inUse, text = view.producerText[index] }
        end
        if utility == "power" then
            local inUse = Energy.inUse(state)
            for _, unit in ipairs(Store.unitList(nil, panel.id)) do
                producers[#producers + 1] = { x = unit.x, y = unit.y, z = unit.z, inUse = inUse, unit = unit.kind,
                    text = Units.name(unit) .. (view.sourceText and "  " .. view.sourceText or "") }
            end
        end
    end
    -- The zones of the building: this box's, the free rooms and other boxes'.
    local zone, inZone = {}, 0
    for id, entry in pairs(Panels.zoneStates(panel, self.building, self.rooms or {})) do
        zone[id] = { state = entry.state, owner = entry.owner and Panels.name(entry.owner) }
        if entry.state == "mine" then inZone = inZone + 1 end
    end
    local editable = Panels.zonesSupported() and self.building ~= nil
    if not editable then self.zoneEditing = false end
    -- The range, while the window shows it in the world.
    local ranges, tier = nil, panel.tier or 1
    if self.rangeShown then
        local exterior = BU.exteriorRange(tier)
        ranges = { exterior = exterior > 0 and exterior or nil, producer = not panel.parent and BU.producerRange(tier) or nil }
    end
    self.plan:setData({ utility = utility, supplied = view.state and view.state.supplied, rooms = rooms, devices = devices,
        producers = producers, box = { x = panel.x, y = panel.y, z = panel.z }, boxText = Panels.name(panel), filter = self.roomFilter,
        zone = zone, zoneEditable = editable, zoneEdit = self.zoneEditing == true, zoneNote = getText("IGUI_BU_ZoneNote", inZone),
        ranges = ranges, rangeKey = (self.building and self.building.key or "") .. "|" .. tier,
        choosing = self.choosing[utility] == true })
end

-- Devices outside, chosen to connect in one go.

-- What connecting the chosen devices takes together: how many, and one cost (tools once, items summed).
function ISBUPanelWindow:chosenCost(utility)
    local panel, count = self.panel, 0
    local cost = { tools = {}, items = {} }
    local tools, items = {}, {}
    local view = self.views[utility]
    for _, device in ipairs(view and view.devices or {}) do
        if self.chosen[utility][device.key] then
            local entry = device.entry
            local one = Actions.lineCost("outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
            if one then
                count = count + 1
                for _, tool in ipairs(one.tools) do
                    if not tools[tool] then tools[tool] = true; cost.tools[#cost.tools + 1] = tool end
                end
                for _, item in ipairs(one.items) do
                    if not items[item[1]] then
                        items[item[1]] = { item[1], 0 }
                        cost.items[#cost.items + 1] = items[item[1]]
                    end
                    items[item[1]][2] = items[item[1]][2] + item[2]
                end
            end
        end
    end
    return count, cost
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
    self:refresh()
end

function ISBUPanelWindow:toggleChosen(key)
    local utility = self:activeUtility()
    local chosen = self.chosen[utility]
    chosen[key] = (not chosen[key]) or nil
    self:fill(utility, self.views[utility] and self.views[utility].state)
    self:updatePlan()
end

function ISBUPanelWindow:chooseAll(utility, on)
    local view = self.views[utility]
    for _, device in ipairs(view and view.devices or {}) do
        if not device.inside and device.state == "off" then self.chosen[utility][device.key] = on or nil end
    end
    self:fill(utility, view and view.state)
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

-- Zones. The plan shows them, and while they are edited a click there takes a room in or out of this box's.
function ISBUPanelWindow:setZoneEditing(on)
    self.zoneEditing = on
    if on then self.roomFilter = nil end
    self:updatePlan()
end

-- The room ids of this box's zone now, as a set.
function ISBUPanelWindow:zoneSet()
    local result = {}
    for _, room in ipairs(self.rooms or {}) do
        if Panels.inZone(self.panel, room.id) then result[room.id] = true end
    end
    return result
end

-- The zone asked for, as a set of room ids; one empty is refused here as on the server.
function ISBUPanelWindow:sendZone(set)
    local ids = {}
    for id in pairs(set) do ids[#ids + 1] = id end
    if #ids == 0 then
        HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_ZoneEmpty"))
        return
    end
    table.sort(ids)
    Sync.send(self.playerObj, "setZone", { panel = self.panel.id, rooms = ids })
end

function ISBUPanelWindow:toggleZoneRoom(id)
    local states = Panels.zoneStates(self.panel, self.building, self.rooms or {})
    local entry = states[id]
    if not entry or entry.state == "taken" then return end
    local set = self:zoneSet()
    set[id] = entry.state == "free" or nil
    self:sendZone(set)
end

-- The zone's menu, for a floor: its free rooms in, its rooms out, only it, or the whole building.
function ISBUPanelWindow:zoneMenu(level)
    local states = Panels.zoneStates(self.panel, self.building, self.rooms or {})
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(BU.floorName(level), nil, nil).notAvailable = true
    local function floorSet(keepOthers, take)
        local set = keepOthers and self:zoneSet() or {}
        for _, room in ipairs(self.rooms or {}) do
            if room.level == level and states[room.id].state ~= "taken" then set[room.id] = take or nil end
        end
        return set
    end
    menu:addOption(getText("IGUI_BU_Menu_ZoneFloorAdd"), self, function(window) window:sendZone(floorSet(true, true)) end)
    menu:addOption(getText("IGUI_BU_Menu_ZoneFloorRemove"), self, function(window) window:sendZone(floorSet(true, false)) end)
    menu:addOption(getText("IGUI_BU_Menu_ZoneFloorOnly"), self, function(window) window:sendZone(floorSet(false, true)) end)
    if self.building and #Panels.ofBuilding(self.building.key) == 1 and self.panel.rooms then
        menu:addOption(getText("IGUI_BU_Menu_ZoneWhole"), self, function(window)
            Sync.send(window.playerObj, "setZone", { panel = window.panel.id, whole = true })
        end)
    end
end

-- A room of the plan in words: its name and what its devices draw.
function ISBUPanelWindow:roomStatus(id)
    local view = self.views[self:activeUtility()]
    local totals = view and view.totals[id or ""]
    local title = totals and totals.title or (self.titles and self.titles[id]) or ""
    if not totals then return title end
    if self:activeUtility() == "power" then return title .. "  " .. load2(totals.total) end
    return title .. "  " .. totals.on .. " / " .. totals.count
end

-- The device under the mouse on the plan, outlined in the world.
function ISBUPanelWindow:outlineDevice(key)
    local playerNum = self.playerObj:getPlayerNum()
    unoutline(playerNum, self.planOutlined)
    self.planOutlined = {}
    if not key then return end
    local view = self.views[self:activeUtility()]
    for _, device in ipairs(view and view.devices or {}) do
        if device.key == key then outline(playerNum, deviceObjects(device), getCore():getGoodHighlitedColor(), self.planOutlined) end
    end
end

-- A dot clicked on the plan: its row, unfolded and shown.
function ISBUPanelWindow:showDevice(key)
    local utility = self:activeUtility()
    local view = self.views[utility]
    local roomId
    for _, device in ipairs(view and view.devices or {}) do
        if device.key == key then roomId = device.inside and device.roomId or OUTSIDE end
    end
    if not roomId then return end
    PanelWindow.folded[self.panel.id .. "|" .. utility .. "|" .. roomId] = nil
    if self.roomFilter and self.roomFilter ~= roomId then self.roomFilter = nil end
    if PanelWindow.options.activeOnly then PanelWindow.options.activeOnly = false; self:placeOptions() end
    self:refresh()
    local list = self.lists[utility]
    for index, item in ipairs(list.items) do
        if item.item.device and item.item.device.key == key then
            list.selected = index
            list:ensureVisible(index)
        end
    end
end

-- A room clicked on the plan: the list shows only it; nil shows them all again.
function ISBUPanelWindow:filterRoom(id)
    self.roomFilter = id
    self:refresh()
end

local function nextSchedule(schedule)
    for index, name in ipairs(BU.SCHEDULES) do
        if name == schedule then return BU.SCHEDULES[index % #BU.SCHEDULES + 1] end
    end
    return BU.SCHEDULES[1]
end

-- A device connected or not: a building's by a switch at the box, one outside by laying or taking away its line.
function ISBUPanelWindow:switchDevice(utility, device)
    local panel, playerObj, entry = self.panel, self.playerObj, device.entry
    if device.state == "other" then return end
    if device.inside then
        Sync.send(playerObj, "setInside", { panel = panel.id, utility = utility, key = device.key, on = device.state ~= "on" })
    elseif device.state == "on" then
        BU.ContextMenu.queueAt(playerObj, entry.x, entry.y, entry.z,
            ISBUDisconnect:new(playerObj, "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite))
    else
        local cost, reason = Actions.lineCost("outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        if not cost or not Costs.affords(playerObj, cost) then
            HaloTextHelper.addBadText(playerObj, cost and getText("IGUI_BU_Reason_cantAfford") or getText("IGUI_BU_Reason_" .. reason))
            return
        end
        BU.ContextMenu.queueAt(playerObj, entry.x, entry.y, entry.z,
            ISBUConnect:new(playerObj, "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite))
    end
end

-- The menu of a dot right-clicked on the plan: what its row offers.
function ISBUPanelWindow:deviceMenu(key)
    local utility = self:activeUtility()
    local view = self.views[utility]
    local device
    for _, candidate in ipairs(view and view.devices or {}) do if candidate.key == key then device = candidate end end
    if not device then return end
    local panel, playerObj = self.panel, self.playerObj
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(view.names[key] or "", nil, nil).notAvailable = true
    if device.state == "other" then
        menu:addOption(view.status[key] or "", nil, nil).notAvailable = true
    else
        local on = device.state == "on"
        menu:addOption(getText(on and "IGUI_BU_Menu_Disconnect" or "IGUI_BU_Menu_Connect"), self, ISBUPanelWindow.switchDevice, utility, device)
        if on and utility == "power" and (panel.tier or 1) >= BU.TIMER_TIER then
            local timer = menu:addOption(getText("IGUI_BU_Menu_Timer"), nil, nil)
            local sub = ISContextMenu:getNew(menu)
            menu:addSubMenu(timer, sub)
            for _, schedule in ipairs(BU.SCHEDULES) do
                local option = sub:addOption(getText("IGUI_BU_Schedule_" .. schedule), playerObj, Sync.send, "setSchedule",
                    { panel = panel.id, key = key, schedule = schedule })
                if schedule == device.schedule then option.notAvailable = true end
            end
        end
        if on and utility == "power" and Panels.sheds(panel) then
            menu:addOption(getText(device.essential and "IGUI_BU_Menu_NotEssential" or "IGUI_BU_Menu_Essential"), playerObj, Sync.send,
                "setEssential", { panel = panel.id, key = key, on = not device.essential })
        end
    end
    menu:addOption(getText("IGUI_BU_Menu_ShowInList"), self, ISBUPanelWindow.showDevice, key)
end

-- The menu of a room right-clicked on the plan: all of it on or off, or only it in the list.
function ISBUPanelWindow:roomMenu(id)
    local utility = self:activeUtility()
    local view = self.views[utility]
    local totals = view and view.totals[id]
    local playerObj = self.playerObj
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(totals and totals.title or (self.titles[id] or ""), nil, nil).notAvailable = true
    if totals and totals.count > 0 then
        local send = function(on) Sync.send(playerObj, "setRoomInside", { panel = self.panel.id, utility = utility, room = id, on = on }) end
        if totals.on < totals.count then menu:addOption(getText("IGUI_BU_Menu_RoomOn"), true, send) end
        if totals.on > 0 then menu:addOption(getText("IGUI_BU_Menu_RoomOff"), false, send) end
    end
    if self.roomFilter == id then
        menu:addOption(getText("IGUI_BU_Menu_AllRooms"), self, ISBUPanelWindow.filterRoom, nil)
    else
        menu:addOption(getText("IGUI_BU_Menu_OnlyRoom"), self, ISBUPanelWindow.filterRoom, id)
    end
end

-- A click on a row: free changes as commands; lines laid or taken away by walking there.
function ISBUPanelWindow:onRow(utility, row, x, width)
    local panel, playerObj = self.panel, self.playerObj
    if row.kind == "source" and row.settings then
        self:controllerMenu()
    elseif row.kind == "producer" then
        for index, name in ipairs(BUTTONS) do
            local bx = width - (#BUTTONS - index + 1) * (BUTTON_W + 4) - PAD
            if x >= bx and x <= bx + BUTTON_W then
                if name == "Remove" then
                    BU.ContextMenu.queueAt(playerObj, row.at.x, row.at.y, row.at.z,
                        ISBUDisconnect:new(playerObj, "producer", panel, utility, row.at.x, row.at.y, row.at.z))
                else
                    Sync.send(playerObj, "moveProducer", { panel = panel.id, utility = utility, index = row.index, delta = name == "Up" and -1 or 1 })
                end
            end
        end
    elseif row.kind == "link" then
        local target = Store.get(row.target)
        if target then PanelWindow.open(playerObj, target) end
    elseif row.kind == "all" then
        Sync.send(playerObj, "setAllInside", { panel = panel.id, utility = utility, on = row.state ~= "on" })
    elseif row.kind == "filter" then
        self:filterRoom(nil)
    elseif row.kind == "batch" then
        for index, name in ipairs(BATCH_BUTTONS) do
            local bx = batchButtonX(width, index)
            if x >= bx and x <= bx + BATCH_W then
                if name == "Connect" then self:connectChosen(utility) else self:chooseAll(utility, name == "All") end
            end
        end
    elseif row.kind == "room" and row.choosable and x >= chooseButtonX(row) and x <= chooseButtonX(row) + CHOOSE_W then
        self:setChoosing(utility, not row.choosing)
    elseif row.kind == "room" then
        if row.state and x >= ROOM_TICK_X and x <= ROOM_TICK_X + ROW then
            Sync.send(playerObj, "setRoomInside", { panel = panel.id, utility = utility, room = row.id, on = row.state ~= "on" })
        else
            PanelWindow.folded[row.foldKey] = (not row.folded) or nil
            self:fill(utility, self.views[utility] and self.views[utility].state)
        end
    elseif row.kind == "device" and row.choosable then
        self:toggleChosen(row.device.key)
    elseif row.kind == "device" and row.state ~= "other" then
        local device = row.device
        for _, button in ipairs((deviceButtons(width, row))) do
            if x >= button.x and x <= button.x + button.w then
                if button.name == "timer" then
                    Sync.send(playerObj, "setSchedule", { panel = panel.id, key = device.key, schedule = nextSchedule(device.schedule) })
                else
                    Sync.send(playerObj, "setEssential", { panel = panel.id, key = device.key, on = not device.essential })
                end
                return
            end
        end
        self:switchDevice(utility, device)
    end
end

-- The range: on the ground around the building, where producers reach (yellow, for a main panel) and where devices
-- outside reach (blue); producers within reach that are no panel's are outlined.
function ISBUPanelWindow:showRange(on)
    local playerNum = self.playerObj:getPlayerNum()
    unoutline(playerNum, self.rangeObjects)
    self.rangeObjects = {}
    self.rangeShown = on
    if not on then return end
    local panel = self.panel
    local rooms = Panels.rooms(Panels.building(panel))
    if #rooms == 0 then return end
    -- Devices outside join by the rooms of their own floor, the ground here; producers by the whole outline.
    local ground = {}
    for _, room in ipairs(rooms) do
        if room.level == 0 then ground[#ground + 1] = room end
    end
    local minX, minY, maxX, maxY
    for _, room in ipairs(rooms) do
        for _, rect in ipairs(room.rects) do
            minX, minY = math.min(minX or rect.x, rect.x), math.min(minY or rect.y, rect.y)
            maxX, maxY = math.max(maxX or rect.x + rect.w - 1, rect.x + rect.w - 1), math.max(maxY or rect.y + rect.h - 1, rect.y + rect.h - 1)
        end
    end
    -- A range of 0 has no ring: devices outside do not join at all.
    local rings, reach = {}, 0
    local exterior, producers = BU.exteriorRange(panel.tier), BU.producerRange(panel.tier)
    if exterior > 0 then
        rings[#rings + 1] = { steps = exterior, colour = ColorInfo.new(0.3, 0.6, 1, 1), ground = true }
        reach = exterior
    end
    if not panel.parent then
        rings[#rings + 1] = { steps = producers, colour = ColorInfo.new(1, 0.85, 0.2, 1) }
        reach = math.max(reach, producers)
    end
    local producerColour = getCore():getGoodHighlitedColor()
    for x = minX - reach, maxX + reach do
        for y = minY - reach, maxY + reach do
            local square = getCell():getGridSquare(x, y, 0)
            if square then
                local steps = Geometry.toBuilding(x, y, rooms)
                local groundSteps = Geometry.toBuilding(x, y, ground)
                for _, ring in ipairs(rings) do
                    local floor = (ring.ground and groundSteps or steps) == ring.steps and square:getFloor()
                    if floor then outline(playerNum, { floor }, ring.colour, self.rangeObjects) end
                end
                if not panel.parent and steps and steps > 0 and steps <= producers then
                    local utility, object = Panels.producerOn(square)
                    if utility and not Store.producerOwner(x, y, 0) then outline(playerNum, { object }, producerColour, self.rangeObjects) end
                end
            end
        end
    end
end

function ISBUPanelWindow:onRange()
    self:showRange(not self.rangeShown)
    self.rangeButton:setTitle(getText(self.rangeShown and "IGUI_BU_RangeHide" or "IGUI_BU_RangeShow"))
    self:updatePlan()
end

function ISBUPanelWindow:onRename()
    -- Empty unless the player named it: confirming the automatic name must not fix it.
    local box = ISTextBox:new(self:getAbsoluteX() + (self.width - 280) / 2, self:getAbsoluteY() + 40, 280, 180,
        getText("IGUI_BU_RenamePrompt"), self.panel.name or "", self, ISBUPanelWindow.onRenamed, self.playerObj:getPlayerNum())
    box:initialise()
    box:addToUIManager()
end

function ISBUPanelWindow:onRenamed(button)
    if button.internal ~= "OK" then return end
    Sync.send(self.playerObj, "rename", { panel = self.panel.id, name = button.parent.entry:getText() })
end

function ISBUPanelWindow:onReset() Sync.send(self.playerObj, "resetBreaker", { panel = self.panel.id }) end

function ISBUPanelWindow:onUpgrade()
    local panel = self.panel
    BU.ContextMenu.queueAt(self.playerObj, panel.x, panel.y, panel.z, ISBUUpgradePanel:new(self.playerObj, panel))
end

-- Joins a main panel (a menu of those it can, with what the lines cost) or leaves the one it has; at its own box.
function ISBUPanelWindow:onMainPanel()
    local panel, playerObj = self.panel, self.playerObj
    if panel.parent then
        BU.ContextMenu.queueAt(playerObj, panel.x, panel.y, panel.z, ISBUDisconnect:new(playerObj, "link", panel, nil, panel.x, panel.y, panel.z))
        return
    end
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    local candidates = Panels.linkCandidates(panel)
    if #candidates == 0 then
        local hasProducers = #panel.power.producers > 0 or #panel.water.producers > 0
        local option = menu:addOption(getText(hasProducers and "IGUI_BU_Reason_hasProducers" or "IGUI_BU_NoMainInRange",
            BU.subPanelRange(BU.TIERS)), nil, nil)
        option.notAvailable = true
        return
    end
    for _, candidate in ipairs(candidates) do
        local option = menu:addOption(getText("IGUI_BU_PanelChoice", Panels.name(candidate.panel), getText("IGUI_BU_Steps", candidate.steps)),
            self, ISBUPanelWindow.onLink, candidate.panel)
        local cost = Costs.link(candidate.steps)
        local tip = ISToolTip:new()
        tip:initialise()
        tip:setVisible(false)
        option.toolTip = tip
        if candidate.tier then
            -- In reach once that box is upgraded.
            tip.description = getText("IGUI_BU_NeedsTier", candidate.tier)
            option.notAvailable = true
        else
            tip.description = Costs.describe(playerObj, cost)
            if not Costs.affords(playerObj, cost) then option.notAvailable = true end
        end
    end
end

function ISBUPanelWindow:onLink(parent)
    local panel, playerObj = self.panel, self.playerObj
    BU.ContextMenu.queueAt(playerObj, panel.x, panel.y, panel.z, ISBUConnect:new(playerObj, "link", panel, nil, panel.x, panel.y, panel.z, parent.id))
end

function PanelWindow.open(playerObj, panel)
    local window = open[panel.id]
    if window then window:bringToTop(); window:refresh(); return window end
    window = ISBUPanelWindow:new(0, 0, playerObj, panel)
    window:setX(math.max(0, (getCore():getScreenWidth() - window.width) / 2))
    window:setY(math.max(0, (getCore():getScreenHeight() - window.height) / 2))
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    open[panel.id] = window
    return window
end

function PanelWindow.isOpen(panelId) return open[panelId] ~= nil end

function PanelWindow.refreshAll()
    for _, window in pairs(open) do window:refresh() end
end

-- The API says a network changed: its panel's window, and its main panel's, show it.
function PanelWindow.onNetworkChange(id)
    local panel = Networks.owner(id)
    if not panel then return end
    if open[panel.id] then open[panel.id]:refresh() end
    if panel.parent and open[panel.parent] then open[panel.parent]:refresh() end
end

return PanelWindow
