-- The trade part's words (money, order reasons, receipt lines), the estimate that follows the
-- settlement's own counting, and the terminal's tab registry.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Trade/Text"
require "OperationAcorn/Trade/Estimate"
require "OperationAcorn/Trade/Terminal"
local OA = OperationAcorn
local Text, Estimate, Boxes, Terminal = OA.Trade.Text, OA.Trade.Estimate, OA.Trade.Boxes, OA.Terminal

test("credits are written with thousands separators", function()
    eq(Text.credits(0), "0")
    eq(Text.credits(999), "999")
    eq(Text.credits(1000), "1,000")
    eq(Text.credits(1234567), "1,234,567")
    eq(Text.credits(-45000), "-45,000")
    eq(Text.credits(12.6), "13", "rounded once")
end)

test("order reasons are the shop's keys or the helicopter's words", function()
    eq(Text.orderReason("IGUI_OA_Econ_Shop_Limit"), "IGUI_OA_Econ_Shop_Limit")
    eq(Text.orderReason("credits"), "IGUI_OA_Trade_OrderReason_credits")
    eq(Text.orderReason(nil), nil)
end)

test("a receipt is written as lines with the cut-short orders marked", function()
    OA.Shop = { catalog = function() return { { id = "pack" } } end, nameKey = function(e) return "Name_" .. e.id end }
    local lines = Text.receipt({
        id = 7, day = 12, kind = "settle", boxes = 2, credits = 1500, trust = 3, bonus = 100, debtPaid = 40,
        balanceBefore = 10, balance = 90,
        lines = { { fullType = "Base.Rag", count = 3, credits = 900 }, { other = 5, count = 9, credits = 600 } },
        orders = { { id = "pack", ordered = 3, delivered = 1, paid = 400, reason = "credits" },
            { id = "pack", ordered = 1, delivered = 1, paid = 100 } },
        gifts = { { type = "Base.Battery", count = 2 } },
        events = { { kind = "stage", n = 2 } },
        note = { key = "IGUI_OA_Story_Note_1" },
    })
    eq(lines[1].kind, "head")
    eq(lines[1].text, "IGUI_OA_Trade_Rc_Head 7 12")
    local kinds = {}
    for _, line in ipairs(lines) do kinds[line.kind] = (kinds[line.kind] or 0) + 1 end
    eq(kinds.bad, 1, "only the order that came short is marked")
    eq(kinds.note, 1)
    eq(kinds.total, 1)
    eq(kinds.good, 3, "bonus, gift, new items")
    local cut
    for _, line in ipairs(lines) do if line.kind == "bad" then cut = line.text end end
    truthy(string.find(cut, "IGUI_OA_Trade_OrderReason_credits", 1, true), "the reason follows")
    OA.Shop = nil
end)

-- An economy with the counting of the real one: a request item is worth a bonus for its first 20 units a week, and the
-- units one line takes are not available to the next.
local function fakeValue()
    OA.Value = {
        CASH_TRUST_CAP = 50,
        context = function() return {} end,
        appraiseLine = function(info, count, ctx, taken)
            local used = taken.requests[info.fullType] or 0
            local units = math.max(0, math.min(count, 20 - used))
            return { fullType = info.fullType, count = count, credits = 100 * count + 50 * units, trust = count,
                cashTrust = 0, requestUnits = units, regionWeight = 0 }
        end,
    }
end

test("the estimate follows what earlier lines of the same flight used up", function()
    fakeValue()
    local record = OA.Store.ensure("rec", "T")
    local result = Estimate.entries(record, {
        { info = { fullType = "Base.Rag" }, count = 15 },
        { info = { fullType = "Base.Rag", condition = 0.5 }, count = 15 },
    })
    eq(result.lines[1].requestUnits, 15)
    eq(result.lines[2].requestUnits, 5, "only five of the twenty are left")
    eq(result.credits, 3000 + 50 * 20)
    eq(result.trust, 30)
    OA.Value = nil
    eq(Estimate.entries(record, {}), nil, "without an economy there is no estimate")
end)

test("the flight estimate puts the sealed boxes, the bonus and the cart together", function()
    fakeValue()
    OA.Shop = {
        catalog = function() return { { id = "a" } } end,
        price = function() return 1000 end,
    }
    local record = OA.Store.ensure("rec", "T")
    local box = Boxes.add(record, { x = 1, y = 1, z = 0 })
    Boxes.seal(record, box.id, { { info = { fullType = "Base.Rag" }, count = 2 } })
    OA.Trade.account(record).credits = 500
    OA.Trade.account(record).bonus = 100
    OA.Trade.Orders.set(record, { { id = "a", count = 2 } })
    local flight = Estimate.flight(record)
    eq(flight.boxes, 1)
    eq(flight.sealed, 300)
    eq(flight.bonus, 100)
    eq(flight.cart, 2000)
    eq(flight.after, 500 + 300 + 100 - 2000)
    OA.Shop = nil
end)

test("a debt that the flight does not clear blocks the orders in the estimate", function()
    fakeValue()
    OA.Shop = { catalog = function() return { { id = "a" } } end, price = function() return 1000 end }
    local record = OA.Store.ensure("rec", "T")
    OA.Trade.account(record).credits = -5000
    OA.Trade.Orders.set(record, { { id = "a", count = 1 } })
    local flight = Estimate.flight(record)
    eq(flight.blocked, true)
    eq(flight.orders, 0)
    eq(flight.after, -5000)
    OA.Shop = nil
end)

test("the terminal has four tabs; a view given again replaces the first", function()
    Terminal.clear()
    eq(table.concat(Terminal.ORDER, ","), "status,shop,delivery,missions")
    local first, second = function() return 1 end, function() return 2 end
    Terminal.addTab("shop", first)
    Terminal.addTab("shop", second)
    eq(Terminal.tab("shop").factory, second)
    eq(Terminal.tab("delivery"), nil)
    eq(Terminal.titleKey("shop"), "IGUI_OA_Terminal_Tab_shop")
    Terminal.clear()
end)

test("a tab's dot comes from its rule; a failing rule shows none", function()
    Terminal.clear()
    Terminal.addTab("shop", function() end, { mark = function(record) return record.flag end })
    Terminal.addTab("status", function() end, { mark = function() error("broken rule") end })
    eq(Terminal.mark("shop", { flag = "new" }), "new")
    eq(Terminal.mark("shop", {}), nil)
    eq(Terminal.mark("status", {}), nil)
    eq(Terminal.mark("missions", {}), nil, "a tab without a view has no dot")
    eq(Terminal.mark("shop", nil), nil)
    Terminal.clear()
end)

test("what a tab has seen is kept as a number under a known key", function()
    local record = {}
    eq(Terminal.seenValue(record, "tier"), nil)
    truthy(Terminal.setSeen(record, "tier", 3))
    eq(Terminal.seenValue(record, "tier"), 3)
    eq(Terminal.setSeen(record, "other", 1), false, "an unknown key")
    eq(Terminal.setSeen(record, "week", "7"), false, "not a number")
    eq(record.ui.seen.other, nil)
    eq(Terminal.seenValue(nil, "tier"), nil)
end)
