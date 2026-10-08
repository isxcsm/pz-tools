-- The shop (NUMBERS 7 and 10, REWARDS): the catalog, what each thing costs, what is open and how much of it a record
-- may still buy. Nothing here takes credits or delivers: the trade part orders, charges and delivers, and calls
-- Shop.bought for what it delivered. All numbers are the defaults of the sandbox options.
--
-- An entry: { id, group, tier, price (the base), give = { { type, count, full, fluid, empty } ... } or
-- choices = { { type, count ... } ... } (the player picks one), week = purchases a week (nil: none), special =
-- "cure" | "delay" | "serum" | "kit" | "reissue" | nil, fixed = true (no shop multiplier, no discount),
-- allowDebt, kits = true (only with KitsForSale) }.
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
    cure = "OperationAcorn.CureSerum", delay = "OperationAcorn.DelayDrug",
    serumScout = "OperationAcorn.UpgradeSerumScout", serumLoad = "OperationAcorn.UpgradeSerumLoad",
    serumSurvival = "OperationAcorn.UpgradeSerumSurvival",
    box = "OperationAcorn.DeliveryBox",
    shredBench = "OperationAcorn.ShredBench", bulkShredder = "OperationAcorn.BulkShredder",
    cutter = "OperationAcorn.FabricCutter", propaneRefinery = "OperationAcorn.PropaneRefinery",
    oilRefinery = "OperationAcorn.OilRefinery", logSaw = "OperationAcorn.LogSaw",
    locker = "OperationAcorn.TeamLocker", cistern = "OperationAcorn.RainCistern", bait = "OperationAcorn.BaitTrap",
    backpack = "OperationAcorn.TeamBackpack",
    fuelMk1 = "OperationAcorn.FuelCanMk1", fuelMk2 = "OperationAcorn.FuelCanMk2", fuelMk3 = "OperationAcorn.FuelCanMk3",
    kitBagCapacity = "OperationAcorn.KitBagCapacity", kitBagWeight = "OperationAcorn.KitBagWeight",
    kitTrunk = "OperationAcorn.KitTrunk", kitEngine = "OperationAcorn.KitEngine",
    motorNormal = "OperationAcorn.MotorNormal", motorModern = "OperationAcorn.MotorModern",
    shredBladeNormal = "OperationAcorn.ShredBladeNormal", shredBladeModern = "OperationAcorn.ShredBladeModern",
    cutBladeNormal = "OperationAcorn.CutBladeNormal", cutBladeModern = "OperationAcorn.CutBladeModern",
    sawBladeNormal = "OperationAcorn.SawBladeNormal", sawBladeModern = "OperationAcorn.SawBladeModern",
    filterNormal = "OperationAcorn.FilterNormal", filterModern = "OperationAcorn.FilterModern",
    muffler = "OperationAcorn.SoundproofCover",
}

-- Upgrade serum trees. The ids are the names the upgrades part uses.
Shop.TREES = { "scout", "load", "survival" }
local SERUM_TYPE = { scout = "serumScout", load = "serumLoad", survival = "serumSurvival" }

