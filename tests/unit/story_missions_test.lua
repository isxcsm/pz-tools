-- The mission flow with a fake game: starting, story first at a new stage, deadlines judged at sealing, rewards at the
-- settlement, the choice, the cooler, the swap and the field call.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Missions"
local OA = OperationAcorn
local M = OA.Missions
local Story = OA.Story

-- A map of buildings in a ring around the origin, a player standing at the base, and a log of what was asked.
local function fakeGame()
    local g = { requested = {}, released = 0, radio = {}, supply = {}, taken = {}, noise = 0 }
    g.list = {}
    for i = 1, 600 do
        local a = i * 0.7
        local r = 100 + (i % 60) * 25
        g.list[i] = { x = math.floor(math.cos(a) * r), y = math.floor(math.sin(a) * r), z = 0,
                      x1 = 0, y1 = 0, x2 = 5, y2 = 5, z1 = 0, z2 = 0 }
        g.list[i].x1, g.list[i].y1 = g.list[i].x - 3, g.list[i].y - 3
        g.list[i].x2, g.list[i].y2 = g.list[i].x + 3, g.list[i].y + 3
    end
    g.buildingCount = function() return #g.list end
    g.building = function(i) return g.list[i].x, g.list[i].y, true end
    g.buildingInfo = function(i) return g.list[i] end
    g.playerPosition = function() return g.px or 0, g.py or 0, 0 end
    g.request = function(record, m, it) g.requested[#g.requested + 1] = { m = m.id, it = it } end
    g.release = function() g.released = g.released + 1 end
    g.takeItem = function(character, name) g.taken[#g.taken + 1] = name; return not g.noItem end
    g.takeMissionItem = function() return true end
    g.noise = function() g.noise_count = (g.noise_count or 0) + 1 end
    g.findItem = function() return g.cooler end
    g.setCoolerText = function() end
    g.deliverInside = function(record, m, it) it.placed = true; g.delivered = it end
    g.giveMissionItem = function(character, full, id) g.given = { full, id } end
    return g
end

local function setup(stage, milestones)
    local record = OA.Store.ensure("p1", "P")
    record.trade = { stage = stage, milestones = milestones or 0, credits = 0, trust = 0 }
    Story.setAnchor(record, 0, 0, 0)
    M.game = fakeGame()
    -- The trade part's pieces, as fakes that record what they are asked.
    OA.Trade = { radio = function(rec, key, args)
        M.game.radio[#M.game.radio + 1] = key
    end, addToDrop = function(rec, items)
        for _, it in ipairs(items) do M.game.supply[#M.game.supply + 1] = it.type end
    end }
    return record
end

test("nothing starts before the first stage", function()
    local record = setup(0)
    M.tick(record)
    eq(M.active(record), nil)
end)

test("entering stage 1 starts the evidence story first, far from the base", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    truthy(m, "a mission")
    eq(m.story, "evidence")
    eq(m.kind, "story")
    eq(m.level, 1)
    local p = OA.StoryData.PLACES[m.place]
    truthy(OA.Places.distance(p.x, p.y, 0, 0) >= 50, "not the base")
    eq(m.items[1].type, "OperationAcorn.EvidenceEnvelope")
    eq(m.items[1].lock, true, "the evidence room is locked")
    eq(#M.game.requested, 1, "its item is asked to be placed")
    -- Story reward is x1.5.
    eq(m.credits, 15000)
    eq(m.trust, 90)
    truthy(M.game.supply[1] == "OperationAcorn.SerumSheet", "the serum sheet goes to the crate")
end)

test("a story mission that is missed comes back at the next stage, and regulars come between", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 8 * 24
    M.tick(record)
    eq(M.active(record), nil, "expired")
    eq(record.missions.results.expired, 1)
    near(record.missions.nextAt, TEST.hours + 72)
    TEST.hours = TEST.hours + 3 * 24 + 1
    M.tick(record)
    local r = M.active(record)
    truthy(r, "next mission")
    eq(r.kind, "regular")
    eq(r.story, nil)
    local d = OA.Places.distance(r.items[1].x, r.items[1].y, 0, 0)
    truthy(d >= 150 - 5 and d <= 600 + 5, "in the first band: " .. d)
    eq(r.credits, 10000)
    eq(r.trust, 60)
    -- Stage 2: the clinic swap comes first, then the missed evidence waits for a regular.
    record.trade.stage = 2
    TEST.hours = TEST.hours + 9 * 24
    M.tick(record)  -- the regular expires and the stage is seen
    TEST.hours = TEST.hours + 3 * 24 + 1
    M.tick(record)
    eq(M.active(record).story, "clinic")
    eq(record.story.queue[1].id, "evidence", "the missed one is queued, not fresh")
    eq(record.story.queue[1].fresh, false)
end)

test("sealed in time is paid in full at the settlement", function()
    local record = setup(2)
    record.story = nil
    M.tick(record)
    local m = M.active(record)
    truthy(m)
    -- Skip the swap for this test: any story gets sealed the same way.
    TEST.hours = TEST.hours + 24
    local id = M.itemId(m, "A")
    M.onSealed(record, "box1", { { info = { mission = id }, count = 1 } })
    eq(m.state, "sealed")
    eq(record.trade.credits, 0, "not paid yet")
    M.onSettled(record, { credits = 1000, trust = 5 })
    eq(M.active(record), nil)
    -- 2nd stage story: 30,000 credits (the economy values the item in time at nothing; the whole reward is paid here).
    eq(record.trade.credits, 30000)
    eq(record.missions.results.done, 1)
    eq(record.story.done[m.story], "done")
end)

test("sealed after the deadline is a plain item and the mission is over", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 10 * 24
    M.onSealed(record, "box1", { { info = { mission = m.id }, count = 1 } })
    eq(M.active(record), nil)
    eq(record.trade.credits, 0)
    eq(record.missions.results.expired, 1)
end)

test("the deadline is judged at sealing, not at settlement", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 6 * 24
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    eq(m.state, "sealed")
    -- The helicopter comes two days after the deadline: still paid.
    TEST.hours = TEST.hours + 3 * 24
    M.tick(record)
    eq(m.state, "sealed", "tick does not expire a sealed mission")
    M.onSettled(record, { credits = 1000 })
    eq(record.missions.results.done, 1)
end)

test("a mission item of another mission is not judged", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    M.onSealed(record, "b", { { info = { mission = "M9999-1" }, count = 1 } })
    eq(m.state, "open")
end)

test("the choice mission offers two and closes the other", function()
    local record = setup(3)
    record.story = nil
    -- Skip the earlier stages' queue.
    local s = Story.section(record)
    s.seenStage = 2
    M.tick(record)
    local m = M.active(record)
    eq(m.story, "observation")
    eq(m.state, "offer")
    eq(#M.game.requested, 0, "nothing is placed before the choice")
    truthy(M.choose(record, "b"))
    eq(m.state, "open")
    eq(m.chosen, "b")
    eq(s.chosen.observation, "b")
    eq(m.items[1].type, "OperationAcorn.FarmJournal")
    eq(#M.game.requested, 1)
    eq(M.choose(record, "a"), false, "no second choice")
end)

test("the far choice (the airfield) ignores the band", function()
    local record = setup(3)
    local s = Story.section(record)
    s.seenStage = 2
    M.tick(record)
    truthy(M.choose(record, "a"))
    local m = M.active(record)
    eq(m.place, "brandenburg_airfield")
    eq(m.items[1].type, "OperationAcorn.WeatherLog")
end)

test("the cooler's reward falls with its warming", function()
    local record = setup(4)
    local s = Story.section(record)
    s.seenStage = 3
    M.tick(record)
    local m = M.active(record)
    eq(m.story, "cooler")
    M.game.cooler = {}
    M.tick(record)
    truthy(m.carry.start, "the clock starts when it is carried")
    TEST.hours = TEST.hours + 30
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    -- The deadline is 7 days; 30 hours is within. Warming 0.5/h from 4C hits the cap: 0.6 of 50,000 x 1.5.
    eq(m.state, "sealed")
    eq(m.cooler.grade, "bad")
    eq(m.pay.credits, 45000)
    eq(m.pay.trust, 270)
    M.onSettled(record, {})
    eq(record.trade.credits, 45000)
    -- The next crate's manifest carries the cooler remark first.
    eq(record.story.noteQueue[1], "cooler_bad")
end)

test("a good cooler keeps the whole reward", function()
    local record = setup(4)
    Story.section(record).seenStage = 3
    M.tick(record)
    local m = M.active(record)
    M.game.cooler = {}
    M.tick(record)
    TEST.hours = TEST.hours + 4
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    eq(m.pay.credits, 75000)
    eq(m.cooler.grade, "good")
end)

test("the swap: case, wait near the place, then the record appears", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    M.tick(record)
    local m = M.active(record)
    eq(m.story, "clinic")
    eq(m.swap.stage, "needcase")
    local p = OA.StoryData.PLACES[m.place]
    M.game.px, M.game.py = p.x + 5, p.y
    truthy(M.swap(record, {}))
    eq(m.swap.stage, "waiting")
    for _ = 1, 11 do M.tick(record); TEST.hours = TEST.hours + 1 / 6 end
    eq(m.swap.stage, "waiting", "not yet two hours")
    for _ = 1, 3 do M.tick(record); TEST.hours = TEST.hours + 1 / 6 end
    eq(m.swap.stage, "done")
    eq(M.game.delivered.type, "OperationAcorn.ClinicRecord")
end)

test("the swap waits only while the player stays near", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    M.tick(record)
    local m = M.active(record)
    local p = OA.StoryData.PLACES[m.place]
    M.game.px, M.game.py = p.x, p.y
    M.swap(record, {})
    M.game.px, M.game.py = p.x + 5000, p.y
    for _ = 1, 30 do M.tick(record); TEST.hours = TEST.hours + 1 / 6 end
    eq(m.swap.stage, "waiting")
end)

-- The cooler mission open, with the fake game's cooler not yet in hand.
local function coolerMission()
    local record = setup(4)
    Story.section(record).seenStage = 3
    M.tick(record)
    local m = M.active(record)
    eq(m.story, "cooler")
    return record, m
end

test("the cooler's clock starts as it is picked up, not at the next look", function()
    local record, m = coolerMission()
    M.game.holds = function(item, id) return item.mission == id end
    TEST.hours = 10
    M.pickedUp(record, { mission = "other" })
    eq(m.carry.start, nil, "another item")
    M.pickedUp(record, { mission = m.id })
    eq(m.carry.start, 10)
    TEST.hours = 11
    M.game.cooler = {}
    M.tick(record)
    eq(m.carry.start, 10, "the look keeps the pickup's time")
    M.pickedUp(record, { mission = m.id })
    eq(m.carry.start, 10, "only the first pickup")
end)

test("a cooler the pickup did not see starts from the last look that missed it", function()
    local record, m = coolerMission()
    TEST.hours = 10
    M.tick(record)
    eq(m.carry.looked, 10)
    TEST.hours = 11.5
    M.game.cooler = {}
    M.tick(record)
    eq(m.carry.start, 10, "never later than it could have been taken")
end)

test("fast-forwarded, the look for the cooler runs at most once each CARRY_LOOK_MS of real time", function()
    local record, m = coolerMission()
    local looks = 0
    M.game.findItem = function() looks = looks + 1; return M.game.cooler end
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    M.tick(record)
    eq(looks, 1)
    for _ = 1, 8 do
        clock = clock + 600
        TEST.hours = TEST.hours + 1 / 6
        M.tick(record)
    end
    eq(looks, 1, "none within CARRY_LOOK_MS")
    clock = clock + M.CARRY_LOOK_MS
    M.tick(record)
    eq(looks, 2)
    truthy(M.CARRY_LOOK_MS < 25000, "the default speed (25 s for ten game minutes) looks every time")
end)

test("the swap's wait counts game time, not looks", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    M.tick(record)
    local m = M.active(record)
    local p = OA.StoryData.PLACES[m.place]
    M.game.px, M.game.py = p.x, p.y
    TEST.hours = 100
    truthy(M.swap(record, {}))
    -- many looks in the same game minute (a batch) add nothing
    for _ = 1, 30 do M.tick(record) end
    eq(m.swap.stage, "waiting", "a batch of looks is no time")
    near(m.swap.waited, 0)
    -- skipped looks: two hours in one step are two hours
    TEST.hours = 102
    M.tick(record)
    eq(m.swap.stage, "done")
end)

test("the swap's wait stops while the player is away and goes on when they are back", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    M.tick(record)
    local m = M.active(record)
    local p = OA.StoryData.PLACES[m.place]
    M.game.px, M.game.py = p.x, p.y
    TEST.hours = 100
    M.swap(record, {})
    TEST.hours = 101
    M.tick(record)
    near(m.swap.waited, 1)
    M.game.px = p.x + 5000
    TEST.hours = 105
    M.tick(record)
    near(m.swap.waited, 1, 1e-9, "the away time is not counted")
    M.game.px = p.x
    TEST.hours = 106
    M.tick(record)
    near(m.swap.waited, 1, 1e-9, "counting again from here")
    eq(m.swap.stage, "waiting")
    TEST.hours = 107
    M.tick(record)
    eq(m.swap.stage, "done")
end)

test("the field call seals on the spot and the helicopter pays", function()
    local record = setup(5)
    Story.section(record).seenStage = 4
    M.tick(record)
    local m = M.active(record)
    eq(m.story, "gym")
    eq(m.field.stage, "needdevice")
    M.game.px, M.game.py = m.area.x, m.area.y
    local ok = M.fieldCall(record, {})
    truthy(ok)
    eq(m.state, "calling")
    for _ = 1, 30 do M.tick(record); TEST.hours = TEST.hours + 1 / 6 end
    truthy((M.game.noise_count or 0) > 0, "the helicopter's noise went out")
    eq(M.active(record), nil, "paid")
    eq(record.trade.credits, 105000)
end)

test("the field call needs the place and the device", function()
    local record = setup(5)
    Story.section(record).seenStage = 4
    M.tick(record)
    M.game.px, M.game.py = 99999, 99999
    local ok, why = M.fieldCall(record, {})
    eq(ok, false); eq(why, "range")
    local m = M.active(record)
    M.game.px, M.game.py = m.area.x, m.area.y
    M.game.noItem = true
    ok, why = M.fieldCall(record, {})
    eq(ok, false); eq(why, "device")
end)

test("a sealed mission whose box never settles is lost after a while", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    TEST.hours = TEST.hours + 15 * 24
    M.tick(record)
    eq(M.active(record), nil)
    eq(record.missions.results.lost, 1)
end)

test("after the handover a contract mission pool replaces the regular one", function()
    local record = setup(5, 3)
    local s = Story.section(record)
    s.seenStage = 5; s.seenMilestones = 3; s.handover = true
    s.done.ward, s.done.cells, s.done.soil, s.done.handover = "done", "done", "done", "done"
    local kinds = {}
    for i = 1, 24 do
        M.tick(record)
        local m = M.active(record)
        truthy(m, "mission " .. i)
        eq(m.level, 6)
        kinds[m.contract or m.title] = true
        M.finish(record, m, "expired")
        TEST.hours = TEST.hours + 4 * 24
    end
    local count = 0
    for _ in pairs(kinds) do count = count + 1 end
    truthy(count >= 3, "several kinds come: " .. count)
end)

test("a mission is one at a time", function()
    local record = setup(1)
    M.tick(record)
    local first = M.active(record)
    TEST.hours = TEST.hours + 100
    M.tick(record)
    TEST.hours = TEST.hours + 24 * 30
    -- Expired, then a gap before the next.
    M.tick(record)
    eq(M.active(record), nil)
    truthy(first.id ~= nil)
end)

test("the economy sees a mission item as plain once its mission is over, late, or not this character's", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    eq(Story.missionExpired(m.id), false, "open and in time")
    eq(Story.missionExpired(m.id .. "#A"), false, "a piece of it")
    eq(Story.missionExpired("M9999-1"), true, "someone else's")
    eq(Story.missionExpired("junk"), true)
    eq(Story.missionExpired(nil), true)
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    TEST.hours = TEST.hours + 20 * 24
    eq(Story.missionExpired(m.id), false, "sealed stays a mission item until it is settled")
    M.onSettled(record, {})
    eq(Story.missionExpired(m.id), true, "over")
end)

test("a mission item past the deadline counts as plain before it is sealed", function()
    local record = setup(1)
    M.tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 8 * 24
    eq(Story.missionExpired(m.id), true)
end)
