-- The terminal's shop and orders tab: the catalog on the left, the order (the cart that rides the next helicopter)
-- on the right. Prices, limits and what is open are the economy part's (OA.Shop); the cart is kept in the record by
-- the server, so a closed window loses nothing.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Gear/Gear"
local OA = OperationAcorn
local Trade, UI, Orders, Text = OA.Trade, OA.Trade.UI, OA.Trade.Orders, OA.Trade.Text

OATabShop = OATab:derive("OATabShop")

-- The kinds of kit that are for a bag; the others are for a vehicle.
local BAG_KITS = { bagCapacity = true, bagWeight = true }
-- How far (squares) a vehicle may be to be chosen for a kit (NUMBERS 7: 30 around the terminal; the character is at it).
local VEHICLE_REACH = 30

-- A kit is ordered for one bag or one vehicle: the target is the id of that bag (its item id) or of that vehicle
-- (OA_TargetId in its parts' modData, given when first chosen), and the price counts the kits of that one. The ids
-- and the names are the gear part's (OA.Gear.bagTargets, vehicleTargets).
function OATabShop:targets(entry)
    if BAG_KITS[entry.kit] then return OA.Gear.bagTargets(self:character()) end
    return OA.Gear.vehicleTargets(self:character(), entry.kit, VEHICLE_REACH)
end

function OATabShop:createChildren()
    local pad = UI.PAD
    local fh = UI.fontHeight()
    local bh = UI.buttonHeight()
    local half = math.floor(self.width * 0.5)
    local top = pad + fh + 4
    local listHeight = self.height - top - bh - pad * 2 - 4
    UI.label(self, pad, pad, getText("IGUI_OA_Trade_Shop_Catalog"))
    UI.label(self, half + pad / 2, pad, getText("IGUI_OA_Trade_Shop_Order"))
    self.catalog = UI.list(self, pad, top, half - pad * 1.5, listHeight, OATabShop.drawCatalogRow)
    self.catalog.anchorBottom = true
    self.cart = UI.list(self, half + pad / 2, top, self.width - half - pad * 1.5, listHeight - fh * 2 - 8, OATabShop.drawCartRow)
    self.cart.anchorBottom = true
    self.cart.anchorRight = true
    local by = self.height - bh - pad
    self.addButton = UI.button(self, pad, by, 140, getText("IGUI_OA_Trade_Shop_Add"), self, OATabShop.onAdd)
    local x = half + pad / 2
    self.minusButton = UI.button(self, x, by, 30, "-", self, OATabShop.onMinus)
    self.plusButton = UI.button(self, x + 34, by, 30, "+", self, OATabShop.onPlus)
    self.removeButton = UI.button(self, x + 68, by, 90, getText("IGUI_OA_Trade_Shop_Remove"), self, OATabShop.onRemove)
    self.clearButton = UI.button(self, x + 162, by, 90, getText("IGUI_OA_Trade_Shop_Clear"), self, OATabShop.onClear)
    for _, b in ipairs({ self.addButton, self.minusButton, self.plusButton, self.removeButton, self.clearButton }) do
        b.anchorTop = false
        b.anchorBottom = true
    end
    self.summary = UI.label(self, x, by - fh * 2 - 4, " ")
    self.summary.anchorTop = false
    self.summary.anchorBottom = true
    self.hint = UI.label(self, x, by - fh - 2, getText("IGUI_OA_Trade_Shop_Hint"), { r = 0.65, g = 0.65, b = 0.65, a = 1 })
    self.hint.anchorTop = false
    self.hint.anchorBottom = true
end

-- Rows ------------------------------------------------------------------------------------------------------------

function OATabShop.drawCatalogRow(list, y, item)
    local row = item.item
    local pad = list.itemPadY
    if row.header then
        list:drawText(row.header, 8, y + pad, 0.7, 0.8, 1, 1, list.font)
        return
    end
    local c = row.open and 0.92 or 0.5
    local price = Text.credits(row.price)
    local priceX = list.width - 20 - UI.textWidth(price)
    list:drawText(UI.fit(row.name, priceX - 24, list.font), 16, y + pad, c, c, c, 1, list.font)
    list:drawText(price, priceX, y + pad, c, c, c, 1, list.font)
end

function OATabShop.drawCartRow(list, y, item)
    local row = item.item
    local pad = list.itemPadY
    local text = "x" .. row.count .. "  " .. Text.credits(row.total)
    local textX = list.width - 20 - UI.textWidth(text)
    list:drawText(UI.fit(row.name, textX - 16, list.font), 8, y + pad, 0.92, 0.92, 0.92, 1, list.font)
    list:drawText(text, textX, y + pad, 0.8, 0.9, 0.8, 1, list.font)
end

local function priceOf(entry, line, record)
    local Shop = OA.Shop
    if entry.special == "kit" then return Shop.kitPrice(entry.kit, line and line.target or "", record) end
    return Shop.price(entry, record)
end

-- The name of a cart line: the entry's, with the choice and the target.
local function lineName(entry, line, character)
    local name = Orders.nameOf(entry)
    if line.choice and entry.choices then name = name .. " - " .. Text.nameOf(line.choice) end
    if line.target and line.target ~= "" and entry.kit then
        name = name .. " (" .. OA.Gear.targetName(entry.kit, line.target, character) .. ")"
    end
    return name
end

function OATabShop:refreshCatalog(record)
    local Shop = OA.Shop
    local selected = self.catalog.selected
    self.catalog:clear()
    local group
    for _, entry in ipairs(Shop.catalog()) do
        local hidden = entry.special == "reissue" or (entry.kits and not OA.option("KitsForSale")) or not Shop.stocked(entry)
        if not hidden then
            if entry.group ~= group then
                group = entry.group
                self.catalog:addItem(group, { header = getText(Shop.groupKey(group)) })
            end
            local n, why = Shop.available(entry, record)
            self.catalog:addItem(entry.id, { entry = entry, name = Orders.nameOf(entry), price = priceOf(entry, nil, record),
                open = n > 0, why = why })
        end
    end
    if selected and selected <= self.catalog.count then self.catalog.selected = selected end
end

function OATabShop:refreshCart(record)
    local selected = self.cart.selected
    self.cart:clear()
    local total = 0
    for _, line in ipairs(Orders.cart(record)) do
        local entry = Orders.entry(line.id)
        if entry then
            local price = OA.round(priceOf(entry, line, record))
            self.cart:addItem(line.id, { line = line, name = lineName(entry, line, self:character()), count = line.count, total = price * line.count })
            total = total + price * line.count
        end
    end
    if selected and selected <= self.cart.count then self.cart.selected = selected end
    local balance = Trade.account(record).credits
    local left = balance - total
    self.summary:setName(getText("IGUI_OA_Trade_Shop_Summary", Text.credits(total), Text.credits(balance), Text.credits(left)))
    if left < 0 then
        self.summary:setColor(1, 0.55, 0.45)
    else
        self.summary:setColor(0.8, 0.9, 0.8)
    end
end

function OATabShop:refresh()
    local record = self:record()
    if not record or not OA.Shop then return end
    self:refreshCatalog(record)
    self:refreshCart(record)
end

-- Sending ---------------------------------------------------------------------------------------------------------

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

function OATabShop:addLine(entry, choice, target)
    local lines = self:linesCopy()
    for _, line in ipairs(lines) do
        if line.id == entry.id and line.choice == choice and line.target == target then
            line.count = line.count + 1
            return self:sendLines(lines)
        end
    end
    lines[#lines + 1] = { id = entry.id, count = 1, choice = choice, target = target }
    self:sendLines(lines)
end

function OATabShop:notice(key)
    OA.Sync.deliver("notice", OA.Client.id(self:character()), { key = key })
end

function OATabShop:onAdd()
    local row = self.catalog.items[self.catalog.selected]
    row = row and row.item
    if not row or row.header then return end
    if not row.open then return self:notice(row.why or "IGUI_OA_Trade_Reason_locked") end
    local entry = row.entry
    local choices = Orders.choicesOf(entry)
    if choices and #choices > 0 then
        local menu = UI.menu(self:character())
        for _, g in ipairs(choices) do
            menu:addOption(Text.nameOf(g.type), self, OATabShop.addLine, entry, g.type, nil)
        end
        return
    end
    if entry.special == "kit" then
        local targets = self:targets(entry)
        local menu = UI.menu(self:character())
        if #targets == 0 then
            menu:addOption(getText("IGUI_OA_Trade_Shop_AnyTarget"), self, OATabShop.addLine, entry, nil, "")
        end
        for _, t in ipairs(targets) do
            menu:addOption(t.name, self, OATabShop.addLine, entry, nil, t.target)
        end
        return
    end
    self:addLine(entry, nil, nil)
end

function OATabShop:selectedLine()
    local row = self.cart.items[self.cart.selected]
    return row and row.item and row.item.line
end

local function same(a, b)
    return a.id == b.id and a.choice == b.choice and a.target == b.target
end

function OATabShop:change(delta)
    local line = self:selectedLine()
    if not line then return end
    local lines = self:linesCopy()
    for _, l in ipairs(lines) do
        if same(l, line) then l.count = l.count + delta end
    end
    self:sendLines(lines)
end

function OATabShop:onPlus() self:change(1) end
function OATabShop:onMinus() self:change(-1) end

function OATabShop:onRemove()
    local line = self:selectedLine()
    if not line then return end
    local lines = {}
    for _, l in ipairs(self:linesCopy()) do
        if not same(l, line) then lines[#lines + 1] = l end
    end
    self:sendLines(lines)
end

function OATabShop:onClear()
    self:sendLines({})
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