-- Kit kinds: first price, and the factor each kit on the same target multiplies the next by.
Shop.KITS = {
    bagCapacity = { price = 40000, growth = 1.3, type = "kitBagCapacity" },
    bagWeight = { price = 50000, growth = 1.3, type = "kitBagWeight" },
    trunk = { price = 60000, growth = 1.25, type = "kitTrunk" },
    engine = { price = 80000, growth = 1.3, type = "kitEngine" },
}
Shop.KIT_ORDER = { "bagCapacity", "bagWeight", "trunk", "engine" }

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
    -- Consumables.
    add({ id = "cure_serum", group = "consumable", tier = 1, price = 30000, special = "cure", give = { give("cure") } })
    add({ id = "delay_drug", group = "consumable", tier = 0, price = 6000, special = "delay", give = { give("delay") } })
    -- Late resources.
    add({ id = "battery_pack", group = "resource", tier = 1, price = 4000, week = 5, give = { vanilla("Battery", 4, { full = true }) } })
    add({ id = "seed_pack", group = "resource", tier = 1, price = 3000, week = 5, choices = "seeds" })
    add({ id = "petrol_can", group = "resource", tier = 2, price = 15000, week = 3,
        give = { vanilla("PetrolCan", 1, { full = true, fluid = "Petrol" }) } })
    add({ id = "scrap_pack", group = "resource", tier = 2, price = 6000, week = 5, give = { vanilla("ElectronicsScrap", 10) } })
    add({ id = "propane_tank", group = "resource", tier = 3, price = 25000, week = 2, give = { vanilla("PropaneTank", 1, { full = true }) } })
    add({ id = "car_battery", group = "resource", tier = 3, price = 20000, week = 2,
        choices = choiceList({ "CarBattery1", "CarBattery2", "CarBattery3" }) })
    add({ id = "car_part_normal", group = "resource", tier = 3, price = 10000, week = 6,
        choices = choiceList(numbered({ "NormalTire", "NormalBrake", "NormalSuspension", "NormalCarMuffler",
            "Windshield", "RearWindshield", "FrontWindow", "RearWindow" }, 3)) })
    add({ id = "engine_parts", group = "resource", tier = 3, price = 20000, week = 2, give = { vanilla("EngineParts", 10) } })
    add({ id = "car_part_modern", group = "resource", tier = 5, price = 25000, week = 6,
        choices = choiceList(numbered({ "ModernTire", "ModernBrake", "ModernSuspension", "ModernCarMuffler" }, 3)) })
    add({ id = "ammo_pistol", group = "resource", tier = 4, price = 40000, week = 2,
        choices = choiceList({ "Bullets9mmBox", "Bullets38Box", "Bullets357Box", "Bullets44Box", "Bullets45Box" }) })
    add({ id = "ammo_shotgun", group = "resource", tier = 4, price = 50000, week = 2, give = { vanilla("ShotgunShellsBox") } })
    add({ id = "ammo_rifle", group = "resource", tier = 4, price = 60000, week = 2,
        choices = choiceList({ "556Box", "308Box", "3030Box" }) })
    -- Gear.
    add({ id = "team_backpack", group = "gear", tier = 5, price = 300000,
        give = { give("backpack"), vanilla("CanteenMilitary", 2, { empty = true }) } })
    -- Machines.
    add({ id = "shred_bench", group = "machine", tier = 0, price = 5000, give = { give("shredBench") } })
    add({ id = "bait_trap", group = "machine", tier = 2, price = 12000, give = { give("bait") } })
    add({ id = "team_locker", group = "machine", tier = 2, price = 60000, give = { give("locker") } })
    add({ id = "fabric_cutter", group = "machine", tier = 2, price = 80000, give = { give("cutter") } })
    add({ id = "log_saw", group = "machine", tier = 2, price = 100000, give = { give("logSaw") } })
    add({ id = "rain_cistern", group = "machine", tier = 3, price = 90000, give = { give("cistern") } })
    add({ id = "bulk_shredder", group = "machine", tier = 3, price = 150000, give = { give("bulkShredder") } })
    add({ id = "propane_refinery", group = "machine", tier = 3, price = 200000, give = { give("propaneRefinery") } })
    add({ id = "oil_refinery", group = "machine", tier = 4, price = 250000, give = { give("oilRefinery") } })
    -- The delivery box.
    add({ id = "box_reissue", group = "box", tier = 0, price = 10000, special = "reissue", fixed = true, allowDebt = true,
        give = { give("box") } })
    -- Machine parts: the worn-down kind comes with the machine.
    local function part(id, tier, price, key)
        add({ id = id, group = "part", tier = tier, price = price, give = { give(key) } })
    end
    part("motor_normal", 3, 25000, "motorNormal")
    part("motor_modern", 5, 60000, "motorModern")
    part("shred_blade_normal", 3, 15000, "shredBladeNormal")
    part("shred_blade_modern", 5, 40000, "shredBladeModern")
    part("cut_blade_normal", 3, 15000, "cutBladeNormal")
    part("cut_blade_modern", 5, 40000, "cutBladeModern")
    part("saw_blade_normal", 3, 15000, "sawBladeNormal")
    part("saw_blade_modern", 5, 40000, "sawBladeModern")
    part("filter_normal", 3, 20000, "filterNormal")
    part("filter_modern", 5, 50000, "filterModern")
    part("soundproof_cover", 3, 30000, "muffler")
    -- Improved gear (Mk): each step is bought on its own, empty.
    add({ id = "fuelcan_mk1", group = "mk", tier = 2, price = 20000, give = { give("fuelMk1", 1, { empty = true }) } })
    add({ id = "fuelcan_mk2", group = "mk", tier = 4, price = 45000, give = { give("fuelMk2", 1, { empty = true }) } })
    add({ id = "fuelcan_mk3", group = "mk", tier = 5, price = 90000, give = { give("fuelMk3", 1, { empty = true }) } })
    -- Modification kits (the first milestone, KitsForSale).
    for _, kind in ipairs(Shop.KIT_ORDER) do
        local k = Shop.KITS[kind]
        add({ id = "kit_" .. kind, group = "kit", tier = 6, price = k.price, special = "kit", kit = kind, kits = true,
            give = { give(k.type) } })
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

