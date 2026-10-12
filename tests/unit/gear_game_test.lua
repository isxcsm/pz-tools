-- Gear on the game side, with fake game objects: fitting each kind of kit with and without the extension API, the count
-- and the effect staying in step, the voucher, the server command. The fakes
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
-- the game's body locations a bag is worn at (registry objects in the game; any distinct values do here)
ItemBodyLocation = ItemBodyLocation or { BACK = "back", FANNY_PACK_FRONT = "fannypackfront" }
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
    function inv:getItems() return newList(self.items) end
    function inv:getContentsWeight()
        local w = 0
        for _, it in ipairs(self.items) do w = w + it.weight end
        return w
    end
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
        slot = opts.slot or (opts.capacity ~= nil and ItemBodyLocation.BACK or nil),
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
    function item:canBeEquipped() return self.slot end
    if opts.noSlot then item.slot = nil end
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
    local kit = kitOf(player, "bagCapacity", Gear.bagKey(bag))
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
    local kit = kitOf(player, "bagCapacity", Gear.bagKey(newItem("Base.Bag_ALICEpack")))
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
    local ok, total = Gear.fitTrunk(player, kitOf(player, "trunk", Gear.vehicleId(car, true)), car)
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
    truthy(Gear.fitTrunk(player, kitOf(player, "trunk", Gear.vehicleId(car, true)), car), "the right vehicle fits")
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
    OA.Shop.bought(entry, record, 1, Gear.bagKey(bag))
    eq(OA.Shop.kitsFor("bagCapacity", Gear.bagKey(bag), record), 1)
    -- the delivered kit carries the target string the shop counted under, and only that bag takes it
    local kit = kitOf(player, "bagCapacity", Gear.bagKey(bag))
    truthy(Gear.fitBag(player, kit, bag))
    eq(bag.md[K.BAG_CAP], 1)
    truthy(OA.Shop.kitPrice("bagCapacity", Gear.bagKey(bag), record) > OA.Shop.KITS.bagCapacity.price)
end)

