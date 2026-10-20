-- The carry nodes' weight as the game reads it everywhere (materials 100% lighter: a plank counts half; furniture 100%),
-- played as the player meets it: a worn backpack filled with planks past its real-weight room, one more put in by the
-- game's transfer; the bag dropped on the floor (the same room used, nothing falls out, the bag itself as carried),
-- picked up and worn again; the bag put into a crate (the crate counts it as carried) and planks straight into the
-- crate; the inventory window's sum of a drag; the run speed a full worn bag costs; a pickup truck's bed full of planks
-- (its container weight and its mass); furniture on the map weighed for the pickup check; a plank's own weight
-- untouched (saves, crafts, swings); the nodes taken away (over the room: nothing more goes in, nothing falls out).
-- The inventory window's numbers are getCapacityWeight's (ISInventoryPage).
-- Setup: single player, PZ Extension API on, free squares 2 east and 5 south. CHANGES THE SAVE: empties the inventory
-- (all but what is worn) and the record's upgrades, and leaves a truck. Lines are tagged "[bagroom]".
RUN("p3_lib.lua")
local OA = OperationAcorn
local Effects = OA.Upgrades.Effects
local Carry = OA.Upgrades.Carry
local t = STEPS("bagroom")
local record, player, u = P3T.record()
local inv = player:getInventory()
local ghost, unlimited = player:isGhostMode(), player:isUnlimitedCarry()
local NODES = { "materials", "materials", "materials", "materialsPlus", "materialsPlus", "furniture", "furniture" }

local function setRanks(ranks)
    P3T.fresh(u)
    for _, id in ipairs(ranks) do
        local ok, why = P3T.buy(u, id)
        if not ok then t.say("could not buy", id, why) end
    end
    Effects.apply(record)
end
local function near(a, b, e) return math.abs(a - b) <= (e or 0.05) end
local function emptyInventory()
    local items = inv:getItems()
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if not player:isEquipped(item) and not player:isEquippedClothing(item) then inv:Remove(item) end
    end
end
local function planks(c)
    local n = 0
    local items = c:getItems()
    for i = 0, items:size() - 1 do if items:get(i):getFullType() == "Base.Plank" then n = n + 1 end end
    return n
end
local function room(c) return string.format("%.2f/%d", c:getCapacityWeight(), c:getEffectiveCapacity(player)) end
local function square(dx, dy)
    return getCell():getGridSquare(math.floor(player:getX()) + dx, math.floor(player:getY()) + dy, math.floor(player:getZ()))
end

