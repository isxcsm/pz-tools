-- The communication terminal's window: one tab each for the shop and orders, the helicopter, the market, the ledger,
-- trust and the radio log, and any tab another part of the mod adds with OA.Terminal.addTab. It opens when the
-- using action completes (OA.Terminal.open) and shows the player's own record, refreshed when the record changes.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISTabPanel"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/Terminal"
require "OperationAcorn/Trade/Things"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local Trade, Terminal, UI = OA.Trade, OA.Terminal, OA.Trade.UI
local Objects, Things = Trade.Objects, Trade.Things

OATerminalWindow = ISCollapsableWindow:derive("OATerminalWindow")
OATerminalWindow.instances = {}

-- A tab's base: a panel that knows its window and the player's record. Tabs derive from it and build their widgets in
-- createChildren; `refresh` redraws them from the record.
OATab = ISPanel:derive("OATab")

function OATab:new(x, y, width, height, window)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.window = window
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

function OATab:character() return self.window.character end
function OATab:record() return OA.Client.record(self.window.character) end
function OATab:refresh() end

-- Sends a command about this terminal: the window's terminal square rides along (the server checks it).
function OATab:send(command, args)
    args = args or {}
    args.x, args.y, args.z = self.window.tx, self.window.ty, self.window.tz
    OA.Sync.send(self.window.character, command, args)
end

function OATerminalWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top, bottom = self:titleBarHeight(), self:resizeWidgetHeight()
    self.panel = ISTabPanel:new(0, top, self.width, self.height - top - bottom)
    self.panel:initialise()
    self.panel.anchorRight = true
    self.panel.anchorBottom = true
    self.panel.target = self
    self.panel.onActivateView = OATerminalWindow.onTab
    self.panel.tabPadX = 12
    self.panel.equalTabWidth = false
    self:addChild(self.panel)
    self.shown = {}
    self:buildTabs()
end

-- The ids of the tabs to show now, as one string, so a change shows.
local function signature(tabs)
    local ids = {}
    for _, tab in ipairs(tabs) do ids[#ids + 1] = tab.id end
    return table.concat(ids, ",")
end

-- Builds the tabs for the record as it is (the market's graph opens with trust, so a tab may come or go).
function OATerminalWindow:buildTabs()
    local record = OA.Client.record(self.character)
    local tabs = Terminal.tabs(record, self.character)
    local sig = signature(tabs)
    if sig == self.signature then return end
    local active = self.activeId
    for _, shown in ipairs(self.shown) do self.panel:removeView(shown.view) end
    self.shown = {}
    self.signature = sig
    local w = self.panel.width
    local h = self.panel.height - self.panel.tabHeight
    for _, tab in ipairs(tabs) do
        local view = tab.factory(0, 0, w, h, self)
        -- A factory may give a view it already made (initialise again would clear the children it added).
        if not view.javaObject then
            view:initialise()
            view:instantiate()
        end
        view.anchorRight = true
        view.anchorBottom = true
        local name = getText(tab.titleKey)
        self.panel:addView(name, view)
        self.shown[#self.shown + 1] = { id = tab.id, name = name, view = view }
    end
    if active then
        for _, shown in ipairs(self.shown) do
            if shown.id == active then self.panel:activateView(shown.name) end
        end
    end
    self:refresh()
end

function OATerminalWindow.onTab(self)
    local view = self.panel:getActiveView()
    for _, shown in ipairs(self.shown) do
        if shown.view == view then self.activeId = shown.id end
    end
    if view and view.refresh then view:refresh() end
end

-- Redraws what is on show: the tabs may have changed, then the active tab.
function OATerminalWindow:refresh()
    self:buildTabs()
    local view = self.panel:getActiveView()
    if view and view.refresh then view:refresh() end
end

-- Every half second or so: the terminal still stands, the player is still near it and it still has power.
function OATerminalWindow:update()
    ISCollapsableWindow.update(self)
    self.ticks = (self.ticks or 0) + 1
    if self.ticks < 30 then return end
    self.ticks = 0
    local square = getCell():getGridSquare(self.tx, self.ty, self.tz)
    local object = square and Objects.find(square, Objects.TERMINAL)
    if not object or self.character:isDead() then return self:close() end
    if not Things.near(self.character, self.tx, self.ty) then return self:close() end
    if not Objects.powered(square) then
        OA.Sync.deliver("notice", OA.Client.id(self.character), { key = "IGUI_OA_Trade_Reason_noPower" })
        return self:close()
    end
end

function OATerminalWindow:close()
    OATerminalWindow.instances[self.playerNum] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

function OATerminalWindow:new(character, x, y, z)
    local width, height = 700, 460
    local sx = (getCore():getScreenWidth() - width) / 2
    local sy = (getCore():getScreenHeight() - height) / 2
    local o = ISCollapsableWindow:new(sx, sy, width, height)
    setmetatable(o, self)
    self.__index = self
    -- nearly opaque: a long text over the world (zombies walking behind it) is hard to read at vanilla's 0.8
    o.backgroundColor = { r = 0.02, g = 0.02, b = 0.03, a = 0.93 }
    o.title = getText("IGUI_OA_Trade_Terminal")
    o.character = character
    o.playerNum = character:getPlayerNum()
    o.tx, o.ty, o.tz = x, y, z
    o:setResizable(true)
    o.minimumWidth, o.minimumHeight = 560, 380
    return o
end

-- Opens the window for a character at the terminal on x, y, z (the one already open comes to the front).
function Terminal.open(character, x, y, z)
    local playerNum = character:getPlayerNum()
    local window = OATerminalWindow.instances[playerNum]
    if window then
        window:close()
    end
    window = OATerminalWindow:new(character, x, y, z)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    OATerminalWindow.instances[playerNum] = window
    OA.Sync.send(character, "tradeUsed", { x = x, y = y, z = z })
    return window
end

-- The record changed: the open windows of that player redraw.
local function onChanged(playerId)
    for _, window in pairs(OATerminalWindow.instances) do
        if playerId == nil or playerId == OA.Client.id(window.character) then window:refresh() end
    end
end
OA.Sync.listen("trade", onChanged)
OA.Sync.listen("all", function() onChanged(nil) end)

return OATerminalWindow
