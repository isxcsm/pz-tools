-- The breaker box window: its name and supply, its load against what it carries, then a tab per utility with its
-- producers (or the main panel that supplies it), its sub-panels, and its devices by room, each with a tick. A row
-- under the mouse outlines its objects in the world. Free changes go to the server as commands; lines are laid and
-- taken away by the player at the place, as timed actions.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTabPanel"
require "ISUI/ISButton"
require "ISUI/ISTextBox"
require "BuildingUtilities/ContextMenu"
local BU = BuildingUtilities
local Store, Panels, Networks, Costs, Actions, Sync = BU.Store, BU.Panels, BU.Networks, BU.Costs, BU.Actions, BU.Sync

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local ROW = FONT_HGT_SMALL + 6
local PAD = 8
local REFRESH_MS = 5000
local BAR_W = 220

local PanelWindow = {}
BU.PanelWindow = PanelWindow
local open = {}

-- The objects a row stands for: a device's, or what is on a producer's square.
local function rowObjects(row)
    if row.device then
        local entry = row.device.entry
        return BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)
    elseif row.at then
        local square = getCell():getGridSquare(row.at.x, row.at.y, row.at.z)
        local _, object = Panels.producerOn(square)
        return object and { object } or {}
    end
    return {}
end

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
    o.highlighted = {}
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
    if self.hovered == item.index and (row.device or row.at) then
        self:drawRect(0, y, width, ROW, 0.15, 1, 1, 1)
    end
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
        if row then self:highlight(rowObjects(row)) end
    end
    ISScrollingListBox.prerender(self)
end

function ISBUPanelList:highlight(objects)
    local playerNum = self.window.playerObj:getPlayerNum()
    local colour = getCore():getGoodHighlitedColor()
    for _, object in ipairs(objects) do
        object:setHighlightColor(playerNum, colour)
        object:setHighlighted(playerNum, true, false)
        object:setOutlineHighlightCol(playerNum, colour)
        object:setOutlineHighlight(playerNum, true)
        self.highlighted[#self.highlighted + 1] = object
    end
end

function ISBUPanelList:unhighlight()
    local playerNum = self.window.playerObj:getPlayerNum()
    for _, object in ipairs(self.highlighted) do
        object:setHighlighted(playerNum, false, false)
        object:setOutlineHighlight(playerNum, false)
    end
    self.highlighted = {}
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
    local o = ISCollapsableWindow.new(self, x, y, 640, 580)
    o.playerObj = playerObj
    o.panel = panel
    o.resizable = true
    o.minimumWidth = 520
    o.minimumHeight = 320
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
    local buttonsY = self.loadY + FONT_HGT_SMALL + PAD
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
    if self.load then
        local share = math.min(1, self.load / math.max(self.capacity, 1e-6))
        local r, g = 0.3, 0.8
        if self.panel.tripped or self.load > self.capacity then r, g = 0.9, 0.2 elseif share > 0.8 then r, g = 0.9, 0.8 end
        self:drawRect(PAD, self.loadY, BAR_W, FONT_HGT_SMALL, 0.6, 0.1, 0.1, 0.1)
        self:drawRect(PAD, self.loadY, BAR_W * share, FONT_HGT_SMALL, 0.8, r, g, 0.2)
        self:drawRectBorder(PAD, self.loadY, BAR_W, FONT_HGT_SMALL, 1, 0.6, 0.6, 0.6)
        self:drawText(self.loadText, PAD + BAR_W + 8, self.loadY, 1, 1, 1, 1, UIFont.Small)
    end
end

function ISBUPanelWindow:update()
    ISCollapsableWindow.update(self)
    if not Store.get(self.panel.id) then self:close(); return end
    if getTimestampMs() - (self.refreshedAt or 0) > REFRESH_MS then self:refresh() end
end

function ISBUPanelWindow:close()
    for _, list in pairs(self.lists or {}) do list:unhighlight() end
    open[self.panel.id] = nil
    self:setVisible(false)
    self:removeFromUIManager()
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
    self.loadText = self.load and getText(panel.tripped and "IGUI_BU_LoadTripped" or "IGUI_BU_Load",
        string.format("%.2f", self.load), string.format("%.2f", self.capacity)) or ""
    local parent = Store.get(panel.parent)
    self.mainButton:setTitle(parent and getText("IGUI_BU_LeaveMain", Panels.name(parent)) or getText("IGUI_BU_JoinMain"))
    self.resetButton:setVisible(panel.tripped == true)
    local tier = panel.tier or 1
    self.upgradeButton:setVisible(tier < BU.TIERS)
    if tier < BU.TIERS then
        self.upgradeButton:setTitle(getText("ContextMenu_BU_Upgrade", tier + 1))
        local cost = Costs.upgrade(tier + 1)
        self.upgradeButton:setTooltip(getText("IGUI_BU_UpgradeNote", string.format("%.2f", BU.capacity(tier + 1))) .. "\n"
            .. Costs.describe(self.playerObj, cost, true))
        self.upgradeButton:setEnable(Costs.affords(self.playerObj, cost))
    end
    for _, utility in ipairs(BU.UTILITIES) do self:fill(utility, utility == "power" and power or water) end
end

local function percent(value, most)
    if not value or not most or most <= 0 then return "-" end
    return string.format("%.0f%%", value * 100 / most)
end

function ISBUPanelWindow:fill(utility, state)
    local list = self.lists[utility]
    local scroll = list:getYScroll()
    list:unhighlight()
    list.hovered = nil
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
            local right = utility == "power" and childState and childState.load and string.format("%.2f", childState.load) or ""
            if child.tripped and utility == "power" then right = right .. "  " .. getText("IGUI_BU_Tripped") end
            add({ kind = "note", text = Panels.name(child) .. "   " .. right })
        end
    end
    local devices, complete = Panels.devices(panel, utility)
    add({ kind = "all", text = getText("IGUI_BU_AllInside"), state = self:allInside(devices) and "on" or "off" })
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
    for _, group in ipairs(order) do
        add({ kind = "header", text = title(group) })
        for _, device in ipairs(groups[group]) do
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
    window = ISBUPanelWindow:new(getCore():getScreenWidth() / 2 - 320, getCore():getScreenHeight() / 2 - 290, playerObj, panel)
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
