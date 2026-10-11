-- 철저한 수색 (the search ledger): its line on entering a building tells roughly what is left, not a count, and a
-- building searched at rank 3 pays three times its bonus, the title saying how much of it the rank added.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Requests"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Sense = OA.Upgrades.Sense

test("the line on entering tells roughly what is left", function()
    eq(Sense.ledgerKey(0, 12), "IGUI_OA_Tree_LedgerUntouched", "nothing opened yet, however big")
    eq(Sense.ledgerKey(0, 1), "IGUI_OA_Tree_LedgerUntouched")
    eq(Sense.ledgerKey(3, 1), "IGUI_OA_Tree_LedgerFew")
    eq(Sense.ledgerKey(3, 2), "IGUI_OA_Tree_LedgerFew")
    eq(Sense.ledgerKey(3, 3), "IGUI_OA_Tree_LedgerSome")
    eq(Sense.ledgerKey(1, 6), "IGUI_OA_Tree_LedgerSome")
    eq(Sense.ledgerKey(1, 7), "IGUI_OA_Tree_LedgerMany")
end)

local function searched(id, rank)
    require "OperationAcorn/Economy"
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    local record = OA.Store.ensure(id, id)
    local u = Rules.section(record)
    u.ranks.ledger = rank
    local titles = {}
    OA.Sync.listen("title", function(_, detail) titles[#titles + 1] = detail end)
    local credits = OA.Economy.searched(record, "b-" .. id, 7)
    return credits, titles[#titles]
end

test("rank 1 and 2 pay the plain bonus and say so", function()
    local credits, title = searched("t2", 2)
    eq(credits, 170, "100 and 10 for each of 7 containers")
    eq(title.sub, "IGUI_OA_Title_SearchedBonus")
    eq(title.subArgs[1], "170")
end)

test("rank 3 pays three times the bonus and the title tells what the rank added", function()
    local credits, title = searched("t3", 3)
    eq(credits, 510)
    eq(title.sub, "IGUI_OA_Title_SearchedBonusThorough")
    eq(title.subArgs[1], "510")
    eq(title.subArgs[2], "340", "the rank's part")
    eq(title.subArgs[3].key, "IGUI_OA_Tree_Node_ledger_Name", "named by the node's own name")
end)

test("a floor's search goes up by stages: half, three quarters, six left, two left, done", function()
    eq(Sense.ledgerStage(100, 51), 0)
    eq(Sense.ledgerStage(100, 50), 1, "half of a big floor")
    eq(Sense.ledgerStage(100, 25), 2, "three quarters")
    eq(Sense.ledgerStage(100, 6), 3)
    eq(Sense.ledgerStage(100, 2), 4)
    eq(Sense.ledgerStage(100, 0), 5)
    eq(Sense.ledgerStage(20, 5), 3, "three quarters of a small floor leaves 6 or fewer: the count's stage")
    eq(Sense.ledgerStage(8, 4), 3, "half of a small floor too")
    eq(#Sense.LEDGER_STAGES, 5)
end)
