-- The shop tab itself (client Trade/TabShop) against stand-ins for the game's UI classes: refresh, layout, drawing and
-- the clicks run on a real record and the real catalog, with a canvas that records what is drawn and where. What
-- the game then looks like is for the game to say; this finds the errors and checks that the tab draws what the
-- record and the terminal call for, in the default window and in the smallest.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Terminal"
local OA = OperationAcorn

local CLASSES = { "ISPanel", "ISButton", "ISComboBox", "ISLabel", "ISScrollingListBox", "ISRichTextPanel" }
local function stub(name, extra)
    local class = { Type = name }
    class.derive = function(self, derived)
        local c = { Type = derived, super = self }
        c.derive = self.derive
        setmetatable(c, { __index = self })
        return c
    end
    for k, v in pairs(extra or {}) do class[k] = v end
    return class
end

-- A canvas panel: it records what it is asked to draw (text and rectangles) and keeps its children.
local function panelClass()
    local P = stub("ISPanel")
    function P.new(self, x, y, w, h)
        local o = { x = x, y = y, width = w, height = h, children = {}, visible = true, drawn = {} }
        setmetatable(o, { __index = self })
        return o
    end
    function P:initialise() if self.createChildren then self:createChildren() end end
    function P:instantiate() self.javaObject = true end
    function P:addChild(c) c.parent = self; table.insert(self.children, c) end
    function P:setX(v) self.x = v end
    function P:setY(v) self.y = v end
    function P:setWidth(v) self.width = v end
    function P:setHeight(v) self.height = v end
    function P:setVisible(v) self.visible = v end
    function P:isMouseOver() return self.mouseAt ~= nil end
    function P:getMouseX() return self.mouseAt and self.mouseAt[1] or 0 end
    function P:getMouseY() return self.mouseAt and self.mouseAt[2] or 0 end
    function P:setStencilRect() end
    function P:clearStencilRect() end
    function P:repaintStencilRect() end
    function P:drawRect(x, y, w, h, a, r, g, b) table.insert(self.drawn, { "rect", x, y, w, h, a }) end
    function P:drawRectBorder(x, y, w, h, a) table.insert(self.drawn, { "frame", x, y, w, h, a }) end
    function P:drawText(t, x, y, r, g, b, a, font) table.insert(self.drawn, { "text", t, x, y, font }) end
    function P:drawTextRight(t, x, y, r, g, b, a, font) table.insert(self.drawn, { "right", t, x, y, font }) end
    function P:drawTextCentre(t, x, y, r, g, b, a, font) table.insert(self.drawn, { "centre", t, x, y, font }) end
    function P:drawTextureScaledAspect(tex, x, y, w, h) table.insert(self.drawn, { "icon", tex, x, y, w }) end
    return P
end

local function buttonClass(P)
    local B = P:derive("ISButton")
    function B.new(self, x, y, w, h, title, target, onclick)
        local o = P.new(P, x, y, w, h)
        o.title, o.target, o.onclick, o.enable, o.onClickArgs = title, target, onclick, true, {}
        return setmetatable(o, { __index = self })
    end
    function B:onMouseDown() self.pressed = true end
    function B:onMouseUp()
        local process = self.pressed
        self.pressed = false
        if self.enable and process and self.onclick then self.onclick(self.target, self) end
    end
    return B
end

local function comboClass(P)
    local C = P:derive("ISComboBox")
    function C.new(self, x, y, w, h, target, onChange)
        local o = P.new(P, x, y, w, h)
        o.target, o.onChange, o.options, o.selected = target, onChange, {}, 0
        return setmetatable(o, { __index = C })
    end
    function C:clear() self.options = {} end
    function C:addOptionWithData(text, data)
        table.insert(self.options, { text = text, data = data })
        if self.selected == 0 then self.selected = 1 end
    end
    function C:getSelectedData() return self.options[self.selected].data end
    return C
end

