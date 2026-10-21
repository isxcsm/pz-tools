-- The survey branch (Story/Survey on Story/Branches): a capstone waiting only for its fragment brings a call once,
-- with a notice; the call played marks the drop site's zone on the maps; the fragment arriving drops a call not yet
-- played and takes the zone away; the tiers never drop it; after the handover 관리 7 calls instead.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Survey"
require "OperationAcorn/Story/View"
require "OperationAcorn/Upgrades/Api"
local OA = OperationAcorn
local Survey, Branches, Comms, Sites = OA.StorySurvey, OA.StoryBranches, OA.Comms, OA.Sites
local Rules = OA.Upgrades.Rules

local ORIGIN = { x = 8000, y = 7000 }
-- The scout tree bought through to its capstone's row (25 points: everything but the capstone).
local SCOUT = { "sight", "sight", "sight", "sixth", "sixth", "alarm", "night", "night", "night", "rich", "rich", "rich",
    "ledger", "ledger", "ledger", "sense", "sense", "keen", "keen", "keen", "ammo", "ammo", "sensePlus", "sensePlus",
    "sensePlus" }

local n = 0
local notices
-- A record whose scout capstone waits for its fragment (`ready`), round sites laid out once.
local function record(ready)
    local sec = OA.Store.world("sites")
    if not sec.list then Sites.ensure(ORIGIN, function() return true end) end
    n = n + 1
    local r = OA.Store.ensure("survey" .. n, "S")
    if ready then
        local u = Rules.section(r)
        for _ = 1, 26 do Rules.inject(u, "scout") end
        for _, id in ipairs(SCOUT) do assert(Rules.buy(u, id)) end
    end
    notices = {}
    OA.Sync.notice = function(_, key) notices[#notices + 1] = key end
    return r
end

local function play(r, id)
    Comms.played(r, id, 3, 100)
    OA.Story.callPlayed(r, id)
end

test("a capstone waiting for its fragment brings its call once, with a notice", function()
    local idle = record(false)
    eq(#Branches.look(idle, "approved"), 0, "nothing waits")
    eq(#notices, 0)
    local r = record(true)
    eq(Rules.blocked(Rules.section(r), "nightEye"), "sealed")
    local fired = Branches.look(r, "approved")
    eq(#fired, 1)
    eq(fired[1], "C_scout")
    eq(#notices, 1)
    eq(notices[1], "IGUI_OA_Story_Notice_BranchCall")
    eq(#Branches.look(r, "settled"), 0, "once")
    eq(#notices, 1, "told once")
    eq(Comms.next(r, "terminal", 50).id, "C_scout")
    -- told at once, there at once: not held by the short calls' gap after the last call
    Comms.played(r, "S1", 1, 49.5)
    eq(Comms.next(r, "terminal", 50).id, "C_scout", "a call just played holds it back no hour")
    eq(Comms.waiting(r) > 0, true, "the terminal shows it waiting")
end)

test("the tiers and a join drop no branch call", function()
    local r = record(true)
    Branches.look(r, "approved")
    Comms.enterTier(r, 8, 10)
    Comms.join(r, 12, true)
    truthy(Comms.ready(r, "C_scout", 50), "still waits to be played")
end)

test("the call played marks the site's zone: the site well inside; the fragment takes it away", function()
    local r = record(true)
    Branches.look(r, "approved")
    eq(#Survey.zones(r), 0, "not before it is heard")
    play(r, "C_scout")
    local zones = Survey.zones(r)
    eq(#zones, 1)
    local z, site = zones[1], Survey.siteOf("scout")
    eq(z.tree, "scout")
    eq(z.r, Survey.R)
    local d = OA.Places.distance(site.x, site.y, z.x, z.y)
    truthy(d < z.r - Survey.GAP, d)
    local again = Survey.zone(site)
    eq(again.x, z.x); eq(again.y, z.y)
    -- on the maps: a dim circle, never where the way leads
    local scene = OA.StoryView.scene(r, nil)
    eq(#scene.circles, 1)
    eq(scene.circles[1].dim, true)
    eq(scene.circles[1].color, OA.StoryView.MAP_SURVEY)
    eq(scene.lead, nil)
    Rules.unseal(Rules.section(r), "scout")
    eq(#Survey.zones(r), 0)
    eq(#Branches.look(r, "approved"), 0, "played once, never again")
end)

local function caught()
    local titles, lines = {}, {}
    local title, tell = OA.Sync.title, OA.Say.tell
    OA.Sync.title = function(_, detail) titles[#titles + 1] = detail end
    OA.Say.tell = function(_, id, ctx, delay) lines[#lines + 1] = { id = id, ctx = ctx, delay = delay } end
    return titles, lines, function() OA.Sync.title, OA.Say.tell = title, tell end
end

-- A point in a zone near its rim, on the side away from the site (in no deeper stage's zone).
local function rimOf(z, site)
    local dx, dy = z.x - site.x, z.y - site.y
    local d = math.max(1, math.sqrt(dx * dx + dy * dy))
    return math.floor(z.x + dx / d * (z.r - 3)), math.floor(z.y + dy / d * (z.r - 3))
end

local function day() return false end

test("walked into, the zone narrows stage by stage: its title and line each time, once; the last stays", function()
    local r = record(true)
    Branches.look(r, "approved")
    local site = Survey.siteOf("scout")
    local titles, lines, done = caught()
    Survey.minute(r, site.x, site.y, day)
    eq(#titles + #lines, 0, "nothing before the call is heard")
    play(r, "C_scout")
    local wide = Survey.zones(r)[1]
    eq(wide.stage, 1); eq(wide.r, Survey.STAGES[1])
    Survey.minute(r, wide.x + wide.r + 5, wide.y, day)
    eq(#titles, 0, "outside")
    local x, y = rimOf(wide, site)
    local next = Survey.zone(site, 2)
    truthy(OA.Places.distance(x, y, next.x, next.y) > next.r, "the rim is outside the next zone")
    Survey.minute(r, x, y, function() return true end)
    local z = Survey.zones(r)[1]
    eq(z.stage, 2); eq(z.r, Survey.STAGES[2])
    truthy(OA.Places.distance(site.x, site.y, z.x, z.y) < z.r - Survey.GAP, "the site well inside")
    eq(#titles, 1)
    eq(titles[1].key, "IGUI_OA_Title_SurveyIn"); eq(titles[1].style, "unveil")
    eq(lines[1].id, "SurveyIn"); eq(lines[1].delay, Survey.SAY)
    eq(lines[1].ctx.night, true); eq(lines[1].ctx.seen, false)
    Survey.minute(r, x, y, day)
    eq(#titles, 1, "once")
    x, y = rimOf(z, site)
    Survey.minute(r, x, y, day)
    z = Survey.zones(r)[1]
    eq(z.stage, 3); eq(z.r, Survey.STAGES[3])
    eq(titles[2].key, "IGUI_OA_Title_SurveyClose")
    eq(lines[2].id, "SurveyNear"); eq(lines[2].ctx.night, false)
    Survey.minute(r, site.x, site.y, day)
    eq(#titles, 2, "the last stage stays")
    eq(Survey.zones(r)[1].stage, 3)
    done()
end)

test("each zone lies inside the one before, its rim GAP inside that one's whichever way it is come to", function()
    for i = 0, 199 do
        local site = { x = 9000 + i * 37, y = 6000 + i * 53 }
        for stage = 1, #Survey.STAGES - 1 do
            local outer, inner = Survey.zone(site, stage), Survey.zone(site, stage + 1)
            local gap = outer.r - inner.r - OA.Places.distance(outer.x, outer.y, inner.x, inner.y)
            truthy(gap >= Survey.GAP - 1.5, "stage " .. stage .. ": " .. gap)
        end
    end
end)

test("walked straight to the site: the last stage at once, its title and line alone; the site's own title kept quiet", function()
    local r = record(true)
    Branches.look(r, "approved")
    local site = Survey.siteOf("scout")
    local titles, lines, done = caught()
    play(r, "C_scout")
    Survey.minute(r, site.x, site.y, day)
    eq(Survey.zones(r)[1].stage, #Survey.STAGES)
    eq(#titles, 1); eq(titles[1].key, "IGUI_OA_Title_SurveyClose")
    eq(#lines, 1); eq(lines[1].id, "SurveyNear")
    site.state = "placed"
    eq(Sites.visit(r, site.x, site.y), true, "seen")
    eq(#titles, 1, "no title of the site's own")
    truthy(Sites.seenOf(r)[site.n])
    done()
end)

test("a site stood near before tells so on walking into its zone", function()
    local r = record(true)
    Branches.look(r, "approved")
    local site = Survey.siteOf("scout")
    local _, lines, done = caught()
    play(r, "C_scout")
    Sites.seenOf(r)[site.n] = true
    local x, y = rimOf(Survey.zones(r)[1], site)
    Survey.minute(r, x, y, day)
    eq(lines[1].id, "SurveyIn"); eq(lines[1].ctx.seen, true)
    done()
end)

test("the site lies at different shares of the last zone's radius and ways from its middle, the stage before's its own", function()
    local shares, same = {}, 0
    for i = 0, 199 do
        local site = { x = 9000 + i * 37, y = 6000 + i * 53 }
        local z, n = Survey.zone(site, #Survey.STAGES), Survey.zone(site, #Survey.STAGES - 1)
        local share = OA.Places.distance(site.x, site.y, z.x, z.y) / z.r
        truthy(share >= Survey.OFFSET_MIN - 0.03 and share <= Survey.OFFSET_MAX + 0.03, share)
        shares[math.floor(share * 10)] = true
        -- the stage before's middle on the same side of the site as the last one's
        local a = math.atan2(z.y - site.y, z.x - site.x)
        local b = math.atan2(n.y - site.y, n.x - site.x)
        if math.abs(math.cos(a - b) - 1) < 0.05 then same = same + 1 end
    end
    for tenth = 2, 6 do truthy(shares[tenth], "a share near " .. tenth / 10) end
    -- (the stage before is moved from the last one's middle: its way leans on the last one's, a quarter of the time)
    truthy(same < 70, "the stage before's way is mostly its own: " .. same)
end)

test("the clearing: all of it within CLEAR_IN, thinning out to CLEAR_OUT, trees most and grass least", function()
    local t, b, g = Sites.clearShare(0)
    eq(t, 1); eq(b, 1); eq(g, 1)
    t, b, g = Sites.clearShare(Sites.CLEAR_IN)
    eq(t, 1)
    local lt, lb, lg = 1, 1, 1
    for d = Sites.CLEAR_IN + 0.5, Sites.CLEAR_OUT, 0.5 do
        t, b, g = Sites.clearShare(d)
        truthy(t <= lt and b <= lb and g <= lg, "thinning at " .. d)
        truthy(t >= b and b >= g - 0.1, "trees most at " .. d)
        lt, lb, lg = t, b, g
    end
    truthy(lt > 0, "some trees go at the edge")
    t, b, g = Sites.clearShare(Sites.CLEAR_OUT + 0.5)
    eq(t + b + g, 0)
end)

-- A fragment item of the scout tree's kind.
local function fragmentItem()
    local fullType = OA.Upgrades.Data.FRAGMENTS.scout
    return { getFullType = function() return fullType end }
end

test("a fragment picked up: the zone goes, its first of a kind has a title and a line once; left somewhere, a pin", function()
    local r = record(true)
    Branches.look(r, "approved")
    play(r, "C_scout")
    local site = Survey.siteOf("scout")
    local titles, lines, done = caught()
    eq(#Survey.zones(r), 1)
    OA.Sites.pickedUp(r, { getFullType = function() return "Base.Axe" end })
    eq(#titles, 0, "not a fragment")
    OA.Sites.pickedUp(r, fragmentItem())
    truthy(site.taken)
    eq(#Survey.zones(r), 0, "the zone goes")
    eq(#titles, 1)
    eq(titles[1].key, "IGUI_OA_Title_Fragment")
    eq(titles[1].sub, "IGUI_OA_Title_FragmentSub_" .. site.kind)
    eq(lines[1].id, "FragmentTaken"); eq(lines[1].ctx.kind, site.kind); eq(lines[1].delay, Sites.TAKEN_SAY)
    OA.Sites.pickedUp(r, fragmentItem())
    eq(#titles, 1, "once a kind")
    -- carried: no pin; left on the floor: a pin where it lies
    site.at = { x = site.x + 40, y = site.y, z = 0, carried = true }
    eq(#Survey.points(r), 0)
    site.at = { x = site.x + 40, y = site.y, z = 0 }
    local points = Survey.points(r)
    eq(#points, 1); eq(points[1].x, site.x + 40); eq(points[1].tree, "scout")
    local scene = OA.StoryView.scene(r, nil)
    eq(#scene.circles, 0)
    eq(#scene.points, 1)
    eq(scene.points[1].color, OA.StoryView.MAP_SURVEY)
    -- the team has it: no pin
    Rules.unseal(Rules.section(r), "scout")
    eq(#Survey.points(r), 0)
    done()
end)

test("a fragment settled that opens the capstone brings the team's word once; after the handover 관리 7's", function()
    local r = record(true)
    Branches.look(r, "approved")
    play(r, "C_scout")
    local fullType = OA.Upgrades.Data.FRAGMENTS.scout
    OA.Story.onSettled(r, { lines = { { marks = { fragment = true }, fullType = fullType } } })
    truthy(Rules.unsealed(Rules.section(r), "scout"))
    eq(Comms.next(r, "terminal", 50).id, "C_got_scout")
    play(r, "C_got_scout")
    OA.Story.onSettled(r, { lines = { { marks = { fragment = true }, fullType = fullType } } })
    eq(Comms.next(r, "terminal", 50), nil, "once")
    -- (a new world's: the team had no fragment from a character before)
    OA.Store.world("sites").received = nil
    local k = record(true)
    OA.Story.section(k).handover = true
    OA.Story.onSettled(k, { lines = { { marks = { fragment = true }, fullType = fullType } } })
    truthy(Comms.section(k).fired.C_got_scout_k ~= nil, "관리 7's")
    eq(Comms.section(k).fired.C_got_scout, nil)
end)

test("a fragment that arrives first drops the call not yet played", function()
    local r = record(true)
    Branches.look(r, "approved")
    Rules.unseal(Rules.section(r), "scout")
    eq(#Branches.look(r, "settled"), 0)
    truthy(Comms.done(r, "C_scout"), "dropped")
    eq(Comms.next(r, "terminal", 50), nil)
end)

test("after the handover 관리 7 calls; a team call not played by then gives way", function()
    local r = record(true)
    Branches.look(r, "approved")
    OA.Story.section(r).handover = true
    local fired = Branches.look(r, "approved")
    eq(#fired, 1)
    eq(fired[1], "C_scout_k")
    truthy(Comms.done(r, "C_scout"), "the team's dropped")
    play(r, "C_scout_k")
    eq(#Survey.zones(r), 1)
    -- one played, neither again
    local s = record(true)
    Branches.look(s, "approved")
    play(s, "C_scout")
    OA.Story.section(s).handover = true
    eq(#Branches.look(s, "approved"), 0)
end)

test("a fragment the team had from a character before lets the next one's capstone through, with a word on it", function()
    local r = record(true)
    local sec = OA.Store.world("sites")
    Sites.receive(OA.Upgrades.Data.FRAGMENTS.scout)
    local fired = Branches.look(r, "approved")
    eq(#fired, 1)
    eq(fired[1], "C_had_scout", "the team's word, not the search")
    eq(Rules.unsealed(Rules.section(r), "scout"), true, "the capstone opens")
    eq(Rules.blocked(Rules.section(r), "nightEye"), nil)
    eq(#Branches.look(r, "approved"), 0, "once")
    play(r, "C_had_scout")
    eq(#Survey.zones(r), 0, "no zone on the maps")
    -- after the handover, 관리 7's
    local k = record(true)
    OA.Story.section(k).handover = true
    eq(Branches.look(k, "approved")[1], "C_had_scout_k")
    sec.received = nil
end)

test("a fragment gone from its site that reaches nobody in LOST_DAYS: its kind falls again, the zone follows", function()
    local r = record(true)
    Branches.look(r, "approved")
    play(r, "C_scout")
    local site = Survey.siteOf("scout")
    site.state, site.left = "placed", 100
    local n = #Sites.list()
    -- (the ring's places as the game's: any map cell, a point from the API)
    PZExtAPI = { version = OA.API_VERSION, client = function() return {} end,
        zones = { points = function(x, y, lo, hi) return { { x = x + hi, y = y, zones = {} } } end } }
    getWorld = function() return { getMetaGrid = function() return { getCellData = function() return {} end } end } end
    Sites.kick(100 + Sites.LOST_DAYS * 24 - 1)
    eq(#Sites.list(), n, "not lost yet")
    Sites.kick(100 + Sites.LOST_DAYS * 24)
    eq(#Sites.list(), n + 1, "another fall")
    local new = Survey.siteOf("scout")
    truthy(new ~= site and new.kind == site.kind and new.state == "pending", "of its kind, waiting for its chunk")
    eq(site.relaid, true)
    local z = Survey.zones(r)[1]
    truthy(OA.Places.distance(new.x, new.y, z.x, z.y) < z.r, "the zone round the new site")
    eq(notices[#notices], "IGUI_OA_Story_Notice_SiteAgain", "the waiting character is told")
    Sites.kick(100 + Sites.LOST_DAYS * 48)
    eq(#Sites.list(), n + 1, "once")
    getWorld, PZExtAPI = nil, nil
    table.remove(Sites.list())
end)

test("a waiting site where no road comes near (across a river at the map's edge) moves, and the zone follows", function()
    local r = record(true)
    Branches.look(r, "approved")
    play(r, "C_scout")
    local site = Survey.siteOf("scout")
    local ox, oy = site.x, site.y
    site.reachable, site.tries = nil, 0
    -- (no road near the old place: a point asked there gives none; the ring's draws give one)
    PZExtAPI = { version = OA.API_VERSION, client = function() return {} end,
        zones = { points = function(x, y, lo, hi)
            if hi == 0 and x == ox and y == oy then return {} end
            return { { x = x + hi, y = y, zones = {} } }
        end } }
    getWorld = function() return { getMetaGrid = function() return { getCellData = function() return {} end } end } end
    notices = {}
    Sites.kick(1)
    truthy(site.x ~= ox or site.y ~= oy, "moved")
    eq(site.state, "pending")
    eq(notices[#notices], "IGUI_OA_Story_Notice_SiteAgain", "the character whose map shows it is told")
    local z = Survey.zones(r)[1]
    truthy(OA.Places.distance(site.x, site.y, z.x, z.y) < z.r, "the zone round its new place")
    Sites.kick(2)
    eq(site.reachable, true, "its new place passes: checked once")
    local x = site.x
    Sites.kick(3)
    eq(site.x, x)
    getWorld, PZExtAPI = nil, nil
end)

test("the dev reset of the fragment calls: a dropped call forgotten, the capstone sealed again, the call at once", function()
    PZExtDev = { section = function() end }
    local debug = isDebugEnabled
    isDebugEnabled = function() return true end
    local real = require
    require = function(file)
        if file == "PZExtDev/Panel" then return true end
        return real(file)
    end
    require "OperationAcorn/Dev/Dev"
    require, isDebugEnabled = real, debug
    local Dev = OA.Dev
    local r = record(true)
    local u = Rules.section(r)
    Branches.look(r, "approved")
    eq(Comms.section(r).fired.C_scout ~= nil, true)
    -- the capstone opened (a dev unseal) before the call was played: the call is dropped for good
    Rules.unseal(u, "scout")
    Branches.look(r, "approved")
    eq(Comms.section(r).dropped.C_scout, true)
    notices = {}
    -- (the sites laid again: a near point drawn for each, none of their places loaded)
    PZExtAPI = { version = OA.API_VERSION, client = function() return {} end,
        zones = { points = function(x, y, lo) return { { x = x + lo, y = y, zones = {} } } end } }
    getWorld = function() return { getMetaGrid = function() return { getCellData = function() return {} end } end } end
    getCell = function() return { getGridSquare = function() return nil end } end
    local specific = getSpecificPlayer
    getSpecificPlayer = function() return nil end
    local site = Survey.siteOf("scout")
    local ox = site.x
    site.state, site.taken, site.left = "placed", true, 3
    OA.Story.section(r).sitesSeen[site.n] = true
    OA.Story.section(r).fragmentsTaken = { [site.kind] = true }
    local fired = Dev.resetSurvey(r)
    eq(site.state, "pending", "its site laid again")
    eq(site.x, ox + Sites.NEAR_LO, "near where it was")
    eq(site.taken, nil)
    eq(site.left, nil)
    eq(OA.Story.section(r).sitesSeen[site.n], nil, "never seen")
    eq(OA.Story.section(r).fragmentsTaken[site.kind], nil, "its first pick-up to come")
    local waits = 0
    for _, e in ipairs(OA.Chunks.list("oa_site")) do
        if e.site == site.n then waits = waits + 1 truthy(e.x == site.x and e.y == site.y) end
    end
    eq(waits, 1, "built when its new place loads")
    truthy(#OA.Chunks.list("oa_dev_unbuild") > 0, "the old one taken down when its place loads")
    eq(Rules.unsealed(u, "scout"), false, "sealed again: its capstone was not taken")
    eq(Comms.section(r).dropped.C_scout, nil)
    eq(fired[1], "C_scout", "the call at once")
    eq(notices[#notices], "IGUI_OA_Story_Notice_BranchCall")
    -- its fragment delivered, then the survey reset: the team's note of the kind goes too, so the search comes again
    local fullType = OA.Upgrades.Data.FRAGMENTS.scout
    OA.Story.onSettled(r, { lines = { { marks = { fragment = true }, fullType = fullType } } })
    truthy(Rules.unsealed(u, "scout") and Sites.received(fullType))
    Dev.resetSurvey(r)
    eq(Rules.unsealed(u, "scout"), false)
    eq(Sites.received(fullType), false, "the world's note of the kind forgotten")
    eq((OA.Story.section(r).fragmentsGot or {}).scout, nil)
    eq(Comms.section(r).fired.C_had_scout, nil, "not opened again as a fragment had")
    truthy(Comms.section(r).fired.C_scout ~= nil, "the search's call again")
    OA.Chunks.remove(function(e) return e.kind == "oa_dev_unbuild" end)
    PZExtDev, PZExtAPI, getWorld, getCell, getSpecificPlayer = nil, nil, nil, nil, specific
end)

test("the survey calls know their order, the same when played again from the record", function()
    local r = record(false)
    local D = OA.CommsData.BY_ID
    eq(Comms.order(r, D.C_load), 1, "none before it")
    Comms.played(r, "C_scout", 3, 100)
    Comms.played(r, "C_got_scout", 3, 101)
    eq(Comms.order(r, D.C_load), 2, "another branch's call is not counted")
    Comms.played(r, "C_load", 3, 102)
    Comms.played(r, "C_survival_k", 3, 103)
    eq(Comms.order(r, D.C_scout), 1, "played again: its own place")
    eq(Comms.order(r, D.C_load), 2)
    eq(Comms.order(r, D.C_survival_k), 3, "관리 7's counts with the team's")
end)
