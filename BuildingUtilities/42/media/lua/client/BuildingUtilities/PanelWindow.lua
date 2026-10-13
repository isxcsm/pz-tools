-- The breaker box window: its name and tier as its title (its rename button at the title bar's end), a row with the
-- upgrade button and a banner when the breaker is down (only while it has either), then a tab per utility with its
-- producers (each generator running, on standby or out of service) and its devices room by room, a tab with the
-- batteries of its racks, from BU.LOG_TIER a tab with what happened to the box, and the manual (BuildingUtilities/
-- PanelManual). Under the tabs the open one's head: its utility's status
-- line (BuildingUtilities/PanelStatus; the batteries' is power's, the log has none) and, on the power tab, the load
-- against the limit with the lever and the breaker's gauge beside it. Beside them the floor plan
-- (BuildingUtilities/PanelPlan). A row under the mouse outlines its objects in the world, marks them on the plan and
-- tells what switching it would do to the load. Free changes, the lever among them, go to the server as commands;
-- lines are laid and taken away by the player at the place, as timed actions: a device outside is wired at itself
-- (its world menu), and listed here once it is. The search box keeps the rows whose device or room has the words; the
-- view options sit on the list's first header; devices new since the window was last closed are marked. The load bar
-- tells what makes the load. Below BU.CUT_TIER the rows have no ticks: everything the box reaches is supplied. The
-- window fades in and out (the kit's UI.fadeIn, UI.fadeOut) and is the player's at the box they opened it at (its anchor; a window
-- opened from another's row keeps that one's): it closes once they are far from it (PanelWindow.CLOSE_RANGE), die
-- or another character takes their place.
require "TimedActions/ISBaseTimedAction"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISPanel"
require "PZUIKit/Prompt"
require "ISUI/ISTextEntryBox"
require "PZUIKit/UI"
require "PZUIKit/Button"
require "PZUIKit/RichText"
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/PanelPlan"
require "BuildingUtilities/PanelList"
require "BuildingUtilities/PanelManual"
require "BuildingUtilities/LineOverlay"
local BU = BuildingUtilities
local Store, Panels, Networks, Costs, Actions, Sync, Energy = BU.Store, BU.Panels, BU.Networks, BU.Costs, BU.Actions,
    BU.Sync, BU.Energy
local Units, Ui, Geometry, Links = BU.Units, BU.PanelUi, BU.Geometry, BU.Links
local MANUAL = Ui.MANUAL
local FONT_HGT_SMALL, ROW, PAD, REFRESH_MS, BAR_W, LOG, BATTERIES, LIST_W, MIN_LIST, MIN_PLAN, SEEN,
    ROOM_TICK_X, load2, percent, nextSchedule = Ui.FONT_HGT_SMALL, Ui.ROW,
    Ui.PAD, Ui.REFRESH_MS, Ui.BAR_W, Ui.LOG, Ui.BATTERIES, Ui.LIST_W, Ui.MIN_LIST, Ui.MIN_PLAN, Ui.SEEN,
    Ui.ROOM_TICK_X, Ui.load2, Ui.percent, Ui.nextSchedule
local deviceButtons = Ui.deviceButtons
local UI, P, ease, approach = Ui.UI, Ui.PALETTE, Ui.ease, Ui.approach

local PanelWindow = {}
BU.PanelWindow = PanelWindow
local open = {}
-- A change told (BU.onChanged, a notice, a network event) refreshes the window once it settles: one action often
-- tells it twice within a few frames.
local SETTLE_MS = 100
-- What the player chose, kept while the game runs: view options, folded rooms, the plan's share of the window and
-- its legend.
PanelWindow.options = { activeOnly = false, byLoad = false, hideUnwired = false }
PanelWindow.folded = {}
-- The plan takes all it can at first (the list at its least, MIN_LIST); the divider moves it. The window is made as
-- wide as a list of LIST_W with the plan WINDOW_SHARE of it beside.
PanelWindow.planShare = 1
local WINDOW_SHARE = 0.42

-- The window.
ISBUPanelWindow = ISCollapsableWindow:derive("ISBUPanelWindow")

-- The window's width for a list so wide beside the plan (design units), and the least it may be.
local function windowWidth(listW) return math.floor(listW / (1 - WINDOW_SHARE)) + PAD end

local MINIMUM_W = MIN_LIST + PAD + MIN_PLAN

-- The most a window may take of the screen, in pixels.
local function screenRoom()
    local core = getCore()
    return math.floor(core:getScreenWidth() * Ui.SCREEN_SHARE), math.floor(core:getScreenHeight() * Ui.SCREEN_SHARE)
end

-- Whether a box shows the battery tab: a box with racks wired to it, while racks are on (BU.enabled).
local function batteriesShown(panel)
    return BU.enabled("rack") and #Store.unitList("rack", panel.id) > 0
end

-- Whether a box shows the log tab: from BU.LOG_TIER (it keeps its log before).
local function logShown(panel) return (panel.tier or 1) >= BU.LOG_TIER end

-- The window's tabs, as a key: the utilities that are on, the battery tab and the log.
local function viewsKey(panel)
    return table.concat(BU.utilities(), ",") .. (batteriesShown(panel) and ",batteries" or "")
        .. (logShown(panel) and ",log" or "")
end

-- A box's name with the floors its zone takes (Panels.zoneFloors): the boxes of a tall building tell apart.
function PanelWindow.boxTitle(panel)
    local name, low, high = Panels.name(panel), Panels.zoneFloors(panel)
    if low and low ~= high then return getText("IGUI_BU_SubPanelFloors", name, BU.floorName(low), BU.floorName(high)) end
    if low then return getText("IGUI_BU_SubPanelFloor", name, BU.floorName(low)) end
    return name
end

-- The window is the game's (in pixels) with the kit's bars and frame in the palette; everything in it stands on its
-- body (ISBUBody), in design units. The scale is worked out again as it opens (UI.refreshScale): a window made under
-- another opens anew (update).
function ISBUPanelWindow:new(x, y, playerObj, panel, anchor)
    UI.refreshScale()
    local maxW, maxH = screenRoom()
    local chrome = UI.titleBarHeight() + UI.resizeWidgetHeight()
    local minW = math.min(UI.px(MINIMUM_W), maxW)
    local width = math.max(minW, math.min(UI.px(windowWidth(LIST_W)), maxW))
    local height = math.max(math.min(UI.px(340) + chrome, maxH), math.min(UI.px(Ui.WINDOW_H) + chrome, maxH))
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    o.playerObj = playerObj
    o.panel = panel
    o.palette = P
    o.era = UI.era
    o.anchor = anchor or { x = panel.x, y = panel.y, z = panel.z }
    o.resizable = true
    o.minimumWidth = minW
    o.minimumHeight = math.min(UI.px(340) + chrome, maxH)
    o.rangeObjects = {}
    o.planOutlined = {}
    o.views = {}
    -- The networks' states the last refresh read, by utility; the tabs not shown since then, filled as they open.
    o.states, o.pending = {}, {}
    o:setTitle(getText("IGUI_BU_TierName", Panels.name(panel), panel.tier or 1))
    return o
end

-- The bars are as high as the kit's Small face (the game's would follow its own font).
function ISBUPanelWindow:titleBarHeight() return UI.titleBarHeight() end
function ISBUPanelWindow:resizeWidgetHeight() return UI.resizeWidgetHeight() end

-- A button of the kit on the body (design units), in the palette; its title set by `titled`, which widens it to fit.
local function button(window, x, y, width, height, onclick)
    local b = PZUIButton:new(x, y, width, height, "", P, window, onclick)
    b.leastWidth = width
    b:initialise()
    window.body:addChild(b)
    return b
end

local function titled(b, text)
    b:setTitle(text)
    local w = math.max(b.leastWidth or 0, UI.textWidth(text) + 16)
    if b:getWidth() ~= w then b:setWidth(w) end
end
PanelWindow.titled = titled

-- The body: the window's room under its title bar and over its resize bar, in design units. It draws the status line,
-- the load bar and the banner under its parts (prerender) and the search's hint and a tab's veil over them (render).
ISBUBody = ISPanel:derive("ISBUBody")

function ISBUBody:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = false
    return o
end

function ISBUBody:prerender() self.window:drawBody(self) end
function ISBUBody:render() self.window:drawBodyOver(self) end

UI.scaled(ISBUBody, ISPanel)

-- A place on the body that shows a tooltip of rich text under the mouse (the kit's, PZUIRichTip): over the status
-- line and over the load bar.
ISBUTipArea = ISPanel:derive("ISBUTipArea")

function ISBUTipArea:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.background = false
    return o
end

function ISBUTipArea:setTooltip(text) self.tip = text end

function ISBUTipArea:prerender()
    if self.tip and self:isMouseOver() then PZUIRichTip.show(self, self.tip, P) else PZUIRichTip.hide(self) end
end

UI.scaled(ISBUTipArea, ISPanel)

-- The top's sizes (design units): its card's height (the load's big percent, its bar and its text), the bar's height
-- and what it shows at most (BAR_MOST of the limit; more stays at its end), the card's inner margin, the lever's width
-- and the breaker's gauge's.
PanelWindow.LOAD_H, PanelWindow.BAR_H, PanelWindow.BAR_MOST, PanelWindow.CARD_PAD = 40, 8, 1.5, 10
PanelWindow.LEVER_W, PanelWindow.GAUGE_W = 22, 4
-- The gauge turns red once the breaker has used up this share of what it holds.
PanelWindow.GAUGE_RED = 0.5
-- The water card's level line at the lever's place: its width (an hour a column of Store.ENERGY_HOURS).
PanelWindow.SPARK_W = 96
-- The space around the parts of a tab's head (the status line, the card).
PanelWindow.HEAD_GAP = 6

-- The box's lever (Changes.setLever): up while its breaker holds and its main switch is on. Drawn as a breaker's
-- toggle: a dark housing with a slot, the handle with its grip sliding along it (LEVER_MS) and a strip on it in the
-- state's colour (green up and live, amber up without supply, red tripped, grey pulled down). Clicked, it is
-- thrown at once (as a device's tick in the window); its tooltip says which way.
ISBULever = ISBUTipArea:derive("ISBULever")
ISBULever.LEVER_MS = 140

function ISBULever:new(x, y, window)
    local o = ISBUTipArea.new(self, x, y, PanelWindow.LEVER_W, PanelWindow.LOAD_H - 10)
    o.window = window
    return o
end

-- Redrawn frame by frame while the handle slides.
local function leverFrame(lever, now)
    if lever.pos == nil or lever.pos == lever.target then return nil end
    return math.floor(now / 16)
end

function ISBULever:prerender()
    ISBUTipArea.prerender(self)
    local window = self.window
    local panel = window.panel
    local w, h = self.width, self.height
    local up = Panels.leverUp(panel)
    local over = self:isMouseOver()
    -- the handle's place, 0 up to 1 down, sliding to where the lever is
    local now = getTimestampMs()
    local target = up and 0 or 1
    self.target = target
    local pos = self.pos or target
    if pos ~= target then
        local step = math.min(100, now - (self.movedAt or now)) / ISBULever.LEVER_MS
        pos = pos < target and math.min(target, pos + step) or math.max(target, pos - step)
        UI.live(self, leverFrame)
    end
    self.pos, self.movedAt = pos, now
    -- the housing and its slot
    UI.fill(self, 0, 0, w, h, P.bg)
    UI.frame(self, 0, 0, w, h, over and P.value or P.border)
    local slotX = math.floor((w - 4) / 2)
    UI.fill(self, slotX, 4, 4, h - 8, P.inset)
    -- the handle: light, its top lit and its foot shaded, two grip lines and the state's strip
    local handleH = 11
    local handleY = math.floor(2 + (h - 4 - handleH) * ease(pos) + 0.5)
    local hx, hw = 3, w - 6
    UI.fill(self, hx, handleY, hw, handleH, P.text, over and 1 or 0.92)
    UI.fill(self, hx, handleY, hw, 1, P.bright, 0.6)
    UI.fill(self, hx, handleY + handleH - 1, hw, 1, P.inset, 0.6)
    local strip = P.off
    if panel.tripped then strip = P.bad
    elseif up then strip = window.live and P.good or P.warn end
    local stripY = up and handleY + handleH - 4 or handleY + 2
    UI.fill(self, hx + 2, stripY, hw - 4, 2, strip)
    local gripY = up and handleY + 2 or handleY + handleH - 5
    UI.fill(self, hx + 3, gripY, hw - 6, 1, P.inset, 0.5)
    UI.fill(self, hx + 3, gripY + 2, hw - 6, 1, P.inset, 0.5)
end

function ISBULever:onMouseUp()
    self.window:onLever()
    return true
end

function ISBUPanelWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    -- Only the close box stays of the game's title bar, drawn in the palette and the kit's face.
    for _, b in ipairs({ self.pinButton, self.collapseButton, self.infoButton }) do
        if b then b:setVisible(false) end
    end
    UI.closeBox(self, P)
    -- The box's name is changed from a small button at the title bar's right end, not a row of its own.
    local titleH = UI.dp(self:titleBarHeight())
    local renameText = getText("IGUI_BU_Rename")
    local renameW = UI.textWidth(renameText) + 16
    self.renameButton = PZUIButton:new(UI.dp(self.width) - renameW - 3, 2, renameW, titleH - 4, renameText, P, self,
        ISBUPanelWindow.onRename)
    self.renameButton:initialise()
    self.renameButton:setAnchorLeft(false)
    self.renameButton:setAnchorRight(true)
    self:addChild(self.renameButton)
    local th, rh = self:titleBarHeight(), self:resizeWidgetHeight()
    local body = ISBUBody:new(0, UI.dp(th), UI.dp(self.width), UI.dp(self.height - th - rh), self)
    body:initialise()
    body:instantiate()
    body:setAnchorRight(true)
    body:setAnchorBottom(true)
    self:addChild(body)
    self.body = body
    local bw = body:getWidth()
    local top = PAD
    -- A row while it has something: the upgrade button and the banner beside it (placeRows); the tabs at the top
    -- without it. The open tab's head under the tabs (placeHead).
    self.statusY, self.loadY = top, top
    self.actionY = top
    self.upgradeButton = button(self, PAD, self.actionY, 160, ROW, ISBUPanelWindow.onUpgrade)
    local tabsY = self.actionY + ROW + PAD
    local listW = bw
    local height = body:getHeight() - tabsY
    -- The list and the plan are placed by layoutPanes, not by anchors: across, only their heights follow the window.
    self.tabsY = tabsY
    self.tabs = ISBUTabs:new(0, tabsY, listW, height)
    self.tabs:initialise()
    self.tabs:setAnchorBottom(true)
    body:addChild(self.tabs)
    self.lists = {}
    -- A tab for each utility that is on (BU.enabled), the batteries' (batteriesShown) and the log (logShown); the window
    -- opens anew when that changes (refresh).
    self.utilities = BU.utilities()
    self.utilitiesKey = viewsKey(self.panel)
    local views = {}
    for _, utility in ipairs(self.utilities) do views[#views + 1] = utility end
    if batteriesShown(self.panel) then views[#views + 1] = BATTERIES end
    if logShown(self.panel) then views[#views + 1] = LOG end
    for _, view in ipairs(views) do
        local list = ISBUPanelList:new(0, 0, listW, height - self.tabs.tabHeight, self, view)
        list:initialise()
        list:setAnchorBottom(true)
        self.tabs:addView(getText("IGUI_BU_Tab_" .. view), list)
        UI.rowHeight(list, ROW)
        self.lists[view] = list
    end
    -- The manual last, with something in it whatever is on.
    self.manual = ISBUManual:new(0, 0, listW, height - self.tabs.tabHeight, self)
    self.manual:initialise()
    self.manual:instantiate()
    self.manual:setAnchorBottom(true)
    self.tabs:addView(getText("IGUI_BU_Tab_" .. MANUAL), self.manual)
    -- The search, from the tabs to the strip's end: the game's entry box (placed from design units), in the palette.
    self.search = ISTextEntryBox:new("", 0, 0, 100, 20)
    self.search:initialise()
    self.search:instantiate()
    self.search:setClearButton(true)
    self.search.onTextChangeFunction = ISBUPanelWindow.onSearch
    self.search.target = self
    self.search.backgroundColor = { r = P.inset[1], g = P.inset[2], b = P.inset[3], a = 1 }
    self.search.borderColor = { r = P.border[1], g = P.border[2], b = P.border[3], a = 1 }
    body:addChild(self.search)
    UI.place(self.search, 0, tabsY + 3, 100, self.tabs.tabHeight - 6)
    self.searchHint = getText("IGUI_BU_Search")
    -- Over the status line: both utilities in full, as a tooltip.
    self.statusArea = ISBUTipArea:new(PAD, self.statusY, bw - PAD * 2, FONT_HGT_SMALL)
    self.statusArea:initialise()
    body:addChild(self.statusArea)
    -- Over the load's percent, bar and text: what makes the load, as a tooltip. Beside them the lever, and the
    -- breaker's gauge while it is not full (placed by placeLever).
    self.loadArea = ISBUTipArea:new(PAD, self.loadY, BAR_W, PanelWindow.LOAD_H)
    self.loadArea:initialise()
    body:addChild(self.loadArea)
    self.lever = ISBULever:new(PAD, self.loadY + 5, self)
    self.lever:initialise()
    body:addChild(self.lever)
    self.gauge = ISBUTipArea:new(PAD, self.loadY + 5, PanelWindow.GAUGE_W + 4, PanelWindow.LOAD_H - 10)
    self.gauge:initialise()
    body:addChild(self.gauge)
    -- On the water tab's card, where the lever is on the power tab: the tanks' level over the last hours.
    self.levelArea = ISBUTipArea:new(PAD, self.loadY + 5, PanelWindow.SPARK_W, PanelWindow.LOAD_H - 10)
    self.levelArea:initialise()
    self.levelArea:setTooltip(getText("IGUI_BU_LevelTitle", Store.ENERGY_HOURS))
    body:addChild(self.levelArea)
    -- Placed by placeOptions as the list's width changes: an anchor would move them again a frame later.
    self.splitter = ISBUSplitter:new(listW, PAD, PAD, body:getHeight() - PAD, self)
    self.splitter:initialise()
    self.splitter:setAnchorBottom(true)
    body:addChild(self.splitter)
    self.plan = ISBUPlan:new(listW, PAD, MIN_PLAN, body:getHeight() - PAD, self)
    self.plan:initialise()
    self.plan:setAnchorBottom(true)
    body:addChild(self.plan)
    self:layoutPanes()
    if PanelWindow.lastTab then self.tabs:activateView(PanelWindow.lastTab) end
    self:refresh()
end

-- The body's width (design units): the window's, which the body spans. Read off the window: the body follows a
-- width set in code only a frame later (its anchor), and the panes laid out meanwhile took the old one (seen in game:
-- the list as wide as before the window was widened).
function ISBUPanelWindow:bodyWidth() return UI.dp(self:getWidth()) end

-- The left column (the boxes' tabs, the status line, the load's card, the buttons, the list) and, beside it, the plan
-- from the body's top with its share of the window, each at least so wide, the divider between them (design units,
-- across the body).
function ISBUPanelWindow:layoutPanes()
    if not (self.tabs and self.plan) then return end
    local bw = self:bodyWidth()
    local planW = math.floor((bw - PAD) * PanelWindow.planShare)
    planW = math.max(MIN_PLAN, math.min(planW, bw - PAD - MIN_LIST))
    local listW = bw - PAD - planW
    self.plan:setX(listW + PAD)
    if self.plan:getWidth() ~= planW then self.plan:setWidth(planW) end
    self.listW = listW
    self.splitter:setX(listW)
    self.statusArea:setWidth(listW - PAD * 2)
    if self.lever then self:placeLever(self.loadTextW or 0) end
    if self.tabs:getWidth() ~= listW then self.tabs:resize(listW, self.tabs:getHeight()) end
    self:placeOptions()
end

-- The window resized by the player: the panes share the new width.
function ISBUPanelWindow:onResize()
    if ISCollapsableWindow.onResize then ISCollapsableWindow.onResize(self) end
    self:layoutPanes()
end

-- The divider dragged: the plan's share of the window.
function ISBUPanelWindow:dragDivider(x)
    local bw = self:bodyWidth()
    local listW = math.max(MIN_LIST, math.min(x, bw - PAD - MIN_PLAN))
    PanelWindow.planShare = (bw - PAD - listW) / (bw - PAD)
    self:layoutPanes()
end

-- The row under the load's card: its buttons shown left to right and the banner after them to the list's end; the
-- tabs right under the card while the row has nothing (laid out again only when that changes).
function ISBUPanelWindow:placeRows()
    local x = PAD
    for _, shown in ipairs({ self.upgradeButton }) do
        if shown:getIsVisible() then
            shown:setX(x)
            x = x + shown:getWidth() + 6
        end
    end
    self.bannerX = x
    local row = self.banner ~= nil or x > PAD
    local tabsY = row and self.actionY + ROW + PAD or self.actionY
    if tabsY ~= self.tabsY then
        self.tabsY = tabsY
        self.tabs:setY(tabsY)
        self.tabs:resize(self.tabs:getWidth(), self.body:getHeight() - tabsY)
        self:placeOptions()
    end
    self:placeHead()
end

-- The open tab's head between the tabs and its list: its utility's status line (none on the log's) and its card: on
-- the power tab the load's with the lever and the breaker's gauge (power on), on the water tab the tanks' (water on,
-- measureWater). The list starts under it.
function ISBUPanelWindow:placeHead()
    local tabs = self.tabs
    if not (tabs and self.statusArea and self.tabsY) then return end
    local view = tabs.activeView and tabs.activeView.view
    local shown = view and view.utility
    local gap = PanelWindow.HEAD_GAP
    local status = shown ~= nil and shown ~= LOG and shown ~= MANUAL
    local card = shown == "power" and BU.enabled("power")
    local waterCard = shown == "water" and self.waterView ~= nil
    local top = self.tabsY + tabs.tabHeight
    local y = top + gap
    self.statusY, self.headStatus = y, status
    if status then y = y + FONT_HGT_SMALL + gap end
    self.loadY, self.headCard = y, card or waterCard
    self.headKind = card and "power" or waterCard and "water" or nil
    if card or waterCard then y = y + PanelWindow.LOAD_H + gap end
    self.statusArea:setY(self.statusY)
    self.statusArea:setVisible(status)
    self.loadArea:setY(self.loadY)
    self.loadArea:setVisible(card and self.load ~= nil)
    self.lever:setY(self.loadY + 5)
    self.lever:setVisible(card)
    self.gauge:setY(self.loadY + 5)
    self.gauge:setVisible(card and self.gaugeShown == true)
    self.levelArea:setY(self.loadY + 5)
    self.levelArea:setVisible(waterCard and self.waterView.spark ~= nil)
    tabs:setHead((status or card or waterCard) and y - top or 0)
end

-- The search between the tabs and the strip's end, while there is room for it.
function ISBUPanelWindow:placeOptions()
    if not self.search then return end
    local x = self.tabs:getX() + self.tabs:getWidthOfAllTabs() + PAD
    local w = self.tabs:getX() + self.tabs:getWidth() - PAD - x
    UI.place(self.search, x, self.tabsY + 3, math.max(10, w), self.tabs.tabHeight - 6)
    self.search:setVisible(w >= 60)
end

-- The view options, on the list's first header (PanelList's optionButtons).
function ISBUPanelWindow:onActiveOnly()
    PanelWindow.options.activeOnly = not PanelWindow.options.activeOnly
    self:redraw()
end

function ISBUPanelWindow:onByLoad()
    PanelWindow.options.byLoad = not PanelWindow.options.byLoad
    self:redraw()
end

-- What is in reach and not connected (devices outside without their line, producers no box has) hidden or shown, in
-- the list and on the plan.
function ISBUPanelWindow:onHideUnwired()
    PanelWindow.options.hideUnwired = not PanelWindow.options.hideUnwired
    self:redraw()
end

-- The utility the list shows now: the plan follows it (the first tab's while the log or the batteries are shown; nil
-- with both off).
function ISBUPanelWindow:activeUtility()
    local view = self.tabs and self.tabs.activeView and self.tabs.activeView.view
    local utility = view and view.utility
    if utility == nil or utility == LOG or utility == BATTERIES or utility == MANUAL then
        return self.utilities and self.utilities[1]
    end
    return utility
end

-- A tab opened: its content comes up out of the background over REVEAL_MS (a veil thinning out below a faint line
-- that runs down it once, as Operation Acorn's terminal does), and slides in from that side (ISBUPanelList:switched).
-- The load bar's fill glides to the load (LOAD_TAU), and the banner of a tripped breaker breathes; each followed frame
-- by frame only while it moves (the kit's UI.live).
ISBUPanelWindow.REVEAL_MS, ISBUPanelWindow.LOAD_TAU = 300, 90

local function bodyFrame(body, now)
    local window = body.window
    local moving = false
    if window.revealAt and now - window.revealAt < ISBUPanelWindow.REVEAL_MS then moving = true end
    if window.load and math.abs((window.loadShown or 0) - window:loadShare()) > 0.002 then moving = true end
    if moving then return math.floor(now / 16) end
    -- A breathing banner alone is slow: redrawn some 15 times a second, not each frame, for as long as it is tripped.
    local banner = window.banner
    if banner and banner.pulse then return math.floor(now / 66) end
    return nil
end

function ISBUPanelWindow:prerender()
    -- The window's own drawing, in the palette: the background, the title bar with the title in the kit's face.
    local th = self:titleBarHeight()
    UI.fill(self, 0, 0, self.width, self.height, P.bg, P.bgAlpha)
    UI.fill(self, 0, 0, self.width, th, P.title)
    UI.fill(self, 0, th - 1, self.width, 1, P.border)
    UI.windowTitle(self, self.title, P.text)
    if self.tabs and self.tabs.activeView then
        PanelWindow.lastTab = self.tabs.activeView.name
        -- A tab opened: its list slides in from that side, and comes up out of the background.
        local index = self.tabs:getActiveViewIndex()
        if self.shownTab and index ~= self.shownTab then
            local view = self.tabs.activeView.view
            if view.switched then view:switched(index > self.shownTab and 1 or -1) end
            self:placeHead()
            self.revealAt = getTimestampMs()
            UI.live(self.body, bodyFrame)
        end
        self.shownTab = index
    end
    -- A tab opened that the last refresh left: its rows, before the plan shows its devices.
    if self.pending[self:activeUtility()] then self:refill(self:activeUtility()) end
    if self.plan and self.planUtility ~= self:activeUtility() then self:updatePlan() end
    if self.statusUtility ~= self:activeUtility() then self:updateStatus() end
    -- The range is outlined a slice a frame: here, as update runs only a few times a second.
    if self.rangeJob then self:stepRange() end
end

-- The resize bar's grip and the frame, in the palette.
function ISBUPanelWindow:render()
    local rh = self:resizeWidgetHeight()
    local w, h = self.width, self.height
    UI.fill(self, 0, h - rh, w, 1, P.border, 0.6)
    for i = 0, 2 do
        for j = 0, i do UI.fill(self, w - 5 - 4 * j, h - rh + 3 + 4 * (2 - i), 2, 2, P.dim) end
    end
    UI.frame(self, 0, 0, w, h, P.border)
end

-- The load against the box's limit, for the top (drawBody): the load, the box's own share and what its bank adds (Panels.limit), whether the power is live (the lever up and the
-- network supplied; else the percent is 0 and the text tells what is switched on), the colour of its state (green
-- within the box's share, blue drawing on the bank, red over the limit), the text under the bar in parts, the
-- breaker's gauge (shown while it is not full) and the tooltips of the lever and the gauge.
function ISBUPanelWindow:measureLoad(panel, power)
    self.capacity = Panels.capacity(panel)
    local bank = Energy.bank(panel)
    self.boost = Energy.boost(panel, bank)
    self.limit = self.capacity + self.boost
    self.load = nil
    self.gaugeShown = false
    self.spareText = nil
    self.lever:setTooltip(getText(panel.tripped and "IGUI_BU_LeverTripTip"
        or Panels.leverUp(panel) and "IGUI_BU_LeverUpTip"
        or "IGUI_BU_LeverDownTip"))
    if not (power and power.load) then
        self:placeLever(0)
        self:placeHead()
        return
    end
    self.load = math.max(0, power.load)
    self.live = Panels.leverUp(panel) and power.supplied == true
    local ratio = self.live and self.load / math.max(self.limit, 1e-6) or 0
    self.ratio = ratio
    local colour = P.good
    if not self.live then colour = P.dim
    elseif ratio > 1 + 1e-6 then colour = P.bad
    elseif self.load > self.capacity + 1e-6 then colour = P.value end
    self.loadColour = colour
    self.percentText = tostring(math.min(999, math.floor(ratio * 100 + 0.5)))
    local parts = { { getText(self.live and "IGUI_BU_Load" or "IGUI_BU_LoadIdle", load2(self.load), load2(self.limit)), P.text } }
    if bank then
        parts[#parts + 1] = { " = ", P.dim }
        parts[#parts + 1] = { load2(self.capacity), P.good }
        parts[#parts + 1] = { " + ", P.dim }
        parts[#parts + 1] = { self.boost > 0 and load2(self.boost) or "0", self.boost > 0 and P.value or P.dim }
    end
    local width = 0
    for _, part in ipairs(parts) do
        part.x = width
        width = width + UI.textWidth(part[1])
    end
    self.loadParts = parts
    -- The breaker's gauge: while it drains, how long it holds as now; while it fills, that it cools.
    local gauge = Panels.breaker(panel)
    self.gaugeValue = gauge
    self.gaugeShown = BU.overloadEnabled() and gauge < 1
    local tip = getText("IGUI_BU_BreakerCooling")
    local hours = self.live and Panels.breakerHoursLeft(gauge, ratio)
    if hours then tip = getText("IGUI_BU_BreakerHolds", Ui.shortDuration(hours)) end
    self.gauge:setTooltip(tip)
    -- under the bar's end: what the limit leaves, or how far the load is over it
    if self.live then
        local spare = self.limit - self.load
        self.spareText = getText(spare >= 0 and "IGUI_BU_LoadSpare" or "IGUI_BU_LoadOver", load2(math.abs(spare)))
        self.spareColour = spare >= 0 and P.dim or P.bad
        self.spareW = UI.textWidth(self.spareText)
    end
    self:placeLever(width)
    self:placeHead()
end

-- The top's card: across the left column, its parts inside it: the percent and the bar with its text from the left,
-- the lever at its right end and the breaker's gauge beside the lever; the bar reaches to the gauge's place (at least
-- BAR_W); the area of the load's tooltip over the left part. Placed again as the left column's width changes
-- (layoutPanes).
function ISBUPanelWindow:placeLever(textW)
    self.loadTextW = textW
    local bigW = UI.textWidth("000", UIFont.Large) + UI.textWidth("%") + 4
    self.bigW = bigW
    local inner = PanelWindow.CARD_PAD
    local cardW = math.max((self.listW or self:bodyWidth()) - PAD * 2, inner * 3 + bigW + BAR_W + PanelWindow.LEVER_W)
    self.cardW = cardW
    local leverX = PAD + cardW - inner - PanelWindow.LEVER_W
    local gaugeX = leverX - 6 - PanelWindow.GAUGE_W - 4
    self.lever:setX(leverX)
    self.gauge:setX(gaugeX)
    self.barW = math.max(BAR_W, gaugeX - 10 - (PAD + inner + bigW + 8))
    self.loadArea:setWidth(inner + bigW + 8 + math.max(self.barW, textW))
    local levelX = PAD + cardW - inner - PanelWindow.SPARK_W
    self.levelArea:setX(levelX)
    self.waterBarW = math.max(BAR_W, levelX - 12 - (PAD + inner + bigW + 8))
end

-- The water tab's card, for the top (drawWaterCard): what the tanks hold of their capacity (the percent, large), the
-- bar of each pipe's water in its colour (with more than one pipe), under it the litres and the change over the last
-- day, and at the right the level over the last hours (the pipes' logs together, Store.recordWater). Nil while water
-- is off.
local DAY = 24
function ISBUPanelWindow:measureWater(panel, state)
    self.waterView = nil
    if not state then
        self:placeHead()
        return
    end
    local amount, capacity = state.amount or 0, state.capacity or 0
    local view = { amount = amount, capacity = capacity, segments = {} }
    view.ratio = capacity > 0 and math.min(1, amount / capacity) or 0
    view.percentText = capacity > 0 and tostring(math.floor(view.ratio * 100 + 0.5)) or "-"
    view.colour = capacity > 0 and P.water or P.dim
    view.text = getText("IGUI_BU_Left_Water", string.format("%.0f", amount), string.format("%.0f", capacity))
    local logs = panel.water.levelLog or {}
    local hours = {}
    local shown = BU.Water.shown(panel)
    for _, pipe in ipairs(BU.Water.pipes(panel)) do
        local each = state.pipes and state.pipes[pipe.id]
        if each and (each.amount or 0) > 0 and capacity > 0 then
            view.segments[#view.segments + 1] = { share = each.amount / capacity,
                colour = shown and BU.Water.colour(pipe.id) or P.water }
        end
        for _, hour in ipairs(logs[pipe.id] or {}) do
            local total = hours[hour.hour] or { amount = 0, capacity = 0 }
            hours[hour.hour] = total
            total.amount = total.amount + (hour.amount or 0)
            total.capacity = total.capacity + (hour.capacity or 0)
        end
    end
    local now = math.floor(getGameTime():getWorldAgeHours())
    local spark, points = {}, 0
    for column = 1, Store.ENERGY_HOURS do
        local total = hours[now - Store.ENERGY_HOURS + column]
        if total and total.capacity > 0 then
            spark[column] = math.min(1, total.amount / total.capacity)
            points = points + 1
        end
    end
    if points > 1 then view.spark = spark end
    -- the change since the first hour kept of the last day
    for back = DAY, 1, -1 do
        local then_ = hours[now - back]
        if then_ then
            local change = amount - then_.amount
            local litres = string.format("%.0f", math.abs(change))
            view.changeText = getText("IGUI_BU_WaterChange", (change < 0 and "-" or "+") .. litres)
            view.changeColour = litres == "0" and P.dim or change < 0 and P.warn or P.good
            view.changeW = UI.textWidth(view.changeText)
            break
        end
    end
    view.textW = UI.textWidth(view.text)
    self.waterView = view
    self:placeHead()
end

function ISBUPanelWindow:drawWaterCard(body)
    local view = self.waterView
    if not (view and self.cardW) then return end
    local top, inner = self.loadY, PanelWindow.CARD_PAD
    local bigY = top + math.floor((PanelWindow.LOAD_H - UI.fontHeight(UIFont.Large)) / 2)
    local right = PAD + inner + self.bigW
    UI.textRight(body, "%", right, bigY + UI.baselineDrop(UIFont.Large, UIFont.Small), view.colour)
    UI.textRight(body, view.percentText, right - UI.textWidth("%") - 1, bigY, view.colour, UIFont.Large)
    local x = right + 8
    local barH = PanelWindow.BAR_H
    local barY = top + math.floor((PanelWindow.LOAD_H - barH - 3 - FONT_HGT_SMALL) / 2)
    local barW = self.waterBarW or BAR_W
    UI.fill(body, x, barY, barW, barH, P.inset)
    local filled = 0
    for _, segment in ipairs(view.segments) do
        local w = math.min(barW - filled, math.floor(barW * segment.share + 0.5))
        if w > 0 then
            UI.fill(body, x + filled, barY, w, barH, segment.colour, 0.9)
            filled = filled + w
        end
    end
    if filled > 0 then UI.fill(body, x, barY, filled, 1, P.bright, 0.25) end
    UI.frame(body, x, barY, barW, barH, P.border)
    local textY = barY + barH + 3
    UI.text(body, view.text, x, textY, P.text)
    if view.changeText and view.textW + 16 + view.changeW <= barW then
        UI.textRight(body, view.changeText, x + barW, textY, view.changeColour)
    end
    local spark = view.spark
    if spark then
        local area = self.levelArea
        local sx, sy, sw, sh = area:getX(), area:getY(), PanelWindow.SPARK_W, area:getHeight()
        UI.fill(body, sx, sy, sw, sh, P.inset)
        local columns = Store.ENERGY_HOURS
        local w = (sw - 2) / columns
        for column = 1, columns do
            local share = spark[column]
            if share then
                local h = math.max(1, math.floor(share * (sh - 2) + 0.5))
                UI.fill(body, sx + 1 + (column - 1) * w, sy + sh - 1 - h, math.max(1, w), h, P.water,
                    column == columns and 0.95 or 0.55)
            end
        end
        UI.frame(body, sx, sy, sw, sh, P.border)
    end
end

-- How much of the bar the load fills now (0 to 1: BAR_MOST of the limit fills it).
function ISBUPanelWindow:loadShare()
    return math.min(1, (self.ratio or 0) / PanelWindow.BAR_MOST)
end

-- Under the body's parts (design units): the status line with its dot, the load's big percent, its bar and text, the
-- breaker's gauge, the banner.
function ISBUPanelWindow:drawBody(body)
    local now = getTimestampMs()
    local ms = math.min(100, now - (self.bodyFrameAt or now))
    self.bodyFrameAt = now
    local status = self.headStatus and self.status
    if status then
        local c, dot = status.colour, FONT_HGT_SMALL - 6
        UI.fill(body, PAD, self.statusY + 3, dot, dot, c)
        UI.text(body, status.text, status.textX, self.statusY, c)
        if status.reason and status.reasonEnd <= (self.listW or body.width) - PAD then
            UI.text(body, status.reason, status.reasonX, self.statusY, P.dim)
        end
    end
    -- the top's card, with the lever on it (also while the network has no state yet)
    if self.cardW and self.headCard then
        UI.fill(body, PAD, self.loadY, self.cardW, PanelWindow.LOAD_H, P.panel)
        UI.frame(body, PAD, self.loadY, self.cardW, PanelWindow.LOAD_H, P.border)
    end
    if self.headKind == "water" then self:drawWaterCard(body) end
    if self.load and self.headKind == "power" then
        local top, colour, inner = self.loadY, self.loadColour, PanelWindow.CARD_PAD
        -- the percent, large, its sign small on its baseline, both at the right of their room
        local bigY = top + math.floor((PanelWindow.LOAD_H - UI.fontHeight(UIFont.Large)) / 2)
        local right = PAD + inner + self.bigW
        UI.textRight(body, "%", right, bigY + UI.baselineDrop(UIFont.Large, UIFont.Small), colour)
        UI.textRight(body, self.percentText, right - UI.textWidth("%") - 1, bigY, colour, UIFont.Large)
        -- the bar: the load's share up to BAR_MOST of the limit, in the state's colour, the limit marked; under it the
        -- limit's parts, the box's own and its bank's, and what lies over the limit, faintly
        local x = right + 8
        local barH = PanelWindow.BAR_H
        local barY = top + math.floor((PanelWindow.LOAD_H - barH - 3 - FONT_HGT_SMALL) / 2)
        local target = self:loadShare()
        local shown = self.loadShown or target
        shown = math.abs(shown - target) > 0.002 and approach(shown, target, ms, ISBUPanelWindow.LOAD_TAU) or target
        self.loadShown = shown
        local barW = self.barW or BAR_W
        local filled = math.floor(barW * shown)
        local limitW = math.floor(barW / PanelWindow.BAR_MOST)
        local ownW = self.limit > 0 and math.floor(limitW * math.min(1, self.capacity / self.limit)) or limitW
        UI.fill(body, x, barY, barW, barH, P.inset)
        UI.fill(body, x, barY, ownW, barH, P.good, 0.12)
        if limitW > ownW then UI.fill(body, x + ownW, barY, limitW - ownW, barH, P.value, 0.12) end
        UI.fill(body, x + limitW, barY, barW - limitW, barH, P.bad, 0.08)
        if filled > 0 then
            UI.fill(body, x, barY, filled, barH, colour, 0.9)
            UI.fill(body, x, barY, filled, 1, P.bright, 0.25)
        end
        UI.frame(body, x, barY, barW, barH, P.border)
        UI.fill(body, x + limitW, barY - 2, 1, barH + 4, P.bright, 0.85)
        -- the load and the limit, and what the limit is made of; what is left of it at the bar's end
        local textY = barY + barH + 3
        for _, part in ipairs(self.loadParts) do UI.text(body, part[1], x + part.x, textY, part[2]) end
        if self.spareText and (self.loadTextW or 0) + 16 + self.spareW <= barW then
            UI.textRight(body, self.spareText, x + barW, textY, self.spareColour)
        end
        -- the breaker's gauge, filled from below: amber while it holds, red near the trip, dimmer while tripped
        if self.gaugeShown then
            local gx, gy = self.gauge:getX() + 2, self.gauge:getY()
            local gw, gh = PanelWindow.GAUGE_W, self.gauge:getHeight()
            local value = math.max(0, math.min(1, self.gaugeValue or 1))
            local c = (self.panel.tripped or value <= PanelWindow.GAUGE_RED) and P.bad or P.warn
            UI.fill(body, gx, gy, gw, gh, P.inset)
            local fill = math.floor(gh * value + 0.5)
            if fill > 0 then UI.fill(body, gx, gy + gh - fill, gw, fill, c, self.panel.tripped and 0.6 or 0.9) end
            UI.frame(body, gx, gy, gw, gh, P.border)
        end
    end
    local banner = self.banner
    if banner then
        local a = 0.85
        if banner.pulse then a = 0.7 + 0.2 * (0.5 + 0.5 * math.sin(now / 260)) end
        local c, x = banner.colour, self.bannerX or PAD
        local w = (self.listW or body.width) - PAD - x
        UI.fill(body, x, self.actionY, w, ROW, c, a)
        UI.fill(body, x, self.actionY, 3, ROW, P.bright, 0.8)
        UI.text(body, UI.fitMemo(banner.text, w - PAD * 2), x + PAD, self.actionY + (ROW - FONT_HGT_SMALL) / 2, P.bright)
    end
end

-- Over the body's parts: the search's hint while it is empty, and the veil of a tab coming up.
function ISBUPanelWindow:drawBodyOver(body)
    local search = self.search
    if search and search:getIsVisible() and search:getText() == "" and not search:isFocused() then
        local sx, sy = UI.dp(search:getX()), UI.dp(search:getY())
        UI.text(body, self.searchHint, sx + 6, sy + (UI.dp(search:getHeight()) - FONT_HGT_SMALL) / 2, P.dim)
    end
    local at = self.revealAt
    if at then
        local t = (getTimestampMs() - at) / ISBUPanelWindow.REVEAL_MS
        if t >= 1 then
            self.revealAt = nil
        else
            local tabs = self.tabs
            local x, top = tabs:getX(), tabs:getY() + tabs.tabHeight + (tabs.headH or 0)
            local w, bottom = tabs:getWidth(), tabs:getY() + tabs:getHeight()
            local u = 1 - math.max(0, t)
            local line = top + math.floor((1 - u * u) * (bottom - top))
            if line > top then UI.fill(body, x, top, w, line - top, P.bg, 0.5 * u) end
            if line < bottom then
                UI.fill(body, x, line, w, bottom - line, P.bg, 0.9 * u)
                UI.fill(body, x, line, w, 1, P.value, 0.35 * u)
            end
        end
    end
end

function ISBUPanelWindow:update()
    ISCollapsableWindow.update(self)
    if not Store.get(self.panel.id) then self:close(); return end
    -- Another window worked the kit's scale or faces out again (the font or the screen changed): this one was laid
    -- out in the old ones and opens anew where it is.
    if self.era ~= UI.era then self:reopen(); return end
    -- Its character dead, or another in its place (a new one after death), or far from the box it was opened at and
    -- from the box it shows: the window was theirs there. Not while an action walks them (one of
    -- the window's own, to a generator or another box): it closes if they stay away once it is done.
    local player = self.playerObj
    if player:isDead() or getSpecificPlayer(player:getPlayerNum()) ~= player then self:close(); return end
    if self:away() > PanelWindow.CLOSE_RANGE and not ISTimedActionQueue.isPlayerDoingAction(player) then
        self:close()
        return
    end
    local now = getTimestampMs()
    if self.changedAt and now - self.changedAt >= SETTLE_MS or now - (self.refreshedAt or 0) > Ui.FULL_MS then
        self:refresh()
    elseif now - (self.tickedAt or 0) > REFRESH_MS then
        self:tick()
    end
end

-- Between full refreshes: the load's card and the status line read again from the networks' states, the rows and
-- the plan left as they are (what changes them is told, BU.onChanged).
function ISBUPanelWindow:tick()
    self.tickedAt = getTimestampMs()
    local panel = Store.get(self.panel.id)
    if not panel then return end
    local power, water = Networks.state(panel, "power"), Networks.state(panel, "water")
    self.states = { power = power, water = water }
    self:measureLoad(panel, power)
    self:measureWater(panel, water)
    if self.load and math.abs((self.loadShown or 0) - self:loadShare()) > 0.002 then UI.live(self.body, bodyFrame) end
    self:updateStatus()
end

-- How far the player is from the nearer of the box it was opened at and the box it shows: the larger of the steps
-- across, and TILES_PER_FLOOR a floor up or down.
function ISBUPanelWindow:away()
    local player = self.playerObj
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local function from(box)
        return math.max(math.abs(px - box.x - 0.5), math.abs(py - box.y - 0.5))
            + math.abs(pz - box.z) * PanelWindow.TILES_PER_FLOOR
    end
    return math.min(from(self.anchor), from(self.panel))
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
    if self.manual then self.manual:leave() end
    self:showRange(false)
    self:outlineDevice(nil)
    open[self.panel.id] = nil
    BU.LineOverlay.refresh()
    -- It fades out (UI.fadeOut), but when another takes its place at once.
    if self.still then
        self:setVisible(false)
        self:removeFromUIManager()
    else
        UI.fadeOut(self)
    end
end

-- What the panel and its networks are now, as rows, and the plan. The tab shown is filled now (and power's, which
-- the load bar's tooltip tells), the other as it opens.
function ISBUPanelWindow:refresh()
    self.refreshedAt, self.tickedAt, self.changedAt = getTimestampMs(), getTimestampMs(), nil
    -- On a client in multiplayer the data is received anew: the panel by its id.
    local panel = Store.get(self.panel.id)
    if not panel then return end
    self.panel = panel
    -- The first box this character sees powered.
    if BU.Titles then BU.Titles.lit(self.playerObj, panel) end
    if self.manual then self.manual:refresh(panel) end
    -- A utility turned on or off in the sandbox, the first rack wired or the last taken away, or the log shown by an
    -- upgrade: the window opens anew where it is, with its tabs (reopen).
    if viewsKey(panel) ~= self.utilitiesKey then
        self:reopen()
        return
    end
    -- The highest floor of its building, for the boosters' rows.
    local building = Panels.building(panel)
    self.buildingTop = building and building.maxLevel or nil
    local powerOn = BU.enabled("power")
    local power, water = Networks.state(panel, "power"), Networks.state(panel, "water")
    self.states = { power = power, water = water }
    self:setTitle(getText("IGUI_BU_TierName", Panels.name(panel), panel.tier or 1))
    self:measureLoad(panel, power)
    self:measureWater(panel, water)
    if self.load and math.abs((self.loadShown or 0) - self:loadShare()) > 0.002 then UI.live(self.body, bodyFrame) end
    -- The banner: the breaker down.
    if powerOn and panel.tripped then
        self.banner = { text = getText("IGUI_BU_BannerTripped", load2(self.limit)), colour = { 0.6, 0.1, 0.1 }, pulse = true }
    else
        self.banner = nil
    end
    if self.banner and self.banner.pulse then UI.live(self.body, bodyFrame) end
    local tier = panel.tier or 1
    self.upgradeButton:setVisible(tier < BU.TIERS)
    if tier < BU.TIERS then
        titled(self.upgradeButton, getText("ContextMenu_BU_Upgrade", tier + 1))
        local cost = Costs.upgrade(tier + 1)
        self.upgradeButton:setTooltip(Panels.upgradeNote(tier + 1, true) .. "\n" .. Costs.describe(self.playerObj, cost, true))
        self.upgradeButton:setEnable(Costs.affords(self.playerObj, cost))
    end
    self:placeRows()
    -- The rooms of every building its zone can have (its own, and those its relays stand in): another building's
    -- named with where it is.
    self.building = Panels.building(panel)
    self.rooms = Panels.zoneRoomList(panel)
    self.titles = {}
    for _, building in ipairs(Panels.zoneBuildings(panel)) do
        local away = not self.building or building.key ~= self.building.key
        local where = away and Panels.where(panel, Geometry.centre(building))
        for id, title in pairs(Panels.roomTitles(building)) do
            self.titles[id] = away and getText("IGUI_BU_RoomAway", title, where) or title
        end
    end
    self.pending = {}
    local active = self:activeUtility()
    for _, utility in ipairs(self.utilities) do
        if utility == active or utility == "power" and self.load then self:fill(utility, self.states[utility])
        else self.pending[utility] = { state = self.states[utility] } end
    end
    if self.lists[LOG] then self:fillLog() end
    if self.lists[BATTERIES] then self:fillBatteries() end
    -- How water reaches the floors with fixtures, from the rows just filled: the status line and the plan both tell.
    self.waterSupply = self:workOutWaterSupply()
    self:updateStatus()
    self.loadArea:setTooltip(self:loadBreakdown())
    self:checkRange()
    self:updatePlan()
end

-- The window opens anew in its place, as large, with what the player had set here: the search, the room shown, the
-- zone editing, the plan's floor, zoom and pan, and the range shown.
function ISBUPanelWindow:reopen()
    local kept = { x = self:getX(), y = self:getY(), w = self:getWidth(), h = self:getHeight(),
        text = self.search:getText(), query = self.query, roomFilter = self.roomFilter, zoneEditing = self.zoneEditing,
        range = self.rangeShown, chapter = self.manual and self.manual.key,
        floor = self.plan.floor, zoom = self.plan.zoom, panX = self.plan.panX, panY = self.plan.panY }
    self.still = true
    self:close()
    local window = PanelWindow.open(self.playerObj, self.panel, self.anchor, true)
    window:setX(kept.x)
    window:setY(kept.y)
    window:setWidth(math.max(kept.w, window.minimumWidth))
    window:setHeight(math.max(kept.h, window.minimumHeight))
    if kept.text and kept.text ~= "" then window.search:setText(kept.text) end
    window.query, window.roomFilter, window.zoneEditing = kept.query, kept.roomFilter, kept.zoneEditing
    window.plan.floor, window.plan.zoom, window.plan.panX, window.plan.panY = kept.floor, kept.zoom, kept.panX, kept.panY
    if kept.range then window:showRange(true) end
    if kept.chapter then window.manual:show(kept.chapter) end
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
    -- The six that draw most; what would read 0.00 is not listed on its own, nor the rest when it comes to that.
    local SHOWN, LEAST, rest, restTotal = 6, 0.005, 0, 0
    for index, group in ipairs(groups) do
        if index <= SHOWN and group.total >= LEAST then lines[#lines + 1] = "  " .. group.title .. "  " .. load2(group.total)
        else rest, restTotal = rest + 1, restTotal + group.total end
    end
    if rest > 0 and restTotal >= LEAST then lines[#lines + 1] = "  " .. getText("IGUI_BU_BreakdownMore", rest) .. "  " .. load2(restTotal) end
    lines[#lines + 1] = getText("IGUI_BU_BreakdownTotal", load2(self.load), load2(self.limit))
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
    local power = device.power or 0
    if power <= 0 or not self.load or device.state == "other" or device.held then return nil end
    local after, key
    if device.state == "on" then
        after, key = self.load - power, "IGUI_BU_PreviewOff"
    else
        after, key = self.load + power, device.wired and "IGUI_BU_PreviewOn" or "IGUI_BU_PreviewConnect"
    end
    local text = getText(key, load2(after), load2(self.limit))
    if device.state ~= "on" and BU.overloadEnabled() and after > self.limit + 1e-6 then
        text = text .. " <LINE> <RGB:1,0.4,0.4> " .. getText("IGUI_BU_PreviewTrip")
    end
    return text
end

-- What a device the box keeps off says, by why (Panels.devices' held).
local HELD_TEXT = { timer = "IGUI_BU_HeldTimer", exterior = "IGUI_BU_HeldExterior", cut = "IGUI_BU_LineNotSupplied" }

-- What a device does now, in words, for its row and the plan.
function ISBUPanelWindow:deviceStatus(utility, device)
    local text, dim = "", false
    if device.state == "other" then
        local other
        for _, key in ipairs(device.keys) do other = other or Store.inclusionOwner(utility, key) end
        return getText("IGUI_BU_ConnectedTo", other and Panels.name(other) or ""), false
    end
    if not device.wired then return getText("IGUI_BU_NotWired"), true end
    if device.cut then return getText("IGUI_BU_LineNotSupplied"), true end
    if utility == "power" then
        local power = device.power or 0
        if device.state ~= "on" then
            text, dim = power > 0 and string.format("%.3f", power) or "", true
        elseif device.held then
            text = getText(HELD_TEXT[device.held])
        elseif device.switchOn == false then
            text, dim = getText("IGUI_BU_SwitchedOff"), true
        elseif power > 0 then
            text = string.format("%.3f", power) .. " (" .. percent(power, self.limit) .. ")"
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

-- Devices in a room built onto the building that the networks do not have yet (Changes.syncAttached runs each minute):
-- the server is asked to add them now, at most every few seconds.
function ISBUPanelWindow:askAttached(devices)
    for _, device in ipairs(devices) do
        if device.pending then
            local now = getTimestampMs()
            if not self.attachedAsked or now - self.attachedAsked > 3000 then
                self.attachedAsked = now
                Sync.send(self.playerObj, "syncAttached", { panel = self.panel.id })
            end
            return
        end
    end
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
    local function add(row, tooltip)
        row.tip = tooltip
        list:addItem(row.text or "", row)
    end
    if not devices then
        devices, complete = Panels.devices(panel, utility)
        self:askAttached(devices)
    end
    -- The building's devices, and those outside in reach: wired to the box (at themselves), or not yet; not those
    -- another box's line reaches.
    local listed = {}
    for _, device in ipairs(devices) do
        if device.inside or device.state ~= "other" then listed[#listed + 1] = device end
    end
    devices = listed
    local view = { state = state, devices = devices, complete = complete, names = {}, status = {}, totals = {},
        producerText = {}, fresh = {} }
    self.views[utility] = view
    -- The pipes first (with more than one): the tanks', rooms', fixtures' and units' rows show theirs.
    if utility == "water" then self:pipeRows(add, state, devices) end
    add({ kind = "header", text = getText("IGUI_BU_Producers"), options = true })
    local producers = panel[utility].producers
    local source = utility == "power" and Energy.hasSource(panel)
    if #producers == 0 and not source then add({ kind = "note", text = getText("IGUI_BU_NoProducers_" .. utility) }) end
    if source then
        for _, entry in ipairs(self:sourceRows(state)) do add(entry.row, entry.tooltip) end
    end
    for index, at in ipairs(producers) do
        local seen = PanelWindow.seenProducer(state, at)
        local inUse = PanelWindow.producerInUse(state, at)
        local where = Panels.where(panel, at.x, at.y, at.z)
        local text, generatorState
        if utility == "power" then
            local square = getCell():getGridSquare(at.x, at.y, at.z)
            local generator = square and square:getGenerator()
            local fuel = seen and seen.fuel and (generator and percent(seen.fuel, generator:getMaxFuel()) or string.format("%.1f", seen.fuel)) or "-"
            generatorState = PanelWindow.generatorState(state, at)
            text = getText("IGUI_BU_GeneratorRow", index, where, PanelWindow.generatorStateText(generatorState), fuel,
                seen and seen.condition and string.format("%.0f%%", seen.condition) or "-")
        else
            -- One the networks do not hold (its line cut) as it stands on its square, when that is loaded.
            local amount, capacity = seen and seen.amount, seen and seen.capacity
            local storage = not amount and Panels.waterStorage(at.x, at.y, at.z)
            if storage then amount, capacity = storage:getAmount(), storage:getCapacity() end
            text = getText("IGUI_BU_TankRow", index, where, amount and string.format("%.0f", amount) or "-",
                capacity and string.format("%.0f", capacity) or "-")
            -- Holding what is not water: left out of the pipes until it is emptied.
            if seen and seen.foreign then text = text .. "  " .. getText("IGUI_BU_TankForeign") end
        end
        -- Its line supplying nothing: dim, the mouse over it telling why.
        local ref = Links.producerRef(at.x, at.y, at.z)
        local cut = Links.reason(panel, ref) ~= nil
        if cut then text = text .. "  " .. getText("IGUI_BU_LineNotSupplied") end
        view.producerText[index] = text
        local row = { kind = "producer", text = text, index = index, at = at, inUse = inUse and not cut,
            water = utility == "water", out = generatorState == "out", cut = cut, bad = seen and seen.foreign }
        if utility == "water" and BU.Water.shown(panel) then
            row.chips, row.pipes = { "Pipe" }, { Pipe = BU.Water.producerPipe(panel, at) }
        end
        -- A generator's row tells how servicing one works: switched off by hand, the others take over.
        add(row, cut and Links.reasonText(panel, ref) or utility == "power" and getText("IGUI_BU_GeneratorTip") or nil)
    end
    if utility == "water" then
        self:waterUnitRows(add)
        self:addPipeRow(add)
    end
    -- What it could take and no box has, dim, unless the view hides it: connected at the thing itself.
    view.unwired = Panels.unwiredProducers(panel, utility)
    if not PanelWindow.options.hideUnwired then
        for _, at in ipairs(view.unwired) do
            -- The API names a water storage by its square only.
            local name = at.unit and Units.name(at.unit) or utility == "water" and getText("IGUI_BU_Legend_tank")
                or BU.displayName(at.x, at.y, at.z, at.sprite)
            add({ kind = "producer", unwired = true, at = at, water = utility == "water",
                text = getText("IGUI_BU_UnwiredProducerRow", name, Panels.where(panel, at.x, at.y, at.z)) },
                getText("IGUI_BU_UnwiredProducerTip"))
        end
    end
    self:lineRows(add, utility)
    local seen = self:seenSet(utility, devices)
    for _, device in ipairs(devices) do
        if not seen[device.key] then view.fresh[device.key] = true end
    end
    local query = self.query or ""
    -- Switching on every device of the building that is off: what the load would be.
    local allTip, offPower = nil, 0
    for _, device in ipairs(devices) do
        if Ui.inBuilding(device) and device.state == "off" then offPower = offPower + (device.power or 0) end
    end
    if utility == "power" and self.load and offPower > 0 then
        allTip = getText("IGUI_BU_PreviewAll", load2(self.load + offPower), load2(self.limit))
    end
    -- Below the tier that cuts devices there is nothing to switch: no "everything inside" row, rows without ticks.
    local fixed = not Panels.cuts(panel)
    if not fixed then
        add({ kind = "all", text = getText("IGUI_BU_AllInside"), state = self:allInside(devices) and "on" or "off" }, allTip)
    end
    if not complete then add({ kind = "note", text = getText("IGUI_BU_NotAllLoaded") }) end
    if #devices == 0 then add({ kind = "note", text = getText("IGUI_BU_NoDevices_" .. utility) }) end
    -- Rooms by their id (rooms of one name stay apart), with the devices outside hung on their walls; a relay's devices
    -- under it; devices in no room after them; then those outside hung on neither, by floor (Ui.groupOf).
    local options = PanelWindow.options
    local groups, order = {}, {}
    local floorOf = {}
    for _, room in ipairs(self.rooms or {}) do floorOf[room.id] = room.level end
    self.displayNames = self.displayNames or {}
    local names = self.displayNames
    for _, device in ipairs(devices) do
        local entry = device.entry
        -- its name looked up once a window (a square's objects searched, a translation read)
        local base = names[device.key]
        if not base then
            base = BU.displayName(entry.x, entry.y, entry.z, entry.sprite)
            names[device.key] = base
        end
        local name = base
        if not device.inside then
            name = name .. "  (" .. Panels.where(panel, entry.x, entry.y, entry.z) .. ")"
        elseif device.attached then
            name = name .. "  (" .. getText("IGUI_BU_Attached") .. ")"
        end
        view.names[device.key] = name
        local status, dim = self:deviceStatus(utility, device)
        view.status[device.key] = status
        local group, level = Ui.groupOf(device)
        if not groups[group] then
            groups[group] = { id = group, devices = {}, total = 0, on = 0, off = 0,
                level = floorOf[group] or level, relay = Links.isRelay(group), outside = Ui.isOutside(group) }
            order[#order + 1] = groups[group]
        end
        local g = groups[group]
        g.roomKey = g.roomKey or device.roomKey
        if device.state == "on" then
            g.on = g.on + 1
            if not device.held then g.total = g.total + (device.power or 0) end
        elseif device.state == "off" and device.wired then
            g.off = g.off + 1
        end
        local shown = (not options.activeOnly or utility ~= "power" or (device.power or 0) > 0 or device.held ~= nil)
            and not (options.hideUnwired and not device.wired)
        if shown then table.insert(g.devices, { device = device, name = name, status = status, dim = dim }) end
    end
    local function title(id)
        if Ui.isOutside(id) then return getText("IGUI_BU_Outside") end
        if id == "" then return getText("IGUI_BU_NoRoom") end
        if Links.isRelay(id) then
            local unit = Links.unitOf(id)
            return unit and Units.name(unit) .. "  (" .. Panels.where(panel, unit.x, unit.y, unit.z) .. ")" or getText("IGUI_BU_NoRoom")
        end
        return self.titles[id] or getText("IGUI_BU_NoRoom")
    end
    local function rank(group) return group.outside and 3 or group.id == "" and 2 or group.relay and 1 or 0 end
    table.sort(order, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        if options.byLoad and a.total ~= b.total then return a.total > b.total end
        return title(a.id) < title(b.id)
    end)
    if self.roomFilter then
        add({ kind = "filter", text = getText("IGUI_BU_FilterNote", title(self.roomFilter)) })
    end
    local timers = (panel.tier or 1) >= BU.TIMER_TIER
    -- Water: the pipes shown (more than one), and the layout that tells a fixture with no tank at or above it.
    local pipesShown = utility == "water" and BU.Water.shown(panel)
    local layout = utility == "water" and BU.Networks.waterLayout(panel) or nil
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
        if not group.outside then
            roomState = group.off == 0 and "on" or group.on == 0 and "off" or "some"
        end
        local right = utility == "power" and load2(group.total) or (group.on .. " / " .. (group.on + group.off))
        local roomPipe = pipesShown and group.roomKey and BU.Water.roomPipe(panel, group.roomKey) or nil
        add({ kind = "room", id = group.id, text = title(group.id), right = right, state = roomState, fixed = fixed,
            folded = folded, foldKey = foldKey, pipe = roomPipe, roomKey = group.roomKey })
        if not folded then
            table.sort(group.devices, function(a, b)
                if options.byLoad and (a.device.power or 0) ~= (b.device.power or 0) then return (a.device.power or 0) > (b.device.power or 0) end
                return a.name < b.name
            end)
            for _, shown in ipairs(group.devices) do
                local device = shown.device
                local tooltip = utility == "power" and self:preview(device) or nil
                if not device.inside then
                    tooltip = (tooltip and tooltip .. " <LINE> " or "")
                        .. (device.cut and Links.reasonText(panel, Links.deviceRef(device.key))
                            or getText(device.wired and "IGUI_BU_OutsideTip" or "IGUI_BU_UnwiredTip"))
                end
                -- its own switch, which way it is: thrown at the device, not here
                if device.switchOn ~= nil then
                    tooltip = (tooltip and tooltip .. " <LINE> " or "")
                        .. getText(device.switchOn and "IGUI_BU_OwnSwitchOnTip" or "IGUI_BU_OwnSwitchOffTip")
                end
                -- its timer button tells what it does over itself (ISBUPanelList.BUTTON_TIPS)
                local controls = timers and utility == "power" and device.state == "on"
                local pipe = pipesShown and device.state == "on" and device.pipe or nil
                -- No tank of its pipe at its floor or above (in its building, or one the lines let down to it).
                local right, bad = shown.status, nil
                if layout and device.state == "on" and device.building and layout.tanks[device.pipe or BU.Water.FIRST] then
                    local id = BU.Water.useId(layout, device.pipe, device.building, device.level)
                    if id and not BU.Water.reachesTank(layout, id) then
                        right, bad = getText("IGUI_BU_TooHigh"), true
                        tooltip = (tooltip and tooltip .. " <LINE> " or "") .. getText("IGUI_BU_TooHighTip")
                    end
                end
                add({ kind = "device", text = shown.name, right = right, dim = shown.dim, device = device,
                    state = device.state, unwired = not device.wired, held = device.held, controls = controls,
                    fixed = fixed, fresh = view.fresh[device.key], pipe = pipe, bad = bad }, tooltip)
            end
        end
    end
    -- Rooms on more than one floor: a header per floor, lowest first, with its rooms, relays and what is outside on it
    -- under it; a floor folded shows the header alone (ISBUPanelWindow:floorFolded). Devices in no room after the
    -- floors.
    local floors, levels = {}, {}
    for _, group in ipairs(order) do
        local level = group.level
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
            if group.level == nil and visible(group) then emit(group) end
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
    IGUI_BU_Notice_WaterEmptyPipe = true, IGUI_BU_Notice_LowFuel = true, IGUI_BU_Notice_Shed = true,
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
    -- The energy graph from BU.GRAPH_TIER; the box keeps its hours before.
    if #hours > 0 and (self.panel.tier or 1) >= BU.GRAPH_TIER then list:addItem("", { kind = "graph", hours = hours }) end
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
        -- The box's name before a notice says nothing in its own log: left out.
        local name = entry.args and entry.args[1]
        local prefix = name and tostring(name) .. ": "
        if prefix and text:sub(1, #prefix) == prefix then text = text:sub(#prefix + 1) end
        list:addItem(text, { kind = "log", text = text, right = ago(math.max(0, worldHours - (entry.hour or worldHours))),
            bad = BAD[entry.key], good = GOOD[entry.key] })
    end
    list:setYScroll(scroll)
end

-- The battery tab: a row per rack wired to the box, folded at first, with what it holds in sum (its state, what it
-- stores and gives, how long that lasts, its charge: RackWindow.drawSummary); unfolded, its batteries under it, as in
-- the rack's own window (RackWindow.drawBattery). The columns are named once at the top.
function ISBUPanelWindow:fillBatteries()
    local list = self.lists[BATTERIES]
    local scroll = list:getYScroll()
    list:clear()
    list:addItem("", { kind = "columns" })
    for _, unit in ipairs(Store.unitList("rack", self.panel.id)) do
        local view = BU.RackWindow.measure(unit)
        local foldKey = self.panel.id .. "|rack|" .. unit.id
        local folded = PanelWindow.folded[foldKey] ~= false
        list:addItem("", { kind = "rack", rack = unit, view = view, folded = folded, foldKey = foldKey,
            text = getText("IGUI_BU_RackRow", BU.Units.name(unit), #view.batteries) })
        if not folded then
            for _, battery in ipairs(view.batteries) do list:addItem("", { kind = "battery", battery = battery }) end
        end
    end
    list:setYScroll(scroll)
end

function ISBUPanelWindow:allInside(devices)
    for _, device in ipairs(devices) do
        if Ui.inBuilding(device) and device.state ~= "on" then return false end
    end
    return true
end

-- A device's tick: its supply switched at the box, free; one outside without its line is wired at itself.
function ISBUPanelWindow:switchDevice(utility, device)
    if device.state == "other" then return end
    if not device.wired then
        HaloTextHelper.addBadText(self.playerObj, getText("IGUI_BU_ConnectAtDevice"))
        return
    end
    Sync.send(self.playerObj, "setInside", { panel = self.panel.id, utility = utility, key = device.key, on = device.state ~= "on" })
end

-- Where a row's thing is, for the plan: a producer's, a unit's or a relay's square, a device's, a room's (or a
-- relay's group's) square, a rack's. Nil for a row of no one place.
local function rowPlace(row)
    local at = row.relay or row.unit or row.at or row.rack or (row.device and row.device.entry)
    if at then return at.x, at.y, at.z end
    if row.kind == "room" then
        if row.roomKey then return BU.parsePlace(row.roomKey) end
        local unit = Links.unitOf(row.id)
        if unit then return unit.x, unit.y, unit.z end
    end
    return nil
end

-- A row's thing shown on the plan, as a click on a row that hits none of its buttons does.
function ISBUPanelWindow:showRow(row)
    local x, y, z = rowPlace(row)
    if x then self:showOnPlan(x, y, z) end
end

-- A click on a row: free changes as commands; lines laid or taken away by walking there. A click on a row's thing
-- that hits none of its buttons also shows it on the plan.
function ISBUPanelWindow:onRow(utility, row, x, width)
    local panel, playerObj = self.panel, self.playerObj
    if row.options then
        for _, button in ipairs(Ui.optionButtons(width, row)) do
            if x >= button.x and x < button.x + button.w then
                if button.name == "ActiveOnly" then self:onActiveOnly()
                elseif button.name == "ByLoad" then self:onByLoad()
                else self:onHideUnwired() end
                return
            end
        end
    end
    if row.kind == "source" then
        for _, button in ipairs(Ui.sourceButtons(width, row)) do
            if x >= button.x and x <= button.x + button.w then
                if row.useSourceReady then
                    Sync.send(playerObj, "useSource", { panel = panel.id })
                else
                    HaloTextHelper.addBadText(playerObj, row.useSourceReason)
                end
            end
        end
    elseif row.kind == "producer" and (row.relay or row.unwired) then
        self:showRow(row)
    elseif row.kind == "producer" and row.unit then
        if not self:onWaterUnitRow(row, x, width) then self:showRow(row) end
    elseif row.kind == "producer" then
        for _, button in ipairs(Ui.producerButtons(width, row)) do
            if x >= button.x and x <= button.x + button.w then
                if button.name == "Pipe" then
                    self:producerPipeMenu(row)
                else
                    Sync.send(playerObj, "moveProducer", { panel = panel.id, utility = utility, index = row.index,
                        delta = button.name == "Up" and -1 or 1 })
                end
                return
            end
        end
        self:showRow(row)
    elseif row.kind == "waterPipe" or row.kind == "addPipe" then
        self:onPipeRow(row, x, width)
    elseif row.kind == "all" then
        if not row.fixed and x >= PAD * 2 and x <= PAD * 2 + ROW then
            Sync.send(playerObj, "setAllInside", { panel = panel.id, utility = utility, on = row.state ~= "on" })
        end
    elseif row.kind == "filter" then
        self:filterRoom(nil)
    elseif row.kind == "note" and row.dead then
        self:showDead(utility)
    elseif row.kind == "rack" then
        PanelWindow.folded[row.foldKey] = not row.folded
        self:fillBatteries()
        self:showRow(row)
    elseif row.kind == "floor" then
        PanelWindow.folded[row.foldKey] = not row.folded
        -- Unfolded, the plan shows that floor (which fills the list again, planFloorChanged); else the list alone.
        if row.folded and self.plan and self.plan.floor ~= row.level then self.plan:showFloor(row.level)
        else self:refill(utility) end
    elseif row.kind == "room" then
        for _, button in ipairs(Ui.roomButtons(width, row)) do
            if x >= button.x and x <= button.x + button.w then return self:roomPipeMenu(row) end
        end
        if row.state and not row.fixed and x >= ROOM_TICK_X and x <= ROOM_TICK_X + ROW then
            Sync.send(playerObj, "setRoomInside", { panel = panel.id, utility = utility, room = row.id, on = row.state ~= "on" })
        else
            PanelWindow.folded[row.foldKey] = (not row.folded) or nil
            self:refill(utility)
            self:showRow(row)
        end
    elseif row.kind == "device" and row.state ~= "other" then
        local device = row.device
        for _, button in ipairs((deviceButtons(width, row))) do
            if x >= button.x and x <= button.x + button.w then
                if button.name == "pipe" then
                    self:devicePipeMenu(device)
                else
                    Sync.send(playerObj, "setSchedule", { panel = panel.id, key = device.key, schedule = nextSchedule(device.schedule) })
                end
                return
            end
        end
        -- its tick switches it; the rest of the row only shows it
        if not row.fixed and not row.unwired and x >= PAD * 3 and x <= PAD * 3 + ROW then self:switchDevice(utility, device)
        else self:showRow(row) end
    end
end

function ISBUPanelWindow:onRename()
    -- Empty unless the player named it: confirming the automatic name must not fix it. The kit's prompt, over the
    -- window.
    UI.prompt(self.playerObj, getText("IGUI_BU_RenamePrompt"), self.panel.name or "", self, ISBUPanelWindow.onRenamed, self)
end

function ISBUPanelWindow:onRenamed(name)
    Sync.send(self.playerObj, "rename", { panel = self.panel.id, name = name })
end

-- The lever thrown the other way, at once, as a device's tick in the window is.
function ISBUPanelWindow:onLever()
    Sync.send(self.playerObj, "setLever", { panel = self.panel.id, up = not Panels.leverUp(self.panel) })
end

function ISBUPanelWindow:onUpgrade()
    local panel = self.panel
    BU.ContextMenu.queueAt(self.playerObj, panel.x, panel.y, panel.z, ISBUUpgradePanel:new(self.playerObj, panel))
end

-- How far from the box it was opened at, in tiles (a floor up or down counting as TILES_PER_FLOOR), a window stays open.
PanelWindow.CLOSE_RANGE, PanelWindow.TILES_PER_FLOOR = 12, 3

-- A box's window, opened at a box (anchor, { x, y, z }: the panel's own when not given); it fades in (UI.fadeIn)
-- unless `still` (one window put in another's place).
function PanelWindow.open(playerObj, panel, anchor, still)
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
    if not still then UI.fadeIn(window) end
    open[panel.id] = window
    -- its lines in the world (BU.LineOverlay)
    BU.LineOverlay.refresh()
    return window
end

function PanelWindow.isOpen(panelId) return open[panelId] ~= nil end

-- The panel ids of the windows open.
function PanelWindow.openIds()
    local ids = {}
    for id in pairs(open) do ids[#ids + 1] = id end
    return ids
end

-- The window open for a panel, or nil.
function PanelWindow.get(panelId) return open[panelId] end

-- The data changed: every window refreshes once that settles, as a box's change can show in another's window too
-- (its name, a device connected to it).
function PanelWindow.refreshAll()
    for _, window in pairs(open) do window:changed() end
end

-- The API says a network changed: its panel's window shows it.
function PanelWindow.onNetworkChange(id)
    local panel = Networks.owner(id)
    if panel and open[panel.id] then open[panel.id]:changed() end
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
