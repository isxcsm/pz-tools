-- The communication terminal's window (DESIGN-terminal 1): five tabs, status, shop, delivery, missions and comms, drawn in
-- the palette of the terminal it is open at (the crude one built from the kit, or the field terminal ordered from the
-- shop). The part that owns a tab gives its view with OA.Terminal.addTab. The window opens on the status tab every
-- time, when the using action completes (OA.Terminal.open), and shows the player's own record, redrawn when the
-- record changes. Every open starts with a short boot sequence over the body (Trade/BootSeq, Trade/TerminalBoot)
-- and ends with the tabs fading in; the window is usable from the start of the fade.
require "ISUI/ISCollapsableWindow"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/Terminal"
require "OperationAcorn/Trade/Things"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/BootSeq"
require "OperationAcorn/Trade/TerminalBoot"
require "OperationAcorn/Trade/TerminalStatic"
local OA = OperationAcorn
local Trade, Terminal, UI = OA.Trade, OA.Terminal, OA.Trade.UI
local Objects, Things = Trade.Objects, Trade.Things
local Seq = Trade.BootSeq

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
local BLACK = { 0, 0, 0 }

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

-- The strip of the tabs under the title bar: the crude terminal's are outlined green boxes, the field
-- terminal's sit on an olive band with an amber line over the chosen one. A dot by a name is something not seen yet
-- (amber, pulsing until the tab is looked at) or a state to deal with (red); a tab that has something new to look at
-- also blinks (OATerminalWindow:blinkTab) until it is shown. What it shows is the window's (the tab on show, the dots,
-- the blinks): each change of it is written to the strip too (OATerminalWindow:tabsChanged), which PZ Optimization
-- watches, so the strip is drawn afresh at once.
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
    local slots, n = self.slots, 0
    local pulse = math.sin(getTimestampMs() / 220)
    local mx = self:isMouseOver() and self:getMouseX() or -1
    for _, id in ipairs(Terminal.ORDER) do
        local name, tw = self.labels[id].name, self.labels[id].w
        local on = id == w.activeId
        -- a tab under the mouse lights up, a clicked one flashes (Trade/UI hover and press lights)
        local k = UI.hoverLight(self, id, not on and mx >= x and mx < x + tw)
        local f = UI.flashLevel(self, id)
        if p.tabStrip then
            if on then
                UI.fill(self, x, 2, tw, h - 2, p.bg)
                UI.fill(self, x, 2, tw, 2, p.value)
            elseif k > 0 then
                UI.fill(self, x, 2, tw, h - 2, p.bg, 0.6 * k)
                UI.fill(self, x, h - 3, tw, 2, p.value, 0.6 * k)
            end
            if f > 0 then UI.fill(self, x, 2, tw, h - 2, p.value, 0.25 * f) end
            UI.textCentre(self, name, x + tw / 2, (h - fh) / 2 + 1, (on or k > 0.5) and p.value or p.text)
        else
            if on then
                UI.fill(self, x, 3, tw, h - 3, p.sel, 0.18)
                UI.frame(self, x, 3, tw, h - 2, p.text)
                UI.fill(self, x + 1, h - 1, tw - 2, 1, p.bg)
            else
                if k > 0 then UI.fill(self, x, 4, tw, h - 5, p.sel, 0.1 * k) end
                UI.frame(self, x, 4, tw, h - 5, p.border)
                if k > 0 then UI.frame(self, x, 4, tw, h - 5, p.text, 0.6 * k) end
            end
            if f > 0 then UI.fill(self, x, 3, tw, h - 3, p.sel, 0.3 * f) end
            UI.textCentre(self, name, x + tw / 2, (h - fh) / 2 + 1, (on or k > 0.5) and p.bright or p.dim)
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
        n = n + 1
        local slot = slots[n]
        if not slot then
            slot = {}
            slots[n] = slot
        end
        slot.id, slot.x, slot.w = id, x, tw
        x = x + tw + 3
    end
    for i = #slots, n + 1, -1 do slots[i] = nil end
    UI.fill(self, 0, h - 1, self.width, 1, p.border)
end

