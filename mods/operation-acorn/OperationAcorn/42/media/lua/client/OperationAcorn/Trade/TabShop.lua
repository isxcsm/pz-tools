-- The terminal's shop tab (DESIGN-terminal 4): the serum box and the sections on the left, the cards of what is
-- chosen with a detail under them, and the cart on the right. Prices, limits and what is open are the economy part's
-- (OA.Shop); the cart is kept in the record by the server, so a closed window loses nothing. What the tab decides
-- (the shelf, the locks, the sizes, the totals) is Trade/ShopView.lua's; this works it out when the record changes and
-- only draws the answers in prerender.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Trade/ShopView"
require "PZUIKit/Button"
require "PZUIKit/Combo"
require "OperationAcorn/Gear/Gear"
require "OperationAcorn/Trade/StatusDraw"
local OA = OperationAcorn
local Trade, UI, Orders, Text = OA.Trade, OA.Trade.UI, OA.Trade.Orders, OA.Trade.Text
local ShopView = OA.Trade.ShopView

-- A scrolling list of rows of different heights, drawn by the tab: `drawRow(list, row, y, palette)` for each row on
-- show (y from the list's top), `onClick(tab, row, x, yInRow)` for a click on a row. A thin bar of the palette stands
-- at the right when there is more than fits (DESIGN-terminal 1.2: lists shrink and scroll in the smallest window).
OAShopScroll = ISPanel:derive("OAShopScroll")

OAShopScroll.STEP = 36
OAShopScroll.BAR = 6

function OAShopScroll:new(tab, drawRow, onClick)
    local o = ISPanel:new(0, 0, 10, 10)
    setmetatable(o, self)
    self.__index = self
    o.background = false
    o.tab = tab
    o.drawRow, o.onClick = drawRow, onClick
    o.rows, o.full, o.scroll = {}, 0, 0
    return o
end

function OAShopScroll:setRows(rows)
    local y = 0
    for _, row in ipairs(rows) do
        row.y = y
        y = y + row.h
    end
    self.rows, self.full = rows, y
    self:setScroll(self.scroll)
end

function OAShopScroll:maxScroll()
    return math.max(0, self.full - self.height)
end

function OAShopScroll:setScroll(v)
    self.scroll = math.max(0, math.min(self:maxScroll(), v))
end

function OAShopScroll:onMouseWheel(del)
    if self:maxScroll() <= 0 then return false end
    self:setScroll(self.scroll + del * OAShopScroll.STEP)
    return true
end

-- The thumb of the bar: its top and its height.
function OAShopScroll:thumb()
    return UI.thumb(self.height, self.full, self.scroll, self:maxScroll())
end

function OAShopScroll:prerender()
    local p = self.tab:palette()
    -- the place under the mouse (a card's id, a cart button) lights up: Trade/UI places
    local over
    if self:isMouseOver() and self.placeAt and not self.dragging then
        local x, y = self:getMouseX(), self:getMouseY() + self.scroll
        local row = self:rowAt(y)
        if row then over = self.placeAt(self.tab, row, x, y - row.y) end
    end
    UI.placeLight(self, over)
    self:setStencilRect(0, 0, self.width, self.height)
    for _, row in ipairs(self.rows) do
        local y = row.y - self.scroll
        if y + row.h > 0 and y < self.height then self.drawRow(self, row, y, p) end
    end
    UI.unclip(self, 0, 0, self.width, self.height)
    if self.full > self.height then
        local bar = OAShopScroll.BAR
        local ty, th = self:thumb()
        UI.drawBar(self, self.width - bar, bar, self.height, ty, th, p.border)
    end
end

function OAShopScroll:rowAt(y)
    for _, row in ipairs(self.rows) do
        if y >= row.y and y < row.y + row.h then return row end
    end
    return nil
end

function OAShopScroll:onMouseDown(x, y)
    if self:maxScroll() > 0 and x >= self.width - OAShopScroll.BAR - 2 then
        UI.barPress(self, y)   -- (a click on the track: the thumb goes there)
        return true
    end
    local row = self:rowAt(y + self.scroll)
    if row then
        local place = self.placeAt and self.placeAt(self.tab, row, x, y + self.scroll - row.y)
        if place ~= nil then UI.placeFlash(self, place) end
        if self.onClick then self.onClick(self.tab, row, x, y + self.scroll - row.y) end
    end
    return true
end

function OAShopScroll:drag(dy)
    UI.barDrag(self, dy)
end

function OAShopScroll:onMouseMove(dx, dy) self:drag(dy) end
function OAShopScroll:onMouseMoveOutside(dx, dy) self:drag(dy) end
function OAShopScroll:onMouseUp() self.dragging = false end
function OAShopScroll:onMouseUpOutside() self.dragging = false end

UI.scaled(OAShopScroll, ISPanel)

OATabShop = OATab:derive("OATabShop")

-- The block heads and notes of the serum shelf (DESIGN-terminal 4.1).
local SHELF_HEAD = { treat = "IGUI_OA_Terminal_Shop_Treat", enhance = "IGUI_OA_Econ_Shop_Group_serum" }
local SHELF_NOTE = { treat = "IGUI_OA_Terminal_Shop_TreatNote", enhance = "IGUI_OA_Terminal_Shop_EnhanceNote" }

-- The icon of an entry: the first thing it gives (its type, found once), drawn from the texture for its size on the
-- screen (Trade/StatusDraw: our items' high-res copies when larger than their 32 px icon).
local types = {}
local function typeOf(entry)
    local known = types[entry.id]
    if known ~= nil then return known or nil end
    local good = entry.give and entry.give[1]
    if not good and entry.choices then
        local choices = OA.Shop.choices(entry)
        good = choices and choices[1]
    end
    local shown = good and (good.icon or good.type)
    types[entry.id] = shown or false
    return shown
end

local function drawIcon(el, entry, x, y, size, p, alpha)
    local fullType = entry and typeOf(entry)
    if not fullType then return end
    UI.icon(el, OA.Trade.Draw.itemTexture(fullType, UI.px(size)), x, y, size, alpha, p.iconTint)
end

-- A panel of the palette: its fill and a one pixel border.
local function panel(el, p, x, y, w, h)
    if p.panel then UI.fill(el, x, y, w, h, p.panel) else UI.fill(el, x, y, w, h, p.text, 0.03) end
    UI.frame(el, x, y, w, h, p.border)
end

-- A right arrow made of rectangles (the fonts have none), 13 wide.
local function arrow(el, x, y, c)
    UI.fill(el, x + 2, y + 4, 10, 1, c)
    UI.fill(el, x + 9, y + 2, 1, 5, c)
    UI.fill(el, x + 10, y + 3, 1, 3, c)
end

local TONE = { dim = "dim", warn = "warn", bad = "bad", timer = "warn" }

-- A time (world age in hours) as "day 12, 14:30".
local function whenText(hours)
    local day, h, m = Trade.clockText(hours)
    return getText("IGUI_OA_Trade_When", day, string.format("%02d:%02d", h, m))
end

function OATabShop:createChildren()
    self.cat, self.onlyOpen = "serums", false
    local p = self:palette()
    self.cards = OAShopScroll:new(self, OATabShop.drawCardRow, OATabShop.onCardRow)
    self.cartList = OAShopScroll:new(self, OATabShop.drawCartRow, OATabShop.onCartRow)
    self.cards.placeAt = OATabShop.cardPlace
    self.cartList.placeAt = OATabShop.cartPlace
    for _, list in ipairs({ self.cards, self.cartList }) do
        list:initialise()
        list:instantiate()
        self:addChild(list)
    end
    self.addButton = self:makeButton(getText("IGUI_OA_Terminal_Shop_Add"), OATabShop.onAdd)
    self.addButton.onOff = function() self:refuse() end
    self.clearButton = self:makeButton(getText("IGUI_OA_Trade_Shop_Clear"), OATabShop.onClear)
    local combo = PZUICombo:new(0, 0, 150, 20, p, self, OATabShop.onCombo)
    combo:initialise()
    combo:instantiate()
    self:addChild(combo)
    self.combo = combo
end

-- A button of the tab (Trade/Button): "off" looks dimmed, does nothing when clicked and says why in its tooltip.
function OATabShop:makeButton(title, onclick)
    local button = PZUIButton:new(0, 0, 20, 20, title, self:palette(), self, onclick)
    button:initialise()
    button:instantiate()
    self:addChild(button)
    return button
end

-- The record changed or the tab was opened: everything the tab shows is worked out again.
function OATabShop:refresh()
    local record = self:record()
    if not record or not OA.Shop then return end
    local Shop = OA.Shop
    local ctx = {
        crude = self.window.tier ~= "field", tier = OA.Trust.tier(record), debt = Trade.inDebt(record),
        whenText = whenText,
    }
    self.ctx = ctx
    local catalog = Shop.catalog()
    local sections = ShopView.sections(catalog)
    local shelf = ShopView.shelf(catalog)
    if self.cat ~= "serums" and not sections.byGroup[self.cat] then self.cat = "serums" end
    self.model = { cats = self:buildCats(sections, ctx), serumEntry = Shop.entry("cure_serum"),
        shelfSub = getText("IGUI_OA_Terminal_Shop_SerumSub") }
    self.model.shelfSubFit = UI.fit(self.model.shelfSub, ShopView.CAT_W - 14)
    self.model.checkFit = UI.fit(getText("IGUI_OA_Terminal_Shop_OnlyOpen"), ShopView.CAT_W - 20)
    self:buildCards(record, ctx, sections, shelf)
    self:buildDetail(record, ctx)
    self:buildCart(record)
    self:styleButtons()
    self:layout()
end

function OATabShop:buildCats(sections, ctx)
    local cats = {}
    for _, group in ipairs(sections.groups) do
        cats[#cats + 1] = {
            id = group, name = getText(OA.Shop.groupKey(group)),
            locked = ShopView.sectionLocked(sections.byGroup[group], ctx.crude),
        }
    end
    return cats
end

local function availOf(entry, record)
    local n, why, reopen = OA.Shop.available(entry, record)
    local avail = { n = n or 0, why = why, reopen = reopen }
    if entry.special == "serum" then avail.serumN = OA.Shop.serumsBought(record, entry.tree) + 1 end
    return avail
end

local function statusText(state)
    return getText(state.key, unpack(state.args))
end

function OATabShop:makeCard(entry, record, ctx)
    local state = ShopView.state(entry, availOf(entry, record), ctx)
    return {
        id = entry.id, entry = entry, state = state, name = Orders.nameOf(entry),
        price = Text.credits(OA.Shop.price(entry, record)), status = statusText(state),
    }
end

-- The cards of the chosen section (the serum shelf with its two heads, or a section) and the band over them.
function OATabShop:buildCards(record, ctx, sections, shelf)
    local blocks, bandEntries = {}, {}
    if self.cat == "serums" then
        for _, b in ipairs(shelf) do
            blocks[#blocks + 1] = { head = getText(SHELF_HEAD[b.id]), note = getText(SHELF_NOTE[b.id]), entries = b.entries }
        end
    else
        bandEntries = sections.byGroup[self.cat]
        blocks[1] = { entries = bandEntries }
    end
    self.byId, self.order = {}, {}
    for _, block in ipairs(blocks) do
        block.cards = {}
        for _, entry in ipairs(block.entries) do
            local card = self:makeCard(entry, record, ctx)
            if card.state.open or not self.onlyOpen then
                block.cards[#block.cards + 1] = card
                self.byId[card.id] = card
                self.order[#self.order + 1] = card
            end
        end
    end
    local rows = ShopView.rows(blocks)
    for _, row in ipairs(rows) do
        if row.kind == "head" and row.note then row.noteX = UI.textWidth(row.head) + 14 end
    end
    self.cards:setRows(rows)
    local band = ShopView.band(self.cat, bandEntries, ctx)
    if band == "debt" then
        self.band = { text = getText("IGUI_OA_Econ_Shop_Debt"), tone = "bad" }
    elseif band == "gate" then
        self.band = { text = getText("IGUI_OA_Terminal_Shop_GateBand"), tone = "warn" }
    else
        self.band = nil
    end
    if not (self.sel and self.byId[self.sel]) then
        self.sel = self.order[1] and self.order[1].id or nil
        self.pick = nil
    end
end

-- The chosen card's detail, with the choices of its combo box.
function OATabShop:buildDetail(record, ctx)
    local entry = self.sel and OA.Shop.entry(self.sel)
    if not entry then
        self.detail = nil
        return
    end
    local d = { entry = entry, state = ShopView.state(entry, availOf(entry, record), ctx) }
    d.name = Orders.nameOf(entry)
    local descKey = OA.Shop.descKey(entry)
    d.desc = getText(descKey)
    if d.desc == descKey then d.desc = "" end
    local info = {}
    if not d.state.open then info[#info + 1] = statusText(d.state) end
    if entry.week then info[#info + 1] = getText("IGUI_OA_Terminal_Shop_PerWeek", entry.week) end
    d.info = table.concat(info, Text.DOT)
    local options
    local choices = Orders.choicesOf(entry)
    if choices and #choices > 0 then
        d.comboLabel = "IGUI_OA_Terminal_Shop_PickKind"
        options = {}
        for _, g in ipairs(choices) do options[#options + 1] = { text = Text.nameOf(g.type), data = g.type } end
    end
    d.options = options
    local picked = 1
    if options then
        for i, o in ipairs(options) do
            if o.data == self.pick then picked = i end
        end
        self.pick = options[picked].data
        d.picked = picked
    end
    d.price = Text.credits(OA.Shop.price(entry, record))
    self.detail = d
    self:fillCombo(d)
end

function OATabShop:fillCombo(d)
    local combo = self.combo
    combo:clear()
    if not d.options then return end
    for _, o in ipairs(d.options) do combo:addOptionWithData(o.text, o.data) end
    combo.selected = d.picked
end

-- The cart: its lines as rows, the totals, the empty cart's text.
function OATabShop:buildCart(record)
    local rows, total = {}, 0
    local svc = Orders.shopService(record)
    for _, line in ipairs(Orders.cart(record)) do
        local entry = Orders.entry(line.id)
        if entry then
            local sum = Orders.lineCost(svc, entry, line)
            total = total + sum
            local n = #rows
            rows[n + 1] = {
                -- its three buttons' places (Trade/UI places: numbers, the same when the cart is made again)
                keys = { n * 3 + 1, n * 3 + 2, n * 3 + 3 },
                line = line, h = ShopView.CART_ROW, price = Text.credits(sum),
                name = getText("IGUI_OA_Terminal_Shop_Line", self:lineName(entry, line), line.count),
            }
        end
    end
    self.cartRows = rows
    self.cartList:setRows(rows)
    local s = ShopView.cartSummary(total, Trade.account(record).credits)
    s.totalText, s.beforeText, s.afterText = Text.credits(s.total), Text.credits(s.balance), Text.credits(s.after)
    s.shortText = s.short > 0 and getText("IGUI_OA_Terminal_Shop_Short", Text.credits(s.short)) or nil
    self.sum = s
end

-- The name of a cart line: the entry's or the choice's.
function OATabShop:lineName(entry, line)
    local name = Orders.nameOf(entry)
    -- A line with a choice is named by what was chosen (the entry's name says only what it is chosen from).
    if line.choice and entry.choices then name = Text.nameOf(line.choice) end
    return name
end

function OATabShop:styleButtons()
    local d = self.detail
    local open = d and d.state.open
    self.addButton:setStyle(open and "strong" or "off")
    self.addButton.tooltip = (d and not open and d.state.reason) and getText(d.state.reason) or nil
    self.clearButton:setStyle(#self.cartRows > 0 and "normal" or "off")
end

-- Sizes ---------------------------------------------------------------------------------------------------------

-- The rectangles and the wrapped texts for the size the tab has now (worked out again when the size or what is shown
-- changes, not every frame).
function OATabShop:layout()
    if not self.model then return end
    local w, h = self.width, self.height
    local fh = UI.fontHeight()
    local cols = ShopView.columns(w)
    local d = self.detail
    local descLines = d and ShopView.wrap(d.desc, cols.cw - ShopView.DETAIL_TEXT - 10, UI.textWidth, 3) or {}
    local bandLines = self.band and ShopView.wrap(self.band.text, cols.cw - 16, UI.textWidth) or {}
    local hintLines = ShopView.wrap(getText("IGUI_OA_Terminal_Shop_PayNote"), cols.cartw - 16, UI.textWidth, 2)
    local shortLines = self.sum.shortText and ShopView.wrap(self.sum.shortText, cols.cartw - 16, UI.textWidth, 4) or {}
    local emptyLines = ShopView.wrap(getText("IGUI_OA_Terminal_Shop_CartEmpty"), cols.cartw - 16, UI.textWidth, 4)
    local rect = ShopView.layout(w, h, { lineH = fh, descLines = #descLines, bandLines = #bandLines })
    local cartRect = ShopView.cartRects(h, #hintLines, #shortLines, #self.cartRows > 0, fh)
    self.rect, self.cartRect = rect, cartRect
    self.descLines, self.bandLines, self.hintLines, self.shortLines, self.emptyLines =
        descLines, bandLines, hintLines, shortLines, emptyLines
    self.laidW, self.laidH = w, h
    self.catRows = { top = ShopView.CAT_TOP }

    -- the lists
    self:place(self.cards, rect.cards.x, rect.cards.y, rect.cards.w, rect.cards.h)
    self:place(self.cartList, rect.cart.x, cartRect.list.y, rect.cart.w, cartRect.list.h)
    -- the detail's controls
    local det = rect.detail
    local row = ShopView.detailRow(det.w, det.h, d ~= nil and d.options ~= nil)
    local by = det.y + row.y
    self.addButton:setVisible(d ~= nil)
    self:place(self.addButton, det.x + row.add.x, by, row.add.w, row.h)
    self.combo:setVisible(d ~= nil and row.combo ~= nil)
    if row.combo then self:place(self.combo, det.x + row.combo.x, by, row.combo.w, row.h) end
    self.detailRow = row
    if d then
        d.nameFit = UI.fit(d.name, det.w - 160, UIFont.Medium)
        d.infoFit = UI.fit(d.info, det.w - ShopView.DETAIL_TEXT - 10)
    end
    -- The description under the name: at 26, or lower when the Medium font is taller than the design's.
    self.descY = math.max(26, 3 + UI.fontHeight(UIFont.Medium))
    -- the cart's clear button
    self:place(self.clearButton, rect.cart.x + 8, cartRect.clearY, rect.cart.w - 16, 22)
    -- the totals' places along their lines
    local s = self.sum
    local p = self:palette()
    local nf = p.numberFont
    s.totalLabel, s.balanceLabel = getText("IGUI_OA_Terminal_Shop_Total") .. " ", getText("IGUI_OA_Terminal_Balance") .. " "
    s.totalX = rect.cart.x + 8 + UI.textWidth(s.totalLabel)
    s.beforeX = rect.cart.x + 8 + UI.textWidth(s.balanceLabel)
    s.arrowX = s.beforeX + UI.textWidth(s.beforeText, nf) + 4
    s.afterX = s.arrowX + 17
end

-- The lists, the buttons and the combo box are ours: UI.place takes their design units.
function OATabShop:place(element, x, y, w, h)
    UI.place(element, x, y, w, h)
end

-- Drawing -------------------------------------------------------------------------------------------------------

function OATabShop:prerender()
    local m = self.model
    if not m then return end
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    local p = self:palette()
    self:drawLeft(p, m)
    self:drawBand(p)
    self:drawDetail(p)
    self:drawCart(p)
    if #self.cards.rows == 0 then
        local r = self.rect.cards
        UI.textCentre(self, UI.str("IGUI_OA_Terminal_Shop_NoneOpen"), r.x + r.w / 2, r.y + 20, p.dim)
    end
end

-- The left column: the serum box, the sections and the "only what can be bought" box.
function OATabShop:drawLeft(p, m)
    local catw, sb = ShopView.CAT_W, ShopView.SERUM_H
    local over = self:isMouseOver() and self:leftAt(self:getMouseX(), self:getMouseY()) or nil
    UI.placeLight(self, over ~= self.cat and over or nil)
    local on = self.cat == "serums"
    local k, f = UI.placeLevels(self, "serums")
    UI.fill(self, 0, 0, catw, sb, p.sel, (on and 0.24 or 0.08) + 0.08 * k + 0.3 * f)
    UI.frame(self, 0, 0, catw, sb, p.sel, on and 1 or 0.7 + 0.3 * k)
    if on then UI.fill(self, 0, 0, 3, sb, p.sel) end
    UI.text(self, UI.str("IGUI_OA_Terminal_Shop_Serum"), 10, 3, on and p.bright or p.head, UIFont.Medium)
    drawIcon(self, m.serumEntry, catw - 30, 4, 24, p)
    UI.text(self, m.shelfSubFit, 10, 3 + UI.fontHeight(UIFont.Medium) + 1, on and p.text or p.dim)
    UI.text(self, UI.str("IGUI_OA_Terminal_Shop_Sections"), 10, sb + 8, p.dim)
    UI.fill(self, 40, sb + 16, catw - 44, 1, p.border, 0.6)
    local y = ShopView.CAT_TOP
    for _, cat in ipairs(m.cats) do
        local chosen = cat.id == self.cat
        if chosen then
            UI.fill(self, 0, y, catw, ShopView.CAT_ROW, p.sel, 0.22)
            UI.fill(self, 0, y, 2, ShopView.CAT_ROW, p.sel)
        end
        k, f = UI.placeLevels(self, cat.id)
        if k > 0 or f > 0 then
            UI.fill(self, 0, y, catw, ShopView.CAT_ROW, p.sel, 0.1 * k + 0.3 * f)
            UI.fill(self, 0, y, 2, ShopView.CAT_ROW, p.sel, 0.6 * k)
        end
        if cat.locked then UI.lock(self, 8, y + 6, p.warn, 0.8) end
        UI.text(self, cat.name, cat.locked and 22 or 10, y + 3, chosen and p.bright or (cat.locked and p.dim or p.text))
        y = y + ShopView.CAT_ROW
    end
    local cy = self.height - 18
    UI.frame(self, 0, cy + 2, 12, 12, p.border)
    k, f = UI.placeLevels(self, "only")
    if k > 0 then UI.frame(self, 0, cy + 2, 12, 12, p.sel, k) end
    if f > 0 then UI.fill(self, 0, cy + 2, 12, 12, p.sel, 0.4 * f) end
    if self.onlyOpen then UI.fill(self, 3, cy + 5, 6, 6, p.text) end
    UI.text(self, m.checkFit, 18, cy, p.text)
end

function OATabShop:drawBand(p)
    local band, r = self.band, self.rect.band
    if not (band and r) then return end
    local c = p[TONE[band.tone]]
    UI.fill(self, r.x, r.y, r.w, r.h, c, 0.16)
    UI.frame(self, r.x, r.y, r.w, r.h, c)
    local fh = UI.fontHeight()
    for i, line in ipairs(self.bandLines) do UI.text(self, line, r.x + 8, r.y + 4 + (i - 1) * fh, c) end
end

function OATabShop:drawDetail(p)
    local r, d = self.rect.detail, self.detail
    panel(self, p, r.x, r.y, r.w, r.h)
    if not d then
        UI.textCentre(self, UI.str("IGUI_OA_Terminal_Shop_DetailEmpty"), r.x + r.w / 2, r.y + 44, p.dim)
        return
    end
    local fh = UI.fontHeight()
    local open = d.state.open
    drawIcon(self, d.entry, r.x + 10, r.y + 8, ShopView.DETAIL_ICON, p, open and 1 or 0.4)
    UI.text(self, d.nameFit, r.x + ShopView.DETAIL_TEXT, r.y + 3, p.bright, UIFont.Medium)
    local unit = UI.creditsUnit()
    UI.textRight(self, unit, r.x + r.w - 10, r.y + 7, p.dim)
    UI.textRight(self, d.price, r.x + r.w - 10 - UI.textWidth(unit) - UI.UNIT_GAP, r.y + 7, p.value, p.numberFont)
    local y = r.y + self.descY
    for _, line in ipairs(self.descLines) do
        UI.text(self, line, r.x + ShopView.DETAIL_TEXT, y, p.text)
        y = y + fh
    end
    if d.info ~= "" then
        UI.text(self, d.infoFit, r.x + ShopView.DETAIL_TEXT, y, open and p.dim or p[TONE[d.state.tone]])
    end
    local row = self.detailRow
    if row.combo and row.combo.label then UI.text(self, UI.str(d.comboLabel), r.x + 10, r.y + row.y + 2, p.dim) end
end

function OATabShop:drawCart(p)
    local r, cr, s = self.rect.cart, self.cartRect, self.sum
    local fh = UI.fontHeight()
    panel(self, p, r.x, r.y, r.w, r.h)
    UI.text(self, UI.str("IGUI_OA_Terminal_Shop_Cart"), r.x + 10, r.y + 6, p.head)
    if #self.cartRows == 0 then
        for i, line in ipairs(self.emptyLines) do UI.text(self, line, r.x + 8, 28 + (i - 1) * fh, p.dim) end
    else
        local nf = p.numberFont
        UI.fill(self, r.x + 8, cr.ruleY, r.w - 16, 1, p.border)
        UI.text(self, s.totalLabel, r.x + 8, cr.totalY, p.dim)
        UI.text(self, s.totalText, s.totalX, cr.totalY, p.value, nf)
        UI.text(self, s.balanceLabel, r.x + 8, cr.balanceY, p.dim)
        UI.text(self, s.beforeText, s.beforeX, cr.balanceY, p.value, nf)
        arrow(self, s.arrowX, cr.balanceY + 3, p.dim)
        UI.text(self, s.afterText, s.afterX, cr.balanceY, s.after < 0 and p.bad or p.value, nf)
        for i, line in ipairs(self.shortLines) do UI.text(self, line, r.x + 8, cr.shortY + (i - 1) * fh, p.bad) end
    end
    for i, line in ipairs(self.hintLines) do UI.text(self, line, r.x + 8, cr.hintY + (i - 1) * fh, p.dim) end
end

-- A row of the card list: a block's head, or up to two cards.
function OATabShop.drawCardRow(list, row, y, p)
    local tab = list.tab
    if row.kind == "head" then
        UI.text(list, row.head, 0, y + 2, p.head)
        if row.note then
            if row.fitW ~= list.width then
                row.fitW = list.width
                row.noteFit = UI.fit(row.note, list.width - row.noteX - 16)
            end
            UI.text(list, row.noteFit, row.noteX, y + 2, p.dim)
        end
        return
    end
    local w = ShopView.cardWidth(list.width)
    for _, card in ipairs(row.cards) do tab:drawCard(list, card, card.col * (w + 6), y, w, p) end
end

function OATabShop:drawCard(list, card, x, y, w, p)
    local h = ShopView.CARD_H
    local fh = UI.fontHeight()
    local st = card.state
    local open = st.open
    local selected = card.id == self.sel
    if selected then
        UI.fill(list, x, y, w, h, p.sel, 0.16)
        UI.frame(list, x, y, w, h, p.sel)
    else
        if p.panel then UI.fill(list, x, y, w, h, p.panel, open and 1 or 0.5) else UI.fill(list, x, y, w, h, p.text, 0.03) end
        UI.frame(list, x, y, w, h, p.border, open and 1 or 0.5)
    end
    local k, f = UI.placeLevels(list, card.id)
    if k > 0 or f > 0 then
        UI.fill(list, x, y, w, h, p.sel, 0.06 * k + 0.25 * f)
        if not selected and k > 0 then UI.frame(list, x, y, w, h, p.text, 0.8 * k) end
    end
    if card.fitW ~= w then
        card.fitW = w
        card.nameFit = UI.fit(card.name, w - 50)
        card.statusFit = UI.fit(card.status, w - (st.lock and 22 or 10))
    end
    drawIcon(list, card.entry, x + 6, y + 5, 32, p, open and 1 or 0.35)
    UI.text(list, card.nameFit, x + 44, y + 3, open and p.text or p.dim)
    UI.textRight(list, card.price, x + w - 8, y + fh + 3, open and p.value or p.dim, p.numberFont, open and 1 or 0.7)
    local sx = x + 6
    local c = p[TONE[st.tone]]
    if st.lock then
        UI.lock(list, sx, y + h - fh + 1, c, 0.9)
        sx = sx + 12
    end
    UI.text(list, card.statusFit, sx, y + h - fh - 4, open and p.dim or c)
end

local CART_GLYPHS = { "-", "+", "x" }

-- A row of the cart list: the line's name, its price and the three small buttons.
function OATabShop.drawCartRow(list, row, y, p)
    local fh = UI.fontHeight()
    if row.fitW ~= list.width then
        row.fitW = list.width
        row.nameFit = UI.fit(row.name, list.width - 16)
    end
    UI.text(list, row.nameFit, 8, y, p.text)
    UI.text(list, row.price, 8, y + fh + 1, p.value, p.numberFont)
    for k, glyph in ipairs(CART_GLYPHS) do
        local bx = list.width - 62 + 18 * (k - 1)
        local c = glyph == "x" and p.bad or p.text
        UI.fill(list, bx, y + fh + 1, 15, 15, p.panel or p.bg)
        local lk, lf = UI.placeLevels(list, row.keys[k])
        if lk > 0 or lf > 0 then UI.fill(list, bx, y + fh + 1, 15, 15, c, 0.14 * lk + 0.35 * lf) end
        UI.frame(list, bx, y + fh + 1, 15, 15, p.border)
        if lk > 0 then UI.frame(list, bx, y + fh + 1, 15, 15, c, 0.8 * lk) end
        UI.textCentre(list, glyph, bx + 8, y + fh, c)
    end
    UI.fill(list, 8, y + 37, list.width - 16, 1, p.border, 0.35)
end

-- Clicks --------------------------------------------------------------------------------------------------------

-- What of the left column is at x, y: "serums" (the serum box), a section's id, "only" (the box at the bottom), or nil.
function OATabShop:leftAt(x, y)
    if not self.model or x < 0 or x >= ShopView.CAT_W then return nil end
    if y < ShopView.SERUM_H then return "serums" end
    if y >= self.height - 20 then return "only" end
    if y < ShopView.CAT_TOP then return nil end
    local cat = self.model.cats[math.floor((y - ShopView.CAT_TOP) / ShopView.CAT_ROW) + 1]
    return cat and cat.id or nil
end

function OATabShop:onMouseDown(x, y)
    local at = self:leftAt(x, y)
    if at == nil then return true end
    if at ~= self.cat then UI.placeFlash(self, at) end
    if at == "only" then
        self.onlyOpen = not self.onlyOpen
        getSoundManager():playUISound("UISelectListItem")
        self.cards:setScroll(0)
        self:refresh()
    else
        self:setCat(at)
    end
    return true
end

-- The cards and the detail come up after a change of what they show (OATerminalWindow:reveal): `whole` the list too.
function OATabShop:revealCards(whole)
    local r = self.rect
    if not r then return end
    if whole then
        self.window:reveal(self, r.cards.x, r.cards.y, r.cards.w, r.detail.y + r.detail.h - r.cards.y)
    else
        self.window:reveal(self, r.detail.x, r.detail.y, r.detail.w, r.detail.h)
    end
end

function OATabShop:setCat(id)
    if id == self.cat then return end
    getSoundManager():playUISound("UISelectListItem")
    self.cat, self.sel = id, nil
    self.cards:setScroll(0)
    self:refresh()
    self:revealCards(true)
end

-- The card at x, y of a row of the card list, or nil.
local function cardAt(tab, row, x, y)
    if row.kind ~= "cards" or y >= ShopView.CARD_H then return nil end
    local w = ShopView.cardWidth(tab.cards.width)
    for _, card in ipairs(row.cards) do
        local cx = card.col * (w + 6)
        if x >= cx and x < cx + w then return card end
    end
    return nil
end

-- The place a card lights (its entry's id), for Trade/UI places.
function OATabShop.cardPlace(tab, row, x, y)
    local card = cardAt(tab, row, x, y)
    return card and card.id or nil
end

function OATabShop.onCardRow(tab, row, x, y)
    local card = cardAt(tab, row, x, y)
    if card and card.id ~= tab.sel then
        getSoundManager():playUISound("UISelectListItem")
        tab.sel, tab.pick = card.id, nil
        tab:refresh()
        tab:revealCards(false)
    end
end

-- Opens the card of an entry: its section (the shelf for a shelf entry), the card chosen and scrolled to.
function OATabShop:showEntry(id)
    local entry = OA.Shop and OA.Shop.entry(id)
    if not entry then return end
    self.cat = ShopView.onShelf(entry) and "serums" or entry.group
    self.sel, self.pick, self.onlyOpen = id, nil, false
    self:refresh()
    for _, row in ipairs(self.cards.rows or {}) do
        for _, card in ipairs(row.cards or {}) do
            if card.id == id then self.cards:setScroll(row.y) return end
        end
    end
end

function OATabShop:onCombo(combo)
    self.pick = combo:getSelectedData()
    self:refresh()
end

-- Ordering -------------------------------------------------------------------------------------------------------

-- The cart as plain lines to send.
function OATabShop:linesCopy()
    local lines = {}
    for _, line in ipairs(Orders.cart(self:record())) do
        lines[#lines + 1] = { id = line.id, count = line.count, choice = line.choice }
    end
    return lines
end

function OATabShop:sendLines(lines)
    self:send("tradeCart", { lines = lines })
end

function OATabShop:addLine(entry, choice, count)
    local lines = self:linesCopy()
    for _, line in ipairs(lines) do
        if line.id == entry.id and line.choice == choice then
            line.count = line.count + count
            return self:sendLines(lines)
        end
    end
    lines[#lines + 1] = { id = entry.id, count = count, choice = choice }
    self:sendLines(lines)
end

function OATabShop:notice(key)
    OA.Sync.deliver("notice", OA.Client.id(self:character()), { key = key })
end

-- A click on the add button while it is off: the reason, as the helicopter's notices give it.
function OATabShop:refuse()
    local d = self.detail
    if d and d.state.reason then self:notice(d.state.reason) end
end

function OATabShop:onAdd()
    local d = self.detail
    if not (d and d.state.open) then return self:refuse() end
    local entry = d.entry
    self:addLine(entry, d.options and self.pick or nil, 1)
end

local function same(a, b)
    return a.id == b.id and a.choice == b.choice
end

function OATabShop:change(line, delta)
    local lines = self:linesCopy()
    for _, l in ipairs(lines) do
        if same(l, line) then l.count = l.count + delta end
    end
    self:sendLines(lines)
end

function OATabShop:remove(line)
    local lines = {}
    for _, l in ipairs(self:linesCopy()) do
        if not same(l, line) then lines[#lines + 1] = l end
    end
    self:sendLines(lines)
end

-- A click on a cart line: its minus, plus or remove box.
-- Which of a cart row's three buttons is at x, y (0, 1, 2), or nil.
local function cartButtonAt(tab, x, y)
    local fh = UI.fontHeight()
    if y < fh + 1 or y >= fh + 16 then return nil end
    local k = math.floor((x - (tab.cartList.width - 62)) / 18)
    if k < 0 or k > 2 or (x - (tab.cartList.width - 62)) - 18 * k >= 15 then return nil end
    return k
end

-- The place a cart button lights (the row's keys), for Trade/UI places.
function OATabShop.cartPlace(tab, row, x, y)
    local k = cartButtonAt(tab, x, y)
    return k and row.keys[k + 1] or nil
end

function OATabShop.onCartRow(tab, row, x, y)
    local k = cartButtonAt(tab, x, y)
    if k == 0 then tab:change(row.line, -1) elseif k == 1 then tab:change(row.line, 1) elseif k == 2 then tab:remove(row.line) end
end

function OATabShop:onClear()
    if #self.cartRows > 0 then self:sendLines({}) end
end

-- The tab's dot: items a new trust level has opened, until the tab is looked at (DESIGN-terminal 1.1); the start's are
-- not new.
OA.Terminal.addTab("shop", function(x, y, w, h, window)
    return OATabShop:new(x, y, w, h, window)
end, {
    mark = function(record)
        return OA.Trust.tier(record) > (OA.Terminal.seenValue(record, "tier") or 1) and "new" or nil
    end,
    seen = function(record) return "tier", OA.Trust.tier(record) end,
})
