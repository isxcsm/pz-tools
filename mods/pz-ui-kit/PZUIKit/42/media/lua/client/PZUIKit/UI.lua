-- PZ UI Kit: what a mod's windows are drawn with: one scale for every screen, sharp texts in the extension API's UI
-- fonts, drawing in a palette, lights under the mouse and on a click, and the few game widgets kept (a list, a scroll
-- bar). Its widgets are Button.lua, Combo.lua, Confirm.lua, RichText.lua and the sub-tabs below. A palette is the
-- caller's: a table of colours { r, g, b } named bg, panel, text, dim, bright, value, head, border, warn, bad, good,
-- sel, title, dark, inset, off (see the README).
--
-- Sizes: design units and one scale ------------------------------------------------------------------------------
-- The kit's screens are laid out in DESIGN UNITS: the numbers written in the code, made for a 16 unit Small font.
-- UI.S is the scale from them to the screen's pixels, worked out again when a window opens (UI.refreshScale):
--   * with the extension API's UI fonts (PZExtAPI.text): by the SCREEN, its height / 540 down to an eighth
--     (720p 1.25, 900p 1.625, 1080p 2, 1440p 2.625, 2160p 4), or by the game's font where that is larger, so that the
--     windows look as big at the 16 pixel font as at the 26 pixel one;
--   * without them: by the game's FONT, the Small font's height / 16 (the font option follows the window's height:
--     16 pixels on a small screen, 19 at 1080p, 26 at 1440p, 38 at 4K). Never under 1.
-- Our texts are drawn in FACES (Faces.lua): with the API, its font of the design height times the scale (Small 16,
-- Medium 20, Large 24 units: 32, 40 and 48 pixels at 1080p); without, the game's own font of that name. The rule:
--   * Layout code writes plain design numbers and never multiplies by UI.S itself. Text is measured in design units
--     too, in its face (UI.textWidth, UI.fontHeight, UI.fit give the pixels / UI.S), so the Small font is 16 high in
--     them, give or take the font's own line.
--   * Our own elements (PZUISubTabs, PZUIButton, PZUICombo, PZUIRichText, PZUIConfirm, and every class a mod makes
--     with UI.scaled) are in design units through and through: their x, y, width and height, every draw* call and stencil,
--     getMouseX/Y and the coordinates their mouse handlers get. The class converts at the boundary with the game (the
--     javaObject), and draws its texts in their faces; the code in it does not.
--   * No game widget that draws text stands in our windows (it would draw in the game's font): buttons, combo boxes,
--     rich text, the confirm are ours (Button.lua, RichText.lua, Confirm.lua). The game's list (ISScrollingListBox) is kept for its scrolling, its rows drawn by us in
--     design units through UI.list or UI.rowPainter; UI.place, UI.size and UI.rowHeight take design numbers for it.
--   * A game window (an ISCollapsableWindow) is in pixels: its sizes are design sizes
--     made pixels with UI.px, its bars are as high as our Small face (UI.titleBarHeight), its title and close box are
--     drawn in our face (UI.windowTitle, UI.closeBox), and it hands its body to our elements in design units.
-- At UI.S == 1 without the API nothing is converted: the scaled classes are the plain game classes, and every number
-- is as written. Lines and borders stay one pixel wide at any scale (the game's own windows keep them so). Item icons
-- go through UI.icon / UI.iconPx.
require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "PZUIKit/Text"
require "PZUIKit/Faces"
local Kit = PZUIKit
local Faces = Kit.Faces
local KitText = Kit.Text
local UI = {}
Kit.UI = UI

-- The Small font's height the design units are made for.
UI.BASE_FONT = 16
UI.S = 1
-- A number that changes whenever the scale or the faces do: a window made before closes (its layout was measured in
-- the old ones).
UI.era = 0
UI.facesOn = false

-- The face for a screen's one big line (a welcome, a title): the API's Massive (32 design units) while our faces are
-- on, the game's Large otherwise (the game's Massive has no Korean letters).
function UI.titleFont()
    return UI.facesOn and UIFont.Massive or UIFont.Large
end
-- The scale as a local too: the drawing below reads it on every call. `on`: whether our classes convert (a scale that
-- is not 1, or the API's faces, which only our classes draw).
local S = 1
local on = false
-- font -> { its space, the space between parts } (UI.fontSpace), until the scale changes: the status header asks
-- each frame
local spaces = {}
-- Text measured once: font -> text -> width (design units), and face -> text -> width (pixels), until the scale or the
-- faces change; and the wraps and cuts made for the frames that draw the same text at the same width each time
-- (UI.wrapMemo, UI.fitMemo). Each table counts its own texts and, past CACHE_MAX (a counter's every number), starts
-- over alone: one that fills does not empty the others.
local widths, pixelWidths, wrapMemos, fitMemos = {}, {}, {}, {}
local widthCount, pixelCount, memoCount = 0, 0, { wrap = 0, fit = 0 }
local CACHE_MAX = 4000
local function forgetText()
    widths, pixelWidths, wrapMemos, fitMemos = {}, {}, {}, {}
    widthCount, pixelCount, memoCount = 0, 0, { wrap = 0, fit = 0 }
end
local floor = math.floor
local faceOf = Faces.face
local WHITE = { 1, 1, 1 }

-- A design number in pixels (rounded to whole pixels when scaled), and pixels in design units.
function UI.px(v)
    if S == 1 then return v end
    return floor(v * S + 0.5)
end

function UI.dp(v)
    if S == 1 then return v end
    return v / S
end

-- A design start and length as pixels: both ends rounded, so that rectangles side by side still meet.
local function span(a, len)
    local r = floor(a * S + 0.5)
    return r, floor((a + len) * S + 0.5) - r
end

-- What a class made with UI.scaled does while the scale is not 1 (at 1 the class is the plain game class).
local SCALED = {}

-- A table's own field. The game's Kahlua rawget looks through the metatable's __index as well (found running the
-- tests on the game's VM), so this goes through pairs.
local function own(t, key)
    for k, v in pairs(t) do
        if k == key then return v end
    end
    return nil
end

-- The mouse handlers the game calls with coordinates (local pixels, or pixels moved): an element of a scaled class
-- gets them in design units.
local MOUSE = { "onMouseDown", "onMouseUp", "onMouseDownOutside", "onMouseUpOutside", "onMouseMove",
    "onMouseMoveOutside", "onRightMouseDown", "onRightMouseUp", "onRightMouseDownOutside", "onRightMouseUpOutside", "onMouseDoubleClick" }

-- As ISUIElement.instantiate, with the place and size in pixels (the children are made after them, so that the
-- game's anchors start from the right size), and the mouse handlers given design coordinates.
function SCALED:instantiate()
    local jo = UIElement.new(self)
    self.javaObject = jo
    self.uiRX, self.uiRY = floor(self.x * S + 0.5), floor(self.y * S + 0.5)
    self.uiRW, self.uiRH = floor(self.width * S + 0.5), floor(self.height * S + 0.5)
    jo:setX(self.uiRX)
    jo:setY(self.uiRY)
    jo:setHeight(self.uiRH)
    jo:setWidth(self.uiRW)
    jo:setAnchorLeft(self.anchorLeft)
    jo:setAnchorRight(self.anchorRight)
    jo:setAnchorTop(self.anchorTop)
    jo:setAnchorBottom(self.anchorBottom)
    jo:setWantKeyEvents(self.wantKeyEvents or false)
    jo:setConsumeMouseEvents(self.wantMouseEvents or false)
    jo:setWantExtraMouseEvents(self.wantExtraMouseEvents or false)
    jo:setForceCursorVisible(self.forceCursorVisible or false)
    for _, name in ipairs(MOUSE) do
        local fn = self[name]
        if fn and own(self, name) == nil then
            self[name] = function(o, x, y) return fn(o, x / S, y / S) end
        end
    end
    self:createChildren()
end

-- The place and the size: kept in design units in the Lua fields, given to the game in pixels. A getter answers the
-- design number it was given while the game has not moved the element itself (an anchor following its parent).
function SCALED:setX(x)
    self.x = x
    local jo = self.javaObject
    if jo then
        self.uiRX = floor(x * S + 0.5)
        jo:setX(self.uiRX)
    end
end

function SCALED:setY(y)
    self.y = y
    local jo = self.javaObject
    if jo then
        self.uiRY = floor(y * S + 0.5)
        jo:setY(self.uiRY)
    end
end

function SCALED:setWidth(w)
    self.width = w
    local jo = self.javaObject
    if jo then
        self.uiRW = floor(w * S + 0.5)
        jo:setWidth(self.uiRW)
    end
end

function SCALED:setHeight(h)
    self.height = h
    local jo = self.javaObject
    if jo then
        self.uiRH = floor(h * S + 0.5)
        jo:setHeight(self.uiRH)
    end
end

local function javaOf(self)
    if self.javaObject == nil then self:instantiate() end
    return self.javaObject
end

function SCALED:getX()
    local r = javaOf(self):getX()
    if r == self.uiRX then return self.x end
    return r / S
end

function SCALED:getY()
    local r = javaOf(self):getY()
    if r == self.uiRY then return self.y end
    return r / S
end

function SCALED:getWidth()
    local r = javaOf(self):getWidth()
    if r == self.uiRW then return self.width end
    return r / S
end

function SCALED:getHeight()
    local r = javaOf(self):getHeight()
    if r == self.uiRH then return self.height end
    return r / S
end

function SCALED:getRight() return self:getX() + self:getWidth() end
function SCALED:getBottom() return self:getY() + self:getHeight() end
function SCALED:getMouseX() return self.uiBase.getMouseX(self) / S end
function SCALED:getMouseY() return self.uiBase.getMouseY(self) / S end

-- Drawing: rectangles by their rounded edges, texts at their rounded place in their own (pixel) font.
function SCALED:drawRect(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.uiBase.drawRect(self, rx, ry, rw, rh, a, r, g, b)
end

function SCALED:drawRectBorder(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.uiBase.drawRectBorder(self, rx, ry, rw, rh, a, r, g, b)
end

-- The "static" ones (the panel's own background and border, which do not scroll with its content).
function SCALED:drawRectStatic(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.uiBase.drawRectStatic(self, rx, ry, rw, rh, a, r, g, b)
end

function SCALED:drawRectBorderStatic(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.uiBase.drawRectBorderStatic(self, rx, ry, rw, rh, a, r, g, b)
end

-- The screen pixel an element's own pixel 0, 0 is drawn at: where UIElement.DrawText puts a text, its absolute place
-- and its scroll.
function UI.origin(el)
    local jo = el.javaObject
    return jo:getAbsoluteX() + jo:getXScroll(), jo:getAbsoluteY() + jo:getYScroll()
end

-- A text at pixels px, py of an element, in the face of `font` (nil: Small): left (align 0), centred on px (1), ending
-- at px (2), or untrimmed (3). `base` draws in pixels in the game's font (the element's class without the scaling).
-- ox, oy: UI.origin(el) when the caller has it (a list of many texts), else nil. An API face is drawn at the same
-- screen pixel the game's text would be, a centred one by half its width as the game's (whole pixels).
local function faceWidth(face, str)
    local known = pixelWidths[face]
    if not known then
        known = {}
        pixelWidths[face] = known
    end
    local w = known[str]
    if w == nil then
        if pixelCount >= CACHE_MAX then
            pixelWidths, pixelCount = {}, 0
            known = {}
            pixelWidths[face] = known
        end
        w = Faces.measure(face, str)
        known[str] = w
        pixelCount = pixelCount + 1
    end
    return w
end

-- What a window's fade (UI.fadeIn, UI.fadeOut) leaves of an alpha drawn on one of its elements: the alpha itself while
-- it is not fading. For what goes to the game's draws or a face straight (UI.textAtPx, UI.iconPx, a list of baked
-- steps), past the element's own draws, which the fade wraps.
function UI.faded(el, a)
    local root = el.uiFadeRoot
    local f = type(root) == "table" and root.uiFade
    if type(f) == "number" then return (a or 1) * f end
    return a or 1
end

-- An element's class's draws, not its own fields (where a fading window's element has the fade's wrappers): the base
-- class's on our scaled classes (in pixels), the class's on others (what its metatable reads through).
function UI.rawDraws(el)
    local base = el.uiBase
    if type(base) == "table" then return base end
    local mt = getmetatable(el)
    local index = mt and mt.__index
    if type(index) == "table" then return index end
    return el
end
local rawDraws = UI.rawDraws

local function textPx(el, base, str, px, py, r, g, b, a, font, align, ox, oy)
    local face = faceOf(font)
    local key = face.key
    if not key then
        if align == 0 then return base.drawText(el, str, px, py, r, g, b, a, face.font) end
        if align == 1 then return base.drawTextCentre(el, str, px, py, r, g, b, a, face.font) end
        if align == 2 then return base.drawTextRight(el, str, px, py, r, g, b, a, face.font) end
        return base.drawTextUntrimmed(el, str, px, py, r, g, b, a, face.font)
    end
    if align == 1 then
        px = px - floor(faceWidth(face, str) / 2)
    elseif align == 2 then
        px = px - faceWidth(face, str)
    end
    if not ox then
        local jo = el.javaObject
        ox, oy = jo:getAbsoluteX() + jo:getXScroll(), jo:getAbsoluteY() + jo:getYScroll()
    end
    Faces.draw(key, str, ox + px, oy + py, r, g, b, a)
end
UI.textPx = textPx

-- The faces from any element, in its own pixels (an element that is not one of our scaled classes, the game's window
-- of another part): a text at px, py in colour `c` ({ r, g, b }), and a text's width and a line's height in a face.
-- In design units, on our scaled classes, UI.text / textCentre / textRight and UI.textWidth / fontHeight are the same.
function UI.textAtPx(el, text, px, py, c, font, a, align)
    return textPx(el, rawDraws(el), text, px, py, c[1], c[2], c[3], UI.faded(el, a), font, align or 0)
end

function UI.faceWidthPx(text, font)
    return faceWidth(faceOf(font), text)
end

function SCALED:drawText(str, x, y, r, g, b, a, font)
    return textPx(self, self.uiBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 0)
end

function SCALED:drawTextCentre(str, x, y, r, g, b, a, font)
    return textPx(self, self.uiBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 1)
end

function SCALED:drawTextRight(str, x, y, r, g, b, a, font)
    return textPx(self, self.uiBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 2)
end

function SCALED:drawTextUntrimmed(str, x, y, r, g, b, a, font)
    return textPx(self, self.uiBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 3)
end

-- A texture at its own size is that many design units.
function SCALED:drawTexture(texture, x, y, a, r, g, b)
    if type(texture) == "string" then texture = getTexture(texture) end
    if not texture then return end
    local rx, rw = span(x, texture:getWidth())
    local ry, rh = span(y, texture:getHeight())
    return self.uiBase.drawTextureScaled(self, texture, rx, ry, rw, rh, a, r, g, b)
end

local function textureIn(name)
    return function(self, texture, x, y, w, h, a, r, g, b)
        local rx, rw = span(x, w)
        local ry, rh = span(y, h)
        return self.uiBase[name](self, texture, rx, ry, rw, rh, a, r, g, b)
    end
end
SCALED.drawTextureScaled = textureIn("drawTextureScaled")
SCALED.drawTextureScaledAspect = textureIn("drawTextureScaledAspect")
SCALED.drawTextureScaledAspect2 = textureIn("drawTextureScaledAspect2")
SCALED.drawTextureScaledAspect3 = textureIn("drawTextureScaledAspect3")

function SCALED:drawTextureScaledUniform(texture, x, y, scale, a, r, g, b)
    local rx, ry = floor(x * S + 0.5), floor(y * S + 0.5)
    return self.uiBase.drawTextureScaledUniform(self, texture, rx, ry, scale * S, a, r, g, b)
end

-- A tiled texture keeps its tiles' own size; only the area is scaled.
local function tiledIn(name)
    return function(self, texture, x, y, w, h, r, g, b, a)
        local rx, rw = span(x, w)
        local ry, rh = span(y, h)
        return self.uiBase[name](self, texture, rx, ry, rw, rh, r, g, b, a)
    end
end
SCALED.drawTextureTiled = tiledIn("drawTextureTiled")
SCALED.drawTextureTiledX = tiledIn("drawTextureTiledX")
SCALED.drawTextureTiledY = tiledIn("drawTextureTiledY")

-- A line from x, y to x2, y2 (the game's drawLine), its thickness scaled too (a whole number of pixels, at least one).
function SCALED:drawLine(texture, x, y, x2, y2, thickness, a, r, g, b)
    return self.uiBase.drawLine(self, texture, floor(x * S + 0.5), floor(y * S + 0.5), floor(x2 * S + 0.5),
        floor(y2 * S + 0.5), math.max(1, floor((thickness or 1) * S + 0.5)), a, r, g, b)
end

function SCALED:setStencilRect(x, y, w, h)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.uiBase.setStencilRect(self, rx, ry, rw, rh)
end

function SCALED:repaintStencilRect(x, y, w, h)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.uiBase.repaintStencilRect(self, rx, ry, rw, rh)
end

-- The drawing ones (a canvas over a game widget has these, and no place of its own).
local DRAWS = { "drawRect", "drawRectBorder", "drawRectStatic", "drawRectBorderStatic", "drawText", "drawTextCentre",
    "drawTextRight", "drawTextUntrimmed", "drawTexture", "drawTextureScaled", "drawTextureScaledAspect", "drawTextureScaledAspect2", "drawTextureScaledAspect3",
    "drawTextureScaledUniform", "drawTextureTiled", "drawTextureTiledX", "drawTextureTiledY", "drawLine", "setStencilRect",
    "repaintStencilRect" }

-- The classes made with UI.scaled, and which of the names above each takes (not one it defines itself).
local scaledClasses = {}

local function install(entry)
    local cls = entry.cls
    for _, name in ipairs(entry.names) do
        local now = own(cls, name)
        if now == nil or now == SCALED[name] then cls[name] = on and SCALED[name] or nil end
    end
end

-- Makes a class (derived from `base`, which keeps ISUIElement's instantiate: ISPanel, ISButton) work in design units,
-- with every class derived from it. Called once its methods are defined; returns the class.
function UI.scaled(cls, base)
    cls.uiScaled, cls.uiBase = true, base
    local names = {}
    for name in pairs(SCALED) do
        if own(cls, name) == nil then names[#names + 1] = name end
    end
    local entry = { cls = cls, names = names }
    scaledClasses[#scaledClasses + 1] = entry
    install(entry)
    return cls
end

-- Sets the scale (1 or more) and the faces: the API's (`useApi`, once Faces.available said yes), or the game's fonts
-- (false; nil keeps the faces' kind as it is). Returns false when the API's faces were asked for and could not be made
-- (the game's are set). The windows open at the time keep the scale they were made with: a window closes when UI.era
-- changes under it.
function UI.setScale(s, useApi)
    s = s or 1
    if useApi == nil then useApi = Faces.on end
    local made = Faces.build(s, useApi)
    forgetText()
    local now = s ~= 1 or Faces.on
    if s == S and now == on and Faces.on == UI.facesOn then return made end
    S, on = s, now
    UI.S, UI.facesOn = s, Faces.on
    UI.era = UI.era + 1
    spaces = {}
    for _, entry in ipairs(scaledClasses) do install(entry) end
    return made
end

-- The scale for the screen and the font in use now (a window calls this as it opens): by the screen with the API's
-- faces, by the Small font without (the rule block at the top).
function UI.refreshScale()
    local byFont = math.max(1, UI.fontHeightPx(UIFont.Small) / UI.BASE_FONT)
    if Faces.available() then
        local byScreen = Faces.screenScale(getCore():getScreenHeight())
        if UI.setScale(math.max(byScreen, byFont), true) then return end
    end
    UI.setScale(byFont, false)
end

-- A call of the API failed while drawing: the game's fonts and the font's scale (the open windows close by UI.era).
Faces.onFail = function() UI.refreshScale() end

-- Whether numbers for an element go in design units: inside one of our elements, while our classes convert.
local function designParent(parent)
    return on and parent ~= nil and parent.uiScaled == true
end

-- The draws, by the place of their alpha among their arguments.
local FADED = { drawRect = 5, drawRectBorder = 5, drawRectStatic = 5, drawRectBorderStatic = 5, drawText = 7,
    drawTextCentre = 7, drawTextRight = 7, drawTextUntrimmed = 7, drawTextZoomed = 8, drawTexture = 4,
    drawTextureScaled = 6, drawTextureScaledAspect = 6, drawTextureScaledAspect2 = 6, drawTextureScaledAspect3 = 6,
    drawTextureScaledUniform = 5, drawTextureTiled = 9, drawTextureTiledX = 9, drawTextureTiledY = 9, drawLine = 7 }
-- A draw whose alpha (its at-th argument) goes through scale(el, a): a window's fade on what is drawn in it.
local function fadedDraw(fn, at, scale)
    if at == 4 then
        return function(el, p1, p2, p3, a, ...) return fn(el, p1, p2, p3, scale(el, a), ...) end
    elseif at == 5 then
        return function(el, p1, p2, p3, p4, a, ...) return fn(el, p1, p2, p3, p4, scale(el, a), ...) end
    elseif at == 6 then
        return function(el, p1, p2, p3, p4, p5, a, ...) return fn(el, p1, p2, p3, p4, p5, scale(el, a), ...) end
    elseif at == 7 then
        return function(el, p1, p2, p3, p4, p5, p6, a, ...) return fn(el, p1, p2, p3, p4, p5, p6, scale(el, a), ...) end
    elseif at == 8 then
        return function(el, p1, p2, p3, p4, p5, p6, p7, a, ...)
            return fn(el, p1, p2, p3, p4, p5, p6, p7, scale(el, a), ...)
        end
    end
    return function(el, p1, p2, p3, p4, p5, p6, p7, p8, a) return fn(el, p1, p2, p3, p4, p5, p6, p7, p8, scale(el, a)) end
end

-- A canvas to draw on a game widget in design units (a row of a game list inside our element): the widget's fields
-- show through it, its width and height are in design units and its drawing converts (its texts in their faces),
-- through the widget's class's draws with the window's fade taken once (UI.faded: the canvas is no element of the
-- window, so the fade's wrappers do not reach it). While
-- our classes do not convert, or outside our
-- elements, the widget itself.
function UI.designCanvas(el)
    if not designParent(el.parent) then return el end
    local c = el.uiCanvas
    if not c then
        c = setmetatable({ uiBase = UI.rawDraws(el), uiDesign = true }, { __index = el })
        for _, name in ipairs(DRAWS) do
            local at = FADED[name]
            c[name] = at and fadedDraw(SCALED[name], at, UI.faded) or SCALED[name]
        end
        el.uiCanvas = c
    end
    c.width, c.height = el.width / S, el.height / S
    return c
end

-- Whether a row of a game list at pixel y (from the list's top, before its scroll) is outside what shows.
local function rowHidden(list, y, h)
    local at = y + list:getYScroll()
    return at + h < 0 or at >= list.height
end

-- A game list's doDrawItem drawing each row with drawRow(list, y, item, alt) in design units (the list as a canvas,
-- y from its top); it gives the list where the next row starts. A row outside the list's visible part is not drawn.
function UI.rowPainter(drawRow)
    return function(list, y, item, alt)
        if rowHidden(list, y, item.height) then return y + item.height end
        local c = UI.designCanvas(list)
        drawRow(c, c == list and y or y / S, item, alt)
        return y + item.height
    end
end

-- The height of a game list's rows (design units inside our elements).
function UI.rowHeight(list, h)
    if designParent(list.parent) then h = floor(h * S + 0.5) end
    list.itemheight = h
end

UI.PAD = 10

-- The room between a number and its unit ("627 credits"): the Korean small font's space is two or three pixels, too
-- thin to read as one.
UI.UNIT_GAP = 4

-- The palette for what is drawn outside a window with one (a question asked from the world): warm white and amber on
-- olive.
UI.DEFAULT_PALETTE = {
    bg = { 0.10, 0.11, 0.08 }, bgAlpha = 1, panel = { 0.15, 0.16, 0.12 },
    text = { 0.92, 0.90, 0.82 }, dim = { 0.62, 0.60, 0.52 }, bright = { 1, 0.98, 0.92 },
    value = { 1, 0.82, 0.25 }, head = { 1, 0.82, 0.25 }, border = { 0.42, 0.45, 0.30 },
    warn = { 1, 0.82, 0.25 }, bad = { 1, 0.45, 0.35 }, good = { 0.6, 0.95, 0.6 },
    sel = { 1, 0.82, 0.25 }, title = { 0.30, 0.33, 0.20 }, dark = { 0.10, 0.11, 0.08 },
    inset = { 0.06, 0.065, 0.045 }, off = { 0.45, 0.45, 0.40 }, tabStrip = { 0.30, 0.33, 0.20 },
}

-- Drawing with a palette colour: a filled rectangle, a border, a text (alpha optional).
-- Takes back a clip set with setStencilRect, given its rectangle again: inside another clip (a window's) the game
-- leaves its squares a level up, where a later clip in the window would let drawing through, so they are painted
-- back (as the game's lists do with doRepaintStencil).
function UI.unclip(el, x, y, w, h)
    el:clearStencilRect()
    el:repaintStencilRect(x, y, w, h)
end

function UI.fill(el, x, y, w, h, c, a)
    el:drawRect(x, y, w, h, a or 1, c[1], c[2], c[3])
end

function UI.frame(el, x, y, w, h, c, a)
    el:drawRectBorder(x, y, w, h, a or 1, c[1], c[2], c[3])
end

function UI.text(el, text, x, y, c, font, a)
    el:drawText(text, x, y, c[1], c[2], c[3], a or 1, font or UIFont.Small)
end

function UI.textCentre(el, text, x, y, c, font, a)
    el:drawTextCentre(text, x, y, c[1], c[2], c[3], a or 1, font or UIFont.Small)
end

function UI.textRight(el, text, x, y, c, font, a)
    el:drawTextRight(text, x, y, c[1], c[2], c[3], a or 1, font or UIFont.Small)
end

-- Text measured in pixels in the game's fonts, for what is drawn on the game's own widgets and windows outside ours
-- (the item tooltip, the loot window's estimate).
function UI.fontHeightPx(font)
    return getTextManager():getFontHeight(font or UIFont.Small)
end

function UI.textWidthPx(text, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, text)
end

-- Text measured in design units in its face (the face's pixels / UI.S): what our elements draw.
function UI.fontHeight(font)
    local h = Faces.height(font)
    if S == 1 then return h end
    return h / S
end

-- Texts of two faces on one baseline (a big number and its smaller unit): how far below the top of the line of `font`
-- the top of a line of `other` goes (design units, whole). UI.BASELINE is where the baseline sits in a face's line,
-- from its top.
UI.BASELINE = 0.8
function UI.baselineDrop(font, other)
    return math.floor((UI.fontHeight(font) - UI.fontHeight(other)) * UI.BASELINE + 0.5)
end

function UI.buttonHeight()
    return UI.fontHeight(UIFont.Small) + 10
end

-- Spaces at a text's end are measured as UI.spaceWidth each: they are not seen, they only place what comes after (a
-- label's value, the next part of a line), and the font's own space is narrower than the layout's scale at the larger
-- sizes ("합계 " then the sum came out as one word). Only a text that ends in a space pays for the look. A text of
-- spaces only (a gap asked for between two parts, a bullet's hang) is that many UI.spaceWidth: measured, it has no
-- letter's image to end at.
local function trailingMore(text, font)
    if string.byte(text, -1) ~= 32 then return 0 end
    local trail = #string.match(text, " *$")
    return trail * math.max(0, UI.spaceWidth(font) - UI.fontSpace(font))
end

local function measureDesign(text, font)
    if text and text ~= "" and string.match(text, "^ +$") then return #text * UI.spaceWidth(font) end
    local w = Faces.measure(faceOf(font), text)
    if S ~= 1 then w = w / S end
    if text and text ~= "" then w = w + trailingMore(text, font) end
    return w
end

function UI.textWidth(text, font)
    if text == nil then return measureDesign(text, font) end
    local key = font or UIFont.Small
    local known = widths[key]
    if not known then
        known = {}
        widths[key] = known
    end
    local w = known[text]
    if w == nil then
        if widthCount >= CACHE_MAX then
            widths, widthCount = {}, 0
            known = {}
            widths[key] = known
        end
        w = measureDesign(text, font)
        known[text] = w
        widthCount = widthCount + 1
    end
    return w
end

-- A space between two parts drawn apart (a label and its value), in design units: the font's space, or a quarter of
-- the font's height where that is wider (the 26-pixel Korean font's space is 4 pixels, a sixth of its height). The
-- font's space is measured between two letters: a text is measured to the end of its last letter's image, so a space
-- or a "·" alone measures short of how far it moves the next letter.
function UI.fontSpace(font)
    font = font or UIFont.Small
    local known = spaces[font]
    if not known then
        local space = UI.textWidth("x x", font) - UI.textWidth("xx", font)
        known = { space, math.max(space, UI.fontHeight(font) / 4) }
        spaces[font] = known
    end
    return known[1]
end

function UI.spaceWidth(font)
    UI.fontSpace(font)
    return spaces[font or UIFont.Small][2]
end

-- For a text drawn as one part of a line (a label, then its value in another colour): what its spaces at the start add
-- to make each UI.spaceWidth, as the shift to draw it at and as what its width gains (the spaces at its end are in
-- UI.textWidth already). The text is drawn whole, its spaces with it: a text is measured to the end of its last
-- letter's image, so one cut before its spaces would measure short of where that letter moves the next.
function UI.spaceGaps(text, font)
    text = text or ""
    if string.byte(text, 1) ~= 32 then return 0, 0 end
    local lead = #string.match(text, "^ *")
    if lead == #text then return 0, 0 end
    local more = lead * math.max(0, UI.spaceWidth(font) - UI.fontSpace(font))
    return more, more
end

-- A text broken into lines no wider than `width` (design units) at its spaces, and at its line ends ("\n"). A word
-- wider than the width by itself stays whole on its own line, as the game's rich text keeps it. (PZUIKit.Text.wrap; a
-- margin, because a width in design units can be a fraction a hair under the text's own.)
local WRAP = { eps = 0.001, paragraphs = true }
function UI.wrap(text, width, font)
    return KitText.wrap(text, width, UI.textWidth, WRAP, font)
end

-- The text cut to a width with "..." at the end (whole when it fits). The game's strings are per character, so a cut
-- never splits a letter. (with a margin: a width in design units can be a fraction a hair under the text's own)
function UI.fit(text, width, font)
    return KitText.fitText(text, width, UI.textWidth, 0.001, font)
end

-- The same in pixels.
function UI.fitPx(text, width, font)
    return KitText.fitText(text, width, UI.textWidthPx, 0.001, font)
end

-- getText for what a frame draws: the translation of a key (with up to two arguments), asked of the game once. The
-- language does not change under the running game.
local strings = {}
local NONE = {}
local stringCount = 0
function UI.str(key, a, b)
    local byKey = strings[key]
    if not byKey then
        byKey = {}
        strings[key] = byKey
    end
    local ka = a == nil and NONE or a
    local byA = byKey[ka]
    if not byA then
        byA = {}
        byKey[ka] = byA
    end
    local kb = b == nil and NONE or b
    local s = byA[kb]
    if s == nil then
        if stringCount >= CACHE_MAX then
            strings, stringCount = {}, 0
        end
        s = getText(key, a, b)
        byA[kb] = s
        stringCount = stringCount + 1
    end
    return s
end

-- The wrap and the cut kept for a text drawn at the same width every frame: the lines are the memo's own, read, not
-- changed. Made again when the scale changes.
local function memoOf(memos, kind, font, text)
    local key = font or UIFont.Small
    local byFont = memos[key]
    if not byFont then
        byFont = {}
        memos[key] = byFont
    end
    local byText = byFont[text]
    if not byText then
        if memoCount[kind] >= CACHE_MAX then
            for each in pairs(memos) do memos[each] = nil end
            memoCount[kind] = 0
            return nil
        end
        byText = {}
        byFont[text] = byText
        memoCount[kind] = memoCount[kind] + 1
    end
    return byText
end

function UI.wrapMemo(text, width, font)
    local byText = memoOf(wrapMemos, "wrap", font, text)
    if not byText then return UI.wrap(text, width, font) end
    local lines = byText[width]
    if not lines then
        lines = UI.wrap(text, width, font)
        byText[width] = lines
    end
    return lines
end

function UI.fitMemo(text, width, font)
    local byText = memoOf(fitMemos, "fit", font, text)
    if not byText then return UI.fit(text, width, font) end
    local cut = byText[width]
    if not cut then
        cut = UI.fit(text, width, font)
        byText[width] = cut
    end
    return cut
end

-- One dot of the small signs drawn from rectangles, in design units: round(S) pixels, so that their strokes thicken
-- with the scale and stay even (a one-pixel line stays one pixel, the rule for borders).
function UI.dot()
    return math.max(1, math.floor(S + 0.5)) / S
end

-- A small padlock drawn from rectangles (the fonts have no glyph for one), 8 dots wide and 9 high from x, y.
function UI.lock(el, x, y, c, a)
    local u = UI.dot()
    UI.fill(el, x + 2 * u, y, 4 * u, u, c, a)
    UI.fill(el, x + 2 * u, y, u, 4 * u, c, a)
    UI.fill(el, x + 5 * u, y, u, 4 * u, c, a)
    UI.fill(el, x, y + 4 * u, 8 * u, 5 * u, c, a)
end

-- A row of sub-tabs: boxes side by side, the chosen one filled. `items` = { { id, label, lock (a padlock before the
-- name), badge (a text on a filled chip after it), dot ("new" or "bad"), tip (a tooltip, PZUITip: Button.lua) } }; a
-- click calls onSelect(target, id).
PZUISubTabs = ISPanel:derive("PZUISubTabs")

function PZUISubTabs:new(x, y, width, palette, target, onSelect)
    local o = ISPanel:new(x, y, width, UI.fontHeight() + 6)
    setmetatable(o, self)
    self.__index = self
    o.background = false
    o.palette = palette
    o.target, o.onSelect = target, onSelect
    o.items, o.slots = {}, {}
    return o
end

function PZUISubTabs:setItems(items, active)
    self.items, self.active = items, active
end

function PZUISubTabs:prerender()
    local p = self.palette
    local fh = UI.fontHeight()
    local h = self.height
    local x = 0
    local mx = self:isMouseOver() and self:getMouseX() or -1
    local slots, n = self.slots, 0
    local tipped = nil
    for _, item in ipairs(self.items) do
        local on = item.id == self.active
        local lw = UI.textWidth(item.label)
        local bw = lw + 32
        if item.lock then bw = bw + 12 end
        local badgeW = item.badge and UI.textWidth(item.badge) + 10 or 0
        if item.badge then bw = bw + badgeW + 4 end
        -- one under the mouse lights up, a clicked one flashes (the hover and press lights below)
        local over = mx >= x and mx < x + bw
        if over and item.tip then tipped = item.tip end
        local k = UI.hoverLight(self, item.id, not on and over)
        local f = UI.flashLevel(self, item.id)
        if on then
            UI.fill(self, x, 0, bw, h, p.sel, 0.2)
            UI.frame(self, x, 0, bw, h, p.sel)
        else
            if p.panel then UI.fill(self, x, 0, bw, h, p.panel) end
            if k > 0 then UI.fill(self, x, 0, bw, h, p.sel, 0.1 * k) end
            UI.frame(self, x, 0, bw, h, p.border)
            if k > 0 then UI.frame(self, x, 0, bw, h, p.sel, 0.6 * k) end
        end
        if f > 0 then UI.fill(self, x, 0, bw, h, p.sel, 0.3 * f) end
        local lx = x + 16
        if item.lock then
            UI.lock(self, lx, (h - 9) / 2, p.warn, 0.9)
            lx = lx + 12
        end
        UI.text(self, item.label, lx, (h - fh) / 2, on and p.bright or p.text)
        if item.badge then
            local bx = lx + lw + 8
            UI.fill(self, bx, 4, badgeW, h - 8, p.sel, 0.85)
            UI.textCentre(self, item.badge, bx + badgeW / 2, (h - fh) / 2, p.dark)
        end
        if item.dot then UI.fill(self, x + bw - 8, 4, 4, 4, item.dot == "bad" and p.bad or p.warn) end
        n = n + 1
        local slot = slots[n]
        if not slot then
            slot = {}
            slots[n] = slot
        end
        slot.id, slot.x, slot.w = item.id, x, bw
        x = x + bw + 4
    end
    for i = #slots, n + 1, -1 do slots[i] = nil end
    if PZUITip then
        if tipped then PZUITip.show(self, tipped, p) else PZUITip.hide(self) end
    end
end

function PZUISubTabs:onMouseDown(x, y)
    for _, slot in ipairs(self.slots) do
        if x >= slot.x and x < slot.x + slot.w then
            UI.flash(self, slot.id)
            if self.onSelect then self.onSelect(self.target, slot.id) end
            return true
        end
    end
    return true
end

UI.scaled(PZUISubTabs, ISPanel)

-- The numbers for a game widget in `parent`: design units made pixels inside our elements, else as they are.
local function inParent(parent, ...)
    if not designParent(parent) then return ... end
    local out = { ... }
    for i = 1, select("#", ...) do out[i] = floor(out[i] * S + 0.5) end
    return unpack(out)
end

-- Places and sizes an element (a nil leaves that number as it is): one of ours in its design units, a game widget
-- inside ours from design units to pixels, any other as it is. The size goes through UI.size.
function UI.place(el, x, y, w, h)
    if not el.uiScaled and designParent(el.parent) then
        if x then x = floor(x * S + 0.5) end
        if y then y = floor(y * S + 0.5) end
        if w then w = floor(w * S + 0.5) end
        if h then h = floor(h * S + 0.5) end
    end
    if x then el:setX(x) end
    if y then el:setY(y) end
    if w then UI.sizePx(el, w, h) end
end

-- Sizes an element (design units for ours and for a game widget inside ours, as UI.place).
function UI.size(el, w, h)
    UI.place(el, nil, nil, w, h)
end

-- Sizes an element in its own numbers and places its vertical scroll bar along its right edge. The game moves a scroll
-- bar by its anchors, by the change since the element's size was last set; a layout that sets a size twice in a frame
-- leaves that change at nothing and the bar at its old height. So the bar is unanchored and placed here.
function UI.sizePx(el, w, h)
    el:setWidth(w)
    el:setHeight(h)
    local bar = el.vscroll
    if bar then
        bar:setAnchorRight(false)
        bar:setAnchorBottom(false)
        bar:setX(w - 16)
        bar:setHeight(h)
        UI.styleScrollBar(bar)
    end
end

-- The palette of the window an element is in (a window keeps it as a table, `palette`), or nil.
local function paletteOf(el)
    local at = el
    while at do
        if type(at.palette) == "table" then return at.palette end
        at = at.parent
    end
    return nil
end
UI.paletteOf = paletteOf

-- A vertical scroll bar drawn in the window's palette: a thin track, the thumb and two small arrows, where the game's
-- grey textures stand out on a palette. The thumb's place and size are the game's own (barx, bary, barwidth and
-- barheight are what its clicks and drags read).
local function renderBar(self)
    local p = self.uiPalette
    local sh = self.parent:getScrollHeight()
    local h = self:getHeight()
    if sh <= h then
        self.barx, self.bary, self.barwidth, self.barheight = 0, 0, 0, 0
        return
    end
    local box = math.max(8, math.ceil(h / sh * (h - 32)))
    local dif = math.ceil((h - 32 - box) * self.pos)
    self.barx, self.bary, self.barwidth, self.barheight = 5, 16 + dif, 8, box
    local over = self.scrolling or (self:isMouseOver() and self:isPointOverThumb(self:getMouseX(), self:getMouseY()))
    local c, t = p.border, over and p.text or p.border
    self:drawRect(7, 16, 4, h - 32, 0.25, c[1], c[2], c[3])
    self:drawRect(6, self.bary, 6, box, 0.95, t[1], t[2], t[3])
    -- the arrows: a small triangle at each end
    for i = 0, 3 do
        self:drawRect(9 - i, 5 + i, 1 + 2 * i, 1, 0.9, c[1], c[2], c[3])
        self:drawRect(9 - i, h - 6 - i, 1 + 2 * i, 1, 0.9, c[1], c[2], c[3])
    end
end

-- Draws a scroll bar in the palette of its window (once; a bar outside a window with a palette keeps the game's look).
function UI.styleScrollBar(bar)
    if bar.uiPalette or not bar.vertical then return end
    local p = paletteOf(bar.parent)
    if not p then return end
    bar.uiPalette = p
    bar.render = renderBar
end

-- The scroll bars of our own scrolling elements (a rich text, a page of cards): an element
-- with `height`, `scroll`, maxScroll() and setScroll(v) shows a thumb on a bar along its right edge.
-- The thumb for `h` visible of `full` content at `scroll` of at most `max`: its top and its height (`least` high at
-- the least, 20 when not given).
function UI.thumb(h, full, scroll, max, least)
    local th = math.max(least or 20, floor(h * h / full))
    return max > 0 and floor((h - th) * scroll / max) or 0, th
end

-- A bar on the right of `el`, `w` wide at `x`: the track faintly, then the thumb (top ty, height th), in colour c.
function UI.drawBar(el, x, w, h, ty, th, c)
    UI.fill(el, x, 0, w, h, c, 0.25)
    UI.fill(el, x, ty, w, th, c, 0.95)
end

-- A click at y on the bar of `el` (which has thumb() as UI.thumb): the thumb goes there unless the click is on it; a
-- drag starts. And the drag by dy.
function UI.barPress(el, y)
    local ty, th = el:thumb()
    if y < ty or y >= ty + th then
        el:setScroll((y - th / 2) * el:maxScroll() / math.max(1, el.height - th))
    end
    el.dragging = true
end

function UI.barDrag(el, dy)
    if not el.dragging then return end
    local _, th = el:thumb()
    el:setScroll(el.scroll + dy * el:maxScroll() / math.max(1, el.height - th))
end

-- A list with rows drawn by `drawRow(list, y, item, alt)` (inside our elements in design units and faces: the list is
-- then a canvas over the game's list, UI.designCanvas). The row's own height is the list's itemheight (UI.rowHeight).
function UI.list(parent, x, y, width, height, drawRow, target, onclick)
    local list = ISScrollingListBox:new(inParent(parent, x, y, width, height))
    list:initialise()
    list:instantiate()
    list.font = UIFont.Small
    list.fontHgt = UI.fontHeightPx(UIFont.Small)
    list.itemPadY = 3
    list.itemheight = list.fontHgt + list.itemPadY * 2 + 2
    list.drawBorder = true
    -- the row under the mouse lights up and a clicked one flashes (UI.placeLight: the rows by their index)
    local basePrerender, baseMouseDown = list.prerender, list.onMouseDown
    list.prerender = function(self)
        local over = self.mouseoverselected
        if not (over and over > 0 and over ~= self.selected and self:isMouseOver() and not self:isMouseOverScrollBar()) then
            over = nil
        end
        UI.placeLight(self, over)
        return basePrerender(self)
    end
    list.onMouseDown = function(self, x, y)
        local row = self:rowAt(x, y)
        if row and row > 0 then UI.placeFlash(self, row) end
        return baseMouseDown(self, x, y)
    end
    list.doDrawItem = function(self, rowY, item, alt)
        if rowHidden(self, rowY, item.height) then return rowY + item.height end
        if self.selected == item.index then
            self:drawSelection(0, rowY, self:getWidth(), item.height - 1)
        end
        local k, f = UI.placeLevels(self, item.index)
        local c = self.mouseOverHighlightColor
        if (k > 0 or f > 0) and c then
            self:drawRect(0, rowY, self:getWidth(), item.height - 1, c.a * k + 0.15 * f, c.r, c.g, c.b)
        end
        local canvas = UI.designCanvas(self)
        drawRow(canvas, canvas == self and rowY or rowY / S, item, alt)
        return rowY + item.height
    end
    if onclick then list:setOnMouseDownFunction(target, onclick) end
    parent:addChild(list)
    -- its scroll bar in the palette of the window it is in (UI.styleScrollBar)
    if list.vscroll then UI.styleScrollBar(list.vscroll) end
    return list
end

-- Item icons ---------------------------------------------------------------------------------------------------------
-- Every item icon in our windows is drawn through these two (so that one change can draw them at whole multiples of
-- their 32 pixel pictures): UI.icon in design units on our elements (the pixels of others), UI.iconPx in the element's
-- pixels (the status lists' baked steps). `tint` is { r, g, b } (nil: none), the picture kept to its aspect.

-- The design size nearest `want` (and no more than `most`, when given) at which a 32 pixel icon is drawn a whole number
-- of times its size: drawn at any other size the picture is blurred (and shimmers when shrunk; the textures have no
-- mipmaps), so a place that shows an icon on its own takes its size from here.
function UI.iconSize(want, most)
    local k = math.max(1, floor(want * S / 32 + 0.5))
    if most then
        while k > 1 and k * 32 / S > most do k = k - 1 end
    end
    return k * 32 / S
end

function UI.iconPx(el, texture, px, py, pw, ph, a, tint)
    if not texture then return end
    local t = tint or WHITE
    rawDraws(el).drawTextureScaledAspect(el, texture, px, py, pw, ph, UI.faded(el, a), t[1], t[2], t[3])
end

function UI.icon(el, texture, x, y, size, a, tint)
    if not texture then return end
    if on and (el.uiScaled or el.uiDesign) then
        local rx, rw = span(x, size)
        local ry, rh = span(y, size)
        return UI.iconPx(el, texture, rx, ry, rw, rh, a, tint)
    end
    UI.iconPx(el, texture, x, y, size, size, a, tint)
end

-- Our game windows' bars --------------------------------------------------------------------------------------------
-- A mod's windows are the game's (ISCollapsableWindow), in pixels. Their bars
-- are as high as our Small face, worked out as the game works its own out from its font (without the API's faces the
-- same numbers), and what the game would draw on them in its font is drawn in ours.

-- The title bar's height and the resize bar's (ISCollapsableWindow's titleBarHeight and resizeWidgetHeight).
function UI.titleBarHeight()
    return math.max(16, Faces.height() + 1)
end

function UI.resizeWidgetHeight()
    return (Faces.height() + 6) / 2 + 2
end

-- A window's title centred on its bar in our face, colour `c` ({ r, g, b }).
function UI.windowTitle(win, title, c, a)
    if not title or title == "" then return end
    local th = win:titleBarHeight()
    textPx(win, rawDraws(win), title, floor(win.width / 2), floor((th - Faces.height()) / 2 + 0.5), c[1], c[2], c[3],
        UI.faded(win, a), nil, 1)
end

-- The close box: an "x" in our face (the game's button with its picture and title taken off), in the palette.
local function closeBoxRender(self)
    local c = self.uiGlyphColour
    textPx(self, rawDraws(self), "x", floor(self.width / 2), floor((self.height - Faces.height()) / 2), c[1], c[2], c[3],
        UI.faded(self, 1), nil, 1)
end

function UI.closeBox(win, p)
    local cb = win.closeButton
    if not cb then return end
    cb:setImage(nil)
    cb:setTitle("")
    cb.uiGlyphColour = p.text
    cb.borderColor = { r = p.border[1], g = p.border[2], b = p.border[3], a = 1 }
    cb.backgroundColorMouseOver = { r = p.sel[1], g = p.sel[2], b = p.sel[3], a = 0.25 }
    cb.render = closeBoxRender
end

-- Drawing that follows the clock ----------------------------------------------------------------------------------
-- PZ Optimization's retained UI (on in its default profile) replays an element's last drawing while nothing it watches
-- has changed: input, the mouse over it, its size or place, a write to its Lua table made before it draws. Once a
-- drawing has held still for a quarter second it is drawn afresh only now and then, up to a second apart, so a drawing
-- that changes by the clock after a pause (a cursor's blink, a line printed on time, a stage of a sequence) would show
-- up to a second late. Such an element registers here with `frame(el, now)`: it does what the element needs every frame
-- and gives a value that changes exactly when the element's drawing does, nil once it no longer moves by itself. Every
-- frame, before the UI draws, a changed value is written to the element (liveLook) and a count to each element it is
-- in (a window held still is replayed with all it holds). An element no longer on show is let go. The handler stays on
-- once used: taking it off from inside the event would make the game skip the next handler of that frame, and with
-- nothing registered it returns at once.
local live, liveHooked, liveCount = {}, false, 0
-- The entries by element and frame function, for the once of UI.live.
local liveOf = {}

-- Whether the element and every element it is in are on show.
local function onShow(el)
    while el do
        if not el:isVisible() then return false end
        el = el.parent
    end
    return true
end

-- An element may be followed for several things at once (its lights, a slide, a glide), each its own entry: one
-- that stops does not let the others go. The element's liveLook is the look of one entry still going (the last that
-- changed), nil once none is; its liveTick changes with any.
local function liveFrame()
    if live[1] == nil then return end
    local now = getTimestampMs()
    for i = #live, 1, -1 do
        local entry = live[i]
        local el = entry.el
        local look = onShow(el) and entry.frame(el, now) or nil
        if look ~= entry.look then
            entry.look = look
            liveCount = liveCount + 1
            el.liveTick = liveCount
            if look ~= nil then
                el.liveLook = look
            else
                local other
                for _, each in ipairs(live) do
                    if each.el == el and each ~= entry and each.look ~= nil then other = each.look end
                end
                el.liveLook = other
            end
            local parent = el.parent
            while parent do
                parent.liveCount = liveCount
                parent = parent.parent
            end
        end
        if look == nil then
            table.remove(live, i)
            liveOf[el][entry.frame] = nil
        end
    end
end
UI.liveFrame = liveFrame

-- Follows an element for a frame function from the next frame on; the same element and function once.
function UI.live(el, frame)
    local frames = liveOf[el]
    if not frames then
        frames = {}
        liveOf[el] = frames
    elseif frames[frame] then
        return
    end
    if not liveHooked then
        Events.OnPreUIDraw.Add(liveFrame)
        liveHooked = true
    end
    local entry = { el = el, frame = frame }
    frames[frame] = entry
    live[#live + 1] = entry
end

-- Fading in and out ---------------------------------------------------------------------------------------------------
-- A window comes up over FADE_IN_MS (UI.fadeIn) and goes over FADE_OUT_MS (UI.fadeOut): all it and its children draw
-- is the more transparent the nearer the fade's dark end, easing at both ends (a fast linear fade read as the window
-- breaking up). While it fades, each element in it draws through wrappers of
-- its draws, instance fields over its class's that scale their alpha by the window's uiFade; they go once it is whole
-- again, so a window that is not fading draws as ever at no cost. Going, it takes no clicks and its elements do
-- nothing each frame (update); it is taken away at the end. A window can also be thinned and kept so (UI.fadeTo: while
-- the character works behind it), its draws wrapped until it is whole again.
UI.FADE_IN_MS, UI.FADE_OUT_MS = 300, 240

-- What a going window's elements stop doing.
local STILLED = { "onMouseDown", "onMouseUp", "onRightMouseDown", "onRightMouseUp", "onMouseWheel",
    "onMouseDoubleClick", "update" }

local function swallow() return true end

local fadeFrame

-- An instance field set over the class's, kept to be put back (false: there was none). The element's own fields are
-- read by going over them (the game's rawget reads through to the class), once when it is wrapped.
local function override(el, name, fn)
    local kept = el.uiFadeKept
    if kept[name] == nil then kept[name] = el.uiFadeOwn[name] or false end
    el[name] = fn
end

-- The window's elements, each wrapped once (new ones as they come); going, stilled too.
local function wrap(el, root, going)
    if el.uiFadeRoot ~= root then
        local owned = {}
        for key, value in pairs(el) do
            if type(value) == "function" then owned[key] = value end
        end
        el.uiFadeRoot, el.uiFadeKept, el.uiFadeOwn = root, {}, owned
        local scale = function(_, a) return (a or 1) * root.uiFade end
        for name, at in pairs(FADED) do
            local fn = el[name]
            if fn then override(el, name, fadedDraw(fn, at, scale)) end
        end
        if el ~= root then UI.live(el, fadeFrame) end
        -- An element added to this one while the window fades is wrapped at the next step (not before).
        local addChild = el.addChild
        if addChild then
            override(el, "addChild", function(self, ...)
                root.uiFadeWalk = true
                return addChild(self, ...)
            end)
        end
        if el.Type == "ISTextEntryBox" then
            local boxes = root.uiTextBoxes or {}
            root.uiTextBoxes = boxes
            boxes[#boxes + 1] = el
        end
    end
    if going and not el.uiStilled then
        el.uiStilled = true
        for _, name in ipairs(STILLED) do override(el, name, name == "update" and function() end or swallow) end
    end
    for _, child in pairs(el.children or {}) do wrap(child, root, going) end
end

local function unwrap(el)
    local kept = el.uiFadeKept
    if kept then
        for name, prev in pairs(kept) do
            if prev then el[name] = prev else el[name] = nil end
        end
        el.uiFadeKept, el.uiFadeRoot, el.uiFadeOwn, el.uiStilled = nil, nil, nil, nil
    end
    for _, child in pairs(el.children or {}) do unwrap(child) end
end

-- The game's text boxes in a fading window draw their text in Java, past every draw here: their text colour (white, as
-- the game makes it) takes the fade, and is whole again at its end.
local function fadeTextBoxes(root, f)
    local boxes = root.uiTextBoxes
    if not boxes then return end
    local colour = root.uiTextColour or ColorInfo.new(1, 1, 1, 1)
    root.uiTextColour = colour
    for _, box in ipairs(boxes) do
        if box.javaObject then box.javaObject:setTextColor(colour:set(1, 1, 1, f)) end
    end
end

-- The window's step of its fade, which its elements follow to be drawn again.
fadeFrame = function(el, now)
    local root = el.uiFadeRoot
    return root and root.uiFadeKey or nil
end

local function fadeStep(root, now)
    local fade = root.uiFading
    if not fade then return nil end
    local t = fade.ms > 0 and (now - fade.at) / fade.ms or 1
    -- Thinned and kept so: once more drawn at the end, then left wrapped as it is.
    if t >= 1 and fade.hold then
        if root.uiFade == fade.to then
            root.uiFading, root.uiFadeKey = nil, nil
            return nil
        end
        root.uiFade, root.uiFadeKey = fade.to, 100
        fadeTextBoxes(root, fade.to)
        return root.uiFadeKey
    end
    if t >= 1 then
        root.uiFading, root.uiFadeKey = nil, nil
        if fade.done then
            root.uiGone = true
            root.uiFade = 0
            fade.done(root)
        end
        fadeTextBoxes(root, 1)
        root.uiTextBoxes = nil
        unwrap(root)
        root.uiFade = nil
        return nil
    end
    local e = t * t * (3 - 2 * t)
    root.uiFade = fade.from + (fade.to - fade.from) * e
    root.uiFadeKey = math.floor(t * 100)
    if root.uiFadeWalk then
        root.uiFadeWalk = nil
        wrap(root, root, fade.done ~= nil)
    end
    fadeTextBoxes(root, root.uiFade)
    return root.uiFadeKey
end

-- Fades a window in from nothing, from now (called as it is put up).
function UI.fadeIn(el, ms)
    el.uiFade, el.uiGone = 0, nil
    el.uiFading = { at = getTimestampMs(), ms = ms or UI.FADE_IN_MS, from = 0, to = 1 }
    el.uiFadeKey = 0
    wrap(el, el, false)
    UI.live(el, fadeStep)
end

-- Thins a window to `to` (0 to 1) over the fade-in's time (a part of it for a shorter way) and keeps it there, still
-- taking clicks; brought back to 1 it draws as ever again. Nothing while it goes.
function UI.fadeTo(el, to, ms)
    local fading = el.uiFading
    if el.uiGone or fading and fading.done then return end
    local from = el.uiFade or 1
    if from == to and not fading then return end
    el.uiFade = from
    el.uiFading = { at = getTimestampMs(), ms = (ms or UI.FADE_IN_MS) * math.abs(to - from), from = from, to = to,
        hold = to < 1 }
    el.uiFadeKey = 0
    wrap(el, el, false)
    UI.live(el, fadeStep)
end

-- A window over the character while they work for it (a timed action it queued): it thins to UI.ASIDE so that the work
-- and its progress bar show through it, and is whole again once the action is done or dropped, each change over
-- UI.ASIDE_MS. UI.aside(el, action) as the window queues it (nothing when it was not queued); UI.stepAside(el, hold)
-- from its update (hold: whole meanwhile, as while a picker of its is open).
UI.ASIDE, UI.ASIDE_MS = 0.15, 200

function UI.stepAside(el, hold)
    if el.uiBusy and not ISTimedActionQueue.hasAction(el.uiBusy) then el.uiBusy = nil end
    local aside = el.uiBusy ~= nil and not hold
    if aside == (el.uiAside == true) then return end
    el.uiAside = aside
    UI.fadeTo(el, aside and UI.ASIDE or 1, UI.ASIDE_MS)
end

function UI.aside(el, action)
    if action and ISTimedActionQueue.hasAction(action) then el.uiBusy = action end
    UI.stepAside(el)
end

-- Fades a window out and then takes it away (`done`, by default hidden and out of the UI manager); from where it
-- is when it was still fading in or held thinned (UI.fadeTo). Once: again while it goes, or once it is gone, nothing.
function UI.fadeOut(el, done, ms)
    local fading = el.uiFading
    if el.uiGone or fading and fading.done then return end
    local from = el.uiFade or 1
    el.uiFade = from
    el.uiFading = { at = getTimestampMs(), ms = (ms or UI.FADE_OUT_MS) * from, from = from, to = 0,
        done = done or function(window)
            window:setVisible(false)
            window:removeFromUIManager()
        end }
    el.uiFadeKey = 0
    wrap(el, el, true)
    UI.live(el, fadeStep)
end

-- Hover and press lights ----------------------------------------------------------------------------------------------
-- What our clickable things show of the mouse: a light that comes up over HOVER_IN_MS when the mouse comes onto one and
-- goes down over HOVER_OUT_MS when it leaves, and a flash on a click that dies out over FLASH_MS (easing out). Each light
-- is kept on its element (el.fx[key] for the hover, el.fxFlash[key] for the flash, so that one key can have both:
-- where it set off from, where it goes, when); its level is worked out from the
-- clock when drawn. While one moves the element is followed each frame (UI.live: PZ Optimization draws the steps);
-- once they are all still it is let go. Made only when a light changes; nothing is kept for an element never hovered.
UI.HOVER_IN_MS, UI.HOVER_OUT_MS, UI.FLASH_MS = 90, 220, 260

local function fxLevel(f, now)
    local d = now - f.at
    if d >= f.dur then return f.to end
    local u = 1 - d / f.dur
    return f.from + (f.to - f.from) * (1 - u * u)
end

-- The look for UI.live: the lights' levels together, nil once none moves.
local function fxSum(lights, now, sum, moving)
    if lights then
        for _, f in pairs(lights) do
            if now - f.at < f.dur then moving = true end
            sum = sum + fxLevel(f, now)
        end
    end
    return sum, moving
end

local function fxFrame(el, now)
    local sum, moving = fxSum(el.fx, now, 0, false)
    sum, moving = fxSum(el.fxFlash, now, sum, moving)
    if not moving then return nil end
    return floor(sum * 100)
end
UI.fxFrame = fxFrame

local function fxOf(el, field)
    local fx = el[field]
    if not fx then
        fx = {}
        el[field] = fx
    end
    return fx
end

-- The light `key` of `el` heading up (`on`) or down: its level now, 0 to 1. Called as the element draws.
function UI.hoverLight(el, key, on)
    local f = el.fx and el.fx[key]
    if not f and not on then return 0 end
    local now = getTimestampMs()
    if not f then
        f = { from = 0, to = 0, at = now, dur = 1 }
        fxOf(el, "fx")[key] = f
    end
    local to = on and 1 or 0
    if f.to ~= to then
        f.from, f.to, f.at, f.dur = fxLevel(f, now), to, now, on and UI.HOVER_IN_MS or UI.HOVER_OUT_MS
        UI.live(el, fxFrame)
    end
    return fxLevel(f, now)
end

-- A click's flash on `el` (its `key`): full now, dying out.
function UI.flash(el, key)
    fxOf(el, "fxFlash")[key] = { from = 1, to = 0, at = getTimestampMs(), dur = UI.FLASH_MS }
    UI.live(el, fxFrame)
end

-- The flash's level now, 0 to 1.
function UI.flashLevel(el, key)
    local f = el.fxFlash and el.fxFlash[key]
    if not f then return 0 end
    return fxLevel(f, getTimestampMs())
end

-- Places on one element lit one at a time (a screen's cards and buttons, a list's rows): a place is any value that
-- stays the same while the element is laid out again (an id, a number, a string made when laid out). The place under
-- the mouse (`over`, nil for none) comes up and the one it left goes down: two lights at most, el.fx.cur and
-- el.fx.fade (a third left as quickly goes dark at once), each with the place and `data` (what the element needs to
-- draw it, its last given). A click's flash is el.fxFlash.press. Called as the element draws.
function UI.placeLight(el, over, data)
    local fx = el.fx
    local cur = fx and fx.cur
    if cur and cur.place == over then
        cur.data = data
        return
    end
    if not cur and over == nil then return end
    fx = fx or fxOf(el, "fx")
    local now = getTimestampMs()
    local fade = fx.fade
    local from = 0
    if fade and fade.place == over then
        from = fxLevel(fade, now)
        fx.fade = nil
    end
    if cur then fx.fade = { place = cur.place, data = cur.data, from = fxLevel(cur, now), to = 0, at = now, dur = UI.HOVER_OUT_MS } end
    fx.cur = over ~= nil and { place = over, data = data, from = from, to = 1, at = now, dur = UI.HOVER_IN_MS } or nil
    UI.live(el, fxFrame)
end

function UI.placeFlash(el, place, data)
    fxOf(el, "fxFlash").press = { place = place, data = data, from = 1, to = 0, at = getTimestampMs(), dur = UI.FLASH_MS }
    UI.live(el, fxFrame)
end

-- How lit a place is now: its hover's level and its flash's, 0 to 1 each.
function UI.placeLevels(el, place)
    local k, f = 0, 0
    local fx, flashes = el.fx, el.fxFlash
    if not (fx or flashes) then return 0, 0 end
    local now = getTimestampMs()
    if fx then
        local cur, fade = fx.cur, fx.fade
        if cur and cur.place == place then
            k = fxLevel(cur, now)
        elseif fade and fade.place == place then
            k = fxLevel(fade, now)
        end
    end
    local press = flashes and flashes.press
    if press and press.place == place then f = fxLevel(press, now) end
    return k, f
end

return UI