function OATerminalTabs:onMouseDown(x, y)
    for _, slot in ipairs(self.slots) do
        if x >= slot.x and x < slot.x + slot.w then
            UI.flash(self, slot.id)
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
    -- Only the close box stays of the vanilla title bar, drawn in the palette and our face.
    for _, b in ipairs({ self.pinButton, self.collapseButton, self.infoButton }) do
        if b then b:setVisible(false) end
    end
    UI.closeBox(self, p)
    local th = self:titleBarHeight()
    -- the terminal's static, behind everything the window holds
    self.static = OATerminalStatic.attach(self, th, self:resizeWidgetHeight())
    -- The strip and the views are ours, in design units: the title bar's pixels are given to them as such.
    self.tabHeight = UI.fontHeight() + 6
    self.strip = OATerminalTabs:new(0, UI.dp(th), UI.dp(self.width), self.tabHeight, self)
    self.strip:initialise()
    self.strip:setAnchorRight(true)
    self:addChild(self.strip)
    self.views = {}
    self:activate(self:openingTab())
    self:startBoot()
end

-- The tab the window opens on: the one with something waiting to play (a call), unless this is a field terminal's
-- first open (its board is on the status tab).
function OATerminalWindow:openingTab()
    if self.firstBoot then return "status" end
    return Terminal.opening(OA.Client.record(self.character))
end

-- The boot sequence ----------------------------------------------------------------------------------------------

-- The console goes over the strip and the body, from under the title bar to above the resize bar (design units).
-- Every frame, before the UI draws (Trade/UI live, so that it shows on time with PZ Optimization too): the boot while
-- it runs, then the crude terminal's weak signal while the window is open (Seq.weakSignal, from the end of the boot);
-- what the window shows, nil when nothing on it moves by itself any more (the field terminal once booted). A screen
-- coming up (OATerminalWindow:reveal) is drawn afresh every frame while it lasts.
local function ownFrame(window, now)
    if window.boot then
        local look = window:bootTick(now)
        if look ~= nil then return look end
    end
    if window.tier ~= "crude" then return nil end
    window.signalFrom = window.signalFrom or now
    local fade, step, jolt, through = Seq.weakSignal(now - window.signalFrom)
    window.signalFade, window.signalStep, window.signalThrough = fade, step, through
    -- the jolt moves the window itself a pixel or two, and back; never while the player drags it (a jolt then is
    -- forgotten: at most a pixel or two off, once)
    if window.moving then
        window.joltX = 0
    else
        local dx = jolt and math.floor(jolt * UI.S * 0.75 + 0.5) or 0
        if dx ~= (window.joltX or 0) then
            window:setX(window:getX() - (window.joltX or 0) + dx)
            window.joltX = dx
        end
    end
    return fade and step + 1 or 0
end

local function liveFrame(window, now)
    local look = ownFrame(window, now)
    if window:revealTick(now) then
        window.revealCount = (window.revealCount or 0) + 1
        return -window.revealCount
    end
    return look
end
OATerminalWindow.liveFrame = liveFrame