test("the order's kit carries the target in OA_Target, the key this part reads", function()
    setup()
    require "OperationAcorn/Trade/Orders"
    local entry = OA.Shop.entry("kit_trunk")
    local specs = OA.Trade.Orders.itemSpecs(entry, { id = "kit_trunk", count = 1, target = "v123456-7" })
    eq(#specs, 1)
    eq(specs[1].type, "OperationAcorn.KitTrunk")
    eq(specs[1].mod[K.TARGET], "v123456-7")
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
    eq(notices[#notices].key, "IGUI_OA_Gear_RedeemFailed")
    eq(notices[#notices].args[1], "voucher")
    local v2 = newItem(Gear.VOUCHER)
    player.inventory:AddItem(v2)
    OA.Sync.send(player, "gear.redeem", { item = v2:getID(), kind = "nonsense" })
    eq(v2.container, player.inventory, "a voucher for no kit is kept")
    eq(notices[#notices].args[1], "kind")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- One bag, one vehicle: the target is an instance, not a type

test("a kit ordered for one bag does not go on another bag of the same kind", function()
    setup()
    local player, first = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local second = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85 })
    player.inventory:AddItem(second)
    truthy(Gear.bagKey(first) ~= Gear.bagKey(second), "two bags, two keys")
    local kit = kitOf(player, "bagCapacity", Gear.bagKey(first))
    local ok, why = Gear.fitBag(player, kit, second)
    eq(ok, false); eq(why, "target")
    eq(second.md, nil)
    truthy(Gear.fitBag(player, kit, first))
    eq(first.md[K.BAG_CAP], 1)
end)

test("the shop's price rises per bag: a kit bought for one bag does not make the other dearer", function()
    setup()
    local record = shopRecord()
    local player, first = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local second = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85 })
    player.inventory:AddItem(second)
    local entry = OA.Shop.entry("kit_bagCapacity")
    local base = OA.Shop.kitPrice("bagCapacity", Gear.bagKey(second), record)
    OA.Shop.bought(entry, record, 1, Gear.bagKey(first))
    eq(OA.Shop.kitPrice("bagCapacity", Gear.bagKey(second), record), base, "the other bag costs what it did")
    truthy(OA.Shop.kitPrice("bagCapacity", Gear.bagKey(first), record) > base, "this one costs more")
end)

test("a bag key is the item id, as a string, and is the same when the bag is in another container", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local key = Gear.bagKey(bag)
    eq(key, tostring(bag:getID()))
    local other = newInventory()
    player.inventory:DoRemoveItem(bag)
    other:AddItem(bag)
    eq(Gear.bagKey(bag), key)
end)

test("the shop's targets are the bags the character has, by id, and a second bag of a name is numbered", function()
    setup()
    local player, first = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local second = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85, name = "Pack" })
    player.inventory:AddItem(second)
    local hammer = newItem("Base.Hammer")
    player.inventory:AddItem(hammer)
    -- a key ring and a fanny pack are containers, not backpacks: no bag kit goes to them
    local ring = newItem("Base.KeyRing", { capacity = 1, noSlot = true })
    local fanny = newItem("Base.Bag_FannyPackFront", { capacity = 4, slot = ItemBodyLocation.FANNY_PACK_FRONT })
    player.inventory:AddItem(ring)
    player.inventory:AddItem(fanny)
    local targets = Gear.bagTargets(player)
    eq(#targets, 2, "the hammer, the key ring and the fanny pack are not backpacks")
    eq(Gear.isBackpack(ring), false)
    eq(Gear.isBackpack(fanny), false)
    local kit = newItem("OperationAcorn.KitBagCapacity")
    player.inventory:AddItem(kit)
    local ok, why = Gear.fitBag(player, kit, ring)
    eq(ok, false); eq(why, "bag", "a kit is not fitted to a key ring")
    eq(targets[1].target, Gear.bagKey(first))
    eq(targets[2].target, Gear.bagKey(second))
    eq(targets[1].name, "Pack #1")
    eq(targets[2].name, "Pack #2")
end)

test("a vehicle gets an id the first time it is chosen, on its parts, and keeps it", function()
    setup()
    local car, trunk = carWithTrunk(100)
    eq(Gear.vehicleId(car), nil)
    eq(Gear.vehicleKey(car), "")
    local id = Gear.vehicleId(car, true)
    truthy(id and id ~= "")
    eq(trunk.md[K.VEHICLE_ID], id)
    eq(car.parts.Engine.md[K.VEHICLE_ID], id, "the engine part carries it too")
    eq(Gear.vehicleId(car, true), id, "asking again gives the same one")
    eq(Gear.vehicleKey(car), id)
    -- the game saves the parts' modData: a reloaded vehicle is the same parts with the same data
    local reloaded = newVehicle({ parts = { newPart("Engine"), newPart("TruckBed", { container = true, capacity = 100 }) } })
    reloaded.parts.Engine.md[K.VEHICLE_ID] = id
    eq(Gear.vehicleKey(reloaded), id)
    -- a vehicle with neither engine nor trunk is nobody's target
    local bare = newVehicle({ parts = { newPart("Door") } })
    eq(Gear.vehicleId(bare, true), nil)
end)

test("two vehicles of one kind have two ids and a kit goes only to the one it was ordered for", function()
    setup()
    local player = newCharacter()
    local first = carWithTrunk(100)
    local second = carWithTrunk(100)
    local a, b = Gear.vehicleId(first, true), Gear.vehicleId(second, true)
    truthy(a ~= b)
    local kit = kitOf(player, "trunk", a)
    eq(select(2, Gear.fitTrunk(player, kit, second)), "target")
    truthy(Gear.fitTrunk(player, kit, first))
    local engineKit = kitOf(player, "engine", b)
    eq(select(2, Gear.fitEngine(player, engineKit, first)), "target")
    truthy(Gear.fitEngine(player, engineKit, second))
    eq(Gear.engineKits(first), 0)
    eq(Gear.engineKits(second), 1)
end)

test("a vehicle never chosen as a target takes only a kit for any", function()
    setup()
    local player = newCharacter()
    local car = carWithTrunk(100)
    eq(select(2, Gear.fitTrunk(player, kitOf(player, "trunk", "v1-1"), car)), "target")
    truthy(Gear.fitTrunk(player, kitOf(player, "trunk", ""), car))
end)

test("a client gives the server the id it made, and the server keeps one that is already there", function()
    setup()
    local player = newCharacter()
    local car = carWithTrunk(100)
    isClient = function() return true end
    getPlayer = function() return player end
    TEST.sent = {}
    local id = Gear.vehicleId(car, true)
    eq(#TEST.sent, 1)
    eq(TEST.sent[1].command, "gear.tag")
    eq(TEST.sent[1].args.tag, id)
    eq(TEST.sent[1].args.vehicle, car:getId())
    isClient = function() return false end
    getPlayer = nil
    -- the server side: a vehicle without an id takes the client's; one with an id keeps its own
    local fresh = carWithTrunk(100)
    OA.Sync.send(player, "gear.tag", { vehicle = fresh:getId(), tag = "vclient-1" })
    eq(Gear.vehicleId(fresh), "vclient-1")
    OA.Sync.send(player, "gear.tag", { vehicle = fresh:getId(), tag = "vother-2" })
    eq(Gear.vehicleId(fresh), "vclient-1")
    OA.Sync.send(player, "gear.tag", { vehicle = fresh:getId(), tag = 5 })
    eq(Gear.vehicleId(fresh), "vclient-1")
end)

test("the shop's targets near a character: vehicles that take the kind of kit, within reach, each with an id", function()
    setup()
    local player = newCharacter()
    local near1 = carWithTrunk(100)
    local far = carWithTrunk(100)
    far.x = 500
    local noTrunk = newVehicle({ parts = { newPart("Engine") } })
    getCell = function() return { getVehicles = function() return { items = { near1, far, noTrunk } } end } end
    local trunks = Gear.vehicleTargets(player, "trunk", 40)
    eq(#trunks, 1)
    eq(trunks[1].target, Gear.vehicleId(near1))
    truthy(string.find(trunks[1].name, "IGUI_OA_Gear_Away", 1, true), "the name tells how far")
    eq(#Gear.vehicleTargets(player, "engine", 40), 2, "the near car and the one without a trunk, not the far one")
    eq(far.parts.Engine.md[K.VEHICLE_ID], nil, "a vehicle out of reach is not tagged")
end)

test("a kit's target is found again as the bag or the vehicle, and named; not with the character is said so", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    bag.name = nil
    local car = carWithTrunk(100)
    getCell = function() return { getVehicles = function() return { items = { car } } end } end
    eq(Gear.findTarget("bagCapacity", Gear.bagKey(bag), player), bag)
    eq(Gear.findTarget("trunk", Gear.vehicleId(car, true), player), car)
    eq(Gear.targetName("bagCapacity", Gear.bagKey(bag), player), "Pack")
    eq(Gear.targetName("bagCapacity", "", player), "IGUI_OA_Gear_AnyTarget")
    eq(Gear.targetName("bagCapacity", "99999", player), "IGUI_OA_Gear_TargetUnknown")
    eq(Gear.targetName("trunk", "vnone-1", player), "IGUI_OA_Gear_TargetUnknown")
    eq(Gear.targetName("trunk", Gear.vehicleId(car), player), "CarNormal")
end)

test("a voucher kit goes to any bag or vehicle and the shop does not count it", function()
    setup()
    local record = shopRecord()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local car = carWithTrunk(100)
    local voucher = newItem(Gear.VOUCHER)
    player.inventory:AddItem(voucher)
    Gear.redeem(player, voucher, "trunk")
    local kit = player.inventory.items[#player.inventory.items]
    eq(Gear.targetOf(kit), "")
    local price = OA.Shop.kitPrice("trunk", Gear.vehicleKey(car), record)
    truthy(Gear.fitTrunk(player, kit, car))
    eq(Gear.trunkKits(car), 1)
    eq(OA.Shop.kitsFor("trunk", Gear.vehicleId(car, true), record), 0)
    eq(OA.Shop.kitPrice("trunk", Gear.vehicleKey(car), record), price)
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- What a character carries, kept per inventory signature; the menus and the actions that read it

test("the bags and kits a character carries are found by one search, kept while the inventory is the same", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local kit = kitOf(player, "bagCapacity", "")
    local plain = newItem("Base.Hammer")
    player.inventory:AddItem(plain)
    local searches = 0
    local search = player.inventory.getAllEvalRecurse
    player.inventory.getAllEvalRecurse = function(self, pred) searches = searches + 1 return search(self, pred) end
    local carried = Gear.carried(player)
    eq(searches, 1)
    eq(#carried.bags, 1)
    eq(carried.bags[1], bag)
    eq(#carried.kits.bagCapacity, 1)
    eq(carried.kits.bagCapacity[1], kit)
    eq(Gear.carried(player), carried)
    eq(Gear.carried(player), carried)
    eq(searches, 1, "the same inventory: not searched again")
    -- an item comes: searched again
    kitOf(player, "bagWeight", "")
    local again = Gear.carried(player)
    eq(searches, 2)
    eq(#again.kits.bagWeight, 1)
    -- a kit used up (its weight goes too): searched again, and it is gone
    player.inventory:DoRemoveItem(kit)
    eq(#(Gear.carried(player).kits.bagCapacity or {}), 0, "it is gone")
    eq(searches, 3)
    -- the target lookups use it
    eq(Gear.findTarget("bagCapacity", Gear.bagKey(bag), player), bag)
    eq(searches, 3, "findTarget does not search")
end)

test("a fitting action checks its kit and bag by the objects it was made with, without searching the inventory", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local kit = kitOf(player, "bagCapacity", Gear.bagKey(bag))
    local searches = 0
    local find = player.inventory.getItemWithIDRecursiv
    player.inventory.getItemWithIDRecursiv = function(self, id) searches = searches + 1 return find(self, id) end
    function player.inventory:getContainingItem() return nil end
    local action = { character = player, kit = kit, bag = bag, kitId = kit:getID(), bagId = bag:getID() }
    for _ = 1, 5 do
        eq(Gear.heldItem(action, "kit", "kitId"), kit)
        eq(Gear.heldItem(action, "bag", "bagId"), bag)
    end
    eq(searches, 0, "ticks of the action: no search")
    -- the kit is gone: looked for once by its id, and not found
    player.inventory:DoRemoveItem(kit)
    eq(Gear.heldItem(action, "kit", "kitId"), nil)
    truthy(searches > 0, "looked for by its id")
end)

-- The kit menus, with the game's UI classes as stand-ins.
local function menuStubs()
    local function stubClass()
        local c = {}
        c.derive = function() return stubClass() end
        return setmetatable(c, { __index = function() return function() end end })
    end
    for _, class in ipairs({ "ISToolTip", "ISToolTipInv", "ISInventoryPaneContextMenu", "ISVehicleMechanics",
        "ISInventoryPane", "ISContextMenu", "ISBaseTimedAction" }) do
        _G[class] = stubClass()
    end
    ISToolTip.new = function() return { initialise = function() end, setVisible = function() end } end
    ISInventoryPane.getActualItems = function(items) return items end
    local function newMenu()
        local menu = { options = {} }
        function menu:addOption(name, target, fn, a, b)
            local o = { name = name, target = target, onSelect = fn, param1 = a, param2 = b }
            self.options[#self.options + 1] = o
            return o
        end
        function menu:addOptionOnTop(name, target, fn, a, b)
            local o = { name = name, target = target, onSelect = fn, param1 = a, param2 = b }
            table.insert(self.options, 1, o)
            return o
        end
        function menu:addSubMenu(o, sub) o.subOption = sub end
        return menu
    end
    ISContextMenu.getNew = function() return newMenu() end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or string.find(name, "^Vehicles/") or string.find(name, "^TimedActions/")
            or name == "OperationAcorn/Client" then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Gear/Menu")
    require = real
    if not ok then error(err, 0) end
    return newMenu
end

test("the kit entries go on top of the inventory menu, and building them searches the inventory once for a signature", function()
    setup()
    local newMenu = menuStubs()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local kit = kitOf(player, "bagCapacity", Gear.bagKey(bag))
    local searches = 0
    local search = player.inventory.getAllEvalRecurse
    player.inventory.getAllEvalRecurse = function(self, pred) searches = searches + 1 return search(self, pred) end
    getSpecificPlayer = function() return player end
    -- right-click on the bag: "fit a kit" above the game's own
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillInventoryObjectContextMenu", 0, menu, { bag })
    eq(menu.options[1].name, "ContextMenu_OA_Gear_FitKit")
    eq(menu.options[2].name, "Vanilla")
    eq(#menu.options[1].subOption.options, 1, "the one kind of kit in hand")
    eq(searches, 1)
    -- again, and on the kit: no new search
    TEST.fire("OnFillInventoryObjectContextMenu", 0, menu, { bag })
    local onKit = newMenu()
    onKit:addOption("Vanilla")
    TEST.fire("OnFillInventoryObjectContextMenu", 0, onKit, { kit })
    eq(onKit.options[1].name, "ContextMenu_OA_Gear_FitBag")
    eq(onKit.options[2].name, "Vanilla")
    eq(#onKit.options[1].subOption.options, 1, "the bag the kit was ordered for")
    eq(searches, 1, "three menus, one search")
    -- the inventory changed
    player.inventory:AddItem(newItem("Base.Hammer"))
    TEST.fire("OnFillInventoryObjectContextMenu", 0, newMenu(), { bag })
    eq(searches, 2)
end)

test("the improved fuel cans weigh, full and carried, what they are set to: Mk.I as a full plain can, the later ones less", function()
    local last = Gear.PLAIN_CAN_FULL + 1
    for _, name in ipairs({ "FuelCanMk1", "FuelCanMk2", "FuelCanMk3" }) do
        local can = Gear.FUEL_CANS[name]
        local full = (Gear.CAN_WEIGHT + can.litres) / (1 + Gear.canEfficiency(name))
        near(full, can.full, 1e-9, name)
        truthy(full <= Gear.PLAIN_CAN_FULL, name .. " full weighs no more than a full plain can")
        truthy(full < last, name .. " lighter than the one before")
        truthy(can.litres > 10, name .. " holds more than the plain can")
        last = full
    end
    near(Gear.FUEL_CANS.FuelCanMk1.full, Gear.PLAIN_CAN_FULL, 1e-9)
end)
