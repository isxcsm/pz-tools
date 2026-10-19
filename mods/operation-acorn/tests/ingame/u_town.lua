-- A town searched through the way a player does it (E2E.md 11.1): the character stands by each container of the town's
-- buildings in turn and the loot window shows it (ISInventoryPage:refreshBackpacks, which the mod's search watch hooks),
-- the walk between them done by moving the character. The town is U_TOWN (or the one the character stands in); with
-- U_TOWN_SHARE (0..1) it stops once that share of the town's buildings is searched. Titles and self-talk come as [st]
-- lines (story_lib); each building searched is printed. Lines "[utown]", the last one "[utown] end".
-- Changes the world (containers marked searched, the town's count).
local OA = OperationAcorn
local Towns = OA.Towns
local player = getPlayer()
local w = Towns.index()
local function say(...) print("[utown]", ...) end
local town = U_TOWN or Towns.at(w, player:getX(), player:getY())
local t = w.list[town]
local stopAt = math.ceil(t.n * (U_TOWN_SHARE or 1))
say("town", town, "buildings", t.n, "need", math.ceil(t.n * Towns.SHARE), "found", w.found[town] or 0, "stop at", stopAt)
local api = OA.api()

local keys = {}
for key, tn in pairs(w.of) do if tn == town and not w.seen[key] then keys[#keys + 1] = key end end
table.sort(keys)

-- where to stand for a container: a free square next to it in the same room, else its own
local function standFor(sq)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local n = getCell():getGridSquare(sq:getX() + d[1], sq:getY() + d[2], sq:getZ())
        if n and n:isFree(false) and n:getRoom() == sq:getRoom() and not sq:isBlockedTo(n) then return n end
    end
    return sq
end

local function containersOf(b)
    local list = {}
    for z = b.minLevel or 0, b.maxLevel or 0 do
        for y = b.minY, b.maxY do
            for x = b.minX, b.maxX do
                local sq = getCell():getGridSquare(x, y, z)
                if sq and sq:getBuilding() then
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if o:getContainer() and not o:getModData()[OA.Trade.Objects.KIND] then
                            list[#list + 1] = sq
                            break
                        end
                    end
                end
            end
        end
    end
    return list
end

local function moveTo(x, y, z)
    player:setX(x) player:setY(y) player:setZ(z)
    player:setLastX(x) player:setLastY(y) player:setLastZ(z)
end

local DWELL = 2500
local bi, list, ci, next = 0, nil, 0, getTimestampMs()
local tick
local function finish(why)
    Events.OnTick.Remove(tick)
    say("end", why, "found", w.found[town] or 0, "of", t.n, "done", tostring(w.done[town] == true))
end
tick = function()
    local now = getTimestampMs()
    if now < next then return end
    if (w.found[town] or 0) >= stopAt then return finish("share reached") end
    if not list then
        bi = bi + 1
        local key = keys[bi]
        if not key then return finish("no building left") end
        local x, y, z = key:match("(%-?%d+),(%-?%d+),(%-?%d+)")
        moveTo(tonumber(x) + 0.5, tonumber(y) + 0.5, 0)
        list, ci = "load", 0
        next = now + 1200
        return
    end
    if list == "load" then
        local key = keys[bi]
        local x, y = key:match("(%-?%d+),(%-?%d+)")
        local ok, b = pcall(api.buildings.at, tonumber(x), tonumber(y), 0)
        list = ok and type(b) == "table" and containersOf(b) or {}
        if #list == 0 then
            -- a building with no container: coming into it is its search (the loot window's refresh on entering)
            say("building", key, "no container")
            local page = getPlayerLoot(0)
            if page then page:refreshBackpacks() end
            list, next = nil, now + DWELL
        end
        return
    end
    ci = ci + 1
    local sq = list[ci]
    if not sq then
        -- a player lingers a moment in a building it has just searched (the watch's look again counts it whole)
        list, next = nil, now + DWELL
        return
    end
    local stand = standFor(sq)
    moveTo(stand:getX() + 0.5, stand:getY() + 0.5, stand:getZ())
    local before = w.found[town] or 0
    local page = getPlayerLoot(0)
    if page then page:refreshBackpacks() end
    if (w.found[town] or 0) > before then say("building searched", keys[bi], "found", w.found[town], "of", t.n) end
    next = now + 200
end
Events.OnTick.Add(tick)
