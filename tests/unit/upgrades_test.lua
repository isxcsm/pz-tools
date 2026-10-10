-- The upgrade rules: data shape, points, row and prerequisite unlocks, capstones and fragments, the 2nd board's costs,
-- the diminishing formulas, reset, serum prices, the cure serum's shelf life and owner, the values
-- the effects hand to the API, and the server's commands.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Api"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Effects = OA.Upgrades.Effects

local function fresh()
    return Rules.blank()
end

-- Injects n serums of a tree.
local function inject(u, tree, n)
    for _ = 1, n do Rules.inject(u, tree) end
end

-- Buys the nodes by ids in order, one rank each time a name appears; fails the test on a refusal.
local function buy(u, ids, ctx)
    ctx = ctx or { fragments = 0 }
    for _, id in ipairs(ids) do
        local ok, why = Rules.buy(u, id, ctx)
        if not ok then error("could not buy " .. id .. ": " .. tostring(why), 2) end
    end
end

local function rep(id, n)
    local list = {}
    for _ = 1, n do list[#list + 1] = id end
    return list
end

local function cat(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, v in ipairs(list) do out[#out + 1] = v end
    end
    return out
end

-- Every node of a tree in an order that satisfies every rule (25 points).
local ORDER = {
    scout = cat(rep("sight", 3), rep("sixth", 2), rep("alarm", 1), rep("night", 3), rep("rich", 3), rep("ledger", 3),
        rep("sense", 2), rep("keen", 3), rep("ammo", 2), rep("sensePlus", 3)),
    load = cat(rep("overload", 2), rep("moveSpeed", 3), rep("keyring", 1), rep("runSpeed", 2), rep("materials", 3),
        rep("furniture", 2), rep("capacity", 5), rep("combatSpeed", 2), rep("materialsPlus", 2), rep("storage", 3)),
    survival = cat(rep("serumAdapt", 2), rep("crowbar", 2), rep("stiff", 3), rep("fall", 3), rep("lock", 2),
        rep("brush", 2), rep("gear", 3), rep("resist", 3), rep("walk", 3), rep("resistPlus", 2)),
}

local function maxTree(u, tree, withCapstone)
    inject(u, tree, 25 + (withCapstone and 1 or 0))
    buy(u, ORDER[tree])
    if withCapstone then
        buy(u, { Data.capstone(tree).id }, { fragments = 1 })
    end
end

local function openBoard(u)
    maxTree(u, "scout", true)
    maxTree(u, "load", true)
    maxTree(u, "survival", true)
end

test("every tree has ten nodes, 25 points and a capstone", function()
    for _, tree in ipairs(Data.TREES) do
        local points, count, caps = 0, 0, 0
        for _, n in ipairs(Data.treeNodes(tree)) do
            if n.capstone then
                caps = caps + 1
                eq(n.ranks, 1, n.id)
            else
                count = count + 1
                points = points + n.ranks
            end
        end
        eq(count, 10, tree .. " nodes")
        eq(points, 25, tree .. " points")
        eq(caps, 1, tree .. " capstone")
    end
end)

test("data is consistent: prerequisites, values, places, api map", function()
    local seen = {}
    for _, n in ipairs(Data.nodes) do
        truthy(not seen[n.id], "duplicate " .. n.id)
        seen[n.id] = true
        truthy(n.kind == "lua" or n.kind == "api", n.id .. " kind")
        truthy(n.icon, n.id .. " icon")
        truthy(n.iconGray, n.id .. " grey icon")
        if not n.board then
            truthy(n.row >= 1 and n.row <= Data.ROWS and n.col >= 1 and n.col <= Data.COLS, n.id .. " place")
            if n.capstone then eq(n.row, 5, n.id) end
            if n.values then eq(#n.values, n.ranks, n.id .. " values") end
            if n.values2 then eq(#n.values2, n.ranks, n.id .. " values2") end
            for _, need in ipairs(n.req) do
                local other = Data.byId[need[1]]
                truthy(other and other.tree == n.tree, n.id .. " needs a node of its own tree")
                truthy(need[2] >= 1 and need[2] <= other.ranks, n.id .. " needs a real rank")
                truthy(other.row < n.row, n.id .. " needs a node above it")
            end
        end
        if n.kind == "api" then truthy(Effects.MAP[n.id], n.id .. " has no api points") end
    end
    for id in pairs(Effects.MAP) do truthy(Data.byId[id], "map names an unknown node " .. id) end
    eq(#Data.boardGroup("load") + #Data.boardGroup("survival") + #Data.boardGroup("scout"), 23)
    local places = {}
    for _, n in ipairs(Data.nodes) do
        if not n.board then
            local key = n.tree .. n.row .. "," .. n.col
            truthy(not places[key], "two nodes at " .. key)
            places[key] = true
        end
    end
end)

test("every prerequisite line runs around the other nodes", function()
    require "OperationAcorn/Upgrades/Links"
    local Links = OA.Upgrades.Links
    local kinds = {}
    for _, tree in ipairs(Data.TREES) do
        local cells = Links.cells(tree)
        for _, link in ipairs(Links.tree(tree)) do
            local from, to = Data.byId[link.from], Data.byId[link.to]
            kinds[link.to] = link.kind
            -- the column a vertical part runs down: no node on the rows it passes
            local function clearDown(c)
                for r = from.row + 1, to.row - 1 do
                    if cells[r .. "," .. c] then return false end
                end
                return true
            end
            if link.kind == "straight" then
                eq(from.col, to.col, link.to)
                truthy(clearDown(to.col), link.to .. " straight through a node")
            elseif link.kind == "elbow" then
                truthy(clearDown(to.col), link.to .. " elbow through a node")
            else
                eq(link.kind, "gutter", link.to)
                local g = link.points[3].c
                truthy(g >= 0 and g <= Data.COLS, link.to .. " gutter inside the grid")
            end
            eq(link.points[1].y, "bottom", link.to)
            eq(link.points[#link.points].y, "top", link.to)
        end
    end
    -- the trees are laid out so that every line is straight, and each capstone stands in the middle (column 2)
    for id, kind in pairs(kinds) do eq(kind, "straight", id) end
    for _, tree in ipairs(Data.TREES) do eq(Data.capstone(tree).col, 2, tree) end
    -- the router itself, on cells made up for it: around a node in the way, and to another column
    eq((Links.route({}, 1, 1, 2, 3)), "elbow")
    eq((Links.route({ ["2,1"] = "x" }, 1, 1, 1, 3)), "gutter")
    eq((Links.route({ ["2,2"] = "x" }, 1, 1, 2, 3)), "gutter")
end)

test("a tree opens with its first serum; each serum is a point of that tree", function()
    local u = fresh()
    truthy(not Rules.treeOpen(u, "scout"))
    eq(Rules.blocked(u, "sight", nil), "treeClosed")
    eq(Rules.inject(u, "scout"), true, "first opens it")
    eq(Rules.inject(u, "scout"), false)
    eq(Rules.ownPool(u, "scout"), 2)
    eq(Rules.ownPool(u, "load"), 0)
    eq(Rules.blocked(u, "overload", nil), "treeClosed", "other trees stay closed")
    buy(u, { "sight" })
    eq(Rules.rank(u, "sight"), 1)
    eq(Rules.ownPool(u, "scout"), 1)
    eq(Rules.treeSpent(u, "scout"), 1)
end)

test("a tree's own points beyond what it can still take are counted apart, for the 2nd board", function()
    local u = fresh()
    inject(u, "scout", 30)
    eq(Rules.treeRoom(u, "scout"), 26, "25 points and the capstone")
    eq(select(1, Rules.ownSplit(u, "scout")), 26)
    eq(select(2, Rules.ownSplit(u, "scout")), 4)
    buy(u, ORDER.scout)
    eq(Rules.treeRoom(u, "scout"), 1)
    eq(select(1, Rules.ownSplit(u, "scout")), 1)
    eq(select(2, Rules.ownSplit(u, "scout")), 4)
    inject(u, "load", 2)
    eq(select(1, Rules.ownSplit(u, "load")), 2)
    eq(select(2, Rules.ownSplit(u, "load")), 0)
end)

test("shared points go into any opened tree, after the tree's own", function()
    local u = fresh()
    inject(u, "load", 1)
    Rules.injectShared(u)
    Rules.injectShared(u)
    eq(Rules.free(u, "load"), 3)
    eq(Rules.blocked(u, "sight", nil), "treeClosed", "a shared point does not open a tree")
    buy(u, { "overload", "overload" })
    eq(u.own.load, 1)
    eq(u.sharedUsed.load, 1, "the second point came from the shared ones")
    eq(Rules.sharedPool(u), 1)
    eq(Rules.treeSpent(u, "load"), 2)
end)

test("rows open by the points spent in the tree: 3, 6, 9", function()
    local u = fresh()
    inject(u, "scout", 12)
    eq(Rules.blocked(u, "rich", nil), "row")
    buy(u, rep("sight", 3))
    eq(Rules.blocked(u, "rich", nil), nil)
    buy(u, rep("sixth", 2))
    eq(Rules.treeSpent(u, "scout"), 5)
    eq(Rules.blocked(u, "sense", nil), "row")
    buy(u, { "alarm" })
    eq(Rules.blocked(u, "sense", nil), nil)
    buy(u, rep("sense", 2))
    eq(Rules.treeSpent(u, "scout"), 8)
    eq(Rules.blocked(u, "sensePlus", nil), "row")
    buy(u, { "ledger" })
    eq(Rules.blocked(u, "sensePlus", nil), nil)
end)

test("prerequisites need the named rank", function()
    local u = fresh()
    inject(u, "scout", 12)
    buy(u, cat(rep("sight", 3), rep("alarm", 1), rep("rich", 1), rep("ledger", 1)))
    eq(Rules.treeSpent(u, "scout"), 6)
    eq(Rules.blocked(u, "keen", nil), "prereq", "keen needs rich 2")
    buy(u, { "rich" })
    eq(Rules.blocked(u, "keen", nil), nil)
    eq(Rules.blocked(u, "ammo", nil), "row", "ammo is row 4")
end)

test("a node cannot go past its ranks, or be bought without a point", function()
    local u = fresh()
    inject(u, "scout", 4)
    buy(u, rep("sight", 3))
    eq(Rules.blocked(u, "sight", nil), "maxed")
    buy(u, { "alarm" })
    eq(Rules.blocked(u, "sixth", nil), "points")
end)

test("a capstone needs 12 points in its tree and a fragment, which it takes", function()
    local u = fresh()
    inject(u, "scout", 26)
    buy(u, ORDER.scout)
    eq(Rules.treeSpent(u, "scout"), 25)
    eq(Rules.blocked(u, "nightEye", { fragments = 0 }), "fragment")
    local ctx = { fragments = 2 }
    buy(u, { "nightEye" }, ctx)
    eq(ctx.fragments, 1, "one fragment taken")
    eq(Rules.rank(u, "nightEye"), 1)
    -- 12 points are enough
    local v = fresh()
    inject(v, "scout", 13)
    buy(v, cat(rep("sight", 3), rep("night", 3), rep("alarm", 1), rep("sixth", 2), rep("ledger", 3)))
    eq(Rules.treeSpent(v, "scout"), 12)
    eq(Rules.blocked(v, "nightEye", { fragments = 1 }), nil)
    -- 11 are not
    local w = fresh()
    inject(w, "scout", 13)
    buy(w, cat(rep("sight", 3), rep("night", 3), rep("alarm", 1), rep("sixth", 2), rep("ledger", 2)))
    eq(Rules.treeSpent(w, "scout"), 11)
    eq(Rules.blocked(w, "nightEye", { fragments = 1 }), "row")
end)

test("the capstone needs its node at rank", function()
    local u = fresh()
    inject(u, "scout", 13)
    buy(u, cat(rep("sight", 3), rep("night", 2), rep("alarm", 1), rep("sixth", 2), rep("ledger", 3), rep("rich", 1)))
    eq(Rules.treeSpent(u, "scout"), 12)
    eq(Rules.blocked(u, "nightEye", { fragments = 1 }), "prereq")
end)

test("the 2nd board opens when all three capstones are approved", function()
    local u = fresh()
    eq(Rules.boardOpen(u), false)
    maxTree(u, "scout", true)
    eq(Rules.capstones(u), 1)
    maxTree(u, "load", true)
    eq(Rules.boardOpen(u), false)
    eq(Rules.blocked(u, "bHeavy", nil), "boardClosed")
    maxTree(u, "survival", true)
    eq(Rules.capstones(u), 3)
    eq(Rules.boardOpen(u), true)
end)

test("2nd board: the k-th rank of a node costs ceil(k/5) points", function()
    local u = fresh()
    openBoard(u)
    eq(Rules.boardFree(u), 0)
    for _ = 1, 40 do Rules.injectShared(u) end
    eq(Rules.cost(u, "bLimit"), 1)
    buy(u, rep("bLimit", 5))
    eq(Rules.boardFree(u), 35)
    eq(Rules.cost(u, "bLimit"), 2, "the 6th rank")
    buy(u, rep("bLimit", 5))
    eq(Rules.boardFree(u), 25, "ranks 6 to 10 cost 2 each")
    eq(Rules.cost(u, "bLimit"), 3, "the 11th rank")
    eq(Rules.rank(u, "bLimit"), 10)
    eq(Rules.cost(u, "bStiff"), 1, "another node starts again at 1")
    eq(u.board.fromShared, 15)
end)

test("2nd board points come from what it has left, then the trees' leftovers, then the shared ones", function()
    local u = fresh()
    openBoard(u)
    inject(u, "scout", 2)
    inject(u, "load", 1)
    Rules.injectShared(u)
    eq(Rules.boardFree(u), 4)
    buy(u, rep("bWound", 4))
    eq(Rules.boardFree(u), 0)
    eq(Rules.ownPool(u, "scout"), 0)
    eq(Rules.ownPool(u, "load"), 0)
    eq(Rules.sharedPool(u), 0)
    eq(Rules.blocked(u, "bWound", nil), "points")
end)

test("the family weight node needs a family choice and counts per family", function()
    local u = fresh()
    openBoard(u)
    for _ = 1, 3 do Rules.injectShared(u) end
    eq(Rules.blocked(u, "bFamily", nil, nil), "choice")
    eq(Rules.blocked(u, "bFamily", nil, "Z"), "choice")
    truthy(Rules.buy(u, "bFamily", nil, "A"))
    truthy(Rules.buy(u, "bFamily", nil, "A"))
    truthy(Rules.buy(u, "bFamily", nil, "G"))
    eq(u.board.family.A, 2)
    near(Rules.familyAmount(u, "A"), 0.2, 1e-9)
    near(Rules.familyAmount(u, "G"), 0.1, 1e-9)
    eq(Rules.familyAmount(u, "B"), 0)
end)

test("diminishing formulas: divide never reaches zero, approach never reaches its limit", function()
    near(Rules.divide(0.2), 1 / 1.2, 1e-9)
    near(Rules.divide(1.0), 0.5, 1e-9)
    near(Rules.divide(2.0), 1 / 3, 1e-9)
    -- the walking speed example of TREES: limit 0.4, 0.1 per point
    local function bonus(points) return Rules.approach(0.4, 0.1 * points) end
    near(bonus(1), 0.036, 0.0005)
    near(bonus(5), 0.133, 0.0005)
    near(bonus(10), 0.2, 0.0005)
    near(bonus(20), 0.267, 0.0005)
    near(bonus(50), 0.333, 0.0005)
    near(bonus(100), 0.364, 0.0005)
    truthy(bonus(100000) < 0.4)
    -- through a node on the board
    local u = fresh()
    openBoard(u)
    for _ = 1, 20 do Rules.injectShared(u) end
    for _ = 1, 10 do truthy(Rules.buy(u, "bWalk", nil)) end
    eq(Rules.rank(u, "bWalk"), 10)
    near(Rules.boardAmount(u, "bWalk"), 0.2, 1e-9)
end)

test("the effect option scales numeric values", function()
    local u = fresh()
    inject(u, "scout", 3)
    buy(u, rep("sight", 3))
    near(Rules.value(u, "sight"), 36, 1e-9)
    SandboxVars.OperationAcorn.UpgradeEffectMultiplier = 0.5
    near(Rules.value(u, "sight"), 18, 1e-9)
    near(Effects.compute(u, 0)["vision.coneAdd"], 18, 1e-9)
    SandboxVars.OperationAcorn.UpgradeEffectMultiplier = 5
    near(Rules.cut(u, "sight"), Rules.MAX_CUT, 1e-9, "cuts stay below a full cut")
end)

test("a plan is approved all or nothing, in order", function()
    local u = fresh()
    inject(u, "scout", 4)
    local ok, result = Rules.approve(u, { { id = "sight" }, { id = "sight" }, { id = "sight" }, { id = "rich" } },
        { fragments = 0 })
    truthy(ok, "the second row opens by the first three")
    eq(Rules.rank(result, "sight"), 3)
    eq(Rules.rank(u, "sight"), 0, "the original is untouched")
    local ok2, why, index = Rules.approve(u, { { id = "sight" }, { id = "rich" } }, { fragments = 0 })
    eq(ok2, false)
    eq(why, "row")
    eq(index, 2)
    local ok3, why3 = Rules.approve(u, { { id = "nope" } }, { fragments = 0 })
    eq(ok3, false)
    eq(why3, "unknown")
end)

test("approving a capstone reports the fragments it uses", function()
    local u = fresh()
    inject(u, "scout", 26)
    buy(u, ORDER.scout)
    local ok, _, used = Rules.approve(u, { { id = "nightEye" } }, { fragments = 3 })
    truthy(ok)
    eq(used, 1)
    local ok2, why = Rules.approve(u, { { id = "nightEye" } }, { fragments = 0 })
    eq(ok2, false)
    eq(why, "fragment")
end)

test("serum prices follow NUMBERS 6", function()
    eq(Rules.serumPrice(1), 8000)
    eq(Rules.serumPrice(2), 9200)
    eq(Rules.serumPrice(3), 10600)
    eq(Rules.serumPrice(5), 14000)
    eq(Rules.serumPrice(10), 28100)
    eq(Rules.serumPrice(15), 56600)
    eq(Rules.serumPrice(20), 113900)
    eq(Rules.serumPrice(25), 229000)
    eq(Rules.serumPrice(26), 263400)
    eq(Rules.serumPrice(27), 293400)
    eq(Rules.serumPrice(30), 383400)
    SandboxVars.OperationAcorn.UpgradeSerumPrice = 16000
    eq(Rules.serumPrice(1), 16000)
end)

test("reset gives every point back, costs 10% of the serums, and keeps the serum count", function()
    local u = fresh()
    inject(u, "load", 13)
    Rules.noteBought(u, "load", 13)
    buy(u, cat(rep("overload", 2), rep("moveSpeed", 3), rep("keyring", 1), rep("runSpeed", 2), rep("materials", 3)))
    eq(Rules.treeSpent(u, "load"), 11)
    local cost = Rules.resetCost(u, "load")
    eq(cost, math.floor(Rules.serumTotal(13) * 0.1 / 100 + 0.5) * 100)
    truthy(cost > 0)
    local ok, why = Rules.reset(u, "load", cost - 1)
    eq(ok, false)
    eq(why, "credits")
    ok, why = Rules.reset(u, "load", -5)
    eq(why, "debt", "debt blocks it")
    local ok2, paid = Rules.reset(u, "load", cost + 50)
    truthy(ok2)
    eq(paid, cost)
    eq(Rules.treeSpent(u, "load"), 0)
    eq(Rules.ownPool(u, "load"), 13, "all points are back")
    eq(Rules.rank(u, "overload"), 0)
    eq(u.bought.load, 13, "the serum count stays")
    eq(Rules.treeOpen(u, "load"), true, "the tree stays open")
    local _, why2 = Rules.reset(u, "load", 1e9)
    eq(why2, "nothing")
end)

test("a tree of 26 serums costs about 196,600 to reset", function()
    local u = fresh()
    Rules.noteBought(u, "scout", 26)
    inject(u, "scout", 1)
    buy(u, { "sight" })
    local cost = Rules.resetCost(u, "scout")
    truthy(cost >= 196500 and cost <= 196700, "cost " .. tostring(cost))
end)

test("reset returns shared points as shared", function()
    local u = fresh()
    inject(u, "load", 1)
    Rules.injectShared(u)
    buy(u, { "overload", "overload" })
    eq(Rules.sharedPool(u), 0)
    truthy(Rules.reset(u, "load", 1e9))
    eq(Rules.sharedPool(u), 1)
    eq(Rules.ownPool(u, "load"), 1)
end)

test("the reset price counts what was paid when known", function()
    local u = fresh()
    Rules.noteBought(u, "scout", 2, 10000)
    eq(Rules.resetCost(u, "scout"), 1000)
    eq(u.bought.scout, 2)
    Rules.noteBought(u, "scout", 1)
    eq(u.bought.scout, 3)
    eq(u.spend.scout, 10000 + Rules.serumPrice(3))
end)

test("resetting a tree with a capstone closes the 2nd board and returns its points as its own", function()
    local u = fresh()
    openBoard(u)
    for _ = 1, 7 do Rules.injectShared(u) end
    buy(u, rep("bStiff", 6))
    eq(Rules.boardLeft(u), 0)
    eq(u.board.total, 7)
    truthy(Rules.reset(u, "scout", 1e9))
    eq(Rules.boardOpen(u), false)
    eq(Rules.rank(u, "bStiff"), 0)
    eq(Rules.boardLeft(u), 7, "2nd board points left")
    eq(Rules.sharedPool(u), 0, "they are not shared points any more")
    eq(Rules.rank(u, "nightEye"), 0, "the capstone is gone")
    -- the fragment is not given back: a new capstone needs one again
    buy(u, ORDER.scout)
    eq(Rules.blocked(u, "nightEye", { fragments = 0 }), "fragment")
    buy(u, { "nightEye" }, { fragments = 1 })
    eq(Rules.boardOpen(u), true, "the board is back")
    -- the left points are spent first and need no shared ones
    buy(u, rep("bStiff", 6))
    eq(Rules.boardLeft(u), 0)
    eq(u.board.total, 7, "no new points went into the board")
end)

test("cure serum: owner and shelf life", function()
    eq((Rules.cureStatus(100, "me", "me", 100, 7)), "ok")
    local status, left = Rules.cureStatus(100, "me", "me", 100 + 24 * 3, 7)
    eq(status, "ok")
    near(left, 4, 1e-9)
    eq((Rules.cureStatus(100, "me", "me", 100 + 24 * 7, 7)), "expired", "exactly on the day it runs out")
    eq((Rules.cureStatus(100, "me", "me", 100 + 24 * 6.9, 7)), "ok")
    eq((Rules.cureStatus(100, "me", "you", 100, 7)), "notOwner")
    eq((Rules.cureStatus(100, "me", "you", 100 + 24 * 30, 7)), "notOwner", "owner first")
    eq((Rules.cureStatus(nil, nil, "you", 5000, 7)), "ok", "no issue time, no owner: usable")
    eq((Rules.cureStatus(nil, "me", "you", 5, 7)), "notOwner")
end)

test("serum kinds", function()
    local Serums = OA.Upgrades.Serums
    eq((Serums.kind("UpgradeSerumScout")), "upgrade")
    local _, tree = Serums.kind("UpgradeSerumLoad")
    eq(tree, "load")
    eq((Serums.kind("UpgradeSerumShared")), "shared")
    eq((Serums.kind("CureSerum")), "cure")
    eq((Serums.kind("DelayDrug")), "delay")
    eq(Serums.kind("Axe"), nil)
end)

test("bite shield: armed at rank 2, rests for seven days, shorter with the board", function()
    local u = fresh()
    eq(Rules.biteReady(u, 0), false, "no node")
    inject(u, "survival", 25)
    buy(u, ORDER.survival)
    eq(Rules.biteReady(u, 0), true)
    u.biteAt = 100
    eq(Rules.biteReady(u, 100 + 167), false)
    eq(Rules.biteReady(u, 100 + 168), true)
    near(Rules.biteWait(u, 120), 148, 1e-9)
    near(Rules.biteHours(u), 168, 1e-9)
    -- the moodle's level: 4 for the first quarter of the rest, down to 1 in its last, 0 once armed
    eq(Rules.biteLevel(u, 100), 4)
    eq(Rules.biteLevel(u, 100 + 42.5), 3)
    eq(Rules.biteLevel(u, 100 + 84.5), 2)
    eq(Rules.biteLevel(u, 100 + 126.5), 1)
    eq(Rules.biteLevel(u, 100 + 168), 0)
    eq(Rules.biteLevel(fresh(), 100), 0, "no shield, no moodle")
    inject(u, "scout", 26)
    buy(u, ORDER.scout)
    buy(u, { "nightEye" }, { fragments = 1 })
    inject(u, "load", 26)
    buy(u, ORDER.load)
    buy(u, { "armor" }, { fragments = 1 })
    inject(u, "survival", 1)
    buy(u, { "dash" }, { fragments = 1 })
    for _ = 1, 5 do Rules.injectShared(u) end
    buy(u, rep("bBite", 5))
    near(Rules.biteHours(u), 168 / 1.5, 1e-9)
end)

test("effects: values for the API from ranks", function()
    local u = fresh()
    inject(u, "scout", 12)
    inject(u, "load", 12)
    buy(u, cat(rep("sight", 3), rep("night", 3), rep("alarm", 1), rep("rich", 2), rep("overload", 1)))
    local v = Effects.compute(u, 0)
    near(v["vision.coneAdd"], 36, 1e-9)
    near(v["vision.darknessRestore"], 0.6, 1e-9)
    near(v["loot.spawnMultiplier"], 1.30, 1e-9)
    near(v["overload.compress"], 0.3, 1e-9)
    eq(v["move.walkMultiplier"], nil)
    eq(v["carry.categoryEfficiency"], nil)
    eq(v["infection.biteShield"], nil)
    buy(u, cat(rep("moveSpeed", 3), rep("materials", 3), rep("furniture", 2), rep("keyring", 1)))
    v = Effects.compute(u, 0)
    near(v["carry.categoryEfficiency"].Material, 0.45, 1e-9)
    near(v["carry.categoryEfficiency"].Paint, 0.45, 1e-9)
    near(v["carry.itemEfficiency"]["base:moveable"], 1.0, 1e-9)
    eq(v["carry.containerTagMultiplier"]["base:keyring"], 0)
end)

test("effects: capacity, overload and the hidden zombie fix", function()
    local u = fresh()
    inject(u, "load", 12)
    buy(u, cat(rep("overload", 2), rep("moveSpeed", 3), rep("keyring", 1), rep("capacity", 5)))
    local v = Effects.compute(u, 0, { hiddenZombieFix = true })
    near(v["capacity.maxWeightAdd"], 10, 1e-9)
    eq(v["capacity.characterLimitAdd"], 18)
    near(v["overload.compress"], 0.6, 1e-9)
    eq(v["vision.hiddenZombieFix"], true)
    eq(Effects.compute(u, 0)["vision.hiddenZombieFix"], nil)
end)

test("effects: the strengthened materials node replaces the base node's total", function()
    local u = fresh()
    inject(u, "load", 25)
    buy(u, cat(rep("overload", 2), rep("moveSpeed", 3), rep("keyring", 1), rep("materials", 3), rep("runSpeed", 2),
        rep("capacity", 5), rep("combatSpeed", 2)))
    near(Effects.compute(u, 0)["carry.categoryEfficiency"].Material, 0.45, 1e-9)
    buy(u, { "materialsPlus" })
    near(Effects.compute(u, 0)["carry.categoryEfficiency"].Material, 0.70, 1e-9)
    buy(u, { "materialsPlus" })
    near(Effects.compute(u, 0)["carry.categoryEfficiency"].Material, 1.00, 1e-9)
end)

test("effects: the board adds to the tree's sum, which divides", function()
    local u = fresh()
    openBoard(u)
    near(Effects.compute(u, 0)["body.discomfortMultiplier"], 0.5, 1e-9, "the capstone halves discomfort")
    for _ = 1, 10 do Rules.injectShared(u) end
    buy(u, rep("bGear", 5))
    near(Effects.compute(u, 0)["body.discomfortMultiplier"], 1 / 2.5, 1e-9)
    buy(u, rep("bHeavy", 5))
    local v = Effects.compute(u, 0)
    near(v["carry.categoryEfficiency"].Material, 2.0, 1e-9, "tree 100% and the board's 100%")
    near(v["carry.itemEfficiency"]["base:moveable"], 2.0, 1e-9)
end)

test("effects: family weight lands on the family's display categories", function()
    local u = fresh()
    openBoard(u)
    for _ = 1, 3 do Rules.injectShared(u) end
    truthy(Rules.buy(u, "bFamily", nil, "A"))
    truthy(Rules.buy(u, "bFamily", nil, "A"))
    truthy(Rules.buy(u, "bFamily", nil, "G"))
    local c = Effects.compute(u, 0)["carry.categoryEfficiency"]
    near(c.Food, 0.2, 1e-9)
    near(c.Electronics, 0.1, 1e-9)
    near(c.Communications, 0.1, 1e-9)
    eq(c.Clothing, nil)
end)

test("effects: infection resistance, walking, trees, falls and the bite shield point", function()
    local u = fresh()
    inject(u, "survival", 25)
    buy(u, ORDER.survival)
    local v = Effects.compute(u, 0)
    near(v["body.poisonMultiplier"], 0.4, 1e-9)
    near(v["body.coldMultiplier"], 0.4, 1e-9)
    near(v["body.corpseSicknessMultiplier"], 0.4, 1e-9)
    near(v["body.corpseCountMultiplier"], 1 / 1.6, 1e-9)
    near(v["infection.woundChance"], 0.4, 1e-9)
    near(v["body.stiffnessMultiplier"], 0.4, 1e-9)
    near(v["body.holeChance"], 0.4, 1e-9)
    eq(v["infection.biteShield"], true)
    u.biteAt = 0
    eq(Effects.compute(u, 10)["infection.biteShield"], nil, "resting")
    eq(Effects.compute(u, 200)["infection.biteShield"], true)
    near(v["move.walkMultiplier"], 1.15, 1e-9)
    near(v["move.treeSlowMultiplier"], 0, 1e-9)
    eq(v["move.treeScratchChance"], 0.5)
    eq(v["fall.landingRemap"], 3)
end)

test("effects are declared once, only what changed, and cleared with nil", function()
    local sets = {}
    PZToolsAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        formulas = {
            set = function(handle, name, value) sets[#sets + 1] = { handle, name, value } end,
            points = function() return { ["vision.coneAdd"] = "applied" } end,
        },
    }
    SandboxVars.OperationAcorn.HiddenZombieFix = false
    local record = OA.Store.ensure("p", "P")
    local u = Rules.section(record)
    inject(u, "scout", 3)
    buy(u, { "sight" })
    -- the cone, and the capacity key every character declares
    eq(Effects.apply(record), 2, "two points declared")
    local function last(name)
        for i = #sets, 1, -1 do
            if sets[i][2] == name then return sets[i][3] end
        end
        return nil
    end
    eq(sets[1][1], "handle")
    eq(last("vision.coneAdd"), 12)
    eq(last("capacity.modDataKey"), "OA_Capacity")
    eq(Effects.apply(record), 0, "nothing changed")
    buy(u, { "sight" })
    eq(Effects.apply(record), 1)
    eq(last("vision.coneAdd"), 24)
    eq((Effects.status("sight")), "ok")
    eq((Effects.status("rich")), "noPoint", "this point is not applied by the API")
    eq((Effects.status("sixth")), "lua")
    Rules.assign(u, Rules.blank())
    eq(Effects.apply(record), 1)
    eq(last("vision.coneAdd"), nil)
    PZToolsAPI = nil
    Effects.reset()
    eq(Effects.apply(record), nil)
    eq((Effects.status("sight")), "noApi")
end)

test("the hidden zombie fix is declared by default, and not with the option off", function()
    local sets = {}
    PZToolsAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        formulas = { set = function(handle, name, value) sets[name] = value end },
    }
    local record = OA.Store.ensure("p", "P")
    Effects.apply(record)
    eq(sets["vision.hiddenZombieFix"], true)
    SandboxVars.OperationAcorn.HiddenZombieFix = false
    Effects.apply(record)
    eq(sets["vision.hiddenZombieFix"], nil)
    PZToolsAPI = nil
end)

test("the sense radii read the board", function()
    local u = fresh()
    eq(Rules.sixthRadius(u), 0)
    eq(Rules.senseRadius(u), 0)
    inject(u, "scout", 3)
    buy(u, { "sixth", "sixth" })
    eq(Rules.sixthRadius(u), 8)
    local v = fresh()
    openBoard(v)
    eq(Rules.senseRadius(v), Data.SENSE_RADIUS)
    for _ = 1, 3 do Rules.injectShared(v) end
    buy(v, rep("bSense", 3))
    eq(Rules.senseRadius(v), Data.SENSE_RADIUS + 3)
end)

test("the fragment bonus and the bundle bonus", function()
    local u = fresh()
    openBoard(u)
    near(Rules.fragmentBonus(u), 1.5, 1e-9, "눈썰미 3 gives +150%")
    near(Rules.bundleBonus(u), 0.3, 1e-9)
    for _ = 1, 10 do Rules.injectShared(u) end
    buy(u, rep("bBundle", 5))
    near(Rules.bundleBonus(u), 0.4, 1e-9)
    buy(u, rep("bShard", 4))
    truthy(Rules.fragmentBonus(u) > 1.5)
end)

test("lock chances, times and side effects follow the ranks", function()
    local u = fresh()
    inject(u, "survival", 10)
    near(Rules.crowbarChance(u), 0, 1e-9)
    eq(Rules.sideEffects(u), 1)
    buy(u, { "serumAdapt", "crowbar" })
    near(Rules.crowbarChance(u), 0.35, 1e-9)
    eq(Rules.sideEffects(u), 0.5)
    buy(u, { "serumAdapt", "crowbar", "stiff" })
    near(Rules.crowbarChance(u), 0.5, 1e-9)
    eq(Rules.sideEffects(u), 0)
    buy(u, { "stiff", "stiff", "lock", "lock" })
    near(Rules.lockChance(u), 0.9, 1e-9)
    eq(Rules.lockTime(u), 0.5)
end)

test("public API reads the record", function()
    local record = OA.Store.ensure("q", "Q")
    eq(OA.Upgrades.rank(record, "sight"), 0)
    OA.Upgrades.noteBought(record, "scout", 1)
    eq(OA.Upgrades.bought(record, "scout"), 1)
    local u = Rules.section(record)
    inject(u, "scout", 1)
    buy(u, { "sight" })
    eq(OA.Upgrades.rank(record, "sight"), 1)
    eq(OA.Upgrades.points(record).scout, 0)
    eq(OA.Upgrades.serumPrice(1), 8000)
end)

-- ---- the server's commands ---------------------------------------------------------------------------------------

-- A character with an inventory that holds fragments, for the commands.
local function fakeCharacter(fragments)
    local items = {}
    for i = 1, fragments do items[#items + 1] = { id = i } end
    local container
    container = {
        getCountTypeRecurse = function() return #items end,
        getFirstTypeRecurse = function()
            local item = items[1]
            if not item then return nil end
            item.getContainer = function() return container end
            return item
        end,
        DoRemoveItem = function(_, item)
            for i, v in ipairs(items) do if v == item then table.remove(items, i) return end end
        end,
    }
    return {
        getUsername = function() return "tester" end,
        getInventory = function() return container end,
        getModData = function() return {} end,
        fragments = function() return #items end,
    }
end

test("server: approve spends points and fragments, and refuses a bad plan whole", function()
    require "OperationAcorn/Upgrades/Server"
    local character = fakeCharacter(2)
    local record = OA.Store.ensure("srv", "tester")
    local u = Rules.section(record)
    inject(u, "scout", 26)
    local steps = {}
    for _, id in ipairs(ORDER.scout) do steps[#steps + 1] = { id = id } end
    steps[#steps + 1] = { id = "nightEye" }
    sendClientCommand(character, OA.MOD, "upgrades.approve", { id = "srv", steps = steps })
    eq(Rules.rank(u, "nightEye"), 1)
    eq(Rules.rank(u, "sight"), 3)
    eq(Rules.ownPool(u, "scout"), 0)
    eq(character:fragments(), 1, "one fragment taken")
    -- a plan with one bad step changes nothing
    local before = Rules.rank(u, "alarm")
    sendClientCommand(character, OA.MOD, "upgrades.approve", { id = "srv", steps = { { id = "alarm" }, { id = "nope" } } })
    eq(Rules.rank(u, "alarm"), before)
    -- a capstone without a fragment is refused
    local v = Rules.section(OA.Store.ensure("srv2", "t2"))
    inject(v, "scout", 26)
    local c2 = fakeCharacter(0)
    local plan = {}
    for _, id in ipairs(ORDER.scout) do plan[#plan + 1] = { id = id } end
    plan[#plan + 1] = { id = "nightEye" }
    sendClientCommand(c2, OA.MOD, "upgrades.approve", { id = "srv2", steps = plan })
    eq(Rules.rank(v, "sight"), 0, "nothing was bought")
end)

test("server: a capstone approved has a gold title with its name; the last one opens the board, one title", function()
    require "OperationAcorn/Upgrades/Server"
    local character = fakeCharacter(3)
    local record = OA.Store.ensure("cap", "tester")
    local u = Rules.section(record)
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    local function approveTree(tree)
        inject(u, tree, 26)
        local steps = {}
        for _, id in ipairs(ORDER[tree]) do steps[#steps + 1] = { id = id } end
        steps[#steps + 1] = { id = Data.capstone(tree).id }
        sendClientCommand(character, OA.MOD, "upgrades.approve", { id = "cap", steps = steps })
    end
    approveTree("scout")
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_Capstone")
    eq(told[1].sub, Data.key("nightEye", "Name"))
    eq(told[1].tone, "gold")
    approveTree("load")
    eq(#told, 2)
    eq(told[2].sub, Data.key("armor", "Name"))
    approveTree("survival")
    truthy(Rules.boardOpen(u))
    eq(#told, 3, "the board's title in place of the capstone's")
    eq(told[3].key, "IGUI_OA_Title_BoardOpened")
    eq(told[3].tone, "gold")
    -- a plan without a capstone has no title
    inject(u, "scout", 1)
    sendClientCommand(character, OA.MOD, "upgrades.approve", { id = "cap", steps = { { id = ORDER.scout[1] } } })
    eq(#told, 3)
end)

test("a cure serum that works has a green title in place of its notice", function()
    local Serums = OA.Upgrades.Serums
    local told, notices = {}, {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    OA.Sync.listen("notice", function(id, detail) notices[#notices + 1] = detail.key end)
    local real = { status = Serums.cureStatus, infected = Serums.infected, body = Serums.cureBody }
    Serums.cureStatus = function() return "ok", 3 end
    Serums.infected = function() return true end
    Serums.cureBody = function() end
    local container = { DoRemoveItem = function() end }
    local item = { getType = function() return "CureSerum" end, getContainer = function() return container end }
    truthy(Serums.cure({}, item, "cure1"))
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_Cured")
    eq(told[1].tone, "green")
    eq(#notices, 0)
    Serums.cureStatus, Serums.infected, Serums.cureBody = real.status, real.infected, real.body
end)

test("server: reset takes the credits and refuses a debt", function()
    require "OperationAcorn/Upgrades/Server"
    local character = fakeCharacter(0)
    local record = OA.Store.ensure("rst", "tester")
    local u = Rules.section(record)
    inject(u, "load", 3)
    Rules.noteBought(u, "load", 3)
    buy(u, { "overload", "overload", "moveSpeed" })
    local cost = Rules.resetCost(u, "load")
    OA.Store.section(record, "trade").credits = -10
    sendClientCommand(character, OA.MOD, "upgrades.reset", { id = "rst", tree = "load" })
    eq(Rules.treeSpent(u, "load"), 3, "debt blocks it")
    OA.Store.section(record, "trade").credits = cost + 500
    sendClientCommand(character, OA.MOD, "upgrades.reset", { id = "rst", tree = "load" })
    eq(Rules.treeSpent(u, "load"), 0)
    eq(OA.Store.section(record, "trade").credits, 500)
end)

test("server: the bite shield rests after a save", function()
    require "OperationAcorn/Upgrades/Server"
    local character = fakeCharacter(0)
    local record = OA.Store.ensure("bit", "tester")
    local u = Rules.section(record)
    inject(u, "survival", 25)
    buy(u, ORDER.survival)
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    TEST.hours = 300
    sendClientCommand(character, OA.MOD, "upgrades.bite", { id = "bit" })
    eq(u.biteAt, 300)
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_BiteSaved")
    eq(told[1].tone, "green")
    eq(told[1].subArgs[1], math.floor(Rules.biteHours(u) / 24 + 0.5))
    TEST.hours = 310
    sendClientCommand(character, OA.MOD, "upgrades.bite", { id = "bit" })
    eq(u.biteAt, 300, "a second save while resting does not count")
    eq(#told, 1)
end)
