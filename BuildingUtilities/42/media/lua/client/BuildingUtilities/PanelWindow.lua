-- The breaker box window: its name and supply, its load against what it carries and a banner when the breaker is
-- down or devices are shed, then a tab per utility with its producers (or the main panel that supplies it), its
-- sub-panels, and its devices room by room, and a tab with what happened to the box; beside them the floor plan
-- (BuildingUtilities/PanelPlan). A row under the mouse outlines its objects in the world, marks them on the plan and
-- tells what switching it would do to the load. Free changes go to the server as commands; lines are laid and taken
-- away by the player at the place, as timed actions.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTabPanel"
require "ISUI/ISButton"
require "ISUI/ISTextBox"
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/PanelPlan"
local BU = BuildingUtilities
local Store, Panels, Networks, Costs, Actions, Sync, Geometry = BU.Store, BU.Panels, BU.Networks, BU.Costs, BU.Actions,
    BU.Sync, BU.Geometry

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local ROW = FONT_HGT_SMALL + 6
local PAD = 8
local REFRESH_MS = 5000
local BAR_W = 220
local SCROLLBAR = 16
local LOG = "log"
local LIST_W, PLAN_W = 680, 380
local OPTION_W = 110
local OUTSIDE = "outside"
local ROOM_TICK_X = PAD + 14

