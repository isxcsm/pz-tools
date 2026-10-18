-- The things of a type (ST_TYPE, a part of their type) in the containers on a square (ST_AT = { x, y, z }; a fridge's
-- freezer too) taken as the player does: walked to, then the game's transfer into the inventory.
local p = getPlayer()
local sq = getCell():getGridSquare(ST_AT[1], ST_AT[2], ST_AT[3] or 0)
if not sq then ST.say("TAKE: not loaded") return end
ISTimedActionQueue.clear(p)
luautils.walkAdj(p, sq, true)
local n = 0
local objects = sq:getObjects()
for i = 0, objects:size() - 1 do
    local o = objects:get(i)
    for k = 0, o:getContainerCount() - 1 do
        local c = o:getContainerByIndex(k)
        local items = c:getItems()
        for j = 0, items:size() - 1 do
            local item = items:get(j)
            if string.find(item:getFullType(), ST_TYPE, 1, true) then
                ISTimedActionQueue.add(ISInventoryTransferAction:new(p, item, c, p:getInventory()))
                n = n + 1
            end
        end
    end
end
ST.say("TAKE", n, "at", ST_AT[1], ST_AT[2])
