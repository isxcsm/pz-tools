-- The base machines on the game side, with fake game objects: the ten-minute step, the catch-up on chunk load,
-- containers, the refiners' tanks, parts in and out, the registry. The fakes mimic only what Machines.lua calls.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data

-- ---------------------------------------------------------------------------------------------------------------------
-- Fake game

local nextId = 1
local ITEMS = {
    ["Base.Log"] = { weight = 9 },
    ["Base.Plank"] = { weight = 3 },
    ["OperationAcorn.SampleBundle"] = { weight = 0.1 },
    ["Base.RippedSheets"] = { weight = 0.1 },
    ["Base.RippedSheetsDirty"] = { weight = 0.1 },
    ["Base.LeatherStrips"] = { weight = 0.1 },
    ["Base.LeatherStripsDirty"] = { weight = 0.1 },
    ["Base.Buckle"] = { weight = 0.1 },
}

local function list(array)
    return {
        size = function() return #array end,
        get = function(self, i) return array[i + 1] end,
        isEmpty = function() return #array == 0 end,
    }
end

local function newContainer(kind, capacity)
    local c = { items = {}, type = kind, capacity = capacity or 100 }
    function c:getItems() return list(self.items) end
    function c:getType() return self.type end
    function c:setType(t) self.type = t end
    function c:getCapacity() return math.min(self.capacity, 100) end
    function c:setCapacity(n) self.capacity = n end
    function c:setExplored() end
    function c:setAcceptItemFunction(f) self.accept = f end
    function c:getParent() return self.parent end
    function c:getCapacityWeight()
        local w = 0
        for _, item in ipairs(self.items) do w = w + item:getActualWeight() end
        return w
    end
    function c:AddItem(item)
        item.container = self
        table.insert(self.items, item)
        return item
    end
    function c:Remove(item)
        for i, it in ipairs(self.items) do
            if it == item then
                table.remove(self.items, i)
                item.container = nil
                return
            end
        end
    end
    function c:contains(item)
        for _, it in ipairs(self.items) do
            if it == item then return true end
        end
        return false
    end
    function c:isEmpty() return #self.items == 0 end
    c.containsRecursive = c.contains
    return c
end

-- classes: a set of class names the instanceof stub answers for.
local function newItem(fullType, fields)
    fields = fields or {}
    local def = ITEMS[fullType] or {}
    local item = { fullType = fullType, weight = fields.weight or def.weight or 1, mod = {}, cond = fields.cond or 100,
        classes = fields.classes or {}, id = nextId, equipped = false, fields = fields }
    nextId = nextId + 1
    function item:getFullType() return self.fullType end
    function item:getType() return (string.gsub(self.fullType, "^.*%.", "")) end
    function item:getActualWeight() return self.weight end
    function item:getModData() return self.mod end
    function item:isEquipped() return self.equipped end
    function item:isFavorite() return false end
    function item:getCondition() return self.cond end
    function item:getConditionMax() return 100 end
    function item:setConditionNoSound(n) self.cond = n end
    function item:getName() return self.fullType end
    function item:getID() return self.id end
    function item:getContainer() return self.container end
    function item:isRotten() return self.fields.rotten == true end
    function item:getBaseHunger() return self.fields.baseHunger or -30 end
    function item:getHungChange() return self.fields.hunger or -30 end
    function item:hasTag() return self.fields.buckle == true end
    function item:getFabricType() return self.fields.fabric end
    function item:getBodyLocation() return self.fields.location and ("base:" .. self.fields.location) or nil end
    function item:getNbrOfCoveredParts() return self.fields.covered or 1 end
    function item:getHolesNumber() return 0 end
    function item:getPatchesNumber() return 0 end
    function item:getDirtiness() return self.fields.dirt or 0 end
    function item:getBloodLevel() return 0 end
    function item:getCurrentUsesFloat() return self.fields.fill or 0 end
    function item:setUsedDelta(v) self.fields.fill = v end
    function item:syncItemFields() end
    if fields.fluid then
        local fluid = { amount = fields.fluid.amount or 0, capacity = fields.fluid.capacity or 10 }
        function fluid:getFreeCapacity() return self.capacity - self.amount end
        function fluid:isEmpty() return self.amount <= 0 end
        function fluid:isPureFluid() return true end
        function fluid:addFluid(_, n) self.amount = self.amount + n end
        function item:getFluidContainer() return fluid end
        item.fluidBox = fluid
    end
    if fields.bag then
        local inner = newContainer("bag", 50)
        function item:getInventory() return inner end
        item.inner = inner
    end
    return item
end

local function newSquare(x, y, z)
    local sq = { x = x, y = y, z = z, objects = {}, power = false, room = true }
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return self.z end
    function sq:haveElectricity() return self.power end
    function sq:hasGridPower() return false end
    function sq:getRoom() return self.room and {} or nil end
    function sq:getObjects() return list(self.objects) end
    return sq
end

local function newObject(square, kind)
    local obj = { square = square, mod = {}, sprite = nil, containers = {} }
    function obj:hasModData() return next(self.mod) ~= nil end
    function obj:getModData() return self.mod end
    function obj:getSquare() return self.square end
    function obj:getX() return self.square.x end
    function obj:getY() return self.square.y end
    function obj:getZ() return self.square.z end
    function obj:getContainerByType(t)
        for _, c in ipairs(self.containers) do
            if c.type == t then return c end
        end
        return nil
    end
    function obj:getSprite()
        local name = self.sprite
        return name and { getName = function() return name end } or nil
    end
    function obj:setSprite(name) self.sprite = name end
    function obj:transmitModData() end
    return obj
