-- The zombie samples and the zombie missions (DESIGN 6 '좀비 시료', 9 '좀비 임무'): the harvest's grades and refusals, the
-- tweezers' mark, the samples' worth; an area clear counted to its end and paid at once, a target mission's samples
-- sealed to its end, the group brought once a visit and let go when the mission ends. The game is a fake that records
-- what it is asked.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Folder"
require "OperationAcorn/Story/Scene"
require "OperationAcorn/Story/Zombies"
require "OperationAcorn/Story/Harvest"
require "OperationAcorn/Story/View"
local OA = OperationAcorn
local M, Z, H = OA.Missions, OA.ZombieMissions, OA.Harvest
local Story, Data, Rewards = OA.Story, OA.StoryData, OA.Rewards

local function fakeGame()
    local g = { requested = {}, released = 0, held = {}, let = {}, spawned = {}, loaded = true, present = 0 }
    g.list = {}
    for i = 1, 600 do
        local a = i * 0.7
        local r = 100 + (i % 60) * 25
        local x, y = math.floor(math.cos(a) * r), math.floor(math.sin(a) * r)
        g.list[i] = { x = x, y = y, z = 0, x1 = x - 3, y1 = y - 3, x2 = x + 3, y2 = y + 3, z1 = 0, z2 = 0 }
    end
    fakeSites(g)
    g.playerPosition = function() return g.px or 0, g.py or 0, 0 end
    g.request = function(record, m, it) g.requested[#g.requested + 1] = { m = m.id, it = it } end
    -- as the game's: what a mission leaves goes, its group with it
    g.release = function(m)
        g.released = g.released + 1
        Z.release(m)
    end
    g.holdZombies = function(m) g.held[#g.held + 1] = m.id end
    g.releaseZombies = function(m) g.let[#g.let + 1] = m.id end
    g.areaLoaded = function() return g.loaded end
    g.countMarked = function() return g.present end
    g.spawnZombies = function(area, outfit, key, count)
        g.spawned[#g.spawned + 1] = { outfit = outfit, key = key, count = count }
        return count
    end
    g.giveMissionItem = function(character, full, id) g.given = { full, id }; return { id = id } end
    return g
end

local recordCount = 0
local function setup(stage, kind)
    recordCount = recordCount + 1
    local record = OA.Store.ensure("p" .. recordCount, "P" .. recordCount)
    record.trade = { stage = stage, milestones = 0, credits = 0, trust = 0 }
    Story.setAnchor(record, 0, 0, 0)
    local s = Story.section(record)
    s.seenStage = stage
    for id in pairs(Data.STORIES) do s.done[id] = "done" end
    Data.REGULAR = { { id = kind, kind = kind, weight = 1 } }
    Rewards.URGENT_CHANCE = 100
    Rewards.FAR_MAX = 0
    M.game = fakeGame()
    Z.reset()
    OA.Trade = { addToDrop = function() end }
    return record
end

-- A mission offered and started at once (Missions.launch): these tests look at it running.
local function startNow(record)
    M.start(record)
    M.launch(record)
    return M.active(record)
end

-- Missions --------------------------------------------------------------------------------------------------------------

test("the regular pick has the area clear and the target sample at three each", function()
    local weights = {}
    for _, e in ipairs(Data.REGULAR) do if e.kind then weights[e.kind] = e.weight end end
    eq(weights.clear, 3)
    eq(weights.target, 3)
end)

test("a zombie mission is a small circle near a building of the band, its group's size by level, never urgent", function()
    for level, want in ipairs({ 12, 18, 24, 30, 40 }) do
        local record = setup(level, "clear")
        local m = startNow(record)
        eq(m.kind, "regular")
        eq(m.title, "clear")
        eq(m.area.r, 15)
        eq(m.zombies.total, want)
        eq(m.zombies.outfit, "Generic01")
        eq(m.urgent, nil, "never urgent")
        eq(#m.items, 0)
        eq(#M.game.requested, 0, "nothing to place")
        local lo, hi = Rewards.band(level)
        local d = OA.Places.distance(0, 0, m.area.x, m.area.y)
        truthy(d >= lo - 30 and d <= hi + 30, "in the band: " .. d)
    end
    local record = setup(3, "target")
    local m = startNow(record)
    eq(m.zombies.total, 3)
    eq(m.zombies.outfit, "HospitalPatient")
    local _, brief = M.keys(m)
    eq(brief, "IGUI_OA_Story_RegBrief_target")
end)

test("an area clear counts its group's deaths wherever they are, and pays at once with the last", function()
    local record = setup(1, "clear")
    local m = startNow(record)
    for _ = 1, 11 do Z.died(m.id, TEST.hours) end
    Z.died("M0-99", TEST.hours)
    eq(m.zombies.killed, 11, "another mission's zombie is not counted")
    eq(M.describe(record).zombies.done, 11)
    eq(record.trade.credits, 0)
    Z.died(m.id, TEST.hours)
    eq(M.active(record), nil, "done")
    eq(record.missions.results.done, 1)
    eq(record.trade.credits, m.credits)
    eq(M.game.let[1], m.id, "its group let go")
end)

test("an area clear finished after its deadline pays nothing", function()
    local record = setup(1, "clear")
    local m = startNow(record)
    for _ = 1, 11 do Z.died(m.id, TEST.hours) end
    TEST.hours = TEST.hours + 15 * 24
    Z.died(m.id, TEST.hours)
    eq(record.trade.credits, 0)
    eq(record.missions.results.expired, 1)
end)

test("a target mission takes a sample from each target and is done when all are sealed", function()
    local record = setup(1, "target")
    local m = startNow(record)
    eq(m.zombies.total, 2)
    Z.died(m.id, TEST.hours)
    eq(#m.zombies.dead, 1)
    local m1, it1, id1 = Z.takeTarget(record, m.id, TEST.hours)
    eq(m1, m)
    eq(id1, m.id .. "#T1")
    eq(it1.type, "OperationAcorn.TissueTarget")
    eq(#m.zombies.dead, 0, "its death let go")
    eq(Z.takeTarget(record, nil, TEST.hours), nil, "an unmarked corpse is a plain one")
    eq(Z.takeTarget(record, "M0-99", TEST.hours), nil, "another mission's is too")
    local _, _, id2 = Z.takeTarget(record, m.id, TEST.hours)
    eq(id2, m.id .. "#T2")
    eq(M.describe(record).zombies.done, 2)
    M.onSealed(record, "box1", { { info = { mission = id1 }, count = 1 } })
    eq(m.state, "open", "one of two")
    eq(M.rerollOffer(record, m), nil, "no taking another once a sample is sealed")
    M.onSealed(record, "box2", { { info = { mission = id2 }, count = 1 } })
    eq(m.state, "sealed")
    eq(M.game.let[1], m.id, "the targets left let go as it is sealed")
    M.onSettled(record, { credits = 0, trust = 0 })
    eq(record.trade.credits, m.credits)
end)

test("a target dead too long is forgotten and another comes; one harvested does not come again", function()
    local record = setup(1, "target")
    local m = startNow(record)
    eq(Z.wanted(m, TEST.hours), 2)
    Z.died(m.id, TEST.hours)
    eq(Z.wanted(m, TEST.hours), 1, "its corpse lies there")
    eq(Z.wanted(m, TEST.hours + 25), 2, "rotten: another target")
    Z.takeTarget(record, m.id, TEST.hours)
    eq(Z.wanted(m, TEST.hours), 1)
end)

test("a target sample lost in a fire is taken again from another target", function()
    local record = setup(1, "target")
    local m = startNow(record)
    local _, it = Z.takeTarget(record, m.id, TEST.hours)
    M.replacePiece(record, m, it)
    eq(#m.items, 0)
    eq(m.zombies.taken, 0)
    eq(Z.wanted(m, TEST.hours), 2)
end)

test("the group is held at once, brought once a visit a look after its squares load, and comes again after the player left", function()
    local record = setup(1, "clear")
    local m = startNow(record)
    local g = M.game
    g.px, g.py = m.area.x + 200, m.area.y
    Z.tick(TEST.hours)
    eq(#g.held, 1, "held")
    eq(#g.spawned, 0, "far: nothing")
    g.px = m.area.x + 50
    g.loaded = false
    Z.tick(TEST.hours)
    eq(#g.spawned, 0, "not loaded yet")
    g.loaded = true
    g.present = 2
    Z.tick(TEST.hours)
    eq(#g.spawned, 0, "loaded: the population brings back what it kept first")
    Z.tick(TEST.hours)
    eq(#g.spawned, 1)
    eq(g.spawned[1].count, 10, "what is missing of the group")
    eq(g.spawned[1].outfit, "Generic01")
    eq(g.spawned[1].key, m.id, "marked with the mission's id")
    Z.tick(TEST.hours)
    eq(#g.spawned, 1, "once a visit")
    g.px = m.area.x + 80
    Z.tick(TEST.hours)
    eq(#g.spawned, 1, "not yet gone")
    g.px = m.area.x + 90
    Z.tick(TEST.hours)
    g.px, g.present = m.area.x, 0
    Z.tick(TEST.hours)
    Z.tick(TEST.hours)
    eq(#g.spawned, 2, "a new visit")
    eq(#g.held, 1, "held once")
end)

test("without the API's zombie marks the zombie missions are not given", function()
    local record = setup(1, "clear")
    M.game.canMarkZombies = function() return false end
    Data.REGULAR = { { id = "clear", kind = "clear", weight = 1 }, { item = "MissionEnvelope", weight = 1 } }
    local m = startNow(record)
    eq(m.zombies, nil)
    eq(m.items[1].type, "OperationAcorn.MissionEnvelope")
end)

test("the circle stays on the maps while a zombie mission runs, whatever was found", function()
    local record = setup(1, "target")
    local m = startNow(record)
    local _, it = Z.takeTarget(record, m.id, TEST.hours)
    it.found = true
    eq(#OA.StoryView.circles(m), 1)
end)

-- The harvest --------------------------------------------------------------------------------------------------------

test("the harvest's grades follow the quick and the precise odds", function()
    local function at(n) return function() return n end end
    eq(H.roll(false, at(70)), "common")
    eq(H.roll(false, at(71)), "infected")
    eq(H.roll(false, at(92)), "infected")
    eq(H.roll(false, at(93)), "neural")
    eq(H.roll(false, at(99)), "neural")
    eq(H.roll(false, at(100)), "anomalous")
    eq(H.roll(true, at(55)), "common")
    eq(H.roll(true, at(83)), "infected")
    eq(H.roll(true, at(95)), "neural")
    eq(H.roll(true, at(96)), "anomalous")
end)

test("a corpse gives a sample when a zombie's, fresh, not a skeleton and not harvested", function()
    eq(H.refusal({ zombie = true, death = 10 }, 30), nil)
    eq(H.refusal({ zombie = true, death = 10 }, 34.5), "old")
    eq(H.refusal({ zombie = true, death = 10, skeleton = true }, 11), "old")
    eq(H.refusal({ zombie = true, death = 10, taken = true }, 11), "taken")
    eq(H.refusal({ zombie = false, death = 10 }, 11), "none")
end)

test("the tweezers delivered mark the character for the precise harvest", function()
    local record = setup(3, "clear")
    eq(H.precise(record), false)
    OA.Shop.bought(OA.Shop.entry("harvest_kit"), record, 1)
    eq(H.precise(record), false)
    OA.Shop.bought(OA.Shop.entry("precision_tweezers"), record, 1)
    eq(H.precise(record), true)
    eq(OA.Shop.entry("harvest_kit").tier, 1)
    eq(OA.Shop.entry("precision_tweezers").tier, 3)
    eq(OA.Shop.fieldOnly(OA.Shop.entry("precision_tweezers")), false, "the crude terminal sells them")
end)

-- What the samples are worth -----------------------------------------------------------------------------------------

local function sample(fullType, data)
    return {
        getFullType = function() return fullType end,
        getScriptItem = function() return nil end,
        isFluidContainer = function() return false end,
        getActualWeight = function() return 0.3 end,
        getDisplayCategory = function() return "Material" end,
        getCategory = function() return "Normal" end,
        isItemType = function() return false end,
        getConditionMax = function() return 0 end,
        hasModData = function() return data ~= nil end,
        getModData = function() return data end,
    }
end

test("the samples are taken at their grade's worth; a target's sample is its mission's, then a common one", function()
    instanceof = instanceof or function() return false end
    ItemType = ItemType or { MOVEABLE = "moveable" }
    local V = OA.Value
    eq(V.OWN.TissueCommon.credits, 200)
    eq(V.OWN.TissueAnomalous.trust, 30)
    eq(V.accepts(V.info(sample("OperationAcorn.TissueNeural"))), true)
    local record = setup(1, "target")
    local m = startNow(record)
    local _, _, id = Z.takeTarget(record, m.id, TEST.hours)
    eq(V.info(sample("OperationAcorn.TissueTarget", { OA_Mission = id })).own, "MissionItem")
    TEST.hours = TEST.hours + 15 * 24
    eq(V.info(sample("OperationAcorn.TissueTarget", { OA_Mission = id })).own, "TissueTarget")
    eq(V.info(sample("OperationAcorn.MissionEnvelope", { OA_Mission = id })).own, "ExpiredMission")
end)
