-- The shop (NUMBERS 7 and 10, REWARDS): the catalog, what each thing costs, what is open and how much of it a record
-- may still buy. Nothing here takes credits or delivers: the trade part orders, charges and delivers, and calls
-- Shop.bought for what it delivered. All numbers are the defaults of the sandbox options.
--
-- An entry: { id, group, tier, price (the base), give = { { type, count, full, fluid, empty } ... } or
-- choices = { { type, count ... } ... } (the player picks one), week = purchases a week (nil: none), special =
-- "cure" | "reversal" | "test" | "delay" (with days) | "serum" | "reissue" | nil, fixed = true (no shop
-- multiplier, no discount), allowDebt, kits = true (only with KitsForSale), item (the item it is named after),
-- descKey (a description shared with other entries) }. A give may carry `mod`, `used` and `name` (Trade.dropSpec).
-- tier is stage + milestones (Trust.tier): 0 the start, 1..5 stages, 6 the first milestone.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Shop = {}
OA.Shop = Shop

-- The item types of this mod's goods. Parts, gear and machines are made by other parts of the mod: a name change
-- is one edit here.
Shop.TYPES = {
    cure = "OperationAcorn.CureSerum", reversal = "OperationAcorn.InfectionReversal",
    delayLong = "OperationAcorn.DelayDrugLong", delay = "OperationAcorn.DelayDrug",
    testKit = "OperationAcorn.InfectionTestKit",
    serumScout = "OperationAcorn.UpgradeSerumScout", serumLoad = "OperationAcorn.UpgradeSerumLoad",
    serumSurvival = "OperationAcorn.UpgradeSerumSurvival",
    box = "OperationAcorn.DeliveryBox",
    shredBench = "OperationAcorn.ShredBench", bulkShredder = "OperationAcorn.BulkShredder",
    cutter = "OperationAcorn.FabricCutter", propaneRefinery = "OperationAcorn.PropaneRefinery",
    oilRefinery = "OperationAcorn.OilRefinery", logSaw = "OperationAcorn.LogSaw",
    locker = "OperationAcorn.TeamLocker", crate = "OperationAcorn.ResearchCrate", cistern = "OperationAcorn.RainCistern",
    bait = "OperationAcorn.BaitTrap",
    backpack = "OperationAcorn.TeamBackpack", waistBag = "OperationAcorn.TeamWaistBagFront",
    waistBagBack = "OperationAcorn.TeamWaistBagBack", fuelCan = "OperationAcorn.TeamFuelCan",
    weldingMask = "OperationAcorn.TeamWeldingMask", welder = "Base.BlowTorch",
    kitCapacity = "OperationAcorn.KitCapacity", kitLightening = "OperationAcorn.KitLightening",
    kitReinforcement = "OperationAcorn.KitReinforcement", kitEngine = "OperationAcorn.KitEngine",
    motorNormal = "OperationAcorn.MotorNormal", motorModern = "OperationAcorn.MotorModern",
    shredBladeNormal = "OperationAcorn.ShredBladeNormal", shredBladeModern = "OperationAcorn.ShredBladeModern",
    cutBladeNormal = "OperationAcorn.CutBladeNormal", cutBladeModern = "OperationAcorn.CutBladeModern",
    sawBladeNormal = "OperationAcorn.SawBladeNormal", sawBladeModern = "OperationAcorn.SawBladeModern",
    filterNormal = "OperationAcorn.FilterNormal", filterModern = "OperationAcorn.FilterModern",
    muffler = "OperationAcorn.SoundproofCover",
    fieldTerminal = "OperationAcorn.FieldTerminal",
}

