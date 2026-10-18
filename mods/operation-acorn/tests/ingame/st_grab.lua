-- The things lying on a square (ST_AT = { x, y, z }, ST_TYPE a part of their type, or all) picked up as the player
-- does: walked to, then the game's grab action for each.
local p = getPlayer()
local sq = getCell():getGridSquare(ST_AT[1], ST_AT[2], ST_AT[3] or 0)
if not sq then ST.say("GRAB: not loaded") return end
local list = sq:getWorldObjects()
local n = 0
ISTimedActionQueue.clear(p)
luautils.walkAdj(p, sq, true)
for i = 0, list:size() - 1 do
    local w = list:get(i)
    local item = w:getItem()
    if not ST_TYPE or string.find(item:getFullType(), ST_TYPE, 1, true) then
        ISTimedActionQueue.add(ISGrabItemAction:new(p, w, 20))
        n = n + 1
    end
end
ST.say("GRAB", n, "at", ST_AT[1], ST_AT[2])
