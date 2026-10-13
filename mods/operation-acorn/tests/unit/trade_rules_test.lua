-- The helicopter's rules: arrival times, the call interval, debt repayment, order payment, stage events, the first
-- supply plan.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
local OA = OperationAcorn
local Rules = OA.Trade.Rules

test("a day arrival keeps its time", function()
    -- 09:00, a call that takes 5 hours: 14:00.
    near(Rules.arrival(0, 9, 5, false, 1), 5)
    -- Exactly 07:00 is day, exactly 19:00 is night.
    near(Rules.arrival(0, 5, 2, false, 1), 2, 1e-9, "07:00")
    near(Rules.arrival(0, 15, 4, false, 0.5), 4 + 12 + 0.5, 1e-9, "19:00 goes to the next morning")
end)

test("a night arrival comes the next morning between 07 and 09", function()
    -- 16:00 plus 4 hours is 20:00: 07:00 the next day is 11 hours on, plus the spread.
    local arrive = Rules.arrival(10, 16, 4, false, 1.5)
    near(arrive, 10 + 4 + 11 + 1.5)
    near(Rules.timeOfDayAfter(16, arrive - 10), 8.5, 1e-9, "08:30")
    -- Early morning (03:00 at arrival) waits until 07:00 of the same morning.
    near(Rules.arrival(0, 23, 4, false, 0), 4 + 4, 1e-9, "03:00 to 07:00")
    -- The spread stays within 0 to 2 hours.
    near(Rules.arrival(0, 16, 4, false, 9), 4 + 11 + 2)
    near(Rules.arrival(0, 16, 4, false, -3), 4 + 11)
end)

test("the night drop reward lets the helicopter come at night", function()
    near(Rules.arrival(0, 16, 6, true, 1), 6)
end)

test("the delay is taken from the rewards' range", function()
    local got
    local function rnd(a, b) got = { a, b }; return a end
    eq(Rules.callDelay({ min = 3, max = 4 }, rnd), 3)
    eq(got[2], 4)
    eq(Rules.callDelay({ min = 5, max = 2 }, rnd), 5, "max below min")
end)

test("a call needs no pending call and the interval passed", function()
    local heli = {}
    eq(Rules.canCall(heli, 0), true)
    Rules.startCall(heli, 100, 105, 3, { kind = "normal" })
    eq(heli.next, 100 + 72)
    local ok, why = Rules.canCall(heli, 101)
    eq(ok, false)
    eq(why, "pending")
    heli.call = nil
    ok, why = Rules.canCall(heli, 150)
    eq(ok, false)
    eq(why, "wait", "interval counts from the call")
    eq(Rules.canCall(heli, 172), true)
    -- A shorter interval (1.5 days) is a plain number of hours.
    Rules.startCall(heli, 200, 204, 1.5, {})
    eq(heli.next, 236)
end)

test("a settlement repays a debt first", function()
    local balance, paid = Rules.applyGain(-300, 1000)
    eq(balance, 700)
    eq(paid, 300)
    balance, paid = Rules.applyGain(-300, 100)
    eq(balance, -200)
    eq(paid, 100)
    balance, paid = Rules.applyGain(50, 10)
    eq(balance, 60)
    eq(paid, 0)
    balance, paid = Rules.applyGain(-300, 0)
    eq(balance, -300)
    eq(paid, 0)
end)

-- A shop of three entries for the order tests. Prices rise by 10% of the base for each unit of "serum" bought.
local function fakeShop(options)
    options = options or {}
    local bought = {}
    local limit = options.limit or {}
    local entries = {
        a = { id = "a", base = 100 },
        b = { id = "b", base = 250 },
        serum = { id = "serum", base = 1000, rises = true },
    }
    local svc = {
        bought = {},
        entry = function(line) return entries[line.id] end,
        available = function(entry, line, delivered)
            if limit[entry.id] and (bought[entry.id] or 0) >= limit[entry.id] then return false, "limit" end
            return true
        end,
        price = function(entry)
            if entry.rises then return entry.base * (1 + 0.1 * (bought[entry.id] or 0)) end
            return entry.base
        end,
        bought = function(entry) bought[entry.id] = (bought[entry.id] or 0) + 1 end,
        items = function(entry) return { { type = "Base." .. entry.id, count = 1 } } end,
    }
    svc.counts = bought
    return svc
end

