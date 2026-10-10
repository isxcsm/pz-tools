-- The terminal's shop tab (DESIGN-terminal 4): the serum box and the sections on the left, the cards of what is
-- chosen with a detail under them, and the cart on the right. Prices, limits and what is open are the economy part's
-- (OA.Shop); the cart is kept in the record by the server, so a closed window loses nothing. What the tab decides
-- (the shelf, the locks, the sizes, the totals) is Trade/ShopView.lua's; this works it out when the record changes and
-- only draws the answers in prerender.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Trade/ShopView"
require "OperationAcorn/Gear/Gear"
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
    local h = self.height
    local th = math.max(20, math.floor(h * h / self.full))
    local max = self:maxScroll()
    return max > 0 and math.floor((h - th) * self.scroll / max) or 0, th
end

function OAShopScroll:prerender()
    local p = self.tab:palette()
    if self:isMouseOver() then
        self.mx, self.my = self:getMouseX(), self:getMouseY()
    else
        self.mx, self.my = nil, nil
    end
    self:setStencilRect(0, 0, self.width, self.height)
    for _, row in ipairs(self.rows) do
        local y = row.y - self.scroll
        if y + row.h > 0 and y < self.height then self.drawRow(self, row, y, p) end
    end
    self:clearStencilRect()
    if self.full > self.height then
        local bar = OAShopScroll.BAR
        local ty, th = self:thumb()
        UI.fill(self, self.width - bar, 0, bar, self.height, p.border, 0.25)
        UI.fill(self, self.width - bar, ty, bar, th, p.border, 0.95)
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
        local ty, th = self:thumb()
        if y < ty or y >= ty + th then
            -- a click on the track: the thumb goes there
            self:setScroll((y - th / 2) * self:maxScroll() / math.max(1, self.height - th))
        end
        self.dragging = true
        return true
    end
    local row = self:rowAt(y + self.scroll)
    if row and self.onClick then self.onClick(self.tab, row, x, y + self.scroll - row.y) end
    return true
end

function OAShopScroll:drag(dy)
    if not self.dragging then return end
    local _, th = self:thumb()
    self:setScroll(self.scroll + dy * self:maxScroll() / math.max(1, self.height - th))
end

function OAShopScroll:onMouseMove(dx, dy) self:drag(dy) end
function OAShopScroll:onMouseMoveOutside(dx, dy) self:drag(dy) end
function OAShopScroll:onMouseUp() self.dragging = false end
function OAShopScroll:onMouseUpOutside() self.dragging = false end

