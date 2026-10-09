-- What is done to the terminal, the delivery box and the supply crate, where the world is decided (the server, or
-- the game alone): put down, taken up, sealed, opened, broken, destroyed. The timed actions and the helicopter call
-- these; each checks the rules again and changes the record (Trade.Boxes) together with the world.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sprites"
require "OperationAcorn/Sync"
require "OperationAcorn/Chunks"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Objects"
local OA = OperationAcorn
local Trade, Sprites, Chunks = OA.Trade, OA.Sprites, OA.Chunks
local Boxes, Objects = Trade.Boxes, Trade.Objects
local Things = {}
Trade.Things = Things

-- The sounds: a crate's latch, a box sealing (vanilla sound names).
Things.LATCH_SOUND = "PZ_MetalSnap"

-- A character within this many tiles of a thing can work on it.
Things.REACH = 6

local function near(character, x, y)
    local dx, dy = character:getX() - (x + 0.5), character:getY() - (y + 0.5)
    return dx * dx + dy * dy <= Things.REACH * Things.REACH
end
Things.near = near

local function changed(record)
    if record then OA.Sync.changed("trade", record.id) end
end

-- The persistent waiting entries for things that must be set up again whenever their chunk loads.
local function watch(kind, x, y, z, extra)
    Chunks.remove(function(e) return e.kind == kind and e.x == x and e.y == y and e.z == z end)
    local entry = { kind = kind, x = x, y = y, z = z }
    for k, v in pairs(extra or {}) do entry[k] = v end
    Chunks.add(entry)
end

local function unwatch(kind, x, y, z)
    Chunks.remove(function(e) return e.kind == kind and e.x == x and e.y == y and e.z == z end)
end

Things.watch, Things.unwatch = watch, unwatch

-- The terminal ------------------------------------------------------------------------------------------------

-- Puts a terminal item down on a square, facing S, E, N or W.
function Things.placeTerminal(character, square, facing, item, record)
    local ok, why = Objects.free(square)
    if not ok then return false, why end
    local upgraded = item and item:getModData()[Objects.UPGRADED] == true
    local object = Objects.create(square, Objects.terminalSprite(facing, Objects.powered(square), upgraded),
        Objects.TERMINAL, { OA_Facing = facing, [Objects.UPGRADED] = upgraded or nil })
    Objects.consume(character, item)
    watch("trade.terminal", square:getX(), square:getY(), square:getZ())
    Objects.showTerminal(object)
    if record then Things.terminalPlaced(record, square) end
    return true, object
end

-- The record learns where its terminal stands (the base, for the story part's distance bands). The first one placed
-- also fixes the story part's anchor; the bands do not move when the terminal does.
function Things.terminalPlaced(record, square)
    local heli = Trade.heli(record)
    local first = heli.terminal == nil
    heli.terminal = { x = square:getX(), y = square:getY(), z = square:getZ() }
    if first and OA.Story and OA.Story.setAnchor then
        OA.Story.setAnchor(record, heli.terminal.x, heli.terminal.y, heli.terminal.z)
    end
end

-- Takes a terminal up to carry.
function Things.takeTerminal(character, object)
    local square = object:getSquare()
    if not square then return false end
    unwatch("trade.terminal", square:getX(), square:getY(), square:getZ())
    local upgraded = Objects.isUpgraded(object)
    Objects.remove(object)
    Objects.giveHeavy(character, Objects.ITEMS.terminal, upgraded and { [Objects.UPGRADED] = true } or nil)
    return true
end

-- Upgrades a terminal with the kit the character carries: the team's own terminal from now on (its look, and the
-- price graph in its market tab). The kit is used up.
function Things.upgradeTerminal(character, object)
    if Objects.kindOf(object) ~= Objects.TERMINAL then return false, "noTerminal" end
    if Objects.isUpgraded(object) then return false, "upgraded" end
    local square = object:getSquare()
    if not square or not near(character, square:getX(), square:getY()) then return false, "far" end
    local kit = character:getInventory():getFirstTypeRecurse(Objects.ITEMS.kit)
    if not kit then return false, "noKit" end
    Objects.consume(character, kit)
    object:getModData()[Objects.UPGRADED] = true
    if isServer() then object:transmitModData() end
    Objects.showTerminal(object)
    square:playSound(Things.LATCH_SOUND)
    return true
