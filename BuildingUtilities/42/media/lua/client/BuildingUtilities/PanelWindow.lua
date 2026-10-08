-- The breaker box window: its name and tier as its title, a status line (BuildingUtilities/PanelStatus), its load against what it carries and a banner when the breaker is
-- down or devices are shed, then a tab per utility (power's led by the box's main switch) with its producers (each
-- generator running, on standby or out of service) or the main panel that supplies it, its sub-panels, and its
-- devices room by room, and a tab with what happened to the box; beside them the floor plan
-- (BuildingUtilities/PanelPlan). A row under the mouse outlines its objects in the world, marks them on the plan and
-- tells what switching it would do to the load. Free changes go to the server as commands; lines are laid and taken
-- away, and the main switch thrown, by the player at the place, as timed actions. Devices outside can be chosen
-- several at a time (the Choose button on their group) and connected in one walk, with what they all take shown first. The search box keeps the
-- rows whose device or room has the words; devices new since the window was last closed are marked. The load bar
-- tells what makes the load. With sub-panels, a tab per box of the supply tree (the main panel, then each sub-panel
-- after the one it hangs from) shows that box in the same window, as a main or sub-panel row does. The window is the
-- player's at the box
-- they opened it at (its anchor; a window opened from another's row keeps that one's): it closes once they are far
-- from it (PanelWindow.CLOSE_RANGE), die or another character takes their place.
require "TimedActions/ISBaseTimedAction"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTabPanel"
require "ISUI/ISButton"
require "ISUI/ISTextBox"
require "ISUI/ISTextEntryBox"
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/PanelPlan"
require "BuildingUtilities/PanelList"
local BU = BuildingUtilities
local Store, Panels, Networks, Costs, Actions, Sync, Energy = BU.Store, BU.Panels, BU.Networks, BU.Costs, BU.Actions,
    BU.Sync, BU.Energy
local Units, Ui = BU.Units, BU.PanelUi
local FONT_HGT_SMALL, ROW, PAD, REFRESH_MS, BAR_W, LOG, LIST_W, MIN_LIST, MIN_PLAN, OPTION_W, SEEN, OUTSIDE,
    ROOM_TICK_X, CHOOSE_W, BATCH_BUTTONS, BATCH_W, load2, percent, count, nextSchedule = Ui.FONT_HGT_SMALL, Ui.ROW,
    Ui.PAD, Ui.REFRESH_MS, Ui.BAR_W, Ui.LOG, Ui.LIST_W, Ui.MIN_LIST, Ui.MIN_PLAN, Ui.OPTION_W, Ui.SEEN, Ui.OUTSIDE,
    Ui.ROOM_TICK_X, Ui.CHOOSE_W, Ui.BATCH_BUTTONS, Ui.BATCH_W, Ui.load2, Ui.percent, Ui.count, Ui.nextSchedule
local deviceButtons, chooseButtonX, batchButtonX = Ui.deviceButtons, Ui.chooseButtonX, Ui.batchButtonX

local PanelWindow = {}
BU.PanelWindow = PanelWindow
local open = {}
-- A change told (BU.onChanged, a notice, a network event) refreshes the window once it settles: one action often
-- tells it twice within a few frames.
local SETTLE_MS = 100
-- What the player chose, kept while the game runs: view options, folded rooms, the plan shown, its share of the
-- window and its legend.
PanelWindow.options = { activeOnly = false, byLoad = false }
PanelWindow.folded = {}
PanelWindow.planShare = 0.5

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

