-- Shop: the catalog, prices, the unlock tiers, the weekly limits, the serum and kit prices.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
local S = OA.Shop

local function record(stage, milestones, credits)
    local r = OA.Store.ensure("s", "S")
    r.trade = { credits = credits or 100000, trust = 0, stage = stage or 0, milestones = milestones or 0,
        bonus = 0, sharedSerums = 0 }
    return r
end

local function find(id)
    local e = S.entry(id)
    truthy(e, "entry " .. id)
    return e
end

test("every NUMBERS 7 price is in the catalog", function()
    local expect = {
        cure_serum = { 30000, 1 }, delay_drug = { 6000, 0 }, battery_pack = { 4000, 1 }, seed_pack = { 3000, 1 },
        petrol_can = { 15000, 2 }, scrap_pack = { 6000, 2 }, propane_tank = { 25000, 3 }, car_battery = { 20000, 3 },
        car_part_normal = { 10000, 3 }, engine_parts = { 20000, 3 }, car_part_modern = { 25000, 5 },
        ammo_pistol = { 40000, 4 }, ammo_shotgun = { 50000, 4 }, ammo_rifle = { 60000, 4 },
        team_backpack = { 300000, 5 }, shred_bench = { 5000, 0 }, bait_trap = { 12000, 2 }, team_locker = { 60000, 2 },
        fabric_cutter = { 80000, 2 }, log_saw = { 100000, 2 }, rain_cistern = { 90000, 3 },
        bulk_shredder = { 150000, 3 }, propane_refinery = { 200000, 3 }, oil_refinery = { 250000, 4 },
        box_reissue = { 10000, 0 },
        motor_normal = { 25000, 3 }, motor_modern = { 60000, 5 }, shred_blade_normal = { 15000, 3 },
        shred_blade_modern = { 40000, 5 }, cut_blade_normal = { 15000, 3 }, cut_blade_modern = { 40000, 5 },
        saw_blade_normal = { 15000, 3 }, saw_blade_modern = { 40000, 5 }, filter_normal = { 20000, 3 },
        filter_modern = { 50000, 5 }, soundproof_cover = { 30000, 3 },
        fuelcan_mk1 = { 20000, 2 }, fuelcan_mk2 = { 45000, 4 }, fuelcan_mk3 = { 90000, 5 },
        torch_mk1 = { 30000, 3 }, torch_mk2 = { 70000, 5 }, torch_mk3 = { 150000, 6 },
        kit_bagCapacity = { 40000, 6 }, kit_bagWeight = { 50000, 6 }, kit_trunk = { 60000, 6 }, kit_engine = { 80000, 6 },
    }
    for id, want in pairs(expect) do
        local e = find(id)
        eq(e.price, want[1], id .. " price")
        eq(e.tier, want[2], id .. " tier")
    end
end)

test("ids are unique and every entry delivers something", function()
    local seen = {}
    for _, e in ipairs(S.catalog()) do
        truthy(not seen[e.id], "duplicate " .. e.id)
        seen[e.id] = true
        truthy(e.give or e.choices, e.id .. " has nothing to deliver")
        truthy(e.group, e.id .. " has a group")
    end
end)

test("the weekly limits of the late resources", function()
    eq(find("battery_pack").week, 5); eq(find("seed_pack").week, 5); eq(find("petrol_can").week, 3)
    eq(find("scrap_pack").week, 5); eq(find("propane_tank").week, 2); eq(find("car_battery").week, 2)
    eq(find("car_part_normal").week, 6); eq(find("engine_parts").week, 2); eq(find("car_part_modern").week, 6)
    eq(find("ammo_pistol").week, 2); eq(find("ammo_shotgun").week, 2); eq(find("ammo_rifle").week, 2)
    eq(find("cure_serum").week, nil)
end)

