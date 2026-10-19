-- Towns: the world's index from the API's zone clusters, a town searched through at 90% once for the world, and the
-- record that takes its share (the shop's windows after the current one shorter).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Codex"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Economy/Towns"
local OA = OperationAcorn
local T = OA.Towns

-- Town A: 20 buildings, keys 1..20, one rectangle 0..99; a village of 19 (not a town); town C: 30 buildings (keys
-- 200..229), two rectangles. `calls` counts the API asks.
local calls
local function fakeApi()
    calls = 0
    local function keys(from, n)
        local out = {}
        for i = 1, n do out[i] = from + i - 1 end
        return out
    end
    PZExtAPI = { version = OA.API_VERSION, client = function() return {} end, zones = { clusters = function(zone, options)
        calls = calls + 1
        eq(zone, "TownZone"); eq(options.buildings, true)
        return {
            { x1 = 0, y1 = 0, x2 = 99, y2 = 99, area = 10000, zones = 1, rects = { 0, 0, 100, 100 }, buildings = keys(1, 20) },
            { x1 = 500, y1 = 500, x2 = 550, y2 = 550, area = 2500, zones = 1, rects = { 500, 500, 50, 50 }, buildings = keys(100, 19) },
            { x1 = 1000, y1 = 1000, x2 = 1299, y2 = 1099, area = 9000, zones = 2,
              rects = { 1000, 1000, 200, 100, 1200, 1000, 100, 50 }, buildings = keys(200, 30) },
            -- 22 buildings of which 4 are basements (their key's level below 0): 18 left, under the 20
            { x1 = 2000, y1 = 2000, x2 = 2099, y2 = 2099, area = 10000, zones = 1, rects = { 2000, 2000, 100, 100 },
              buildings = { "2000,2000,0", "2010,2000,0", "2020,2000,0", "2030,2000,0", "2040,2000,0", "2050,2000,0",
                  "2060,2000,0", "2070,2000,0", "2080,2000,0", "2090,2000,0", "2000,2010,0", "2010,2010,0", "2020,2010,0",
                  "2030,2010,0", "2040,2010,0", "2050,2010,0", "2060,2010,0", "2070,2010,0",
                  "2000,2000,-1", "2010,2000,-1", "2020,2000,-1", "2030,2000,-1" } },
        }
    end } }
end

-- A record that has used the terminal.
local function record(id)
    local r = OA.Store.ensure(id, id)
    OA.Trust.section(r).stage = 1
    return r
end

-- The titles told: the town done in `told`, the steps on the way in `steps`; the lines of self-talk in `says`.
local steps, says = {}, {}
local function listen()
    local told = {}
    steps, says = {}, {}
    OA.Sync.listen("title", function(id, detail)
        local into = string.find(detail.key, "IGUI_OA_Title_TownProgress", 1, true) and steps or told
        into[#into + 1] = { id = id, detail = detail }
    end)
    OA.Say.tell = function(id, bundle, ctx, delay) says[#says + 1] = { id = id, bundle = bundle, delay = delay } end
    return told
end

test("the index keeps the towns of 20 buildings or more, once a world", function()
    fakeApi()
    local w = T.index()
    eq(#w.list, 2)
    eq(w.list[1].n, 20); eq(w.list[2].n, 30)
    eq(w.of["5"], 1); eq(w.of["100"], nil); eq(w.of["230"], nil); eq(w.of["229"], 2)
    eq(w.of["2000,2000,0"], nil, "a town short of 20 once its basements are left out")
    eq(T.basement("2000,2000,-1"), true); eq(T.basement("2000,2000,0"), false); eq(T.basement(5), false)
    T.index(); T.index()
    eq(calls, 1)
    -- a later session reads the world's copy, not the API
    T.reset()
    PZExtAPI = nil
    eq(T.index(), w)
end)

test("no API, no towns, no error", function()
    PZExtAPI = nil
    eq(T.index(), nil)
    T.searched(record("a"), "5")
    eq(T.enter(record("a"), 10, 10), false)
end)

test("a position is found in its town by the grid and the rectangles", function()
    fakeApi()
    local w = T.index()
    eq(T.at(w, 50, 50), 1)
    eq(T.at(w, 100, 50), nil, "the rectangle ends at 99")
    eq(T.at(w, 1250, 1020), 2, "the second rectangle")
    eq(T.at(w, 1250, 1080), nil, "past the second rectangle's end")
    eq(T.at(w, 9000, 9000), nil)
end)

test("a town is done at 90% of its buildings, once, and the one who completes it takes its share and a title", function()
    fakeApi()
    local told = listen()
    local a = record("a")
    for key = 1, 17 do T.searched(a, tostring(key)) end
    eq(T.index().ndone, 0)
    eq(a.shop, nil, "no share yet")
    T.searched(a, "18")
    eq(T.index().done[1], true)
    eq(T.index().ndone, 1)
    eq(a.shop.restock.nextFactor, 0.9)
    eq(#told, 1)
    eq(told[1].detail.key, "IGUI_OA_Title_TownSearched")
    eq(told[1].detail.sub, "IGUI_OA_Title_TownSearchedSub")
    eq(told[1].detail.style, "discovery")
    -- the rest of the town and a building twice change nothing
    T.searched(a, "19"); T.searched(a, "19"); T.searched(a, "20")
    eq(a.shop.restock.nextFactor, 0.9)
    eq(#told, 1)
    -- a building outside every town, and one of a village, do not count
    T.searched(a, "999"); T.searched(a, "100")
    eq(T.index().ndone, 1)
end)

test("on the way a town tells its half and three quarters of what it takes, once each, to the one who searched", function()
    fakeApi()
    T.reset()
    local w = OA.Store.world("towns")
    w.built = nil
    local told = listen()
    local a, b = record("a"), record("b")
    -- town A takes 18: the half at 9, three quarters at 14
    for key = 1, 8 do T.searched(a, tostring(key)) end
    eq(#steps, 0)
    T.searched(b, "9")
    eq(#steps, 1)
    eq(steps[1].id, "b")
    eq(steps[1].detail.key, "IGUI_OA_Title_TownProgress1")
    eq(steps[1].detail.style, "brief")
    eq(says[1].bundle, "TownHalf"); eq(says[1].delay, T.PROGRESS_SAY)
    for key = 10, 13 do T.searched(a, tostring(key)) end
    eq(#steps, 1)
    T.searched(a, "14")
    eq(#steps, 2)
    eq(steps[2].detail.key, "IGUI_OA_Title_TownProgress2")
    eq(says[2].bundle, "TownNearly")
    for key = 15, 18 do T.searched(a, tostring(key)) end
    eq(#steps, 2, "the town done has its own title")
    eq(#told, 1)
    -- a record that has not met the team is not told, and the step is gone for the world
    local quiet = OA.Store.ensure("q", "q")
    for key = 200, 213 do T.searched(quiet, tostring(key)) end
    eq(#steps, 2)
    T.searched(a, "214")
    eq(#steps, 2, "the half of town C was reached (by one not told)")
end)

test("the codex hands each building it counts for the first time to its town", function()
    fakeApi()
    local a = record("a")
    for key = 1, 18 do OA.Codex.buildingSearched(a, key, 3) end
    eq(T.index().done[1], true)
    eq(a.shop.restock.nextFactor, 0.9)
    OA.Codex.buildingSearched(a, 18, 3)
    OA.Codex.buildingSearched(a, 19, 3)
    eq(a.shop.restock.nextFactor, 0.9, "counted once")
end)

test("searches of different characters add up for the world; the other takes its share by coming in", function()
    fakeApi()
    local told = listen()
    local a, b = record("a"), record("b")
    for key = 1, 10 do T.searched(a, tostring(key)) end
    for key = 11, 18 do T.searched(b, tostring(key)) end
    eq(T.index().done[1], true)
    eq(b.shop.restock.nextFactor, 0.9, "the character who completed it")
    eq(a.shop, nil, "a has not been in the town since")
    eq(T.enter(a, 5000, 5000), false, "outside any town")
    eq(T.enter(a, 1050, 1050), false, "a town not done")
    eq(T.enter(a, 50, 50), true)
    eq(a.shop.restock.nextFactor, 0.9)
    eq(T.enter(a, 60, 60), false, "once")
    eq(a.shop.restock.nextFactor, 0.9)
    eq(#told, 2)
    eq(told[2].id, "a")
    eq(told[2].detail.sub, "IGUI_OA_Title_TownSearchedSubKnown")
end)

test("a character made after the town was done takes its share too, and towns multiply", function()
    fakeApi()
    local a, c = record("a"), record("c")
    for key = 1, 18 do T.searched(a, tostring(key)) end
    -- town C needs 27 of 30
    for key = 200, 226 do T.searched(a, tostring(key)) end
    eq(T.index().done[2], true)
    near(a.shop.restock.nextFactor, 0.81, 1e-12)
    T.enter(c, 1250, 1020)
    near(c.shop.restock.nextFactor, 0.9, 1e-12)
    T.enter(c, 10, 10)
    near(c.shop.restock.nextFactor, 0.81, 1e-12)
end)

test("a record that has not met the team takes its share without a title", function()
    fakeApi()
    local told = listen()
    local a = OA.Store.ensure("a", "a")
    for key = 1, 18 do T.searched(a, tostring(key)) end
    eq(a.shop.restock.nextFactor, 0.9)
    eq(#told, 0)
end)

test("the searched town shortens the next restock window of the shop", function()
    fakeApi()
    local a = record("a")
    TEST.hours = 0
    local serum = OA.Shop.entry("serum_shared")
    OA.Shop.available(serum, a)
    for key = 1, 18 do T.searched(a, tostring(key)) end
    eq(OA.Shop.restockEnd(a), 240)
    TEST.hours = 250
    near(OA.Shop.restockEnd(a), 240 + 216, 1e-9)
end)

test("a character that has not met the team takes no town yet; once it has, the share comes with its title", function()
    fakeApi()
    local told = listen()
    local a = record("a")
    for key = 1, 18 do T.searched(a, tostring(key)) end
    local fresh = OA.Store.ensure("fresh", "fresh")
    OA.Trust.section(fresh).stage = 0
    eq(T.enter(fresh, 50, 50), false, "before the first contact")
    eq(fresh.shop, nil, "no share taken untold")
    OA.Trust.section(fresh).stage = 1
    eq(T.enter(fresh, 50, 50), true)
    eq(fresh.shop.restock.nextFactor, 0.9)
    eq(told[#told].id, "fresh")
    eq(told[#told].detail.sub, "IGUI_OA_Title_TownSearchedSubKnown")
end)
