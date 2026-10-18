-- Side threads of the team's calls (CommsData `branch`): calls that come on a condition of their own, apart from the
-- story's order. A branch says at which moments its condition can change, which of its calls the condition fires now
-- (CommsData triggers), which of its calls are no longer wanted, and what a call of it does once played. Calls fired
-- here come with a notice; Story/Comms keeps their order (a branch call waits only for its own branch, holds nothing
-- else up and is never dropped by a tier). A new branch: its calls in CommsData with `branch`, and a Branches.define.
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Comms"
local OA = OperationAcorn
local Branches = {}
OA.StoryBranches = Branches

-- The moments the story looks at the branches: "approved" (a serum plan applied), "settled" (a crate settled).
local defs, names = {}, {}

-- name: the CommsData `branch`. def = { at = { moment, ... }, fires = function(record) -> { trigger, ... },
-- unwanted = function(record) -> { entry id, ... } (optional), played = function(record, entry) (optional) }.
function Branches.define(name, def)
    if not defs[name] then names[#names + 1] = name end
    local at = {}
    for _, moment in ipairs(def.at or {}) do at[moment] = true end
    defs[name] = { at = at, fires = def.fires, unwanted = def.unwanted, played = def.played }
end

-- Looks at the branches that watch this moment: drops what is no longer wanted, fires what the conditions give, and
-- tells the player once when a call came. Returns the ids fired.
function Branches.look(record, moment)
    local fired = {}
    for _, name in ipairs(names) do
        local def = defs[name]
        if def.at[moment] then
            for _, id in ipairs(def.unwanted and def.unwanted(record) or {}) do OA.Comms.drop(record, id) end
            for _, trigger in ipairs(def.fires(record)) do
                for _, id in ipairs(OA.Comms.fire(record, trigger)) do fired[#fired + 1] = id end
            end
        end
    end
    if #fired > 0 then
        OA.Sync.changed("comms", record.id)
        OA.Sync.notice(record.id, "IGUI_OA_Story_Notice_BranchCall", {})
    end
    return fired
end

-- A call was played: its branch does what the call speaks of.
function Branches.played(record, id)
    local e = OA.CommsData.BY_ID[id]
    local def = e and e.branch and defs[e.branch]
    if def and def.played then def.played(record, e) end
end

return Branches