-- Switching screens ------------------------------------------------------------------------------------------------
-- A screen just put on show (a tab, a sub-tab's screen) comes up out of the background over REVEAL_MS: a veil of the
-- background over it thins out, thicker below a faint line that runs down it once (eased out), so that it reads as
-- drawn in from the top. The window draws it over what it holds; clicks reach the screen at once. Not in the boot,
-- whose own fade brings the first screen up. A part of a screen can come up alone (a card's detail).
OATerminalWindow.REVEAL_MS = 340

local function within(el, outer)
    while el do
        if el == outer then return true end
        el = el.parent
    end
    return false
end

local function onShow(el)
    while el do
        if not el:isVisible() then return false end
        el = el.parent
    end
    return true
end

-- `el` comes up, or the part x, y, w, h of it (its own units).
function OATerminalWindow:reveal(el, x, y, w, h)
    if self.boot or not el then return end
    local now = getTimestampMs()
    local r = self.revealing
    -- a tab opened on one of its screens: the whole tab comes up
    if r and r.at == now and not r.w and within(el, r.el) then return end
    self.revealing = { el = el, at = now, x = x, y = y, w = w, h = h }
    self.revealT = 0
    UI.live(self, liveFrame)
end

-- How far the screen coming up is (0 to 1) at `now`, nil when none is (over, or taken off the screen).
function OATerminalWindow:revealTick(now)
    local r = self.revealing
    if not r then return nil end
    local t = (now - r.at) / OATerminalWindow.REVEAL_MS
    if t >= 1 or not onShow(r.el) then
        self.revealing, self.revealT = nil, nil
        return nil
    end
    self.revealT = math.max(0, t)
    return self.revealT
end

-- The veil, in the window's pixels over the screen's place (kept to the body).
function OATerminalWindow:drawReveal()
    local r, t = self.revealing, self.revealT
    local jo, ej = self.javaObject, r and r.el.javaObject
    if not (t and jo and ej) then return end
    local x, y = ej:getAbsoluteX() - jo:getAbsoluteX(), ej:getAbsoluteY() - jo:getAbsoluteY()
    local w, h = ej:getWidth(), ej:getHeight()
    if r.w then
        x, y, w, h = x + UI.px(r.x), y + UI.px(r.y), UI.px(r.w), UI.px(r.h)
    end
    local top = math.max(y, self:titleBarHeight())
    local bottom = math.min(y + h, self.height - self:resizeWidgetHeight())
    if bottom <= top then return end
    local p = self.palette
    local u = 1 - t
    local line = top + math.floor((1 - u * u) * (bottom - top))
    if line > top then UI.fill(self, x, top, w, line - top, p.bg, 0.55 * u) end
    if line < bottom then
        UI.fill(self, x, line, w, bottom - line, p.bg, 0.92 * u)
        UI.fill(self, x, line, w, 1, p.text, 0.3 * u)
    end
end

function OATerminalWindow:startBoot()
    local run = self.boot
    if not run then return end
    UI.live(self, liveFrame)
    if #run.lines == 0 then return end
    local top = UI.dp(self:titleBarHeight())
    local bottom = UI.dp(self:resizeWidgetHeight())
    local overlay = OATerminalBoot:new(0, top, UI.dp(self.width), UI.dp(self.height) - top - bottom, self, run)
    overlay:initialise()
    overlay:instantiate()
    overlay:setAnchorRight(true)
    overlay:setAnchorBottom(true)
    self:addChild(overlay)
    self.bootOverlay = overlay
end

-- Each frame while the sequence lasts: when the console is over the panel comes off and the status tab hears of it,
-- then the fade-in is the window's own black over the tabs, until it is done and the run is let go. What the console
-- shows is written to it (Seq.look); gives what the window shows (the console's look, then the fade), nil when over.
function OATerminalWindow:bootTick(now)
    local run = self.boot
    local phase, shown, t, e = Seq.state(run, now or getTimestampMs())
    if phase == "console" or phase == "collapse" then
        local look = Seq.look(run, phase, shown, e)
        if self.bootOverlay then self.bootOverlay.look = look end
        return look
    end
    if not self.consoleDone then
        self.consoleDone = true
        if self.bootOverlay then
            self:removeChild(self.bootOverlay)
            self.bootOverlay = nil
        end
        for _, view in pairs(self.views) do
            if view.consoleOver then view:consoleOver() end
        end
        -- something came to play while the console ran (the first contact): the window goes to it
        local opening = self:openingTab()
        if opening ~= self.activeId and self.activeId == "status" then self:activate(opening) end
    end
    if phase == "fade" then
        self.bootAlpha = 1 - t
        return self.bootAlpha
    end
    self.boot, self.bootAlpha = nil, nil
    -- the keys stay with a tab that takes some now (a call that started in the fade)
    local view = self.views[self.activeId]
    self:setWantKeyEvents(view ~= nil and view.wantsKeys ~= nil and view:wantsKeys())
    return nil
end

-- A click on the console, or a key: the fade-in starts now.
function OATerminalWindow:bootSkip()
    if not self.boot then return end
    Seq.skip(self.boot, getTimestampMs())
    self:bootTick()
end

function OATerminalWindow:onKeyPress(key)
    if self.boot then return self:bootSkip() end
    local view = self.views[self.activeId]
    if view and view.onKey then view:onKey(key) end
end

-- The keys the tab on show takes (they do not reach the game).
function OATerminalWindow:isKeyConsumed(key)
    local view = self.views[self.activeId]
    return view ~= nil and view.consumesKey ~= nil and view:consumesKey(key)
end

-- The bars are as high as our Small face (the game's would follow its own font).
function OATerminalWindow:titleBarHeight() return UI.titleBarHeight() end
function OATerminalWindow:resizeWidgetHeight() return UI.resizeWidgetHeight() end

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

-- The tab on show, a dot or a blink changed: a count written to the strip (see OATerminalTabs).
function OATerminalWindow:tabsChanged()
    local strip = self.strip
    if strip then strip.rev = (strip.rev or 0) + 1 end
end

function OATerminalWindow:activate(id)
    if self.blink[id] then
        self.blink[id] = nil
        self:tabsChanged()
    end
    if self.activeId == id and self.views[id] then return end
    local leaving = self.activeId and self.views[self.activeId]
    if leaving and leaving.onTabLeave then leaving:onTabLeave() end
    for vid, view in pairs(self.views) do
        if vid ~= id then view:setVisible(false) end
    end
    local before = self.activeId
    self.activeId = id
    self:tabsChanged()
    local view = self:view(id)
    view:setVisible(true)
    if before then self:reveal(view) end
    self:refresh()
end

-- A tab with something new to look at blinks until it is shown (the one on show has nothing to blink for). The one
-- way to draw attention to a tab: the dots call it when a tab's mark turns new, a part may call it for its own news
-- (the field terminal's first open).
function OATerminalWindow:blinkTab(id)
    if id ~= self.activeId and not self.blink[id] then
        self.blink[id] = true
        self:tabsChanged()
    end
end

-- Which screen of a tab with sub-tabs is on show (nil for a tab without, or not made yet).
function OATerminalWindow:subOn(id)
    local view = self.views[id]
    return view and view.sub or nil
end

-- The shop tab opened on an entry's card (the '주문 탭에서 보기' buttons of the other tabs).
function OATerminalWindow:showShopEntry(entryId)
    self:activate("shop")
    local view = self.views.shop
    if view and view.showEntry then view:showEntry(entryId) end
end

-- The dots of the tabs, worked out again when the record changes (not every frame). A tab whose dot turns new blinks
-- (the first time too: what was new when the window opened).
function OATerminalWindow:updateMarks(record)
    local marks = {}
    local changed = false
    for _, id in ipairs(Terminal.ORDER) do
        marks[id] = Terminal.mark(id, record)
        if marks[id] ~= self.marks[id] then changed = true end
        if marks[id] == "new" and self.marks[id] ~= "new" then self:blinkTab(id) end
    end
    self.marks = marks
    if changed then self:tabsChanged() end
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
    UI.windowTitle(self, self.title, p.text)
    UI.fill(self, 0, th - 1, self.width, 1, p.border)
    if p.scanlines and self.scanline then
        local top = th + UI.px(self.tabHeight)
        local rh = self:resizeWidgetHeight()
        local c = p.text
        self:drawTextureTiled(self.scanline, 0, top, self.width, self.height - top - rh, c[1], c[2], c[3], 0.07)
    end
end

-- The crude terminal's weak signal (Seq.weakSignal), over the strip and the body (the tabs still take clicks): the
-- picture fades towards the background in bands of their own depth that change with the spell's step, the static
-- thickens over it, a lighter band rolls down once, and a few bright lines of interference cross it.
OATerminalWindow.WEAK_BANDS = 9

function OATerminalWindow:drawWeakSignal(th, rh)
    local p = self.palette
    local w, bodyH = self.width, self.height - th - rh
    local fade, step = self.signalFade, self.signalStep
    local k = fade / Seq.WEAK_FADE
    local n = OATerminalWindow.WEAK_BANDS
    for b = 0, n - 1 do
        local y0, y1 = math.floor(b * bodyH / n), math.floor((b + 1) * bodyH / n)
        local depth = 0.55 + 0.45 * ((step * 7 + b * 13) % 5) / 4
        UI.fill(self, 0, th + y0, w, y1 - y0, p.bg, fade * depth)
    end
    local static = self.static
    local tex = static and static.tiles[step % 2 + 1]
    if tex then
        local shift = (step * 37) % OATerminalStatic.TILE
        self:setStencilRect(0, th, w, bodyH)
        self:drawTextureTiled(tex, 0, th - shift, w, bodyH + shift, p.text[1], p.text[2], p.text[3], 0.32 * k)
        UI.unclip(self, 0, th, w, bodyH)
    end
    local rollH = math.max(8, math.floor(bodyH / 7))
    local rollY = math.floor((self.signalThrough or 0) * (bodyH + rollH)) - rollH
    if rollY < bodyH then
        local top = math.max(0, rollY)
        UI.fill(self, 0, th + top, w, math.min(bodyH, rollY + rollH) - top, p.text, 0.05 * k)
    end
    for j = 1, 3 do
        local seed = step * 7 + j * 13
        local a = (0.16 + 0.08 * (seed % 3)) * k
        UI.fill(self, 0, th + (seed * 97) % math.max(1, bodyH - 6), w, 1 + seed % 3, p.text, a)
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
    -- a field terminal's static, over its screen (OATerminalStatic.OVER; the boot's console draws its own)
    if self.static and not self.bootOverlay and OATerminalStatic.OVER[self.tier] then
        OATerminalStatic.drawOver(self.static, self)
    end
    -- The fade-in: black over the strip and the body, thinning out (over the tabs, which take clicks through it).
    local fade = self.bootAlpha
    if fade and fade > 0 then
        local th = self:titleBarHeight()
        UI.fill(self, 0, th, w, h - th - rh, BLACK, fade)
    end
    if self.revealT then self:drawReveal() end
    if self.signalFade then self:drawWeakSignal(self:titleBarHeight(), rh) end
    UI.frame(self, 0, 0, w, h, p.border)
end

-- How far (squares) the player walks before the directions on show are worked out again (DESIGN-terminal 6.5).
OATerminalWindow.MOVED = 10

-- Every half second or so: the terminal still stands, the player is still near it and it still has power; a player
-- who has walked a few squares gets the directions again.
function OATerminalWindow:update()
    ISCollapsableWindow.update(self)
    -- Another window worked the scale or the faces out again (the font or the screen changed): this one was made
    -- with the old ones.
    if self.era ~= UI.era then return self:close() end
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
    if not Objects.powered(square, object) then
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
    UI.fadeOut(self)
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

-- Whether this is the first open of a field terminal (its modData OA_Booted is not set yet): sets it, so that it is the
-- first once. The crude terminal has no first boot: an upgrade is the same object, and its first open as a field
-- terminal is the one that shows what the field terminal opened.
function OATerminalWindow.claimFirst(object, tier)
    if tier ~= "field" or not object then return false end
    local data = object:getModData()
    if data.OA_Booted then return false end
    data.OA_Booted = true
    if isClient() then object:transmitModData() end
    return true
end

-- Whether this is the terminal's first open at all, either tier (its modData OA_Opened is not set yet): sets it. The
-- boot of a first open plays out whole; from the next open on a click skips it.
function OATerminalWindow.claimOpened(object)
    if not object then return false end
    local data = object:getModData()
    if data.OA_Opened then return false end
    data.OA_Opened = true
    if isClient() then object:transmitModData() end
    return true
end

-- `tier` is "crude" or "field": which terminal the window is open at. `first`: its first open as a field terminal (the
-- long boot, then the board of what it opened). `locked`: a boot that cannot be skipped (a first open).
function OATerminalWindow:new(character, x, y, z, tier, first, locked)
    UI.refreshScale()
    local width, height, minW, minH = OATerminalWindow.sizes()
    local sx = (getCore():getScreenWidth() - width) / 2
    local sy = (getCore():getScreenHeight() - height) / 2
    local o = ISCollapsableWindow:new(sx, sy, width, height)
    setmetatable(o, self)
    self.__index = self
    o.tier = tier
    o.era = UI.era
    o.palette = UI.palette(tier)
    o.scanline = getTexture(SCANLINE)
    local record = OA.Client.record(character)
    o.title = getText("IGUI_OA_Terminal_Title", string.format("%04d", record and record.number or 0))
    o.character = character
    o.playerNum = character:getPlayerNum()
    o.tx, o.ty, o.tz = x, y, z
    o.firstBoot = first and true or false
    o.boot = Seq.new(first, tier == "crude")
    o.boot.locked = locked and true or false
    o.wantKeyEvents = #o.boot.lines > 0
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
    local opened = OATerminalWindow.claimOpened(object)
    local first = OATerminalWindow.claimFirst(object, tier)
    window = OATerminalWindow:new(character, x, y, z, tier, first, opened or first)
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
OA.Sync.listen("comms", onChanged)
OA.Sync.listen("all", function() onChanged(nil) end)

return OATerminalWindow
