-- What is left of a town's search (after u_town.lua): each building not counted yet, its containers loaded and marked,
-- and where the unmarked ones are. U_TOWN the town. Moves the character to each building to load it. Lines "[utownleft]",
-- the last "[utownleft] end".
local OA = OperationAcorn
local w = OA.Towns.index()
local api = OA.api()
local player = getPlayer()
local town = U_TOWN
local function say(...) print("[utownleft]", ...) end
local keys = {}
for key, tn in pairs(w.of) do if tn == town and not w.seen[key] then keys[#keys + 1] = key end end
table.sort(keys)
local i, next, moved = 0, getTimestampMs(), false
local tick
tick = function()
    local now = getTimestampMs()
    if now < next then return end
    if not moved then
        i = i + 1
        local key = keys[i]
        if not key then Events.OnTick.Remove(tick) say("end", #keys, "left") return end
        local x, y = key:match("(%-?%d+),(%-?%d+)")
        player:setX(tonumber(x) + 0.5) player:setY(tonumber(y) + 0.5) player:setZ(0)
        player:setLastX(tonumber(x) + 0.5) player:setLastY(tonumber(y) + 0.5) player:setLastZ(0)
        moved, next = true, now + 1200
        return
    end
    moved = false
    local key = keys[i]
    local x, y = key:match("(%-?%d+),(%-?%d+)")
    local ok, b = pcall(api.buildings.at, tonumber(x), tonumber(y), 0)
    if not (ok and type(b) == "table") then say(key, "not a building now") return end
    local n, marked, left = 0, 0, {}
    for z = b.minLevel or 0, b.maxLevel or 0 do
        for yy = b.minY, b.maxY do
            for xx = b.minX, b.maxX do
                local sq = getCell():getGridSquare(xx, yy, z)
                if sq and sq:getBuilding() then
                    local objs = sq:getObjects()
                    for k = 0, objs:size() - 1 do
                        local o = objs:get(k)
                        if o:getContainer() and not o:getModData()[OA.Trade.Objects.KIND] then
                            n = n + 1
                            if o:getModData()[OA.Buildings.SEARCHED] then marked = marked + 1
                            elseif #left < 4 then left[#left + 1] = xx .. "," .. yy .. "," .. z .. ":" .. tostring(o:getContainer():getType()) end
                        end
                    end
                end
            end
        end
    end
    say(key, "levels", b.minLevel, b.maxLevel, "containers", n, "marked", marked, "left", table.concat(left, " "))
end
Events.OnTick.Add(tick)
