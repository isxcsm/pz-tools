-- Categories: the letters, the do-not-take list and the judging order.
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Categories"
local OA = OperationAcorn
local C = OA.Categories

local function info(fullType, display, extra)
    local t = { fullType = fullType, baseType = C.baseType(fullType), weight = 1, displayCategory = display }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

test("display categories map to the letters of NUMBERS 12", function()
    eq(C.of(info("Base.Apple", "Food")), "A")
    eq(C.of(info("Base.Shirt", "Clothing")), "B")
    eq(C.of(info("Base.Bag_Satchel", "Bag")), "C")
    eq(C.of(info("Base.Book", "Literature")), "D")
    eq(C.of(info("Base.Teddy", "Teddy Bear")), "E")
    eq(C.of(info("Base.Pan", "Cooking")), "F")
    eq(C.of(info("Base.Radio", "Electronics")), "G")
    eq(C.of(info("Base.Hammer", "Tool")), "H")
    eq(C.of(info("Base.Pills", "FirstAid")), "I")
    eq(C.of(info("Base.Bat", "Weapon")), "J")
    eq(C.of(info("Base.Screws", "Material")), "K")
    eq(C.of(info("Base.Paint", "Paint")), "K")
end)

test("an unknown display category is E, a missing one too", function()
    eq(C.of(info("Mod.Thing", "SomethingNew")), "E")
    eq(C.of(info("Mod.Thing", nil)), "E")
end)

test("the do-not-take list gives its reasons", function()
    local cat, why = C.of(info("Base.Bullets9mm", "Ammo"))
    eq(cat, nil); eq(why, "Ammo")
    eq(select(2, C.of(info("Base.Bag_AmmoBox_9mm", "Container"))), "Ammo", "ammo bag by id")
    eq(select(2, C.of(info("Base.AmmoStraps", "Container"))), "Ammo")
    eq(select(2, C.of(info("Base.Bag_ProtectiveCaseBulkyAmmo_556", "Bag"))), "Ammo")
    eq(select(2, C.of(info("Base.Molotov", "Explosives"))), "Explosive")
    eq(select(2, C.of(info("Base.Sofa", "Furniture", { moveable = true }))), "Furniture")
    eq(select(2, C.of(info("Base.Chair", "Household", { moveable = true }))), "Furniture", "moveable beats the category")
    eq(select(2, C.of(info("Base.Log", "Material"))), "Nature")
    eq(select(2, C.of(info("Base.Twigs", "Material"))), "Nature")
    eq(select(2, C.of(info("Base.Dung_Cow", "Junk"))), "AnimalPart")
    eq(select(2, C.of(info("Base.Steak", "AnimalPart"))), "AnimalPart")
    eq(select(2, C.of(info("Base.Bandage_Wound", "Bandage"))), "Body")
    eq(select(2, C.of(info("Base.ZedDmg_Cut", "ZedDmg"))), "Body")
    eq(select(2, C.of(info("Base.LargeMeteorite", "Memento"))), "Meteor")
    eq(select(2, C.of(info("Base.Hammer", "Tool", { bought = true }))), "Bought")
end)

test("the id lists name vanilla items only", function()
    eq(C.of(info("SomeMod.Log", "Material")), "K", "another mod's Log is judged by its category")
    eq(C.of(info("SomeMod.Bag_AmmoBox_X", "Bag")), "C")
end)

test("cash and the mod's goods are judged before the category", function()
    -- Vanilla Money is Junk (E): the cash rule has to come first.
    local cat, why = C.of(info("Base.Money", "Junk", { cash = 1 }))
    eq(cat, nil); eq(why, "Cash")
    eq(select(2, C.of(info("OperationAcorn.SampleBundle", "Junk", { own = "SampleBundle" }))), "Own")
end)

test("colour variants share a base type", function()
    eq(C.baseType("Base.Hat_BaseballCapTINT"), "Hat_BaseballCap")
    eq(C.baseType("Base.Trousers_Shellsuit_TINT"), "Trousers_Shellsuit")
    eq(C.baseType("Base.Hat_BaseballCapTINT_Reverse"), "Hat_BaseballCap_Reverse")
    eq(C.baseType("Base.Apple"), "Apple")
    eq(C.baseType("Mod.Apple"), "Mod.Apple")
end)

test("units per weight", function()
    eq(C.UNIT.A, 250); eq(C.UNIT.G, 600); eq(C.UNIT.K, 150)
    eq(#C.LETTERS, 11)
end)

test("what counts as loot for the codex", function()
    truthy(C.isLoot(info("Base.Apple", "Food")))
    truthy(C.isLoot(info("Base.Bullets9mm", "Ammo")), "ammo is loot (just not taken)")
    truthy(not C.isLoot(info("Base.ZedDmg_Cut", "ZedDmg")))
    truthy(not C.isLoot(info("Base.Hammer", "Tool", { bought = true })))
    truthy(not C.isLoot(info("OperationAcorn.X", "Tool", { own = "X" })))
end)
