-- A drop-down choice in its window's palette, the kit's in place of the game's
-- ISComboBox, which draws in the game's font: a box with the chosen text and an arrow; a click opens the list of the
-- choices under it (above it near the bottom of the screen), a click on one chooses it and calls onChange(target,
-- combo), a click anywhere else closes the list. In design units and the kit's faces (UI.lua). Its calls are the game's combo's: clear, addOptionWithData, selected, getSelectedData.
require "ISUI/ISPanel"
require "PZUIKit/UI"
local UI = PZUIKit.UI

PZUICombo = ISPanel:derive("PZUICombo")

-- The most rows the list shows at once (the wheel scrolls the rest), and a row's margin above and below its text.
PZUICombo.ROWS = 8
PZUICombo.ROW_PAD = 3
-- How soon (real ms) after the list closed on a click on the combo the combo's own handler hears the same click.
PZUICombo.SAME_CLICK_MS = 100

function PZUICombo:new(x, y, width, height, palette, target, onChange)
    local o = ISPanel.new(self, x, y, width, height)
    o.palette, o.target, o.onChange = palette, target, onChange
    o.options, o.selected = {}, 1
    o.background = false
    return o
end

function PZUICombo:clear()
    self.options, self.selected = {}, 1
    self:closeList()
end

function PZUICombo:addOptionWithData(text, data)
    self.options[#self.options + 1] = { text = text, data = data }
end

function PZUICombo:getSelectedData()
    local o = self.options[self.selected]
    return o and o.data
end

-- A small arrow down, 7 dots wide and 4 high, from x, y (rectangles: the fonts have none).
local function arrowDown(el, x, y, c)
    local u = UI.dot()
    for k = 0, 3 do UI.fill(el, x + k * u, y + k * u, (7 - 2 * k) * u, u, c) end
end

function PZUICombo:prerender()
    local p = self.palette
    local w, h = self.width, self.height
    UI.fill(self, 0, 0, w, h, p.dark)
    local k = UI.hoverLight(self, "hover", self:isMouseOver() or self.list ~= nil)
    if k > 0 then UI.fill(self, 0, 0, w, h, p.sel, 0.3 * k) end
    UI.frame(self, 0, 0, w, h, p.border)
    local o = self.options[self.selected]
    if o then
        if self.fitW ~= w or self.fitOf ~= o.text then
            self.fitW, self.fitOf = w, o.text
            self.fit = UI.fit(o.text, w - 26)
        end
        UI.text(self, self.fit, 6, (h - UI.fontHeight()) / 2, p.text)
    end
    arrowDown(self, w - 15, math.floor((h - 4 * UI.dot()) / 2), p.text)
end

function PZUICombo:onMouseDown(x, y)
    local closed = self.closedAt
    self.closedAt = nil
    if closed and getTimestampMs() - closed < PZUICombo.SAME_CLICK_MS then
        -- this click closed the list (it came to the list first): it does not open it again
        return true
    end
    if self.list then
        self:closeList()
    elseif #self.options > 0 then
        self:openList()
    end
    return true
end

function PZUICombo:openList()
    local list = PZUIComboList:new(self)
    list:initialise()
    list:addToUIManager()
    list:setAlwaysOnTop(true)
    self.list = list
end

function PZUICombo:closeList()
    local list = self.list
    if not list then return end
    self.list = nil
    list:setVisible(false)
    list:removeFromUIManager()
end

function PZUICombo:choose(i)
    self:closeList()
    if not self.options[i] then return end
    self.selected = i
    getSoundManager():playUISound("UISelectListItem")
    if self.onChange then self.onChange(self.target, self) end
end

function PZUICombo:setVisible(visible)
    if not visible then self:closeList() end
    ISPanel.setVisible(self, visible)
end

UI.scaled(PZUICombo, ISPanel)

-- The open list of a combo: over everything, at the combo's place on the screen (design units).
PZUIComboList = ISPanel:derive("PZUIComboList")

function PZUIComboList:new(combo)
    local fh = UI.fontHeight()
    local rowH = fh + 2 * PZUICombo.ROW_PAD
    local width = combo.width
    for _, o in ipairs(combo.options) do width = math.max(width, UI.textWidth(o.text) + 16) end
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    width = math.min(width, screenW)
    local shown = math.min(#combo.options, PZUICombo.ROWS)
    local h = shown * rowH + 2
    local x = math.max(0, math.min(UI.dp(combo:getAbsoluteX()), screenW - width))
    local top = UI.dp(combo:getAbsoluteY())
    local y = top + combo.height
    if y + h > screenH then y = math.max(0, top - h) end
    local o = ISPanel.new(self, x, y, width, h)
    o.combo, o.rowH, o.shown, o.first = combo, rowH, shown, 0
    o.fits = {}
    for i, opt in ipairs(combo.options) do o.fits[i] = UI.fit(opt.text, width - 12) end
    o.background = false
    -- the chosen one in sight
    o.first = math.max(0, math.min(combo.selected - 1, #combo.options - shown))
    return o
end

function PZUIComboList:prerender()
    local combo = self.combo
    if combo.list ~= self or not combo:isReallyVisible() then return combo.list == self and combo:closeList() end
    local p = combo.palette
    UI.fill(self, 0, 0, self.width, self.height, p.bg, 0.98)
    UI.frame(self, 0, 0, self.width, self.height, p.border)
    local over = self:isMouseOver() and self:rowAt(self:getMouseY()) or nil
    local fh = UI.fontHeight()
    for k = 1, self.shown do
        local i = self.first + k
        local y = 1 + (k - 1) * self.rowH
        if i == combo.selected then UI.fill(self, 1, y, self.width - 2, self.rowH, p.sel, 0.25)
        elseif i == over then UI.fill(self, 1, y, self.width - 2, self.rowH, p.sel, 0.12) end
        UI.text(self, self.fits[i], 6, y + (self.rowH - fh) / 2, i == combo.selected and p.bright or p.text)
    end
    local n = #combo.options
    if n > self.shown then
        -- where the rows on show are among all of them: a thin bar on the right
        local th = math.max(8, math.floor(self.height * self.shown / n))
        local ty = math.floor((self.height - th) * self.first / (n - self.shown))
        UI.fill(self, self.width - 4, ty, 3, th, p.border, 0.9)
    end
end

-- The choice under y (design units from the list's top), or nil.
function PZUIComboList:rowAt(y)
    local k = math.floor((y - 1) / self.rowH) + 1
    if k < 1 or k > self.shown then return nil end
    return self.first + k
end

function PZUIComboList:onMouseDown(x, y)
    local i = self:rowAt(y)
    if i then self.combo:choose(i) end
    return true
end

function PZUIComboList:onMouseDownOutside()
    local combo = self.combo
    if combo.list ~= self then return end
    -- a click on the combo itself closes the list here: the combo is told not to open it again for that click
    if combo:isMouseOver() then combo.closedAt = getTimestampMs() end
    combo:closeList()
end

function PZUIComboList:onMouseWheel(del)
    local n = #self.combo.options
    self.first = math.max(0, math.min(n - self.shown, self.first + del))
    return true
end

UI.scaled(PZUIComboList, ISPanel)

return PZUICombo
