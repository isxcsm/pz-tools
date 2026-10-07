-- The breaker box window: its name and supply, its load against what it carries and a banner when the breaker is
-- down or devices are shed, then a tab per utility with its producers (or the main panel that supplies it), its
-- sub-panels, and its devices by room, each with a tick, and a tab with what happened to the box. A row under the
-- mouse outlines its objects in the world and tells what switching it would do to the load; the range button marks
-- how far the box reaches. Free changes go to the server as commands; lines are laid and taken away by the player
-- at the place, as timed actions.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTabPanel"
require "ISUI/ISButton"
require "ISUI/ISTextBox"
require "BuildingUtilities/ContextMenu"
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

local PanelWindow = {}
BU.PanelWindow = PanelWindow
local open = {}

local function load2(value) return string.format("%.2f", value) end

-- The objects a row stands for: a device's, every part of it, or what is on a producer's square.
local function rowObjects(row)
    if row.device then
        local entry = row.device.entry
        local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
        return object and BU.objectParts(object) or {}
    elseif row.at then
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

local function tick(list, x, y, on)
    list:drawRectBorder(x, y + 3, ROW - 6, ROW - 6, 1, 0.8, 0.8, 0.8)
    if on then list:drawRect(x + 3, y + 6, ROW - 12, ROW - 12, 1, 0.4, 0.9, 0.4) end
end

