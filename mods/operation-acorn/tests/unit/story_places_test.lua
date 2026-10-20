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

test("a plain building has plain rooms only: a house, an office, a church; not a shop, a diner, a story house", function()
    eq(P.plain({ "kitchen", "livingroom", "bedroom", "bathroom" }), true)
    eq(P.plain({ "office", "breakroom", "bathroom", "lobby" }), true)
    eq(P.plain({ "church", "officechurch", "bathroom" }), true)
    eq(P.plain({ "gasstore", "bathroom" }), false)
    eq(P.plain({ "pizzawhirled", "pizzakitchen" }), false)
    eq(P.plain({ "laundry", "vacated", "bathroom" }), true, "a laundromat's rooms are a house's")
    eq(P.plain({ "cultistbedroom", "kitchen" }), false)
    eq(P.plain({ "room1", "kitchen", "storage", "bathroom", "bathroom" }), false, "a diner named as a house")
    eq(P.plain({}), false)
end)

-- Story sites (Places.pickSite): a list as Game.sitesInBand gives it.
local function site(dist, area, rooms, home)
    return { x = dist, y = 0, dist = dist, area = area, rooms = rooms, home = home }
end

test("a public site is a public building of a few rooms first, then a house, then a smaller public one", function()
    local list = { site(100, 50, 1, false), site(200, 80, 4, false), site(300, 60, 6, true) }
    local int = rng(3)
    for _ = 1, 20 do eq(P.pickSite(list, "public", int), 2) end
    list[2].rooms = 2
    for _ = 1, 20 do eq(P.pickSite(list, "public", int), 3, "a house before a public one of few rooms") end
    eq(P.pickSite({ site(100, 50, 1, false) }, "public", int), 1, "a small public one when there is no house")
    eq(P.pickSite({}, "public", int), nil)
end)

test("the largest site is the largest public building, else the largest house", function()
    local list = { site(100, 50, 1, false), site(200, 300, 1, true), site(300, 90, 3, false) }
    eq(P.pickSite(list, "largest"), 3)
    eq(P.pickSite({ site(100, 50, 1, true), site(200, 70, 1, true) }, "largest"), 2)
end)

test("a building's rooms leave out the toilets and closets: a block of toilets has none", function()
    eq(P.mainRooms({ "bathroom", "bathroom", "bathroom", "janitor", "bathroom" }), 0)
    eq(P.mainRooms({ "office", "hall", "bathroom", "storageunit" }), 3)
end)

test("a house is one with a bedroom or a living room: a cabin without a bedroom too", function()
    eq(P.home({ "livingroom", "kitchen", "bathroom" }), true)
    eq(P.home({ "bedroom", "bathroom" }), true)
    eq(P.home({ "office", "kitchen", "bathroom" }), false)
    eq(P.home({ "church", "officechurch" }), false)
end)

test("a building mostly of lock-ups or sheds is taken last: no one was taken in there", function()
    eq(P.mostlyStores({ "garage", "garage", "storageunit" }), true)
    eq(P.mostlyStores({ "storageunit", "storageunit", "storageunit", "office", "hall" }), true, "a self-storage")
    eq(P.mostlyStores({ "garage", "office" }), false)
    eq(P.mostlyStores({ "garage", "kitchen", "bedroom", "bathroom" }), false, "a house with a garage")
    eq(P.mostlyStores({}), false)
    eq(P.mostlyStores({ "barn", "empty" }), true, "a barn and its loft")
    eq(P.mostlyStores({ "office", "empty" }), false)
    local lockups = site(150, 900, 12, false)
    lockups.stores = true
    local list = { lockups, site(100, 50, 1, false), site(200, 300, 2, true) }
    eq(P.pickSite(list, "largest"), 2, "a smaller public one before the larger lock-ups")
    eq(P.pickSite({ lockups, site(200, 300, 2, true) }, "largest"), 2, "a house before them")
    eq(P.pickSite({ lockups }, "largest"), 1, "taken when there is nothing else")
    local int = rng(3)
    for _ = 1, 20 do eq(P.pickSite({ lockups, site(200, 300, 2, true) }, "public", int), 2) end
end)