-- Loads the tab with the stand-ins in place; the stand-ins go again after it.
local function loadTab()
    local P = panelClass()
    _G.ISPanel, _G.ISButton, _G.ISComboBox = P, buttonClass(P), comboClass(P)
    _G.ISLabel, _G.ISScrollingListBox, _G.ISRichTextPanel = stub("ISLabel"), stub("ISScrollingListBox"), stub("ISRichTextPanel")
    _G.UIFont = { Small = "S", Medium = "M", Code = "C" }
    _G.getTextManager = function()
        return {
            getFontHeight = function(_, font) return font == "M" and 23 or 16 end,
            MeasureStringX = function(_, font, text) return #text * 2 end,
        }
    end
    _G.getSoundManager = function() return { playUISound = function() end } end
    _G.getItemNameFromFullType = function(t) return "name:" .. t end
    _G.getScriptManager = function()
        return {
            FindItem = function(_, t) return { getNormalTexture = function() return "tex:" .. t end,
                getIcon = function() return "Item_" .. t end } end,
            getAllItems = function()
                local seeds = {}
                for _, n in ipairs({ "TomatoBagSeed", "CarrotBagSeed" }) do
                    seeds[#seeds + 1] = { getName = function() return n end, getModuleName = function() return "Base" end,
                        getDisplayCategory = function() return "Gardening" end }
                end
                return { size = function() return #seeds end, get = function(_, i) return seeds[i + 1] end }
            end,
        }
    end
    -- OATab as the window gives it: a panel that knows its window and the record
    _G.OATab = P:derive("OATab")
    function OATab.new(self, x, y, w, h, window)
        local o = P.new(P, x, y, w, h)
        o.window = window
        return setmetatable(o, { __index = self })
    end
    function OATab:character() return self.window.character end
    function OATab:record() return self.window.record end
    function OATab:palette() return self.window.palette end
    function OATab:refresh() end
    function OATab:send(command, args) table.insert(self.window.sent, { command = command, args = args }) end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Trade/UI"
        real "OperationAcorn/Trade/Estimate"
        return real "OperationAcorn/Trade/TabShop"
    end)
    require = real
    if not ok then error(err, 0) end
    return OATabShop
end

local function makeRecord(stage, credits)
    local r = OA.Store.ensure("s", "S")
    r.trade = { credits = credits or 48200, trust = 0, stage = stage or 2, milestones = 0, bonus = 0, sharedSerums = 0,
        levels = {} }
    OA.Trust.reset()
    return r
end

-- A tab on a window of the tier, sized like the default (700 x 408) or the smallest (580 x 348) body.
local function open(tier, w, h, stage, credits)
    local Tab = loadTab()
    local UI = OA.Trade.UI
    local record = makeRecord(stage, credits)
    OA.Client = OA.Client or {}
    OA.Client.id = function() return "s" end
    local notices = {}
    OA.Sync.deliver = function(kind, id, args) table.insert(notices, { kind = kind, args = args }) end
    local window = { palette = UI.palette(tier), tier = tier, record = record, sent = {}, character = {},
        reveal = function() end }
    local tab = Tab:new(0, 0, w or 700, h or 408, window)
    tab:initialise()
    tab:instantiate()
    tab:refresh()
    return tab, window, record, notices
end

