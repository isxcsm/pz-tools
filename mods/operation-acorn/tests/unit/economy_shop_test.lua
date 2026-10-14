-- Shop: the catalog, prices, the unlock tiers, the weekly limits, the serum and kit prices.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
local S = OA.Shop

-- A record at a stage with the flight support levels trust alone used to give there (the discount is an upgrade now),
-- or the levels it is given.
local function record(stage, milestones, credits, levels)
    local r = OA.Store.ensure("s", "S")
    r.trade = { credits = credits or 100000, trust = 0, stage = stage or 0, milestones = milestones or 0,
        bonus = 0, sharedSerums = 0,
        levels = levels or OA.Support.levelsForTier((stage or 0) + (milestones or 0)) }
    OA.Trust.reset()
    return r
end

local function find(id)
    local e = S.entry(id)
    truthy(e, "entry " .. id)
    return e
end

test("every NUMBERS 7 price is in the catalog", function()
    local expect = {
        cure_serum = { 500000, 5 }, reversal = { 50000, 1 }, delay_long = { 20000, 0 }, delay_drug = { 5000, 0 },
        test_kit = { 2000, 0 }, battery_pack = { 4000, 1 }, seed_pack = { 3000, 1 },
        petrol_can = { 15000, 2 }, scrap_pack = { 6000, 2 }, propane_tank = { 25000, 3 }, car_battery = { 20000, 3 },
        car_part_normal = { 10000, 3 }, engine_parts = { 20000, 3 }, car_part_modern = { 25000, 5 },
        ammo_pistol = { 40000, 4 }, ammo_shotgun = { 50000, 4 }, ammo_rifle = { 60000, 4 },
        team_backpack = { 300000, 5 }, shred_bench = { 5000, 0 }, bait_trap = { 12000, 2 }, team_locker = { 60000, 2 },
        team_crate = { 15000, 2 }, nails_box = { 8000, 1 }, screws_box = { 8000, 1 }, nuts_bolts = { 15000, 2 },
        welding_rods = { 12000, 2 }, team_welding_mask = { 40000, 3 },
        light_screwdriver = { 20000, 2 }, light_hammer = { 30000, 2 }, light_saw = { 30000, 2 },
        light_wrench = { 25000, 2 }, light_lug_wrench = { 25000, 2 }, light_crowbar = { 35000, 3 },
        light_shovel = { 35000, 3 }, light_wood_axe = { 45000, 3 }, light_pickaxe = { 45000, 3 },
        light_sledgehammer = { 60000, 4 },
        fabric_cutter = { 80000, 2 }, log_saw = { 100000, 2 }, rain_cistern = { 90000, 3 },
        bulk_shredder = { 150000, 3 }, propane_refinery = { 200000, 3 }, oil_refinery = { 250000, 4 },
        box_reissue = { 10000, 0 },
        motor_normal = { 25000, 3 }, motor_modern = { 60000, 5 }, shred_blade_normal = { 15000, 3 },
        shred_blade_modern = { 40000, 5 }, cut_blade_normal = { 10000, 3 }, cut_blade_modern = { 25000, 5 },
        saw_blade_normal = { 15000, 3 }, saw_blade_modern = { 40000, 5 }, filter_normal = { 20000, 3 },
        filter_modern = { 50000, 5 }, soundproof_cover = { 30000, 3 },
        fuelcan_mk1 = { 20000, 2 }, fuelcan_mk2 = { 45000, 4 }, fuelcan_mk3 = { 90000, 5 },
        kit_bagCapacity = { 40000, 6 }, kit_bagWeight = { 50000, 6 }, kit_storage = { 60000, 6 }, kit_engine = { 80000, 6 },
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
    eq(#find("team_backpack").give, 1, "the backpack alone: its water storage is built in")
    eq(find("team_backpack").give[1].type, "OperationAcorn.TeamBackpack")
    eq(find("team_welding_mask").give[1].type, "OperationAcorn.TeamWeldingMask")
    eq(find("light_lug_wrench").give[1].type, "OperationAcorn.LightLugWrench")
    eq(find("light_lug_wrench").group, "gear")
    eq(find("petrol_can").give[1].fluid, "Petrol")
    truthy(find("fuelcan_mk1").give[1].empty)
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

test("the discount is an upgrade: the stage alone gives none", function()
    local r = record(5, 2, nil, {})
    eq(S.price(find("battery_pack"), r), 4000)
    r = record(5, 2, nil, { discount = 1 })
    eq(S.price(find("battery_pack"), r), 3800, "level 1 is 5% off")
    r = record(5, 2, nil, { discount = 2 })
    eq(S.price(find("battery_pack"), r), 3600, "level 2 is 10% off")
end)

test("the cure serum price is the mod's, times its option", function()
    eq(S.price(find("cure_serum"), record(0)), 500000)
    SandboxVars.OperationAcorn.CureSerumPriceMultiplier = 0.1
    eq(S.price(find("cure_serum"), record(0)), 50000)
end)

test("the serum shelf: five infection items in the serum group, special and days as designed", function()
    local want = { cure_serum = "cure", reversal = "reversal", delay_long = "delay", test_kit = "test", delay_drug = "delay" }
    for id, special in pairs(want) do
        local e = find(id)
        eq(e.group, "serum", id .. " group")
        eq(e.special, special, id .. " special")
        eq(e.fixed, true, id .. " is fixed")
        eq(S.fieldOnly(e), false, id .. " is ordered at the crude terminal too")
    end
    eq(find("delay_long").days, 7)
    eq(find("delay_drug").days, 1)
    eq(find("reversal").give[1].type, "OperationAcorn.InfectionReversal")
    eq(find("test_kit").give[1].type, "OperationAcorn.InfectionTestKit")
    eq(find("delay_long").give[1].type, "OperationAcorn.DelayDrugLong")
end)

test("the infection medicines ignore the multiplier and the discount", function()
    SandboxVars.OperationAcorn.ShopPriceMultiplier = 2.0
    local r = record(5, 2, nil, { discount = 2 })
    eq(S.price(find("cure_serum"), r), 500000)
    eq(S.price(find("reversal"), r), 50000)
    eq(S.price(find("delay_long"), r), 20000)
    eq(S.price(find("delay_drug"), r), 5000)
    eq(S.price(find("test_kit"), r), 2000)
end)

test("the shelf opens as designed: the reversal at the first stage, the cure at the fifth, the rest from the start", function()
    local r = record(0)
    for _, id in ipairs({ "delay_long", "delay_drug", "test_kit" }) do truthy(S.available(find(id), r) > 0, id) end
    for _, id in ipairs({ "cure_serum", "reversal" }) do
        local n, why = S.available(find(id), r)
        eq(n, 0, id); eq(why, "IGUI_OA_Econ_Shop_Locked")
    end
    r = record(1)
    truthy(S.available(find("reversal"), r) > 0)
    eq(S.available(find("cure_serum"), record(4)), 0, "not yet at the fourth")
    truthy(S.available(find("cure_serum"), record(5)) > 0)
end)

test("serums and the box ignore the multiplier and the discount", function()
    SandboxVars.OperationAcorn.ShopPriceMultiplier = 2.0
    local r = record(5, 2)
    eq(S.price(find("serum_scout"), r), 8000)
    eq(S.price(find("box_reissue"), r), 10000)
    SandboxVars.OperationAcorn.BoxReissueCostMultiplier = 0.7
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
    SandboxVars.OperationAcorn.UpgradeSerumPriceMultiplier = 2
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

test("serum growth scales with its option", function()
    SandboxVars.OperationAcorn.UpgradeSerumGrowthMultiplier = 0
    eq(S.serumPriceAt(20), 8000)
end)

test("a kit's price stays the same however many are bought", function()
    -- At the first milestone the 5% discount of stage 4 is on.
    local r = record(5, 1)
    eq(S.price(find("kit_bagCapacity"), r), 38000)
    S.bought(find("kit_bagCapacity"), r, 3)
    eq(S.price(find("kit_bagCapacity"), r), 38000)
end)

test("kit prices take the multiplier and the discount", function()
    SandboxVars.OperationAcorn.ShopPriceMultiplier = 2.0
    local r = record(5, 2)
    eq(S.price(find("kit_engine"), r), OA.round(80000 * 2.0 * 0.9))
end)

test("tiers lock and unlock entries", function()
    local r = record(0)
    local n, why = S.available(find("cure_serum"), r)
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_Locked")
    n = S.available(find("delay_drug"), r)
    truthy(n > 0)
    r = record(1)
    truthy(S.available(find("reversal"), r) > 0)
    n, why = S.available(find("propane_tank"), r)
    eq(n, 0)
    r = record(3)
    truthy(S.available(find("propane_tank"), r) > 0)
    n = S.available(find("kit_storage"), record(5, 0))
    eq(n, 0)
    truthy(S.available(find("kit_storage"), record(5, 1)) > 0)
end)

test("kits can be switched off", function()
    SandboxVars.OperationAcorn.KitsForSale = false
    local n, why = S.available(find("kit_storage"), record(5, 1))
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_KitsOff")
    eq(#S.opensAt(6), 0, "the kits are the only goods of the first milestone")
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

test("cure serums and delay drugs have no purchase interval and no count limit", function()
    local r = record(5)
    local cure, delay = find("cure_serum"), find("delay_drug")
    for _, id in ipairs({ "reversal", "delay_long", "test_kit" }) do eq(S.available(find(id), r), 99, id) end
    eq(S.available(cure, r), 99)
    eq(S.available(delay, r), 99)
    TEST.hours = 100
    S.bought(cure, r, 1)
    S.bought(delay, r, 3)
    eq(S.available(cure, r), 99, "bought at once again")
    eq(S.available(delay, r), 99)
    S.bought(cure, r, 5)
    local n, why = S.available(cure, r)
    eq(n, 99); eq(why, nil)
    eq(S.available(cure, record(5, 3)), 99, "the same at a high tier")
end)

test("the cure serum and the delay drug still need the tier, stock and no debt", function()
    local n, why = S.available(find("cure_serum"), record(0))
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_Locked")
    n, why = S.available(find("cure_serum"), record(5, 0, -1))
    eq(n, 0); eq(why, "IGUI_OA_Econ_Shop_Debt")
    for _, id in ipairs({ "delay_drug", "delay_long", "reversal", "test_kit" }) do
        n, why = S.available(find(id), record(1, 0, -1))
        eq(n, 0, id); eq(why, "IGUI_OA_Econ_Shop_Debt")
    end
end)

test("rewards no longer carry the serum intervals and counts, and the sandbox options are gone", function()
    local rewards = OA.Trust.rewards(record(5, 3))
    eq(rewards.cureInterval, nil); eq(rewards.cureCount, nil)
    eq(rewards.delayInterval, nil); eq(rewards.delayCount, nil)
    eq(SandboxVars.OperationAcorn.CureSerumInterval, nil)
    eq(SandboxVars.OperationAcorn.DelayDrugInterval, nil)
end)

test("opensAt lists what a tier brings", function()
    local ids = {}
    for _, e in ipairs(S.opensAt(2)) do ids[e.id] = true end
    truthy(ids.petrol_can and ids.bait_trap and ids.team_locker and ids.fabric_cutter and ids.log_saw)
    truthy(not ids.propane_tank)
end)

test("a purchase is remembered by the week, not by its time", function()
    local r = record(3)
    TEST.hours = 55
    S.bought(find("battery_pack"), r, 2)
    eq(r.shop.last, nil, "the time of the last purchase is no longer kept")
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

test("a good whose item is not defined in the scripts is not sold", function()
    local missing = { ["OperationAcorn.TeamBackpack"] = true, ["Base.CarBattery2"] = true }
    getScriptManager = function()
        return { FindItem = function(_, fullType) if missing[fullType] then return nil end return {} end }
    end
    local r = record(5, 1)
    local backpack = find("team_backpack")
    eq(S.stocked(backpack), false)
    local n, why = S.available(backpack, r)
    eq(n, 0)
    eq(why, "IGUI_OA_Econ_Shop_NotStocked")
    eq(S.stocked(find("car_battery")), false, "one of the choices is missing")
    truthy(S.stocked(find("shred_bench")))
    truthy(S.available(find("shred_bench"), r) > 0)
    eq(S.stocked(find("seed_pack")), true, "choices named by a list kind")
    getScriptManager = nil
end)

test("the field terminal is ordered at the second stage for 50,000; the crude terminal orders only some groups", function()
    local field = find("field_terminal")
    eq(field.tier, 2)
    eq(field.price, 50000)
    eq(field.give[1].type, "OperationAcorn.FieldTerminal")
    eq(S.entry("terminal_kit"), nil, "the upgrade kit is gone")
    eq(S.fieldOnly(field), false)
    eq(S.fieldOnly(find("shred_bench")), false)
    eq(S.fieldOnly(find("bait_trap")), false)
    eq(S.fieldOnly(find("battery_pack")), false)
    eq(S.fieldOnly(find("cure_serum")), false)
    eq(S.fieldOnly(find("box_reissue")), false)
    eq(S.fieldOnly(find("team_locker")), true)
    eq(S.fieldOnly(find("motor_normal")), true)
    eq(S.fieldOnly(find("team_backpack")), true)
end)
