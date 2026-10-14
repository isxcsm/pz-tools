-- Shred: half a sample bundle per weight, repeat decay, the extras cap, the first-shred bonus.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Shred"
local OA = OperationAcorn
local Sh = OA.Shred

local function thing(name, weight, display, extra)
    local t = { fullType = "Base." .. name, baseType = name, weight = weight, displayCategory = display or "Junk" }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

local function record()
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    return OA.Store.ensure("s", "S")
end

test("half a sample bundle for every weight", function()
    local r = record()
    near((Sh.yield(thing("Pencil", 0.2), r)), 0.1, 1e-9)
    near((Sh.yield(thing("Pan", 1.0, "Cooking"), r)), 0.5, 1e-9)
    near((Sh.yield(thing("Anvil", 12.0, "Tool"), r)), 6.0, 1e-9)
    near((Sh.yield(thing("Ghost", 0), r)), 0)
end)

test("the state of the thing does not matter", function()
    local r = record()
    near((Sh.yield(thing("Radio", 1.0, "Electronics", { condition = 0 }), r)), 0.5, 1e-9)
end)

test("rotten food gives half", function()
    local r = record()
    near((Sh.yield(thing("Steak", 1.0, "Food", { food = "rotten" }), r)), 0.25, 1e-9)
    near((Sh.yield(thing("Steak", 1.0, "Food", { food = "fresh" }), r)), 0.5, 1e-9)
end)

test("repeats decay: 1 / (1 + c / 50)", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")
    near((Sh.yield(pan, r, nil, 0)), 0.5, 1e-9)
    near((Sh.yield(pan, r, nil, 50)), 0.25, 1e-9, "50 recent shreds halve it")
    near((Sh.yield(pan, r, nil, 150)), 0.125, 1e-9)
    SandboxVars.OperationAcorn.ShredDecayMultiplier = 0.2
    near((Sh.yield(pan, r, nil, 10)), 0.25, 1e-9, "the option scales the half point")
end)

test("five a day halve the yield in the long run", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")
    -- Each day shreds 5 more; the counts decay by 0.9 a day. The steady count is 5 / (1 - 0.9) = 50.
    for day = 0, 79 do
        TEST.hours = day * 24 + 1
        Sh.commit(r, pan, 5)
    end
    TEST.hours = 79 * 24 + 1
    near(Sh.count(r, "Pan"), 50, 0.5)
    near((Sh.yield(pan, r)), 0.25, 0.005)
end)

test("the daily decay is 0.9", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")
    Sh.commit(r, pan, 10)
    near(Sh.count(r, "Pan"), 10, 1e-9)
    TEST.hours = 24 * 2
    near(Sh.count(r, "Pan"), 10 * 0.9 ^ OA.day(), 1e-9)
    TEST.hours = 24 * 40
    truthy(Sh.count(r, "Pan") < 0.5)
end)

test("extras add up and cannot pass the base", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")               -- base 0.5
    near((Sh.yield(pan, r, { bundles = 0.1 })), 0.6, 1e-9)
    near((Sh.yield(pan, r, { bundles = 0.3 })), 0.8, 1e-9)
    near((Sh.yield(pan, r, { board = 5 })), 0.6, 1e-9, "0.02 per point")
    near((Sh.yield(pan, r, { blade = 1.2 })), 0.6, 1e-9, "base * 0.2")
    near((Sh.yield(pan, r, { bundles = 0.3, board = 5, blade = 1.2 })), 1.0, 1e-9, "0.3 + 0.1 + 0.1 = 0.5, exactly the cap")
    near((Sh.yield(pan, r, { bundles = 0.3, board = 100, blade = 1.2 })), 1.0, 1e-9, "never more than twice the base")
    local light = thing("Pencil", 0.2)                      -- base 0.1
    near((Sh.yield(light, r, { bundles = 0.3 })), 0.2, 1e-9, "a light thing cannot make many bundles")
end)

test("the cap works on the base after the decay", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")
    near((Sh.yield(pan, r, { bundles = 0.3 }, 50)), 0.5, 1e-9, "base 0.25, extra capped at 0.25")
end)

