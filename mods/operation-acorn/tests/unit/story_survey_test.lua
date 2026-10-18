-- The survey branch (Story/Survey on Story/Branches): a capstone waiting only for its fragment brings a call once,
-- with a notice; the call played marks the drop site's zone on the maps; the fragment arriving drops a call not yet
-- played and takes the zone away; the tiers never drop it; after the handover 관리 7 calls instead.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Survey"
require "OperationAcorn/Story/View"
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
