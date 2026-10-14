-- Gear on the game side, with fake game objects: fitting each kind of kit to each thing it fits, with and without the
-- extension API, the count and the effect staying in step, the voucher, the server command, the menus. The fakes mimic
-- only what Gear.lua calls.
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
ItemBodyLocation = ItemBodyLocation or { BACK = "back", FANNY_PACK_FRONT = "fannypackfront", FANNY_PACK_BACK = "fannypackback" }
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

-- An item. opts: weight, capacity (a bag), reduction, slot, noSlot, name, litres (a fluid container), condition (its
-- most, the script's), head (a head's condition), uses (a drainable's, with no key).
local function newItem(fullType, opts)
    opts = opts or {}
    nextId = nextId + 1
    local item = { id = nextId, fullType = fullType, weight = opts.weight or 0.5, bag = opts.capacity ~= nil,
        slot = opts.slot or (opts.capacity ~= nil and ItemBodyLocation.BACK or nil),
        reduction = opts.reduction or 0, inner = { capacity = opts.capacity or 0 }, synced = 0, poked = 0,
        conditionMax = opts.condition or 10, head = opts.head }
    item.condition = item.conditionMax
    local script = { weight = item.weight, conditionMax = item.conditionMax }
    function script:getActualWeight() return self.weight end
    function script:getConditionMax() return self.conditionMax end
    function item:getScriptItem() return script end
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
    function item:setActualWeight(w)
        self.weight = w
        self.poked = self.poked + 1
    end
    function item:IsInventoryContainer() return self.bag end
    function item:canBeEquipped() return self.slot end
    if opts.noSlot then item.slot = nil end
    function item:getItemContainer() return self.inner end
    function item:setCapacity(n) self.inner.capacity = n end
    function item:getWeightReduction() return self.reduction end
    function item:setWeightReduction(n) self.reduction = math.max(0, math.min(100, n)) end
    function item:syncItemFields() self.synced = self.synced + 1 end
    item.inner.getCapacity = function(c) return c.capacity end
    if opts.litres then
        local fluid = { capacity = opts.litres }
        function fluid:getCapacity() return self.capacity end
        function fluid:setCapacity(n) self.capacity = n end
        item.fluid = fluid
    end
    function item:getFluidContainer() return self.fluid end
    function item:getConditionMax() return self.conditionMax end
    function item:setConditionMax(n) self.conditionMax = n end
    function item:getCondition() return self.condition end
    function item:setCondition(n) self.condition = math.min(n, self.conditionMax) end
    function item:hasHeadCondition() return self.head ~= nil end
    function item:getHeadCondition() return self.head end
    function item:setHeadCondition(n) self.head = math.min(n, self.conditionMax) end
    -- the API divides the use delta by the key's number
    function item:getMaxUses() return math.floor((opts.uses or 10) * (self.md and self.md[OA.Gear.Rules.KEY.USES] or 1) + 0.5) end
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
    local part = { id = id, md = {}, capacity = opts.capacity or 0, container = opts.container, item = opts.item,
        category = opts.category or "bodywork" }
    function part:getId() return self.id end
    function part:getModData() return self.md end
    function part:isContainer() return self.container end
    -- a part that holds items has an item container; a fuel tank is a container of a fluid and has none
    function part:getItemContainer() return self.container and not opts.fluid and {} or nil end
    function part:getCategory() return self.category end
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
    v.order = {}
    for _, part in ipairs(opts.parts or {}) do
        v.parts[part.id] = part
        v.order[#v.order + 1] = part
    end
    function v:getId() return self.id end
    function v:getPartCount() return #self.order end
    function v:getPartByIndex(i) return self.order[i + 1] end
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

-- The API: declared points and their status. `applied` is whether its hooks went in (every point), `points` the
-- points that did when only some did; `weights` what formulas.weight answers per item.
local function setApi(applied, points)
    local status = {}
    local api = { version = OA.API_VERSION, sets = {} }
    function api.client() return { name = OA.MOD } end
    for _, name in ipairs(points or { "capacity.modDataKey", "carry.efficiencyKey", "uses.modDataKey", "craft.carryKeys" }) do
        if applied then status[name] = "applied" end
    end
    api.formulas = {
        set = function(handle, name, value) api.sets[#api.sets + 1] = { name = name, value = value } end,
        points = function() return status end,
        weight = function(item) return item.weight / (1 + (item.md and item.md.OA_Carry or 0)) end,
    }
    PZExtAPI = api
    TEST.hours = (TEST.hours or 0) + 1      -- the answer is kept for a few minutes of game time
    return api
end

local function declaredValue(api, point)
    for _, s in ipairs(api.sets) do if s.name == point then return s.value end end
    return nil
end

local function noApi()
    PZExtAPI = nil
    TEST.hours = (TEST.hours or 0) + 1
end

local function bagFixture(fullType, capacity, reduction, weight)
    local player = newCharacter()
    local bag = newItem(fullType, { capacity = capacity, reduction = reduction, weight = weight or 2, name = "Pack" })
    player.inventory:AddItem(bag)
    return player, bag
end

local function kitOf(player, kind)
    local kit = newItem(Rules.kitType(kind))
    player.inventory:AddItem(kit)
    return kit
end

local function setup()
    TEST.vehicles = {}
    nextId = 100
    PZExtAPI = nil
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

test("an expansion kit without the API goes into the bag's capacity and is counted on the bag", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local kit = kitOf(player, "capacity")
    local ok, value = Gear.fitItem(player, kit, bag)
    truthy(ok)
    eq(value, "31")
    eq(bag.inner.capacity, 31)
    eq(bag.md[K.KIT_CAP], 1)
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
        truthy(Gear.fitItem(player, kitOf(player, "capacity"), bag))
        eq(bag.md[K.KIT_CAP], n)
        eq(bag.inner.capacity, Rules.capacity(28, n))
    end
    eq(bag.md[K.BAG_BASE_CAP], 28, "the original is kept from the first kit")
end)

test("a lightening kit lifts the bag's weight reduction toward 95", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    truthy(Gear.fitItem(player, kitOf(player, "lightening"), bag))
    eq(bag.reduction, 87)
    truthy(Gear.fitItem(player, kitOf(player, "lightening"), bag))
    eq(bag.reduction, 89)            -- 88.6
    eq(bag.md[K.KIT_LIGHT], 2)
    eq(bag.inner.capacity, 28, "the capacity is not touched by a lightening kit")
    eq(bag.weight, 2, "a bag is lightened by its reduction, not its own weight")
    eq(notices[2].args[2], "89%")
end)

test("without the API the game's limit cuts the capacity and the count still goes up", function()
    setup()
    local player, bag = bagFixture("OperationAcorn.TeamBackpack", 35, 85, 2)
    for _ = 1, 5 do truthy(Gear.fitItem(player, kitOf(player, "capacity"), bag)) end
    eq(bag.md[K.KIT_CAP], 5)
    eq(bag.inner.capacity, 48, "50 less the bag's own weight of 2")
    local info = Gear.itemInfo(bag)
    eq(info.total, 53)
    eq(info.limit, 48)
    eq(info.cut, true)
    local lines = Gear.itemLines(bag)
    eq(#lines, 2)
    truthy(string.find(lines[2], "Tooltip_OA_Gear_BagCut", 1, true), "the tooltip says what the limit is")
end)

test("with the API the original stays and OA_Capacity adds the kits, past the limit", function()
    setup()
    local api = setApi(true)
    local player, bag = bagFixture("OperationAcorn.TeamBackpack", 35, 85, 2)
    for _ = 1, 5 do truthy(Gear.fitItem(player, kitOf(player, "capacity"), bag)) end
    eq(bag.inner.capacity, 35, "the raw capacity is the original")
    eq(bag.md[K.CAPACITY], 18, "52.5 rounds to 53, 18 more than 35")
    eq(Gear.itemInfo(bag).cut, false)
    eq(#Gear.itemLines(bag), 1, "no word about a limit")
    eq(declaredValue(api, "capacity.modDataKey"), "OA_Capacity", "the key is declared when the upgrades part has not yet")
end)

test("the key the API reads is the number, never a boolean", function()
    setup()
    setApi(true)
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    truthy(Gear.fitItem(player, kitOf(player, "capacity"), bag))
    eq(type(bag.md[K.CAPACITY]), "number")
    eq(bag.md[K.CAPACITY], 3)
end)

test("a bag fitted without the API is written again when the API is there, and back", function()
    setup()
    local player, bag = bagFixture("OperationAcorn.TeamBackpack", 35, 85, 2)
    for _ = 1, 5 do Gear.fitItem(player, kitOf(player, "capacity"), bag) end
    eq(bag.inner.capacity, 48)
    setApi(true)
    Gear.refreshItem(bag)
    eq(bag.inner.capacity, 35)
    eq(bag.md[K.CAPACITY], 18)
    Gear.refreshItem(bag)
    eq(bag.inner.capacity, 35, "and writing it again changes nothing")
    noApi()
    Gear.refreshItem(bag)
    eq(bag.inner.capacity, 48)
    eq(bag.md[K.CAPACITY], nil)
    eq(bag.md[K.KIT_CAP], 5, "the count was never touched")
end)

test("the waist bag takes the kits either way it is worn, and the other side gets them when it is put on", function()
    setup()
    local player = newCharacter()
    local front = newItem("OperationAcorn.TeamWaistBagFront", { capacity = 6, reduction = 85,
        slot = ItemBodyLocation.FANNY_PACK_FRONT })
    player.inventory:AddItem(front)
    eq(Gear.targetOf(front), "bag")
    truthy(Gear.fitItem(player, kitOf(player, "capacity"), front))
    truthy(Gear.fitItem(player, kitOf(player, "capacity"), front))
    truthy(Gear.fitItem(player, kitOf(player, "lightening"), front))
    eq(front.inner.capacity, 7)
    eq(front.reduction, 87)
    -- worn at the back: the game makes the other item, the modData copied, the script's capacity and reduction
    local back = newItem("OperationAcorn.TeamWaistBagBack", { capacity = 6, reduction = 85,
        slot = ItemBodyLocation.FANNY_PACK_BACK })
    back.md = {}
    for k, v in pairs(front.md) do back.md[k] = v end
    player.inventory:DoRemoveItem(front)
    player.inventory:AddItem(back)
    eq(Gear.targetOf(back), "bag")
    Gear.refreshItem(back)
    eq(back.inner.capacity, 7, "the kits are written into the new item though its last raw value is in the copy")
    eq(back.reduction, 87)
    eq(back.md[K.BAG_ID], back:getID())
end)

test("refreshAll finds fitted items in the inventory", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    Gear.fitItem(player, kitOf(player, "capacity"), bag)
    Gear.fitItem(player, kitOf(player, "lightening"), bag)
    bag.inner.capacity = 28
    bag.reduction = 85
    bag.md[K.BAG_ID] = nil
    local plain = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85 })
    player.inventory:AddItem(plain)
    local tool = newItem("OperationAcorn.FieldHammer", { weight = 1.28 })
    player.inventory:AddItem(tool)
    Gear.fitItem(player, kitOf(player, "lightening"), tool)
    tool.weight = 1.28      -- a game loaded without the API: the weight the game does not save
    eq(Gear.refreshAll(player), 2, "the fitted bag and the fitted tool")
    eq(bag.inner.capacity, 31)
    eq(bag.reduction, 87)
    near(tool.weight, 1.28 * Rules.lightness(1), 1e-6)
    eq(plain.md, nil, "a bag without kits gets no modData made for it")
end)

test("a kit goes where it fits: bags, a key ring or a fanny pack not, a vehicle kit not on an item", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local ring = newItem("Base.KeyRing", { capacity = 1, noSlot = true })
    local fanny = newItem("Base.Bag_FannyPackFront", { capacity = 4, slot = ItemBodyLocation.FANNY_PACK_FRONT })
    local hammer = newItem("Base.Hammer")
    for _, it in ipairs({ ring, fanny, hammer }) do player.inventory:AddItem(it) end
    eq(Gear.targetOf(ring), nil)
    eq(Gear.targetOf(fanny), nil)
    eq(Gear.targetOf(hammer), nil, "a vanilla tool is not the team's")
    eq(select(2, Gear.fitItem(player, kitOf(player, "capacity"), ring)), "target")
    eq(select(2, Gear.fitItem(player, kitOf(player, "reinforcement"), bag)), "target")
    eq(select(2, Gear.fitItem(player, kitOf(player, "engine"), bag)), "target")
    local vehicle = newVehicle({ parts = { newPart("TruckBed", { container = true, capacity = 100 }), newPart("Engine") } })
    eq(select(2, Gear.fitStorage(player, kitOf(player, "lightening"), vehicle, "TruckBed")), "kit")
    eq(select(2, Gear.fitEngine(player, kitOf(player, "capacity"), vehicle)), "kit")
    eq(select(2, Gear.fitItem(player, kitOf(player, "capacity"), kitOf(player, "capacity"))), "target")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The team's fuel can, welder and field tools

local function can(player)
    local c = newItem("OperationAcorn.TeamFuelCan", { weight = 1.6, litres = 12 })
    player.inventory:AddItem(c)
    return c
end

test("the fuel can: an expansion kit adds two litres, from its own capacity", function()
    setup()
    local player = newCharacter()
    local c = can(player)
    eq(Gear.targetOf(c), "can")
    local ok, value = Gear.fitItem(player, kitOf(player, "capacity"), c)
    truthy(ok)
    eq(value, "14")
    eq(c.fluid.capacity, 14)
    truthy(Gear.fitItem(player, kitOf(player, "capacity"), c))
    eq(c.fluid.capacity, 16)
    eq(c.md[K.BAG_BASE_CAP], 12)
    eq(notices[1].key, "IGUI_OA_Gear_Fitted_litres")
    c.fluid.capacity = 12
    Gear.refreshItem(c)
    eq(c.fluid.capacity, 16, "written again from the count")
    eq(Gear.itemLines(c)[1], "Tooltip_OA_Gear_CanKits 2 16")
end)

test("a lightening kit: with the API the item's own efficiency, without it its weight", function()
    setup()
    local api = setApi(true)
    local player = newCharacter()
    local c = can(player)
    truthy(Gear.fitItem(player, kitOf(player, "lightening"), c))
    near(c.md[K.CARRY], Rules.efficiency(1), 1e-9)
    eq(c.weight, 1.6, "the scale's weight stays")
    truthy(c.poked >= 1, "the item tells the game its weight changed")
    near(api.formulas.weight(c), 1.6 * Rules.lightness(1), 1e-9)
    eq(declaredValue(api, "carry.efficiencyKey"), "OA_Carry")
    eq(notices[1].key, "IGUI_OA_Gear_Fitted_lighter")
    eq(notices[1].args[2], "88%")
    -- the API gone: its key is taken back and the weight written instead
    noApi()
    Gear.refreshItem(c)
    eq(c.md[K.CARRY], nil)
    near(c.weight, 1.6 * Rules.lightness(1), 1e-9)
    -- and back: the weight is the script's (the game does not save it), the key again
    c.weight = 1.6
    setApi(true)
    Gear.refreshItem(c)
    near(c.md[K.CARRY], Rules.efficiency(1), 1e-9)
    eq(c.weight, 1.6)
end)

local function welder(player)
    local w = newItem("Base.BlowTorch", { weight = 1.0, uses = 10 })
    local md = w:getModData()
    md[K.TEAM] = true
    md[K.USES] = Rules.uses(0)
    player.inventory:AddItem(w)
    return w
end

test("the welder: the team's torch by its mark, its uses raised by the expansion kit through the API", function()
    setup()
    local player = newCharacter()
    local plain = newItem("Base.BlowTorch")
    player.inventory:AddItem(plain)
    eq(Gear.targetOf(plain), nil, "a torch without the mark is the game's")
    local w = welder(player)
    eq(Gear.targetOf(w), "welder")
    eq(select(2, Gear.fitItem(player, kitOf(player, "capacity"), w)), "api", "without the API its uses cannot change")
    truthy(Gear.fitItem(player, kitOf(player, "lightening"), w), "its weight can")
    local api = setApi(true)
    local ok, value = Gear.fitItem(player, kitOf(player, "capacity"), w)
    truthy(ok)
    near(w.md[K.USES], 1.4, 1e-9)
    eq(value, "14")
    eq(notices[#notices].key, "IGUI_OA_Gear_Fitted_uses")
    eq(declaredValue(api, "uses.modDataKey"), "OA_Uses")
    eq(Gear.itemLines(w)[1], "Tooltip_OA_Gear_WelderUses 14")
    eq(select(2, Gear.fitItem(player, kitOf(player, "reinforcement"), w)), "target")
end)

test("the keys a refilled welder keeps are declared to the API when the game starts", function()
    setup()
    local api = setApi(true)
    Gear.declare()
    local keys = declaredValue(api, "craft.carryKeys")
    local set = {}
    for _, k in ipairs(keys or {}) do set[k] = true end
    truthy(set[K.TEAM] and set[K.USES] and set[K.CARRY] and set[K.KIT_CAP] and set[K.KIT_LIGHT], "the mark, the uses and the kits")
    eq(declaredValue(api, "carry.efficiencyKey"), K.CARRY)
    eq(declaredValue(api, "uses.modDataKey"), K.USES)
end)

test("the shop's welder is the vanilla torch with the team's mark and the uses with no kit", function()
    eq(OA.Shop.WELDER.type, OA.Shop.TYPES.welder)
    eq(OA.Shop.WELDER.mod[K.TEAM], true)
    near(OA.Shop.WELDER.mod[K.USES], Rules.uses(0), 1e-9)
    eq(OA.Shop.WELDER.used, 1, "filled to its uses")
end)

test("a field tool: the reinforcement kit raises its most condition, the condition and the head by as much", function()
    setup()
    local player = newCharacter()
    local tool = newItem("OperationAcorn.FieldHammer", { weight = 1.28, condition = 12, head = 9 })
    player.inventory:AddItem(tool)
    tool.condition = 7
    eq(Gear.targetOf(tool), "tool")
    local ok, value = Gear.fitItem(player, kitOf(player, "reinforcement"), tool)
    truthy(ok)
    eq(tool.conditionMax, 15)
    eq(tool.condition, 10)
    eq(tool.head, 12)
    eq(value, "15")
    for _ = 2, Rules.TOUGH_MOST do truthy(Gear.fitItem(player, kitOf(player, "reinforcement"), tool)) end
    eq(tool.conditionMax, 24, "twice the script's at the most")
    eq(select(2, Gear.fitItem(player, kitOf(player, "reinforcement"), tool)), "most")
    eq(select(2, Gear.fitItem(player, kitOf(player, "capacity"), tool)), "target")
    truthy(Gear.fitItem(player, kitOf(player, "lightening"), tool))
    eq(Gear.itemLines(tool)[2], "Tooltip_OA_Gear_ToughKits 4 24")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- Vehicle storage

local function carWithTrunk(capacity, opts)
    local trunk = newPart("TruckBed", { container = true, capacity = capacity,
        item = opts and opts.item or nil })
    local car = newVehicle({ parts = { trunk, newPart("Engine"), newPart("TruckBedOpen", { container = false }) } })
    return car, trunk
end

test("an expansion kit on a storage without the API raises the part's capacity, counted on the part", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(100)
    local ok, total = Gear.fitStorage(player, kitOf(player, "capacity"), car, "TruckBed")
    truthy(ok)
    eq(total, 110)
    eq(trunk.capacity, 110)
    eq(trunk.md[K.KIT_CAP], 1)
    eq(trunk.md[K.STORAGE_BASE], 100)
    eq(trunk.md[K.CAPACITY], nil)
    truthy(car.partsSent > 0, "the part's data is sent")
    eq(Gear.storageInfo(trunk).kits, 1)
    eq(notices[1].key, "IGUI_OA_Gear_Fitted_storage")
    eq(notices[1].args[2], "IGUI_VehiclePartTruckBed", "the notice names the part")
end)

test("an expansion kit on a storage with the API leaves the capacity and adds the number", function()
    setup()
    setApi(true)
    local player = newCharacter()
    local car, trunk = carWithTrunk(100)
    for _ = 1, 3 do truthy(Gear.fitStorage(player, kitOf(player, "capacity"), car, "TruckBed")) end
    eq(trunk.capacity, 100)
    eq(trunk.md[K.CAPACITY], 30)
    eq(type(trunk.md[K.CAPACITY]), "number")
    eq(Gear.storageInfo(trunk).total, 130)
    eq(Gear.storageInfo(trunk).cut, false)
end)

test("the storage's original is the installed item's maximum, not what a damaged trunk holds now", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(60, { item = { getMaxCapacity = function() return 120 end } })
    truthy(Gear.fitStorage(player, kitOf(player, "capacity"), car, "TruckBed"))
    eq(trunk.md[K.STORAGE_BASE], 120)
    eq(trunk.capacity, 132)
end)

test("an expansion kit goes on the one part it is fitted to: a roof rack, a modded vehicle's own storage, not a seat", function()
    setup()
    local player = newCharacter()
    local trunk = newPart("TruckBed", { container = true, capacity = 100 })
    local rack = newPart("Roofrack", { container = true, capacity = 60 })
    local modded = newPart("ATA2InteractiveTrunkRoofRack", { container = true, capacity = 40, category = "Other" })
    local seat = newPart("SeatFrontLeft", { container = true, capacity = 20, category = "seat" })
    local seatNoCategory = newPart("SeatRearLeft", { container = true, capacity = 20, category = "" })
    local tank = newPart("GasTank", { container = true, fluid = true, capacity = 50 })
    local car = newVehicle({ parts = { trunk, rack, modded, seat, seatNoCategory, tank, newPart("Engine") } })
    local ids = {}
    for _, part in ipairs(Gear.storageParts(car)) do ids[#ids + 1] = part:getId() end
    eq(table.concat(ids, ","), "TruckBed,Roofrack,ATA2InteractiveTrunkRoofRack")
    truthy(Gear.fitStorage(player, kitOf(player, "capacity"), car, "Roofrack"))
    eq(rack.capacity, 66)
    eq(trunk.capacity, 100, "the trunk is left as it is")
    truthy(Gear.fitStorage(player, kitOf(player, "capacity"), car, "ATA2InteractiveTrunkRoofRack"))
    eq(modded.capacity, 44)
    eq(select(2, Gear.fitStorage(player, kitOf(player, "capacity"), car, "SeatFrontLeft")), "part")
    eq(select(2, Gear.fitStorage(player, kitOf(player, "capacity"), car, "SeatRearLeft")), "part")
    eq(select(2, Gear.fitStorage(player, kitOf(player, "capacity"), car, "GasTank")), "part")
    eq(select(2, Gear.fitStorage(player, kitOf(player, "capacity"), car, "Engine")), "part")
end)

test("past the vehicle limit the storage is cut without the API", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(900)
    for _ = 1, 3 do truthy(Gear.fitStorage(player, kitOf(player, "capacity"), car, "TruckBed")) end
    eq(trunk.capacity, 1000)
    eq(Gear.storageInfo(trunk).cut, true)
    eq(#Gear.storageLines(trunk), 2)
end)

test("a storage fitted without the API is refreshed when the API is there", function()
    setup()
    local player = newCharacter()
    local car, trunk = carWithTrunk(100)
    Gear.fitStorage(player, kitOf(player, "capacity"), car, "TruckBed")
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

test("vehicle kits need the character beside the vehicle and the part", function()
    setup()
    local player = newCharacter()
    local car = carWithTrunk(100)
    car.x = 100
    eq(select(2, Gear.fitStorage(player, kitOf(player, "capacity"), car, "TruckBed")), "far")
    car.x = 12
    eq(select(2, Gear.fitStorage(player, kitOf(player, "capacity"), nil, "TruckBed")), "gone")
    local bare = newVehicle({ parts = { newPart("Engine") } })
    eq(select(2, Gear.fitStorage(player, kitOf(player, "capacity"), bare, "TruckBed")), "part")
    truthy(Gear.fitStorage(player, kitOf(player, "capacity"), car, "TruckBed"), "beside it, it fits")
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

test("an engine kit wants a vehicle, an engine and the character beside it", function()
    setup()
    local player = newCharacter()
    local noEngine = newVehicle({ parts = { newPart("TruckBed", { container = true }) } })
    eq(select(2, Gear.fitEngine(player, kitOf(player, "engine"), noEngine)), "part")
    local car = newVehicle({ parts = { newPart("Engine") } })
    car.y = 80
    eq(select(2, Gear.fitEngine(player, kitOf(player, "engine"), car)), "far")
    eq(Gear.fitVehicle(player, kitOf(player, "lightening"), car, "Engine"), false)
end)

test("the lines about a vehicle's kits", function()
    setup()
    local player = newCharacter()
    local car = newVehicle({ power = 140, loud = 37, parts = { newPart("Engine"), newPart("TruckBed", { container = true, capacity = 100 }) } })
    eq(Gear.engineLines(car), nil)
    local trunk = car:getPartById("TruckBed")
    eq(Gear.storageLines(trunk), nil)
    truthy(Gear.fitVehicle(player, kitOf(player, "engine"), car, "Engine"))
    truthy(Gear.fitVehicle(player, kitOf(player, "capacity"), car, "TruckBed"))
    eq(Gear.engineLines(car)[1], "Tooltip_OA_Gear_EngineKits 1 15.4 39")
    eq(Gear.storageLines(trunk)[1], "Tooltip_OA_Gear_StorageKits 1 110")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The voucher

test("the voucher gives one kit of the kind chosen", function()
    setup()
    local player = newCharacter()
    local voucher = newItem(Gear.VOUCHER)
    player.inventory:AddItem(voucher)
    truthy(Gear.redeem(player, voucher, "capacity"))
    eq(voucher.container, nil, "the voucher is used up")
    eq(#player.inventory.items, 1)
    local kit = player.inventory.items[1]
    eq(kit:getFullType(), "OperationAcorn.KitCapacity")
    -- it fits a bag, and then counts on that bag like any kit
    local bag = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85 })
    player.inventory:AddItem(bag)
    truthy(Gear.fitItem(player, kit, bag))
    eq(bag.md[K.KIT_CAP], 1)
end)

test("the server command redeems the voucher a character names", function()
    setup()
    local player = newCharacter()
    player.inventory:AddItem(newItem(Gear.VOUCHER))
    local voucher = player.inventory.items[1]
    OA.Sync.send(player, "gear.redeem", { item = voucher:getID(), kind = "reinforcement" })
    eq(#player.inventory.items, 1)
    eq(player.inventory.items[1]:getFullType(), "OperationAcorn.KitReinforcement")
    -- another item, or a kind that is not one, does nothing and says why
    local other = newItem("Base.Hammer")
    player.inventory:AddItem(other)
    OA.Sync.send(player, "gear.redeem", { item = other:getID(), kind = "capacity" })
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
-- A kit goes to any of its targets

test("a kit goes on any of its targets the character has, counted on that one", function()
    setup()
    local player, first = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local second = newItem("Base.Bag_ALICEpack", { capacity = 28, reduction = 85, name = "Pack" })
    player.inventory:AddItem(second)
    truthy(Gear.fitItem(player, kitOf(player, "capacity"), first))
    truthy(Gear.fitItem(player, kitOf(player, "capacity"), second))
    eq(first.md[K.KIT_CAP], 1)
    eq(second.md[K.KIT_CAP], 1)
    local one, oneTrunk = carWithTrunk(100)
    local two, twoTrunk = carWithTrunk(100)
    truthy(Gear.fitStorage(player, kitOf(player, "capacity"), one, "TruckBed"))
    truthy(Gear.fitEngine(player, kitOf(player, "engine"), two))
    eq(Gear.storageInfo(oneTrunk).kits, 1)
    eq(Gear.storageInfo(twoTrunk), nil)
    eq(Gear.engineKits(one), 0)
    eq(Gear.engineKits(two), 1)
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- What a character carries, kept per inventory signature; the menus and the actions that read it

test("the targets and kits a character carries are found by one search, kept while the inventory is the same", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local kit = kitOf(player, "capacity")
    local plain = newItem("Base.Hammer")
    player.inventory:AddItem(plain)
    local c = can(player)
    local searches = 0
    local search = player.inventory.getAllEvalRecurse
    player.inventory.getAllEvalRecurse = function(self, pred) searches = searches + 1 return search(self, pred) end
    local carried = Gear.carried(player)
    eq(searches, 1)
    eq(#carried.items, 2)
    eq(carried.items[1], bag)
    eq(carried.items[2], c)
    eq(#carried.kits.capacity, 1)
    eq(carried.kits.capacity[1], kit)
    eq(Gear.carried(player), carried)
    eq(Gear.carried(player), carried)
    eq(searches, 1, "the same inventory: not searched again")
    -- an item comes: searched again
    kitOf(player, "lightening")
    local again = Gear.carried(player)
    eq(searches, 2)
    eq(#again.kits.lightening, 1)
    -- a kit used up (its weight goes too): searched again, and it is gone
    player.inventory:DoRemoveItem(kit)
    eq(#(Gear.carried(player).kits.capacity or {}), 0, "it is gone")
    eq(searches, 3)
end)

test("a fitting action checks its kit and item by the objects it was made with, without searching the inventory", function()
    setup()
    local player, bag = bagFixture("Base.Bag_ALICEpack", 28, 85)
    local kit = kitOf(player, "capacity")
    local searches = 0
    local find = player.inventory.getItemWithIDRecursiv
    player.inventory.getItemWithIDRecursiv = function(self, id) searches = searches + 1 return find(self, id) end
    function player.inventory:getContainingItem() return nil end
    local action = { character = player, kit = kit, item = bag, kitId = kit:getID(), itemId = bag:getID() }
    for _ = 1, 5 do
        eq(Gear.heldItem(action, "kit", "kitId"), kit)
        eq(Gear.heldItem(action, "item", "itemId"), bag)
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
    local kit = kitOf(player, "capacity")
    kitOf(player, "reinforcement")
    local searches = 0
    local search = player.inventory.getAllEvalRecurse
    player.inventory.getAllEvalRecurse = function(self, pred) searches = searches + 1 return search(self, pred) end
    getSpecificPlayer = function() return player end
    -- right-click on the bag: "fit a kit" above the game's own, the kits that fit it only
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillInventoryObjectContextMenu", 0, menu, { bag })
    eq(menu.options[1].name, "ContextMenu_OA_Gear_FitKit")
    eq(menu.options[2].name, "Vanilla")
    eq(#menu.options[1].subOption.options, 1, "the expansion kit; the reinforcement kit does not fit a bag")
    eq(searches, 1)
    -- again, and on the kit: no new search
    TEST.fire("OnFillInventoryObjectContextMenu", 0, menu, { bag })
    local onKit = newMenu()
    onKit:addOption("Vanilla")
    TEST.fire("OnFillInventoryObjectContextMenu", 0, onKit, { kit })
    eq(onKit.options[1].name, "ContextMenu_OA_Gear_FitItem")
    eq(onKit.options[2].name, "Vanilla")
    eq(#onKit.options[1].subOption.options, 1, "the one bag in hand")
    eq(searches, 1, "three menus, one search")
    -- the inventory changed
    player.inventory:AddItem(newItem("Base.Hammer"))
    TEST.fire("OnFillInventoryObjectContextMenu", 0, newMenu(), { bag })
    eq(searches, 2)
end)
