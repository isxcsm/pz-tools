-- Value: the formulas of NUMBERS 1, the state factor, cash, request and new-region bonuses, one rounding a flight.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
local OA = OperationAcorn
local V = OA.Value

local function info(fullType, display, weight, extra)
    local t = { fullType = fullType, baseType = OA.Categories.baseType(fullType), weight = weight,
        displayCategory = display }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

-- A plain context: index 1 everywhere, no premiums.
local function ctx(extra)
    local c = { rate = 1.0, trustAccel = 1.0, requestBonus = 0.5, index = {}, refused = {}, requests = {},
        requestUsed = {}, cellUsed = {} }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

test("the example box: 20 clothing, 10 documents, 10 household, 10 food is 18,500 credits and 185 trust", function()
    local entries = {
        { info = info("Base.Shirt", "Clothing", 1.0), count = 20 },
        { info = info("Base.Book", "Literature", 0.5), count = 20 },
        { info = info("Base.Pan", "Cooking", 0.5), count = 20 },
        { info = info("Base.Can", "Food", 0.2), count = 50 },
    }
    local credits, trust = 0, 0
    for _, e in ipairs(entries) do
        local line = V.appraiseLine(e.info, e.count, ctx())
        credits = credits + line.credits
        trust = trust + line.trust
    end
    near(credits, 8000 + 4500 + 3500 + 2500, 1e-6)
    near(trust, 185, 1e-6)
end)

test("a box of sample bundles: 500 of them are 30,000 credits and 300 trust", function()
    local line = V.appraiseLine(info("OperationAcorn.SampleBundle", "Junk", 0.1, { own = "SampleBundle" }), 500, ctx())
    near(line.credits, 30000, 1e-6)
    near(line.trust, 300, 1e-6)
end)

test("the market index multiplies credits and never trust", function()
    local c = ctx({ index = { B = 1.5 } })
    local a = V.appraise(info("Base.Shirt", "Clothing", 1.0), c)
    near(a.credits, 600, 1e-9)
    near(a.trust, 4.0, 1e-9)
    eq(a.category, "B")
    truthy(a.marks.high)
    c.index.B = 0.5
    a = V.appraise(info("Base.Shirt", "Clothing", 1.0), c)
    truthy(a.marks.low); truthy(not a.marks.high)
end)

test("condition: 0.5 + 0.5 of the ratio, food by freshness", function()
    near(V.state(info("X", "Tool", 1)), 1.0)
    near(V.state(info("X", "Tool", 1, { condition = 0 })), 0.5)
    near(V.state(info("X", "Tool", 1, { condition = 0.5 })), 0.75)
    near(V.state(info("X", "Food", 1, { food = "fresh" })), 1.0)
    near(V.state(info("X", "Food", 1, { food = "stale" })), 0.5)
    local a = V.appraise(info("Base.Battery", "Electronics", 0.2, { condition = 0 }), ctx())
    near(a.credits, 0.2 * 600 * 0.5, 1e-9, "a spent battery is half")
    near(a.trust, 0.2 * 6 * 0.5, 1e-9)
end)

test("the exchange rate and the trust acceleration", function()
    local c = ctx({ rate = 1.15, trustAccel = 1.2 })
    local a = V.appraise(info("Base.Shirt", "Clothing", 1.0), c)
    near(a.credits, 400 * 1.15, 1e-9)
    near(a.trust, 4 * 1.2, 1e-9)
end)

test("cash is 100 credits a dollar, with the rate, and 0.02 trust a dollar", function()
    local money = info("Base.Money", "Junk", 0.01, { cash = 1 })
    local bundle = info("Base.MoneyBundle", "Junk", 0.5, { cash = 100 })
    local a = V.appraise(money, ctx({ index = { E = 2.0 }, rate = 1.05 }))
    near(a.credits, 105, 1e-9, "no market, the rate on top")
    near(a.cashTrust, 0.02, 1e-9)
    eq(a.trust, 0)
    local line = V.appraiseLine(bundle, 3, ctx())
    near(line.credits, 30000, 1e-9)
    near(line.cashTrust, 6, 1e-9)
end)

test("cash trust is capped at 50 for a whole flight", function()
    local record = OA.Store.ensure("c", "C")
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    local bundle = info("Base.MoneyBundle", "Junk", 0.5, { cash = 100 })
    local result = V.settle(record, { { info = bundle, count = 100 } })
    near(result.credits, 1000000, 1e-9)
    near(result.cashTrust, 50, 1e-9)
    near(result.trust, 50, 1e-9, "100 bundles are $10,000: 200 trust uncapped, 50 capped")
    local shirt = info("Base.Shirt", "Clothing", 1.0)
    result = V.settle(record, { { info = bundle, count = 100 }, { info = shirt, count = 10 } })
    near(result.trust, 50 + 40, 1e-9, "the cap is on cash only")
end)