-- The field tools (scripts/OA_field_tools.txt, made by tools/field_tools.py: the vanilla tool of the name, a little
-- lighter and longer lasting): the tool, tier, price, in the shop's order (that tool's list). The common hand tools open
-- first; the metalworking ones, the heavy ones and the big blades later, the dearer the more a run carries them.
Shop.FIELD_TOOLS = {
    { "Hammer", 1, 15000 }, { "BallPeenHammer", 2, 15000 }, { "ClubHammer", 2, 18000 }, { "WoodenMallet", 2, 12000 },
    { "Saw", 1, 15000 }, { "GardenSaw", 2, 16000 }, { "SmallSaw", 2, 14000 }, { "CarpentryChisel", 2, 14000 },
    { "HandDrill", 2, 20000 },
    { "SmithingHammer", 3, 20000 }, { "Tongs", 3, 16000 }, { "MetalworkingPliers", 3, 16000 },
    { "MetalworkingPunch", 3, 16000 }, { "MetalworkingChisel", 3, 16000 }, { "File", 3, 14000 },
    { "SmallFileSet", 3, 18000 }, { "SheetMetalSnips", 3, 18000 }, { "ViseGrips", 3, 16000 },
    { "HeadingTool", 3, 16000 }, { "SmallPunchSet", 3, 18000 },
    { "MasonsTrowel", 2, 12000 }, { "MasonsChisel", 2, 14000 }, { "PlasterTrowel", 2, 12000 },
    { "Screwdriver", 1, 12000 }, { "Wrench", 1, 14000 }, { "Ratchet", 2, 16000 }, { "PipeWrench", 2, 18000 },
    { "LugWrench", 1, 14000 }, { "Pliers", 1, 12000 },
    { "Crowbar", 2, 22000 }, { "BoltCutters", 3, 28000 }, { "Sledgehammer", 4, 35000 },
    { "WoodAxe", 3, 28000 }, { "Axe", 3, 28000 }, { "HandAxe", 2, 20000 }, { "Shovel", 2, 20000 },
    { "HandShovel", 2, 12000 }, { "PickAxe", 3, 28000 }, { "GardenHoe", 2, 18000 }, { "GardenFork", 2, 18000 },
    { "Scythe", 2, 22000 }, { "HandScythe", 2, 14000 },
    { "Scissors", 1, 10000 }, { "Awl", 1, 10000 }, { "Whetstone", 1, 10000 },
}

-- A field tool's item type and shop id.
function Shop.fieldType(tool)
    return "OperationAcorn.Field" .. tool
end

function Shop.fieldId(tool)
    return "field_" .. string.lower(tool)
end

-- Upgrade serum trees. The ids are the names the upgrades part uses.
Shop.TREES = { "scout", "load", "survival" }
local SERUM_TYPE = { scout = "serumScout", load = "serumLoad", survival = "serumSurvival" }

-- Kit kinds, one per thing they improve (Gear/Rules.lua), and their prices (each kit the same, however many are bought).
Shop.KITS = {
    capacity = { price = 50000, type = "kitCapacity" },
    lightening = { price = 50000, type = "kitLightening" },
    reinforcement = { price = 40000, type = "kitReinforcement" },
    engine = { price = 80000, type = "kitEngine" },
}
Shop.KIT_ORDER = { "capacity", "lightening", "reinforcement", "engine" }

-- The team's welder: the vanilla blowtorch with the team's mark and its uses (Gear/Rules.lua: USES and USES_BASE, which
-- the extension API reads), filled to them, named as the team's. The kits find it by the mark.
Shop.WELDER = { type = "Base.BlowTorch", mod = { OA_Team = true, OA_Uses = 1.2 }, used = 1, name = "IGUI_OA_Gear_TeamWelder" }

Shop.SERUM_LINEAR_FROM = 26       -- the 26th serum of a tree costs 8000 * 1.15^25; after it the price is linear
Shop.SERUM_LINEAR_STEP = 30000    -- per serum after the 26th, at the default base price

local function give(key, count, extra)
    local g = { type = Shop.TYPES[key] or key, count = count or 1 }
    if extra then for k, v in pairs(extra) do g[k] = v end end
    return g
end

local function vanilla(name, count, extra)
    local g = { type = "Base." .. name, count = count or 1 }
    if extra then for k, v in pairs(extra) do g[k] = v end end
    return g
end

local function choiceList(names)
    local list = {}
    for _, name in ipairs(names) do table.insert(list, vanilla(name)) end
    return list
end

local function numbered(prefixes, count)
    local names = {}
    for _, p in ipairs(prefixes) do
        for i = 1, count do table.insert(names, p .. i) end
    end
    return names
