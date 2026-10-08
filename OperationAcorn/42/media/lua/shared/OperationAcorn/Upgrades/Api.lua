-- What the other parts of the mod call (ARCHITECTURE section 5): ranks, the serum purchase count, the bonuses the
-- shredder and the meteor drops read. Everything takes a player's record, as Store.player gives it. The parts that
-- build the screen and the effects are in the client folder.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Upgrades/Effects"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/Plan"
require "OperationAcorn/Upgrades/Sense"
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

-- Meteor fragments from a drop site are multiplied by 1 + this (눈썰미 and the board).
function Upgrades.fragmentBonus(record)
    return Rules.fragmentBonus(Rules.section(record))
end

-- Sample bundles the shredder adds to its yield, as an expected count (눈썰미 and the board).
function Upgrades.bundleBonus(record)
    return Rules.bundleBonus(Rules.section(record))
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