-- A button in the terminal's palette. An "off" button looks dimmed, does nothing when clicked and says why in its
-- tooltip (the game's own disabled look is a flat grey that belongs to no palette).
OAShopButton = ISButton:derive("OAShopButton")

function OAShopButton:new(title, target, onclick)
    local o = ISButton:new(0, 0, 20, 20, title, target, onclick)
    setmetatable(o, self)
    self.__index = self
    return o
end

function OAShopButton:onMouseDown(x, y)
    if not self.off then ISButton.onMouseDown(self, x, y) end
end

function OAShopButton:onMouseUp(x, y)
    if not self.off then return ISButton.onMouseUp(self, x, y) end
    self.pressed = false
    if self.onOff then self.onOff(self.target) end
end

-- The colours of a button for a state: "normal", "strong" or "off" (DESIGN-terminal 1.3's palette).
function OAShopButton:style(p, state)
    local function color(c, a) return { r = c[1], g = c[2], b = c[3], a = a } end
    self.off = state == "off"
    if state == "off" then
        local c = p.panel or p.bg
        self.backgroundColor = color(c, p.panel and 0.6 or 0)
        self.backgroundColorMouseOver = color(c, p.panel and 0.6 or 0)
        self.borderColor = color(p.border, 0.5)
        self.textColor = color(p.dim, 0.6)
    elseif state == "strong" then
        self.backgroundColor = color(p.sel, 0.22)
        self.backgroundColorMouseOver = color(p.sel, 0.34)
        self.borderColor = color(p.sel, 0.9)
        self.textColor = color(p.bright, 1)
    else
        self.backgroundColor = p.panel and color(p.panel, 1) or color(p.sel, 0.06)
        self.backgroundColorMouseOver = color(p.sel, 0.14)
        self.borderColor = color(p.border, 1)
        self.textColor = color(p.text, 1)
    end
end

OATabShop = OATab:derive("OATabShop")

-- The kinds of kit that are for a bag; the others are for a vehicle.
local BAG_KITS = { bagCapacity = true, bagWeight = true }
-- How far (squares) a vehicle may be to be chosen for a kit (NUMBERS 7: 30 around the terminal; the character is at it).
local VEHICLE_REACH = 30

-- The block heads and notes of the serum shelf (DESIGN-terminal 4.1).
local SHELF_HEAD = { treat = "IGUI_OA_Terminal_Shop_Treat", enhance = "IGUI_OA_Econ_Shop_Group_serum" }
local SHELF_NOTE = { treat = "IGUI_OA_Terminal_Shop_TreatNote", enhance = "IGUI_OA_Terminal_Shop_EnhanceNote" }

-- The icon of an entry: the first thing it gives, from its item script (found once).
local icons = {}
local function iconOf(entry)
    local known = icons[entry.id]
    if known ~= nil then return known or nil end
    local good = entry.give and entry.give[1]
    if not good and entry.choices then
        local choices = OA.Shop.choices(entry)
        good = choices and choices[1]
    end
    if not good then return nil end
    local script = getScriptManager():FindItem(good.type)
    local texture = script and script:getNormalTexture() or false
    icons[entry.id] = texture
    return texture or nil
end

local function drawIcon(el, entry, x, y, size, p, alpha)
    local texture = entry and iconOf(entry)
    if not texture then return end
    local t = p.iconTint or { 1, 1, 1 }
    el:drawTextureScaledAspect(texture, x, y, size, size, alpha or 1, t[1], t[2], t[3])
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

-- A kit is ordered for one bag or one vehicle: the target is the id of that bag (its item id) or of that vehicle
-- (OA_TargetId in its parts' modData, given when first chosen), and the price counts the kits of that one. The ids
-- and the names are the gear part's (OA.Gear.bagTargets, vehicleTargets).
function OATabShop:targets(entry)
    if BAG_KITS[entry.kit] then return OA.Gear.bagTargets(self:character()) end
    return OA.Gear.vehicleTargets(self:character(), entry.kit, VEHICLE_REACH)
end

function OATabShop:createChildren()
    self.cat, self.qty, self.onlyOpen = "serums", 1, false
    local p = self:palette()
    self.cards = OAShopScroll:new(self, OATabShop.drawCardRow, OATabShop.onCardRow)
    self.cartList = OAShopScroll:new(self, OATabShop.drawCartRow, OATabShop.onCartRow)
    for _, list in ipairs({ self.cards, self.cartList }) do
        list:initialise()
        list:instantiate()
        self:addChild(list)
    end
    self.minusButton = self:makeButton("-", OATabShop.onMinus)
    self.plusButton = self:makeButton("+", OATabShop.onPlus)
    self.addButton = self:makeButton(getText("IGUI_OA_Terminal_Shop_Add"), OATabShop.onAdd)
    self.addButton.onOff = function() self:refuse() end
    self.clearButton = self:makeButton(getText("IGUI_OA_Trade_Shop_Clear"), OATabShop.onClear)
    local combo = ISComboBox:new(0, 0, 150, 20, self, OATabShop.onCombo)
    combo:initialise()
    combo:instantiate()
    combo.backgroundColor = { r = p.dark[1], g = p.dark[2], b = p.dark[3], a = 1 }
    combo.backgroundColorMouseOver = { r = p.sel[1], g = p.sel[2], b = p.sel[3], a = 0.3 }
    combo.borderColor = { r = p.border[1], g = p.border[2], b = p.border[3], a = 1 }
    combo.textColor = { r = p.text[1], g = p.text[2], b = p.text[3], a = 1 }
    self:addChild(combo)
    self.combo = combo
end

function OATabShop:makeButton(title, onclick)
    local button = OAShopButton:new(title, self, onclick)
    button:initialise()
    button:instantiate()
    button:style(self:palette(), "normal")
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
    if self.cat ~= "serums" and self.cat ~= "all" and not sections.byGroup[self.cat] then self.cat = "serums" end
    self.model = { cats = self:buildCats(sections, ctx), serumEntry = Shop.entry("cure_serum"),
        shelfSub = getText("IGUI_OA_Terminal_Shop_SerumSub", ShopView.shelfCount(shelf)) }
    self.model.shelfSubFit = UI.fit(self.model.shelfSub, ShopView.CAT_W - 14)
    self.model.checkFit = UI.fit(getText("IGUI_OA_Terminal_Shop_OnlyOpen"), ShopView.CAT_W - 20)
    self:buildCards(record, ctx, sections, shelf)
    self:buildDetail(record, ctx)
    self:buildCart(record)
    self:styleButtons()
    self:layout()
end

function OATabShop:buildCats(sections, ctx)
    local cats = { { id = "all", name = getText("IGUI_OA_Terminal_Shop_All") } }
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
    if entry.special == "serum" then avail.serumN = (OA.Shop.section(record).serums[entry.tree] or 0) + 1 end
    return avail
end

local function priceOf(entry, line, record)
    local Shop = OA.Shop
    if entry.special == "kit" then return Shop.kitPrice(entry.kit, line and line.target or "", record) end
    return Shop.price(entry, record)
end

local function statusText(state)
    return getText(state.key, unpack(state.args))
end

function OATabShop:makeCard(entry, record, ctx)
    local state = ShopView.state(entry, availOf(entry, record), ctx)
    return {
        id = entry.id, entry = entry, state = state, name = Orders.nameOf(entry),
        price = Text.credits(priceOf(entry, nil, record)), status = statusText(state),
    }
end

-- The cards of the chosen section (the serum shelf with its two heads, a section, or all of them) and the band over
-- them.
function OATabShop:buildCards(record, ctx, sections, shelf)
    local blocks, bandEntries = {}, {}
    if self.cat == "serums" then
        for _, b in ipairs(shelf) do
            blocks[#blocks + 1] = { head = getText(SHELF_HEAD[b.id]), note = getText(SHELF_NOTE[b.id]), entries = b.entries }
        end
    else
        bandEntries = self.cat == "all" and sections.all or sections.byGroup[self.cat]
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
        self.qty, self.pick = 1, nil
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
    local descKey = "IGUI_OA_Terminal_Shop_Desc_" .. entry.id
    d.desc = getText(descKey)
    if d.desc == descKey then d.desc = "" end
    local info = {}
    if not d.state.open then info[#info + 1] = statusText(d.state) end
    if entry.week then info[#info + 1] = getText("IGUI_OA_Terminal_Shop_PerWeek", entry.week) end
    d.info = table.concat(info, Text.DOT)
    d.maxQty = d.state.open and math.min(Orders.MAX_COUNT, d.state.n) or 1
    self.qty = math.max(1, math.min(self.qty or 1, d.maxQty))
    local options
    local choices = Orders.choicesOf(entry)
    if choices and #choices > 0 then
        d.comboLabel = "IGUI_OA_Terminal_Shop_PickKind"
        options = {}
        for _, g in ipairs(choices) do options[#options + 1] = { text = Text.nameOf(g.type), data = g.type } end
    elseif entry.special == "kit" then
        d.comboLabel = "IGUI_OA_Terminal_Shop_PickTarget"
        options = {}
        for _, t in ipairs(self:targets(entry)) do options[#options + 1] = { text = t.name, data = t.target } end
        if #options == 0 then options[1] = { text = getText("IGUI_OA_Trade_Shop_AnyTarget"), data = "" } end
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
    local line = entry.special == "kit" and { target = self.pick or "" } or nil
    d.price = Text.credits(priceOf(entry, line, record))
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
    for _, line in ipairs(Orders.cart(record)) do
        local entry = Orders.entry(line.id)
        if entry then
            local sum = OA.round(priceOf(entry, line, record)) * line.count
            total = total + sum
            rows[#rows + 1] = {
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

-- The name of a cart line: the entry's, with the choice and the target.
function OATabShop:lineName(entry, line)
    local name = Orders.nameOf(entry)
    if line.choice and entry.choices then name = name .. " - " .. Text.nameOf(line.choice) end
    if line.target and line.target ~= "" and entry.kit then
        name = name .. " (" .. OA.Gear.targetName(entry.kit, line.target, self:character()) .. ")"
    end
    return name
end

function OATabShop:styleButtons()
    local p = self:palette()
    local d = self.detail
    local open = d and d.state.open
    self.addButton:style(p, open and "strong" or "off")
    self.addButton.tooltip = (d and not open and d.state.reason) and getText(d.state.reason) or nil
    self.minusButton:style(p, open and "normal" or "off")
    self.plusButton:style(p, open and "normal" or "off")
    self.clearButton:style(p, #self.cartRows > 0 and "normal" or "off")
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
    local descLines = d and ShopView.wrap(d.desc, cols.cw - 78, UI.textWidth, 3) or {}
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
    self.minusButton:setVisible(d ~= nil and row.minus ~= nil)
    self.plusButton:setVisible(d ~= nil and row.plus ~= nil)
    if row.minus then
        self:place(self.minusButton, det.x + row.minus.x, by, row.minus.w, row.h)
        self:place(self.plusButton, det.x + row.plus.x, by, row.plus.w, row.h)
    end
    self.combo:setVisible(d ~= nil and row.combo ~= nil)
    if row.combo then self:place(self.combo, det.x + row.combo.x, by, row.combo.w, row.h) end
    self.detailRow = row
    if d then
        d.nameFit = UI.fit(d.name, det.w - 160, UIFont.Medium)
        d.infoFit = UI.fit(d.info, det.w - 78)
    end
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

function OATabShop:place(element, x, y, w, h)
    element:setX(x)
    element:setY(y)
    element:setWidth(w)
    element:setHeight(h)
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
        UI.textCentre(self, getText("IGUI_OA_Terminal_Shop_NoneOpen"), r.x + r.w / 2, r.y + 20, p.dim)
    end
end

-- The left column: the serum box, the sections and the "only what can be bought" box.
function OATabShop:drawLeft(p, m)
    local catw, sb = ShopView.CAT_W, ShopView.SERUM_H
    local on = self.cat == "serums"
    UI.fill(self, 0, 0, catw, sb, p.sel, on and 0.24 or 0.08)
    UI.frame(self, 0, 0, catw, sb, p.sel, on and 1 or 0.7)
    if on then UI.fill(self, 0, 0, 3, sb, p.sel) end
    UI.text(self, getText("IGUI_OA_Terminal_Shop_Serum"), 10, 3, on and p.bright or p.head, UIFont.Medium)
    drawIcon(self, m.serumEntry, catw - 30, 4, 24, p)
    UI.text(self, m.shelfSubFit, 10, 3 + UI.fontHeight(UIFont.Medium) + 1, on and p.text or p.dim)
    UI.text(self, getText("IGUI_OA_Terminal_Shop_Sections"), 10, sb + 8, p.dim)
    UI.fill(self, 40, sb + 16, catw - 44, 1, p.border, 0.6)
    local y = ShopView.CAT_TOP
    for _, cat in ipairs(m.cats) do
        local chosen = cat.id == self.cat
        if chosen then
            UI.fill(self, 0, y, catw, ShopView.CAT_ROW, p.sel, 0.22)
            UI.fill(self, 0, y, 2, ShopView.CAT_ROW, p.sel)
        end
        if cat.locked then UI.lock(self, 8, y + 6, p.warn, 0.8) end
        UI.text(self, cat.name, cat.locked and 22 or 10, y + 3, chosen and p.bright or (cat.locked and p.dim or p.text))
        y = y + ShopView.CAT_ROW
    end
    local cy = self.height - 18
    UI.frame(self, 0, cy + 2, 12, 12, p.border)
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
        UI.textCentre(self, getText("IGUI_OA_Terminal_Shop_DetailEmpty"), r.x + r.w / 2, r.y + 44, p.dim)
        return
    end
    local fh = UI.fontHeight()
    local open = d.state.open
    drawIcon(self, d.entry, r.x + 10, r.y + 10, 48, p, open and 1 or 0.4)
    UI.text(self, d.nameFit, r.x + 68, r.y + 3, p.bright, UIFont.Medium)
    local unit = " " .. getText("IGUI_OA_Terminal_Credits")
    UI.textRight(self, unit, r.x + r.w - 10, r.y + 7, p.dim)
    UI.textRight(self, d.price, r.x + r.w - 10 - UI.textWidth(unit), r.y + 7, p.value, p.numberFont)
    local y = r.y + 26
    for _, line in ipairs(self.descLines) do
        UI.text(self, line, r.x + 68, y, p.text)
        y = y + fh
    end
    if d.info ~= "" then
        UI.text(self, d.infoFit, r.x + 68, y, open and p.dim or p[TONE[d.state.tone]])
    end
    local row = self.detailRow
    if row.combo and row.combo.label then UI.text(self, getText(d.comboLabel), r.x + 10, r.y + row.y + 2, p.dim) end
    if row.count then
        UI.textCentre(self, tostring(self.qty), r.x + row.count.x + row.count.w / 2, r.y + row.y + 2, open and p.text or p.dim, p.numberFont)
    end
end

function OATabShop:drawCart(p)
    local r, cr, s = self.rect.cart, self.cartRect, self.sum
    local fh = UI.fontHeight()
    panel(self, p, r.x, r.y, r.w, r.h)
    UI.text(self, getText("IGUI_OA_Terminal_Shop_Cart"), r.x + 10, r.y + 6, p.head)
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
        if list.mx and list.mx >= x and list.mx < x + w and list.my >= y and list.my < y + h then
            UI.frame(list, x, y, w, h, p.text, 0.8)
        end
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

-- A row of the cart list: the line's name, its price and the three small buttons.
function OATabShop.drawCartRow(list, row, y, p)
    local fh = UI.fontHeight()
    if row.fitW ~= list.width then
        row.fitW = list.width
        row.nameFit = UI.fit(row.name, list.width - 16)
    end
    UI.text(list, row.nameFit, 8, y, p.text)
    UI.text(list, row.price, 8, y + fh + 1, p.value, p.numberFont)
    for k, glyph in ipairs({ "-", "+", "x" }) do
        local bx = list.width - 62 + 18 * (k - 1)
        UI.fill(list, bx, y + fh + 1, 15, 15, p.panel or p.bg)
        UI.frame(list, bx, y + fh + 1, 15, 15, p.border)
        UI.textCentre(list, glyph, bx + 8, y + fh, glyph == "x" and p.bad or p.text)
    end
    UI.fill(list, 8, y + 37, list.width - 16, 1, p.border, 0.35)
end

-- Clicks --------------------------------------------------------------------------------------------------------

function OATabShop:onMouseDown(x, y)
    if not self.model then return true end
    if x < ShopView.CAT_W then
        if y < ShopView.SERUM_H then
            self:setCat("serums")
        elseif y >= self.height - 20 then
            self.onlyOpen = not self.onlyOpen
            getSoundManager():playUISound("UISelectListItem")
            self.cards:setScroll(0)
            self:refresh()
        else
            local cat = self.model.cats[math.floor((y - ShopView.CAT_TOP) / ShopView.CAT_ROW) + 1]
            if cat and y >= ShopView.CAT_TOP then self:setCat(cat.id) end
        end
    end
    return true
end

function OATabShop:setCat(id)
    if id == self.cat then return end
    getSoundManager():playUISound("UISelectListItem")
    self.cat, self.sel = id, nil
    self.cards:setScroll(0)
    self:refresh()
end

function OATabShop.onCardRow(tab, row, x, y)
    if row.kind ~= "cards" or y >= ShopView.CARD_H then return end
    local w = ShopView.cardWidth(tab.cards.width)
    for _, card in ipairs(row.cards) do
        local cx = card.col * (w + 6)
        if x >= cx and x < cx + w then
            if card.id ~= tab.sel then
                getSoundManager():playUISound("UISelectListItem")
                tab.sel, tab.qty, tab.pick = card.id, 1, nil
                tab:refresh()
            end
            return
        end
    end
end

-- Opens the card of an entry: its section (the shelf for a shelf entry), the card chosen and scrolled to.
function OATabShop:showEntry(id)
    local entry = OA.Shop and OA.Shop.entry(id)
    if not entry then return end
    self.cat = ShopView.onShelf(entry) and "serums" or entry.group
    self.sel, self.qty, self.pick, self.onlyOpen = id, 1, nil, false
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

function OATabShop:onMinus() self.qty = math.max(1, self.qty - 1) end

function OATabShop:onPlus()
    local d = self.detail
    self.qty = math.min(d and d.maxQty or 1, self.qty + 1)
end

-- Ordering -------------------------------------------------------------------------------------------------------

-- The cart as plain lines to send.
function OATabShop:linesCopy()
    local lines = {}
    for _, line in ipairs(Orders.cart(self:record())) do
        lines[#lines + 1] = { id = line.id, count = line.count, target = line.target, choice = line.choice }
    end
    return lines
end

function OATabShop:sendLines(lines)
    self:send("tradeCart", { lines = lines })
end

function OATabShop:addLine(entry, choice, target, count)
    local lines = self:linesCopy()
    for _, line in ipairs(lines) do
        if line.id == entry.id and line.choice == choice and line.target == target then
            line.count = line.count + count
            return self:sendLines(lines)
        end
    end
    lines[#lines + 1] = { id = entry.id, count = count, choice = choice, target = target }
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
    local choice, target
    if d.options then
        if entry.special == "kit" then target = self.pick or "" else choice = self.pick end
    end
    local count = d.options and 1 or self.qty
    self.qty = 1
    self:addLine(entry, choice, target, count)
end

local function same(a, b)
    return a.id == b.id and a.choice == b.choice and a.target == b.target
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
function OATabShop.onCartRow(tab, row, x, y)
    local fh = UI.fontHeight()
    if y < fh + 1 or y >= fh + 16 then return end
    local k = math.floor((x - (tab.cartList.width - 62)) / 18)
    if k < 0 or k > 2 or (x - (tab.cartList.width - 62)) % 18 >= 15 then return end
    if k == 0 then tab:change(row.line, -1) elseif k == 1 then tab:change(row.line, 1) else tab:remove(row.line) end
end

function OATabShop:onClear()
    if #self.cartRows > 0 then self:sendLines({}) end
end

-- The tab's dot: items a new trust level has opened, until the tab is looked at (DESIGN-terminal 1.1).
OA.Terminal.addTab("shop", function(x, y, w, h, window)
    return OATabShop:new(x, y, w, h, window)
end, {
    mark = function(record)
        return OA.Trust.tier(record) > (OA.Terminal.seenValue(record, "tier") or 0) and "new" or nil
    end,
    seen = function(record) return "tier", OA.Trust.tier(record) end,
})
