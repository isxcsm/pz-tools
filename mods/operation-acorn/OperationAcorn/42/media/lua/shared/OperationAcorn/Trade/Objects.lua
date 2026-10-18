-- The trade part's things in the world: the communication terminal, the delivery box and the supply crate. They are
-- plain objects of a square (IsoObject with this mod's tile) that carry their kind and owner in their own modData,
-- so that nothing needs to scan squares to know them. This file holds what is done to a square and its objects:
-- finding a clear place, making and removing an object, setting up a box's container, making an item from a spec.
-- Called from the timed actions, the server's handlers and the chunk handlers (all of which run where the world is
-- decided).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sprites"
require "OperationAcorn/Chunks"
require "OperationAcorn/Lights"
require "OperationAcorn/Trade/Trade"
local OA = OperationAcorn
local Trade = OA.Trade
local Sprites = OA.Sprites
local Objects = {}
Trade.Objects = Objects

-- modData keys on the objects (all start with OA_, DESIGN 1).
Objects.KIND = "OA_Kind"
Objects.OWNER = "OA_Owner"
Objects.BOX = "OA_Box"
Objects.CARGO = "OA_Cargo"
Objects.SEALED = "OA_Sealed"

-- The kinds.
Objects.TERMINAL, Objects.DELIVERY_BOX, Objects.CRATE = "terminal", "box", "crate"

-- The items that carry them, and the container types the loot window names (IGUI_ContainerTitle_<type>).
Objects.ITEMS = {
    terminal = "OperationAcorn.CommTerminal",
    box = "OperationAcorn.DeliveryBox",
    field = "OperationAcorn.FieldTerminal",
}
-- The modData key of a field terminal standing in the world (put down from the FieldTerminal item): the team's own
-- terminal (DESIGN-terminal 3).
Objects.UPGRADED = "OA_Upgraded"
Objects.BOX_CONTAINER, Objects.CRATE_CONTAINER = "OADeliveryBox", "OASupplyCrate"
-- The container of a box whose owner's character died (Objects.abandoned): its own title in the loot window.
Objects.ABANDONED_CONTAINER = "OAAbandonedBox"
-- The texts of those titles; named here so that the translation check sees them used.
Objects.TITLE_KEYS = {
    box = "IGUI_ContainerTitle_OADeliveryBox",
    abandoned = "IGUI_ContainerTitle_OAAbandonedBox",
    crate = "IGUI_ContainerTitle_OASupplyCrate",
}

-- A box takes only what the team takes: the container's accept function is looked up by this global name each time
-- (the game does not keep it in the save, so every place a box shows up sets it again).
Objects.ACCEPT = "OperationAcorn.Trade.Objects.acceptItem"
-- The accept function of an opened supply crate: things are only taken out of it (it is not a storage box).
Objects.TAKE_ONLY = "OperationAcorn.Trade.Objects.acceptNothing"

-- Clear space around a delivery box (tiles): no building and no tree within this, so that a helicopter can come down.
Objects.CLEAR_RADIUS = 3

local function cell() return getCell() end

function Objects.square(x, y, z)
    return cell():getGridSquare(x, y, z)
end

-- The kind of an object, or nil: read without making a modData table for objects that never had one.
function Objects.kindOf(object)
    if object and object:hasModData() then return object:getModData()[Objects.KIND] end
    return nil
end

-- The first object of a kind on a square (and, when given, with the box id).
function Objects.find(square, kind, boxId)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if Objects.kindOf(object) == kind then
            if not boxId or object:getModData()[Objects.BOX] == boxId then return object end
        end
    end
    return nil
end

-- The world queries (the extension API: squares.nearest). Their conditions are constants: the API reads a table once
-- and keeps what it read with the table, so a table used again costs nothing to read.
local function squares() return OA.api().squares end

-- A new condition table: `base` and `more`.
local function with(base, more)
    local made = {}
    for k, v in pairs(base) do made[k] = v end
    for k, v in pairs(more) do made[k] = v end
    return made
end

