-- Rooms built onto a map building (attached rooms) and the game's AllowExteriorGenerator option.
--
-- Set up once: RUN("bu_room.lua") builds all of this near the player (and the test panel in that building), and puts
-- the player inside. By hand instead, in a save with the test panel (bu_setup.lua, in a map building; the default
-- exterior range 10):
--   1. Build a small room against the building from outside: floor, walls on all four sides (one side the building's
--      own wall), a door, and a roof over it (floor tiles on the level above), so that it is enclosed and at least half
--      roofed. Wait a few seconds for the game to settle.
--   2. Put a device that uses power in it (a fridge, a lamp, a radio) and, for the water part, a sink or another
--      fixture that takes water. Stand inside the room, on the ground floor.
--   3. Put another device that uses power outside, in the yard within the exterior range, on a loaded square, and
--      not under the room's roof.
-- Then RUN("bu_attached.lua"). It prints what the game and the API give for the room (no room def, no API building, the
-- game's region), then checks: the room found and counted as part of the building's room it touches; its devices
-- inside, connected, in the box's networks and switched off and on like a room's; the one outside still outside and
-- off. Last the option: AllowExteriorGenerator on, the outside device connected and supplied; off (applied as the
-- server's minute does), it is not supplied and is held as "exterior", the one in the room still is, and the connect
-- menu's reason shows; on again, supplied again; unset, it counts as on. The outside device is disconnected at the end.
-- The devices in the room stay in the box's attached lists, as the box keeps them. "[buatt]" lines, each check "ok"
-- or "BAD", ending with "done".
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Actions, Water = BU.Store, BU.Panels, BU.Changes, BU.Actions, BU.Water
local say = BUT.say("buatt")
local function check(what, got, want)
    say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want))
end

local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
local api = BU.api()
if not panel or not api then say("BAD no test panel or no API"); return end
local building = Panels.building(panel)
if not building then say("BAD the test panel is in no building"); return end
local square = getPlayer():getSquare()
local x, y, z = square:getX(), square:getY(), square:getZ()
local grid = getWorld():getMetaGrid()

-- What the game and the API give for the square the player stands on.
say("square", x, y, z, "building", building.key, "panel", panel.id, "tier", panel.tier)
check("the API has no building at the square", api.buildings.at(x, y, z), nil)
check("the map has no room def there", grid:getRoomAt(x, y, z), nil)
local region = IsoRegions.getIsoWorldRegion(x, y, z)
if region then
    say("region enclosed", tostring(region:isEnclosed()), "roofed", string.format("%.2f", region:getRoofedPercentage()),
        "squares", region:getSquareSize(), "building def", tostring(region:getBuildingDef()))
else
    say("BAD no region at the square")
end