end

local catalog

local function build()
    local list = {}
    local function add(e) table.insert(list, e) end
    -- The serum shelf, infection (DESIGN 10, NUMBERS 10): no discount, no count, no interval; the reversal opens at the
    -- first stage, the cure at the fifth.
    add({ id = "cure_serum", group = "serum", tier = 5, price = 500000, special = "cure", fixed = true,
        give = { give("cure") } })
    add({ id = "reversal", group = "serum", tier = 1, price = 50000, special = "reversal", fixed = true,
        give = { give("reversal") } })
    add({ id = "delay_long", group = "serum", tier = 0, price = 20000, special = "delay", days = 7, fixed = true,
        give = { give("delayLong") } })
    add({ id = "test_kit", group = "serum", tier = 0, price = 2000, special = "test", fixed = true,
        give = { give("testKit") } })
    add({ id = "delay_drug", group = "serum", tier = 0, price = 5000, special = "delay", days = 1, fixed = true,
        give = { give("delay") } })
    -- Supplies, the ones bought most often first: the ammunition, then the fuels and batteries, then the rest.
    add({ id = "ammo_pistol", group = "resource", tier = 4, price = 40000, week = 2,
        choices = choiceList({ "Bullets9mmBox", "Bullets38Box", "Bullets357Box", "Bullets44Box", "Bullets45Box" }) })
    add({ id = "ammo_shotgun", group = "resource", tier = 4, price = 50000, week = 2, give = { vanilla("ShotgunShellsBox") } })
    add({ id = "ammo_rifle", group = "resource", tier = 4, price = 60000, week = 2,
        choices = choiceList({ "556Box", "308Box", "3030Box" }) })
    add({ id = "battery_pack", group = "resource", tier = 1, price = 4000, week = 5, give = { vanilla("Battery", 4, { full = true }) } })
    add({ id = "petrol_can", group = "resource", tier = 2, price = 15000, week = 3,
        give = { vanilla("PetrolCan", 1, { full = true, fluid = "Petrol" }) } })
    add({ id = "propane_tank", group = "resource", tier = 3, price = 25000, week = 2, give = { vanilla("PropaneTank", 1, { full = true }) } })
    add({ id = "seed_pack", group = "resource", tier = 1, price = 3000, week = 5, choices = "seeds" })
    add({ id = "scrap_pack", group = "resource", tier = 2, price = 6000, week = 5, give = { vanilla("ElectronicsScrap", 10) } })
    -- Building hardware, dear (NUMBERS 7): a box of 100 nails or screws is what a delivery of 2 weight pays ten times
    -- over. Nuts and bolts come loose in fives and never in a box, so they cost the most a piece.
    add({ id = "nails_box", group = "resource", tier = 1, price = 8000, week = 3, give = { vanilla("NailsBox") } })
    add({ id = "screws_box", group = "resource", tier = 1, price = 8000, week = 3, give = { vanilla("ScrewsBox") } })
    add({ id = "nuts_bolts", group = "resource", tier = 2, price = 15000, week = 2, give = { vanilla("NutsBolts", 20) } })
    add({ id = "welding_rods", group = "resource", tier = 2, price = 12000, week = 3, give = { vanilla("WeldingRods") } })
    add({ id = "engine_parts", group = "resource", tier = 3, price = 20000, week = 2, give = { vanilla("EngineParts", 10) } })
    add({ id = "car_battery", group = "resource", tier = 3, price = 20000, week = 2,
        choices = choiceList({ "CarBattery1", "CarBattery2", "CarBattery3" }) })
    add({ id = "car_part_normal", group = "resource", tier = 3, price = 10000, week = 6,
        choices = choiceList(numbered({ "NormalTire", "NormalBrake", "NormalSuspension", "NormalCarMuffler",
            "Windshield", "RearWindshield", "FrontWindow", "RearWindow" }, 3)) })
    add({ id = "car_part_modern", group = "resource", tier = 5, price = 25000, week = 6,
        choices = choiceList(numbered({ "ModernTire", "ModernBrake", "ModernSuspension", "ModernCarMuffler" }, 3)) })
    -- Gear.
    -- The backpack's water storage is built in (its two canteens are part of the pack), so no canteens come with it.
    add({ id = "team_backpack", group = "gear", tier = 5, price = 300000, give = { give("backpack") } })
    add({ id = "team_waist_bag", group = "gear", tier = 3, price = 90000, give = { give("waistBag") } })
    add({ id = "team_fuel_can", group = "gear", tier = 2, price = 20000, give = { give("fuelCan", 1, { empty = true }) } })
    add({ id = "team_welder", group = "gear", tier = 3, price = 35000, give = { Shop.WELDER } })
    add({ id = "team_welding_mask", group = "gear", tier = 3, price = 40000, give = { give("weldingMask") } })
    -- Machines.
    add({ id = "shred_bench", group = "machine", tier = 0, price = 5000, give = { give("shredBench") } })
    add({ id = "bait_trap", group = "machine", tier = 2, price = 12000, give = { give("bait") } })
    add({ id = "field_terminal", group = "machine", tier = 2, price = 50000, give = { give("fieldTerminal") } })
    add({ id = "team_locker", group = "machine", tier = 2, price = 60000, give = { give("locker") } })
    -- the locker's small kind, stacked three high
    add({ id = "team_crate", group = "machine", tier = 2, price = 15000, give = { give("crate") } })
    add({ id = "fabric_cutter", group = "machine", tier = 2, price = 80000, give = { give("cutter") } })
    add({ id = "log_saw", group = "machine", tier = 2, price = 100000, give = { give("logSaw") } })
    add({ id = "rain_cistern", group = "machine", tier = 3, price = 90000, give = { give("cistern") } })
    add({ id = "bulk_shredder", group = "machine", tier = 3, price = 150000, give = { give("bulkShredder") } })
    add({ id = "propane_refinery", group = "machine", tier = 3, price = 200000, give = { give("propaneRefinery") } })
    add({ id = "oil_refinery", group = "machine", tier = 4, price = 250000, give = { give("oilRefinery") } })
    -- The field tools, after the machines: the catalog's order is the news board's, which names the first few. Named
    -- as their items are; one description for all.
    for _, t in ipairs(Shop.FIELD_TOOLS) do
        add({ id = Shop.fieldId(t[1]), group = "tool", tier = t[2], price = t[3], item = Shop.fieldType(t[1]),
            descKey = "IGUI_OA_Terminal_Shop_Desc_field_tool", give = { give(Shop.fieldType(t[1])) } })
    end
    -- The delivery box.
    add({ id = "box_reissue", group = "box", tier = 0, price = 10000, special = "reissue", fixed = true, allowDebt = true,
        give = { give("box") } })
    -- Machine parts: the worn-down kind comes with the machine. A yield part pays its price back within a mid game's
    -- work (NUMBERS 7): the cutter's pieces are cheap rags, so its blade adds more and costs less.
    local function part(id, tier, price, key)
        add({ id = id, group = "part", tier = tier, price = price, give = { give(key) } })
    end
    part("motor_normal", 3, 25000, "motorNormal")
    part("motor_modern", 5, 60000, "motorModern")
    part("shred_blade_normal", 3, 15000, "shredBladeNormal")
    part("shred_blade_modern", 5, 40000, "shredBladeModern")
    part("cut_blade_normal", 3, 10000, "cutBladeNormal")
    part("cut_blade_modern", 5, 25000, "cutBladeModern")
    part("saw_blade_normal", 3, 15000, "sawBladeNormal")
    part("saw_blade_modern", 5, 40000, "sawBladeModern")
    part("filter_normal", 3, 20000, "filterNormal")
    part("filter_modern", 5, 50000, "filterModern")
    part("soundproof_cover", 3, 30000, "muffler")
    -- Modification kits (the first milestone, KitsForSale).
    for _, kind in ipairs(Shop.KIT_ORDER) do
        local k = Shop.KITS[kind]
        add({ id = "kit_" .. kind, group = "kit", tier = 6, price = k.price, kits = true, give = { give(k.type) } })
    end
    -- Upgrade serums: one entry per tree, the price by how many the record bought.
    for _, tree in ipairs(Shop.TREES) do
        add({ id = "serum_" .. tree, group = "serum", tier = 0, price = 8000, special = "serum", tree = tree,
            fixed = true, give = { give(SERUM_TYPE[tree]) } })
    end
    return list
