-- The plan on the research screen: ranks chosen but not yet approved. A plan is a list of steps { id, choice }, each
-- taking one rank; it is shown on a copy of the record's upgrades (the simulation) so that the screen sees what the
-- plan would make true. Pure; the screen only draws what these give.
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Plan = {}
OA.Upgrades.Plan = Plan

-- Runs the steps on a copy of u. Steps that cannot be taken in their place (a step after one that was removed) are
-- left out. Returns the simulation, the steps that held, and the fragments the plan uses.
function Plan.simulate(u, steps, fragments)
    local sim = Rules.copy(u)
    local run = { fragments = fragments or 0 }
    local kept = {}
    for _, step in ipairs(steps) do
        if Rules.buy(sim, step.id, run, step.choice) then kept[#kept + 1] = step end
    end
    return sim, kept, (fragments or 0) - run.fragments
end

-- The plan with one more rank of a node, or nil and the reason it cannot be taken now.
function Plan.add(u, steps, id, choice, fragments)
    local sim, kept, used = Plan.simulate(u, steps, fragments)
    local why = Rules.blocked(sim, id, { fragments = (fragments or 0) - used }, choice)
    if why then return nil, why end
    local out = {}
    for i, step in ipairs(kept) do out[i] = step end
    out[#out + 1] = { id = id, choice = choice }
    return out
end

-- The plan without the last planned rank of a node, and without the steps that depended on it. Returns the new plan
-- (the same one when the node has no planned rank).
function Plan.remove(u, steps, id, fragments)
    local last
    for i, step in ipairs(steps) do
        if step.id == id then last = i end
    end
    if not last then return steps end
    local rest = {}
    for i, step in ipairs(steps) do
        if i ~= last then rest[#rest + 1] = step end
    end
    local _, kept = Plan.simulate(u, rest, fragments)
    return kept
end

-- How many ranks of each node the plan takes: { [id] = n }.
function Plan.counts(steps)
    local n = {}
    for _, step in ipairs(steps) do n[step.id] = (n[step.id] or 0) + 1 end
    return n
end

-- Points the plan spends: { [tree] = points in that tree's nodes, board = points on the board }, from the simulation.
function Plan.spent(u, sim)
    local out = { board = sim.board.spent - u.board.spent }
    for _, tree in ipairs(Data.TREES) do
        out[tree] = Rules.treeSpent(sim, tree) - Rules.treeSpent(u, tree)
    end
    return out
end

return Plan
