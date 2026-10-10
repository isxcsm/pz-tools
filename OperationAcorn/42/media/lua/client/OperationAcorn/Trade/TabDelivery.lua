-- The terminal's delivery tab (DESIGN-terminal 5): this week's request groups with their fixed prices, how much of each
-- the week has taken, what a full line gives, the settlement the sealed boxes would make, and under it this week's
-- situation: the market's events, the season, and today's index of each category. A row shows its group's name and
-- picture; the mouse over it lists the kinds the group takes. Everything is worked out when the record changes (or the
-- day does) and the frames only draw it.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/Estimate"
require "OperationAcorn/Economy/Requests"
require "OperationAcorn/Economy/Market"
require "OperationAcorn/Economy/Season"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Boxes, Estimate = Trade.Boxes, Trade.Estimate

OATabDelivery = OATab:derive("OATabDelivery")

OATabDelivery.ROW_H = 26
-- Under this width (the window near its smallest) the columns tighten and the note takes two lines.
OATabDelivery.NARROW = 680
-- How many lines of events the situation shows: the rest are counted.
OATabDelivery.SIT_MAX = 5
-- How many kinds a row's tooltip names: the rest are counted.
OATabDelivery.TIP_MAX = 12
-- An index at or past these is drawn as high or low.
OATabDelivery.CHIP_HIGH, OATabDelivery.CHIP_LOW = 1.15, 0.85
-- Frames between looking whether the day or the market has moved on while the tab is open.
OATabDelivery.WATCH = 120

local WHITE = { 1, 1, 1 }

-- 1.5 as "1.5", 1.25 as "1.25", 1 as "1.0".
local function trimmed(v)
    local s = string.format("%.2f", v)
    if string.sub(s, -1) == "0" then s = string.sub(s, 1, -2) end
    return s
end