local bag, bagInv, cap, n, used, crate, truck, speedFull
t.run({
    { 0, function()
        player:setGhostMode(false)
        player:setUnlimitedCarry(false)
        emptyInventory()
        setRanks(NODES)
        bag = inv:AddItem("Base.Bag_ALICEpack")
        ISInventoryPaneContextMenu.onWearItems({ bag }, player:getPlayerNum())
    end },
    { 3000, function()
        t.check("the bag is worn", player:isEquippedClothing(bag))
        bagInv = bag:getInventory()
        cap = bagInv:getEffectiveCapacity(player)
        local plank = instanceItem("Base.Plank")
        t.say("info bag capacity", cap, "plank: own weight", plank:getActualWeight(), "carried", plank:getUnequippedWeight())
        t.check("a plank is carried at half its weight, its own weight stays", near(plank:getUnequippedWeight(), 1.5) and plank:getActualWeight() == 3
            and plank:getWeight() == 3, plank:getUnequippedWeight())
        speedFull = player:calculateBaseSpeed()
        n = 0
        while n < 200 do
            local one = instanceItem("Base.Plank")
            if not bagInv:hasRoomFor(player, one) then break end
            bagInv:AddItem(one)
            n = n + 1
        end
        t.check("planks fit by half their weight", n == math.floor(cap / 1.5 + 0.001), n .. " (real room " .. math.floor(cap / 3) .. ")")
        t.check("the window counts them half", near(bagInv:getCapacityWeight(), n * 1.5), room(bagInv))
        local one = bagInv:getFirstType("Base.Plank")
        bagInv:Remove(one)
        inv:AddItem(one)
        ISTimedActionQueue.add(ISInventoryTransferAction:new(player, one, inv, bagInv))
    end },
    { 4000, function()
        t.check("the transfer put the plank back in", planks(bagInv) == n, planks(bagInv))
        t.check("a plank more does not fit", not bagInv:hasRoomFor(player, instanceItem("Base.Plank")))
        used = bagInv:getCapacityWeight()
        -- the run speed a full worn bag costs: with the nodes, the bag's contents count half
        local withNodes = player:calculateBaseSpeed()
        setRanks({})
        local without = player:calculateBaseSpeed()
        setRanks(NODES)
        t.say("info base speed: empty bag", speedFull, "full with the nodes", withNodes, "full without", without)
        t.check("the full bag slows less with the nodes", withNodes > without, withNodes .. " vs " .. without)
        t.say("info worn: bag", room(bagInv), "load", player:getInventoryWeight(), "max", player:getMaxWeight())
        ISInventoryPaneContextMenu.onDropItems({ bag }, player:getPlayerNum())
    end },
    { 4000, function()
        t.check("the bag is on the floor", bag:getWorldItem() ~= nil, tostring(bag:getContainer()))
        t.check("on the floor its room is the same", near(bagInv:getCapacityWeight(), used), room(bagInv))
        t.check("nothing fell out", planks(bagInv) == n, planks(bagInv))
        t.check("the bag itself weighs as carried", near(bag:getUnequippedWeight(), bag:getActualWeight() + used, 0.1),
            bag:getUnequippedWeight() .. " (own " .. bag:getActualWeight() .. ")")
        if bag:getWorldItem() then ISTimedActionQueue.add(ISGrabItemAction:new(player, bag:getWorldItem(), 50)) end
    end },
    { 4000, function()
        t.check("picked up", bag:getContainer() == inv, tostring(bag:getContainer()))
        ISInventoryPaneContextMenu.onWearItems({ bag }, player:getPlayerNum())
    end },
    { 4000, function()
        t.check("worn again, the room the same", player:isEquippedClothing(bag) and near(bagInv:getCapacityWeight(), used), room(bagInv))
        -- a crate 2 east: the bag goes in as carried, and planks straight in count half
        local csq = square(2, 0)
        crate = IsoObject.new(csq, "carpentry_01_16", "Crate")
        csq:AddSpecialObject(crate)
        crate:createContainersFromSpriteProperties()
        local c = crate:getContainer()
        player:removeWornItem(bag)
        inv:Remove(bag)
        c:AddItem(bag)
        t.check("the crate counts the bag as carried", near(c:getCapacityWeight(), bag:getUnequippedWeight(), 0.1), room(c))
        c:Remove(bag)
        inv:AddItem(bag)
        local k = 0
        while k < 200 do
            local one = instanceItem("Base.Plank")
            if not c:hasRoomFor(player, one) then break end
            c:AddItem(one)
            k = k + 1
        end
        t.check("planks fit a crate by half their weight", k == math.floor(c:getEffectiveCapacity(player) / 1.5 + 0.001), k .. " in " .. room(c))
        -- what the inventory window adds up for a drag of ten planks
        local sum = 0
        local items = c:getItems()
        for i = 0, 9 do sum = sum + items:get(i):getUnequippedWeight() end
        t.check("a drag's sum counts the planks half", near(sum, 15), sum)
        c:removeAllItems()
        csq:transmitRemoveItemFromSquare(crate)
        ISInventoryPaneContextMenu.onWearItems({ bag }, player:getPlayerNum())
        -- a pickup truck 5 south, its bed full of planks
        truck = addVehicleDebug("Base.PickUpTruck", IsoDirections.E, nil, square(0, 5))
    end },
    { 3000, function()
        local bed = truck and truck:getPartById("TruckBed")
        local bc = bed and bed:getItemContainer()
        t.check("a truck with a bed", bc ~= nil, tostring(truck))
        if not bc then return end
        for _ = 1, 40 do bc:AddItem("Base.Plank") end
        t.check("the bed counts the planks half", near(bc:getCapacityWeight(), 60), room(bc))
        truck:updateTotalMass()
        local withNodes, items = truck:getMass(), truck:getTotalContainerItemWeight()
        setRanks({})
        truck:updateTotalMass()
        local without, itemsRaw = truck:getMass(), truck:getTotalContainerItemWeight()
        setRanks(NODES)
        truck:updateTotalMass()
        t.say("info truck: items", items, "mass", withNodes, "| without the nodes: items", itemsRaw, "mass", without)
        t.check("the truck carries the planks lighter", near(items, 60, 0.5) and near(itemsRaw, 120, 0.5) and withNodes < without,
            withNodes .. " vs " .. without)
        -- furniture on the map: the pickup check and the panel see the weight it will be carried at
        local props = ISMoveableSpriteProps.new(getSprite("furniture_seating_indoor_01_0"))
        local weight = props and props.weight
        t.check("a sofa weighed as carried", type(weight) == "number" and near(Carry.moveableWeight(props), weight / 2), tostring(weight))
        -- the nodes taken away: over its room, nothing more, nothing out
        setRanks({})
        t.check("without the nodes the bag is over its room", bagInv:getCapacityWeight() > cap, room(bagInv))
        t.check("nothing more goes in", not bagInv:hasRoomFor(player, instanceItem("Base.Plank")))
        t.check("nothing fell out", planks(bagInv) == n, planks(bagInv))
    end },
    { 500, function()
        t.check("still nothing fell out after a frame", planks(bagInv) == n, planks(bagInv))
        player:removeWornItem(bag)
        inv:Remove(bag)
        emptyInventory()
        player:setGhostMode(ghost)
        player:setUnlimitedCarry(unlimited)
    end },
})
