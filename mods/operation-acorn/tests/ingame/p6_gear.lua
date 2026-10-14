-- P6 gear and kits: what the unit tests cannot reach, checked on the real game objects. Single player, a character with
-- a record (the first hello makes it). Run RUN("p6_gear.lua"); lines are tagged "[p6gear]", each ending "ok" or "BAD".
-- Use a throwaway save: the vehicle checks fit kits to the nearest vehicle within 6 squares (stand beside a car that
-- has a storage such as a trunk), and P6_CLEAN() takes back what it can (the kits it fitted to the vehicle, the items it made).
--
-- What it checks: every item of OA_gear.txt against the vanilla item it is modelled on (the backpack's capacity,
-- reduction and water storage, the waist bag's two sides, the gas can's fluid container); the team welder as the shop
-- makes it; each field tool against its vanilla tool (lighter, longer lasting, the same tool to the game); the shop
-- stocks all of them; each kit on each kind of item it fits (a vanilla bag, the research backpack, the gas can, the
-- welder, a field tool), with and without the extension API (it reads which one is there), and the refusals; an
-- expansion kit (on each storage part) and an engine kit on the nearest vehicle against the game's own getters; the
-- voucher through the server command.
--
-- Not scripted (do by hand): buy each good in the shop and see it arrive (the can empty, the welder full and named);
-- hover a fitted item and see the kit lines; right-click a kit (the menu of what it fits, the reasons it cannot) and
-- fit it with the real timed action (the progress bar, the notice), and a vehicle kit from the mechanics window
-- (right-click a storage, a roof rack too, and the engine part); wear the waist bag, fit a kit, then turn it to the
-- back and see the kits stay; weld with the team welder and see it last longer; build with a field tool (it counts as
-- the vanilla tool); save, quit and load: the bags, the can, the welder, the tools' condition and weight, the storages,
-- the engine are as left; drive the car with a full trunk; fit one to a modded vehicle's own storage (a KI5 car's
-- roof rack); wear the backpack, fill its water storage at a tap and drink from it (right-click), hang a radio on a
-- shoulder-strap hanger.
local OA = OperationAcorn
local Gear = OA.Gear
local Rules = Gear.Rules
local K = Rules.KEY
local player = getPlayer()
local made = {}
local fitted = {}

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[p6gear] " .. table.concat(parts, " "))
end

local function check(label, condition, detail)
    say(label, condition and "ok" or "BAD", detail ~= nil and tostring(detail) or "")
    return condition and true or false
end

local function near(a, b, eps)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-4)
end

local function section(name, fn)
    say("----", name)
    local ok, err = pcall(fn)
    if not ok then say("BAD", name, "error", tostring(err)) end
end

