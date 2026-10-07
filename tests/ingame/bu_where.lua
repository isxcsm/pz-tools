-- Each unit's square and where it is on the game screen; with BUOUT set, the player moves to a free outside square
-- next to the first solar panel.
local BU = BuildingUtilities
local p = getPlayer()
local z = getCore():getZoom(0)
for _, unit in ipairs(BU.Store.unitList()) do
    local sx = (IsoUtils.XToScreen(unit.x + 0.5, unit.y + 0.5, unit.z, 0) - IsoCamera.getOffX()) / z
    local sy = (IsoUtils.YToScreen(unit.x + 0.5, unit.y + 0.5, unit.z, 0) - IsoCamera.getOffY()) / z
    print("[buwhere]", unit.id, unit.kind, unit.x, unit.y, unit.z, unit.sprite, "screen", math.floor(sx), math.floor(sy),
        "object", tostring(BU.Units.object(unit) ~= nil))
end
if BUOUT then
    local solar = BU.Store.unitList("solar")[1]
    for _, d in ipairs({ { 1, 1 }, { 0, 2 }, { 2, 0 }, { -1, 1 }, { 1, -1 }, { 0, -2 }, { -2, 0 } }) do
        local sq = getCell():getGridSquare(solar.x + d[1], solar.y + d[2], 0)
        if sq and sq:isOutside() and sq:isFree(false) then
            p:setX(sq:getX() + 0.5); p:setY(sq:getY() + 0.5); p:setLastX(sq:getX() + 0.5); p:setLastY(sq:getY() + 0.5)
            print("[buwhere] moved to", sq:getX(), sq:getY())
            break
        end
    end
end
