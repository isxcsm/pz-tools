-- Drawing for the status tab's screens: a screen is laid out into a list of drawing steps (rectangles, borders, texts,
-- textures) when its record or its size changes, and each frame only goes through that list. Texts are measured and
-- cut to their width while the list is made. The list also keeps the places that answer a click or show a tooltip.
-- The steps and the places are in design units (Trade/UI.lua); the steps are made pixels once (Draw.bake), and a frame
-- hands those to the game as they are.
-- The widgets are those of the mockups (mockups/terminal/gen/ui.py): panels, buttons, bars, a padlock, a bullet and
-- an arrow made of rectangles (the fonts have no glyph for them), in the palette of the terminal.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local Trade, UI = OA.Trade, OA.Trade.UI
local Draw = {}
Trade.Draw = Draw

local RECT, FRAME, TEXT, TEX, CLIP, UNCLIP = 1, 2, 3, 4, 5, 6

-- A new list for a palette.
function Draw.list(p)
    return { p = p, ops = {}, hits = {}, fh = UI.fontHeight(UIFont.Small) }
end

local function add(L, op)
    L.ops[#L.ops + 1] = op
end

function Draw.rect(L, x, y, w, h, c, a)
    if w <= 0 or h <= 0 or not c then return end
    add(L, { RECT, x, y, w, h, c, a or 1 })
end

function Draw.frame(L, x, y, w, h, c, a)
    if w <= 0 or h <= 0 or not c then return end
    add(L, { FRAME, x, y, w, h, c, a or 1 })
end

function Draw.box(L, x, y, w, h, fill, fa, line, la)
    if fill then Draw.rect(L, x, y, w, h, fill, fa) end
    Draw.frame(L, x, y, w, h, line, la)
end

-- A text at x, y (its top); returns its width.
function Draw.text(L, s, x, y, c, font, a)
    if not s or s == "" then return 0 end
    add(L, { TEXT, s, x, y, c, a or 1, font or UIFont.Small })
    return UI.textWidth(s, font)
end

-- A text cut to a width ("..." at the end), left, right or centred in it.
function Draw.fit(L, s, x, y, w, c, font, a, align)
    if not s or s == "" or w <= 0 then return 0 end
    s = UI.fit(s, w, font)
    local tw = UI.textWidth(s, font)
    if align == "right" then x = x + w - tw elseif align == "centre" then x = x + math.floor((w - tw) / 2) end
    add(L, { TEXT, s, x, y, c, a or 1, font or UIFont.Small })
    return tw
end

function Draw.textRight(L, s, right, y, c, font, a)
    local tw = UI.textWidth(s, font)
    Draw.text(L, s, right - tw, y, c, font, a)
    return tw
end

function Draw.textCentre(L, s, centre, y, c, font, a)
    local tw = UI.textWidth(s, font)
    Draw.text(L, s, centre - math.floor(tw / 2), y, c, font, a)
    return tw
end

-- A run of parts { s, c, font, a } or { arrow = true, c } side by side, cut at width `w` (nil: no limit), left or
-- right in it. Returns the width drawn.
-- The spaces at a part's ends are widened (UI.spaceGaps): a part's seam is a gap of the layout.
-- Widths are compared with a margin: in design units at a scale like 1.625 they are fractions, and what is left after
-- one part (the run's width less it) can come out a hair under the next part's width.
local ARROW_W = 16
local EPS = 0.001

local widened = function(part) return UI.spaceGaps(part.s, part.font) end

-- A part's width: `pad` pixels before it, then the arrow or the text.
local function partWidth(part)
    if part.arrow then return ARROW_W + (part.pad or 0) end
    local _, more = widened(part)
    return UI.textWidth(part.s or "", part.font) + more + (part.pad or 0)
end

function Draw.runWidth(parts)
    local w = 0
    for _, part in ipairs(parts) do w = w + partWidth(part) end
    return w
end

function Draw.run(L, parts, x, y, w, align)
    local total = Draw.runWidth(parts)
    if w and align == "right" and total < w then x = x + w - total end
    if w and align == "centre" and total < w then x = x + math.floor((w - total) / 2) end
    local left = w and math.min(w, total) or total
    local cx = x
    for _, part in ipairs(parts) do
        local pw = partWidth(part)
        local pad = part.pad or 0
        cx, pw, left = cx + pad, pw - pad, left - pad
        if part.arrow then
            if pw > left + EPS then break end
            Draw.arrow(L, cx + 3, y + math.floor((L.fh - 7) / 2), part.c, part.a)
        else
            local before = widened(part)
            if pw <= left + EPS then
                Draw.text(L, part.s, cx + before, y, part.c, part.font, part.a)
            else
                if left - before > 0 then Draw.fit(L, part.s, cx + before, y, left - before, part.c, part.font, part.a) end
                cx = cx + left
                break
            end
        end
        cx = cx + pw
        left = left - pw
    end
    return cx - x
end

-- A model's parts (StatusModel.parts) as a run: the plain text in colour `c`, the arguments in their style
-- styles[n] = { c, font } (default: colour `argC` in the number font).
function Draw.styled(L, parts, c, argC, styles)
    local out = {}
    for _, part in ipairs(parts or {}) do
        if part.arg then
            local st = styles and styles[part.arg]
            out[#out + 1] = { s = part.s, c = st and st[1] or argC or c, font = st and st[2] or L.p.numberFont }
        else
            out[#out + 1] = { s = part.s, c = c }
        end
    end
    return out
end

-- A text broken into lines no wider than `w` at its spaces.
function Draw.wrap(text, w, font)
    local lines, current = {}, nil
    for word in string.gmatch(text or "", "%S+") do
        local longer = current and (current .. " " .. word) or word
        if current and UI.textWidth(longer, font) > w then
            lines[#lines + 1] = current
            current = word
        else
            current = longer
        end
    end
    if current then lines[#lines + 1] = current end
    return lines
end

-- Textures ---------------------------------------------------------------------------------------------------------

local textures = {}
-- The icon of an item type (its script's), found once.
function Draw.itemTexture(fullType)
    if not fullType then return nil end
    local tex = textures[fullType]
    if tex == nil then
        local script = getScriptManager():FindItem(fullType)
        tex = script and script:getNormalTexture() or false
        textures[fullType] = tex
    end
    return tex or nil
end

-- An item's icon, tinted on the crude terminal.
function Draw.item(L, fullType, x, y, size, a)
    local tex = Draw.itemTexture(fullType)
    if not tex then return end
    local t = L.p.iconTint or { 1, 1, 1 }
    add(L, { TEX, tex, x, y, size, size, a or 1, t })
end

function Draw.clip(L, x, y, w, h)
    add(L, { CLIP, x, y, w, h })
end

function Draw.unclip(L)
    add(L, { UNCLIP })
end

-- Small glyphs drawn with rectangles ---------------------------------------------------------------------------------

function Draw.lock(L, x, y, c, a)
    Draw.frame(L, x + 2, y, 4, 4, c, a)
    Draw.rect(L, x, y + 4, 8, 5, c, a)
end

function Draw.bullet(L, x, y, c, a)
    Draw.rect(L, x, y + 7, 3, 3, c, a)
end

-- A right arrow 10 wide and 7 high from x, y.
function Draw.arrow(L, x, y, c, a)
    Draw.rect(L, x, y + 3, 10, 1, c, a)
    Draw.rect(L, x + 7, y + 1, 1, 5, c, a)
    Draw.rect(L, x + 8, y + 2, 1, 3, c, a)
    Draw.rect(L, x + 9, y + 3, 1, 1, c, a)
end

-- Widgets -----------------------------------------------------------------------------------------------------------

function Draw.panel(L, x, y, w, h)
    local p = L.p
    if p.panel then Draw.box(L, x, y, w, h, p.panel, 1, p.border) else Draw.box(L, x, y, w, h, p.text, 0.03, p.border) end
end

-- A bar filled to `frac` (with `ticks` equal parts marked).
function Draw.progress(L, x, y, w, h, frac, c)
    local p = L.p
    Draw.rect(L, x, y, w, h, p.border, 0.30)
    Draw.rect(L, x, y, math.floor(w * OA.clamp(frac or 0, 0, 1)), h, c or p.sel, 0.95)
    Draw.frame(L, x - 1, y - 1, w + 2, h + 2, p.border)
end

function Draw.scrollbar(L, x, y, h, top, size)
    local p = L.p
    Draw.rect(L, x, y, 6, h, p.border, 0.25)
    local th = math.max(20, math.floor(h * size))
    Draw.rect(L, x, y + math.floor((h - th) * top), 6, th, p.border, 0.95)
end

-- A button: state "normal", "strong" or "disabled". Its place is kept as a hit { id, tip, enabled, button }.
function Draw.button(L, x, y, w, h, label, state, font, id, tip)
    local p = L.p
    local c, a = p.text, 1
    if state == "disabled" then
        Draw.box(L, x, y, w, h, p.panel or p.bg, p.panel and 0.6 or 0, p.border, 0.5)
        c, a = p.dim, 0.6
    elseif state == "strong" then
        Draw.box(L, x, y, w, h, p.sel, 0.22, p.sel, 0.9)
        c = p.bright
    else
        if p.panel then Draw.box(L, x, y, w, h, p.panel, 1, p.border) else Draw.box(L, x, y, w, h, p.sel, 0.06, p.border) end
    end
    if label and label ~= "" then
        local fh = UI.fontHeight(font)
        Draw.fit(L, label, x + 4, y + math.floor((h - fh) / 2), w - 8, c, font, a, "centre")
    end
    return Draw.hit(L, x, y, w, h, id, tip, state ~= "disabled", true)
end

-- A place that answers the mouse: `id` for a click (when enabled), `tip` (a tooltip from Draw.tip) on hover.
function Draw.hit(L, x, y, w, h, id, tip, enabled, button)
    local hit = { x = x, y = y, w = w, h = h, id = id, tip = tip, enabled = enabled ~= false, button = button }
    L.hits[#L.hits + 1] = hit
    return hit
end

function Draw.hitAt(L, x, y)
    if not L then return nil end
    for i = #L.hits, 1, -1 do
        local hit = L.hits[i]
        if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then return hit end
    end
    return nil
end

-- A tooltip made ready to draw: lines are texts, { s, c, font } or "-" (a rule). Measured once.
function Draw.tip(p, lines)
    local fh = UI.fontHeight(UIFont.Small)
    local tip = { lines = {}, w = 0, h = 4 }
    for _, line in ipairs(lines) do
        if line == "-" then
            tip.lines[#tip.lines + 1] = { rule = true, y = tip.h }
            tip.h = tip.h + 8
        else
            if type(line) == "string" then line = { s = line } end
            local font = line.font or UIFont.Small
            tip.lines[#tip.lines + 1] = { s = line.s, c = line.c or p.text, font = font, y = tip.h }
            tip.w = math.max(tip.w, UI.textWidth(line.s, font))
            tip.h = tip.h + UI.fontHeight(font)
        end
    end
    tip.w = tip.w + 14
    tip.h = tip.h + 4
    return tip
end

-- A step's pixels for the scale now: rx, ry (and rw, rh for a rectangle), by the rounded edges as UI.lua draws them.
-- At scale 1 they are the design numbers as they are.
function Draw.bakeOp(op)
    local s = UI.S
    local k = op[1]
    local x, y, w, h
    if k == TEXT or k == TEX then x, y, w, h = op[3], op[4], op[5], op[6] else x, y, w, h = op[2], op[3], op[4], op[5] end
    if s == 1 then
        op.rx, op.ry = x, y
        if k ~= TEXT then op.rw, op.rh = w, h end
        return
    end
    local floor = math.floor
    op.rx, op.ry = floor(x * s + 0.5), floor(y * s + 0.5)
    if k ~= TEXT and k ~= UNCLIP then
        op.rw, op.rh = floor((x + w) * s + 0.5) - op.rx, floor((y + h) * s + 0.5) - op.ry
    end
end

-- Makes every step pixels (once a list is made, and again if the scale changed).
function Draw.bake(L)
    for _, op in ipairs(L.ops) do
        if op[1] ~= UNCLIP then Draw.bakeOp(op) end
    end
    L.scale = UI.S
end

-- Draws a list on one of our elements (each frame): the baked pixels go to the game's drawing as they are (the
-- element's class without the scaling, el.oaBase).
function Draw.paint(el, L)
    if not L then return end
    if L.scale ~= UI.S then Draw.bake(L) end
    local B = el.oaBase or el
    local rect, border, text, tex = B.drawRect, B.drawRectBorder, B.drawText, B.drawTextureScaledAspect
    local ops = L.ops
    for i = 1, #ops do
        local op = ops[i]
        local k = op[1]
        if k == RECT then
            local c = op[6]
            rect(el, op.rx, op.ry, op.rw, op.rh, op[7], c[1], c[2], c[3])
        elseif k == FRAME then
            local c = op[6]
            border(el, op.rx, op.ry, op.rw, op.rh, op[7], c[1], c[2], c[3])
        elseif k == TEXT then
            local c = op[5]
            text(el, op[2], op.rx, op.ry, c[1], c[2], c[3], op[6], op[7])
        elseif k == TEX then
            local t = op[8]
            tex(el, op[2], op.rx, op.ry, op.rw, op.rh, op[7], t[1], t[2], t[3])
        elseif k == CLIP then
            B.setStencilRect(el, op.rx, op.ry, op.rw, op.rh)
        elseif k == UNCLIP then
            B.clearStencilRect(el)
        end
    end
end

-- Draws a tooltip near x, y, kept inside the element where it fits.
function Draw.paintTip(el, p, tip, x, y)
    if x + tip.w > el.width then x = math.max(0, el.width - tip.w) end
    if y + tip.h > el.height then y = math.max(0, y - tip.h - 24) end
    el:drawRect(x, y, tip.w, tip.h, 0.92, 0, 0, 0)
    el:drawRectBorder(x, y, tip.w, tip.h, 1, p.border[1], p.border[2], p.border[3])
    for _, line in ipairs(tip.lines) do
        if line.rule then
            el:drawRect(x + 6, y + line.y + 4, tip.w - 12, 1, 1, p.border[1], p.border[2], p.border[3])
        else
            el:drawText(line.s, x + 7, y + line.y, line.c[1], line.c[2], line.c[3], 1, line.font)
        end
    end
end

-- The base of the status tab's screens -------------------------------------------------------------------------------
-- A screen gives `build(L, w, h)` (lays its data out into the list) and may give `model()` (works the data out from
-- the record, on refresh) and `onHit(hit)`. The list is made again when the record changes or the size does.
OAStatusView = OATab:derive("OAStatusView")

function OAStatusView:refresh()
    local record = self:record()
    if not record then return end
    if self.model then self.data = self:model(record) end
    self:layout()
end

function OAStatusView:layout()
    self.laidW, self.laidH = self.width, self.height
    if not self.data then return end
    local L = Draw.list(self:palette())
    self:build(L, self.width, self.height)
    Draw.bake(L)
    self.list = L
end

function OAStatusView:prerender()
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    Draw.paint(self, self.list)
end

-- On top: the hover of a button or a card, and the tooltip of what the mouse is over.
function OAStatusView:render()
    if not (self.list and self:isMouseOver()) then return end
    local mx, my = self:getMouseX(), self:getMouseY()
    local hit = Draw.hitAt(self.list, mx, my)
    if not hit then return end
    local p = self:palette()
    if hit.button and hit.enabled then
        self:drawRect(hit.x + 1, hit.y + 1, hit.w - 2, hit.h - 2, 0.10, p.sel[1], p.sel[2], p.sel[3])
    elseif hit.hover then
        self:drawRect(hit.x + 1, hit.y + 1, hit.w - 2, hit.h - 2, 0.08, p.sel[1], p.sel[2], p.sel[3])
    end
    if hit.tip then Draw.paintTip(self, p, hit.tip, mx + 12, my + 18) end
end

function OAStatusView:onMouseDown(x, y)
    local hit = Draw.hitAt(self.list, x, y)
    if hit and hit.id and hit.enabled and self.onHit then self:onHit(hit) end
    return true
end

return Draw
