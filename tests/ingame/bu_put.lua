-- The player's car batteries into the rack the vanilla way (ISInventoryTransferAction, as a drag in the loot window
-- does), and a plank that the rack must refuse. "[buput]" lines; bu_rackdiag shows the result.
local BU = BuildingUtilities
local p = getPlayer()
local rack = BU.Store.unitList("rack")[1]
local box = BU.Units.object(rack):getContainer()
local inv = p:getInventory()
local list = inv:getAllTagRecurse(ItemTag.CAR_BATTERY, ArrayList.new())
for i = 0, list:size() - 1 do
    local item = list:get(i)
    ISTimedActionQueue.add(ISInventoryTransferAction:new(p, item, item:getContainer(), box))
end
local plank = inv:AddItem("Base.Plank")
local action = ISInventoryTransferAction:new(p, plank, inv, box)
print("[buput] batteries", list:size(), "plank allowed", box:isItemAllowed(plank), "plank action valid", action:isValid())
inv:Remove(plank)