end

-- Seed packets the shop offers: the vanilla seed bags (the farming ones), found once in the scripts.
local seeds
function Shop.seedChoices()
    if seeds then return seeds end
    seeds = {}
    if not getScriptManager then return seeds end
    local all = getScriptManager():getAllItems()
    local names = {}
    for i = 0, all:size() - 1 do
        local script = all:get(i)
        local name = script:getName()
        if script:getModuleName() == "Base" and string.find(name, "^[A-Z][A-Za-z]*BagSeed[0-9]?$")
            and script:getDisplayCategory() == "Gardening" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do table.insert(seeds, vanilla(name)) end
    return seeds
end

-- The shop's entries, in the order the shop shows them. Entries are shared: do not change them.
function Shop.catalog()
    if not catalog then catalog = build() end
    return catalog
end

-- What the crude terminal orders too (DESIGN-terminal 3.1): the serums, the late resources, the delivery box, the
-- shredding bench, the bait and the field terminal itself. Everything else the research team made is ordered at the
-- field terminal only.
Shop.CRUDE_GROUPS = { serum = true, resource = true, box = true }
Shop.CRUDE_IDS = { shred_bench = true, bait_trap = true, field_terminal = true }

function Shop.fieldOnly(entry)
    return not (Shop.CRUDE_GROUPS[entry.group] or Shop.CRUDE_IDS[entry.id])
