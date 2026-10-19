-- Value: the formulas of NUMBERS 1, the state factor, cash, the fixed request prices and the new-region bonus, one
-- rounding a flight.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
local OA = OperationAcorn
local V = OA.Value
-- The request lines here are by item type: no generated groups.
OA.Requests.useGroups({})

local function info(fullType, display, weight, extra)
    local t = { fullType = fullType, baseType = OA.Categories.baseType(fullType), weight = weight,
        displayCategory = display }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

-- The rules below are shown on a thing of category B at B's own unit, 400 (an accessory; worn clothes have their own
-- unit, and their test).

-- A plain context: index 1 everywhere, no premiums.
local function ctx(extra)
    local c = { rate = 1.0, trustAccel = 1.0, index = {}, refused = {}, requests = {},
        requestUsed = {}, cellUsed = {} }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

test("the example box: 20 clothing, 10 documents, 10 household, 10 food is 12,500 credits and 125 trust", function()
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
    near(credits, 2000 + 4500 + 3500 + 2500, 1e-6)
    near(trust, 125, 1e-6)
end)

test("worn clothes go at 100 a weight; the rest of their category (accessories, protective gear) at B's 400", function()
    near(V.appraiseLine(info("Base.Shirt", "Clothing", 1.0), 1, ctx()).credits, 100, 1e-9)
    near(V.appraiseLine(info("Base.Shirt", "Clothing", 1.0), 1, ctx()).trust, 1, 1e-9)
    near(V.appraiseLine(info("Base.Hat_GasMask", "ProtectiveGear", 1.0), 1, ctx()).credits, 400, 1e-9)
    near(V.appraiseLine(info("Base.Necklace", "Accessory", 1.0), 1, ctx()).credits, 400, 1e-9)
    -- the market's index is the category's (B) for both
    local c = ctx({ index = { B = 2.0 } })
    near(V.appraiseLine(info("Base.Shirt", "Clothing", 1.0), 1, c).credits, 200, 1e-9)
end)

test("a box of sample bundles: 50 of them are 30,000 credits and 300 trust", function()
    local line = V.appraiseLine(info("OperationAcorn.SampleBundle", "Junk", 1.0, { own = "SampleBundle" }), 50, ctx())
    near(line.credits, 30000, 1e-6)
    near(line.trust, 300, 1e-6)
end)

test("the call for samples (an event on \"samples\") raises the bundles' credits, not their trust", function()
    local c = ctx({ index = { samples = 1.25 } })
    local line = V.appraiseLine(info("OperationAcorn.SampleBundle", "Junk", 1.0, { own = "SampleBundle" }), 2, c)
    near(line.credits, 1500, 1e-6)
    near(line.trust, 12, 1e-6)
    line = V.appraiseLine(info("OperationAcorn.SelectedSample", "Material", 0.5, { own = "SelectedSample" }), 1, c)
    near(line.credits, 1500, 1e-6)
    line = V.appraiseLine(info("OperationAcorn.TissueCommon", "Junk", 0.1, { own = "TissueCommon" }), 1, c)
    near(line.credits, 200, 1e-6, "a zombie sample is not what the call asks for")
end)

test("a selected sample is worth two sample bundles", function()
    local line = V.appraiseLine(info("OperationAcorn.SelectedSample", "Material", 0.5, { own = "SelectedSample" }), 3,
        ctx())
    near(line.credits, 3600, 1e-6)
    near(line.trust, 36, 1e-6)
end)

test("the market index multiplies credits and never trust", function()
    local c = ctx({ index = { B = 1.5 } })
    local a = V.appraise(info("Base.Shirt", "Accessory", 1.0), c)
    near(a.credits, 600, 1e-9)
    near(a.trust, 4.0, 1e-9)
    eq(a.category, "B")
    truthy(a.marks.high)
    c.index.B = 0.5
    a = V.appraise(info("Base.Shirt", "Accessory", 1.0), c)
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
    local a = V.appraise(info("Base.Shirt", "Accessory", 1.0), c)
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
    local shirt = info("Base.Shirt", "Accessory", 1.0)
    result = V.settle(record, { { info = bundle, count = 100 }, { info = shirt, count = 10 } })
    near(result.trust, 50 + 40, 1e-9, "the cap is on cash only")
end)

