-- The shop tab's rules and layout (client Trade/ShopView): the serum shelf and its order, the sections and their
-- padlocks, why a card is locked, the wrap, the rows of cards, the sizes in a default and a smallest window, the
-- cart's totals.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Trade/ShopView"
local OA = OperationAcorn
local V = OA.Trade.ShopView

local function ids(list)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.id end
    return table.concat(out, ",")
end

local function entry(id, group, extra)
    local e = { id = id, group = group, tier = 0, price = 100 }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

test("the shelf holds the serum group and the serum-special entries in the fixed order, skipping missing ids", function()
    local blocks = V.shelf({
        entry("cure_serum", "serum", { special = "cure" }),
        entry("delay_drug", "serum", { special = "delay" }),
        entry("battery_pack", "resource"),
        entry("serum_load", "serum", { special = "serum" }),
        entry("box_reissue", "box", { special = "reissue" }),
    })
    eq(ids(blocks[2].entries), "cure_serum,delay_drug")
    eq(ids(blocks[1].entries), "serum_load")
    -- five treatments: the order is the fixed one whatever the catalog's
    local full = {
        entry("serum_scout", "serum", { special = "serum" }),
        entry("delay_drug", "serum", { special = "delay" }),
        entry("test_kit", "serum", { special = "test" }),
        entry("delay_long", "serum", { special = "delay" }),
        entry("reversal", "serum", { special = "reversal" }),
        entry("cure_serum", "serum", { special = "cure" }),
        entry("serum_survival", "serum", { special = "serum" }),
        entry("serum_load", "serum", { special = "serum" }),
    }
    blocks = V.shelf(full)
    eq(ids(blocks[2].entries), "cure_serum,reversal,delay_long,delay_drug,test_kit")
    eq(ids(blocks[1].entries), "serum_scout,serum_load,serum_survival")
end)

test("an entry the order does not name still lands on the shelf, by what it is", function()
    local blocks = V.shelf({
        entry("cure_serum", "serum", { special = "cure" }),
        entry("new_drug", "serum"),
        entry("serum_extra", "resource", { special = "serum" }),
    })
    eq(ids(blocks[2].entries), "cure_serum,new_drug")
    eq(ids(blocks[1].entries), "serum_extra")
end)