test("the request bonus covers the first 20 units of an item", function()
    local c = ctx({ requests = { ["Base.Shirt"] = true }, requestBonus = 0.65 })
    local shirt = info("Base.Shirt", "Clothing", 1.0)
    local one = V.appraise(shirt, c)
    near(one.credits, 400 * 1.65, 1e-9)
    truthy(one.marks.request)
    local line = V.appraiseLine(shirt, 30, c)
    near(line.credits, 400 * (30 + 0.65 * 20), 1e-6, "20 with the bonus, 10 without")
    eq(line.requestUnits, 20)
    near(line.trust, 4 * 30, 1e-9, "trust has no bonus")
    c.requestUsed["Base.Shirt"] = 15
    line = V.appraiseLine(shirt, 30, c)
    eq(line.requestUnits, 5, "15 were used this week")
    c.requestUsed["Base.Shirt"] = 20
    line = V.appraiseLine(shirt, 3, c)
    eq(line.requestUnits, 0)
    truthy(not line.marks.request)
end)

test("an item that is not on the list gets no bonus", function()
    local c = ctx({ requests = { ["Base.Pan"] = true } })
    local a = V.appraise(info("Base.Shirt", "Clothing", 1.0), c)
    near(a.credits, 400, 1e-9)
    truthy(not a.marks.request)
end)

test("a new region pays +25% on the first 30 weight of a cell", function()
    local c = ctx()
    local shirt = info("Base.Shirt", "Clothing", 1.0, { cell = "3,4" })
    local line = V.appraiseLine(shirt, 20, c)
    near(line.credits, 400 * 20 * 1.25, 1e-6, "20 weight, all inside 30")
    near(line.regionWeight, 20, 1e-9)
    truthy(line.marks.newRegion)
    line = V.appraiseLine(shirt, 40, c)
    near(line.credits, 400 * (40 + 0.25 * 30), 1e-6, "30 of 40 units")
    near(line.regionWeight, 30, 1e-9)
    c.cellUsed["3,4"] = 25
    line = V.appraiseLine(shirt, 40, c)
    near(line.credits, 400 * (40 + 0.25 * 5), 1e-6, "5 weight left in the cell")
    c.cellUsed["3,4"] = 30
    line = V.appraiseLine(shirt, 40, c)
    near(line.credits, 400 * 40, 1e-6)
    truthy(not line.marks.newRegion)
end)

test("a heavy unit takes the premium for the part of it that fits", function()
    local c = ctx()
    local anvil = info("Base.Anvil", "Tool", 12.0, { cell = "0,0" })
    local line = V.appraiseLine(anvil, 3, c)
    -- 30 weight fits two whole anvils (24) and 6/12 of the third.
    near(line.credits, 12 * 300 * (3 + 0.25 * (2 + 0.5)), 1e-6)
    near(line.regionWeight, 30, 1e-9)
    local single = V.appraise(anvil, ctx({ cellUsed = { ["0,0"] = 24 } }))
    near(single.credits, 12 * 300 * (1 + 0.25 * 0.5), 1e-6, "6 of 12 weight left")
end)

test("the request bonus and the new region multiply", function()
    local c = ctx({ requests = { ["Base.Shirt"] = true }, requestBonus = 0.5 })
    local shirt = info("Base.Shirt", "Clothing", 1.0, { cell = "9,9" })
    local a = V.appraise(shirt, c)
    near(a.credits, 400 * 1.5 * 1.25, 1e-9)
    local line = V.appraiseLine(shirt, 40, c)
    -- 40 units: first 20 with the bonus; the first 30 in the region. Units 1..20 have both, 21..30 the region only.
    near(line.credits, 400 * (20 * 1.5 * 1.25 + 10 * 1.25 + 10), 1e-6)
end)

test("an item with no cell tag has no region bonus", function()
    local a = V.appraise(info("Base.Shirt", "Clothing", 1.0), ctx())
    truthy(not a.marks.newRegion)
end)

test("a refused category is marked and still valued", function()
    local c = ctx({ refused = { B = true } })
    local a = V.appraise(info("Base.Shirt", "Clothing", 1.0), c)
    truthy(a.marks.refused)
    near(a.credits, 400, 1e-9)
end)

test("what the box takes, and why not", function()
    truthy(V.accepts(info("Base.Shirt", "Clothing", 1)))
    truthy(V.accepts(info("Base.Money", "Junk", 0.01, { cash = 1 })))
    truthy(V.accepts(info("OperationAcorn.SampleBundle", "Junk", 0.1, { own = "SampleBundle" })))
    truthy(V.accepts(info("OperationAcorn.MeteorFragment", "Material", 1, { own = "MeteorFragment" })))
    local ok, why = V.accepts(info("OperationAcorn.CureSerum", "FirstAid", 0.1, { own = "CureSerum" }))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Own")
    ok, why = V.accepts(info("Base.Bullets9mm", "Ammo", 0.01))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Ammo")
    ok, why = V.accepts(info("Base.Apple", "Food", 0.2, { food = "rotten" }))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Rotten")
    truthy(V.accepts(info("Base.Apple", "Food", 0.2, { food = "stale" })))
    ok, why = V.accepts(info("Base.Satchel", "Bag", 0.5, { filled = true }))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Filled")
    truthy(V.accepts(info("Base.Satchel", "Bag", 0.5, { filled = false })))
    ok, why = V.accepts(info("Base.Hammer", "Tool", 1, { bought = true }))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Bought")
    ok, why = V.accepts(info("Base.Sofa", "Furniture", 20, { moveable = true }))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Furniture")
    ok, why = V.accepts(info("Base.LargeMeteorite", "Memento", 5))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Meteor")
end)