-- A request line as Requests.entries gives it: a common item, 600 a unit, 10 a week, trust 5 for a full line.
local function request(extra)
    local r = { band = "common", price = 600, qty = 10, trust = 5 }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

test("a request item is bought at its fixed price for the first units of the week", function()
    local c = ctx({ requests = { ["Base.Shirt"] = request() } })
    local shirt = info("Base.Shirt", "Accessory", 1.0)
    local one = V.appraise(shirt, c)
    near(one.credits, 600, 1e-9, "not the 400 of its weight")
    truthy(one.marks.request)
    local line = V.appraiseLine(shirt, 14, c)
    near(line.credits, 10 * 600 + 4 * 400, 1e-6, "10 at the fixed price, 4 by weight")
    eq(line.requestUnits, 10)
    near(line.requestCredits, 6000, 1e-6)
    near(line.trust, 4 * 14, 1e-9, "trust is by weight, the request adds none")
    near(line.marketWeight, 4, 1e-9, "only the other units go to the market")
    c.requestUsed["Base.Shirt"] = 7
    line = V.appraiseLine(shirt, 5, c)
    eq(line.requestUnits, 3, "7 of the 10 were settled this week")
    near(line.credits, 3 * 600 + 2 * 400, 1e-6)
    c.requestUsed["Base.Shirt"] = 10
    line = V.appraiseLine(shirt, 3, c)
    eq(line.requestUnits, 0)
    truthy(not line.marks.request)
    near(line.credits, 3 * 400, 1e-6)
end)

test("a request price ignores the weight and the market, but not the state or the rate", function()
    local c = ctx({ requests = { ["Base.Hammer"] = request({ price = 1500, qty = 5, band = "normal" }) },
        rate = 1.05 })
    c.index.H = 1.8
    local hammer = info("Base.Hammer", "Tool", 1.0, { condition = 0.5 })
    near(V.appraise(hammer, c).credits, 1500 * 0.75 * 1.05, 1e-9, "state 0.75, rate 1.05, no index")
    local heavy = info("Base.Hammer", "Tool", 2.0, { condition = 1.0 })
    near(V.appraise(heavy, c).credits, 1500 * 1.05, 1e-9, "heavier is not worth more (2 x 300 x 1.8 is less)")
    local other = info("Base.Saw", "Tool", 1.0)
    near(V.appraise(other, c).credits, 300 * 1.8 * 1.05, 1e-9, "a thing off the list keeps the index")
end)

test("a request unit never fetches less than it would unrequested at the day's index", function()
    -- A television (10 weight of electronics, G 600 a weight) is worth 6,000; the common line's 600 would be a tenth.
    local c = ctx({ requests = { ["Base.TvBlack"] = request() }, rate = 1.0 })
    local tv = info("Base.TvBlack", "Communications", 10.0)
    local line = V.appraiseLine(tv, 2, c)
    eq(line.requestUnits, 2, "still the request's units: they count for the line")
    near(line.credits, 2 * 6000, 1e-9)
    c.index.G = 1.5
    near(V.appraiseLine(tv, 1, c).credits, 9000, 1e-9, "and at a high index the index's value")
end)

test("each kind of a group on the list is paid its own worth, not the dearest kind's", function()
    -- One line of a group that takes a television (6,000 by weight) and a shirt (400): base 600, reward x1.1.
    OA.Requests.useGroups({ { id = "mixed", score = 1, wt = 10, dc = "Communications",
        items = { "Base.TvBlack", "Base.Shirt" } } })
    local c = ctx({ requests = { mixed = request({ price = 660, base = 600, mult = 1.1 }) } })
    local taken = { requests = {}, cells = {} }
    local shirt = V.appraiseLine(info("Base.Shirt", "Accessory", 1.0), 2, c, taken)
    eq(shirt.requestUnits, 2)
    near(shirt.requestCredits, 2 * 660, 1e-9, "the shirt at the line's price, not the television's")
    eq(shirt.requestPrice, 660)
    taken.requests.mixed = 2
    local tv = V.appraiseLine(info("Base.TvBlack", "Communications", 10.0), 1, c, taken)
    near(tv.requestCredits, 6600, 1e-9, "the television at its own worth times the reward")
    c.index.G = 1.5
    near(V.appraiseLine(info("Base.TvBlack", "Communications", 10.0), 1, c, taken).requestCredits, 9000, 1e-9,
        "never less than unrequested at the day's index")
    near(V.appraiseLine(info("Base.Shirt", "Accessory", 1.0), 1, c, taken).requestCredits, 660, 1e-9,
        "the shirt's own 400 stays under the line's price")
end)

