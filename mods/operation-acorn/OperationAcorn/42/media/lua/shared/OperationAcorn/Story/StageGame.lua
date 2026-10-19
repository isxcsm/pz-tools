-- A story site's stage in the game world (server side, and alone): Stage.game points here. Reads the building's layout
-- and puts each kind of piece (Story/StageData). Checked in the game, not by unit tests.
--
-- B42 calls used (checked in the jar): BuildingDef getRooms, isFullyStreamedIn, getKeyId, getX/getY/getX2/getY2;
-- RoomDef getName, getArea, getZ, getX/getY/getX2/getY2, getIsoRoom; IsoRoom getRandomFreeSquare,
-- getRandomWallSquare; IsoGridSquare AddSpecialObject, RecalcProperties, RecalcAllWithNeighbours;
-- IsoObject.new and IsoRadio.new (cell, square, sprite); IsoDoor and IsoWindow getNorth; IsoDoor setLocked, setLockedByKey, setKeyId;
-- IsoBarricade.AddBarricadeToObject(object, onOpposite) then addPlank(nil, nil) and transmitCompleteItemToClients (as
-- the game's own police siege story, RBPoliceSiege, does it); RandomizedWorldBase.createRandomDeadBody(square, nil, 0, 0,
-- outfit) (nil: a random direction); zombies by SceneGame.spawn; addVehicleDebug; IsoDeadBody isFakeDead
-- and reanimateNow (the debug menu's own); IsoObject createContainersFromSpriteProperties and ItemContainer setExplored
-- (as ISMoveableSpriteProps); IsoDoor IsOpen, ToggleDoorSilent, getBarricadeOnSameSquare/OppositeSquare; IsoBarricade
-- getNumPlanks, removePlank(nil); IsoGridSquare playSound ("BreakBarricadePlank"); IsoWindow ToggleWindow(nil) (no
-- character: no barricade asked), BuildingDef isAlarmed, setAlarmed; IsoGenerator.new(item, cell, square), getMaxFuel,
-- setFuel, setCondition (as the game's TimedActionsTests); BaseVehicle createVehicleKey (addKeyToGloveBox does nothing
-- once the car's key was given out as it spawned; a key in the ignition needs a driver: putKeyInIgnition reads the
-- driver's inventory), VehiclePart setContainerContentAmount, getContainerCapacity, getItemContainer. What was a scan of
-- squares is asked of the extension API (squares, objects, buildings: its World queries); its condition tables are
-- constants.
require "OperationAcorn/Core"
require "OperationAcorn/Story/Stage"
require "OperationAcorn/Story/Game"
require "OperationAcorn/Story/SceneGame"
require "OperationAcorn/Trade/Later"
require "OperationAcorn/Sounds"
local OA = OperationAcorn
local StageGame = {}
OA.StageGame = StageGame

-- The site's building: the one whose corner is the site's key. A basement is a building of its own, under the one above
-- it and often reaching past it: the point's building with a room on the site's ground floor first, then any whose box
-- holds the point (getBuildingAtRelax gives the first of the list, the basement as well as the house).
local function defAt(site)
    local grid = getWorld():getMetaGrid()
    local x, y = math.floor(site.x), math.floor(site.y)
    local def = grid:getBuildingAt(x, y, math.max(site.z1 or 0, 0))
    if def and (def:getX() .. "," .. def:getY()) == site.key then return def end
    return def or grid:getBuildingAtRelax(x, y)
end

-- Whether the box's four corners are loaded (the loaded squares are one block round the player: the box is too).
local function boxLoaded(x1, y1, x2, y2, z)
    local c = getCell()
    return c:getGridSquare(x1, y1, z) ~= nil and c:getGridSquare(x2, y2, z) ~= nil
        and c:getGridSquare(x1, y2, z) ~= nil and c:getGridSquare(x2, y1, z) ~= nil
end

-- The site's building is all loaded, or its square is and the player is `close`; and the squares out to
-- Stage.GROUND_RADIUS round it (open ground) or round the building's box (a vehicle outside the entrance, the yard's
-- things).
function StageGame.siteLoaded(site, close)
    local x, y, z = math.floor(site.x), math.floor(site.y), site.z or 0
    if not getCell():getGridSquare(x, y, z) then return false end
    local r = OA.Stage.GROUND_RADIUS
    if site.ground then return boxLoaded(x - r, y - r, x + r, y + r, z) end
    local def = defAt(site)
    return def ~= nil and (close or def:isFullyStreamedIn())
        and boxLoaded(def:getX() - r, def:getY() - r, def:getX2() + r, def:getY2() + r, z)
end

-- An open-ground site is checked for bare ground before its stage goes up (Story/Game: settleGround).
function StageGame.settle(record, m)
    return OA.StoryGame.settleGround(record, m)
end

-- A square of a room that has a floor, or nil: a tall hall's upper "rooms" are its air.
local FLOOR = { floor = true }
local function floorOf(r)
    return OA.api().squares.nearest({ room = r }, FLOOR)
end

-- The doors and the windows on the edges of a building, the doorways with no door too, with the other side in no room;
-- the doors on the edges of a room; the windows.
local OUTER_EDGES = { class = { "IsoDoor", "IsoWindow" } }
local OUTER = { doorways = true, outer = true }
local DOORS = { class = { "IsoDoor" } }
local WINDOWS = { class = { "IsoWindow" } }

-- The building's layout (Story/Stage): its rooms with a floor, and its outer doors and windows on the ground floor. The
-- RoomDefs and the objects ride along (rooms[i].def, doors[i].object, windows[i].object) for the pieces; not saved.
-- A door or a window stands on a square's north or west edge, so an outer one is often on the square outside; one is
-- outer when one side of its edge is in the building and the other in no room (objects.edges). A door is a doorway,
-- with or without a door. (IsoRoom.getWindows is empty in game.) `key` is the API's key of the building.
function StageGame.layout(site)
    local layout = { rooms = {}, doors = {}, windows = {} }
    -- open ground: no rooms, its middle
    if site.ground then
        layout.ground, layout.x, layout.y, layout.z = true, math.floor(site.x), math.floor(site.y), site.z or 0
        return layout
    end
    local def = defAt(site)
    if not def then return layout end
    local api = OA.api()
    local bx1, by1, bx2, by2 = def:getX(), def:getY(), def:getX2(), def:getY2()
    local list = def:getRooms()
    local lowest, ground, key
    for i = 0, list:size() - 1 do
        local r = list:get(i)
        -- (a tall hall's upper "rooms" are its air: no floor, no room for a piece)
        local floor = floorOf(r)
        if floor then
            local x, y, x2, y2 = r:getX(), r:getY(), r:getX2(), r:getY2()
            local entry = { name = r:getName(), area = r:getArea(), z = r:getZ(), x = x, y = y, x2 = x2, y2 = y2,
                edge = x <= bx1 or y <= by1 or x2 >= bx2 or y2 >= by2, def = r, doors = 0 }
            layout.rooms[#layout.rooms + 1] = entry
            local b = not key and api.buildings.at(floor:getX(), floor:getY(), floor:getZ())
            key = key or (b and b.key)
            if not lowest or r:getZ() < lowest then lowest = r:getZ() end
            if r:getZ() == 0 then ground = true end
        end
    end
    if not (lowest and key) then return layout end
    layout.key = key
    -- the ground floor: z 0, or the lowest there is (Stage.roles's floor; a basement is below it)
    if ground then lowest = 0 end
    for _, e in ipairs(api.objects.edges({ building = key, z = lowest }, OUTER_EDGES, OUTER)) do
        local o = e.object
        local at = { x = e.x, y = e.y, z = e.z, north = e.north, object = o, own = e.inside }
        if o and instanceof(o, "IsoWindow") then
            layout.windows[#layout.windows + 1] = at
        else
            layout.doors[#layout.doors + 1] = at
        end
    end
    -- (the stage keeps the roles by index into the doors: the same order whenever it is read)
    table.sort(layout.doors, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        if a.y ~= b.y then return a.y < b.y end
        return a.north and not b.north
    end)
    -- the rooms on the ground floor have a door (one that can be locked)
    for _, entry in ipairs(layout.rooms) do
        if entry.z == lowest then entry.doors = #api.objects.edges({ room = entry.def }, DOORS) end
    end
    return layout
end

-- Puts a sprite on a square as the game's moveables do (ISMoveableSpriteProps): an IsoRadio for a radio's sprite (its
-- device data made from the sprite), a plain object otherwise. Not RandomizedWorldBase.addTileObject: that clears the
-- square first (cleanSquareForStory takes every object but the floor, walls and a desk's other half too).
-- Outdoors, the plants of the map's natural detail tiles (d_plants, d_generic: ferns, flowers) on a square a thing is
-- put on: it would stand in them, leaves through its top. The grass stays.
local function clearPlants(sq)
    if sq:getRoom() then return end
    local objects = sq:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local o = objects:get(i)
        local spr = o:getSprite()
        local name = spr and spr:getName()
        if name and string.sub(name, 1, 2) == "d_" then sq:transmitRemoveItemFromSquare(o) end
    end
end

local function put(sq, sprite, on)
    local spr = sq and getSprite(sprite)
    if not spr then return nil end
    clearPlants(sq)
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

-- Whether a room has a window on its edge.
local function hasWindow(def)
    return #OA.api().objects.edges({ room = def }, WINDOWS) > 0
end

-- The room of the layout a piece asks for by name or floor: with `up`, the largest on the floor above the ground floor
-- with a window (one named in `names` first; one without a window when none has one; on the ground floor when there is
-- no floor above); with `names` alone, the largest so named on any floor. The room is kept for the piece's `at` in the
-- stage (st.picked: its index in the layout) for every later piece of that `at`, and another `at` takes another room.
local function pickRoom(ctx, p)
    local rooms = ctx.layout and ctx.layout.rooms or {}
    local st = ctx.m and ctx.m.stage
    local picked = st and (st.picked or {})
    if st then st.picked = picked end
    if picked and p.at and picked[p.at] then return rooms[picked[p.at]] end
    local taken = {}
    for _, i in pairs(picked or {}) do taken[i] = true end
    local ground = OA.Stage.groundFloor(rooms)
    local named = {}
    for _, n in ipairs(p.names or {}) do named[n] = true end
    local function pick(z, lit)
        local best, bestNamed
        for i, r in ipairs(rooms) do
            if not taken[i] and (not z or r.z == z) and (r.area or 0) >= OA.Stage.ROOM_AREA
                and (not lit or hasWindow(r.def)) then
                if named[r.name or ""] and (not bestNamed or r.area > bestNamed.area) then bestNamed = r end
                if not best or r.area > best.area then best = r end
            end
        end
        return best, bestNamed
    end
    -- (a house of one floor: the ground floor's instead)
    local chosen
    if p.up then
        local up = (ground or 0) + 1
        local best, bestNamed = pick(up, true)
        if not best then best, bestNamed = pick(up) end
        if not best then best, bestNamed = pick(ground or 0, true) end
        if not best then best, bestNamed = pick(ground or 0) end
        chosen = bestNamed or best
    else
        local _, bestNamed = pick(nil)
        chosen = bestNamed
    end
    if chosen and picked and p.at then
        for i, r in ipairs(rooms) do
            if r == chosen then picked[p.at] = i end
        end
    end
    return chosen
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
local FREE_OUTSIDE = { room = "none", free = true }
local function freeNear(x, y, z, reach)
    return OA.api().squares.nearest({ x = x, y = y, z = z, to = reach or 0 }, FREE_OUTSIDE)
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

-- Keeps the site's building from the game's own stories (Stage.begin): they are set up as a building first loads
-- (RandomizedBuildingBase.ChunkLoaded), and not in one with a room already seen. Its smallest room is marked seen:
-- that room alone spawns no zombies of its own when first seen (the stage makes its own).
function StageGame.claim(site)
    local def = site and not site.ground and defAt(site)
    if not def then return end
    local rooms = def:getRooms()
    local small
    for i = 0, rooms:size() - 1 do
        local r = rooms:get(i)
        if not small or r:getArea() < small:getArea() then small = r end
    end
    if small then small:setExplored(true) end
end

-- Whether the site's building was taken before the stage (Stage.place): a door or a window boarded, something built
-- in it (survivors', a player's), a square burnt out.
local BURNT_OUT = { flags = { "burntOut" } }
local BUILT = { class = { "IsoThumpable" } }
local ONE = { limit = 1 }
function StageGame.occupied(ctx)
    local l = ctx.layout
    if not l or l.ground then return false end
    for _, list in ipairs({ l.doors or {}, l.windows or {} }) do
        for _, at in ipairs(list) do
            if at.object and at.object:isBarricaded() then return true end
        end
    end
    if not l.key then return false end
    local api = OA.api()
    local area = { building = l.key }
    return api.squares.nearest(area, BURNT_OUT) ~= nil or #api.objects.find(area, BUILT, ONE) > 0
end

-- What clearing a room takes: a moveable standing on the floor (MoveType Object, as ISMoveableSpriteProps reads it), not
-- one on a wall or a window, a rug or a floor tile; the building's own fixtures (doors, windows, curtains, boards) and
-- what a player built stay. A furniture holding a mission's item (one placed before its stage went up: a revisit's, in
-- the building its story set up) stays, all of it.
local FURNITURE = { props = { "IsMoveAble" }, propIn = { MoveType = { "Object", false } },
    notClass = { "IsoDoor", "IsoWindow", "IsoCurtain", "IsoBarricade", "IsoThumpable", "IsoGenerator" } }
local KEEP_MISSION = { keep = { holds = { data = "OA_Mission" } } }

-- Clears open ground of its trees and bushes (what the game cuts as a bush: canBeCut, as ISRemovePlantCursor) in a
-- ragged ring round its middle: all of them out to Stage.CLEAR_INNER squares, fewer and fewer out to CLEAR_RADIUS, so
-- the clearing runs into the woods round it. The grass stays.
local TREES = { class = { "IsoTree" } }
local BUSHES = { props = { "canBeCut" } }
local OUTDOORS = { room = "none" }
local function clearGround(l)
    local inner, r = OA.Stage.CLEAR_INNER, OA.Stage.CLEAR_RADIUS
    local area = { x = l.x, y = l.y, z = l.z, r = r }
    local options = { squares = OUTDOORS, falloff = { x = l.x, y = l.y, inner = inner, outer = r } }
    local objects = OA.api().objects
    objects.remove(area, TREES, options)
    objects.remove(area, BUSHES, options)
end

-- Clears the room a set goes to of its furniture, once (Stage.place, before any piece): the team made room for it.
-- Its containers go with it, and what was in them, but a mission's item (KEEP_MISSION). Open ground ("ground"): its trees
-- and bushes (clearGround).
function StageGame.clear(ctx, p)
    if p.at == "ground" then
        if ctx.layout and ctx.layout.ground then clearGround(ctx.layout) end
        return true
    end
    local room = roomOf(ctx, p)
    if not room then return nil end
    ctx.cleared = ctx.cleared or {}
    if ctx.cleared[room] then return true end
    ctx.cleared[room] = true
    OA.api().objects.remove({ room = room }, FURNITURE, KEEP_MISSION)
    return true
end

-- Sprites placed together: an anchor square of the room (outdoors: about the piece's spot, within `reach`, else 3)
-- where every square of the set is free, by no door and in the room (outdoors: in none); with `more`, those too where
-- they fit with it, else the set alone. `count` sets of it, each where it fits.
local SET_INSIDE = { free = true, room = "anchor", doorEdge = false }
local SET_OUTSIDE = { free = true, room = "none", doorEdge = false }
local RANDOM_ORDER = { order = "random" }
function StageGame.set(ctx, p)
    local room = not outdoors(p) and roomOf(ctx, p)
    if not (room or outdoors(p)) then return nil end
    local area, filter
    if room then
        area, filter = { room = room }, SET_INSIDE
    else
        local x, y, z = spotOf(ctx, p)
        if not x then return nil end
        local reach = p.reach or 3
        area, filter = { x1 = x - reach, y1 = y - reach, x2 = x + reach, y2 = y + reach, z = z }, SET_OUTSIDE
    end
    -- An anchor where the list fits, as a list of it (none: empty). The anchors are looked at in a new random order
    -- each time and the first that fits is it: as random as a pick among all that fit, without trying them all (a large
    -- room has a thousand squares, and a set is tried for each of its copies).
    local function anchors(list)
        local offsets = {}
        for _, t in ipairs(list) do
            offsets[#offsets + 1] = t[1]
            offsets[#offsets + 1] = t[2]
        end
        local a = OA.api().squares.fit(area, { { offsets = offsets, filter = filter } }, RANDOM_ORDER)
        return a and { a } or {}
    end
    local placed = false
    for _ = 1, p.count or 1 do
        local first = StageGame.setOnce(p, anchors)
        if first then
            placed = true
            -- `top`: its first tile's top takes the room's piece asked there (the roll on the reception desk)
            if p.top and first ~= true and not (ctx.tops and ctx.tops[p.at]) then
                ctx.tops = ctx.tops or {}
                ctx.tops[p.at] = first
            end
        end
    end
    return placed or nil
end

-- One of a set's copies (StageGame.set): where the set and `more` fit, else the set alone; with `fewer` (a row), its
-- first tiles down to that many where the whole row does not fit.
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
    local n = #p.tiles - 1
    while #fits == 0 and p.fewer and n >= p.fewer do
        tiles = {}
        for k = 1, n do tiles[k] = p.tiles[k] end
        fits = anchors(tiles)
        n = n - 1
    end
    if #fits == 0 then return nil end
    local a = fits[OA.random(1, #fits)]
    local first
    for _, t in ipairs(tiles) do
        local obj = put(c:getGridSquare(a:getX() + t[1], a:getY() + t[2], a:getZ()), t[3], p.on)
        first = first or obj
    end
    return first or true
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

-- Whether the world spawns a vehicle script: it is in one of the game's zone lists (VehicleZoneDistribution; a mod
-- that keeps vanilla's vehicles off the roads takes them out of these).
local function spawns(script)
    for _, zone in pairs(VehicleZoneDistribution or {}) do
        if type(zone) == "table" and type(zone.vehicles) == "table" and zone.vehicles[script] then return true end
    end
    return false
end

-- Whether a vehicle script has the parts a piece works on: its doors to open, a truck bed or trunk for its load, the
-- gas tank for its fuel, the battery.
local function fits(script, p)
    local s = getScriptManager():getVehicle(script)
    if not s then return false end
    for _, id in ipairs(type(p.open) == "table" and p.open or { p.open }) do
        if not s:getPartById(id) then return false end
    end
    if p.load and not (s:getPartById("TruckBed") or s:getPartById("TrunkDoor")) then return false end
    if p.fuel and not s:getPartById("GasTank") then return false end
    if p.battery and not s:getPartById("Battery") then return false end
    return true
end

-- One of a zone list's vehicles that fits the piece, by the list's spawn chances; nil when none does.
local function fromZone(name, p)
    local zone = VehicleZoneDistribution and VehicleZoneDistribution[name]
    if type(zone) ~= "table" or type(zone.vehicles) ~= "table" then return nil end
    local list, total = {}, 0
    for script, entry in pairs(zone.vehicles) do
        local weight = type(entry) == "table" and tonumber(entry.spawnChance) or 1
        if weight > 0 and fits(script, p) then
            list[#list + 1] = { script = script, weight = weight }
            total = total + weight
        end
    end
    if total <= 0 then return nil end
    table.sort(list, function(a, b) return a.script < b.script end)
    local roll = OA.randomFloat(0, total)
    for _, e in ipairs(list) do
        roll = roll - e.weight
        if roll <= 0 then return e.script end
    end
    return list[#list].script
end

-- The vehicle a piece gets: while the world spawns its own script, one of its first zone's (`zones`) that fits, else
-- the script; in a world that does not (a mod's vehicles in place of vanilla's), one of the first of its zones that
-- has one that fits, else the script.
local function vehicleFor(p)
    local zones = p.zones or {}
    if spawns(p.script) then
        return (zones[1] and fromZone(zones[1], p)) or p.script
    end
    for _, name in ipairs(zones) do
        local script = fromZone(name, p)
        if script then return script end
    end
    return p.script
end

-- The squares of a vehicle's body: free ground outside, no vehicle on it; the margin round it: no vehicle, and free
-- too the first time round.
local VEHICLE_BODY = { free = true, room = "none", vehicle = false, wet = false }
local VEHICLE_ROOMY = { free = true, vehicle = false }
local VEHICLE_MARGIN = { vehicle = false }

-- A vehicle outside the entrance (or the role's door: "back"), along the wall: the first spot a few squares out (4, 3,
-- 5, 6; straight out, then to either side) where its body (5 squares along the wall, 3 across) is free ground outside
-- and no vehicle stands within a square of it (a parked car there already); first a spot where the square around the
-- body is free too (a long pickup's nose, a swing set, the stage's garden chairs at its side), else the body alone. On open ground: about the piece's spot,
-- lying north to south (`across`: east to west). Doors open (`open`: a part id, or a list), the battery and the fuel
-- as given, its key in the glove box (`key`). Which vehicle: vehicleFor (the world's own, by `zones`).
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
    -- the body's squares and the margin round it, as offsets from the spot
    local body, margin = {}, {}
    for l = -3, 3 do
        for w = -2, 2 do
            local list = (l >= -2 and l <= 2 and w >= -1 and w <= 1) and body or margin
            list[#list + 1] = ax * l + dx * w
            list[#list + 1] = ay * l + dy * w
        end
    end
    local sq
    local outs = p.at == "ground" and { 0, 1, -1, 2, -2 } or { 4, 3, 5, 6 }
    for _, roomy in ipairs({ true, false }) do
        local spots = {}
        for _, k in ipairs(outs) do
            for _, side in ipairs({ 0, 3, -3, 6, -6 }) do
                spots[#spots + 1] = out:getX() + dx * k + ax * side
                spots[#spots + 1] = out:getY() + dy * k + ay * side
                spots[#spots + 1] = z
            end
        end
        sq = OA.api().squares.fit({ list = spots }, { { offsets = body, filter = VEHICLE_BODY },
            { offsets = margin, filter = roomy and VEHICLE_ROOMY or VEHICLE_MARGIN } })
        if sq then break end
    end
    if not sq then return nil end
    local dir = dx ~= 0 and IsoDirections.N or IsoDirections.E
    local car = addVehicleDebug(vehicleFor(p), dir, nil, sq)
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
    -- its key in the glove box (the game may have given its own to a zombie or a house as the car spawned)
    local glove = (p.key or p.piece) and car:getPartById("GloveBox")
    local box = glove and glove:getItemContainer()
    local key = p.key and box and car:createVehicleKey()
    if key then
        box:AddItem(key)
        car:transmitPartItem(glove)
    end
    -- a wreck: its parts battered, some taken out, glass on the ground (the API's one call over all its parts)
    local vehicles = p.wreck and OA.api().vehicles
    if vehicles and vehicles.damage then vehicles.damage(car, p.wreck) end
    -- the mission's piece it holds, in the glove box
    if p.piece and box then
        for _, it in ipairs(ctx.m.items or {}) do
            if it.key == p.piece and it.staged and OA.StoryGame.placeInContainer(ctx.record, ctx.m, it, box, sq) then
                it.staged = nil
                car:transmitPartItem(glove)
            end
        end
    end
    return true
end

-- The planks a window or a door is boarded with when the piece names none ({ least, most }), and the condition a
-- generator is put with.
StageGame.PLANKS = { 2, 3 }
StageGame.GENERATOR_CONDITION = 80

local function planksOf(p)
    local planks = p.planks or StageGame.PLANKS
    return planks[1], planks[2]
end

-- Boards on the inside of the ground floor's windows.
function StageGame.barricade(ctx, p)
    local lo, hi = planksOf(p)
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
-- A door stands on a square's north or west edge, so one in the room's south or east wall is on the square outside.
local function doorsOf(room)
    local c = getCell()
    local out = {}
    for _, e in ipairs(OA.api().objects.edges({ room = room }, DOORS)) do
        out[#out + 1] = { door = e.object, square = c:getGridSquare(e.x, e.y, e.z), inRoom = e.inside }
    end
    return out
end

-- Boards the room's doors from outside it (`planks` { least, most }, closed first); returns where the first is
-- ({ x, y, z, north, opposite }: the barricade on the door's other square) for a plank to drop from (`drop`), and in
-- it `all`, every door boarded so (for the last plank taken off: `last`).
function StageGame.board(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    local lo, hi = planksOf(p)
    local first
    local all = {}
    for _, d in ipairs(doorsOf(room)) do
        local o = d.door
        if o:IsOpen() then o:ToggleDoorSilent() end
        if o:isBarricadeAllowed() then
            -- the outside of the room: the door's other square when its own is the room's
            local b = IsoBarricade.AddBarricadeToObject(o, d.inRoom)
            if b then
                for _ = 1, OA.random(lo, hi) do b:addPlank(nil, nil) end
                b:transmitCompleteItemToClients()
                local at = { x = d.square:getX(), y = d.square:getY(), z = d.square:getZ(), north = o:getNorth(),
                    opposite = d.inRoom }
                all[#all + 1] = at
                first = first or { x = at.x, y = at.y, z = at.z, north = at.north, opposite = at.opposite }
            end
        end
    end
    if first then
        first.all = all
        return first
    end
    -- nothing boarded: fine for a stage that only wants the doors boarded, no use for one that drops from a plank
    if p.drop then return nil end
    return true
end

-- The door at a boarded place ({ x, y, z, north }), or nil.
local function doorAt(at)
    local sq = getCell():getGridSquare(at.x, at.y, at.z)
    local objects = sq and sq:getObjects()
    for j = 0, (objects and objects:size() or 0) - 1 do
        local o = objects:get(j)
        if instanceof(o, "IsoDoor") and o:getNorth() == at.north then return o end
    end
    return nil
end

-- Whether a boarded place has no planks left on the side it was boarded from (an unloaded one counts as not yet).
function StageGame.unboardedAt(at)
    local o = doorAt(at)
    if not o then return false end
    local b = at.opposite and o:getBarricadeOnOppositeSquare() or o:getBarricadeOnSameSquare()
    return b == nil or b:getNumPlanks() == 0
end

-- Blocks the room's ways in but one from inside with a hospital bed (the ward shut itself in): its doors to the
-- outside or to a hall (not to a side room, a bathroom or a closet), a bed of two squares reaching into the room from
-- the door where both are free. The one left is the first such door found.
local BLOCK_BED = { north = { "location_community_medical_01_17", "location_community_medical_01_16" },
    west = { "location_community_medical_01_20", "location_community_medical_01_21" } }
local function wayIn(d, c)
    local o = d.door
    local x, y, z = d.square:getX(), d.square:getY(), d.square:getZ()
    local other = d.inRoom and (o:getNorth() and c:getGridSquare(x, y - 1, z) or c:getGridSquare(x - 1, y, z)) or d.square
    local r = other and other:getRoom()
    return r == nil or OA.Stage.HALL[r:getName() or ""] == true
end
function StageGame.block(ctx, p)
    local room = roomOf(ctx, p)
    if not room then return nil end
    local c = getCell()
    local doors = {}
    for _, d in ipairs(doorsOf(room)) do
        if wayIn(d, c) then doors[#doors + 1] = d end
    end
    if #doors < 2 then return nil end
    local blocked = 0
    for i = 2, #doors do
        local d = doors[i]
        local o = d.door
        if o:IsOpen() then o:ToggleDoorSilent() end
        local x, y, z = d.square:getX(), d.square:getY(), d.square:getZ()
        local north = o:getNorth()
        -- the square inside the door, and the way into the room from it
        if not d.inRoom then
            if north then y = y - 1 else x = x - 1 end
        end
        local step = d.inRoom and 1 or -1
        local a = c:getGridSquare(x, y, z)
        local b = north and c:getGridSquare(x, y + step, z) or c:getGridSquare(x + step, y, z)
        local function fits(s) return s and s:getRoom() == room and s:isFree(false) end
        if fits(a) and fits(b) then
            -- the bed's first tile is the one nearer the room's top or left
            local lo, hi = a, b
            if step < 0 then lo, hi = b, a end
            local pair = north and BLOCK_BED.north or BLOCK_BED.west
            put(lo, pair[1])
            put(hi, pair[2])
            blocked = blocked + 1
        end
    end
    return blocked > 0 or nil
end

-- The player took planks off a door (vanilla's unbarricade action, below): a stage whose boarded doors are all bare
-- now hears it (Stage.unboarded).
function StageGame.unbarricaded(character)
    local record = OA.Trade and OA.Trade.Actions and OA.Trade.Actions.recordOf and OA.Trade.Actions.recordOf(character)
    if record and OA.Stage then OA.Stage.unboarded(record) end
end

-- (not while the mod is off: OA.off)
if not OA.off and ISUnbarricadeAction and not ISUnbarricadeAction.OA_stage then
    local complete = ISUnbarricadeAction.complete
    ISUnbarricadeAction.OA_stage = true
    function ISUnbarricadeAction:complete()
        local result = complete(self)
        OA.try("stage: a barricade taken down", StageGame.unbarricaded, self.character)
        return result
    end
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
                PZUIKit.Sound.at("oa.stage.plank", under)
            end
            return
        end
    end
end

-- Unlocks the role's outer door (the entrance) when the game locked it: IsoDoor's locked flag too, as checkKeyId turns
-- a locked door with a key id back into one locked by key.
function StageGame.unlock(ctx, p)
    local i = ctx.roles and ctx.roles[p.at or "entrance"]
    local d = i and ctx.layout.doors[i]
    local o = d and d.object
    if not (o and instanceof(o, "IsoDoor")) then return nil end
    o:setLocked(false)
    o:setLockedByKey(false)
    return true
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

-- Opens one of the room's windows (one on an edge of its squares, whole and not barricaded); a building's alarm is
-- off (its people left by it, the window open). With `chair` ({ N, S, W, E } sprites by the way it faces): a chair on the
-- square inside it, turned to it (a window with a free square inside first).
function StageGame.window(ctx, p)
    local room = roomOf(ctx, p)
    local def = roomDefOf(ctx, p)
    if not room then return nil end
    local building = def:getBuilding()
    if building and building:isAlarmed() then building:setAlarmed(false) end
    local c = getCell()
    local found, free = {}, {}
    for _, e in ipairs(OA.api().objects.edges({ room = room }, WINDOWS)) do
        local o = e.object
        if not o:IsOpen() and not o:isSmashed() and not o:isBarricaded() then
            -- a window stands on its square's north or west edge: the room's square is its own (the chair faces N or
            -- W), or the one north or west of it (the chair faces S or E)
            local sq, facing
            if e.inside then
                sq, facing = c:getGridSquare(e.x, e.y, e.z), e.north and "N" or "W"
            elseif e.north then
                sq, facing = c:getGridSquare(e.x, e.y - 1, e.z), "S"
            else
                sq, facing = c:getGridSquare(e.x - 1, e.y, e.z), "E"
            end
            if sq then
                local at = { window = o, square = sq, facing = facing }
                found[#found + 1] = at
                if sq:isFree(false) then free[#free + 1] = at end
            end
        end
    end
    if #found == 0 then return nil end
    local list = (p.chair and #free > 0) and free or found
    local at = list[OA.random(1, #list)]
    at.window:ToggleWindow(nil)
    if p.chair and at.square:isFree(false) then put(at.square, p.chair[at.facing]) end
    return true
end

-- A generator on a free square about the piece's spot (or of its room), its fuel as given (0 to 1), not running.
function StageGame.generator(ctx, p)
    local sq = squareFor(ctx, p)
    if not sq then return nil end
    local g = IsoGenerator.new(instanceItem(p.type or "Base.Generator"), getCell(), sq)
    if not g then return nil end
    g:setFuel(g:getMaxFuel() * (p.fuel or 0))
    g:setCondition(p.condition or StageGame.GENERATOR_CONDITION)
    if isServer() then g:transmitCompleteItemToClients() end
    return true
end

-- Locks the room's doors with the building's key; returns the key's id. The game gives a door a key id only between
-- the building and outside (IsoDoor.checkKeyId): an inner door locked by key with none opens to no key, so it takes
-- the building's here.
function StageGame.lock(ctx, p)
    local room = roomOf(ctx, p)
    local def = roomDefOf(ctx, p)
    if not room then return nil end
    local doors = doorsOf(room)
    if #doors == 0 then return nil end
    local keyId = def:getBuilding():getKeyId()
    for _, d in ipairs(doors) do
        if d.door:IsOpen() then d.door:ToggleDoorSilent() end
        d.door:setKeyId(keyId)
        d.door:setLockedByKey(true)
    end
    return keyId
end

-- A body in an outfit in the room; with `key`, the building's key in its pockets. A world with no zombies makes no
-- random bodies (createRandomDeadBody looks at IsoWorld.getZombiesDisabled): there the body is a zombie spawned and
-- laid down as the fake dead are (SceneGame.spawn), only not to get up. The key is left on the floor if none is made.
local function deadBody(sq, outfit)
    local b = RandomizedWorldBase.createRandomDeadBody(sq, nil, 0, 0, outfit)
    if b or not IsoWorld.getZombiesDisabled() then return b end
    local zombie = OA.SceneGame.spawn(sq, outfit)
    return zombie and IsoDeadBody.new(zombie, false) or nil
end

function StageGame.corpse(ctx, p)
    local made = false
    for n = 1, p.count or 1 do
        local sq = squareFor(ctx, p)
        if sq then
            local body = deadBody(sq, p.outfit)
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
            -- on the top of the room's set when it asks for it (the roll on the reception desk)
            local top = p.top and ctx.tops and ctx.tops[p.at]
            local done = top and OA.StoryGame.placeOnSurface(ctx.record, ctx.m, it, top)
            if not done and def then
                done = OA.StoryGame.placeInRoom(ctx.record, ctx.m, it, def, p.floor)
            elseif not done then
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
            OA.SceneGame.spawn(sq, p.outfit, p.female, false, p.look == "fakeDead", p.look == "sitting")
            points[#points + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
        end
    end
    return points
end

local AROUND = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }

-- Where a thing that sounds on an event stands (`call`): the nearest square about its spot with its sprite (the set
-- put it there), as { x, y, z }; nil when the set did not go down.
function StageGame.call(ctx, p)
    local x, y, z = spotOf(ctx, p)
    if not x then return nil end
    local found = OA.api().objects.find({ x = x, y = y, z = z, to = (p.reach or 1) + 1 }, { sprite = { p.sprite } }, ONE)[1]
    local sq = found and found:getSquare()
    return sq and { x = sq:getX(), y = sq:getY(), z = z } or nil
end

-- Things sounding once ({ x, y, z, sound = a cue of OA.Sounds, secs }): each from a free emitter on its square, stopped
-- after its seconds.
-- Only an emitter's sound: no world sound, so zombies are not drawn.
function StageGame.sound(list)
    for _, at in ipairs(list) do
        local emitter = getWorld():getFreeEmitter(at.x + 0.5, at.y + 0.5, at.z)
        local name = emitter and PZUIKit.Sound.name(at.sound)
        local id = name and emitter:playSound(name)
        if id and id ~= 0 and at.secs then
            OA.Trade.Later.after(at.secs, function() emitter:stopSound(id) end)
        end
    end
end

-- Wakes what lies fake dead at the points (or a square from them); with `stagger`, one after
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
        -- its own square first: one lying next to it is another point's
        for _, d in ipairs(AROUND) do
            local sq = not done and c:getGridSquare(at.x + d[1], at.y + d[2], at.z)
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

function StageGame.request(record, m, it)
    OA.StoryGame.request(record, m, it)
end

return StageGame