test("orders are paid in order", function()
    local svc = fakeShop()
    local balance, spent, results, items = Rules.payOrders(1000, {
        { id = "a", count = 3 }, { id = "b", count = 2 },
    }, svc)
    eq(balance, 1000 - 300 - 500)
    eq(spent, 800)
    eq(results[1].delivered, 3)
    eq(results[2].delivered, 2)
    eq(results[2].reason, nil)
    eq(#items, 5)
    eq(svc.counts.a, 3)
end)

test("a short balance gives a partial delivery with the reason", function()
    local svc = fakeShop()
    local balance, spent, results, items = Rules.payOrders(600, {
        { id = "a", count = 2 }, { id = "b", count = 3 }, { id = "a", count = 1 },
    }, svc)
    -- a x2 = 200, then b: 250 + 250 = 500 > 400 left: one b (250), then the last a (100) fits.
    eq(results[1].delivered, 2)
    eq(results[2].delivered, 1)
    eq(results[2].reason, "credits")
    eq(results[3].delivered, 1, "a cheaper line later still fits")
    eq(balance, 600 - 200 - 250 - 100)
    eq(spent, 550)
    eq(#items, 4)
end)

test("prices that rise with each unit are paid unit by unit", function()
    local svc = fakeShop()
    -- 1000 + 1100 + 1200 = 3300.
    local balance, spent, results = Rules.payOrders(3300, { { id = "serum", count = 3 } }, svc)
    eq(spent, 3300)
    eq(balance, 0)
    eq(results[1].delivered, 3)
    local _, spent2, results2 = Rules.payOrders(3299, { { id = "serum", count = 3 } }, fakeShop())
    eq(results2[1].delivered, 2)
    eq(spent2, 2100)
    eq(results2[1].reason, "credits")
end)

test("a debt pays no orders", function()
    local svc = fakeShop()
    local balance, spent, results, items = Rules.payOrders(-1, { { id = "a", count = 1 } }, svc)
    eq(balance, -1)
    eq(spent, 0)
    eq(results[1].reason, "debt")
    eq(results[1].delivered, 0)
    eq(#items, 0)
    eq(svc.counts.a, nil, "nothing was bought")
end)

test("a limit or an unknown entry is told in the result", function()
    local svc = fakeShop({ limit = { b = 1 } })
    local _, _, results = Rules.payOrders(10000, {
        { id = "b", count = 3 }, { id = "zzz", count = 1 }, { id = "a", count = 1 },
    }, svc)
    eq(results[1].delivered, 1)
    eq(results[1].reason, "limit")
    eq(results[2].reason, "unknown")
    eq(results[3].delivered, 1)
end)

test("the balance is not changed by free lines", function()
    local svc = fakeShop()
    svc.price = function() return 0 end
    local balance, spent = Rules.payOrders(0, { { id = "a", count = 2 } }, svc)
    eq(balance, 0)
    eq(spent, 0)
end)

test("stage events are read from the shapes OA.Trust.add may give", function()
    local events = Rules.stageEvents({ 2, { stage = 3 }, { milestone = 1 }, { kind = "milestone", n = 2 },
        { kind = "stage", stage = 4 }, "junk", { foo = 1 } })
    eq(#events, 5)
    eq(events[1].kind, "stage")
    eq(events[1].n, 2)
    eq(events[3].kind, "milestone")
    eq(events[5].n, 4)
    eq(#Rules.stageEvents(nil), 0)
end)

test("the first supply of a world with the vanilla helicopter", function()
    local function rnd(a, b) return a end
    -- Day 2: the vanilla window is on night 7, ending at 14.
    local plan = Rules.firstPlan({ option = 2, nights = 2, tod = 9, heliDay = 7, heliEnd = 14, rnd = rnd })
    eq(plan.mode, "window")
    eq(plan.day, 7)
    eq(plan.hour, 14)
    eq(Rules.firstDue(plan, 7, 13.9), false)
    eq(Rules.firstDue(plan, 7, 14), true)
    eq(Rules.firstDue(plan, 8, 2), true, "the next morning counts")
    eq(Rules.firstDue(plan, 6, 20), false)
end)

test("the first supply without a helicopter comes on the 7th day", function()
    local function rnd(a, b) return b end
    local plan = Rules.firstPlan({ option = 1, nights = 0, tod = 9, heliDay = 0, heliEnd = 0, rnd = rnd })
    eq(plan.mode, "none")
    eq(plan.day, 7)
    eq(plan.hour, 17)
    -- Joined on day 7 before the hour: still the 7th day.
    plan = Rules.firstPlan({ option = 1, nights = 7, tod = 10, heliDay = 0, heliEnd = 0, rnd = rnd })
    eq(plan.mode, "none")
    -- After the 7th day it is a late first supply.
    plan = Rules.firstPlan({ option = 1, nights = 8, tod = 10, heliDay = 0, heliEnd = 0, rnd = rnd })
    eq(plan.mode, "late")
end)

test("a mod added after the helicopter's day drops the next morning", function()
    local function rnd(a, b) return b end
    local plan = Rules.firstPlan({ option = 2, nights = 12, tod = 15, heliDay = 7, heliEnd = 14, rnd = rnd })
    eq(plan.mode, "late")
    eq(plan.day, 13)
    eq(plan.hour, 9)
    eq(Rules.firstDue(plan, 12, 23), false)
    eq(Rules.firstDue(plan, 13, 8.9), false)
    eq(Rules.firstDue(plan, 13, 9), true)
    -- A sometimes-helicopter already rescheduled to a day beyond the first possible: the first one is lost.
    plan = Rules.firstPlan({ option = 3, nights = 9, tod = 20, heliDay = 22, heliEnd = 15, rnd = rnd })
    eq(plan.mode, "late")
    -- The window of the day itself, already past: due at once.
    plan = Rules.firstPlan({ option = 4, nights = 8, tod = 20, heliDay = 8, heliEnd = 14, rnd = rnd })
    eq(plan.mode, "window")
    eq(Rules.firstDue(plan, 8, 20), true)
end)