end

local squares
local sounds
local halo

-- Puts a machine of a kind in the fake world at x, y, owned by "p1", with the containers its kind has.
local function addMachine(kind, x, y)
    squares = squares or {}
    local key = x .. "," .. y .. ",0"
    local sq = squares[key] or newSquare(x, y, 0)
    squares[key] = sq
    local obj = newObject(sq, kind)
    local def = Data.KINDS[kind]
    local state = { id = "m" .. (OA.Store.world("machines").next or 1), kind = kind, dir = "S", owner = "p1", on = true,
        last = OA.hours(), carry = 0, idle = true, running = false, buffer = 0, parts = Machines.Logic.newParts(kind) }
    for _, which in ipairs(def.containers) do
        local spec = Data.CONTAINERS[which]
        local c = newContainer(spec.type, spec.capacity)
        c.parent = obj
        table.insert(obj.containers, c)
    end
    obj.mod[Data.KEY] = state
    table.insert(sq.objects, obj)
    local reg = OA.Store.world("machines")
    reg.next = (reg.next or 1) + 1
    reg.list = reg.list or {}
    reg.byChunk = reg.byChunk or {}
    reg.list[state.id] = { kind = kind, x = x, y = y, z = 0 }
    local ck = OA.Chunks.key(x, y)
    reg.byChunk[ck] = reg.byChunk[ck] or {}
    table.insert(reg.byChunk[ck], state.id)
    return obj, state, sq
end

local function fill(container, fullType, count, fields)
    for _ = 1, count do container:AddItem(newItem(fullType, fields)) end
end

local function countOf(container, fullType)
    local n = 0
    for _, item in ipairs(container.items) do
        if item.fullType == fullType then n = n + 1 end
    end
    return n
end

local function player()
    local inv = newContainer("main", 100)
    local p = { inv = inv, mod = {} }
    function p:getInventory() return self.inv end
    function p:getModData() return self.mod end
    function p:getUsername() return "tester" end
    function p:removeFromHands() end
    return p
end

