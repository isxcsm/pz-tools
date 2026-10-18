-- The supply crates within 20 squares of the character: where, sealed or open, and what is in them.
local Objects = OperationAcorn.Trade.Objects
local p = getPlayer()
local px, py = math.floor(p:getX()), math.floor(p:getY())
ST.say("PLAYER", px, py)
for dy = -20, 20 do
    for dx = -20, 20 do
        local sq = getCell():getGridSquare(px + dx, py + dy, 0)
        local o = sq and Objects.find(sq, Objects.CRATE)
        if o then
            local c = o:getContainer()
            local items = {}
            for j = 0, (c and c:getItems():size() or 0) - 1 do items[#items + 1] = c:getItems():get(j):getType() end
            ST.say("CRATE", sq:getX(), sq:getY(), o:getModData()[Objects.SEALED] and "sealed" or "open", table.concat(items, ","))
        end
    end
end