test("this mod's taken goods have fixed values and ignore the market", function()
    local c = ctx({ index = { K = 2.0 }, rate = 1.1, trustAccel = 1.1 })
    local frag = V.appraise(info("OperationAcorn.MeteorFragment", "Material", 1, { own = "MeteorFragment" }), c)
    near(frag.credits, 30000 * 1.1, 1e-6)
    near(frag.trust, 10 * 1.1, 1e-9)
    local expired = V.appraise(info("OperationAcorn.Note", "Junk", 0.1, { own = "ExpiredMission" }), c)
    near(expired.credits, 1100, 1e-6)
    near(expired.trust, 5.5, 1e-9)
    local mission = V.appraise(info("OperationAcorn.Note", "Junk", 0.1, { own = "MissionItem" }), c)
    eq(mission.credits, 0)
end)

test("a whole flight is rounded once", function()
    local record = OA.Store.ensure("r", "R")
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    -- 7 pencils of weight 0.01 in category E: 0.01 * 350 = 3.5 credits each, 24.5 together.
    local pencil = info("Base.Pencil", "Junk", 0.01)
    local lines = {}
    for i = 1, 7 do lines[i] = { info = pencil, count = 1 } end
    local result = V.settle(record, lines)
    eq(result.credits, 25, "24.5 rounds to 25 once; seven rounded 3.5s would be 28")
    near(result.trust, 7 * 0.035, 1e-9)
    eq(#result.lines, 7)
end)

test("settle uses the record's rate and the sandbox multiplier", function()
    SandboxVars.OperationAcorn.CreditMultiplier = 2.0
    local record = OA.Store.ensure("m", "M")
    OA.Trust.add(record, 5500)           -- stage 3: rate +5%
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    OA.Market.state()
    for _, c in ipairs(OA.Categories.LETTERS) do OA.Market.state().M[c] = 1.0 end
    local index = OA.Market.index("B")
    local result = V.settle(record, { { info = info("Base.Shirt", "Clothing", 1.0), count = 1 } })
    near(result.credits, 400 * 1.05 * 2.0 * index, 0.5, "rate")
end)

test("settle sends the weight to the market and uses up the premiums", function()
    local record = OA.Store.ensure("s", "S")
    OA.Requests.install({ version = 1, types = { "Base.Shirt" }, score = { 2.0 },
        kinds = { Shirt = "B" }, total = { B = 1 }, n = 1 })
    OA.randomFloat = function() return 0 end
    OA.Market.update(OA.day())
    for _, c in ipairs(OA.Categories.LETTERS) do OA.Market.state().M[c] = 1.0 end
    eq(OA.Requests.list(record)[1], "Base.Shirt")
    local shirt = info("Base.Shirt", "Clothing", 1.0, { cell = "1,1" })
    local before = OA.Market.index("B")
    local result = V.settle(record, { { info = shirt, count = 30 }, { info = shirt, count = 10 } })
    -- 40 shirts: the first 20 with the request bonus (+50%) and the first 30 in the region (+25%).
    local expected = 400 * before * (20 * 1.5 * 1.25 + 10 * 1.25 + 10)
    near(result.credits, OA.round(expected), 0.5)
    near(OA.Market.state().S.B, 0.97 ^ 4, 1e-9, "40 weight shipped")
    eq(OA.Requests.used(record)["Base.Shirt"], 20)
    near(record.codex.cells["1,1"], 30, 1e-9)
    -- A second flight: the premiums are used up.
    local price = 400 * OA.Market.index("B")
    local second = V.settle(record, { { info = shirt, count = 10 } })
    near(second.credits, 10 * price, 0.5, "no bonus, no region left")
end)

test("the context is cached for the day and follows the market live", function()
    local record = OA.Store.ensure("x", "X")
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    OA.randomFloat = function() return 0 end
    OA.Market.update(OA.day())
    local c = V.context(record)
    eq(V.context(record), c, "the same table within the day")
    near(c.index.A, 1.0, 1e-6)
    OA.Market.ship("A", 100)
    near(c.index.A, 0.97 ^ 10, 1e-6, "the cached context sees the new supply")
    TEST.hours = 30
    truthy(V.context(record) ~= c, "a new day, a new table")
    near(c.rate, 1.0)
end)