-- The text cut into lines no wider than `width`: at spaces, or inside a word that is wider by itself.
local function wrap(text, width)
    local lines = {}
    local line = ""
    for word in string.gmatch(text, "%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if UI.textWidth(try) <= width then
            line = try
        else
            if line ~= "" then lines[#lines + 1] = line end
            line = word
            while UI.textWidth(line) > width and #line > 1 do
                local cut = line
                while #cut > 1 and UI.textWidth(cut) > width do cut = string.sub(cut, 1, #cut - 1) end
                lines[#lines + 1] = cut
                line = string.sub(line, #cut + 1)
            end
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

function OATabDelivery:createChildren()
    local list = ISScrollingListBox:new(0, 0, self.width, 100)
    list:initialise()
    list:instantiate()
    list.font = UIFont.Small
    list.itemheight = OATabDelivery.ROW_H
    list.drawBorder = false
    list.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    list.doDrawItem = OATabDelivery.drawRow
    -- The rows are for reading: a click on one selects nothing and makes no sound.
    list.onMouseDown = function() end
    list.tab = self
    self:addChild(list)
    self.list = list
    self.data = nil
    self.stamp = nil
    self.frames = 0
end

-- Data --------------------------------------------------------------------------------------------------------

local function itemTexture(fullType)
    local script = getScriptManager():FindItem(fullType)
    return script and script:getNormalTexture() or nil
end

-- The days until the week's list changes, as a text.
local function refreshText()
    local left = (OA.week() + 1) * 7 - OA.day()
    if left <= 1 then return getText("IGUI_OA_Terminal_Del_RefreshOne") end
    return getText("IGUI_OA_Terminal_Del_Refresh", left)
end

-- The tooltip lines of a group: the kinds it takes (a group of one has none).
local function tipOf(key)
    local names = OA.Requests.memberNames(key)
    if #names < 2 then return nil end
    local lines = { getText("IGUI_OA_Terminal_Del_Takes") }
    local shown = math.min(#names, OATabDelivery.TIP_MAX)
    if shown < #names then shown = shown - 1 end
    for i = 1, shown do lines[#lines + 1] = names[i] end
    if shown < #names then lines[#lines + 1] = getText("IGUI_OA_Terminal_Del_TakesMore", #names - shown) end
    return lines
end

-- The rows of the week's list: what each shows, from the record and the sealed boxes' estimate.
local function rowsOf(record, worth)
    local sealed = {}
    for _, r in ipairs(worth and worth.requests and worth.requests.lines or {}) do
        local key = r.key or r.fullType
        sealed[key] = (sealed[key] or 0) + r.units
    end
    local rows = {}
    for _, line in ipairs(OA.Requests.entries(record)) do
        local key = line.key
        rows[#rows + 1] = {
            key = key, name = OA.Requests.nameOf(key), texture = itemTexture(OA.Requests.iconType(key)),
            tip = tipOf(key),
            band = line.band, bandText = getText("IGUI_OA_Terminal_Del_Band_" .. line.band),
            price = Text.credits(line.price), used = line.used, qty = line.qty, sealed = sealed[key] or 0,
            progress = line.used .. "/" .. line.qty, full = line.full, trust = "+" .. line.trust,
        }
    end
    return rows
end

-- The lines of this week's situation: what the market has on now, from its state; nothing was kept for them.
local function situationOf()
    local lines = {}
    local all = OA.Market.situation()
    local shown = #all
    if shown > OATabDelivery.SIT_MAX then shown = OATabDelivery.SIT_MAX - 1 end
    for i = 1, shown do
        local e = all[i]
        local text = e.withCat and getText(e.key, getText(OA.Categories.nameKey(e.cat))) or getText(e.key)
        local line = { text = text, kind = e.kind == "raise" and "good" or "bad",
            left = getText("IGUI_OA_Terminal_Del_SitLeft", e.left) }
        if e.mult then line.mult = getText("IGUI_OA_Terminal_Del_SitMult", trimmed(e.mult)) end
        lines[#lines + 1] = line
    end
    if #all > shown then
        lines[#lines + 1] = { text = getText("IGUI_OA_Terminal_Del_SitMore", #all - shown), kind = "dim" }
    end
    if #lines == 0 then lines[1] = { text = getText("IGUI_OA_Terminal_Del_SitNone"), kind = "dim" } end
    return lines
end

-- The eleven categories' index today, with the forecast arrow when the record has the upgrade.
local function chipsOf(record)
    local forecast = OA.Trust.rewards(record).marketForecast
    local chips = {}
    for i, letter in ipairs(OA.Categories.LETTERS) do
        local value = OA.Market.index(letter)
        local chip = { value = string.format("%.2f", value), name = getText("IGUI_OA_Econ_CatShort_" .. letter) }
        if OA.Market.refused(letter) then
            chip.kind = "off"
        else
            chip.kind = value >= OATabDelivery.CHIP_HIGH and "hi" or (value <= OATabDelivery.CHIP_LOW and "lo" or "mid")
            if forecast then
                local way = OA.Market.forecast(letter)
                if way ~= "flat" then chip.trend = way end
            end
        end
        chip.tip = getText("IGUI_OA_Terminal_Del_ChipTip", getText(OA.Categories.nameKey(letter)), chip.value)
        chips[i] = chip
    end
    return chips
end

function OATabDelivery:refresh()
    local record = self:record()
    if not record then return end
    local worth = Estimate.entries(record, Boxes.sealedEntries(record))
    local rows = rowsOf(record, worth)
    local expect
    if worth and worth.requests.units > 0 then
        local fill = 0
        for _, f in ipairs(worth.filled or {}) do fill = fill + f.trust end
        if fill > 0 then
            expect = getText("IGUI_OA_Terminal_Del_ExpectFull", Text.credits(worth.requests.credits), Text.credits(fill))
        else
            expect = getText("IGUI_OA_Terminal_Del_Expect", Text.credits(worth.requests.credits))
        end
    end
    self.data = {
        head = getText("IGUI_OA_Terminal_Del_Head", #rows),
        priceLabel = getText("IGUI_OA_Support_Name_reqprice") .. " ",
        price = Text.TIMES .. trimmed(OA.Trust.rewards(record).requestPrice),
        refresh = refreshText(),
        rows = rows,
        expect = expect,
        sitHead = getText("IGUI_OA_Terminal_Del_Sit", getText(OA.Season.nameKey(OA.Season.current()))),
        sit = situationOf(),
        chips = chipsOf(record),
        chipOff = getText("IGUI_OA_Terminal_Del_ChipOff"),
        news = OA.Market.news(),
        day = OA.day(),
    }
    local list = self.list
    list:clear()
    for _, row in ipairs(rows) do list:addItem(row.name, row) end
    self:layout()
end

-- Layout ------------------------------------------------------------------------------------------------------

-- The places of the columns and the panel, worked out when the data or the size changes.
function OATabDelivery:layout()
    local d = self.data
    if not d then return end
    local w, h = self:getWidth(), self:getHeight()
    self.laidW, self.laidH = w, h
    local fh = UI.fontHeight()
    local m = { narrow = w < OATabDelivery.NARROW }
    m.NX, m.RX = 32, m.narrow and 178 or 214
    m.PX = m.RX + 44
    m.BX = m.PX + 84
    m.BW = w - m.BX - (m.narrow and 150 or 168)
    m.CX = m.BX + m.BW + 6
    m.GX = m.CX + 48
    m.nameW = m.RX - m.NX - 10
    m.headY = 20
    m.listY = m.headY + 22
    m.lineH = fh + 2
    -- What each row draws that depends on the width: the name cut to its column, the words before the trust.
    local trustWord = getText("IGUI_OA_Terminal_Del_Trust") .. " "
    local doneWord = getText("IGUI_OA_Terminal_Del_DoneShort")
    if not m.narrow then doneWord = doneWord .. Text.DOT .. trustWord end
    local trustW, doneW = UI.textWidth(trustWord), UI.textWidth(doneWord)
    for _, row in ipairs(d.rows) do
        row.nameFit = UI.fit(row.name, m.nameW)
        row.word = row.full and doneWord or trustWord
        row.wordW = row.full and doneW or trustW
    end
    d.priceX = 150 + UI.textWidth(d.priceLabel)
    -- Under the list: the note, and the settlement the sealed boxes would make.
    d.noteLines = wrap(getText("IGUI_OA_Terminal_Del_Note"), w)
    local noteH = #d.noteLines * fh + 4
    local expectH = d.expect and fh + 4 or 0
    d.expectFit = d.expect and UI.fit(d.expect, w) or nil
    -- The situation panel at the bottom.
    m.sitH = 24 + fh * #d.sit + 52
    for i, line in ipairs(d.sit) do
        line.fit = UI.fit(line.text, w - 170)
        if line.left then
            local sep = line.mult and Text.DOT or ""
            local wl, ws = UI.textWidth(line.left), UI.textWidth(sep)
            local wm = line.mult and UI.textWidth(line.mult) or 0
            line.xLeft = w - 10 - wl
            line.xSep = line.xLeft - ws
            line.xMult = line.xSep - wm
            line.sep = sep
        end
    end
    m.sitY = h - m.sitH
    local avail = math.max(OATabDelivery.ROW_H * 2, m.sitY - noteH - expectH - 4 - m.listY)
    local listH = math.min(OATabDelivery.ROW_H * #d.rows, avail)
    m.listW = w - 8
    m.noteY = m.listY + listH + 4
    m.expectY = m.noteY + noteH
    self.list:setY(m.listY)
    UI.size(self.list, w, listH)
    self.list:setVisible(#d.rows > 0)
    -- The index chips, six and five in two rows.
    local perRow = 6
    local cw = math.floor((w - 20 - (perRow - 1) * 4) / perRow)
    m.chipW = cw
    m.chipY = m.sitH - 48
    d.chipRects = {}
    for k = 1, #d.chips do
        d.chipRects[k] = { x = 10 + ((k - 1) % perRow) * (cw + 4), y = m.chipY + math.floor((k - 1) / perRow) * 22 }
    end
    self.metrics = m
end

-- Drawing -----------------------------------------------------------------------------------------------------

local function kindColor(p, kind)
    if kind == "good" then return p.good end
    if kind == "bad" then return p.bad end
    if kind == "hi" then return p.good end
    if kind == "lo" then return p.bad end
    if kind == "off" or kind == "dim" then return p.dim end
    return p.text
end

-- One row of the list (the list's own doDrawItem, in the content's coordinates).
function OATabDelivery.drawRow(list, y, item, alt)
    local tab = list.tab
    local m = tab.metrics
    if not m then return y + item.height end
    local p = tab:palette()
    local row = item.item
    local nf = p.numberFont
    local fh = UI.fontHeight()
    local ty = y + (OATabDelivery.ROW_H - fh) / 2
    local done = row.full
    if alt then UI.fill(list, 0, y, m.listW, OATabDelivery.ROW_H, p.text, 0.03) end
    if row.texture then
        local tint = p.iconTint or WHITE
        list:drawTextureScaledAspect(row.texture, 2, y + 1, 24, 24, done and 0.5 or 1, tint[1], tint[2], tint[3])
    end
    UI.text(list, row.nameFit, m.NX, ty, done and p.dim or p.text)
    local band = row.band == "rare" and p.warn or (row.band == "normal" and p.text or p.dim)
    UI.text(list, row.bandText, m.RX, ty, band)
    UI.textRight(list, row.price, m.PX + 70, ty, done and p.dim or p.text, nf)
    local fill = p.tabStrip and p.value or p.sel
    local frac = row.used / row.qty
    UI.fill(list, m.BX, y + 9, m.BW, 8, p.border, 0.30)
    UI.fill(list, m.BX, y + 9, math.floor(m.BW * frac), 8, fill, done and 0.5 or 0.9)
    if row.sealed > 0 then
        UI.fill(list, m.BX + math.floor(m.BW * frac), y + 9, math.floor(m.BW * row.sealed / row.qty), 8, fill, 0.35)
    end
    UI.frame(list, m.BX - 1, y + 8, m.BW + 2, 10, p.border)
    UI.text(list, row.progress, m.CX, ty, done and p.dim or p.text, nf)
    UI.text(list, row.word, m.GX, ty, p.dim)
    if not (done and m.narrow) then UI.text(list, row.trust, m.GX + row.wordW, ty, done and p.dim or p.text, nf) end
    return y + item.height
end

-- A framed box with a heading, as the situation sits in.
local function panelBox(el, p, x, y, w, h, title)
    if p.panel then UI.fill(el, x, y, w, h, p.panel) end
    UI.frame(el, x, y, w, h, p.border)
    UI.text(el, title, x + 10, y + 4, p.head)
end

local function drawTriangle(el, x, y, up, c)
    -- Drawn from rectangles: the fonts have no triangle. Five wide, three high.
    if up then
        UI.fill(el, x + 2, y, 1, 1, c)
        UI.fill(el, x + 1, y + 1, 3, 1, c)
        UI.fill(el, x, y + 2, 5, 1, c)
    else
        UI.fill(el, x, y, 5, 1, c)
        UI.fill(el, x + 1, y + 1, 3, 1, c)
        UI.fill(el, x + 2, y + 2, 1, 1, c)
    end
end

function OATabDelivery:prerender()
    if self.data and (self.laidW ~= self:getWidth() or self.laidH ~= self:getHeight()) then self:layout() end
    local d, m = self.data, self.metrics
    if not (d and m) then return end
    local p = self:palette()
    local w = self:getWidth()
    local nf = p.numberFont
    local fh = UI.fontHeight()
    UI.text(self, d.head, 0, 0, p.head)
    UI.text(self, d.priceLabel, 150, 0, p.dim)
    -- (Small, not the number font: a number font need not have the multiplication sign.)
    UI.text(self, d.price, d.priceX, 0, p.text)
    UI.textRight(self, d.refresh, w, 0, p.dim)
    local hy = m.headY
    UI.text(self, getText("IGUI_OA_Terminal_Del_Col_Item"), m.NX, hy, p.dim)
    UI.text(self, getText("IGUI_OA_Terminal_Del_Col_Band"), m.RX - 6, hy, p.dim)
    UI.textRight(self, getText("IGUI_OA_Terminal_Del_Col_Price"), m.PX + 70, hy, p.dim)
    UI.text(self, getText("IGUI_OA_Terminal_Del_Col_Week"), m.BX, hy, p.dim)
    UI.text(self, getText("IGUI_OA_Terminal_Del_Col_Full"), m.GX, hy, p.dim)
    UI.fill(self, 0, hy + 17, w, 1, p.border, 0.6)
    if #d.rows == 0 then UI.text(self, getText("IGUI_OA_Terminal_Del_Empty"), 0, m.listY + 4, p.dim) end
    for i, line in ipairs(d.noteLines) do UI.text(self, line, 0, m.noteY + (i - 1) * fh, p.dim) end
    if d.expectFit then UI.text(self, d.expectFit, 0, m.expectY, p.text) end
    -- The situation.
    local sy = m.sitY
    panelBox(self, p, 0, sy, w, m.sitH, d.sitHead)
    for i, line in ipairs(d.sit) do
        local ly = sy + 24 + (i - 1) * fh
        local c = kindColor(p, line.kind)
        if line.kind ~= "dim" then UI.fill(self, 12, ly + 6, 3, 3, c) end
        UI.text(self, line.fit, line.kind == "dim" and 12 or 22, ly, c)
        if line.left then
            if line.mult then
                UI.text(self, line.mult, line.xMult, ly, c)
                UI.text(self, line.sep, line.xSep, ly, p.dim)
            end
            UI.text(self, line.left, line.xLeft, ly, p.dim)
        end
    end
    -- The category index chips, no graph.
    for k, chip in ipairs(d.chips) do
        local r = d.chipRects[k]
        local c = kindColor(p, chip.kind)
        local x, y = r.x, sy + r.y
        if chip.kind ~= "mid" then
            UI.fill(self, x, y, m.chipW, 18, c, 0.08)
            UI.frame(self, x, y, m.chipW, 18, c, 0.7)
        else
            UI.frame(self, x, y, m.chipW, 18, p.border, 0.7)
        end
        UI.text(self, chip.name, x + 4, y + 1, chip.kind == "mid" and p.text or c)
        if chip.kind == "off" then
            UI.textRight(self, d.chipOff, x + m.chipW - 5, y + 1, c)
        else
            local right = x + m.chipW - 5 - (chip.trend and 9 or 0)
            UI.textRight(self, chip.value, right, y + 1, c, nf)
            if chip.trend then drawTriangle(self, x + m.chipW - 11, y + (chip.trend == "up" and 6 or 7), chip.trend == "up", c) end
        end
    end
end

-- The kinds a row's group takes, beside the row under the mouse (drawn as the chips' tip is).
function OATabDelivery:drawRowTip()
    local list = self.list
    if #list.items == 0 or not list:isMouseOver() then return false end
    local item = list.items[list.mouseoverselected or -1]
    local tip = item and item.item and item.item.tip
    if not tip then return false end
    local p = self:palette()
    local fh = UI.fontHeight()
    local tw = 0
    for _, line in ipairs(tip) do tw = math.max(tw, UI.textWidth(line)) end
    tw = tw + 12
    local th = #tip * fh + 6
    local x = math.min(list:getX() + list:getMouseX() + 16, self:getWidth() - tw)
    local y = list:getY() + list:getMouseY() + 16
    if y + th > self:getHeight() then y = math.max(0, list:getY() + list:getMouseY() - th - 4) end
    UI.fill(self, x, y, tw, th, p.bg, 0.97)
    UI.frame(self, x, y, tw, th, p.border)
    for i, line in ipairs(tip) do UI.text(self, line, x + 6, y + 3 + (i - 1) * fh, i == 1 and p.dim or p.bright) end
    return true
end

-- A row under the mouse lists what its group takes; a chip under the mouse tells its category's long name and today's
-- index.
function OATabDelivery:render()
    local d, m = self.data, self.metrics
    if not (d and m) then return end
    if self:drawRowTip() then return end
    if not self:isMouseOver() then return end
    local mx, my = self:getMouseX(), self:getMouseY()
    for k, chip in ipairs(d.chips) do
        local r = d.chipRects[k]
        local y = m.sitY + r.y
        if mx >= r.x and mx < r.x + m.chipW and my >= y and my < y + 18 then
            local p = self:palette()
            local tw = UI.textWidth(chip.tip) + 12
            local x = math.min(r.x, self:getWidth() - tw)
            local ty = y - UI.fontHeight() - 8
            UI.fill(self, x, ty, tw, UI.fontHeight() + 6, p.bg, 0.97)
            UI.frame(self, x, ty, tw, UI.fontHeight() + 6, p.border)
            UI.text(self, chip.tip, x + 6, ty + 3, p.bright)
            return
        end
    end
end

-- Now and then: the day has moved on (the list's days left, the market's step), or an event began or ended.
function OATabDelivery:update()
    self.frames = (self.frames or 0) + 1
    if self.frames < OATabDelivery.WATCH then return end
    self.frames = 0
    local d = self.data
    if d and (d.day ~= OA.day() or d.news ~= OA.Market.news()) then self:refresh() end
end

-- The tab's dot: this week's list or a market event not seen yet (DESIGN-terminal 1.1, 11).
OA.Terminal.addTab("delivery", function(x, y, w, h, window)
    return OATabDelivery:new(x, y, w, h, window)
end, {
    mark = function(record)
        if (OA.Terminal.seenValue(record, "week") or -1) < OA.week() then return "new" end
        if (OA.Terminal.seenValue(record, "market") or 0) ~= OA.Market.news() then return "new" end
        return nil
    end,
    seen = function(record) return { week = OA.week(), market = OA.Market.news() } end,
})