end

-- The delivery box ----------------------------------------------------------------------------------------------

-- The record that owns a box object or item: by the owner id it carries, else the character's.
local function ownerOf(modData, fallback)
    local id = modData and modData[Objects.OWNER]
    return (id and OA.Store.player(id)) or fallback
end

-- Puts a delivery box item down. A box the record does not know (made by hand, say) is entered as a previous box
-- unless the record has no active box.
function Things.placeBox(character, record, square, item)
    local owner = ownerOf(item:getModData(), record)
    local ok, why = Objects.clearSquare(square)
    if not ok then return false, why end
    local id = item:getModData()[Objects.BOX]
    local box = id and Boxes.get(owner, id) or nil
    if box and box.state == "sealed" then return false, "state" end
    if not box then
        box = Boxes.add(owner, { state = "placed", x = square:getX(), y = square:getY(), z = square:getZ(), active = nil })
    end
    Boxes.place(owner, box.id, square:getX(), square:getY(), square:getZ())
    box.pending = nil
    local object = Objects.create(square, Sprites.deliveryBox(false), Objects.DELIVERY_BOX,
        { OA_Box = box.id, OA_Owner = owner.id })
    Objects.setupBox(object, owner)
    Objects.consume(character, item)
    watch("trade.box", square:getX(), square:getY(), square:getZ(), { box = box.id, owner = owner.id })
    changed(owner)
    return true, object, box
end

-- Takes an empty open box up to carry; the record remembers the spot it stood on.
function Things.takeBox(character, object)
    local md = object:getModData()
    if md[Objects.SEALED] then return false, "sealed" end
    local owner = ownerOf(md, nil)
    local container = object:getContainer()
    if container and not container:isEmpty() then return false, "notEmpty" end
    local square = object:getSquare()
    if not square then return false end
    local boxId = md[Objects.BOX]
    if owner and boxId then Boxes.carry(owner, boxId) end
    unwatch("trade.box", square:getX(), square:getY(), square:getZ())
    Objects.remove(object)
    Objects.giveHeavy(character, Objects.ITEMS.box, { OA_Box = boxId, OA_Owner = owner and owner.id or nil })
    changed(owner)
    return true
end

-- The items of a box's container as a plain list.
local function itemsOf(container)
    local list = {}
    local items = container:getItems()
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    return list
end
Things.itemsOf = itemsOf

