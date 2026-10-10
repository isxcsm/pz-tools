-- The communication terminal's window (DESIGN-terminal 1): four tabs, status, shop, delivery and missions, drawn in
-- the palette of the terminal it is open at (the crude one built from the kit, or the field terminal ordered from the
-- shop). The part that owns a tab gives its view with OA.Terminal.addTab. The window opens on the status tab every
-- time, when the using action completes (OA.Terminal.open), and shows the player's own record, redrawn when the
-- record changes.
require "ISUI/ISCollapsableWindow"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/Terminal"
require "OperationAcorn/Trade/Things"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local Trade, Terminal, UI = OA.Trade, OA.Terminal, OA.Trade.UI
local Objects, Things = Trade.Objects, Trade.Things

OATerminalWindow = ISCollapsableWindow:derive("OATerminalWindow")
OATerminalWindow.instances = {}

-- Sizes (DESIGN-terminal 1.2): the default and the smallest, and the inner margin of the body, in design units (the
-- window is the game's and in pixels: these times the scale, Trade/UI.lua; the tabs in its body are in design units).
OATerminalWindow.WIDTH, OATerminalWindow.HEIGHT = 720, 480
OATerminalWindow.MIN_WIDTH, OATerminalWindow.MIN_HEIGHT = 600, 420
OATerminalWindow.PAD = 10
-- The most of the screen the window takes.
OATerminalWindow.SCREEN_SHARE = 0.9

local SCANLINE = "media/textures/OA_Scanline.png"

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
function OATab:palette() return self.window.palette end
function OATab:refresh() end

-- Sends a command about this terminal: the window's terminal square rides along (the server checks it).
function OATab:send(command, args)
    args = args or {}
    args.x, args.y, args.z = self.window.tx, self.window.ty, self.window.tz
    OA.Sync.send(self.window.character, command, args)
end

UI.scaled(OATab, ISPanel)

-- The strip of the four tabs under the title bar: the crude terminal's are outlined green boxes, the field
-- terminal's sit on an olive band with an amber line over the chosen one. A dot by a name is something not seen yet
-- (amber, pulsing until the tab is looked at) or a state to deal with (red); a tab that has something new to look at
-- also blinks (OATerminalWindow:blinkTab) until it is shown.
OATerminalTabs = ISPanel:derive("OATerminalTabs")

function OATerminalTabs:new(x, y, width, height, window)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.window = window
    o.background = false
    o.slots = {}
    -- The names and their widths, measured once (the language does not change while the window is open).
    o.labels = {}
    for _, id in ipairs(Terminal.ORDER) do
        local name = getText(Terminal.titleKey(id))
        o.labels[id] = { name = name, w = UI.textWidth(name) + 30 }
    end
    return o
end

function OATerminalTabs:prerender()
    local w = self.window
    local p = w.palette
    local h = self.height
    if p.tabStrip then UI.fill(self, 0, 0, self.width, h, p.tabStrip) end
    local fh = UI.fontHeight()
    local x = 8
    self.slots = {}
    local pulse = math.sin(getTimestampMs() / 220)
    for _, id in ipairs(Terminal.ORDER) do
        local name, tw = self.labels[id].name, self.labels[id].w
        local on = id == w.activeId
        if p.tabStrip then
            if on then
                UI.fill(self, x, 2, tw, h - 2, p.bg)
                UI.fill(self, x, 2, tw, 2, p.value)
            end
            UI.textCentre(self, name, x + tw / 2, (h - fh) / 2 + 1, on and p.value or p.text)
        else
            if on then
                UI.fill(self, x, 3, tw, h - 3, p.sel, 0.18)
                UI.frame(self, x, 3, tw, h - 2, p.text)
                UI.fill(self, x + 1, h - 1, tw - 2, 1, p.bg)
            else
                UI.frame(self, x, 4, tw, h - 5, p.border)
            end
            UI.textCentre(self, name, x + tw / 2, (h - fh) / 2 + 1, on and p.bright or p.dim)
        end
        if w.blink[id] then
            UI.frame(self, x - 1, 1, tw + 2, h - 1, p.value, 0.5 + 0.5 * pulse)
        end
        local mark = w.marks[id]
        if mark then
            local a = 1
            if mark == "new" then a = 0.55 + 0.45 * pulse end
            UI.fill(self, x + tw - 8, 7, 4, 4, mark == "bad" and p.bad or p.warn, a)
        end
        self.slots[#self.slots + 1] = { id = id, x = x, w = tw }
        x = x + tw + 3
    end
    UI.fill(self, 0, h - 1, self.width, 1, p.border)
end

function OATerminalTabs:onMouseDown(x, y)
    for _, slot in ipairs(self.slots) do
        if x >= slot.x and x < slot.x + slot.w then
            self.window:activate(slot.id)
            return true
        end
    end
    return true
end

UI.scaled(OATerminalTabs, ISPanel)

-- The window ----------------------------------------------------------------------------------------------------

function OATerminalWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local p = self.palette
    -- Only the close box stays of the vanilla title bar, drawn in the palette.
    for _, b in ipairs({ self.pinButton, self.collapseButton, self.infoButton }) do
        if b then b:setVisible(false) end
    end
    local cb = self.closeButton
    cb:setImage(nil)
    cb:setTitle("x")
    cb.textColor = { r = p.text[1], g = p.text[2], b = p.text[3], a = 1 }
    cb.borderColor = { r = p.border[1], g = p.border[2], b = p.border[3], a = 1 }
    cb.backgroundColorMouseOver = { r = p.sel[1], g = p.sel[2], b = p.sel[3], a = 0.25 }
    local th = self:titleBarHeight()
    -- The strip and the views are ours, in design units: the title bar's pixels are given to them as such.
    self.tabHeight = UI.fontHeight() + 6
    self.strip = OATerminalTabs:new(0, UI.dp(th), UI.dp(self.width), self.tabHeight, self)
    self.strip:initialise()
    self.strip:setAnchorRight(true)
    self:addChild(self.strip)
    self.views = {}
    self:activate("status")
end

-- Where the active tab's view goes: under the strip, inside the margin, above the resize bar (design units).
function OATerminalWindow:bodyRect()
    local pad = OATerminalWindow.PAD
    local top = UI.dp(self:titleBarHeight()) + self.tabHeight + pad
    local bottom = UI.dp(self:resizeWidgetHeight()) + pad
    return pad, top, UI.dp(self.width) - pad * 2, UI.dp(self.height) - top - bottom
end

-- The view of a tab, made the first time it is shown. A tab no part has given a view yet shows nothing.
function OATerminalWindow:view(id)
    local view = self.views[id]
    if view then return view end
    local x, y, w, h = self:bodyRect()
    local tab = Terminal.tab(id)
    if tab then
        view = tab.factory(x, y, w, h, self)
    else
        view = OATab:new(x, y, w, h, self)
    end
    -- A factory may give a view it already made (initialise again would clear the children it added).
    if not view.javaObject then
        view:initialise()
        view:instantiate()
    end
    view:setAnchorRight(true)
    view:setAnchorBottom(true)
    view:setVisible(false)
    self:addChild(view)
    self.views[id] = view
    return view
end

function OATerminalWindow:activate(id)
    self.blink[id] = nil
    if self.activeId == id and self.views[id] then return end
    for vid, view in pairs(self.views) do
        if vid ~= id then view:setVisible(false) end
    end
    self.activeId = id
    local view = self:view(id)
    view:setVisible(true)
    self:refresh()
end

-- A tab with something new to look at blinks until it is shown (the one on show has nothing to blink for). The one
-- way to draw attention to a tab: the dots call it when a tab's mark turns new, a part may call it for its own news
-- (the field terminal's first open).
function OATerminalWindow:blinkTab(id)
    if id ~= self.activeId then self.blink[id] = true end
end

-- Which screen of a tab with sub-tabs is on show (nil for a tab without, or not made yet).
function OATerminalWindow:subOn(id)
    local view = self.views[id]
    return view and view.sub or nil
end

-- The shop tab opened on an entry's card (the '상점에서 보기' buttons of the other tabs).
function OATerminalWindow:showShopEntry(entryId)
    self:activate("shop")
    local view = self.views.shop
    if view and view.showEntry then view:showEntry(entryId) end
end

-- The dots of the tabs, worked out again when the record changes (not every frame). A tab whose dot turns new blinks
-- (the first time too: what was new when the window opened).
function OATerminalWindow:updateMarks(record)
    local marks = {}
    for _, id in ipairs(Terminal.ORDER) do
        marks[id] = Terminal.mark(id, record)
        if marks[id] == "new" and self.marks[id] ~= "new" then self:blinkTab(id) end
    end
    self.marks = marks
end

-- The tab on show has been looked at: what its dot waits for is kept as seen (each value is sent once; the record
-- answers with it).
function OATerminalWindow:markSeen(record)
    if not record then return end
    for _, pair in ipairs(Terminal.seenPairs(self.activeId, record, self)) do
        if Terminal.seenValue(record, pair.key) ~= pair.value and self.told[pair.key] ~= pair.value then
            self.told[pair.key] = pair.value
            OA.Sync.send(self.character, "terminalSeen", { key = pair.key, value = pair.value })
        end
    end
end

-- Redraws what is on show: the dots, then the active tab.
function OATerminalWindow:refresh()
    self.atX, self.atY = self.character:getX(), self.character:getY()
    local record = OA.Client.record(self.character)
    self:updateMarks(record)
    local view = self.views[self.activeId]
    if view and view.refresh then view:refresh() end
    self:markSeen(record)
end

function OATerminalWindow:prerender()
    local p = self.palette
    local th = self:titleBarHeight()
    UI.fill(self, 0, 0, self.width, self.height, p.bg, p.bgAlpha)
    UI.fill(self, 0, 0, self.width, th, p.title)
    UI.textCentre(self, self.title, self.width / 2, (th - UI.fontHeightPx()) / 2, p.text)
    UI.fill(self, 0, th - 1, self.width, 1, p.border)
    if p.scanlines and self.scanline then
        local top = th + UI.px(self.tabHeight)
        local rh = self:resizeWidgetHeight()
        self:drawTextureTiled(self.scanline, 0, top, self.width, self.height - top - rh, p.text[1], p.text[2], p.text[3], 0.07)
    end
end

function OATerminalWindow:render()
    local p = self.palette
    local rh = self:resizeWidgetHeight()
    local w, h = self.width, self.height
    UI.fill(self, 0, h - rh, w, 1, p.border, 0.6)
    for i = 0, 2 do
        for j = 0, i do UI.fill(self, w - 5 - 4 * j, h - rh + 3 + 4 * (2 - i), 2, 2, p.dim) end
    end
    UI.frame(self, 0, 0, w, h, p.border)
end

-- How far (squares) the player walks before the directions on show are worked out again (DESIGN-terminal 6.5).
OATerminalWindow.MOVED = 10

-- Every half second or so: the terminal still stands, the player is still near it and it still has power; a player
-- who has walked a few squares gets the directions again.
function OATerminalWindow:update()
    ISCollapsableWindow.update(self)
    -- Another window worked the scale out again from a font that changed: this one was made with the old one.
    if self.scale ~= UI.S then return self:close() end
    self.ticks = (self.ticks or 0) + 1
    if self.ticks < 30 then return end
    self.ticks = 0
    local px, py = self.character:getX(), self.character:getY()
    if self.atX then
        local dx, dy = px - self.atX, py - self.atY
        if dx * dx + dy * dy > OATerminalWindow.MOVED * OATerminalWindow.MOVED then self:refresh() end
    end
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
    -- A tab may keep something as the window goes (the folder's typing).
    for _, view in pairs(self.views or {}) do
        if view.onWindowClose then view:onWindowClose() end
    end
    OATerminalWindow.instances[self.playerNum] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

-- The window's default and smallest sizes in pixels: the design sizes times the scale, kept to a share of the screen.
function OATerminalWindow.sizes()
    local core = getCore()
    local share = OATerminalWindow.SCREEN_SHARE
    local maxW, maxH = math.floor(core:getScreenWidth() * share), math.floor(core:getScreenHeight() * share)
    local W = OATerminalWindow
    return math.min(UI.px(W.WIDTH), maxW), math.min(UI.px(W.HEIGHT), maxH),
        math.min(UI.px(W.MIN_WIDTH), maxW), math.min(UI.px(W.MIN_HEIGHT), maxH)
end

-- `tier` is "crude" or "field": which terminal the window is open at.
function OATerminalWindow:new(character, x, y, z, tier)
    UI.refreshScale()
    local width, height, minW, minH = OATerminalWindow.sizes()
    local sx = (getCore():getScreenWidth() - width) / 2
    local sy = (getCore():getScreenHeight() - height) / 2
    local o = ISCollapsableWindow:new(sx, sy, width, height)
    setmetatable(o, self)
    self.__index = self
    o.tier = tier
    o.scale = UI.S
    o.palette = UI.palette(tier)
    o.scanline = getTexture(SCANLINE)
    local record = OA.Client.record(character)
    o.title = getText("IGUI_OA_Terminal_Title", string.format("%04d", record and record.number or 0))
    o.character = character
    o.playerNum = character:getPlayerNum()
    o.tx, o.ty, o.tz = x, y, z
    o.marks = {}
    o.blink = {}
    o.told = {}
    o:setResizable(true)
    o.minimumWidth, o.minimumHeight = minW, minH
    return o
end

-- Opens the window for a character at the terminal on x, y, z (one already open closes first).
function Terminal.open(character, x, y, z)
    local playerNum = character:getPlayerNum()
    local window = OATerminalWindow.instances[playerNum]
    if window then
        window:close()
    end
    local square = getCell():getGridSquare(x, y, z)
    local object = square and Objects.find(square, Objects.TERMINAL)
    local tier = object and Objects.isUpgraded(object) and "field" or "crude"
    window = OATerminalWindow:new(character, x, y, z, tier)
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
OA.Sync.listen("story", onChanged)
OA.Sync.listen("missions", onChanged)
OA.Sync.listen("all", function() onChanged(nil) end)

return OATerminalWindow