-- The room found. Kept while the API's version of the buildings holds: asked again, nothing is read again.
Panels.forgetRooms()
local rooms = Panels.rooms(building)
check("the buildings' version holds while nothing changes", api.buildings.version() == api.buildings.version(), true)
check("the rooms are kept for it", Panels.rooms(building) == rooms, true)
local spaces = Panels.attached(building)
check("rooms built onto the building found", spaces ~= nil and #spaces >= 1, true)
local space = Panels.attachedAt(spaces, x, y, z)
check("the square is in one", space ~= nil, true)
if not space then say("BAD stand inside the room you built, on the ground floor"); return end
say("space level", space.level, "squares", space.count, "rectangles", #space.rects, "extent", space.extent,
    "host room", space.host)
check("on the player's floor", space.level, z)
check("a square beside the room is in none", Panels.attachedAt(spaces, x + 40, y + 40, z), nil)
local host
for _, room in ipairs(rooms) do
    if room.id == space.host then host = room end
end
check("the host room is one of the building's", host ~= nil, true)
check("its rectangles have the room's after its own", host ~= nil and #host.rects > #space.rects, true)
check("the building's outline reaches the square", BU.Geometry.toLevel(x, y, z, rooms), 0)

-- The room's devices, and the one outside.
local function find(utility)
    local inRoom, outside
    for _, device in ipairs(Panels.devices(panel, utility)) do
        if device.attached and not inRoom then inRoom = device end
        if not device.inside and device.state == "off" and not outside then outside = device end
    end
    return inRoom, outside
end
local function supplied(utility, id, key)
    local list = api.networks.consumers(id)
    local ox, oy, oz, sprite = BU.parseThing(key)
    for index = 1, list and #list or 0 do
        local entry = list[index]
        if entry.x == ox and entry.y == oy and entry.z == oz and entry.sprite == sprite then return true end
    end
    return false
end
local powerId = BU.networkId(panel.id, "power")
local inRoom, outside = find("power")
check("a power device in the room is inside", inRoom ~= nil and inRoom.inside, true)
if inRoom then
    say("device in the room", inRoom.key, "room", inRoom.roomId, "pending", tostring(inRoom.pending))
    check("it is in the host room", inRoom.roomId, space.host)
    check("it is connected by default", inRoom.state, "on")
    Changes.syncAttached(panel)
    check("it is in the box's attached after the sync", panel.power.attached[inRoom.key], true)
    check("the network supplies it", supplied("power", powerId, inRoom.key), true)
    local listed = Panels.device(panel, "power", inRoom.key)
    check("no longer pending", listed and listed.pending, false)
    Changes.setInside(panel, "power", listed, false)
    check("excluded at the box: not supplied", supplied("power", powerId, inRoom.key), false)
    check("excluded: listed off", Panels.device(panel, "power", inRoom.key).state, "off")
    Changes.setInside(panel, "power", Panels.device(panel, "power", inRoom.key), true)
    check("connected again: supplied", supplied("power", powerId, inRoom.key), true)
end
if BU.enabled("water") and BU.waterAvailable() then
    local fixture = find("water")
    if fixture then
        check("a fixture in the room is inside", fixture.inside, true)
        Changes.syncAttached(panel)
        check("it is in the box's attached", panel.water.attached[fixture.key], true)
        local id = Water.useId(BU.Networks.waterLayout(panel), fixture.pipe or Water.FIRST, fixture.building, fixture.level)
        check("its floor's water network supplies it", supplied("water", id, fixture.key), true)
    else
        say("no fixture with water in the room: the water part is skipped")
    end
end
check("a power device outside the room is outside", outside ~= nil, true)
if not outside then say("BAD put a power device in the yard, within the exterior range"); return end
say("device outside", outside.key, "state", outside.state, "steps", Panels.where(panel, outside.entry.x, outside.entry.y))
check("it is off by default", outside.state, "off")
check("it is not attached", outside.attached, nil)

-- The option: AllowExteriorGenerator.
local vars = SandboxVars
local was = vars.AllowExteriorGenerator
vars.AllowExteriorGenerator = true
Changes.applyShape()
check("on: exterior power", BU.exteriorPower(), true)
local cost = Actions.outsideCost(panel, "power", outside)
check("on: the outside device can be connected", cost ~= nil, true)
Changes.includeOutside(panel, "power", outside, {})
check("on: connected outside, the network supplies it", supplied("power", powerId, outside.key), true)
check("on: not held", Panels.device(panel, "power", outside.key).held, nil)
vars.AllowExteriorGenerator = false
Changes.applyShape()
check("off: no exterior power", BU.exteriorPower(), false)
local held = Panels.device(panel, "power", outside.key)
check("off: the outside device is held as exterior", held.held, "exterior")
check("off: still connected at the box", held.state, "on")
check("off: the network does not supply it", supplied("power", powerId, outside.key), false)
if inRoom then check("off: the device in the room is still supplied", supplied("power", powerId, inRoom.key), true) end
Changes.excludeOutside(panel, "power", held)
local cost2, reason = Actions.outsideCost(panel, "power", Panels.device(panel, "power", outside.key))
check("off: connecting is refused", cost2, nil)
check("off: with the reason", reason, "exteriorOff")
local text = getText("IGUI_BU_Reason_" .. tostring(reason))
say("reason shown:", text)
check("off: the reason has a text", text ~= "IGUI_BU_Reason_exteriorOff", true)
vars.AllowExteriorGenerator = true
Changes.applyShape()
check("on again: connecting costs again", Actions.outsideCost(panel, "power", Panels.device(panel, "power", outside.key)) ~= nil, true)
vars.AllowExteriorGenerator = nil
check("unset counts as on", BU.exteriorPower(), true)

-- Put back.
vars.AllowExteriorGenerator = was
Changes.applyShape()
check("put back: the option as found", vars.AllowExteriorGenerator, was)
say("done")