-- What would be sealed of a container's items: { taken = { item }, infos = { info }, refused = { item },
-- weight }. An item the team does not take (the manual left in, say) is `refused`: it goes back to the character.
function Things.sealable(container)
    local taken, infos, refused, refusedInfos, weight = {}, {}, {}, {}, 0
    for _, item in ipairs(itemsOf(container)) do
        local ok, info = pcall(OA.Value.info, item)
        if ok and info and OA.Value.accepts(info) == true then
            taken[#taken + 1] = item
            infos[#infos + 1] = info
            weight = weight + item:getActualWeight()
        else
            refused[#refused + 1] = item
            if ok and info then refusedInfos[#refusedInfos + 1] = info end
        end
    end
    return { taken = taken, infos = infos, refused = refused, refusedInfos = refusedInfos, weight = weight }
end

-- The economy hears of what the box turned away (the big meteorite gets its radio line, once a day for a record).
-- Only when a box is really sealed, not when the estimate is looked at.
function Things.noteRefusals(record, infos)
    if not (OA.Value and OA.Value.noteRefusal) then return end
    for _, info in ipairs(infos or {}) do
        local ok, err = pcall(OA.Value.noteRefusal, record, info)
        if not ok then OA.log("refusal note failed:", tostring(err)) end
    end
end

-- Seals a box: records its items by kind and count in the save, deletes them, shows the sealed tile and closes the
-- container for good. Returns true, or false and a reason.
function Things.seal(character, record, object)
    local md = object:getModData()
    if Objects.kindOf(object) ~= Objects.DELIVERY_BOX or md[Objects.SEALED] then return false, "state" end
    local owner = ownerOf(md, record)
    local square = object:getSquare()
    if not square or not near(character, square:getX(), square:getY()) then return false, "far" end
    local container = object:getContainer()
    local box = Boxes.get(owner, md[Objects.BOX])
    if not container or not box or box.state ~= "placed" then return false, "state" end
    if not (OA.Value and OA.Value.info and OA.Value.accepts) then return false, "noEconomy" end
    local plan = Things.sealable(container)
    local entries = Boxes.group(plan.infos)
    -- Records first, then the things: a failure leaves the items where they were.
    local ok, why = Boxes.seal(owner, box.id, entries, plan.weight)
    if not ok then return false, why end
    local inventory = character:getInventory()
    for _, item in ipairs(plan.refused) do
        container:DoRemoveItem(item)
        sendRemoveItemFromContainer(container, item)
        inventory:AddItem(item)
        sendAddItemToContainer(inventory, item)
    end
    for _, item in ipairs(plan.taken) do
        container:DoRemoveItem(item)
        sendRemoveItemFromContainer(container, item)
    end
    md[Objects.SEALED] = true
    Things.noteRefusals(owner, plan.refusedInfos)
    Objects.closeFor(object)
    Objects.setSprite(object, Sprites.deliveryBox(true))
    if isServer() then object:transmitCompleteItemToClients() end
    square:playSound(Things.LATCH_SOUND)
    Trade.fireSealed(owner, box.id, entries)
    changed(owner)
    return true, entries, plan
end

-- A box or terminal removed without us (sledgehammer, fire): the record forgets it. Its contents are lost. For an
-- active box the owner is told the way to a new one (the terminal's reissue). `object` may be a plain table with
-- kind, x, y, z, and the box data (from the reconciliation of a box whose square is loaded and empty).
function Things.destroyed(thing)
    local md = thing.getModData and thing:getModData() or thing.data or {}
    local kind = md[Objects.KIND] or thing.kind
    local x, y, z
    if thing.getSquare then
        local square = thing:getSquare()
        if square then x, y, z = square:getX(), square:getY(), square:getZ() end
    else
        x, y, z = thing.x, thing.y, thing.z
    end
    if kind == Objects.TERMINAL then
        if x then unwatch("trade.terminal", x, y, z) end
        return
    end
    if kind ~= Objects.DELIVERY_BOX then return end
    if x then unwatch("trade.box", x, y, z) end
    local owner = ownerOf(md, nil)
    local id = md[Objects.BOX] or thing.box
    if not owner or not id then return end
    local box, wasActive = Boxes.remove(owner, id)
    if not box then return end
    OA.log("box", id, "was destroyed", box.state == "sealed" and "(sealed, its items are lost)" or "")
    if box.state == "sealed" then
        Trade.radio(owner, "IGUI_OA_Trade_Radio_BoxLostSealed")
    elseif wasActive then
        Trade.radio(owner, "IGUI_OA_Trade_Radio_BoxLost")
    end
    if wasActive then OA.Sync.notice(owner.id, "IGUI_OA_Trade_Notice_BoxLost") end
    changed(owner)
end

-- Checks the boxes of a record whose squares are loaded: one gone without a trace (burnt away, say) is destroyed.
-- A box not yet put in the world (pending) or being carried is left alone.
function Things.reconcile(record)
    local gone = {}
    for _, box in ipairs(Boxes.all(record)) do
        if (box.state == "placed" or box.state == "sealed") and not box.pending and box.x then
            local square = Objects.square(box.x, box.y, box.z)
            if square and not Objects.find(square, Objects.DELIVERY_BOX, box.id) then
                gone[#gone + 1] = { kind = Objects.DELIVERY_BOX, x = box.x, y = box.y, z = box.z, box = box.id,
                    data = { [Objects.OWNER] = record.id, [Objects.BOX] = box.id } }
            end
        end
    end
    for _, thing in ipairs(gone) do Things.destroyed(thing) end
    return #gone
end

-- Bulk loading ------------------------------------------------------------------------------------------------------

-- Tiles around a box within which containers are sources, and around it for a vehicle's trunk.
Things.BULK_RADIUS, Things.BULK_VEHICLE_RADIUS = 2, 4
Things.VEHICLE_PARTS = { "TruckBed", "TruckBedOpen", "GloveBox" }

local function ours(object)
    local kind = Objects.kindOf(object)
    return kind == Objects.DELIVERY_BOX or (kind == Objects.CRATE and object:getModData()[Objects.SEALED])
end

-- The containers a box can be loaded from: those of furniture and objects within BULK_RADIUS tiles of it, and the
-- trunk and glove box of a vehicle within BULK_VEHICLE_RADIUS that the character can reach. Other boxes and
-- locked containers are left out.
function Things.bulkSources(character, boxObject)
    local sources, seen = {}, {}
    local square = boxObject:getSquare()
    if not square then return sources end
    local cx, cy, z = square:getX(), square:getY(), square:getZ()
    local c = getCell()
    local reach = Things.BULK_VEHICLE_RADIUS
    for dx = -reach, reach do
        for dy = -reach, reach do
            local sq = c:getGridSquare(cx + dx, cy + dy, z)
            if sq then
                if math.max(math.abs(dx), math.abs(dy)) <= Things.BULK_RADIUS then
                    local objects = sq:getObjects()
                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)
                        if object ~= boxObject and not ours(object)
                            and not (instanceof(object, "IsoThumpable") and object:isLockedToCharacter(character)) then
                            for k = 0, object:getContainerCount() - 1 do
                                local container = object:getContainerByIndex(k)
                                if container and not seen[container] then
                                    seen[container] = true
                                    sources[#sources + 1] = container
                                end
                            end
                        end
                    end
                end
                local vehicle = sq:getVehicleContainer()
                if vehicle and not seen[vehicle] then
                    seen[vehicle] = true
                    for _, id in ipairs(Things.VEHICLE_PARTS) do
                        local part = vehicle:getPartById(id)
                        local container = part and part:getItemContainer()
                        if container and vehicle:canAccessContainer(part:getIndex(), character) then
                            sources[#sources + 1] = container
                        end
                    end
                end
            end
        end
    end
    return sources
end

-- What a bulk load would move: { moves = { { item, from } }, count, weight }, the items the team takes, container by
-- container, as many as the box has room for (an item that does not fit is skipped, a lighter one may).
function Things.bulkPlan(character, boxObject)
    local moves, weight = {}, 0
    local box = boxObject:getContainer()
    if not box or not (OA.Value and OA.Value.info and OA.Value.accepts) then return { moves = moves, count = 0, weight = 0 } end
    local room = box:getCapacity() - box:getContentsWeight()
    for _, from in ipairs(Things.bulkSources(character, boxObject)) do
        local items = from:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            local w = item:getUnequippedWeight()
            if weight + w <= room then
                local ok, info = pcall(OA.Value.info, item)
                if ok and info and OA.Value.accepts(info) == true then
                    moves[#moves + 1] = { item = item, from = from }
                    weight = weight + w
                end
            end
        end
    end
    return { moves = moves, count = #moves, weight = weight }
end

-- Moves the items of a plan into the box, in one go: no transfer action per item. Returns how many moved.
function Things.bulkLoad(character, boxObject)
    if Objects.kindOf(boxObject) ~= Objects.DELIVERY_BOX or boxObject:getModData()[Objects.SEALED] then return 0 end
    local square = boxObject:getSquare()
    if not square or not near(character, square:getX(), square:getY()) then return 0 end
    local box = Objects.setupBoxOf(boxObject)
    if not box then return 0 end
    local plan = Things.bulkPlan(character, boxObject)
    local parts = {}
    for _, move in ipairs(plan.moves) do
        local from, item = move.from, move.item
        if from:contains(item) then
            from:DoRemoveItem(item)
            sendRemoveItemFromContainer(from, item)
            box:AddItem(item)
            sendAddItemToContainer(box, item)
            local part = from:getVehiclePart()
            if part then parts[part] = from end
        end
    end
    for part, from in pairs(parts) do part:setContainerContentAmount(from:getCapacityWeight()) end
    box:setDrawDirty(true)
    return plan.count
end

-- The supply crate ---------------------------------------------------------------------------------------------

-- Puts a crate down on a square: sealed, with the cargo (a list of item specs) kept in its modData until it is opened,
-- or an empty open crate when there is no cargo. `parachute` shows the falling tile first.
function Things.makeCrate(square, cargo, parachute)
    local sealed = cargo ~= nil
    local sprite = parachute and Sprites.PARACHUTE_CRATE or Sprites.supplyCrate(not sealed)
    local data = {}
    if sealed then
        data[Objects.SEALED] = true
        data[Objects.CARGO] = cargo
    end
    local object = Objects.create(square, sprite, Objects.CRATE, data)
    if sealed then Objects.closeFor(object) else Things.crateContainer(object) end
    return object
end

-- The crate's container (made when missing). Things are only taken out of it: the game does not keep a container's
-- accept function, so the loot window sets it again each time it shows the crate (client Trade/Crate.lua).
function Things.crateContainer(object)
    local container = object:getContainer()
    if not container then
        container = ItemContainer.new(Objects.CRATE_CONTAINER, object:getSquare(), object)
        object:setContainer(container)
    end
    -- (unexplored, the game would roll loot into it when it is first opened)
    if not container:isExplored() then container:setExplored(true) end
    Objects.nameContainer(container, Objects.CRATE_CONTAINER)
    container:setCapacity(100)
    if container:getAcceptItemFunction() ~= Objects.TAKE_ONLY then container:setAcceptItemFunction(Objects.TAKE_ONLY) end
    return container
end

-- The tile of a crate that has landed, still sealed: after the parachute.
function Things.land(object)
    Objects.setSprite(object, Sprites.supplyCrate(false))
end

-- Opens a sealed crate: the cargo becomes real items in a normal container, and the tile shows it open.
function Things.unseal(character, object)
    local md = object:getModData()
    if Objects.kindOf(object) ~= Objects.CRATE or not md[Objects.SEALED] then return false, "state" end
    local square = object:getSquare()
    if not square or not near(character, square:getX(), square:getY()) then return false, "far" end
    local cargo = md[Objects.CARGO] or {}
    local container = Things.crateContainer(object)
    Objects.fill(container, cargo)
    md[Objects.CARGO] = nil
    md[Objects.SEALED] = nil
    Objects.setSprite(object, Sprites.supplyCrate(true))
    if isServer() then object:transmitCompleteItemToClients() end
    square:playSound(Things.LATCH_SOUND)
    return true
end

-- Whether an opened crate is empty (and so breaks).
function Things.crateEmpty(object)
    local md = object:getModData()
    if md[Objects.SEALED] then return false end
    local container = object:getContainer()
    return container == nil or container:isEmpty()
end

-- What an emptied crate leaves on the floor, and the sound it breaks with.
Things.CRATE_MATERIALS = { { "Base.Plank", 3 }, { "Base.Nails", 6 } }
Things.BREAK_SOUND = "BreakFurniture"

-- An opened crate that is empty breaks: it is taken away and its wood and nails fall where it stood. Returns whether
-- it broke.
function Things.breakEmptyCrate(object)
    if Objects.kindOf(object) ~= Objects.CRATE or not Things.crateEmpty(object) then return false end
    local square = object:getSquare()
    if not square then return false end
    Objects.remove(object)
    for _, m in ipairs(Things.CRATE_MATERIALS) do
        for _ = 1, m[2] do
            local item = instanceItem(m[1])
            if item then square:AddWorldInventoryItem(item, 0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), 0) end
        end
    end
    square:playSound(Things.BREAK_SOUND)
    return true
end

return Things
