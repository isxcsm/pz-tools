-- Our windows' faces and widgets (the UI kit, PZUIKit: Faces, UI, RichText, Button, Combo, Confirm; the mod's Trade/UI,
-- and the folder's list in Story/TabFolder), against stand-ins of the game's elements and of the
-- extension API's UI fonts (PZExtAPI.text): the scale by the screen in eighths, a text drawn in the API's face at the
-- screen pixel the game's text would take, the game's fonts and the font's scale without the API or when one of its
-- calls fails (said once), our rich text's lines, our buttons, combo box and confirm, and a folder list that is not
-- built again when nothing it lists changed.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
local OA = OperationAcorn

-- The game's fonts: Small `px` high, Medium a little more; a text 7 units a character at 16 px, growing with the font.
local font
local function stubFonts(px)
    font = { S = px, M = math.floor(px * 1.3 + 0.5), L = math.floor(px * 1.5 + 0.5) }
    _G.UIFont = { Small = "S", Medium = "M", Large = "L", NewSmall = "S" }
    _G.getTextManager = function()
        return {
            getFontHeight = function(_, f) return font[f] or font.S end,
            MeasureStringX = function(_, f, text) return #tostring(text) * 7 * (font[f] or font.S) / 16 end,
        }
    end
end

local screen = { w = 1920, h = 1080 }