function ISBUPanelList:doDrawItem(y, item, alt)
    local row = item.item
    item.height = ROW
    local width = self:getWidth()
    local textY = y + (ROW - FONT_HGT_SMALL) / 2
    if self.hovered == item.index and (row.device or row.at) then
        self:drawRect(0, y, width, ROW, 0.15, 1, 1, 1)
    end
    if row.kind == "header" then
        self:drawRect(0, y, width, ROW, 0.3, 0.3, 0.3, 0.3)
        self:drawText(row.text, PAD, textY, 1, 0.85, 0.5, 1, UIFont.Small)
    elseif row.kind == "note" then
        self:drawText(row.text, PAD * 2, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
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
        local enabled = row.state ~= "other"
        tick(self, PAD * 2, y, row.state == "on")
        local shade = enabled and 1 or 0.5
        self:drawText(row.text, PAD * 2 + ROW + 4, textY, shade, shade, shade, 1, UIFont.Small)
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
            if row.held then r, g, b = 1, 0.65, 0.3 end
            self:drawTextRight(row.right, textRight, textY, r, g, b, 1, UIFont.Small)
        end
    end
    return y + ROW
end

-- The row under the mouse outlines its objects in the world, until the mouse leaves it.
function ISBUPanelList:prerender()
    local index = self:isVisible() and self:isMouseOver() and self.mouseoverselected or nil
    local row = index and self.items[index] and self.items[index].item
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

function ISBUPanelWindow:new(x, y, playerObj, panel)
    local o = ISCollapsableWindow.new(self, x, y, 680, 610)
    o.playerObj = playerObj
    o.panel = panel
    o.resizable = true
    o.minimumWidth = 560
    o.minimumHeight = 340
    o.rangeObjects = {}
    o:setTitle(getText("IGUI_BU_WindowTitle"))
    return o
end

local function button(window, x, y, width, onclick)
    local b = ISButton:new(x, y, width, ROW, "", window, onclick)
    b:initialise()
    window:addChild(b)
    return b
end

function ISBUPanelWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD
    self.summaryY = top
    self.loadY = top + FONT_HGT_SMALL + 4
    self.bannerY = self.loadY + ROW + 4
    local buttonsY = self.bannerY + ROW + 4
    self.rangeButton = button(self, self.width - PAD - 130, self.loadY, 130, ISBUPanelWindow.onRange)
    self.rangeButton:setAnchorLeft(false)
    self.rangeButton:setAnchorRight(true)
    self.rangeButton:setTooltip(getText("IGUI_BU_RangeNote"))
    self.renameButton = button(self, PAD, buttonsY, 100, ISBUPanelWindow.onRename)
    self.renameButton:setTitle(getText("IGUI_BU_Rename"))
    self.mainButton = button(self, PAD + 106, buttonsY, 200, ISBUPanelWindow.onMainPanel)
    self.resetButton = button(self, PAD + 312, buttonsY, 110, ISBUPanelWindow.onReset)
    self.resetButton:setTitle(getText("ContextMenu_BU_ResetBreaker"))
    self.upgradeButton = button(self, PAD + 428, buttonsY, 160, ISBUPanelWindow.onUpgrade)
    local tabsY = buttonsY + ROW + PAD
    self.tabs = ISTabPanel:new(0, tabsY, self.width, self.height - tabsY - self:resizeWidgetHeight())
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
        local list = ISBUPanelList:new(0, 0, self.width, self.tabs.height - self.tabs.tabHeight, self, view)
        list:initialise()
        list:setAnchorRight(true)
        list:setAnchorBottom(true)
        self.tabs:addView(getText("IGUI_BU_Tab_" .. view), list)
        self.lists[view] = list
    end
    if PanelWindow.lastTab then self.tabs:activateView(PanelWindow.lastTab) end
    self:refresh()
end

function ISBUPanelWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.tabs and self.tabs.activeView then PanelWindow.lastTab = self.tabs.activeView.name end
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
    open[self.panel.id] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

local function count(set)
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    return n
end

-- What the panel and its networks are now, as rows.
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
    self.loadText = self.load and getText(panel.tripped and "IGUI_BU_LoadTripped" or "IGUI_BU_Load", load2(self.load),
        load2(self.capacity)) or ""
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
    local parent = Store.get(panel.parent)
    self.mainButton:setTitle(parent and getText("IGUI_BU_LeaveMain", Panels.name(parent)) or getText("IGUI_BU_JoinMain"))
    self.resetButton:setVisible(panel.tripped == true)
    local tier = panel.tier or 1
    self.upgradeButton:setVisible(tier < BU.TIERS)
    if tier < BU.TIERS then
        self.upgradeButton:setTitle(getText("ContextMenu_BU_Upgrade", tier + 1))
        local cost = Costs.upgrade(tier + 1)
        local note = getText("IGUI_BU_UpgradeNote", load2(BU.capacity(tier + 1)))
        if tier + 1 == BU.SMART_TIER then note = note .. "\n" .. getText("IGUI_BU_SmartNote") end
        self.upgradeButton:setTooltip(note .. "\n" .. Costs.describe(self.playerObj, cost, true))
        self.upgradeButton:setEnable(Costs.affords(self.playerObj, cost))
    end
    for _, utility in ipairs(BU.UTILITIES) do self:fill(utility, utility == "power" and power or water) end
    self:fillLog()
end

local function percent(value, most)
    if not value or not most or most <= 0 then return "-" end
    return string.format("%.0f%%", value * 100 / most)
end

-- What switching a power device would make of the load, for its row's tooltip; nil when it would not change it.
function ISBUPanelWindow:preview(device)
    local power = device.power or 0
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

function ISBUPanelWindow:fill(utility, state)
    local list = self.lists[utility]
    local scroll = list:getYScroll()
    list:unhighlight()
    list.hovered = nil
    list:clear()
    local panel, playerObj = self.panel, self.playerObj
    local function add(row, tooltip) list:addItem(row.text or "", row, tooltip) end
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
    -- Rooms by name, devices in no room after them, then those outside.
    local OUTSIDE = {}
    local groups, order = {}, {}
    for _, device in ipairs(devices) do
        local group = device.inside and (device.entry.room or "") or OUTSIDE
        if not groups[group] then groups[group] = {}; order[#order + 1] = group end
        table.insert(groups[group], device)
    end
    local function title(group)
        if group == OUTSIDE then return getText("IGUI_BU_Outside") end
        return group == "" and getText("IGUI_BU_NoRoom") or BU.roomName(group)
    end
    local function rank(group) return group == OUTSIDE and 2 or group == "" and 1 or 0 end
    table.sort(order, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return title(a) < title(b)
    end)
    local sheds = Panels.sheds(panel)
    for _, group in ipairs(order) do
        add({ kind = "header", text = title(group) })
        for _, device in ipairs(groups[group]) do
            local entry = device.entry
            local name = BU.displayName(entry.x, entry.y, entry.z, entry.sprite)
            if not device.inside then name = name .. "  (" .. Panels.where(panel, entry.x, entry.y) .. ")" end
            local right = utility == "power" and device.power and string.format("%.3f", device.power) or ""
            if device.state == "other" then
                local other = Store.inclusionOwner(utility, device.key)
                right = getText("IGUI_BU_ConnectedTo", other and Panels.name(other) or "")
            elseif device.state == "on" then
                local missing = self:missingOther(utility, device)
                if missing then right = right .. "  " .. missing end
                if device.held then right = right .. "  " .. getText(device.held == "shed" and "IGUI_BU_HeldShed" or "IGUI_BU_HeldTimer") end
            end
            local tooltip = utility == "power" and self:preview(device) or nil
            if not device.inside and device.state == "off" then
                local cost = Actions.lineCost("outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
                if cost then tooltip = (tooltip and tooltip .. " <LINE> " or "") .. Costs.describe(playerObj, cost) end
            end
            local controls = utility == "power" and device.state == "on"
            if controls then
                tooltip = (tooltip and tooltip .. " <LINE> " or "") .. " <RGB:0.7,0.7,0.7> "
                    .. getText(sheds and "IGUI_BU_ControlsNoteSmart" or "IGUI_BU_ControlsNote")
            end
            add({ kind = "device", text = name, right = right, device = device, state = device.state, held = device.held,
                controls = controls, sheds = sheds }, tooltip)
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
    if BU.exteriorRange() > 0 then
        rings[#rings + 1] = { steps = BU.exteriorRange(), colour = ColorInfo.new(0.3, 0.6, 1, 1) }
        reach = BU.exteriorRange()
    end
    if not panel.parent then
        rings[#rings + 1] = { steps = BU.producerRange(), colour = ColorInfo.new(1, 0.85, 0.2, 1) }
        reach = math.max(reach, BU.producerRange())
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
                if not panel.parent and steps and steps > 0 and steps <= BU.producerRange() then
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
            BU.subPanelRange()), nil, nil)
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
        tip.description = Costs.describe(playerObj, cost)
        option.toolTip = tip
        if not Costs.affords(playerObj, cost) then option.notAvailable = true end
    end
end

function ISBUPanelWindow:onLink(parent)
    local panel, playerObj = self.panel, self.playerObj
    BU.ContextMenu.queueAt(playerObj, panel.x, panel.y, panel.z, ISBUConnect:new(playerObj, "link", panel, nil, panel.x, panel.y, panel.z, parent.id))
end

function PanelWindow.open(playerObj, panel)
    local window = open[panel.id]
    if window then window:bringToTop(); window:refresh(); return window end
    window = ISBUPanelWindow:new(getCore():getScreenWidth() / 2 - 340, getCore():getScreenHeight() / 2 - 305, playerObj, panel)
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