local function give(fullType)
    local item = player:getInventory():AddItem(fullType)
    made[#made + 1] = item
    return item
end

local function kitFor(kind)
    return give(Rules.kitType(kind))
end

local function welder()
    local item = OA.Trade.Objects.makeItem(OA.Shop.WELDER)
    player:getInventory():AddItem(item)
    made[#made + 1] = item
    return item
end

-- What an item weighs to carry: the API's formula when it applies, else the item's own weight.
local function carried(item)
    return Gear.carriedWeight(item) or item:getActualWeight()
end

local scripts = getScriptManager()
local api = OA.api()
local lifted = Gear.lifts(true)
local carry = Gear.applies(Gear.CARRY_POINT, true)
local uses = Gear.applies(Gear.USES_POINT, true)
say("extension API", api and "present" or "missing", "capacity", tostring(lifted), "carry", tostring(carry),
    "uses", tostring(uses))

-- ---------------------------------------------------------------------------------------------------------------------
section("the items against the vanilla ones", function()
    local T = OA.Shop.TYPES
    for _, key in ipairs({ "backpack", "waistBag", "waistBagBack", "fuelCan", "weldingMask",
        "kitCapacity", "kitLightening", "kitReinforcement", "kitEngine" }) do
        check("script " .. T[key], scripts:FindItem(T[key]) ~= nil)
    end

    local pack = give(T.backpack)
    check("backpack is a container", pack:IsInventoryContainer())
    check("backpack capacity 35", pack:getItemContainer():getCapacity() == 35, pack:getItemContainer():getCapacity())
    check("backpack weight reduction 85", pack:getWeightReduction() == 85, pack:getWeightReduction())
    check("backpack is worn on the back", string.find(string.lower(tostring(pack:canBeEquipped())), "back", 1, true) ~= nil,
        tostring(pack:canBeEquipped()))
    local water = pack:getFluidContainer()
    check("backpack has its water storage", water ~= nil)
    if water then
        check("water storage holds 1.8 L (two military canteens)", near(water:getCapacity(), 1.8), water:getCapacity())
        check("water storage comes empty", water:isEmpty(), water:getAmount())
    end
    local alice = give("Base.Bag_ALICEpack")
    check("the vanilla pack for comparison: 28 and 85", alice:getItemContainer():getCapacity() == 28 and alice:getWeightReduction() == 85)

    for _, key in ipairs({ "waistBag", "waistBagBack" }) do
        local bag = give(T[key])
        check(key .. " is a container", bag:IsInventoryContainer())
        check(key .. " capacity 6", bag:getItemContainer():getCapacity() == 6, bag:getItemContainer():getCapacity())
        check(key .. " weight reduction 85", bag:getWeightReduction() == 85, bag:getWeightReduction())
        check(key .. " has its clothing item", bag:getClothingItem() ~= nil)
        check(key .. " turns to the other side", bag:getClothingItemExtra() ~= nil and bag:getClothingItemExtra():size() > 0)
    end

    local vanillaCan = give("Base.PetrolCan")
    vanillaCan:getFluidContainer():Empty()
    local can = give(T.fuelCan)
    local fluid = can:getFluidContainer()
    if check("the gas can has a fluid container", fluid ~= nil) then
        check("the gas can holds 12 L", near(fluid:getCapacity(), 12), fluid:getCapacity())
        check("the gas can is a petrol can (tag)", can:hasTag(ItemTag.PETROL))
        fluid:Empty()
        check("the gas can's empty weight is the vanilla can's",
            near(can:getActualWeight(), vanillaCan:getActualWeight(), 1e-3), can:getActualWeight() .. " vs " .. vanillaCan:getActualWeight())
    end

    local torch, plainTorch = welder(), give("Base.BlowTorch")
    check("the welder is the vanilla torch", torch:getFullType() == "Base.BlowTorch")
    check("the welder carries the team's mark", torch:getModData()[K.TEAM] == true)
    check("the welder is Gear's welder", Gear.targetOf(torch) == "welder")
    check("a plain torch is not", Gear.targetOf(plainTorch) == nil)
    check("the welder has the team's name", torch:getDisplayName() == getText("IGUI_OA_Gear_TeamWelder"), torch:getDisplayName())
    check("the welder comes full", near(torch:getCurrentUsesFloat(), 1, 1e-3), torch:getCurrentUsesFloat())
    if uses then
        local ratio = torch:getMaxUses() / plainTorch:getMaxUses()
        check("with the API the welder lasts 1.2 times as long", near(ratio, Rules.uses(0), 0.1),
            torch:getMaxUses() .. " vs " .. plainTorch:getMaxUses())
    else
        say("the uses point does not apply: the welder lasts as the vanilla torch", torch:getMaxUses())
    end

    local shop = OA.Shop
    local ids = { "team_backpack", "team_welding_mask", "team_waist_bag", "team_fuel_can", "team_welder",
        "kit_capacity", "kit_lightening", "kit_reinforcement", "kit_engine" }
    for _, t in ipairs(shop.FIELD_TOOLS) do ids[#ids + 1] = shop.fieldId(t[1]) end
    for _, id in ipairs(ids) do
        check("the shop stocks " .. id, shop.stocked(shop.entry(id)))
    end
end)

-- ---------------------------------------------------------------------------------------------------------------------
section("the welding mask and the field tools", function()
    local mask = give("OperationAcorn.TeamWeldingMask")
    local vanillaMask = give("Base.WeldingMask")
    check("the mask is a welding mask by its tag", mask:hasTag(ItemTag.WELDING_MASK))
    check("the mask is less in the way", mask:getDiscomfortModifier() < vanillaMask:getDiscomfortModifier(),
        mask:getDiscomfortModifier() .. " vs " .. vanillaMask:getDiscomfortModifier())
    check("the mask is cooler", mask:getInsulation() < vanillaMask:getInsulation(), mask:getInsulation())
    check("the mask sees as the vanilla one", mask:getVisionModifier() == vanillaMask:getVisionModifier())
    check("the mask has its clothing item", mask:getClothingItem() ~= nil)
    for _, t in ipairs(OA.Shop.FIELD_TOOLS) do
        local name = t[1]
        local tool, plain = give(OA.Shop.fieldType(name)), give("Base." .. name)
        check(name .. " is a field tool", Gear.targetOf(tool) == "tool")
        check(name .. " is lighter", tool:getActualWeight() < plain:getActualWeight(),
            tool:getActualWeight() .. " vs " .. plain:getActualWeight())
        check(name .. " lasts longer", tool:getConditionMax() > plain:getConditionMax(),
            tool:getConditionMax() .. " vs " .. plain:getConditionMax())
        check(name .. " comes whole", tool:getCondition() == tool:getConditionMax())
        local sprite = tool.getWeaponSprite and tool:getWeaponSprite()
        if sprite then
            check(name .. " model " .. sprite, scripts:getModelScript(sprite) ~= nil)
        end
        local static = tool:getWorldStaticModel()
        if static then check(name .. " ground model " .. static, scripts:getModelScript(static) ~= nil) end
        check(name .. " icon", tool:getTex() ~= nil and tool:getTex():getName() ~= "Question_On")
    end
    -- the game takes them as the vanilla tools by their tags
    check("the field hammer is a hammer", give("OperationAcorn.FieldHammer"):hasTag(ItemTag.HAMMER))
    check("the field saw is a saw", give("OperationAcorn.FieldSaw"):hasTag(ItemTag.SAW))
    check("the field screwdriver is a screwdriver", give("OperationAcorn.FieldScrewdriver"):hasTag(ItemTag.SCREWDRIVER))
end)

-- ---------------------------------------------------------------------------------------------------------------------
section("kits on bags", function()
    local alice = give("Base.Bag_ALICEpack")
    local kit = kitFor("capacity")
    local ok, value = Gear.fitItem(player, kit, alice)
    check("expansion kit fits a bag", ok, value)
    check("count 1 on the bag", alice:getModData()[K.KIT_CAP] == 1)
    check("original kept", alice:getModData()[K.BAG_BASE_CAP] == 28)
    local total = Rules.capacity(28, 1)
    check("the bag holds " .. total .. " by the game's own getter", alice:getItemContainer():getCapacity() == total, alice:getItemContainer():getCapacity())
    check("and effective", alice:getInventory():getEffectiveCapacity(player) >= total, alice:getInventory():getEffectiveCapacity(player))
    check("the kit is used up", kit:getContainer() == nil)
    ok, value = Gear.fitItem(player, kitFor("lightening"), alice)
    check("lightening kit fits a bag", ok, value)
    check("reduction " .. Rules.reductionInt(85, 1), alice:getWeightReduction() == Rules.reductionInt(85, 1), alice:getWeightReduction())
    Gear.fitItem(player, kitFor("lightening"), alice)
    check("reduction " .. Rules.reductionInt(85, 2) .. " after two", alice:getWeightReduction() == Rules.reductionInt(85, 2), alice:getWeightReduction())
    local why = Gear.refusal(kitFor("reinforcement"), alice)
    check("a reinforcement kit does not go on a bag", why == "target", why)

    local pack = give(OA.Shop.TYPES.backpack)
    for _ = 1, 5 do Gear.fitItem(player, kitFor("capacity"), pack) end
    local capacity = pack:getItemContainer():getCapacity()
    local effective = pack:getInventory():getEffectiveCapacity(player)
    local five = Rules.capacity(35, 5)
    if lifted then
        check("with the API: " .. five .. " by the game's getter, past the limit", capacity == five, capacity)
        check("with the API: the bag's own answer is not cut", pack:getCapacity() == five, pack:getCapacity())
        check("with the API: effective capacity " .. five, effective == five, effective)
    else
        check("without the API: cut to the vanilla limit", capacity == Rules.bagLimit(pack:getActualWeight()), capacity)
        check("without the API: the count is 5 anyway", pack:getModData()[K.KIT_CAP] == 5)
    end
    local lines = Gear.itemLines(pack)
    check("the tooltip lines", lines ~= nil and #lines >= 1, lines and lines[1])
    check("OA_Capacity is a number only with the API", (type(pack:getModData()[K.CAPACITY]) == "number") == lifted,
        tostring(pack:getModData()[K.CAPACITY]))

    local waist = give(OA.Shop.TYPES.waistBag)
    ok = Gear.fitItem(player, kitFor("capacity"), waist)
    check("expansion kit fits the waist bag", ok)
    check("the waist bag holds " .. Rules.capacity(6, 1), waist:getItemContainer():getCapacity() == Rules.capacity(6, 1),
        waist:getItemContainer():getCapacity())
end)

-- ---------------------------------------------------------------------------------------------------------------------
section("kits on the gas can, the welder and a field tool", function()
    local can = give(OA.Shop.TYPES.fuelCan)
    local ok, value = Gear.fitItem(player, kitFor("capacity"), can)
    check("expansion kit fits the can", ok, value)
    check("the can holds " .. Rules.canLitres(12, 1) .. " L", near(can:getFluidContainer():getCapacity(), Rules.canLitres(12, 1)),
        can:getFluidContainer():getCapacity())
    local before = carried(can)
    ok = Gear.fitItem(player, kitFor("lightening"), can)
    check("lightening kit fits the can", ok)
    local after = carried(can)
    check("the empty can carries " .. Rules.lightness(1) .. " of its weight", near(after, before * Rules.lightness(1), 0.02),
        before .. " -> " .. after)
    if carry then
        check("with the API the scale weight stays the script's", near(can:getActualWeight(), can:getScriptItem():getActualWeight(), 1e-3),
            can:getActualWeight())
        check("with the API OA_Carry is set", type(can:getModData()[K.CARRY]) == "number", tostring(can:getModData()[K.CARRY]))
    end

    local torch = welder()
    local most = torch:getMaxUses()
    ok, value = Gear.fitItem(player, kitFor("capacity"), torch)
    if uses then
        check("expansion kit fits the welder", ok, value)
        check("the welder lasts longer", torch:getMaxUses() > most, most .. " -> " .. torch:getMaxUses())
        check("OA_Uses " .. Rules.uses(1), near(torch:getModData()[K.USES], Rules.uses(1), 1e-6), tostring(torch:getModData()[K.USES]))
    else
        check("without the uses point the welder takes no expansion kit", not ok and value == "api", value)
    end
    ok = Gear.fitItem(player, kitFor("lightening"), torch)
    check("lightening kit fits the welder", ok)
    local plainTorch = give("Base.BlowTorch")
    check("a plain torch takes no kit", Gear.refusal(kitFor("lightening"), plainTorch) == "target")

    local hammer = give("OperationAcorn.FieldHammer")
    local base = hammer:getScriptItem():getConditionMax()
    hammer:setCondition(hammer:getConditionMax() - 2)
    local cond = hammer:getCondition()
    ok, value = Gear.fitItem(player, kitFor("reinforcement"), hammer)
    check("reinforcement kit fits a field tool", ok, value)
    check("most condition " .. Rules.toughness(base, 1), hammer:getConditionMax() == Rules.toughness(base, 1), hammer:getConditionMax())
    check("the condition rises by as much", hammer:getCondition() == cond + Rules.toughness(base, 1) - base, hammer:getCondition())
    for _ = 2, Rules.TOUGH_MOST do Gear.fitItem(player, kitFor("reinforcement"), hammer) end
    check("most condition " .. Rules.toughness(base, Rules.TOUGH_MOST) .. " with all of them",
        hammer:getConditionMax() == Rules.toughness(base, Rules.TOUGH_MOST), hammer:getConditionMax())
    local why = Gear.refusal(kitFor("reinforcement"), hammer)
    check("no more than " .. Rules.TOUGH_MOST, why == "most", why)
    before = carried(hammer)
    Gear.fitItem(player, kitFor("lightening"), hammer)
    check("a lightened field tool carries less", carried(hammer) < before, before .. " -> " .. carried(hammer))
    check("an expansion kit does not go on a tool", Gear.refusal(kitFor("capacity"), hammer) == "target")
    check("the tool's lines", Gear.itemLines(hammer) ~= nil)
    local plain = give("Base.Hammer")
    check("a vanilla hammer takes no kit", Gear.refusal(kitFor("reinforcement"), plain) == "target")
end)

-- ---------------------------------------------------------------------------------------------------------------------
local function nearestVehicle()
    local vehicles = OperationAcorn.vehicles()
    local best, bestD
    for i = 0, vehicles:size() - 1 do
        local v = vehicles:get(i)
        local dx, dy = v:getX() - player:getX(), v:getY() - player:getY()
        local d = dx * dx + dy * dy
        if d <= Gear.REACH * Gear.REACH and (not bestD or d < bestD) then best, bestD = v, d end
    end
    return best
end

section("vehicle kits", function()
    local vehicle = nearestVehicle()
    if not check("a vehicle within " .. Gear.REACH .. " squares", vehicle ~= nil) then return end
    say("vehicle", Gear.vehicleName(vehicle))
    local storages = Gear.storageParts(vehicle)
    local engine = vehicle:getPartById(Gear.ENGINE_PART)
    fitted[#fitted + 1] = vehicle

    if #storages > 0 then
        for _, part in ipairs(storages) do
            local id = part:getId()
            local before = part:getContainerCapacity()
            local ok, total = Gear.fitStorage(player, kitFor("capacity"), vehicle, id)
            check("expansion kit fits " .. id, ok, total)
            check(id .. " counted", part:getModData()[K.KIT_CAP] == 1)
            local now = part:getContainerCapacity()
            check(id .. " holds more by the game's getter", now > before or before == 0, before .. " -> " .. now)
            check(id .. " effective capacity", part:getItemContainer():getEffectiveCapacity(player) >= now,
                part:getItemContainer():getEffectiveCapacity(player))
            check(id .. " lines", Gear.storageLines(part) ~= nil)
            if lifted then
                check(id .. ": with the API the part has OA_Capacity as a number", type(part:getModData()[K.CAPACITY]) == "number")
            end
        end
    else
        say("this vehicle has no storage part; expansion kit not checked")
    end

    if engine then
        local power, loud = vehicle:getEnginePower(), vehicle:getEngineLoudness()
        local ok, value = Gear.fitEngine(player, kitFor("engine"), vehicle)
        check("engine kit fits", ok, value)
        check("power +10%", vehicle:getEnginePower() == Rules.engine(power, 1, Rules.POWER_STEP), power .. " -> " .. vehicle:getEnginePower())
        check("loudness +5%", vehicle:getEngineLoudness() == Rules.engine(loud, 1, Rules.LOUDNESS_STEP), loud .. " -> " .. vehicle:getEngineLoudness())
        check("the original is kept on the engine part", engine:getModData()[K.ENGINE_POWER] == power and engine:getModData()[K.ENGINE_LOUD] == loud)
        check("the engine lines", Gear.engineLines(vehicle) ~= nil)
    else
        say("this vehicle has no engine part; engine kit not checked")
    end
end)

-- ---------------------------------------------------------------------------------------------------------------------
section("the voucher", function()
    local voucher = give(Gear.VOUCHER)
    local kitType = Rules.kitType("capacity")
    -- the kits already held (earlier sections made some): the new one is the one not among them
    local held = {}
    local kits = player:getInventory():getAllTypeRecurse(kitType)
    for i = 0, kits:size() - 1 do held[kits:get(i):getID()] = true end
    OA.Sync.send(player, "gear.redeem", { item = voucher:getID(), kind = "capacity" })
    -- a client command reaches the server side on a later tick, even alone: look a few ticks on
    local ticks = 0
    local function later()
        ticks = ticks + 1
        if ticks < 10 then return end
        Events.OnTick.Remove(later)
        check("the voucher is gone", voucher:getContainer() == nil)
        local kit
        kits = player:getInventory():getAllTypeRecurse(kitType)
        for i = 0, kits:size() - 1 do
            if not held[kits:get(i):getID()] then kit = kits:get(i) end
        end
        check("an expansion kit arrived", kit ~= nil)
        if kit then made[#made + 1] = kit end
        say("voucher checked")
    end
    Events.OnTick.Add(later)
end)

-- Takes away the items the checks made and puts back the vehicle they fitted (power, loudness, the storages).
function P6_CLEAN()
    for _, item in ipairs(made) do
        local container = item:getContainer()
        if container then container:Remove(item) end
    end
    made = {}
    for _, vehicle in ipairs(fitted) do
        local engine = vehicle:getPartById(Gear.ENGINE_PART)
        if engine then
            local md = engine:getModData()
            if md[K.ENGINE_POWER] then
                vehicle:setEngineFeature(vehicle:getEngineQuality(), Rules.loudnessArgument(md[K.ENGINE_LOUD]), md[K.ENGINE_POWER])
                md[K.ENGINE], md[K.ENGINE_POWER], md[K.ENGINE_LOUD] = nil, nil, nil
                vehicle:transmitEngine()
            end
        end
        for _, part in ipairs(Gear.storageParts(vehicle)) do
            local md = part:getModData()
            if md[K.STORAGE_BASE] then
                part:setContainerCapacity(md[K.STORAGE_BASE])
                md[K.KIT_CAP], md[K.STORAGE_BASE], md[K.RAW], md[K.CAPACITY] = nil, nil, nil, nil
                vehicle:transmitPartModData(part)
            end
        end
    end
    fitted = {}
    say("cleaned")
end

say("finished (the voucher lines follow a few ticks later); search the log for BAD and ERROR, then call P6_CLEAN()")
