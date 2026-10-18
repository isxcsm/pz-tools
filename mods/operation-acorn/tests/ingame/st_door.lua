-- The locked doors within 6 squares of ST_AT = { x, y, z } listed; with ST_OPEN, the nearest one opened as the player
-- does (walked to, the game's open action: a key carried unlocks it).
local x0, y0, z0 = ST_AT[1], ST_AT[2], ST_AT[3] or 0
local best, bestD
for dy = -6, 6 do
    for dx = -6, 6 do
        local sq = getCell():getGridSquare(x0 + dx, y0 + dy, z0)
        local objs = sq and sq:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local o = objs:get(i)
            if instanceof(o, "IsoDoor") then
                ST.say("DOOR", sq:getX(), sq:getY(), "locked", tostring(o:isLocked()), "byKey", tostring(o:isLockedByKey()),
                    "keyId", o:getKeyId(), "open", tostring(o:IsOpen()))
                if o:isLockedByKey() and (not bestD or dx * dx + dy * dy < bestD) then best, bestD = o, dx * dx + dy * dy end
            end
        end
    end
end
if ST_OPEN and best then
    local p = getPlayer()
    ISTimedActionQueue.clear(p)
    if luautils.walkAdjWindowOrDoor(p, best:getSquare(), best) then
        ISTimedActionQueue.add(ISOpenCloseDoor:new(p, best))
        ST.say("OPENING", best:getSquare():getX(), best:getSquare():getY())
    end
end