function Shop.entry(id)
    for _, e in ipairs(Shop.catalog()) do
        if e.id == id then return e end
    end
    return nil
end

-- The translation keys of an entry's name and of a group's.
function Shop.nameKey(entry)
    return "IGUI_OA_Econ_Shop_Item_" .. entry.id
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
    s.last = s.last or {}       -- [entry id] = world age of the last purchase
    s.week = s.week or {}       -- [entry id] = { week, n }
    s.kits = s.kits or {}       -- [kit kind] = { [target] = kits bought for it }
    s.serums = s.serums or {}   -- [tree] = serums bought
    return s
end

-- Upgrade serum price by how many of the tree were bought before (n = 1 for the first): 8000 * 1.15^(n - 1) to the
-- nearest 100, straight up after the 26th (NUMBERS 6). The sandbox base price scales the straight part.
function Shop.serumPriceAt(n)
    local base = OA.option("UpgradeSerumPrice") or 8000
    local growth = OA.option("UpgradeSerumGrowth") or 1.15
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

-- Kits bought for a target (applied or not): the price of the next counts them (NUMBERS 7).
function Shop.kitsFor(kind, target, record)
    local per = Shop.section(record).kits[kind]
    return per and per[tostring(target)] or 0
end

-- The price of a kit of a kind for a target. `pending` is the kits of the same kind and target already in the
-- order being made; a record cannot lower the price by ordering ahead.
function Shop.kitPrice(kind, target, record, pending)
    local k = Shop.KITS[kind]
    local n = Shop.kitsFor(kind, target, record) + (pending or 0)
    local multiplier = OA.option("ShopPriceMultiplier") or 1.0
    local discount = OA.Trust.rewards(record).discount
    return OA.round(k.price * k.growth ^ n * multiplier * (1 - discount))
end

-- The price of an entry for a record, in credits (a whole number). Serums and the box ignore the shop multiplier and
-- the discount; a kit needs its target, so ask Shop.kitPrice.
function Shop.price(entry, record)
    if entry.special == "serum" then return Shop.serumPrice(entry.tree, record) end
    if entry.special == "kit" then return Shop.kitPrice(entry.kit, "", record) end
    if entry.special == "reissue" then return OA.option("BoxReissueCost") or entry.price end
    local base = entry.price
    if entry.special == "cure" then base = OA.option("CureSerumPrice") or base end
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
--   locked (tier), debt (blocks every order but the box), kits off, the purchase interval of the cure serum and the
--   delay drug (shorter with trust), the weekly limit, and how many one order may hold.
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
    local now = OA.hours()
    local rewards = OA.Trust.rewards(record)
    local most = 99
    if entry.special == "cure" or entry.special == "delay" then
        local interval = entry.special == "cure" and rewards.cureInterval or rewards.delayInterval
        local last = shop.last[entry.id]
        if last and interval > 0 and now < last + interval * 24 then
            return 0, "IGUI_OA_Econ_Shop_Interval", last + interval * 24
        end
        most = entry.special == "cure" and rewards.cureCount or rewards.delayCount
    end
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

-- Records a purchase the trade part delivered: `count` of the entry (for a kit, bought for `target`).
function Shop.bought(entry, record, count, target)
    count = count or 1
    local shop = Shop.section(record)
    shop.last[entry.id] = OA.hours()
    if entry.week then
        local week = OA.week()
        local w = shop.week[entry.id]
        if not w or w.week ~= week then
            w = { week = week, n = 0 }
            shop.week[entry.id] = w
        end
        w.n = w.n + count
    end
    if entry.special == "kit" then
        local per = shop.kits[entry.kit]
        if not per then
            per = {}
            shop.kits[entry.kit] = per
        end
        local key = tostring(target or "")
        per[key] = (per[key] or 0) + count
    elseif entry.special == "serum" then
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