-- A square a thing can stand on: a solid floor out of the water, nothing in the way (no vehicle either), and nothing of
-- this mod's (an object with a kind) on it.
local FREE = { free = true, solidFloor = true, water = false, vehicle = false, noObjectData = Objects.KIND }
-- ... and no one (a player, a zombie) on it: a crate coming down does not land on anyone.
local FREE_EMPTY = with(FREE, { moving = false })
-- A square that can be come up to: one of the eight round it is free (a crate dropped among others, every side
-- taken, could not be opened).
local REACHABLE = { around = FREE }
-- A free, empty square beside a spot that can be come up to; outdoors if possible.
local BESIDE = with(FREE_EMPTY, REACHABLE)
local BESIDE_OUTSIDE = with(BESIDE, { outside = true })
-- Squares with no building (nor a room) and no tree, and the parts of that, to tell which one fails.
local OPEN_GROUND = { building = "none", room = "none", tree = false }
local NO_BUILDING = { building = "none", room = "none" }
local NO_TREE = { tree = false }
local ANY = {}

-- The clearances a box is looked for with: the full one first, then less (a crowded town has few wide places).
local CLEARANCES = { Objects.CLEAR_RADIUS, 2, 1, 0 }

-- Outdoors, free, reachable, and open ground within `radius` tiles (all of it loaded); `empty` adds that no one stands
-- on it. By radius, made once.
local clearing = {}
local function clearFilter(radius, empty)
    local made = clearing[radius]
    if not made then
        local base = with(FREE, { outside = true, around = FREE, clear = { r = radius, filter = OPEN_GROUND } })
        made = { base, with(base, { moving = false }) }
        clearing[radius] = made
    end
    return made[empty and 2 or 1]
end

-- The parts of a clearance by radius, made once: unloaded squares, then a building, then a tree.
local parting = {}
local function clearParts(radius)
    local made = parting[radius]
    if not made then
        made = {
            { why = "notLoaded", filter = { clear = { r = radius, filter = ANY } } },
            { why = "building", filter = { clear = { r = radius, filter = NO_BUILDING } } },
            { why = "tree", filter = { clear = { r = radius, filter = NO_TREE } } },
        }
        parting[radius] = made
    end
    return made
end

-- Whether a loaded square meets a condition table (one call).
local function met(square, filter)
    return squares().nearest({ list = { square:getX(), square:getY(), square:getZ() } }, filter) ~= nil
end

-- Whether a square is a place a box or a terminal can stand on: loaded, a solid floor, nothing in the way.
function Objects.isFree(square)
    return square ~= nil and met(square, FREE)
end

-- Why a loaded square is not free (IGUI_OA_Trade_Reason_<reason>), in the order the game would stop at it.
local function whyNotFree(square)
    if square:isWaterSquare() then return "water" end
    if not square:TreatAsSolidFloor() then return "floor" end
    if square:isVehicleIntersecting() or square:getVehicleContainer() ~= nil then return "vehicle" end
    if not square:isFree(false) then return "blocked" end
    return "occupied"
end

-- Like isFree: true, or false and a reason (IGUI_OA_Trade_Reason_<reason>).
function Objects.free(square)
    if not square then return false, "notLoaded" end
    if met(square, FREE) then return true end
    return false, whyNotFree(square)
end

-- Whether a square can be come up to: one of the eight round it is free.
function Objects.reachable(square)
    return met(square, REACHABLE)
end

-- Whether a delivery box can stand on a square: outdoors with nothing above, on the ground floor, a free square that
-- can be come up to, and no building or tree within `radius` tiles (DESIGN 9: room for a helicopter).
function Objects.isClear(square, radius)
    if not square or square:getZ() ~= 0 then return false end
    return met(square, clearFilter(radius or Objects.CLEAR_RADIUS))
end

-- Like isClear: true, or false and a reason (told only once it is not clear, by the parts of the conditions).
function Objects.clearSquare(square, radius)
    radius = radius or Objects.CLEAR_RADIUS
    if not square then return false, "notLoaded" end
    if square:getZ() ~= 0 then return false, "level" end
    if met(square, clearFilter(radius)) then return true end
    if not square:isOutside() then return false, "inside" end
    local ok, why = Objects.free(square)
    if not ok then return false, why end
    if not Objects.reachable(square) then return false, "blocked" end
    for _, part in ipairs(clearParts(radius)) do
        if not met(square, part.filter) then return false, part.why end
    end
    return false, "blocked"
