-- Gear: the kit numbers (NUMBERS 7), the target keys the shop uses, and the item scripts of the gear package against the
-- numbers of the docs and the vanilla scripts they are modelled on.
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Gear/Rules"
local OA = OperationAcorn
local R = OA.Gear.Rules

local SCRIPT = "OperationAcorn/42/media/scripts/OA_gear.txt"

-- The body of an item of the gear script as a table of its properties.
local function item(name)
    local text = readfile(SCRIPT)
    truthy(text, "the gear script is there")
    local body = string.match(text, "item%s+" .. name .. "%s*(%b{})")
    truthy(body, "item " .. name)
    local props = {}
    -- only the top level: a nested block (the fluid container) is cut out first
    local flat = string.gsub(body, "component%s+%w+%s*%b{}", "")
    for key, value in string.gmatch(flat, "([%w_]+)%s*=%s*([^,\n]+)") do props[key] = value end
    props.body = body
    return props
end

test("capacity: a tenth of the original per kit, rounded once", function()
    eq(R.capacity(28, 0), 28)
    eq(R.capacity(28, 1), 31)       -- 30.8
    eq(R.capacity(28, 2), 34)       -- 33.6
    eq(R.capacity(35, 1), 39)       -- 38.5 rounds up
    eq(R.capacity(35, 5), 53)       -- 52.5
    eq(R.capacity(8, 1), 9)         -- 8.8
    eq(R.extra(35, 5), 18)
    eq(R.capacity(100, 3), 130)
end)

test("the count, not the value so far, makes the capacity: no rounding builds up", function()
    local base = 8
    local walked = base
    for n = 1, 10 do
        walked = R.capacity(base, n)
        eq(walked, math.floor(base * (1 + 0.1 * n) + 0.5), "kit " .. n)
    end
    eq(R.capacity(base, 10), 16)
end)

test("weight reduction approaches 95 and fills a fifth of the gap per kit", function()
    near(R.reduction(85, 0), 85)
    near(R.reduction(85, 1), 87)
    near(R.reduction(85, 2), 88.6)
    near(R.reduction(85, 3), 89.88, 1e-9)
    eq(R.reductionInt(85, 1), 87)
    eq(R.reductionInt(85, 2), 89)
    truthy(R.reduction(85, 60) < 95, "it never reaches 95")
    eq(R.reductionInt(85, 200), 95)
    near(R.reduction(0, 1), 19)
    near(R.reduction(95, 4), 95)
    near(R.reduction(98, 4), 98, 1e-9, "a bag already past 95 is left alone")
end)

test("the vanilla limits", function()
    eq(R.bagLimit(2), 48)
    eq(R.bagLimit(1.5), 48)          -- 48.5 truncates
    eq(R.bagLimit(0.2), 49)
    eq(R.VEHICLE_LIMIT, 1000)
end)

test("the raw capacity: the original with the API, cut at the limit without it", function()
    eq(R.raw(35, 39, 48, true), 35)
    eq(R.raw(35, 39, 48, false), 39)
    eq(R.raw(35, 53, 48, false), 48)
    eq(R.raw(60, 66, 48, false), 60, "never below the original")
    eq(R.cut(53, 48, false), true)
    eq(R.cut(53, 48, true), false)
    eq(R.cut(39, 48, false), false)
end)

test("engine values: a tenth of the power and a twentieth of the loudness per kit", function()
    eq(R.engine(140, 0, R.POWER_STEP), 140)
    eq(R.engine(140, 1, R.POWER_STEP), 154)
    eq(R.engine(140, 3, R.POWER_STEP), 182)
    eq(R.engine(37, 1, R.LOUDNESS_STEP), 39)     -- 38.85
    eq(R.engine(37, 2, R.LOUDNESS_STEP), 41)     -- 40.7
    eq(R.engine(37, 10, R.LOUDNESS_STEP), 56)    -- 55.5
end)

test("the loudness argument stores back as the loudness wanted (the game stores (int)(given * 0.37037036))", function()
    for stored = 1, 400 do
        local given = R.loudnessArgument(stored)
        local back = math.floor(given * R.LOUDNESS_SCALE)
        eq(back, stored, "stored " .. stored)
    end
end)

test("the kit kinds are the shop's, with the type names it delivers", function()
    for _, kind in ipairs(OA.Shop.KIT_ORDER) do
        local fullType = R.kitType(kind)
        truthy(fullType, kind .. " has a kit type")
        eq(R.kindOf(fullType), kind)
        truthy(R.SCOPE[kind], kind .. " has a scope")
    end
    eq(R.kitType("bagCapacity"), "OperationAcorn.KitBagCapacity")
    eq(R.kitType("engine"), "OperationAcorn.KitEngine")
    eq(R.kindOf("Base.Hammer"), nil)
    eq(R.SCOPE.bagCapacity, "bag"); eq(R.SCOPE.bagWeight, "bag"); eq(R.SCOPE.trunk, "vehicle"); eq(R.SCOPE.engine, "vehicle")
end)