-- The boxes of a box's supply tree: its main panel (Panels.root) first, then each sub-panel after the one it hangs
-- from, each { panel, depth }.
function PanelWindow.tree(panel)
    local result, seen = {}, {}
    local function walk(box, depth)
        if seen[box.id] then return end
        seen[box.id] = true
        result[#result + 1] = { panel = box, depth = depth }
        for _, child in ipairs(Store.children(box.id)) do walk(child, depth + 1) end
    end
    walk(Panels.root(panel), 0)
    return result
end

local function treeKey(tree)
    local ids = {}
    for _, entry in ipairs(tree) do ids[#ids + 1] = entry.panel.id end
    return table.concat(ids, ",")
end

-- A box's name with the floors its zone takes (Panels.zoneFloors): the boxes of a tall building tell apart.
function PanelWindow.boxTitle(panel)
    local name, low, high = Panels.name(panel), Panels.zoneFloors(panel)
    if low and low ~= high then return getText("IGUI_BU_SubPanelFloors", name, BU.floorName(low), BU.floorName(high)) end
    if low then return getText("IGUI_BU_SubPanelFloor", name, BU.floorName(low)) end
    return name
end

-- A box's tab: its title, the main panel's marked in front (where a cut title keeps it), and below the first
-- sub-panels a mark a level down; and its tooltip, the whole title, the main panel's saying so in words.
local function tabTitle(entry)
    local name = PanelWindow.boxTitle(entry.panel)
    if entry.depth == 0 then return getText("IGUI_BU_MainTab", name), getText("IGUI_BU_MainTabTip", name) end
    if entry.depth > 1 then name = string.rep(">", entry.depth - 1) .. " " .. name end
    return name, name
end

function ISBUPanelWindow:new(x, y, playerObj, panel, anchor)
    local shown = PanelWindow.planShown
    if shown == nil then shown = planByDefault() end
    local width = math.min(windowWidth(LIST_W, shown), getCore():getScreenWidth())
    local o = ISCollapsableWindow.new(self, x, y, math.max(width, minimumWidth(shown)), 610)
    o.playerObj = playerObj
    o.panel = panel
    o.anchor = anchor or { x = panel.x, y = panel.y, z = panel.z }
    o.tree = PanelWindow.tree(panel)
    o.treeKey = treeKey(o.tree)
    o.planWanted = shown
    o.resizable = true
    o.minimumWidth = minimumWidth(shown)
    o.minimumHeight = 340 + (#o.tree > 1 and ROW + PAD or 0)
    o.rangeObjects = {}
    o.planOutlined = {}
    o.views = {}
    -- The networks' states the last refresh read, by utility; the tabs not shown since then, filled as they open.
    o.states, o.pending = {}, {}
    -- Devices outside being chosen to connect together, by utility.
    o.choosing, o.chosen = {}, { power = {}, water = {} }
    o:setTitle(getText("IGUI_BU_TierName", Panels.name(panel), panel.tier or 1))
    return o
end

local function button(window, x, y, width, height, onclick)
    local b = ISButton:new(x, y, width, height, "", window, onclick)
    b:initialise()
    window:addChild(b)
    return b
end

function ISBUPanelWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD
    -- The supply tree's boxes as tabs, when it has more than this one (placed by placePanelTabs).
    self.panelTabs = {}
    if #self.tree > 1 then
        for _, entry in ipairs(self.tree) do
            local tab = button(self, PAD, top, 60, ROW, ISBUPanelWindow.onPanelTab)
            tab.internal = entry.panel.id
            self.panelTabs[#self.panelTabs + 1] = tab
        end
        top = top + ROW + PAD
    end
    self.statusY = top
    self.loadY = top + FONT_HGT_SMALL + 4
    self.bannerY = self.loadY + ROW + 4
    local buttonsY = self.bannerY + ROW + 4
    -- Placed by layoutPanes at the right, as the window's width changes.
    self.rangeButton = button(self, self.width - PAD - 130, self.loadY, 130, ROW, ISBUPanelWindow.onRange)
    self.planButton = button(self, self.width - PAD - 130 - 4 - 110, self.loadY, 110, ROW, ISBUPanelWindow.onPlan)
    self.renameButton = button(self, PAD, buttonsY, 100, ROW, ISBUPanelWindow.onRename)
    self.renameButton:setTitle(getText("IGUI_BU_Rename"))
    self.mainButton = button(self, PAD + 106, buttonsY, 170, ROW, ISBUPanelWindow.onMainPanel)
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
    -- A tab for each utility that is on (BU.enabled), and the log; the window opens anew when that changes (refresh).
    self.utilities = BU.utilities()
    self.utilitiesKey = table.concat(self.utilities, ",")
    local views = {}
    for _, utility in ipairs(self.utilities) do views[#views + 1] = utility end
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
    self.searchHint = getText("IGUI_BU_Search")
    -- Over the status line: both utilities in full, as a tooltip.
    self.statusArea = ISButton:new(PAD, self.statusY, self.width - PAD * 2, FONT_HGT_SMALL, "", self, nil)
    self.statusArea:initialise()
    self.statusArea.displayBackground = false
    self.statusArea.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.statusArea:setAnchorRight(true)
    self:addChild(self.statusArea)
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

-- The list and, beside it, the plan with its share of the window, each at least so wide; the divider between them;
-- the buttons at the right of the load bar.
function ISBUPanelWindow:layoutPanes()
    if not (self.tabs and self.plan) then return end
    local shown = self.plan:getIsVisible()
    self:placeTopButtons(shown)
    self:placePanelTabs()
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

-- The boxes' tabs' titles and their widths, measured once a refresh (not each time the window is laid out).
function ISBUPanelWindow:measurePanelTabs()
    local measure = getTextManager()
    self.tabTitles, self.tabTips, self.tabWidths = {}, {}, {}
    for index, entry in ipairs(self.tree) do
        self.tabTitles[index], self.tabTips[index] = tabTitle(entry)
        self.tabWidths[index] = measure:MeasureStringX(UIFont.Small, self.tabTitles[index]) + 16
    end
end

-- The boxes' tabs across the top: each as wide as its title; where they do not all fit, each an equal share with its
-- title cut (the whole one its tooltip). This box's lit. Laid out again only when the window's width changed (a
-- divider dragged does not), or when asked (a refresh).
function ISBUPanelWindow:placePanelTabs(force)
    local tabs = self.panelTabs or {}
    if #tabs == 0 or not force and self.tabsPlacedAt == self.width then return end
    if not self.tabTitles then self:measurePanelTabs() end
    self.tabsPlacedAt = self.width
    local measure = getTextManager()
    local function width(text) return measure:MeasureStringX(UIFont.Small, text) end
    local titles, total = self.tabTitles, 0
    for index = 1, #tabs do total = total + (self.tabWidths[index] or 0) end
    local room = self.width - PAD * 2 - (#tabs - 1) * 4
    local share = total > room and math.floor(room / #tabs) or nil
    local x = PAD
    for index, tab in ipairs(tabs) do
        local title, w = titles[index] or "", self.tabWidths[index] or 16
        if share then
            w = share
            local cut = title
            while width(cut .. "...") > w - 10 and #cut > 1 do cut = cut:sub(1, -2) end
            if cut ~= title then title = cut .. "..." end
        end
        tab:setX(x)
        tab:setWidth(w)
        tab:setTitle(title)
        tab:setTooltip(self.tabTips[index])
        local lit = tab.internal == self.panel.id
        tab.backgroundColor = lit and { r = 0.15, g = 0.4, b = 0.55, a = 1 } or { r = 0, g = 0, b = 0, a = 0.8 }
        tab.borderColor = lit and { r = 0.5, g = 0.75, b = 0.9, a = 1 } or { r = 0.4, g = 0.4, b = 0.4, a = 1 }
        x = x + w + 4
    end
end

function ISBUPanelWindow:onPanelTab(tab)
    local target = Store.get(tab.internal)
    if target then self:switchTo(target) end
end

-- Another box of the supply tree shown in this window's place (its own window, where it has one, moved here).
function ISBUPanelWindow:switchTo(target)
    if target.id == self.panel.id then return end
    local x, y, w, h = self:getX(), self:getY(), self:getWidth(), self:getHeight()
    local anchor = self.anchor
    self:close()
    local window = PanelWindow.open(self.playerObj, target, anchor)
    window:setX(x)
    window:setY(y)
    window:setWidth(math.max(w, window.minimumWidth))
    window:setHeight(math.max(h, window.minimumHeight))
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

-- The plan beside the list, or not: the window grows or shrinks by it and the list keeps its width. A frame later
-- the game moves the window's anchored children (its title bar's buttons, the resize grips, the status line) by the
-- difference and calls onResize, which lays the panes out again as here: what layoutPanes places has no anchor across.
function ISBUPanelWindow:setPlanShown(shown)
    PanelWindow.planShown = shown
    if self.plan:getIsVisible() == shown then return end
    local listW = self.tabs:getWidth()
    self.plan:setVisible(shown)
    self.splitter:setVisible(shown)
    self.minimumWidth = minimumWidth(shown)
    self:setWidth(math.max(self.minimumWidth, math.min(windowWidth(listW, shown), getCore():getScreenWidth())))
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

-- The plan and range buttons at the right of the load bar. With the plan shown the range is a switch on it: only the
-- plan button stays.
function ISBUPanelWindow:placeTopButtons(planShown)
    self.rangeButton:setVisible(not planShown)
    self.rangeButton:setX(self.width - PAD - 130)
    self.planButton:setX(planShown and self.width - PAD - 110 or self.width - PAD - 130 - 4 - 110)
end

function ISBUPanelWindow:onPlan() self:setPlanShown(not self.plan:getIsVisible()) end

function ISBUPanelWindow:onActiveOnly()
    PanelWindow.options.activeOnly = not PanelWindow.options.activeOnly
    self:placeOptions()
    self:redraw()
end

function ISBUPanelWindow:onByLoad()
    PanelWindow.options.byLoad = not PanelWindow.options.byLoad
    self:placeOptions()
    self:redraw()
end

-- The utility the list shows now: the plan follows it (the first tab's while the log is shown; nil with both off).
function ISBUPanelWindow:activeUtility()
    local view = self.tabs and self.tabs.activeView and self.tabs.activeView.view
    local utility = view and view.utility
    if utility == nil or utility == LOG then return self.utilities and self.utilities[1] end
    return utility
end

function ISBUPanelWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.tabs and self.tabs.activeView then PanelWindow.lastTab = self.tabs.activeView.name end
    -- A tab opened that the last refresh left: its rows, before the plan shows its devices.
    if self.pending[self:activeUtility()] then self:refill(self:activeUtility()) end
    if self.plan and self.plan:getIsVisible() and self.planUtility ~= self:activeUtility() then self:updatePlan() end
    if self.statusUtility ~= self:activeUtility() then self:updateStatus() end
    -- The range is outlined a slice a frame: here, as update runs only a few times a second.
    if self.rangeJob then self:stepRange() end
end

function ISBUPanelWindow:render()
    ISCollapsableWindow.render(self)
    local status = self.status
    if status then
        local c, dot = status.colour, FONT_HGT_SMALL - 6
        self:drawRect(PAD, self.statusY + 3, dot, dot, 1, c[1], c[2], c[3])
        self:drawText(status.text, status.textX, self.statusY, c[1], c[2], c[3], 1, UIFont.Small)
        if status.reason and status.reasonEnd <= self.width - PAD then
            self:drawText(status.reason, status.reasonX, self.statusY, 0.65, 0.65, 0.65, 1, UIFont.Small)
        end
    end
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
        self:drawText(self.searchHint, search:getX() + 6, search:getY() + (search:getHeight() - FONT_HGT_SMALL) / 2,
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
    -- Its character dead, or another in its place (a new one after death), or far from the box it was opened at and
    -- from every box of the supply tree it shows: the window was theirs there. Not while an action walks them (one of
    -- the window's own, to a generator or another box): it closes if they stay away once it is done.
    local player = self.playerObj
    if player:isDead() or getSpecificPlayer(player:getPlayerNum()) ~= player then self:close(); return end
    if self:away() > PanelWindow.CLOSE_RANGE and not ISTimedActionQueue.isPlayerDoingAction(player) then
        self:close()
        return
    end
    local now = getTimestampMs()
    if self.changedAt and now - self.changedAt >= SETTLE_MS or now - (self.refreshedAt or 0) > REFRESH_MS then self:refresh() end
end

-- How far the player is from the nearest of the box it was opened at and the boxes of its supply tree: the larger of
-- the steps across, and TILES_PER_FLOOR a floor up or down.
function ISBUPanelWindow:away()
    local player = self.playerObj
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local function from(box)
        return math.max(math.abs(px - box.x - 0.5), math.abs(py - box.y - 0.5))
            + math.abs(pz - box.z) * PanelWindow.TILES_PER_FLOOR
    end
    local nearest = from(self.anchor)
    for _, entry in ipairs(self.tree) do nearest = math.min(nearest, from(entry.panel)) end
    return nearest
end

-- Something the window shows changed: it refreshes once that settles (SETTLE_MS).
function ISBUPanelWindow:changed() self.changedAt = self.changedAt or getTimestampMs() end

function ISBUPanelWindow:close()
    -- What the window listed is no longer new; for a box taken down nothing is kept.
    if Store.get(self.panel.id) then
        local store = ModData.getOrCreate(SEEN)
        for utility, view in pairs(self.views or {}) do
            local set = {}
            for _, device in ipairs(view.devices or {}) do set[device.key] = true end
            store[self.panel.id .. "|" .. utility] = set
        end
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

-- What the panel and its networks are now, as rows, and the plan. The tab shown is filled now (and power's, which
-- the load bar's tooltip tells), the other as it opens.
function ISBUPanelWindow:refresh()
    self.refreshedAt, self.changedAt = getTimestampMs(), nil
    -- On a client in multiplayer the data is received anew: the panel by its id.
    local panel = Store.get(self.panel.id)
    if not panel then return end
    self.panel = panel
    -- A utility turned on or off in the sandbox, or a box joined or left the supply tree: the window opens anew where
    -- it is, with its tabs (reopen).
    local tree = PanelWindow.tree(panel)
    if table.concat(BU.utilities(), ",") ~= self.utilitiesKey or treeKey(tree) ~= self.treeKey then
        self:reopen()
        return
    end
    -- The same boxes, as the data has them now (renamed, rezoned): the tabs' titles, measured here, not as they are
    -- laid out; and the highest floor of their buildings, for the boosters' rows.
    self.tree = tree
    self:measurePanelTabs()
    self.treeTop = nil
    for _, entry in ipairs(tree) do
        local building = Panels.building(entry.panel)
        if building and (not self.treeTop or building.maxLevel > self.treeTop) then self.treeTop = building.maxLevel end
    end
    local powerOn = BU.enabled("power")
    local power, water = Networks.state(panel, "power"), Networks.state(panel, "water")
    self.states = { power = power, water = water }
    self:setTitle(getText("IGUI_BU_TierName", Panels.name(panel), panel.tier or 1))
    self:placePanelTabs(true)
    self.capacity = Panels.capacity(panel)
    self.load = power and power.load or nil
    self.loadFactor = power and power.loadFactor or 1
    self.loadText = self.load and getText(panel.tripped and "IGUI_BU_LoadTripped" or "IGUI_BU_Load", load2(self.load),
        load2(self.capacity)) or ""
    -- What the line into the box loses, counted in the load.
    local pieces, loss = Panels.powerLine(panel, power)
    if self.load and pieces and loss > 0 and power.loadFactor then
        local withLoss = self.loadText .. "   " .. getText("IGUI_BU_LineLoss", string.format("%.1f", loss), pieces)
        local room = self.planButton:getX() - (PAD + BAR_W + 8) - PAD
        if getTextManager():MeasureStringX(UIFont.Small, withLoss) <= room then self.loadText = withLoss end
    end
    self.loadArea:setVisible(self.load ~= nil)
    self.loadArea:setWidth(BAR_W + 8 + getTextManager():MeasureStringX(UIFont.Small, self.loadText))
    -- The banner: the breaker down, devices shed, or the load near what the box carries.
    local shed = count(panel.power.shed)
    if powerOn and panel.tripped then
        self.banner = { text = getText("IGUI_BU_BannerTripped", load2(self.capacity)), r = 0.6, g = 0.1, b = 0.1 }
    elseif powerOn and shed > 0 then
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
    self.resetButton:setVisible(powerOn and panel.tripped == true)
    local tier = panel.tier or 1
    self.upgradeButton:setVisible(tier < BU.TIERS)
    if tier < BU.TIERS then
        self.upgradeButton:setTitle(getText("ContextMenu_BU_Upgrade", tier + 1))
        local cost = Costs.upgrade(tier + 1)
        self.upgradeButton:setTooltip(Panels.upgradeNote(tier + 1, true) .. "\n" .. Costs.describe(self.playerObj, cost, true))
        self.upgradeButton:setEnable(Costs.affords(self.playerObj, cost))
    end
    -- The buttons shown, left to right: the reset only while the breaker is down, so the row fits the narrowest window.
    local x = PAD
    for _, shown in ipairs({ self.renameButton, self.mainButton, self.resetButton, self.upgradeButton }) do
        if shown:getIsVisible() then
            shown:setX(x)
            x = x + shown:getWidth() + 6
        end
    end
    local building = Panels.building(panel)
    self.building = building
    self.rooms = Panels.rooms(building)
    self.titles = Panels.roomTitles(building)
    self.pending = {}
    local active = self:activeUtility()
    for _, utility in ipairs(self.utilities) do
        if utility == active or utility == "power" and self.load then self:fill(utility, self.states[utility])
        else self.pending[utility] = { state = self.states[utility] } end
    end
    self:fillLog()
    -- How water reaches the floors with fixtures, from the rows just filled: the status line and the plan both tell.
    self.waterSupply = self:workOutWaterSupply()
    self:updateStatus()
    self.loadArea:setTooltip(self:loadBreakdown())
    self:checkRange()
    self:updatePlan()
end

-- The window opens anew in its place, as large, with what the player had set here: the search, the room shown, the
-- zone editing, the devices outside being chosen, the plan's floor, zoom and pan, and the range shown.
function ISBUPanelWindow:reopen()
    local kept = { x = self:getX(), y = self:getY(), w = self:getWidth(), h = self:getHeight(),
        text = self.search:getText(), query = self.query, roomFilter = self.roomFilter, zoneEditing = self.zoneEditing,
        choosing = self.choosing, chosen = self.chosen, range = self.rangeShown,
        floor = self.plan.floor, zoom = self.plan.zoom, panX = self.plan.panX, panY = self.plan.panY }
    self:close()
    local window = PanelWindow.open(self.playerObj, self.panel, self.anchor)
    window:setX(kept.x)
    window:setY(kept.y)
    window:setWidth(math.max(kept.w, window.minimumWidth))
    window:setHeight(math.max(kept.h, window.minimumHeight))
    if kept.text and kept.text ~= "" then window.search:setText(kept.text) end
    window.query, window.roomFilter, window.zoneEditing = kept.query, kept.roomFilter, kept.zoneEditing
    window.choosing, window.chosen = kept.choosing, kept.chosen
    window.plan.floor, window.plan.zoom, window.plan.panX, window.plan.panY = kept.floor, kept.zoom, kept.panX, kept.panY
    if kept.range then window:showRange(true) end
    window:refresh()
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

-- One tab's rows again from what the last refresh read (a fold, a choice): the API is not asked again.
function ISBUPanelWindow:refill(utility)
    local pending, view = self.pending[utility], self.views[utility]
    self.pending[utility] = nil
    if pending then return self:fill(utility, pending.state, pending.devices, pending.complete) end
    if view then self:fill(utility, view.state, view.devices, view.complete) end
end

-- Every tab's rows again so (a search, a view option, a room filtered): the one shown now, the other as it opens.
function ISBUPanelWindow:redraw()
    local active = self:activeUtility()
    for _, utility in ipairs(self.utilities) do
        local view = self.views[utility]
        if utility == active then
            self:refill(utility)
        elseif view and not self.pending[utility] then
            self.pending[utility] = { state = view.state, devices = view.devices, complete = view.complete }
        end
    end
end

-- Search.
function ISBUPanelWindow:onSearch()
    local text = self.search:getText() or ""
    self.query = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    self:redraw()
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
                or device.held == "blackout" and "IGUI_BU_HeldBlackout" or "IGUI_BU_HeldTimer")
        elseif power > 0 then
            text = string.format("%.3f", power) .. " (" .. percent(power, self.capacity) .. ")"
        else
            text, dim = getText("IGUI_BU_Idle"), true
        end
    end
    if device.state == "on" then
        local missing = Panels.missingOther(self.panel, utility, device, self.states[utility == "power" and "water" or "power"])
        if missing then text = (text ~= "" and text .. "  " or "") .. getText("IGUI_BU_Missing_" .. missing) end
    end
    return text, dim
end

-- A tab's rows, from the panel's devices as the API has them now, or as given (devices and whether they are
-- complete, from the last refresh).
function ISBUPanelWindow:fill(utility, state, devices, complete)
    local list = self.lists[utility]
    local scroll = list:getYScroll()
    list:unhighlight()
    list.hovered = nil
    list.selected = -1
    list:clear()
    local panel, playerObj = self.panel, self.playerObj
    local function add(row, tooltip) list:addItem(row.text or "", row, tooltip) end
    if not devices then devices, complete = Panels.devices(panel, utility) end
    local view = { state = state, devices = devices, complete = complete, names = {}, status = {}, totals = {},
        producerText = {}, fresh = {} }
    self.views[utility] = view
    -- The box's main switch first: all its power, thrown at the box.
    if utility == "power" then
        local off = panel.switchedOff == true
        add({ kind = "mainSwitch", text = getText(off and "IGUI_BU_MainSwitchOff" or "IGUI_BU_MainSwitchOn"),
            state = off and "off" or "on" }, getText(panel.parent and "IGUI_BU_MainSwitchTipSub" or "IGUI_BU_MainSwitchTip"))
    end
    local parent = Store.get(panel.parent)
    if parent then
        add({ kind = "link", header = true, text = getText("IGUI_BU_SuppliedBy", Panels.name(parent)), target = parent.id },
            getText("IGUI_BU_OpenTip"))
        -- What is wired through it on to its main panel, which lists them.
        local root, routed = Panels.root(panel), 0
        for _, at in ipairs(root[utility].producers) do
            if at.via == panel.id then routed = routed + 1 end
        end
        for _, unit in ipairs(Units.of(root.id, utility)) do
            if unit.via == panel.id then routed = routed + 1 end
        end
        if routed > 0 then
            add({ kind = "link", text = getText("IGUI_BU_RoutedHere", routed, Panels.name(root)), target = root.id },
                getText("IGUI_BU_OpenTip"))
        end
    else
        -- Water groups first: the tanks' and fixtures' rows name theirs (with more than one).
        if utility == "water" then self:waterGroupRows(add, state, devices) end
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
            local inUse = PanelWindow.producerInUse(state, at)
            local where = Panels.where(panel, at.x, at.y)
            local via = at.via and Store.get(at.via)
            if via then where = getText("IGUI_BU_WhereVia", where, Panels.name(via)) end
            local text, generatorState
            if utility == "power" then
                local square = getCell():getGridSquare(at.x, at.y, at.z)
                local generator = square and square:getGenerator()
                local fuel = seen and seen.fuel and (generator and percent(seen.fuel, generator:getMaxFuel()) or string.format("%.1f", seen.fuel)) or "-"
                generatorState = PanelWindow.generatorState(state, at)
                text = getText("IGUI_BU_GeneratorRow", index, where, PanelWindow.generatorStateText(generatorState), fuel,
                    seen and seen.condition and string.format("%.0f%%", seen.condition) or "-")
            else
                text = getText("IGUI_BU_TankRow", index, where, seen and seen.amount and string.format("%.0f", seen.amount) or "-",
                    seen and seen.capacity and string.format("%.0f", seen.capacity) or "-")
            end
            view.producerText[index] = text
            local row = { kind = "producer", text = text, index = index, at = at, inUse = inUse, water = utility == "water",
                out = generatorState == "out" }
            if utility == "water" and #BU.Water.groups(panel) > 1 then
                row.group = BU.Water.producerGroup(at)
                row.groupText, row.groupColour = BU.Water.groupName(panel, row.group), PanelWindow.groupColour(panel, row.group)
            end
            -- A generator's row tells how servicing one works: switched off by hand, the others take over.
            add(row, utility == "power" and getText("IGUI_BU_GeneratorTip") or nil)
        end
        if utility == "water" then self:waterUnitRows(add) end
    end
    local children = Store.children(panel.id)
    if #children > 0 then
        add({ kind = "header", text = getText("IGUI_BU_SubPanels") })
        for _, child in ipairs(children) do
            local childState = Networks.state(child, utility)
            local right = utility == "power" and childState and childState.load and load2(childState.load) or ""
            if child.tripped and utility == "power" then right = right .. "  " .. getText("IGUI_BU_Tripped") end
            add({ kind = "link", text = PanelWindow.boxTitle(child) .. "   " .. right, target = child.id },
                getText("IGUI_BU_OpenTip"))
        end
    end
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
    if utility == "power" then
        local dark = count(panel.power.blackout)
        add({ kind = "blackout", text = dark > 0 and getText("IGUI_BU_BlackoutOn", dark) or getText("IGUI_BU_Blackout"),
            state = dark > 0 and "on" or "off" }, getText(dark > 0 and "IGUI_BU_BlackoutEndTip" or "IGUI_BU_BlackoutTip"))
    end
    if not complete then add({ kind = "note", text = getText("IGUI_BU_NotAllLoaded") }) end
    if #devices == 0 then add({ kind = "note", text = getText("IGUI_BU_NoDevices_" .. utility) }) end
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
    end
    local function visible(group) return #group.devices > 0 and (not self.roomFilter or self.roomFilter == group.id) end
    -- A room's header and its devices.
    local function emit(group)
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
                local device = shown.device
                local tooltip = utility == "power" and self:preview(device) or nil
                if not device.inside and device.state == "off" then
                    local cost = Actions.outsideCost(panel, utility, device)
                    if cost then tooltip = (tooltip and tooltip .. " <LINE> " or "") .. Costs.describe(playerObj, cost) end
                end
                local controls = timers and utility == "power" and device.state == "on"
                if controls then
                    tooltip = (tooltip and tooltip .. " <LINE> " or "") .. " <RGB:0.7,0.7,0.7> "
                        .. getText(sheds and "IGUI_BU_ControlsNoteSmart" or "IGUI_BU_ControlsNote")
                end
                local choosableDevice = choosing and not device.inside and device.state == "off"
                local groupText, groupColour
                if device.group and device.state == "on" and #BU.Water.groups(panel) > 1 then
                    groupText, groupColour = BU.Water.groupName(panel, device.group), PanelWindow.groupColour(panel, device.group)
                end
                add({ kind = "device", text = shown.name, right = shown.status, dim = shown.dim, device = device,
                    state = device.state, held = device.held, controls = controls, sheds = sheds,
                    choosable = choosableDevice, chosen = choosableDevice and chosen[device.key] == true,
                    fresh = view.fresh[device.key], groupText = groupText, groupColour = groupColour }, tooltip)
            end
        end
    end
    -- Rooms on more than one floor: a header per floor, lowest first, with its rooms under it; a floor folded shows
    -- the header alone (ISBUPanelWindow:floorFolded). Devices in no room and outside after the floors.
    local floorOf = {}
    for _, room in ipairs(self.rooms or {}) do floorOf[room.id] = room.level end
    local floors, levels = {}, {}
    for _, group in ipairs(order) do
        local level = group.id ~= OUTSIDE and floorOf[group.id] or nil
        if level ~= nil then
            if not floors[level] then
                floors[level] = { groups = {}, total = 0, on = 0, off = 0 }
                levels[#levels + 1] = level
            end
            local floor = floors[level]
            floor.groups[#floor.groups + 1] = group
            floor.total, floor.on, floor.off = floor.total + group.total, floor.on + group.on, floor.off + group.off
        end
    end
    if #levels < 2 then
        for _, group in ipairs(order) do
            if visible(group) then emit(group) end
        end
    else
        table.sort(levels)
        for _, level in ipairs(levels) do
            local floor, any = floors[level], false
            for _, group in ipairs(floor.groups) do any = any or visible(group) end
            if any then
                local foldKey = panel.id .. "|" .. utility .. "|floor|" .. level
                local folded = query == "" and not self.roomFilter and self:floorFolded(foldKey, level)
                local right = utility == "power" and load2(floor.total) or (floor.on .. " / " .. (floor.on + floor.off))
                add({ kind = "floor", level = level, text = BU.floorName(level), right = right, folded = folded, foldKey = foldKey },
                    getText(folded and "IGUI_BU_FloorRowOpen" or "IGUI_BU_FloorRowFold"))
                if not folded then
                    for _, group in ipairs(floor.groups) do
                        if visible(group) then emit(group) end
                    end
                end
            end
        end
        for _, group in ipairs(order) do
            if floorOf[group.id] == nil and visible(group) then emit(group) end
        end
    end
    list:setYScroll(scroll)
end

-- Whether a floor's header in the list is folded: as the player left it (PanelWindow.folded), else open only for the
-- floor the plan shows (the box's before it shows one), so a tall zone lists one floor at a time.
function ISBUPanelWindow:floorFolded(foldKey, level)
    local chosen = PanelWindow.folded[foldKey]
    if chosen ~= nil then return chosen end
    local shown = self.plan and self.plan.floor
    if shown == nil then shown = self.panel.z end
    return level ~= shown
end

-- The plan shows another floor: the list opens its floor's rooms (where the player has not folded it).
function ISBUPanelWindow:planFloorChanged(level)
    if self.views[self:activeUtility()] then self:refill(self:activeUtility()) end
end

-- What happened to the box, newest first, with how long ago.
local BAD = { IGUI_BU_Notice_Tripped = true, IGUI_BU_Notice_PowerLost = true, IGUI_BU_Notice_WaterEmpty = true,
    IGUI_BU_Notice_WaterEmptyGroup = true, IGUI_BU_Notice_LowFuel = true, IGUI_BU_Notice_Shed = true,
    IGUI_BU_Notice_Frozen = true, IGUI_BU_Notice_FilterSpent = true }
local GOOD = { IGUI_BU_Log_Reset = true, IGUI_BU_Log_Restored = true, IGUI_BU_Log_Upgraded = true,
    IGUI_BU_Notice_Thawed = true, IGUI_BU_Notice_SwitchedOn = true }

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
    local hours = {}
    for _, hour in ipairs(self.panel.energyLog or {}) do hours[#hours + 1] = hour end
    local now = self.panel.energyNow
    if now and now.n > 0 then hours[#hours + 1] = { made = now.made / now.n, used = now.used / now.n, charge = now.charge } end
    if #hours > 0 then list:addItem("", { kind = "graph", hours = hours }) end
    -- What the box has done for the player: how long its solar side carried the load, how long since power was cut.
    local stats = self.panel.stats
    if stats then
        local worldNow = getGameTime():getWorldAgeHours()
        if (stats.carried or 0) > 0 then
            local text = getText("IGUI_BU_StatsCarried", Ui.duration(stats.carried))
            if (stats.saved or 0) >= 0.1 then text = text .. "  " .. getText("IGUI_BU_StatsSaved", string.format("%.1f", stats.saved)) end
            list:addItem("", { kind = "note", text = text })
        end
        list:addItem("", { kind = "note", text = getText("IGUI_BU_StatsNoOutage", Ui.duration(worldNow - (stats.outage or stats.since))) })
    end
    if #log == 0 then list:addItem("", { kind = "note", text = getText("IGUI_BU_LogEmpty") }) end
    local worldHours = getGameTime():getWorldAgeHours()
    for index = #log, 1, -1 do
        local entry = log[index]
        local text = BU.noticeText(entry.key, entry.args)
        list:addItem(text, { kind = "log", text = text, right = ago(math.max(0, worldHours - (entry.hour or worldHours))),
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
        local cost, reason = Actions.outsideCost(panel, utility, device)
        if not cost or not Costs.affords(playerObj, cost) then
            HaloTextHelper.addBadText(playerObj, cost and getText("IGUI_BU_Reason_cantAfford") or getText("IGUI_BU_Reason_" .. reason))
            return
        end
        BU.ContextMenu.queueAt(playerObj, entry.x, entry.y, entry.z,
            ISBUConnect:new(playerObj, "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite))
    end
end

-- A click on a row: free changes as commands; lines laid or taken away by walking there.
function ISBUPanelWindow:onRow(utility, row, x, width)
    local panel, playerObj = self.panel, self.playerObj
    if row.kind == "source" then
        for _, button in ipairs(Ui.sourceButtons(width, row)) do
            if x >= button.x and x <= button.x + button.w then
                if button.name == "Settings" then
                    self:controllerMenu()
                elseif row.useSourceReady then
                    Sync.send(playerObj, "useSource", { panel = panel.id })
                else
                    HaloTextHelper.addBadText(playerObj, row.useSourceReason)
                end
            end
        end
    elseif row.kind == "producer" and row.unit then
        self:onWaterUnitRow(row, x, width)
    elseif row.kind == "producer" then
        for _, button in ipairs(Ui.producerButtons(width, row)) do
            if x >= button.x and x <= button.x + button.w then
                if button.name == "Remove" then
                    BU.ContextMenu.queueAt(playerObj, row.at.x, row.at.y, row.at.z,
                        ISBUDisconnect:new(playerObj, "producer", panel, utility, row.at.x, row.at.y, row.at.z))
                elseif button.name == "Group" then
                    self:producerGroupMenu(row)
                else
                    Sync.send(playerObj, "moveProducer", { panel = panel.id, utility = utility, index = row.index,
                        delta = button.name == "Up" and -1 or 1 })
                end
            end
        end
    elseif row.kind == "waterGroup" or row.kind == "addGroup" then
        self:onGroupRow(row, x, width)
    elseif row.kind == "link" then
        local target = Store.get(row.target)
        if target then self:switchTo(target) end
    elseif row.kind == "all" then
        Sync.send(playerObj, "setAllInside", { panel = panel.id, utility = utility, on = row.state ~= "on" })
    elseif row.kind == "blackout" then
        Sync.send(playerObj, "setBlackout", { panel = panel.id, on = row.state ~= "on" })
    elseif row.kind == "mainSwitch" then
        BU.ContextMenu.queueAt(playerObj, panel.x, panel.y, panel.z, ISBUMainSwitch:new(playerObj, panel, row.state == "on"))
    elseif row.kind == "filter" then
        self:filterRoom(nil)
    elseif row.kind == "batch" then
        for index, name in ipairs(BATCH_BUTTONS) do
            local bx = batchButtonX(width, index)
            if x >= bx and x <= bx + BATCH_W then
                if name == "Connect" then self:connectChosen(utility) else self:chooseAll(utility, name == "All") end
            end
        end
    elseif row.kind == "floor" then
        PanelWindow.folded[row.foldKey] = not row.folded
        -- Unfolded, the plan shows that floor (which fills the list again, planFloorChanged); else the list alone.
        if row.folded and self.plan and self.plan.floor ~= row.level then self.plan:showFloor(row.level)
        else self:refill(utility) end
    elseif row.kind == "room" and row.choosable and x >= chooseButtonX(row) and x <= chooseButtonX(row) + CHOOSE_W then
        self:setChoosing(utility, not row.choosing)
    elseif row.kind == "room" then
        if row.state and x >= ROOM_TICK_X and x <= ROOM_TICK_X + ROW then
            Sync.send(playerObj, "setRoomInside", { panel = panel.id, utility = utility, room = row.id, on = row.state ~= "on" })
        else
            PanelWindow.folded[row.foldKey] = (not row.folded) or nil
            self:refill(utility)
        end
    elseif row.kind == "device" and row.choosable then
        self:toggleChosen(row.device.key)
    elseif row.kind == "device" and row.state ~= "other" then
        local device = row.device
        for _, button in ipairs((deviceButtons(width, row))) do
            if x >= button.x and x <= button.x + button.w then
                if button.name == "group" then
                    self:deviceGroupMenu(device)
                elseif button.name == "timer" then
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
        local cost = Costs.link(candidate.wire)
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

-- How far from the box it was opened at, in tiles (a floor up or down counting as TILES_PER_FLOOR), a window stays open.
PanelWindow.CLOSE_RANGE, PanelWindow.TILES_PER_FLOOR = 12, 3

-- A box's window, opened at a box (anchor, { x, y, z }: the panel's own when not given).
function PanelWindow.open(playerObj, panel, anchor)
    local window = open[panel.id]
    if window then
        if anchor or not window.anchor then window.anchor = anchor or { x = panel.x, y = panel.y, z = panel.z } end
        window:bringToTop()
        window:refresh()
        return window
    end
    window = ISBUPanelWindow:new(0, 0, playerObj, panel, anchor)
    window:setX(math.max(0, (getCore():getScreenWidth() - window.width) / 2))
    window:setY(math.max(0, (getCore():getScreenHeight() - window.height) / 2))
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    open[panel.id] = window
    return window
end

function PanelWindow.isOpen(panelId) return open[panelId] ~= nil end

-- The window open for a panel, or nil.
function PanelWindow.get(panelId) return open[panelId] end

-- The data changed: every window refreshes once that settles, as a box's change can show in another's window too
-- (its name, a device connected to it, a sub-panel's supply).
function PanelWindow.refreshAll()
    for _, window in pairs(open) do window:changed() end
end

-- The API says a network changed: its panel's window, and its main panel's, show it.
function PanelWindow.onNetworkChange(id)
    local panel = Networks.owner(id)
    if not panel then return end
    if open[panel.id] then open[panel.id]:changed() end
    if panel.parent and open[panel.parent] then open[panel.parent]:changed() end
end

-- What the windows marked as seen, forgotten for the boxes that are gone: an id is never given again.
function PanelWindow.forgetRemoved()
    local store = ModData.getOrCreate(SEEN)
    local gone = {}
    for key in pairs(store) do
        local id = tostring(key):match("^(.-)|")
        if not (id and Store.get(id)) then gone[#gone + 1] = key end
    end
    for _, key in ipairs(gone) do store[key] = nil end
end

-- Opening a box's window: the player walks to the box first (BU.ContextMenu.queueAt), as to a generator's info.
ISBUOpenPanel = ISBaseTimedAction:derive("ISBUOpenPanel")

function ISBUOpenPanel:isValid() return Store.get(self.panelId) ~= nil end

function ISBUOpenPanel:perform()
    local panel = Store.get(self.panelId)
    if panel then PanelWindow.open(self.character, panel, { x = panel.x, y = panel.y, z = panel.z }) end
    ISBaseTimedAction.perform(self)
end

function ISBUOpenPanel:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId = panel.id
    o.maxTime = 0
    return o
end

return PanelWindow
