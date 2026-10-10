-- What follows an upgrade serum dose (DESIGN-terminal 19): the body adapts for a while (the moodle `적응 중`), the
-- research point comes when it is over, with a line over the head and a line of self-talk, and the research team's
-- papers come to the terminal's folder (the research plan with the first dose ever, a memo when a tree opens and
-- another when its capstone is approved). The rules of the time are Rules.startAdapt, adaptDone and finishAdapt (pure);
-- this file touches the record, the folder and the player's screen, where the world is decided (the server, or the game
-- alone). The client asks for the end once a game minute (client Upgrades/Adapting.lua) and the server decides.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Say"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Docs = OA.StoryDocs
local Adapt = {}
OA.Upgrades.Adapt = Adapt

-- The documents the research team sends to the folder (Docs.addGuide): the plan, and for each tree its memo when it
-- opens ("open") and when its capstone is approved ("cap").
Adapt.GUIDE = "research_guide"
Adapt.MEMOS = { "open", "cap" }

function Adapt.memoId(tree, which)
    return "memo_" .. tree .. "_" .. which
end

Docs.addGuide(Adapt.GUIDE)
for _, tree in ipairs(Data.TREES) do
    for _, which in ipairs(Adapt.MEMOS) do Docs.addGuide(Adapt.memoId(tree, which)) end
end

-- The self-talk when an adaptation is over: three lines a tree, in the order of the trees.
local PER_TREE = 3
local tags = {}
for n = 1, #Data.TREES * PER_TREE do tags[n] = { tree = Data.TREES[math.ceil(n / PER_TREE)] } end
OA.Say.define("Adapted", { tags = tags })

-- Puts a document in the record's folder, new until opened. True when it was not there yet (false too when the story
-- part is not there to keep it).
function Adapt.deliver(record, id)
    local story = OA.Story
    if not (story and story.deliverDocument) then return false end
    return story.deliverDocument(record, id) == true
end

-- A dose of an upgrade serum (a tree's, or "shared") is injected: its adaptation starts, and the first dose ever brings
-- the research plan to the folder. Returns true when that paper came now.
function Adapt.start(record, key, now)
    Rules.startAdapt(Rules.section(record), key, now or OA.hours())
    return Adapt.deliver(record, Adapt.GUIDE)
end

-- The adaptation is over (the time of the record's end has passed): the points come, the trees that opened bring their
-- memo, and the player is told. Returns true when it ended now.
function Adapt.finish(record, now)
    local u = Rules.section(record)
    if not Rules.adaptDone(u, now or OA.hours()) then return false end
    local result = Rules.finishAdapt(u)
    local id = record.id
    local talk, most = nil, 0
    for _, tree in ipairs(Data.TREES) do
        local n = result.trees[tree]
        if n then
            OA.Sync.notice(id, "IGUI_OA_Tree_Adapted", { tree, n })
            if n > most then talk, most = tree, n end
        end
    end
    if result.shared > 0 then OA.Sync.notice(id, "IGUI_OA_Tree_AdaptedShared", { result.shared }) end
    for _, tree in ipairs(result.opened) do
        local sent = Adapt.deliver(record, Adapt.memoId(tree, "open"))
        OA.Sync.notice(id, "IGUI_OA_Tree_Opened", { tree, sent and "guide" or "" })
    end
    OA.Sync.changed("upgrades", id, { kind = "adapted" })
    if talk then OA.Say.tell(id, "Adapted", { tree = talk }) end
    return true
end

-- The trees whose capstone is approved in u: { [tree] = true }.
function Adapt.capstones(u)
    local done = {}
    for _, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        if cap and Rules.rank(u, cap.id) >= 1 then done[tree] = true end
    end
    return done
end

-- A plan is approved: each capstone newly taken (not in `before`, as Adapt.capstones gave it) brings its memo. The
-- player is told once. Returns true when a memo came.
function Adapt.approved(record, before)
    local after = Adapt.capstones(Rules.section(record))
    local sent = false
    for _, tree in ipairs(Data.TREES) do
        if after[tree] and not before[tree] and Adapt.deliver(record, Adapt.memoId(tree, "cap")) then sent = true end
    end
    if sent then OA.Sync.notice(record.id, "IGUI_OA_Tree_GuideSent", {}) end
    return sent
end

return Adapt
