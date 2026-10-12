-- Place choices: the building for a regular mission, the candidate of a story mission, the map circle, the meteor
-- drop sites.
require "OperationAcorn/Core"
require "OperationAcorn/Story/Places"
local OA = OperationAcorn
local P = OA.Places

-- The harness's random numbers are too regular for spread tests: a small generator of our own (state stays far
-- below 2^53 so Kahlua's arithmetic is exact).
local function rng(seed)
    local state = seed
    return function(a, b)
        state = OA.remainder(state * 16807, 2147483647)
        return a + OA.remainder(math.floor(state / 7), b - a + 1)
    end
end

-- A fake map: a list of buildings along a diagonal.
local function buildings(n)
    local list = {}
    for i = 1, n do list[i] = { x = i * 10, y = i * 10 } end
    return list, function(i) local b = list[i]; return b.x, b.y end
end

test("a building comes from inside the band", function()
    local list, at = buildings(400)
    -- Anchor at the origin: the i-th is i * 14.14 away. Band 150..600 holds i = 11..42.
    for _ = 1, 30 do
        local i = P.pickBuilding(#list, at, 0, 0, 150, 600, nil, rng(2))
        local d = P.distance(list[i].x, list[i].y, 0, 0)
        truthy(d >= 150 and d <= 600, "in band: " .. d)
    end
end)

test("the scan finds a rare building the random picks miss", function()
    -- Only building 77 of 1000 is in the band: random picks usually miss, the scan must find it.
    local function at(i)
        if i == 77 then return 300, 0 end
        return 5000 + i, 5000
    end
    for _ = 1, 10 do eq(P.pickBuilding(1000, at, 0, 0, 150, 600, 5), 77) end
end)

test("with nothing in the band the building nearest to it is taken", function()
    local function at(i) return 1000 + i * 100, 0 end
    eq(P.pickBuilding(10, at, 0, 0, 150, 600, 5), 1)
end)

test("buildings that may not be used are skipped", function()
    local function at(i) return 300, 0, i == 3 end
    for _ = 1, 10 do eq(P.pickBuilding(10, at, 0, 0, 150, 600), 3) end
end)

test("the base itself is never a story candidate", function()
    local cands = { { x = 10, y = 0 }, { x = 400, y = 0 } }
    for _ = 1, 20 do
        local i, why = P.pickCandidate(cands, 0, 0, 150, 600)
        eq(i, 2); eq(why, "band")
    end
end)

test("a story candidate inside the band beats one outside", function()
    local cands = { { x = 100, y = 0 }, { x = 900, y = 0 }, { x = 300, y = 0 } }
    for _ = 1, 20 do eq(P.pickCandidate(cands, 0, 0, 150, 600), 3) end
end)

test("with none in the band the candidate nearest to the band is used", function()
    local cands = { { x = 900, y = 0 }, { x = 700, y = 0 }, { x = 2000, y = 0 } }
    local i, why = P.pickCandidate(cands, 0, 0, 150, 600)
    eq(i, 2); eq(why, "nearest")
    -- Below the band counts too: 60 is 90 under it, 800 is 200 over it.
    local c2 = { { x = 60, y = 0 }, { x = 800, y = 0 } }
    i, why = P.pickCandidate(c2, 0, 0, 150, 600)
    eq(i, 1); eq(why, "nearest")
end)

test("a far choice candidate ignores the band", function()
    local cands = { { x = 4000, y = 0 }, { x = 8000, y = 0 } }
    local seen = {}
    local int = rng(7)
    for _ = 1, 40 do
        local i, why = P.pickCandidate(cands, 0, 0, 150, 600, { ignoreBand = true }, int)
        eq(why, "any")
        seen[i] = true
    end
    truthy(seen[1] and seen[2], "both can come")
end)

test("when every candidate is the base the farthest is used", function()
    local cands = { { x = 10, y = 0 }, { x = 30, y = 0 } }
    local i, why = P.pickCandidate(cands, 0, 0, 150, 600)
    eq(i, 2); eq(why, "farthest")
end)

test("closed candidates are not offered", function()
    local cands = { { x = 300, y = 0, closed = true }, { x = 5000, y = 0 } }
    local i = P.pickCandidate(cands, 0, 0, 150, 600)
    eq(i, 2)
    eq(P.pickCandidate({ { x = 300, y = 0, closed = true } }, 0, 0, 150, 600), nil)
end)

test("the map circle holds the place, anywhere but its outer ring and not kept near the middle", function()
    local outer = 0
    for i = 1, 400 do
        local cx, cy, r = P.circle(1000, 2000, 60)
        local d = P.distance(cx, cy, 1000, 2000)
        truthy(d <= 60 * P.CIRCLE_OFF + 1.5, "inside the circle's inner part")
        if d > 60 * P.CIRCLE_OFF / 2 then outer = outer + 1 end
        eq(r, 60)
    end
    -- The same chance over the area: three quarters of the draws lie past half the offset.
    truthy(outer > 400 * 0.6, "the middle is no hint: " .. outer)
end)

test("drop sites are spaced over the map", function()
    local bounds = { minX = 0, minY = 0, maxX = 16000, maxY = 14000 }
    local sites, spacing = P.layoutSites(bounds, 24, 300, nil, nil, rng(11))
    eq(#sites, 24)
    eq(spacing, 300, "enough room, no relaxing")
    for i = 1, #sites do
        for j = i + 1, #sites do
            truthy(P.distance(sites[i].x, sites[i].y, sites[j].x, sites[j].y) >= 300, "apart")
        end
    end
end)

test("sites only land where the map accepts them", function()
    local bounds = { minX = 0, minY = 0, maxX = 16000, maxY = 14000 }
    local sites = P.layoutSites(bounds, 12, 300, function(x, y) return x < 8000 end, nil, rng(5))
    eq(#sites, 12)
    for _, s in ipairs(sites) do truthy(s.x < 8000, "on land") end
end)

test("a small map relaxes the spacing instead of failing", function()
    local bounds = { minX = 0, minY = 0, maxX = 1500, maxY = 1500 }
    local sites, spacing = P.layoutSites(bounds, 24, 300, nil, nil, rng(3))
    truthy(#sites >= 20, "most are placed: " .. #sites)
    truthy(spacing < 300, "spacing relaxed")
    truthy(spacing >= 100, "not below a third")
end)

test("existing sites stay and new ones keep apart from them", function()
    local bounds = { minX = 0, minY = 0, maxX = 5000, maxY = 5000 }
    local first = P.layoutSites(bounds, 3, 300, nil, nil, rng(9))
    local more = P.layoutSites(bounds, 6, 300, nil, first, rng(13))
    eq(#more, 6)
    for i = 1, 3 do eq(more[i], first[i]) end
    for i = 4, 6 do
        truthy(P.farEnough({ more[1], more[2], more[3] }, more[i].x, more[i].y, 300), "apart from old")
    end
end)

test("a compass point is one of eight, the game's y growing south", function()
    eq(P.bearing(0, 0, 10, 0), "E")
    eq(P.bearing(0, 0, 0, -10), "N")
    eq(P.bearing(0, 0, 10, -10), "NE")
    eq(P.bearing(0, 0, -10, 10), "SW")
    eq(P.bearing(5, 5, 5, 5), nil)
end)

test("where a place is: inside the area, close by, then metres and kilometres in steps", function()
    eq(P.whereKey(0, 0, 30, 0, 50), "IGUI_OA_Place_Inside")
    eq(P.whereKey(0, 0, 99, 0), "IGUI_OA_Place_Near")
    local key, args = P.whereKey(0, 0, 0, -340)
    eq(key, "IGUI_OA_Place_Metres")
    eq(args[1], "IGUI_OA_Place_Dir_N")
    eq(args[2], "350", "50 m steps")
    key, args = P.whereKey(0, 0, 990, 0)
    eq(key, "IGUI_OA_Place_Km", "a round kilometre is told in kilometres")
    eq(args[2], "1.0")
    key, args = P.whereKey(0, 0, 1700, 1700)
    eq(key, "IGUI_OA_Place_Km")
    eq(args[1], "IGUI_OA_Place_Dir_SE")
    eq(args[2], "2.4", "0.1 km steps")
    key, args = P.whereKey(0, 0, -9970, 0)
    eq(args[2], "10", "from 10 km whole kilometres")
    key, args = P.whereKey(0, 0, 12400, 0)
    eq(args[2], "12")
end)