end

-- The nearest square to x, y that passes `test(square)`, searching ring by ring up to maxRadius tiles. Returns the
-- square and how far it is, or nil. (For the dev tools and the in-game tests, which ask with a test of their own.)
function Objects.search(x, y, z, maxRadius, test)
    local c = cell()
    for r = 0, maxRadius do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local square = c:getGridSquare(x + dx, y + dy, z)
                    if square and test(square) then return square, r end
                end
            end
        end
    end
    return nil
end

-- The nearest free square to x, y on level z within maxRadius tiles, no one standing on it. Returns the square and how
-- far it is, or nil.
function Objects.findFree(x, y, z, maxRadius)
    return squares().nearest({ x = x, y = y, z = z, to = maxRadius }, FREE_EMPTY)
end

-- A clear spot for a box near x, y: the full clearance first, then less. `empty`: only a square no one stands on
-- (where a crate comes down). Returns the square, the clearance and how far it is.
function Objects.findClear(x, y, maxRadius, empty)
    local area = { x = x, y = y, z = 0, to = maxRadius or 30 }
    for _, clearance in ipairs(CLEARANCES) do
        local square, r = squares().nearest(area, clearFilter(clearance, empty))
        if square then return square, clearance, r end
    end
    return nil
end

-- A free square beside a spot for the crate to come down on, no one standing on it and one beside it free: nearest,
-- outdoors if possible.
function Objects.findBeside(x, y, z, maxRadius)
    local area = { x = x, y = y, z = z, from = 1, to = maxRadius or 4 }
    return (squares().nearest(area, BESIDE_OUTSIDE)) or (squares().nearest(area, BESIDE))
end

-- Whether a terminal has power, as the game asks of any appliance (IsoObject.checkObjectPowered): a generator in
-- range, the grid while it lasts, or a network of the extension API that it is a consumer of (a breaker box's
-- outside line). Without the object yet (being put down), its square's.
function Objects.powered(square, object)
    if object and object:getSquare() then return object:checkObjectPowered() end
    if not square then return false end
    return square:haveElectricity() or square:hasGridPower()
end

-- Makes an object of a kind on a square and tells the clients: sprite = the tile name; data = modData to put on it.
function Objects.create(square, sprite, kind, data)
    -- The tile gives the object its container when it names one (delivery box and supply crate tiles do).
    local object = IsoObject.new(getCell(), square, sprite)
    local md = object:getModData()
    md[Objects.KIND] = kind
    for k, v in pairs(data or {}) do md[k] = v end
    square:AddTileObject(object)
    Objects.markExplored(object)
    if isServer() then object:transmitCompleteItemToClients() end
    return object
end

-- Marks the object's containers explored: the game rolls loot into a container the first time it is opened unless it
-- is (ISInventoryPage, ItemPickerJava), and the tile's container is not, as the game makes it.
function Objects.markExplored(object)
    for i = 0, object:getContainerCount() - 1 do
        local container = object:getContainerByIndex(i)
        if container and not container:isExplored() then container:setExplored(true) end
    end
end

-- Takes an object off its square on purpose (picked up, taken by the helicopter): its removal is not a destruction.
Objects.removing = false
function Objects.remove(object)
    local square = object:getSquare()
    if not square then return end
    Objects.removing = true
    local ok, err = pcall(function() square:transmitRemoveItemFromSquare(object) end)
    Objects.removing = false
    if not ok then OA.log("remove failed:", tostring(err)) end
end

-- Changes an object's tile and tells the clients.
function Objects.setSprite(object, name)
    local sprite = object:getSprite()
    if sprite and sprite:getName() == name then return end
    -- the tile the game knows by that name, with its properties (setSprite with a name makes a bare picture: no name,
    -- no properties, nothing solid)
    object:setSpriteFromName(name)
    if isServer() then object:transmitUpdatedSpriteToClients() end
end