local function setup()
    squares = {}
    sounds = {}
    halo = {}
    nextId = 1
    getCell = function()
        return { getGridSquare = function(self, x, y, z) return squares[x .. "," .. y .. "," .. z] end }
    end
    instanceof = function(obj, class)
        if class == "InventoryContainer" then return obj.fields ~= nil and obj.fields.bag == true end
        return obj.classes ~= nil and obj.classes[class] == true or (obj.fields and obj.fields.classes and obj.fields.classes[class] == true)
    end
    instanceItem = function(fullType)
        return newItem(fullType)
    end
    sendAddItemToContainer = function() end
    sendRemoveItemFromContainer = function() end
    addSound = function(source, x, y, z, r, v) sounds[#sounds + 1] = { x = x, y = y, radius = r, volume = v } end
    ClothingRecipesDefinitions = { FabricType = {
        Cotton = { material = "Base.RippedSheets", materialDirty = "Base.RippedSheetsDirty" },
        Leather = { material = "Base.LeatherStrips", materialDirty = "Base.LeatherStripsDirty" },
    } }
    Fluid = { Petrol = "Petrol" }
    FluidType = { Petrol = "Petrol" }
    getPlayer = function() return nil end
    ItemTag = { BUCKLE = "buckle" }
    -- P1's pieces, simplified: every item yields its weight times 5, a kind shredded before is not first.
    OA.Value = { info = function(item)
        return { fullType = item:getFullType(), baseType = item:getFullType(), weight = item:getActualWeight() }
    end }
    OA.Shred = {
        committed = {},
        can = function(info) return info.weight < 100 end,
        yield = function(info, record, extras)
            return info.weight * 5 * (extras and extras.blade or 1), 0
        end,
        roll = function(x) return math.floor(x + 0.5) end,
        commit = function(record, info, n)
            OA.Shred.committed[#OA.Shred.committed + 1] = { record = record, type = info.fullType, n = n }
            return 0
        end,
    }
    OA.Sync.notice = function(playerId, key, args) halo[#halo + 1] = { player = playerId, key = key, args = args } end
    OA.Store.ensure("p1", "tester")
end

local function powered(sq) sq.power = true end

-- ---------------------------------------------------------------------------------------------------------------------
-- Tests

test("a bulk shredder shreds a box of items into sample bundles over time", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    local inC, outC = Machines.container(obj, "in"), Machines.container(obj, "out")
    local box = newItem("Base.CardboardBox", { bag = true })
    inC:AddItem(box)
    fill(box.inner, "Base.Hammer", 10, {})            -- weight 1 each
    -- First tick: the machine finds work and starts its clock.
    TEST.hours = 1
    Machines.update(obj)
    eq(state.idle, false, "started")
    eq(#outC.items, 0)
    -- One hour later: 30 weight an hour, so all ten are done (10 weight is 20 minutes).
    TEST.hours = 2
    Machines.update(obj)
    eq(#box.inner.items, 0, "box is empty")
    eq(countOf(outC, "OperationAcorn.SampleBundle"), 50, "10 items of weight 1: 5 bundles each")
    eq(state.idle, true)
    eq(state.running, false)
    eq(#OA.Shred.committed, 10, "each shred was booked")
    eq(OA.Shred.committed[1].record.id, "p1")
    eq(inC.items[1], box, "the box stays")
    truthy(#sounds >= 1, "it made noise")
    eq(sounds[1].radius, 20)
end)

test("catching up when the chunk loads does the work of the time away", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 18, 3)
    powered(sq)
    local inC, outC = Machines.container(obj, "in"), Machines.container(obj, "out")
    fill(inC, "Base.Hammer", 100, {})
    TEST.hours = 1
    Machines.update(obj)
    eq(state.idle, false)
    -- Away for 2 hours: 60 weight of hammers, 60 hammers.
    TEST.hours = 3
    local chunk = { getGridSquare = function(self, lx, ly, lz)
        return squares[(16 + lx) .. "," .. (0 + ly) .. "," .. lz]
    end }
    -- The chunk of (18, 3) starts at (16, 0).
    squares["16,0,0"] = newSquare(16, 0, 0)
    squares["18,3,0"] = sq
    Machines.onChunk(chunk)
    eq(#inC.items, 40, "60 of 100 shredded")
    eq(countOf(outC, "OperationAcorn.SampleBundle"), 300)
    eq(#sounds, 0, "a catch-up makes no sound")
end)

test("a machine that was idle does not catch up", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 18, 3)
    powered(sq)
    fill(Machines.container(obj, "in"), "Base.Hammer", 5, {})
    TEST.hours = 5
    local chunk = { getGridSquare = function(self, lx, ly, lz) return squares[(16 + lx) .. "," .. ly .. "," .. lz] end }
    squares["16,0,0"] = newSquare(16, 0, 0)
    squares["18,3,0"] = sq
    Machines.onChunk(chunk)
    eq(#Machines.container(obj, "in").items, 5)
end)

test("no power, no work; the clock restarts when power comes back", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    fill(Machines.container(obj, "in"), "Base.Hammer", 40, {})
    TEST.hours = 1
    Machines.update(obj)
    eq(state.idle, true)
    eq(state.reason, "noPower")
    eq(#Machines.container(obj, "in").items, 40)
    powered(sq)
    TEST.hours = 2
    Machines.update(obj)
    eq(state.idle, false, "found work, started")
    TEST.hours = 2.5
    Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 25, "30 minutes: 15 weight")
end)

test("a switched-off machine does not work", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    fill(Machines.container(obj, "in"), "Base.Hammer", 10, {})
    Machines.setOn(obj, false)
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 3
    Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 10)
    eq(state.reason, "off")
    Machines.setOn(obj, true)
    TEST.hours = 4
    Machines.update(obj)
    TEST.hours = 5
    Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 0)
end)

test("it stops when the output is full", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    local outC = Machines.container(obj, "out")
    fill(outC, "Base.Plank", 33, {})                 -- 99 of 100 weight
    fill(outC, "Base.Buckle", 5, {})                 -- and 0.5 more: under 1 left
    fill(Machines.container(obj, "in"), "Base.Hammer", 10, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    local r = Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 10)
    eq(state.reason, "outputFull")
end)

test("a better blade yields more, a worn one less", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    state.parts.blade = { tier = "modern", cond = 100 }
    fill(Machines.container(obj, "in"), "Base.Hammer", 1, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    -- The fake yield multiplies by the blade: 5 * 1.2 = 6.
    eq(countOf(Machines.container(obj, "out"), "OperationAcorn.SampleBundle"), 6)
end)

test("parts wear while it runs and a worn-out motor stops it, with a note", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    state.parts.motor.cond = 1
    fill(Machines.container(obj, "in"), "Base.Hammer", 200, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    eq(state.parts.motor.cond, 0)
    local broken = false
    for _, h in ipairs(halo) do
        if h.key == "IGUI_OA_Machine_PartBroken" then broken = true end
    end
    truthy(broken, "told the owner")
    TEST.hours = 3
    Machines.update(obj)
    eq(state.reason, "stopped")
end)

test("the cutter turns clothes into rags", function()
    setup()
    local obj, state, sq = addMachine("cutter", 10, 10)
    powered(sq)
    local inC, outC = Machines.container(obj, "in"), Machines.container(obj, "out")
    fill(inC, "Base.Tshirt", 4, { classes = { Clothing = true }, fabric = "Cotton", location = "tshirt", covered = 3 })
    fill(inC, "Base.Jacket", 2, { classes = { Clothing = true }, fabric = "Leather", location = "jacket", covered = 4, buckle = true })
    fill(inC, "Base.Hat", 2, { classes = { Clothing = true }, location = "hat" })
    fill(inC, "Base.Spoon", 3, {})                 -- not cloth: stays
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    eq(#inC.items, 3, "only the spoons are left")
    local rags = countOf(outC, "Base.RippedSheets")
    truthy(rags >= 4 * 2 + 2, "cotton shirts give 2 or 3 each and hats 1 or 2: " .. rags)
    truthy(countOf(outC, "Base.LeatherStrips") >= 4, "leather jackets")
    eq(countOf(outC, "Base.Buckle"), 2, "buckles come out")
end)

test("the saw cuts logs into six planks", function()
    setup()
    local obj, state, sq = addMachine("woodSaw", 10, 10)
    powered(sq)
    local inC, outC = Machines.container(obj, "in"), Machines.container(obj, "out")
    fill(inC, "Base.Log", 3, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    eq(#inC.items, 0)
    eq(countOf(outC, "Base.Plank"), 18)
    eq(sounds[1].radius, 40)
end)

test("the saw stops when the planks have no room", function()
    setup()
    local obj, state, sq = addMachine("woodSaw", 10, 10)
    powered(sq)
    local outC = Machines.container(obj, "out")
    fill(outC, "Base.Plank", 25, {})                 -- 75 weight, 25 left, a log needs 3 * 7
    fill(Machines.container(obj, "in"), "Base.Log", 3, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 2, "one log went in before it was full")
    eq(state.reason, "outputFull")
end)

test("the propane refiner fills an empty tank from rotten food", function()
    setup()
    local obj, state, sq = addMachine("propaneRefiner", 10, 10)
    powered(sq)
    local inC = Machines.container(obj, "in")
    local tank = newItem("Base.PropaneTank", { fill = 0 })
    inC:AddItem(tank)
    fill(inC, "Base.Meat", 10, { classes = { Food = true }, rotten = true, weight = 5 })
    fill(inC, "Base.Apple", 3, { classes = { Food = true }, rotten = false, weight = 1 })
    TEST.hours = 1
    Machines.update(obj)
    -- 2 weight an hour: 25 hours for 50 weight. After 12.5 hours (5 weight each: one per 2.5 hours) 5 pieces.
    TEST.hours = 13.5
    Machines.update(obj)
    near(tank:getCurrentUsesFloat(), 0.5, 0.01, "half a tank")
    eq(countOf(inC, "Base.Apple"), 3, "fresh food is not taken")
    TEST.hours = 40
    Machines.update(obj)
    near(tank:getCurrentUsesFloat(), 1.0, 1e-6, "a full tank")
    eq(countOf(inC, "Base.Meat"), 0, "all ten used: 50 weight fills one tank")
end)

test("the propane refiner holds its product until a tank comes, and does nothing with a full tank", function()
    setup()
    local obj, state, sq = addMachine("propaneRefiner", 10, 10)
    powered(sq)
    local inC = Machines.container(obj, "in")
    fill(inC, "Base.Meat", 20, { classes = { Food = true }, rotten = true, weight = 5 })
    local full = newItem("Base.PropaneTank", { fill = 1 })
    inC:AddItem(full)
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 30
    Machines.update(obj)
    -- Without room in a tank the product waits in the machine, up to one tank's worth.
    truthy(state.buffer <= 1.0001, "buffer " .. tostring(state.buffer))
    eq(state.reason, "noTank")
    local empty = newItem("Base.PropaneTank", { fill = 0 })
    inC:AddItem(empty)
    TEST.hours = 31
    Machines.update(obj)
    TEST.hours = 32
    Machines.update(obj)
    truthy(empty:getCurrentUsesFloat() > 0.5, "the buffered product went into the new tank")
end)

test("the oil refiner makes petrol from oil and seeds", function()
    setup()
    local obj, state, sq = addMachine("oilRefiner", 10, 10)
    powered(sq)
    local inC = Machines.container(obj, "in")
    local can = newItem("Base.PetrolCan", { fluid = { amount = 0, capacity = 10 } })
    inC:AddItem(can)
    fill(inC, "Base.OilVegetable", 4, { classes = { Food = true }, baseHunger = -30, hunger = -30 })
    fill(inC, "Base.SunflowerSeeds", 90, { classes = { Food = true } })
    TEST.hours = 1
    Machines.update(obj)
    -- 5 L of oil at half a litre an hour is 10 hours. 4 + 1 = 5 L make 4 L of petrol.
    TEST.hours = 20
    Machines.update(obj)
    TEST.hours = 21
    Machines.update(obj)
    near(can.fluidBox.amount, 4.0, 0.01)
    eq(countOf(inC, "Base.OilVegetable"), 0)
    eq(countOf(inC, "Base.SunflowerSeeds"), 0)
end)

test("a half-used bottle of oil counts for what is left", function()
    setup()
    local bottle = newItem("Base.OilVegetable", { classes = { Food = true }, baseHunger = -30, hunger = -15 })
    near(Machines.oilOf(bottle), 0.5)
    eq(Machines.oilOf(newItem("Base.Sugar")), nil)
end)

test("accepts: what each machine lets in", function()
    setup()
    local cloth = newItem("Base.Tshirt", { classes = { Clothing = true }, fabric = "Cotton", location = "tshirt" })
    local hammer = newItem("Base.Hammer", {})
    local log = newItem("Base.Log", {})
    local meat = newItem("Base.Meat", { classes = { Food = true }, rotten = true })
    local fresh = newItem("Base.Apple", { classes = { Food = true } })
    truthy(Machines.accepts("bulkShredder", hammer))
    truthy(not Machines.accepts("bulkShredder", newItem("Base.Anvil", { weight = 300 })), "P1 refuses it")
    truthy(Machines.accepts("cutter", cloth))
    truthy(not Machines.accepts("cutter", hammer))
    truthy(Machines.accepts("woodSaw", log))
    truthy(not Machines.accepts("woodSaw", hammer))
    truthy(Machines.accepts("propaneRefiner", meat))
    truthy(not Machines.accepts("propaneRefiner", fresh))
    truthy(Machines.accepts("propaneRefiner", newItem("Base.PropaneTank", {})))
    truthy(Machines.accepts("oilRefiner", newItem("Base.OilOlive", { classes = { Food = true } })))
    truthy(Machines.accepts("oilRefiner", newItem("Base.PetrolCan", { fluid = {} })))
    truthy(not Machines.accepts("oilRefiner", hammer))
    truthy(Machines.accepts("bulkShredder", newItem("Base.Bag", { bag = true })), "bags and boxes go in")
end)

test("installing and removing parts", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    local p = player()
    local motor = newItem("OperationAcorn.MotorModern", {})
    motor.cond = 70
    p.inv:AddItem(motor)
    truthy(Machines.canInstall(obj, "motor", motor))
    local ok, why = Machines.canInstall(obj, "blade", motor)
    eq(ok, nil)
    eq(why, "wrongPart")
    truthy(Machines.installPart(obj, "motor", motor, p))
    eq(state.parts.motor.tier, "modern")
    eq(state.parts.motor.cond, 70)
    -- The old motor came out to the character, at the condition it had.
    eq(#p.inv.items, 1)
    eq(p.inv.items[1].fullType, "OperationAcorn.MotorOld")
    eq(p.inv.items[1].cond, 100)
    -- Removing it.
    truthy(Machines.removePart(obj, "motor", p))
    eq(state.parts.motor, nil)
    eq(#p.inv.items, 2)
    eq(p.inv.items[2].fullType, "OperationAcorn.MotorModern")
    eq(p.inv.items[2].cond, 70)
    -- Without a motor it is stopped.
    powered(sq)
    fill(Machines.container(obj, "in"), "Base.Hammer", 3, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 3)
    -- The cover goes in the saw only.
    local cover = newItem("OperationAcorn.SoundproofCover", {})
    eq(Machines.canInstall(obj, "cover", cover), nil)
    local saw = addMachine("woodSaw", 12, 12)
    truthy(Machines.canInstall(saw, "cover", cover))
    -- A vanilla item named like a part is not one.
    local fake = newItem("Base.MotorOld", {})
    eq(Machines.partOf(fake), nil)
end)

test("the generator load of machines", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    eq(Machines.load(obj), 0, "not running")
    state.running = true
    near(Machines.load(obj), 0.6)
    state.parts.motor = { tier = "modern", cond = 100 }
    near(Machines.load(obj), 0.9)
    near(Machines.loadOf({ kind = "cutter", parts = Machines.Logic.newParts("cutter"), running = true }), 0.4)
    local loads = Machines.loads()
    eq(#loads, 1)
    near(loads[1].load, 0.9)
end)

test("the lure sounds, then is spent", function()
    setup()
    local obj, state, sq = addMachine("lure", 10, 10)
    state.start, state.slot, state.spent, state.running = 0, -1, false, true
    TEST.hours = 0.01
    Machines.update(obj)
    eq(#sounds, 1)
    eq(sounds[1].radius, 60)
    TEST.hours = 0.1
    Machines.update(obj)
    eq(#sounds, 1)
    TEST.hours = 0.3
    Machines.update(obj)
    eq(#sounds, 2)
    TEST.hours = 24.5
    Machines.update(obj)
    eq(state.spent, true)
    eq(obj.sprite, OA.Sprites.lure(false))
    local count = #sounds
    TEST.hours = 30
    Machines.update(obj)
    eq(#sounds, count, "a spent lure is quiet")
    truthy(Machines.canPickUp(obj), "its shell may be removed")
end)

test("a lure that loads after its time is only a shell and sounds nothing", function()
    setup()
    local obj, state, sq = addMachine("lure", 18, 3)
    state.start, state.slot, state.spent, state.running = 0, -1, false, true
    TEST.hours = 10
    local chunk = { getGridSquare = function(self, lx, ly, lz) return squares[(16 + lx) .. "," .. ly .. "," .. lz] end }
    squares["16,0,0"] = newSquare(16, 0, 0)
    squares["18,3,0"] = sq
    Machines.onChunk(chunk)
    eq(#sounds, 0, "no sound for a catch-up")
    eq(state.spent, false)
    TEST.hours = 40
    Machines.onChunk(chunk)
    eq(state.spent, true)
end)

test("an armed lure cannot be picked up; a machine with things in it cannot", function()
    setup()
    local lure, lureState = addMachine("lure", 10, 10)
    lureState.start, lureState.slot, lureState.spent = 0, -1, false
    local ok, why = Machines.canPickUp(lure)
    eq(ok, nil)
    eq(why, "armed")
    local obj = addMachine("cutter", 12, 12)
    truthy(Machines.canPickUp(obj))
    fill(Machines.container(obj, "in"), "Base.Hammer", 1, {})
    ok, why = Machines.canPickUp(obj)
    eq(ok, nil)
    eq(why, "notEmpty")
end)

test("the tick works loaded machines and forgets ones whose object is gone", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    fill(Machines.container(obj, "in"), "Base.Hammer", 2, {})
    TEST.hours = 1
    Machines.tick()
    eq(state.idle, false)
    -- A machine in an unloaded place is left alone.
    local reg = OA.Store.world("machines")
    reg.list["far"] = { kind = "cutter", x = 500, y = 500, z = 0 }
    Machines.tick()
    truthy(reg.list["far"], "unloaded stays")
    -- The object disappears from a loaded square: gone after two ticks.
    sq.objects = {}
    Machines.tick()
    truthy(reg.list[state.id], "once is not enough")
    Machines.tick()
    eq(reg.list[state.id], nil)
end)

test("the registry finds a machine by id and by square", function()
    setup()
    local obj, state, sq = addMachine("cutter", 10, 10)
    eq(Machines.find(state.id), obj)
    eq(Machines.at(sq), obj)
    eq(Machines.find("nope"), nil)
    eq(Machines.list()[state.id].kind, "cutter")
end)

test("hand shredding takes the items and gives bundles, booked to the record", function()
    setup()
    local p = player()
    local hammer = newItem("Base.Hammer", {})
    p.inv:AddItem(hammer)
    local anvil = newItem("Base.Anvil", { weight = 300 })
    p.inv:AddItem(anvil)
    local entries = Machines.benchCandidates(p, 10)
    eq(#entries, 1, "the anvil is refused by P1's rule")
    local record = OA.Store.player("p1")
    local n = Machines.shredByHand(p, record, { hammer })
    eq(n, 5)
    eq(countOf(p.inv, "OperationAcorn.SampleBundle"), 5)
    eq(countOf(p.inv, "Base.Hammer"), 0)
    eq(#OA.Shred.committed, 1)
    near(Machines.benchMinutesFor(entries), 2)
end)

test("sprites follow the state and the kind", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    state.dir = "E"
    state.running = false
    Machines.refreshLook(obj, state)
    eq(obj.sprite, OA.Sprites.machine("bulkShredder", "E", false))
    state.running = true
    Machines.refreshLook(obj, state)
    eq(obj.sprite, OA.Sprites.machine("bulkShredder", "E", true))
    eq(Machines.spriteName("rainStorage", "N", false), OA.Sprites.RAIN_STORAGE)
    eq(Machines.spriteName("lure", "N", true), OA.Sprites.lure(true))
    eq(Machines.itemFullType("woodSaw"), "OperationAcorn.LogSaw")
end)

test("the unpowered grid: a square needs a generator or the grid inside a room", function()
    setup()
    local sq = newSquare(1, 1, 0)
    eq(Machines.hasPower(sq), false)
    sq.power = true
    eq(Machines.hasPower(sq), true)
    sq.power = false
    sq.hasGridPower = function() return true end
    eq(Machines.hasPower(sq), true, "grid power in a room")
    sq.room = false
    eq(Machines.hasPower(sq), false, "not outside")
end)

test("status for the window", function()
    setup()
    local obj, state, sq = addMachine("woodSaw", 10, 10)
    obj.getFluidAmount = nil
    local st = Machines.status(obj)
    eq(st.kind, "woodSaw")
    near(st.rate, 12)
    near(st.load, 0.8)
    eq(st.noise, 40)
    eq(st.stopped, false)
    state.parts.cover = { tier = "normal", cond = 100 }
    st = Machines.status(obj)
    eq(st.noise, 20)
    near(st.rate, 12 * 0.85)
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- Multi-tile machines (DESIGN 12: big facilities take several tiles)

-- The fakes for building objects: squares that can take objects, thumpables, containers made by the script.
local function worldSetup()
    setup()
    local function square(x, y, z)
        local key = x .. "," .. y .. "," .. z
        if not squares[key] then
            local sq = newSquare(x, y, z)
            sq.outside = true
            function sq:TreatAsSolidFloor() return true end
            function sq:isSolid() return false end
            function sq:isSolidTrans() return false end
            function sq:HasStairs() return false end
            function sq:HasTree() return false end
            function sq:isFree() return not self.busy end
            function sq:isVehicleIntersecting() return false end
            function sq:getProperties() return { has = function() return false end } end
            function sq:isOutside() return self.outside end
            function sq:RecalcAllWithNeighbours() end
            function sq:AddSpecialObject(object) table.insert(self.objects, object) end
            function sq:transmitRemoveItemFromSquare(object)
                for i, o in ipairs(self.objects) do
                    if o == object then table.remove(self.objects, i) return end
                end
            end
            function sq:AddWorldInventoryItem(item) self.dropped = self.dropped or {}; table.insert(self.dropped, item) end
            squares[key] = sq
        end
        return squares[key]
    end
    getCell = function()
        return { getGridSquare = function(self, x, y, z) return squares[x .. "," .. y .. "," .. z] end }
    end
    IsoFlagType = { water = "water" }
    IsoThumpable = { new = function(cell, sq, sprite)
        local obj = newObject(sq, nil)
        obj.sprite = sprite
        obj.thumpable = true
        function obj:setCanPassThrough(v) self.passable = v end
        function obj:setBlockAllTheSquare(v) self.blocks = v end
        function obj:setCanBarricade() end
        function obj:setIsThumpable() end
        function obj:setIsDismantable() end
        function obj:setIsHoppable() end
        function obj:setMaxHealth() end
        function obj:setHealth() end
        function obj:setBreakSound() end
        function obj:setIsContainer(v) self.isContainer = v; self.containers[1] = self.containers[1] or newContainer("none", 100) end
        function obj:getContainer() return self.containers[1] end
        function obj:addSecondaryContainer(c) table.insert(self.containers, c) end
        function obj:transmitCompleteItemToClients() end
        function obj:getObjectIndex() return 0 end
        return obj
    end }
    ItemContainer = { new = function(kind, sq, parent)
        local c = newContainer(kind, 100)
        c.parent = parent
        return c
    end }
    entityCalls = {}
    getScriptManager = function()
        return { getGameEntityScript = function(self, name) return { name = name } end }
    end
    GameEntityFactory = { CreateIsoObjectEntity = function(object, script) entityCalls[#entityCalls + 1] = { object = object, script = script } end }
    getSprite = function() return nil end
    -- The assets' multi-tile functions (P8): a 2x1 and a 2x2.
    OA.Sprites.machineTiles = function(kind, dir, running)
        local w, h = 2, 1
        if kind == "propaneRefiner" or kind == "oilRefiner" then w, h = 2, 2 end
        if dir == "E" or dir == "W" then w, h = h, w end
        local tiles = {}
        for dy = 0, h - 1 do
            for dx = 0, w - 1 do
                tiles[#tiles + 1] = { dx = dx, dy = dy, sprite = kind .. dir .. (running and "R" or "S") .. dx .. dy }
            end
        end
        return tiles
    end
    OA.Sprites.rainStorageTiles = function()
        return { { dx = 0, dy = 0, sprite = "rain00" }, { dx = 1, dy = 0, sprite = "rain10" },
            { dx = 0, dy = 1, sprite = "rain01" }, { dx = 1, dy = 1, sprite = "rain11" } }
    end
    return square
end

local function cleanup()
    OA.Sprites.machineTiles, OA.Sprites.rainStorageTiles = nil, nil
end

test("a 2x1 machine takes two squares: the anchor holds the state, the other points to it", function()
    local square = worldSetup()
    local p = player()
    local item = newItem("OperationAcorn.BulkShredder")
    local sq = square(10, 10, 0)
    square(11, 10, 0)
    square(10, 11, 0)
    eq(Machines.footprint("bulkShredder", "S"), 2)
    local _, h = Machines.footprint("bulkShredder", "E")
    eq(h, 2, "turned, it is two along y")
    truthy(Machines.canPlace("bulkShredder", sq, "S"))
    local anchor = Machines.place("bulkShredder", sq, p, item, "S")
    truthy(anchor)
    local state = Machines.state(anchor)
    eq(state.x, 10)
    eq(state.y, 10)
    local partSquare = square(11, 10, 0)
    eq(#partSquare.objects, 1)
    local part = partSquare.objects[1]
    eq(Machines.state(part), nil)
    eq(part.mod[Data.ANCHOR_KEY].id, state.id)
    eq(part.sprite, "bulkShredderSS10")
    eq(anchor.sprite, "bulkShredderSS00")
    eq(#anchor.containers, 2, "in and out, on the anchor only")
    eq(#part.containers, 0)
    -- Any part resolves to the anchor.
    eq(Machines.at(partSquare), anchor)
    eq(Machines.at(sq), anchor)
    eq(Machines.anchorOf(part), anchor)
    -- Only the anchor is registered.
    local count = 0
    for _ in pairs(Machines.list()) do count = count + 1 end
    eq(count, 1)
    eq(Machines.find(state.id), anchor)
    -- The square next to it is free; one the machine covers is taken.
    local ok, why = Machines.canPlace("lure", partSquare, "S")
    eq(ok, nil)
    eq(why, "taken")
    cleanup()
end)

test("turning changes the footprint, and a blocked square refuses the whole machine", function()
    local square = worldSetup()
    local sq = square(20, 20, 0)
    square(21, 20, 0)
    square(20, 21, 0).busy = true
    truthy(Machines.canPlace("cutter", sq, "S"))
    local ok, why = Machines.canPlace("cutter", sq, "E")
    eq(ok, nil)
    eq(why, "blocked")
    ok, why = Machines.canPlace("cutter", square(21, 20, 0), "S")
    eq(ok, nil)
    eq(why, "noSquare", "the second square of the footprint is not loaded")
    -- The refiner needs four squares and the fourth is not loaded.
    ok, why = Machines.canPlace("propaneRefiner", sq, "S")
    eq(ok, nil)
    eq(why, "noSquare")
    cleanup()
end)

test("the rain storage is 2x2 and only outside; the entity is made on the anchor's tile alone", function()
    local square = worldSetup()
    local p = player()
    local sq = square(30, 30, 0)
    square(31, 30, 0)
    square(30, 31, 0)
    local inside = square(31, 31, 0)
    inside.outside = false
    local ok, why = Machines.canPlace("rainStorage", sq, "S")
    eq(ok, nil)
    eq(why, "notOutside")
    inside.outside = true
    truthy(Machines.canPlace("rainStorage", sq, "E"), "it does not turn: always the same four squares")
    local anchor = Machines.place("rainStorage", sq, p, newItem("OperationAcorn.RainCistern"), "N")
    eq(#entityCalls, 1)
    eq(entityCalls[1].object, anchor)
    eq(entityCalls[1].script.name, Data.RAIN_ENTITY)
    eq(anchor.sprite, "rain00")
    eq(square(31, 31, 0).objects[1].sprite, "rain11")
    for _, key in ipairs({ "31,30,0", "30,31,0", "31,31,0" }) do
        eq(#squares[key].objects, 1)
        eq(Machines.at(squares[key]), anchor)
    end
    cleanup()
end)

test("the lure is one passable tile", function()
    local square = worldSetup()
    local p = player()
    local sq = square(40, 40, 0)
    local anchor = Machines.place("lure", sq, p, newItem("OperationAcorn.BaitTrap"), "S")
    truthy(anchor)
    eq(anchor.passable, true)
    eq(anchor.blocks, false)
    eq(#sq.objects, 1)
    cleanup()
end)

test("picking up removes every part and gives one item with the parts", function()
    local square = worldSetup()
    local p = player()
    local sq = square(10, 10, 0)
    square(11, 10, 0)
    local anchor = Machines.place("woodSaw", sq, p, newItem("OperationAcorn.LogSaw"), "S")
    local state = Machines.state(anchor)
    state.parts.blade.cond = 61
    truthy(Machines.canPickUp(anchor))
    local item = Machines.pickUp(anchor, p)
    truthy(item)
    eq(item:getFullType(), "OperationAcorn.LogSaw")
    eq(item.mod[Data.KEY].parts.blade.cond, 61)
    eq(#sq.objects, 0)
    eq(#square(11, 10, 0).objects, 0)
    eq(Machines.list()[state.id], nil)
    eq(countOf(p.inv, "OperationAcorn.LogSaw"), 1)
    cleanup()
end)

test("a machine with something in it cannot be picked up, wherever it is clicked", function()
    local square = worldSetup()
    local p = player()
    local sq = square(10, 10, 0)
    local other = square(11, 10, 0)
    local anchor = Machines.place("cutter", sq, p, newItem("OperationAcorn.FabricCutter"), "S")
    fill(Machines.container(anchor, "out"), "Base.RippedSheets", 1)
    local found = Machines.at(other)
    eq(found, anchor)
    local ok, why = Machines.canPickUp(found)
    eq(ok, nil)
    eq(why, "notEmpty")
    cleanup()
end)

test("destroying any part takes the whole machine, dropping what it held", function()
    local square = worldSetup()
    local p = player()
    local sq = square(10, 10, 0)
    local other = square(11, 10, 0)
    local anchor = Machines.place("cutter", sq, p, newItem("OperationAcorn.FabricCutter"), "S")
    local state = Machines.state(anchor)
    fill(Machines.container(anchor, "in"), "Base.Hammer", 2)
    local part = other.objects[1]
    Machines.forget(part)
    eq(#sq.objects, 0, "the anchor goes too")
    eq(#sq.dropped, 2, "what was in it lies on the floor")
    eq(Machines.list()[state.id], nil)
    cleanup()
end)

test("destroying the anchor takes the other parts", function()
    local square = worldSetup()
    local p = player()
    local s1, s2 = square(20, 20, 0), square(21, 20, 0)
    local a = Machines.place("cutter", s1, p, newItem("OperationAcorn.FabricCutter"), "S")
    local id = Machines.state(a).id
    s1:transmitRemoveItemFromSquare(a)
    Machines.forget(a)
    eq(#s2.objects, 0)
    eq(Machines.list()[id], nil)
    cleanup()
end)

test("an orphan part whose anchor is gone is removed when it is looked at", function()
    local square = worldSetup()
    local p = player()
    local s1, s2 = square(10, 10, 0), square(11, 10, 0)
    local a = Machines.place("cutter", s1, p, newItem("OperationAcorn.FabricCutter"), "S")
    s1:transmitRemoveItemFromSquare(a)
    eq(Machines.at(s2), nil)
    eq(#s2.objects, 0)
    cleanup()
end)

test("a part whose anchor's square is not loaded waits", function()
    local square = worldSetup()
    local p = player()
    local s1, s2 = square(10, 10, 0), square(11, 10, 0)
    Machines.place("cutter", s1, p, newItem("OperationAcorn.FabricCutter"), "S")
    squares["10,10,0"] = nil
    eq(Machines.at(s2), nil)
    eq(#s2.objects, 1, "kept")
    cleanup()
end)

test("the look follows the state on every tile", function()
    local square = worldSetup()
    local p = player()
    local s1, s2 = square(10, 10, 0), square(11, 10, 0)
    local a = Machines.place("bulkShredder", s1, p, newItem("OperationAcorn.BulkShredder"), "S")
    local state = Machines.state(a)
    state.running = true
    Machines.refreshLook(a, state)
    eq(a.sprite, "bulkShredderSR00")
    eq(s2.objects[1].sprite, "bulkShredderSR10")
    state.running = false
    Machines.refreshLook(a, state)
    eq(s2.objects[1].sprite, "bulkShredderSS10")
    cleanup()
end)

test("a 2x2 refiner works from its anchor as before", function()
    local square = worldSetup()
    local p = player()
    local sq = square(10, 10, 0)
    square(11, 10, 0); square(10, 11, 0); square(11, 11, 0)
    local a = Machines.place("propaneRefiner", sq, p, newItem("OperationAcorn.PropaneRefinery"), "S")
    eq(#squares["11,11,0"].objects, 1)
    sq.power = true
    local inC = Machines.container(a, "in")
    local tank = newItem("Base.PropaneTank", { fill = 0 })
    inC:AddItem(tank)
    fill(inC, "Base.Meat", 10, { classes = { Food = true }, rotten = true, weight = 5 })
    TEST.hours = 1
    Machines.tick()
    TEST.hours = 13.5
    Machines.tick()
    near(tank:getCurrentUsesFloat(), 0.5, 0.01, "half a tank")
    cleanup()
end)
