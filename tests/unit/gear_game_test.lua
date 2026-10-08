-- Gear on the game side, with fake game objects: fitting each kind of kit with and without the extension API, the count
-- and the effect staying in step, the voucher, the server command, the improved torches in the recipes. The fakes
-- mimic only what Gear.lua calls.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Server"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Gear/Gear"
require "OperationAcorn/Gear/Server"
local OA = OperationAcorn
local Gear = OA.Gear
local Rules = Gear.Rules
local K = Rules.KEY

-- ---------------------------------------------------------------------------------------------------------------------
-- Fake game

local nextId = 100
local function newList(array)
    return {
        size = function() return #array end,
        get = function(_, i) return array[i + 1] end,
    }
end

-- An inventory with items; an item knows its container.
local function newInventory()
    local inv = { items = {} }
    function inv:AddItem(item)
        table.insert(self.items, item)
        item.container = self
        return item
    end
    function inv:DoRemoveItem(item)
        for i, it in ipairs(self.items) do
            if it == item then table.remove(self.items, i); break end
        end
        item.container = nil
    end
    function inv:getItemWithIDRecursiv(id)
        for _, it in ipairs(self.items) do if it.id == id then return it end end
        return nil
    end
    function inv:getItemById(id) return self:getItemWithIDRecursiv(id) end
    function inv:getAllEvalRecurse(pred)
        local found = {}
        for _, it in ipairs(self.items) do if pred(it) then found[#found + 1] = it end end
        return newList(found)
    end
    return inv
end

local function newItem(fullType, opts)
    opts = opts or {}
    nextId = nextId + 1
    local item = { id = nextId, fullType = fullType, weight = opts.weight or 0.5, bag = opts.capacity ~= nil,
        reduction = opts.reduction or 0, inner = { capacity = opts.capacity or 0 }, synced = 0 }
    function item:getID() return self.id end
    function item:getFullType() return self.fullType end
    function item:getType() return (string.match(self.fullType, "%.(.+)$")) end
    function item:getModule() return (string.match(self.fullType, "^(.-)%.")) end
    function item:getDisplayName() return opts.name or self:getType() end
    function item:hasModData() return self.md ~= nil end
    function item:getModData()
        self.md = self.md or {}
        return self.md
    end
    function item:getContainer() return self.container end
    function item:getActualWeight() return self.weight end
    function item:IsInventoryContainer() return self.bag end
    function item:getItemContainer() return self.inner end
    function item:setCapacity(n) self.inner.capacity = n end
    function item:getWeightReduction() return self.reduction end
    function item:setWeightReduction(n) self.reduction = math.max(0, math.min(100, n)) end
    function item:syncItemFields() self.synced = self.synced + 1 end
    item.inner.getCapacity = function(c) return c.capacity end
    return item
end

local function newCharacter()
    local c = { md = {}, inventory = newInventory(), x = 10, y = 10 }
    function c:getInventory() return self.inventory end
    function c:getModData() return self.md end
    function c:getX() return self.x end
    function c:getY() return self.y end
    function c:getUsername() return "tester" end
    function c:getPerkLevel() return 0 end
    return c
end

local function newPart(id, opts)
    opts = opts or {}
    local part = { id = id, md = {}, capacity = opts.capacity or 0, container = opts.container, item = opts.item }
    function part:getId() return self.id end
    function part:getModData() return self.md end
    function part:isContainer() return self.container end
    function part:getInventoryItem() return self.item end
    function part:getContainerCapacity() return self.capacity end
    function part:setContainerCapacity(n) self.capacity = n end
    return part
end

local function newVehicle(opts)
    opts = opts or {}
    nextId = nextId + 1
    local v = { id = nextId, x = 12, y = 10, name = opts.name or "CarNormal", power = opts.power or 140,
        loud = opts.loud or 37, quality = 80, transmitted = 0, partsSent = 0, parts = {} }
    for _, part in ipairs(opts.parts or {}) do v.parts[part.id] = part end
    function v:getId() return self.id end
    function v:getX() return self.x end
    function v:getY() return self.y end
    function v:getPartById(id) return self.parts[id] end
    function v:getScript()
        local name = self.name
        return { getName = function() return name end, getCarModelName = function() return name end }
    end
    function v:getEnginePower() return self.power end
    function v:getEngineLoudness() return self.loud end
    function v:getEngineQuality() return self.quality end
    -- BaseVehicle.setEngineFeature: VehicleEngine.setFeatures stores the loudness times 0.37037036, truncated
    function v:setEngineFeature(quality, loudness, power)
        self.quality = math.max(0, math.min(100, quality))
        self.loud = math.floor(loudness * 0.37037036)
        self.power = power
    end
    function v:transmitEngine() self.transmitted = self.transmitted + 1 end
    function v:transmitPartModData() self.partsSent = self.partsSent + 1 end
    TEST.vehicles = TEST.vehicles or {}
    TEST.vehicles[v.id] = v
    return v
end

local notices
local function listen()
    notices = {}
    OA.Sync.listen("notice", function(playerId, detail) notices[#notices + 1] = detail end)
end

-- The API: declared points and their status. `applied` is whether it applies the capacity key.
local function setApi(applied)
    local status = {}
    local api = { version = OA.API_VERSION, sets = {} }
    function api.client() return { name = OA.MOD } end
    api.formulas = {
        set = function(handle, name, value)
            api.sets[#api.sets + 1] = { name = name, value = value }
            if applied then status[name] = "applied" end
        end,
        points = function() return status end,
    }
    PZToolsAPI = api
    TEST.hours = (TEST.hours or 0) + 1      -- the answer is kept for a few minutes of game time
    return api
end

local function noApi()
    PZToolsAPI = nil
    TEST.hours = (TEST.hours or 0) + 1
end

local function bagFixture(fullType, capacity, reduction, weight)
    local player = newCharacter()
    local bag = newItem(fullType, { capacity = capacity, reduction = reduction, weight = weight or 2, name = "Pack" })
    player.inventory:AddItem(bag)
    return player, bag
end

local function kitOf(player, kind, target)
    local kit = newItem(Rules.kitType(kind))
    kit:getModData()[K.TARGET] = target or ""
    player.inventory:AddItem(kit)
    return kit
end

local function setup()
    TEST.vehicles = {}
    nextId = 100
    PZToolsAPI = nil
    getVehicleById = function(id) return TEST.vehicles[id] end
    instanceItem = function(fullType) return newItem(fullType) end
    sendRemoveItemFromContainer = function() end
    sendAddItemToContainer = function() end
    getItemNameFromFullType = function(t) return t end
    getTextOrNull = function() return nil end
    listen()
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Bags

test("a capacity kit without the API goes into the bag's capacity and is counted on the bag", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local kit = kitOf(player, "bagCapacity", "Base.Bag_ALICEpack")
    local ok, value = Gear.fitBag(player, kit, bag)
    truthy(ok)
    eq(value, 31)
    eq(bag.inner.capacity, 31)
    eq(bag.md[K.BAG_CAP], 1)
    eq(bag.md[K.BAG_BASE_CAP], 28)
    eq(bag.md[K.CAPACITY], nil, "no API: nothing for it to add")
    eq(kit.container, nil, "the kit is used up")
    eq(#player.inventory.items, 1)
    eq(notices[1].key, "IGUI_OA_Gear_Fitted_bagCapacity")
    eq(notices[1].args[2], "31")
    eq(bag.synced, 1)
end)

test("kits stack on one bag: the count rises, the value comes from the original", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    for n = 1, 4 do
        local ok = Gear.fitBag(player, kitOf(player, "bagCapacity"), bag)
        truthy(ok)
        eq(bag.md[K.BAG_CAP], n)
        eq(bag.inner.capacity, Rules.capacity(28, n))
    end
    eq(bag.md[K.BAG_BASE_CAP], 28, "the original is kept from the first kit")
end)

test("a weight kit lifts the bag's weight reduction toward 95", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    truthy(Gear.fitBag(player, kitOf(player, "bagWeight"), bag))
    eq(bag.reduction, 87)
    truthy(Gear.fitBag(player, kitOf(player, "bagWeight"), bag))
    eq(bag.reduction, 89)            -- 88.6
    eq(bag.md[K.BAG_WEIGHT], 2)
    eq(bag.inner.capacity, 28, "the capacity is not touched by a weight kit")
    eq(notices[2].args[2], "89%")
end)

test("without the API the game's limit cuts the capacity and the count still goes up", function()
    setup()
    local player, bag = bagFixture("OperationAcorn.TeamBackpack", 35, 85, 2)
    for _ = 1, 5 do truthy(Gear.fitBag(player, kitOf(player, "bagCapacity"), bag)) end
    eq(bag.md[K.BAG_CAP], 5)
    eq(bag.inner.capacity, 48, "50 less the bag's own weight of 2")
    local info = Gear.bagInfo(bag)
    eq(info.total, 53)
    eq(info.limit, 48)
    eq(info.cut, true)
    local lines = Gear.bagLines(bag)
    eq(#lines, 2)
    truthy(string.find(lines[2], "Tooltip_OA_Gear_BagCut", 1, true), "the tooltip says what the limit is")
end)

test("with the API the original stays and OA_Capacity adds the kits, past the limit", function()
    setup()
    setApi(true)
    local player, bag = bagFixture("OperationAcorn.TeamBackpack", 35, 85, 2)
    for n = 1, 5 do truthy(Gear.fitBag(player, kitOf(player, "bagCapacity"), bag)) end
    eq(bag.inner.capacity, 35, "the raw capacity is the original")
    eq(bag.md[K.CAPACITY], 18, "52.5 rounds to 53, 18 more than 35")
    eq(Gear.bagInfo(bag).cut, false)
    eq(#Gear.bagLines(bag), 1, "no word about a limit")
    local declared = false
    for _, s in ipairs(PZToolsAPI.sets) do if s.name == "capacity.modDataKey" and s.value == "OA_Capacity" then declared = true end end
    truthy(declared, "the key is declared when the upgrades part has not yet")
end)

test("the key the API reads is the number, never a boolean", function()
    setup()
    setApi(true)
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    truthy(Gear.fitBag(player, kitOf(player, "bagCapacity"), bag))
    eq(type(bag.md[K.CAPACITY]), "number")
    eq(bag.md[K.CAPACITY], 3)
end)

test("a bag fitted without the API is written again when the API is there, and back", function()
    setup()
    local player, bag = bagFixture("OperationAcorn.TeamBackpack", 35, 85, 2)
    for _ = 1, 5 do Gear.fitBag(player, kitOf(player, "bagCapacity"), bag) end
    eq(bag.inner.capacity, 48)
    setApi(true)
    Gear.refreshBag(bag)
    eq(bag.inner.capacity, 35)
    eq(bag.md[K.CAPACITY], 18)
    -- and writing it again changes nothing
    local synced = bag.synced
    Gear.refreshBag(bag)
    eq(bag.inner.capacity, 35)
    noApi()
    Gear.refreshBag(bag)
    eq(bag.inner.capacity, 48)
    eq(bag.md[K.CAPACITY], nil)
    eq(bag.md[K.BAG_CAP], 5, "the count was never touched")
end)

test("refreshAll finds fitted bags in the inventory, in bags too", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    Gear.fitBag(player, kitOf(player, "bagCapacity"), bag)
    Gear.fitBag(player, kitOf(player, "bagWeight"), bag)
    bag.inner.capacity = 28
    bag.reduction = 85
    bag.md[K.RAW] = nil
    local plain = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85 })
    player.inventory:AddItem(plain)
    eq(Gear.refreshAll(player), 1, "only the fitted bag")
    eq(bag.inner.capacity, 31)
    eq(bag.reduction, 87)
    eq(plain.md, nil, "a bag without kits gets no modData made for it")
end)

test("a kit ordered for one bag does not go on another", function()
    setup()
    local player, bag = bagFixture("OperationAcorn.TeamBackpack", 35, 85)
    local kit = kitOf(player, "bagCapacity", "Base.Bag_ALICEpack")
    local ok, why = Gear.fitBag(player, kit, bag)
    eq(ok, false)
    eq(why, "target")
    eq(kit.container, player.inventory, "the kit is still there")
    eq(bag.md, nil, "and the bag is not touched")
    -- a kit for any target goes on
    truthy(Gear.fitBag(player, kitOf(player, "bagCapacity", ""), bag))
end)

test("a vehicle kit does not go on a bag, a bag kit not on a vehicle", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    eq(select(2, Gear.fitBag(player, kitOf(player, "trunk"), bag)), "kit")
    local vehicle = newVehicle({ parts = { newPart("TruckBed", { container = true, capacity = 100 }), newPart("Engine") } })
    eq(select(2, Gear.fitTrunk(player, kitOf(player, "bagCapacity"), vehicle)), "kit")
    eq(select(2, Gear.fitEngine(player, kitOf(player, "trunk"), vehicle)), "kit")
    local notBag = newItem("Base.Hammer")
    player.inventory:AddItem(notBag)
    eq(select(2, Gear.fitBag(player, kitOf(player, "bagCapacity"), notBag)), "bag")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- Trunks

local function carWithTrunk(capacity, opts)
    local trunk = newPart("TruckBed", { container = true, capacity = capacity,
        item = opts and opts.item or nil })
    local car = newVehicle({ parts = { trunk, newPart("Engine"), newPart("TruckBedOpen", { container = false }) } })
    return car, trunk
end

test("a trunk kit without the API raises the trunk part's capacity, counted on the part", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(100)
    local ok, total = Gear.fitTrunk(player, kitOf(player, "trunk", "CarNormal"), car)
    truthy(ok)
    eq(total, 110)
    eq(trunk.capacity, 110)
    eq(trunk.md[K.TRUNK], 1)
    eq(trunk.md[K.TRUNK_BASE], 100)
    eq(trunk.md[K.CAPACITY], nil)
    truthy(car.partsSent > 0, "the part's data is sent")
    eq(Gear.trunkKits(car), 1)
    eq(notices[1].key, "IGUI_OA_Gear_Fitted_trunk")
end)

test("a trunk kit with the API leaves the capacity and adds the number", function()
    setup()
    setApi(true)
    local player = newCharacter()
    local car, trunk = carWithTrunk(100)
    for n = 1, 3 do truthy(Gear.fitTrunk(player, kitOf(player, "trunk"), car)) end
    eq(trunk.capacity, 100)
    eq(trunk.md[K.CAPACITY], 30)
    eq(type(trunk.md[K.CAPACITY]), "number")
    eq(Gear.trunkInfo(car).total, 130)
    eq(Gear.trunkInfo(car).cut, false)
end)

test("the trunk's original is the installed trunk item's maximum, not what a damaged trunk holds now", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(60, { item = { getMaxCapacity = function() return 120 end } })
    truthy(Gear.fitTrunk(player, kitOf(player, "trunk"), car))
    eq(trunk.md[K.TRUNK_BASE], 120)
    eq(trunk.capacity, 132)
end)

test("a trunk kit goes on every trunk part the vehicle has and leaves the rest", function()
    setup()
    local player = newCharacter()
    local closed = newPart("TruckBed", { container = true, capacity = 100 })
    local open = newPart("TruckBedOpen", { container = true, capacity = 150 })
    local car = newVehicle({ parts = { closed, open, newPart("Engine") } })
    truthy(Gear.fitTrunk(player, kitOf(player, "trunk"), car))
    eq(closed.capacity, 110)
    eq(open.capacity, 165)
    eq(Gear.trunkKits(car), 1)
end)

test("past the vehicle limit the trunk is cut without the API", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(900)
    for _ = 1, 3 do truthy(Gear.fitTrunk(player, kitOf(player, "trunk"), car)) end
    eq(trunk.capacity, 1000)
    eq(Gear.trunkInfo(car).cut, true)
    eq(#Gear.trunkLines(car), 2)
end)

test("a trunk fitted without the API is refreshed when the API is there", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(100)
    Gear.fitTrunk(player, kitOf(player, "trunk"), car)
    eq(trunk.capacity, 110)
    setApi(true)
    Gear.refreshVehicle(car)
    eq(trunk.capacity, 100)
    eq(trunk.md[K.CAPACITY], 10)
    noApi()
    Gear.refreshVehicle(car)
    eq(trunk.capacity, 110)
    eq(trunk.md[K.CAPACITY], nil)
end)

test("vehicle kits need the character beside the vehicle, the right vehicle and the part", function()
    setup()
    local player = newCharacter()
    local car = carWithTrunk(100)
    car.x = 100
    eq(select(2, Gear.fitTrunk(player, kitOf(player, "trunk"), car)), "far")
    car.x = 12
    eq(select(2, Gear.fitTrunk(player, kitOf(player, "trunk", "PickUpVan"), car)), "target")
    eq(select(2, Gear.fitTrunk(player, kitOf(player, "trunk"), nil)), "gone")
    local bare = newVehicle({ parts = { newPart("Engine") } })
    eq(select(2, Gear.fitTrunk(player, kitOf(player, "trunk"), bare)), "part")
    truthy(Gear.fitTrunk(player, kitOf(player, "trunk", "CarNormal"), car), "the right script name fits")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- Engines

test("an engine kit adds a tenth of the power and a twentieth of the loudness, from the original", function()
    setup()
    local player = newCharacter()
    local car = newVehicle({ power = 140, loud = 37, parts = { newPart("Engine") } })
    local ok, power = Gear.fitEngine(player, kitOf(player, "engine"), car)
    truthy(ok)
    eq(power, 154)
    eq(car.power, 154)
    eq(car.loud, 39)
    eq(car.quality, 80, "the quality is kept")
    eq(car.transmitted, 1)
    local md = car.parts.Engine.md
    eq(md[K.ENGINE], 1); eq(md[K.ENGINE_POWER], 140); eq(md[K.ENGINE_LOUD], 37)
    truthy(Gear.fitEngine(player, kitOf(player, "engine"), car))
    eq(car.power, 168)
    eq(car.loud, 41)
    eq(md[K.ENGINE_POWER], 140, "the original is not overwritten")
    eq(Gear.engineKits(car), 2)
    eq(notices[2].args[2], "16.8")
end)

test("the engine survives the game putting the script's values back, and refresh is not a write when it is right", function()
    setup()
    local player = newCharacter()
    local car = newVehicle({ power = 140, loud = 37, parts = { newPart("Engine") } })
    Gear.fitEngine(player, kitOf(player, "engine"), car)
    local sent = car.transmitted
    eq(Gear.refreshEngine(car), false)
    eq(car.transmitted, sent, "nothing to write")
    car.power, car.loud = 140, 37       -- a debug repair of the engine part
    eq(Gear.refreshEngine(car), true)
    eq(car.power, 154); eq(car.loud, 39)
end)

test("an engine kit wants a vehicle, an engine, the right script and the character beside it", function()
    setup()
    local player = newCharacter()
    local noEngine = newVehicle({ parts = { newPart("TruckBed", { container = true }) } })
    eq(select(2, Gear.fitEngine(player, kitOf(player, "engine"), noEngine)), "part")
    local car = newVehicle({ parts = { newPart("Engine") } })
    eq(select(2, Gear.fitEngine(player, kitOf(player, "engine", "PickUpVan"), car)), "target")
    car.y = 80
    eq(select(2, Gear.fitEngine(player, kitOf(player, "engine"), car)), "far")
    eq(Gear.fitVehicle(player, kitOf(player, "bagWeight"), car), false)
end)

test("the lines about a vehicle's kits", function()
    setup()
    local player = newCharacter()
    local car = newVehicle({ power = 140, loud = 37, parts = { newPart("Engine"), newPart("TruckBed", { container = true, capacity = 100 }) } })
    eq(Gear.engineLines(car), nil)
    eq(Gear.trunkLines(car), nil)
    Gear.fitVehicle(player, kitOf(player, "engine"), car)
    Gear.fitVehicle(player, kitOf(player, "trunk"), car)
    eq(Gear.engineLines(car)[1], "Tooltip_OA_Gear_EngineKits 1 15.4 39")
    eq(Gear.trunkLines(car)[1], "Tooltip_OA_Gear_TrunkKits 1 110")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The voucher and the shop

local function shopRecord()
    local record = OA.Store.ensure("g", "G")
    record.trade = { credits = 1000000, trust = 0, stage = 5, milestones = 1, bonus = 0, sharedSerums = 0 }
    return record
end

test("the voucher gives one kit of the kind chosen, for any target, and the shop does not count it", function()
    setup()
    local record = shopRecord()
    local player = newCharacter()
    local voucher = newItem(Gear.VOUCHER)
    player.inventory:AddItem(voucher)
    local before = OA.Shop.kitPrice("bagCapacity", "Base.Bag_ALICEpack", record)
    local ok = Gear.redeem(player, voucher, "bagCapacity")
    truthy(ok)
    eq(voucher.container, nil, "the voucher is used up")
    eq(#player.inventory.items, 1)
    local kit = player.inventory.items[1]
    eq(kit:getFullType(), "OperationAcorn.KitBagCapacity")
    eq(kit.md[K.TARGET], "")
    eq(kit.md[K.VOUCHER], true)
    eq(OA.Shop.kitPrice("bagCapacity", "Base.Bag_ALICEpack", record), before, "the next kit costs what it did")
    eq(OA.Shop.kitsFor("bagCapacity", "Base.Bag_ALICEpack", record), 0)
    -- it fits any bag, and then counts on that bag like any kit
    local bag = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85 })
    player.inventory:AddItem(bag)
    truthy(Gear.fitBag(player, kit, bag))
    eq(bag.md[K.BAG_CAP], 1)
    eq(OA.Shop.kitsFor("bagCapacity", "Base.Bag_ALICEpack", record), 0, "still not the shop's count")
end)

test("a bought kit is counted by the shop for its target and by the bag for the bag", function()
    setup()
    local record = shopRecord()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local entry = OA.Shop.entry("kit_bagCapacity")
    OA.Shop.bought(entry, record, 1, "Base.Bag_ALICEpack")
    eq(OA.Shop.kitsFor("bagCapacity", "Base.Bag_ALICEpack", record), 1)
    -- the delivered kit carries the target string the shop counted under, and only that bag takes it
    local kit = kitOf(player, "bagCapacity", "Base.Bag_ALICEpack")
    truthy(Gear.fitBag(player, kit, bag))
    eq(bag.md[K.BAG_CAP], 1)
    truthy(OA.Shop.kitPrice("bagCapacity", "Base.Bag_ALICEpack", record) > OA.Shop.KITS.bagCapacity.price)
end)

test("the order's kit carries the target in OA_Target, the key this part reads", function()
    setup()
    require "OperationAcorn/Trade/Orders"
    local entry = OA.Shop.entry("kit_trunk")
    local specs = OA.Trade.Orders.itemSpecs(entry, { id = "kit_trunk", count = 1, target = "CarNormal" })
    eq(#specs, 1)
    eq(specs[1].type, "OperationAcorn.KitTrunk")
    eq(specs[1].mod[K.TARGET], "CarNormal")
end)

test("the server command redeems the voucher a character names", function()
    setup()
    local player = newCharacter()
    player.inventory:AddItem(newItem(Gear.VOUCHER))
    local voucher = player.inventory.items[1]
    OA.Sync.send(player, "gear.redeem", { item = voucher:getID(), kind = "trunk" })
    eq(#player.inventory.items, 1)
    eq(player.inventory.items[1]:getFullType(), "OperationAcorn.KitTrunk")
    -- another item, or a kind that is not one, does nothing and says why
    local other = newItem("Base.Hammer")
    player.inventory:AddItem(other)
    OA.Sync.send(player, "gear.redeem", { item = other:getID(), kind = "trunk" })
    eq(#player.inventory.items, 2)
    eq(notices[#notices].key, "IGUI_OA_Gear_Failed")
    eq(notices[#notices].args[1], "voucher")
    local v2 = newItem(Gear.VOUCHER)
    player.inventory:AddItem(v2)
    OA.Sync.send(player, "gear.redeem", { item = v2:getID(), kind = "nonsense" })
    eq(v2.container, player.inventory, "a voucher for no kit is kept")
    eq(notices[#notices].args[1], "kind")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The improved torches in the vanilla recipes

local TORCHES = { "OperationAcorn.TorchMk1", "OperationAcorn.TorchMk2", "OperationAcorn.TorchMk3" }

-- A script manager with the items by name and the recipe lists; `torches` false leaves the vanilla torch out.
local function newScriptManager(recipes, items)
    return {
        FindItem = function(_, name) return items[name] end,
        getAllCraftRecipes = function() return newList(recipes.craft) end,
        getAllBuildableRecipes = function() return newList(recipes.build) end,
    }
end

local function newScripts()
    local items = {}
    for _, name in ipairs({ "Base.BlowTorch", "Base.Hammer", TORCHES[1], TORCHES[2], TORCHES[3] }) do
        items[name] = { name = name }
    end
    return items
end

local function newRecipe(name, inputs)
    return { getName = function() return name end, getInputs = function() return newList(inputs) end }
end

-- A craft input: it lists the item scripts it accepts and hands the list out (the stand-in for the ArrayList).
local function newInput(list, opts)
    opts = opts or {}
    local input = { list = list }
    function input:isAcceptsAnyItem() return opts.any or false end
    function input:getPossibleInputItems() return self end
    function input:containsItem(script)
        for _, s in ipairs(self.list) do if s == script then return true end end
        return false
    end
    function input:add(script)
        if opts.locked then error("unmodifiable") end
        table.insert(self.list, script)
        return true
    end
    return input
end

test("the improved torches join every craft input that lists the vanilla torch, but not the refill recipe", function()
    setup()
    local items = newScripts()
    local vanilla, hammer = items["Base.BlowTorch"], items["Base.Hammer"]
    local weapon = newInput({ vanilla })
    local tool = newInput({ hammer })
    local any = newInput({ vanilla }, { any = true })
    local refill = newInput({ vanilla })
    local wall = newInput({ vanilla, hammer })
    local locked = newInput({ vanilla }, { locked = true })
    local recipes = {
        craft = { newRecipe("MakeBlockBludgeon", { weapon, tool, any }), newRecipe("RefillBlowTorch", { refill }),
            newRecipe("Locked", { locked }) },
        build = { newRecipe("BuildWall", { wall }) },
    }
    getScriptManager = function() return newScriptManager(recipes, items) end
    eq(Gear.extendRecipes(), 2, "the weapon input and the wall input")
    eq(#weapon.list, 4)
    truthy(weapon:containsItem(items[TORCHES[1]]))
    truthy(weapon:containsItem(items[TORCHES[3]]))
    eq(#tool.list, 1, "an input without the torch is left alone")
    eq(#any.list, 1, "so is an input that takes any item")
    eq(#refill.list, 1, "refilling replaces the torch with a vanilla one: it takes the vanilla torch only")
    eq(#wall.list, 5)
    eq(#locked.list, 1, "an input that cannot be changed is left and the rest goes on")
    -- once more changes nothing
    eq(Gear.extendRecipes(), 0)
    eq(#weapon.list, 4)
end)

test("without the script manager or the vanilla torch the recipes are left alone", function()
    setup()
    getScriptManager = nil
    eq(Gear.extendRecipes(), 0)
    getScriptManager = function() return { FindItem = function() return nil end } end
    eq(Gear.extendRecipes(), 0)
end)

test("the recipes are extended when the game starts", function()
    setup()
    local items = newScripts()
    local weapon = newInput({ items["Base.BlowTorch"] })
    local recipes = { craft = { newRecipe("MakeBlockBludgeon", { weapon }) }, build = {} }
    getScriptManager = function() return newScriptManager(recipes, items) end
    TEST.fire("OnGameStart")
    eq(#weapon.list, 4)
end)
