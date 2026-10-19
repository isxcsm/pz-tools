-- The shop (NUMBERS 7 and 10, REWARDS): the catalog, what each thing costs, what is open and how much of it a record
-- may still buy. Nothing here takes credits or delivers: the trade part orders, charges and delivers, and calls
-- Shop.bought for what it delivered. All numbers are the defaults of the sandbox options.
--
-- An entry: { id, group, tier, price (the base), give = { { type, count, full, fluid, empty } ... } or
-- choices = { { type, count ... } ... } (the player picks one), week = purchases a week (nil: none), special =
-- "cure" | "reversal" | "test" | "delay" (with days) | "serum" | "reissue" | nil, fixed = true (no shop
-- multiplier, no discount), allowDebt, kits = true (only with KitsForSale), item (the item it is named after),
-- descKey (a description shared with other entries), bu (the Building Utilities feature it serves), harvest (the mark receiving it gives the character, Harvest),
-- restock (a number, or a function(record) of how many the entry restocks to; see below), priceAt (a function(record, n)
-- of the price of the n-th purchase of the restock window) }. A give may carry `mod`, `used` and `name` (Trade.dropSpec).
-- tier is stage + milestones (Trust.tier): 1..5 the stages (1 the start), 6 the first milestone.
--
-- The restock clock (NUMBERS 7, 'Restock items'): a record's shop section keeps restock = { start (world hours the window
-- began), factor (the window's length as a share of RESTOCK_DAYS), nextFactor (the next window's: a town searched
-- through multiplies it), n = { [entry id] = purchases this window }, towns = { [town] = true } (the towns whose share the
-- record has taken) }. Nothing runs on a clock: the window rolls when the shop is asked (Shop.restock). The stock left of
-- an entry is its quantity now less the purchases of the window, so a quantity that grows (a tier, a place cleared)
-- shows at once; a refill resets the purchases and leaves nothing over.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Eggs"
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
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
    kit = "OperationAcorn.HarvestKit", tweezers = "OperationAcorn.PrecisionTweezers",
}

-- The field tools (scripts/OA_field_tools.txt, made by tools/field_tools.py: the vanilla tool of the name, a little
-- lighter and longer lasting): the tool, tier, price, in the shop's order (that tool's list). The common hand tools open
-- first; the metalworking ones, the heavy ones and the big blades later, the dearer the more a run carries them.
Shop.FIELD_TOOLS = {
    { "Hammer", 1, 45000 }, { "BallPeenHammer", 2, 45000 }, { "ClubHammer", 2, 54000 }, { "WoodenMallet", 2, 36000 },
    { "Saw", 1, 45000 }, { "GardenSaw", 2, 48000 }, { "SmallSaw", 2, 42000 }, { "CarpentryChisel", 2, 42000 },
    { "HandDrill", 2, 60000 },
    { "SmithingHammer", 3, 60000 }, { "Tongs", 3, 48000 }, { "MetalworkingPliers", 3, 48000 },
    { "MetalworkingPunch", 3, 48000 }, { "MetalworkingChisel", 3, 48000 }, { "File", 3, 42000 },
    { "SmallFileSet", 3, 54000 }, { "SheetMetalSnips", 3, 54000 }, { "ViseGrips", 3, 48000 },
    { "HeadingTool", 3, 48000 }, { "SmallPunchSet", 3, 54000 },
    { "MasonsTrowel", 2, 36000 }, { "MasonsChisel", 2, 42000 }, { "PlasterTrowel", 2, 36000 },
    { "Screwdriver", 1, 36000 }, { "Wrench", 1, 42000 }, { "Ratchet", 2, 48000 }, { "PipeWrench", 2, 54000 },
    { "LugWrench", 1, 42000 }, { "Pliers", 1, 36000 },
    { "Crowbar", 2, 66000 }, { "BoltCutters", 3, 84000 }, { "Sledgehammer", 4, 200000 },
    { "WoodAxe", 3, 84000 }, { "Axe", 3, 84000 }, { "HandAxe", 2, 60000 }, { "Shovel", 2, 60000 },
    { "HandShovel", 2, 36000 }, { "PickAxe", 3, 84000 }, { "GardenHoe", 2, 54000 }, { "GardenFork", 2, 54000 },
    { "Scythe", 2, 66000 }, { "HandScythe", 2, 42000 },
    { "Scissors", 1, 30000 }, { "Awl", 1, 30000 }, { "Whetstone", 1, 30000 },
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
    reinforcement = { price = 60000, type = "kitReinforcement" },
    engine = { price = 80000, type = "kitEngine" },
}
Shop.KIT_ORDER = { "capacity", "lightening", "reinforcement", "engine" }