end

function Shop.entry(id)
    for _, e in ipairs(Shop.catalog()) do
        if e.id == id then return e end
    end
    return nil
end

-- The translation keys of an entry's name and of a group's. An entry that sells one item under that item's name
-- (`item`: the field tools) has no key of its own: Shop.name gives its name.
function Shop.nameKey(entry)
    return "IGUI_OA_Econ_Shop_Item_" .. entry.id
end

function Shop.name(entry)
    if entry.item and getItemNameFromFullType then return getItemNameFromFullType(entry.item) end
    return getText(Shop.nameKey(entry))
end

-- The translation key of an entry's description in the shop.
function Shop.descKey(entry)
    return entry.descKey or ("IGUI_OA_Terminal_Shop_Desc_" .. entry.id)
end

function Shop.groupKey(group)
    return "IGUI_OA_Econ_Shop_Group_" .. group
end

-- The list of things an entry delivers to choose from (the seeds are found when first asked).
function Shop.choices(entry)
    if entry.choices == "seeds" then return Shop.seedChoices() end
    return entry.choices
end

-- The shop section of a record.
function Shop.section(record)
    local s = OA.Store.section(record, "shop")
    s.week = s.week or {}       -- [entry id] = { week, n }
    s.serums = s.serums or {}   -- [tree] = serums bought
    return s
end

-- Upgrade serum price by how many of the tree were bought before (n = 1 for the first): 8000 * 1.15^(n - 1) to the
-- nearest 100, straight up after the 26th (NUMBERS 6). The sandbox base price scales the straight part.
function Shop.serumPriceAt(n)
    local base = OA.scaled(8000, "UpgradeSerumPriceMultiplier")
    local growth = 1 + OA.scaled(0.15, "UpgradeSerumGrowthMultiplier")
    local limit = Shop.SERUM_LINEAR_FROM
    local function rounded(x) return OA.round(x / 100) * 100 end
    if n <= limit then return rounded(base * growth ^ (n - 1)) end
    local last = rounded(base * growth ^ (limit - 1))
    return last + rounded(Shop.SERUM_LINEAR_STEP * base / 8000) * (n - limit)
end

-- The price of the next serum of a tree for a record (`bought` overrides how many it bought).
function Shop.serumPrice(tree, record, bought)
    if bought == nil then bought = Shop.section(record).serums[tree] or 0 end
    return Shop.serumPriceAt(bought + 1)
