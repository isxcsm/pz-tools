-- Moves the player to BUGO = { x, y } (set before RUN), for looking at the units from there.
local p = getPlayer()
p:setX(BUGO[1] + 0.5)
p:setY(BUGO[2] + 0.5)
p:setLastX(BUGO[1] + 0.5)
p:setLastY(BUGO[2] + 0.5)
print("[bugo]", p:getX(), p:getY(), "outside", tostring(p:getCurrentSquare() and p:getCurrentSquare():isOutside()))
