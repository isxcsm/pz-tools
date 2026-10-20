-- The drop sites' survey zones (the "survey" branch of the team's calls, Story/Branches): when a tree's capstone waits
-- for nothing but its meteorite fragment (every other condition met: Upgrades Rules.blocked gives "sealed"), a call
-- comes once about the fragment, and as it is played the maps mark a wide zone the tree's drop site lies in, away from
-- its middle. The zone narrows in STAGES: walking into the zone the maps show puts a smaller one there, round the site
-- and away from its middle again, so each step has the next place to go to, and the last one (the site's props in
-- sight from anywhere in it) is the player's to search. Into the first: a title as a mission's circle has ("unveil")
-- and a line after it (SurveyIn); into the next: a title and its line (SurveyNear). The zone stays until the fragment
-- reaches the team; once its fragment is picked up the zone goes, and the maps mark where the fragment lies whenever the
-- character does not carry it (Survey.points; Sites.lookFragments follows it). Before the handover the team calls, after it 관리 7 (each its own call; one fired before the
-- handover and not yet played gives way to the other).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Sites"
require "OperationAcorn/Story/Branches"
require "OperationAcorn/Say"
local OA = OperationAcorn
local Survey = {}
OA.StorySurvey = Survey

-- The zones' radii (squares), stage by stage, and how far from the site a zone's middle lies, a share of its radius
-- from OFFSET_MIN to OFFSET_MAX that the site's place picks: the site is inside, never at the middle nor always as far
-- from it. R: the first.
Survey.STAGES = { 150, 60, 25 }
Survey.R = Survey.STAGES[1]
Survey.OFFSET_MIN, Survey.OFFSET_MAX = 0.2, 0.7
-- Real seconds from a title to its line (the title is read first, as Scene.ARRIVE_SAY).
Survey.SAY = 5

-- The self-talk. SurveyIn (each line first takes in that this is the place): lines 1-2 at night, 3 by day, 4 for a
-- site the character has stood near before, the rest any time. SurveyNear: line 1 at night, 2 by day, the rest any time.
OA.Say.define("SurveyIn", { tags = {
    [1] = { night = true }, [2] = { night = true }, [3] = { night = false }, [4] = { seen = true },
} })
OA.Say.define("SurveyNear", { tags = { [1] = { night = true }, [2] = { night = false } } })

local function rules() return OA.Upgrades.Rules end
local function data() return OA.Upgrades.Data end

-- The call ids of a tree: the team's and 관리 7's.
function Survey.callOf(tree, admin)
    return "C_" .. tree .. (admin and "_k" or "")
end

-- The drop site of a tree's fragment kind (the latest fall: one whose fragment was lost has another), or nil (none
-- decided yet).
function Survey.siteOf(tree)
    local fullType = data().FRAGMENTS[tree]
    local found
    for _, site in ipairs(OA.Sites.list()) do
        local item = OA.Sites.FRAGMENT[site.kind]
        if item and fullType == "OperationAcorn." .. item and not site.relaid then found = site end
    end
    return found
end

-- The zone of a site at a stage (1 by default): { x, y, r }, its middle a share of its radius (OFFSET_MIN ..
-- OFFSET_MAX) from the site in a direction, both picked by the site's place and the stage (the same every time it is
-- asked; where one stage's middle lay tells nothing of where in the next the site is).
function Survey.zone(site, stage)
    stage = stage or 1
    local salt = stage - 1
    local turn = OA.remainder(site.x * 31 + site.y * 17 + salt * 157, 360) * math.pi / 180
    local share = OA.remainder(site.x * 13 + site.y * 7 + salt * 389, 1000) / 1000
    local r = Survey.STAGES[stage]
    local d = r * (Survey.OFFSET_MIN + share * (Survey.OFFSET_MAX - Survey.OFFSET_MIN))
    return { x = math.floor(site.x + d * math.cos(turn) + 0.5), y = math.floor(site.y + d * math.sin(turn) + 0.5),
        r = r }
end

-- Whether a tree's capstone waits only for its fragment.
function Survey.waiting(record, tree)
    local cap = data().capstone(tree)
    return cap ~= nil and rules().blocked(rules().section(record), cap.id) == "sealed"
end

local function marked(record)
    local s = OA.Story.section(record)
    s.surveys = s.surveys or {}
    return s.surveys
end

-- The stage each tree's zone is at: { n = its site, stage }, 1 when none is kept for that site (a lost fragment's new
-- fall starts wide again).
local function stages(record)
    local s = OA.Story.section(record)
    s.surveysStage = s.surveysStage or {}
    return s.surveysStage
end

local function stageOf(record, tree, site)
    local at = stages(record)[tree]
    return at and at.n == site.n and at.stage or 1
end

-- The site of a tree's zone shown to a record, or nil (no call played, or its fragment reached the team).
local function surveyed(record, tree)
    local site = marked(record)[tree] and Survey.siteOf(tree)
    if site and not rules().unsealed(rules().section(record), tree) then return site end
    return nil
end

