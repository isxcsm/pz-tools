-- Takes the shack's box down with the mod's own action, then checks the item came back and the main panel lost its child.
local BU = BuildingUtilities
local player = getPlayer()
local child = BU.Store.get(ModData.getOrCreate("BUTEST").child)
local object = BU.Panels.object(child)
print("[butake] child", child.id, "object", object ~= nil, "items before", player:getInventory():getCountTypeRecurse(BU.PANEL_ITEM))
if luautils.walkAdj(player, object:getSquare()) then ISTimedActionQueue.add(ISBURemovePanel:new(player, child)) end
local ticks = 0
local function tick()
    ticks = ticks + 1
    if BU.Store.get(child.id) and ticks < 3000 then return end
    Events.OnTick.Remove(tick)
    local square = getCell():getGridSquare(child.x, child.y, child.z)
    local left = 0
    for i = 0, square:getObjects():size() - 1 do
        if square:getObjects():get(i):getModData()[BU.Panels.MODDATA] then left = left + 1 end
    end
    print("[butake] gone", BU.Store.get(child.id) == nil, "object left", left, "items after",
        player:getInventory():getCountTypeRecurse(BU.PANEL_ITEM), "network", BU.Networks.state(child, "power") == nil,
        "main children", #BU.Store.children(ModData.getOrCreate("BUTEST").main), "ticks", ticks)
end
Events.OnTick.Add(tick)
