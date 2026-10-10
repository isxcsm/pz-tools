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
-- After the server's approval comes back, the research tab runs over the planned nodes one by one (each pops and
-- flashes gold with a ring as it lights), then a seal drops onto the trees: it falls in from larger, slams down with a
-- squash, jolts the trees and sends an ink ring out from the impact; its ink settles, it holds, and it lifts away.
-- This is only the timing and the curves; the tab draws it, while it is open.

-- Milliseconds and sizes: between two nodes lighting (shorter for a long plan, so that the nodes take STAMP_MAX_MS at
-- most), how long a node's flash lasts, its pop (STAMP_POP of its size, over STAMP_POP_MS) and its ring (out to
-- STAMP_RING design units); the pause before the seal; the seal's fall (from SEAL_FROM times its size), its squash
-- (SEAL_SQUASH of its height), the trees' jolt (SEAL_JOLT_DU design units), its ink splatter (from SEAL_INK_FROM of
-- the seal's size out by SEAL_INK_GROW of it) and how much its ink settles (SEAL_SETTLE); how long it stays from its
-- fall (the end lifts it by SEAL_LIFT and fades it).
Plan.STAMP_STEP_MS = 140
Plan.STAMP_MAX_MS = 1400
Plan.STAMP_FLASH_MS = 420
Plan.STAMP_POP, Plan.STAMP_POP_MS = 0.16, 240
Plan.STAMP_RING = 10
Plan.SEAL_WAIT_MS = 120
Plan.SEAL_DROP_MS, Plan.SEAL_FROM = 150, 1.35
Plan.SEAL_SQUASH_MS, Plan.SEAL_SQUASH = 170, 0.09
Plan.SEAL_JOLT_MS, Plan.SEAL_JOLT_DU = 160, 3
Plan.SEAL_INK_MS, Plan.SEAL_INK_FROM, Plan.SEAL_INK_GROW = 480, 0.95, 0.3
Plan.SEAL_SETTLE = 0.15
Plan.SEAL_MS = 1250
Plan.SEAL_FADE_MS, Plan.SEAL_LIFT = 320, 0.06

local function easeOut(u)
    if u <= 0 then return 0 end
    if u >= 1 then return 1 end
    local v = 1 - u
    return 1 - v * v * v
end

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

-- When the seal starts to fall, and when the whole stamp is over, for n nodes.
function Plan.sealAt(n)
    return n * Plan.stampStep(n) + Plan.SEAL_WAIT_MS
end

function Plan.stampEnd(n)
    return Plan.sealAt(n) + Plan.SEAL_MS
end

-- How long the seal moves from the start of its fall: the fall, then the longest of the squash, the jolt and the ink.
function Plan.sealSettle()
    return Plan.SEAL_DROP_MS + math.max(Plan.SEAL_SQUASH_MS, Plan.SEAL_JOLT_MS, Plan.SEAL_INK_MS)
end

-- How many nodes of a stamp of n have lit at `t` ms.
function Plan.stampLit(n, t)
    if t < 0 then return 0 end
    return math.min(n, math.floor(t / Plan.stampStep(n)) + 1)
end

-- The stamp at `t` ms: how many nodes have lit, how long ago the seal started to fall (nil before), and whether it is
-- over.
function Plan.stamp(n, t)
    local sealAge = t >= Plan.sealAt(n) and (t - Plan.sealAt(n)) or nil
    return { lit = Plan.stampLit(n, t), sealAge = sealAge, over = t >= Plan.stampEnd(n) }
end

-- A lit node's scale `age` ms after it lit: one quick swell (its top early), 1 outside it.
function Plan.stampPop(age)
    if age < 0 or age >= Plan.STAMP_POP_MS then return 1 end
    return 1 + Plan.STAMP_POP * math.sin(math.pi * easeOut(age / Plan.STAMP_POP_MS))
end

-- A lit node's flash `age` ms after it lit: its strength and how far its ring has gone; nil once over.
function Plan.stampFlash(age)
    if age < 0 or age >= Plan.STAMP_FLASH_MS then return nil end
    local u = age / Plan.STAMP_FLASH_MS
    local fade = 1 - u
    return fade * fade, Plan.STAMP_RING * easeOut(u)
end

-- The seal `age` ms after it started to fall: its width and height as shares of its size, how much of it shows, how
-- strong its ink is (settling after the impact), and its ink splatter's size (a share of the seal's) and strength
-- (nil, 0 outside it); nil before the fall and once it is gone.
function Plan.seal(age)
    if age < 0 or age >= Plan.SEAL_MS then return nil end
    local drop = Plan.SEAL_DROP_MS
    local sx, sy, a, ink = 1, 1, 1, 1
    local inkSize, inkA = nil, 0
    if age < drop then
        -- falling: faster and faster, from larger, coming into view
        local u = age / drop
        local k = Plan.SEAL_FROM - (Plan.SEAL_FROM - 1) * u * u
        sx, sy = k, k
        a = math.min(1, u / 0.4)
        a = a * a * (3 - 2 * a)
    else
        local t = age - drop
        if t < Plan.SEAL_SQUASH_MS then
            local q = 1 - t / Plan.SEAL_SQUASH_MS
            q = q * q
            sx, sy = 1 + 0.7 * Plan.SEAL_SQUASH * q, 1 - Plan.SEAL_SQUASH * q
        end
        if t < Plan.SEAL_INK_MS then
            local u = t / Plan.SEAL_INK_MS
            local fade = 1 - u
            inkSize, inkA = Plan.SEAL_INK_FROM + Plan.SEAL_INK_GROW * easeOut(u), 0.95 * fade * math.sqrt(fade)
        end
        ink = 1 - Plan.SEAL_SETTLE * easeOut(t / Plan.SEAL_INK_MS)
        -- lifting away at the end
        local left = Plan.SEAL_MS - age
        if left < Plan.SEAL_FADE_MS then
            local v = 1 - left / Plan.SEAL_FADE_MS
            local k = 1 + Plan.SEAL_LIFT * v
            sx, sy = sx * k, sy * k
            a = 1 - v * v * (3 - 2 * v)
        end
    end
    return sx, sy, a, ink, inkSize, inkA
end

-- The trees' jolt `age` ms after the seal started to fall: how far they are pushed down (design units: down at the
-- impact, a small bounce back, still); 0 outside it.
function Plan.sealJolt(age)
    local t = age - Plan.SEAL_DROP_MS
    if t < 0 or t >= Plan.SEAL_JOLT_MS then return 0 end
    local u = t / Plan.SEAL_JOLT_MS
    return Plan.SEAL_JOLT_DU * (1 - u) * math.cos(3 * math.pi * u)
end

-- What the stamp of n nodes shows at `t` ms, as a number that changes exactly when its drawing does (the tab is drawn
-- afresh on it with PZ Optimization): `t` while a node's pop or flash, the seal's fall, squash, jolt and ink, or its
-- lift moves, -1 while the pressed seal holds still, nil once the stamp is over.
function Plan.stampLook(n, t)
    if t >= Plan.stampEnd(n) then return nil end
    local sealAt = Plan.sealAt(n)
    local still = math.max(sealAt + Plan.sealSettle(), (n - 1) * Plan.stampStep(n) + Plan.STAMP_FLASH_MS)
    if t >= still and t < sealAt + Plan.SEAL_MS - Plan.SEAL_FADE_MS then return -1 end
    return t
end

return Plan
