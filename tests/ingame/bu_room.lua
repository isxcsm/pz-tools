-- The scene bu_attached.lua needs, built by script instead of by hand: a 3x3 room onto the east wall of a map building
-- near the player (the building's wall its west side; wooden walls on the others, a door frame with a door south, a
-- floor, and a roof of floor tiles on the level above), a fridge and a sink in it, a fridge in the yard east of it,
-- and the test panel (ModData BUTEST) in that building. The player is put inside, for RUN("bu_attached.lua") a few
-- seconds later (the game works out the room's region in the background). The room stays; BUROOM has its corner.
--
-- The game's regions see a door only with its frame (a DoorWallN wall), and a square's roof only when the square is
-- told again after the floor above it is laid: both are done here. "[buroom]" lines, ending with "done".
RUN("bu_lib.lua")
local BU = BuildingUtilities
local say = BUT.say("buroom")
local cell = getCell()
local player = getPlayer()
local px, py = math.floor(player:getX()), math.floor(player:getY())
local function at(x, y, z) return cell:getGridSquare(x, y, z) end
local function make(x, y, z)
    local sq = at(x, y, z)
    if not sq then
        sq = IsoGridSquare.new(cell, nil, x, y, z)
        cell:ConnectNewSquare(sq, true)
    end
    return sq
end
local function open(sq) return sq ~= nil and sq:getRoom() == nil and sq:getBuilding() == nil end
local function noRoof(x, y)
    local above = at(x, y, 1)
    return above == nil or above:getFloor() == nil
end

-- A place: three squares in a column outside the building's east wall (a plain wall, no door or window), the room's
-- squares east of it free and unroofed, nothing of a building around them, and a free yard square east of the room.
local function fits(x, y)
    local building
    for j = 0, 2 do
        local s, w = at(x, y + j, 0), at(x - 1, y + j, 0)
        if not (open(s) and w and w:getRoom()) then return nil end
        building = building or w:getBuilding()
        if w:getBuilding() ~= building then return nil end
        if not s:getWall(false) or s:getDoorTo(w) or s:getWindowTo(w) or s:getWindowFrameTo(w) then return nil end
    end
    for i = 0, 2 do
        if not open(at(x + i, y - 1, 0)) then return nil end
        for j = 0, 2 do
            local s = at(x + i, y + j, 0)
            if not (open(s) and s:isFree(false) and s:getFloor() and not s:getWall(true)) then return nil end
            if i > 0 and s:getWall(false) then return nil end
            if not noRoof(x + i, y + j) then return nil end
        end
        local south = at(x + i, y + 3, 0)
        if not (open(south) and not south:getWall(true)) then return nil end
    end
    for j = 0, 2 do
        local east = at(x + 3, y + j, 0)
        if not (open(east) and not east:getWall(false)) then return nil end
    end
    local yard = at(x + 5, y + 1, 0)
    if not (open(yard) and yard:isFree(false) and noRoof(x + 5, y + 1)) then return nil end
    if not at(x + 1, y + 3, 0):isFree(false) then return nil end
    return building
end

local x, y, host, best
for dx = -60, 60 do
    for dy = -60, 60 do
        local building = fits(px + dx, py + dy)
        local d = dx * dx + dy * dy
        if building and (not best or d < best) then x, y, host, best = px + dx, py + dy, building, d end
    end
end
if not x then say("BAD no place near the player: a map building with a plain east wall and a free yard") return end
say("room", x, y, "to", x + 2, y + 2)

-- Floor and roof first, then the walls and the door (the vanilla sprites: wooden wall, wooden door frame, door).
local touched = {}
for i = 0, 2 do
    for j = 0, 2 do
        make(x + i, y + j, 0):addFloor("carpentry_02_57")
        make(x + i, y + j, 1):addFloor("carpentry_02_57")
    end
end
local function wall(wx, wy, north, sprite, open)
    local sq = make(wx, wy, 0)
    local object = IsoThumpable.new(cell, sq, sprite, open, north, nil)
    object:setMaxHealth(500)
    object:setHealth(500)
    sq:AddSpecialObject(object)
    touched[#touched + 1] = sq
    return object
end
for i = 0, 2 do
    wall(x + i, y, true, "walls_exterior_wooden_01_41"):setCanPassThrough(false)
    wall(x + 3, y + i, false, "walls_exterior_wooden_01_40"):setCanPassThrough(false)
    if i ~= 1 then wall(x + i, y + 3, true, "walls_exterior_wooden_01_41"):setCanPassThrough(false) end
end
wall(x + 1, y + 3, true, "walls_exterior_wooden_01_55")
wall(x + 1, y + 3, true, "carpentry_01_49", "carpentry_01_51"):setIsDoor(true)
for z = 0, 1 do
    for i = -1, 3 do
        for j = -1, 3 do
            local sq = at(x + i, y + j, z)
            if sq then
                sq:RecalcAllWithNeighbours(true)
                sq:setSquareChanged()
            end
        end
    end
end

-- The devices: a fridge and a sink (the first sink sprite water can be piped to) in the room, a fridge in the yard.
local function fridge(sq)
    local object = IsoObject.new(cell, sq, "appliances_refrigeration_01_0")
    sq:AddTileObject(object)
    object:createContainersFromSpriteProperties()
end
fridge(at(x + 2, y, 0))
local sink
for i = 0, 63 do
    local sprite = getSprite("fixtures_sinks_01_" .. i)
    if sprite and sprite:getProperties():has(IsoFlagType.waterPiped) then
        sink = "fixtures_sinks_01_" .. i
        break
    end
end
if sink then
    local sq = at(x + 2, y + 2, 0)
    sq:AddTileObject(IsoObject.new(cell, sq, sink))
end
fridge(at(x + 5, y + 1, 0))
say("devices: a fridge in the room, sink", tostring(sink), ", a fridge in the yard at", x + 5, y + 1)

-- The test panel in that building: the one there, or a new one on the nearest free square of the building.
local data = ModData.getOrCreate("BUTEST")
local panel = data.panel and BU.Store.get(data.panel)
local panelSq = panel and at(panel.x, panel.y, panel.z)
if not (panelSq and panelSq:getBuilding() == host) then
    local square, near
    for dx = -12, 0 do
        for dy = -6, 9 do
            local sq = at(x + dx, y + dy, 0)
            if sq and sq:getBuilding() == host and sq:isFree(false) and BU.Panels.canInstall(sq) then
                local d = dx * dx + (dy - 1) * (dy - 1)
                if not near or d < near then square, near = sq, d end
            end
        end
    end
    if not square then say("BAD no square for a panel in the building") return end
    panel = BU.Changes.install(square, BU.PANEL_SPRITES[1])
    data.panel = panel.id
end
say("panel", panel.id, panel.x, panel.y, panel.z, "tier", panel.tier)

player:setX(x + 1.5)
player:setY(y + 1.5)
player:setZ(0)
player:setLastX(x + 1.5)
player:setLastY(y + 1.5)
player:setLastZ(0)
BUROOM = { x = x, y = y }
say("done; the player stands in the room: RUN(\"bu_attached.lua\") in a few seconds")
