-- The terminal's scale (client Trade/UI.lua, DESIGN-terminal 1.2): the screens are laid out in design units made for a
-- 16 pixel Small font, and the scale (the Small font's height / 16) is put on at the boundary with the game. Here: the
-- scale itself, the classes made with UI.scaled against a stand-in of the game's element and its Java object (what
-- reaches the game is in pixels, what the code sees is in design units, and at scale 1 nothing changes), the game's
-- widgets placed inside ours, the status screens' baked drawing steps, the window's sizes, and the screens laid out
-- with the fonts of 16, 19, 26 and 38 pixel screens: no two texts on top of each other, every text inside its screen.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Terminal"
local OA = OperationAcorn

-- The game's fonts at the four sizes the font option gives (the Korean line heights; Medium at 16 px is a guess).
local FONTS = {
    [16] = { S = 16, M = 22 },
    [19] = { S = 19, M = 29 },
    [26] = { S = 26, M = 33 },
    [38] = { S = 38, M = 45 },
}
local font

-- A text's width in pixels: 7 per character at 16 px, growing with the font.
local function stubFonts(px)
    font = FONTS[px]
    _G.UIFont = { Small = "S", Medium = "M", Code = "C", NewSmall = "S" }
    _G.getTextManager = function()
        return {
            getFontHeight = function(_, f) return font[f] or font.S end,
            MeasureStringX = function(_, f, text) return #tostring(text) * 7 * (font[f] or font.S) / 16 end,
        }
    end
end

-- The Java object of an element: its place and size in pixels, and what the game was asked to draw.
local function javaObject()
    local j = { x = 0, y = 0, w = 0, h = 0 }
    function j:setX(v) self.x = v end
    function j:setY(v) self.y = v end
    function j:setWidth(v) self.w = v end
    function j:setHeight(v) self.h = v end
    function j:getX() return self.x end
    function j:getY() return self.y end
    function j:getWidth() return self.w end
    function j:getHeight() return self.h end
    -- its place on the screen: where it was put, under its parent's (the tests set ax, ay)
    function j:getAbsoluteX() return (self.ax or 0) + self.x end
    function j:getAbsoluteY() return (self.ay or 0) + self.y end
    function j:getXScroll() return 0 end
    function j:getYScroll() return self.yscroll or 0 end
    for _, name in ipairs({ "setAnchorLeft", "setAnchorRight", "setAnchorTop", "setAnchorBottom", "setWantKeyEvents",
        "setConsumeMouseEvents", "setWantExtraMouseEvents", "setForceCursorVisible", "setVisible" }) do
        j[name] = function() end
    end
    return j
end

