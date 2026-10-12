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
--     on, last (world hours up to which it has worked), lanes (the work done on each job in hand), idle, running, reason,
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
require "OperationAcorn/Lights"
require "OperationAcorn/Machines/Data"
require "OperationAcorn/Machines/Logic"
local OA = OperationAcorn
local Store, Sprites, Chunks, Sync = OA.Store, OA.Sprites, OA.Chunks, OA.Sync
local Machines = OA.Machines
local Data, Logic = Machines.Data, Machines.Logic

Machines.SAMPLE = "OperationAcorn.SampleBundle"
Machines.SELECTED = "OperationAcorn.SelectedSample"

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
function Machines.tiles(kind, dir, look)
    if kind == "lure" then return { { dx = 0, dy = 0, sprite = Sprites.lure(look) } } end
    if kind == "rainStorage" then return Sprites.rainStorageTiles() end
    return Sprites.machineTiles(kind, dir or "S", look)
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

-- The loaded square of a machine's footprint nearest to a character: where they walk up to it. The anchor is the
-- footprint's back corner on screen, and walking up to it would take them round the machine. Asked when the player
-- picks something to do, not per tick.
function Machines.nearSquare(object, character)
    local anchor = object:getSquare()
    local state = Machines.state(object)
    if not anchor or not state then return anchor end
    local ax, ay, z = anchor:getX(), anchor:getY(), anchor:getZ()
    local px, py = character:getX(), character:getY()
    local best, bestD = anchor, nil
    for _, tile in ipairs(Machines.tiles(state.kind, state.dir, false)) do
        local square = getCell():getGridSquare(ax + tile.dx, ay + tile.dy, z)
        if square then
            local dx, dy = ax + tile.dx + 0.5 - px, ay + tile.dy + 0.5 - py
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then best, bestD = square, d end
        end
    end
    return best
end

-- The sprite of the anchor (the tile at 0, 0): the one the rain storage's entity script is attached to.
function Machines.spriteName(kind, dir, look)
    for _, tile in ipairs(Machines.tiles(kind, dir, look)) do
        if tile.dx == 0 and tile.dy == 0 then return tile.sprite end
    end
    return nil
end

-- sprite name -> machine kind, every look of every kind but the lure (which is no furniture): made the first time it is
-- asked. The furniture tool's pieces (Moveables.lua) and the menu of a piece in the inventory (client Menu.lua) read it.
local pieceKinds = nil

function Machines.kindOfSprite(spriteName)
    if not pieceKinds then
        pieceKinds = {}
        for _, kind in ipairs(Data.ORDER) do
            if kind ~= "lure" then
                for _, dir in ipairs({ "S", "E", "N", "W" }) do
                    for _, look in ipairs(Sprites.LOOKS) do
                        for _, t in ipairs(Sprites.machineTiles(kind, dir, look) or {}) do pieceKinds[t.sprite] = kind end
                    end
                end
            end
        end
    end
    return pieceKinds[spriteName]
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
    -- the tile the game knows by that name, with its properties (setSprite with a name makes a bare picture)
    object:setSpriteFromName(want)
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
                for _, look in ipairs(Sprites.LOOKS) do
                    local name = Machines.spriteName(kind, dir, look)
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

-- The working lure's sound rings (Data.LURE_FX) on its object, or off. Drawn where the game draws (not on a dedicated
-- server). The game would save the animation with the object, but drops it on load (it has no tile id), so a loaded
-- lure gets it again (Machines.onChunk). Each lure has its own instance of the shared frames, so that two in sight do
-- not step one another's frames. The game steps the frames of no ordinary object: the extension API steps those of an
-- object with Data.ANIM_KEY set, while it is drawn (anim.stepKey, Machines.declareAnim). Without the API the rings
-- stand still.
local whiteTint

function Machines.lureFx(object, on)
    if isServer() then return end
    if object:hasAttachedAnimSprites() then object:RemoveAttachedAnims() end
    if not on then
        if object:hasModData() then object:getModData()[Data.ANIM_KEY] = nil end
        return
    end
    local fx = Data.LURE_FX
    local sprite = IsoSprite.CreateSpriteUsingCache(fx.name, fx.anim, fx.frames)
    whiteTint = whiteTint or ColorInfo.new(1, 1, 1, 1)
    object:AttachExistingAnim(sprite, 0, 0, true, 0, false, 0, whiteTint)
    local list = object:getAttachedAnimSprite()
    local mine = list and list:size() > 0 and list:get(list:size() - 1)
    if not mine then return end
    mine:setFrameSpeedPerFrame(fx.speed)
    object:getModData()[Data.ANIM_KEY] = 1
end

