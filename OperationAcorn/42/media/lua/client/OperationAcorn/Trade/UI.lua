-- Small helpers for the trade part's windows: the same few widgets (a label, a button, a list, a rich text) with the
-- sizes the game's own windows use.
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISRichTextPanel"
require "OperationAcorn/Trade/Text"
local OA = OperationAcorn
local UI = {}
OA.Trade.UI = UI

UI.PAD = 10

-- The room between a number and its unit ("627 크레딧"): the Korean small font's space is two or three pixels, too
-- thin to read as one.
UI.UNIT_GAP = 4

-- The unit of money as the screens write it after a number, without a space (UI.UNIT_GAP goes before it).
function UI.creditsUnit()
    return getText("IGUI_OA_Terminal_Credits")
end

-- The two terminals' colours (DESIGN-terminal 1.3): the crude one built from the kit, phosphor green on near black;
-- the field terminal ordered from the shop, warm white and amber on olive. Every screen draws from the palette of
-- the terminal it is open at. Colours are { r, g, b }.
UI.PALETTES = {
    crude = {
        bg = { 0.02, 0.05, 0.03 }, bgAlpha = 0.95, panel = nil,
        text = { 0.45, 0.95, 0.55 }, dim = { 0.25, 0.55, 0.30 }, bright = { 0.78, 1.0, 0.82 },
        value = { 0.78, 1.0, 0.82 }, head = { 0.78, 1.0, 0.82 }, border = { 0.20, 0.50, 0.25 },
        warn = { 0.95, 0.75, 0.30 }, bad = { 1, 0.45, 0.35 }, good = { 0.78, 1.0, 0.82 },
        sel = { 0.45, 0.95, 0.55 }, title = { 0.04, 0.10, 0.05 }, dark = { 0.02, 0.05, 0.03 },
        tabStrip = nil, numberFont = UIFont.Code, iconTint = { 0.6, 1, 0.6 }, scanlines = true, tape = true,
    },
    field = {
        bg = { 0.10, 0.11, 0.08 }, bgAlpha = 0.96, panel = { 0.15, 0.16, 0.12 },
        text = { 0.92, 0.90, 0.82 }, dim = { 0.62, 0.60, 0.52 }, bright = { 1, 0.98, 0.92 },
        value = { 1, 0.82, 0.25 }, head = { 1, 0.82, 0.25 }, border = { 0.42, 0.45, 0.30 },
        warn = { 1, 0.82, 0.25 }, bad = { 1, 0.45, 0.35 }, good = { 0.6, 0.95, 0.6 },
        sel = { 1, 0.82, 0.25 }, title = { 0.30, 0.33, 0.20 }, dark = { 0.10, 0.11, 0.08 },
        tabStrip = { 0.30, 0.33, 0.20 }, numberFont = UIFont.Small, iconTint = nil, scanlines = false, tape = false,
    },
}
-- The tape over the crude terminal's corners.
UI.TAPE = { 0.75, 0.68, 0.45 }

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

-- The game measures a Code font text (the crude terminal's numbers) to the last glyph's ink, not to the end of its
-- cell: "8" is 5 pixels, "88" 13. The glyph sits a little right in its cell, so whatever follows overlapped it and
-- the thin space of the small font after it disappeared ("8/ 37,000"). Its width counts this much more.
UI.CODE_TAIL = 3

function UI.text(el, text, x, y, c, font, a)
    el:drawText(text, x, y, c[1], c[2], c[3], a or 1, font or UIFont.Small)
end

function UI.textCentre(el, text, x, y, c, font, a)
    el:drawTextCentre(text, x, y, c[1], c[2], c[3], a or 1, font or UIFont.Small)
end

-- Ends at x by UI.textWidth (the game's own right alignment would let a Code font text run past x).
function UI.textRight(el, text, x, y, c, font, a)
    el:drawText(text, x - UI.textWidth(text, font), y, c[1], c[2], c[3], a or 1, font or UIFont.Small)
end

function UI.fontHeight(font)
    return getTextManager():getFontHeight(font or UIFont.Small)
end

function UI.buttonHeight()
    return UI.fontHeight(UIFont.Small) + 10
end

function UI.textWidth(text, font)
    local w = getTextManager():MeasureStringX(font or UIFont.Small, text)
    if font and font == UIFont.Code and text ~= "" then w = w + UI.CODE_TAIL end
    return w
end

-- The text cut to a width with "..." at the end (whole when it fits). The game's strings are per character, so a cut
-- never splits a letter.
function UI.fit(text, width, font)
    if UI.textWidth(text, font) <= width then return text end
    local cut = text
    while #cut > 1 and UI.textWidth(cut .. "...", font) > width do
        cut = string.sub(cut, 1, #cut - 1)
    end
    return cut .. "..."
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

-- A label at x, y.
function UI.label(parent, x, y, text, color, font)
    color = color or { r = 0.9, g = 0.9, b = 0.9, a = 1 }
    local label = ISLabel:new(x, y, UI.fontHeight(font), text, color.r, color.g, color.b, color.a, font or UIFont.Small, true)
    label:initialise()
    label:instantiate()
    parent:addChild(label)
    return label
end

-- A button whose click calls onclick(target, button).
function UI.button(parent, x, y, width, title, target, onclick)
    local button = ISButton:new(x, y, width, UI.buttonHeight(), title, target, onclick)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
    parent:addChild(button)
    return button
end

-- Sizes an element and places its vertical scroll bar along its right edge. The game moves a scroll bar by its anchors,
-- by the change since the element's size was last set; a layout that sets a size twice in a frame leaves that change
-- at nothing and the bar at its old height. So the bar is unanchored and placed here.
function UI.size(el, w, h)
    el:setWidth(w)
    el:setHeight(h)
    local bar = el.vscroll
    if bar then
        bar:setAnchorRight(false)
        bar:setAnchorBottom(false)
        bar:setX(w - 16)
        bar:setHeight(h)
    end
end

-- A list with rows drawn by `drawRow(list, y, item, alt)`, which returns the y of the next row. The row's own height
-- is the list's itemheight.
function UI.list(parent, x, y, width, height, drawRow, target, onclick)
    local list = ISScrollingListBox:new(x, y, width, height)
    list:initialise()
    list:instantiate()
    list.font = UIFont.Small
    list.fontHgt = UI.fontHeight(UIFont.Small)
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
        drawRow(self, rowY, item, alt)
        return rowY + item.height
    end
    if onclick then list:setOnMouseDownFunction(target, onclick) end
    parent:addChild(list)
    return list
end

-- A scrolling rich text panel.
function UI.rich(parent, x, y, width, height, class)
    local panel = (class or ISRichTextPanel):new(x, y, width, height)
    panel:initialise()
    panel:instantiate()
    panel.autosetheight = false
    panel.clip = true
    panel.marginLeft = 8
    panel.marginRight = 8
    panel.marginTop = 6
    panel.marginBottom = 6
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

-- Asks yes or no; onYes(target, a, b) runs on yes.
function UI.confirm(character, text, target, onYes, a, b)
    local modal = ISModalDialog:new(0, 0, 360, 150, text, true, nil, function(_, button)
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