-- The game's element as far as the classes use it: the derive and new of ISBaseObject, ISUIElement's instantiate,
-- place and size, and drawing that records the pixels it is given.
local function gameClasses()
    local E = {}
    E.__index = E
    function E:derive(name)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o.Type = name
        return o
    end
    function E:new(x, y, w, h)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o.x, o.y, o.width, o.height = x, y, w, h
        o.anchorLeft, o.anchorTop = true, true
        o.children, o.drawn = {}, {}
        o.visible = true
        return o
    end
    function E:initialise() self.children = {} end
    function E:instantiate()
        local j = javaObject()
        self.javaObject = j
        j:setX(self.x); j:setY(self.y); j:setHeight(self.height); j:setWidth(self.width)
        self:createChildren()
    end
    function E:createChildren() end
    function E:addChild(c)
        if not c.javaObject then c:instantiate() end
        c.parent = self
        self.children = self.children or {}
        self.children[#self.children + 1] = c
    end
    function E:removeChild() end
    function E:setX(x) self.x = x; if self.javaObject then self.javaObject:setX(x) end end
    function E:setY(y) self.y = y; if self.javaObject then self.javaObject:setY(y) end end
    function E:setWidth(w) self.width = w; if self.javaObject then self.javaObject:setWidth(w) end end
    function E:setHeight(h) self.height = h; if self.javaObject then self.javaObject:setHeight(h) end end
    function E:getX() return self.javaObject:getX() end
    function E:getY() return self.javaObject:getY() end
    function E:getWidth() return self.javaObject:getWidth() end
    function E:getHeight() return self.javaObject:getHeight() end
    function E:getMouseX() return self.mousePx and self.mousePx[1] or 0 end
    function E:getMouseY() return self.mousePx and self.mousePx[2] or 0 end
    function E:isMouseOver() return self.mousePx ~= nil end
    function E:setVisible(v) self.visible = v end
    function E:getIsVisible() return self.visible end
    function E:setAnchorRight(v) self.anchorRight = v end
    function E:setAnchorBottom(v) self.anchorBottom = v end
    function E:setAnchorLeft(v) self.anchorLeft = v end
    function E:setAnchorTop(v) self.anchorTop = v end
    local function rec(kind)
        return function(self, ...)
            self.drawn = self.drawn or {}
            self.drawn[#self.drawn + 1] = { kind, ... }
        end
    end
    E.drawRect, E.drawRectBorder = rec("rect"), rec("frame")
    E.drawText, E.drawTextCentre, E.drawTextRight = rec("text"), rec("centre"), rec("right")
    E.drawTextureScaledAspect, E.drawTextureScaled, E.drawTextureTiled = rec("icon"), rec("texture"), rec("tiled")
    E.setStencilRect, E.clearStencilRect = rec("clip"), rec("unclip")
    local Panel = E:derive("ISPanel")
    local Button = Panel:derive("ISButton")
    function Button:new(x, y, w, h, title, target, onclick)
        local o = Panel.new(self, x, y, w, h)
        o.title, o.target, o.onclick, o.enable = title, target, onclick, true
        return o
    end
    function Button:setTitle(t) self.title = t end
    local List = Panel:derive("ISScrollingListBox")
    function List:new(x, y, w, h)
        local o = Panel.new(self, x, y, w, h)
        o.items = {}
        return o
    end
    function List:addItem(name, item) self.items[#self.items + 1] = { text = name, item = item, height = self.itemheight } end
    function List:clear() self.items = {} end
    function List:setOnMouseDownFunction(target, fn) self.onPick = { target, fn } end
    function List:getYScroll() return 0 end
    _G.ISUIElement, _G.ISPanel, _G.ISButton, _G.ISScrollingListBox = E, Panel, Button, List
    _G.ISLabel, _G.ISRichTextPanel, _G.ISComboBox, _G.ISCollapsableWindow = Panel:derive("ISLabel"),
        Panel:derive("ISRichTextPanel"), Panel:derive("ISComboBox"), Panel:derive("ISCollapsableWindow")
    _G.UIElement = { new = function() return javaObject() end }
end

local function loadUI(px)
    stubFonts(px or 16)
    gameClasses()
    _G.PZToolsAPI = nil
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Trade/UI")
    require = real
    if not ok then error(err, 0) end
    return OA.Trade.UI
end

-- Our rich text panel (Trade/RichText) on the stand-in classes.
local function loadRich()
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Trade/RichText")
    require = real
    if not ok then error(err, 0) end
    return OARichText
end

-- A class of ours made with UI.scaled, as the terminal's are.
local function ourClass(UI)
    local C = ISPanel:derive("OATestPanel")
    function C:onMouseDown(x, y) self.down = { x, y } return true end
    function C:onMouseMove(dx, dy) self.moved = { dx, dy } end
    UI.scaled(C, ISPanel)
    return C
end

local function last(el) return el.drawn[#el.drawn] end

-- A table's own field (Kahlua's rawget looks through __index).
local function own(t, key)
    for k, v in pairs(t) do
        if k == key then return v end
    end
    return nil
end

-- The scale -------------------------------------------------------------------------------------------------------

test("the scale is the Small font's height over 16, and never under 1", function()
    local UI = loadUI(26)
    eq(UI.S, 1, "1 until a window works it out")
    UI.refreshScale()
    eq(UI.S, 26 / 16)
    font = FONTS[19]
    UI.refreshScale()
    eq(UI.S, 19 / 16)
    font = { S = 14, M = 20 }
    UI.refreshScale()
    eq(UI.S, 1, "a font smaller than the design's keeps the design's sizes")
end)

test("text is measured in design units: the Small font is 16 high at any scale", function()
    local UI = loadUI(26)
    UI.refreshScale()
    eq(UI.fontHeight(), 16)
    eq(UI.fontHeightPx(), 26)
    near(UI.fontHeight(UIFont.Medium), 33 / 1.625, 1e-9)
    eq(UI.textWidth("abcd"), 28, "the same width as at 16 px")
    eq(UI.textWidthPx("abcd"), 28 * 1.625)
    eq(UI.buttonHeight(), 26)
    eq(UI.fit("abcdefghij", 40), "ab...", "cut by its design width")
end)

-- The classes ------------------------------------------------------------------------------------------------------

test("at scale 1 a scaled class is the game's class: nothing is put between", function()
    local UI = loadUI(16)
    local C = ourClass(UI)
    UI.refreshScale()
    eq(UI.S, 1)
    for _, name in ipairs({ "instantiate", "drawRect", "drawText", "setX", "getWidth", "getMouseX", "setStencilRect" }) do
        eq(own(C, name), nil, name)
    end
    local el = C:new(10.5, 20, 100, 50)
    el:initialise()
    el:instantiate()
    eq(el.javaObject.x, 10.5)
    eq(own(el, "onMouseDown"), nil, "the game calls the class's handler")
    el:drawRect(1.5, 2, 3, 4, 1, 0, 0, 0)
    local d = last(el)
    eq(d[2], 1.5); eq(d[3], 2); eq(d[4], 3); eq(d[5], 4)
end)

test("a scaled element: design units in the Lua fields and the code, pixels for the game", function()
    local UI = loadUI(26)
    local C = ourClass(UI)
    UI.refreshScale()
    local el = C:new(10, 20, 100, 50)
    el:initialise()
    el:instantiate()
    local j = el.javaObject
    eq(j.x, 16); eq(j.y, 33); eq(j.w, 163); eq(j.h, 81)
    eq(el:getX(), 10); eq(el:getWidth(), 100, "the number it was given, not 163 / 1.625")
    el:setWidth(200)
    eq(j.w, 325); eq(el.width, 200); eq(el:getWidth(), 200)
    -- the game widens it (an anchor following the window): the width is read back from the pixels
    j.w = 390
    eq(el:getWidth(), 240)
    eq(el:getRight(), 250)
    -- the mouse: the game's handlers get pixels, the class's get design units
    el.onMouseDown(el, 26, 52)
    eq(el.down[1], 16); eq(el.down[2], 32)
    el.onMouseMove(el, 13, -13)
    eq(el.moved[1], 8); eq(el.moved[2], -8)
    el.mousePx = { 65, 130 }
    eq(el:getMouseX(), 40); eq(el:getMouseY(), 80)
end)

test("a scaled element draws at whole pixels, rectangles by their rounded edges, lines one pixel wide", function()
    local UI = loadUI(26)
    local C = ourClass(UI)
    UI.refreshScale()
    local el = C:new(0, 0, 100, 50)
    el:initialise()
    el:instantiate()
    el:drawRect(10, 10, 20, 1, 1, 0, 0, 0)
    local d = last(el)
    eq(d[2], 16); eq(d[3], 16); eq(d[4], 49 - 16, "to the edge at 30 * 1.625"); eq(d[5], 2)
    -- two rectangles side by side meet
    el:drawRect(30, 10, 20, 1, 1, 0, 0, 0)
    eq(last(el)[2], 49)
    el:drawRectBorder(0, 0, 100, 50, 1, 0, 0, 0)
    d = last(el)
    eq(d[1], "frame"); eq(d[4], 163); eq(d[5], 81)
    UI.text(el, "hello", 7, 3, { 1, 1, 1 })
    d = last(el)
    eq(d[1], "text"); eq(d[2], "hello"); eq(d[3], 11); eq(d[4], 5); eq(d[9], UIFont.Small, "the game's font as it is")
    UI.textCentre(el, "x", 50, 0, { 1, 1, 1 })
    eq(last(el)[3], 81)
    el:drawTextureScaledAspect("tex", 4, 4, 24, 24, 1, 1, 1, 1)
    d = last(el)
    eq(d[1], "icon"); eq(d[3], 7); eq(d[5], 46 - 7)
    el:setStencilRect(0, 0, 100, 50)
    d = last(el)
    eq(d[1], "clip"); eq(d[4], 163); eq(d[5], 81)
end)

test("back at scale 1 the classes are the game's again", function()
    local UI = loadUI(26)
    local C = ourClass(UI)
    UI.refreshScale()
    truthy(own(C, "drawRect"), "scaled")
    function C:getHeight() return 1234 end
    UI.setScale(1)
    eq(own(C, "drawRect"), nil)
    eq(own(C, "instantiate"), nil)
    UI.setScale(2)
    eq(C:getHeight(), 1234, "a method the class has of its own is never taken")
end)

-- The game's widgets inside ours -----------------------------------------------------------------------------------

test("a game widget inside ours is placed from design units; one in a game window is left as it is", function()
    local UI = loadUI(26)
    local C = ourClass(UI)
    UI.refreshScale()
    local tab = C:new(0, 0, 400, 300)
    tab:initialise()
    tab:instantiate()
    local button = ISButton:new(0, 0, 20, 20, "b")
    button:initialise()
    tab:addChild(button)
    UI.place(button, 10, 20, 100, 26)
    eq(button.x, 16); eq(button.y, 33); eq(button.width, 163); eq(button.height, 42)
    UI.place(button, nil, 40, 100, 26)
    eq(button.x, 16, "a nil keeps the place"); eq(button.y, 65)
    -- ours: its own design units
    local inner = C:new(0, 0, 10, 10)
    inner:initialise()
    tab:addChild(inner)
    UI.place(inner, 10, 20, 100, 26)
    eq(inner.x, 10); eq(inner.javaObject.x, 16)
    -- a game window's widget: pixels as given
    local window = ISPanel:new(0, 0, 800, 600)
    window:initialise()
    window:instantiate()
    local other = ISButton:new(0, 0, 20, 20, "b")
    other:initialise()
    window:addChild(other)
    UI.place(other, 10, 20, 100, 26)
    eq(other.x, 10); eq(other.width, 100)
end)

test("a game list inside ours: its rows are drawn in design units on a canvas, its row height in pixels", function()
    local UI = loadUI(26)
    local C = ourClass(UI)
    UI.refreshScale()
    local tab = C:new(0, 0, 400, 300)
    tab:initialise()
    tab:instantiate()
    local seen
    local list = UI.list(tab, 0, 0, 200, 300, function(l, y, item)
        seen = { width = l.width, y = y, palette = l.palette }
        UI.text(l, item.item.text, 8, y + 1, { 1, 1, 1 })
        UI.fill(l, 0, y, l.width, 1, { 1, 1, 1 })
    end)
    eq(list.width, 325, "made in pixels")
    eq(list.fontHgt, 26)
    UI.rowHeight(list, 18)
    eq(list.itemheight, 29)
    list.palette = "p"
    list.height = 487
    list.isMouseOver = function() return false end
    list.doDrawItem(list, 58.5, { item = { text = "row" }, height = 29, index = 2 }, false)
    eq(seen.width, 200, "the canvas's width in design units")
    eq(seen.y, 36, "the row's top in design units")
    eq(seen.palette, "p", "the list's fields show through")
    local text, rule = list.drawn[1], list.drawn[2]
    eq(text[1], "text"); eq(text[3], 13); eq(text[4], 60)
    eq(rule[1], "rect"); eq(rule[4], 325)
    -- the delivery tab's rows: the same through UI.rowPainter, which gives the list the next row's place
    local painter = UI.rowPainter(function(l, y) seen.y2 = y end)
    eq(painter(list, 29, { height = 29 }), 58)
    eq(seen.y2, 29 / 1.625)
end)

test("a rich text panel is ours: its place, size and margins design units in any window", function()
    local UI = loadUI(16)
    loadRich()
    local window = ISPanel:new(0, 0, 400, 300)
    window:initialise()
    window:instantiate()
    local rich = UI.rich(window, 0, 10, 300, 200)
    eq(rich.marginLeft, 8); eq(rich.marginTop, 6); eq(rich.y, 10)
    UI.setScale(1.5)
    rich = UI.rich(window, 0, 10, 300, 200)
    eq(rich.marginLeft, 8, "the margins are design units"); eq(rich.javaObject.y, 15, "the place too, made pixels")
end)

-- The status screens' drawing steps --------------------------------------------------------------------------------

local function loadDraw(px)
    local UI = loadUI(px)
    _G.OATab = ISPanel:derive("OATab")
    function OATab:new(x, y, w, h, window)
        local o = ISPanel.new(self, x, y, w, h)
        o.window = window
        return o
    end
    function OATab:palette() return self.window.palette end
    function OATab:record() return self.window.record end
    function OATab:character() return self.window.character end
    UI.scaled(OATab, ISPanel)
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Trade/StatusDraw")
    require = real
    if not ok then error(err, 0) end
    return UI, OA.Trade.Draw
end

test("a screen's steps are made pixels once; at scale 1 they are the design numbers", function()
    local UI, Draw = loadDraw(16)
    local view = OAStatusView:new(0, 0, 300, 200, { palette = UI.palette("crude") })
    view:initialise()
    view:instantiate()
    local L = Draw.list(view:palette())
    Draw.rect(L, 10.5, 2, 30, 1, { 1, 1, 1 })
    Draw.text(L, "hi", 7.5, 3, { 1, 1, 1 })
    Draw.paint(view, L)
    eq(view.drawn[1][2], 10.5); eq(view.drawn[1][4], 30)
    eq(view.drawn[2][3], 7.5)
    UI.setScale(1.625)
    view.drawn = {}
    Draw.paint(view, L)
    eq(L.scale, 1.625, "baked again for the new scale")
    local r, t = view.drawn[1], view.drawn[2]
    eq(r[2], 17); eq(r[3], 3); eq(r[4], 66 - 17); eq(r[5], 2)
    eq(t[3], 12); eq(t[4], 5)
    -- a step changed after (the helicopter's arrival bar) is made pixels again by itself
    L.ops[1][4] = 60
    Draw.bakeOp(L.ops[1])
    view.drawn = {}
    Draw.paint(view, L)
    eq(view.drawn[1][4], 115 - 17)
end)

test("a tooltip is measured and drawn in design units", function()
    local UI, Draw = loadDraw(26)
    UI.refreshScale()
    local view = OAStatusView:new(0, 0, 300, 200, { palette = UI.palette("crude") })
    view:initialise()
    view:instantiate()
    local tip = Draw.tip(view:palette(), { "abc", "-", "defgh" })
    eq(tip.w, 35 + 14); eq(tip.h, 4 + 16 + 8 + 16 + 4)
    view.drawn = {}
    Draw.paintTip(view, view:palette(), tip, 280, 10)
    local box = view.drawn[1]
    eq(box[2], math.floor((300 - 49) * 1.625 + 0.5), "kept inside the screen, in its design width")
end)

test("a run's seams: a narrow font space widened to a quarter of the line, and no part cut that fits", function()
    local UI, Draw = loadDraw(26)
    UI.refreshScale()
    -- letters 13 pixels wide, a space 4 (the 26 pixel Korean font's); a text measured to its last letter's end
    _G.getTextManager = function()
        return {
            getFontHeight = function() return 26 end,
            MeasureStringX = function(_, _, text)
                local w = 0
                for k = 1, #text do w = w + (string.sub(text, k, k) == " " and 4 or 13) end
                return w
            end,
        }
    end
    UI.setScale(1)
    UI.setScale(1.625)
    eq(UI.spaceWidth(), 4, "a quarter of 16 design units")
    -- a label measured with its space ("합계 " then the sum drawn after it): the space is a full one
    assert(math.abs(UI.textWidth("ab ") - (26 / 1.625 + 4)) < 1e-9, "label width " .. UI.textWidth("ab "))
    assert(math.abs(UI.textWidth(" ") - 4) < 1e-9, "a lone space (a bullet's hang) is a full space " .. UI.textWidth(" "))
    assert(math.abs(UI.textWidth("  ") - 8) < 1e-9, "two spaces")
    eq(UI.textWidth("ab"), 26 / 1.625)
    local L = Draw.list(UI.palette("crude"))
    local drawn = Draw.run(L, { { s = "ab ", c = { 1, 1, 1 } }, { s = "1.5", c = { 1, 1, 1 } } }, 0, 0, 200)
    local texts = {}
    for _, op in ipairs(L.ops) do if op[1] == 3 then texts[#texts + 1] = op end end
    eq(#texts, 2)
    eq(texts[1][2], "ab "); eq(texts[2][2], "1.5", "whole: not cut to \"...\"")
    local before = (13 + 13 + 4) / 1.625
    assert(math.abs(texts[2][3] - (before + 4 - 4 / 1.625)) < 1e-9, "the value after a full space: " .. texts[2][3])
    assert(drawn <= 200)
    -- a width that is the run's own, left as a fraction: nothing is cut
    L = Draw.list(UI.palette("crude"))
    local parts = { { s = "abc " }, { s = "de" }, { s = " f" } }
    Draw.run(L, parts, 0, 0, Draw.runWidth(parts))
    for _, op in ipairs(L.ops) do
        if op[1] == 3 then assert(not string.find(op[2], "%.%.%.$"), "cut: " .. op[2]) end
    end
end)

-- The window ---------------------------------------------------------------------------------------------------------

local function loadWindow(px, screenW, screenH)
    local UI = loadUI(px)
    _G.getCore = function()
        return { getScreenWidth = function() return screenW end, getScreenHeight = function() return screenH end }
    end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Trade/TerminalWindow")
    require = real
    if not ok then error(err, 0) end
    UI.refreshScale()
    return UI, OATerminalWindow
end

test("the window is the design's size times the scale, within 90% of the screen", function()
    local _, W = loadWindow(16, 1366, 768)
    local w, h, mw, mh = W.sizes()
    eq(w, 720); eq(h, 480); eq(mw, 600); eq(mh, 420)
    _, W = loadWindow(26, 2560, 1440)
    w, h, mw, mh = W.sizes()
    eq(w, 1170); eq(h, 780); eq(mw, 975); eq(mh, 683)
    _, W = loadWindow(38, 3840, 2160)
    w, h = W.sizes()
    eq(w, 1710); eq(h, 1140)
    _, W = loadWindow(26, 1280, 720)
    w, h, mw, mh = W.sizes()
    eq(w, 1152); eq(h, 648); eq(mh, 648)
end)

test("the body the tabs get is the design's 700 x 408 at every scale (the game's bars grow with their font)", function()
    for _, px in ipairs({ 16, 19, 26, 38 }) do
        local UI, W = loadWindow(px, 3840, 2160)
        local width, height = W.sizes()
        local window = setmetatable({ width = width, height = height, tabHeight = UI.fontHeight() + 6 }, { __index = W })
        -- the game's title bar is its font's height + 1, the resize bar half a button (font + 6) + 2
        window.titleBarHeight = function() return font.S + 1 end
        window.resizeWidgetHeight = function() return (font.S + 6) / 2 + 2 end
        local x, y, w, h = window:bodyRect()
        eq(x, 10)
        eq(w, 700, px .. " px")
        near(h, 408, 4, px .. " px")
        truthy(y > 10 + 16 + 22 and y <= 10 + 17 + 22, "under the title and the strip: " .. y)
    end
end)

-- The screens at the four font sizes ---------------------------------------------------------------------------------
-- Every text drawn (design units, its box from its font) inside the screen and not on another one.

local function boxes(drawn)
    local out = {}
    for _, d in ipairs(drawn) do
        local kind = d[1]
        if kind == "text" or kind == "right" or kind == "centre" then
            local s, x, y, f = d[2], d[3], d[4], d[9]
            if s ~= "" then
                local w = OA.Trade.UI.textWidth(s, f)
                if kind == "right" then x = x - w elseif kind == "centre" then x = x - w / 2 end
                out[#out + 1] = { s = s, x = x, y = y, w = w, h = OA.Trade.UI.fontHeight(f) }
            end
        end
    end
    return out
end

-- Inside its screen: a text may reach a unit or two past where the design packs the lines (a line's height has room
-- above the letters).
local SLACK = 2

local function inside(list, w, h, what)
    for _, a in ipairs(list) do
        truthy(a.x >= -SLACK and a.x + a.w <= w + SLACK, what .. ": '" .. a.s .. "' inside the width (" .. a.x .. ", " .. a.w .. ")")
        truthy(a.y >= -SLACK and a.y + a.h <= h + SLACK, what .. ": '" .. a.s .. "' inside the height (" .. a.y .. ", " .. a.h .. ")")
    end
end

-- How far two texts lie on each other (0 when they do not).
local function overlap(a, b)
    local ox = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
    local oy = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
    return math.max(0, math.min(ox, oy))
end

-- None on another more than at the design's own 16 px font (the smallest window packs a few lines a unit or two into
-- each other by design): the same screen laid out at 16 px is the measure, text by text.
local function noWorse(list, base, what, slack)
    eq(#list, #base, what .. ": the same texts as at 16 px")
    for i = 1, #list do
        for j = i + 1, #list do
            local now, was = overlap(list[i], list[j]), overlap(base[i], base[j])
            truthy(now <= math.max(was, 0) + 1 + (slack or 0), what .. ": '" .. list[i].s .. "' at " .. list[i].x .. "," .. list[i].y
                .. " and '" .. list[j].s .. "' at " .. list[j].x .. "," .. list[j].y .. " overlap " .. now .. " (" .. was .. " at 16 px)")
        end
    end
end

-- Short words for every text (the keys the harness's getText gives are far longer than any translation): what is
-- checked is where the lines go, not how long the words are.
local function shortTexts()
    getText = function() return "Word" end
end

-- The status screens: their steps laid out from a record, at the default body and the smallest one.
local function loadStatus(px)
    shortTexts()
    local UI, Draw = loadDraw(px)
    getScriptManager = function() return { FindItem = function() return nil end } end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Trade/TabHeli"
        real "OperationAcorn/Trade/TabProgress"
        real "OperationAcorn/Trade/TabUpgrades"
        real "OperationAcorn/Trade/TabRecords"
    end)
    require = real
    if not ok then error(err, 0) end
    return UI, Draw
end

-- Sets the fonts of a screen size and the scale they give.
local function useFonts(UI, px)
    font = FONTS[px]
    UI.refreshScale()
end

local function statusRecord(stage)
    local r = OA.Store.ensure("st", "Tester")
    r.trade = { credits = 48200, trust = 3940, stage = stage, milestones = 0, bonus = 0, sharedSerums = 0, levels = {} }
    OA.Trust.reset()
    return r
end

local function textsOf(view)
    local drawn = {}
    for _, op in ipairs(view.list.ops) do
        if op[1] == 3 then drawn[#drawn + 1] = { "text", op[2], op[3], op[4], nil, nil, nil, nil, op[7] } end
    end
    return boxes(drawn)
end

local STATUS = { "OATabHeli", "OATabProgress", "OATabUpgrades", "OATabRecords" }

local function statusTexts(UI, name, tier, size)
    local character = { getX = function() return 0 end, getY = function() return 0 end }
    local window = { palette = UI.palette(tier), tier = tier, record = statusRecord(3), character = character }
    local view = _G[name]:new(0, 0, size[1], size[2], window)
    view:initialise()
    view:instantiate()
    view:refresh()
    truthy(view.list, name .. " laid out")
    return textsOf(view)
end

for _, px in ipairs({ 19, 26, 38 }) do
    test("the status screens at " .. px .. " px: every text inside its screen, none on another more than at 16 px", function()
        local UI = loadStatus(px)
        for _, tier in ipairs({ "crude", "field" }) do
            for _, size in ipairs({ { 700, 312 }, { 580, 252 } }) do
                for _, name in ipairs(STATUS) do
                    local what = px .. " px " .. tier .. " " .. name .. " " .. size[1]
                    useFonts(UI, 16)
                    local base = statusTexts(UI, name, tier, size)
                    inside(base, size[1], size[2], "16 px " .. what)
                    useFonts(UI, px)
                    local now = statusTexts(UI, name, tier, size)
                    inside(now, size[1], size[2], what)
                    noWorse(now, base, what)
                end
            end
        end
    end)
end

-- The extension API's UI fonts as the Korean language has them: a size asked for is the nearest of its bitmap fonts'
-- line heights within a few pixels, else drawn at that size; a character 7/16 of the line wide.
local KO = { 19, 26, 29, 33, 38, 40, 45 }
local function koApi()
    local function pick(px)
        local best
        for _, h in ipairs(KO) do
            if math.abs(h - px) <= 3 and (not best or math.abs(h - px) < math.abs(best - px)) then best = h end
        end
        return best or px
    end
    _G.PZToolsAPI = { version = OA.API_VERSION, client = function() return "h" end, text = {
        font = function(_, px) return pick(px) end,
        fontHeight = function(_, key) return key end,
        measure = function(_, key, s) return #tostring(s) * key * 7 / 16 end,
        draw = function() end,
    } }
end

for _, screenH in ipairs({ 720, 900, 1080, 1440 }) do
    test("the status screens with the API's fonts at " .. screenH .. "p: every text inside, none on another more than at 16 px", function()
        local UI = loadStatus(16)
        for _, tier in ipairs({ "crude", "field" }) do
            for _, size in ipairs({ { 700, 312 }, { 580, 252 } }) do
                for _, name in ipairs(STATUS) do
                    local what = screenH .. "p " .. tier .. " " .. name .. " " .. size[1]
                    _G.PZToolsAPI = nil
                    useFonts(UI, 16)
                    local base = statusTexts(UI, name, tier, size)
                    koApi()
                    _G.getCore = function()
                        return { getScreenWidth = function() return screenH * 16 / 9 end, getScreenHeight = function() return screenH end }
                    end
                    UI.refreshScale()
                    eq(UI.facesOn, true)
                    eq(UI.S, OA.Trade.Faces.screenScale(screenH))
                    local now = statusTexts(UI, name, tier, size)
                    inside(now, size[1], size[2], what)
                    -- a bitmap font is a little larger than the design's at some sizes (33 pixels at 2x is 16.5
                    -- units, its letters as much wider): texts the design packs into each other meet by that much
                    -- more, a few percent of a text's size
                    local grown = math.max(1, UI.fontHeight() / 16, UI.fontHeight(UIFont.Medium) / 20)
                    noWorse(now, base, what, (grown - 1) * 40)
                end
            end
        end
    end)
end

-- The shop tab: the tab's own texts and its two lists', in design units (what our scaled elements were asked to draw,
-- back from pixels).
local function designTexts(el, UI)
    local s = el.oaScaled and UI.S or 1
    local drawn = {}
    for _, d in ipairs(el.drawn or {}) do
        if d[1] == "text" or d[1] == "right" or d[1] == "centre" then
            drawn[#drawn + 1] = { d[1], d[2], d[3] / s, d[4] / s, nil, nil, nil, nil, d[9] }
        end
    end
    return boxes(drawn)
end

local function loadShop(px)
    shortTexts()
    local UI = loadUI(px)
    function ISComboBox:clear() self.options = {} end
    function ISComboBox:addOptionWithData(text, data) self.options = self.options or {}; self.options[#self.options + 1] = { text = text, data = data } end
    function ISComboBox:getSelectedData() return self.options[self.selected or 1].data end
    _G.getSoundManager = function() return { playUISound = function() end } end
    _G.getItemNameFromFullType = function(t) return "Name" end
    _G.getScriptManager = function()
        return {
            FindItem = function(_, t) return { getNormalTexture = function() return "tex" end,
                getIcon = function() return "Item_" .. t end } end,
            getAllItems = function() return { size = function() return 0 end, get = function() return nil end } end,
        }
    end
    _G.OATab = ISPanel:derive("OATab")
    function OATab:new(x, y, w, h, window)
        local o = ISPanel.new(self, x, y, w, h)
        o.window = window
        return o
    end
    function OATab:character() return self.window.character end
    function OATab:record() return self.window.record end
    function OATab:palette() return self.window.palette end
    function OATab:refresh() end
    function OATab:send() end
    UI.scaled(OATab, ISPanel)
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Trade/Estimate"
        real "OperationAcorn/Trade/TabShop"
    end)
    require = real
    if not ok then error(err, 0) end
    OA.Client = OA.Client or {}
    OA.Client.id = function() return "s" end
    return UI
end

local function shopTexts(UI, tier, size, cat)
    local r = OA.Store.ensure("s", "S")
    r.trade = { credits = 48200, trust = 0, stage = 3, milestones = 0, bonus = 0, sharedSerums = 0, levels = {} }
    OA.Trust.reset()
    local window = { palette = UI.palette(tier), tier = tier, record = r, character = {}, reveal = function() end }
    local tab = OATabShop:new(0, 0, size[1], size[2], window)
    tab:initialise()
    tab:instantiate()
    tab:refresh()
    if cat then tab:setCat(cat) end
    tab.drawn, tab.cards.drawn, tab.cartList.drawn = {}, {}, {}
    tab:prerender()
    tab.cards:prerender()
    tab.cartList:prerender()
    return { tab = designTexts(tab, UI), cards = designTexts(tab.cards, UI), cart = designTexts(tab.cartList, UI),
        cardsW = tab.cards.width, cardsH = tab.cards.height, cartW = tab.cartList.width, cartH = tab.cartList.height }
end

for _, px in ipairs({ 19, 26, 38 }) do
    test("the shop tab at " .. px .. " px: every text inside its place, none on another more than at 16 px", function()
        local UI = loadShop(px)
        for _, tier in ipairs({ "crude", "field" }) do
            for _, size in ipairs({ { 700, 408 }, { 580, 348 } }) do
                for _, cat in ipairs({ false, "all" }) do
                    local what = px .. " px " .. tier .. " " .. size[1] .. " " .. tostring(cat)
                    useFonts(UI, 16)
                    local base = shopTexts(UI, tier, size, cat or nil)
                    useFonts(UI, px)
                    local now = shopTexts(UI, tier, size, cat or nil)
                    inside(now.tab, size[1], size[2], what .. " tab")
                    noWorse(now.tab, base.tab, what .. " tab")
                    noWorse(now.cards, base.cards, what .. " cards")
                    noWorse(now.cart, base.cart, what .. " cart")
                end
            end
        end
    end)
end

-- The folder and the missions' buttons -------------------------------------------------------------------------------

local function loadFolder(px)
    local UI = loadUI(px)
    _G.OATab = ISPanel:derive("OATab")
    UI.scaled(OATab, ISPanel)
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Trade/Button"
        real "OperationAcorn/Story/TabFolder"
    end)
    require = real
    if not ok then error(err, 0) end
    UI.refreshScale()
    return UI
end

test("the folder reads in the Medium font, its heads making room for it; at 16 px they are where they were", function()
    local UI = loadFolder(16)
    eq(OATabFolder.BODY_FONT, UIFont.Medium)
    local metaY, ruleY, bodyY = OATabFolder.heads()
    eq(metaY, 30); eq(ruleY, 50); eq(bodyY, 58)
    for _, px in ipairs({ 19, 26, 38 }) do
        font = FONTS[px]
        UI.refreshScale()
        metaY, ruleY, bodyY = OATabFolder.heads()
        truthy(metaY >= 6 + UI.fontHeight(UIFont.Medium), px .. " px: the line under the title is under the title")
        eq(ruleY, metaY + 20)
        eq(bodyY, ruleY + 8)
    end
end)

test("a missions button is as wide as its title in design units, not in pixels", function()
    local UI = loadFolder(26)
    ISButton.new = function(self, x, y, w, h, title)
        local o = ISPanel.new(self, x, y, w, h)
        -- the game's: at least the title's pixels + 10
        o.width = math.max(w, UI.textWidthPx(title) + 10)
        o.title = title
        return o
    end
    local short = OAMButton:new(0, 0, 70, 26, "Prev", {})
    eq(short.width, 70, "a short title keeps the width asked for")
    local long = OAMButton:new(0, 0, 70, 26, "Next page", {})
    eq(long.width, 9 * 7 + 10, "73 units, where the game's measure would make it 112")
end)

test("a list row outside the list's visible part is not drawn", function()
    local UI = loadUI(16)
    local drawn = 0
    local painter = UI.rowPainter(function() drawn = drawn + 1 end)
    local list = { height = 100, getYScroll = function() return -40 end }
    eq(painter(list, 10, { height = 20 }, false), 30, "above the top (scrolled up): the next place, nothing drawn")
    eq(drawn, 0)
    eq(painter(list, 200, { height = 20 }, false), 220, "below the bottom")
    eq(drawn, 0)
    painter(list, 60, { height = 20 }, false)
    eq(drawn, 1, "on show")
    painter(list, 139, { height = 20 }, false)
    eq(drawn, 2, "its top just inside")
end)

test("texts measured once are not measured again until the scale is set", function()
    local UI = loadUI(16)
    local calls = 0
    local measure = getTextManager().MeasureStringX
    local manager = getTextManager()
    local wrapped = setmetatable({}, { __index = manager })
    wrapped.MeasureStringX = function(self, font, text) calls = calls + 1 return measure(manager, font, text) end
    local was = getTextManager
    getTextManager = function() return wrapped end
    local w = UI.textWidth("some words")
    local first = calls
    truthy(first > 0)
    eq(UI.textWidth("some words"), w)
    eq(calls, first, "the second ask is from memory")
    local lines = UI.wrapMemo("one two three", 20)
    local again = UI.wrapMemo("one two three", 20)
    truthy(lines == again, "the same wrap, kept")
    eq(UI.fitMemo("one two three", 20), UI.fit("one two three", 20))
    UI.setScale(2)
    UI.textWidth("some words")
    truthy(calls > first, "measured again at the new scale")
    getTextManager = was
end)

test("the sub-tabs' frame reuses its click slots instead of making them each frame", function()
    local UI = loadUI(16)
    local tabs = OASubTabs:new(0, 0, 400, UI.palette("field"), nil, nil)
    tabs:setItems({ { id = "a", label = "One" }, { id = "b", label = "Two", badge = "3" }, { id = "c", label = "Three" } }, "a")
    tabs:prerender()
    eq(#tabs.slots, 3)
    local first, second = tabs.slots[1], tabs.slots[2]
    local x2 = second.x
    tabs:prerender()
    truthy(tabs.slots[1] == first and tabs.slots[2] == second, "the same tables")
    eq(tabs.slots[2].x, x2)
    eq(tabs.slots[3].id, "c")
    tabs:setItems({ { id = "a", label = "One" } }, "a")
    tabs:prerender()
    eq(#tabs.slots, 1, "fewer items: the slots past them gone")
end)