test("every good the shop names for this package is an item of the gear script", function()
    local T = OA.Shop.TYPES
    for _, key in ipairs({ "backpack", "fuelMk1", "fuelMk2", "fuelMk3",
        "kitBagCapacity", "kitBagWeight", "kitTrunk", "kitEngine" }) do
        local name = string.match(T[key], "^OperationAcorn%.(%w+)$")
        truthy(name, key .. " is of this mod")
        item(name)
    end
end)

test("the research backpack: 35 capacity, 85 weight reduction, webbing hangers (NUMBERS 7)", function()
    local p = item("TeamBackpack")
    eq(p.Capacity, "35"); eq(p.WeightReduction, "85")
    eq(p.AttachmentsProvided, "WebbingLeft;WebbingRight")
    eq(p.AttachmentReplacement, "Bag")
    eq(p.ClothingItem, "OA_Bag_ResearchPack")
    eq(p.ReplaceInPrimaryHand, "OA_Bag_ResearchPack_RHand holdingbagright")
    eq(p.ReplaceInSecondHand, "OA_Bag_ResearchPack_LHand holdingbagleft")
    eq(p.CanBeEquipped, "base:back")
    eq(p.ItemType, "base:container")
    truthy(string.find(p.WorldStaticModel, "OA_ResearchPack_Ground", 1, true))
    -- the model is defined, and the clothing items are files the game can find
    truthy(string.find(readfile("OperationAcorn/42/media/scripts/OA_backpack_models.txt"), "model OA_ResearchPack_Ground", 1, true))
    for _, name in ipairs({ "OA_Bag_ResearchPack", "OA_Bag_ResearchPack_LHand", "OA_Bag_ResearchPack_RHand" }) do
        local xml = readfile("OperationAcorn/42/media/clothing/clothingItems/" .. name .. ".xml")
        truthy(xml, name .. ".xml")
        local guid = string.match(xml, "<m_GUID>([^<]+)</m_GUID>")
        truthy(guid and string.find(readfile("OperationAcorn/42/media/fileGuidTable.xml"), guid, 1, true), name .. " has a guid in the table")
    end
end)

test("the fuel cans: the vanilla petrol can with a 15, 20 and 25 litre tank and the same empty weight", function()
    -- PetrolCan (media/scripts/generated/items/normal.txt): weight 1.6, tag base:petrol, Capacity = 10.0
    for name, litres in pairs({ FuelCanMk1 = "15.0", FuelCanMk2 = "20.0", FuelCanMk3 = "25.0" }) do
        local p = item(name)
        eq(p.Weight, "1.6", name .. " weight")
        eq(p.ItemType, "base:normal")
        truthy(string.find(p.Tags, "base:petrol", 1, true), name .. " keeps the petrol tag")
        truthy(string.find(p.body, "component FluidContainer", 1, true), name .. " has the fluid container")
        eq(string.match(p.body, "Capacity%s*=%s*([%d%.]+)"), litres, name .. " capacity")
        truthy(string.find(p.body, "fluid = Petrol:1.0", 1, true), name .. " holds petrol")
    end
end)

test("the kits are real items with their icons", function()
    local icons = {}
    for _, f in ipairs(listfiles("OperationAcorn/42/media/textures")) do icons[f] = true end
    local text = readfile(SCRIPT)
    local count = 0
    for name in string.gmatch(text, "\n    item (%w+)") do
        local p = item(name)
        local icon = string.match(p.Icon or "", "^OA_(%w+)$")
        truthy(icon, name .. " has an OA_ icon")
        truthy(icons["Item_OA_" .. icon .. ".png"], name .. " icon Item_OA_" .. icon .. ".png exists")
        count = count + 1
    end
    eq(count, 8)
    eq(item("KitBagCapacity").Icon, "OA_BagCapacityKit")
    eq(item("KitBagWeight").Icon, "OA_BagWeightKit")
    eq(item("KitTrunk").Icon, "OA_TrunkKit")
    eq(item("KitEngine").Icon, "OA_EngineTuningKit")
    eq(item("TeamBackpack").Icon, "OA_ResearchBackpack")
end)

test("the work of fitting a kit: bags a fixed time, vehicles faster with mechanics, never under 40 percent", function()
    eq(R.workTicks("bag"), 240)
    eq(R.workTicks("bagWeight", 10), 240)
    eq(R.workTicks("trunk", 0), 500)
    eq(R.workTicks("engine", 0), 700)
    eq(R.workTicks("trunk", 5), 400)      -- 80 percent
    eq(R.workTicks("engine", 10), 420)    -- 60 percent
    eq(R.workTicks("trunk", 15), 200)     -- 40 percent, the least
    eq(R.workTicks("engine", nil), 700)
end)
