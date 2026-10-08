-- Mission rewards, deadlines judged at sealing, the sample cooler (NUMBERS 9).
require "OperationAcorn/Core"
require "OperationAcorn/Story/Rewards"
local OA = OperationAcorn
local R = OA.Rewards

test("levels follow the trust stage, six after a milestone", function()
    eq(R.level(0, 0), nil, "no missions before stage 1")
    eq(R.level(1, 0), 1)
    eq(R.level(4, 0), 4)
    eq(R.level(5, 0), 5)
    eq(R.level(5, 1), 6, "milestone")
    eq(R.level(5, 3), 6)
end)

test("bands and rewards come from the table", function()
    local lo, hi = R.band(1)
    eq(lo, 150); eq(hi, 600)
    lo, hi = R.band(6)
    eq(lo, 2000); eq(hi, 8000)
    local c, t = R.reward(1, false)
    eq(c, 10000); eq(t, 60)
    c, t = R.reward(3, false)
    eq(c, 35000); eq(t, 200)
    c, t = R.reward(2, true)
    eq(c, 30000, "story is x1.5"); eq(t, 180)
    c, t = R.reward(5, true)
    eq(c, 105000); eq(t, 600)
    c, t = R.reward(6, false)
    eq(c, 90000); eq(t, 500)
end)

test("the credit scale applies to credits only", function()
    local c, t = R.reward(1, false, 1, 2)
    eq(c, 20000); eq(t, 60)
end)

test("the deadline is judged when the box is sealed", function()
    eq(R.judge(100, 99.9), "ok")
    eq(R.judge(100, 100), "ok")
    eq(R.judge(100, 100.5), "late")
end)

test("the cooler warms by the hour and the reward slides", function()
    near(R.coolerTemp(0), 4)
    near(R.coolerTemp(4), 6)
    near(R.coolerTemp(1000), 30, 1e-9, "capped")
    near(R.coolerQuality(4), 1.0)
    near(R.coolerQuality(8), 1.0)
    near(R.coolerQuality(12), 0.8)
    near(R.coolerQuality(16), 0.6)
    near(R.coolerQuality(30), 0.6)
    eq(R.coolerGrade(7), "good")
    eq(R.coolerGrade(10), "warm")
    eq(R.coolerGrade(20), "bad")
    -- The cooler's reward at its worst: a 4th stage story mission.
    local c, t = R.reward(4, true, R.coolerQuality(30))
    eq(c, 45000); eq(t, 270)
end)
