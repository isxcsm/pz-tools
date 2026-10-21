-- The reward devices of the missions (DESIGN-terminal 7.2): the streak, the danger pay, taking another, the urgent
-- mission, the kinds mixed among the regular ones (the comparison, bare-ground soil, scattered samples, the heavy
-- sample), the field notes drawn unread first; and the special requests (6.3): two offered, one taken, its steps, the
-- reward, the request copy. The game is a fake that records what it is asked.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Folder"
require "OperationAcorn/Story/Scene"
local OA = OperationAcorn
local M = OA.Missions
local Story, Data, Rewards = OA.Story, OA.StoryData, OA.Rewards

local function building(x, y)
    return { x = x, y = y, z = 0, x1 = x - 3, y1 = y - 3, x2 = x + 3, y2 = y + 3, z1 = 0, z2 = 0 }
end

-- A ring of buildings round the origin (as the missions test has), or the list given.
local function fakeGame(list)
    local g = { requested = {}, released = 0, supply = {}, taken = {}, delivered = nil }
    if not list then
        list = {}
        for i = 1, 600 do
            local a = i * 0.7
            local r = 100 + (i % 60) * 25
            list[i] = building(math.floor(math.cos(a) * r), math.floor(math.sin(a) * r))
        end
    end
    g.list = list
    fakeSites(g)
    g.playerPosition = function() return g.px or 0, g.py or 0, 0 end
    g.request = function(record, m, it) g.requested[#g.requested + 1] = { m = m.id, it = it } end
    g.release = function() g.released = g.released + 1 end
    g.takeItem = function(character, name) g.taken[#g.taken + 1] = name; return not g.noItem end
    g.takeMissionItem = function() return true end
    g.noise = function() end
    g.findItem = function() return nil end
    g.deliverInside = function(record, m, it) it.placed = true; g.delivered = it end
    g.giveMissionItem = function(character, full, id) g.given = { full, id } end
    return g
end

-- A record at a trust stage whose story has been told (so that the missions that start are the plain ones), the base
-- known, the plain pickup the only regular kind, no urgent one and no distance pay: each test turns on what it looks at.
local recordCount = 0
local function setup(stage, list)
    recordCount = recordCount + 1
    local record = OA.Store.ensure("p" .. recordCount, "P" .. recordCount)
    record.trade = { stage = stage, milestones = 0, credits = 0, trust = 0 }
    Story.setAnchor(record, 0, 0, 0)
    OA.Comms.played(record, "S1", 1)
    local s = Story.section(record)
    s.seenStage = stage
    for id in pairs(Data.STORIES) do s.done[id] = "done" end
    Data.REGULAR = { { item = "MissionEnvelope", weight = 1 } }
    Rewards.URGENT_CHANCE = 0
    Rewards.FAR_MAX = 0
    M.game = fakeGame(list)
    OA.Trade = { addToDrop = function(rec, items)
        for _, it in ipairs(items) do M.game.supply[#M.game.supply + 1] = it.type end
    end }
    return record
end


-- Missions wait to be started (Missions.launch); these tests look at them running: a tick starts what it offered, and
-- a story's briefing is over at once.
local function taken(record)
    local m = M.active(record)
    if m and m.state == "waiting" then
        M.launch(record)
        m = M.active(record)
        if m and m.state == "briefing" then M.briefed(record, m.brief) end
    end
    return M.active(record)
end

local function tick(record)
    M.tick(record)
    taken(record)
end

-- A generator that spreads (Park-Miller: its products stay within what a double holds): the harness's own repeats a
-- pattern in its low bits, which a pick between two things shows. Taken back after the test.
local function spread()
    local state = 12345
    ZombRand = function(a, b)
        state = (state * 16807) % 2147483647
        if b == nil then a, b = 0, a end
        if b <= a then return a end
        return a + state % (b - a)
    end
end

local function only(kind)
    Data.REGULAR = { kind }
end

local function start(record)
    tick(record)
    return M.active(record)
end

local function seal(record, m, key, box)
    M.onSealed(record, box or "box", { { info = { mission = M.itemId(m, key) }, count = 1 } })
end

-- The streak ------------------------------------------------------------------------------------------------------

test("the streak counts missions done in time, an expired one ends it, a lost one leaves it", function()
    local record = setup(1)
    local s = M.state(record)
    eq(s.streak, 0); eq(s.bestStreak, 0)
    local function done(result) M.finish(record, { id = "M1-" .. result, kind = "regular" }, result) end
    done("done"); done("done")
    eq(s.streak, 2); eq(s.bestStreak, 2)
    done("lost")
    eq(s.streak, 2, "lost does not end it")
    done("done")
    eq(s.streak, 3); eq(s.bestStreak, 3)
    done("expired")
    eq(s.streak, 0, "past the deadline ends it")
    eq(s.bestStreak, 3, "the longest is kept")
    done("done")
    eq(s.streak, 1); eq(s.bestStreak, 3)
end)

test("the streak adds a tenth a mission to the next one's credits and not to its trust", function()
    local record = setup(1)
    M.state(record).streak = 2
    local m = start(record)
    eq(m.base, 10000)
    eq(m.streak, 2)
    eq(m.credits, 12000)
    eq(m.trust, 60)
    local info = M.describe(record)
    eq(info.base, 10000); eq(info.streak, 2); eq(info.credits, 12000)
end)

test("a streak past three still adds three tenths", function()
    local record = setup(1)
    M.state(record).streak = 7
    local m = start(record)
    eq(m.streak, 7)
    eq(m.credits, 13000)
end)

test("the pay of a done mission goes to the record and the streak grows by it", function()
    local record = setup(1)
    local m = start(record)
    seal(record, m, "A")
    M.onSettled(record, {})
    eq(record.trade.credits, 10000)
    eq(M.state(record).streak, 1)
    TEST.hours = TEST.hours + 3 * 24 + 1
    local n = start(record)
    eq(n.streak, 1)
    eq(n.credits, 11000)
end)

-- The danger pay ------------------------------------------------------------------------------------------------

test("the danger pay is read once, from a few points of the circle", function()
    local record = setup(1)
    local calls = {}
    M.game.zombieIntensity = function(x, y) calls[#calls + 1] = { x, y }; return 0.22 end
    local m = start(record)
    eq(#calls, 5, "the middle and four points round it")
    local area = m.area
    local far = 0
    for _, p in ipairs(calls) do
        local d = OA.Places.distance(p[1], p[2], area.x, area.y)
        truthy(d <= area.r, "inside the circle")
        if d > 1 then far = far + 1 end
    end
    eq(far, 4)
    near(m.danger, 0.15, 1e-9)
    eq(m.credits, 11500)
    eq(M.describe(record).danger, m.danger)
    M.describe(record)
    eq(#calls, 5, "not read again")
end)

test("the danger pay is the average of the points, and nothing where the game cannot say", function()
    local record = setup(1)
    local values, n = { 0.05, 0.05, 0.05, 0.05, 0.55 }, 0
    M.game.zombieIntensity = function() n = n + 1; return values[n] end
    near(M.dangerOf({ { x = 0, y = 0, r = 60 } }), 0.10, 1e-9, "(0.15 - 0.05) x 100 per cent")
    M.game.zombieIntensity = function() return nil end
    eq(M.dangerOf({ { x = 0, y = 0, r = 60 } }), 0)
    M.game.zombieIntensity = nil
    eq(M.dangerOf({ { x = 0, y = 0, r = 60 } }), 0)
    eq(M.dangerOf({}), 0)
end)

test("the danger pay and the streak are added together; the danger goes on the trust too, the streak does not", function()
    local record = setup(1)
    M.state(record).streak = 2
    M.game.zombieIntensity = function() return 0.22 end
    local m = start(record)
    eq(m.credits, 13500, "10,000 x (1 + 0.15 + 0.20)")
    eq(m.trust, 69, "60 x 1.15")
    seal(record, m, "A")
    eq(m.pay.credits, 13500)
end)

test("the cooler's pay keeps the danger pay and the streak on its warming", function()
    local record = setup(4)
    local s = Story.section(record)
    s.done.cooler = nil
    s.seenStage = 3
    M.state(record).streak = 1
    M.game.zombieIntensity = function() return 0.22 end
    tick(record)
    local m = M.active(record)
    eq(m.story, "cooler")
    M.game.findItem = function() return {} end
    tick(record)
    TEST.hours = TEST.hours + 2
    seal(record, m, "A")
    -- 50,000 x 1.5 x (1 + 0.15 + 0.1)
    eq(m.pay.credits, 93750)
end)

-- Urgent missions ---------------------------------------------------------------------------------------------------

test("an urgent mission has a day and pays half again", function()
    local record = setup(1)
    Rewards.URGENT_CHANCE = 100
    local m = start(record)
    eq(m.urgent, true)
    near(m.deadline - m.issued, 24)
    eq(m.base, 15000)
    eq(m.credits, 15000)
    eq(m.trust, 90)
    eq(M.describe(record).urgent, true)
    TEST.hours = TEST.hours + 25
    tick(record)
    eq(M.active(record), nil, "a day later it is over")
end)

test("one regular mission in ten is urgent, and none is when the chance is none", function()
    eq(Rewards.URGENT_CHANCE, 10)
    eq(Rewards.URGENT_HOURS, 24)
    near(Rewards.URGENT_MULTIPLIER, 1.5)
    local record = setup(1)
    Rewards.URGENT_CHANCE = 0
    eq(start(record).urgent, nil)
end)

test("the kinds that need more than one place or one carry are never urgent", function()
    for _, kind in ipairs({ { id = "compare", kind = "compare", item = "CopyOriginal", weight = 1 },
        { id = "soil", kind = "soil", weight = 1 }, { item = "MissionHeavyCase", kind = "heavy", weight = 1 } }) do
        local record = setup(1)
        Rewards.URGENT_CHANCE = 100
        only(kind)
        local m = start(record)
        truthy(m, "a mission")
        eq(m.urgent, nil, tostring(kind.id or kind.kind))
    end
end)

-- Kinds mixed among the regular missions ------------------------------------------------------------------------------

test("the regular missions' pick has the comparison and the soil at one in the 13 of the plain kinds, and the heavy sample", function()
    local weights, plain = {}, 0
    for _, e in ipairs(Data.REGULAR) do
        if e.kind then weights[e.kind] = e.weight else plain = plain + e.weight end
    end
    eq(plain, 13)
    eq(weights.compare, 1)
    eq(weights.soil, 1)
    eq(weights.heavy, 1)
    truthy(weights.scatter and weights.scatter >= 1)
end)

test("a comparison among the regular missions is a regular mission with two copies in two buildings", function()
    local record = setup(1)
    only({ id = "compare", kind = "compare", item = "CopyOriginal", weight = 1 })
    local m = start(record)
    eq(m.kind, "regular")
    eq(m.title, "compare")
    eq(m.contract, nil)
    eq(#m.items, 2)
    truthy(m.area2, "a second circle")
    truthy(m.compare.serial)
    local title, brief = M.keys(m)
    eq(title, "IGUI_OA_Story_ConTitle_compare", "told in the contract's words")
    eq(brief, "IGUI_OA_Story_ConBrief_compare")
    eq(M.describe(record).compare, m.compare.serial)
    seal(record, m, m.compare.right == "A" and "B" or "A")
    eq(m.state, "open", "the copy is not the original")
    seal(record, m, m.compare.right)
    eq(m.state, "sealed")
    M.onSettled(record, {})
    eq(record.trade.credits, 10000)
end)

test("the soil among the regular missions is taken from bare ground, anywhere, and sealed", function()
    local record = setup(1)
    only({ id = "soil", kind = "soil", weight = 1 })
    local m = start(record)
    eq(m.kind, "regular")
    eq(m.title, "soil")
    eq(m.soil.variant, "plain")
    eq(m.area, nil, "no circle")
    eq(#m.items, 0)
    local title = M.keys(m)
    eq(title, "IGUI_OA_Story_RegTitle_soil")
    truthy(M.soil(record, {}))
    eq(m.items[1].type, "OperationAcorn.SoilSample")
    seal(record, m, "A")
    M.onSettled(record, {})
    eq(record.trade.credits, 10000)
end)

test("the heavy sample is one heavy item in a building and the card says its weight", function()
    local record = setup(1)
    only({ item = "MissionHeavyCase", kind = "heavy", weight = 1 })
    local m = start(record)
    eq(m.title, "MissionHeavyCase")
    eq(m.heavy, 15)
    eq(m.items[1].type, "OperationAcorn.MissionHeavyCase")
    eq(M.describe(record).heavy, 15)
    eq(Data.ITEMS.MissionHeavyCase.weight, 15)
    eq(select(1, M.keys(m)), "IGUI_OA_Story_RegTitle_MissionHeavyCase")
end)

test("the plain pickups carry a field note, the ones not read first", function()
    local record = setup(1)
    Data.FIELD_NOTE_CHANCE = 100
    local s = Story.section(record)
    for n = 1, 11 do s.docs["note_" .. n] = true end
    local m = start(record)
    eq(m.items[1].mods.OA_Note, "note_12", "the only one not read")
    M.finish(record, m, "done")
    for n = 1, 12 do s.docs["note_" .. n] = true end
    TEST.hours = TEST.hours + 3 * 24 + 1
    local seen = {}
    for _ = 1, 10 do
        local n = start(record)
        truthy(n.items[1].mods.OA_Note, "a note when all are read")
        seen[n.items[1].mods.OA_Note] = true
        M.finish(record, n, "done")
        TEST.hours = TEST.hours + 3 * 24 + 1
    end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    truthy(count >= 2, "any of them again")
end)

test("a note chance of none gives no note", function()
    local record = setup(1)
    Data.FIELD_NOTE_CHANCE = 0
    eq(start(record).items[1].mods.OA_Note, nil)
end)

-- Scattered samples ----------------------------------------------------------------------------------------------------

local TIN_SCATTER = { id = "scatter", kind = "scatter", item = "MissionSampleTin", weight = 1 }

local function cluster()
    return { building(300, 0), building(310, 5), building(305, -8) }
end

test("scattered samples are pieces in two or three buildings of the circle, the whole set paying a fifth more", function()
    spread()
    local counts = {}
    for round = 1, 12 do
        local record = setup(1, cluster())
        only(TIN_SCATTER)
        local m = start(record)
        truthy(m.scatter, "scattered")
        counts[m.scatter.total] = true
        eq(#m.items, m.scatter.total)
        truthy(m.scatter.total == 2 or m.scatter.total == 3)
        local seen = {}
        for i, it in ipairs(m.items) do
            eq(it.key, string.sub("ABC", i, i))
            eq(it.type, "OperationAcorn.MissionSampleTin")
            truthy(OA.Places.distance(it.x, it.y, m.area.x, m.area.y) <= m.area.r, "inside the circle")
            local at = it.x .. "," .. it.y
            eq(seen[at], nil, "a building of its own")
            seen[at] = true
        end
        eq(m.title, "scatter")
        eq(m.credits, 12000)
        eq(m.trust, 72)
        eq(#M.game.requested, m.scatter.total, "each piece asked to be placed")
    end
    truthy(counts[2] and counts[3], "both counts come")
end)

test("a scattered mission in a place with one building is an ordinary pickup", function()
    local record = setup(1, { building(300, 0) })
    only(TIN_SCATTER)
    local m = start(record)
    eq(m.scatter, nil)
    eq(m.title, "MissionSampleTin")
    eq(#m.items, 1)
    eq(m.credits, 10000)
end)

local function scattered()
    local record = setup(1, cluster())
    only(TIN_SCATTER)
    local m = start(record)
    truthy(m.scatter, "scattered")
    return record, m
end

test("a piece sealed counts and the mission stays open until the set is in", function()
    local record, m = scattered()
    local total = m.scatter.total
    seal(record, m, "A", "b1")
    eq(m.state, "open")
    eq(M.scatterCount(m), 1)
    local info = M.describe(record)
    eq(info.scatter.total, total)
    eq(info.scatter.found, 1)
    eq(info.item, "MissionSampleTin")
    seal(record, m, "A", "b1")
    eq(M.scatterCount(m), 1, "the same piece twice is one")
    for i = 2, total do seal(record, m, string.sub("ABC", i, i), "b" .. i) end
    eq(m.state, "sealed")
    eq(m.pay.credits, 12000, "the whole set, with its extra")
    eq(m.pay.trust, 72)
    M.onSettled(record, { boxes = 1 })
    eq(record.trade.credits, 12000)
    eq(M.active(record), nil)
    eq(M.state(record).results.done, 1)
end)

test("a scattered mission whose time runs out pays the share found", function()
    local record, m = scattered()
    local total = m.scatter.total
    seal(record, m, "A", "b1")
    TEST.hours = TEST.hours + 15 * 24
    tick(record)
    eq(m.state, "sealed", "what was found is paid")
    local share = 1 / total / 1.2
    eq(m.pay.credits, OA.round(12000 * share))
    eq(m.pay.trust, OA.round(72 * share))
    M.onSettled(record, { boxes = 1 })
    eq(record.trade.credits, OA.round(12000 * share))
    eq(M.state(record).results.done, 1)
    eq(M.state(record).results.expired, 0)
end)

test("a scattered mission with nothing found when its time runs out is an expired mission", function()
    local record, m = scattered()
    TEST.hours = TEST.hours + 15 * 24
    tick(record)
    eq(M.active(record), nil)
    eq(M.state(record).results.expired, 1)
    eq(record.trade.credits, 0)
end)

test("a piece sealed after the deadline is a plain item and the pieces found before it are paid", function()
    local record, m = scattered()
    seal(record, m, "A", "b1")
    TEST.hours = TEST.hours + 15 * 24
    seal(record, m, "B", "b2")
    eq(m.state, "sealed")
    eq(M.scatterCount(m), 1, "the late piece does not count")
end)

test("a scattered mission's pieces are one mission's items", function()
    local record, m = scattered()
    eq(M.itemId(m, "A"), m.id .. "#A")
    eq(Story.missionExpired(m.id .. "#B"), false)
    seal(record, m, "A", "b1")
    eq(Story.missionExpired(m.id .. "#A"), false, "open and in time")
end)

-- Taking another ----------------------------------------------------------------------------------------------------

test("taking another is offered for an open regular mission, once a week, at a tenth of the level's trust", function()
    local record = setup(2)
    local m = start(record)
    local offer = M.rerollOffer(record, m)
    eq(offer.trust, 12)
    eq(offer.left, 1)
    eq(M.describe(record).reroll.trust, 12)
    m.state = "sealed"
    eq(M.rerollOffer(record, m), nil, "not once it is sealed")
    m.state = "open"
    m.kind = "story"
    eq(M.rerollOffer(record, m), nil, "not a story mission")
    m.kind = "contract"
    truthy(M.rerollOffer(record, m), "a contract mission")
    m.kind = "special"
    eq(M.rerollOffer(record, m), nil)
    eq(M.rerollOffer(record, nil), nil)
end)

test("taking another gives a new mission, costs the trust, and cannot be done again that week", function()
    local record = setup(1)
    record.trade.trust = 1000
    local m = start(record)
    local first = m.id
    M.state(record).streak = 2
    truthy(M.reroll(record))
    local n = M.active(record)
    truthy(n.id ~= first)
    eq(n.kind, "regular")
    eq(record.trade.trust, 994, "6 of the first level's 60")
    eq(M.state(record).streak, 2, "the streak is left")
    eq(M.state(record).results.done, 0)
    eq(M.state(record).results.expired, 0)
    eq(n.streak, 2, "the new mission is priced with the streak")
    eq(Story.missionExpired(first), true, "what the old one left is a plain item")
    eq(M.rerollOffer(record, n).left, 0)
    eq(M.reroll(record), false)
    eq(record.trade.trust, 994)
    eq(M.active(record).id, n.id)
    TEST.hours = TEST.hours + 8 * 24
    n.deadline = TEST.hours + 100
    eq(M.rerollOffer(record, n).left, 1, "a new week")
    truthy(M.reroll(record))
    eq(record.trade.trust, 988)
end)

test("taking another never takes the trust below where the level began", function()
    local record = setup(2)
    record.trade.trust = 402
    start(record)
    truthy(M.reroll(record))
    eq(record.trade.trust, 400, "the second stage began at 400")
end)

test("the distance pay: how far into its band a mission lies, on the credits and the trust", function()
    Rewards.FAR_MAX = 0.5
    eq(Rewards.farPay(150, 150, 600), 0, "at the near edge: none")
    near(Rewards.farPay(600, 150, 600), 0.5, 1e-9, "at the far edge: the most")
    near(Rewards.farPay(375, 150, 600), 0.25, 1e-9)
    near(Rewards.farPay(330, 150, 600), 0.2, 1e-9, "in steps of five per cent")
    near(Rewards.farPay(340, 150, 600), 0.2, 1e-9)
    near(Rewards.farPay(9000, 150, 600), 0.5, 1e-9, "past the band: no more")
    eq(Rewards.farPay(100, 150, 600), 0, "inside the band's start: none")
    eq(Rewards.trustWithBonus(60, 0.15, 0.3), 87, "the danger and the distance on the trust")
    eq(Rewards.withBonus(10000, 0.15, 2, 0.3, 0.1), 17500, "and on the credits with the streak and the support")
    local record = setup(1)
    Rewards.FAR_MAX = 0.5
    near(M.farOf(record, { x = 600, y = 0 }, 1), 0.5, 1e-9, "from the terminal, in the level's band")
    eq(M.farOf(record, { x = 150, y = 0 }, 1), 0)
    local m = start(record)
    near(m.far, M.farOf(record, m.area, 1), 1e-9)
    eq(m.credits, Rewards.withBonus(m.base, m.danger, m.streak, m.far, m.support))
    eq(m.trust, Rewards.trustWithBonus(m.trustBase, m.danger, m.far))
end)

test("a mission that cannot be made keeps the old one and costs nothing", function()
    local record = setup(1)
    record.trade.trust = 1000
    local m = start(record)
    M.game.buildingsIn = function() return {} end
    eq(M.reroll(record), false)
    eq(M.active(record), m)
    eq(record.trade.trust, 1000)
    eq(M.rerollOffer(record, m).left, 1)
end)

test("a scattered mission with a piece found cannot be taken again", function()
    local record, m = scattered()
    truthy(M.rerollOffer(record, m))
    seal(record, m, "A", "b1")
    eq(M.rerollOffer(record, m), nil)
end)

test("a story mission cannot be taken again", function()
    local record = setup(1)
    Story.section(record).done.evidence = nil
    Story.queueStory(record, "evidence", true)
    local m = start(record)
    eq(m.story, "evidence")
    eq(M.rerollOffer(record, m), nil)
    eq(M.reroll(record), false)
end)

-- The special request ------------------------------------------------------------------------------------------------

-- A record with a field line, at the third stage (35,000 a regular mission), and two requests of each form to pick from.
local function fieldRecord(stage)
    local record = setup(stage or 3)
    record.heli = { line = true }
    return record
end

local function offered(record)
    tick(record)
    local sp = M.special(record)
    truthy(sp.offer, "an offer")
    return sp.offer
end

test("two special requests are offered once the field line is open at the second stage", function()
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    local record = fieldRecord(3)
    local offer = offered(record)
    truthy(offer.a.id ~= offer.b.id, "two different requests")
    truthy(offer.a.form ~= offer.b.form, "of two forms")
    eq(Data.SPECIAL_BY_ID[offer.a.id].form, offer.a.form)
    truthy(offer.a.area and offer.b.area)
    local news = 0
    for _, d in ipairs(told) do if d.key == "IGUI_OA_Title_NewRequest" then news = news + 1 end end
    truthy(news >= 1, "the offer has its title")
    eq(OA.StoryFolder.missionSeq(record) >= offer.seq, true, "the tab's dot")
    local sealedSeq = M.state(record).seq
    eq(offer.seq, sealedSeq)
    tick(record)
    eq(M.special(record).offer, offer, "not offered again")
end)

test("no special request without the field line or before the second stage", function()
    local record = setup(3)
    tick(record)
    eq(M.special(record).offer, nil, "no field line")
    eq(M.specialSlot(record), nil)
    local other = OA.Store.ensure("p2", "Q")
    other.trade = { stage = 1, milestones = 0, credits = 0, trust = 0 }
    other.heli = { line = true }
    local open = M.specialOpen(other)
    eq(open, false, "the first stage")
    local ok, level = M.specialOpen(record)
    eq(ok, false)
    eq(level, 3)
    record.heli = { line = true }
    eq((M.specialOpen(record)), true)
end)

test("the offer's slot tells the options with the reward doubled, the days and the danger", function()
    local record = fieldRecord(3)
    M.game.zombieIntensity = function() return 0.22 end
    offered(record)
    local slot = M.specialSlot(record)
    eq(slot.state, "offer")
    for _, key in ipairs({ "a", "b" }) do
        local o = slot.options[key]
        eq(o.credits, 80500, "70,000 x 1.15")
        eq(o.trust, 230, "200 x 1.15")
        eq(o.days, 14)
        near(o.danger, 0.15, 1e-9)
        truthy(o.area.r > 0)
        eq(o.facility, Data.SPECIAL_BY_ID[o.id].facility)
    end
    M.game.zombieIntensity = nil
end)

test("the offer's places are picked in the band of the level above, two different ones", function()
    local record = fieldRecord(3)
    local lo, hi = Rewards.band(Rewards.specialBandLevel(3))
    for _ = 1, 10 do
        record.missions = nil
        M.offerSpecial(record, 3)
        local offer = M.special(record).offer
        for _, key in ipairs({ "a", "b" }) do
            local site = offer[key].site
            local d = OA.Places.distance(site.x, site.y, 0, 0)
            truthy(site.ground or (d >= lo and d <= hi), "in the band of level 4")
        end
        truthy(offer.a.site.key ~= offer.b.site.key, "not the same building")
    end
end)

test("a site on offer is not given to a story mission meanwhile; taken, it is used for the world", function()
    local record = fieldRecord(3)
    -- one public building in the band of both levels and nothing else
    M.game.list = { { x = 1500, y = 0, z = 0, x1 = 1497, y1 = -3, x2 = 1503, y2 = 3, z1 = 0, z2 = 0, home = false, rooms = 4 },
                    { x = 1600, y = 0, z = 0, x1 = 1597, y1 = -3, x2 = 1603, y2 = 3, z1 = 0, z2 = 0, home = false, rooms = 4 } }
    M.game.noGround = true
    truthy(M.offerSpecial(record, 3))
    eq(M.pickSite(record, 3, { want = "public" }), nil, "both on offer")
    truthy(M.acceptSpecial(record, "a"))
    local key = M.special(record).mission.site.key
    truthy(Story.world().used[key])
end)

test("two offers never repeat the last pair, and a request whose copy is not sent is likelier", function()
    spread()
    local record = fieldRecord(3)
    local sp = M.special(record)
    sp.last = { "can", "cold" }
    for _ = 1, 30 do
        local a, b = M.pickSpecials(record)
        truthy(a.id ~= "can" and a.id ~= "cold" and b.id ~= "can" and b.id ~= "cold", "not the last pair")
        truthy(a.id ~= b.id)
        truthy(a.form ~= b.form, "another form for the second")
    end
    -- every copy sent but one: that one is three times as likely
    local s = Story.section(record)
    sp.last = {}
    for _, entry in ipairs(Data.SPECIALS) do
        if entry.id ~= "handover" then s.requests[#s.requests + 1] = { id = entry.request, form = entry.form, no = 100 } end
    end
    local firsts = 0
    for _ = 1, 60 do
        local a = M.pickSpecials(record)
        if a.id == "handover" then firsts = firsts + 1 end
    end
    truthy(firsts >= 15, "the unsent one is first often: " .. firsts)
end)

local function accept(record, option)
    offered(record)
    return M.acceptSpecial(record, option or "a")
end

-- An offer of the form given (the data narrowed to its two entries).
local function formRecord(form)
    local record = fieldRecord(3)
    local list = {}
    for _, entry in ipairs(Data.SPECIALS) do
        if entry.form == form then list[#list + 1] = entry end
    end
    Data.SPECIALS = list
    return record
end

test("taking a request makes it the special mission, closes the other and files its request copy", function()
    local record = fieldRecord(3)
    local offer = offered(record)
    local main = M.active(record)
    truthy(main, "the main mission runs beside it")
    eq(M.acceptSpecial(record, "c"), false, "no such option")
    truthy(M.acceptSpecial(record, "b"))
    local sp = M.special(record)
    local m = sp.mission
    eq(sp.offer, nil, "the other closes")
    eq(m.kind, "special")
    eq(m.special, true)
    eq(m.title, offer.b.id)
    eq(m.form, offer.b.form)
    eq(m.credits, 70000)
    eq(m.trust, 200)
    near(m.deadline - m.issued, 14 * 24)
    eq(m.area.x, offer.b.area.x)
    eq(m.site, offer.b.site)
    eq(m.facility, Data.SPECIAL_BY_ID[offer.b.id].facility)
    eq(M.active(record), main, "the main mission is left")
    eq(sp.last[1], offer.a.id)
    eq(sp.last[2], offer.b.id)
    eq(M.acceptSpecial(record, "a"), false, "no second one")
    local title, brief = M.keys(m)
    eq(title, "IGUI_OA_Story_SpecialTitle_" .. offer.b.id)
    eq(#M.live(record), 2)
    truthy(m.scene, "its place gets a scene, as the main mission's does (Story/Scene)")
    -- the staff's request copy
    eq(#record.story.requests, 1)
    eq(m.request, 117)
    eq(record.story.requests[1].form, offer.b.form)
    eq(record.story.requests[1].id, Data.SPECIAL_BY_ID[offer.b.id].request, "the text the request is for")
    truthy(record.story.unread["r:117"])
    local info = M.specialSlot(record)
    eq(info.state, "mission")
    eq(info.mission.title, offer.b.id)
    eq(info.mission.request, 117)
    eq(info.mission.credits, 70000)
end)

test("a request taken is not made when the offer is gone or the line is not open", function()
    local record = fieldRecord(3)
    eq(M.acceptSpecial(record, "a"), false, "none offered")
    offered(record)
    record.heli = nil
    eq(M.acceptSpecial(record, "a"), false)
    eq(M.special(record).offer ~= nil, true, "the offer stays")
end)

test("the copy sent is the request's own, then the form's next, then none", function()
    local record = formRecord("exchange")
    Data.SPECIALS = { Data.SPECIAL_BY_ID.cold, Data.SPECIAL_BY_ID.can }
    offered(record)
    local offer = M.special(record).offer
    local first = offer.a.id
    truthy(M.acceptSpecial(record, "a"))
    eq(record.story.requests[1].id, Data.SPECIAL_BY_ID[first].request)
    local m = M.special(record).mission
    M.finish(record, m, "expired")
    TEST.hours = TEST.hours + 8 * 24
    tick(record)
    truthy(M.special(record).offer)
    Data.SPECIALS = { Data.SPECIAL_BY_ID.cold, Data.SPECIAL_BY_ID.can }
    M.special(record).last = {}
    truthy(M.acceptSpecial(record, "a"))
    eq(#record.story.requests, 2, "the other text of the form")
    local m2 = M.special(record).mission
    M.finish(record, m2, "expired")
    TEST.hours = TEST.hours + 8 * 24
    tick(record)
    M.special(record).last = {}
    truthy(M.acceptSpecial(record, "a"))
    eq(#record.story.requests, 2, "both texts have been sent: no copy")
    eq(M.special(record).mission.request, nil)
end)

test("an exchange: the sealed case is left at the place, the item turns up, the box pays twice a regular mission", function()
    local record = formRecord("exchange")
    local told = {}
    truthy(accept(record))
    local m = M.special(record).mission
    eq(m.swap.stage, "needcase")
    local seen = false
    for _, t in ipairs(M.game.supply) do if t == "OperationAcorn.SampleCase" then seen = true end end
    truthy(seen, "the case comes in the next supply crate")
    eq(m.items[1].key, "CASE")
    eq(m.items[1].mode, "case")
    eq(#M.game.requested >= 2, true)
    local p = m.site
    M.game.px, M.game.py = p.x + 5, p.y
    truthy(M.swap(record, {}))
    eq(m.swap.stage, "waiting")
    TEST.hours = TEST.hours + 2.5
    tick(record)
    eq(m.swap.stage, "done")
    eq(M.game.delivered.type, "OperationAcorn." .. m.swap.item)
    seal(record, m, "A", "box7")
    eq(m.state, "sealed")
    eq(M.active(record).state, "open", "the main mission is not touched")
    M.onSettled(record, { boxes = 1 })
    eq(record.trade.credits, 70000)
    eq(record.trade.trust, 200)
    eq(M.special(record).mission, nil)
end)

test("a retrieve: the container waits at the place with the item inside", function()
    local record = formRecord("fetch")
    truthy(accept(record))
    local m = M.special(record).mission
    eq(m.form, "fetch")
    local it = m.items[1]
    eq(it.key, "CASE")
    eq(it.mode, "case")
    eq(it.inside, Data.SPECIAL_BY_ID[m.title].item)
    eq(m.drop.item, it.inside)
    eq(it.mods.OA_Inside, it.inside)
    eq(#M.game.requested >= 1, true)
    seal(record, m, "A", "box1")
    eq(m.state, "sealed")
    M.onSettled(record, { boxes = 1 })
    eq(record.trade.credits, 70000)
end)

test("a field trade: the device is sent, the call is made on the spot, the helicopter pays", function()
    local record = formRecord("field")
    truthy(accept(record))
    local m = M.special(record).mission
    eq(m.field.stage, "needdevice")
    local seen = false
    for _, t in ipairs(M.game.supply) do if t == "OperationAcorn.FieldCallDevice" then seen = true end end
    truthy(seen)
    eq(m.items[1].type, "OperationAcorn." .. Data.SPECIAL_BY_ID[m.title].item)
    M.game.px, M.game.py = m.area.x, m.area.y
    local ok = M.fieldCall(record, {})
    truthy(ok)
    eq(m.state, "calling")
    eq(M.active(record).state, "open", "the main mission is open still")
    for _ = 1, 80 do tick(record); TEST.hours = TEST.hours + 1 / 6 end
    eq(M.special(record).mission, nil, "paid")
    eq(record.trade.credits, 70000)
    eq(M.state(record).streak, 0, "the special request does not count in the streak")
end)

test("a field call goes to the mission the player stands at, the story's or the special request's", function()
    local record = formRecord("field")
    truthy(accept(record))
    local special = M.special(record).mission
    M.game.px, M.game.py = 99999, 99999
    local ok, why = M.fieldCall(record, {})
    eq(ok, false); eq(why, "range")
    M.game.px, M.game.py = special.area.x, special.area.y
    M.game.noItem = true
    ok, why = M.fieldCall(record, {})
    eq(ok, false); eq(why, "device")
    M.game.noItem = false
    truthy(M.fieldCall(record, {}))
    eq(special.state, "calling")
    eq(M.fieldCall(record, {}), false, "nothing is left to call")
end)

test("the special request neither counts in the streak nor ends it, and keeps its own timer", function()
    local record = fieldRecord(3)
    local s = M.state(record)
    s.streak = 2
    truthy(accept(record))
    s.nextAt = 12345
    local m = M.special(record).mission
    M.finish(record, m, "done")
    eq(s.streak, 2)
    eq(s.bestStreak, 0)
    eq(s.nextAt, 12345, "the main mission's timer is not touched")
    eq(s.results.done, 1)
    near(M.special(record).nextAt, TEST.hours + 7 * 24)
    truthy(M.active(record), "the main mission is still there")
end)

test("a request past its fourteen days is an expired one, the next offer comes seven days after", function()
    local record = fieldRecord(3)
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    local streak = M.state(record)
    streak.streak = 2
    truthy(accept(record))
    local m = M.special(record).mission
    M.active(record).deadline = math.huge
    TEST.hours = TEST.hours + 13 * 24
    tick(record)
    eq(M.special(record).mission, m, "still open at thirteen days")
    TEST.hours = TEST.hours + 1.2 * 24
    local at = TEST.hours
    tick(record)
    eq(M.special(record).mission, nil)
    eq(M.state(record).results.expired, 1)
    eq(streak.streak, 2, "the streak is left")
    local expired
    for _, t in ipairs(told) do if t.key == "IGUI_OA_Title_Expired" then expired = t end end
    truthy(expired)
    eq(expired.sub, "IGUI_OA_Story_SpecialTitle_" .. m.title)
    near(M.special(record).nextAt, at + 7 * 24)
    TEST.hours = at + 6 * 24
    tick(record)
    eq(M.special(record).offer, nil, "not before the seven days")
    TEST.hours = at + 7 * 24 + 1
    tick(record)
    truthy(M.special(record).offer, "the next offer")
end)

test("the special request's expiry does not end the streak of the main missions", function()
    local record = fieldRecord(3)
    M.state(record).streak = 2
    truthy(accept(record))
    local special = M.special(record).mission
    special.deadline = TEST.hours - 1
    M.active(record).deadline = TEST.hours + 100
    tick(record)
    eq(M.special(record).mission, nil)
    eq(M.state(record).streak, 2)
end)

test("both missions can be sealed in one box and are paid together", function()
    local record = formRecord("fetch")
    truthy(accept(record))
    local special = M.special(record).mission
    local main = M.active(record)
    M.onSealed(record, "bx", { { info = { mission = M.itemId(main, "A") }, count = 1 },
        { info = { mission = M.itemId(special, "A") }, count = 1 } })
    eq(main.state, "sealed")
    eq(special.state, "sealed")
    M.onSettled(record, { boxes = 2 })
    eq(M.active(record), nil)
    eq(M.special(record).mission, nil)
    truthy(record.trade.credits >= 70000 + 35000)
    eq(M.state(record).results.done, 2)
end)

test("the economy sees a special request's item as a mission item while it is open", function()
    local record = formRecord("fetch")
    truthy(accept(record))
    local m = M.special(record).mission
    eq(Story.missionExpired(m.id), false)
    TEST.hours = TEST.hours + 15 * 24
    eq(Story.missionExpired(m.id), true)
end)

test("the special request's pieces are looked for with the main mission's: a lookup finds either", function()
    local record = formRecord("fetch")
    truthy(accept(record))
    local live = M.live(record)
    eq(#live, 2)
    eq(live[1], M.active(record))
    eq(live[2], M.special(record).mission)
    eq(#M.live(nil), 0)
    eq(#M.live({}), 0)
end)

test("the slot has nothing to tell before the line, waits between two requests, and comes back after", function()
    local record = fieldRecord(3)
    eq(M.specialSlot(record).state, "wait", "nothing offered yet")
    tick(record)
    eq(M.specialSlot(record).state, "offer")
    truthy(M.acceptSpecial(record, "a"))
    eq(M.specialSlot(record).state, "mission")
    M.finish(record, M.special(record).mission, "done")
    local slot = M.specialSlot(record)
    eq(slot.state, "wait")
    near(slot.nextIn, 7 * 24, 1e-6)
end)

test("a special request that ends with its character's death waits as after any ending of it", function()
    local record = fieldRecord(3)
    tick(record)
    truthy(M.acceptSpecial(record, "a"))
    eq(M.specialSlot(record).state, "mission")
    TEST.hours = TEST.hours + 2
    OA.Store.retire(record)
    M.retire(record)
    eq(M.special(record).mission, nil)
    local slot = M.specialSlot(record)
    eq(slot.state, "wait")
    near(slot.nextIn, 7 * 24, 1e-6)
end)

test("an old save without the slot is made one when a request is offered", function()
    local record = fieldRecord(3)
    eq(record.missions, nil)
    tick(record)
    truthy(record.missions.special.offer)
end)

test("the dot of the missions tab lights for a special request offered, not for the same one again", function()
    local record = fieldRecord(3)
    local Folder = OA.StoryFolder
    tick(record)
    local seq = Folder.missionSeq(record)
    truthy(seq >= M.special(record).offer.seq)
    eq(Folder.missionSeq({ missions = { active = { seq = 4 }, special = { offer = { seq = 9 } } } }), 9)
    eq(Folder.missionSeq({ missions = { active = { seq = 4 }, special = { mission = { seq = 6 } } } }), 6)
    eq(Folder.missionSeq({ missions = { active = { seq = 7 }, special = { mission = { seq = 6 } } } }), 7)
    eq(Folder.missionSeq({ missions = { special = { nextAt = 3 } } }), 0)
end)

test("trust lost is never below where the level began", function()
    local record = setup(2)
    record.trade.trust = 420
    eq(Story.loseTrust(record, 12), 12)
    eq(record.trade.trust, 408)
    record.trade.trust = 405
    eq(Story.loseTrust(record, 12), 5, "the second stage began at 400")
    eq(record.trade.trust, 400)
    eq(Story.loseTrust(record, 12), 0)
    eq(Story.loseTrust(record, 0), 0)
    eq(Story.loseTrust(record, nil), 0)
end)
