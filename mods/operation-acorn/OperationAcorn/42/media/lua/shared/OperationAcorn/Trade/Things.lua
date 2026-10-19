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
require "PZUIKit/Heavy"
require "OperationAcorn/Sounds"
local OA = OperationAcorn
local Trade, Sprites, Chunks = OA.Trade, OA.Sprites, OA.Chunks
local Boxes, Objects = Trade.Boxes, Trade.Objects
local Things = {}
Trade.Things = Things

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

-- Puts a terminal item down on a square, facing S, E, N or W: the assembled one, or the field terminal.
function Things.placeTerminal(character, square, facing, item, record)
    local ok, why = Objects.free(square)
    if not ok then return false, why end
    local upgraded = item ~= nil and item:getFullType() == Objects.ITEMS.field
    local object = Objects.create(square, Objects.terminalSprite(facing, Objects.powered(square), upgraded),
        Objects.TERMINAL, { OA_Facing = facing, [Objects.UPGRADED] = upgraded or nil })
    Objects.consume(character, item)
    watch("trade.terminal", square:getX(), square:getY(), square:getZ())
    Objects.showTerminal(object)
    if record then
        Things.terminalPlaced(record, square)
        if upgraded then Things.lineOpened(record) end
    end
    return true, object
end

-- The first field terminal a record puts down registers its line with the team (DESIGN-terminal 3.2, 12): special
-- requests come to it from then on, even if that terminal is lost. A gold title says what has opened.
function Things.lineOpened(record)
    local heli = Trade.heli(record)
    if heli.line then return false end
    heli.line = true
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_LineOpened", sub = "IGUI_OA_Title_LineOpenedSub", style = "unveil",
        tone = "gold" })
    return true
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
    PZUIKit.Heavy.give(character, upgraded and Objects.ITEMS.field or Objects.ITEMS.terminal)
    return true
end

-- The delivery box ----------------------------------------------------------------------------------------------

-- The record that owns a box object or item: by the owner id it carries, else the character's.
local function ownerOf(modData, fallback)
    local id = modData and modData[Objects.OWNER]
    return (id and OA.Store.player(id)) or fallback
end

-- Whose a box (its object's or item's mod data) is to a character: "own" (the character's record, or none named: a box
-- made by hand), "abandoned" (its owner's character died) or "other" (another living one's). Only an own box is
-- loaded, sealed, taken up or put down; an abandoned one is dismantled; another's is left alone.
function Things.boxSide(character, md)
    local id = md and md[Objects.OWNER]
    if not id or id == OA.Store.idOf(character) then return "own" end
    local owner = OA.Store.player(id)
    if not owner then return "own" end
    return OA.Store.alive(owner) and "other" or "abandoned"
end

-- Puts a delivery box item down. A box the record does not know (made by hand, say) is entered as a previous box
-- unless the record has no active box.
function Things.placeBox(character, record, square, item)
    if Things.boxSide(character, item:getModData()) ~= "own" then return false, "notOwner" end
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
    if Things.boxSide(character, md) ~= "own" then return false, "notOwner" end
    local owner = ownerOf(md, nil)
    local container = object:getContainer()
    if container and not container:isEmpty() then return false, "notEmpty" end
    local square = object:getSquare()
    if not square then return false end
    local boxId = md[Objects.BOX]
    if owner and boxId then Boxes.carry(owner, boxId) end
    unwatch("trade.box", square:getX(), square:getY(), square:getZ())
    Objects.remove(object)
    PZUIKit.Heavy.give(character, Objects.ITEMS.box, { OA_Box = boxId, OA_Owner = owner and owner.id or nil })
    changed(owner)
    return true
end

-- The items of a box's container as a plain list.
local function itemsOf(container)
    local list = {}
    -- oa-scan: ok (a delivery box's contents: asked when the player seals it, and by the estimate panel under the box's
    -- signature)
    local items = container:getItems()
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    return list
end
Things.itemsOf = itemsOf

