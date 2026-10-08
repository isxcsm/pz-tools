-- P6 gear and kits: what the unit tests cannot reach, checked on the real game objects. Single player, a character with
-- a record (the first hello makes it). Run RUN("p6_gear.lua"); lines are tagged "[p6gear]", each ending "ok" or "BAD".
-- Use a throwaway save: the vehicle checks fit kits to the nearest vehicle within 6 squares (stand beside a car that
-- has a trunk), and P6_CLEAN() takes back what it can (the kits it fitted to the vehicle, the items it made).
--
-- What it checks: every item of OA_gear.txt against the vanilla item it is modelled on (the fuel cans' fluid container,
-- the torches' uses and weights, the backpack's capacity and reduction); the shop stocks all of them; the improved
-- torches are inputs of the vanilla welding recipes (and the refill recipe stays vanilla only); a bag kit and a weight
-- kit on a vanilla bag and on the research backpack, with and without the extension API (it reads which one is there);
-- a trunk kit and an engine kit on the nearest vehicle against the game's own getters; the voucher through the server
-- command, and the shop's count unchanged by it.
--
-- Not scripted (do by hand): buy each good in the shop and see it arrive empty (cans, torches); hover a fitted bag and
-- see the kit lines; right-click a kit and a bag; fit a bag kit and a vehicle kit with the real timed action (the
-- progress bar, the notice), from the inventory menu and from the mechanics window (right-click the trunk and the engine
-- part); save, quit and load: the bag's capacity and reduction, the trunk, the engine power and loudness are as left;
-- drive the car with a full trunk; weld a barricade-free recipe (a block bludgeon) with a Mk torch and see it use
-- charges; refill a Mk torch from a propane tank; wear the backpack and hang two canteens on its sides.
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

local function kitFor(kind, target)
    local kit = give(Rules.kitType(kind))
    kit:getModData()[K.TARGET] = target or ""
    return kit
end

local scripts = getScriptManager()
local api = OA.api()
local lifted = Gear.lifts(true)
say("extension API", api and "present" or "missing", "capacity key applied", tostring(lifted))

-- ---------------------------------------------------------------------------------------------------------------------
section("the items against the vanilla ones", function()
    local T = OA.Shop.TYPES
    for _, key in ipairs({ "backpack", "fuelMk1", "fuelMk2", "fuelMk3", "torchMk1", "torchMk2", "torchMk3",
        "kitBagCapacity", "kitBagWeight", "kitTrunk", "kitEngine" }) do
        check("script " .. T[key], scripts:FindItem(T[key]) ~= nil)
    end

    local pack = give(T.backpack)
    check("backpack is a container", pack:IsInventoryContainer())
    check("backpack capacity 35", pack:getItemContainer():getCapacity() == 35, pack:getItemContainer():getCapacity())
    check("backpack weight reduction 85", pack:getWeightReduction() == 85, pack:getWeightReduction())
    check("backpack is worn on the back", string.find(string.lower(tostring(pack:canBeEquipped())), "back", 1, true) ~= nil,
        tostring(pack:canBeEquipped()))
    local alice = give("Base.Bag_ALICEpack")
    check("the vanilla pack for comparison: 28 and 85", alice:getItemContainer():getCapacity() == 28 and alice:getWeightReduction() == 85)

    local vanillaCan = give("Base.PetrolCan")
    vanillaCan:getFluidContainer():Empty()
    for mk, litres in pairs({ [1] = 15, [2] = 20, [3] = 25 }) do
        local can = give(T["fuelMk" .. mk])
        local fluid = can:getFluidContainer()
        check("fuel can Mk" .. mk .. " has a fluid container", fluid ~= nil)
        if fluid then
            check("fuel can Mk" .. mk .. " holds " .. litres .. " L", near(fluid:getCapacity(), litres), fluid:getCapacity())
            check("fuel can Mk" .. mk .. " is a petrol can (tag)", can:hasTag(ItemTag.PETROL))
            fluid:Empty()
            check("fuel can Mk" .. mk .. " empty weight is the vanilla can's",
                near(can:getActualWeight(), vanillaCan:getActualWeight(), 1e-3), can:getActualWeight() .. " vs " .. vanillaCan:getActualWeight())
        end
    end

    local vanillaTorch = give("Base.BlowTorch")
    check("vanilla torch has 10 uses", vanillaTorch:getMaxUses() == 10, vanillaTorch:getMaxUses())
    local want = { [1] = { 15, 1.0 }, [2] = { 20, 0.6 }, [3] = { 30, 0.4 } }
    for mk, w in pairs(want) do
        local torch = give(T["torchMk" .. mk])
        check("torch Mk" .. mk .. " uses " .. w[1], torch:getMaxUses() == w[1], torch:getMaxUses())
        torch:setUsedDelta(1)
        vanillaTorch:setUsedDelta(1)
        check("torch Mk" .. mk .. " full weight x" .. w[2], near(torch:getActualWeight(), vanillaTorch:getActualWeight() * w[2], 0.01),
            torch:getActualWeight() .. " vs " .. vanillaTorch:getActualWeight())
        torch:setUsedDelta(0)
        vanillaTorch:setUsedDelta(0)
        check("torch Mk" .. mk .. " empty weight x" .. w[2], near(torch:getActualWeight(), vanillaTorch:getActualWeight() * w[2], 0.01),
            torch:getActualWeight() .. " vs " .. vanillaTorch:getActualWeight())
        check("torch Mk" .. mk .. " is a blowtorch (tag)", torch:hasTag(ItemTag.BLOW_TORCH))
    end

    local shop = OA.Shop
    for _, id in ipairs({ "team_backpack", "fuelcan_mk1", "fuelcan_mk2", "fuelcan_mk3", "torch_mk1", "torch_mk2", "torch_mk3",
        "kit_bagCapacity", "kit_bagWeight", "kit_trunk", "kit_engine" }) do
        check("the shop stocks " .. id, shop.stocked(shop.entry(id)))
    end
end)

