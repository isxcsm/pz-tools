-- The dense places (Story/Dense): the API's list kept once a world, a kit kind given by density order, the maps showing the
-- places from trust level 6, and the clearing: a baseline of the most counted, a tenth of it to clear, never from a baseline
-- under 20, and one reward a record, also for a place another character cleared.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Dense"
require "OperationAcorn/Story/View"
local OA = OperationAcorn
local Dense, View = OA.Dense, OA.StoryView

-- The API's answer for the places: the densest first.
local PLACES = {
    { x = 1000, y = 1000, r = 60, x1 = 900, y1 = 900, x2 = 1100, y2 = 1100, chunks = 40, peak = 255, mean = 200 },
    { x = 2000, y = 2000, r = 40, chunks = 12, peak = 220, mean = 180 },
    { x = 3000, y = 3000, r = 30, chunks = 8, peak = 200, mean = 170 },
    { x = 4000, y = 4000, r = 25, chunks = 6, peak = 170, mean = 165 },
}

local asked, titles, changes, counts
local n = 0

-- A fresh world's dense section and an API that answers `places` and counts the zombies set in `counts` (by "x,y").
local function setup(places)
    asked = {}
    titles, changes = {}, {}
    counts = {}
    local world = OA.Store.world("dense")
    world.made, world.list, world.baseline, world.cleared = nil, nil, nil, nil
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return { name = OA.MOD } end,
        zombies = {
            dense = function(options)
                asked[#asked + 1] = options
                return places or PLACES
            end,
            near = function(x, y)
                return counts[x .. "," .. y] or 0, {}
            end,
        },
    }
    OA.Sync.title = function(id, detail) titles[#titles + 1] = { id = id, detail = detail } end
    OA.Sync.changed = function(what, id) changes[#changes + 1] = { what = what, id = id } end
end

local function record(tier)
    n = n + 1
    local r = OA.Store.ensure("dense" .. n, "D")
    r.trade = { stage = math.min(tier, 5), milestones = math.max(0, tier - 5) }
    return r
end

local function stand(r, place, away)
    Dense.look(r, place.x + (away or 0), place.y)
end

test("the list is asked of the API once a world, with the constants, in the density order with a kind each", function()
    setup()
    truthy(Dense.ensure())
    eq(#asked, 1)
    eq(asked[1].min, 160)
    eq(asked[1].minChunks, 6)
    eq(Dense.MIN, 160)
    eq(Dense.CHUNKS, 6)
    local list = Dense.list()
    eq(#list, 4)
    eq(list[1].id, "D1"); eq(list[4].id, "D4")
    eq(list[1].kind, "damage"); eq(list[2].kind, "crit"); eq(list[3].kind, "repair"); eq(list[4].kind, "damage")
    eq(list[2].x, 2000); eq(list[2].r, 40)
    Dense.ensure()
    Dense.ensure()
    eq(#asked, 1, "kept in the world store, not asked again")
    eq(OA.Store.world("dense").made, true)
    eq(#OA.Store.world("dense").list, 4)
end)

test("without the API's answer nothing is made and it is asked again; an empty answer is an answer", function()
    setup()
    PZExtAPI = nil
    eq(Dense.ensure(), nil)
    eq(#Dense.list(), 0)
    eq(OA.Store.world("dense").made, nil)
    setup({})
    eq(#Dense.ensure(), 0)
    eq(#asked, 1)
    Dense.ensure()
    eq(#asked, 1)
end)

test("the maps show the places from trust level 6, in the colour of their kit, until the record has the kit", function()
    setup()
    Dense.ensure()
    local low, high = record(5), record(6)
    eq(#View.scene(low, nil).circles, 0, "not below level 6")
    local scene = View.scene(high, nil)
    eq(#scene.circles, 4)
    eq(scene.empty, false)
    eq(scene.lead, nil, "never where the way leads")
    local c = scene.circles[2]
    eq(c.dim, true)
    eq(c.x, 2000.5); eq(c.y, 2000.5); eq(c.r, 40)
    eq(c.color, View.MAP_DENSE.crit)
    eq(scene.circles[1].color, View.MAP_DENSE.damage)
    eq(scene.circles[3].color, View.MAP_DENSE.repair)
    OA.Store.world("dense").cleared = { D2 = { by = "someone", at = 5 } }
    local after = View.scene(high, nil)
    eq(#after.circles, 4, "cleared by another: its kit still waits there for this one")
    Dense.got(high).D2 = "crit"
    local had = View.scene(high, nil)
    eq(#had.circles, 3, "gone once the record has it")
    for _, circle in ipairs(had.circles) do truthy(circle.x ~= 2000.5) end
end)

test("the most counted is the baseline; a tenth of it clears the place, once, and gives its kit to the one who cleared it", function()
    setup()
    Dense.ensure()
    local r = record(6)
    local p = Dense.list()[1]
    counts["1000,1000"] = 80
    stand(r, p)
    eq(OA.Store.world("dense").baseline.D1, 80, "the first count")
    counts["1000,1000"] = 30
    stand(r, p)
    eq(OA.Store.world("dense").baseline.D1, 80, "a lower count leaves it")
    eq(#titles, 0)
    counts["1000,1000"] = 9
    stand(r, p)
    eq(#titles, 0, "9 is more than a tenth of 80")
    counts["1000,1000"] = 8
    stand(r, p)
    eq(#titles, 1)
    eq(titles[1].id, r.id)
    eq(titles[1].detail.key, "IGUI_OA_Title_DenseCleared")
    eq(titles[1].detail.sub, "IGUI_OA_Title_DenseClearedSub")
    eq(titles[1].detail.subArgs[1].key, "IGUI_OA_Dense_Kit_damage")
    eq(titles[1].detail.style, "discovery")
    eq(Dense.got(r).D1, "damage")
    eq(Dense.count(r, "damage"), 1)
    eq(Dense.count(r, "crit"), 0)
    eq(Dense.cleared("D1").by, r.id)
    eq(Dense.cleared("D1").at, TEST.hours)
    eq(#changes, 1)
    eq(changes[1].what, "trade")
    eq(changes[1].id, r.id)
    counts["1000,1000"] = 0
    stand(r, p)
    stand(r, p)
    eq(#titles, 1, "once")
    eq(#changes, 1)
    eq(Dense.count(r, "damage"), 1)
end)

test("a baseline under 20 never clears; none is taken of an empty count", function()
    setup()
    Dense.ensure()
    local r = record(6)
    local p = Dense.list()[2]
    counts["2000,2000"] = 0
    stand(r, p)
    eq(OA.Store.world("dense").baseline.D2, nil, "nothing counted yet is no baseline")
    counts["2000,2000"] = 19
    stand(r, p)
    eq(OA.Store.world("dense").baseline.D2, 19)
    counts["2000,2000"] = 0
    stand(r, p)
    eq(#titles, 0, "19 is too few to clear")
    eq(Dense.cleared("D2"), nil)
    local q = Dense.list()[3]
    counts["3000,3000"] = 20
    stand(r, q)
    counts["3000,3000"] = 2
    stand(r, q)
    eq(#titles, 1, "20 is enough, and 2 is a tenth of it")
    eq(Dense.got(r).D3, "repair")
end)

test("only within 20 squares of the middle, no more than once a real second, and not below level 6", function()
    setup()
    Dense.ensure()
    local r = record(6)
    local p = Dense.list()[1]
    local asks = 0
    local real = Dense.countAt
    Dense.countAt = function(x, y)
        asks = asks + 1
        return real(x, y)
    end
    counts["1000,1000"] = 50
    stand(r, p, 21)
    eq(asks, 0, "21 squares away")
    stand(r, p, 20)
    eq(asks, 1, "20 squares away")
    local now = 5000000
    local clock = getTimestampMs
    getTimestampMs = function() return now end
    Dense.look(r, p.x, p.y)
    Dense.look(r, p.x, p.y)
    now = now + 400
    Dense.look(r, p.x, p.y)
    eq(asks, 2, "one look a second")
    now = now + 1000
    Dense.look(r, p.x, p.y)
    eq(asks, 3)
    local low = record(5)
    now = now + 5000
    Dense.look(low, p.x, p.y)
    eq(asks, 3, "below level 6 nothing is looked at")
    -- no API: nothing happens
    Dense.countAt = real
    PZExtAPI.zombies.near = nil
    now = now + 5000
    Dense.look(r, p.x, p.y)
    eq(#titles, 0)
    getTimestampMs = clock
end)

test("a place another character cleared is the reward of a record that stands at its middle, once, with its own line", function()
    setup()
    Dense.ensure()
    local first, second = record(6), record(7)
    local p = Dense.list()[4]
    counts["4000,4000"] = 40
    stand(first, p)
    counts["4000,4000"] = 3
    stand(first, p)
    eq(Dense.got(first).D4, "damage")
    eq(#titles, 1)
    -- the second one never counted anything there: standing is enough
    counts["4000,4000"] = 50
    stand(second, p)
    eq(#titles, 2)
    eq(titles[2].id, second.id)
    eq(titles[2].detail.sub, "IGUI_OA_Title_DenseHadSub")
    eq(titles[2].detail.subArgs[1].key, "IGUI_OA_Dense_Kit_damage")
    eq(Dense.got(second).D4, "damage")
    eq(Dense.cleared("D4").by, first.id, "the clearing stays the first one's")
    eq(changes[#changes].id, second.id)
    stand(second, p)
    eq(#titles, 2, "once")
    -- a record below level 6 gets nothing by standing
    local low = record(4)
    stand(low, p)
    eq(Dense.got(low).D4, nil)
    eq(Dense.count(second, "damage"), 1)
end)