test("what an entry hands over", function()
    eq(find("battery_pack").give[1].count, 4)
    eq(find("scrap_pack").give[1].count, 10)
    eq(find("engine_parts").give[1].count, 10)
    eq(#find("car_battery").choices, 3)
    eq(#find("ammo_pistol").choices, 5)
    eq(#find("ammo_rifle").choices, 3)
    eq(find("team_backpack").give[2].count, 2)
    eq(find("team_backpack").give[2].type, "Base.CanteenMilitary")
    eq(find("petrol_can").give[1].fluid, "Petrol")
    truthy(find("fuelcan_mk1").give[1].empty)
    eq(find("torch_mk3").fragments, 1)
end)

test("the price is the base times the multiplier and the stage discount", function()
    local r = record(0)
    eq(S.price(find("battery_pack"), r), 4000)
    SandboxVars.OperationAcorn.ShopPriceMultiplier = 1.5
    eq(S.price(find("battery_pack"), r), 6000)
    SandboxVars.OperationAcorn.ShopPriceMultiplier = 1.0
    r = record(4)
    eq(S.price(find("battery_pack"), r), 3800, "5% off from stage 4")
    r = record(5, 2)
    eq(S.price(find("battery_pack"), r), 3600, "10% off from the second milestone")
end)

test("the cure serum price is a sandbox option", function()
    SandboxVars.OperationAcorn.CureSerumPrice = 50000
    eq(S.price(find("cure_serum"), record(0)), 50000)
end)

test("serums and the box ignore the multiplier and the discount", function()
    SandboxVars.OperationAcorn.ShopPriceMultiplier = 2.0
    local r = record(5, 2)
    eq(S.price(find("serum_scout"), r), 8000)
    eq(S.price(find("box_reissue"), r), 10000)
    SandboxVars.OperationAcorn.BoxReissueCost = 7000
    eq(S.price(find("box_reissue"), r), 7000)
end)

test("upgrade serum price: 8,000 times 1.15 per serum, to the nearest 100", function()
    local want = { [1] = 8000, [2] = 9200, [3] = 10600, [5] = 14000, [10] = 28100, [15] = 56600, [20] = 113900,
        [25] = 229000, [26] = 263400 }
    for n, price in pairs(want) do eq(S.serumPriceAt(n), price, "serum " .. n) end
end)

test("after the 26th the price goes straight up by 30,000", function()
    eq(S.serumPriceAt(27), 263400 + 30000)
    eq(S.serumPriceAt(30), 263400 + 120000)
    SandboxVars.OperationAcorn.UpgradeSerumPrice = 16000
    eq(S.serumPriceAt(1), 16000)
    eq(S.serumPriceAt(27) - S.serumPriceAt(26), 60000, "the straight part scales with the base")
end)

test("each tree counts its own serums", function()
    local r = record(0)
    local scout = find("serum_scout")
    eq(S.price(scout, r), 8000)
    S.bought(scout, r, 1)
    eq(S.price(scout, r), 9200)
    eq(S.price(find("serum_load"), r), 8000, "another tree is still at the first")
    S.bought(scout, r, 3)
    eq(S.price(scout, r), S.serumPriceAt(5))
    eq(S.serumPrice("scout", r, 9), S.serumPriceAt(10))
end)

test("serum growth is a sandbox option", function()
    SandboxVars.OperationAcorn.UpgradeSerumGrowth = 1.0
    eq(S.serumPriceAt(20), 8000)
end)

test("kit prices rise with the kits bought for the same target", function()
    -- At the first milestone the 5% discount of stage 4 is on.
    local r = record(5, 1)
    eq(S.kitPrice("bagCapacity", "bag1", r), 38000)
    local kit = find("kit_bagCapacity")
    S.bought(kit, r, 1, "bag1")
    eq(S.kitPrice("bagCapacity", "bag1", r), OA.round(40000 * 1.3 * 0.95))
    eq(S.kitPrice("bagCapacity", "bag2", r), 38000, "another bag starts over")
    eq(S.kitPrice("bagWeight", "bag1", r), OA.round(50000 * 0.95), "another kind too")
    eq(S.kitPrice("bagCapacity", "bag1", r, 2), OA.round(40000 * 1.3 ^ 3 * 0.95), "kits already in the order count")
    S.bought(find("kit_trunk"), r, 2, "car7")
    eq(S.kitPrice("trunk", "car7", r), OA.round(60000 * 1.25 ^ 2 * 0.95))
    eq(S.kitPrice("engine", "car7", r), OA.round(80000 * 0.95))
end)

test("kit prices take the multiplier and the discount", function()
    SandboxVars.OperationAcorn.ShopPriceMultiplier = 2.0
    local r = record(5, 2)
    eq(S.kitPrice("engine", "car", r), OA.round(80000 * 2.0 * 0.9))
end)

test("tiers lock and unlock entries", function()
    local r = record(0)
    local n, why = S.available(find("cure_serum"), r)
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_Locked")
    n = S.available(find("delay_drug"), r)
    truthy(n > 0)
    r = record(1)
    truthy(S.available(find("cure_serum"), r) > 0)
    n, why = S.available(find("propane_tank"), r)
    eq(n, 0)
    r = record(3)
    truthy(S.available(find("propane_tank"), r) > 0)
    n = S.available(find("kit_trunk"), record(5, 0))
    eq(n, 0)
    truthy(S.available(find("kit_trunk"), record(5, 1)) > 0)
end)

test("kits can be switched off", function()
    SandboxVars.OperationAcorn.KitsForSale = false
    local n, why = S.available(find("kit_trunk"), record(5, 1))
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_KitsOff")
    eq(#S.opensAt(6), 1, "the Mk.III torch only")
end)

test("debt blocks orders but not the box", function()
    local r = record(5, 1, -500)
    local n, why = S.available(find("battery_pack"), r)
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_Debt")
    truthy(S.available(find("box_reissue"), r) > 0)
    n, why = S.available(find("cure_serum"), r)
    eq(n, 0)
end)

test("weekly limits count what was bought this week and reopen the next", function()
    local r = record(3)
    local e = find("propane_tank")
    eq(S.available(e, r), 2)
    S.bought(e, r, 1)
    eq(S.available(e, r), 1)
    S.bought(e, r, 1)
    local n, why, opens = S.available(e, r)
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_Limit")
    truthy(opens > OA.hours())
    TEST.hours = 24 * 7 + 1
    eq(S.available(e, r), 2, "a new week")
end)

test("the next week begins at midnight of its first day", function()
    local r = record(3)
    local e = find("propane_tank")
    S.bought(e, r, 2)
    local _, _, opens = S.available(e, r)
    TEST.hours = opens
    eq(OA.day(), 7)
    TEST.hours = opens - 0.01
    eq(OA.day(), 6)
end)

test("the cure serum waits out its purchase interval", function()
    local r = record(1)
    local e = find("cure_serum")
    eq(S.available(e, r), 1)
    TEST.hours = 100
    S.bought(e, r, 1)
    local n, why, opens = S.available(e, r)
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_Interval")
    near(opens, 100 + 14 * 24)
    TEST.hours = 100 + 14 * 24 - 1
    eq(S.available(e, r), 0)
    TEST.hours = 100 + 14 * 24
    eq(S.available(e, r), 1)
end)

test("trust shortens the interval and widens the order", function()
    local r = record(5, 0)
    local e = find("cure_serum")
    TEST.hours = 100
    S.bought(e, r, 1)
    TEST.hours = 100 + 7 * 24
    eq(S.available(e, r), 1, "7 days at stage 5")
    r = record(5, 1)
    eq(S.available(e, r), 2, "two at a time from the first milestone")
    local d = find("delay_drug")
    r = record(5, 2)
    eq(S.available(d, r), 3, "three delay drugs from the second milestone")
    S.bought(d, r, 3)
    eq(S.available(d, r), 0)
    TEST.hours = TEST.hours + 24
    eq(S.available(d, r), 3, "one day at stage 5")
end)

test("a zero interval means no waiting", function()
    SandboxVars.OperationAcorn.CureSerumInterval = 0
    local r = record(1)
    local e = find("cure_serum")
    S.bought(e, r, 1)
    eq(S.available(e, r), 1)
end)

test("opensAt lists what a tier brings", function()
    local ids = {}
    for _, e in ipairs(S.opensAt(2)) do ids[e.id] = true end
    truthy(ids.petrol_can and ids.bait_trap and ids.team_locker and ids.fabric_cutter and ids.log_saw)
    truthy(not ids.propane_tank)
end)

test("a purchase is remembered with its time", function()
    local r = record(3)
    TEST.hours = 55
    S.bought(find("battery_pack"), r, 2)
    eq(r.shop.last.battery_pack, 55)
    eq(r.shop.week.battery_pack.n, 2)
    eq(S.available(find("battery_pack"), r), 3)
end)

test("a serum bought is also noted to the upgrades part when it is there", function()
    local noted = {}
    OA.Upgrades = { noteBought = function(rec, tree, count) noted[#noted + 1] = { rec = rec, tree = tree, count = count } end }
    local r = record(0)
    S.bought(find("serum_load"), r, 2)
    eq(#noted, 1)
    eq(noted[1].tree, "load"); eq(noted[1].count, 2)
    eq(r.shop.serums.load, 2)
    OA.Upgrades = nil
    S.bought(find("serum_load"), r, 1)
    eq(r.shop.serums.load, 3)
end)