-- The API's UI fonts: a key is the font's pixel height, its line that high, a character 7/16 of it wide. What it was
-- asked to draw is kept. `opts`: missing (no text table), noFont (font() gives nil), throwFont, throwDraw.
local function stubApi(opts)
    opts = opts or {}
    local seen = { fonts = {}, draws = {} }
    local text = {
        font = function(handle, px)
            seen.fonts[#seen.fonts + 1] = px
            if opts.throwFont then error("no fonts here") end
            if opts.noFont then return nil end
            return px
        end,
        fontHeight = function(handle, key) return key end,
        measure = function(handle, key, s) return #tostring(s) * key * 7 / 16 end,
        draw = function(handle, key, s, x, y, r, g, b, a)
            if opts.throwDraw then error("cannot draw") end
            seen.draws[#seen.draws + 1] = { key = key, s = s, x = x, y = y }
        end,
    }
    _G.PZExtAPI = { version = OA.API_VERSION, client = function() return "handle" end,
        text = not opts.missing and text or nil }
    return seen
end

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

local ui -- what the stand-in UI manager holds
local function gameClasses()
    ui = {}
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
        c.javaObject.ax, c.javaObject.ay = self.javaObject:getAbsoluteX(), self.javaObject:getAbsoluteY()
        self.children[#self.children + 1] = c
    end
    function E:addToUIManager()
        if not self.javaObject then self:instantiate() end
        ui[self] = true
    end
    function E:removeFromUIManager() ui[self] = nil end
    function E:setAlwaysOnTop() end
    function E:bringToTop() end
    function E:isReallyVisible() return self.visible end
    function E:setX(x) self.x = x; if self.javaObject then self.javaObject:setX(x) end end
    function E:setY(y) self.y = y; if self.javaObject then self.javaObject:setY(y) end end
    function E:setWidth(w) self.width = w; if self.javaObject then self.javaObject:setWidth(w) end end
    function E:setHeight(h) self.height = h; if self.javaObject then self.javaObject:setHeight(h) end end
    function E:getX() return self.javaObject:getX() end
    function E:getY() return self.javaObject:getY() end
    function E:getWidth() return self.javaObject:getWidth() end
    function E:getHeight() return self.javaObject:getHeight() end
    function E:getAbsoluteX() return self.javaObject:getAbsoluteX() end
    function E:getAbsoluteY() return self.javaObject:getAbsoluteY() end
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
    E.drawTextureScaledAspect, E.drawTextureScaled = rec("icon"), rec("texture")
    E.setStencilRect, E.clearStencilRect = rec("clip"), rec("unclip")
    function E.repaintStencilRect() end
    local Panel = E:derive("ISPanel")
    function Panel:prerender() end
    local Button = Panel:derive("ISButton")
    function Button:new(x, y, w, h, title, target, onclick)
        local o = Panel.new(self, x, y, w, h)
        o.title, o.target, o.onclick, o.enable, o.onClickArgs = title, target, onclick, true, {}
        return o
    end
    function Button:onMouseDown() self.pressed = true end
    function Button:onMouseUp()
        local process = self.pressed
        self.pressed = false
        if self.enable and process and self.onclick then self.onclick(self.target, self) end
    end
    function Button:setVisible(v) self.visible = v end
    local List = Panel:derive("ISScrollingListBox")
    function List:new(x, y, w, h)
        local o = Panel.new(self, x, y, w, h)
        o.items, o.count, o.scrollH = {}, 0, 0
        return o
    end
    -- the game's: clear keeps the height it scrolls over, each row adds its own
    function List:addItem(name, item)
        self.count = self.count + 1
        local i = { text = name, item = item, height = self.itemheight, itemindex = self.count }
        self.items[#self.items + 1] = i
        self:setScrollHeight(self:getScrollHeight() + i.height)
        return i
    end
    function List:clear() self.items, self.count = {}, 0; self.cleared = (self.cleared or 0) + 1 end
    function List:setScrollHeight(h) self.scrollH = h end
    function List:getScrollHeight() return self.scrollH end
    function List:isVScrollBarVisible() return self.scrollH > self.height end
    function List:setOnMouseDownFunction() end
    function List:getYScroll() return 0 end
    function List:ensureVisible() end
    _G.ISUIElement, _G.ISPanel, _G.ISButton, _G.ISScrollingListBox = E, Panel, Button, List
    _G.UIElement = { new = function() return javaObject() end }
end

local logged
local kitCap   -- the kit's own cap on the screen's scale, lifted in load
local function load(px, files)
    stubFonts(px or 16)
    gameClasses()
    _G.PZExtAPI = nil
    _G.OATab = ISPanel:derive("OATab")
    _G.getCore = function()
        return { getScreenWidth = function() return screen.w end, getScreenHeight = function() return screen.h end }
    end
    _G.getMouseX = function() return 400 end
    _G.getMouseY = function() return 300 end
    _G.getSoundManager = function() return { playUISound = function() end } end
    logged = {}
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Trade/UI"
        local log = PZUIKit.kitTestLog or PZUIKit.log
        PZUIKit.kitTestLog = log
        PZUIKit.log = function(...)
            logged[#logged + 1] = table.concat({ ... }, " ")
            return log(...)
        end
        for _, f in ipairs(files or {}) do real(f) end
    end)
    require = real
    if not ok then error(err, 0) end
    -- the screen's scale without the kit's cap, so that these follow the scale's arithmetic up a large screen (the
    -- cap has its own test)
    kitCap = PZUIKit.UI.MAX_SCREEN_SCALE
    PZUIKit.UI.MAX_SCREEN_SCALE = 4
    return OA.Trade.UI, PZUIKit.Faces
end

local function own(t, key)
    for k, v in pairs(t) do
        if k == key then return v end
    end
    return nil
end

-- One of our elements (a class made with UI.scaled), placed at ax, ay on the screen (pixels).
local function ourElement(UI, ax, ay, w, h)
    local C = ISPanel:derive("OAFacesTest")
    UI.scaled(C, ISPanel)
    local el = C:new(0, 0, w or 300, h or 200)
    el:initialise()
    el:instantiate()
    el.javaObject.ax, el.javaObject.ay = ax or 0, ay or 0
    return el, C
end

local function texts(el)
    local out = {}
    for _, d in ipairs(el.drawn) do
        if d[1] == "text" or d[1] == "centre" or d[1] == "right" then out[#out + 1] = d end
    end
    return out
end

-- The scale ------------------------------------------------------------------------------------------------------

test("the screen's scale is its height over 540 in eighths, never under 1", function()
    local _, Faces = load()
    for _, case in ipairs({ { 600, 1 }, { 720, 1.25 }, { 768, 1.375 }, { 900, 1.625 }, { 1080, 2 }, { 1200, 2.125 },
        { 1440, 2.625 }, { 2160, 4 } }) do
        eq(Faces.screenScale(case[1]), case[2], case[1] .. " px")
    end
end)

test("the screen's scale stops at the kit's cap (the windows' size on a 1600x900 screen); a larger font still wins", function()
    local UI = load(16)
    stubApi()
    PZUIKit.UI.MAX_SCREEN_SCALE = kitCap
    eq(kitCap, 1.625)
    for _, case in ipairs({ { 720, 1.25 }, { 900, 1.625 }, { 1080, 1.625 }, { 1440, 1.625 }, { 2160, 1.625 } }) do
        screen.h = case[1]
        UI.refreshScale()
        eq(UI.S, case[2], case[1] .. "p")
    end
    font = { S = 38, M = 45, L = 50 }
    UI.refreshScale()
    eq(UI.S, 38 / 16, "the game's 4K font")
    font = { S = 16, M = 20, L = 24 }
end)

test("without the API the scale and the faces are the game font's, as before", function()
    local UI = load(26)
    screen.h = 1080
    UI.refreshScale()
    eq(UI.S, 26 / 16)
    eq(UI.facesOn, false)
    eq(UI.fontHeight(), 16)
    eq(UI.titleBarHeight(), 27, "the game's bar: its Small font + 1")
    eq(UI.resizeWidgetHeight(), (26 + 6) / 2 + 2)
end)

test("with the API the scale is the screen's, or the font's where that is larger; the faces are its fonts", function()
    local UI = load(16)
    local seen = stubApi()
    screen.h = 1080
    UI.refreshScale()
    eq(UI.S, 2)
    eq(UI.facesOn, true)
    local asked = {}
    for _, px in ipairs(seen.fonts) do asked[px] = true end
    truthy(asked[32] and asked[40] and asked[48], "Small 16, Medium 20, Large 24 times 2")
    eq(UI.fontHeight(), 16, "the face's 32 pixels in design units")
    eq(UI.fontHeight(UIFont.Medium), 20)
    eq(UI.textWidth("abcd"), 4 * 32 * 7 / 16 / 2)
    eq(UI.titleBarHeight(), 33, "the bars follow the face")
    -- a font larger than the screen asks for wins
    font = { S = 38, M = 45, L = 50 }
    UI.refreshScale()
    eq(UI.S, 38 / 16)
    screen.h = 900
    font = { S = 16, M = 20, L = 24 }
    UI.refreshScale()
    eq(UI.S, 1.625, "900p")
end)

test("with the API our text is drawn in its face at the screen pixel the game's would take", function()
    local UI = load(16)
    local seen = stubApi()
    screen.h = 1080
    UI.refreshScale()
    local el = ourElement(UI, 100, 50)
    UI.text(el, "hi", 10, 5, { 1, 1, 1 })
    eq(#texts(el), 0, "nothing in the game's font")
    local d = seen.draws[1]
    eq(d.key, 32); eq(d.s, "hi"); eq(d.x, 100 + 20); eq(d.y, 50 + 10)
    UI.textCentre(el, "abcd", 50, 0, { 1, 1, 1 }, UIFont.Medium)
    d = seen.draws[2]
    eq(d.key, 40); eq(d.x, 100 + 100 - math.floor(4 * 40 * 7 / 16 / 2))
    UI.textRight(el, "ab", 50, 0, { 1, 1, 1 })
    eq(seen.draws[3].x, 100 + 100 - 2 * 32 * 7 / 16)
    -- a scrolled element: the scroll is added as the game's drawText adds it
    el.javaObject.yscroll = -30
    UI.text(el, "x", 0, 20, { 1, 1, 1 })
    eq(seen.draws[4].y, 50 + 40 - 30)
    -- from an element that is not a scaled class: its pixels
    local plain = ISPanel:new(0, 0, 10, 10)
    plain:initialise()
    plain:instantiate()
    plain.javaObject.ax = 7
    UI.textAtPx(plain, "p", 3, 4, { 1, 1, 1 })
    eq(seen.draws[5].x, 10); eq(seen.draws[5].y, 4)
    near(UI.faceWidthPx("ab"), 2 * 32 * 7 / 16, 1e-9)
end)

test("at scale 1 with the API our classes still convert: their texts go to the faces", function()
    local UI = load(16)
    local seen = stubApi()
    screen.h = 600
    UI.refreshScale()
    eq(UI.S, 1)
    local el, C = ourElement(UI)
    truthy(own(C, "drawText"), "the scaled drawing is on")
    UI.text(el, "x", 1, 2, { 1, 1, 1 })
    eq(seen.draws[1].key, 16)
end)

test("a status list's texts go to the faces from the element's place, asked once a paint", function()
    local UI = load(16, { "OperationAcorn/Trade/StatusDraw" })
    local seen = stubApi()
    screen.h = 1080
    UI.refreshScale()
    local el = ourElement(UI, 10, 20)
    _G.getScriptManager = function()
        return { FindItem = function() return { getNormalTexture = function() return "tex" end, getIcon = function() return "Thing" end } end }
    end
    local Draw = OA.Trade.Draw
    local L = Draw.list(UI.palette("crude"))
    Draw.text(L, "one", 5, 2, { 1, 1, 1 })
    Draw.item(L, "Base.Axe", 0, 8, 24)
    Draw.paint(el, L, -4)
    eq(seen.draws[1].x, 10 + 10); eq(seen.draws[1].y, 20 + 4 - 4, "moved up by the scroll")
    local icon = el.drawn[#el.drawn]
    eq(icon[1], "icon"); eq(icon[2], "tex"); eq(icon[4], 16 - 4); eq(icon[5], 48)
    eq(icon[8], UI.palette("crude").iconTint[1], "tinted on the crude terminal")
end)

test("an API without UI fonts leaves the game's fonts and the font's scale, and says nothing", function()
    local UI = load(26)
    stubApi({ missing = true })
    screen.h = 1080
    UI.refreshScale()
    eq(UI.S, 26 / 16)
    eq(UI.facesOn, false)
    eq(#logged, 0, "an older PZ Extension API is not an error")
end)

test("an API whose font call fails leaves the game's fonts and the font's scale, said once", function()
    local UI = load(26)
    screen.h = 1080
    stubApi({ throwFont = true })
    UI.refreshScale()
    eq(UI.S, 26 / 16)
    eq(UI.facesOn, false)
    eq(#logged, 1, "said once")
    UI.refreshScale()
    eq(#logged, 1, "and not again")
end)

test("an API with no font for the language leaves the game's fonts", function()
    local UI = load(26)
    screen.h = 1080
    stubApi({ noFont = true })
    UI.refreshScale()
    eq(UI.facesOn, false)
    eq(UI.S, 26 / 16)
end)

test("a draw that throws gives the API up once: the game's fonts and the font's scale, the windows closed by the era", function()
    local UI = load(19)
    stubApi({ throwDraw = true })
    screen.h = 1080
    UI.refreshScale()
    eq(UI.S, 2)
    local era = UI.era
    local el = ourElement(UI)
    UI.text(el, "x", 0, 0, { 1, 1, 1 })
    eq(UI.facesOn, false)
    eq(UI.S, 19 / 16)
    truthy(UI.era ~= era, "a window made before closes")
    eq(#logged, 1)
    UI.text(el, "y", 0, 0, { 1, 1, 1 })
    eq(texts(el)[1][2], "y", "in the game's font now")
    eq(#logged, 1)
end)

test("an item icon goes through UI.icon: design units on ours, made pixels by the rounded edges", function()
    local UI = load(26)
    UI.refreshScale()
    local el = ourElement(UI)
    UI.icon(el, "tex", 4, 4, 24, 0.5, { 0.6, 1, 0.6 })
    local d = el.drawn[#el.drawn]
    eq(d[1], "icon"); eq(d[3], 7); eq(d[5], 46 - 7); eq(d[7], 0.5); eq(d[8], 0.6)
    local n = #el.drawn
    UI.icon(el, nil, 4, 4, 24)
    eq(#el.drawn, n, "no texture, nothing")
end)

-- Our rich text ------------------------------------------------------------------------------------------------------

local function rich(UI, w, h, text, fontName)
    local panel = PZUIRichText:new(0, 0, w, h)
    panel:initialise()
    panel:instantiate()
    panel.marginLeft, panel.marginRight, panel.marginTop, panel.marginBottom = 0, 0, 0, 0
    if fontName then panel.defaultFont = fontName end
    panel.text = text
    panel:paginate()
    return panel
end

local function lineList(panel)
    local out = {}
    for c, s in ipairs(panel.lines) do if s ~= "" then out[#out + 1] = s .. "@" .. panel.lineY[c] end end
    return table.concat(out, "|")
end

test("rich text: lines broken at spaces to the width short of the bar, a long word whole on its own row", function()
    local UI = load(16, { "PZUIKit/RichText" })
    UI.refreshScale()
    -- 7 a character, the text area 100 - 14 = 86: twelve characters a row
    local panel = rich(UI, 100, 200, "aaa bbb ccc ddd eee averyveryverylongword f")
    eq(lineList(panel), "aaa bbb ccc@0|ddd eee@16|averyveryverylongword@32|f@48")
    eq(panel.contentH, 64)
    for c, s in ipairs(panel.lines) do
        if #s < 15 then
            truthy(panel.lineX[c] + UI.textWidth(s) <= panel:barX() - PZUIRichText.BAR_GAP,
                "'" .. s .. "' ends left of the bar and its gap")
        end
    end
end)

test("rich text: the commands the mod's texts use, and a row as high as its face", function()
    local UI = load(16, { "PZUIKit/RichText" })
    UI.refreshScale()
    local panel = rich(UI, 400, 300,
        " <H1> <RGB:1,1,1> Title <LINE> <LINE> <TEXT> <RGB:0.5,0.6,0.7> one &lt;two&gt; <LINE> three\nfour <SPACE> <RGB:1,0,0> red ")
    local byText = {}
    for c, s in ipairs(panel.lines) do byText[s] = c end
    local t = byText["Title"]
    truthy(t, "the title")
    eq(panel.cFont[t], UIFont.Large)
    near(panel.cX[t], (400 - 14 - UI.textWidth("Title", UIFont.Large)) / 2, 1e-9, "centred in the text's room")
    local one = byText["one <two>"]
    truthy(one, "escapes read")
    eq(panel.lineY[one], 2 * 24, "two rows of the Large face under the title")
    eq(panel.cRGB[one][2], 0.6)
    eq(panel.cFont[one], UIFont.Small)
    eq(panel.lineY[byText["three"]], 48 + 16)
    eq(panel.lineY[byText["four"]], 48 + 32, "a line end is a <LINE>")
    local red = byText["red"]
    eq(panel.cRGB[red][1], 1); eq(panel.cRGB[red][2], 0)
    truthy(panel.lineX[red] > UI.textWidth("four"), "a space asked for between the colours")
end)

test("rich text: the documents' half rows, hanging bullets and a sign-off on the right", function()
    local UI = load(16, { "PZUIKit/RichText" })
    UI.refreshScale()
    -- 7 a character, the text area 100 - 14 = 86
    local panel = rich(UI, 100, 300, " <TEXT> head <LINE> <HALF> x <LINE> - <HANG> aaa bbb ccc ddd eee fff <LINE> "
        .. "<HALF> <RIGHT> sign <LINE> <LEFT> after")
    local byText = {}
    for c, s in ipairs(panel.lines) do byText[s] = c end
    eq(panel.lineY[byText["head"]], 0)
    eq(panel.lineY[byText["x"]], 16 + 8, "half a row above")
    local first = byText["aaa bbb"]
    truthy(first, lineList(panel))
    eq(panel.lineX[first], 7 + 7, "after the bullet and its space")
    local rows = 0
    for c, s in ipairs(panel.lines) do
        if s ~= "" and c > first and panel.lineY[c] > panel.lineY[first] and panel.lineY[c] < panel.lineY[byText["sign"]] then
            rows = rows + 1
            eq(panel.lineX[c], 14, "'" .. s .. "' hangs under the text, not the bullet")
            truthy(panel.lineX[c] + UI.textWidth(s) <= 86, "and keeps to the room")
        end
    end
    truthy(rows >= 2, "the bullet's line wrapped: " .. lineList(panel))
    local sign = byText["sign"]
    near(panel.cX[sign] + UI.textWidth("sign"), 86, 1e-9, "the sign-off ends at the text's right edge")
    local after = byText["after"]
    eq(panel.lineX[after], 0, "a line end ends the hang")
    eq(panel.cX[after], 0, "and <LEFT> the right side")
    eq(panel.lineY[after], panel.lineY[sign] + 16)
end)

test("rich text draws the rows on show in their faces, scrolls by the wheel and keeps inside its text", function()
    local UI = load(16, { "PZUIKit/RichText" })
    local seen = stubApi()
    screen.h = 1080
    UI.refreshScale()
    local lines = {}
    for i = 1, 30 do lines[i] = "row" .. i end
    local panel = rich(UI, 200, 100, table.concat(lines, " <LINE> "))
    panel:render()
    eq(#seen.draws, 7, "100 units show six rows and a part")
    eq(seen.draws[1].s, "row1"); eq(seen.draws[1].key, 32)
    truthy(panel:onMouseWheel(2))
    eq(panel.scroll, 36)
    eq(panel:getYScroll(), -36)
    seen.draws = {}
    panel:render()
    eq(seen.draws[1].s, "row3")
    panel:onMouseWheel(1000)
    eq(panel.scroll, 30 * 16 - 100, "no further than the end")
    panel:setYScroll(0)
    eq(panel.scroll, 0)
    -- the bar: on the right, clear of the text
    panel.drawn = {}
    panel:render()
    local bar = panel.drawn[#panel.drawn]
    eq(bar[1], "rect")
    eq(bar[2], math.floor((200 - 7) * 2 + 0.5), "the bar at its place, in pixels")
end)

test("a rich text a click hurries reads its click anywhere, its bar takes the clicks on it", function()
    local UI = load(16, { "PZUIKit/RichText" })
    UI.refreshScale()
    local lines = {}
    for i = 1, 30 do lines[i] = "row" .. i end
    local panel = rich(UI, 200, 100, table.concat(lines, " <LINE> "))
    local clicks = 0
    panel.onmousedown = function() clicks = clicks + 1 end
    panel:onMouseDown(20, 20)
    eq(clicks, 1)
    panel:onMouseDown(198, 90)
    eq(clicks, 1, "the bar's")
    truthy(panel.scroll > 0, "a click on the track moves the thumb")
end)

-- Our buttons, combo box and confirm ---------------------------------------------------------------------------------

test("a button that is off does nothing when clicked but tells why; its tooltip is ours, in our face", function()
    local UI = load(16, { "PZUIKit/Button" })
    stubApi()
    screen.h = 1080
    UI.refreshScale()
    local clicked, refused = 0, 0
    local target = {}
    local b = PZUIButton:new(10, 10, 60, 26, "Add", UI.palette("field"), target, function() clicked = clicked + 1 end, "off")
    b:initialise()
    b:instantiate()
    b.onOff = function() refused = refused + 1 end
    b:onMouseDown(5, 5)
    b:onMouseUp(5, 5)
    eq(clicked, 0); eq(refused, 1)
    b:setStyle("normal")
    b:onMouseDown(5, 5)
    b:onMouseUp(5, 5)
    eq(clicked, 1)
    b.tooltip = "Why it is off"
    b.mousePx = { 4, 4 }
    b:prerender()
    local tip
    for el in pairs(ui) do if el.Type == "PZUITip" then tip = el end end
    truthy(tip, "our tooltip is up")
    eq(tip.lines[1], "Why it is off")
    eq(tip.y, 10 + 26 + 8, "under the button")
    b.mousePx = nil
    b:prerender()
    eq(ui[tip], nil, "gone when the mouse leaves")
end)

test("our combo box: its list opens under it, a choice calls back, a click on the box closes it", function()
    local UI = load(16, { "PZUIKit/Combo" })
    UI.refreshScale()
    _G.getTimestampMs = function() return 5000 end
    local picked = {}
    local target = {}
    local combo = PZUICombo:new(20, 30, 150, 22, UI.palette("crude"), target, function(t, c) picked[#picked + 1] = c:getSelectedData() end)
    combo:initialise()
    combo:instantiate()
    combo:addOptionWithData("One", "a")
    combo:addOptionWithData("Two", "b")
    eq(combo:getSelectedData(), "a")
    combo:onMouseDown(5, 5)
    local list = combo.list
    truthy(list and ui[list], "open")
    eq(list.y, 30 + 22, "under the box")
    list:onMouseDown(5, list.rowH + 3)
    eq(picked[1], "b")
    eq(combo.list, nil)
    eq(ui[list], nil)
    -- open again; a click on the box comes to the list first (outside it) and closes it, and does not open it again
    combo:onMouseDown(5, 5)
    list = combo.list
    combo.mousePx = { 5, 5 }
    list:onMouseDownOutside()
    combo:onMouseDown(5, 5)
    eq(combo.list, nil, "closed, not opened again")
    combo:clear()
    eq(#combo.options, 0)
end)

test("the confirm is ours: its text broken to its width, yes runs the answer, no does not", function()
    local UI = load(16, { "PZUIKit/Confirm" })
    UI.refreshScale()
    local yes = 0
    local window = ISPanel:new(0, 0, 800, 600)
    window.palette = UI.palette("crude")
    local tab = ISPanel:new(0, 0, 10, 10)
    tab.parent = window
    local character = { getPlayerNum = function() return 0 end }
    local long = string.rep("word ", 30) .. "\nsecond line"
    local modal = UI.confirm(character, long, tab, function(t, a) yes = yes + a end, 5)
    truthy(ui[modal], "shown")
    eq(modal.palette, window.palette, "in the palette of the window it was asked from")
    truthy(#modal.lines >= 3, "broken to its width and at its line end")
    eq(modal.lines[#modal.lines], "second line")
    for _, line in ipairs(modal.lines) do truthy(UI.textWidth(line) <= PZUIConfirm.WIDTH - 20, line) end
    modal.yes.onclick(modal.yes.target, modal.yes)
    eq(yes, 5)
    eq(ui[modal], nil)
    modal = UI.confirm(character, "Sure?", nil, function() yes = yes + 100 end)
    eq(modal.palette, PZUIKit.UI.DEFAULT_PALETTE, "from the world: the kit's default")
    modal.no.onclick(modal.no.target, modal.no)
    eq(yes, 5)
end)

-- The folder's list ---------------------------------------------------------------------------------------------------

local function loadFolder(px)
    local UI = load(px or 16, { "OperationAcorn/Story/Folder" })
    _G.OATab = ISPanel:derive("OATab")
    function OATab:new(x, y, w, h, window)
        local o = ISPanel.new(self, x, y, w, h)
        o.window = window
        return o
    end
    function OATab:palette() return self.window.palette end
    function OATab:record() return self.window.record end
    function OATab:send(command, args) self.window.sent[#self.window.sent + 1] = command end
    UI.scaled(OATab, ISPanel)
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Story/TabFolder")
    require = real
    if not ok then error(err, 0) end
    UI.refreshScale()
    local Folder = OA.StoryFolder
    local groups = { { id = "radio", entries = {
        { key = "c:1", title = "First copy", tier = 2, isNew = false, seq = 1 },
        { key = "c:2", title = "Second copy", tier = 6, isNew = true, seq = 2 } } } }
    Folder.entries = function() return groups end
    Folder.content = function(_, entry) return { title = entry.title, meta = "meta", body = "Body", marked = "Body" } end
    local window = { palette = UI.palette("crude"), tier = "crude", record = OA.Store.ensure("f", "F"), sent = {} }
    local tab = OATabFolder:new(0, 0, 700, 300, window)
    tab:initialise()
    tab:instantiate()
    return UI, tab, groups
end

test("the folder's list is in the Medium font, its rows a line of it high", function()
    local UI, tab = loadFolder(16)
    tab:refresh()
    eq(OATabFolder.LIST_FONT, UIFont.Medium)
    eq(tab.rowH, math.ceil(UI.fontHeight(UIFont.Medium)) + OATabFolder.ROW_PAD)
    local list = tab.list
    list.drawn = {}
    local canvas = UI.designCanvas(list)
    OATabFolder.drawRow(canvas, 0, list.items[3])
    local fonts = {}
    for _, d in ipairs(list.drawn) do if d[1] == "text" or d[1] == "right" then fonts[#fonts + 1] = d[9] end end
    eq(#fonts, 2, "the title and its stage")
    eq(fonts[1], UIFont.Medium); eq(fonts[2], UIFont.Medium)
end)

test("a refresh that changes nothing the list shows leaves it as it was (a hurry click's answer, the typing's)", function()
    local _, tab, groups = loadFolder(16)
    tab:refresh()
    local list = tab.list
    eq(list.cleared, 1)
    local laid = tab.laidW
    tab.layout = function() error("laid out again") end
    for _ = 1, 3 do tab:refresh() end
    eq(list.cleared, 1, "not built again")
    -- what it lists changed: a document seen, its mark goes
    groups[1].entries[2].isNew = false
    tab:refresh()
    eq(list.cleared, 2)
    eq(tab.laidW, laid)
end)

test("the list built again counts its rows once: no scroll bar (nor stage labels moved) for a frame", function()
    local UI, tab, groups = loadFolder(16)
    tab:refresh()
    local list = tab.list
    local h = list:getScrollHeight()
    eq(h, 3 * list.itemheight)
    groups[1].entries[1].title = "Renamed"
    tab:refresh()
    eq(list:getScrollHeight(), h, "the old rows are not counted with the new")
    eq(list:isVScrollBarVisible(), false)
end)
