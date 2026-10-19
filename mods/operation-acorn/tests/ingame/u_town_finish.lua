-- The last containers of a building, the way the search ledger points at them (Buildings.unopened): for each building
-- of U_TOWN not counted yet, the character goes in, then stands by each container the watch still lists as not opened
-- and the loot window shows it, a floor at a time, then lingers. Lines "[utownfin]", the last "[utownfin] end".
local OA = OperationAcorn
local w = OA.Towns.index()
local player = getPlayer()
local town = U_TOWN
local function say(...) print("[utownfin]", ...) end
local keys = {}
for key, tn in pairs(w.of) do if tn == town and not w.seen[key] then keys[#keys + 1] = key end end
table.sort(keys)

local function moveTo(x, y, z)
    player:setX(x) player:setY(y) player:setZ(z)
    player:setLastX(x) player:setLastY(y) player:setLastZ(z)
end
local function refresh()
    local page = getPlayerLoot(0)
    if page then page:refreshBackpacks() end
end
local function standFor(sq)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }) do
        local n = getCell():getGridSquare(sq:getX() + d[1], sq:getY() + d[2], sq:getZ())
        if n and n:isFree(false) and n:getRoom() and not sq:isBlockedTo(n) then return n end
    end
    return sq
end

local bi, todo, next, tries = 0, nil, getTimestampMs(), 0
local tick
tick = function()
    local now = getTimestampMs()
    if now < next then return end
    if not todo then
        bi = bi + 1
        local key = keys[bi]
        if not key then
            Events.OnTick.Remove(tick)
            say("end", "found", w.found[town] or 0, "of", w.list[town].n, "done", tostring(w.done[town] == true))
            return
        end
        local x, y = key:match("(%-?%d+),(%-?%d+)")
        moveTo(tonumber(x) + 0.5, tonumber(y) + 0.5, 0)
        refresh()
        todo, tries, next = "look", 0, now + 1500
        return
    end
    tries = tries + 1
    local open, ox, oy, oz = OA.Buildings.unopened(player)
    local n = open and #open or 0
    if n == 0 and tries <= 60 then
        -- none left on this floor: down or up to a floor that has some (a house's basement is part of it)
        for z = -1, 3 do
            local left = OA.Buildings.floor(player, z)
            if left and left > 0 and z ~= math.floor(player:getZ()) then
                local key = keys[bi]
                local x0, y0 = key:match("(%-?%d+),(%-?%d+)")
                x0, y0 = tonumber(x0), tonumber(y0)
                for r = 0, 20 do
                    for dy = -r, r do
                        for dx = -r, r do
                            local sq = getCell():getGridSquare(x0 + dx, y0 + dy, z)
                            if sq and sq:getRoom() and sq:isFree(false) then
                                moveTo(sq:getX() + 0.5, sq:getY() + 0.5, z)
                                refresh()
                                next = now + 1500
                                say(key, "to floor", z, "left there", left)
                                return
                            end
                        end
                    end
                end
            end
        end
    end
    if n == 0 or tries > 60 then
        say(keys[bi], "left unopened", n, "seen", tostring(w.seen[keys[bi]] == true))
        todo, next = nil, now + 2500
        return
    end
    local x, y, z = ox and ox[1], oy and oy[1], oz and oz[1]
    if not x then
        local c = open[1]
        local o = c and c:getParent()
        local sq = o and o:getSquare()
        if sq then x, y, z = sq:getX(), sq:getY(), sq:getZ() end
    end
    if not x then todo = nil return end
    local stand = standFor(getCell():getGridSquare(x, y, z))
    moveTo(stand:getX() + 0.5, stand:getY() + 0.5, stand:getZ())
    refresh()
    next = now + 400
end
Events.OnTick.Add(tick)
