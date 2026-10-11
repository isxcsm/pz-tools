-- A building's container counts as searched once the player's loot window has shown it (OA.Buildings.mark). The
-- window asks the game about each container it lists (ISInventoryPage:checkExplored, which rolls the loot of one not
-- rolled yet); the mark is set there, once an object, so nothing runs that the window does not already do.
require "ISUI/ISInventoryPage"
require "OperationAcorn/Economy/Buildings"
local OA = OperationAcorn

local checkExplored = ISInventoryPage.checkExplored
function ISInventoryPage:checkExplored(container, playerObj, ...)
    checkExplored(self, container, playerObj, ...)
    if container and playerObj and playerObj:isLocalPlayer() then OA.Buildings.mark(container) end
end