-- ---------------------------------------------------------------------------------------------------------------------
section("the improved torches in the welding recipes", function()
    Gear.extendRecipes()
    local vanilla = scripts:FindItem(Gear.TORCH)
    local mk = scripts:FindItem(OA.Shop.TYPES.torchMk3)
    local lists = { scripts:getAllCraftRecipes(), scripts:getAllBuildableRecipes() }
    local inputs, with, refill, refillMk = 0, 0, nil, nil
    for _, list in ipairs(lists) do
        for i = 0, list:size() - 1 do
            local recipe = list:get(i)
            local ins = recipe:getInputs()
            for j = 0, ins:size() - 1 do
                local input = ins:get(j)
                if not input:isAcceptsAnyItem() and input:containsItem(vanilla) then
                    if recipe:getName() == "RefillBlowTorch" then
                        refill = input:containsItem(mk)
                    else
                        inputs = inputs + 1
                        if input:containsItem(mk) then with = with + 1 end
                    end
                end
            end
            if string.find(recipe:getName(), "RefillTorchMk", 1, true) then refillMk = true end
        end
    end
    say("inputs that take the vanilla torch", inputs, "of them also take the Mk.III", with)
    check("there are such inputs", inputs > 0)
    check("every one takes the Mk torches too", with == inputs)
    check("the refill recipe does not take a Mk torch", refill == false or refill == nil, tostring(refill))
    check("the Mk refill recipes exist", refillMk == true)
end)