test("carry gives the whole bundles and keeps the rest on the record", function()
    local r = record()
    eq(Sh.carry(r, 0.5), 0, "half a bundle: none yet")
    eq(Sh.carry(r, 0.75), 1, "with the half kept: one, a quarter kept")
    near(r.shred.rest, 0.25, 1e-9)
    eq(Sh.carry(r, 2.75), 3)
    near(r.shred.rest, 0, 1e-9)
    eq(Sh.carry(r, 0), 0)
    eq(Sh.carry(r, -1), 0, "nothing negative")
end)

test("ten pencils make one bundle, two pans one", function()
    local r = record()
    local made = 0
    for _ = 1, 10 do made = made + Sh.carry(r, (Sh.yield(thing("Pencil", 0.2), r, nil, 0))) end
    eq(made, 1)
    made = 0
    for _ = 1, 2 do made = made + Sh.carry(r, (Sh.yield(thing("Pan", 1.0, "Cooking"), r, nil, 0))) end
    eq(made, 1)
end)

test("the first shred of a kind pays 200 and enters the codex", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")
    local _, bonus = Sh.yield(pan, r)
    eq(bonus, 200)
    local paid = Sh.commit(r, pan, 1)
    eq(paid, 200)
    near(r.trade.bonus, 200 + 100, 1e-9, "200 for the shred and 100 for a new kind")
    truthy(r.codex.kinds.Pan)
    _, bonus = Sh.yield(pan, r)
    eq(bonus, 0)
    eq(Sh.commit(r, pan, 1), 0)
    near(r.trade.bonus, 300, 1e-9)
end)

test("a kind already in the codex pays only the shred bonus", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")
    OA.Codex.acquire(r, pan)
    near(r.trade.bonus, 100)
    Sh.commit(r, pan, 1)
    near(r.trade.bonus, 300)
end)

test("the first shred bonus follows BonusMultiplier", function()
    SandboxVars.OperationAcorn.BonusMultiplier = 2.0
    local r = record()
    eq(Sh.commit(r, thing("Pan", 1.0, "Cooking"), 1), 400)
end)

test("a batch of the same kind decays as it goes", function()
    local r = record()
    local pan = thing("Pan", 1.0, "Cooking")
    local total, bonus = Sh.yieldMany(pan, r, 3)
    near(total, 0.5 + 0.5 / (1 + 1 / 50) + 0.5 / (1 + 2 / 50), 1e-9)
    eq(bonus, 200)
    local expected = 0
    for i = 0, 99 do expected = expected + 0.5 / (1 + i / 50) end
    near((Sh.yieldMany(pan, r, 100)), expected, 1e-9)
end)

test("what can be shredded", function()
    truthy(Sh.can(thing("Shirt", 0.5, "Clothing")))
    truthy(Sh.can(thing("Steak", 0.5, "Food", { food = "rotten" })))
    truthy(Sh.can(thing("Battery", 0.1, "Electronics", { condition = 0 })))
    truthy(Sh.can(thing("Shotgun", 3, "Weapon")))
    truthy(Sh.can(thing("Satchel", 0.5, "Bag", { filled = false })))
    local ok, why = Sh.can(thing("Satchel", 0.5, "Bag", { filled = true }))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Filled")
    ok, why = Sh.can(thing("Screws", 0.1, "Material"))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Material")
    ok, why = Sh.can(thing("Bullets9mm", 0.01, "Ammo"))
    eq(ok, false); eq(why, "IGUI_OA_Econ_Reject_Ammo")
    ok = Sh.can(thing("Grenade", 0.5, "Explosives"))
    eq(ok, false)
    ok = Sh.can(thing("Claw", 0.5, "AnimalPartWeapon"))
    eq(ok, false)
    ok = Sh.can(thing("Sofa", 20, "Furniture", { moveable = true }))
    eq(ok, false)
    ok = Sh.can(thing("Money", 0.01, "Junk", { cash = 1 }))
    eq(ok, false)
    ok = Sh.can(thing("Hammer", 1, "Tool", { bought = true }))
    eq(ok, false)
    ok = Sh.can(thing("X", 1, "Tool", { own = "SampleBundle" }))
    eq(ok, false)
    ok = Sh.can(thing("Meat", 1, "AnimalPart"))
    eq(ok, false)
end)

test("the daily upkeep drops counts that decayed away", function()
    local r = record()
    Sh.commit(r, thing("Pan", 1.0, "Cooking"), 1)
    TEST.hours = 24 * 60
    Sh.daily(r)
    eq(r.shred.counts.Pan, nil)
    truthy(r.shred.first.Pan, "the first-shred mark stays")
end)