test("the sections leave out the shelf and the box reissue and keep the catalog's order", function()
    local sections = V.sections(OA.Shop.catalog())
    eq(table.concat(sections.groups, ","), "resource,harvest,gear,machine,tool,part,kit")
    for _, g in ipairs(sections.groups) do
        for _, e in ipairs(sections.byGroup[g]) do
            truthy(not V.onShelf(e), e.id .. " is not on the shelf")
            truthy(e.special ~= "reissue", "no reissue")
        end
    end
    eq(#sections.byGroup.machine, 11)
    -- the real catalog's shelf: the five treatments, the three serums and the shared one
    local blocks = V.shelf(OA.Shop.catalog())
    eq(ids(blocks[2].entries), "cure_serum,reversal,delay_long,delay_drug,test_kit")
    eq(ids(blocks[1].entries), "serum_scout,serum_load,serum_survival,serum_shared")
end)

test("a section is locked on the crude terminal when all its entries are for the field terminal", function()
    local sections = V.sections(OA.Shop.catalog())
    local locked = {}
    for _, g in ipairs(sections.groups) do
        if V.sectionLocked(sections.byGroup[g], true) then locked[#locked + 1] = g end
    end
    eq(table.concat(locked, ","), "gear,tool,part,kit")
    eq(V.sectionLocked(sections.byGroup.gear, false), false, "never on the field terminal")
    eq(V.sectionLocked(sections.byGroup.machine, true), false, "the bench, the bait and the terminal are open")
    eq(V.sectionLocked({}, true), false)
end)

test("the band over the cards is the debt first, then the gate of a locked section", function()
    local sections = V.sections(OA.Shop.catalog())
    eq(V.band("part", sections.byGroup.part, { crude = true, debt = false }), "gate")
    eq(V.band("part", sections.byGroup.part, { crude = false, debt = false }), nil)
    eq(V.band("part", sections.byGroup.part, { crude = true, debt = true }), "debt")
    eq(V.band("serums", {}, { crude = true, debt = false }), nil)
    eq(V.band("resource", sections.byGroup.resource, { crude = true, debt = false }), nil)
    eq(V.band("serums", {}, { crude = false, debt = true }), "debt")
end)

local function when(hours) return "day " .. hours end

test("a card says what it is: ready, left this week, the serum's number", function()
    local ctx = { crude = true, tier = 3, debt = false, whenText = when }
    local s = V.state(entry("cure_serum", "serum", { tier = 1 }), { n = 99 }, ctx)
    eq(s.open, true)
    eq(s.key, "IGUI_OA_Terminal_Shop_Ready")
    eq(s.lock, false)
    s = V.state(entry("petrol", "resource", { tier = 2, week = 3 }), { n = 2 }, ctx)
    eq(s.key, "IGUI_OA_Terminal_Shop_WeekLeft")
    eq(s.args[1], 2)
    eq(s.args[2], 3)
    s = V.state(entry("serum_scout", "serum", { special = "serum" }), { n = 99, serumN = 6 }, ctx)
    eq(s.key, "IGUI_OA_Terminal_Shop_Nth")
    eq(s.args[1], 6)
end)

test("a locked card names its reason: the trust level, the field terminal, or both", function()
    local crude = { crude = true, tier = 2, debt = false, whenText = when }
    local field = { crude = false, tier = 2, debt = false, whenText = when }
    local up = entry("team_locker", "machine", { tier = 2 })
    local s = V.state(up, { n = 99 }, crude)
    eq(s.open, false)
    eq(s.key, "IGUI_OA_Terminal_Shop_FieldNeeded")
    eq(s.tone, "warn")
    eq(s.lock, true)
    eq(s.reason, "IGUI_OA_Trade_Reason_fieldOnly")
    s = V.state(entry("motor_normal", "part", { tier = 3 }), { n = 0, why = "IGUI_OA_Econ_Shop_Locked" }, crude)
    eq(s.key, "IGUI_OA_Terminal_Shop_FieldTier")
    eq(s.args[1], 3)
    eq(s.tone, "warn")
    -- the same card at the field terminal: only the level
    s = V.state(entry("motor_normal", "part", { tier = 3 }), { n = 0, why = "IGUI_OA_Econ_Shop_Locked" }, field)
    eq(s.key, "IGUI_OA_Terminal_Shop_Tier")
    eq(s.args[1], 3)
    eq(s.tone, "dim")
    -- a vanilla good above the level is the level alone, on either terminal
    s = V.state(entry("ammo_rifle", "resource", { tier = 4 }), { n = 0, why = "IGUI_OA_Econ_Shop_Locked" }, crude)
    eq(s.key, "IGUI_OA_Terminal_Shop_Tier")
    -- a field-only entry whose level is reached: the terminal alone
    s = V.state(entry("team_fuel_can", "gear", { tier = 2 }), { n = 99 }, crude)
    eq(s.key, "IGUI_OA_Terminal_Shop_FieldNeeded")
end)

test("a card says debt, kits off, not stocked and the weekly limit", function()
    local ctx = { crude = false, tier = 5, debt = true, whenText = when }
    local s = V.state(entry("petrol", "resource", { week = 3 }), { n = 0, why = "IGUI_OA_Econ_Shop_Debt" }, ctx)
    eq(s.key, "IGUI_OA_Terminal_Shop_Debt")
    eq(s.tone, "bad")
    eq(s.open, false)
    -- the box is bought in debt
    s = V.state(entry("box_reissue", "box", { allowDebt = true }), { n = 99 }, ctx)
    eq(s.open, true)
    ctx.debt = false
    s = V.state(entry("kit_capacity", "kit", { kits = true }), { n = 0, why = "IGUI_OA_Econ_Shop_KitsOff" }, ctx)
    eq(s.key, "IGUI_OA_Econ_Shop_KitsOff")
    eq(s.lock, true)
    s = V.state(entry("x", "resource"), { n = 0, why = "IGUI_OA_Econ_Shop_NotStocked" }, ctx)
    eq(s.key, "IGUI_OA_Econ_Shop_NotStocked")
    s = V.state(entry("petrol", "resource", { week = 3 }), { n = 0, why = "IGUI_OA_Econ_Shop_Limit", reopen = 1200 }, ctx)
    eq(s.key, "IGUI_OA_Terminal_Shop_LimitFrom")
    eq(s.args[1], "day 1200")
    eq(s.tone, "timer")
    eq(s.lock, false)
    eq(s.open, false)
    s = V.state(entry("petrol", "resource", { week = 3 }), { n = 0, why = "IGUI_OA_Econ_Shop_Limit" }, ctx)
    eq(s.key, "IGUI_OA_Econ_Shop_Limit")
end)

local function measure(s) return #s * 6 end

test("a text wraps at spaces, cuts a word too long, and ends in dots at the line limit", function()
    local lines = V.wrap("aaa bbb ccc ddd", 42, measure)
    eq(#lines, 2)
    eq(lines[1], "aaa bbb")
    eq(lines[2], "ccc ddd")
    lines = V.wrap("abcdefghijklmnop", 30, measure)
    eq(lines[1], "abcde")
    eq(#lines, 4)
    eq(lines[4], "p")
    lines = V.wrap("one two three four five six seven", 40, measure, 2)
    eq(#lines, 2)
    eq(string.sub(lines[2], -3), "...")
    truthy(measure(lines[2]) <= 40, "the dots fit too")
    eq(#V.wrap("", 40, measure), 0)
    eq(#V.wrap("short", 40, measure, 1), 1)
end)

test("cards are rows of two, a block's head is a row and blocks are told apart", function()
    local function cards(n)
        local list = {}
        for i = 1, n do list[i] = { id = "c" .. i } end
        return list
    end
    local rows = V.rows({
        { head = "cure", note = "n", cards = cards(5) },
        { head = "serum", note = "m", cards = cards(3) },
    })
    eq(#rows, 2 + 3 + 2)
    eq(rows[1].kind, "head")
    eq(rows[2].kind, "cards")
    eq(#rows[2].cards, 2)
    eq(rows[2].cards[1].col, 0)
    eq(rows[2].cards[2].col, 1)
    eq(#rows[4].cards, 1, "the odd card is alone")
    eq(rows[4].h, V.ROW_H + V.BLOCK_GAP, "room after the first block")
    eq(rows[7].h, V.ROW_H, "none after the last")
    -- a block without cards leaves no head; no heads in a plain list
    rows = V.rows({ { head = "x", cards = {} }, { cards = cards(3) } })
    eq(#rows, 2)
    eq(rows[1].kind, "cards")
end)

test("the columns follow the body width: the cart is 200 wide, 176 when narrow", function()
    local c = V.columns(700)
    eq(c.cartw, 200)
    eq(c.cx, 112)
    eq(c.cw, 380, "the mockup's 380")
    c = V.columns(580)
    eq(c.cartw, 176)
    eq(c.cw, 284)
    eq(V.columns(680).cartw, 200)
    eq(V.columns(679).cartw, 176)
    eq(V.cardWidth(380), 183)
    eq(V.cardWidth(284), 135)
end)

test("the layout puts the detail under the cards, 120 high for a text of three lines, under the band", function()
    local l = V.layout(700, 408, { lineH = 16, descLines = 2, bandLines = 0 })
    eq(l.detail.h, 104)
    eq(l.detail.y, 304)
    eq(l.cards.y, 0)
    eq(l.cards.h, 408 - 104 - 8)
    eq(l.cart.x, 500)
    eq(l.cart.h, 408)
    l = V.layout(700, 408, { lineH = 16, descLines = 3, bandLines = 0 })
    eq(l.detail.h, 120)
    eq(l.detail.y, 288)
    l = V.layout(700, 408, { lineH = 16, descLines = 2, bandLines = 2 })
    eq(l.band.h, 40)
    eq(l.cards.y, 46)
    eq(l.cards.h, 408 - 104 - 8 - 46)
    -- the smallest window: the body is 580 x 348
    l = V.layout(580, 348, { lineH = 16, descLines = 3, bandLines = 3 })
    eq(l.cart.w, 176)
    eq(l.cards.w, 284)
    truthy(l.cards.h >= 0, "never negative")
    eq(l.detail.y + l.detail.h, 348)
end)

test("the detail's control row: the add button, and a combo box that gives way to it", function()
    local r = V.detailRow(380, 104, false)
    eq(r.y, 76)
    eq(r.add.x, 252)
    eq(r.combo, nil)
    eq(r.minus, nil, "no quantity: the cart sets how many")
    r = V.detailRow(380, 104, true)
    eq(r.combo.x, 76)
    eq(r.combo.w, 150)
    eq(r.combo.label, true)
    -- narrow: no label, the box starts at the margin and ends before the button
    r = V.detailRow(284, 104, true)
    eq(r.combo.label, false)
    eq(r.combo.x, 10)
    truthy(r.combo.x + r.combo.w + 8 <= r.add.x, "clear of the button")
    truthy(r.combo.w >= 100, "wide enough to read")
end)

test("the cart's totals say what is short", function()
    local s = V.cartSummary(25000, 48200)
    eq(s.total, 25000)
    eq(s.after, 23200)
    eq(s.short, 0)
    s = V.cartSummary(50000, 48200)
    eq(s.after, -1800)
    eq(s.short, 1800)
    s = V.cartSummary(0, 0)
    eq(s.after, 0)
    eq(s.short, 0)
end)

test("the cart's bottom keeps the buttons on the floor and the list above the totals", function()
    local r = V.cartRects(408, 1, 0, true, 16)
    eq(r.clearY, 378)
    eq(r.hintY, 356)
    truthy(r.sumY < r.hintY, "totals over the hint")
    truthy(r.list.y + r.list.h <= r.ruleY, "the list ends over the rule")
    local short = V.cartRects(408, 1, 3, true, 16)
    truthy(short.sumY < r.sumY, "a short balance takes more room")
    truthy(short.shortY > short.balanceY, "its words go under the balance")
    truthy(short.shortY + 48 <= short.hintY, "and end over the hint")
    local empty = V.cartRects(408, 1, 0, false, 16)
    eq(empty.sumY, nil)
    truthy(empty.list.h > r.list.h, "an empty cart has no totals")
    -- the smallest window: the list may shrink to nothing but not below
    local tight = V.cartRects(348, 2, 3, true, 16)
    truthy(tight.list.h >= 0)
end)

test("the shelf and the sections are kept for a catalog, and made again when it, the kits option or a BU feature changes", function()
    local bu = true
    BuildingUtilities = { enabled = function() return bu end }
    local catalog = {
        entry("cure_serum", "serum", { special = "cure" }),
        entry("battery_pack", "resource"),
        entry("bu_pump", "resource", { bu = "pump" }),
    }
    local shelf, sections = V.shelf(catalog), V.sections(catalog)
    eq(V.shelf(catalog), shelf, "the same list again")
    eq(V.sections(catalog), sections)
    eq(#sections.byGroup.resource, 2)
    bu = false
    local without = V.sections(catalog)
    truthy(without ~= sections, "a BU feature went off: made again")
    eq(#without.byGroup.resource, 1)
    eq(V.sections(catalog), without)
    bu = true
    eq(#V.sections(catalog).byGroup.resource, 2)
    local before = V.sections(catalog)
    catalog[#catalog + 1] = entry("cable", "resource")
    local after = V.sections(catalog)
    truthy(after ~= before, "an entry added: made again")
    eq(#after.byGroup.resource, 3)
    local other = { entry("battery_pack", "resource") }
    eq(#V.sections(other).byGroup.resource, 1, "another catalog")
    eq(ids(V.shelf(catalog)[2].entries), "cure_serum")
    local was = SandboxVars.OperationAcorn.KitsForSale
    SandboxVars.OperationAcorn.KitsForSale = not was
    truthy(V.sections(catalog) ~= V.sections(other))
    SandboxVars.OperationAcorn.KitsForSale = was
    BuildingUtilities = nil
end)

test("Shop.available asks for the restock window once for a restock entry", function()
    local Shop = OA.Shop
    local record = OA.Store.ensure("p", "P")
    local entry = Shop.entry("serum_shared")
    truthy(entry and entry.restock, "a restock entry")
    local asked = 0
    local real = Shop.restock
    Shop.restock = function(r) asked = asked + 1 return real(r) end
    local n, why, reopen = Shop.available(entry, record)
    eq(asked, 1)
    Shop.restock = real
    local n2, why2, reopen2 = Shop.available(entry, record)
    eq(n2, n)
    eq(why2, why)
    eq(reopen2, reopen)
    eq(reopen, Shop.restockEnd(record))
end)
