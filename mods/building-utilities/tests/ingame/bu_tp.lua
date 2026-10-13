-- Moves the player beside the test panel (ModData BUTEST), for the checks that put things down near the player.
local BU = BuildingUtilities
local panel = BU.Store.get(ModData.getOrCreate("BUTEST").panel)
print("[tp] test panel", panel and panel.id, panel and panel.x, panel and panel.y, panel and panel.z)
if not panel then return end
local p = getPlayer()
local x, y = panel.x + 1, panel.y + 1
p:setX(x) p:setY(y) p:setZ(panel.z)
p:setLastX(x) p:setLastY(y) p:setLastZ(panel.z)
print("[tp] moved to", x, y)
