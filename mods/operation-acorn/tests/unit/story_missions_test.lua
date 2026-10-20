-- The mission flow with a fake game: starting, story first at a new stage, deadlines judged at sealing, rewards at the
-- settlement, the choice, the cooler, the swap and the field call.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Folder"
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
    fakeSites(g)
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
    OA.Comms.played(record, "S1", 1)
    -- The plain pickup only, never an urgent one and no distance pay: the tests that follow the pay count on it. The
    -- mixed kinds, the urgent one and the distance pay have their own tests (story_devices_test).
    OA.StoryData.REGULAR = { { item = "MissionEnvelope", weight = 1 } }
    OA.Rewards.URGENT_CHANCE = 0
    OA.Rewards.FAR_MAX = 0
    M.game = fakeGame()
    -- The trade part's pieces, as fakes that record what they are asked.
    OA.Trade = { radio = function(rec, key, args)
        M.game.radio[#M.game.radio + 1] = key
    end, addToDrop = function(rec, items)
        for _, it in ipairs(items) do M.game.supply[#M.game.supply + 1] = it.type end
    end }
    return record
end


-- Missions wait to be started (Missions.launch); these tests look at them running: a tick starts what it offered (a
-- choice with `option`, "a" if none), and a story's briefing is over at once.
local function taken(record, option)
    local m = M.active(record)
    if m and m.state == "waiting" then
        M.launch(record, option or "a")
        m = M.active(record)
        if m and m.state == "briefing" then M.briefed(record, m.brief) end
    end
    return M.active(record)
end

local function tick(record, option)
    M.tick(record)
    taken(record, option)
end

-- The titles the missions show the player.
local function listenTitles()
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    return told
end

test("a new request, its pay and its expiry each have a title; the pay names it, with the credits", function()
    local record = setup(2)
    record.story = nil
    local told = listenTitles()
    M.tick(record)
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_NewRequest")
    eq(told[1].style, "notice")
    eq(M.active(record).state, "waiting", "offered: no deadline before it is started")
    eq(M.active(record).deadline, nil)
    local m = taken(record)
    eq(m.kind, "story")
    eq(#told, 2, "a story mission starts when its briefing is over")
    eq(told[2].key, "IGUI_OA_Title_Launched", "the short title after the call")
    eq(told[2].sub, (M.keys(m)))
    M.onSealed(record, "box1", { { info = { mission = M.itemId(m, "A") }, count = 1 } })
    M.onSettled(record, { credits = 1000, trust = 5 })
    eq(told[3].key, "IGUI_OA_Title_Paid")
    eq(told[3].style, "dust")
    eq(told[3].sub, "IGUI_OA_Title_PaidSub")
    eq(told[3].subArgs[1].key, (M.keys(m)))
    eq(told[3].subArgs[1].key, "IGUI_OA_Story_Title_" .. m.title)
    eq(told[3].subArgs[2].credits, 30000)
    -- the next one runs out
    TEST.hours = TEST.hours + 3 * 24 + 1
    tick(record)
    local n = M.active(record)
    if n.kind ~= "story" then
        eq(told[#told].key, "IGUI_OA_Title_Launched", "a regular one's start has its short title")
        eq(told[#told].sub, (M.keys(n)))
    end
    TEST.hours = TEST.hours + 22 * 24
    tick(record)
    eq(M.active(record), nil)
    eq(told[#told].key, "IGUI_OA_Title_Expired")
    eq(told[#told].style, "sink")
    eq(told[#told].sub, (M.keys(n)))
end)

test("a mission's keys follow its kind", function()
    eq((M.keys({ kind = "regular", title = "MissionTape" })), "IGUI_OA_Story_RegTitle_MissionTape")
    local title, brief = M.keys({ kind = "contract", title = "stake" })
    eq(title, "IGUI_OA_Story_ConTitle_stake")
    eq(brief, "IGUI_OA_Story_ConBrief_stake")
    eq((M.keys({ kind = "story", title = "clinic" })), "IGUI_OA_Story_Title_clinic")
end)

test("no mission is offered before the call that tells of them has played", function()
    local record = setup(2)
    record.story = nil
    OA.Comms.section(record).played.S1 = nil
    OA.Comms.fire(record, "settled") -- fired, not played: a passed tier does not drop it
    M.tick(record)
    eq(M.active(record), nil)
    OA.Comms.section(record).dropped.S1 = true
    M.tick(record)
    truthy(M.active(record), "a dropped call holds nothing up")
end)

test("the call's line that says the missions are sent offers the first at once, with no title over the call", function()
    local record = setup(1)
    record.story = nil
    OA.Comms.section(record).played.S1 = nil
    local titles = 0
    OA.Sync.listen("title", function() titles = titles + 1 end)
    eq(M.opened(record), false)
    truthy(M.openByCall(record, true), "offered as the line starts")
    truthy(M.active(record))
    eq(M.opened(record), true, "open before the call has ended")
    eq(titles, 0, "the call says it")
    eq(M.openByCall(record, true), nil, "once")
end)

test("a skipped or played opening call offers the first at once if its line has not, with the title", function()
    local record = setup(1)
    record.story = nil
    OA.Comms.section(record).played.S1 = nil
    local titles = 0
    OA.Sync.listen("title", function(_, d) if d.key == "IGUI_OA_Title_NewRequest" then titles = titles + 1 end end)
    OA.Comms.played(record, "S1", 1)
    Story.callPlayed(record, "S1")
    truthy(M.active(record))
    eq(titles, 1)
    local cued = false
    for _, line in ipairs(OA.CommsData.BY_ID.S1.lines) do cued = cued or line.cue == "missions" end
    truthy(cued, "S1 carries the cue"); eq(OA.CommsData.BY_ID.K0M.lines[1].cue, "missions")
end)

test("an offer waits without a deadline, a place asked for or a circle until it is started", function()
    local record = setup(2)
    for id in pairs(OA.StoryData.STORIES) do Story.section(record).done[id] = "done" end
    M.tick(record)
    local m = M.active(record)
    eq(m.kind, "regular")
    eq(m.state, "waiting")
    eq(m.deadline, nil)
    near(m.span, 14 * 24, 1e-6, "a regular mission's days")
    eq(#M.game.requested, 0)
    eq(OA.StoryView.shown(record), nil, "no circle on the map")
    eq(#M.live(record), 0)
    TEST.hours = TEST.hours + 40 * 24
    M.tick(record)
    eq(M.active(record), m, "it never runs out while it waits")
    local told = listenTitles()
    truthy(M.launch(record))
    eq(told[#told].key, "IGUI_OA_Title_Launched", "a short title as it starts")
    eq(m.state, "open")
    eq(m.issued, TEST.hours)
    near(m.deadline, TEST.hours + 14 * 24, 1e-6)
    eq(#M.game.requested, 1)
    eq(OA.StoryView.shown(record), m)
    eq(M.launch(record), false, "started once")
end)

test("an offer taken again stays an offer; a stage's story mission takes the place of a regular offer", function()
    local record = setup(2)
    for id in pairs(OA.StoryData.STORIES) do Story.section(record).done[id] = "done" end
    record.trade.trust = 1000
    M.tick(record)
    local m = M.active(record)
    truthy(M.reroll(record))
    local n = M.active(record)
    truthy(n.id ~= m.id)
    eq(n.state, "waiting")
    eq(n.deadline, nil)
    Story.section(record).done.cooler = nil
    Story.queueStory(record, "cooler", true)
    M.tick(record)
    local c = M.active(record)
    eq(c.story, "cooler")
    eq(c.state, "waiting")
    near(c.span, 21 * 24, 1e-6, "a story's days")
    eq(c.site, nil, "its site is picked once its briefing is over")
    local ok, brief = M.launch(record)
    truthy(ok)
    eq(brief, "brief")
    eq(c.brief, "B4")
    M.tick(record)
    eq(M.active(record), c, "waits for its briefing")
    OA.Comms.played(record, "B4", 4)
    Story.callPlayed(record, "B4")
    local made = M.active(record)
    eq(made.state, "open")
    eq(made.id, c.id, "the number it was offered under")
    truthy(made.site)
end)

test("nothing starts before the first stage", function()
    local record = setup(0)
    tick(record)
    eq(M.active(record), nil)
end)

test("entering stage 1 starts the evidence story first, far from the base", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    truthy(m, "a mission")
    eq(m.story, "evidence")
    eq(m.kind, "story")
    eq(m.level, 1)
    eq(m.seq, 1, "numbered, for the terminal's dot")
    eq(OA.StoryFolder.missionSeq(record), 1)
    local p = m.site
    truthy(OA.Places.distance(p.x, p.y, 0, 0) >= 50, "not the base")
    eq(m.facility, "police")
    truthy(Story.world().used[p.key], "the site is used for the world")
    eq(Story.section(record).sites.evidence, p, "kept for the revisit")
    eq(m.items[1].mods.OA_Variant, "police")
    eq(m.items[1].type, "OperationAcorn.EvidenceEnvelope")
    eq(m.items[1].lock, true, "the evidence room is locked")
    eq(#M.game.requested, 1, "its item is asked to be placed")
    -- Story reward is x1.5.
    eq(m.credits, 15000)
    eq(m.trust, 90)
    eq(Story.section(record).papers[1].doc, "serum_sheet", "the serum sheet waits for a crate")
end)

test("a story mission that is missed comes back once a regular has come between", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 22 * 24
    tick(record)
    eq(M.active(record), nil, "expired")
    eq(record.missions.results.expired, 1)
    near(record.missions.nextAt, TEST.hours + 72)
    TEST.hours = TEST.hours + 3 * 24 + 1
    tick(record)
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
    TEST.hours = TEST.hours + 15 * 24
    tick(record)  -- the regular expires and the stage is seen
    TEST.hours = TEST.hours + 3 * 24 + 1
    tick(record)
    eq(M.active(record).story, "clinic")
    eq(record.story.queue[1].id, "evidence", "the missed one is queued, not fresh")
    eq(record.story.queue[1].fresh, false)
end)

test("sealed in time is paid in full at the settlement", function()
    local record = setup(2)
    record.story = nil
    tick(record)
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
    tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 22 * 24
    M.onSealed(record, "box1", { { info = { mission = m.id }, count = 1 } })
    eq(M.active(record), nil)
    eq(record.trade.credits, 0)
    eq(record.missions.results.expired, 1)
end)

test("the deadline is judged at sealing, not at settlement", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 20 * 24
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    eq(m.state, "sealed")
    -- The helicopter comes two days after the deadline: still paid.
    TEST.hours = TEST.hours + 3 * 24
    tick(record)
    eq(m.state, "sealed", "tick does not expire a sealed mission")
    M.onSettled(record, { credits = 1000 })
    eq(record.missions.results.done, 1)
end)

test("a mission item of another mission is not judged", function()
    local record = setup(1)
    tick(record)
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
    eq(m.state, "waiting")
    eq(#M.game.requested, 0, "nothing is placed before the choice")
    eq(M.launch(record, "c"), false, "no such option")
    local ok, brief = M.launch(record, "b")
    truthy(ok)
    eq(brief, "brief")
    eq(m.state, "briefing")
    eq(m.brief, "B3b")
    eq(OA.Comms.next(record, "terminal").id, "B3b", "the option's briefing plays")
    eq(#M.game.requested, 0, "nothing placed before the briefing is over")
    M.briefed(record, "S2")
    eq(M.active(record), m, "another call does not start it")
    OA.Comms.played(record, "B3b", 3)
    Story.callPlayed(record, "B3b")
    m = M.active(record)
    eq(m.state, "open")
    eq(m.chosen, "b")
    eq(s.chosen.observation, "b")
    eq(m.items[1].type, "OperationAcorn.FarmJournal")
    eq(#M.game.requested, 1)
    near(m.deadline - m.issued, 21 * 24, 1e-6, "a story's days")
    eq(M.launch(record, "a"), false, "no second choice")
end)

test("the choice's far option is a house far in the band, at the farm facility", function()
    local record = setup(3)
    local s = Story.section(record)
    s.seenStage = 2
    tick(record, "a")
    local m = M.active(record)
    eq(m.facility, "farm")
    eq(m.items[1].type, "OperationAcorn.WeatherLog")
    eq(m.items[1].mods.OA_Variant, "farm")
    local lo, hi = OA.Rewards.band(m.level)
    local d = OA.Places.distance(m.site.x, m.site.y, 0, 0)
    truthy(d >= lo and d <= hi, "in the band")
    truthy(d >= lo + (hi - lo) / 2, "in the far part of it")
end)

test("a story site is never one used before in the world, the base's building or a searched one", function()
    local record = setup(1)
    local all = M.game.sitesInBand(0, 0, OA.Rewards.band(1))
    -- every building of the band but one is used, searched or the base
    local keep = all[1].key
    for i = 2, #all do
        if i == 2 then M.game.baseKey = all[i].key
        elseif i - math.floor(i / 2) * 2 == 0 then Story.useSite(all[i].key)
        else Story.touchBuilding(all[i].key) end
    end
    tick(record)
    eq(M.active(record).site.key, keep)
end)

test("with no building left in the band a story site is open ground, the piece on its floor", function()
    local record = setup(1)
    M.game.list = {}
    tick(record)
    local m = M.active(record)
    eq(m.story, "evidence")
    eq(m.site.ground, true)
    eq(m.items[1].mode, "floor")
    eq(m.items[1].lock, nil, "nothing to lock")
end)

test("with no building in the band the band reaches further out first, then open ground", function()
    local record = setup(1)
    local lo, hi = OA.Rewards.band(1)
    M.game.list = { { x = math.floor(hi * 1.4), y = 0 } }
    local site = M.pickSite(record, 1, { want = "public" })
    eq(site.key, tostring(math.floor(hi * 1.4)) .. ",0")
    M.game.list = { { x = math.floor(hi * 2.5), y = 0 } }
    eq(M.pickSite(record, 1, { want = "public" }).ground, true, "too far out")
    truthy(lo < hi)
end)

test("a story site wanted on open ground is never a building", function()
    local record = setup(4)
    Story.section(record).seenStage = 3
    tick(record)
    local m = M.active(record)
    eq(m.story, "cooler")
    eq(m.site.ground, true)
    eq(m.facility, "army")
end)

test("a site wanted with more than one floor is such a building first, else any", function()
    local record = setup(1)
    local all = M.game.sitesInBand(0, 0, OA.Rewards.band(1))
    local tall
    for _, b in ipairs(M.game.list) do
        b.z1, b.z2 = 0, 0
        for _, s in ipairs(all) do
            if s.home and s.key == tostring(b.x) .. "," .. tostring(b.y) then tall = tall or b end
        end
    end
    tall.z2 = 1
    for _ = 1, 10 do eq(M.pickSite(record, 1, { want = "far", up = true }).key, tostring(tall.x) .. "," .. tostring(tall.y)) end
    tall.z2 = 0
    truthy(M.pickSite(record, 1, { want = "far", up = true }), "none of more: any")
    truthy(#all > 1)
end)

test("no building and no open ground: no story mission", function()
    local record = setup(1)
    M.game.list = {}
    M.game.noGround = true
    eq(M.pickSite(record, 1, { want = "public" }), nil)
end)

test("the cooler's reward falls with its warming", function()
    local record = setup(4)
    local s = Story.section(record)
    s.seenStage = 3
    tick(record)
    local m = M.active(record)
    eq(m.story, "cooler")
    M.game.cooler = {}
    tick(record)
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
    tick(record)
    local m = M.active(record)
    M.game.cooler = {}
    tick(record)
    TEST.hours = TEST.hours + 4
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    eq(m.pay.credits, 75000)
    eq(m.cooler.grade, "good")
end)

test("the swap: case, wait near the place, then the record appears", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    tick(record)
    local m = M.active(record)
    eq(m.story, "clinic")
    eq(m.swap.stage, "needcase")
    local wanted = M.describe(record).item
    truthy(wanted and wanted:find("ClinicRecord"), "the card names the record, not the case left behind")
    local p = m.site
    M.game.px, M.game.py = p.x + 5, p.y
    truthy(M.swap(record, {}))
    eq(m.swap.stage, "waiting")
    eq(M.describe(record).item, wanted, "still the record while waiting")
    for _ = 1, 11 do tick(record); TEST.hours = TEST.hours + 1 / 6 end
    eq(m.swap.stage, "waiting", "not yet two hours")
    for _ = 1, 3 do tick(record); TEST.hours = TEST.hours + 1 / 6 end
    eq(m.swap.stage, "done")
    eq(M.game.delivered.type, "OperationAcorn.ClinicRecord")
end)

test("the swap waits only while the player stays near", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    tick(record)
    local m = M.active(record)
    local p = m.site
    M.game.px, M.game.py = p.x, p.y
    M.swap(record, {})
    M.game.px, M.game.py = p.x + 5000, p.y
    for _ = 1, 30 do tick(record); TEST.hours = TEST.hours + 1 / 6 end
    eq(m.swap.stage, "waiting")
end)

-- The cooler mission open, with the fake game's cooler not yet in hand.
local function coolerMission()
    local record = setup(4)
    Story.section(record).seenStage = 3
    tick(record)
    local m = M.active(record)
    eq(m.story, "cooler")
    return record, m
end

test("the cooler's clock starts as it is picked up, not at the next look", function()
    local record, m = coolerMission()
    M.game.holds = function(item, id) return item.mission == id end
    TEST.hours = 10
    local function noData() return false end
    M.pickedUp(record, { mission = "other", hasModData = noData })
    eq(m.carry.start, nil, "another item")
    M.pickedUp(record, { mission = m.id, hasModData = noData })
    eq(m.carry.start, 10)
    TEST.hours = 11
    M.game.cooler = {}
    tick(record)
    eq(m.carry.start, 10, "the look keeps the pickup's time")
    M.pickedUp(record, { mission = m.id, hasModData = noData })
    eq(m.carry.start, 10, "only the first pickup")
end)

test("a cooler the pickup did not see starts from the last look that missed it", function()
    local record, m = coolerMission()
    TEST.hours = 10
    tick(record)
    eq(m.carry.looked, 10)
    TEST.hours = 11.5
    M.game.cooler = {}
    tick(record)
    eq(m.carry.start, 10, "never later than it could have been taken")
end)

test("fast-forwarded, the look for the cooler runs at most once each CARRY_LOOK_MS of real time", function()
    local record, m = coolerMission()
    local looks = 0
    M.game.findItem = function() looks = looks + 1; return M.game.cooler end
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    tick(record)
    eq(looks, 1)
    for _ = 1, 8 do
        clock = clock + 600
        TEST.hours = TEST.hours + 1 / 6
        tick(record)
    end
    eq(looks, 1, "none within CARRY_LOOK_MS")
    clock = clock + M.CARRY_LOOK_MS
    tick(record)
    eq(looks, 2)
    truthy(M.CARRY_LOOK_MS < 25000, "the default speed (25 s for ten game minutes) looks every time")
end)

test("the swap's wait counts game time, not looks", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    tick(record)
    local m = M.active(record)
    local p = m.site
    M.game.px, M.game.py = p.x, p.y
    TEST.hours = 100
    truthy(M.swap(record, {}))
    -- many looks in the same game minute (a batch) add nothing
    for _ = 1, 30 do tick(record) end
    eq(m.swap.stage, "waiting", "a batch of looks is no time")
    near(m.swap.waited, 0)
    -- skipped looks: two hours in one step are two hours
    TEST.hours = 102
    tick(record)
    eq(m.swap.stage, "done")
end)

test("the swap: monologues as the case is left and the wait ends; the record comes once the drop is out of sight", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    tick(record)
    local m = M.active(record)
    local p = m.site
    M.game.px, M.game.py = p.x, p.y
    local seen = true
    M.game.dropSeen = function() return seen end
    local progress = {}
    require "OperationAcorn/Story/Stage"
    local stage = OperationAcorn.Stage
    local was = stage and stage.progress
    if stage then stage.progress = function(_, _, name, f) progress[#progress + 1] = name .. ":" .. f end end
    TEST.hours = 100
    truthy(M.swap(record, {}))
    local played = OperationAcorn.Comms.section(record).played
    truthy(played.S2F_put, "the case left")
    TEST.hours = 101
    tick(record)
    eq(progress[#progress], "wait:0.5", "the stage follows the wait")
    TEST.hours = 102
    tick(record)
    eq(m.swap.stage, "ready", "over, the drop in sight")
    truthy(played.S2F_waited, "the wait over")
    eq(M.game.delivered, nil)
    TEST.hours = 102.2
    tick(record)
    eq(m.swap.stage, "ready", "still in sight")
    seen = false
    M.game.px = p.x + 5000
    TEST.hours = 102.4
    tick(record)
    eq(m.swap.stage, "done", "out of sight, wherever the player is")
    eq(M.game.delivered.type, "OperationAcorn.ClinicRecord")
    M.game.dropSeen = nil
    if stage then stage.progress = was end
end)

test("the swap's wait stops while the player is away and goes on when they are back", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    tick(record)
    local m = M.active(record)
    local p = m.site
    M.game.px, M.game.py = p.x, p.y
    TEST.hours = 100
    M.swap(record, {})
    TEST.hours = 101
    tick(record)
    near(m.swap.waited, 1)
    M.game.px = p.x + 5000
    TEST.hours = 105
    tick(record)
    near(m.swap.waited, 1, 1e-9, "the away time is not counted")
    M.game.px = p.x
    TEST.hours = 106
    tick(record)
    near(m.swap.waited, 1, 1e-9, "counting again from here")
    eq(m.swap.stage, "waiting")
    TEST.hours = 107
    tick(record)
    eq(m.swap.stage, "done")
end)

test("the field call seals on the spot and the helicopter pays", function()
    local record = setup(5)
    Story.section(record).seenStage = 4
    tick(record)
    local m = M.active(record)
    eq(m.story, "gym")
    eq(m.field.stage, "needdevice")
    M.onOpened(record, { { type = "Base.Plank", count = 1 } })
    eq(m.field.stage, "needdevice", "a crate without the device")
    M.onOpened(record, { { type = OA.StoryData.fullType("FieldCallDevice"), count = 1 } })
    eq(m.field.stage, "device", "the crate with it opened")
    M.game.px, M.game.py = m.area.x, m.area.y
    local told = {}
    OA.Sync.listen("notice", function(id, detail) told[#told + 1] = { id = id, detail = detail } end)
    local ok = M.fieldCall(record, {})
    truthy(ok)
    eq(m.state, "calling")
    eq(#told, 1, "the player is told the call went out")
    eq(told[1].id, record.id)
    eq(told[1].detail.key, "IGUI_OA_Story_UI_Field_calling")
    eq(record.radio, nil, "no radio line is written")
    for _ = 1, 30 do tick(record); TEST.hours = TEST.hours + 1 / 6 end
    truthy((M.game.noise_count or 0) > 0, "the helicopter's noise went out")
    eq(M.active(record), nil, "paid")
    eq(record.trade.credits, 105000)
end)

test("the field call needs the place and the device", function()
    local record = setup(5)
    Story.section(record).seenStage = 4
    tick(record)
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
    tick(record)
    local m = M.active(record)
    M.onSealed(record, "b", { { info = { mission = m.id }, count = 1 } })
    local told = listenTitles()
    TEST.hours = TEST.hours + 15 * 24
    tick(record)
    eq(M.active(record), nil)
    eq(record.missions.results.lost, 1)
    eq(told[1].key, "IGUI_OA_Title_WrittenOff", "the player is told")
end)

test("after the handover a contract mission pool replaces the regular one", function()
    local record = setup(5, 3)
    local s = Story.section(record)
    s.seenStage = 5; s.seenMilestones = 3; s.handover = true
    s.done.ward, s.done.cells, s.done.soil, s.done.handover = "done", "done", "done", "done"
    local kinds = {}
    for i = 1, 24 do
        tick(record)
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

test("the drop site check leads to a site not yet seen while there is one", function()
    require "OperationAcorn/Story/Sites"
    local Sites = OA.Sites
    local record = setup(5, 3)
    local s = Story.section(record)
    s.seenStage = 5; s.seenMilestones = 3; s.handover = true
    s.done.ward, s.done.cells, s.done.soil, s.done.handover = "done", "done", "done", "done"
    local sec = OA.Store.world("sites")
    sec.made, sec.origin = true, { x = 0, y = 0 }
    sec.list = { { n = 1, x = 900, y = 0, stake = 211, state = "placed" },
                 { n = 2, x = -900, y = 0, stake = 322, state = "placed" },
                 { n = 3, x = 0, y = 900, stake = 433, state = "placed" } }
    local contracts = OA.StoryData.CONTRACTS
    OA.StoryData.CONTRACTS = { { id = "stake", kind = "stake", item = "StakeTag", weight = 1 } }
    local function nextStake()
        tick(record)
        local m = M.active(record)
        truthy(m and m.title == "stake", "a drop site check")
        M.finish(record, m, "expired")
        TEST.hours = TEST.hours + 4 * 24
        return m
    end
    Sites.seenOf(record)[1] = true
    Sites.seenOf(record)[3] = true
    for _ = 1, 3 do
        local m = nextStake()
        eq(m.stake, 2, "the one not seen")
        eq(m.stakeNo, 322)
    end
    Sites.seenOf(record)[2] = true
    local any = {}
    for _ = 1, 12 do any[nextStake().stake] = true end
    truthy(any[1] or any[2], "all seen: any of them")
    eq(any[3], nil, "never a failed one")
    OA.StoryData.CONTRACTS = contracts
    for k in pairs(sec) do sec[k] = nil end
end)

test("a mission is one at a time", function()
    local record = setup(1)
    tick(record)
    local first = M.active(record)
    TEST.hours = TEST.hours + 100
    tick(record)
    TEST.hours = TEST.hours + 24 * 30
    -- Expired, then a gap before the next.
    tick(record)
    eq(M.active(record), nil)
    truthy(first.id ~= nil)
end)

test("the economy sees a mission item as plain once its mission is over, late, or not this character's", function()
    local record = setup(1)
    tick(record)
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
    tick(record)
    local m = M.active(record)
    TEST.hours = TEST.hours + 22 * 24
    eq(Story.missionExpired(m.id), true)
end)

-- The papers of what was delivered come back -------------------------------------------------------------------------

local function full(name) return OA.StoryData.fullType(name) end

test("what the mission delivered has its papers listed: the original of a pair, the record of a swap, a drop's inside", function()
    local compare = { compare = { right = "B" }, items = {
        { key = "A", type = full("CopyOriginal"), mods = { OA_Serial = 100 } },
        { key = "B", type = full("CopyOriginal"), mods = { OA_Serial = 140 } } } }
    local docs = M.documentsOf(compare)
    eq(#docs, 1)
    eq(docs[1].id, "con_compare")
    eq(docs[1].extra, 140, "the original's number")
    local swap = { swap = { item = "ClinicRecord" }, items = {
        { key = "CASE", type = full("DeadDropCase"), mode = "case", mods = {} },
        { key = "A", type = full("ClinicRecord"), mode = "inside", mods = { OA_Variant = "medical" } } } }
    docs = M.documentsOf(swap)
    eq(#docs, 1)
    eq(docs[1].id, "clinic_log")
    eq(docs[1].variant, "medical")
    local drop = { drop = { item = "ReviewMemo" }, items = {
        { key = "CASE", type = full("DeadDropCase"), mode = "case", inside = "ReviewMemo",
          mods = { OA_Variant = "army", OA_Inside = "ReviewMemo" } } } }
    docs = M.documentsOf(drop)
    eq(#docs, 1)
    eq(docs[1].id, "review_memo")
    eq(docs[1].variant, "army")
    local cooler = { items = { { key = "A", type = full("SampleCooler"), mods = { OA_Variant = "army" } } } }
    eq(#M.documentsOf(cooler), 2, "front and back")
    local note = { items = { { key = "A", type = full("MissionEnvelope"), mods = { OA_Note = "note_4" } } } }
    docs = M.documentsOf(note)
    eq(#docs, 1)
    eq(docs[1].id, "note_4")
    eq(#M.documentsOf({ items = { { key = "A", type = full("MissionTape"), mods = {} } } }), 0)
end)

test("a soil sample's paper takes the stake number, a plain one has none", function()
    local docs = M.documentsOf({ soil = { stake = 412, variant = "site" }, items = { { type = full("SoilSample"), mode = "given" } } })
    eq(docs[1].id, "soil_slip")
    eq(docs[1].extra, 412)
    docs = M.documentsOf({ soil = { variant = "plain" }, items = { { type = full("SoilSample"), mode = "given" } } })
    eq(docs[1].id, "soil_slip")
    eq(docs[1].extra, nil)
end)

test("the delivered mission item's paper is in the folder after the settlement, as a copy, new", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    eq(m.story, "evidence")
    local place = m.facility
    M.onSealed(record, "box1", { { info = { mission = M.itemId(m, "A") }, count = 1 } })
    eq(Story.section(record).docs.police_card, nil, "not before the settlement")
    M.onSettled(record, { credits = 1000, trust = 5 })
    local s = Story.section(record)
    eq(s.docs.police_card, place, "with the place it was found at")
    eq(s.copies.police_card, true)
    truthy(s.unread["d:police_card"], "new in the folder")
    eq(s.docStage.police_card, 1)
end)

test("a paper the player read before the settlement stays as it was read", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    Story.markRead(record, "police_card", m.facility)
    M.onSealed(record, "box1", { { info = { mission = M.itemId(m, "A") }, count = 1 } })
    M.onSettled(record, { credits = 1000, trust = 5 })
    local s = Story.section(record)
    eq(s.copies.police_card, nil)
    eq(s.unread["d:police_card"], nil)
end)

test("a mission that ran out sends no copy", function()
    local record = setup(1)
    tick(record)
    TEST.hours = TEST.hours + 22 * 24
    tick(record)
    eq(M.active(record), nil)
    eq(Story.section(record).docs.police_card, nil)
end)

-- The handover and the revisits have papers of their own -------------------------------------------------------------

test("the handover mission's item is its own paper, the revisits' items carry the new office's forms", function()
    local record = setup(5, 3)
    local s = Story.section(record)
    s.seenStage = 5; s.seenMilestones = 2
    Story.queueStory(record, "handover", true)
    tick(record)
    local m = M.active(record)
    eq(m.story, "handover")
    eq(m.items[1].type, "OperationAcorn.HandoverPages")
    eq(OA.StoryDocs.forItem(record, "HandoverPages", m.items[1].mods)[1].id, "handover_pages")
    M.finish(record, m, "expired")
    for _, id in ipairs({ "revisit_ledger", "revisit_roster", "revisit_police" }) do
        s.done[id] = nil
        TEST.hours = TEST.hours + 4 * 24
        Story.queueStory(record, id, true)
        tick(record)
        local mission = M.active(record)
        eq(mission.story, id)
        local docs = OA.StoryDocs.forItem(record, OA.StoryData.itemName(mission.items[1].type), mission.items[1].mods)
        eq(#docs, 1, "the new form alone, not the item's old paper")
        eq(docs[1].id, id)
        eq(docs[1].variant, mission.facility)
        M.finish(record, mission, "expired")
    end
end)

test("a revisit goes back to the site its story had, or picks one of its facility", function()
    local record = setup(5, 3)
    local s = Story.section(record)
    s.seenStage = 5; s.seenMilestones = 3
    local site = { x = 1500, y = 0, z = 0, x1 = 1497, y1 = -3, x2 = 1503, y2 = 3, z1 = 0, z2 = 0, key = "1500,0" }
    s.sites.evidence = site
    Story.queueStory(record, "revisit_police", true)
    tick(record)
    local m = M.active(record)
    eq(m.story, "revisit_police")
    eq(m.site, site)
    eq(m.facility, "police")
    M.finish(record, m, "expired")
    Story.queueStory(record, "revisit_ledger", true)
    TEST.hours = TEST.hours + 4 * 24
    tick(record)
    m = M.active(record)
    eq(m.story, "revisit_ledger")
    truthy(m.site and m.site.key ~= "1500,0", "a new site")
    eq(m.facility, "medical")
end)

test("the wreck: a site of open ground for the whole world, its log the log's own paper", function()
    local record = setup(5, 7)
    local s = Story.section(record)
    s.seenStage = 5; s.seenMilestones = 7
    Story.queueStory(record, "revisit_wreck", true)
    tick(record)
    local m = M.active(record)
    eq(m.story, "revisit_wreck")
    eq(m.facility, "wreck")
    truthy(m.site and m.site.ground, "open ground")
    local docs = OA.StoryDocs.forItem(record, OA.StoryData.itemName(m.items[1].type), m.items[1].mods)
    eq(docs[1].id, "transport_log", "the truck's own log, no form of the new office")
    eq(Story.world().shared.revisit_wreck, m.site)
    local site = m.site
    M.finish(record, m, "expired")
    -- sent again (a later character in the same world): the same truck
    s.sites.revisit_wreck, s.done.revisit_wreck, s.queue = nil, nil, {}
    TEST.hours = TEST.hours + 4 * 24
    Story.queueStory(record, "revisit_wreck", true)
    tick(record)
    eq(M.active(record).story, "revisit_wreck")
    eq(M.active(record).site, site)
end)

test("what the team makes of a delivery: Admin 7's remark on a revisit, the reply on a soil sample", function()
    local record = setup(5, 4)
    local s = Story.section(record)
    M.answer(record, { story = "revisit_roster" })
    eq(s.noteQueue[#s.noteQueue], "revisit_roster_done")
    M.answer(record, { story = "soil", soil = { stake = 412 } })
    eq(s.papers[#s.papers].doc, "reply_soil_site")
    M.answer(record, { story = "soil", soil = {} })
    eq(s.papers[#s.papers].doc, "reply_soil_plain")
    local n = #s.noteQueue
    M.answer(record, { story = "evidence" })
    eq(#s.noteQueue, n, "a story of 2반's has its own scene")
end)

test("a piece destroyed is got again the way it was got, with as much time as the mission had", function()
    local record = setup(2)
    record.story = nil
    tick(record)
    local m = M.active(record)
    local it = m.items[1]
    it.placed, it.at = true, { x = 1, y = 2, z = 0 }
    local again = {}
    M.game.placeAgain = function(rec, mission, piece) again[#again + 1] = piece end
    local told = listenTitles()
    local span = m.deadline - m.issued
    TEST.hours = TEST.hours + 6 * 24
    local found, piece = M.pieceOf(record, M.itemId(m, it.key))
    eq(found, m)
    eq(piece, it)
    M.replacePiece(record, m, piece)
    eq(it.placed, false, "laid out again")
    eq(it.at, nil)
    eq(again[1], it)
    near(m.deadline, TEST.hours + span, 1e-6, "as much time as it had from the start")
    eq(told[#told].key, "IGUI_OA_Title_Lost")
    eq(told[#told].sub, "IGUI_OA_Title_LostSub_Find")
    -- A soil sample is taken again; the deadline it has now is kept (a second loss gives no more time).
    local deadline = m.deadline
    m.soil = { taken = true }
    it.mode = "given"
    M.replacePiece(record, m, it)
    eq(m.soil.taken, false, "taken again")
    eq(m.deadline, deadline)
    eq(told[#told].sub, "IGUI_OA_Title_LostSub_Soil")
    m.soil = nil
    -- The exchanged record is waited for again; the piece goes, a new one comes with the wait.
    m.swap = { stage = "done", waited = 9, at = 1 }
    it.mode = "inside"
    M.replacePiece(record, m, it)
    eq(m.swap.stage, "waiting")
    eq(m.swap.waited, 0)
    eq(#m.items, 0, "the old piece went")
    eq(told[#told].sub, "IGUI_OA_Title_LostSub_Swap")
    -- A piece of no known way: left as it is.
    local count = #told
    M.replacePiece(record, m, { key = "Z", mode = "other" })
    eq(#told, count)
    m.items[1] = it
    eq(M.state(record).active, m, "the mission goes on")
    eq(M.pieceOf(record, "M0-999"), nil, "another mission's item")
    m.state = "sealed"
    eq(M.pieceOf(record, M.itemId(m, it.key)), nil, "a sealed mission's")
end)

test("a piece picked up is found and followed; a bag is looked into only while a piece is to be found", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    local it = m.items[1]
    local tracked, bags = {}, 0
    M.game.track = function(mission, piece, item) tracked[piece] = item end
    M.game.whereNow = function(rec, mission, piece) if tracked[piece] then return 3, 4, 0, true end end
    M.game.pieceIn = function(bag, id) bags = bags + 1; return bag.inner end
    local function thing(id, inner)
        local data = { OA_Mission = id }
        return { inner = inner, hasModData = function() return id ~= nil end, getModData = function() return data end }
    end
    -- An item of no mission, then a bag holding the piece.
    local bag = thing(nil, thing(M.itemId(m, it.key)))
    local was = instanceof
    instanceof = function(o, cls) return o == bag and cls == "InventoryContainer" end
    M.lookForPiece(record, thing("M0-77"))
    eq(it.found, nil)
    M.lookForPiece(record, bag)
    eq(bags, 1)
    eq(it.found, true)
    eq(it.where.x, 3)
    eq(it.where.carried, true)
    M.lookForPiece(record, bag)
    eq(bags, 1, "every piece found: a bag is not looked into")
    -- A destroyed piece is to be found again.
    M.game.placeAgain = function() end
    M.replacePiece(record, m, it)
    eq(it.found, nil)
    eq(it.where, nil)
    instanceof = was
end)

test("a character that died: its running missions end without a result and nothing waits for their pieces", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    truthy(m)
    local released = M.game.released
    OA.Store.retire(record)
    M.retire(record)
    eq(M.active(record), nil)
    eq(M.game.released, released + 1, "its pieces released")
    eq(record.missions.results.expired or 0, 0, "no result counted")
    truthy(M.expired(m.id), "its items read as an expired mission's")
end)

test("a retired record waits for its next offer as after any ending; a record with no mission keeps its schedule", function()
    local record = setup(1)
    tick(record)
    truthy(M.active(record))
    TEST.hours = TEST.hours + 5
    OA.Store.retire(record)
    M.retire(record)
    near(record.missions.nextAt, TEST.hours + 72, 1e-6, "the same wait as after a mission that ended")
    -- a record the character comes back to (Server's hello revives it) gets no offer at once
    record.dead = nil
    tick(record)
    eq(M.active(record), nil, "no offer at once")
    TEST.hours = TEST.hours + 72 + 1
    tick(record)
    truthy(M.active(record), "the offer comes when its time has")
    -- retiring with nothing running leaves the schedule as it was
    local idle = OA.Store.ensure("p2", "Q")
    idle.trade = { stage = 1, milestones = 0, credits = 0, trust = 0 }
    local s = M.state(idle)
    s.nextAt = 12345
    M.retire(idle)
    eq(s.nextAt, 12345, "nothing ended")
    -- a new character's record starts from the first offer (CANON S19)
    local fresh = OA.Store.ensure("p3", "R")
    eq(M.state(fresh).nextAt, 0)
end)

test("a piece first in hands has a title over the mission's; the card then tells to seal it", function()
    local record = setup(1)
    tick(record)
    local m = M.active(record)
    local it = m.items[1]
    local told = listenTitles()
    local was = #told
    M.found(record, m, it, {})
    eq(#told, was + 1)
    eq(told[#told].key, "IGUI_OA_Title_Secured")
    eq(told[#told].sub, (M.keys(m)))
    M.found(record, m, it, {})
    eq(#told, was + 1, "only the first time")
    local info = M.describe(record)
    eq(info.held, true)
    eq(info.gathered, true)
    M.onSealed(record, "box1", { { info = { mission = M.itemId(m, it.key) }, count = 1 } })
    info = M.describe(record)
    eq(info.held, nil, "sealed: the card says so instead")
    -- A mission of several: how many of how many. The comparison and a plain piece have none.
    local several = { id = "x", kind = "regular", title = "MissionEnvelope", scatter = { total = 3, found = {} },
        items = { { key = "A", found = true }, { key = "B" }, { key = "C" } } }
    M.securedTitle(record, several, several.items[1])
    eq(told[#told].sub, "IGUI_OA_Title_SecuredOf")
    eq(told[#told].subArgs[1].key, (M.keys(several)))
    eq(told[#told].subArgs[2], 1)
    eq(told[#told].subArgs[3], 3)
    local count = #told
    M.securedTitle(record, { id = "y", kind = "regular", title = "compare", compare = { right = "A" },
        items = { { key = "A", found = true } } }, { key = "A", found = true })
    M.securedTitle(record, several, { key = "K", plain = true })
    eq(#told, count)
end)

test("an open mission warns once a day before its deadline; a short one does not, a moved deadline warns again", function()
    local record = setup(1)
    local told = listenTitles()
    local m = { id = "w", kind = "regular", title = "MissionEnvelope", issued = 0, deadline = 100 }
    local was = #told
    M.warnDeadline(record, m, 70)
    eq(#told, was)
    M.warnDeadline(record, m, 80)
    eq(#told, was + 1)
    eq(told[#told].key, "IGUI_OA_Title_DayLeft")
    eq(told[#told].sub, (M.keys(m)))
    M.warnDeadline(record, m, 90)
    eq(#told, was + 1, "once")
    m.deadline = 130
    M.warnDeadline(record, m, 110)
    eq(#told, was + 2, "a deadline moved later warns again")
    M.warnDeadline(record, { id = "s", kind = "regular", title = "X", issued = 80, deadline = 100 }, 85)
    eq(#told, was + 2, "a mission short all along")
end)

test("a box about to be sealed tells its missions' reward; sealed, the reward waits for the settlement", function()
    local record = setup(2)
    record.story = nil
    M.tick(record)
    local m = taken(record)
    local infos = { { mission = M.itemId(m, "A") }, { mission = nil } }
    local list = M.sealing(record, infos)
    eq(#list, 1)
    eq(list[1].m, m); eq(list[1].credits, m.credits); eq(list[1].trust, m.trust)
    eq(#M.sealing(record, { { mission = "M999-1#A" } }), 0, "not this record's mission")
    eq(M.sealedPay(record), 0, "nothing sealed")
    M.onSealed(record, "box1", { { info = { mission = M.itemId(m, "A") }, count = 1 } })
    eq(#M.sealing(record, infos), 0, "sealed already")
    eq(M.sealedPay(record), OA.round(m.pay.credits))
    -- too late: no reward told
    local record2 = setup(2)
    record2.story = nil
    M.tick(record2)
    local late = taken(record2)
    eq(#M.sealing(record2, { { mission = M.itemId(late, "A") } }, late.deadline + 1), 0)
end)

test("the sample cooler's reward is its state as it is sealed: the confirmation tells it as it will be paid", function()
    local record = setup(2)
    record.story = nil
    M.tick(record)
    local cool = taken(record)
    local now = OA.hours()
    cool.carry = { start = now - 3 }
    local told = M.sealing(record, { { mission = M.itemId(cool, "A") } }, now)
    truthy(told[1].credits, "known as it is sealed")
    M.onSealed(record, "box1", { { info = { mission = M.itemId(cool, "A") }, count = 1 } })
    eq(told[1].credits, cool.pay.credits)
    eq(told[1].trust, cool.pay.trust)
end)

test("the swap's drop case: picked up empty it says nothing; with the record in it, the record is found", function()
    local record = setup(2)
    Story.section(record).seenStage = 1
    tick(record)
    local m = M.active(record)
    local told = listenTitles()
    M.game.pieceIn = function(bag) return bag.inner end
    local function thing(id, inner)
        local data = { OA_Mission = id }
        return { inner = inner, hasModData = function() return true end, getModData = function() return data end }
    end
    local was = instanceof
    instanceof = function(o, cls) return cls == "InventoryContainer" and o.inner ~= nil end
    local played = OperationAcorn.Comms.section(record).played
    -- the empty case before the sample is left: no pickup line, no title
    M.lookForPiece(record, thing(M.itemId(m, "CASE")))
    eq(played.S2F_pickup, nil)
    eq(#told, 0)
    -- the record swapped in: the case picked up with it inside
    M.game.px, M.game.py = m.site.x, m.site.y
    truthy(M.swap(record, {}))
    TEST.hours = TEST.hours + 3
    tick(record)
    eq(m.swap.stage, "done")
    local recordPiece
    for _, it in ipairs(m.items) do if it.key == "A" then recordPiece = it end end
    M.lookForPiece(record, thing(M.itemId(m, "CASE"), thing(M.itemId(m, "A"))))
    eq(recordPiece.found, true)
    truthy(played.S2F_pickup, "its line")
    eq(told[#told].key, "IGUI_OA_Title_Secured")
    instanceof = was
end)