-- The restock items. The shared serum's first price (it doubles with each one bought in a window); the weapon kits: id,
-- the kind of dense place whose clearing adds one (the dense section's `got`), the fixed price and the item.
Shop.SHARED_SERUM_PRICE = 20000
Shop.WEAPON_KITS = {
    { "kit_weapon_damage", "damage", 60000, "OperationAcorn.KitWeaponDamage" },
    { "kit_weapon_crit", "crit", 60000, "OperationAcorn.KitWeaponCrit" },
    { "kit_weapon_critdamage", "critDamage", 60000, "OperationAcorn.KitWeaponCritDamage" },
    { "kit_weapon_repair", "repair", 30000, "OperationAcorn.KitWeaponRepair" },
}

-- A weapon kit's quantity: one for each dense place the record cleared that gave this kind (the dense section, kept by
-- the part that clears them: got = { [place id] = kind }); none before the first, and the shop does not show it then
-- (Shop.hidden).
function Shop.denseQuantity(kind)
    return function(record)
        local dense = record.dense
        local got = dense and dense.got
        local n = 0
        if type(got) == "table" then
            for _, k in pairs(got) do
                if k == kind then n = n + 1 end
            end
        end
        return n
    end
end

-- The team's welder: the vanilla blowtorch (the game's own code asks for a blowtorch by its type), with the team's mark
-- and its uses (Gear/Rules.lua: USES and USES_BASE, which the extension API reads), filled to them. It is drawn with the
-- team's icon (the game's own customInventoryIcon) and named as the team's (NAME, which the extension API reads in the
-- language of the moment; Trade/Objects.lua). The kits find it by the mark; the shop draws it by `icon`.
Shop.WELDER_ICON = "OA_TeamWelder"
Shop.WELDER = { type = "Base.BlowTorch", used = 1, name = "IGUI_OA_Gear_TeamWelder", icon = Shop.WELDER_ICON,
    mod = { OA_Team = true, OA_Uses = 1.2, OA_Name = "IGUI_OA_Gear_TeamWelder",
        customInventoryIcon = "media/textures/Item_" .. Shop.WELDER_ICON .. ".png" } }

-- Building Utilities' goods (another mod of ours). Sold only while it is loaded (Shop.stocked: their items are
-- defined) and the feature each serves is on in its sandbox (`bu`, a name of BuildingUtilities.enabled).
local BU_BOARD = "BuildingUtilities.ControlBoard"
Shop.BU_MACHINES = {       -- id, item, tier, price, feature
    { "bu_solar_panel", "BuildingUtilities.SolarPanel", 3, 80000, "solar" },
    { "bu_water_pump", "BuildingUtilities.WaterPump", 2, 80000, "pump" },
    { "bu_water_filter", "BuildingUtilities.WaterFilter", 3, 100000, "filter" },
    { "bu_booster_pump", "BuildingUtilities.BoosterPump", 4, 120000, "booster" },
}

-- Whether a good that needs no Building Utilities feature (nil) may be sold, or BU is loaded with the feature on
-- (BuildingUtilities.enabled).
function Shop.buOn(feature)
    if not feature then return true end
    local bu = BuildingUtilities
    if not (bu and bu.enabled) then return false end
    return bu.enabled(feature) == true
end

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
local catalogOf, byId   -- the catalog the entries by id were made from, and they