-- What would be sealed of a container's items: { taken = { item }, infos = { info }, refused = { item },
-- refusedInfos = { info of each refused item (nil when it could not be read) }, refusedWhys = { the translation key
-- of why each is refused (nil when none is given) }, weight }. An item the team does not take (the manual left in,
-- say) is `refused`: it goes back to the character.
-- `memo` (optional: a table the caller keeps and clears, by item) holds { info, ok, why } of the items read before;
-- the estimate panel gives one, since it asks again at every change of the box. A sealing reads fresh (no memo).
-- A bag is never memoised: what is put in it or taken out of it changes whether the team takes it.
function Things.sealable(container, memo)
    local taken, infos, refused, weight = {}, {}, {}, 0
    local refusedInfos, refusedWhys = {}, {}
    for _, item in ipairs(itemsOf(container)) do
        local read = memo and memo[item]
        if not read then
            local ok, info = pcall(OA.Value.info, item)
            local accepted, why = false, nil
            if ok and info then accepted, why = OA.Value.accepts(info) end
            read = { info = ok and info or nil, ok = accepted == true, why = why }
            -- (`filled` is only given for a bag)
            if memo and ok and info and info.filled == nil then memo[item] = read end
        end
        if read.ok then
            taken[#taken + 1] = item
            infos[#infos + 1] = read.info
            weight = weight + item:getActualWeight()
        else
            refused[#refused + 1] = item
            refusedInfos[#refused] = read.info
            refusedWhys[#refused] = read.why
        end
    end
    return { taken = taken, infos = infos, refused = refused, refusedInfos = refusedInfos, refusedWhys = refusedWhys,
        weight = weight }
end

-- Seals a box: records its items by kind and count in the save, deletes them, shows the sealed tile and closes the
-- container for good. Returns true, or false and a reason.
function Things.seal(character, record, object)
    local md = object:getModData()
    if Objects.kindOf(object) ~= Objects.DELIVERY_BOX or md[Objects.SEALED] then return false, "state" end
    -- what is in another's box is not this character's sale, and an abandoned box no longer reaches the team
    if Things.boxSide(character, md) ~= "own" then return false, "notOwner" end
    local owner = ownerOf(md, record)
    local square = object:getSquare()
    if not square or not near(character, square:getX(), square:getY()) then return false, "far" end
    local container = object:getContainer()
    local box = Boxes.get(owner, md[Objects.BOX])
    if not container or not box or box.state ~= "placed" then return false, "state" end
    if not (OA.Value and OA.Value.info and OA.Value.accepts) then return false, "noEconomy" end
    local plan = Things.sealable(container)
    -- a box with nothing the team takes would go up empty and come back as it went
    if #plan.taken == 0 then return false, "nothing" end
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
    Objects.closeFor(object)
    Objects.setSprite(object, Sprites.deliveryBox(true))
    if isServer() then object:transmitCompleteItemToClients() end
    PZUIKit.Sound.at("oa.box.latch", square)
    Trade.fireSealed(owner, box.id, entries)
    changed(owner)
    return true, entries, plan
end

-- Dismantles an abandoned box (sealed or not): it is taken out of the world, what an open one holds is left on its
-- square, and its record forgets it. Returns true, or false and a reason.
function Things.dismantleBox(character, object)
    if Objects.kindOf(object) ~= Objects.DELIVERY_BOX then return false, "state" end
    local md = object:getModData()
    if Things.boxSide(character, md) ~= "abandoned" then return false, "notOwner" end
    local square = object:getSquare()
    if not square or not near(character, square:getX(), square:getY()) then return false, "far" end
    local container = object:getContainer()
    if container and not md[Objects.SEALED] then
        for _, item in ipairs(itemsOf(container)) do
            container:DoRemoveItem(item)
            sendRemoveItemFromContainer(container, item)
            square:AddWorldInventoryItem(item, OA.randomFloat(0.1, 0.9), OA.randomFloat(0.1, 0.9), 0)
        end
    end
    unwatch("trade.box", square:getX(), square:getY(), square:getZ())
    Objects.remove(object)
    local owner = ownerOf(md, nil)
    local id = md[Objects.BOX]
    if owner and id then Boxes.remove(owner, id) end
    if owner then changed(owner) end
    return true
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
    if box.state == "sealed" or wasActive then
        OA.Sync.title(owner.id, { key = "IGUI_OA_Title_BoxLost",
            sub = box.state == "sealed" and "IGUI_OA_Title_BoxLostSealedSub" or "IGUI_OA_Title_BoxLostSub",
            style = "dust", tone = "red" })
    end
    changed(owner)
end

-- Checks the boxes of a record whose squares are loaded: one gone without a trace (burnt away, say) is destroyed.
-- A box that is an item (carried, or in its crate) is left alone.
function Things.reconcile(record)
    local gone = {}
    local boxes, where = {}, {}
    for _, box in ipairs(Boxes.all(record)) do
        if (box.state == "placed" or box.state == "sealed") and box.x then
            boxes[#boxes + 1] = box
            local n = #where
            where[n + 1], where[n + 2], where[n + 3], where[n + 4] = box.x, box.y, box.z, box.id
        end
    end
    if #boxes == 0 then return 0 end
    -- (for each: the object with its id, false when its square is loaded and none is there, "unloaded" when it is not)
    local found = OA.api().objects.byData(Objects.BOX, where)
    for i, box in ipairs(boxes) do
        if found[i] == false then
            gone[#gone + 1] = { kind = Objects.DELIVERY_BOX, x = box.x, y = box.y, z = box.z, box = box.id,
                data = { [Objects.OWNER] = record.id, [Objects.BOX] = box.id } }
        end
    end
    for _, thing in ipairs(gone) do Things.destroyed(thing) end
    return #gone
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

-- Opens a sealed crate: the cargo becomes real items in a normal container, and the tile shows it open. The other
-- parts hear what it held (Trade.onOpened) when the opener's record is given.
function Things.unseal(character, object, record)
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
    PZUIKit.Sound.at("oa.box.latch", square)
    if record and Trade.fireOpened then Trade.fireOpened(record, cargo) end
    return true
end

-- Whether an opened crate is empty (and so breaks).
function Things.crateEmpty(object)
    local md = object:getModData()
    if md[Objects.SEALED] then return false end
    local container = object:getContainer()
    return container == nil or container:isEmpty()
end

-- What an emptied crate leaves on the floor: a plank, a sign of the crate rather than a reward (it breaks after every
-- flight; three planks and six nails each time were a supply of their own, the nails above all).
Things.CRATE_MATERIALS = { { "Base.Plank", 1 } }

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
    PZUIKit.Sound.at("oa.box.break", square)
    return true
end

return Things
