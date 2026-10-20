-- A bag's room with the materials nodes (100% lighter: a plank counts half), played as the player meets it: a worn
-- backpack filled with planks past its real-weight room, one more put in by the game's transfer; the bag dropped on the
-- floor (the same room used, nothing falls out, the floor holds it), picked up and worn again (the same); the bag put
-- into a crate (the crate counts it by its real weight); the nodes taken away (the bag over its room: nothing more
-- goes in, nothing falls out). The inventory window's numbers are getCapacityWeight's (ISInventoryPage).
-- Setup: single player, PZ Extension API on, a free square 2 east. CHANGES THE SAVE: empties the inventory (all but
-- what is worn) and the record's upgrades. Lines are tagged "[bagroom]".
RUN("p3_lib.lua")
local OA = OperationAcorn
local Effects = OA.Upgrades.Effects
local t = STEPS("bagroom")
local record, player, u = P3T.record()
local inv = player:getInventory()
local ghost, unlimited = player:isGhostMode(), player:isUnlimitedCarry()

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

local bag, bagInv, cap, w, n, used, sq, worldItem, crate
local steps = {
    { 0, function()
        player:setGhostMode(false)
        player:setUnlimitedCarry(false)
        emptyInventory()
        setRanks({ "materials", "materials", "materials", "materialsPlus", "materialsPlus" })
        bag = inv:AddItem("Base.Bag_ALICEpack")
        ISInventoryPaneContextMenu.onWearItems({ bag }, player:getPlayerNum())
    end },
    { 3000, function()
        t.check("the bag is worn", player:isEquippedClothing(bag))
        bagInv = bag:getInventory()
        cap = bagInv:getEffectiveCapacity(player)
        w = instanceItem("Base.Plank"):getActualWeight()
        t.say("info bag", bag:getFullType(), "capacity", cap, "plank weight", w, "category", instanceItem("Base.Plank"):getDisplayCategory())
        n = 0
        while n < 200 do
            local plank = instanceItem("Base.Plank")
            if not bagInv:hasRoomFor(player, plank) then break end
            bagInv:AddItem(plank)
            n = n + 1
        end
        t.check("planks fit by half their weight", n == math.floor(cap / (w / 2) + 0.001), n .. " (real room " .. math.floor(cap / w) .. ")")
        t.check("the window counts them half", near(bagInv:getCapacityWeight(), n * w / 2), room(bagInv))
        t.check("past what fits by real weight", n * w > cap, n * w)
        -- one out to the main inventory, then the game's own transfer puts it back
        local one = bagInv:getFirstType("Base.Plank")
        bagInv:Remove(one)
        inv:AddItem(one)
        ISTimedActionQueue.add(ISInventoryTransferAction:new(player, one, inv, bagInv))
    end },
    { 4000, function()
        t.check("the transfer put the plank back in", planks(bagInv) == n, planks(bagInv))
        t.check("a plank more does not fit", not bagInv:hasRoomFor(player, instanceItem("Base.Plank")))
        used = bagInv:getCapacityWeight()
        t.say("info worn: bag", room(bagInv), "load", player:getInventoryWeight(), "max", player:getMaxWeight())
        ISInventoryPaneContextMenu.onDropItems({ bag }, player:getPlayerNum())
    end },
    { 4000, function()
        sq = player:getCurrentSquare()
        t.check("the bag is on the floor", bag:getWorldItem() ~= nil, tostring(bag:getContainer()))
        worldItem = bag:getWorldItem()
        t.check("on the floor its room is the same", near(bagInv:getCapacityWeight(), used), room(bagInv))
        t.check("nothing fell out", planks(bagInv) == n, planks(bagInv))
        t.check("still a plank more does not fit", not bagInv:hasRoomFor(player, instanceItem("Base.Plank")))
        t.say("info the bag's own weight on the floor", bag:getUnequippedWeight(), "real contents", bagInv:getContentsWeight())
        if worldItem then ISTimedActionQueue.add(ISGrabItemAction:new(player, worldItem, 50)) end
    end },
    { 4000, function()
        t.check("picked up", bag:getContainer() == inv, tostring(bag:getContainer()))
        t.check("carried in hand its room is the same", near(bagInv:getCapacityWeight(), used), room(bagInv))
        ISInventoryPaneContextMenu.onWearItems({ bag }, player:getPlayerNum())
    end },
    { 4000, function()
        t.check("worn again", player:isEquippedClothing(bag))
        t.check("worn again its room is the same", near(bagInv:getCapacityWeight(), used), room(bagInv))
        t.check("nothing fell out", planks(bagInv) == n, planks(bagInv))
        t.say("info worn again: load", player:getInventoryWeight())
        -- a crate 2 east: the bag goes in by its real weight
        local csq = getCell():getGridSquare(math.floor(player:getX()) + 2, math.floor(player:getY()), math.floor(player:getZ()))
        crate = IsoObject.new(csq, "carpentry_01_16", "Crate")
        csq:AddSpecialObject(crate)
        crate:createContainersFromSpriteProperties()
        local c = crate:getContainer()
        player:removeWornItem(bag)
        inv:Remove(bag)
        c:AddItem(bag)
        t.check("the crate counts the bag by its real weight", near(c:getCapacityWeight(), bag:getActualWeight() + bagInv:getContentsWeight(), 0.1),
            room(c) .. " vs real " .. (bag:getActualWeight() + bagInv:getContentsWeight()))
        t.check("in the crate the bag's room is the same", near(bagInv:getCapacityWeight(), used), room(bagInv))
        c:Remove(bag)
        csq:transmitRemoveItemFromSquare(crate)
        inv:AddItem(bag)
        ISInventoryPaneContextMenu.onWearItems({ bag }, player:getPlayerNum())
    end },
    { 3000, function()
        t.check("worn once more", player:isEquippedClothing(bag))
        -- the nodes taken away: over its room, nothing more, nothing out
        setRanks({})
        t.check("without the nodes it is over its room", bagInv:getCapacityWeight() > cap, room(bagInv))
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
}
t.run(steps)
