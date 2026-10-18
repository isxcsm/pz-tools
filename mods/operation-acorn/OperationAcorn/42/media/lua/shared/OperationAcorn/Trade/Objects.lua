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

-- The objects of a square as a plain list.
function Objects.list(square)
    local result = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do result[#result + 1] = objects:get(i) end
    return result
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

-- Whether a square is a place a box or a terminal can stand on: loaded, a solid floor, nothing in the way. Returns
-- true, or false and a reason (IGUI_OA_Trade_Reason_<reason>).
function Objects.free(square)
    if not square then return false, "notLoaded" end
    if square:isWaterSquare() then return false, "water" end
    if not square:TreatAsSolidFloor() then return false, "floor" end
    if square:isVehicleIntersecting() then return false, "vehicle" end
    if not square:isFree(false) then return false, "blocked" end
    for _, object in ipairs(Objects.list(square)) do
        if Objects.kindOf(object) then return false, "occupied" end
    end
    return true
end

-- Whether a square can be come up to: one of the eight round it is free (a crate dropped among others, every side
-- taken, could not be opened).
function Objects.reachable(square)
    local c = cell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dx = -1, 1 do
        for dy = -1, 1 do
            if (dx ~= 0 or dy ~= 0) and Objects.free(c:getGridSquare(x + dx, y + dy, z)) then return true end
        end
    end
    return false
end

-- Whether a square holds a building or a tree.
local function buildingOrTree(square)
    if square:getBuilding() ~= nil or square:getRoom() ~= nil then return "building" end
    if square:HasTree() then return "tree" end
    return nil
end

-- Whether a delivery box can stand on a square: outdoors with nothing above, on the ground floor, a free square,
-- and no building or tree within `radius` tiles (DESIGN 9: room for a helicopter). `cache` (a table the caller keeps
-- for one search) remembers what a square near held. Returns true, or false and a reason.
function Objects.clearSquare(square, radius, cache)
    radius = radius or Objects.CLEAR_RADIUS
    if not square then return false, "notLoaded" end
    if square:getZ() ~= 0 then return false, "level" end
    if not square:isOutside() then return false, "inside" end
    local ok, why = Objects.free(square)
    if not ok then return false, why end
    if not Objects.reachable(square) then return false, "blocked" end
    local cx, cy = square:getX(), square:getY()
    local c = cell()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local key = (cx + dx) * 100000 + (cy + dy)
            local near = cache and cache[key]
            if near == nil then
                local s = c:getGridSquare(cx + dx, cy + dy, 0)
                if not s then
                    near = "notLoaded"
                else
                    near = buildingOrTree(s) or false
                end
                if cache then cache[key] = near end
            end
            if near then return false, near end
        end
    end
    return true
end

-- The nearest square to x, y that passes `test(square, cache)`, searching ring by ring up to maxRadius tiles. Returns
-- the square and how far it is, or nil.
function Objects.search(x, y, z, maxRadius, test)
    local c = cell()
    local cache = {}
    for r = 0, maxRadius do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local square = c:getGridSquare(x + dx, y + dy, z)
                    if square and test(square, cache) then return square, r end
                end
            end
        end
    end
    return nil
end

-- Whether no one (a player, a zombie) stands on a square: a crate coming down does not land on anyone.
function Objects.nobody(square)
    local moving = square:getMovingObjects()
    return moving == nil or moving:isEmpty()
end

-- A clear spot for a box near x, y: the full clearance first, then less (a crowded town has few wide places). `empty`:
-- only a square no one stands on (where a crate comes down).
function Objects.findClear(x, y, maxRadius, empty)
    for _, clearance in ipairs({ Objects.CLEAR_RADIUS, 2, 1, 0 }) do
        local square, r = Objects.search(x, y, 0, maxRadius or 30, function(square, cache)
            if empty and not Objects.nobody(square) then return false end
            return Objects.clearSquare(square, clearance, cache)
        end)
        if square then return square, clearance, r end
    end
    return nil
end

-- A free square beside a spot for the crate to come down on, no one standing on it and one beside it free: nearest,
-- outdoors if possible.
function Objects.findBeside(x, y, z, maxRadius)
    local square = Objects.search(x, y, z, maxRadius or 4, function(square)
        if not Objects.free(square) or not Objects.nobody(square) or not Objects.reachable(square) then return false end
        return square:isOutside() and (x ~= square:getX() or y ~= square:getY())
    end)
    if square then return square end
    return Objects.search(x, y, z, maxRadius or 4, function(square)
        return Objects.free(square) and Objects.nobody(square) and Objects.reachable(square)
            and (x ~= square:getX() or y ~= square:getY())
    end)
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
