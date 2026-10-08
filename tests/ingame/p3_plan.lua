-- P3: plan, approval and reset, through the server code (single player: the game is its own server).
-- Setup: a single-player world, the mod on. Changes the record (points, ranks, credits): use a throwaway save.
-- Prints "[p3plan]" lines.
RUN("p3_lib.lua")
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Server = OA.Upgrades.Server
local say = P3T.say("p3plan")
local record, player, u, id = P3T.record()

P3T.points(u, "scout", 13)
P3T.points(u, "load", 13)
P3T.points(u, "survival", 13)
local trade = OA.Store.section(record, "trade")
trade.credits = (trade.credits or 0) + 2000000
-- some serums count as bought so a reset has a price
OA.Upgrades.noteBought(record, "scout", 13)

local ok, why = Server.approve(player, record, P3T.steps({ "sight", "sight", "sight", "sixth", "sixth", "alarm" }))
P3T.check(say, "a legal plan is approved", ok, why)
P3T.check(say, "sight at 3", Rules.rank(u, "sight") == 3)
ok, why = Server.approve(player, record, P3T.steps({ "sense" }))
P3T.check(say, "a node with its prerequisite", ok, why)
ok, why = Server.approve(player, record, P3T.steps({ "sensePlus", "sensePlus", "sensePlus", "nightEye" }))
P3T.check(say, "a plan with an unmet capstone is refused whole", not ok, why)
P3T.check(say, "...and changed nothing", Rules.rank(u, "sensePlus") == 0)

-- a capstone: needs 12 points in the tree and a fragment
local fragmentKnown = getScriptManager():FindItem(Data.FRAGMENT) ~= nil
say("meteor fragment item exists", fragmentKnown)
ok, why = Server.approve(player, record, P3T.steps({ "night", "night", "night", "rich", "rich", "rich", "ledger", "ledger", "ledger" }))
P3T.check(say, "nine more points of the scout tree", ok, why)
say("scout points spent", Rules.treeSpent(u, "scout"))
if fragmentKnown then
    ok, why = Server.approve(player, record, P3T.steps({ "nightEye" }))
    P3T.check(say, "the capstone is refused without a fragment", not ok, why)
    P3T.give(Data.FRAGMENT)
    ok, why = Server.approve(player, record, P3T.steps({ "nightEye" }))
    P3T.check(say, "the capstone is approved with a fragment", ok, why)
    P3T.check(say, "the fragment is consumed", player:getInventory():getCountTypeRecurse(Data.FRAGMENT) == 0)
end

-- reset
local cost = Rules.resetCost(u, "scout")
local before = trade.credits
say("reset cost of the scout tree", cost, "credits", before)
ok, why = Server.reset(record, "scout")
P3T.check(say, "reset works", ok, why)
P3T.check(say, "the cost was taken", trade.credits == before - cost)
P3T.check(say, "ranks are back to 0", Rules.rank(u, "sight") == 0)
P3T.check(say, "the points are back", Rules.ownPool(u, "scout") == 13)
P3T.check(say, "the serum count never decreases", u.injected.scout == 13)
Server.approve(player, record, P3T.steps({ "sight" }))
trade.credits = -5
ok, why = Server.reset(record, "scout")
P3T.check(say, "debt blocks a reset", not ok and why == "debt", why)
trade.credits = 0
say("now open the window (OA.Upgrades.open()) and look at the three tabs and the ??? board")
