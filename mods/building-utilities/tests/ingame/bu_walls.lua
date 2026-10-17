-- Rooms that follow the walls (RoomWalls, PZExtAPI.buildings.watchWalls), in a map building near the player: a plain
-- wall between two of its rooms is taken down (the two become one) and built again (one becomes two), the player
-- standing in the building. The ticks over 40 ms are listed for each stretch (settling, idle, after each change), with
-- what the changes and setRooms took, for a spike the work would make. BUWALLS_NOSET=true first leaves the rooms unset
-- (the game's own cost of a wall alone). "[buwalls]" lines over about 10 seconds, ending with "done: N BAD". The
-- building keeps the wall and its rooms.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local say = BUT.say("buwalls")
local bad = 0
local function check(what, ok, got)
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", what, tostring(got))
end

local found = BU.api()
local player = getPlayer()
local here = player:getCurrentSquare()
local current = here and here:getBuilding()

-- A plain wall on the north side of a room's square, another room of the same map building north of it.
local function wallBetween(sq)
    local room, north = sq:getRoom(), getCell():getGridSquare(sq:getX(), sq:getY() - 1, sq:getZ())
    if not room or not north or not north:getRoom() or north:getRoom() == room then return false end
    local building = sq:getBuilding()
    if not building or building ~= north:getBuilding() or building == current then return false end
    local wall = sq:getWall(true)
    if not wall or sq:getDoorTo(north) or sq:getWindowTo(north) or sq:getWindowFrameTo(north) then return false end
    local info = found.buildings.at(sq:getX(), sq:getY(), sq:getZ())
    return info ~= nil and not info.playerBuilt
end

local sq = BUT.squareNear(1, 40, wallBetween)
if not sq then say("no wall between two rooms of another map building near the player") say("done: 1 BAD") return end
local north = getCell():getGridSquare(sq:getX(), sq:getY() - 1, sq:getZ())
local wall = sq:getWall(true)
local sprite = wall:getSprite():getName()
local southName, northName = sq:getRoom():getName(), north:getRoom():getName()
say("wall", sprite, "at", sq:getX(), sq:getY(), sq:getZ(), "between", southName, "and", northName)

-- What the API tells: wrapped before the watch starts (the player moves into the building after this).
local told = {}
local onWalls = BU.RoomWalls.onWalls
BU.RoomWalls.onWalls = function(key, rooms)
    local start = getTimestampMs()
    if not BUWALLS_NOSET then onWalls(key, rooms) end
    told[#told + 1] = { rooms = #rooms, ms = getTimestampMs() - start }
end

-- The wall's square as a mod watching it hears of it (the game's square changes, which the walls' watch hears too).
local heard = 0
local handle = BU.handle()
local squareWatch = found.squares.watch(handle, { sq:getX(), sq:getY(), sq:getZ() }, function() heard = heard + 1 end)

player:setX(sq:getX() + 0.5) player:setY(sq:getY() + 0.5) player:setZ(sq:getZ())
player:setLastX(sq:getX() + 0.5) player:setLastY(sq:getY() + 0.5) player:setLastZ(sq:getZ())

-- The steps, a number of ticks apart: settle, idle (the ticks with nothing done, to compare), take down, look, build, look.
-- The ticks over 40 ms of each stretch are listed as tick:ms, the tick counted from the stretch's start.
local steps, step, ticks, last, slow = {}, 1, 0, nil, {}
local function slowTicks()
    local text = #slow == 0 and "none" or table.concat(slow, " ")
    slow = {}
    return text
end
-- A call's own time, in ms.
local function timed(call)
    local start = getTimestampMs()
    call()
    return getTimestampMs() - start
end

steps[1] = { wait = 150, run = function()
    check("rooms untold before a change", #told == 0, #told)
    say("slow ticks, settling:", slowTicks())
end }
steps[2] = { wait = 90, run = function()
    say("slow ticks, idle:", slowTicks())
    say("taking the wall down took", timed(function() sq:transmitRemoveItemFromSquare(wall) end), "ms")
end }
steps[3] = { wait = 90, run = function()
    say("slow ticks after the wall came down:", slowTicks(), "; its square heard of", heard, "times")
    heard = 0
    check("told once", #told == 1, #told)
    if told[1] then say("onWalls (setRooms) took", told[1].ms, "ms for", told[1].rooms, "rooms") end
    check("the two rooms are one", sq:getRoom() ~= nil and sq:getRoom() == north:getRoom(), sq:getRoom() and sq:getRoom():getName())
    local again = IsoObject.new(getCell(), sq, sprite)
    say("building the wall took", timed(function() sq:transmitAddObjectToSquare(again, -1) end), "ms")
end }
steps[4] = { wait = 90, run = function()
    say("slow ticks after the wall went up:", slowTicks(), "; its square heard of", heard, "times")
    found.squares.unwatch(handle, squareWatch)
    check("told again", #told == 2, #told)
    if told[2] then say("onWalls (setRooms) took", told[2].ms, "ms for", told[2].rooms, "rooms") end
    local south, back = sq:getRoom(), north:getRoom()
    check("one room is two again", south ~= nil and back ~= nil and south ~= back,
        tostring(south and south:getName()) .. " / " .. tostring(back and back:getName()))
    check("each with its name back", south ~= nil and back ~= nil and south:getName() == southName and back:getName() == northName,
        tostring(south and south:getName()) .. " / " .. tostring(back and back:getName()))
    BU.RoomWalls.onWalls = onWalls
    say("done: " .. bad .. " BAD")
end }

BUWALLS_TICK = function()
    local now = getTimestampMs()
    local due = steps[step]
    if last and due and now - last > 40 then slow[#slow + 1] = ticks .. ":" .. (now - last) end
    last = now
    if not due then return end
    ticks = ticks + 1
    if ticks < due.wait then return end
    ticks = 0
    step = step + 1
    local ok, err = pcall(due.run)
    if not ok then say("ERROR", tostring(err)) say("done: 1 BAD") step = #steps + 1 end
end
-- Added once (a handler taken out while the event runs costs the next one its call); a run again replaces the function.
if not BUWALLS_HOOKED then
    BUWALLS_HOOKED = true
    Events.OnTick.Add(function() if BUWALLS_TICK then BUWALLS_TICK() end end)
end
