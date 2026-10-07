-- A utility panel in the nearest building to the player, for the batch checks; its id in ModData BUTEST.
local BU = BuildingUtilities
local p = getPlayer()
local cell = getCell()
local best, bestD
for dx = -30, 30 do
    for dy = -30, 30 do
        local sq = cell:getGridSquare(p:getX() + dx, p:getY() + dy, 0)
        if sq and sq:getRoom() and sq:isFree(false) and BU.Panels.canInstall(sq) then
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then best, bestD = sq, d end
        end
    end
end
if not best then print("[busetup] no building square near"); return end
local panel = BU.Changes.install(best, BU.PANEL_SPRITES[1])
ModData.getOrCreate("BUTEST").panel = panel.id
print("[busetup] panel", panel.id, panel.x, panel.y, panel.z, "devices", #BU.Panels.devices(panel, "power"))
