-- The drop sites' survey zones (the "survey" branch of the team's calls, Story/Branches): when a tree's capstone waits
-- for nothing but its meteorite fragment (every other condition met: Upgrades Rules.blocked gives "sealed"), a call
-- comes once about the fragment, and as it is played the maps mark a wide zone the tree's drop site lies in, away from
-- its middle: the last stretch is the player's to search. Once the player comes within NEAR of the site, or into the
-- inner part of the zone (INNER of its radius round its middle: the middle is where the map says to go), the zone
-- narrows to a small one round it (NEAR_R, as far off its middle), with a title. First walking into the zone has its
-- title as a mission's circle has ("unveil"), and each title its line after it (SurveyIn, SurveyNear). The zone stays until the fragment
-- reaches the team. Before
-- the handover the team calls, after it 관리 7 (each its own call; one fired before the handover and not yet played
-- gives way to the other).
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

-- The zone's radius (squares), and how far from the site its middle lies, a share of the radius from OFFSET_MIN to
-- OFFSET_MAX that the site's place picks: the site is inside, never at the middle nor always as far from it.
Survey.R = 150
Survey.OFFSET_MIN, Survey.OFFSET_MAX = 0.2, 0.7
-- How near the site the zone narrows (Sites.visit's reach), and the narrow zone's radius: the site's props are in
-- sight from anywhere in it.
Survey.NEAR = 80
Survey.NEAR_R = 30
Survey.INNER = 0.5
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

-- The zone of a site: { x, y, r }, its middle a share of its radius (OFFSET_MIN .. OFFSET_MAX) from the site in a
-- direction, both picked by the site's place (the same every time it is asked); `narrow`: the small one, with its own
-- share and direction (where the wide one's middle lay tells nothing of where in the small one the site is).
function Survey.zone(site, narrow)
    local salt = narrow and 1 or 0
    local turn = OA.remainder(site.x * 31 + site.y * 17 + salt * 157, 360) * math.pi / 180
    local share = OA.remainder(site.x * 13 + site.y * 7 + salt * 389, 1000) / 1000
    local r = narrow and Survey.NEAR_R or Survey.R
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

-- The sites each tree's zone narrowed round (a lost fragment's new fall starts wide again).
local function narrowed(record)
    local s = OA.Story.section(record)
    s.surveysNear = s.surveysNear or {}
    return s.surveysNear
end

-- The sites each tree's zone was walked into.
local function entered(record)
    local s = OA.Story.section(record)
    s.surveysIn = s.surveysIn or {}
    return s.surveysIn
end

-- The zones the maps show: { { x, y, r, tree }, ... } for each tree whose call was played and whose fragment has not
-- reached the team (round its latest fall: a lost fragment's kind fell again).
function Survey.zones(record)
    local list = {}
    local u = rules().section(record)
    for _, tree in ipairs(data().TREES) do
        local site = marked(record)[tree] and Survey.siteOf(tree)
        if site and not rules().unsealed(u, tree) then
            local z = Survey.zone(site, narrowed(record)[tree] == site.n)
            z.tree = tree
            list[#list + 1] = z
        end
    end
    return list
end

-- Every game minute, the player at x, y (`isNight()` asked only when a line is said): a wide zone first walked into
-- has its line; one whose site is within NEAR, or whose inner part is reached, narrows, with a title and then its line (the site counts as seen:
-- Sites.visit gives no title of its own for it; walked straight that near, only the narrowing's line).
function Survey.minute(record, x, y, isNight)
    local s = OA.Story.section(record)
    if not s.surveys or not x then return end
    local u = rules().section(record)
    for _, tree in ipairs(data().TREES) do
        local site = s.surveys[tree] and Survey.siteOf(tree)
        if site and narrowed(record)[tree] ~= site.n and not rules().unsealed(u, tree) then
            local seen = OA.Sites.seenOf(record)
            local wide = Survey.zone(site)
            if OA.Places.distance(x, y, site.x, site.y) <= Survey.NEAR
                or OA.Places.distance(x, y, wide.x, wide.y) <= wide.r * Survey.INNER then
                narrowed(record)[tree], entered(record)[tree] = site.n, site.n
                if seen then seen[site.n] = true end
                OA.Sync.title(record.id, { key = "IGUI_OA_Title_Site", sub = "IGUI_OA_Title_SurveyNear", style = "discovery" })
                OA.Say.tell(record.id, "SurveyNear", { night = isNight() == true }, Survey.SAY)
                OA.Sync.changed("story", record.id)
            elseif entered(record)[tree] ~= site.n then
                if OA.Places.distance(x, y, wide.x, wide.y) <= wide.r then
                    entered(record)[tree] = site.n
                    OA.Sync.title(record.id, { key = "IGUI_OA_Title_SurveyIn", sub = "IGUI_OA_Title_SurveyInSub", style = "unveil" })
                    OA.Say.tell(record.id, "SurveyIn", { night = isNight() == true, seen = (seen and seen[site.n]) == true },
                        Survey.SAY)
                end
            end
        end
    end
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
