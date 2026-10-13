-- Reconditioning in game: a worn sports battery in the player's inventory, the tools for it, Electricity 4 for now
-- (BUREVIVE keeps the level it was), then the inventory's context menu for the battery opened as a right click
-- would. With BUREVIVE_DONE the level goes back. "[burevive]" lines.
local BU = BuildingUtilities
local p = getPlayer()
if BUREVIVE_DONE then
    if BUREVIVE then p:getXp():setXPToLevel(Perks.Electricity, BUREVIVE.level) p:setPerkLevelDebug(Perks.Electricity, BUREVIVE.level) end
    print("[burevive] level back to", p:getPerkLevel(Perks.Electricity))
    BUREVIVE, BUREVIVE_DONE = nil, nil
    return
end
BUREVIVE = BUREVIVE or { level = p:getPerkLevel(Perks.Electricity) }
p:setPerkLevelDebug(Perks.Electricity, 4)
local inv = p:getInventory()
local battery = inv:AddItem("Base.CarBattery3")
battery:setCondition(30)
battery:setUsedDelta(0.4)
if not inv:getFirstTypeRecurse("Base.BakingSoda") then inv:AddItem("Base.BakingSoda") end
if not inv:getFirstTagRecurse(ItemTag.SCREWDRIVER) then inv:AddItem("Base.Screwdriver") end
print("[burevive] level", p:getPerkLevel(Perks.Electricity), "can", tostring(BU.Rack.canRevive(p, battery)))
ISInventoryPaneContextMenu.createMenu(0, true, { battery }, 900, 400)
