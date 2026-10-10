-- Small helpers for the windows of the mod (the terminal and its readers, the machine window): the scale, the faces of
-- their texts, drawing in a palette, and the few game widgets left in them (a list, a scroll bar).
--
-- Sizes: design units and one scale (DESIGN-terminal 1.2, worklist 3-2) ------------------------------------------
-- The terminal's screens are laid out in DESIGN UNITS: the numbers written in the code, made for a 16 unit Small font.
-- UI.S is the scale from them to the screen's pixels, worked out again when a window opens (UI.refreshScale):
--   * with the extension API's UI fonts (PZToolsAPI.text): by the SCREEN, its height / 540 down to an eighth
--     (720p 1.25, 900p 1.625, 1080p 2, 1440p 2.625, 2160p 4), or by the game's font where that is larger, so that the
--     windows look as big at the 16 pixel font as at the 26 pixel one;
--   * without them: by the game's FONT, the Small font's height / 16 (the font option follows the window's height:
--     16 pixels on a small screen, 19 at 1080p, 26 at 1440p, 38 at 4K). Never under 1.
-- Our texts are drawn in FACES (Trade/Faces.lua): with the API, its font of the design height times the scale (Small 16,
-- Medium 20, Large 24 units: 32, 40 and 48 pixels at 1080p); without, the game's own font of that name. The rule:
--   * Layout code writes plain design numbers and never multiplies by UI.S itself. Text is measured in design units
--     too, in its face (UI.textWidth, UI.fontHeight, UI.fit give the pixels / UI.S), so the Small font is 16 high in
--     them, give or take the font's own line.
--   * Our own elements (OATab and every tab and screen derived from it, the tab strip, OASubTabs, OAShopScroll,
--     OAMButton, OACombo, OARichText, the confirm, the status board, the machine window's body: each class made with
--     UI.scaled) are in design units through and through: their x, y, width and height, every draw* call and stencil,
--     getMouseX/Y and the coordinates their mouse handlers get. The class converts at the boundary with the game (the
--     javaObject), and draws its texts in their faces; the code in it does not.
--   * No game widget that draws text stands in our windows (it would draw in the game's font): buttons, combo boxes,
--     rich text, the confirm are ours (Trade/Button, Trade/RichText, Trade/Confirm; tools/check_translations.py
--     refuses the game's). The game's list (ISScrollingListBox) is kept for its scrolling, its rows drawn by us in
--     design units through UI.list or UI.rowPainter; UI.place, UI.size and UI.rowHeight take design numbers for it.
--   * A game window (the terminal window, the readers, the machine window) is in pixels: its sizes are design sizes
--     made pixels with UI.px, its bars are as high as our Small face (UI.titleBarHeight), its title and close box are
--     drawn in our face (UI.windowTitle, UI.closeBox), and it hands its body to our elements in design units.
-- At UI.S == 1 without the API nothing is converted: the scaled classes are the plain game classes, and every number
-- is as written. Lines and borders stay one pixel wide at any scale (the game's own windows keep them so). Item icons
-- go through UI.icon / UI.iconPx.
require "ISUI/ISPanel"
require "ISUI/ISScrollingListBox"
require "OperationAcorn/Trade/Text"
require "OperationAcorn/Trade/Faces"
local OA = OperationAcorn
local Faces = OA.Trade.Faces
local UI = {}
OA.Trade.UI = UI

-- The Small font's height the design units are made for.
UI.BASE_FONT = 16
UI.S = 1
-- A number that changes whenever the scale or the faces do: a window made before closes (its layout was measured in
-- the old ones).
UI.era = 0
UI.facesOn = false
-- The scale as a local too: the drawing below reads it on every call. `on`: whether our classes convert (a scale that
-- is not 1, or the API's faces, which only our classes draw).
local S = 1
local on = false
-- font -> { its space, the space between parts } (UI.fontSpace), until the scale changes: the status header asks
-- each frame
local spaces = {}
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
    self.oaRX, self.oaRY = floor(self.x * S + 0.5), floor(self.y * S + 0.5)
    self.oaRW, self.oaRH = floor(self.width * S + 0.5), floor(self.height * S + 0.5)
    jo:setX(self.oaRX)
    jo:setY(self.oaRY)
    jo:setHeight(self.oaRH)
    jo:setWidth(self.oaRW)
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
        self.oaRX = floor(x * S + 0.5)
        jo:setX(self.oaRX)
    end
end

function SCALED:setY(y)
    self.y = y
    local jo = self.javaObject
    if jo then
        self.oaRY = floor(y * S + 0.5)
        jo:setY(self.oaRY)
    end
end

function SCALED:setWidth(w)
    self.width = w
    local jo = self.javaObject
    if jo then
        self.oaRW = floor(w * S + 0.5)
        jo:setWidth(self.oaRW)
    end
end

function SCALED:setHeight(h)
    self.height = h
    local jo = self.javaObject
    if jo then
        self.oaRH = floor(h * S + 0.5)
        jo:setHeight(self.oaRH)
    end
end

local function javaOf(self)
    if self.javaObject == nil then self:instantiate() end
    return self.javaObject
end

function SCALED:getX()
    local r = javaOf(self):getX()
    if r == self.oaRX then return self.x end
    return r / S
end

function SCALED:getY()
    local r = javaOf(self):getY()
    if r == self.oaRY then return self.y end
    return r / S
end

function SCALED:getWidth()
    local r = javaOf(self):getWidth()
    if r == self.oaRW then return self.width end
    return r / S
end

function SCALED:getHeight()
    local r = javaOf(self):getHeight()
    if r == self.oaRH then return self.height end
    return r / S
end

function SCALED:getRight() return self:getX() + self:getWidth() end
function SCALED:getBottom() return self:getY() + self:getHeight() end
function SCALED:getMouseX() return self.oaBase.getMouseX(self) / S end
function SCALED:getMouseY() return self.oaBase.getMouseY(self) / S end

-- Drawing: rectangles by their rounded edges, texts at their rounded place in their own (pixel) font.
function SCALED:drawRect(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.oaBase.drawRect(self, rx, ry, rw, rh, a, r, g, b)
end

function SCALED:drawRectBorder(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.oaBase.drawRectBorder(self, rx, ry, rw, rh, a, r, g, b)
end

-- The "static" ones (the panel's own background and border, which do not scroll with its content).
function SCALED:drawRectStatic(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.oaBase.drawRectStatic(self, rx, ry, rw, rh, a, r, g, b)
end

function SCALED:drawRectBorderStatic(x, y, w, h, a, r, g, b)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.oaBase.drawRectBorderStatic(self, rx, ry, rw, rh, a, r, g, b)
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
        px = px - floor(Faces.measure(face, str) / 2)
    elseif align == 2 then
        px = px - Faces.measure(face, str)
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
    return textPx(el, el.oaBase or el, text, px, py, c[1], c[2], c[3], a or 1, font, align or 0)
end

function UI.faceWidthPx(text, font)
    return Faces.measure(faceOf(font), text)
end

function SCALED:drawText(str, x, y, r, g, b, a, font)
    return textPx(self, self.oaBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 0)
end

function SCALED:drawTextCentre(str, x, y, r, g, b, a, font)
    return textPx(self, self.oaBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 1)
end

function SCALED:drawTextRight(str, x, y, r, g, b, a, font)
    return textPx(self, self.oaBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 2)
end

function SCALED:drawTextUntrimmed(str, x, y, r, g, b, a, font)
    return textPx(self, self.oaBase, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font, 3)
end

-- A texture at its own size is that many design units.
function SCALED:drawTexture(texture, x, y, a, r, g, b)
    if type(texture) == "string" then texture = getTexture(texture) end
    if not texture then return end
    local rx, rw = span(x, texture:getWidth())
    local ry, rh = span(y, texture:getHeight())
    return self.oaBase.drawTextureScaled(self, texture, rx, ry, rw, rh, a, r, g, b)
end

local function textureIn(name)
    return function(self, texture, x, y, w, h, a, r, g, b)
        local rx, rw = span(x, w)
        local ry, rh = span(y, h)
        return self.oaBase[name](self, texture, rx, ry, rw, rh, a, r, g, b)
    end
end
SCALED.drawTextureScaled = textureIn("drawTextureScaled")
SCALED.drawTextureScaledAspect = textureIn("drawTextureScaledAspect")
SCALED.drawTextureScaledAspect2 = textureIn("drawTextureScaledAspect2")
SCALED.drawTextureScaledAspect3 = textureIn("drawTextureScaledAspect3")

function SCALED:drawTextureScaledUniform(texture, x, y, scale, a, r, g, b)
    local rx, ry = floor(x * S + 0.5), floor(y * S + 0.5)
    return self.oaBase.drawTextureScaledUniform(self, texture, rx, ry, scale * S, a, r, g, b)
end

-- A tiled texture keeps its tiles' own size; only the area is scaled.
local function tiledIn(name)
    return function(self, texture, x, y, w, h, r, g, b, a)
        local rx, rw = span(x, w)
        local ry, rh = span(y, h)
        return self.oaBase[name](self, texture, rx, ry, rw, rh, r, g, b, a)
    end
end
SCALED.drawTextureTiled = tiledIn("drawTextureTiled")
SCALED.drawTextureTiledX = tiledIn("drawTextureTiledX")
SCALED.drawTextureTiledY = tiledIn("drawTextureTiledY")

function SCALED:setStencilRect(x, y, w, h)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.oaBase.setStencilRect(self, rx, ry, rw, rh)
end

function SCALED:repaintStencilRect(x, y, w, h)
    local rx, rw = span(x, w)
    local ry, rh = span(y, h)
    return self.oaBase.repaintStencilRect(self, rx, ry, rw, rh)
end

-- The drawing ones (a canvas over a game widget has these, and no place of its own).
local DRAWS = { "drawRect", "drawRectBorder", "drawRectStatic", "drawRectBorderStatic", "drawText", "drawTextCentre",
    "drawTextRight", "drawTextUntrimmed", "drawTexture", "drawTextureScaled", "drawTextureScaledAspect", "drawTextureScaledAspect2", "drawTextureScaledAspect3",
    "drawTextureScaledUniform", "drawTextureTiled", "drawTextureTiledX", "drawTextureTiledY", "setStencilRect",
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
    cls.oaScaled, cls.oaBase = true, base
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
    return on and parent ~= nil and parent.oaScaled == true
end

-- A canvas to draw on a game widget in design units (a row of a game list inside our element): the widget's fields
-- show through it, its width and height are in design units and its drawing converts (its texts in their faces). While
-- our classes do not convert, or outside our
-- elements, the widget itself.
function UI.designCanvas(el)
    if not designParent(el.parent) then return el end
    local c = el.oaCanvas
    if not c then
        c = setmetatable({ oaBase = el, oaDesign = true }, { __index = el })
        for _, name in ipairs(DRAWS) do c[name] = SCALED[name] end
        el.oaCanvas = c
    end
    c.width, c.height = el.width / S, el.height / S
    return c
end

-- A game list's doDrawItem drawing each row with drawRow(list, y, item, alt) in design units (the list as a canvas,
-- y from its top); it gives the list where the next row starts.
function UI.rowPainter(drawRow)
    return function(list, y, item, alt)
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

-- The room between a number and its unit ("627 크레딧"): the Korean small font's space is two or three pixels, too
-- thin to read as one.
UI.UNIT_GAP = 4

-- The unit of money as the screens write it after a number, without a space (UI.UNIT_GAP goes before it).
function UI.creditsUnit()
    return getText("IGUI_OA_Terminal_Credits")
end

-- The two terminals' colours (DESIGN-terminal 1.3): the crude one built from the kit, phosphor green on near black
-- and nothing else (a warning, a debt, a mission's colour are the bright green: `mono`); the field terminal ordered
-- from the shop, warm white and amber on olive. Every screen draws from the palette of the terminal it is open at.
-- The machine window (Machines/Window.lua) is drawn in the field terminal's. `inset` is a well darker than the
-- background (a gauge, an icon's frame), `water` the rain storage's, `off` a light that is out.
-- Colours are { r, g, b }.
UI.PALETTES = {
    crude = {
        bg = { 0.02, 0.05, 0.03 }, bgAlpha = 1, panel = nil,
        text = { 0.45, 0.95, 0.55 }, dim = { 0.25, 0.55, 0.30 }, bright = { 0.78, 1.0, 0.82 },
        value = { 0.78, 1.0, 0.82 }, head = { 0.78, 1.0, 0.82 }, border = { 0.20, 0.50, 0.25 },
        warn = { 0.78, 1.0, 0.82 }, bad = { 0.78, 1.0, 0.82 }, good = { 0.78, 1.0, 0.82 },
        sel = { 0.45, 0.95, 0.55 }, title = { 0.04, 0.10, 0.05 }, dark = { 0.02, 0.05, 0.03 },
        inset = { 0.01, 0.025, 0.015 }, water = { 0.45, 0.95, 0.55 }, off = { 0.25, 0.55, 0.30 },
        tabStrip = nil, numberFont = UIFont.Small, iconTint = { 0.6, 1, 0.6 }, scanlines = true, mono = true,
    },
    field = {
        bg = { 0.10, 0.11, 0.08 }, bgAlpha = 1, panel = { 0.15, 0.16, 0.12 },
        text = { 0.92, 0.90, 0.82 }, dim = { 0.62, 0.60, 0.52 }, bright = { 1, 0.98, 0.92 },
        value = { 1, 0.82, 0.25 }, head = { 1, 0.82, 0.25 }, border = { 0.42, 0.45, 0.30 },
        warn = { 1, 0.82, 0.25 }, bad = { 1, 0.45, 0.35 }, good = { 0.6, 0.95, 0.6 },
        sel = { 1, 0.82, 0.25 }, title = { 0.30, 0.33, 0.20 }, dark = { 0.10, 0.11, 0.08 },
        inset = { 0.06, 0.065, 0.045 }, water = { 0.45, 0.72, 1.0 }, off = { 0.45, 0.45, 0.40 },
        tabStrip = { 0.30, 0.33, 0.20 }, numberFont = UIFont.Small, iconTint = nil, scanlines = false, mono = false,
    },
}
function UI.palette(tier)
    return UI.PALETTES[tier] or UI.PALETTES.crude
end

-- Drawing with a palette colour: a filled rectangle, a border, a text (alpha optional).
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

-- The same in pixels (our game windows' bars, a face's lines in pixels).
function UI.faceHeightPx(font)
    return Faces.height(font)
end

function UI.buttonHeight()
    return UI.fontHeight(UIFont.Small) + 10
end

-- Spaces at a text's end are measured as UI.spaceWidth each: they are not seen, they only place what comes after (a
-- label's value, the next part of a line), and the font's own space is narrower than the layout's scale at the larger
-- sizes ("합계 " then the sum came out as one word). Only a text that ends in a space pays for the look.
local function trailingMore(text, font)
    if string.byte(text, -1) ~= 32 then return 0 end
    local trail = #string.match(text, " *$")
    if trail == #text then return 0 end
    return trail * math.max(0, UI.spaceWidth(font) - UI.fontSpace(font))
end

function UI.textWidth(text, font)
    local w = Faces.measure(faceOf(font), text)
    if S ~= 1 then w = w / S end
    if text and text ~= "" then w = w + trailingMore(text, font) end
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
-- wider than the width by itself stays whole on its own line, as the game's rich text keeps it.
function UI.wrap(text, width, font)
    local lines = {}
    for para in string.gmatch((text or "") .. "\n", "(.-)\n") do
        local current
        for word in string.gmatch(para, "%S+") do
            local longer = current and (current .. " " .. word) or word
            if current and UI.textWidth(longer, font) > width + 0.001 then
                lines[#lines + 1] = current
                current = word
            else
                current = longer
            end
        end
        lines[#lines + 1] = current or ""
    end
    return lines
end

-- The text cut to a width with "..." at the end (whole when it fits). The game's strings are per character, so a cut
-- never splits a letter.
-- (with a margin: a width in design units can be a fraction a hair under the text's own)
local function fitWith(measure, text, width, font)
    width = width + 0.001
    if measure(text, font) <= width then return text end
    local cut = text
    while #cut > 1 and measure(cut .. "...", font) > width do
        cut = string.sub(cut, 1, #cut - 1)
    end
    return cut .. "..."
end

function UI.fit(text, width, font)
    return fitWith(UI.textWidth, text, width, font)
end

-- The same in pixels.
function UI.fitPx(text, width, font)
    return fitWith(UI.textWidthPx, text, width, font)
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

-- A row of sub-tabs (the status tab's and the missions tab's, DESIGN-terminal 2.1a, 6.4): boxes side by side, the
-- chosen one filled. `items` = { { id, label, lock (a padlock before the name), badge (a text on a filled chip after
-- it), dot ("new" or "bad") } }; a click calls onSelect(target, id).
OASubTabs = ISPanel:derive("OASubTabs")

function OASubTabs:new(x, y, width, palette, target, onSelect)
    local o = ISPanel:new(x, y, width, UI.fontHeight() + 6)
    setmetatable(o, self)
    self.__index = self
    o.background = false
    o.palette = palette
    o.target, o.onSelect = target, onSelect
    o.items, o.slots = {}, {}
    return o
end

function OASubTabs:setItems(items, active)
    self.items, self.active = items, active
end

function OASubTabs:prerender()
    local p = self.palette
    local fh = UI.fontHeight()
    local h = self.height
    local x = 0
    self.slots = {}
    for _, item in ipairs(self.items) do
        local on = item.id == self.active
        local lw = UI.textWidth(item.label)
        local bw = lw + 32
        if item.lock then bw = bw + 12 end
        local badgeW = item.badge and UI.textWidth(item.badge) + 10 or 0
        if item.badge then bw = bw + badgeW + 4 end
        if on then
            UI.fill(self, x, 0, bw, h, p.sel, 0.2)
            UI.frame(self, x, 0, bw, h, p.sel)
        else
            if p.panel then UI.fill(self, x, 0, bw, h, p.panel) end
            UI.frame(self, x, 0, bw, h, p.border)
        end
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
        self.slots[#self.slots + 1] = { id = item.id, x = x, w = bw }
        x = x + bw + 4
    end
end

function OASubTabs:onMouseDown(x, y)
    for _, slot in ipairs(self.slots) do
        if x >= slot.x and x < slot.x + slot.w then
            if self.onSelect then self.onSelect(self.target, slot.id) end
            return true
        end
    end
    return true
end

UI.scaled(OASubTabs, ISPanel)

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
    if not el.oaScaled and designParent(el.parent) then
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

-- The palette of the window an element is in (the terminal window keeps it as a table), or nil.
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
-- grey textures stood out on the terminal. The thumb's place and size are the game's own (barx, bary, barwidth and
-- barheight are what its clicks and drags read).
local function renderBar(self)
    local p = self.oaPalette
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

-- Draws a scroll bar in the palette of its window (once; a bar outside the terminal keeps the game's look).
function UI.styleScrollBar(bar)
    if bar.oaPalette or not bar.vertical then return end
    local p = paletteOf(bar.parent)
    if not p then return end
    bar.oaPalette = p
    bar.render = renderBar
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
    list.doDrawItem = function(self, rowY, item, alt)
        if rowY + self:getYScroll() + item.height < 0 or rowY + self:getYScroll() >= self.height then
            return rowY + item.height
        end
        if self.selected == item.index then
            self:drawSelection(0, rowY, self:getWidth(), item.height - 1)
        elseif self.mouseoverselected == item.index and self:isMouseOver() and not self:isMouseOverScrollBar() then
            self:drawMouseOverHighlight(0, rowY, self:getWidth(), item.height - 1)
        end
        local c = UI.designCanvas(self)
        drawRow(c, c == self and rowY or rowY / S, item, alt)
        return rowY + item.height
    end
    if onclick then list:setOnMouseDownFunction(target, onclick) end
    parent:addChild(list)
    return list
end

-- Rich text colors for the receipt kinds.
UI.KIND_TAG = {
    head = " <H2> <RGB:1,1,1> ",
    line = " <TEXT> <RGB:0.85,0.85,0.85> ",
    good = " <TEXT> <RGB:0.55,0.9,0.55> ",
    bad = " <TEXT> <RGB:0.95,0.55,0.45> ",
    note = " <TEXT> <RGB:0.8,0.75,0.55> ",
    total = " <TEXT> <RGB:1,1,1> ",
}

-- Text lines { kind, text } as rich text.
function UI.richLines(lines)
    local parts = {}
    for _, line in ipairs(lines) do
        parts[#parts + 1] = (UI.KIND_TAG[line.kind] or UI.KIND_TAG.line) .. line.text .. " <LINE> "
    end
    return table.concat(parts)
end

-- Item icons ---------------------------------------------------------------------------------------------------------
-- Every item icon in our windows is drawn through these two (so that one change can draw them at whole multiples of
-- their 32 pixel pictures): UI.icon in design units on our elements (the pixels of others), UI.iconPx in the element's
-- pixels (the status lists' baked steps). `tint` is { r, g, b } (nil: none), the picture kept to its aspect.

function UI.iconPx(el, texture, px, py, pw, ph, a, tint)
    if not texture then return end
    local t = tint or WHITE
    local base = el.oaBase or el
    base.drawTextureScaledAspect(el, texture, px, py, pw, ph, a or 1, t[1], t[2], t[3])
end

function UI.icon(el, texture, x, y, size, a, tint)
    if not texture then return end
    if on and (el.oaScaled or el.oaDesign) then
        local rx, rw = span(x, size)
        local ry, rh = span(y, size)
        return UI.iconPx(el, texture, rx, ry, rw, rh, a, tint)
    end
    UI.iconPx(el, texture, x, y, size, size, a, tint)
end

-- Our game windows' bars --------------------------------------------------------------------------------------------
-- The terminal window, the readers and the machine window are the game's (ISCollapsableWindow), in pixels. Their bars
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
    textPx(win, win, title, floor(win.width / 2), floor((th - Faces.height()) / 2 + 0.5), c[1], c[2], c[3], a or 1,
        nil, 1)
end

-- The close box: an "x" in our face (the game's button with its picture and title taken off), in the palette.
local function closeBoxRender(self)
    local c = self.oaGlyphColour
    textPx(self, self, "x", floor(self.width / 2), floor((self.height - Faces.height()) / 2), c[1], c[2], c[3], 1, nil, 1)
end

function UI.closeBox(win, p)
    local cb = win.closeButton
    if not cb then return end
    cb:setImage(nil)
    cb:setTitle("")
    cb.oaGlyphColour = p.text
    cb.borderColor = { r = p.border[1], g = p.border[2], b = p.border[3], a = 1 }
    cb.backgroundColorMouseOver = { r = p.sel[1], g = p.sel[2], b = p.sel[3], a = 0.25 }
    cb.render = closeBoxRender
end

-- A context menu at the mouse for the player: returns it.
function UI.menu(character)
    local x, y = getMouseX(), getMouseY()
    return ISContextMenu.get(character:getPlayerNum(), x, y)
end

return UI