test("a crafted twin fills the request of its group: wood charcoal for charcoal", function()
    OA.Requests.useGroups({ { id = "base:charcoal", score = 1, wt = 0.8, dc = "Material",
        items = { "Base.Charcoal", "Base.Coke", "Base.CharcoalCrafted" } } })
    local c = ctx({ requests = { ["base:charcoal"] = request() } })
    local looted = V.appraiseLine(info("Base.Charcoal", "Material", 0.8), 4, c, { requests = {}, cells = {} })
    eq(looted.requestKey, "base:charcoal")
    eq(looted.requestUnits, 4)
    local taken = { requests = { ["base:charcoal"] = 4 }, cells = {} }
    local crafted = V.appraiseLine(info("Base.CharcoalCrafted", "Material", 0.8), 12, c, taken)
    eq(crafted.requestKey, "base:charcoal")
    eq(crafted.requestUnits, 6, "the group's ten units a week are shared by its kinds")
    near(crafted.requestCredits, 6 * 600, 1e-9)
end)

test("an item that is not on the list gets no request price", function()
    local c = ctx({ requests = { ["Base.Pan"] = request() } })
    local a = V.appraise(info("Base.Shirt", "Accessory", 1.0), c)
    near(a.credits, 400, 1e-9)
    truthy(not a.marks.request)
end)