-- The terminal's tile for a facing and for power on or off.
function Objects.terminalSprite(facing, on, upgraded)
    return Sprites.terminal(facing or "S", on, upgraded)
end

-- Whether a terminal object is the field terminal.
function Objects.isUpgraded(object)
    return object:getModData()[Objects.UPGRADED] == true
end

-- The light a terminal's screen gives off around it at night while it has power (OA.Lights): the crude one's phosphor
-- green, the field terminal's warm white. { r, g, b, radius in squares }.
Objects.TERMINAL_LIGHTS = {
    crude = { 0.2, 0.5, 0.25, 3 },
    field = { 0.5, 0.46, 0.34, 3 },
}

-- Shows a terminal's power: its lit or dark tile, when that changed, and the light of its screen.
function Objects.showTerminal(object)
    local square = object:getSquare()
    if not square then return end
    local facing = object:getModData().OA_Facing or "S"
    local on, upgraded = Objects.powered(square, object), Objects.isUpgraded(object)
    Objects.setSprite(object, Objects.terminalSprite(facing, on, upgraded))
    OA.Lights.set(object, on and Objects.TERMINAL_LIGHTS[upgraded and "field" or "crude"] or nil)
end

-- What the delivery box's container takes: items the team accepts (P1's rule), nothing otherwise.
function Objects.acceptItem(container, item)
    -- an abandoned box takes nothing: what is in it can only be taken out
    if Objects.abandoned(container:getParent()) then return false end
    if not (OA.Value and OA.Value.info and OA.Value.accepts) then return false end
    local ok, info = OA.try("objects: the info of an item", OA.Value.info, item)
    if not ok or not info then return false end
    return OA.Value.accepts(info) == true
end

function Objects.acceptNothing()
    return false
end

-- The capacity a record's box has now: the trust rewards' box capacity (the vanilla cap of 100 for a container stays
-- until the extension API lifts it; ItemContainer.getCapacity cuts what is set to 100).
function Objects.capacityFor(record)
    if record and OA.Trust and OA.Trust.rewards then
        local ok, rewards = OA.try("objects: the rewards", OA.Trust.rewards, record)
        if ok and rewards and rewards.boxCapacity then return rewards.boxCapacity end
    end
    return OA.BALANCE.boxCapacity
end

-- The game's cap on a container's capacity.
Objects.VANILLA_CAP = 100

-- Sets up a delivery box's container (made when missing): what it accepts and how much it holds. Done when the box
-- is put down, when its chunk loads and when it is shown. A box with its sealed tile has no container.
function Objects.setupBox(object, record)
    if object:getModData()[Objects.SEALED] then
        Objects.closeFor(object)
        return nil
    end
    local container = object:getContainer()
    if not container then
        container = ItemContainer.new(Objects.BOX_CONTAINER, object:getSquare(), object)
        object:setContainer(container)
    end
    if not container:isExplored() then container:setExplored(true) end
    Objects.nameContainer(container, Objects.abandoned(object) and Objects.ABANDONED_CONTAINER or Objects.BOX_CONTAINER)
    -- The PZ Extension API lifts the vanilla cap of 100 for containers whose object carries modData OA_Capacity as a number
    -- (the upgrades part declares that key) and adds the number to the raw capacity; without it the game holds the
    -- box to 100. The raw capacity stays within 100 (the game warns on every larger one, and this runs on every
    -- refresh of the loot window): the rest is OA_Capacity. Only what differs is written.
    local capacity = Objects.capacityFor(record)
    local raw = math.min(capacity, Objects.VANILLA_CAP)
    local md = object:getModData()
    if md[OA.CAPACITY_KEY] ~= capacity - raw then md[OA.CAPACITY_KEY] = capacity - raw end
    -- (with the API getCapacity says the whole, raw and OA_Capacity; without it the raw)
    local now = container:getCapacity()
    if now ~= raw and now ~= capacity then container:setCapacity(raw) end
    if container:getAcceptItemFunction() ~= Objects.ACCEPT then container:setAcceptItemFunction(Objects.ACCEPT) end
    return container
end

