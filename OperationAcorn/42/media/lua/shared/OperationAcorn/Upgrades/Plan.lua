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

-- ---- the body taking an applied selection (DESIGN-terminal 19) --------------------------------------------------
-- When an applied selection comes back while the tab is open, the body takes it: a scan runs over the applied nodes in
-- the selection's order, one every TAKE_STEP_MS (shorter for a long selection, so that the scan lasts TAKE_MAX_MS at
-- most). Each node pops (TAKE_POP of its size over TAKE_POP_MS) and bursts: a glow in its tree's colour grows from
-- TAKE_BURST_FROM to TAKE_BURST_TO times its size and fades over TAKE_BURST_MS, a bright core flashes over
-- TAKE_CORE_MS, and its selected ranks settle into solid pips (a flash over TAKE_PIP_MS). A light runs from it up its
-- lit lines towards its tree's header (TAKE_SPEED design units a second, a TAKE_TAIL tail), and the header flashes as
-- it arrives (TAKE_HEADER_MS). TAKE_GLOW_WAIT_MS after the last node, and not before the last light has arrived, a
-- light runs round the frame of each column that took points, both ways from the middle of its top, and meets itself
-- at the bottom (in TAKE_TRACE of TAKE_GLOW_MS, slowing as it comes round), the column lighting softly behind it; then
-- the frame and the light fade (TAKE_GLOW_MS in all); the padlocks it opened come off after it.
Plan.TAKE_STEP_MS, Plan.TAKE_MAX_MS = 200, 1000
Plan.TAKE_POP, Plan.TAKE_POP_MS = 0.18, 260
Plan.TAKE_BURST_MS, Plan.TAKE_BURST_FROM, Plan.TAKE_BURST_TO = 520, 1.1, 3.0
Plan.TAKE_CORE_MS = 180
Plan.TAKE_PIP_MS = 360
Plan.TAKE_SPEED, Plan.TAKE_TAIL = 520, 34
Plan.TAKE_HEADER_MS = 420
Plan.TAKE_GLOW_WAIT_MS, Plan.TAKE_GLOW_MS, Plan.TAKE_TRACE = 100, 500, 0.65

local easeOut = OperationAcorn.easeOut

-- The nodes the scan takes: the selection's, in its order, each once. `shown` (id -> true) keeps the ones on the
-- screen.
function Plan.takeOrder(steps, shown)
    local order, seen = {}, {}
    for _, step in ipairs(steps) do
        if not seen[step.id] and (shown == nil or shown[step.id]) then
            seen[step.id] = true
            order[#order + 1] = step.id
        end
    end
    return order
end

-- Milliseconds between two nodes of a scan of n nodes.
function Plan.takeStep(n)
    if n <= 0 then return Plan.TAKE_STEP_MS end
    return math.min(Plan.TAKE_STEP_MS, math.floor(Plan.TAKE_MAX_MS / n))
end

-- How many nodes of a scan of n have been taken at `t` ms.
function Plan.takeLit(n, t)
    if n <= 0 or t < 0 then return 0 end
    return math.min(n, math.floor(t / Plan.takeStep(n)) + 1)
end

-- A node's size `age` ms after it was taken, as a share of its own.
function Plan.takePop(age)
    if age < 0 or age >= Plan.TAKE_POP_MS then return 1 end
    return 1 + Plan.TAKE_POP * math.sin(math.pi * easeOut(age / Plan.TAKE_POP_MS))
end

-- A node's burst `age` ms after it was taken: the glow's size (a share of the node's), its strength, and the core
-- flash's strength; nil once it is over.
function Plan.takeBurst(age)
    if age < 0 or age >= Plan.TAKE_BURST_MS then return nil end
    local u = age / Plan.TAKE_BURST_MS
    local size = Plan.TAKE_BURST_FROM + (Plan.TAKE_BURST_TO - Plan.TAKE_BURST_FROM) * easeOut(u)
    local core = 0
    if age < Plan.TAKE_CORE_MS then
        local v = 1 - age / Plan.TAKE_CORE_MS
        core = v * v
    end
    return size, (1 - u) ^ 1.6, core
end

-- The flash of a node's new pips `age` ms after it was taken (1 at once, fading), nil once it is over.
function Plan.takePip(age)
    if age < 0 or age >= Plan.TAKE_PIP_MS then return nil end
    local v = 1 - age / Plan.TAKE_PIP_MS
    return v * v
end

-- The light running up from a node `age` ms after it was taken, on a way `len` design units long: how far its head
-- is from the node (past the way's end while its tail drains), its strength; nil before and once its tail is out.
function Plan.takeRun(age, len)
    if age < 0 then return nil end
    local head = age * Plan.TAKE_SPEED / 1000
    if head >= len + Plan.TAKE_TAIL then return nil end
    local a = 1
    if head > len then a = 1 - (head - len) / Plan.TAKE_TAIL end
    return head, a
end

-- Milliseconds the light takes up a way `len` design units long (its head at the header's end).
function Plan.takeArrive(len)
    return len * 1000 / Plan.TAKE_SPEED
end

-- A header's flash `age` ms after a light arrived: quick to come, slower to go; 0 outside it.
function Plan.takeHeader(age)
    if age < 0 or age >= Plan.TAKE_HEADER_MS then return 0 end
    local rise = math.min(1, age / 60)
    local v = 1 - age / Plan.TAKE_HEADER_MS
    return rise * v * v
end

-- When the columns glow for a scan of n nodes whose last light arrives at `arrive` ms, and when the whole is over.
function Plan.takeGlowAt(n, arrive)
    return math.max(math.max(0, n - 1) * Plan.takeStep(n) + Plan.TAKE_GLOW_WAIT_MS, arrive or 0)
end

function Plan.takeEnd(n, arrive)
    local last = math.max(0, n - 1) * Plan.takeStep(n)
    return math.max(Plan.takeGlowAt(n, arrive) + Plan.TAKE_GLOW_MS, (arrive or 0) + Plan.TAKE_HEADER_MS,
        last + Plan.TAKE_BURST_MS, last + Plan.TAKE_PIP_MS)
end

-- The columns' light `age` ms after it started: how far round the frame it has run (0 at the top's middle, 1 where
-- the two ways meet at the bottom), the strength of the frame it lit, and of the column's soft light (0 to 1); nil
-- outside it.
function Plan.takeGlow(age)
    if age < 0 or age >= Plan.TAKE_GLOW_MS then return nil end
    local u, trace = age / Plan.TAKE_GLOW_MS, Plan.TAKE_TRACE
    local p = math.min(1, u / trace)
    local along = 1 - (1 - p) * (1 - p)
    local line = 1
    if u > trace then
        local q = (u - trace) / (1 - trace)
        line = 1 - q * q * (3 - 2 * q)
    end
    return along, line, line * p * p * (3 - 2 * p)
end

return Plan
