-- The base machines on the game side: putting them down and taking them up, their containers and parts, and the
-- work they do. The numbers and the pure logic are in Data.lua and Logic.lua; this holds the game objects and
-- adapts them to that logic (a machine's items become jobs).
--
-- Where things are kept:
--   The world section "machines" (Store.world): { next, list = { [id] = { kind, x, y, z } }, byChunk = { [chunk key] =
--     { id ... } } }. It only says where machines are, so that the ten-minute step and the chunk load find them.
--   A machine covers one or more squares (DESIGN 12: 2x1 or 2x2 for the big ones), one object on each. The anchor, at
--     the smallest x and y, holds everything below, the containers and the rain storage's fluid; the other objects
--     carry only modData OA_Anchor = { id, x, y, z }. Machines.at(square) gives the anchor for any of the squares.
--   The anchor's object modData OA_Machine: { id, kind, dir, x, y, z (the anchor), owner (player id), parts = { [slot] = { tier, cond } },
--     on, last (world hours up to which it has worked), carry (work not yet a whole job), idle, running, reason,
--     buffer (a refiner's product not yet in a tank) ... }. It travels with the object when the chunk unloads, which
--     is what lets a place catch up the time it was away (DESIGN 12, performance rules).
--   Products go into the machine's own `out` container (a refiner's stay in the tank it fills, in `in`).
-- Nothing here runs per tick or per square: Machines.tick is the EveryTenMinutes handler, Machines.onChunk the
-- LoadChunk one.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Sprites"
require "OperationAcorn/Chunks"
require "OperationAcorn/Machines/Data"
require "OperationAcorn/Machines/Logic"
local OA = OperationAcorn
local Store, Sprites, Chunks, Sync = OA.Store, OA.Sprites, OA.Chunks, OA.Sync
local Machines = OA.Machines
local Data, Logic = Machines.Data, Machines.Logic

Machines.SAMPLE = "OperationAcorn.SampleBundle"

local function text(key, ...) return getText(key, ...) end

-- ---------------------------------------------------------------------------------------------------------------------
-- The registry

local function registry()
    local reg = Store.world("machines")
    reg.next = reg.next or 1
    reg.list = reg.list or {}
    reg.byChunk = reg.byChunk or {}
    return reg
end

local function chunkKeyOf(entry) return Chunks.key(entry.x, entry.y) end

local function register(state, x, y, z)
    local reg = registry()
    local entry = { kind = state.kind, x = x, y = y, z = z }
    reg.list[state.id] = entry
    local key = chunkKeyOf(entry)
    reg.byChunk[key] = reg.byChunk[key] or {}
    table.insert(reg.byChunk[key], state.id)
    return entry
end

local function unregister(id)
    local reg = registry()
    local entry = reg.list[id]
    if not entry then return end
    reg.list[id] = nil
    local key = chunkKeyOf(entry)
    local ids = reg.byChunk[key]
    if ids then
        for i = #ids, 1, -1 do
            if ids[i] == id then table.remove(ids, i) end
        end
        if #ids == 0 then reg.byChunk[key] = nil end
    end
end

-- Every registered machine: { [id] = { kind, x, y, z } } (do not change it).
function Machines.list()
    return registry().list
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Finding a machine

-- The state a machine object keeps, or nil if the object is not one of ours.
function Machines.state(object)
    if not object or not object:hasModData() then return nil end
    return object:getModData()[Data.KEY]
end

local function findOnSquare(square, id)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local state = Machines.state(object)
        if state and (id == nil or state.id == id) then return object, state end
    end
    return nil
end

-- The machine object of an id on its loaded square, or nil (not loaded, or gone).
function Machines.find(id)
    local entry = registry().list[id]
    if not entry then return nil end
    return findOnSquare(getCell():getGridSquare(entry.x, entry.y, entry.z), id)
end

-- A part of a multi-tile machine (a square of its footprint other than the anchor's) carries OA_Anchor = { id, x, y, z }
-- in its object modData and nothing else: the state, the containers and the fluid container are the anchor's.
function Machines.anchorMark(object)
    if not object or not object:hasModData() then return nil end
    return object:getModData()[Data.ANCHOR_KEY]
end

-- Whether an object is a machine's anchor or one of its other parts.
function Machines.isMachineObject(object)
    return Machines.state(object) ~= nil or Machines.anchorMark(object) ~= nil
end

-- The anchor of a machine object (the object itself when it is the anchor). nil when it is a part whose anchor's
-- square is not loaded; a part whose anchor's square is loaded but whose anchor is gone is an orphan and is taken away.
function Machines.anchorOf(object)
    if Machines.state(object) then return object, Machines.state(object) end
    local mark = Machines.anchorMark(object)
    if not mark then return nil end
    local square = getCell():getGridSquare(mark.x, mark.y, mark.z)
    if not square then return nil end
    local anchor, state = findOnSquare(square, mark.id)
    if not anchor then
        local own = object:getSquare()
        if own then own:transmitRemoveItemFromSquare(object) end
        return nil
    end
    return anchor, state
end

-- The machine on a square (its anchor, whichever of its squares this is), if any.
function Machines.at(square)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if Machines.state(object) then return object, Machines.state(object) end
        if Machines.anchorMark(object) then
            local anchor, state = Machines.anchorOf(object)
            if anchor then return anchor, state end
        end
    end
    return nil
end

-- Whether a machine object (anchor or part) stands on a square.
local function occupied(square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        if Machines.isMachineObject(objects:get(i)) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Names, looks, footprints

function Machines.name(kind)
    return text("IGUI_OA_Machine_Name_" .. kind)
end

local function itemFullType(kind)
    return Data.MODULE .. "." .. Data.KINDS[kind].item
end
Machines.itemFullType = itemFullType

-- The tiles of a machine facing dir, running or not: { { dx, dy, sprite } ... }, one for each square of its footprint,
-- dx and dy counted from the anchor (the footprint's smallest x and y; always the tile at 0, 0), as Sprites has them
-- (a lure is one tile, on or off; the rain storage 2x2, and it does not turn).
function Machines.tiles(kind, dir, running)
    if kind == "lure" then return { { dx = 0, dy = 0, sprite = Sprites.lure(running) } } end
    if kind == "rainStorage" then return Sprites.rainStorageTiles() end
    return Sprites.machineTiles(kind, dir or "S", running == true)
end

-- The size of a machine's footprint facing dir: w squares along x, h along y.
function Machines.footprint(kind, dir)
    local w, h = 1, 1
    for _, tile in ipairs(Machines.tiles(kind, dir, false)) do
        if tile.dx + 1 > w then w = tile.dx + 1 end
        if tile.dy + 1 > h then h = tile.dy + 1 end
    end
    return w, h
end

-- The sprite of the anchor (the tile at 0, 0): the one the rain storage's entity script is attached to.
function Machines.spriteName(kind, dir, running)
    for _, tile in ipairs(Machines.tiles(kind, dir, running)) do
        if tile.dx == 0 and tile.dy == 0 then return tile.sprite end
    end
    return nil
end

-- The other objects of a machine on loaded squares: { { dx, dy, object } ... }.
function Machines.partsOf(state)
    local parts = {}
    for _, tile in ipairs(Machines.tiles(state.kind, state.dir, false)) do
        if tile.dx ~= 0 or tile.dy ~= 0 then
            local square = getCell():getGridSquare(state.x + tile.dx, state.y + tile.dy, state.z)
            if square then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local mark = Machines.anchorMark(objects:get(i))
                    if mark and mark.id == state.id then
                        parts[#parts + 1] = { dx = tile.dx, dy = tile.dy, object = objects:get(i) }
                    end
                end
            end
        end
    end
    return parts
end

local function showSprite(object, want)
    if not want then return end
    local sprite = object:getSprite()
    if sprite and sprite:getName() == want then return end
    object:setSprite(want)
    if isServer() then object:transmitUpdatedSpriteToClients() end
end

-- Keeps the load multiplier the generator hook reads (the anchor's modData OA_Load) as the state says: the motor's
-- power multiplier while it runs, 0 otherwise. It is written only when it changes.
function Machines.syncLoad(object, state)
    local def = Data.KINDS[state.kind]
    if not def or not def.load then return end
    local multiplier = Logic.loadMultiplier(state.kind, state.parts, state.running == true)
    local data = object:getModData()
    if data[Data.LOAD_KEY] ~= multiplier then
        data[Data.LOAD_KEY] = multiplier
        if isServer() then object:transmitModData() end
        -- The generators near it count their load again (as the game's own Lua does when a powered thing changes).
        local square = object:getSquare()
        if square and IsoGenerator and IsoGenerator.updateGenerator then IsoGenerator.updateGenerator(square) end
    end
end

-- Tells the extension API what each machine draws from a generator: the base load (NUMBERS 11) on the anchor's
-- sprites of every facing and state, times the anchor's OA_Load (the motor's multiplier while it runs, else 0). The
-- other squares of a machine draw nothing. Once a game; returns true when the API took it.
function Machines.declarePower()
    local api = OA.api()
    local handle = OA.handle()
    if not (api and handle and type(api.formulas) == "table" and type(api.formulas.set) == "function") then return false end
    local base = {}
    for kind, def in pairs(Data.KINDS) do
        if def.load and Sprites.MACHINE_KINDS[kind] then
            for _, dir in ipairs(Sprites.DIRECTIONS) do
                for _, running in ipairs({ false, true }) do
                    local name = Machines.spriteName(kind, dir, running)
                    if name then base[name] = def.load end
                end
            end
        end
    end
    local ok1, err1 = pcall(api.formulas.set, handle, "machine.baseConsumption", base)
    local ok2, err2 = pcall(api.formulas.set, handle, "machine.loadKey", Data.LOAD_KEY)
    if not (ok1 and ok2) then OA.log("machine power not declared:", tostring(err1), tostring(err2)) end
    return ok1 and ok2
end

-- Shows the look the state calls for on every loaded square of the machine, where it is not already shown. Also
-- brings the load multiplier up to date (every change of running goes through here).
function Machines.refreshLook(object, state)
    Machines.syncLoad(object, state)
    local running = state.running == true
    if state.kind == "lure" then running = not state.spent end
    local parts
    for _, tile in ipairs(Machines.tiles(state.kind, state.dir, running)) do
        if tile.dx == 0 and tile.dy == 0 then
            showSprite(object, tile.sprite)
        elseif state.x then
            parts = parts or Machines.partsOf(state)
            for _, part in ipairs(parts) do
                if part.dx == tile.dx and part.dy == tile.dy then showSprite(part.object, tile.sprite) end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Power

-- Whether a square has electricity for a machine: a generator's, or the grid's inside a room (as the game's
-- appliances, ItemContainer.isSquarePowered). The generator's load itself is the extension API's to count
-- (Machines.declarePower); without the API a machine runs on a generator without burning more of its fuel.
function Machines.hasPower(square)
    if not square then return false end
    if square:haveElectricity() then return true end
    return square:hasGridPower() and square:getRoom() ~= nil
end

-- The generator load of a machine object now (NUMBERS 11); 0 when it is not running. The extension API's power
-- hook reads this per machine.
function Machines.load(object)
    local state = Machines.state(object)
    if not state or not state.running then return 0 end
    return Logic.load(state.kind, state.parts, true)
end

-- The same for a state table that is not in the world (a window, the tests).
function Machines.loadOf(state)
    return Logic.load(state.kind, state.parts, state.running == true)
end

-- Every machine with a load, as { object, kind, load } for the ones running on loaded squares: what the API's
-- generator hook would sum for a square's neighbours.
function Machines.loads()
    local found = {}
    for id, entry in pairs(registry().list) do
        local def = Data.KINDS[entry.kind]
        if def.load then
            local object = Machines.find(id)
            if object then
                local load = Machines.load(object)
                if load > 0 then found[#found + 1] = { object = object, kind = entry.kind, load = load } end
            end
        end
    end
    return found
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The one who owns the products

-- The player record the machine's work is booked to. Alone, whoever plays now (a new character after a death takes
-- the machines over); on a server, the one who put it down.
function Machines.record(state)
    if not isClient() and not isServer() then
        local player = getPlayer()
        if player then
            return Store.ensure(Store.idOf(player), player.getUsername and player:getUsername() or nil)
        end
    end
    return state.owner and Store.player(state.owner) or nil
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Containers

local function free(container)
    return container:getCapacity() - container:getCapacityWeight()
end

-- The machine's container of a role ("in", "out", "store"), or nil.
function Machines.container(object, which)
    local def = Data.CONTAINERS[which]
    return def and object:getContainerByType(def.type) or nil
end

-- Walks the items of a container, into the bags and boxes in it (their contents are the machine's work, the bag stays),
-- and collects up to `limit` for which accept(item) gives a value: { item, container, data }.
local function collect(container, accept, limit)
    local found = {}
    local function walk(c, depth)
        local items = c:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if instanceof(item, "InventoryContainer") then
                if depth < 3 and walk(item:getInventory(), depth + 1) then return true end
            else
                local data = accept(item)
                if data then
                    found[#found + 1] = { item = item, container = c, data = data }
                    if #found >= limit then return true end
                end
            end
        end
        return false
    end
    walk(container, 1)
    return found
end
Machines.collect = collect

local function takeOut(entry)
    entry.container:Remove(entry.item)
    sendRemoveItemFromContainer(entry.container, entry.item)
end

local function putIn(container, item)
    container:AddItem(item)
    sendAddItemToContainer(container, item)
end

local function putInType(container, fullType, count)
    for _ = 1, count do
        local item = instanceItem(fullType)
        if item then putIn(container, item) end
    end
end

-- Whether an item is still in the container it was collected from.
local function present(entry)
    return entry.container:contains(entry.item)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- What each kind takes in

local function itemInfo(item)
    if OA.Value and OA.Value.info then return OA.Value.info(item) end
    return nil
end
Machines.itemInfo = itemInfo

-- Whether an item can be shredded (P1's rule, OA.Shred.can on the item's info): the info, or nil.
function Machines.shreddable(item)
    if not (OA.Shred and OA.Shred.can) then return nil end
    local info = itemInfo(item)
    if not info then return nil end
    if (OA.Shred.can(info)) then return info end
    return nil
end

-- The clothing facts the cutter needs, as Logic.cutterPlan takes them.
local function clothingFacts(item)
    local location = item:getBodyLocation()
    location = location and tostring(location) or ""
    location = string.lower((string.gsub(location, "^.*:", "")))
    local buckle = false
    if ItemTag and ItemTag.BUCKLE then buckle = item:hasTag(ItemTag.BUCKLE) == true end
    return {
        fullType = item:getType(), fabric = item:getFabricType(), location = location,
        covered = item:getNbrOfCoveredParts(), holes = item:getHolesNumber(), patches = item:getPatchesNumber(),
        dirt = item:getDirtiness(), blood = item:getBloodLevel(), buckle = buckle,
    }
end

-- The plan the cutter has for a piece of clothing, or nil.
function Machines.cutterPlan(item)
    if not instanceof(item, "Clothing") or item:isEquipped() then return nil end
    local plan = Logic.cutterPlan(clothingFacts(item))
    if not plan then return nil end
    local defs = ClothingRecipesDefinitions and ClothingRecipesDefinitions["FabricType"]
    local fabric = defs and defs[plan.material]
    if not fabric then return nil end
    plan.clean, plan.dirty = fabric.material, fabric.materialDirty
    return plan
end

-- Rotten food for the propane refiner: its weight, or nil.
function Machines.rottenFood(item)
    if not instanceof(item, "Food") or not item:isRotten() then return nil end
    return math.max(item:getActualWeight(), 0.01)
end

-- The oil an item carries for the oil refiner (litres), or nil.
function Machines.oilOf(item)
    local fullType = item:getFullType()
    if not Data.OILS[fullType] then return nil end
    local left = 1
    if Data.OIL_FOOD[fullType] and instanceof(item, "Food") then
        local base = item:getBaseHunger()
        if base and base ~= 0 then left = item:getHungChange() / base end
    end
    return Logic.oilLitres(fullType, left)
end

local function isPropaneTank(item)
    return item:getFullType() == "Base.PropaneTank"
end

-- A propane tank with room, or a petrol can that is empty or holds only petrol.
local function tankRoom(item)
    return isPropaneTank(item) and item:getCurrentUsesFloat() < 0.999
end

local function canRoom(item)
    if item:getFullType() ~= "Base.PetrolCan" then return false end
    local fluid = item:getFluidContainer()
    if not fluid then return false end
    if fluid:getFreeCapacity() < 0.001 then return false end
    return fluid:isEmpty() or fluid:isPureFluid(Fluid.Petrol)
end

-- Whether a machine kind's `in` container takes an item (the container's accept function, and the menus).
function Machines.accepts(kind, item)
    if instanceof(item, "InventoryContainer") then return true end
    if kind == "bulkShredder" then return Machines.shreddable(item) ~= nil end
    if kind == "cutter" then return Machines.cutterPlan(item) ~= nil end
    if kind == "woodSaw" then return item:getFullType() == "Base.Log" end
    if kind == "propaneRefiner" then return Machines.rottenFood(item) ~= nil or isPropaneTank(item) end
    if kind == "oilRefiner" then return Machines.oilOf(item) ~= nil or item:getFullType() == "Base.PetrolCan" end
    return false
end

-- The container's accept function, as the game calls it: (container, item) -> boolean. It is set by name:
-- ItemContainer.setAcceptItemFunction("OperationAcorn.Machines.acceptInput").
function Machines.acceptInput(container, item)
    local object = container:getParent()
    local state = object and Machines.state(object)
    if not state then return true end
    return Machines.accepts(state.kind, item)
end

-- The output container takes nothing from a player (the machine puts products in directly).
function Machines.acceptNothing()
    return false
end

local function applyAccept(object, state)
    local def = Data.KINDS[state.kind]
    for _, which in ipairs(def.containers) do
        local container = Machines.container(object, which)
        if container then
            if which == "in" then container:setAcceptItemFunction("OperationAcorn.Machines.acceptInput")
            elseif which == "out" then container:setAcceptItemFunction("OperationAcorn.Machines.acceptNothing") end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Shredding (P1's yield, P3's bonus)

-- The extras the shred yield takes (P1: keen = added bundles, blade = the blade's multiplier).
local function shredExtras(record, fx)
    local keen = 0
    if OA.Upgrades then
        if OA.Upgrades.bundleBonus then keen = OA.Upgrades.bundleBonus(record) or 0
        elseif OA.Upgrades.rank then keen = OA.Upgrades.rank(record, "keen") or 0 end
    end
    return { keen = keen, blade = fx and fx.shred or 1 }
end

-- Shreds one item for a record: books it (the repeat count, the first-shred bonus) and returns how many sample
-- bundles it gives (rolled from the expected count, times the wear multiplier). The item is not taken here.
function Machines.shredYield(record, info, fx)
    local expected = OA.Shred.yield(info, record, shredExtras(record, fx))
    expected = expected * (fx and fx.yield or 1)
    local count = OA.Shred.roll(expected)
    OA.Shred.commit(record, info, 1)
    return count
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The jobs of each kind, for Logic.advance

local function newQueue(container, accept, limit)
    local queue = { list = collect(container, accept, limit), i = 1 }
    function queue.peek()
        while queue.list[queue.i] and not present(queue.list[queue.i]) do queue.i = queue.i + 1 end
        return queue.list[queue.i]
    end
    function queue.pop() queue.i = queue.i + 1 end
    return queue
end

-- Moves what a refiner has made (state.buffer) into the tanks in its container: propane into tanks with room (as
-- the part of a full tank), petrol into cans (litres). Returns the amount left.
local function deposit(inC, state, kind)
    local buffer = state.buffer or 0
    if buffer <= 0 then return 0 end
    local tanks = collect(inC, function(item)
        if kind == "propaneRefiner" then return tankRoom(item) and true or nil end
        return canRoom(item) and true or nil
    end, 20)
    for _, entry in ipairs(tanks) do
        if buffer <= 0 then break end
        local item = entry.item
        if kind == "propaneRefiner" then
            local room = 1 - item:getCurrentUsesFloat()
            local put = math.min(room, buffer)
            item:setUsedDelta(item:getCurrentUsesFloat() + put)
            buffer = buffer - put
        else
            local fluid = item:getFluidContainer()
            local put = math.min(fluid:getFreeCapacity(), buffer)
            if put > 0 then
                fluid:addFluid(FluidType.Petrol, put)
                item:syncItemFields()
                buffer = buffer - put
            end
        end
    end
    state.buffer = buffer
    return buffer
end

-- Whether the refiner has somewhere to put its product: a tank with room, or buffer room for one tank's worth.
local function hasSink(inC, state, kind)
    if (state.buffer or 0) < (kind == "propaneRefiner" and 1 or 10) - 1e-6 then return true end
    local tanks = collect(inC, function(item)
        if kind == "propaneRefiner" then return tankRoom(item) and true or nil end
        return canRoom(item) and true or nil
    end, 1)
    return #tanks > 0
end

-- The io Logic.advance works through for a machine object. Returns nil when its containers are missing.
local function makeIO(object, state, record)
    local kind = state.kind
    local inC = Machines.container(object, "in")
    local outC = Machines.container(object, "out")
    if not inC then return nil end
    local io = {}
    local queue

    if kind == "bulkShredder" then
        local function reset() queue = newQueue(inC, Machines.shreddable, Data.BATCH + 5) end
        reset()
        io.reset = reset
        io.next = function(fx)
            if not record then return nil, "noOwner" end
            local entry = queue.peek()
            if not entry then return nil, "noInput" end
            if not outC or free(outC) < 1 then return nil, "outputFull" end
            return { cost = math.max(entry.data.weight or 0, 0.05), entry = entry }
        end
        io.finish = function(job, fx)
            local count = Machines.shredYield(record, job.entry.data, fx)
            takeOut(job.entry)
            queue.pop()
            putInType(outC, Machines.SAMPLE, count)
        end

    elseif kind == "cutter" then
        local function reset() queue = newQueue(inC, Machines.cutterPlan, Data.BATCH + 5) end
        reset()
        io.reset = reset
        io.next = function(fx)
            local entry = queue.peek()
            if not entry then return nil, "noInput" end
            if not outC or free(outC) < 1 then return nil, "outputFull" end
            return { cost = 1, entry = entry }
        end
        io.finish = function(job, fx)
            local plan = job.entry.data
            local count, dirty = Logic.cutterPieces(plan, fx)
            takeOut(job.entry)
            queue.pop()
            putInType(outC, plan.clean, count - dirty)
            putInType(outC, plan.dirty, dirty)
            if plan.buckle then putInType(outC, "Base.Buckle", 1) end
        end

    elseif kind == "woodSaw" then
        local function reset()
            queue = newQueue(inC, function(item) return item:getFullType() == "Base.Log" and true or nil end, Data.BATCH + 5)
        end
        reset()
        io.reset = reset
        io.next = function(fx)
            local entry = queue.peek()
            if not entry then return nil, "noInput" end
            if not outC or free(outC) < 3 * (fx.planks + 1) then return nil, "outputFull" end
            return { cost = 1, entry = entry }
        end
        io.finish = function(job, fx)
            local count = Logic.sawPlanks(fx)
            takeOut(job.entry)
            queue.pop()
            putInType(outC, "Base.Plank", count)
        end

    elseif kind == "propaneRefiner" or kind == "oilRefiner" then
        local propane = kind == "propaneRefiner"
        local function reset()
            queue = newQueue(inC, propane and Machines.rottenFood or Machines.oilOf, Data.BATCH + 5)
        end
        reset()
        io.reset = reset
        io.next = function(fx)
            deposit(inC, state, kind)
            local entry = queue.peek()
            if not entry then return nil, "noInput" end
            if not hasSink(inC, state, kind) then return nil, "noTank" end
            return { cost = entry.data, entry = entry }
        end
        io.finish = function(job, fx)
            local gain
            if propane then gain = Logic.propaneGain(job.entry.data, fx)
            else gain = Logic.petrolGain(job.entry.data, fx) end
            takeOut(job.entry)
            queue.pop()
            state.buffer = (state.buffer or 0) + gain
            deposit(inC, state, kind)
        end
    else
        return nil
    end
    return io
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Working

local function notePart(state, slot, what)
    if not state.owner then return end
    local key = what == "broken" and "IGUI_OA_Machine_PartBroken" or "IGUI_OA_Machine_PartWorn"
    Sync.notice(state.owner, key, { Machines.name(state.kind), text("IGUI_OA_Machine_Slot_" .. slot) })
end

local function sound(object, radius)
    if radius <= 0 then return end
    addSound(object, math.floor(object:getX()), math.floor(object:getY()), math.floor(object:getZ()), radius, radius)
end

-- Works on one machine from where it left off to now.
--   opts.catchUp: a chunk load: only a machine that was running and has power does anything, up to a few batches,
--     and it makes no sound.
-- Returns the Logic.advance result of the last batch (or nil when there was nothing to do).
function Machines.update(object, opts)
    local state = Machines.state(object)
    if not state then return nil end
    local kind = state.kind
    if kind == "lure" then return Machines.updateLure(object, state, opts) end
    if kind == "rainStorage" then return Machines.updateRain(object, state) end
    if not Data.processes(kind) then return nil end

    local square = object:getSquare()
    if not square then return nil end
    local catchUp = opts and opts.catchUp
    local now = OA.hours()
    local powered = Machines.hasPower(square)
    if catchUp and (state.idle ~= false or state.on == false or not powered) then return nil end

    if state.on == false or not powered then
        -- Without power or switched off it does not work, and the time does not count: its clock starts again.
        state.idle, state.running, state.last, state.carry = true, false, now, 0
        state.reason = state.on == false and "off" or "noPower"
        Machines.refreshLook(object, state)
        if isServer() then object:transmitModData() end
        return nil
    end

    local record = Machines.record(state)
    local io = makeIO(object, state, record)
    if not io then return nil end
    local result
    local worked = 0
    local worn
    for batch = 1, catchUp and Data.CATCHUP_BATCHES or 1 do
        result = Logic.advance(state, now, io, Data.BATCH)
        worked = worked + result.hours
        if result.worn then worn = Logic.merge(worn, result.worn) end
        if not result.debt then break end
        io.reset()
    end
    state.running = state.idle ~= true
    state.reason = result.reason
    Machines.refreshLook(object, state)
    if worked > 0 and not catchUp then
        sound(object, Logic.noiseRadius(kind, Logic.effects(kind, state.parts)))
    end
    if worn then
        for slot, what in pairs(worn) do notePart(state, slot, what) end
    end
    if isServer() then object:transmitModData() end
    return result
end

-- The lure: a sound every 15 minutes for 24 hours of world time, then a spent shell. Only a loaded lure does
-- anything: the time it was unloaded passes without sounds (and a lure that loads past its end is only a shell).
function Machines.updateLure(object, state, opts)
    if state.spent then return nil end
    local catchUp = opts and opts.catchUp
    local result = Logic.lureStep(state, OA.hours())
    if result.expired then
        state.running = false
        Machines.refreshLook(object, state)
        if isServer() then object:transmitModData() end
    elseif result.sound and not catchUp then
        sound(object, Data.LURE.radius)
    end
    return result
end

-- The look of a rain storage's water, 0 (dry) to Sprites.RAIN_LEVELS - 1 (full), from the share of its capacity. The
-- art has a dry floor, a quarter, a half and a full tank; a share shows the nearest of them, except that any water at
-- all shows (dry only under 2 %).
function Machines.rainLevel(amount, capacity)
    if not capacity or capacity <= 0 then return 0 end
    local share = (amount or 0) / capacity
    if share < 0.02 then return 0 end
    if share < 0.375 then return 1 end
    if share < 0.75 then return 2 end
    return 3
end

local function showOverlay(object, want)
    local current = object:getOverlaySprite()
    if (current and current:getName() or nil) == want then return end
    object:setOverlaySprite(want, isServer())
end

-- A rain storage shows its water as an overlay on each of its squares (its own sprite is the one its entity's sprite
-- config names, and must stay so). The overlays change only when the level passes from one look to another; a
-- machine with a square not loaded keeps its old level and tries again on the next step.
function Machines.updateRain(object, state)
    if not object.getFluidAmount then return nil end
    local level = Machines.rainLevel(object:getFluidAmount(), object:getFluidCapacity())
    if state.level == level then return nil end
    local want = {}
    for _, tile in ipairs(Sprites.rainOverlayTiles(level)) do want[tile.dx .. "," .. tile.dy] = tile.sprite end
    showOverlay(object, want["0,0"])
    local parts = Machines.partsOf(state)
    for _, part in ipairs(parts) do showOverlay(part.object, want[part.dx .. "," .. part.dy]) end
    if #parts + 1 < #Machines.tiles("rainStorage") then return nil end
    state.level = level
    if isServer() then object:transmitModData() end
    return nil
end

-- The EveryTenMinutes handler: works every machine whose square is loaded. A registered machine whose square is
-- loaded but whose object is gone (destroyed) is dropped from the registry after two such steps.
function Machines.tick()
    local reg = registry()
    if next(reg.list) == nil then return end
    local ids = {}
    for id in pairs(reg.list) do ids[#ids + 1] = id end
    local cell = getCell()
    for _, id in ipairs(ids) do
        local entry = reg.list[id]
        local square = cell:getGridSquare(entry.x, entry.y, entry.z)
        if square then
            local object = findOnSquare(square, id)
            if object then
                entry.missed = nil
                local ok, err = pcall(Machines.update, object)
                if not ok then OA.log("machine", id, "failed:", tostring(err)) end
            else
                entry.missed = (entry.missed or 0) + 1
                if entry.missed >= 2 then unregister(id) end
            end
        end
    end
end

-- The LoadChunk handler: the machines on the chunk catch up the time they were away.
function Machines.onChunk(chunk)
    local reg = Store.world("machines")
    if not reg.byChunk or next(reg.byChunk) == nil then return end
    local first = chunk:getGridSquare(0, 0, 0)
    if not first then return end
    local ids = reg.byChunk[Chunks.key(first:getX(), first:getY())]
    if not ids then return end
    local copy = {}
    for i, id in ipairs(ids) do copy[i] = id end
    for _, id in ipairs(copy) do
        local entry = reg.list[id]
        if entry then
            local square = chunk:getGridSquare(entry.x - Chunks.SIZE * math.floor(entry.x / Chunks.SIZE),
                entry.y - Chunks.SIZE * math.floor(entry.y / Chunks.SIZE), entry.z)
            local object = findOnSquare(square, id)
            if object then
                local state = Machines.state(object)
                Machines.ensureSpriteProperties()
                applyAccept(object, state)
                local ok, err = pcall(Machines.update, object, { catchUp = true })
                if not ok then OA.log("machine", id, "catch-up failed:", tostring(err)) end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The status (for windows and tooltips)

-- What a machine is doing now: { kind, name, on, running, reason, powered, speed, load, noise, stopped, missing,
-- broken, worn, parts = { [slot] = { tier, cond } } }.
function Machines.status(object)
    local state = Machines.state(object)
    if not state then return nil end
    local fx = Logic.effects(state.kind, state.parts)
    local def = Data.KINDS[state.kind]
    local status = {
        kind = state.kind, name = Machines.name(state.kind), on = state.on ~= false, running = state.running == true,
        reason = state.reason, powered = def.power and Machines.hasPower(object:getSquare()) or nil,
        speed = fx.speed, load = Logic.load(state.kind, state.parts, true), noise = Logic.noiseRadius(state.kind, fx),
        stopped = fx.stopped, missing = fx.missing, broken = fx.broken, worn = fx.worn, parts = state.parts,
        rate = def.rate and def.rate * fx.speed or nil,
    }
    if state.kind == "lure" then
        status.left = state.spent and 0 or Logic.lureLeft(state, OA.hours())
        status.spent = state.spent == true
    end
    if state.kind == "rainStorage" and object.getFluidAmount then
        status.water, status.capacity = object:getFluidAmount(), object:getFluidCapacity()
    end
    return status
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Putting down and taking up

-- Rain storage needs the rain flag on its sprite for the plumbing to treat it as a water source (Building Utilities
-- asks for the IsWaterCollector tile property). The tile definition has it; this sets it when a build lacks it. Only
-- the anchor's tile has it: the fluid container is the anchor's alone.
local propertiesDone = false
function Machines.ensureSpriteProperties()
    if propertiesDone then return end
    propertiesDone = true
    local ok = pcall(function()
        local sprite = getSprite(Machines.spriteName("rainStorage", "S", false))
        local properties = sprite and sprite:getProperties()
        if properties and not properties:has("IsWaterCollector") then
            properties:set("IsWaterCollector", "")
            properties:CreateKeySet()
        end
    end)
    if not ok then OA.log("could not set the rain storage sprite property") end
end

-- Why a square cannot take a tile of a machine: nil when it can, else the reason.
local function squareProblem(kind, square)
    if not square then return "noSquare" end
    if not square:TreatAsSolidFloor() then return "noFloor" end
    if square:isSolid() or square:isSolidTrans() or square:HasStairs() or square:HasTree() then return "blocked" end
    if not square:isFree(false) then return "blocked" end
    if square:isVehicleIntersecting() then return "blocked" end
    local properties = square:getProperties()
    if properties and properties:has(IsoFlagType.water) then return "water" end
    if occupied(square) then return "taken" end
    if kind == "rainStorage" and not square:isOutside() then return "notOutside" end
    return nil
end

-- The squares a machine of a kind facing dir would stand on with its anchor at a square:
-- { { dx, dy, square, sprite } ... }. Returns nil and a reason when one is missing.
function Machines.footprintSquares(kind, square, dir)
    local found = {}
    local cell = getCell()
    for _, tile in ipairs(Machines.tiles(kind, dir, kind == "lure")) do
        local target = square
        if tile.dx ~= 0 or tile.dy ~= 0 then
            target = cell:getGridSquare(square:getX() + tile.dx, square:getY() + tile.dy, square:getZ())
        end
        if not target then return nil, "noSquare" end
        found[#found + 1] = { dx = tile.dx, dy = tile.dy, square = target, sprite = tile.sprite }
    end
    return found
end

-- Whether a machine of a kind, facing dir, can stand with its anchor on a square (every square of its footprint on
-- the same floor, free and not another machine's): true, or nil and a reason (IGUI_OA_Machine_Reason_<reason>).
function Machines.canPlace(kind, square, dir)
    if not square then return nil, "noSquare" end
    local squares, reason = Machines.footprintSquares(kind, square, dir or "S")
    if not squares then return nil, reason end
    for _, entry in ipairs(squares) do
        local problem = squareProblem(kind, entry.square)
        if problem then return nil, problem end
    end
    return true
end

local function copyParts(parts)
    local copy = {}
    for slot, part in pairs(parts or {}) do copy[slot] = { tier = part.tier, cond = part.cond } end
    return copy
end

-- The facing a machine put down by a character at a square takes: its front toward the character.
function Machines.facing(square, character)
    local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
    if math.abs(dx) > math.abs(dy) then return dx > 0 and "E" or "W" end
    return dy > 0 and "S" or "N"
end

local function setupContainers(object, square, kind)
    local def = Data.KINDS[kind]
    for i, which in ipairs(def.containers) do
        local spec = Data.CONTAINERS[which]
        local container
        if i == 1 then
            container = object:getContainer()
            if not container then
                object:setIsContainer(true)
                container = object:getContainer()
            end
            container:setType(spec.type)
        else
            container = ItemContainer.new(spec.type, square, object)
            object:addSecondaryContainer(container)
        end
        container:setCapacity(spec.capacity)
        container:setExplored(true)
    end
end

-- One IsoThumpable of a machine on a square, with the sprite of its tile.
local function newObject(kind, square, sprite)
    local object = IsoThumpable.new(getCell(), square, sprite, false)
    local passable = kind == "lure"
    object:setCanPassThrough(passable)
    object:setBlockAllTheSquare(not passable)
    object:setCanBarricade(false)
    object:setIsThumpable(false)
    object:setIsDismantable(false)
    object:setIsHoppable(false)
    object:setMaxHealth(500)
    object:setHealth(500)
    object:setBreakSound("BreakObject")
    return object
end

-- Puts a machine down: one object on each square of its footprint (the anchor, at the smallest x and y, holds the
-- state, the containers and the rain storage's fluid; the others point to it), its state (the parts of a carried item
-- if it has them), the registry (the anchor only). `character` is the one who puts it down (owner), `dir` the facing
-- (the character's side of the square when not given). Returns the anchor object. The item is not removed here.
function Machines.place(kind, square, character, item, dir)
    Machines.ensureSpriteProperties()
    dir = dir or Machines.facing(square, character)
    local squares = Machines.footprintSquares(kind, square, dir)
    if not squares then return nil end
    local reg = registry()
    local id = "m" .. tostring(reg.next)
    reg.next = reg.next + 1

    local ax, ay, az = square:getX(), square:getY(), square:getZ()
    local state = { id = id, kind = kind, dir = dir, owner = Store.idOf(character), on = true, last = OA.hours(),
        carry = 0, idle = true, running = false, buffer = 0, x = ax, y = ay, z = az }
    local carried = item and item:getModData()[Data.KEY]
    state.parts = carried and carried.parts and copyParts(carried.parts) or Logic.newParts(kind)
    if kind == "lure" then
        state.start, state.slot, state.spent = OA.hours(), -1, false
        state.running = true
    end

    local anchor
    for _, entry in ipairs(squares) do
        local object = newObject(kind, entry.square, entry.sprite)
        if entry.dx == 0 and entry.dy == 0 then
            anchor = object
            object:getModData()[Data.KEY] = state
            if kind == "rainStorage" then
                local script = getScriptManager():getGameEntityScript(Data.RAIN_ENTITY)
                if script then GameEntityFactory.CreateIsoObjectEntity(object, script, true)
                else OA.log("no entity script", Data.RAIN_ENTITY) end
            end
            setupContainers(object, entry.square, kind)
            applyAccept(object, state)
            if kind == "researchStorage" then object:getModData()[Data.CAPACITY_KEY] = 0 end
            Machines.syncLoad(object, state)
        else
            object:getModData()[Data.ANCHOR_KEY] = { id = id, x = ax, y = ay, z = az }
        end
        entry.square:AddSpecialObject(object)
        object:transmitCompleteItemToClients()
    end
    for _, entry in ipairs(squares) do entry.square:RecalcAllWithNeighbours(true) end
    register(state, ax, ay, az)
    OA.log("placed", kind, id, "at", ax, ay, az, dir, #squares, "squares")
    return anchor
end

-- Whether every container of a machine is empty (it can be picked up).
function Machines.isEmpty(object)
    local state = Machines.state(object)
    for _, which in ipairs(Data.KINDS[state.kind].containers) do
        local container = Machines.container(object, which)
        if container and not container:getItems():isEmpty() then return false end
    end
    if state.kind == "rainStorage" and object.getFluidAmount and object:getFluidAmount() > 0.01 then return false end
    return true
end

-- Whether a machine can be picked up: true, or nil and a reason. `object` is the anchor (Machines.at gives it).
function Machines.canPickUp(object)
    local state = Machines.state(object)
    if not state then return nil, "notMachine" end
    if state.kind == "lure" and not state.spent then return nil, "armed" end
    if not Machines.isEmpty(object) then return nil, "notEmpty" end
    return true
end

-- Takes a machine up: gives the character the item (with the parts and their condition in its modData), removes
-- every part, the anchor and the registry entry. A spent lure gives nothing. Returns the item or nil.
function Machines.pickUp(object, character)
    local state = Machines.state(object)
    if not state or not Machines.canPickUp(object) then return nil end
    local item
    if state.kind ~= "lure" then
        item = instanceItem(itemFullType(state.kind))
        if item then
            item:getModData()[Data.KEY] = { kind = state.kind, parts = copyParts(state.parts) }
            local inventory = character:getInventory()
            inventory:AddItem(item)
            sendAddItemToContainer(inventory, item)
        end
    end
    Machines.remove(object)
    return item
end

local function removeObject(object)
    local square = object:getSquare()
    if square then square:transmitRemoveItemFromSquare(object) end
end

-- Removes a machine: all its objects on loaded squares and its registry entry (nothing given). A part on a square
-- that is not loaded is an orphan, taken away when its anchor is looked for and not found.
function Machines.remove(object)
    local state = Machines.state(object)
    if state then
        unregister(state.id)
        if state.x then
            for _, part in ipairs(Machines.partsOf(state)) do removeObject(part.object) end
        end
    end
    removeObject(object)
end

-- Drops what a machine holds on the ground by its anchor (a machine broken up).
local function spill(object)
    local state = Machines.state(object)
    local square = object:getSquare()
    if not state or not square then return end
    for _, which in ipairs(Data.KINDS[state.kind].containers) do
        local container = Machines.container(object, which)
        if container then
            local items = container:getItems()
            for i = items:size() - 1, 0, -1 do
                local held = items:get(i)
                container:Remove(held)
                square:AddWorldInventoryItem(held, 0.5, 0.5, 0)
            end
        end
    end
end

-- A machine object was destroyed by other means (the game's OnDestroyIsoThumpable): the whole machine goes. The
-- destroyed object may be the anchor or any part; the rest of the machine is taken away, what the anchor held is
-- dropped, and the registry entry is forgotten.
function Machines.forget(destroyed)
    local anchor, state = Machines.anchorOf(destroyed)
    if not state then return end
    unregister(state.id)
    if anchor ~= destroyed then
        spill(anchor)
        removeObject(anchor)
    end
    if state.x then
        for _, part in ipairs(Machines.partsOf(state)) do
            if part.object ~= destroyed then removeObject(part.object) end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Parts

-- The part an inventory item is, as { part, tier }, or nil.
function Machines.partOf(item)
    local info = Data.PART_ITEMS[item:getType()]
    if info and item:getFullType() == Data.MODULE .. "." .. item:getType() then return info end
    return nil
end

-- The condition of a part item, 0..100.
local function itemCondition(item)
    local max = item:getConditionMax()
    if not max or max <= 0 then return Data.CONDITION_MAX end
    return item:getCondition() * Data.CONDITION_MAX / max
end

-- Whether a part item fits a slot of a machine: true, or nil and a reason.
function Machines.canInstall(object, slot, item)
    local state = Machines.state(object)
    if not state then return nil, "notMachine" end
    local info = Machines.partOf(item)
    if not info then return nil, "notPart" end
    if not Logic.fits(state.kind, slot, info.part, info.tier) then return nil, "wrongPart" end
    return true
end

-- Gives a part back as an item (condition set) into the character's inventory.
local function giveBack(character, kind, slot, part)
    local name = Data.partKind(kind, slot)
    local fullType = Data.MODULE .. "." .. Data.partItem(name, part.tier)
    local item = instanceItem(fullType)
    if not item then return nil end
    item:setConditionNoSound(math.max(0, math.min(item:getConditionMax(), OA.round(part.cond))))
    local inventory = character:getInventory()
    inventory:AddItem(item)
    sendAddItemToContainer(inventory, item)
    return item
end

-- Puts a part into a slot (the one in it comes out to the character). The item is taken out of its container.
function Machines.installPart(object, slot, item, character)
    local state = Machines.state(object)
    if not Machines.canInstall(object, slot, item) then return false end
    local info = Machines.partOf(item)
    local old = state.parts[slot]
    if character.removeFromHands then character:removeFromHands(item) end
    local container = item:getContainer()
    if container then
        container:Remove(item)
        sendRemoveItemFromContainer(container, item)
    end
    if old then giveBack(character, state.kind, slot, old) end
    state.parts[slot] = { tier = info.tier, cond = itemCondition(item) }
    Machines.syncLoad(object, state)
    -- A fresh start: the machine looks at its work again from now.
    state.idle, state.last, state.carry = true, OA.hours(), 0
    if isServer() then object:transmitModData() end
    return true
end

-- Takes the part out of a slot into the character's inventory.
function Machines.removePart(object, slot, character)
    local state = Machines.state(object)
    local part = state and state.parts[slot]
    if not part then return false end
    state.parts[slot] = nil
    giveBack(character, state.kind, slot, part)
    state.idle, state.running, state.last, state.carry = true, false, OA.hours(), 0
    Machines.refreshLook(object, state)
    if isServer() then object:transmitModData() end
    return true
end

-- Switches a machine on or off.
function Machines.setOn(object, on)
    local state = Machines.state(object)
    if not state or not Data.processes(state.kind) then return end
    state.on = on and true or false
    state.idle, state.last, state.carry = true, OA.hours(), 0
    if not state.on then
        state.running = false
        Machines.refreshLook(object, state)
    end
    if isServer() then object:transmitModData() end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The hand bench

-- What a character can shred by hand: their inventory's shreddable items (not equipped, not favorites, not bags).
-- Returns a list of { item, info }.
function Machines.benchCandidates(character, limit)
    local inventory = character:getInventory()
    return collect(inventory, function(item)
        if item:isEquipped() or item:isFavorite() then return nil end
        return Machines.shreddable(item)
    end, limit or 200)
end

-- Shreds the given items by hand for a character: every one still in their inventory is taken, and the sample
-- bundles go into it. Returns the number of bundles. `record` is the character's.
function Machines.shredByHand(character, record, items)
    local inventory = character:getInventory()
    local total = 0
    for _, item in ipairs(items) do
        if inventory:containsRecursive(item) and not item:isEquipped() then
            local info = Machines.shreddable(item)
            if info then
                local count = Machines.shredYield(record, info, nil)
                local container = item:getContainer()
                container:Remove(item)
                sendRemoveItemFromContainer(container, item)
                for _ = 1, count do
                    local bundle = instanceItem(Machines.SAMPLE)
                    if bundle then
                        inventory:AddItem(bundle)
                        sendAddItemToContainer(inventory, bundle)
                    end
                end
                total = total + count
            end
        end
    end
    return total
end

-- The game minutes shredding these items takes by hand (the bench's rule, per item).
function Machines.benchMinutesFor(entries)
    local minutes = 0
    for _, entry in ipairs(entries) do
        minutes = minutes + Logic.benchMinutes(math.max(entry.data.weight or 0, 0))
    end
    return minutes
end

return Machines