local PanelWindow = {}
BU.PanelWindow = PanelWindow
local open = {}
-- What the player chose, kept while the game runs: view options, folded rooms, the plan shown.
PanelWindow.options = { activeOnly = false, byLoad = false }
PanelWindow.folded = {}

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
    if (self.hovered == item.index and (row.device or row.at)) or self.selected == item.index and row.device then
        self:drawRect(0, y, width, ROW, 0.15, 1, 1, 1)
    end
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
        if row.right then self:drawTextRight(row.right, width - PAD - SCROLLBAR, textY, 0.9, 0.85, 0.6, 1, UIFont.Small) end
    elseif row.kind == "note" or row.kind == "filter" then
        local shade = row.kind == "filter" and 1 or 0.7
        self:drawText(row.text, PAD * 2, textY, shade, shade, row.kind == "filter" and 0.6 or shade, 1, UIFont.Small)
    elseif row.kind == "log" then
        local r, g, b = 0.9, 0.9, 0.9
        if row.bad then r, g, b = 1, 0.55, 0.5 elseif row.good then r, g, b = 0.6, 1, 0.6 end
        self:drawText(row.text, PAD, textY, r, g, b, 1, UIFont.Small)
        self:drawTextRight(row.right, width - PAD - SCROLLBAR, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    elseif row.kind == "producer" then
        self:drawText(row.text, PAD * 2, textY, row.inUse and 0.5 or 0.9, row.inUse and 1 or 0.9, row.inUse and 0.5 or 0.9, 1, UIFont.Small)
        for index, name in ipairs(BUTTONS) do
            local bx = width - (#BUTTONS - index + 1) * (BUTTON_W + 4) - PAD
            smallButton(self, bx, y, BUTTON_W, getText("IGUI_BU_" .. name), 1, 1, 1)
        end
    elseif row.kind == "device" or row.kind == "all" then
        local indent = row.kind == "device" and PAD * 3 or PAD * 2
        tick(self, indent, y, row.state == "on" and "on" or "off")
        local shade = row.state ~= "other" and 1 or 0.5
        self:drawText(row.text, indent + ROW + 4, textY, shade, shade, shade, 1, UIFont.Small)
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

-- The window.
ISBUPanelWindow = ISCollapsableWindow:derive("ISBUPanelWindow")

-- Shown at first on a screen wide enough for the window and the game beside it.
local function planByDefault() return getCore():getScreenWidth() >= 1500 end

function ISBUPanelWindow:new(x, y, playerObj, panel)
    local shown = PanelWindow.planShown
    if shown == nil then shown = planByDefault() end
    local o = ISCollapsableWindow.new(self, x, y, LIST_W + (shown and PLAN_W + PAD or 0), 610)
    o.playerObj = playerObj
    o.panel = panel
    o.planWanted = shown
    o.resizable = true
    o.minimumWidth = 560 + (shown and PLAN_W + PAD or 0)
    o.minimumHeight = 340
    o.rangeObjects = {}
    o.planOutlined = {}
    o.views = {}
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
    local listW = self.width - (self.planWanted and PLAN_W + PAD or 0)
    local height = self.height - tabsY - self:resizeWidgetHeight()
    self.tabs = ISTabPanel:new(0, tabsY, listW, height)
    self.tabs:initialise()
    self.tabs:setAnchorRight(true)
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
        list:setAnchorRight(true)
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
    anchorRight(self.activeButton)
    anchorRight(self.loadSortButton)
    self:placeOptions()
    self.plan = ISBUPlan:new(listW, tabsY, PLAN_W, height, self)
    self.plan:initialise()
    anchorRight(self.plan)
    self.plan:setAnchorBottom(true)
    self:addChild(self.plan)
    self.plan:setVisible(self.planWanted)
    if PanelWindow.lastTab then self.tabs:activateView(PanelWindow.lastTab) end
    self:refresh()
end

function ISBUPanelWindow:placeOptions()
    local right = self.tabs:getX() + self.tabs:getWidth() - PAD
    self.loadSortButton:setX(right - OPTION_W)
    self.activeButton:setX(right - OPTION_W * 2 - 4)
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
    local delta = PLAN_W + PAD
    self.plan:setVisible(shown)
    self.minimumWidth = 560 + (shown and delta or 0)
    self.width = listW + (shown and delta or 0)
    self.javaObject:setWidthSilent(self.width)
    self.plan:setX(listW)
    self.rangeButton:setX(self.width - PAD - 130)
    self.planButton:setX(self.width - PAD - 130 - 4 - 110)
    self:placeOptions()
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
    self.rooms = Panels.rooms(building)
    self.titles = Panels.roomTitles(building)
    for _, utility in ipairs(BU.UTILITIES) do self:fill(utility, utility == "power" and power or water) end
    self:fillLog()
    self:updatePlan()
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
            text = getText(device.held == "shed" and "IGUI_BU_HeldShed" or "IGUI_BU_HeldTimer")
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

function ISBUPanelWindow:fill(utility, state)
    local list = self.lists[utility]
    local scroll = list:getYScroll()
    list:unhighlight()
    list.hovered = nil
    list.selected = -1
    list:clear()
    local panel, playerObj = self.panel, self.playerObj
    local function add(row, tooltip) list:addItem(row.text or "", row, tooltip) end
    local view = { state = state, devices = {}, names = {}, status = {}, totals = {}, producerText = {} }
    self.views[utility] = view
    local parent = Store.get(panel.parent)
    if parent then
        add({ kind = "header", text = getText("IGUI_BU_SuppliedBy", Panels.name(parent)) })
    else
        add({ kind = "header", text = getText("IGUI_BU_Producers") })
        local producers = panel[utility].producers
        if #producers == 0 then add({ kind = "note", text = getText("IGUI_BU_NoProducers_" .. utility) }) end
        for index, at in ipairs(producers) do
            local seen = state and state.producers and state.producers[index]
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
            add({ kind = "note", text = Panels.name(child) .. "   " .. right })
        end
    end
    local devices, complete = Panels.devices(panel, utility)
    view.devices = devices
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
        if #group.devices > 0 and (not self.roomFilter or self.roomFilter == group.id) then
            local foldKey = panel.id .. "|" .. utility .. "|" .. group.id
            local folded = PanelWindow.folded[foldKey] == true
            local roomState
            if group.id ~= OUTSIDE then
                roomState = group.off == 0 and "on" or group.on == 0 and "off" or "some"
            end
            local right = utility == "power" and load2(group.total) or (group.on .. " / " .. (group.on + group.off))
            add({ kind = "room", id = group.id, text = title(group.id), right = right, state = roomState, folded = folded, foldKey = foldKey })
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
                    add({ kind = "device", text = shown.name, right = shown.status, dim = shown.dim, device = device,
                        state = device.state, held = device.held, controls = controls, sheds = sheds }, tooltip)
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
        devices[#devices + 1] = { key = device.key, x = entry.x, y = entry.y, z = entry.z, roomId = device.roomId, inside = device.inside,
            state = device.state, held = device.held, power = device.power, utility = utility,
            name = view.names[device.key] or "", status = view.status[device.key] }
    end
    local producers = {}
    if not panel.parent then
        local state = view.state
        for index, at in ipairs(panel[utility].producers) do
            local inUse = state and state.producer and state.producer.x == at.x and state.producer.y == at.y and state.producer.z == at.z
            producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, inUse = inUse, text = view.producerText[index] }
        end
    end
    self.plan:setData({ utility = utility, supplied = view.state and view.state.supplied, rooms = rooms, devices = devices,
        producers = producers, box = { x = panel.x, y = panel.y, z = panel.z }, boxText = Panels.name(panel), filter = self.roomFilter })
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

-- A click on a row: free changes as commands; lines laid or taken away by walking there.
function ISBUPanelWindow:onRow(utility, row, x, width)
    local panel, playerObj = self.panel, self.playerObj
    if row.kind == "producer" then
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
    elseif row.kind == "all" then
        Sync.send(playerObj, "setAllInside", { panel = panel.id, utility = utility, on = row.state ~= "on" })
    elseif row.kind == "filter" then
        self:filterRoom(nil)
    elseif row.kind == "room" then
        if row.state and x >= ROOM_TICK_X and x <= ROOM_TICK_X + ROW then
            Sync.send(playerObj, "setRoomInside", { panel = panel.id, utility = utility, room = row.id, on = row.state ~= "on" })
        else
            PanelWindow.folded[row.foldKey] = (not row.folded) or nil
            self:fill(utility, self.views[utility] and self.views[utility].state)
        end
    elseif row.kind == "device" and row.state ~= "other" then
        local device, entry = row.device, row.device.entry
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
        if device.inside then
            Sync.send(playerObj, "setInside", { panel = panel.id, utility = utility, key = device.key, on = row.state ~= "on" })
        elseif row.state == "on" then
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
        rings[#rings + 1] = { steps = exterior, colour = ColorInfo.new(0.3, 0.6, 1, 1) }
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
                for _, ring in ipairs(rings) do
                    local floor = steps == ring.steps and square:getFloor()
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
