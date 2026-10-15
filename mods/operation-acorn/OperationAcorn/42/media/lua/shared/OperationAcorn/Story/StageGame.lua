-- A story site's stage in the game world (server side, and alone): Stage.game points here. Reads the building's layout
-- and puts each kind of piece (Story/StageData). Checked in the game, not by unit tests.
--
-- B42 calls used (checked in the jar): BuildingDef getRooms, isFullyStreamedIn, getKeyId, getX/getY/getX2/getY2;
-- RoomDef getName, getArea, getZ, getX/getY/getX2/getY2, getIsoRoom; IsoRoom getSquares, getWindows,
-- getRandomFreeSquare, getRandomWallSquare; IsoDoor isExterior, getNorth, getOppositeSquare, setLockedByKey;
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

-- The site's building is all loaded.
function StageGame.siteLoaded(site)
    if not getCell():getGridSquare(math.floor(site.x), math.floor(site.y), site.z or 0) then return false end
    local def = defAt(site)
    return def ~= nil and def:isFullyStreamedIn()
end

-- The building's layout (Story/Stage): its rooms and its outer doors on the ground floor. The RoomDefs and the doors'
-- objects ride along (rooms[i].def, doors[i].object) for the pieces; they are not saved.
function StageGame.layout(site)
    local def = defAt(site)
    local layout = { rooms = {}, doors = {} }
    if not def then return layout end
    local bx1, by1, bx2, by2 = def:getX(), def:getY(), def:getX2(), def:getY2()
    local list = def:getRooms()
    local lowest
    for i = 0, list:size() - 1 do
        local r = list:get(i)
        local x, y, x2, y2 = r:getX(), r:getY(), r:getX2(), r:getY2()
        layout.rooms[#layout.rooms + 1] = { name = r:getName(), area = r:getArea(), z = r:getZ(), x = x, y = y, x2 = x2,
            y2 = y2, edge = x <= bx1 or y <= by1 or x2 >= bx2 or y2 >= by2, def = r }
        if not lowest or r:getZ() < lowest then lowest = r:getZ() end
    end
    local seen = {}
    for _, room in ipairs(layout.rooms) do
        local iso = room.z == lowest and room.def:getIsoRoom()
        if iso then
            local squares = iso:getSquares()
            for i = 0, squares:size() - 1 do
                local sq = squares:get(i)
                local objects = sq:getObjects()
                for j = 0, objects:size() - 1 do
                    local o = objects:get(j)
                    if instanceof(o, "IsoDoor") and not seen[o] and o:isExterior() then
                        seen[o] = true
                        layout.doors[#layout.doors + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(),
                            north = o:getNorth(), object = o }
                    end
                end
            end
        end
    end
    return layout
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

-- A sprite on a free square of the room (against a wall with `wall`); at the entrance, on a free square just outside.
function StageGame.tile(ctx, p)
    local sq
    if p.at == "entrance" then
        local out, dx, dy, d = outside(ctx)
        if not out then return nil end
        -- one square aside from the door, along the wall
        local c = getCell()
        local side = d.north and c:getGridSquare(out:getX() + 1, out:getY(), out:getZ())
            or c:getGridSquare(out:getX(), out:getY() + 1, out:getZ())
        sq = (side and side:isFree(false)) and side or out
    else
        local room = roomOf(ctx, p)
        if not room then return nil end
        sq = p.wall and room:getRandomWallSquare() or room:getRandomFreeSquare()
    end
    if not sq then return nil end
    local sprite = p.sprite
    if type(sprite) == "table" then
        local i = ctx.roles.entrance
        local d = i and ctx.layout.doors[i]
        sprite = (d and d.north) and sprite.north or sprite.west
    end
    return rb():addTileObject(sq, sprite) ~= nil
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

-- A vehicle outside the entrance, a few squares out, along the wall; a door open, the battery as given.
function StageGame.vehicle(ctx, p)
    local out, dx, dy = outside(ctx)
    if not out then return nil end
    local sq = getCell():getGridSquare(out:getX() + dx * 4, out:getY() + dy * 4, out:getZ())
    if not (sq and sq:isFree(false)) or sq:getRoom() then return nil end
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
    for _, room in ipairs(ctx.layout.rooms) do
        local iso = room.def and room.def:getIsoRoom()
        if iso and room.z == ctx.layout.rooms[ctx.roles.big or 1].z then
            local windows = iso:getWindows()
            for i = 0, windows:size() - 1 do
                local w = windows:get(i)
                if w:isBarricadeAllowed() then
                    local own = w:getSquare() and w:getSquare():getRoom() ~= nil
                    local b = IsoBarricade.AddBarricadeToObject(w, not own)
                    if b then
                        for _ = 1, OA.random(lo, hi) do b:addPlank(nil, nil) end
                        b:transmitCompleteItemToClients()
                    end
                end
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

-- A body in an outfit in the room; with `key`, the building's key in its pockets.
function StageGame.corpse(ctx, p)
    local room = roomOf(ctx, p)
    local sq = room and room:getRandomFreeSquare()
    if not sq then return nil end
    local body = RandomizedWorldBase.createRandomDeadBody(sq, nil, 0, 0, p.outfit)
    if not body then return nil end
    if p.key and ctx.keyId then
        local key = instanceItem("Base.Key1")
        if key then
            key:setKeyId(ctx.keyId)
            body:getContainer():AddItem(key)
        end
    end
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

-- Zombies in an outfit in the room, away from the player; returns where each lies ({ x, y, z }) for waking.
function StageGame.zombies(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    local near2 = (ctx.near or 0) * (ctx.near or 0)
    local points = {}
    for _ = 1, p.count or 1 do
        local sq
        for _ = 1, 8 do
            local s = room:getRandomFreeSquare()
            if s and ctx.px then
                local dx, dy = s:getX() - ctx.px, s:getY() - ctx.py
                if dx * dx + dy * dy >= near2 then sq = s end
            else
                sq = s
            end
            if sq then break end
        end
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