-- Tells the extension API to step the attached animations of the objects with Data.ANIM_KEY set (the lures' rings).
-- Where the game draws, once a game; returns true when the API took it.
function Machines.declareAnim()
    local api = OA.api()
    local handle = OA.handle()
    if not (api and handle and type(api.formulas) == "table" and type(api.formulas.set) == "function") then return false end
    local ok, err = pcall(api.formulas.set, handle, "anim.stepKey", Data.ANIM_KEY)
    if not ok then OA.log("lure rings not declared:", tostring(err)) end
    return ok
end

-- The look the state calls for: true running (the lure: working), "ready" (switched on and waiting: the lamps lit,
-- nothing moving) or false.
local function lookOf(object, state)
    if state.kind == "lure" then return not state.spent end
    local look = state.running == true
    if not look and Data.processes(state.kind) and state.on ~= false
        and not Logic.effects(state.kind, state.parts).stopped and Machines.hasPower(object:getSquare()) then
        look = "ready"
    end
    return look
end

-- The machine's light (Data.LIGHTS) as its look calls for. A chunk loading brings it back (the game keeps none).
function Machines.light(object, state, look)
    if look == nil then look = lookOf(object, state) end
    OA.Lights.set(object, Data.lightOf(state.kind, look))
end

-- Shows the look the state calls for on every loaded square of the machine, where it is not already shown, and its
-- light. Also brings the load multiplier up to date (every change of running goes through here).
function Machines.refreshLook(object, state)
    Machines.syncLoad(object, state)
    local look = lookOf(object, state)
    if state.kind == "lure" then Machines.lureFx(object, look) end
    Machines.light(object, state, look)
    local parts
    for _, tile in ipairs(Machines.tiles(state.kind, state.dir, look)) do
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

-- The objects of a machine that hold its containers: the anchor, and its other squares' for a kind with containers
-- on every square (Data everyTile: the research storage).
local function holders(object, state)
    local list = { object }
    if state.x then
        for _, part in ipairs(Machines.partsOf(state)) do list[#list + 1] = part.object end
    end
    return list
end

-- anchor -> { role -> the square's object that holds it }, so that a container on another square is not looked for
-- each time (a watched window asks ten times a second). An entry is checked before it is used: still on its square.
local held = setmetatable({}, { __mode = "k" })

-- The machine's container of a role ("in", "out", "store"), or nil. `object` is any square's object: its own container
-- of the role, or, for the anchor, the one on the square that holds it (Data containerAt).
function Machines.container(object, which)
    local def = Data.CONTAINERS[which]
    if not def then return nil end
    local own = object:getContainerByType(def.type)
    if own then return own end
    local state = Machines.state(object)
    if not state or not state.x then return nil end
    local cache = held[object]
    local holder = cache and cache[which]
    if holder and holder:getObjectIndex() >= 0 then return holder:getContainerByType(def.type) end
    for _, part in ipairs(Machines.partsOf(state)) do
        local found = part.object:getContainerByType(def.type)
        if found then
            cache = cache or {}
            held[object] = cache
            cache[which] = part.object
            return found
        end
    end
    return nil
end

-- The roles whose containers are on a square of a machine facing dir (dx, dy from the anchor).
local function rolesAt(kind, dir, dx, dy)
    local def = Data.KINDS[kind]
    if def.everyTile then return def.containers end
    local roles = {}
    for _, which in ipairs(def.containers) do
        local at = def.containerAt and def.containerAt[which] or { 0, 0 }
        local x, y = Sprites.turnSquare(kind, dir, at[1], at[2])
        if x == dx and y == dy then roles[#roles + 1] = which end
    end
    return roles
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
    entry.taken = true
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
    return not entry.taken and entry.container:contains(entry.item)
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
    plan.weight = item:getActualWeight()
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
    if kind == "propaneRefiner" then return Machines.rottenFood(item) ~= nil end
    if kind == "oilRefiner" then return Machines.oilOf(item) ~= nil end
    return false
end

-- Whether a refiner's tank container takes an item: the propane tanks, or the petrol cans, it fills.
function Machines.acceptsTank(kind, item)
    if kind == "propaneRefiner" then return isPropaneTank(item) end
    if kind == "oilRefiner" then return item:getFullType() == "Base.PetrolCan" end
    return false
end

-- The container's accept function, as the game calls it: (container, item) -> boolean. It is set by name:
-- ItemContainer.setAcceptItemFunction("OperationAcorn.Machines.acceptInput").
function Machines.acceptInput(container, item)
    local object = container:getParent()
    local state = object and Machines.isMachineObject(object) and select(2, Machines.anchorOf(object))
    if not state then return true end
    return Machines.accepts(state.kind, item)
end

-- The tank container's accept function (set by name, as acceptInput).
function Machines.acceptTank(container, item)
    local object = container:getParent()
    local state = object and Machines.isMachineObject(object) and select(2, Machines.anchorOf(object))
    if not state then return true end
    return Machines.acceptsTank(state.kind, item)
end

-- The output container takes nothing from a player (the machine puts products in directly).
function Machines.acceptNothing()
    return false
end

local function applyAccept(object, roles)
    for _, which in ipairs(roles) do
        local container = Machines.container(object, which)
        if container then
            if which == "in" then container:setAcceptItemFunction("OperationAcorn.Machines.acceptInput")
            elseif which == "tank" then container:setAcceptItemFunction("OperationAcorn.Machines.acceptTank")
            elseif which == "out" then container:setAcceptItemFunction("OperationAcorn.Machines.acceptNothing") end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Shredding (P1's yield, P3's bonus)

-- The extras the shred yield takes (P1: bundles = the upgrades' added bundles, blade = the blade's multiplier).
local function shredExtras(record, fx)
    local bundles = 0
    if OA.Upgrades and OA.Upgrades.bundleBonus then bundles = OA.Upgrades.bundleBonus(record) or 0 end
    return { bundles = bundles, blade = fx and fx.shred or 1 }
end

-- How many of `count` sample bundles come with a selected sample: each by the record's chance (시료 감별).
function Machines.selectedOf(record, count, roll)
    local chance = 0
    if count > 0 and OA.Upgrades and OA.Upgrades.selectedChance then chance = OA.Upgrades.selectedChance(record) or 0 end
    if chance <= 0 then return 0 end
    roll = roll or OA.randomFloat
    local n = 0
    for _ = 1, count do
        if roll(0, 1) < chance then n = n + 1 end
    end
    return n
end

-- Shreds one item for a record: books it (the repeat count, the first-shred bonus) and returns how many sample
-- bundles it gives now (its yield times the wear multiplier, with what the record kept from before; the rest is kept)
-- and how many selected samples come with them. The item is not taken here.
function Machines.shredYield(record, info, fx)
    local amount = OA.Shred.yield(info, record, shredExtras(record, fx))
    local count = OA.Shred.carry(record, amount * (fx and fx.yield or 1))
    OA.Shred.commit(record, info, 1)
    return count, Machines.selectedOf(record, count)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The jobs of each kind, for Logic.advance

-- What a machine found to take from a container at its last step: container -> { key, limit, list } (weak: a
-- container that is gone drops out). A step finds the same things again, without a walk, while the container's
-- signature (OA.signature: how many items, what they weigh) is the same and the things are all still in it; a refiner's
-- key also changes every ten game minutes (food rots into fit to take with time). A job done drops it (the walk is
-- done again with what is left).
local queueMemo = setmetatable({}, { __mode = "k" })

-- The things a machine works on, in the order of its container; one taken out (done, or by a player) is skipped. The
-- container is not walked until the first thing is asked for.
local function newQueue(container, accept, limit, timed)
    local queue = {}
    local function load(force)
        local key = OA.signature(container)
        if timed then key = key .. "|" .. math.floor(OA.hours() * 6) end
        local hit = not force and queueMemo[container]
        if hit and hit.key == key and hit.limit == limit then
            local all = true
            for _, entry in ipairs(hit.list) do
                if not present(entry) then all = false break end
            end
            if all then queue.list = hit.list return end
        end
        -- oa-scan: ok (once for a signature, and for a refiner not before ten game minutes pass)
        queue.list = collect(container, accept, limit)
        queueMemo[container] = { key = key, limit = limit, list = queue.list }
    end
    -- the container walked again (a step that goes on after a batch)
    function queue.reload() load(true) end
    -- the n-th thing still there (1 when not given)
    function queue.peek(n)
        if not queue.list then load(false) end
        n = n or 1
        for _, entry in ipairs(queue.list) do
            if present(entry) then
                n = n - 1
                if n == 0 then return entry end
            end
        end
        return nil
    end
    return queue
end

-- Moves what a refiner has made (state.buffer) into the tanks in its tank container: propane into tanks with room
-- (as the part of a full tank), petrol into cans (litres). Returns the amount left.
local function deposit(tankC, state, kind)
    local buffer = state.buffer or 0
    if buffer <= 0 then return 0 end
    local tanks = collect(tankC, function(item)
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
local function hasSink(tankC, state, kind)
    if (state.buffer or 0) < (kind == "propaneRefiner" and 1 or 10) - 1e-6 then return true end
    local tanks = collect(tankC, function(item)
        if kind == "propaneRefiner" then return tankRoom(item) and true or nil end
        return canRoom(item) and true or nil
    end, 1)
    return #tanks > 0
end

-- What each working kind takes from its in-container (the data the job needs, or nil), and the work units one job
-- costs (Data rate is units an hour). The work and the progress the player sees ask the same.
local ACCEPT = {
    bulkShredder = function(item) return Machines.shreddable(item) end,
    cutter = function(item) return Machines.cutterPlan(item) end,
    woodSaw = function(item) return item:getFullType() == "Base.Log" and { weight = item:getActualWeight() } or nil end,
    propaneRefiner = function(item) return Machines.rottenFood(item) end,
    oilRefiner = function(item) return Machines.oilOf(item) end,
}

local function jobCost(kind, entry)
    local work = Data.KINDS[kind].work
    if work then
        -- by weight, never under the least time for one thing
        local s = Data.WORK_SECONDS[work]
        return math.max(entry.data.weight or 0, s.least / s.perWeight)
    end
    return entry.data   -- a refiner: the litres (or weight) it makes from the thing
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
        queue = newQueue(inC, ACCEPT.bulkShredder, Data.BATCH + 5)
        io.reset = queue.reload
        io.next = function(fx, lane)
            if not record then return nil, "noOwner" end
            local entry = queue.peek(lane)
            if not entry then return nil, "noInput" end
            if not outC or free(outC) < 1 then return nil, "outputFull" end
            return { cost = jobCost(kind, entry), entry = entry }
        end
        io.finish = function(job, fx)
            local count, selected = Machines.shredYield(record, job.entry.data, fx)
            takeOut(job.entry)
            putInType(outC, Machines.SAMPLE, count)
            putInType(outC, Machines.SELECTED, selected)
        end

    elseif kind == "cutter" then
        queue = newQueue(inC, ACCEPT.cutter, Data.BATCH + 5)
        io.reset = queue.reload
        io.next = function(fx, lane)
            local entry = queue.peek(lane)
            if not entry then return nil, "noInput" end
            if not outC or free(outC) < 1 then return nil, "outputFull" end
            return { cost = jobCost(kind, entry), entry = entry }
        end
        io.finish = function(job, fx)
            local plan = job.entry.data
            local count, dirty = Logic.cutterPieces(plan, fx)
            takeOut(job.entry)
            putInType(outC, plan.clean, count - dirty)
            putInType(outC, plan.dirty, dirty)
            if plan.buckle then putInType(outC, "Base.Buckle", 1) end
        end

    elseif kind == "woodSaw" then
        queue = newQueue(inC, ACCEPT.woodSaw, Data.BATCH + 5)
        io.reset = queue.reload
        io.next = function(fx, lane)
            local entry = queue.peek(lane)
            if not entry then return nil, "noInput" end
            if not outC or free(outC) < 3 * (fx.planks + 1) then return nil, "outputFull" end
            return { cost = jobCost(kind, entry), entry = entry }
        end
        io.finish = function(job, fx)
            local count = Logic.sawPlanks(fx)
            takeOut(job.entry)
            putInType(outC, "Base.Plank", count)
        end

    elseif kind == "propaneRefiner" or kind == "oilRefiner" then
        local propane = kind == "propaneRefiner"
        local tankC = Machines.container(object, "tank")
        queue = newQueue(inC, ACCEPT[kind], Data.BATCH + 5, propane)
        io.reset = queue.reload
        io.next = function(fx, lane)
            if tankC then deposit(tankC, state, kind) end
            local entry = queue.peek(lane)
            if not entry then return nil, "noInput" end
            if not tankC or not hasSink(tankC, state, kind) then return nil, "noTank" end
            return { cost = jobCost(kind, entry), entry = entry }
        end
        io.finish = function(job, fx)
            local gain
            if propane then gain = Logic.propaneGain(job.entry.data, fx)
            else gain = Logic.petrolGain(job.entry.data, fx) end
            takeOut(job.entry)
            state.buffer = (state.buffer or 0) + gain
            if tankC then deposit(tankC, state, kind) end
        end
    else
        return nil
    end
    -- a job done changes the container: the next step walks it again
    local finish = io.finish
    io.finish = function(job, fx)
        queueMemo[inC] = nil
        return finish(job, fx)
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

    -- What a client reads of an idle machine: whether it runs, why it does not, the product waiting in the buffer.
    -- (`last` and the lanes mean nothing to it while idle: its clock starts again with the first job.) A step that
    -- leaves an idle machine as it was sends nothing.
    local wasIdle, wasRunning, wasReason, wasBuffer = state.idle == true, state.running, state.reason, state.buffer

    if state.on == false or not powered then
        -- Without power or switched off it does not work, and the time does not count: its clock starts again.
        state.idle, state.running, state.last, state.lanes = true, false, now, {}
        state.reason = state.on == false and "off" or "noPower"
        Machines.refreshLook(object, state)
        if isServer() and not (wasIdle and wasRunning == false and wasReason == state.reason) then
            object:transmitModData()
        end
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
    -- the noise of its work once a step: a machine watched works more often (Watch.lua), not louder
    if worked > 0 and not catchUp and (not state.heard or now - state.heard >= Machines.NOISE_EVERY or now < state.heard) then
        state.heard = now
        sound(object, Logic.noiseRadius(kind, Logic.effects(kind, state.parts)))
    end
    if worn then
        for slot, what in pairs(worn) do notePart(state, slot, what) end
    end
    if isServer() and not (wasIdle and state.idle == true and wasRunning == state.running and wasReason == state.reason
        and wasBuffer == state.buffer) then
        object:transmitModData()
    end
    return result
end

-- Hours between the noises a working machine makes (the ten-minute step).
Machines.NOISE_EVERY = 1 / 6

-- The first things a machine would take from its in-container, for the window that shows its jobs (asked ten times a
-- second): found by one walk through the container, and kept while the container's signature (OA.signature: how many
-- items, what they weigh) is the same, the things are still in it, and no more than ten game minutes have passed (an item
-- can become fit to take with time, rotten food). container -> { key, entries } (weak: a container that is gone drops
-- out).
local takesMemo = setmetatable({}, { __mode = "k" })

local function firstTaken(container, kind, lanes)
    local key = OA.signature(container) .. "|" .. kind .. "|" .. lanes .. "|" .. math.floor(OA.hours() * 6)
    local hit = takesMemo[container]
    if hit and hit.key == key then
        local all = true
        for _, entry in ipairs(hit.entries) do
            if not present(entry) then all = false break end
        end
        if all then return hit.entries end
    end
    -- oa-scan: ok (once for a signature, and not before ten game minutes pass)
    local entries = collect(container, ACCEPT[kind], lanes)
    takesMemo[container] = { key = key, entries = entries }
    return entries
end

-- The jobs a working machine is on now, for the player watching it: a list, a lane each, of { item, share } (the
-- share of it done by now, more than 1 when it is due and the machine has not worked since). nil when it is not on a
-- job (idle, off, no power, a part worn out). Light enough for a window that is open: the first things it takes
-- (kept, firstTaken), and the time since it last worked.
function Machines.progress(object)
    local state = Machines.state(object)
    if not state or state.idle ~= false or state.on == false or not ACCEPT[state.kind] then return nil end
    local fx = Logic.effects(state.kind, state.parts)
    local square = object:getSquare()
    if fx.stopped or not square or not Machines.hasPower(square) then return nil end
    local inC = Machines.container(object, "in")
    local entries = inC and firstTaken(inC, state.kind, fx.lanes) or {}
    if #entries == 0 then return nil end
    local spent = Data.KINDS[state.kind].rate * fx.speed * math.max(0, OA.hours() - (state.last or 0))
    local carries = state.lanes or { state.carry or 0 }
    local list = {}
    for lane, entry in ipairs(entries) do
        list[lane] = { item = entry.item, share = ((carries[lane] or 0) + spent) / jobCost(state.kind, entry) }
    end
    return list
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

-- Real milliseconds a machine's object must stay missing from its loaded square, from the step that first found it
-- missing to a later one, before the registry forgets the machine (destroyed). The object can come a little after its
-- square while the game streams the chunk in, and that takes real time, not game time: two ten-minute steps are 25 s
-- apart at the default day length but some 1.2 s fast-forwarded (x40), and less asleep, which could drop a machine
-- still loading. At the default speed the second step still drops it, as before.
Machines.MISSING_MS = 20000

local missingSince = {}   -- by machine id: the real time (ms) a step first found its loaded square without it

-- The EveryTenMinutes handler: works every machine whose square is loaded (each step: a machine integrates the time
-- since it last worked). A registered machine whose square is loaded but whose object is gone (destroyed) is dropped
-- from the registry once it has been missing MISSING_MS of real time; a square unloaded in between starts over.
function Machines.tick()
    local reg = registry()
    if OA.isEmpty(reg.list) then return end
    local ids = {}
    for id in pairs(reg.list) do ids[#ids + 1] = id end
    local cell = getCell()
    local now = getTimestampMs()
    for _, id in ipairs(ids) do
        local entry = reg.list[id]
        entry.missed = nil   -- the old count of steps, kept in saves made before
        local square = cell:getGridSquare(entry.x, entry.y, entry.z)
        local object = square and findOnSquare(square, id)
        if object then
            missingSince[id] = nil
            local ok, err = pcall(Machines.update, object)
            if not ok then OA.log("machine", id, "failed:", tostring(err)) end
        elseif not square then
            missingSince[id] = nil
        else
            local since = missingSince[id]
            if not since or now < since then
                missingSince[id] = now
            elseif now - since >= Machines.MISSING_MS then
                missingSince[id] = nil
                unregister(id)
            end
        end
    end
end

-- The LoadChunk handler: the machines on the chunk catch up the time they were away.
function Machines.onChunk(chunk)
    local reg = Store.world("machines")
    if not reg.byChunk or OA.isEmpty(reg.byChunk) then return end
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
                Machines.addMissingContainers(object, square, rolesAt(state.kind, state.dir, 0, 0))
                applyAccept(object, Data.KINDS[state.kind].containers)
                if state.kind == "lure" then Machines.lureFx(object, not state.spent) end
                Machines.light(object, state)
                local ok, err = pcall(Machines.update, object, { catchUp = true })
                if not ok then OA.log("machine", id, "catch-up failed:", tostring(err)) end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The status (for windows and tooltips)

-- The words for what a machine is doing (its window's status line): off, stopped (a part broken or missing), no
-- power, working, or why it waits.
function Machines.statusText(status)
    if not status.on then return getText("IGUI_OA_Machine_State_off") end
    if status.stopped then
        if status.broken then return getText("IGUI_OA_Machine_State_broken", getText("IGUI_OA_Machine_Slot_" .. status.broken)) end
        return getText("IGUI_OA_Machine_State_missing", getText("IGUI_OA_Machine_Slot_" .. (status.missing or "motor")))
    end
    if status.powered == false then return getText("IGUI_OA_Machine_State_noPower") end
    if status.running then return getText("IGUI_OA_Machine_State_running") end
    local reason = status.reason
    if reason == "noInput" or reason == "outputFull" or reason == "noTank" or reason == "noOwner" then
        return getText("IGUI_OA_Machine_State_" .. reason)
    end
    return getText("IGUI_OA_Machine_State_idle")
end

-- Why a machine with things in it is not working on them, in words: nil when it works, or only waits for its next
-- step (the reason it gave last is noInput, or none yet).
local STOP_REASONS = { outputFull = true, noTank = true, noOwner = true }
function Machines.stopText(object)
    local status = Machines.status(object)
    if not status or status.running then return nil end
    if status.on and not status.stopped and status.powered ~= false and not STOP_REASONS[status.reason] then return nil end
    -- off for want of a part: that, rather than only off
    if not status.on and status.stopped then return select(2, Machines.canSwitchOn(object)) end
    return Machines.statusText(status)
end

-- What a machine is doing now: { kind, name, on, running, reason, powered, speed, lanes, rate, load, noise, stopped,
-- missing, broken, worn, parts = { [slot] = { tier, cond } } }. rate: work an hour on all its lanes; speed: that over
-- the old motor's (lanes x the motor's speed).
function Machines.status(object)
    local state = Machines.state(object)
    if not state then return nil end
    local fx = Logic.effects(state.kind, state.parts)
    local def = Data.KINDS[state.kind]
    local status = {
        kind = state.kind, name = Machines.name(state.kind), on = state.on ~= false, running = state.running == true,
        reason = state.reason, powered = def.power and Machines.hasPower(object:getSquare()) or nil,
        speed = fx.speed * fx.lanes, lanes = fx.lanes, load = Logic.load(state.kind, state.parts, true),
        noise = Logic.noiseRadius(state.kind, fx), stopped = fx.stopped, missing = fx.missing, broken = fx.broken,
        worn = fx.worn, parts = state.parts, rate = def.rate and def.rate * fx.speed * fx.lanes or nil,
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
    -- A machine's own tiles are solid: say "taken", which tells the player more than "blocked".
    if occupied(square) then return "taken" end
    if not square:TreatAsSolidFloor() then return "noFloor" end
    if square:isSolid() or square:isSolidTrans() or square:HasStairs() or square:HasTree() then return "blocked" end
    if not square:isFree(false) then return "blocked" end
    if square:isVehicleIntersecting() then return "blocked" end
    local properties = square:getProperties()
    if properties and properties:has(IsoFlagType.water) then return "water" end
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

-- The facing a machine put down by a character at a square takes: its front toward the character.
function Machines.facing(square, character)
    local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
    if math.abs(dx) > math.abs(dy) then return dx > 0 and "E" or "W" end
    return dy > 0 and "S" or "N"
end

local function setupContainers(object, square, roles)
    for i, which in ipairs(roles) do
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
        -- within the game's cap of 100 (it warns on more); the rest is OA_Capacity, which the PZ Tools API adds
        local raw = math.min(spec.capacity, 100)
        if spec.capacity > raw then object:getModData()[Data.CAPACITY_KEY] = spec.capacity - raw end
        container:setCapacity(raw)
        container:setExplored(true)
    end
end

-- The containers a machine's square should hold and does not (a machine of an older save, before its kind had them):
-- made, as setupContainers makes them.
function Machines.addMissingContainers(object, square, roles)
    local missing = {}
    for _, which in ipairs(roles) do
        if not object:getContainerByType(Data.CONTAINERS[which].type) then missing[#missing + 1] = which end
    end
    if #missing == 0 then return end
    if object:getContainer() then
        for _, which in ipairs(missing) do
            local spec = Data.CONTAINERS[which]
            local container = ItemContainer.new(spec.type, square, object)
            object:addSecondaryContainer(container)
            container:setCapacity(math.min(spec.capacity, 100))
            container:setExplored(true)
        end
    else
        setupContainers(object, square, missing)
    end
    OA.log("machine", tostring(Machines.state(object) and Machines.state(object).id), "given its new containers:",
        table.concat(missing, ", "))
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
-- state, the containers and the rain storage's fluid; the others point to it), its state, the registry (the anchor
-- only). `character` is the one who puts it down (owner), `dir` the facing (the character's side of the square when not
-- given). A machine comes with the parts a new one has, or none when `bare` (put down from its pieces by the furniture
-- tool: its parts were taken out before it was taken up, Moveables.lua). Returns the anchor object. The item (a
-- lure's) is not removed here.
function Machines.place(kind, square, character, item, dir, bare)
    Machines.ensureSpriteProperties()
    dir = dir or Machines.facing(square, character)
    local squares = Machines.footprintSquares(kind, square, dir)
    if not squares then return nil end
    local reg = registry()
    local id = "m" .. tostring(reg.next)
    reg.next = reg.next + 1

    local ax, ay, az = square:getX(), square:getY(), square:getZ()
    local state = { id = id, kind = kind, dir = dir, owner = Store.idOf(character), on = true, last = OA.hours(),
        lanes = {}, idle = true, running = false, buffer = 0, x = ax, y = ay, z = az }
    state.parts = bare and {} or Logic.newParts(kind)
    if kind == "lure" then
        -- a lure taken back while it worked goes on with the hours it had left
        local left = item and item:getModData()[Data.LURE_LEFT_KEY]
        local used = type(left) == "number" and math.max(0, math.min(Data.LURE.hours, Data.LURE.hours - left)) or 0
        state.start, state.slot, state.spent = OA.hours() - used, -1, false
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
            Machines.syncLoad(object, state)
        else
            object:getModData()[Data.ANCHOR_KEY] = { id = id, x = ax, y = ay, z = az }
        end
        -- each container on the square the picture shows it on
        local roles = rolesAt(kind, dir, entry.dx, entry.dy)
        setupContainers(object, entry.square, roles)
        applyAccept(object, roles)
        entry.square:AddSpecialObject(object)
        object:transmitCompleteItemToClients()
    end
    for _, entry in ipairs(squares) do entry.square:RecalcAllWithNeighbours(true) end
    register(state, ax, ay, az)
    -- the look it is put down in: ready when it is on and has power (Machines.refreshLook); a lure's sound rings
    if Data.processes(kind) or kind == "lure" then Machines.refreshLook(anchor, state) end
    OA.log("placed", kind, id, "at", ax, ay, az, dir, #squares, "squares")
    return anchor
end

-- Whether every container of a machine is empty (it can be taken up, Machines.canPickUp).
function Machines.isEmpty(object)
    local state = Machines.state(object)
    for _, holder in ipairs(holders(object, state)) do
        for _, which in ipairs(Data.KINDS[state.kind].containers) do
            local container = holder:getContainerByType(Data.CONTAINERS[which].type)
            if container and not container:getItems():isEmpty() then return false end
        end
    end
    if state.kind == "rainStorage" and object.getFluidAmount and object:getFluidAmount() > 0.01 then return false end
    return true
end

-- Whether a machine can be taken up (the furniture tool, Moveables.lua) or a spent lure cleared: true, or nil and a
-- reason. Its parts count as contents: they are taken out first. `object` is the anchor (Machines.at gives it).
function Machines.canPickUp(object)
    local state = Machines.state(object)
    if not state then return nil, "notMachine" end
    if state.kind == "lure" and not state.spent then return nil, "armed" end
    if not Machines.isEmpty(object) then return nil, "notEmpty" end
    if state.kind ~= "lure" and not OA.isEmpty(state.parts or {}) then return nil, "hasParts" end
    return true
end

-- Clears a spent lure away (a machine is taken up by the furniture tool): every tile and the registry entry, nothing
-- given. Returns whether it was cleared.
function Machines.pickUp(object)
    if not Machines.state(object) or not Machines.canPickUp(object) then return false end
    Machines.remove(object)
    return true
end

-- Whether a lure can be taken back: one that still works (a spent one is cleared, Machines.pickUp).
function Machines.canTakeLure(object)
    local state = Machines.state(object)
    return state ~= nil and state.kind == "lure" and not state.spent
end

-- Takes a working lure back as its item, with the hours it had left (Data.LURE_LEFT_KEY). Returns the item, or nil.
function Machines.takeLure(object, character)
    if not Machines.canTakeLure(object) then return nil end
    local state = Machines.state(object)
    local left = Logic.lureLeft(state, OA.hours())
    local item = instanceItem(itemFullType("lure"))
    if not item then return nil end
    item:getModData()[Data.LURE_LEFT_KEY] = left
    Machines.remove(object)
    local inventory = character:getInventory()
    inventory:AddItem(item)
    sendAddItemToContainer(inventory, item)
    return item
end

local function removeObject(object)
    local square = object:getSquare()
    -- one taken away already (a pick up, a broken part) keeps its square but is no longer on it: nothing to do
    if not square or object:getObjectIndex() < 0 then return end
    if square:transmitRemoveItemFromSquare(object) < 0 then
        OA.log("could not remove a machine object at", square:getX(), square:getY(), square:getZ())
    end
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
    for _, holder in ipairs(holders(object, state)) do
        for _, which in ipairs(Data.KINDS[state.kind].containers) do
            local container = holder:getContainerByType(Data.CONTAINERS[which].type)
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
    state.idle, state.last, state.lanes = true, OA.hours(), {}
    if isServer() then object:transmitModData() end
    return true
end

-- Takes the part out of a slot into the character's inventory. A working machine is switched off first.
function Machines.removePart(object, slot, character)
    local state = Machines.state(object)
    local part = state and state.parts[slot]
    if not part then return false end
    if Data.processes(state.kind) then state.on = false end
    state.parts[slot] = nil
    giveBack(character, state.kind, slot, part)
    state.idle, state.running, state.last, state.lanes = true, false, OA.hours(), {}
    Machines.refreshLook(object, state)
    if isServer() then object:transmitModData() end
    return true
end

-- Whether a machine can be switched on: true, or nil and why, in words (a part it needs is missing or broken).
function Machines.canSwitchOn(object)
    local state = Machines.state(object)
    if not state then return nil end
    local fx = Logic.effects(state.kind, state.parts)
    if not fx.stopped then return true end
    if fx.broken then
        return nil, getText("IGUI_OA_Machine_CannotOn_broken", getText("IGUI_OA_Machine_Slot_" .. fx.broken))
    end
    return nil, getText("IGUI_OA_Machine_CannotOn_missing", getText("IGUI_OA_Machine_Slot_" .. (fx.missing or "motor")))
end

-- Switches a machine on or off. It is not switched on without the parts it needs.
function Machines.setOn(object, on)
    local state = Machines.state(object)
    if not state or not Data.processes(state.kind) then return end
    if on and not Machines.canSwitchOn(object) then return end
    state.on = on and true or false
    state.idle, state.last, state.lanes = true, OA.hours(), {}
    if not state.on then state.running = false end
    Machines.refreshLook(object, state)
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
-- bundles (and the selected samples with them) go into it. Returns the number of bundles and of selected samples.
-- `record` is the character's.
function Machines.shredByHand(character, record, items)
    local inventory = character:getInventory()
    local total, selectedTotal = 0, 0
    local function give(fullType, n)
        for _ = 1, n do
            local made = instanceItem(fullType)
            if made then
                inventory:AddItem(made)
                sendAddItemToContainer(inventory, made)
            end
        end
    end
    for _, item in ipairs(items) do
        if inventory:containsRecursive(item) and not item:isEquipped() then
            local info = Machines.shreddable(item)
            if info then
                local count, selected = Machines.shredYield(record, info, nil)
                local container = item:getContainer()
                container:Remove(item)
                sendRemoveItemFromContainer(container, item)
                give(Machines.SAMPLE, count)
                give(Machines.SELECTED, selected)
                total, selectedTotal = total + count, selectedTotal + selected
            end
        end
    end
    return total, selectedTotal
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
