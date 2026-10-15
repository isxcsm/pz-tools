-- A story site's stage in the game world (server side, and alone): Stage.game points here. Reads the building's layout
-- and puts each kind of piece (Story/StageData). Checked in the game, not by unit tests.
--
-- B42 calls used (checked in the jar): BuildingDef getRooms, isFullyStreamedIn, getKeyId, getX/getY/getX2/getY2;
-- RoomDef getName, getArea, getZ, getX/getY/getX2/getY2, getIsoRoom; IsoRoom getSquares, getRandomFreeSquare,
-- getRandomWallSquare; IsoGridSquare getBuildingDef, AddSpecialObject, RecalcProperties, RecalcAllWithNeighbours;
-- IsoObject.new and IsoRadio.new (cell, square, sprite); IsoDoor and IsoWindow getNorth; IsoDoor setLockedByKey;
-- IsoBarricade.AddBarricadeToObject(object, onOpposite) then addPlank(nil, nil) and transmitCompleteItemToClients (as
-- the game's own police siege story, RBPoliceSiege, does it); RandomizedWorldBase.createRandomDeadBody(square, nil, 0, 0,
-- outfit) (nil: a random direction); addZombiesInOutfit (as Story/SceneGame); addVehicleDebug; IsoDeadBody isFakeDead
-- and reanimateNow (the debug menu's own).
require "OperationAcorn/Core"
require "OperationAcorn/Story/Stage"
require "OperationAcorn/Story/Game"
local OA = OperationAcorn
local StageGame = {}
OA.StageGame = StageGame

local function defAt(site)
    return getWorld():getMetaGrid():getBuildingAtRelax(math.floor(site.x), math.floor(site.y))
end

-- The site's building is all loaded, or its square is and the player is `close`.
function StageGame.siteLoaded(site, close)
    if not getCell():getGridSquare(math.floor(site.x), math.floor(site.y), site.z or 0) then return false end
    local def = defAt(site)
    return def ~= nil and (close or def:isFullyStreamedIn())
end

-- The building's layout (Story/Stage): its rooms, and its outer doors and windows on the ground floor. The RoomDefs and
-- the objects ride along (rooms[i].def, doors[i].object, windows[i].object) for the pieces; they are not saved.
-- A door or a window stands on a square's north or west edge, so an outer one is often on the square outside: the
-- building's box is scanned one square wider, and one is outer when one side is in the building and the other in no
-- room. A door is a doorway, with or without a door. (IsoRoom.getWindows is empty in game: found by the scan too.)
function StageGame.layout(site)
    local def = defAt(site)
    local layout = { rooms = {}, doors = {}, windows = {} }
    if not def then return layout end
    local bx1, by1, bx2, by2 = def:getX(), def:getY(), def:getX2(), def:getY2()
    local list = def:getRooms()
    local lowest, ground
    local byDef = {}
    for i = 0, list:size() - 1 do
        local r = list:get(i)
        local x, y, x2, y2 = r:getX(), r:getY(), r:getX2(), r:getY2()
        local entry = { name = r:getName(), area = r:getArea(), z = r:getZ(), x = x, y = y, x2 = x2, y2 = y2,
            edge = x <= bx1 or y <= by1 or x2 >= bx2 or y2 >= by2, def = r, doors = 0 }
        layout.rooms[#layout.rooms + 1] = entry
        byDef[r] = entry
        if not lowest or r:getZ() < lowest then lowest = r:getZ() end
        if r:getZ() == 0 then ground = true end
    end
    if not lowest then return layout end
    -- the ground floor: z 0, or the lowest there is (Stage.roles's floor; a basement is below it)
    if ground then lowest = 0 end
    local c = getCell()
    local function inside(sq)
        return sq ~= nil and sq:getRoom() ~= nil and sq:getBuildingDef() == def
    end
    -- the square's side (north or west edge) between the building and no room: whether the square is the inside one
    local function outerEdge(sq, x, y, north)
        local other = north and c:getGridSquare(x, y - 1, lowest) or c:getGridSquare(x - 1, y, lowest)
        local a, b = inside(sq), inside(other)
        if a == b or (a and other and other:getRoom()) or (b and sq:getRoom()) then return nil end
        return a
    end
    -- a doorway is the square's flag (DoorWallN/W, as IsoGridSquare.isDoorSquare reads it), with a door in it or not
    -- (a church's open front); a door's object rides along when there is one
    local doorAt = {}
    local function addDoor(x, y, north, o)
        local key = x .. "," .. y .. (north and "N" or "W")
        local at = doorAt[key]
        if at then
            at.object = at.object or o
            return
        end
        local own = outerEdge(c:getGridSquare(x, y, lowest), x, y, north)
        if own == nil then return end
        at = { x = x, y = y, z = lowest, north = north, object = o, own = own }
        doorAt[key] = at
        layout.doors[#layout.doors + 1] = at
    end
    for x = bx1 - 1, bx2 + 1 do
        for y = by1 - 1, by2 + 1 do
            local sq = c:getGridSquare(x, y, lowest)
            local props = sq and sq:getProperties()
            if props and props:has(IsoFlagType.DoorWallN) then addDoor(x, y, true, nil) end
            if props and props:has(IsoFlagType.DoorWallW) then addDoor(x, y, false, nil) end
            local objects = sq and sq:getObjects()
            for j = 0, (objects and objects:size() or 0) - 1 do
                local o = objects:get(j)
                if instanceof(o, "IsoDoor") then
                    addDoor(x, y, o:getNorth(), o)
                    -- the rooms on its two sides have a door (one that can be locked)
                    local other = o:getNorth() and c:getGridSquare(x, y - 1, lowest) or c:getGridSquare(x - 1, y, lowest)
                    for _, s in ipairs({ sq, other }) do
                        local room = s and s:getRoom()
                        local entry = room and byDef[room:getRoomDef()]
                        if entry then entry.doors = entry.doors + 1 end
                    end
                elseif instanceof(o, "IsoWindow") then
                    local own = outerEdge(sq, x, y, o:getNorth())
                    if own ~= nil then
                        layout.windows[#layout.windows + 1] = { x = x, y = y, z = lowest, north = o:getNorth(), object = o,
                            own = own }
                    end
                end
            end
        end
    end
    return layout
end

-- Puts a sprite on a square as the game's moveables do (ISMoveableSpriteProps): an IsoRadio for a radio's sprite (its
-- device data made from the sprite), a plain object otherwise. Not RandomizedWorldBase.addTileObject: that clears the
-- square first (cleanSquareForStory takes every object but the floor, walls and a desk's other half too).
local function put(sq, sprite)
    local spr = sq and getSprite(sprite)
    if not spr then return nil end
    local props = spr:getProperties()
    local kind = props and props:has("IsoType") and props:get("IsoType")
    local obj
    if kind == "IsoRadio" then
        obj = IsoRadio.new(getCell(), sq, spr)
    else
        obj = IsoObject.new(getCell(), sq, spr)
    end
    sq:AddSpecialObject(obj)
    if isServer() then obj:transmitCompleteItemToClients() end
    getTileOverlays():fixTableTopOverlays(sq)
    sq:RecalcProperties()
    sq:RecalcAllWithNeighbours(true)
    return obj
end

local function roomOf(ctx, p)
    local i = ctx.roles and ctx.roles[p.at]
    local room = i and ctx.layout and ctx.layout.rooms[i]
    return room and room.def and room.def:getIsoRoom()
end

local function roomDefOf(ctx, p)
    local i = ctx.roles and ctx.roles[p.at]
    local room = i and ctx.layout and ctx.layout.rooms[i]
    return room and room.def
end

-- The square outside the entrance door and the way out from it ({ dx, dy }), or nil.
local function outside(ctx)
    local i = ctx.roles and ctx.roles.entrance
    local d = i and ctx.layout.doors[i]
    if not d then return nil end
    local c = getCell()
    local here = c:getGridSquare(d.x, d.y, d.z)
    local dx, dy = 0, 0
    if d.north then dy = -1 else dx = -1 end
    local there = c:getGridSquare(d.x + dx, d.y + dy, d.z)
    if here and not here:getRoom() then return here, -dx, -dy, d end
    if there and not there:getRoom() then return there, dx, dy, d end
    return nil
end

local function rb()
    return RBBasic.new()
end

-- A sprite on a free square of the room (against a wall with `wall`); at the entrance, a wall object on the wall
-- beside the door: a square along the door's edge whose own north (or west) side is a wall, the sprite of that side.
-- A wall object shows on the side of the square that holds it: outside when the door's square is outside.
function StageGame.tile(ctx, p)
    local sq, sprite = nil, p.sprite
    if p.at == "entrance" then
        local i = ctx.roles and ctx.roles.entrance
        local d = i and ctx.layout.doors[i]
        if not d then return nil end
        local c = getCell()
        local list = d.north and { { 1, 0 }, { -1, 0 }, { 2, 0 } } or { { 0, 1 }, { 0, -1 }, { 0, 2 } }
        for _, o in ipairs(list) do
            local s = not sq and c:getGridSquare(d.x + o[1], d.y + o[2], d.z)
            if s and s:getWall(d.north) then sq = s end
        end
        sprite = d.north and sprite.north or sprite.west
    else
        local room = roomOf(ctx, p)
        if not room then return nil end
        sq = p.wall and room:getRandomWallSquare() or room:getRandomFreeSquare()
    end
    if not sq then return nil end
    return put(sq, sprite) ~= nil
end

-- Sprites placed together: an anchor square of the room where every square of the set is free and in the room; with
-- `more`, those too where they fit with it, else the set alone.
function StageGame.set(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    local c = getCell()
    local squares = room:getSquares()
    local function anchors(list)
        local fits = {}
        for i = 0, squares:size() - 1 do
            local a = squares:get(i)
            local ok = true
            for _, t in ipairs(list) do
                local s = ok and c:getGridSquare(a:getX() + t[1], a:getY() + t[2], a:getZ())
                if not (s and s:getRoom() == room and s:isFree(false)) then ok = false end
            end
            if ok then fits[#fits + 1] = a end
        end
        return fits
    end
    local tiles = p.tiles
    local fits = {}
    if p.more then
        tiles = {}
        for _, t in ipairs(p.tiles) do tiles[#tiles + 1] = t end
        for _, t in ipairs(p.more) do tiles[#tiles + 1] = t end
        fits = anchors(tiles)
    end
    if #fits == 0 then
        tiles = p.tiles
        fits = anchors(tiles)
    end
    if #fits == 0 then return nil end
    local a = fits[OA.random(1, #fits)]
    for _, t in ipairs(tiles) do
        put(c:getGridSquare(a:getX() + t[1], a:getY() + t[2], a:getZ()), t[3])
    end
    return true
end

-- Loose things on the room's floor.
function StageGame.item(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    for _ = 1, p.count or 1 do
        local sq = room:getRandomFreeSquare()
        if sq then sq:AddWorldInventoryItem(p.type, 0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), 0) end
    end
    return true
end

-- A vehicle outside the entrance, along the wall: the first spot a few squares out (4, 3, 5, 6; straight out, then to
-- either side) where its body (5 squares along the wall, 3 across) is free ground outside and no vehicle stands within
-- a square of it (a parked car there already). A door open, the battery as given.
function StageGame.vehicle(ctx, p)
    local out, dx, dy = outside(ctx)
    if not out then return nil end
    local c = getCell()
    local z = out:getZ()
    local ax, ay = dy ~= 0 and 1 or 0, dx ~= 0 and 1 or 0
    local function clear(cx, cy)
        for l = -3, 3 do
            for w = -2, 2 do
                local s = c:getGridSquare(cx + ax * l + dx * w, cy + ay * l + dy * w, z)
                if not s or s:getVehicleContainer() then return false end
                if l >= -2 and l <= 2 and w >= -1 and w <= 1 and (s:getRoom() or not s:isFree(false)) then return false end
            end
        end
        return true
    end
    local sq
    for _, k in ipairs({ 4, 3, 5, 6 }) do
        for _, side in ipairs({ 0, 3, -3, 6, -6 }) do
            local cx, cy = out:getX() + dx * k + ax * side, out:getY() + dy * k + ay * side
            if not sq and clear(cx, cy) then sq = c:getGridSquare(cx, cy, z) end
        end
    end
    if not sq then return nil end
    local dir = dx ~= 0 and IsoDirections.N or IsoDirections.E
    local car = addVehicleDebug(p.script, dir, nil, sq)
    if not car then return nil end
    if p.open then
        local part = car:getPartById(p.open)
        local door = part and part:getDoor()
        if door then
            door:setOpen(true)
            car:transmitPartDoor(part)
        end
    end
    if p.battery then
        local part = car:getPartById("Battery")
        local item = part and part:getInventoryItem()
        if item then
            item:setUsedDelta(p.battery)
            car:transmitPartItem(part)
        end
    end
    return true
end

-- Boards on the inside of the ground floor's windows.
function StageGame.barricade(ctx, p)
    local lo, hi = (p.planks or { 2, 3 })[1], (p.planks or { 2, 3 })[2]
    for _, at in ipairs(ctx.layout.windows or {}) do
        local w = at.object
        if w:isBarricadeAllowed() then
            local b = IsoBarricade.AddBarricadeToObject(w, not at.own)
            if b then
                for _ = 1, OA.random(lo, hi) do b:addPlank(nil, nil) end
                b:transmitCompleteItemToClients()
            end
        end
    end
    return true
end

-- Locks the room's doors with the building's key; returns the key's id.
function StageGame.lock(ctx, p)
    local room = roomOf(ctx, p)
    local def = roomDefOf(ctx, p)
    if not room then return nil end
    local c = getCell()
    local squares = room:getSquares()
    local locked = 0
    for i = 0, squares:size() - 1 do
        local sq = squares:get(i)
        local objects = sq:getObjects()
        for j = 0, objects:size() - 1 do
            local o = objects:get(j)
            if instanceof(o, "IsoDoor") then
                local other = o:getNorth() and c:getGridSquare(sq:getX(), sq:getY() - 1, sq:getZ())
                    or c:getGridSquare(sq:getX() - 1, sq:getY(), sq:getZ())
                if (sq:getRoom() == room) ~= (other and other:getRoom() == room) then
                    o:setLockedByKey(true)
                    locked = locked + 1
                end
            end
        end
    end
    if locked == 0 then return nil end
    return def:getBuilding():getKeyId()
end

-- A body in an outfit in the room; with `key`, the building's key in its pockets. A world with no zombies makes no
-- bodies (IsoWorld.getZombiesDisabled): the key is left on the floor there, so the locked room still opens.
function StageGame.corpse(ctx, p)
    local room = roomOf(ctx, p)
    local sq = room and room:getRandomFreeSquare()
    if not sq then return nil end
    local body = RandomizedWorldBase.createRandomDeadBody(sq, nil, 0, 0, p.outfit)
    local key = p.key and ctx.keyId and instanceItem("Base.Key1")
    if key then key:setKeyId(ctx.keyId) end
    if not body then
        if key then sq:AddWorldInventoryItem(key, 0.5, 0.5, 0) end
        return nil
    end
    if key then body:getContainer():AddItem(key) end
    return true
end

-- Blood on the room's floor.
function StageGame.blood(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    local g = rb()
    for _ = 1, p.count or 1 do
        local sq = room:getRandomFreeSquare()
        if sq then g:addBloodSplat(sq, OA.random(1, 4)) end
    end
    return true
end

-- The mission's own item in the room.
function StageGame.piece(ctx, p)
    local def = roomDefOf(ctx, p)
    if not def then return nil end
    for _, it in ipairs(ctx.m.items or {}) do
        if it.key == p.key and it.staged then
            if OA.StoryGame.placeInRoom(ctx.record, ctx.m, it, def) then it.staged = nil end
        end
    end
    return true
end

-- Zombies in an outfit in the room, away from the player (`near`; else the farthest square tried, if it is CLOSE away
-- as Story/Scene allows: the player may have come well inside READY between two looks); returns where each lies
-- ({ x, y, z }) for waking.
function StageGame.zombies(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    local near2 = (ctx.near or 0) * (ctx.near or 0)
    local close = OA.Scene and OA.Scene.CLOSE or 10
    local points = {}
    for _ = 1, p.count or 1 do
        local sq, best, bestD
        for _ = 1, 12 do
            local s = room:getRandomFreeSquare()
            if s and ctx.px then
                local dx, dy = s:getX() - ctx.px, s:getY() - ctx.py
                local d2 = dx * dx + dy * dy
                if d2 >= near2 then sq = s end
                if not bestD or d2 > bestD then best, bestD = s, d2 end
            else
                sq = s
            end
            if sq then break end
        end
        if not sq and best and bestD >= close * close then sq = best end
        if sq then
            local female = p.female
            addZombiesInOutfit(sq:getX(), sq:getY(), sq:getZ(), 1, p.outfit or nil, female or nil, false, false,
                p.look == "fakeDead", false, false, p.look == "sitting", 1.0)
            points[#points + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
        end
    end
    return points
end

-- Wakes what lies fake dead at the points (or a square from them: a body may have slid).
function StageGame.wake(points)
    local c = getCell()
    for _, at in ipairs(points) do
        local done = false
        for dx = -1, 1 do
            for dy = -1, 1 do
                local sq = not done and c:getGridSquare(at.x + dx, at.y + dy, at.z)
                local bodies = sq and sq:getDeadBodys()
                if bodies then
                    for i = 0, bodies:size() - 1 do
                        local b = bodies:get(i)
                        if not done and b:isFakeDead() then
                            b:reanimateNow()
                            done = true
                        end
                    end
                end
                local moving = sq and sq:getMovingObjects()
                if moving and not done then
                    for i = 0, moving:size() - 1 do
                        local z = moving:get(i)
                        if not done and instanceof(z, "IsoZombie") and z:isFakeDead() then
                            z:setFakeDead(false)
                            done = true
                        end
                    end
                end
            end
        end
    end
end

function StageGame.request(record, m, it)
    OA.StoryGame.request(record, m, it)
end

return StageGame
