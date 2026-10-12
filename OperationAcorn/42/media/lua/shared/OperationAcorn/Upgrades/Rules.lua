-- The rules of the upgrade trees, pure: they work on the "upgrades" section of a player's record (a plain table) and
-- touch nothing else, so the unit tests can run all of them. What the points are, how a node opens, what a capstone
-- or the 2nd board costs, what a reset gives back, how long a cure serum keeps, and the numbers a node's ranks give.
--
-- The section u:
--   injected[tree]  serums of the tree injected (each is a point in that tree), sharedInjected for shared serums
--   opened[tree]    the tree has been opened by its first serum
--   bought[tree]    serums bought in the tree: only grows, the price follows it. spend[tree]: credits paid for them
--   ranks[id]       the rank of each tree node (the capstone's is 1 once approved)
--   unsealed[tree]  the tree's capstone may be taken: its meteorite fragment reached the research team. Kept for good
--                   (a reset leaves it)
--   own[tree], sharedUsed[tree]   points spent in the tree, from its own serums and from shared ones
--   board           the 2nd board: ranks[id], family[letter] (the family weight's choices), total (points that
--                   went into the board, ever), spent (points in ranks now), fromTree[tree], fromShared (where the
--                   board's points came from, so the pools stay right when the board closes and gives them back
--                   as "points left")
--   biteAt          the world age hour the bite shield last saved a bite
--   adapt           doses injected and not yet adapted to: { endsAt = world age hour, doses = { [tree or "shared"] = n } },
--                   gone when the adaptation ends and the points come (nil when there is none)
--   firstEffect     [id] = true for each node that has told its first effect (once each)
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Upgrades/Data"
local OA = OperationAcorn
OA.Upgrades = OA.Upgrades or {}
local Data = OA.Upgrades.Data
local Rules = {}
OA.Upgrades.Rules = Rules

-- A reduction effect never reaches a full cut.
Rules.MAX_CUT = 0.95

local function perTree(value)
    local t = {}
    for _, tree in ipairs(Data.TREES) do t[tree] = value end
    return t
end

local function fillTree(t, value)
    for _, tree in ipairs(Data.TREES) do
        if type(t[tree]) ~= "number" then t[tree] = value end
    end
end

-- A fresh section.
function Rules.blank()
    return Rules.fill({})
end

-- Makes sure every field exists (a new record, or one saved before a field was added). Returns u.
function Rules.fill(u)
    u.v = u.v or 1
    u.opened = u.opened or {}
    u.injected = u.injected or perTree(0)
    fillTree(u.injected, 0)
    u.sharedInjected = u.sharedInjected or 0
    u.bought = u.bought or perTree(0)
    fillTree(u.bought, 0)
    u.spend = u.spend or perTree(0)
    fillTree(u.spend, 0)
    u.ranks = u.ranks or {}
    u.own = u.own or perTree(0)
    fillTree(u.own, 0)
    u.sharedUsed = u.sharedUsed or perTree(0)
    fillTree(u.sharedUsed, 0)
    u.firstEffect = u.firstEffect or {}
    if not u.unsealed then
        -- a record from before the capstones were opened by sending a fragment: a capstone it took paid one then
        u.unsealed = {}
        for _, tree in ipairs(Data.TREES) do
            local cap = Data.capstone(tree)
            if cap and (u.ranks[cap.id] or 0) >= 1 then u.unsealed[tree] = true end
        end
    end
    if type(u.adapt) ~= "table" or type(u.adapt.doses) ~= "table" then u.adapt = nil end
    local b = u.board
    if not b then
        b = {}
        u.board = b
    end
    b.ranks = b.ranks or {}
    b.family = b.family or {}
    b.total = b.total or 0
    b.spent = b.spent or 0
    b.fromTree = b.fromTree or perTree(0)
    fillTree(b.fromTree, 0)
    b.fromShared = b.fromShared or 0
    -- the delay drug's window of the first version: the drug is kept in the infection section now (Infection.lua)
    u.delayStart, u.delayUntil = nil, nil
    return u
end

-- The section of a player's record, filled.
function Rules.section(record)
    return Rules.fill(OA.Store.section(record, "upgrades"))
end

-- A deep copy of a plain table.
function Rules.copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = Rules.copy(v) end
    return c
end

-- Replaces what u holds with a copy's content (u stays the same table, as the record keeps it).
function Rules.assign(u, copy)
    for k in pairs(u) do u[k] = nil end
    for k, v in pairs(copy) do u[k] = v end
    return u
end

-- The effect size option (UpgradeEffectMultiplier): every numeric effect scales with it.
function Rules.mult()
    return OA.option("UpgradeEffectMultiplier") or 1
end

-- ---- points ---------------------------------------------------------------------------------------------------

function Rules.ownPool(u, tree)
    return u.injected[tree] - u.own[tree] - u.board.fromTree[tree]
end

function Rules.sharedPool(u)
    local used = u.board.fromShared
    for _, tree in ipairs(Data.TREES) do used = used + u.sharedUsed[tree] end
    return u.sharedInjected - used
end

-- The points the 2nd board has given back (or not yet spent): usable on the board only.
function Rules.boardLeft(u)
    return u.board.total - u.board.spent
end

-- Points spent in a tree: what its rows' unlocks count.
function Rules.treeSpent(u, tree)
    return u.own[tree] + u.sharedUsed[tree]
end

-- The ranks a tree still has to take (its capstone with them): what more of its points it can use.
function Rules.treeRoom(u, tree)
    local n = 0
    for _, node in ipairs(Data.treeNodes(tree)) do n = n + node.ranks - Rules.rank(u, node.id) end
    return math.max(0, n)
end

-- A tree's own points split into what the tree can still take and the rest, which only the 2nd board can use.
function Rules.ownSplit(u, tree)
    local pool = Rules.ownPool(u, tree)
    local usable = math.min(pool, Rules.treeRoom(u, tree))
    return usable, pool - usable
end

-- Points a plan could spend in a tree now: the tree's own and the shared.
function Rules.free(u, tree)
    return Rules.ownPool(u, tree) + Rules.sharedPool(u)
end

-- Points a plan could spend on the 2nd board now: what it has left, every tree's leftover, the shared.
function Rules.boardFree(u)
    local n = Rules.boardLeft(u) + Rules.sharedPool(u)
    for _, tree in ipairs(Data.TREES) do n = n + Rules.ownPool(u, tree) end
    return n
end

-- ---- ranks and openings ---------------------------------------------------------------------------------------

function Rules.rank(u, id)
    local node = Data.byId[id]
    if not node then return 0 end
    if node.board then return u.board.ranks[id] or 0 end
    return u.ranks[id] or 0
end

function Rules.treeOpen(u, tree)
    return u.opened[tree] == true
end

-- Every capstone approved: the 2nd board is open.
function Rules.boardOpen(u)
    for _, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        if not cap or Rules.rank(u, cap.id) < 1 then return false end
    end
    return true
end

-- How many capstones are approved (the board shows one outline more for each).
function Rules.capstones(u)
    local n = 0
    for _, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        if cap and Rules.rank(u, cap.id) >= 1 then n = n + 1 end
    end
    return n
end

-- The points a tree needs spent in it before a row opens (row 1 is always open; row 5 is the capstone).
function Rules.rowNeed(row)
    if row >= Data.ROWS then return Data.CAPSTONE_COST end
    return Data.ROW_COST[row] or 0
end

function Rules.rowOpen(u, tree, row)
    return Rules.treeSpent(u, tree) >= Rules.rowNeed(row)
end

-- What the next rank of a node costs in points: 1 in a tree, ceil(k / 5) for the k-th rank on the 2nd board.
function Rules.cost(u, id)
    local node = Data.byId[id]
    if not node then return nil end
    if node.board then
        return math.ceil((Rules.rank(u, id) + 1) / Data.BOARD_STEP)
    end
    return 1
end

function Rules.maxed(u, id)
    local node = Data.byId[id]
    if not node or node.board then return false end
    return Rules.rank(u, id) >= node.ranks
end

-- Whether a tree's capstone is open to take (its fragment reached the research team).
function Rules.unsealed(u, tree)
    return u.unsealed[tree] == true
end

-- A fragment of a tree reached the research team: its capstone opens for good. True when it opened now.
function Rules.unseal(u, tree)
    if not tree or u.unsealed[tree] then return false end
    u.unsealed[tree] = true
    return true
end

-- Why a node cannot take its next rank, or nil when it can: "unknown", "treeClosed", "boardClosed", "maxed",
-- "row" (not enough points spent in the tree), "prereq", "points", "sealed" (a capstone whose fragment has not reached
-- the research team), "choice".
function Rules.blocked(u, id, choice)
    local node = Data.byId[id]
    if not node then return "unknown" end
    if node.board then
        if not Rules.boardOpen(u) then return "boardClosed" end
        if node.choose and not Data.FAMILIES[choice] then return "choice" end
        if Rules.boardFree(u) < Rules.cost(u, id) then return "points" end
        return nil
    end
    if not Rules.treeOpen(u, node.tree) then return "treeClosed" end
    if Rules.maxed(u, id) then return "maxed" end
    if not Rules.rowOpen(u, node.tree, node.row) then return "row" end
    for _, need in ipairs(node.req) do
        if Rules.rank(u, need[1]) < need[2] then return "prereq" end
    end
    if node.capstone and not Rules.unsealed(u, node.tree) then return "sealed" end
    if Rules.free(u, node.tree) < 1 then return "points" end
    return nil
end

-- Takes the next rank of a node, paying its points. Returns true, or false and the reason (as blocked).
function Rules.buy(u, id, choice)
    local why = Rules.blocked(u, id, choice)
    if why then return false, why end
    local node = Data.byId[id]
    if node.board then
        local cost = Rules.cost(u, id)
        local b = u.board
        local fromLeft = math.min(Rules.boardLeft(u), cost)
        local need = cost - fromLeft
        local rest = need
        for _, tree in ipairs(Data.TREES) do
            local take = math.min(rest, Rules.ownPool(u, tree))
            b.fromTree[tree] = b.fromTree[tree] + take
            rest = rest - take
        end
        if rest > 0 then b.fromShared = b.fromShared + rest end
        b.total = b.total + need
        b.spent = b.spent + cost
        b.ranks[id] = (b.ranks[id] or 0) + 1
        if node.choose then b.family[choice] = (b.family[choice] or 0) + 1 end
        return true
    end
    if Rules.ownPool(u, node.tree) >= 1 then
        u.own[node.tree] = u.own[node.tree] + 1
    else
        u.sharedUsed[node.tree] = u.sharedUsed[node.tree] + 1
    end
    u.ranks[id] = (u.ranks[id] or 0) + 1
    return true
end

-- Applies a plan, a list of steps { id = ..., choice = ... } each taking one rank, in order (a later step may need an
-- earlier one). All or nothing: returns true and a new section; or false, the reason, the step's number. u itself is
-- not touched.
function Rules.approve(u, steps)
    local copy = Rules.copy(u)
    for i, step in ipairs(steps) do
        local ok, why = Rules.buy(copy, step.id, step.choice)
        if not ok then return false, why, i end
    end
    return true, copy
end

-- ---- serums ---------------------------------------------------------------------------------------------------

-- An upgrade serum of a tree injected: the tree opens with the first, every one is a point. Returns true when this
-- one opened the tree.
function Rules.inject(u, tree)
    local first = not u.opened[tree]
    u.opened[tree] = true
    u.injected[tree] = u.injected[tree] + 1
    return first
end

function Rules.injectShared(u)
    u.sharedInjected = u.sharedInjected + 1
end

local function round100(x)
    return math.floor(x / 100 + 0.5) * 100
end

-- The price of the n-th serum bought in a tree (NUMBERS 6): 8,000 * 1.15^(n-1) to 100; past the 26th, a straight
-- line up by 30,000 a serum (scaled with the base price option). The shop (economy package) sells the serums, so
-- its price is the one asked when it is there; the same formula stands in for it when it is not (tests).
function Rules.serumPrice(n)
    if OA.Shop and OA.Shop.serumPriceAt then return OA.Shop.serumPriceAt(n) end
    local base = OA.scaled(8000, "UpgradeSerumPriceMultiplier")
    local growth = 1 + OA.scaled(0.15, "UpgradeSerumGrowthMultiplier")
    local function grown(k) return round100(base * growth ^ (k - 1)) end
    if n <= 26 then return grown(n) end
    return grown(26) + round100(30000 * base / 8000) * (n - 26)
end

-- What n serums cost together at the base price.
function Rules.serumTotal(n)
    local sum = 0
    for k = 1, n do sum = sum + Rules.serumPrice(k) end
    return sum
end

-- Serums were bought in a tree (count of them, for the credits paid when known). The count only grows.
function Rules.noteBought(u, tree, count, paid)
    count = count or 1
    local before = u.bought[tree]
    u.bought[tree] = before + count
    if paid == nil then
        paid = Rules.serumTotal(before + count) - Rules.serumTotal(before)
    end
    u.spend[tree] = u.spend[tree] + paid
end

-- ---- adaptation -----------------------------------------------------------------------------------------------

-- Hours a dose adapts for: Data.ADAPT_HOURS, a half of it with 혈청 적응 and a quarter at its second rank.
function Rules.adaptHours(u)
    local r = Rules.rank(u, "serumAdapt")
    if r >= 2 then return Data.ADAPT_HOURS / 4 end
    if r == 1 then return Data.ADAPT_HOURS / 2 end
    return Data.ADAPT_HOURS
end

-- A dose of an upgrade serum of a tree (or "shared") is taken at world age hour `now`: it adapts for Rules.adaptHours,
-- and doses taken meanwhile share the time (the end is the latest dose's, not a sum). The point comes at the end
-- (finishAdapt).
function Rules.startAdapt(u, key, now)
    local a = u.adapt
    if not a then
        a = { endsAt = 0, doses = {} }
        u.adapt = a
    end
    a.doses[key] = (a.doses[key] or 0) + 1
    a.endsAt = math.max(a.endsAt or 0, now + Rules.adaptHours(u))
end

-- The level of the moodle 적응 중 for the time left (hours): 4 above 20 game minutes, 3 above 10, 2 above 5, 1 within
-- the last 5 (its text says about how long is left); 0 when nothing adapts.
function Rules.adaptLevel(u, now)
    local left = Rules.adaptLeft(u, now)
    if not left then return 0 end
    local minutes = left * 60
    if minutes > 20 then return 4 end
    if minutes > 10 then return 3 end
    if minutes > 5 then return 2 end
    return 1
end

-- Hours of adaptation left at `now` (0 when it is over), or nil when no dose is adapting.
function Rules.adaptLeft(u, now)
    if not u.adapt then return nil end
    return math.max(0, (u.adapt.endsAt or 0) - now)
end

function Rules.adaptDone(u, now)
    return u.adapt ~= nil and now >= (u.adapt.endsAt or 0)
end

-- The adaptation is over: every dose becomes its point (the first of a tree opens it). Returns { trees = { [tree] = n },
-- shared = n, opened = { tree... } } in the trees' order, or nil when there was no adaptation.
function Rules.finishAdapt(u)
    local a = u.adapt
    if not a then return nil end
    local result = { trees = {}, shared = 0, opened = {} }
    for _, tree in ipairs(Data.TREES) do
        local n = a.doses[tree] or 0
        for _ = 1, n do
            if Rules.inject(u, tree) then result.opened[#result.opened + 1] = tree end
        end
        if n > 0 then result.trees[tree] = n end
    end
    for _ = 1, a.doses.shared or 0 do Rules.injectShared(u) end
    result.shared = a.doses.shared or 0
    u.adapt = nil
    return result
end

-- ---- first effects --------------------------------------------------------------------------------------------

-- A node of Data.FIRST_EFFECT has just had its effect in the game. True the first time only (with a rank taken, and
-- noted for good in u.firstEffect).
function Rules.firstEffect(u, id)
    local listed = false
    for _, one in ipairs(Data.FIRST_EFFECT) do
        if one == id then listed = true end
    end
    if not listed or Rules.rank(u, id) < 1 or u.firstEffect[id] then return false end
    u.firstEffect[id] = true
    return true
end

-- ---- reset ----------------------------------------------------------------------------------------------------

-- What the tree's serums cost (as paid, or at the base price when the purchases were not noted with a price).
function Rules.treeSpend(u, tree)
    local spend = u.spend[tree]
    if spend <= 0 then spend = Rules.serumTotal(u.bought[tree]) end
    return spend
end

-- The credits a reset of the tree costs: 10% of what its serums cost, to 100.
function Rules.resetCost(u, tree)
    return round100(Rules.treeSpend(u, tree) * Data.RESET_SHARE)
end

-- Why a tree cannot be reset with so many credits, or nil: "unknown", "nothing" (nothing was spent), "debt"
-- (credits below zero), "credits" (not enough). Second result: the cost.
function Rules.resetBlocked(u, tree, credits)
    local valid = false
    for _, t in ipairs(Data.TREES) do if t == tree then valid = true end end
    if not valid then return "unknown" end
    local cost = Rules.resetCost(u, tree)
    local spent = Rules.treeSpent(u, tree)
    if spent <= 0 then return "nothing", cost end
    if credits < 0 then return "debt", cost end
    if credits < cost then return "credits", cost end
    return nil, cost
end

-- Resets a tree: every point in it comes back (shared ones as shared points), its ranks go, and the 2nd board
-- closes with its spent points returned as the board's own "points left". The serum count does not come back, and the
-- tree stays unsealed. Returns true and the credits it costs (the caller takes them), or false and the reason.
function Rules.reset(u, tree, credits)
    local why, cost = Rules.resetBlocked(u, tree, credits)
    if why then return false, why end
    for _, node in ipairs(Data.treeNodes(tree)) do u.ranks[node.id] = nil end
    u.own[tree] = 0
    u.sharedUsed[tree] = 0
    -- The capstone is gone, so the board closed: its ranks go and what they cost is left to spend again.
    u.board.ranks = {}
    u.board.family = {}
    u.board.spent = 0
    return true, cost
end

-- ---- cure serum -----------------------------------------------------------------------------------------------

-- Whether a cure serum works for this character now: owner is the record id on the serum (OA_Owner), issued the world
-- age hour it was issued (OA_Issued), shelfDays the shelf life option. Returns "ok" and the days left, "expired" or
-- "notOwner". A serum with no issue time never expires; with no owner anyone may use it.
function Rules.cureStatus(issued, owner, myId, now, shelfDays)
    if owner ~= nil and myId ~= nil and owner ~= myId then return "notOwner", nil end
    if issued == nil then return "ok", shelfDays end
    local left = shelfDays - (now - issued) / 24
    if left <= 0 then return "expired", 0 end
    return "ok", left
end

-- ---- numbers --------------------------------------------------------------------------------------------------

-- 1 / (1 + sum): a reduction sum divides a value, never reaching zero.
function Rules.divide(sum)
    return 1 / (1 + sum)
end

-- limit * sum / (1 + sum): grows with the sum and never passes the limit.
function Rules.approach(limit, sum)
    return limit * sum / (1 + sum)
end

local function clampCut(x)
    if x < 0 then return 0 end
    if x > Rules.MAX_CUT then return Rules.MAX_CUT end
    return x
end

-- The value of a tree node's current rank in its unit (scaled by the effect option), or 0.
function Rules.value(u, id)
    local node = Data.byId[id]
    local r = Rules.rank(u, id)
    if not node or r < 1 or not node.values then return 0 end
    return node.values[r] * Rules.mult()
end

-- A percent value as a fraction.
function Rules.fraction(u, id)
    return Rules.value(u, id) / 100
end

-- A percent value as a cut of a penalty, kept below a full cut.
function Rules.cut(u, id)
    return clampCut(Rules.value(u, id) / 100)
end

-- A percent value as a cut that may reach a full cut (the bush slowdown goes to nothing).
function Rules.cutFull(u, id)
    return OA.clamp(Rules.value(u, id) / 100, 0, 1)
end

-- The 2nd board node's amount, by its form: the reduction sum (divide), the added amount (add) or the bonus
-- (approach). 0 with no ranks.
function Rules.boardAmount(u, id)
    local node = Data.byId[id]
    local r = Rules.rank(u, id)
    if not node or not node.board or r < 1 then return 0 end
    local m = Rules.mult()
    if node.form == "approach" then
        return Rules.approach(node.limit * m, node.step * r)
    end
    return node.step * r * m
end

-- The family weight node's amount for one family (+10% a point it was chosen for).
function Rules.familyAmount(u, family)
    local node = Data.byId["bFamily"]
    local n = u.board.family[family] or 0
    if n < 1 or Rules.rank(u, "bFamily") < 1 then return 0 end
    return node.step * n * Rules.mult()
end

-- Sample bundles a shred adds on top (눈썰미 and the board's bundle node), as an expected count.
function Rules.bundleBonus(u)
    return Rules.value(u, "keen") + Rules.boardAmount(u, "bBundle")
end

-- The distance 육감 watches, in tiles (0 without the node).
function Rules.sixthRadius(u)
    if Rules.rank(u, "sixth") < 1 then return 0 end
    return Rules.value(u, "sixth") + Rules.boardAmount(u, "bSixth")
end

-- The distance 기척 감지 watches, in tiles (0 without the node).
function Rules.senseRadius(u)
    if Rules.rank(u, "sense") < 1 then return 0 end
    return Data.SENSE_RADIUS * Rules.mult() + Rules.boardAmount(u, "bSense")
end

-- Hours between two bites the shield saves you from.
function Rules.biteHours(u)
    return Data.BITE_DAYS * 24 * Rules.divide(Rules.boardAmount(u, "bBite"))
end

-- Whether the bite shield is armed now: the node at rank 2 and the wait since the last save over.
function Rules.biteReady(u, now)
    if Rules.rank(u, "resistPlus") < 2 then return false end
    if u.biteAt == nil then return true end
    return now - u.biteAt >= Rules.biteHours(u)
end

-- Hours left until the shield is armed again (0 when it is).
function Rules.biteWait(u, now)
    if u.biteAt == nil then return 0 end
    return math.max(0, Rules.biteHours(u) - (now - u.biteAt))
end

-- The bite shield's moodle level while it rests (0 when it is armed or not had): 4 with more than three quarters of
-- the rest ahead, then 3, 2, and 1 in its last quarter.
function Rules.biteLevel(u, now)
    if Rules.rank(u, "resistPlus") < 2 then return 0 end
    local wait = Rules.biteWait(u, now)
    if wait <= 0 then return 0 end
    local share = wait / Rules.biteHours(u)
    if share > 0.75 then return 4 end
    if share > 0.5 then return 3 end
    if share > 0.25 then return 2 end
    return 1
end

-- The share of the time an item transfer takes that is left after the transfer node and the board's (a multiplier).
function Rules.transferTime(u)
    local time = 1 - Rules.cut(u, "moveSpeed")
    return time * Rules.divide(Rules.boardAmount(u, "bTransfer"))
end

-- Moving an item takes the time of its weight up to 3 (vanilla). With a carry efficiency the weight is divided by
-- (1 + efficiency), so the time shrinks by this factor once the weight comes under 3.
function Rules.weightRatio(weight, efficiency)
    local before = math.min(weight, 3)
    if before <= 0 or efficiency <= 0 then return 1 end
    return math.min(weight / (1 + efficiency), 3) / before
end

-- Endurance a breakthrough sprint costs per zombie, before skill, after the board's reduction (a multiplier).
function Rules.dashCost(u)
    return Rules.divide(Rules.boardAmount(u, "bDash"))
end

-- The chance a pry bar opens a lock, a lock pick opens one (fractions), and how long the pick takes (a multiplier).
function Rules.crowbarChance(u)
    return OA.clamp(Rules.fraction(u, "crowbar"), 0, 1)
end

function Rules.lockChance(u)
    return OA.clamp(Rules.fraction(u, "lock"), 0, 1)
end

function Rules.lockTime(u)
    if Rules.rank(u, "lock") >= 2 then return 0.5 end
    return 1
end

-- The share of serum side effects that remain: 1, one half, none (혈청 적응).
function Rules.sideEffects(u)
    local r = Rules.rank(u, "serumAdapt")
    if r >= 2 then return 0 end
    if r == 1 then return 0.5 end
    return 1
end

return Rules
