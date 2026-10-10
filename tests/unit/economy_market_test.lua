-- The market: M random walk, S supply, E events, the clamp, history, refusals and the stage events.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Market"
local OA = OperationAcorn
local M = OA.Market

-- Fixed noise and picks: randomFloat returns `noise`, random takes the low end.
local noise = 0
local function fix()
    noise = 0
    OA.randomFloat = function(a, b) return noise end
    OA.random = function(a, b) return a end
end

test("a new market starts at 1 for every category", function()
    fix()
    for _, c in ipairs(OA.Categories.LETTERS) do near(M.index(c), 1.0, 1e-9, c) end
    near(M.index("nothing"), 1.0)
end)

test("M walks back toward 1 and stays inside 0.70..1.30", function()
    fix()
    M.update(0)
    local st = M.state()
    noise = 0.05
    st.M.A = 1.0
    M.update(1)
    near(st.M.A, 1.05, 1e-9, "1 + 0.10*0 + 0.05")
    M.update(2)
    near(st.M.A, 1.05 + 0.1 * (1 - 1.05) + 0.05, 1e-9, "second day")
    for d = 3, 60 do M.update(d) end
    near(st.M.A, 1.30, 1e-9, "noise of +0.05 forever sits on the cap")
    noise = -0.05
    for d = 61, 200 do M.update(d) end
    near(st.M.A, 0.70, 1e-9, "the low cap")
end)

test("noise zero: the market stays at 1", function()
    fix()
    M.update(0)
    for d = 1, 20 do M.update(d) end
    near(M.state().M.G, 1.0, 1e-9)
end)

test("shipping lowers the supply by 0.97 per 10 weight, to a floor of 0.40", function()
    fix()
    M.update(0)
    M.ship("A", 50)
    near(M.state().S.A, 0.97 ^ 5, 1e-9)
    near(M.index("A"), 0.8587, 1e-3, "50 weight is 0.86")
    M.ship("B", 200)
    near(M.state().S.B, 0.97 ^ 20, 1e-9)
    near(M.state().S.B, 0.54, 0.01, "200 weight is 0.54")
    M.ship("B", 100000)
    near(M.state().S.B, 0.40, 1e-9, "floor")
    M.ship("C", 0)
    near(M.state().S.C, 1.0, 1e-9, "nothing shipped")
    M.ship("C", -5)
    near(M.state().S.C, 1.0, 1e-9, "negative")
end)

test("the softer supply reward turns 0.97 into 0.9775", function()
    fix()
    M.update(0)
    local record = { id = "r", trade = { stage = 4, milestones = 0, levels = { softer = 1 } } }
    M.ship("A", 10, record)
    near(M.state().S.A, 0.9775, 1e-9)
    local plain = { id = "p", trade = { stage = 3, milestones = 0 } }
    M.ship("B", 10, plain)
    near(M.state().S.B, 0.97, 1e-9)
end)

test("the softer supply is a flight support upgrade: the stage alone does not bring it", function()
    fix()
    M.update(0)
    local record = { id = "r", trade = { stage = 5, milestones = 2 } }
    M.ship("A", 10, record)
    near(M.state().S.A, 0.97, 1e-9, "stage 5 without the level")
end)

test("the supply recovers 0.03 a day up to 1", function()
    fix()
    M.update(0)
    M.state().S.A = 0.5
    M.update(1)
    near(M.state().S.A, 0.53, 1e-9)
    for d = 2, 40 do M.update(d) end
    near(M.state().S.A, 1.0, 1e-9)
end)

test("one event per category: the largest raise, a glut only alone", function()
    fix()
    M.update(0)
    M.addEvent("A", 1.25, 5, "k")
    M.addEvent("A", 1.5, 5, "k")
    M.addEvent("A", 0.8, 5, "k")
    near(M.index("A"), 1.5, 1e-9, "the larger raise wins, not the product")
    M.addEvent("B", 0.8, 5, "k")
    near(M.index("B"), 0.8, 1e-9, "a glut alone")
    M.addEvent("B", 0.8, 5, "k")
    near(M.index("B"), 0.8, 1e-9, "two gluts do not stack")
end)

test("the index is clamped to 0.3..2.0", function()
    fix()
    M.update(0)
    local st = M.state()
    st.M.A, st.S.A = 1.3, 1.0
    M.addEvent("A", 1.5, 5, "k")
    near(M.index("A"), 1.95, 1e-9, "the top of the unclamped range")
    M.addEvent("A", 3.0, 5, "k")
    near(M.index("A"), 2.0, 1e-9, "clamped above")
    st.M.B, st.S.B = 0.7, 0.4
    M.addEvent("B", 0.8, 5, "k")
    near(M.index("B"), 0.3, 1e-9, "0.7*0.4*0.8 = 0.224 clamped below")
end)