-- The container type the loot window names it by (IGUI_ContainerTitle_<type>); the tile's own is "crate" or
-- "militarycrate". Best effort: the vanilla title shows when the game refuses.
function Objects.nameContainer(container, containerType)
    if container:getType() ~= containerType then
        OA.try("objects: the container type", function() container:setType(containerType) end)
    end
end

-- A sealed thing has no way in: the container the tile gave it (a delivery box and a crate tile each name one) is
-- taken away, now and again whenever its chunk loads.
function Objects.closeFor(object)
    if object:getContainer() then object:removeAllContainers() end
end

-- Whether a box (an object, or the mod data of a box item) is abandoned: its owner's character died. No one deals
-- through it any more: it takes nothing, is not sealed or taken up, and can be dismantled (Things.dismantleBox).
function Objects.abandoned(thing)
    if not thing then return false end
    local md = thing.getModData and thing:getModData() or thing
    local id = md and md[Objects.OWNER]
    local owner = id and OA.Store.player(id)
    return owner ~= nil and not OA.Store.alive(owner)
end

-- The same for a record that is looked for by the box's owner id.
function Objects.setupBoxOf(object)
    local owner = object:getModData()[Objects.OWNER]
    return Objects.setupBox(object, owner and OA.Store.player(owner) or nil)
end

-- An item made from a spec { type, count (not used here), mod, condition, used, fluid, amount, receipt, name }. Nil
-- when the type does not exist.
function Objects.makeItem(spec)
    local item = instanceItem(spec.type)
    if not item then
        OA.log("no such item", tostring(spec.type))
        return nil
    end
    if spec.mod then
        local md = item:getModData()
        for k, v in pairs(spec.mod) do md[k] = v end
    end
    if spec.receipt then item:getModData().OA_Receipt = spec.receipt end
    -- a name (a translation key): what the extension API names the item by when it holds the key (the name follows the
    -- language), else written in as a player names an item
    if spec.name then
        item:setName(getText(spec.name))
        if not (OA.Gear and OA.Gear.namedByKey and OA.Gear.namedByKey(item)) then item:setCustomName(true) end
    end
    if spec.condition then item:setCondition(spec.condition) end
    if spec.used then item:setUsedDelta(spec.used) end
    if spec.fluid then
        local fluidContainer = item:getFluidContainer()
        local fluid = FluidType and FluidType.FromNameLower and FluidType.FromNameLower(string.lower(spec.fluid))
        if fluidContainer and fluid then
            fluidContainer:Empty()
            fluidContainer:addFluid(fluid, spec.amount or fluidContainer:getCapacity())
        end
    elseif spec.empty then
        local fluidContainer = item:getFluidContainer()
        if fluidContainer then fluidContainer:Empty() end
    end
    return item
end

-- Puts the specs' items into a container, telling the clients, and returns how many items were added.
function Objects.fill(container, specs)
    local added = 0
    local function put(item)
        container:AddItem(item)
        if isServer() then sendAddItemToContainer(container, item) end
        added = added + 1
    end
    for _, spec in ipairs(specs or {}) do
        for _ = 1, spec.count or 1 do
            -- a machine comes as the furniture tool's pieces and its parts (Machines.deliveryItems)
            local pieces = OA.Machines and OA.Machines.deliveryItems and OA.Machines.deliveryItems(spec.type)
            if pieces then
                for _, item in ipairs(pieces) do put(item) end
            else
                local item = Objects.makeItem(spec)
                if item then put(item) end
            end
        end
    end
    return added
end

-- Takes an item that is put down away from the character.
function Objects.consume(character, item)
    if character:getPrimaryHandItem() == item then character:setPrimaryHandItem(nil) end
    if character:getSecondaryHandItem() == item then character:setSecondaryHandItem(nil) end
    local container = item:getContainer()
    if container then
        container:DoRemoveItem(item)
        sendRemoveItemFromContainer(container, item)
    end
    sendEquip(character)
end

-- Gives a character ordinary items by type and count (what a broken crate leaves).
function Objects.give(character, fullType, count)
    local inventory = character:getInventory()
    for _ = 1, count do
        local item = inventory:AddItem(fullType)
        if item then sendAddItemToContainer(inventory, item) end
    end
end

return Objects
