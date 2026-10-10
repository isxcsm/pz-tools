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

-- ---- the approval stamp (DESIGN-terminal 19) --------------------------------------------------------------------
-- After the server's approval comes back, the research tab lights the planned nodes one by one and presses a seal on the
-- plan. This is only the timing; the tab draws it, while it is open.

-- Milliseconds: between two nodes lighting (shorter for a long plan, so that the nodes take STAMP_MAX_MS at most), how
-- long a node's flash lasts, the pause before the seal, the seal's press, and how long the seal stays (the end fades).
Plan.STAMP_STEP_MS = 160
Plan.STAMP_MAX_MS = 2200
Plan.STAMP_FLASH_MS = 450
Plan.SEAL_WAIT_MS = 150
Plan.SEAL_PRESS_MS = 140
Plan.SEAL_MS = 1600
Plan.SEAL_FADE_MS = 400

-- The nodes the stamp lights: the plan's, in its order, each once. `shown` (id -> true) keeps the ones on the screen.
function Plan.stampOrder(steps, shown)
    local order, seen = {}, {}
    for _, step in ipairs(steps) do
        if not seen[step.id] and (shown == nil or shown[step.id]) then
            seen[step.id] = true
            order[#order + 1] = step.id
        end
    end
    return order
end

-- Milliseconds between two nodes of a stamp of n nodes.
function Plan.stampStep(n)
    if n <= 0 then return Plan.STAMP_STEP_MS end
    return math.min(Plan.STAMP_STEP_MS, math.floor(Plan.STAMP_MAX_MS / n))
end

-- When the seal is pressed, and when the whole stamp is over, for n nodes.
function Plan.sealAt(n)
    return n * Plan.stampStep(n) + Plan.SEAL_WAIT_MS
end

function Plan.stampEnd(n)
    return Plan.sealAt(n) + Plan.SEAL_MS
end

-- The stamp at `t` ms: how many nodes have lit, how long ago the seal was pressed (nil before), and whether it is over.
function Plan.stamp(n, t)
    local step = Plan.stampStep(n)
    local lit = math.min(n, math.floor(t / step) + 1)
    if t < 0 then lit = 0 end
    local sealAge = t >= Plan.sealAt(n) and (t - Plan.sealAt(n)) or nil
    return { lit = lit, sealAge = sealAge, over = t >= Plan.stampEnd(n) }
end

-- What the stamp of n nodes shows at `t` ms, as a number that changes exactly when its drawing does (the tab is drawn
-- afresh on it with PZ Optimization): `t` while a node's flash, the seal's press or its fade moves, -1 while the
-- pressed seal holds still, nil once the stamp is over.
function Plan.stampLook(n, t)
    if t >= Plan.stampEnd(n) then return nil end
    local sealAt = Plan.sealAt(n)
    local still = math.max(sealAt + Plan.SEAL_PRESS_MS, (n - 1) * Plan.stampStep(n) + Plan.STAMP_FLASH_MS)
    if t >= still and t < sealAt + Plan.SEAL_MS - Plan.SEAL_FADE_MS then return -1 end
    return t
end

return Plan
