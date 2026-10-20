-- The drop sites' survey zones (the "survey" branch of the team's calls, Story/Branches): when a tree's capstone waits
-- for nothing but its meteorite fragment (every other condition met: Upgrades Rules.blocked gives "sealed"), a call
-- comes once about the fragment, and as it is played the maps mark a wide zone the tree's drop site lies in, away from
-- its middle: the last stretch is the player's to search. The zone stays until the fragment reaches the team. Before
-- the handover the team calls, after it 관리 7 (each its own call; one fired before the handover and not yet played
-- gives way to the other).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Sites"
require "OperationAcorn/Story/Branches"
local OA = OperationAcorn
local Survey = {}
OA.StorySurvey = Survey

-- The zone's radius (squares), and how far from the site its middle lies, a share of the radius: the site is inside,
-- and from anywhere on the zone's rim the player is within reach of the site's title (Sites.visit's 80) halfway in.
Survey.R = 150
Survey.OFFSET = 0.5

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

-- The zone of a site: { x, y, r }, its middle OFFSET * R from the site in a direction the site's place picks (the same
-- every time it is asked).
function Survey.zone(site)
    local turn = OA.remainder(site.x * 31 + site.y * 17, 360) * math.pi / 180
    local d = Survey.R * Survey.OFFSET
    return { x = math.floor(site.x + d * math.cos(turn) + 0.5), y = math.floor(site.y + d * math.sin(turn) + 0.5),
        r = Survey.R }
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

-- The zones the maps show: { { x, y, r, tree }, ... } for each tree whose call was played and whose fragment has not
-- reached the team (round its latest fall: a lost fragment's kind fell again).
function Survey.zones(record)
    local list = {}
    local u = rules().section(record)
    for _, tree in ipairs(data().TREES) do
        local site = marked(record)[tree] and Survey.siteOf(tree)
        if site and not rules().unsealed(u, tree) then
            local z = Survey.zone(site)
            z.tree = tree
            list[#list + 1] = z
        end
    end
    return list
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
