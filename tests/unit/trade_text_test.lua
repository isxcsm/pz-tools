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
require "OperationAcorn/Economy/Support"
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

test("a car part's name carries its vehicle class; other items keep the game's name", function()
    local saved = { getItemNameFromFullType, getScriptManager, instanceItem }
    local made = 0
    getItemNameFromFullType = function(t) return t == "Base.CarBattery2" and "Car Battery" or "Apple" end
    getScriptManager = function()
        return { FindItem = function(_, t)
            return { getDisplayCategory = function() return t == "Base.CarBattery2" and "VehicleMaintenance" or "Food" end }
        end }
    end
    instanceItem = function()
        made = made + 1
        return { getMechanicType = function() return 2 end }
    end
    eq(Text.itemName("Base.CarBattery2"), "IGUI_OA_Item_VehicleClass Car Battery IGUI_VehicleType_2")
    eq(Text.itemName("Base.CarBattery2"), "IGUI_OA_Item_VehicleClass Car Battery IGUI_VehicleType_2")
    eq(made, 1, "the class is looked up once per type")
    eq(Text.itemName("Base.Apple"), "Apple")
    eq(made, 1, "no item is made for other categories")
    getItemNameFromFullType, getScriptManager, instanceItem = saved[1], saved[2], saved[3]
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

test("a text with nested texts is translated from the inside out", function()
    eq(Text.trText({ key = "A" }), "A")
    eq(Text.trText({ key = "A", args = { "x", 3 } }), "A x 3")
    eq(Text.trText({ key = "A", args = { { key = "B", args = { "y" } }, "z" } }), "A B y z")
    local change = Text.trText(OA.Support.changeText("box", 0, 1))
    eq(change, "IGUI_OA_Support_Change IGUI_OA_Support_Name_box IGUI_OA_Support_V_box 50 IGUI_OA_Support_V_box 100")
end)

test("a receipt has a line for each flight support entry and a note with the count of those applied", function()
    local lines = Text.receipt({
        id = 7, day = 12, kind = "settle", boxes = 0, credits = 0, trust = 0, balanceBefore = 90000, balance = 20000,
        support = {
            { id = "box", from = 0, to = 1, price = 30000, paid = true },
            { id = "night", from = 0, to = 1, price = 100000, paid = false },
            { id = "call", from = 0, to = 1, price = 40000, paid = true },
        },
    })
    local change = function(id) return Text.trText(OA.Support.changeText(id, 0, 1)) end
    local paid, waiting, note = {}, {}, {}
    for i, line in ipairs(lines) do
        if string.find(line.text, "IGUI_OA_Trade_Rc_Support ", 1, true) == 1 then paid[#paid + 1] = { i, line }
        elseif string.find(line.text, "IGUI_OA_Trade_Rc_SupportWait", 1, true) == 1 then waiting[#waiting + 1] = { i, line }
        elseif string.find(line.text, "IGUI_OA_Trade_Rc_SupportNote", 1, true) == 1 then note[#note + 1] = { i, line } end
    end
    eq(#paid, 2)
    eq(paid[1][2].text, "IGUI_OA_Trade_Rc_Support " .. change("box") .. " 30,000")
    eq(paid[1][2].kind, "line")
    eq(paid[2][2].text, "IGUI_OA_Trade_Rc_Support " .. change("call") .. " 40,000")
    eq(#waiting, 1)
    eq(waiting[1][2].text, "IGUI_OA_Trade_Rc_SupportWait " .. change("night"))
    eq(waiting[1][2].kind, "bad", "an unpaid request is marked")
    eq(#note, 1)
    eq(note[1][2].text, "IGUI_OA_Trade_Rc_SupportNote 2", "two were applied")
    eq(note[1][2].kind, "note")
    truthy(paid[1][1] < waiting[1][1] and waiting[1][1] < paid[2][1], "in the order of the entries")
    truthy(note[1][1] > paid[2][1], "the note comes after the lines")
    eq(lines[#lines].kind, "total", "the balance closes the receipt")
end)

test("a receipt with only unpaid support entries has no applied note", function()
    local lines = Text.receipt({ id = 1, day = 1, balanceBefore = 0, balance = 0,
        support = { { id = "box", from = 0, to = 1, price = 30000, paid = false } } })
    local waiting, note = 0, 0
    for _, line in ipairs(lines) do
        if string.find(line.text, "IGUI_OA_Trade_Rc_SupportWait", 1, true) then waiting = waiting + 1 end
        if string.find(line.text, "IGUI_OA_Trade_Rc_SupportNote", 1, true) then note = note + 1 end
    end
    eq(waiting, 1); eq(note, 0)
end)

test("a receipt tells the request lines the flight filled", function()
    local lines = Text.receipt({ id = 1, day = 1, balanceBefore = 0, balance = 0,
        filled = { { fullType = "Base.Rag", band = "common", trust = 5 } } })
    local found
    for _, line in ipairs(lines) do
        if string.find(line.text, "IGUI_OA_Trade_Rc_Filled", 1, true) then found = line end
    end
    truthy(found, "a line for the filled request")
    eq(found.kind, "good")
    truthy(string.find(found.text, "5", 1, true))
    local plain = Text.receipt({ id = 1, day = 1, balanceBefore = 0, balance = 0 })
    for _, line in ipairs(plain) do eq(string.find(line.text, "Rc_Filled", 1, true), nil) end
end)

test("a receipt without support entries has no support lines", function()
    local lines = Text.receipt({ id = 1, day = 1, balanceBefore = 0, balance = 0 })
    for _, line in ipairs(lines) do
        eq(string.find(line.text, "Rc_Support", 1, true), nil, line.text)
    end
end)

-- An economy with the counting of the real one: a request item's first 20 units a week are worth more, and the units
-- one line takes are not available to the next.
local function fakeValue()
    OA.Value = {
        CASH_TRUST_CAP = 50,
        context = function() return {} end,
        appraiseLine = function(info, count, ctx, taken)
            local used = taken.requests[info.fullType] or 0
            local units = math.max(0, math.min(count, 20 - used))
            return { fullType = info.fullType, count = count, credits = 100 * count + 50 * units, trust = count,
                cashTrust = 0, requestUnits = units, requestCredits = 150 * units, regionWeight = 0 }
        end,
        requestFills = function(ctx, taken)
            if (taken.requests["Base.Rag"] or 0) >= 20 then
                return { fills = { { fullType = "Base.Rag", band = "common", trust = 5 } }, trust = 5 }
            end
            return { fills = {}, trust = 0 }
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
    eq(result.trust, 30 + 5, "the full line's trust is in")
    eq(#result.filled, 1)
    eq(result.requests.units, 20); eq(result.requests.credits, 3000)
    eq(result.requests.lines[1].fullType, "Base.Rag"); eq(result.requests.lines[1].units, 20)
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
    eq(flight.requests.units, 2, "what B1's waybill draws: the request units and what they fetch")
    eq(flight.requests.credits, 300); eq(flight.requests.lines[1].fullType, "Base.Rag")
    eq(#flight.filled, 0)
    OA.Shop = nil
end)

test("the flight estimate withholds the infection handling fee: sealed is gross, fee and net are given", function()
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
    local plain = Estimate.flight(record)
    eq(plain.fee, 0)
    eq(plain.feeRate, 0)
    eq(plain.net, 300)
    OA.Infection.wounded(record, "scratch", 0)
    local flight = Estimate.flight(record)
    eq(flight.sealed, 300, "the worth before the fee")
    eq(flight.fee, 90)
    eq(flight.feeRate, 0.3)
    eq(flight.net, 210)
    eq(flight.bonus, 100)
    eq(flight.after, 500 + 210 + 100 - 2000)
    eq(flight.after, plain.after - 90)
    OA.Infection.tested(record, true, 0.1)
    eq(Estimate.flight(record).fee, 90, "the same once the infection is known")
    OA.Infection.tested(record, false)
    eq(Estimate.flight(record).fee, 0, "none after a negative test")
    OA.Shop = nil
end)

test("a fee on a debt that the rest does not clear still blocks the orders", function()
    fakeValue()
    OA.Shop = { catalog = function() return { { id = "a" } } end, price = function() return 1000 end }
    local record = OA.Store.ensure("rec", "T")
    local box = Boxes.add(record, { x = 1, y = 1, z = 0 })
    Boxes.seal(record, box.id, { { info = { fullType = "Base.Rag" }, count = 2 } })
    OA.Trade.account(record).credits = -400
    OA.Infection.wounded(record, "cut", 0)
    OA.Trade.Orders.set(record, { { id = "a", count = 1 } })
    local flight = Estimate.flight(record)
    eq(flight.after, -400 + 300 - 90)
    eq(flight.blocked, true)
    eq(flight.orders, 0)
    OA.Shop = nil
end)

test("a receipt with a fee has a marked line with the share and the credits withheld", function()
    local lines = Text.receipt({ id = 1, day = 2, boxes = 1, credits = 1000, fee = 300, feeRate = 0.3, trust = 5,
        balanceBefore = 0, balance = 700 })
    local found
    for _, line in ipairs(lines) do
        if string.find(line.text, "IGUI_OA_Trade_Rc_Fee", 1, true) then found = line end
    end
    truthy(found, "a fee line")
    eq(found.text, "IGUI_OA_Trade_Rc_Fee 30 300")
    eq(found.kind, "bad")
    lines = Text.receipt({ id = 1, day = 2, boxes = 1, credits = 1000, trust = 5, balanceBefore = 0, balance = 1000 })
    for _, line in ipairs(lines) do eq(string.find(line.text, "Rc_Fee", 1, true), nil) end
end)

test("a receipt after a cure has the lifted-fee line, a good one, and one with a fee has not", function()
    local lines = Text.receipt({ id = 1, day = 2, boxes = 1, credits = 1000, feeReleased = true, trust = 5,
        balanceBefore = 0, balance = 1000 })
    local found
    for _, line in ipairs(lines) do
        if line.text == "IGUI_OA_Trade_Rc_FeeReleased" then found = line end
    end
    truthy(found, "a lifted-fee line")
    eq(found.kind, "good")
    lines = Text.receipt({ id = 1, day = 2, boxes = 1, credits = 1000, fee = 300, feeRate = 0.3, feeReleased = true,
        trust = 5, balanceBefore = 0, balance = 700 })
    for _, line in ipairs(lines) do eq(line.text == "IGUI_OA_Trade_Rc_FeeReleased", false) end
end)

test("the flight estimate carries the lifted fee for a flight with credits only", function()
    fakeValue()
    local record = OA.Store.ensure("rec", "T")
    local box = Boxes.add(record, { x = 1, y = 1, z = 0 })
    Boxes.seal(record, box.id, { { info = { fullType = "Base.Rag" }, count = 2 } })
    OA.Infection.tested(record, true, 0.1)
    OA.Infection.cured(record)
    eq(Estimate.flight(record).feeReleased, true)
    OA.Infection.wounded(record, "scratch", 0)
    eq(Estimate.flight(record).feeReleased, false, "a fee is taken again")
end)

test("a debt that the flight does not clear blocks the orders in the estimate", function()
    fakeValue()
    OA.Shop = { catalog = function() return { { id = "a" } } end, price = function() return 1000 end }
    local record = OA.Store.ensure("rec", "T")
    OA.Trade.account(record).credits = -5000
    OA.Trade.Orders.set(record, { { id = "a", count = 1 } })
    local flight = Estimate.flight(record)
    eq(flight.requests.units, 0, "no sealed box, no request units")
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

test("a tab keeps one thing as seen, or several: the pairs come by key", function()
    Terminal.clear()
    Terminal.addTab("shop", function() end, { seen = function() return "tier", 4 end })
    Terminal.addTab("delivery", function() end, { seen = function() return { week = 3, market = 12 } end })
    Terminal.addTab("status", function() end, { seen = function() error("broken") end })
    Terminal.addTab("missions", function() end)
    local one = Terminal.seenPairs("shop", {})
    eq(#one, 1); eq(one[1].key, "tier"); eq(one[1].value, 4)
    local two = Terminal.seenPairs("delivery", {})
    eq(#two, 2); eq(two[1].key, "market"); eq(two[1].value, 12); eq(two[2].key, "week"); eq(two[2].value, 3)
    eq(#Terminal.seenPairs("status", {}), 0, "a failing rule keeps nothing")
    eq(#Terminal.seenPairs("missions", {}), 0, "a tab without a rule")
    eq(#Terminal.seenPairs("shop", nil), 0)
    local record = {}
    truthy(Terminal.setSeen(record, "market", 12))
    eq(Terminal.seenValue(record, "market"), 12)
    Terminal.clear()
end)

test("a tab's seen rule gets the window, to ask which of its screens is on show", function()
    Terminal.clear()
    local window = { subOn = function(_, id) return id == "status" and "progress" or nil end }
    Terminal.addTab("status", function() end, { seen = function(record, w)
        if w and w:subOn("status") == "progress" then return "road", 3 end
        return nil
    end })
    local list = Terminal.seenPairs("status", {}, window)
    eq(#list, 1); eq(list[1].key, "road"); eq(list[1].value, 3)
    eq(#Terminal.seenPairs("status", {}, nil), 0, "no window: nothing is on show")
    local record = {}
    truthy(Terminal.setSeen(record, "road", 3), "road is a key the record keeps")
    eq(Terminal.seenValue(record, "road"), 3)
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
