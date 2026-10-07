-- After bu_take.lua: where the battery is, its charge, and the rack's records.
local BU = BuildingUtilities
local rack = BU.Store.unitList("rack")[1]
local item = BUTAKEN
print("[butake] in player", tostring(getPlayer():getInventory():contains(item)), "charge", string.format("%.3f", item:getCurrentUsesFloat()),
    "condition", item:getCondition(), "rack records", #rack.batteries, "items", BU.Units.object(rack):getContainer():getItems():size())
