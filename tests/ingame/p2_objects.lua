-- P2: items, the recipe, and the three objects in the world: the terminal, the delivery box (placing, container,
-- accept rule, capacity, sealing, destroying) and the supply crate (sealed, opening). Needs one character with a
-- record, open ground nearby (a clear patch east or south). Makes objects: call P2_CLEAN() after.
-- Prints "[p2obj]" lines.
RUN("p2_lib.lua")
local OA = OperationAcorn
local T = OA.Trade
local Objects, Things, Boxes = T.Objects, T.Things, T.Boxes
local say = P2T.say("p2obj")
local record, player = P2T.record()
P2T.check(say, "the character has a record", record ~= nil)
if not record then return end

-- Items and the recipe.
for _, type in ipairs({ "CommTerminal", "DeliveryBox", "SupplyCrate", "TerminalManual", "SupplyManifest" }) do
    local item = instanceItem("OperationAcorn." .. type)
    P2T.check(say, "item " .. type, item ~= nil)
    P2T.check(say, "name " .. type, item and item:getDisplayName() ~= "OperationAcorn." .. type, item and item:getDisplayName())
end
P2T.check(say, "recipe exists", getScriptManager():getCraftRecipe("OperationAcorn.AssembleCommTerminal") ~= nil)

-- Terminal.
local square = P2T.spot()
P2T.check(say, "a square to work on", square ~= nil)
if not square then return end
local terminalItem = player:getInventory():AddItem("OperationAcorn.CommTerminal")
local ok, terminal = Things.placeTerminal(player, square, "S", terminalItem)
P2T.check(say, "terminal placed", ok and terminal ~= nil)
if ok then
    P2T.keep(terminal)
    say("terminal sprite", terminal:getSpriteName(), "powered", tostring(Objects.powered(square)))
    P2T.check(say, "terminal has no container", terminal:getContainer() == nil)
    P2T.check(say, "terminal is found by kind", Objects.find(square, Objects.TERMINAL) == terminal)
    P2T.check(say, "an occupied square is not free", Objects.free(square) == false)
end

-- Delivery box.
local spot = Objects.findClear(math.floor(player:getX()) + 3, math.floor(player:getY()), 25)
P2T.check(say, "a clear square for the box", spot ~= nil)
if not spot then return end
local boxItem = player:getInventory():AddItem("OperationAcorn.DeliveryBox")
local ok2, object, box = Things.placeBox(player, record, spot, boxItem)
P2T.check(say, "box placed", ok2 and object ~= nil and box ~= nil)
if not ok2 then return end
P2T.keep(object)
local container = object:getContainer()
P2T.check(say, "box has a container", container ~= nil)
if container then
    say("capacity", container:getCapacity(), "type", container:getType(), "wanted", Objects.capacityFor(record))
    -- the raw capacity within the game's cap, the rest in OA_Capacity for the API to add
    local extra = object:getModData().OA_Capacity
    P2T.check(say, "raw capacity within the game's cap, the rest for the API",
        container:getCapacity() <= 100 and container:getCapacity() + (extra or 0) == Objects.capacityFor(record),
        container:getCapacity() .. " + " .. tostring(extra))
    local rag = instanceItem("Base.RippedSheets")
    local bullet = instanceItem("Base.Bullets9mm")
    P2T.check(say, "accepts cloth scraps", container:isItemAllowed(rag))
    P2T.check(say, "refuses ammunition", not container:isItemAllowed(bullet))
    container:AddItem(rag)
    container:AddItem(bullet)
    local plan = Things.sealable(container)
    P2T.check(say, "the sealable plan takes the cloth and refuses the ammunition", #plan.taken == 1 and #plan.refused == 1,
        #plan.taken .. "/" .. #plan.refused)
    local sealed = Things.seal(player, record, object)
    P2T.check(say, "box sealed", sealed == true)
    P2T.check(say, "sealed tile", object:getSpriteName() == OA.Sprites.deliveryBox(true), object:getSpriteName())
    P2T.check(say, "sealed box has no way in", object:getContainer() == nil)
    P2T.check(say, "record says sealed", Boxes.get(record, box.id).state == "sealed")
    P2T.check(say, "the refused ammunition came back", player:getInventory():containsType("Bullets9mm"))
    -- Destroyed by something else: the record forgets it.
    Things.destroyed(object)
    P2T.check(say, "destroyed box is gone from the record", Boxes.get(record, box.id) == nil)
end

-- Supply crate.
local crateSquare = Objects.findBeside(spot:getX(), spot:getY(), 0, 6)
if crateSquare then
    local crate = P2T.keep(Things.makeCrate(crateSquare, { { type = "Base.Battery", count = 2 } }, false))
    P2T.check(say, "sealed crate has no container", crate:getContainer() == nil)
    local opened = Things.unseal(player, crate)
    P2T.check(say, "crate opens", opened == true)
    local c = crate:getContainer()
    P2T.check(say, "opened crate holds the cargo", c ~= nil and c:getItems():size() == 2)
    P2T.check(say, "not empty so it cannot be carried", Things.crateEmpty(crate) == false)
end
say("done; call P2_CLEAN() to remove what was made")