local function build()
    local list = {}
    local function add(e) table.insert(list, e) end
    -- The serum shelf, infection (DESIGN 10, NUMBERS 10): no discount, no count, no interval; the reversal opens at the
    -- first stage, the cure at the fifth.
    add({ id = "cure_serum", group = "serum", tier = 5, price = 500000, special = "cure", fixed = true,
        give = { give("cure") } })
    add({ id = "reversal", group = "serum", tier = 1, price = 50000, special = "reversal", fixed = true,
        give = { give("reversal") } })
    add({ id = "delay_long", group = "serum", tier = 1, price = 20000, special = "delay", days = 7, fixed = true,
        give = { give("delayLong") } })
    add({ id = "test_kit", group = "serum", tier = 1, price = 2000, special = "test", fixed = true,
        give = { give("testKit") } })
    add({ id = "delay_drug", group = "serum", tier = 1, price = 5000, special = "delay", days = 1, fixed = true,
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
    add({ id = "seed_pack", group = "resource", tier = 1, price = 30000, week = 5, choices = "seeds" })
    add({ id = "scrap_pack", group = "resource", tier = 2, price = 6000, week = 5, give = { vanilla("ElectronicsScrap", 10) } })
    -- Building hardware, dear (NUMBERS 7): a box of 100 nails or screws is what a delivery of 2 weight pays ten times
    -- over. Nuts and bolts come loose in fives and never in a box, so they cost the most a piece.
    add({ id = "nails_box", group = "resource", tier = 1, price = 80000, week = 3, give = { vanilla("NailsBox") } })
    add({ id = "screws_box", group = "resource", tier = 1, price = 80000, week = 3, give = { vanilla("ScrewsBox") } })
    add({ id = "nuts_bolts", group = "resource", tier = 2, price = 80000, week = 2, give = { vanilla("NutsBolts", 10) } })
    add({ id = "welding_rods", group = "resource", tier = 2, price = 50000, week = 3, give = { vanilla("WeldingRods", 4) } })
    add({ id = "engine_parts", group = "resource", tier = 3, price = 20000, week = 2, give = { vanilla("EngineParts", 10) } })
    add({ id = "car_battery", group = "resource", tier = 3, price = 20000, week = 2,
        choices = choiceList({ "CarBattery1", "CarBattery2", "CarBattery3" }) })
    add({ id = "car_part_normal", group = "resource", tier = 3, price = 10000, week = 6,
        choices = choiceList(numbered({ "NormalTire", "NormalBrake", "NormalSuspension", "NormalCarMuffler",
            "Windshield", "RearWindshield", "FrontWindow", "RearWindow" }, 3)) })
    add({ id = "car_part_modern", group = "resource", tier = 5, price = 25000, week = 6,
        choices = choiceList(numbered({ "ModernTire", "ModernBrake", "ModernSuspension", "ModernCarMuffler" }, 3)) })
    -- What Building Utilities runs on (`bu`): its lines' wire and pipe, and the board its utility panels go up a tier
    -- with. The board is the scarce one: dear and a few a week, so looting the electronics stores stays the way.
    add({ id = "bu_wire", group = "resource", tier = 1, price = 8000, week = 3, bu = "power",
        give = { vanilla("ElectricWire", 10) } })
    add({ id = "bu_pipe", group = "resource", tier = 2, price = 10000, week = 3, bu = "water",
        give = { vanilla("Pipe", 5) } })
    add({ id = "bu_control_board", group = "resource", tier = 2, price = 50000, week = 2, bu = "panel",
        item = BU_BOARD, give = { give(BU_BOARD) } })
    -- The zombie sample tools (NUMBERS 4 '좀비 시료'): the harvest kit to start with, the tweezers for the precise harvest.
    -- Receiving the tweezers marks the character (Harvest.received): the corpse menu then offers the precise harvest.
    add({ id = "harvest_kit", group = "harvest", tier = 1, price = 3000, give = { give("kit") } })
    add({ id = "precision_tweezers", group = "harvest", tier = 3, price = 40000, harvest = "precise",
        give = { give("tweezers") } })
    -- Gear.
    -- The backpack's water storage is built in (its two canteens are part of the pack), so no canteens come with it.
    add({ id = "team_backpack", group = "gear", tier = 5, price = 300000, give = { give("backpack") } })
    add({ id = "team_waist_bag", group = "gear", tier = 3, price = 90000, give = { give("waistBag") } })
    add({ id = "team_fuel_can", group = "gear", tier = 2, price = 20000, give = { give("fuelCan", 1, { empty = true }) } })
    add({ id = "team_welder", group = "gear", tier = 3, price = 35000, give = { Shop.WELDER } })
    add({ id = "team_welding_mask", group = "gear", tier = 3, price = 40000, give = { give("weldingMask") } })
    -- Machines.
    add({ id = "shred_bench", group = "machine", tier = 1, price = 5000, give = { give("shredBench") } })
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
    -- Building Utilities' machines that are hard to come by (a learned recipe, glassmaking, rare loot), named as their
    -- items are. Dear: they spare the hunt, not replace it. Its utility panel is not sold: finding one is how its
    -- recipe is learned.
    for _, m in ipairs(Shop.BU_MACHINES) do
        add({ id = m[1], group = "machine", tier = m[3], price = m[4], bu = m[5], item = m[2], give = { give(m[2]) } })
    end
    -- The field tools, after the machines: the catalog's order is the news board's, which names the first few. Named
    -- as their items are; one description for all.
    for _, t in ipairs(Shop.FIELD_TOOLS) do
        add({ id = Shop.fieldId(t[1]), group = "tool", tier = t[2], price = t[3], item = Shop.fieldType(t[1]),
            descKey = "IGUI_OA_Terminal_Shop_Desc_field_tool", give = { give(Shop.fieldType(t[1])) } })
    end
    -- The delivery box.
    add({ id = "box_reissue", group = "box", tier = 1, price = OA.BALANCE.reissueCost, special = "reissue", fixed = true, allowDebt = true,
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
        add({ id = "serum_" .. tree, group = "serum", tier = 1, price = 8000, special = "serum", tree = tree,
            fixed = true, give = { give(SERUM_TYPE[tree]) } })
    end
    -- The restock items (NUMBERS 7): the shared serum, dearer with each one bought in a window, and the weapon kits,
    -- as many as places cleared.
    add({ id = "serum_shared", group = "serum", tier = 1, price = Shop.SHARED_SERUM_PRICE, fixed = true,
        restock = function(record) return math.floor(OA.Trust.tier(record) / 3) + 1 end,
        priceAt = function(record, n)
            return OA.scaled(Shop.SHARED_SERUM_PRICE, "UpgradeSerumPriceMultiplier") * 2 ^ (n - 1) * OA.Eggs.serumScale(record)
        end,
        give = { give("OperationAcorn.UpgradeSerumShared") } })
    for _, k in ipairs(Shop.WEAPON_KITS) do
        add({ id = k[1], group = "kit", tier = 6, price = k[3], kits = true, fixed = true, restock = Shop.denseQuantity(k[2]),
            dense = true, give = { give(k[4]) } })
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
-- sample tools, the shredding bench, the bait and the field terminal itself. Everything else the research team made is ordered at the
-- field terminal only.
Shop.CRUDE_GROUPS = { serum = true, resource = true, box = true, harvest = true }
Shop.CRUDE_IDS = { shred_bench = true, bait_trap = true, field_terminal = true }

function Shop.fieldOnly(entry)
    return not (Shop.CRUDE_GROUPS[entry.group] or Shop.CRUDE_IDS[entry.id])
end

function Shop.entry(id)
    local list = Shop.catalog()
    if catalogOf ~= list then
        catalogOf, byId = list, {}
        for _, e in ipairs(list) do byId[e.id] = e end
    end
    return byId[id]
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
    return s
end

-- How many serums of a tree the record bought: the upgrades part keeps the count (its board reads it too).
function Shop.serumsBought(record, tree)
    return Rules.section(record).bought[tree] or 0
end

-- The price of the n-th serum of a tree (n = 1 for the first): the upgrades part owns the formula. With `record`, the
-- price it pays (the dead squirrel egg's 0.9, Eggs.serumScale, a whole number).
function Shop.serumPriceAt(n, record)
    local price = Rules.serumPrice(n)
    if record then price = OA.round(price * OA.Eggs.serumScale(record)) end
    return price
end

-- The price of the next serum of a tree for a record (`bought` overrides how many it bought).
function Shop.serumPrice(tree, record, bought)
    if bought == nil then bought = Shop.serumsBought(record, tree) end
    return Shop.serumPriceAt(bought + 1, record)
end

-- The restock window of a record (the clock in the header), rolled to now: the first look starts the first window; a
-- window that has ended is replaced by the next one, which starts where the old one ended (and by the whole windows
-- after it, when more than one passed), takes the next factor and finds every purchase count at 0.
Shop.RESTOCK_DAYS = 10
Shop.TOWN_FACTOR = 0.9      -- what a town searched through multiplies the next windows' length by
function Shop.restock(record)
    local shop = Shop.section(record)
    local now = OA.hours()
    local r = shop.restock
    if not r then
        r = { start = now, factor = 1.0, nextFactor = 1.0, n = {}, towns = {} }
        shop.restock = r
        return r
    end
    local length = Shop.RESTOCK_DAYS * 24 * r.factor
    if now >= r.start + length then
        r.start = r.start + length
        r.factor = r.nextFactor
        length = Shop.RESTOCK_DAYS * 24 * r.factor
        if now >= r.start + length then r.start = r.start + math.floor((now - r.start) / length) * length end
        r.n = {}
    end
    return r
end

-- The world age the record's current restock window ends at.
function Shop.restockEnd(record)
    local r = Shop.restock(record)
    return r.start + Shop.RESTOCK_DAYS * 24 * r.factor
end

-- What a restock entry restocks to for a record.
-- Whether the shop leaves an entry out for a record: a weapon kit whose dense places it has not cleared any of.
function Shop.hidden(entry, record)
    return entry.dense == true and Shop.restockQuantity(entry, record) <= 0
end

function Shop.restockQuantity(entry, record)
    local q = entry.restock
    if type(q) == "function" then q = q(record) end
    return q or 0
end

-- How many of a restock entry the record bought in this window.
function Shop.restockBought(entry, record)
    return Shop.restock(record).n[entry.id] or 0
end

-- A town the record searched through (or came into after the world did): the windows after this one are shorter.
-- True when the record had not taken that town's share yet.
function Shop.townDone(record, town)
    local r = Shop.restock(record)
    if r.towns[town] then return false end
    r.towns[town] = true
    r.nextFactor = r.nextFactor * Shop.TOWN_FACTOR
    return true
end

-- The price of an entry for a record, in credits (a whole number). Serums, the box and every fixed entry (the infection
-- medicines) ignore the shop multiplier and the discount. A restock entry with `priceAt` is priced by the purchase it
-- would be in the window, `ahead` more (the units of one order before this one).
function Shop.price(entry, record, ahead)
    if entry.priceAt then
        return OA.round(entry.priceAt(record, Shop.restockBought(entry, record) + 1 + (ahead or 0)))
    end
    if entry.special == "serum" then return Shop.serumPrice(entry.tree, record) end
    if entry.special == "reissue" then return OA.reissueCost() end
    local base = entry.price
    if entry.special == "cure" then base = OA.scaled(base, "CureSerumPriceMultiplier") end
    if entry.fixed then return OA.round(base) end
    local multiplier = OA.option("ShopPriceMultiplier") or 1.0
    local discount = OA.Trust.rewards(record).discount
    return OA.round(base * multiplier * (1 - discount))
end

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

-- Whether an entry is on sale: its feature is on and every item it gives is defined.
function Shop.stocked(entry)
    if not Shop.buOn(entry.bu) then return false end
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

-- Whether reaching a tier puts anything new on sale (a level's title says so only then): an entry of that tier that
-- is stocked, a kit only while kits are sold.
function Shop.opensAt(tier)
    for _, e in ipairs(Shop.catalog()) do
        if e.tier == tier and Shop.stocked(e) and not (e.kits and not OA.option("KitsForSale")) then return true end
    end
    return false
end

-- How many of an entry a record may buy right now, why not (a translation key) when none, and the world age when
-- it opens again, if that is known (a restock entry gives the age its window ends at also while it has stock):
--   locked (tier), debt (blocks every order but the box), kits off, the weekly limit, the restock stock, and how many
--   one order may hold.
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
            return 0, "IGUI_OA_Econ_Shop_Limit", OA.dayStart(OA.weekStart(week + 1))
        end
        most = math.min(most, entry.week - used)
    end
    local refill
    if entry.restock then
        -- (the window is asked for once: bought and the end are read off it)
        local r = Shop.restock(record)
        local left = Shop.restockQuantity(entry, record) - (r.n[entry.id] or 0)
        refill = r.start + Shop.RESTOCK_DAYS * 24 * r.factor
        if left <= 0 then return 0, "IGUI_OA_Econ_Shop_SoldOut", refill end
        most = math.min(most, left)
    end
    return most, nil, refill
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
    if entry.restock then
        local r = Shop.restock(record)
        r.n[entry.id] = (r.n[entry.id] or 0) + count
    end
    if entry.special == "serum" then
        Rules.noteBought(Rules.section(record), entry.tree, count)
    end
    if entry.harvest and OA.Harvest and OA.Harvest.received then OA.Harvest.received(record, entry.harvest) end
end

return Shop