test("a line made full gives its trust once", function()
    local c = ctx({ requests = { ["Base.Shirt"] = request(), ["Base.Pan"] = request({ trust = 10, band = "normal" }) } })
    local fills = V.requestFills(c, { requests = { ["Base.Shirt"] = 10 } })
    eq(#fills.fills, 1); eq(fills.trust, 5); eq(fills.fills[1].fullType, "Base.Shirt")
    eq(fills.fills[1].band, "common")
    c.requestUsed["Base.Shirt"] = 8
    fills = V.requestFills(c, { requests = { ["Base.Shirt"] = 2, ["Base.Pan"] = 4 } })
    eq(#fills.fills, 1, "8 and 2 fill the shirts, 4 of 10 do not fill the pans")
    eq(fills.trust, 5)
    c.requestUsed["Base.Shirt"] = 10
    fills = V.requestFills(c, { requests = { ["Base.Shirt"] = 0 } })
    eq(#fills.fills, 0, "a line already full gave its trust")
    eq(V.requestFills(c, { requests = {} }).trust, 0)
    c.requestUsed["Base.Pan"] = 6
    fills = V.requestFills(c, { requests = { ["Base.Pan"] = 4 } })
    eq(fills.trust, 10, "a normal line gives 10")
end)

test("a new region pays +25% on the first 30 weight of a cell", function()
    local c = ctx()
    local shirt = info("Base.Shirt", "Accessory", 1.0, { cell = "3,4" })
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

test("the request units get no new-region premium, the other units do", function()
    local c = ctx({ requests = { ["Base.Shirt"] = request() } })
    local shirt = info("Base.Shirt", "Accessory", 1.0, { cell = "9,9" })
    local a = V.appraise(shirt, c)
    near(a.credits, 600, 1e-9, "no premium on a request unit")
    local line = V.appraiseLine(shirt, 40, c)
    -- 40 units: 10 request units at 600; the 30 others take the 30 weight of the region.
    near(line.credits, 10 * 600 + 400 * 30 * 1.25, 1e-6)
    near(line.regionWeight, 30, 1e-9, "the request units use none of the cell")
    line = V.appraiseLine(shirt, 20, c)
    near(line.credits, 10 * 600 + 400 * 10 * 1.25, 1e-6)
    near(line.regionWeight, 10, 1e-9)
end)

test("settle uses the record's rate and the sandbox multiplier", function()
    SandboxVars.OperationAcorn.CreditMultiplier = 2.0
    local record = OA.Store.ensure("m", "M")
    OA.Trust.add(record, 5500)           -- stage 3
    near(OA.Trust.rewards(record).rate, 0, 1e-9, "trust alone gives no rate")
    TEST.setSupportLevel(record, "rate", 1)   -- the upgrade: rate +5%
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    OA.Market.state()
    for _, c in ipairs(OA.Categories.LETTERS) do OA.Market.state().M[c] = 1.0 end
    local index = OA.Market.index("B")
    local result = V.settle(record, { { info = info("Base.Shirt", "Accessory", 1.0), count = 1 } })
    near(result.credits, 400 * 1.05 * 2.0 * index, 0.5, "rate")
end)

local function oneShirt()
    local record = OA.Store.ensure("s", "S")
    OA.Requests.install({ version = 1, types = { "Base.Shirt" }, score = { 2.0 },
        kinds = { Shirt = "B" }, total = { B = 1 }, n = 1 })
    OA.randomFloat = function() return 0 end
    OA.Market.update(OA.day())
    for _, c in ipairs(OA.Categories.LETTERS) do OA.Market.state().M[c] = 1.0 end
    -- This week's line takes 10 (the shirt alone would rank first and ask the band's most).
    OA.Requests.list(record)
    record.codex.req.qty["Base.Shirt"] = 10
    return record
end

test("settle sends the weight to the market and uses up the premiums", function()
    local record = oneShirt()
    eq(OA.Requests.list(record)[1], "Base.Shirt")
    local shirt = info("Base.Shirt", "Accessory", 1.0, { cell = "1,1" })
    local before = OA.Market.index("B")
    local result = V.settle(record, { { info = shirt, count = 30 }, { info = shirt, count = 10 } })
    -- 40 shirts: 10 are the week's request at 600 (no premium); the other 30 all take the region's +25%.
    local expected = 10 * 600 + 400 * before * 30 * 1.25
    near(result.credits, OA.round(expected), 0.5)
    near(OA.Market.state().S.B, 0.97 ^ 3, 1e-9, "the 30 other units are shipped, the request ones are not")
    eq(OA.Requests.used(record)["Base.Shirt"], 10)
    near(record.codex.cells["1,1"], 30, 1e-9)
    near(result.trust, 40 * 4 + 5, 1e-9, "trust by weight and 5 for the full line")
    eq(#result.filled, 1); eq(result.filled[1].fullType, "Base.Shirt"); eq(result.filled[1].trust, 5)
    -- A second flight: the request and the region are used up, the line gave its trust already.
    local price = 400 * OA.Market.index("B")
    local second = V.settle(record, { { info = shirt, count = 10 } })
    near(second.credits, 10 * price, 0.5, "no request, no region left")
    near(second.trust, 40, 1e-9)
    eq(#second.filled, 0)
end)

test("a line filled over two flights gives its trust on the second", function()
    local record = oneShirt()
    local shirt = info("Base.Shirt", "Accessory", 1.0)
    local first = V.settle(record, { { info = shirt, count = 6 } })
    eq(#first.filled, 0); near(first.trust, 24, 1e-9)
    local price = 400 * OA.Market.index("B")
    local second = V.settle(record, { { info = shirt, count = 6 } })
    eq(#second.filled, 1, "6 and 6 pass the 10")
    near(second.trust, 24 + 5, 1e-9)
    near(second.credits, 4 * 600 + 2 * price, 0.5)
end)

test("a new week starts the request counters again", function()
    local record = oneShirt()
    local shirt = info("Base.Shirt", "Accessory", 1.0)
    V.settle(record, { { info = shirt, count = 10 } })
    eq(OA.Requests.entry(record, "Base.Shirt").left, 0)
    TEST.hours = 24 * 7 + 2
    V.reset()
    local qty = OA.Requests.qtyOf("Base.Shirt")
    eq(OA.Requests.entry(record, "Base.Shirt").left, qty, "the week's counters were drawn anew, at the table's quantity")
    local result = V.settle(record, { { info = shirt, count = qty } })
    eq(#result.filled, 1, "and the line can be filled again")
end)

test("the cached context follows the rewards: a new request price level reaches the next appraisal", function()
    local record = oneShirt()
    local shirt = info("Base.Shirt", "Accessory", 1.0)
    near(V.appraise(shirt, V.context(record)).credits, 600, 1e-9)
    TEST.setSupportLevel(record, "reqprice", 1)
    near(V.appraise(shirt, V.context(record)).credits, 660, 1e-9, "x1.1 the same day")
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
