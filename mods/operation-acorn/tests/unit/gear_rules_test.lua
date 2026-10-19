-- Gear: the kit numbers (NUMBERS 7), what each kit fits, and the item scripts of the gear package and the field tools
-- against the numbers of the docs and the vanilla scripts they are modelled on.
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Gear/Rules"
local OA = OperationAcorn
local R = OA.Gear.Rules

local SCRIPT = "OperationAcorn/42/media/scripts/OA_gear.txt"

-- The body of an item of the gear script (or another of the mod's scripts) as a table of its properties.
local function item(name, script)
    local text = readfile(script or SCRIPT)
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

test("the team items: two litres, a fifth of the welder's uses, a quarter of a tool's condition per kit", function()
    eq(R.canLitres(12, 0), 12)
    eq(R.canLitres(12, 3), 18)
    near(R.uses(0), 1.2, 1e-9)
    near(R.uses(2), 1.6, 1e-9)
    eq(R.toughness(12, 0), 12)
    eq(R.toughness(12, 1), 15)
    eq(R.toughness(10, 1), 13)          -- 12.5 rounds up
    eq(R.toughness(12, 4), 24)
    eq(R.toughness(12, 9), 24, "no more than its most kits")
end)

test("a lightening kit takes a fifth of what is left above 40 percent of the script's weight", function()
    near(R.lightness(0), 1, 1e-12)
    near(R.lightness(1), 0.88, 1e-12)
    near(R.lightness(2), 0.784, 1e-12)
    truthy(R.lightness(50) > 0.4, "it never reaches the floor")
    for n = 0, 6 do near(1 / (1 + R.efficiency(n)), R.lightness(n), 1e-12, "the efficiency weighs the same, kit " .. n) end
    near(R.efficiency(0), 0, 1e-12)
end)

test("what each kit fits", function()
    truthy(R.fits("capacity", "bag")); truthy(R.fits("capacity", "can")); truthy(R.fits("capacity", "welder"))
    truthy(R.fits("capacity", "storage"))
    eq(R.fits("capacity", "tool"), false)
    truthy(R.fits("lightening", "bag")); truthy(R.fits("lightening", "tool")); truthy(R.fits("lightening", "welder"))
    eq(R.fits("lightening", "storage"), false)
    truthy(R.fits("reinforcement", "tool"))
    eq(R.fits("reinforcement", "bag"), false)
    truthy(R.fits("engine", "engine"))
    eq(R.fits("engine", "bag"), false)
    eq(R.fits("capacity", nil), false)
    eq(R.fits("nonsense", "bag"), false)
    truthy(R.onItems("capacity")); truthy(R.onItems("lightening")); truthy(R.onItems("reinforcement"))
    eq(R.onItems("engine"), false)
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
        truthy(R.TARGETS[kind], kind .. " has targets")
    end
    eq(R.kitType("capacity"), "OperationAcorn.KitCapacity")
    eq(R.kitType("lightening"), "OperationAcorn.KitLightening")
    eq(R.kitType("reinforcement"), "OperationAcorn.KitReinforcement")
    eq(R.kitType("engine"), "OperationAcorn.KitEngine")
    eq(R.kindOf("Base.Hammer"), nil)
end)

test("every good the shop names for this package is an item of the gear script", function()
    local T = OA.Shop.TYPES
    for _, key in ipairs({ "backpack", "waistBag", "waistBagBack", "fuelCan", "weldingMask",
        "kitCapacity", "kitLightening", "kitReinforcement", "kitEngine" }) do
        local name = string.match(T[key], "^OperationAcorn%.(%w+)$")
        truthy(name, key .. " is of this mod")
        item(name)
    end
    eq(T.welder, "Base.BlowTorch", "the welder is the game's own torch")
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

test("the waist bag: worn front or back, the two sides the same bag", function()
    local front, back = item("TeamWaistBagFront"), item("TeamWaistBagBack")
    eq(front.ClothingItemExtra, "OperationAcorn.TeamWaistBagBack")
    eq(back.ClothingItemExtra, "OperationAcorn.TeamWaistBagFront")
    eq(front.BodyLocation, "base:fannypackfront"); eq(back.BodyLocation, "base:fannypackback")
    for _, key in ipairs({ "Capacity", "WeightReduction", "Weight", "RunSpeedModifier", "Icon", "WorldStaticModel" }) do
        eq(front[key], back[key], key .. " the same either way")
    end
    eq(front.Capacity, "6"); eq(front.WeightReduction, "85")
    truthy(string.find(readfile("OperationAcorn/42/media/scripts/OA_waistbag_models.txt"), "model OA_ResearchWaist_Ground", 1, true))
    for _, name in ipairs({ "OA_Bag_ResearchWaistFront", "OA_Bag_ResearchWaistBack" }) do
        local xml = readfile("OperationAcorn/42/media/clothing/clothingItems/" .. name .. ".xml")
        truthy(xml, name .. ".xml")
        local guid = string.match(xml, "<m_GUID>([^<]+)</m_GUID>")
        truthy(guid and string.find(readfile("OperationAcorn/42/media/fileGuidTable.xml"), guid, 1, true), name .. " has a guid in the table")
    end
end)

test("the fuel can: the vanilla petrol can with a 12 litre tank and the same empty weight", function()
    -- PetrolCan (media/scripts/generated/items/normal.txt): weight 1.6, tag base:petrol, Capacity = 10.0
    local p = item("TeamFuelCan")
    eq(p.Weight, "1.6")
    eq(p.ItemType, "base:normal")
    truthy(string.find(p.Tags, "base:petrol", 1, true), "it keeps the petrol tag")
    eq(string.match(p.body, "Capacity%s*=%s*([%d%.]+)"), "12.0")
    truthy(string.find(p.body, "fluid = Petrol:1.0", 1, true), "it holds petrol")
    local models = readfile("OperationAcorn/42/media/scripts/OA_fuelcan_models.txt")
    truthy(string.find(models, "model OA_TeamFuelCan\n", 1, false) or string.find(models, "model OA_TeamFuelCan", 1, true))
    eq(string.find(models, "Mk", 1, true), nil, "one can, no marks")
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
    eq(count, 13)
    eq(item("KitCapacity").Icon, "OA_CapacityKit")
    eq(item("KitLightening").Icon, "OA_LighteningKit")
    eq(item("KitReinforcement").Icon, "OA_ReinforcementKit")
    eq(item("KitEngine").Icon, "OA_EngineTuningKit")
    eq(item("KitWeaponDamage").ItemType, "base:normal")
    for _, name in ipairs({ "KitWeaponDamage", "KitWeaponCrit", "KitWeaponRepair" }) do
        eq(item(name).DisplayCategory, "Tool", name)
    end
    eq(item("TeamBackpack").Icon, "OA_ResearchBackpack")
end)

test("the team welding mask is cooler and easier to wear than the vanilla one and welds the same", function()
    local mask = item("TeamWeldingMask")
    eq(mask.Insulation, "0.1")
    eq(mask.WindResistance, "0.3")
    eq(mask.DiscomfortModifier, "0.05")
    eq(mask.VisionModifier, "0.5")
    eq(mask.BodyLocation, "base:maskfull")
    eq(mask.ClothingItem, "OA_Hat_TeamWelderMask")
    truthy(string.find(mask.Tags, "base:weldingmask", 1, true))
    truthy(readfile("OperationAcorn/42/media/clothing/clothingItems/OA_Hat_TeamWelderMask.xml"))
    truthy(string.find(readfile("OperationAcorn/42/media/fileGuidTable.xml"), "OA_Hat_TeamWelderMask.xml", 1, true))
end)

test("the field tools are the shop's list, each a little lighter and longer lasting than the vanilla tool", function()
    local script = "OperationAcorn/42/media/scripts/OA_field_tools.txt"
    local text = readfile(script)
    local icons = {}
    for _, f in ipairs(listfiles("OperationAcorn/42/media/textures")) do icons[f] = true end
    local inScript = {}
    for name in string.gmatch(text, "\n    item (%w+)") do inScript[name] = true end
    local listed = 0
    for _, t in ipairs(OA.Shop.FIELD_TOOLS) do
        local name = string.match(OA.Shop.fieldType(t[1]), "^OperationAcorn%.(%w+)$")
        truthy(inScript[name], name .. " is in the field tools' script")
        inScript[name] = nil
        local p = item(name, script)
        eq(p.Icon, "OA_" .. name)
        truthy(icons["Item_OA_" .. name .. ".png"], name .. " has its icon")
        eq(p.IconsForTexture, nil, name .. ": one icon")
        eq(p.WeaponSpritesByIndex, nil, name .. ": one model")
        listed = listed + 1
    end
    for name in pairs(inScript) do truthy(false, name .. " is in the script and not in the shop") end
    eq(listed, 45)
    -- spot checks against the vanilla tools (weapon.txt, normal.txt): 0.85 of the weight, 1.2 of the condition
    local hammer = item("FieldHammer", script)
    eq(hammer.Weight, "1.27"); eq(hammer.ConditionMax, "12"); eq(hammer.HeadCondition, "12")
    truthy(string.find(hammer.Tags, "base:hammer", 1, true))
    eq(hammer.WeaponSprite, "OperationAcorn.OA_FieldHammer", "the hammer's grip in the olive")
    local wrench = item("FieldWrench", script)
    eq(wrench.Weight, "0.85"); eq(wrench.ConditionMax, "11")
    eq(wrench.WeaponSprite, "Base.Wrench", "an all-metal tool keeps the vanilla model")
    local lug = item("FieldLugWrench", script)
    eq(lug.ConditionMax, "12", "a tool with the game's default 10")
    eq(item("FieldSledgehammer", script).Weight, "5.1")
    truthy(string.find(text, "model OA_FieldHammer", 1, true), "the olive model is defined")
end)

test("the work of fitting a kit: to an item a fixed time, to a vehicle faster with mechanics, never under 40 percent", function()
    eq(R.workTicks("item"), 240)
    eq(R.workTicks("item", 10), 240)
    eq(R.workTicks("storage", 0), 500)
    eq(R.workTicks("engine", 0), 700)
    eq(R.workTicks("storage", 5), 400)      -- 80 percent
    eq(R.workTicks("engine", 10), 420)    -- 60 percent
    eq(R.workTicks("storage", 15), 200)     -- 40 percent, the least
    eq(R.workTicks("engine", nil), 700)
end)

test("weapon kits: damage a tenth of the original per kit with no most, critical five points per kit with no most", function()
    near(R.damage(1.5, 0), 1.5, 1e-9)
    near(R.damage(1.5, 1), 1.65, 1e-9)
    near(R.damage(2.0, 3), 2.6, 1e-9)
    near(R.damage(0.8, 100), 8.8, 1e-9, "no cap")
    eq(R.crit(20, 0), 20)
    eq(R.crit(20, 1), 25)
    eq(R.crit(0, 4), 20)
    eq(R.crit(35, 50), 285, "no cap")
end)

test("the repair kit puts back a tenth of the most condition rounded up, at least 1, and stops at the most", function()
    eq(R.repairGain(10), 1)
    eq(R.repairGain(11), 2)
    eq(R.repairGain(30), 3, "a decimal tenth of 30 would round up to 4")
    eq(R.repairGain(7), 1, "at least 1")
    eq(R.repairGain(1), 1)
    eq(R.repairGain(0), 1)
    eq(R.repairGain(100), 10)
    eq(R.repaired(5, 10), 6)
    eq(R.repaired(10, 10), 10)
    eq(R.repaired(29, 30), 30, "stops at the most")
    eq(R.repaired(0, 25), 3)
end)

test("the weapon kits are kinds of their own: items by type, fitted to weapons only, not to a vehicle", function()
    eq(R.kitType("weaponDamage"), "OperationAcorn.KitWeaponDamage")
    eq(R.kitType("weaponCrit"), "OperationAcorn.KitWeaponCrit")
    eq(R.kitType("weaponCritDamage"), "OperationAcorn.KitWeaponCritDamage")
    eq(R.kindOf("OperationAcorn.KitWeaponCritDamage"), "weaponCritDamage")
    eq(R.kitType("weaponRepair"), "OperationAcorn.KitWeaponRepair")
    eq(R.kindOf("OperationAcorn.KitWeaponCrit"), "weaponCrit")
    eq(R.kindOf("OperationAcorn.KitCapacity"), "capacity", "the others still found")
    for _, kind in ipairs(R.WEAPON_ORDER) do
        truthy(R.fits(kind, "weapon"), kind)
        truthy(not R.fits(kind, "bag"), kind)
        truthy(R.onItems(kind), kind)
    end
    truthy(not R.fits("capacity", "weapon"))
    truthy(not R.fits("reinforcement", "weapon"))
    local kinds = R.kinds()
    eq(#kinds, #OA.Shop.KIT_ORDER + 4)
    eq(kinds[#kinds], "weaponRepair")
end)
