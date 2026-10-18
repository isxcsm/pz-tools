-- The kit's rich text panel: the game's ISRichTextPanel draws in the game's font, so this one takes its place, in
-- design units and the kit's faces (UI.lua). It reads the commands of the game's rich text: <LINE>, <BR>, <TEXT> (the panel's own font, grey), <H1> (Large, white, centred), <H2> (Medium,
-- light grey), <RGB:r,g,b>, <PUSHRGB:r,g,b> and <POPRGB>, <CENTRE>, <LEFT>, <RIGHT>, <SPACE>, <SIZE:small|medium|large>,
-- &lt; and &gt;, and a line end as <LINE>; and two of its own: <HALF> (half a row
-- down) and <HANG> (the rows the line wraps into start where the text after it does: a bullet's hanging indent). It lays the text out as the game's does, piece for piece (a "chunk" is
-- the text between two commands on one row; a caller may reveal them a character at a time): the text is cut at
-- its spaces, a word goes to the next row when the row would grow past the width, and a word wider than the row by
-- itself stays whole on its own row. A row is as high as its font's face.
-- It scrolls by itself (the wheel, and a thin bar of the palette on its right that can be dragged), so the game's
-- scroll bar, which works in pixels, is not used.
require "ISUI/ISPanel"
require "PZUIKit/UI"
local UI = PZUIKit.UI

PZUIRichText = ISPanel:derive("PZUIRichText")

-- A wheel step (design units), the bar's width and its gap to the panel's right edge, and the gap kept between the
-- text and the bar. The text is always broken short of the bar and its gap, whether the bar shows or not: a text that
-- grows past the panel as it is typed does not break its lines again when the bar comes, and the bar never covers it.
PZUIRichText.WHEEL = 18
PZUIRichText.BAR = 6
PZUIRichText.BAR_EDGE = 1
PZUIRichText.BAR_GAP = 7
PZUIRichText.BAR_ROOM = PZUIRichText.BAR + PZUIRichText.BAR_EDGE + PZUIRichText.BAR_GAP

local floor = math.floor
local find, sub = string.find, string.sub

function PZUIRichText:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.text = ""
    o.defaultFont = UIFont.Small
    o.marginLeft, o.marginTop, o.marginRight, o.marginBottom = 8, 6, 8, 6
    o.contentTransparency = 1
    o.clip = true
    o.scroll, o.contentH = 0, 0
    o.lines, o.lineX, o.lineY = {}, {}, {}
    o.textDirty = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.35 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.9 }
    return o
end