-- The zones the maps show: { { x, y, r, tree }, ... } for each tree whose call was played and whose fragment has not
-- reached the team (round its latest fall: a lost fragment's kind fell again).
function Survey.zones(record)
    local list = {}
    for _, tree in ipairs(data().TREES) do
        local site = surveyed(record, tree)
        if site and not site.taken then
            local z = Survey.zone(site, stageOf(record, tree, site))
            z.tree, z.stage = tree, stageOf(record, tree, site)
            list[#list + 1] = z
        end
    end
    return list
end

-- Every game minute, the player at x, y (`isNight()` asked only when a line is said): a zone walked into narrows to
-- the next stage, with its title and line; walked straight into a deeper one (a car's speed), the stage after the
-- deepest, with that one's title and line alone.
function Survey.minute(record, x, y, isNight)
    if not OA.Story.section(record).surveys or not x then return end
    if OA.Sites.lookFragments(record) then OA.Sync.changed("story", record.id) end
    local last = #Survey.STAGES
    for _, tree in ipairs(data().TREES) do
        local site = surveyed(record, tree)
        local at = site and not site.taken and stageOf(record, tree, site)
        if at and at < last then
            local to = at
            for stage = last - 1, at, -1 do
                local z = Survey.zone(site, stage)
                if OA.Places.distance(x, y, z.x, z.y) <= z.r then
                    to = stage + 1
                    break
                end
            end
            if to > at then
                stages(record)[tree] = { n = site.n, stage = to }
                local night = isNight() == true
                if to == last then
                    OA.Sync.title(record.id, { key = "IGUI_OA_Title_SurveyClose", sub = "IGUI_OA_Title_SurveyCloseSub",
                        style = "discovery" })
                    OA.Say.tell(record.id, "SurveyNear", { night = night }, Survey.SAY)
                else
                    local seen = OA.Sites.seenOf(record)
                    OA.Sync.title(record.id, { key = "IGUI_OA_Title_SurveyIn", sub = "IGUI_OA_Title_SurveyInSub", style = "unveil" })
                    OA.Say.tell(record.id, "SurveyIn", { night = night, seen = (seen and seen[site.n]) == true }, Survey.SAY)
                end
                OA.Sync.changed("story", record.id)
            end
        end
    end
end

-- Where the fragments of the zones shown lie when the character does not carry them: { { x, y, tree }, ... } (the
-- last place known: Sites.lookFragments).
function Survey.points(record)
    local list = {}
    for _, tree in ipairs(data().TREES) do
        local site = surveyed(record, tree)
        local at = site and site.taken and site.at
        if at and not at.carried then list[#list + 1] = { x = at.x, y = at.y, tree = tree } end
    end
    return list
end

-- A site a record searches by its zone has no title of its own when first come near (Sites.visit): the zone's titles
-- tell of it.
function OA.Sites.quiet(record, site)
    for _, tree in ipairs(data().TREES) do
        if surveyed(record, tree) == site then return true end
    end
    return false
end

-- A capstone waiting for a fragment the research team has had already (a character before this one delivered it): the
-- team has it, the capstone opens (Upgrades.fragmentReceived: its memo and word of it), and no call is made.
local function hadAlready(record)
    for _, tree in ipairs(data().TREES) do
        local fullType = data().FRAGMENTS[tree]
        if Survey.waiting(record, tree) and OA.Sites.received(fullType) and OA.Upgrades.fragmentReceived then
            OA.Upgrades.fragmentReceived(record, fullType)
        end
    end
end

-- Another fall of a lost fragment's kind (Sites.relay): every character still waiting for that kind, whose call was
-- played, is told the maps show the new place.
function OA.Sites.onRelaid(site)
    for _, record in pairs(OA.Store.players()) do
        if OA.Store.alive(record) then
            for _, tree in ipairs(data().TREES) do
                local waits = not rules().unsealed(rules().section(record), tree)
                if waits and marked(record)[tree] and Survey.siteOf(tree) == site then
                    OA.Sync.notice(record.id, "IGUI_OA_Story_Notice_SiteAgain", {})
                    OA.Sync.changed("story", record.id)
                end
            end
        end
    end
end

OA.StoryBranches.define("survey", {
    at = { "approved", "settled" },
    fires = function(record)
        hadAlready(record)
        local admin = OA.Story.handedOver(record)
        local triggers = {}
        for _, tree in ipairs(data().TREES) do
            local heard = OA.Comms.section(record).played
            if not (heard[Survey.callOf(tree, false)] or heard[Survey.callOf(tree, true)])
                and Survey.waiting(record, tree) and Survey.siteOf(tree) then
                triggers[#triggers + 1] = "survey:" .. tree .. (admin and ":admin" or "")
            end
        end
        return triggers
    end,
    unwanted = function(record)
        local u = rules().section(record)
        local admin = OA.Story.handedOver(record)
        local ids = {}
        for _, tree in ipairs(data().TREES) do
            if rules().unsealed(u, tree) then
                ids[#ids + 1] = Survey.callOf(tree, false)
                ids[#ids + 1] = Survey.callOf(tree, true)
            elseif admin then
                ids[#ids + 1] = Survey.callOf(tree, false)
            end
        end
        return ids
    end,
    played = function(record, entry)
        local site = Survey.siteOf(entry.survey)
        if site then
            marked(record)[entry.survey] = site.n
            OA.Sync.changed("story", record.id)
        end
    end,
})

return Survey