test("the near and far houses come from the inner and outer third of the band's houses", function()
    local list = {}
    for i = 1, 9 do list[i] = site(i * 100, 50, 2, true) end
    list[10] = site(50, 500, 5, false)
    local int = rng(11)
    local near, far = {}, {}
    for _ = 1, 60 do
        near[P.pickSite(list, "near", int)] = true
        far[P.pickSite(list, "far", int)] = true
    end
    for i in pairs(near) do truthy(i >= 1 and i <= 3, "near: " .. i) end
    for i in pairs(far) do truthy(i >= 7 and i <= 9, "far: " .. i) end
    truthy(near[1] and near[3] and far[7] and far[9], "any of the third")
    eq(P.pickSite({ site(50, 500, 5, false) }, "far", int), 1, "a public building when there is no house")
    eq(P.pickSite({ site(50, 50, 1, true) }, "near", int), 1, "one house is both thirds")
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

local START = { x = 8000, y = 7000 }

test("drop sites lie in the ring round the start, spaced", function()
    local sites = P.ringSites(START, 3, 500, 1500, 400, nil, nil, rng(11))
    eq(#sites, 3)
    for i = 1, #sites do
        local d = P.distance(START.x, START.y, sites[i].x, sites[i].y)
        truthy(d >= 499 and d <= 1501, "in the ring: " .. d)
        for j = i + 1, #sites do
            truthy(P.distance(sites[i].x, sites[i].y, sites[j].x, sites[j].y) >= 400, "apart")
        end
    end
end)

test("sites only land where the map accepts them", function()
    local sites = P.ringSites(START, 3, 500, 1500, 400, function(x, y) return x < START.x end, nil, rng(5))
    eq(#sites, 3)
    for _, s in ipairs(sites) do truthy(s.x < START.x, "on land") end
end)

test("a crowded ring relaxes the spacing, down to a third", function()
    -- land only in a thin strip east of the start: three sites 800 apart do not fit in it
    local function strip(x, y) return x > START.x and math.abs(y - START.y) <= 40 end
    local sites = P.ringSites(START, 3, 500, 1500, 800, strip, nil, rng(3))
    eq(#sites, 3)
    local closest = math.huge
    for i = 1, #sites do
        for j = i + 1, #sites do
            closest = math.min(closest, P.distance(sites[i].x, sites[i].y, sites[j].x, sites[j].y))
        end
    end
    truthy(closest < 800, "spacing relaxed: " .. closest)
    truthy(closest >= 800 / 3 - 1, "not below a third: " .. closest)
end)

test("a ring with no land widens outward, up to three times its edge", function()
    local function beyond(x, y) return P.distance(START.x, START.y, x, y) > 2000 end
    local sites = P.ringSites(START, 3, 500, 1500, 400, beyond, nil, rng(7))
    eq(#sites, 3)
    for _, s in ipairs(sites) do
        local d = P.distance(START.x, START.y, s.x, s.y)
        truthy(d > 2000 and d <= 4501, "widened: " .. d)
    end
    eq(#P.ringSites(START, 3, 500, 1500, 400, function() return false end, nil, rng(9)), 0, "gives up")
end)

test("a draw that finds none (the API tried hundreds of points) is not asked again", function()
    local asked = 0
    local function draw() asked = asked + 1; return nil end
    eq(#P.ringSites(START, 3, 500, 1500, 400, function() return true end, nil, rng(9), draw), 0)
    eq(asked, 1, "once")
end)

test("existing sites stay and new ones keep apart from them", function()
    local first = P.ringSites(START, 1, 500, 1500, 400, nil, nil, rng(9))
    local more = P.ringSites(START, 3, 500, 1500, 400, nil, first, rng(13))
    eq(#more, 3)
    eq(more[1], first[1])
    for i = 2, 3 do
        truthy(P.farEnough({ more[1] }, more[i].x, more[i].y, 400), "apart from the old")
    end
end)

test("a compass point is one of eight, the game's y growing south", function()
    eq(P.bearing(0, 0, 10, 0), "E")
    eq(P.bearing(0, 0, 0, -10), "N")
    eq(P.bearing(0, 0, 10, -10), "NE")
    eq(P.bearing(0, 0, -10, 10), "SW")
    eq(P.bearing(5, 5, 5, 5), nil)
end)

test("where a place is: inside the area, close by, then squares in steps (50, 100, 1,000), grouped", function()
    eq(P.whereKey(0, 0, 30, 0, 50), "IGUI_OA_Place_Inside")
    eq(P.whereKey(0, 0, 99, 0), "IGUI_OA_Place_Near")
    local key, args = P.whereKey(0, 0, 0, -340)
    eq(key, "IGUI_OA_Place_Squares")
    eq(args[1], "IGUI_OA_Place_Dir_N")
    eq(args[2], "350", "50-square steps")
    key, args = P.whereKey(0, 0, 990, 0)
    eq(args[2], "1,000")
    key, args = P.whereKey(0, 0, 1700, 1700)
    eq(args[1], "IGUI_OA_Place_Dir_SE")
    eq(args[2], "2,400", "100-square steps")
    key, args = P.whereKey(0, 0, -9970, 0)
    eq(args[2], "10,000", "from 10,000 steps of 1,000")
    key, args = P.whereKey(0, 0, 12400, 0)
    eq(args[2], "12,000")
    eq(P.grouped(1234567), "1,234,567"); eq(P.grouped(999), "999")
end)
