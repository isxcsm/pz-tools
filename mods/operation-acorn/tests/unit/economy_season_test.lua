-- The seasons by month and what they want (NUMBERS 2, DESIGN-terminal 5.3).
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Season"
local OA = OperationAcorn
local S = OA.Season

test("the months make the seasons: December to February winter, then spring, summer, autumn", function()
    local want = { "winter", "winter", "spring", "spring", "spring", "summer", "summer", "summer", "autumn", "autumn",
        "autumn", "winter" }
    for month = 1, 12 do eq(S.of(month), want[month], "month " .. month) end
end)

test("the month is the game's, counted from 1 (the game counts from 0)", function()
    TEST.month = 0
    eq(S.month(), 1); eq(S.current(), "winter")
    TEST.month = 6
    eq(S.month(), 7); eq(S.current(), "summer")
    TEST.month = 11
    eq(S.month(), 12); eq(S.current(), "winter")
end)

test("the weights: winter B x3 F x2, spring H x3 K x2, summer I x3 C x2, autumn A x3 H x2, the rest 1", function()
    local want = {
        winter = { B = 3, F = 2 }, spring = { H = 3, K = 2 }, summer = { I = 3, C = 2 }, autumn = { A = 3, H = 2 },
    }
    for season, weights in pairs(want) do
        for _, c in ipairs(OA.Categories.LETTERS) do
            eq(S.weight(season, c), weights[c] or 1, season .. " " .. c)
            eq(S.raised(season, c), weights[c] ~= nil)
        end
    end
    eq(S.weight("nowhere", "A"), 1)
end)

test("the keys of the lines and the names", function()
    eq(S.lineKey("winter", "B", 2), "IGUI_OA_Econ_Season_winter_B_2")
    eq(S.nameKey("autumn"), "IGUI_OA_Econ_SeasonName_autumn")
    truthy(S.isLineKey("IGUI_OA_Econ_Season_winter_B_2"))
    truthy(not S.isLineKey("IGUI_OA_Econ_Event_Demand"))
    truthy(not S.isLineKey(nil))
end)

test("every raised category has its lines in both languages' keys: 16 in all", function()
    local n = 0
    for _, season in ipairs(S.NAMES) do
        for _, c in ipairs(OA.Categories.LETTERS) do
            if S.raised(season, c) then n = n + S.LINES end
        end
    end
    eq(n, 16)
end)

test("pickOther skips the categories the season raises", function()
    for pick = 1, 9 do
        local c = S.pickOther(OA.Categories.LETTERS, "summer", function(a, b) return math.min(pick, b) end)
        truthy(c ~= "I" and c ~= "C")
    end
end)
