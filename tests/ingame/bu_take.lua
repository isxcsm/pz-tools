-- The rack's first battery back to the player the vanilla way (ISInventoryTransferAction); BUTAKEN keeps it for
-- bu_taken.lua, which prints it once the action is done. "[butake]" lines.
local BU = BuildingUtilities
local p = getPlayer()
local rack = BU.Store.unitList("rack")[1]
local box = BU.Units.object(rack):getContainer()
local item = box:getItems():get(0)
BUTAKEN = item
print("[butake] taking", item:getFullType(), item:getID(), "charge", string.format("%.3f", item:getCurrentUsesFloat()),
    "record", string.format("%.3f", rack.batteries[1].charge))
ISTimedActionQueue.add(ISInventoryTransferAction:new(p, item, box, p:getInventory()))
