-- What the other parts of the mod call (ARCHITECTURE section 5): ranks, the serum purchase count, the bonus the
-- shredder reads, a meteorite fragment settled. Everything takes a player's record, as Store.player gives it. The parts that
-- build the screen and the effects are in the client folder.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Upgrades/Effects"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/Plan"
require "OperationAcorn/Upgrades/Sense"
require "OperationAcorn/Upgrades/Adapt"
local OA = OperationAcorn
local Upgrades = OA.Upgrades
local Rules = Upgrades.Rules

-- The rank a node has (0 when none).
function Upgrades.rank(record, id)
    if not record then return 0 end
    return Rules.rank(Rules.section(record), id)
end

-- How many serums of a tree the record has bought: the next costs the price of this number plus one.
function Upgrades.bought(record, tree)
    return Rules.section(record).bought[tree] or 0
end

-- Notes serums bought: `count` of the tree, for `paid` credits (nil: the base price). Called by the shop when an order
-- is placed or settled. The count never goes down.
function Upgrades.noteBought(record, tree, count, paid)
    Rules.noteBought(Rules.section(record), tree, count, paid)
end

-- The base price of the n-th serum of a tree (NUMBERS 6), before the shop's multiplier and discounts.
function Upgrades.serumPrice(n)
    return Rules.serumPrice(n)
end

-- A meteorite fragment reached the research team (a delivery box settled it): the capstone of its tree opens for
-- good and the team's memo on the sample comes to the folder. True when it opened a capstone now.
function Upgrades.fragmentReceived(record, fullType)
    local tree = Upgrades.Data.treeOfFragment(fullType)
    if not (tree and Rules.unseal(Rules.section(record), tree)) then return false end
    OA.Sync.changed("upgrades", record.id, { kind = "unseal", tree = tree })
    Upgrades.Adapt.unsealed(record, tree)
    return true
end

-- The title of a capstone taken: its name, and under it what it is (a final adaptation); quiet (the API's "dust": it
-- fades in and crumbles away), in gold.
function Upgrades.capstoneTitle(node)
    return { key = Upgrades.Data.key(node.id, "Name"), sub = "IGUI_OA_Title_Capstone", style = "dust", tone = "gold",
        size = "major" }
end

-- The title of the second board opening (the last capstone taken): the same quiet one, in gold.
function Upgrades.boardTitle()
    return { key = "IGUI_OA_Title_BoardOpened", sub = "IGUI_OA_Title_BoardOpenedSub", style = "dust", tone = "gold" }
end

-- Sample bundles the shredder adds to its yield, as an expected count (the board).
function Upgrades.bundleBonus(record)
    return Rules.bundleBonus(Rules.section(record))
end

-- The chance a sample bundle comes with a selected sample (시료 감별 and the board), 0..1.
function Upgrades.selectedChance(record)
    return Rules.selectedChance(Rules.section(record))
end

-- Points the record can spend now: { scout, load, survival, shared, board }.
function Upgrades.points(record)
    local u = Rules.section(record)
    return {
        scout = Rules.ownPool(u, "scout"), load = Rules.ownPool(u, "load"), survival = Rules.ownPool(u, "survival"),
        shared = Rules.sharedPool(u), board = Rules.boardLeft(u),
    }
end

return Upgrades
