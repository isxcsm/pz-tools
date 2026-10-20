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

test("the call played marks the site's zone: the site inside, away from the middle; the fragment takes it away", function()
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
    near(d, Survey.R * Survey.OFFSET, 1)
    truthy(d < z.r)
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

test("a fragment the team had from a character before lets the next one's capstone through, with no call", function()
    local r = record(true)
    local sec = OA.Store.world("sites")
    Sites.receive(OA.Upgrades.Data.FRAGMENTS.scout)
    eq(#Branches.look(r, "approved"), 0, "no call")
    eq(Rules.unsealed(Rules.section(r), "scout"), true, "the capstone opens")
    eq(Rules.blocked(Rules.section(r), "nightEye"), nil)
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
    local fired = Dev.resetSurvey(r)
    eq(Rules.unsealed(u, "scout"), false, "sealed again: its capstone was not taken")
    eq(Comms.section(r).dropped.C_scout, nil)
    eq(fired[1], "C_scout", "the call at once")
    eq(notices[#notices], "IGUI_OA_Story_Notice_BranchCall")
    PZExtDev = nil
end)