-- ---------------------------------------------------------------------------------------------------------------------
section("bag kits", function()
    local alice = give("Base.Bag_ALICEpack")
    local kit = kitFor("bagCapacity", "Base.Bag_ALICEpack")
    local ok, value = Gear.fitBag(player, kit, alice)
    check("capacity kit fits", ok, value)
    check("count 1 on the bag", alice:getModData()[K.BAG_CAP] == 1)
    check("original kept", alice:getModData()[K.BAG_BASE_CAP] == 28)
    check("the bag holds 31 by the game's own getter", alice:getItemContainer():getCapacity() == 31, alice:getItemContainer():getCapacity())
    check("and effective", alice:getInventory():getEffectiveCapacity(player) >= 31, alice:getInventory():getEffectiveCapacity(player))
    check("the kit is used up", kit:getContainer() == nil)
    ok, value = Gear.fitBag(player, kitFor("bagWeight", ""), alice)
    check("weight kit fits", ok, value)
    check("reduction 87", alice:getWeightReduction() == 87, alice:getWeightReduction())
    Gear.fitBag(player, kitFor("bagWeight", ""), alice)
    check("reduction 89 after two", alice:getWeightReduction() == 89, alice:getWeightReduction())
    local wrong = kitFor("bagCapacity", "Base.Bag_ALICEpack")
    local pack = give(OA.Shop.TYPES.backpack)
    ok = Gear.fitBag(player, wrong, pack)
    check("a kit ordered for the vanilla pack does not fit the research pack", not ok)

    for _ = 1, 5 do Gear.fitBag(player, kitFor("bagCapacity", ""), pack) end
    local capacity = pack:getItemContainer():getCapacity()
    local effective = pack:getInventory():getEffectiveCapacity(player)
    if lifted then
        check("with the API: 53 by the game's getter, past the limit", capacity == 53, capacity)
        check("with the API: the bag's own answer is not cut", pack:getCapacity() == 53, pack:getCapacity())
        check("with the API: effective capacity 53", effective == 53, effective)
    else
        check("without the API: cut to the vanilla limit", capacity == Rules.bagLimit(pack:getActualWeight()), capacity)
        check("without the API: the count is 5 anyway", pack:getModData()[K.BAG_CAP] == 5)
    end
    local lines = Gear.bagLines(pack)
    check("the tooltip lines", lines ~= nil and #lines >= 1, lines and lines[1])
    check("OA_Capacity is a number only with the API", (type(pack:getModData()[K.CAPACITY]) == "number") == lifted,
        tostring(pack:getModData()[K.CAPACITY]))
end)

-- ---------------------------------------------------------------------------------------------------------------------
local function nearestVehicle()
    local vehicles = getCell():getVehicles()
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
    say("vehicle", Gear.vehicleKey(vehicle), Gear.vehicleName(vehicle))
    local trunks = Gear.trunkParts(vehicle)
    local engine = vehicle:getPartById(Gear.ENGINE_PART)
    fitted[#fitted + 1] = vehicle

    if #trunks > 0 then
        local before = {}
        for i, part in ipairs(trunks) do before[i] = part:getContainerCapacity() end
        local ok, total = Gear.fitTrunk(player, kitFor("trunk", Gear.vehicleKey(vehicle)), vehicle)
        check("trunk kit fits", ok, total)
        for i, part in ipairs(trunks) do
            local md = part:getModData()
            check("trunk part " .. part:getId() .. " counted", md[K.TRUNK] == 1)
            local now = part:getContainerCapacity()
            check("trunk part " .. part:getId() .. " holds more by the game's getter", now > before[i], before[i] .. " -> " .. now)
            check("trunk part " .. part:getId() .. " effective capacity", part:getItemContainer() ~= nil
                and part:getItemContainer():getEffectiveCapacity(player) >= now, part:getItemContainer() and part:getItemContainer():getEffectiveCapacity(player))
        end
        check("the kit count by the helper", Gear.trunkKits(vehicle) == 1)
        check("the trunk lines", Gear.trunkLines(vehicle) ~= nil)
        if lifted then
            check("with the API the part has OA_Capacity as a number", type(trunks[1]:getModData()[K.CAPACITY]) == "number")
        end
    else
        say("this vehicle has no trunk part; trunk kit not checked")
    end

    if engine then
        local power, loud = vehicle:getEnginePower(), vehicle:getEngineLoudness()
        local ok, value = Gear.fitEngine(player, kitFor("engine", Gear.vehicleKey(vehicle)), vehicle)
        check("engine kit fits", ok, value)
        check("power +10%", vehicle:getEnginePower() == Rules.engine(power, 1, Rules.POWER_STEP), power .. " -> " .. vehicle:getEnginePower())
        check("loudness +5%", vehicle:getEngineLoudness() == Rules.engine(loud, 1, Rules.LOUDNESS_STEP), loud .. " -> " .. vehicle:getEngineLoudness())
        check("the original is kept on the engine part", engine:getModData()[K.ENGINE_POWER] == power and engine:getModData()[K.ENGINE_LOUD] == loud)
        check("the engine lines", Gear.engineLines(vehicle) ~= nil)
    else
        say("this vehicle has no engine part; engine kit not checked")
    end
    check("a kit ordered for another vehicle does not fit", select(1, Gear.fitEngine(player, kitFor("engine", "NoSuchCar"), vehicle)) == false)
end)

-- ---------------------------------------------------------------------------------------------------------------------
section("the voucher", function()
    local record = OA.Client.record(player)
    local voucher = give(Gear.VOUCHER)
    local before = OA.Shop.kitsFor("bagCapacity", "Base.Bag_ALICEpack", record)
    local price = OA.Shop.kitPrice("bagCapacity", "Base.Bag_ALICEpack", record)
    OA.Sync.send(player, "gear.redeem", { item = voucher:getID(), kind = "bagCapacity" })
    check("the voucher is gone", voucher:getContainer() == nil)
    local kit = player:getInventory():getFirstTypeRecurse("KitBagCapacity")
    check("a bag capacity kit arrived", kit ~= nil)
    if kit then
        made[#made + 1] = kit
        check("for any target", Gear.targetOf(kit) == "")
        check("marked as a voucher kit", kit:getModData()[K.VOUCHER] == true)
    end
    check("the shop's count did not move", OA.Shop.kitsFor("bagCapacity", "Base.Bag_ALICEpack", record) == before)
    check("nor the price", OA.Shop.kitPrice("bagCapacity", "Base.Bag_ALICEpack", record) == price)
end)

-- Takes away the items the checks made and puts back the vehicle they fitted (power, loudness, the trunks).
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
        for _, part in ipairs(Gear.trunkParts(vehicle)) do
            local md = part:getModData()
            if md[K.TRUNK_BASE] then
                part:setContainerCapacity(md[K.TRUNK_BASE])
                md[K.TRUNK], md[K.TRUNK_BASE], md[K.RAW], md[K.CAPACITY] = nil, nil, nil, nil
                vehicle:transmitPartModData(part)
            end
        end
    end
    fitted = {}
    say("cleaned")
end

say("finished; search the log for BAD and ERROR, then call P6_CLEAN()")
