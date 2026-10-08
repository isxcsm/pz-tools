-- The terminal's market tab: this week's requests, today's index for each category, and (once the trust reward for
-- the terminal's graph is reached) the last thirty days of the selected category as a line. The forecast arrow comes
-- with its own reward. Values are the economy part's (OA.Market, OA.Requests).
require "OperationAcorn/Trade/TerminalWindow"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text

OATabMarket = OATab:derive("OATabMarket")

local ARROW = { up = "IGUI_OA_Trade_Market_Up", down = "IGUI_OA_Trade_Market_Down", flat = "IGUI_OA_Trade_Market_Flat" }

function OATabMarket:createChildren()
    local pad = UI.PAD
    local fh = UI.fontHeight()
    local half = math.floor(self.width * 0.42)
    local top = pad + fh + 4
    local height = self.height - top - pad
    UI.label(self, pad, pad, getText("IGUI_OA_Trade_Market_Requests"))
    UI.label(self, half + pad / 2, pad, getText("IGUI_OA_Trade_Market_Categories"))
    self.requests = UI.list(self, pad, top, half - pad * 1.5, height, OATabMarket.drawRequest)
    self.requests.anchorBottom = true
    local right = self.width - half - pad * 1.5
    local listHeight = math.floor(height * 0.5)
    self.categories = UI.list(self, half + pad / 2, top, right, listHeight, OATabMarket.drawCategory, self, OATabMarket.onSelect)
    self.categories.anchorRight = true
    self.categoryHeight = listHeight
    self.graphX, self.graphY, self.graphW, self.graphH = half + pad / 2, top + listHeight + pad, right, height - listHeight - pad
end

function OATabMarket.drawRequest(list, y, item)
    local row = item.item
    local pad = list.itemPadY
    list:drawText(row.name, 8, y + pad, 0.92, 0.92, 0.92, 1, list.font)
    local text = row.text
    list:drawText(text, list.width - 20 - UI.textWidth(text), y + pad, 0.85, 0.8, 0.5, 1, list.font)
end

function OATabMarket.drawCategory(list, y, item)
    local row = item.item
    local pad = list.itemPadY
    list:drawText(row.name, 8, y + pad, 0.92, 0.92, 0.92, 1, list.font)
    local c = row.index >= 1.15 and { 0.6, 0.95, 0.6 } or (row.index <= 0.85 and { 0.95, 0.6, 0.55 } or { 0.85, 0.85, 0.85 })
    local text = row.arrow and (string.format("%.2f", row.index) .. "  " .. row.arrow) or string.format("%.2f", row.index)
    list:drawText(text, list.width - 20 - UI.textWidth(text), y + pad, c[1], c[2], c[3], 1, list.font)
end

function OATabMarket:onSelect()
    self:refreshGraph()
end

function OATabMarket:refresh()
    local record = self:record()
    if not record or not (OA.Market and OA.Requests and OA.Categories) then return end
    local rewards = OA.Trust.rewards(record)
    self.requests:clear()
    for _, fullType in ipairs(OA.Requests.list(record)) do
        local bonus, left = OA.Requests.bonusFor(record, fullType)
        local text = left > 0 and getText("IGUI_OA_Trade_Market_Bonus", math.floor(bonus * 100 + 0.5) .. "%", left) or getText("IGUI_OA_Trade_Market_Used")
        self.requests:addItem(fullType, { name = Text.nameOf(fullType), text = text })
    end
    local selected = self.categories.selected
    self.categories:clear()
    for _, letter in ipairs(OA.Categories.LETTERS) do
        local arrow
        if rewards.marketForecast then arrow = getText(ARROW[OA.Market.forecast(letter)] or ARROW.flat) end
        self.categories:addItem(letter, { letter = letter, name = getText(OA.Categories.nameKey(letter)),
            index = OA.Market.index(letter), arrow = arrow })
    end
    if selected and selected <= self.categories.count then self.categories.selected = selected end
    self.graphOpen = rewards.terminalGraph and true or false
    self:refreshGraph()
end

-- The history of the selected category, kept for render.
function OATabMarket:refreshGraph()
    self.history = nil
    local row = self.categories.items[self.categories.selected]
    row = row and row.item
    if row and self.graphOpen then
        self.history = OA.Market.history(row.letter)
        self.graphLetter = row.letter
    end
end

function OATabMarket:render()
    ISPanel.render(self)
    local x, y, w, h = self.graphX, self.graphY, self.graphW, self.graphH
    self:drawRect(x, y, w, h, 0.35, 0, 0, 0)
    self:drawRectBorder(x, y, w, h, 0.9, 0.4, 0.4, 0.4)
    if not self.graphOpen then
        self:drawText(getText("IGUI_OA_Trade_Market_GraphLocked"), x + 8, y + 8, 0.7, 0.7, 0.7, 1, UIFont.Small)
        return
    end
    local history = self.history
    if not history or #history < 2 then
        self:drawText(getText("IGUI_OA_Trade_Market_NoHistory"), x + 8, y + 8, 0.7, 0.7, 0.7, 1, UIFont.Small)
        return
    end
    local lo, hi = 0.5, 1.5
    for _, point in ipairs(history) do
        if point.i < lo then lo = point.i end
        if point.i > hi then hi = point.i end
    end
    local left, right, top, bottom = x + 8, x + w - 8, y + 8, y + h - 8
    local function py(index) return bottom - (index - lo) / (hi - lo) * (bottom - top) end
    -- The line of 1.0, where the market rests.
    self:drawLine2(left, py(1.0), right, py(1.0), 0.5, 0.6, 0.6, 0.6)
    local first, last = history[1].d, history[#history].d
    local span = math.max(1, last - first)
    local px, pyy
    for _, point in ipairs(history) do
        local nx = left + (point.d - first) / span * (right - left)
        local ny = py(point.i)
        if px then self:drawLine2(px, pyy, nx, ny, 1, 0.95, 0.85, 0.45) end
        px, pyy = nx, ny
    end
end

OA.Terminal.addTab("market", "IGUI_OA_Trade_Tab_Market", function(x, y, w, h, window)
    return OATabMarket:new(x, y, w, h, window)
end)
