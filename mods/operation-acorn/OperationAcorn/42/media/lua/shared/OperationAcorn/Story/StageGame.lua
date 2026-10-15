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
-- and reanimateNow (the debug menu's own); IsoObject createContainersFromSpriteProperties and ItemContainer setExplored
-- (as ISMoveableSpriteProps); IsoDoor IsOpen, ToggleDoorSilent, getBarricadeOnSameSquare/OppositeSquare; IsoBarricade
-- getNumPlanks, removePlank(nil); IsoGridSquare playSound ("BreakBarricadePlank"); IsoWindow ToggleWindow(nil) (no
-- character: no barricade asked), BuildingDef isAlarmed; IsoGenerator.new(item, cell, square), getMaxFuel, setFuel,
-- setCondition (as the game's TimedActionsTests); BaseVehicle createVehicleKey, putKeyInIgnition(key, -1),
-- addKeyToGloveBox, VehiclePart setContainerContentAmount, getContainerCapacity, getItemContainer.
require "OperationAcorn/Core"
require "OperationAcorn/Story/Stage"
require "OperationAcorn/Story/Game"
require "OperationAcorn/Trade/Later"
local OA = OperationAcorn
local StageGame = {}
OA.StageGame = StageGame

local function defAt(site)
    return getWorld():getMetaGrid():getBuildingAtRelax(math.floor(site.x), math.floor(site.y))
end

-- The site's building is all loaded, or its square is and the player is `close`; open ground, when the squares out to
-- Stage.GROUND_RADIUS round it are.
function StageGame.siteLoaded(site, close)
    local c = getCell()
    local x, y, z = math.floor(site.x), math.floor(site.y), site.z or 0
    if not c:getGridSquare(x, y, z) then return false end
    if site.ground then
        local r = OA.Stage.GROUND_RADIUS
        return c:getGridSquare(x - r, y - r, z) ~= nil and c:getGridSquare(x + r, y + r, z) ~= nil
            and c:getGridSquare(x - r, y + r, z) ~= nil and c:getGridSquare(x + r, y - r, z) ~= nil
    end
    local def = defAt(site)
    return def ~= nil and (close or def:isFullyStreamedIn())
end

-- The building's layout (Story/Stage): its rooms, and its outer doors and windows on the ground floor. The RoomDefs and
-- the objects ride along (rooms[i].def, doors[i].object, windows[i].object) for the pieces; they are not saved.
-- A door or a window stands on a square's north or west edge, so an outer one is often on the square outside: the
-- building's box is scanned one square wider, and one is outer when one side is in the building and the other in no
-- room. A door is a doorway, with or without a door. (IsoRoom.getWindows is empty in game: found by the scan too.)
function StageGame.layout(site)
    local layout = { rooms = {}, doors = {}, windows = {} }
    -- open ground: no rooms, its middle
    if site.ground then
        layout.ground, layout.x, layout.y, layout.z = true, math.floor(site.x), math.floor(site.y), site.z or 0
        return layout
    end
    local def = defAt(site)
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
local function put(sq, sprite, on)
    local spr = sq and getSprite(sprite)
    if not spr then return nil end
    local props = spr:getProperties()
    local kind = props and props:has("IsoType") and props:get("IsoType")
    local obj
    if kind == "IsoRadio" then
        obj = IsoRadio.new(getCell(), sq, spr)
        if on then obj:getDeviceData():setIsTurnedOn(true) end
    else
        obj = IsoObject.new(getCell(), sq, spr)
    end
    -- its containers (a crate, a desk's drawer), empty: what was in them is gone (explored, so no loot is rolled)
    obj:createContainersFromSpriteProperties()
    for i = 0, obj:getContainerCount() - 1 do obj:getContainerByIndex(i):setExplored(true) end
    sq:AddSpecialObject(obj)
    if isServer() then obj:transmitCompleteItemToClients() end
    getTileOverlays():fixTableTopOverlays(sq)
    sq:RecalcProperties()
    sq:RecalcAllWithNeighbours(true)
    return obj
end

-- The room of the layout a piece asks for by name or floor: with `up`, the largest on the floor above the ground floor
-- (one named in `names` first); with `names` alone, the largest so named on any floor. The same for every piece that
-- asks the same (the stage's later look reads the layout again).
local function pickRoom(ctx, p)
    local rooms = ctx.layout and ctx.layout.rooms or {}
    local ground
    for _, r in ipairs(rooms) do
        if r.z == 0 then ground = 0 end
    end
    if not ground then
        for _, r in ipairs(rooms) do
            if not ground or r.z < ground then ground = r.z end
        end
    end
    local named = {}
    for _, n in ipairs(p.names or {}) do named[n] = true end
    local best, bestNamed
    for _, r in ipairs(rooms) do
        if (not p.up or r.z == (ground or 0) + 1) and (r.area or 0) >= OA.Stage.ROOM_AREA then
            if named[r.name or ""] and (not bestNamed or r.area > bestNamed.area) then bestNamed = r end
            if not best or r.area > best.area then best = r end
        end
    end
    if p.up then return bestNamed or best end
    return bestNamed
end

-- The RoomDef a piece goes to: the room it asks for (pickRoom), else (`names` not found) its role's.
local function roomDefOf(ctx, p)
    if p.up or p.names then
        local r = pickRoom(ctx, p)
        if r then return r.def end
        if p.up then return nil end
    end
    local i = ctx.roles and ctx.roles[p.at]
    local room = i and ctx.layout and ctx.layout.rooms[i]
    return room and room.def
end

local function roomOf(ctx, p)
    local def = roomDefOf(ctx, p)
    return def and def:getIsoRoom()
end

-- The square outside an outer door (the entrance, or the role's: "back") and the way out from it ({ dx, dy }), or nil.
local function outside(ctx, role)
    local i = ctx.roles and ctx.roles[role or "entrance"]
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

-- A free square outdoors about (x, y): the square itself, else the nearest one out to `reach` squares that is free and
-- in no room.
local function freeNear(x, y, z, reach)
    local c = getCell()
    for r = 0, reach or 0 do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local s = c:getGridSquare(x + dx, y + dy, z)
                    if s and not s:getRoom() and s:isFree(false) then return s end
                end
            end
        end
    end
    return nil
end

-- Whether a piece goes outdoors: on open ground ("ground") or the yard outside the entrance ("yard").
local function outdoors(p)
    return p.at == "ground" or p.at == "yard"
end

-- The square about which an outdoor piece goes: on open ground the site's middle moved by (dx, dy); in the yard a few
-- squares (2 to 4) out from the entrance, to either side.
local function spotOf(ctx, p)
    local l = ctx.layout
    if p.at == "ground" and l.ground then return l.x + (p.dx or 0), l.y + (p.dy or 0), l.z end
    if p.at == "yard" then
        local out, dx, dy = outside(ctx)
        if not out then return nil end
        local ax, ay = dy ~= 0 and 1 or 0, dx ~= 0 and 1 or 0
        local k, side = OA.random(2, 4), OA.random(-3, 3)
        return out:getX() + dx * k + ax * side, out:getY() + dy * k + ay * side, out:getZ()
    end
    return nil
end

-- A free square for a piece: outdoors one about its spot (a random square within `reach`, else 1, or the nearest free
-- one to it), else a free square of its room.
local function squareFor(ctx, p, reach)
    if outdoors(p) then
        local x, y, z = spotOf(ctx, p)
        if not x then return nil end
        local r = reach or p.reach or 1
        return freeNear(x + OA.random(-r, r), y + OA.random(-r, r), z, 2)
    end
    local room = roomOf(ctx, p)
    return room and room:getRandomFreeSquare()
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
        local list = d.north and { { 1, 0 }, { -1, 0 }, { 2, 0 }, { -2, 0 } } or { { 0, 1 }, { 0, -1 }, { 0, 2 }, { 0, -2 } }
        local walls = {}
        for _, o in ipairs(list) do
            local s = c:getGridSquare(d.x + o[1], d.y + o[2], d.z)
            if s and s:getWall(d.north) then walls[#walls + 1] = s end
        end
        local sprites = d.north and sprite.north or sprite.west
        if type(sprites) ~= "table" then sprites = { sprites } end
        -- `count` of them (a sprite of the list each), one to a square
        local made = false
        for k = 1, math.min(p.count or 1, #walls) do
            if put(walls[k], sprites[OA.random(1, #sprites)], p.on) then made = true end
        end
        return made or nil
    elseif outdoors(p) then
        sq = squareFor(ctx, p)
    else
        local room = roomOf(ctx, p)
        if not room then return nil end
        sq = p.wall and room:getRandomWallSquare() or room:getRandomFreeSquare()
    end
    if not sq then return nil end
    return put(sq, sprite, p.on) ~= nil
end

-- Sprites placed together: an anchor square of the room (outdoors: about the piece's spot, within `reach`, else 3)
-- where every square of the set is free and in the room (outdoors: in none); with `more`, those too where they fit
-- with it, else the set alone. `count` sets of it, each where it fits.
function StageGame.set(ctx, p)
    local room = not outdoors(p) and roomOf(ctx, p)
    if not (room or outdoors(p)) then return nil end
    local c = getCell()
    local candidates = {}
    if room then
        local squares = room:getSquares()
        for i = 0, squares:size() - 1 do candidates[#candidates + 1] = squares:get(i) end
    else
        local x, y, z = spotOf(ctx, p)
        if not x then return nil end
        local reach = p.reach or 3
        for dx = -reach, reach do
            for dy = -reach, reach do
                local s = c:getGridSquare(x + dx, y + dy, z)
                if s then candidates[#candidates + 1] = s end
            end
        end
    end
    local function fitsAt(s)
        if not (s and s:isFree(false)) then return false end
        if room then return s:getRoom() == room end
        return s:getRoom() == nil
    end
    local function anchors(list)
        local fits = {}
        for _, a in ipairs(candidates) do
            local ok = true
            for _, t in ipairs(list) do
                if ok and not fitsAt(c:getGridSquare(a:getX() + t[1], a:getY() + t[2], a:getZ())) then ok = false end
            end
            if ok then fits[#fits + 1] = a end
        end
        return fits
    end
    local placed = false
    for _ = 1, p.count or 1 do
        if StageGame.setOnce(p, anchors) then placed = true end
    end
    return placed or nil
end

-- One of a set's copies (StageGame.set): where the set and `more` fit, else the set alone.
function StageGame.setOnce(p, anchors)
    local c = getCell()
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
        put(c:getGridSquare(a:getX() + t[1], a:getY() + t[2], a:getZ()), t[3], p.on)
    end
    return true
end

-- A row of one sprite on open ground: from the site's middle moved by (dx, dy), `length` squares along `step`
-- ({ x, y }); a square in a room or taken is skipped (the row has a gap there).
function StageGame.line(ctx, p)
    local l = ctx.layout
    if not l.ground then return nil end
    local c = getCell()
    local made = 0
    for k = 0, (p.length or 1) - 1 do
        local s = c:getGridSquare(l.x + (p.dx or 0) + p.step[1] * k, l.y + (p.dy or 0) + p.step[2] * k, l.z)
        if s and not s:getRoom() and s:isFree(false) and not s:getVehicleContainer() then
            put(s, p.sprite)
            made = made + 1
        end
    end
    return made > 0 or nil
end

-- Loose things on the room's floor (outdoors: about the piece's spot); `types` for a few of one list, each of them.
function StageGame.item(ctx, p)
    if not (outdoors(p) or roomOf(ctx, p)) then return nil end
    for _ = 1, p.count or 1 do
        local sq = squareFor(ctx, p)
        local kind = p.types and p.types[OA.random(1, #p.types)] or p.type
        if sq then sq:AddWorldInventoryItem(kind, 0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), 0) end
    end
    return true
end

-- A vehicle outside the entrance (or the role's door: "back"), along the wall: the first spot a few squares out (4, 3,
-- 5, 6; straight out, then to either side) where its body (5 squares along the wall, 3 across) is free ground outside
-- and no vehicle stands within a square of it (a parked car there already). On open ground: about the piece's spot,
-- lying north to south (`across`: east to west). Doors open (`open`: a part id, or a list), the battery and the fuel
-- as given, its key in it (`key`).
function StageGame.vehicle(ctx, p)
    local c = getCell()
    local out, dx, dy, z
    if p.at == "ground" then
        local x, y, gz = spotOf(ctx, p)
        if not x then return nil end
        out, z = c:getGridSquare(x, y, gz), gz
        if p.across then dx, dy = 0, 1 else dx, dy = 1, 0 end
        if not out then return nil end
    else
        out, dx, dy = outside(ctx, p.at ~= "entrance" and p.at or nil)
        if not out then return nil end
        z = out:getZ()
    end
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
    local outs = p.at == "ground" and { 0, 1, -1, 2, -2 } or { 4, 3, 5, 6 }
    for _, k in ipairs(outs) do
        for _, side in ipairs({ 0, 3, -3, 6, -6 }) do
            local cx, cy = out:getX() + dx * k + ax * side, out:getY() + dy * k + ay * side
            if not sq and clear(cx, cy) then sq = c:getGridSquare(cx, cy, z) end
        end
    end
    if not sq then return nil end
    local dir = dx ~= 0 and IsoDirections.N or IsoDirections.E
    local car = addVehicleDebug(p.script, dir, nil, sq)
    if not car then return nil end
    local opens = type(p.open) == "table" and p.open or { p.open }
    for _, id in ipairs(opens) do
        local part = car:getPartById(id)
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
    if p.fuel then
        local tank = car:getPartById("GasTank")
        if tank then
            tank:setContainerContentAmount(tank:getContainerCapacity() * p.fuel)
            car:transmitPartModData(tank)
        end
    end
    -- its load in the truck bed (or the trunk)
    if p.load then
        local bed = car:getPartById("TruckBed") or car:getPartById("TrunkDoor")
        local container = bed and bed:getItemContainer()
        if container then
            for _, kind in ipairs(p.load) do container:AddItem(kind) end
            car:transmitPartItem(bed)
        end
    end
    -- (with no driver the key goes straight in: BaseVehicle.putKeyInIgnition; else it is left in the glove box)
    if p.key then
        local key = car:createVehicleKey()
        if not (key and pcall(function() car:putKeyInIgnition(key, -1) end)) then car:addKeyToGloveBox() end
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

-- The doors of a room: its IsoDoors with the room on one side only, each with whether its own square is the room's.
-- A door stands on a square's north or west edge, so one in the room's south or east wall is on the square outside:
-- the room's box is scanned one square wider.
local function doorsOf(room)
    local c = getCell()
    local def = room:getRoomDef()
    local z = def:getZ()
    local out = {}
    for x = def:getX() - 1, def:getX2() + 1 do
        for y = def:getY() - 1, def:getY2() + 1 do
            local sq = c:getGridSquare(x, y, z)
            local objects = sq and sq:getObjects()
            for j = 0, (objects and objects:size() or 0) - 1 do
                local o = objects:get(j)
                if instanceof(o, "IsoDoor") then
                    local other = o:getNorth() and c:getGridSquare(x, y - 1, z) or c:getGridSquare(x - 1, y, z)
                    local inRoom = sq:getRoom() == room
                    if inRoom ~= (other ~= nil and other:getRoom() == room) then
                        out[#out + 1] = { door = o, square = sq, inRoom = inRoom }
                    end
                end
            end
        end
    end
    return out
end

-- Boards the room's doors from outside it (`planks` { least, most }, closed first); returns where the first is
-- ({ x, y, z, north, opposite }: the barricade on the door's other square) for a plank to drop from (`drop`).
function StageGame.board(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    local lo, hi = (p.planks or { 2, 3 })[1], (p.planks or { 2, 3 })[2]
    local first
    for _, d in ipairs(doorsOf(room)) do
        local o = d.door
        if o:IsOpen() then o:ToggleDoorSilent() end
        if o:isBarricadeAllowed() then
            -- the outside of the room: the door's other square when its own is the room's
            local b = IsoBarricade.AddBarricadeToObject(o, d.inRoom)
            if b then
                for _ = 1, OA.random(lo, hi) do b:addPlank(nil, nil) end
                b:transmitCompleteItemToClients()
                first = first or { x = d.square:getX(), y = d.square:getY(), z = d.square:getZ(), north = o:getNorth(),
                    opposite = d.inRoom }
            end
        end
    end
    return first or (not p.drop and true) or nil
end

-- A plank of a boarded door falls (Stage.progress): it lies on the floor below the barricade, with the sound of it.
function StageGame.unplank(at)
    local sq = getCell():getGridSquare(at.x, at.y, at.z)
    local objects = sq and sq:getObjects()
    for j = 0, (objects and objects:size() or 0) - 1 do
        local o = objects:get(j)
        if instanceof(o, "IsoDoor") and o:getNorth() == at.north then
            local b = at.opposite and o:getBarricadeOnOppositeSquare() or o:getBarricadeOnSameSquare()
            if b and b:getNumPlanks() > 0 then
                local plank = b:removePlank(nil)
                local under = b:getSquare() or sq
                if plank then under:AddWorldInventoryItem(plank, 0.5, 0.5, 0) end
                under:playSound("BreakBarricadePlank")
            end
            return
        end
    end
end

-- Locks the building's outer doors but the entrance (no key: they were shut from inside).
function StageGame.lockout(ctx, p)
    local entrance = ctx.roles and ctx.roles.entrance
    local locked = 0
    for i, d in ipairs(ctx.layout.doors or {}) do
        local o = d.object
        if i ~= entrance and o and instanceof(o, "IsoDoor") and not o:IsOpen() then
            o:setLockedByKey(true)
            locked = locked + 1
        end
    end
    return locked > 0 or nil
end

-- Opens one of the room's windows (one on an edge of its squares, whole and not barricaded; none in a building with an
-- alarm: opening one would set it off).
function StageGame.window(ctx, p)
    local room = roomOf(ctx, p)
    local def = roomDefOf(ctx, p)
    if not room then return nil end
    local building = def:getBuilding()
    if building and building:isAlarmed() then return nil end
    local c = getCell()
    local found = {}
    local squares = room:getSquares()
    for i = 0, squares:size() - 1 do
        local sq = squares:get(i)
        -- a window stands on its square's north or west edge: this square's, or the one east or south of it
        for _, s in ipairs({ sq, c:getGridSquare(sq:getX() + 1, sq:getY(), sq:getZ()), c:getGridSquare(sq:getX(), sq:getY() + 1, sq:getZ()) }) do
            local objects = s and s:getObjects()
            for j = 0, (objects and objects:size() or 0) - 1 do
                local o = objects:get(j)
                if instanceof(o, "IsoWindow") and not o:IsOpen() and not o:isSmashed() and not o:isBarricaded() then
                    found[#found + 1] = o
                end
            end
        end
    end
    if #found == 0 then return nil end
    found[OA.random(1, #found)]:ToggleWindow(nil)
    return true
end

-- A generator on a free square about the piece's spot (or of its room), its fuel as given (0 to 1), not running.
function StageGame.generator(ctx, p)
    local sq = squareFor(ctx, p)
    if not sq then return nil end
    local g = IsoGenerator.new(instanceItem(p.type or "Base.Generator"), getCell(), sq)
    if not g then return nil end
    g:setFuel(g:getMaxFuel() * (p.fuel or 0))
    g:setCondition(p.condition or 80)
    if isServer() then g:transmitCompleteItemToClients() end
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
    local made = false
    for n = 1, p.count or 1 do
        local sq = squareFor(ctx, p)
        if sq then
            local body = RandomizedWorldBase.createRandomDeadBody(sq, nil, 0, 0, p.outfit)
            -- (the key goes with the first)
            local key = n == 1 and p.key and ctx.keyId and instanceItem("Base.Key1")
            if key then key:setKeyId(ctx.keyId) end
            if body then
                if key then body:getContainer():AddItem(key) end
                made = true
            elseif key then
                sq:AddWorldInventoryItem(key, 0.5, 0.5, 0)
            end
        end
    end
    return made or nil
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

-- The mission's own item in the room (`floor`: on its floor, not in a container); outdoors, on the ground about the
-- piece's spot.
function StageGame.piece(ctx, p)
    local def = not outdoors(p) and roomDefOf(ctx, p)
    if not (def or outdoors(p)) then return nil end
    for _, it in ipairs(ctx.m.items or {}) do
        if it.key == p.key and it.staged then
            local done
            if def then
                done = OA.StoryGame.placeInRoom(ctx.record, ctx.m, it, def, p.floor)
            else
                done = OA.StoryGame.placeOnSquare(ctx.record, ctx.m, it, squareFor(ctx, p))
            end
            if done then it.staged = nil end
        end
    end
    return true
end

-- Zombies in an outfit in the room, away from the player (`near`; else the farthest square tried, if it is CLOSE away
-- as Story/Scene allows: the player may have come well inside READY between two looks); returns where each lies
-- ({ x, y, z }) for waking.
function StageGame.zombies(ctx, p)
    local room = not outdoors(p) and roomOf(ctx, p)
    if not (room or outdoors(p)) then return nil end
    local near2 = (ctx.near or 0) * (ctx.near or 0)
    local close = OA.Scene and OA.Scene.CLOSE or 10
    local points = {}
    for _ = 1, p.count or 1 do
        local sq, best, bestD
        for _ = 1, 12 do
            local s = room and room:getRandomFreeSquare() or squareFor(ctx, p, p.reach or 4)
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

-- Wakes what lies fake dead at the points (or a square from them: a body may have slid); with `stagger`, one after
-- another that many real seconds apart (the first at once), in a random order.
function StageGame.wake(points, stagger)
    if stagger and #points > 1 then
        local order = {}
        for _, at in ipairs(points) do table.insert(order, OA.random(1, #order + 1), at) end
        for i, at in ipairs(order) do
            if i == 1 then
                StageGame.wake({ at })
            else
                OA.Trade.Later.after(stagger * (i - 1), function() StageGame.wake({ at }) end)
            end
        end
        return
    end
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
