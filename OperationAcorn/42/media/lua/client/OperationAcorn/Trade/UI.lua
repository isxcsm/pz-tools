-- Small helpers for the trade part's windows: the same few widgets (a label, a button, a list, a rich text) with the
-- sizes the game's own windows use.
--
-- Sizes: design units and one scale (DESIGN-terminal 1.2) ---------------------------------------------------------
-- The game's font option defaults to following the window's height, so the Small font is 16 pixels high on a small
-- screen, 19 at 1080p, 26 at 1440p and 38 at 4K. The terminal's screens are laid out in DESIGN UNITS: the numbers
-- written in the code, made for a 16 pixel Small font. UI.S is the scale from them to the screen's pixels: the Small
-- font's height / 16 (never under 1), worked out again when a window opens (UI.refreshScale). The rule:
--   * Layout code writes plain design numbers and never multiplies by UI.S itself. Text is measured in design units
--     too (UI.textWidth, UI.fontHeight give the pixels / UI.S), so the Small font is always 16 high in them.
--   * Our own elements (OATab and every tab and screen derived from it, the tab strip, OASubTabs, OAShopScroll,
--     OAMButton, the status board: each class made with UI.scaled) are in design units through and through: their
--     x, y, width and height, every draw* call and stencil, getMouseX/Y and the coordinates their mouse handlers get.
--     The class converts at the boundary with the game (the javaObject); the code in it does not.
--   * The game's own widgets (ISButton, ISScrollingListBox, ISRichTextPanel, ISLabel, ISComboBox, scroll bars) draw
--     their own text and stay in pixels. Inside our elements they are made and moved with the helpers below
--     (UI.list, UI.rich, UI.button, UI.label, UI.place, UI.size, UI.rowHeight), which take design numbers and convert.
--     A game list's rows are drawn in design units through UI.list or UI.rowPainter.
--   * A game window (the terminal window, the readers, the confirm dialog) is in pixels: its sizes are design sizes
--     made pixels with UI.px, and the terminal window hands its body to the tabs in design units.
-- At UI.S == 1 nothing is converted: the scaled classes are the plain game classes, and every number is as written.
-- Lines and borders stay one pixel wide at any scale (the game's own windows keep them so).
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISRichTextPanel"
require "OperationAcorn/Trade/Text"
local OA = OperationAcorn
local UI = {}
OA.Trade.UI = UI

-- The Small font's height the design units are made for.
UI.BASE_FONT = 16
UI.S = 1
-- The scale as a local too: the drawing below reads it on every call.
local S = 1
-- font -> { its space, the space between parts } (UI.fontSpace), until the scale changes: the status header asks
-- each frame
local spaces = {}
local floor = math.floor

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

function SCALED:drawText(str, x, y, r, g, b, a, font)
    return self.oaBase.drawText(self, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font)
end

function SCALED:drawTextCentre(str, x, y, r, g, b, a, font)
    return self.oaBase.drawTextCentre(self, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font)
end

function SCALED:drawTextRight(str, x, y, r, g, b, a, font)
    return self.oaBase.drawTextRight(self, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font)
end

function SCALED:drawTextUntrimmed(str, x, y, r, g, b, a, font)
    return self.oaBase.drawTextUntrimmed(self, str, floor(x * S + 0.5), floor(y * S + 0.5), r, g, b, a, font)
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
        if now == nil or now == SCALED[name] then cls[name] = S ~= 1 and SCALED[name] or nil end
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

-- Sets the scale (1 or more). The windows open at the time keep the one they were made with: the terminal window
-- closes when the scale changes under it.
function UI.setScale(s)
    s = s or 1
    if s == S then return end
    S = s
    UI.S = s
    spaces = {}
    for _, entry in ipairs(scaledClasses) do install(entry) end
end

-- The scale from the Small font in use now (a window calls this as it opens).
function UI.refreshScale()
    UI.setScale(math.max(1, UI.fontHeightPx(UIFont.Small) / UI.BASE_FONT))
end

-- Whether numbers for an element go in design units: inside one of our elements, while the scale is not 1.
local function designParent(parent)
    return S ~= 1 and parent ~= nil and parent.oaScaled == true
end

-- A canvas to draw on a game widget in design units (a row of a game list inside our element): the widget's fields
-- show through it, its width and height are in design units and its drawing converts. At scale 1, or outside our
-- elements, the widget itself.
function UI.designCanvas(el)
    if not designParent(el.parent) then return el end
    local c = el.oaCanvas
    if not c then
        c = setmetatable({ oaBase = el }, { __index = el })
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

-- Text measured in design units (the pixels / UI.S), and in pixels for what is drawn on the game's own widgets and
-- windows outside the terminal (the item tooltip, the loot window's estimate).
function UI.fontHeightPx(font)
    return getTextManager():getFontHeight(font or UIFont.Small)
end

function UI.textWidthPx(text, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, text)
end

function UI.fontHeight(font)
    local h = getTextManager():getFontHeight(font or UIFont.Small)
    if S == 1 then return h end
    return h / S
end

function UI.buttonHeight()
    return UI.fontHeight(UIFont.Small) + 10
end

function UI.textWidth(text, font)
    local w = getTextManager():MeasureStringX(font or UIFont.Small, text)
    if S == 1 then return w end
    return w / S
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

-- For a text drawn as one part of a line (a label, then its value in another colour): what its spaces at the ends add
-- to its width to make each UI.spaceWidth, the first of those before it. The font's space is narrower than the
-- layout's scale at the larger font sizes (4 pixels in the 26-pixel Korean font). The text is drawn whole, its spaces
-- with it: a text is measured to the end of its last letter's image, so one cut before its spaces would measure short
-- of where that letter moves the next.
function UI.spaceGaps(text, font)
    text = text or ""
    local lead, trail = #string.match(text, "^ *"), #string.match(text, " *$")
    if lead == #text then trail = 0 end
    if lead + trail == 0 then return 0, 0 end
    local more = math.max(0, UI.spaceWidth(font) - UI.fontSpace(font))
    return lead * more, (lead + trail) * more
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

-- A small padlock drawn from rectangles (the fonts have no glyph for one), 8 wide and 9 high from x, y.
function UI.lock(el, x, y, c, a)
    UI.frame(el, x + 2, y, 4, 4, c, a)
    UI.fill(el, x, y + 4, 8, 5, c, a)
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

-- A label at x, y.
function UI.label(parent, x, y, text, color, font)
    color = color or { r = 0.9, g = 0.9, b = 0.9, a = 1 }
    local lx, ly = inParent(parent, x, y)
    local label = ISLabel:new(lx, ly, UI.fontHeightPx(font), text, color.r, color.g, color.b, color.a, font or UIFont.Small,
        true)
    label:initialise()
    label:instantiate()
    parent:addChild(label)
    return label
end

-- A button whose click calls onclick(target, button).
function UI.button(parent, x, y, width, title, target, onclick)
    local bx, by, bw, bh = inParent(parent, x, y, width, UI.buttonHeight())
    local button = ISButton:new(bx, by, bw, bh, title, target, onclick)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
    parent:addChild(button)
    return button
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

-- A list with rows drawn by `drawRow(list, y, item, alt)` (inside our elements in design units: the list is then a
-- canvas over the game's list, UI.designCanvas). The row's own height is the list's itemheight (UI.rowHeight).
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

-- A scrolling rich text panel (its margins are design units in any window).
function UI.rich(parent, x, y, width, height, class)
    local panel = (class or ISRichTextPanel):new(inParent(parent, x, y, width, height))
    panel:initialise()
    panel:instantiate()
    panel.autosetheight = false
    panel.clip = true
    panel.marginLeft = UI.px(8)
    panel.marginRight = UI.px(8)
    panel.marginTop = UI.px(6)
    panel.marginBottom = UI.px(6)
    panel:addScrollBars()
    panel.backgroundColor = { r = 0, g = 0, b = 0, a = 0.35 }
    panel.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.9 }
    parent:addChild(panel)
    return panel
end

function UI.setRich(panel, text)
    panel.text = text
    panel:paginate()
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

-- Asks yes or no; onYes(target, a, b) runs on yes. The game's dialog in the terminal's scale.
function UI.confirm(character, text, target, onYes, a, b)
    UI.refreshScale()
    local modal = ISModalDialog:new(0, 0, UI.px(360), UI.px(150), text, true, nil, function(_, button)
        if button.internal == "YES" then onYes(target, a, b) end
    end, character:getPlayerNum())
    modal:initialise()
    modal:addToUIManager()
    return modal
end

-- A context menu at the mouse for the player: returns it.
function UI.menu(character)
    local x, y = getMouseX(), getMouseY()
    return ISContextMenu.get(character:getPlayerNum(), x, y)
end

return UI
