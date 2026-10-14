-- P6 gear and kits: what the unit tests cannot reach, checked on the real game objects. Single player, a character with
-- a record (the first hello makes it). Run RUN("p6_gear.lua"); lines are tagged "[p6gear]", each ending "ok" or "BAD".
-- Use a throwaway save: the vehicle checks fit kits to the nearest vehicle within 6 squares (stand beside a car that
-- has a storage such as a trunk), and P6_CLEAN() takes back what it can (the kits it fitted to the vehicle, the items it made).
--
-- What it checks: every item of OA_gear.txt against the vanilla item it is modelled on (the fuel cans' fluid container,
-- the backpack's capacity, reduction and water storage); the shop stocks all of them; a bag kit and a weight
-- kit on a vanilla bag and on the research backpack, with and without the extension API (it reads which one is there);
-- a storage kit (on each storage part) and an engine kit on the nearest vehicle against the game's own getters; the voucher through the server
-- command; that a kit goes on any backpack.
--
-- Not scripted (do by hand): buy each good in the shop and see it arrive empty (the cans); hover a fitted bag and
-- see the kit lines; right-click a kit and a bag; fit a bag kit and a vehicle kit with the real timed action (the
-- progress bar, the notice), from the inventory menu and from the mechanics window (right-click a storage, a roof rack too,
-- and the engine part); save, quit and load: the bag's capacity and reduction, the storages, the engine power and loudness are as left;
-- drive the car with a full trunk; fit one to a modded vehicle's own storage (a KI5 car's roof rack); wear the backpack, fill its water storage at a tap and drink from it (right-click),
-- hang a radio on a shoulder-strap hanger; load a save made before the water storage (a pack bought then has it,
-- empty, and keeps its contents and kits).
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

local scripts = getScriptManager()
local api = OA.api()
local lifted = Gear.lifts(true)
say("extension API", api and "present" or "missing", "capacity key applied", tostring(lifted))

-- ---------------------------------------------------------------------------------------------------------------------
section("the items against the vanilla ones", function()
    local T = OA.Shop.TYPES
    for _, key in ipairs({ "backpack", "fuelMk1", "fuelMk2", "fuelMk3",
        "kitBagCapacity", "kitBagWeight", "kitStorage", "kitEngine" }) do
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

    local shop = OA.Shop
    for _, id in ipairs({ "team_backpack", "fuelcan_mk1", "fuelcan_mk2", "fuelcan_mk3",
        "kit_bagCapacity", "kit_bagWeight", "kit_storage", "kit_engine" }) do
        check("the shop stocks " .. id, shop.stocked(shop.entry(id)))
    end
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- ---------------------------------------------------------------------------------------------------------------------
section("bag kits", function()
    local alice = give("Base.Bag_ALICEpack")
    local kit = kitFor("bagCapacity")
    local ok, value = Gear.fitBag(player, kit, alice)
    check("capacity kit fits", ok, value)
    check("count 1 on the bag", alice:getModData()[K.BAG_CAP] == 1)
    check("original kept", alice:getModData()[K.BAG_BASE_CAP] == 28)
    check("the bag holds 31 by the game's own getter", alice:getItemContainer():getCapacity() == 31, alice:getItemContainer():getCapacity())
    check("and effective", alice:getInventory():getEffectiveCapacity(player) >= 31, alice:getInventory():getEffectiveCapacity(player))
    check("the kit is used up", kit:getContainer() == nil)
    ok, value = Gear.fitBag(player, kitFor("bagWeight"), alice)
    check("weight kit fits", ok, value)
    check("reduction 87", alice:getWeightReduction() == 87, alice:getWeightReduction())
    Gear.fitBag(player, kitFor("bagWeight"), alice)
    check("reduction 89 after two", alice:getWeightReduction() == 89, alice:getWeightReduction())
    local pack = give(OA.Shop.TYPES.backpack)
    local twin = give("Base.Bag_ALICEpack")
    check("a kit goes on another bag of the same kind too", Gear.fitBag(player, kitFor("bagCapacity"), twin))

    for _ = 1, 5 do Gear.fitBag(player, kitFor("bagCapacity"), pack) end
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
            local ok, total = Gear.fitStorage(player, kitFor("storage"), vehicle, id)
            check("storage kit fits " .. id, ok, total)
            check(id .. " counted", part:getModData()[K.STORAGE] == 1)
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
        say("this vehicle has no storage part; storage kit not checked")
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
    -- the kits already held (earlier sections made some): the new one is the one not among them
    local held = {}
    local kits = player:getInventory():getAllTypeRecurse("OperationAcorn.KitBagCapacity")
    for i = 0, kits:size() - 1 do held[kits:get(i):getID()] = true end
    OA.Sync.send(player, "gear.redeem", { item = voucher:getID(), kind = "bagCapacity" })
    -- a client command reaches the server side on a later tick, even alone: look a few ticks on
    local ticks = 0
    local function later()
        ticks = ticks + 1
        if ticks < 10 then return end
        Events.OnTick.Remove(later)
        check("the voucher is gone", voucher:getContainer() == nil)
        local kit
        kits = player:getInventory():getAllTypeRecurse("OperationAcorn.KitBagCapacity")
        for i = 0, kits:size() - 1 do
            if not held[kits:get(i):getID()] then kit = kits:get(i) end
        end
        check("a bag capacity kit arrived", kit ~= nil)
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
                md[K.STORAGE], md[K.STORAGE_BASE], md[K.RAW], md[K.CAPACITY] = nil, nil, nil, nil
                vehicle:transmitPartModData(part)
            end
        end
    end
    fitted = {}
    say("cleaned")
end

say("finished (the voucher lines follow a few ticks later); search the log for BAD and ERROR, then call P6_CLEAN()")