local function texts(el)
    local out = {}
    for _, d in ipairs(el.drawn) do
        if d[1] == "text" or d[1] == "right" or d[1] == "centre" then out[#out + 1] = d[2] end
    end
    return out
end

local function has(list, text)
    for _, t in ipairs(list) do
        if t == text then return true end
    end
    return false
end

-- Draws the tab and its two lists; returns everything drawn as { tab = texts, cards = texts, cart = texts }.
local function draw(tab)
    tab.drawn, tab.cards.drawn, tab.cartList.drawn = {}, {}, {}
    tab:prerender()
    tab.cards:prerender()
    tab.cartList:prerender()
    return { tab = texts(tab), cards = texts(tab.cards), cart = texts(tab.cartList) }
end

-- Clicks the card of an entry in the card list.
local function clickCard(tab, id)
    local w = OA.Trade.ShopView.cardWidth(tab.cards.width)
    for _, row in ipairs(tab.cards.rows) do
        if row.kind == "cards" then
            for _, card in ipairs(row.cards) do
                if card.id == id then
                    tab.cards:onMouseDown(card.col * (w + 6) + 4, row.y - tab.cards.scroll + 4)
                    return true
                end
            end
        end
    end
    return false
end

test("the shop opens on the serum shelf with the three serums above the five treatments, the first serum selected", function()
    local tab = open("crude")
    local seen = draw(tab)
    eq(tab.cat, "serums")
    eq(tab.sel, "serum_scout", "the upgrade serums come first: they are bought far more often")
    truthy(has(seen.tab, "IGUI_OA_Terminal_Shop_Serum"), "the serum box")
    truthy(has(seen.tab, "IGUI_OA_Terminal_Shop_Sections"))
    truthy(has(seen.cards, "IGUI_OA_Terminal_Shop_Treat"), "the treatment head")
    truthy(has(seen.cards, "IGUI_OA_Econ_Shop_Group_serum"), "the enhancement head")
    truthy(has(seen.cards, "IGUI_OA_Econ_Shop_Item_cure_serum"))
    truthy(has(seen.cards, "IGUI_OA_Econ_Shop_Item_serum_load"))
    truthy(has(seen.cards, "IGUI_OA_Terminal_Shop_Nth 1"), "the first serum of a tree")
    eq(#tab.cards.rows, 2 + 3 + 2, "two heads, two card rows for the three serums and three for the five treatments")
end)

test("the sections list the groups, the locked ones with a padlock, on the crude terminal", function()
    local tab = open("crude")
    local ids = {}
    for _, c in ipairs(tab.model.cats) do ids[#ids + 1] = c.id .. (c.locked and "*" or "") end
    eq(table.concat(ids, ","), "all,resource,gear*,machine,part*,mk*,kit*")
    local field = open("field")
    ids = {}
    for _, c in ipairs(field.model.cats) do ids[#ids + 1] = c.id .. (c.locked and "*" or "") end
    eq(table.concat(ids, ","), "all,resource,gear,machine,part,mk,kit")
end)

test("a section on the crude terminal: the gate band and cards that name the terminal and the level", function()
    local tab = open("crude")
    tab:setCat("part")
    local seen = draw(tab)
    truthy(tab.band, "the gate band")
    eq(tab.band.tone, "warn")
    truthy(#tab.bandLines >= 1)
    truthy(has(seen.cards, "IGUI_OA_Terminal_Shop_FieldTier 3"), "the field terminal and the level, together")
    truthy(has(seen.cards, "IGUI_OA_Terminal_Shop_FieldTier 5"))
    eq(tab.detail.state.open, false)
    eq(tab.addButton.style, "off")
    -- the same section at the field terminal at stage 3: open and sold
    local field = open("field", 700, 408, 3)
    field:setCat("part")
    seen = draw(field)
    eq(field.band, nil)
    truthy(has(seen.cards, "IGUI_OA_Terminal_Shop_Ready"))
    truthy(has(seen.cards, "IGUI_OA_Terminal_Shop_Tier 5"), "the modern parts wait for stage 5")
end)

test("the machine section on the crude terminal opens the bench, the bait and the field terminal only", function()
    local tab = open("crude")
    tab:setCat("machine")
    draw(tab)
    eq(tab.band, nil, "no band: the section is mixed")
    eq(tab.byId.shred_bench.state.open, true)
    eq(tab.byId.bait_trap.state.open, true)
    eq(tab.byId.field_terminal.state.open, true)
    eq(tab.byId.team_locker.state.open, false)
    eq(tab.byId.team_locker.state.key, "IGUI_OA_Terminal_Shop_FieldNeeded")
    eq(tab.byId.oil_refinery.state.key, "IGUI_OA_Terminal_Shop_FieldTier")
end)

test("a debt gives the red band over every card and no card opens", function()
    local tab = open("crude", 700, 408, 2, -12300)
    tab:setCat("resource")
    draw(tab)
    eq(tab.band.tone, "bad")
    for _, card in ipairs(tab.order) do
        eq(card.state.open, false, card.id)
        eq(card.state.key, "IGUI_OA_Terminal_Shop_Debt", card.id)
    end
    eq(tab.addButton.style, "off")
end)

test("only what can be bought hides the locked cards", function()
    local tab = open("crude")
    tab:setCat("all")
    local all = #tab.order
    tab.onlyOpen = true
    tab:refresh()
    truthy(#tab.order < all and #tab.order > 0)
    for _, card in ipairs(tab.order) do eq(card.state.open, true, card.id) end
    -- everything shut: the tab says so
    local debt = open("crude", 700, 408, 2, -1)
    debt.onlyOpen = true
    debt:refresh()
    eq(#debt.cards.rows, 0)
    truthy(has(draw(debt).tab, "IGUI_OA_Terminal_Shop_NoneOpen"))
end)

test("a card is chosen with a click and the detail follows it", function()
    local tab = open("field", 700, 408, 3)
    tab:setCat("machine")
    truthy(clickCard(tab, "bulk_shredder"))
    eq(tab.sel, "bulk_shredder")
    eq(tab.detail.entry.id, "bulk_shredder")
    eq(tab.detail.price, "150,000")
    eq(tab.detail.state.open, true)
    local seen = draw(tab)
    truthy(has(seen.tab, "IGUI_OA_Econ_Shop_Item_bulk_shredder"))
    truthy(has(seen.tab, "150,000"))
    eq(tab.addButton.style ~= "off", true)
end)

test("a weekly limit shows what is left and a week with none left shows when it opens again", function()
    local tab = open("field", 700, 408, 3)
    tab:setCat("resource")
    eq(tab.byId.petrol_can.state.key, "IGUI_OA_Terminal_Shop_WeekLeft")
    eq(tab.byId.petrol_can.state.args[1], 3)
    local record = tab.window.record
    local week = OA.week()
    OA.Shop.section(record).week.petrol_can = { week = week, n = 3 }
    tab:refresh()
    eq(tab.byId.petrol_can.state.key, "IGUI_OA_Terminal_Shop_LimitFrom")
    eq(tab.byId.petrol_can.state.open, false)
end)

test("a seed packet has a combo box of kinds and no quantity; the order carries the kind picked", function()
    local tab, window = open("crude", 700, 408, 2)
    tab:setCat("resource")
    truthy(clickCard(tab, "seed_pack"))
    eq(#tab.detail.options, 2)
    eq(tab.combo.visible, true)
    eq(tab.minusButton.visible, false)
    eq(tab.plusButton.visible, false)
    eq(tab.combo.options[1].data, "Base.CarrotBagSeed", "sorted by name")
    local seen = draw(tab)
    truthy(has(seen.tab, "IGUI_OA_Terminal_Shop_PickKind"), "the label at this width")
    tab.addButton:onMouseDown()
    tab.addButton:onMouseUp()
    eq(window.sent[1].args.lines[1].choice, "Base.CarrotBagSeed")
    -- the smallest window drops the label and keeps the box clear of the button
    tab.width, tab.height = 580, 348
    seen = draw(tab)
    truthy(not has(seen.tab, "IGUI_OA_Terminal_Shop_PickKind"))
    truthy(tab.combo.x + tab.combo.width < tab.addButton.x, "the box ends before the button")
end)

test("a car battery's kinds fill the combo box and the pick is ordered", function()
    local tab, window = open("field", 700, 408, 3)
    tab:setCat("resource")
    truthy(clickCard(tab, "car_battery"))
    eq(#tab.detail.options, 3)
    eq(tab.combo.visible, true)
    eq(tab.minusButton.visible, false)
    eq(tab.combo.options[2].data, "Base.CarBattery2")
    tab.combo.selected = 2
    tab:onCombo(tab.combo)
    eq(tab.pick, "Base.CarBattery2")
    eq(tab.combo.selected, 2, "the pick stays through the redraw")
    tab.addButton:onMouseDown()
    tab.addButton:onMouseUp()
    eq(#window.sent, 1)
    eq(window.sent[1].command, "tradeCart")
    eq(window.sent[1].args.lines[1].choice, "Base.CarBattery2")
    eq(window.sent[1].args.lines[1].count, 1)
    -- the cart line is named by the kind picked alone
    local entry = OA.Shop.entry("car_battery")
    eq(tab:lineName(entry, { id = "car_battery", choice = "Base.CarBattery2" }), OA.Trade.Text.nameOf("Base.CarBattery2"))
end)

test("the quantity adds that many, and not beyond the weekly count", function()
    local tab, window = open("field", 700, 408, 3)
    tab:setCat("resource")
    truthy(clickCard(tab, "petrol_can"))
    eq(tab.detail.maxQty, 3)
    tab.plusButton:onMouseDown()
    tab.plusButton:onMouseUp()
    tab.plusButton:onMouseDown()
    tab.plusButton:onMouseUp()
    tab.plusButton:onMouseDown()
    tab.plusButton:onMouseUp()
    eq(tab.qty, 3)
    tab.minusButton:onMouseDown()
    tab.minusButton:onMouseUp()
    eq(tab.qty, 2)
    tab.addButton:onMouseDown()
    tab.addButton:onMouseUp()
    eq(window.sent[1].args.lines[1].id, "petrol_can")
    eq(window.sent[1].args.lines[1].count, 2)
    eq(tab.qty, 1, "back to one")
end)

test("a locked card cannot be added: the button does nothing and the click gives the reason", function()
    local tab, window, _, notices = open("crude")
    tab:setCat("part")
    truthy(clickCard(tab, "motor_normal"))
    eq(tab.addButton.style, "off")
    tab.addButton:onMouseDown()
    tab.addButton:onMouseUp()
    eq(#window.sent, 0)
    eq(#notices, 1)
    eq(notices[1].args.key, "IGUI_OA_Trade_Reason_fieldOnly")
    eq(tab.addButton.tooltip, "IGUI_OA_Trade_Reason_fieldOnly")
end)

test("the cart shows its lines with the total, the balance before and after, and what is short", function()
    local tab, window, record = open("crude", 700, 408, 2, 48200)
    OA.Trade.Orders.set(record, { { id = "petrol_can", count = 1 }, { id = "scrap_pack", count = 2 } })
    tab:refresh()
    eq(#tab.cartRows, 2)
    eq(tab.sum.total, 27000)
    eq(tab.sum.afterText, "21,200")
    eq(tab.sum.shortText, nil)
    local seen = draw(tab)
    truthy(has(seen.cart, "IGUI_OA_Terminal_Shop_Line IGUI_OA_Econ_Shop_Item_petrol_can 1"), "the line's name and count")
    truthy(has(seen.cart, "15,000"))
    truthy(has(seen.cart, "12,000"), "the line's total")
    truthy(has(seen.tab, "27,000"))
    truthy(has(seen.tab, "48,200"))
    truthy(has(seen.tab, "21,200"))
    -- the same cart with 10,000 in the bank
    local poor = open("crude", 700, 408, 2, 10000)
    OA.Trade.Orders.set(poor.window.record, { { id = "petrol_can", count = 1 } })
    poor:refresh()
    eq(poor.sum.short, 5000)
    truthy(poor.sum.shortText)
    truthy(#poor.shortLines >= 1)
    draw(poor)
end)

test("the cart's small buttons change, remove and clear", function()
    local tab, window, record = open("crude", 700, 408, 2, 100000)
    OA.Trade.Orders.set(record, { { id = "petrol_can", count = 1 }, { id = "scrap_pack", count = 2 } })
    tab:refresh()
    local fh = 16
    local list = tab.cartList
    local function click(row, k)
        local x = list.width - 62 + 18 * k + 4
        list:onMouseDown(x, row.y + fh + 4)
    end
    click(list.rows[2], 1)
    eq(window.sent[1].args.lines[2].count, 3, "plus")
    click(list.rows[2], 0)
    eq(window.sent[2].args.lines[2].count, 1, "minus")
    click(list.rows[1], 2)
    eq(#window.sent[3].args.lines, 1, "remove")
    eq(window.sent[3].args.lines[1].id, "scrap_pack")
    list:onMouseDown(10, list.rows[1].y + 3)
    eq(#window.sent, 3, "a click on the name does nothing")
    tab.clearButton:onMouseDown()
    tab.clearButton:onMouseUp()
    eq(#window.sent[4].args.lines, 0)
    -- an empty cart has nothing to clear
    OA.Trade.Orders.set(record, {})
    tab:refresh()
    eq(tab.clearButton.style, "off")
    tab.clearButton:onMouseDown()
    tab.clearButton:onMouseUp()
    eq(#window.sent, 4)
end)

test("the smallest window: the cart is narrower, the cards scroll and nothing draws outside the tab", function()
    local tab = open("crude", 580, 348, 2)
    tab:setCat("all")
    local seen = draw(tab)
    eq(tab.rect.cart.w, 176)
    eq(tab.rect.cards.w, 284)
    truthy(tab.cards.full > tab.cards.height, "more cards than room")
    truthy(tab.cards:maxScroll() > 0)
    tab.cards:onMouseWheel(1)
    truthy(tab.cards.scroll > 0)
    tab.cards:onMouseWheel(-5)
    eq(tab.cards.scroll, 0)
    for _, d in ipairs(tab.drawn) do
        if d[1] == "text" or d[1] == "right" or d[1] == "centre" then
            truthy(d[4] < 348 and d[4] >= -1, "text inside the tab: " .. tostring(d[2]) .. " at " .. tostring(d[4]))
        end
    end
    truthy(#seen.cards > 0)
    -- the detail and the cart fit the tab
    eq(tab.rect.detail.y + tab.rect.detail.h, 348)
    truthy(tab.cartRect.list.y + tab.cartRect.list.h <= tab.cartRect.hintY)
end)

test("a resize works the layout out again", function()
    local tab = open("crude")
    draw(tab)
    eq(tab.rect.cart.w, 200)
    tab.width, tab.height = 580, 348
    draw(tab)
    eq(tab.rect.cart.w, 176)
    eq(tab.cards.width, 284)
end)

test("a kit is ordered for a target: its combo lists the targets or says there is none", function()
    OA.Gear = OA.Gear or {}
    local tab, window = open("field", 700, 408, 6)
    OA.Gear.bagTargets = function() return { { target = "bag-1", name = "Hiking bag" } } end
    tab:setCat("kit")
    truthy(clickCard(tab, "kit_bagCapacity"))
    eq(#tab.detail.options, 1)
    eq(tab.detail.options[1].data, "bag-1")
    tab.addButton:onMouseDown()
    tab.addButton:onMouseUp()
    eq(window.sent[1].args.lines[1].target, "bag-1")
    OA.Gear.bagTargets = function() return {} end
    tab:refresh()
    eq(tab.detail.options[1].data, "", "no target given")
end)

test("a long description takes the taller detail", function()
    local real = getText
    getText = function(key, ...)
        if string.find(key, "Shop_Desc_serum_scout", 1, true) then
            return string.rep("word ", 100)
        end
        return real(key, ...)
    end
    local tab = open("field", 700, 408, 3)
    draw(tab)
    eq(#tab.descLines, 3)
    eq(tab.rect.detail.h, 120)
    getText = real
end)
