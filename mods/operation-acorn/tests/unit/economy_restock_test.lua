-- The shop's restock items (NUMBERS 7): the clock, the quantities, the shared serum's price and the weapon kits.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Trade/Rules"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Trade/ShopView"
local OA = OperationAcorn
local S = OA.Shop

-- A record at a trust tier (the stage up to 5, the milestones past it) with credits.
local function atTier(tier, id)
    local r = OA.Store.ensure(id or "s", "S")
    r.trade = { credits = 1000000, trust = 0, stage = math.min(tier, 5), milestones = math.max(0, tier - 5),
        bonus = 0, sharedSerums = 0, levels = TEST.levelsForTier(tier) }
    OA.Trust.reset()
    return r
end

local function find(id)
    local e = S.entry(id)
    truthy(e, "entry " .. id)
    return e
end

test("the restock window starts at the first look and rolls when asked: it refills and nothing piles up", function()
    local r = atTier(1)
    local serum = find("serum_shared")
    TEST.hours = 100
    eq(r.shop, nil, "no clock before the shop is looked at")
    eq((S.available(serum, r)), 1)
    eq(r.shop.restock.start, 100)
    S.bought(serum, r, 1)
    local n, why, at = S.available(serum, r)
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_SoldOut"); eq(at, 340, "ten days on")
    TEST.hours = 339.9
    eq((S.available(serum, r)), 0)
    TEST.hours = 340
    eq((S.available(serum, r)), 1)
    eq(r.shop.restock.start, 340)
    eq(r.shop.restock.n.serum_shared, nil, "the count starts again")
    -- windows that passed unasked leave one window's stock, and the next window starts on the old rhythm
    TEST.hours = 340 + 240 * 5 + 10
    eq((S.available(serum, r)), 1, "not six")
    eq(r.shop.restock.start, 340 + 240 * 5)
    eq(select(3, S.available(serum, r)), 340 + 240 * 6)
end)

test("a town makes the windows after this one shorter, by a tenth each, with no floor", function()
    local r = atTier(1)
    local serum = find("serum_shared")
    TEST.hours = 0
    S.available(serum, r)
    eq(S.townDone(r, 1), true)
    eq(S.townDone(r, 1), false, "a town once")
    eq(select(3, S.available(serum, r)), 240, "this window keeps its length")
    TEST.hours = 240
    near(select(3, S.available(serum, r)), 240 + 216, 1e-9, "the next is 0.9 of ten days")
    S.townDone(r, 2)
    TEST.hours = 456
    near(select(3, S.available(serum, r)), 456 + 240 * 0.81, 1e-9, "two towns 0.81")
    for town = 3, 40 do S.townDone(r, town) end
    TEST.hours = 456 + 240 * 0.81
    truthy(select(3, S.available(serum, r)) > TEST.hours, "a window still has a length")
    near(r.shop.restock.nextFactor, 0.9 ^ 40, 1e-12)
end)

test("the shared serum restocks to a third of the trust tier plus one", function()
    local serum = find("serum_shared")
    local want = { [1] = 1, [2] = 1, [3] = 2, [4] = 2, [5] = 2, [6] = 3, [8] = 3, [9] = 4, [12] = 5 }
    for tier, q in pairs(want) do
        local r = atTier(tier)
        eq(S.restockQuantity(serum, r), q, "tier " .. tier)
        eq((S.available(serum, r)), q, "stock at tier " .. tier)
    end
end)

test("the shared serum's price doubles with each one bought in a window and starts over with the next", function()
    local r = atTier(6)
    local serum = find("serum_shared")
    TEST.hours = 0
    eq(S.price(serum, r), 20000)
    S.bought(serum, r, 1)
    eq(S.price(serum, r), 40000)
    S.bought(serum, r, 1)
    eq(S.price(serum, r), 80000)
    eq(S.price(serum, r, 1), 160000, "the unit after, in one order")
    S.bought(serum, r, 1)
    eq((S.available(serum, r)), 0, "three at tier 6")
    TEST.hours = 240
    eq(S.price(serum, r), 20000)
    eq((S.available(serum, r)), 3)
end)

