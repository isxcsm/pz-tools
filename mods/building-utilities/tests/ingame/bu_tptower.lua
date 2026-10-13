-- Moves the player beside the tower panel (ModData BUTOWER), for bu_floors.lua and bu_nearest.lua.
local main = BuildingUtilities.Store.get(ModData.getOrCreate("BUTOWER").panel)
if not main then print("[tp] no tower panel") return end
local p = getPlayer()
local x, y = main.x + 0.5, main.y + 1.5
p:setX(x) p:setY(y) p:setZ(main.z)
p:setLastX(x) p:setLastY(y) p:setLastZ(main.z)
print("[tp] tower", main.id, x, y)