test("events end on their day", function()
    fix()
    M.update(0)
    M.addEvent("D", 1.3, 14, "k")
    M.update(13)
    near(M.index("D"), 1.3, 1e-9, "still on day 13")
    M.update(14)
    near(M.index("D"), 1.0, 1e-9, "over on day 14")
end)

test("entering a stage raises the categories the team wants for 14 days", function()
    fix()
    M.update(0)
    M.stageEvent(1)
    near(M.index("B"), 1.3, 1e-9); near(M.index("G"), 1.3, 1e-9); near(M.index("A"), 1.0, 1e-9)
    M.stageEvent(3)
    near(M.index("D"), 1.3, 1e-9)
    M.stageEvent(4)
    near(M.index("I"), 1.3, 1e-9); near(M.index("J"), 1.3, 1e-9)
end)

test("stage 2 brings the filter story event on top (the larger raise wins)", function()
    fix()
    M.update(0)
    M.stageEvent(2)
    near(M.index("B"), 1.5, 1e-9, "B x1.5 beats x1.3")
    near(M.index("G"), 1.3, 1e-9)
    M.update(10)
    near(M.index("B"), 1.3, 1e-9, "the filter event is 10 days, the stage event 14")
    M.update(14)
    near(M.index("B"), 1.0, 1e-9)
end)

test("listeners hear the events", function()
    fix()
    local heard = {}
    M.listen(function(e) table.insert(heard, e) end)
    M.update(0)
    M.stageEvent(1)
    eq(#heard, 2)
    eq(heard[1].kind, "stage")
end)

test("random demand comes every 10 to 15 days, a glut one time in three", function()
    fix()
    M.update(0)
    local st = M.state()
    eq(st.nextDemand, 10, "first demand day 10 with the low roll")
    for d = 1, 9 do M.update(d) end
    eq(#st.events, 0)
    M.update(10)
    eq(#st.events, 1)
    local e = st.events[1]
    eq(e.cat, "A", "low pick is the first category")
    eq(e.mult, 0.8, "random(1,3)==1 is the glut")
    eq(e.ends, 15)
    eq(st.nextDemand, 20)
    OA.random = function(a, b) return b end
    M.update(20)
    eq(st.events[#st.events].mult, 1.25, "a high roll is demand")
end)

test("refusals start with the first stage and come back as a request", function()
    fix()
    M.update(0)
    local st = M.state()
    eq(st.nextRefusal, 20)
    for d = 1, 25 do M.update(d) end
    eq(OA.isEmpty(st.refused), true, "no refusals at stage 0")
    OA.Store.ensure("p", "P")
    OA.Store.player("p").trade = { stage = 1 }
    st.nextRefusal = 26
    for d = 26, 27 do M.update(d) end
    truthy(M.refused("A"), "category A is refused for a week")
    eq(st.refused.A, 33)
    eq(#st.due, 1)
    eq(st.due[1].day, 33 + 14, "returns 14..21 days after the refusal ends")
    for d = 28, 33 do M.update(d) end
    truthy(not M.refused("A"), "over after 7 days")
    eq(#M.dueRequests(40, 50), 1)
    eq(#M.dueRequests(0, 30), 0)
end)

test("history keeps 30 days and folds the rest into totals", function()
    fix()
    M.update(0)
    for d = 1, 45 do M.update(d) end
    local list, totals = M.history("K")
    eq(#list, 30, "30 days")
    eq(list[#list].d, 45)
    truthy(totals ~= nil, "older days are totals")
    eq(totals.n, 46 - 30, "16 folded")
    near(totals.min, 1.0, 1e-9)
    near(totals.sum, totals.n * 1.0, 1e-9)
end)

test("a save away for months does not walk months of days", function()
    fix()
    M.update(0)
    M.update(500)
    local list, totals = M.history("K")
    eq(#list + (totals and totals.n or 0), 41, "40 catch-up steps and the first")
    eq(M.state().day, 500)
end)

test("forecast: the supply recovering points up, an ending event down", function()
    fix()
    M.update(0)
    eq(M.forecast("A"), "flat")
    M.state().S.A = 0.6
    eq(M.forecast("A"), "up")
    M.state().S.A = 1.0
    M.addEvent("B", 1.3, 1, "k")
    eq(M.forecast("B"), "down", "the event ends tomorrow")
    eq(M.forecast("nothing"), "flat")
end)

test("refused is false for an unknown category and with no refusal", function()
    fix()
    M.update(0)
    truthy(not M.refused("A"))
    truthy(not M.refused("ZZ"))
end)
