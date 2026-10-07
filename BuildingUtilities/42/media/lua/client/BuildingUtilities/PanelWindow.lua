-- The breaker box window: a summary line, then a tab per utility with its producers (or the main panel that supplies
-- it), its sub-panels, and its devices by room, each with a tick.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTabPanel"
require "ISUI/ISButton"
require "ISUI/ISTextBox"
require "BuildingUtilities/Panels"
local BU = BuildingUtilities
local Store, Panels, Networks = BU.Store, BU.Panels, BU.Networks

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local ROW = FONT_HGT_SMALL + 6
local PAD = 8
local REFRESH_MS = 5000

local PanelWindow = {}
BU.PanelWindow = PanelWindow
local open = {}

-- One tab's list. Each item is a row table with a kind; clicks act on the row and the part of it clicked.
ISBUPanelList = ISScrollingListBox:derive("ISBUPanelList")

local BUTTONS = { "Up", "Down", "Remove" }
local BUTTON_W = 60

function ISBUPanelList:new(x, y, width, height, window, utility)
    local o = ISScrollingListBox.new(self, x, y, width, height)
    o.window = window
    o.utility = utility
    o.itemheight = ROW
    o.font = UIFont.Small
    o.drawBorder = true
    return o
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
    if row.kind == "header" then
        self:drawRect(0, y, width, ROW, 0.3, 0.3, 0.3, 0.3)
        self:drawText(row.text, PAD, textY, 1, 0.85, 0.5, 1, UIFont.Small)
    elseif row.kind == "note" then
        self:drawText(row.text, PAD * 2, textY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    elseif row.kind == "producer" then
        self:drawText(row.text, PAD * 2, textY, row.inUse and 0.5 or 0.9, row.inUse and 1 or 0.9, row.inUse and 0.5 or 0.9, 1, UIFont.Small)
        for index, name in ipairs(BUTTONS) do
            local bx = width - (#BUTTONS - index + 1) * (BUTTON_W + 4) - PAD
            self:drawRectBorder(bx, y + 2, BUTTON_W, ROW - 4, 1, 0.6, 0.6, 0.6)
            self:drawTextCentre(getText("IGUI_BU_" .. name), bx + BUTTON_W / 2, textY, 1, 1, 1, 1, UIFont.Small)
        end
    elseif row.kind == "device" or row.kind == "all" then
        local enabled = row.state ~= "other"
        tick(self, PAD * 2, y, row.state == "on")
        local shade = enabled and 1 or 0.5
        self:drawText(row.text, PAD * 2 + ROW + 4, textY, shade, shade, shade, 1, UIFont.Small)
        if row.right then
            self:drawTextRight(row.right, width - PAD - 16, textY, 0.8, 0.8, 0.8, 1, UIFont.Small)
        end
    elseif row.kind == "link" then
        self:drawText(row.text, PAD * 2, textY, 0.6, 0.8, 1, 1, UIFont.Small)
    end
    return y + ROW
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
    local o = ISCollapsableWindow.new(self, x, y, 620, 560)
    o.playerObj = playerObj
    o.panel = panel
    o.resizable = true
    o.minimumWidth = 480
    o.minimumHeight = 300
    o:setTitle(getText("IGUI_BU_WindowTitle"))
    return o
end

function ISBUPanelWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD
    self.summaryY = top
    local buttonsY = top + FONT_HGT_SMALL + PAD
    self.renameButton = ISButton:new(PAD, buttonsY, 110, ROW, getText("IGUI_BU_Rename"), self, ISBUPanelWindow.onRename)
    self.renameButton:initialise()
    self:addChild(self.renameButton)
    self.mainButton = ISButton:new(PAD + 118, buttonsY, 220, ROW, "", self, ISBUPanelWindow.onMainPanel)
    self.mainButton:initialise()
    self:addChild(self.mainButton)
    local tabsY = buttonsY + ROW + PAD
    self.tabs = ISTabPanel:new(0, tabsY, self.width, self.height - tabsY - self:resizeWidgetHeight())
    self.tabs:initialise()
    self.tabs:setAnchorRight(true)
    self.tabs:setAnchorBottom(true)
    self.tabs:setEqualTabWidth(false)
    self:addChild(self.tabs)
    self.lists = {}
    for _, utility in ipairs(BU.UTILITIES) do
        local list = ISBUPanelList:new(0, 0, self.width, self.tabs.height - self.tabs.tabHeight, self, utility)
        list:initialise()
        list:setAnchorRight(true)
        list:setAnchorBottom(true)
        self.tabs:addView(getText("IGUI_BU_Tab_" .. utility), list)
        self.lists[utility] = list
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
end

function ISBUPanelWindow:update()
    ISCollapsableWindow.update(self)
    if not Store.get(self.panel.id) then self:close(); return end
    if getTimestampMs() - (self.refreshedAt or 0) > REFRESH_MS then self:refresh() end
end

function ISBUPanelWindow:close()
    open[self.panel.id] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

-- What the panel and its networks are now, as rows.
function ISBUPanelWindow:refresh()
    self.refreshedAt = getTimestampMs()
    local panel = self.panel
    local power, water = Networks.state(panel, "power"), Networks.state(panel, "water")
    local powerText = getText("IGUI_BU_SummaryPower", power and power.supplied and "*" or "-",
        power and power.hoursLeft and string.format("%.0f", power.hoursLeft) or "-")
    local waterText = getText("IGUI_BU_SummaryWater", water and water.supplied and "*" or "-",
        water and string.format("%.0f", water.amount or 0) or "-", water and string.format("%.0f", water.capacity or 0) or "-")
    self.summary = Panels.name(panel) .. "   " .. powerText .. "   " .. waterText
    local parent = Store.get(panel.parent)
    self.mainButton:setTitle(parent and getText("IGUI_BU_LeaveMain", Panels.name(parent)) or getText("IGUI_BU_JoinMain"))
    for _, utility in ipairs(BU.UTILITIES) do self:fill(utility, utility == "power" and power or water) end
end

local function percent(value, most)
    if not value or not most or most <= 0 then return "-" end
    return string.format("%.0f%%", value * 100 / most)
end

function ISBUPanelWindow:fill(utility, state)
    local list = self.lists[utility]
    local scroll = list:getYScroll()
    list:clear()
    local panel = self.panel
    local function add(row) list:addItem(row.text or "", row) end
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
                local generator = getCell():getGridSquare(at.x, at.y, at.z)
                generator = generator and generator:getGenerator()
                local fuel = seen and seen.fuel and (generator and percent(seen.fuel, generator:getMaxFuel()) or string.format("%.1f", seen.fuel)) or "-"
                text = getText("IGUI_BU_GeneratorRow", index, where,
                    getText(inUse and "IGUI_BU_Running" or "IGUI_BU_Standby"), fuel, seen and seen.condition and string.format("%.0f%%", seen.condition) or "-")
            else
                text = getText("IGUI_BU_TankRow", index, where, seen and seen.amount and string.format("%.0f", seen.amount) or "-",
                    seen and seen.capacity and string.format("%.0f", seen.capacity) or "-")
            end
            add({ kind = "producer", text = text, index = index, inUse = inUse })
        end
    end
    local children = Store.children(panel.id)
    if #children > 0 then
        add({ kind = "header", text = getText("IGUI_BU_SubPanels") })
        for _, child in ipairs(children) do
            local childState = Networks.state(child, utility)
            local right = utility == "power" and childState and childState.load and string.format("%.2f", childState.load) or ""
            add({ kind = "note", text = Panels.name(child) .. "   " .. right })
        end
    end
    local devices, complete = Panels.devices(panel, utility)
    add({ kind = "all", text = getText("IGUI_BU_AllInside"), state = self:allInside(devices) and "on" or "off" })
    if not complete then add({ kind = "note", text = getText("IGUI_BU_NotAllLoaded") }) end
    local rooms, order = {}, {}
    for _, device in ipairs(devices) do
        local room = device.inside and (device.entry.room or "") or "\0outside"
        if not rooms[room] then rooms[room] = {}; order[#order + 1] = room end
        table.insert(rooms[room], device)
    end
    table.sort(order)
    for _, room in ipairs(order) do
        local title = room == "\0outside" and getText("IGUI_BU_Outside") or (room == "" and getText("IGUI_BU_NoRoom") or BU.roomName(room))
        add({ kind = "header", text = title })
        for _, device in ipairs(rooms[room]) do
            local entry = device.entry
            local name = BU.displayName(entry.x, entry.y, entry.z, entry.sprite)
            if not device.inside then name = name .. "  (" .. Panels.where(panel, entry.x, entry.y) .. ")" end
            local right = utility == "power" and entry.power and string.format("%.3f", entry.power) or ""
            if device.state == "other" then
                local other = Store.inclusionOwner(utility, device.key)
                right = getText("IGUI_BU_ConnectedTo", other and Panels.name(other) or "")
            elseif device.state == "on" then
                local missing = self:missingOther(utility, device)
                if missing then right = right .. "  " .. missing end
            end
            add({ kind = "device", text = name, right = right, device = device, state = device.state })
        end
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
    local excluded = device.inside and self.panel[other].excluded[device.key]
    local included = not device.inside and self.panel[other].included[device.key]
    if excluded or (not device.inside and not included) or not (otherState and otherState.supplied) then
        return getText("IGUI_BU_Missing_" .. other)
    end
    return nil
end

function ISBUPanelWindow:onRow(utility, row, x, width)
    local panel = self.panel
    if row.kind == "producer" then
        for index, name in ipairs(BUTTONS) do
            local bx = width - (#BUTTONS - index + 1) * (BUTTON_W + 4) - PAD
            if x >= bx and x <= bx + BUTTON_W then
                if name == "Up" then Panels.moveProducer(panel, utility, row.index, -1)
                elseif name == "Down" then Panels.moveProducer(panel, utility, row.index, 1)
                else Panels.disconnectProducer(panel, utility, row.index) end
            end
        end
    elseif row.kind == "all" then
        Panels.setAllInside(panel, utility, row.state ~= "on")
    elseif row.kind == "device" and row.state ~= "other" then
        Panels.setDevice(panel, utility, row.device, row.state ~= "on")
    end
    self:refresh()
end

function ISBUPanelWindow:onRename()
    local box = ISTextBox:new(0, 0, 280, 180, getText("IGUI_BU_RenamePrompt"), Panels.name(self.panel), self,
        ISBUPanelWindow.onRenamed, self.playerObj:getPlayerNum())
    box:initialise()
    box:addToUIManager()
end

function ISBUPanelWindow:onRenamed(button)
    if button.internal ~= "OK" then return end
    local text = button.parent.entry:getText()
    self.panel.name = text ~= "" and text or nil
    PanelWindow.refreshAll()
end

-- Joins a main panel (a menu of those it can) or leaves the one it has.
function ISBUPanelWindow:onMainPanel()
    local panel = self.panel
    if panel.parent then
        Panels.unlink(panel)
        PanelWindow.refreshAll()
        return
    end
    local menu = ISContextMenu.get(self.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    local candidates = Panels.linkCandidates(panel)
    if #candidates == 0 then
        local hasProducers = #panel.power.producers > 0 or #panel.water.producers > 0
        local option = menu:addOption(getText(hasProducers and "IGUI_BU_Reason_hasProducers" or "IGUI_BU_NoMainInRange",
            BU.subPanelRange()), nil, nil)
        option.notAvailable = true
        return
    end
    for _, candidate in ipairs(candidates) do
        menu:addOption(getText("IGUI_BU_PanelChoice", Panels.name(candidate.panel), getText("IGUI_BU_Steps", candidate.steps)),
            self, ISBUPanelWindow.onLink, candidate.panel)
    end
end

function ISBUPanelWindow:onLink(parent)
    local ok, reason = Panels.link(self.panel, parent)
    if not ok then HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_Reason_" .. reason)) end
    PanelWindow.refreshAll()
end

function PanelWindow.open(playerObj, panel)
    local window = open[panel.id]
    if window then window:bringToTop(); window:refresh(); return window end
    window = ISBUPanelWindow:new(getCore():getScreenWidth() / 2 - 310, getCore():getScreenHeight() / 2 - 280, playerObj, panel)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    open[panel.id] = window
    return window
end

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