-- Measures for the layout and the typing (design units, in the faces).
function PZUIRichText:measure(text, font) return UI.textWidth(text, font) end
-- (the same, not kept in the texts' cache: for what is measured once, the growing chunks of a layout, a text typed on)
function PZUIRichText:measureRaw(text, font) return UI.textWidthRaw(text, font) end
function PZUIRichText:lineHeightOf(font) return UI.fontHeight(font) end

function PZUIRichText:setText(text)
    self.text = text or ""
    self.textDirty = true
end

local function trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function unescape(s)
    if find(s, "&", 1, true) then
        s = string.gsub(s, "&lt;", "<")
        s = string.gsub(s, "&gt;", ">")
    end
    return s
end

local function rgbOf(text)
    local r, g, b = string.match(text, "^%s*([%d.]+)%s*,%s*([%d.]+)%s*,%s*([%d.]+)")
    return { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1 }
end

local GREY_TEXT, GREY_H2, WHITE = { 0.7, 0.7, 0.7 }, { 0.8, 0.8, 0.8 }, { 1, 1, 1 }

-- A command between < and >: what it does to the place (x, y) and to what the next chunk is drawn in.
function PZUIRichText:command(cmd, x, y, lineHeight)
    local at = self.currentLine
    if cmd == "LINE" then
        self.hang = 0
        return 0, y + lineHeight
    elseif cmd == "BR" then
        self.hang = 0
        return 0, y + 2 * lineHeight
    elseif cmd == "HALF" then
        return x, y + lineHeight / 2
    elseif cmd == "HANG" then
        self.hang = x + self:measure(" ", self.font)
        return self.hang, y
    elseif cmd == "H1" then
        self.orient[at], self.rgb[at], self.font = "centre", WHITE, UIFont.Large
        self.fonts[at] = self.font
    elseif cmd == "H2" then
        self.orient[at], self.rgb[at], self.font = "left", GREY_H2, UIFont.Medium
        self.fonts[at] = self.font
    elseif cmd == "TEXT" then
        self.orient[at], self.rgb[at], self.font = "left", GREY_TEXT, self.defaultFont
        self.rgbCurrent = GREY_TEXT
        self.fonts[at] = self.font
    elseif cmd == "CENTRE" or cmd == "LEFT" or cmd == "RIGHT" then
        self.orient[at] = cmd == "CENTRE" and "centre" or string.lower(cmd)
    elseif find(cmd, "^PUSHRGB:") then
        self.rgbStack[#self.rgbStack + 1] = self.rgbCurrent
        self.rgb[at] = rgbOf(sub(cmd, 9))
        self.rgbCurrent = self.rgb[at]
    elseif cmd == "POPRGB" then
        if #self.rgbStack > 0 then
            self.rgbCurrent = table.remove(self.rgbStack)
            self.rgb[at] = self.rgbCurrent
        end
    elseif find(cmd, "^RGB:") then
        self.rgb[at] = rgbOf(sub(cmd, 5))
        self.rgbCurrent = self.rgb[at]
    elseif find(cmd, "^SIZE:") then
        local size = sub(cmd, 6)
        self.font = (size == "medium" and UIFont.Medium) or (size == "large" and UIFont.Large) or UIFont.Small
        self.fonts[at] = self.font
    elseif cmd == "SPACE" then
        if x > 0 then x = x + self:measure(" ", self.font) end
    end
    return x, y
end

-- Lays the text out for the width now (the game's ISRichTextPanel:paginate, piece for piece): lines (the chunks),
-- lineX, lineY (from the text's top left inside the margins), and what each chunk is drawn in and where.
function PZUIRichText:paginate()
    self.textDirty, self.laidW = false, self.width
    self.font = self.defaultFont
    self.fonts, self.rgb, self.orient = {}, {}, {}
    self.rgbCurrent, self.rgbStack = WHITE, {}
    self.hang = 0
    local lines, lineX, lineY = {}, {}, {}
    self.lines, self.lineX, self.lineY = lines, lineX, lineY
    local maxW = self.width - self.marginLeft - self.marginRight - PZUIRichText.BAR_ROOM
    local n, x, y = 1, 0, 0
    local left = string.gsub(self.text or "", "\n", " <LINE> ") .. " "
    local cur = 0
    while true do
        cur = find(left, " ", cur + 1, true)
        if not cur then
            if trim(left) ~= "" then
                lines[n] = trim(unescape(left))
                lineX[n], lineY[n] = x, y
                y = y + self:lineHeightOf(self.font)
            elseif lines[n] and lines[n] ~= "" then
                y = y + self:lineHeightOf(self.font)
            end
            break
        end
        local token = sub(left, 1, cur)
        local lt, gt = find(token, "<", 1, true), find(token, ">", 1, true)
        if lt and gt then
            -- a command not followed by a space ends at its ">"
            cur = gt + 1
            token = sub(left, 1, cur - 1)
        end
        left = sub(left, cur)
        cur = 1
        if lt and gt then
            if not lines[n] then
                lines[n] = ""
                lineX[n], lineY[n] = x, y
            end
            n = n + 1
            self.currentLine = n
            local lineHeight = math.max(10, self:lineHeightOf(self.font))
            x, y = self:command(sub(token, lt + 1, gt - 1), x, y, lineHeight)
        else
            token = trim(unescape(token))
            local chunk = lines[n] or ""
            local chunkX = lineX[n] or x
            if chunk == "" then chunk = token elseif token ~= "" then chunk = chunk .. " " .. token end
            local w = self:measureRaw(chunk, self.font)
            if chunkX + w > maxW + 0.001 then
                if lines[n] and lines[n] ~= "" then n = n + 1 end
                y = y + self:lineHeightOf(self.font)
                lines[n] = token
                lineX[n], lineY[n] = self.hang, y
                x = self.hang + self:measureRaw(token, self.font)
            else
                if not lines[n] then lineX[n], lineY[n] = x, y end
                lines[n] = chunk
                x = lineX[n] + w
            end
        end
    end
    self.contentH = self.marginTop + y + self.marginBottom
    self:place()
    self:setScroll(self.scroll)
end

-- What each chunk is drawn in (the font, the colour and the side carried on from the chunks before, as the game's
-- render does) and its x: a centred row is centred as a whole, a row on the right ends at the text's right edge (short
-- of the bar), their chunks side by side.
function PZUIRichText:place()
    local lines, lineX, lineY = self.lines, self.lineX, self.lineY
    local font, rgb, orient = self.defaultFont, WHITE, "left"
    local cFont, cRGB, cOrient, cX = {}, {}, {}, {}
    local fontList, listed = {}, {}
    for c = 1, #lines do
        if self.rgb[c] then rgb = self.rgb[c] end
        if self.orient[c] then orient = self.orient[c] end
        if self.fonts[c] then font = self.fonts[c] end
        cFont[c], cRGB[c], cOrient[c] = font, rgb, orient
        cX[c] = self.marginLeft + lineX[c]
        if not listed[font] then
            listed[font] = true
            fontList[#fontList + 1] = font
        end
    end
    self.fontList = fontList
    local inner = self.width - self.marginLeft - self.marginRight - PZUIRichText.BAR_ROOM
    local c = 1
    while c <= #lines do
        local side = cOrient[c]
        if (side == "centre" or side == "right") and lines[c] ~= "" then
            local row, last, w = lineY[c], c, 0
            while last <= #lines and lineY[last] == row do
                if side == "centre" then
                    w = w + self:measure(lines[last], cFont[last])
                elseif lines[last] ~= "" then
                    w = lineX[last] - lineX[c] + self:measure(lines[last], cFont[last])
                end
                last = last + 1
            end
            local x0
            if side == "centre" then x0 = self.marginLeft + (inner - w) / 2 else x0 = self.marginLeft + inner - w - lineX[c] end
            for k = c, last - 1 do cX[k] = x0 + lineX[k] end
            c = last
        else
            c = c + 1
        end
    end
    self.cFont, self.cRGB, self.cOrient, self.cX = cFont, cRGB, cOrient, cX
end

-- The scroll: `scroll` design units down the text, kept between the top and the end.
function PZUIRichText:maxScroll()
    return math.max(0, self.contentH - self.height)
end

function PZUIRichText:setScroll(v)
    self.scroll = math.max(0, math.min(self:maxScroll(), v or 0))
end

-- As the game's panel: 0 at the top, negative scrolled down.
function PZUIRichText:getYScroll() return -self.scroll end
function PZUIRichText:setYScroll(v) self:setScroll(-(v or 0)) end
function PZUIRichText:getScrollHeight() return self.contentH end

function PZUIRichText:onMouseWheel(del)
    if self:maxScroll() <= 0 then return false end
    self:setScroll(self.scroll + del * PZUIRichText.WHEEL)
    return true
end

-- The bar's thumb: its top and its height.
function PZUIRichText:thumb()
    return UI.thumb(self.height, self.contentH, self.scroll, self:maxScroll())
end

function PZUIRichText:onMouseDown(x, y)
    if self:maxScroll() > 0 and x >= self:barX() - 1 then
        UI.barPress(self, y)
        return true
    end
    if self.onmousedown then self.onmousedown(self.target) end
    return true
end

function PZUIRichText:drag(dy)
    UI.barDrag(self, dy)
end

function PZUIRichText:onMouseMove(dx, dy) self:drag(dy) end
function PZUIRichText:onMouseMoveOutside(dx, dy) self:drag(dy) end
function PZUIRichText:onMouseUp() self.dragging = false end
function PZUIRichText:onMouseUpOutside() self.dragging = false end

-- The game resized it (an anchor following its window): laid out again for the new width.
function PZUIRichText:onResize()
    self.width, self.height = self:getWidth(), self:getHeight()
    self.textDirty = true
end

-- The line heights asked in the render now: font -> height. A font's height can change under an open window (the
-- game's fonts made again, the API's font arriving), so none is kept past the render: the fonts set are listed, and the
-- next render clears them (nothing is made for it).
local heights, heightFonts, heightsSet = {}, {}, 0

local function heightOf(panel, font)
    local h = heights[font]
    if h == nil then
        h = panel:lineHeightOf(font)
        heights[font] = h
        heightsSet = heightsSet + 1
        heightFonts[heightsSet] = font
    end
    return h
end

-- The rows on show, in their faces: a frame draws only what it reads from the layout. Rows go down the panel in order
-- (lineY only grows), so the ones above the top are found by halving, not one by one: a row shows once its place and
-- its font's height reach past the top, and no row is taller than the tallest font in the layout.
function PZUIRichText:render()
    if self.textDirty or self.laidW ~= self.width then self:paginate() end
    local h = self.height
    if self.clip then self:setStencilRect(0, 0, self.width, h) end
    local lines, lineY, cX, cFont, cRGB, cOrient = self.lines, self.lineY, self.cX, self.cFont, self.cRGB, self.cOrient
    local top = self.marginTop - self.scroll
    local a = self.contentTransparency
    for i = 1, heightsSet do heights[heightFonts[i]] = nil end
    heightsSet = 0
    local first = 1
    local fonts = self.fontList
    if fonts and top < 0 then
        local tall = 0
        for i = 1, #fonts do tall = math.max(tall, heightOf(self, fonts[i])) end
        local lo, hi, limit = 1, #lines + 1, -top - tall - 1
        while lo < hi do
            local mid = floor((lo + hi) / 2)
            if lineY[mid] > limit then hi = mid else lo = mid + 1 end
        end
        first = lo
    end
    for c = first, #lines do
        local ly = top + lineY[c]
        if ly >= h then break end
        local v = lines[c]
        local font = cFont[c]
        if v ~= "" and ly + heightOf(self, font) > 0 then
            local rgb = cRGB[c]
            self:drawText(v, cX[c], ly, rgb[1], rgb[2], rgb[3], a, font)
        end
    end
    if self.clip then UI.unclip(self, 0, 0, self.width, h) end
    self:drawBar()
end

-- Where the bar stands: its width and its gap in from the right edge (the text keeps BAR_GAP more to its left).
function PZUIRichText:barX()
    return self.width - PZUIRichText.BAR - PZUIRichText.BAR_EDGE
end

local BAR_GREY = { 0.5, 0.5, 0.5 }

-- The bar on the right, while there is more than shows: in the palette of the window (grey in a game-coloured one,
-- found once).
function PZUIRichText:drawBar()
    if self:maxScroll() <= 0 then return end
    if self.palette == nil then self.palette = UI.paletteOf(self.parent) or false end
    local c = self.palette and self.palette.border or BAR_GREY
    local bar = PZUIRichText.BAR
    local ty, th = self:thumb()
    UI.drawBar(self, self:barX(), bar, self.height, ty, th, c)
end

UI.scaled(PZUIRichText, ISPanel)

-- A rich text panel in `parent` at design numbers (the class: PZUIRichText or one derived from it). Its margins, place
-- and size are design units in any window (UI.dp for a game window's pixels).
function UI.rich(parent, x, y, width, height, class)
    local panel = (class or PZUIRichText):new(x, y, width, height)
    panel:initialise()
    panel:instantiate()
    parent:addChild(panel)
    return panel
end

function UI.setRich(panel, text)
    panel.text = text
    panel:paginate()
end

-- A tooltip of rich text (the game's tags: <LINE>, <RGB:r,g,b> and the rest), the kit's in place of the game's
-- ISToolTip, which draws in the game's font: one panel over everything, shown for one owner at a time by the mouse, in
-- the owner's palette, as wide as its widest line up to PZUIRichTip.MAX_W (design units), laid out once a text. While
-- an owner holds it (a menu open, PZUIPopMenu), no other owner shows it.
PZUIRichTip = {}
PZUIRichTip.MAX_W = 360

local tip, holder

-- Keeps the tooltip for owner (nil: for whoever shows it).
function PZUIRichTip.hold(owner)
    holder = owner
end

local function widest(panel)
    local w = 0
    for c, line in ipairs(panel.lines) do
        if line ~= "" then w = math.max(w, panel.cX[c] + panel:measure(line, panel.cFont[c])) end
    end
    return w
end

function PZUIRichTip.show(owner, text, palette)
    if holder and owner ~= holder then return end
    if not tip then
        tip = PZUIRichText:new(0, 0, PZUIRichTip.MAX_W, 20)
        tip:initialise()
        tip:instantiate()
        -- the mouse goes through a tooltip, as onto it from its owner it would take the mouse's events
        tip.javaObject:setConsumeMouseEvents(false)
        tip:setAlwaysOnTop(true)
        tip.clip = false
        -- it goes once its owner is no longer under the mouse or on show (a tab switched, a window closed)
        tip.prerender = function(self)
            local o = self.owner
            if not (o and o:isReallyVisible() and o:isMouseOver()) then return PZUIRichTip.hide(o) end
            return PZUIRichText.prerender(self)
        end
    end
    if tip.tipText ~= text or tip.era ~= UI.era then
        tip.tipText, tip.era = text, UI.era
        tip:setWidth(PZUIRichTip.MAX_W)
        tip:setText(text)
        tip:paginate()
        local w = math.ceil(widest(tip) + tip.marginRight + PZUIRichText.BAR_ROOM + 1)
        if w < PZUIRichTip.MAX_W then
            tip:setWidth(w)
            tip:paginate()
        end
        tip:setHeight(tip.contentH)
    end
    local p = palette or UI.DEFAULT_PALETTE
    tip.backgroundColor = { r = p.bg[1], g = p.bg[2], b = p.bg[3], a = 0.97 }
    tip.borderColor = { r = p.border[1], g = p.border[2], b = p.border[3], a = 1 }
    tip.owner = owner
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    local mx, my = UI.dp(getMouseX()), UI.dp(getMouseY())
    local x = math.max(0, math.min(mx + 14, screenW - tip.width))
    local y = my + 20
    if y + tip.height > screenH then y = math.max(0, my - tip.height - 6) end
    tip:setX(x)
    tip:setY(y)
    if not tip.shown then
        tip.shown = true
        tip:addToUIManager()
        tip:setVisible(true)
    end
end

-- Hides the tooltip if it is `owner`'s (nil: whoever's).
function PZUIRichTip.hide(owner)
    if not (tip and tip.shown) or (owner and tip.owner ~= owner) then return end
    tip.shown, tip.owner = false, nil
    tip:setVisible(false)
    tip:removeFromUIManager()
end

return PZUIRichText
