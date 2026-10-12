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
    ["OperationAcorn.SampleBundle"] = { weight = 1.0 },
    ["OperationAcorn.SelectedSample"] = { weight = 0.5 },
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
    function c:getContentsWeight()
        local w = 0
        for _, it in ipairs(self.items) do w = w + it:getActualWeight() end
        return w
    end
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
    function obj:hasModData() return not OA.isEmpty(self.mod) end
    function obj:getModData() return self.mod end
    function obj:getSquare() return self.square end
    -- the game's appliance question: a generator's electricity, or the grid's inside a room
    function obj:checkObjectPowered()
        local sq = self.square
        return sq:haveElectricity() or (sq:hasGridPower() and sq:getRoom() ~= nil)
    end
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
    function obj:setSpriteFromName(name) self.sprite = name end
    function obj:transmitModData() end
    -- the animations drawn over it (the lure's sound rings)
    obj.anims = {}
    function obj:hasAttachedAnimSprites() return #self.anims > 0 end
    function obj:RemoveAttachedAnims() self.anims = {} end
    function obj:AttachExistingAnim(sprite)
        local instance = { sprite = sprite }
        function instance:setFrameSpeedPerFrame(v) self.speed = v end
        table.insert(self.anims, instance)
    end
    function obj:getAttachedAnimSprite()
        local anims = self.anims
        return { size = function() return #anims end, get = function(_, i) return anims[i + 1] end }
    end
    return obj
end
IsoSprite = { CreateSpriteUsingCache = function(name, anim, frames) return { name = name, anim = anim, frames = frames } end }
ColorInfo = { new = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }

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
    -- P1's pieces, simplified: every item yields half its weight, the rest of a bundle is kept on the record, a kind
    -- shredded before is not first.
    OA.Value = { info = function(item)
        return { fullType = item:getFullType(), baseType = item:getFullType(), weight = item:getActualWeight() }
    end }
    OA.Shred = {
        committed = {},
        can = function(info) return info.weight < 100 end,
        yield = function(info, record, extras)
            return info.weight * 0.5 * (extras and extras.blade or 1), 0
        end,
        carry = function(record, x)
            local total = (record.rest or 0) + x
            local whole = math.floor(total + 1e-9)
            record.rest = total - whole
            return whole
        end,
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
    eq(countOf(outC, "OperationAcorn.SampleBundle"), 5, "10 items of weight 1: half a bundle each")
    eq(state.idle, true)
    eq(state.running, false)
    eq(#OA.Shred.committed, 10, "each shred was booked")
    eq(OA.Shred.committed[1].record.id, "p1")
    eq(inC.items[1], box, "the box stays")
    truthy(#sounds >= 1, "it made noise")
    eq(sounds[1].radius, 40)
end)

test("the progress a window shows: the first job's share by now, nil when it is not working", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    local inC = Machines.container(obj, "in")
    fill(inC, "Base.Hammer", 3, {})                   -- weight 1 each: five minutes each at 12 an hour
    eq(Machines.progress(obj), nil, "idle until a step finds the input")
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 1 + 1 / 24
    local jobs = Machines.progress(obj)
    eq(#jobs, 1, "one lane with the old motor")
    eq(jobs[1].item, inC.items[1])
    truthy(math.abs(jobs[1].share - 0.5) < 1e-6, "two and a half of five minutes")
    -- asked to work at that time (a watched window), half a hammer is kept, none done
    Machines.update(obj)
    eq(#inC.items, 3)
    TEST.hours = 1 + 1 / 12
    Machines.update(obj)
    eq(#inC.items, 2, "the first is done the moment its share is full")
    eq(#sounds, 1, "worked twice in ten minutes: one noise")
    -- a normal motor: the next two at once, a bar each
    state.parts.motor = { tier = "normal", cond = 100 }
    local two = Machines.progress(obj)
    eq(#two, 2, "two lanes")
    eq(two[1].item, inC.items[1])
    eq(two[2].item, inC.items[2])
    TEST.hours = TEST.hours + 1 / (12 * 1.15)
    Machines.update(obj)
    eq(#inC.items, 0, "both done together")
    Machines.setOn(obj, false)
    eq(Machines.progress(obj), nil, "switched off")
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
    -- Away for 10 minutes: 2 weight of hammers, 2 hammers.
    TEST.hours = 1 + 1 / 6
    local chunk = { getGridSquare = function(self, lx, ly, lz)
        return squares[(16 + lx) .. "," .. (0 + ly) .. "," .. lz]
    end }
    -- The chunk of (18, 3) starts at (16, 0).
    squares["16,0,0"] = newSquare(16, 0, 0)
    squares["18,3,0"] = sq
    Machines.onChunk(chunk)
    eq(#inC.items, 98, "2 of 100 shredded")
    eq(countOf(outC, "OperationAcorn.SampleBundle"), 1)
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
    TEST.hours = 3
    Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 28, "an hour: 12 weight")
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
    fill(Machines.container(obj, "in"), "Base.Hammer", 5, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    -- The fake yield multiplies by the blade: 5 x 0.5 x 1.2 = 3.
    eq(countOf(Machines.container(obj, "out"), "OperationAcorn.SampleBundle"), 3)
end)

test("parts wear while it runs and a worn-out motor stops it, with a note", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    state.parts.motor.cond = 1
    fill(Machines.container(obj, "in"), "Base.Hammer", 200, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 4
    Machines.update(obj)
    eq(state.parts.motor.cond, 0)
    local broken = false
    for _, h in ipairs(halo) do
        if h.key == "IGUI_OA_Machine_PartBroken" then broken = true end
    end
    truthy(broken, "told the owner")
    TEST.hours = 5
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
    eq(sounds[1].radius, 60)
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
    Machines.container(obj, "tank"):AddItem(tank)
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
    Machines.container(obj, "tank"):AddItem(full)
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 30
    Machines.update(obj)
    -- Without room in a tank the product waits in the machine, up to one tank's worth.
    truthy(state.buffer <= 1.0001, "buffer " .. tostring(state.buffer))
    eq(state.reason, "noTank")
    local empty = newItem("Base.PropaneTank", { fill = 0 })
    Machines.container(obj, "tank"):AddItem(empty)
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
    Machines.container(obj, "tank"):AddItem(can)
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
    truthy(not Machines.accepts("propaneRefiner", newItem("Base.PropaneTank", {})), "tanks go in the fill box")
    truthy(Machines.acceptsTank("propaneRefiner", newItem("Base.PropaneTank", {})))
    truthy(not Machines.acceptsTank("propaneRefiner", meat), "food does not go in the fill box")
    truthy(Machines.accepts("oilRefiner", newItem("Base.OilOlive", { classes = { Food = true } })))
    truthy(not Machines.accepts("oilRefiner", newItem("Base.PetrolCan", { fluid = {} })))
    truthy(Machines.acceptsTank("oilRefiner", newItem("Base.PetrolCan", { fluid = {} })))
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
    -- Taking a part out switches it off; without a motor it cannot be switched on, nor work.
    eq(state.on, false, "switched off by the removal")
    local can, why = Machines.canSwitchOn(obj)
    eq(can, nil)
    truthy(why and why:find("motor"), "says the motor")
    Machines.setOn(obj, true)
    eq(state.on, false, "not switched on without a motor")
    eq(Machines.stopText(obj), "IGUI_OA_Machine_CannotOn_missing IGUI_OA_Machine_Slot_motor", "why it is not working")
    state.on = true
    powered(sq)
    fill(Machines.container(obj, "in"), "Base.Hammer", 3, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 2
    Machines.update(obj)
    eq(#Machines.container(obj, "in").items, 3)
    -- The cover goes in every powered machine.
    local cover = newItem("OperationAcorn.SoundproofCover", {})
    truthy(Machines.canInstall(obj, "cover", cover))
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
    local obj, state = addMachine("cutter", 12, 12)
    state.parts = {}
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

test("fast-forwarded, a machine missing for a few steps is kept until MISSING_MS of real time", function()
    setup()
    local obj, state, sq = addMachine("cutter", 10, 10)
    local reg = OA.Store.world("machines")
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    local objects = sq.objects
    sq.objects = {}
    -- x40: ten-minute steps some 0.6 s apart while the chunk streams in
    for _ = 1, 10 do
        Machines.tick()
        clock = clock + 600
    end
    truthy(reg.list[state.id], "kept within MISSING_MS")
    -- the object is there now: the count starts over
    sq.objects = objects
    Machines.tick()
    sq.objects = {}
    clock = clock + 600
    Machines.tick()
    clock = clock + Machines.MISSING_MS - 1
    Machines.tick()
    truthy(reg.list[state.id], "missing again only since the last find")
    clock = clock + 1
    Machines.tick()
    eq(reg.list[state.id], nil, "gone once MISSING_MS passed")
end)

test("a machine's square unloaded in between starts its missing time over", function()
    setup()
    local obj, state, sq = addMachine("cutter", 10, 10)
    local reg = OA.Store.world("machines")
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    local entry = reg.list[state.id]
    entry.missed = 1   -- a save from before kept a count of steps
    sq.objects = {}
    Machines.tick()
    eq(entry.missed, nil, "the old count goes")
    -- the place unloads (its square is somewhere else now), and loads again later
    local x = entry.x
    entry.x = 500
    clock = clock + Machines.MISSING_MS
    Machines.tick()
    entry.x = x
    clock = clock + 1000
    Machines.tick()
    truthy(reg.list[state.id], "the first miss of this load")
    clock = clock + Machines.MISSING_MS
    Machines.tick()
    eq(reg.list[state.id], nil)
    truthy(Machines.MISSING_MS <= 25000, "the default speed (25 s for ten game minutes) drops at the second step")
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
    local hammer = newItem("Base.Hammer", { weight = 2 })
    p.inv:AddItem(hammer)
    local anvil = newItem("Base.Anvil", { weight = 300 })
    p.inv:AddItem(anvil)
    local entries = Machines.benchCandidates(p, 10)
    eq(#entries, 1, "the anvil is refused by P1's rule")
    local record = OA.Store.player("p1")
    local n = Machines.shredByHand(p, record, { hammer })
    eq(n, 1, "weight 2: one bundle")
    eq(countOf(p.inv, "OperationAcorn.SampleBundle"), 1)
    eq(countOf(p.inv, "Base.Hammer"), 0)
    eq(#OA.Shred.committed, 1)
    near(Machines.benchMinutesFor(entries), 10)
end)

test("a selected sample comes with a bundle by the record's chance, by hand and in the bulk shredder", function()
    setup()
    local record = OA.Store.player("p1")
    local was = OA.Upgrades
    OA.Upgrades = { selectedChance = function() return 0.25 end }
    local rolls = { 0.1, 0.9, 0.24, 0.25 }
    local i = 0
    local function roll() i = i + 1 return rolls[i] end
    eq(Machines.selectedOf(record, 4, roll), 2, "under the chance: 0.1 and 0.24")
    eq(Machines.selectedOf(record, 0, roll), 0, "no bundle, no roll")
    OA.Upgrades = { selectedChance = function() return 1 end }
    local p = player()
    local hammer = newItem("Base.Hammer", { weight = 4 })
    p.inv:AddItem(hammer)
    local n, selected = Machines.shredByHand(p, record, { hammer })
    eq(n, 2)
    eq(selected, 2)
    eq(countOf(p.inv, "OperationAcorn.SelectedSample"), 2)
    OA.Upgrades = nil
    eq(Machines.selectedOf(record, 3), 0, "without the upgrades part there is none")
    OA.Upgrades = was
end)

test("sprites follow the state and the kind", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    state.dir = "E"
    state.running = false
    Machines.refreshLook(obj, state)
    eq(obj.sprite, OA.Sprites.machineTiles("bulkShredder", "E", false)[1].sprite)
    state.running = true
    Machines.refreshLook(obj, state)
    eq(obj.sprite, OA.Sprites.machineTiles("bulkShredder", "E", true)[1].sprite)
    eq(Machines.spriteName("rainStorage", "N", false), OA.Sprites.rainStorageTiles()[1].sprite)
    eq(Machines.spriteName("lure", "N", true), OA.Sprites.lure(true))
    eq(Machines.itemFullType("woodSaw"), "OperationAcorn.LogSaw")
end)

test("a machine has power as the game's appliances do: the object is asked, not its square", function()
    setup()
    local sq = newSquare(1, 1, 0)
    local obj = newObject(sq)
    eq(Machines.hasPower(obj), false)
    sq.power = true
    eq(Machines.hasPower(obj), true)
    sq.power = false
    sq.hasGridPower = function() return true end
    eq(Machines.hasPower(obj), true, "grid power in a room")
    sq.room = false
    eq(Machines.hasPower(obj), false, "not outside")
    -- a power network's consumer outdoors: the square has nothing, the object is powered (the extension API's answer)
    obj.checkObjectPowered = function() return true end
    eq(sq:haveElectricity(), false)
    eq(Machines.hasPower(obj), true, "a network's consumer")
    eq(Machines.hasPower(nil), false)
    obj.square = nil
    eq(Machines.hasPower(obj), false, "off the map")
end)

test("status for the window", function()
    setup()
    local obj, state, sq = addMachine("woodSaw", 10, 10)
    obj.getFluidAmount = nil
    local st = Machines.status(obj)
    eq(st.kind, "woodSaw")
    near(st.rate, 180)
    eq(st.lanes, 1)
    near(st.load, 0.8)
    eq(st.noise, 60)
    eq(st.stopped, false)
    state.parts.cover = { tier = "normal", cond = 100 }
    st = Machines.status(obj)
    eq(st.noise, 30)
    near(st.rate, 180 * 0.85)
    state.parts.motor = { tier = "modern", cond = 100 }
    st = Machines.status(obj)
    eq(st.lanes, 3)
    near(st.rate, 180 * 0.85 * 1.3 * 3, 1e-6, "every lane counts")
    near(st.speed, 0.85 * 1.3 * 3, 1e-6)
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
            -- like the game: the index the object had, -1 when it is not there
            function sq:transmitRemoveItemFromSquare(object)
                for i, o in ipairs(self.objects) do
                    if o == object then table.remove(self.objects, i) return i - 1 end
                end
                return -1
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
        -- like the game: its place on its square, -1 once it is off it
        function obj:getObjectIndex()
            local sq = self:getSquare()
            for i, o in ipairs(sq and sq.objects or {}) do
                if o == self then return i - 1 end
            end
            return -1
        end
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
    eq(#anchor.containers, 1, "the input on the anchor (the hopper)")
    eq(#part.containers, 1, "the output on the other square (the bin)")
    eq(Machines.container(anchor, "in"), anchor.containers[1])
    eq(Machines.container(anchor, "out"), part.containers[1], "the anchor finds its output on the other square")
    eq(Machines.container(anchor, "out"), part.containers[1], "and again, from what it noted")
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

test("the rain storage shows its water as overlays, changed only when the level passes to another look", function()
    local square = worldSetup()
    local p = player()
    local sq = square(30, 30, 0)
    square(31, 30, 0)
    square(30, 31, 0)
    square(31, 31, 0)
    OA.Sprites.rainOverlayTiles = function(level)
        if level <= 0 then return {} end
        return { { dx = 0, dy = 0, sprite = "w" .. level .. "00" }, { dx = 1, dy = 0, sprite = "w" .. level .. "10" },
            { dx = 0, dy = 1, sprite = "w" .. level .. "01" }, { dx = 1, dy = 1, sprite = "w" .. level .. "11" } }
    end
    local anchor = Machines.place("rainStorage", sq, p, newItem("OperationAcorn.RainCistern"), "S")
    local water, sets = 0, 0
    local function overlays(object)
        object.overlay = nil
        function object:getOverlaySprite()
            local name = self.overlay
            return name and { getName = function() return name end } or nil
        end
        function object:setOverlaySprite(name) self.overlay = name; sets = sets + 1 end
    end
    local objects = { anchor, squares["31,30,0"].objects[1], squares["30,31,0"].objects[1], squares["31,31,0"].objects[1] }
    for _, o in ipairs(objects) do overlays(o) end
    function anchor:getFluidAmount() return water end
    function anchor:getFluidCapacity() return 4000 end
    local function shown()
        local names = {}
        for i, o in ipairs(objects) do names[i] = o.overlay or "-" end
        return table.concat(names, " ")
    end

    eq(Machines.rainLevel(0, 4000), 0)
    eq(Machines.rainLevel(79, 4000), 0, "under 2 % is dry")
    eq(Machines.rainLevel(80, 4000), 1, "any water shows")
    eq(Machines.rainLevel(1499, 4000), 1)
    eq(Machines.rainLevel(1500, 4000), 2)
    eq(Machines.rainLevel(2999, 4000), 2)
    eq(Machines.rainLevel(3000, 4000), 3)
    eq(Machines.rainLevel(10, 0), 0, "no capacity")

    Machines.tick()
    eq(shown(), "- - - -", "dry")
    eq(sets, 0, "nothing to change on a dry new tank")
    water = 500
    Machines.tick()
    eq(shown(), "w100 w110 w101 w111")
    eq(sets, 4)
    water = 1400
    Machines.tick()
    eq(sets, 4, "the same look: nothing set")
    water = 3500
    Machines.tick()
    eq(shown(), "w300 w310 w301 w311")
    water = 0
    Machines.tick()
    eq(shown(), "- - - -", "drained: the overlays go")

    -- A square not loaded: what is loaded changes now, the rest on a later step.
    water = 2000
    local away = squares["31,31,0"]
    squares["31,31,0"] = nil
    Machines.tick()
    eq(shown(), "w200 w210 w201 -")
    squares["31,31,0"] = away
    Machines.tick()
    eq(shown(), "w200 w210 w201 w211")
    local before = sets
    Machines.tick()
    eq(sets, before, "settled")
    OA.Sprites.rainOverlayTiles = nil
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

test("parts count as contents: a machine is taken up only with its parts out", function()
    local square = worldSetup()
    local p = player()
    local sq = square(10, 10, 0)
    square(11, 10, 0)
    local anchor = Machines.place("woodSaw", sq, p, newItem("OperationAcorn.LogSaw"), "S")
    local state = Machines.state(anchor)
    truthy(state.parts.motor and state.parts.blade, "a new machine has its parts")
    local ok, why = Machines.canPickUp(anchor)
    eq(ok, nil)
    eq(why, "hasParts")
    state.parts.blade.cond = 61
    truthy(Machines.removePart(anchor, "blade", p))
    truthy(Machines.removePart(anchor, "motor", p))
    eq(countOf(p.inv, "OperationAcorn.SawBladeOld"), 1, "the blade comes out as its item")
    truthy(Machines.canPickUp(anchor))
    cleanup()
end)

test("a machine put down from its pieces has no parts", function()
    local square = worldSetup()
    local p = player()
    local sq = square(10, 10, 0)
    square(11, 10, 0)
    local anchor = Machines.place("woodSaw", sq, p, nil, "S", true)
    truthy(OA.isEmpty(Machines.state(anchor).parts))
    truthy(Machines.canPickUp(anchor))
    cleanup()
end)

test("clearing a spent lure removes it and gives nothing", function()
    local square = worldSetup()
    local p = player()
    local sq = square(40, 40, 0)
    local anchor = Machines.place("lure", sq, p, newItem("OperationAcorn.BaitTrap"), "S")
    local state = Machines.state(anchor)
    eq(Machines.pickUp(anchor), false, "an armed lure stays")
    state.spent = true
    eq(Machines.pickUp(anchor), true)
    eq(#sq.objects, 0)
    eq(Machines.list()[state.id], nil)
    eq(#p.inv.items, 0)
    cleanup()
end)

test("a refiner of an older save, with no fill box, is given one", function()
    local square = worldSetup()
    local p = player()
    local sq = square(10, 10, 0)
    square(11, 10, 0); square(10, 11, 0); square(11, 11, 0)
    local a = Machines.place("propaneRefiner", sq, p, newItem("OperationAcorn.PropaneRefinery"), "S")
    -- as it was: the input only
    for i = #a.containers, 1, -1 do
        if a.containers[i].type == "OAMachineTank" then table.remove(a.containers, i) end
    end
    eq(Machines.container(a, "tank"), nil)
    Machines.addMissingContainers(a, sq, { "in", "tank" })
    truthy(Machines.container(a, "tank"), "the fill box")
    eq(#a.containers, 2, "the input kept, one new")
    Machines.addMissingContainers(a, sq, { "in", "tank" })
    eq(#a.containers, 2, "nothing more the second time")
    cleanup()
end)

test("a working lure plays its sound rings, once, and a spent one does not", function()
    local square = worldSetup()
    local p = player()
    local sq = square(40, 40, 0)
    local anchor = Machines.place("lure", sq, p, newItem("OperationAcorn.BaitTrap"), "S")
    local state = Machines.state(anchor)
    eq(#anchor.anims, 1, "placed: the rings")
    eq(anchor.anims[1].sprite.name, Machines.Data.LURE_FX.name)
    eq(anchor.anims[1].speed, Machines.Data.LURE_FX.speed)
    eq(anchor.mod[Machines.Data.ANIM_KEY], 1, "the API steps it")
    Machines.refreshLook(anchor, state)
    eq(#anchor.anims, 1, "shown again: still one")
    state.spent = true
    Machines.refreshLook(anchor, state)
    eq(#anchor.anims, 0, "spent: none")
    eq(anchor.mod[Machines.Data.ANIM_KEY], nil, "nothing to step")
    cleanup()
end)

test("the lures' rings are declared to the API's attached animation stepping", function()
    local sets = {}
    PZExtAPI = { version = OA.API_VERSION, client = function() return "h" end,
        formulas = { set = function(handle, point, value) sets[point] = { handle = handle, value = value } end } }
    truthy(Machines.declareAnim())
    eq(sets["anim.stepKey"].value, Machines.Data.ANIM_KEY)
    eq(sets["anim.stepKey"].handle, "h")
    PZExtAPI.formulas.set = function() error("unknown point") end
    eq(Machines.declareAnim(), false, "an API without the point")
    PZExtAPI = nil
    eq(Machines.declareAnim(), false, "no API")
end)

test("a working lure is taken back with the hours it has left, and goes on from there", function()
    local square = worldSetup()
    local p = player()
    local sq = square(40, 40, 0)
    TEST.hours = 100
    local anchor = Machines.place("lure", sq, p, newItem("OperationAcorn.BaitTrap"), "S")
    TEST.hours = 110
    truthy(Machines.canTakeLure(anchor))
    local item = Machines.takeLure(anchor, p)
    truthy(item, "taken back")
    eq(#sq.objects, 0)
    eq(#p.inv.items, 1)
    near(item:getModData()[Machines.Data.LURE_LEFT_KEY], 14, 1e-6, "24 hours less the 10 it worked")
    -- put down again later: it goes on with its 14 hours, not a new day
    TEST.hours = 200
    local again = Machines.place("lure", sq, p, item, "S")
    near(OA.Machines.Logic.lureLeft(Machines.state(again), 200), 14, 1e-6)
    -- a spent lure is not taken back, only cleared
    Machines.state(again).spent = true
    eq(Machines.canTakeLure(again), false)
    eq(Machines.takeLure(again, p), nil)
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
    Machines.container(a, "tank"):AddItem(tank)
    truthy(Machines.container(a, "tank") ~= inC, "the fill box is a container of its own, on the anchor")
    fill(inC, "Base.Meat", 10, { classes = { Food = true }, rotten = true, weight = 5 })
    TEST.hours = 1
    Machines.tick()
    TEST.hours = 13.5
    Machines.tick()
    near(tank:getCurrentUsesFloat(), 0.5, 0.01, "half a tank")
    cleanup()
end)

test("the anchor keeps the load multiplier and the capacity flag for the API", function()
    local square = worldSetup()
    local p = player()
    square(11, 10, 0)
    local a = Machines.place("bulkShredder", square(10, 10, 0), p, newItem("OperationAcorn.BulkShredder"), "S")
    eq(a.mod[Data.LOAD_KEY], 0, "a machine that does not run draws nothing")
    local state = Machines.state(a)
    state.running = true
    Machines.refreshLook(a, state)
    eq(a.mod[Data.LOAD_KEY], 1.0, "old motor")
    state.parts.motor = { tier = "modern", cond = 100 }
    Machines.refreshLook(a, state)
    eq(a.mod[Data.LOAD_KEY], 1.5)
    near(Machines.load(a), 0.9)
    state.parts.motor = { tier = "normal", cond = 100 }
    Machines.syncLoad(a, state)
    eq(a.mod[Data.LOAD_KEY], 1.25)
    state.running = false
    Machines.refreshLook(a, state)
    eq(a.mod[Data.LOAD_KEY], 0)
    eq(a.mod[Data.CAPACITY_KEY], nil, "only the research storage lifts its cap")
    square(21, 20, 0)
    local store = Machines.place("researchStorage", square(20, 20, 0), p, newItem("OperationAcorn.TeamLocker"), "S")
    eq(store.mod[Data.CAPACITY_KEY], 400, "500: 100 raw (the game's cap) and 400 the API adds")
    local other = Machines.partsOf(Machines.state(store))[1].object
    eq(other.mod[Data.CAPACITY_KEY], 400, "the other square has its own locker")
    truthy(Machines.container(other, "store"), "a container on the other square")
    truthy(Machines.isEmpty(store))
    Machines.container(other, "store"):AddItem(newItem("Base.Hammer"))
    eq(Machines.canPickUp(store), nil, "something in the other square's locker: not taken up")
    eq(store.mod[Data.LOAD_KEY], nil, "no load for a storage")
    cleanup()
end)

test("the machines' generator load is declared to the API: the anchors' sprites and the load key", function()
    local sets = {}
    PZExtAPI = { version = OA.API_VERSION, client = function() return "h" end,
        formulas = { set = function(handle, point, value) sets[point] = { handle = handle, value = value } end } }
    truthy(Machines.declarePower())
    eq(sets["machine.loadKey"].value, Data.LOAD_KEY)
    eq(sets["machine.loadKey"].handle, "h")
    local base = sets["machine.baseConsumption"].value
    for _, dir in ipairs(OA.Sprites.DIRECTIONS) do
        eq(base[Machines.spriteName("woodSaw", dir, true)], 0.8)
        eq(base[Machines.spriteName("woodSaw", dir, false)], 0.8)
        eq(base[Machines.spriteName("bulkShredder", dir, true)], 0.6)
    end
    local woodSaw = Machines.tiles("woodSaw", "S", true)
    for _, tile in ipairs(woodSaw) do
        if tile.dx ~= 0 or tile.dy ~= 0 then eq(base[tile.sprite], nil, "only the anchor draws") end
    end
    eq(base[Machines.spriteName("researchStorage", "S", false)], nil, "no load, no entry")
    eq(base[Machines.spriteName("rainStorage", "S", false)], nil)
    -- every look is one object: each tile of a lit or running look is known by the same tile at rest
    local names = sets["machine.spriteName"].value
    for _, kind in ipairs({ "woodSaw", "propaneRefiner", "bulkShredder" }) do
        for _, dir in ipairs(OA.Sprites.DIRECTIONS) do
            local rest = {}
            for _, tile in ipairs(Machines.tiles(kind, dir, false)) do
                rest[tile.dx .. "," .. tile.dy] = tile.sprite
                eq(names[tile.sprite], nil, "a tile at rest keeps its own name")
            end
            for _, look in ipairs({ true, "ready" }) do
                for _, tile in ipairs(Machines.tiles(kind, dir, look)) do
                    local want = rest[tile.dx .. "," .. tile.dy]
                    if want ~= tile.sprite then eq(names[tile.sprite], want, kind .. " " .. dir .. " " .. tostring(look)) end
                end
            end
        end
    end
    eq(names[Machines.spriteName("researchStorage", "S", false)], nil, "no load, no name")
    local count = 0
    for _ in pairs(names) do count = count + 1 end
    truthy(count > 0 and count <= 256, "within what the API takes: " .. count)
    -- an API from before the names: the load still declared
    PZExtAPI.formulas.set = function(handle, point, value)
        if point == "machine.spriteName" then error("there is no point machine.spriteName") end
        sets[point] = { handle = handle, value = value }
    end
    truthy(Machines.declarePower())
    PZExtAPI = nil
    eq(Machines.declarePower(), false, "no API")
end)

test("a change of the load key makes the generators near count again", function()
    local square = worldSetup()
    local p = player()
    square(11, 10, 0)
    local updated = {}
    IsoGenerator = { updateGenerator = function(sq) updated[#updated + 1] = sq end }
    local a = Machines.place("bulkShredder", square(10, 10, 0), p, newItem("OperationAcorn.BulkShredder"), "S")
    local n = #updated
    local state = Machines.state(a)
    Machines.syncLoad(a, state)
    eq(#updated, n, "nothing changed")
    state.running = true
    Machines.syncLoad(a, state)
    eq(#updated, n + 1)
    eq(updated[#updated], square(10, 10, 0))
    IsoGenerator = nil
    cleanup()
end)

test("the window's progress walks the in-container once for what it holds, not at every ask", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    local inC = Machines.container(obj, "in")
    fill(inC, "Base.Hammer", 3, {})
    TEST.hours = 1
    Machines.update(obj)
    TEST.hours = 1 + 1 / 60
    local reads = 0
    local getItems = inC.getItems
    inC.getItems = function(self)
        local l = getItems(self)
        local get = l.get
        l.get = function(...) reads = reads + 1 return get(...) end
        return l
    end
    eq(#Machines.progress(obj), 1)
    local first = reads
    truthy(first > 0, "the first ask walks")
    for _ = 1, 10 do Machines.progress(obj) end
    eq(reads, first, "asked ten times a second by a watched window: no more walks")
    -- something came in: walked again
    fill(inC, "Base.Hammer", 1, {})
    Machines.progress(obj)
    truthy(reads > first, "the container changed")
    local second = reads
    -- ten game minutes on: walked again (an item can become fit to take with time)
    TEST.hours = TEST.hours + 1 / 6
    Machines.progress(obj)
    truthy(reads > second, "ten game minutes passed")
end)

test("an action's item is held by the object it was made with, and the inventory is searched only when it is not there", function()
    setup()
    ISBaseTimedAction = { derive = function() return {} end, new = function() return {} end }
    local real = require
    require = function(name)
        if string.find(name, "^TimedActions/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Machines/Actions")
    require = real
    if not ok then error(err, 0) end
    local searches = 0
    local inventory = newContainer("main", 100)
    function inventory:getItemWithIDRecursiv() searches = searches + 1 return nil end
    function inventory:getItemById() return nil end
    function inventory:getContainingItem() return nil end
    local character = { getInventory = function() return inventory end }
    local item = newItem("Base.Hammer")
    inventory:AddItem(item)
    local action = { character = character, item = item, itemId = item:getID() }
    eq(Machines.Actions.heldItem(action), item)
    eq(Machines.Actions.heldItem(action), item)
    eq(searches, 0, "in the inventory: no search")
    -- in a bag of the inventory: a walk up from its container
    local bag = newItem("Base.Bag", { bag = true })
    inventory:AddItem(bag)
    bag.inner.getContainingItem = function() return bag end
    local inner = newItem("Base.Plank")
    bag.inner:AddItem(inner)
    action = { character = character, item = inner, itemId = inner:getID() }
    eq(Machines.Actions.heldItem(action), inner)
    eq(searches, 0, "in a bag in the inventory: no search")
    -- gone: searched (once), and nothing kept
    inventory:Remove(item)
    eq(Machines.Actions.heldItem({ character = character, item = item, itemId = item:getID() }), nil)
    eq(searches, 1)
end)

test("a machine's furniture piece is known by its sprite, the lure's tile is not one", function()
    setup()
    eq(Machines.kindOfSprite(Machines.spriteName("cutter", "E", false)), "cutter")
    eq(Machines.kindOfSprite(Machines.spriteName("oilRefiner", "S", true)), "oilRefiner")
    eq(Machines.kindOfSprite(Machines.spriteName("lure", "S", true)), nil)
    eq(Machines.kindOfSprite("furniture_seating_01_0"), nil)
end)

test("a step that leaves an idle machine as it was sends nothing to the clients", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    local sent = 0
    obj.transmitModData = function() sent = sent + 1 end
    obj.transmitUpdatedSpriteToClients = function() end
    local wasServer = isServer
    isServer = function() return true end
    -- idle, nothing to take: the first step settles the state (reason noInput), the later ones change nothing
    TEST.hours = 1
    Machines.update(obj)
    local settled = sent
    TEST.hours = 1 + 1 / 6
    Machines.update(obj)
    TEST.hours = 1 + 2 / 6
    Machines.update(obj)
    eq(sent, settled, "two idle steps: nothing sent")
    -- no power: the same, after the step that says so
    sq.power = false
    TEST.hours = 2
    Machines.update(obj)
    local dark = sent
    truthy(dark > settled, "the change to noPower is sent")
    TEST.hours = 2 + 1 / 6
    Machines.update(obj)
    eq(sent, dark, "still no power: nothing sent")
    -- work comes: sent at the start and while it runs
    sq.power = true
    fill(Machines.container(obj, "in"), "Base.Hammer", 3, {})
    TEST.hours = 3
    Machines.update(obj)
    eq(state.idle, false, "started")
    truthy(sent > dark, "the start is sent")
    local running = sent
    TEST.hours = 3 + 1 / 600
    Machines.update(obj)
    truthy(sent > running, "a working machine sends its clock")
    isServer = wasServer
end)

test("an idle machine's step does not walk its in-container again while it holds the same", function()
    setup()
    local obj, state, sq = addMachine("bulkShredder", 10, 10)
    powered(sq)
    local inC = Machines.container(obj, "in")
    -- a bag with nothing a shredder takes: a walk finds no work, every time
    inC:AddItem(newItem("Base.CardboardBox", { bag = true }))
    local reads = 0
    local getItems = inC.getItems
    inC.getItems = function(self)
        local l = getItems(self)
        local get = l.get
        l.get = function(...) reads = reads + 1 return get(...) end
        return l
    end
    TEST.hours = 1
    Machines.update(obj)
    local first = reads
    truthy(first > 0, "the first step looks")
    for i = 1, 5 do
        TEST.hours = 1 + i / 6
        Machines.update(obj)
    end
    eq(reads, first, "the same contents: no more walks")
    fill(inC, "Base.Hammer", 1, {})
    TEST.hours = 3
    Machines.update(obj)
    eq(state.idle, false, "something came in: found")
end)