end

-- The price of an entry for a record, in credits (a whole number). Serums, the box and every fixed entry (the infection
-- medicines) ignore the shop multiplier and the discount.
function Shop.price(entry, record)
    if entry.special == "serum" then return Shop.serumPrice(entry.tree, record) end
    if entry.special == "reissue" then return OA.reissueCost() end
    local base = entry.price
    if entry.special == "cure" then base = OA.scaled(base, "CureSerumPriceMultiplier") end
    if entry.fixed then return OA.round(base) end
    local multiplier = OA.option("ShopPriceMultiplier") or 1.0
    local discount = OA.Trust.rewards(record).discount
    return OA.round(base * multiplier * (1 - discount))
end

-- The world age (hours) a game day starts at.
local function dayStart(day)
    local offset = OA.remainder(getGameTime():getTimeOfDay() - OA.hours(), 24)
    return day * 24 - offset
end

-- How many of an entry a record may buy right now, why not (a translation key) when none, and the world age when
-- it opens again, if that is known:
--   locked (tier), debt (blocks every order but the box), kits off, the weekly limit, and how many one order may hold.
-- Whether every item an entry gives is defined in the scripts. A good whose item a part of the mod still to come has
-- not defined is not sold (it would be charged and never delivered) and not shown. Kept per type once known; without a
-- script manager (the tests) every type counts as defined.
local defined = {}
local function isDefined(fullType)
    local known = defined[fullType]
    if known == nil then
        local scripts = getScriptManager and getScriptManager()
        if not scripts then return true end
        known = scripts:FindItem(fullType) ~= nil
        defined[fullType] = known
    end
    return known
end
function Shop.stocked(entry)
    for _, g in ipairs(entry.give or {}) do
        if not isDefined(g.type) then return false end
    end
    if type(entry.choices) == "table" then
        for _, c in ipairs(entry.choices) do
            if not isDefined(type(c) == "table" and c.type or c) then return false end
        end
    end
    return true
end

function Shop.available(entry, record)
    local t = record.trade or {}
    if not Shop.stocked(entry) then return 0, "IGUI_OA_Econ_Shop_NotStocked" end
    if OA.Trust.tier(record) < entry.tier then return 0, "IGUI_OA_Econ_Shop_Locked" end
    if entry.kits and not OA.option("KitsForSale") then return 0, "IGUI_OA_Econ_Shop_KitsOff" end
    if (t.credits or 0) < 0 and not entry.allowDebt then return 0, "IGUI_OA_Econ_Shop_Debt" end
    local shop = Shop.section(record)
    local most = 99
    if entry.week then
        local week = OA.week()
        local w = shop.week[entry.id]
        local used = (w and w.week == week) and w.n or 0
        if used >= entry.week then
            return 0, "IGUI_OA_Econ_Shop_Limit", dayStart((week + 1) * 7)
        end
        most = math.min(most, entry.week - used)
    end
    return most
end

-- Records a purchase the trade part delivered: `count` of the entry.
function Shop.bought(entry, record, count)
    count = count or 1
    local shop = Shop.section(record)
    if entry.week then
        local week = OA.week()
        local w = shop.week[entry.id]
        if not w or w.week ~= week then
            w = { week = week, n = 0 }
            shop.week[entry.id] = w
        end
        w.n = w.n + count
    end
    if entry.special == "serum" then
        shop.serums[entry.tree] = (shop.serums[entry.tree] or 0) + count
        -- The upgrades part keeps its own count of serums bought (its board and price read it): keep it in step.
        if OA.Upgrades and OA.Upgrades.noteBought then
            local ok, err = pcall(OA.Upgrades.noteBought, record, entry.tree, count)
            if not ok then OA.log("upgrades noteBought failed:", tostring(err)) end
        end
    end
end

-- The entries that open at a tier (the shop shows the next ones above its trust bar).
function Shop.opensAt(tier)
    local found = {}
    for _, e in ipairs(Shop.catalog()) do
        if e.tier == tier and not (e.kits and not OA.option("KitsForSale")) then table.insert(found, e) end
    end
    return found
end

return Shop