test("the shared serum's price follows the serum price option; the shop multiplier and the discount leave it", function()
    local r = atTier(1)
    local serum = find("serum_shared")
    local option = OA.option
    OA.option = function(name)
        if name == "UpgradeSerumPriceMultiplier" then return 1.5 end
        if name == "ShopPriceMultiplier" then return 3 end
        return option(name)
    end
    eq(S.price(serum, r), 30000)
    OA.option = option
end)

test("an order of the shared serum is charged by the window's own prices, one unit after the other", function()
    local r = atTier(6)
    local serum = find("serum_shared")
    local Orders, Rules = OA.Trade.Orders, OA.Trade.Rules
    local svc = Orders.shopService(r)
    eq(Orders.lineCost(svc, serum, { id = "serum_shared", count = 3 }), 140000, "the cart shows 20k + 40k + 80k")
    local balance, spent, results = Rules.payOrders(1000000, { { id = "serum_shared", count = 5 } }, svc)
    eq(spent, 140000)
    eq(balance, 860000)
    eq(results[1].delivered, 3, "only the stock")
    eq(results[1].reason, "limit")
    eq(S.price(serum, r), 20000 * 8)
end)

test("the weapon kits: tier 6, kits only, fixed prices, one more for each place cleared that gave their kind", function()
    local damage, crit, repair = find("kit_weapon_damage"), find("kit_weapon_crit"), find("kit_weapon_repair")
    for _, e in ipairs({ damage, crit, repair }) do
        eq(e.tier, 6); eq(e.kits, true); eq(e.group, "kit"); eq(e.fixed, true)
    end
    eq(damage.give[1].type, "OperationAcorn.KitWeaponDamage")
    eq(crit.give[1].type, "OperationAcorn.KitWeaponCrit")
    eq(repair.give[1].type, "OperationAcorn.KitWeaponRepair")
    local r = atTier(6)
    eq(S.restockQuantity(damage, r), 1, "no dense section")
    r.dense = { got = { a = "damage", b = "damage", c = "crit", d = "repair", e = "repair", f = "repair" } }
    eq(S.restockQuantity(damage, r), 3)
    eq(S.restockQuantity(crit, r), 2)
    eq(S.restockQuantity(repair, r), 4)
    local option = OA.option
    OA.option = function(name)
        if name == "ShopPriceMultiplier" then return 2 end
        return option(name)
    end
    eq(S.price(damage, r), 60000); eq(S.price(crit, r), 60000); eq(S.price(repair, r), 30000)
    OA.option = option
    S.available(damage, r)
    S.bought(damage, r, 3)
    eq((S.available(damage, r)), 0)
    r.dense.got.g = "damage"
    eq((S.available(damage, r)), 1, "a place cleared mid-window adds one at once")
    eq((S.available(repair, atTier(5, "low"))), 0, "locked below tier 6")
    OA.option = function(name)
        if name == "KitsForSale" then return false end
        return option(name)
    end
    eq(select(2, S.available(damage, r)), "IGUI_OA_Econ_Shop_KitsOff")
    OA.option = option
end)

test("the shop card of a restock entry says its stock, or when it is back", function()
    local V = OA.Trade.ShopView
    local serum = find("serum_shared")
    local r = atTier(6)
    local ctx = { crude = false, tier = 6, debt = false, whenText = function(h) return "at " .. h end }
    TEST.hours = 0
    local n, why, at = S.available(serum, r)
    local st = V.state(serum, { n = n, why = why, reopen = at }, ctx)
    eq(st.open, true); eq(st.key, "IGUI_OA_Terminal_Shop_StockLeft"); eq(st.args[1], 3)
    S.bought(serum, r, 3)
    n, why, at = S.available(serum, r)
    st = V.state(serum, { n = n, why = why, reopen = at }, ctx)
    eq(st.open, false); eq(st.key, "IGUI_OA_Terminal_Shop_SoldOutFrom"); eq(st.args[1], "at 240"); eq(st.tone, "timer")
end)
