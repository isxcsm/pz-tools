-- The lines on the ground (BU.FloorLines), at the test panel (bu_setup.lua): a junction box put down in the yard a few
-- squares out and wired to the box, a sprinkler further on wired too; their lines lie on the floor along their routes
-- (Links.route), and the floor pieces the squares want are those of the routes. The player is moved beside the junction
-- box for a look. "[bufloor]" lines, each "ok" or "BAD", ending with "done". Left down for the look; BUFLOOR_UNDO()
-- takes them away and puts the player back.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Units, Links = BU.Store, BU.Panels, BU.Changes, BU.Units, BU.Links
local say = BUT.say("bufloor")
local bad = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", label, got, "want", want)
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local player = getPlayer()
local home = { x = player:getX(), y = player:getY(), z = player:getZ() }
local tierWas = panel.tier or 1
BU.Dev.setTier(panel, 3)

local function yard(from, to, test)
    return BUT.square(panel.x, panel.y, 0, from, to, function(s)
        return s:isOutside() and s:isFree(false) and not Panels.buildingAt(s:getX(), s:getY(), 0) and test(s)
    end)
end
local junctionSquare = yard(6, 14, function(s)
    local place = Links.placeOn(panel, "power", s:getX(), s:getY(), 0, true)
    return Units.canInstall("junction", s) and place ~= nil and place.from == "wall" and place.length >= 4
end)
if not junctionSquare then say("BAD no yard square for a junction box"); return end
local junction = Changes.installUnit("junction", junctionSquare, BU.Relays.SPRITES.junction)
Changes.connectUnit(junction, panel, {})
say("junction box at", junction.x, junction.y)
local sprinklerSquare = yard(8, 16, function(s)
    local place = Links.placeOn(panel, "water", s:getX(), s:getY(), 0)
    return Units.canInstall("sprinkler", s) and place ~= nil and place.length >= 4
        and math.abs(s:getX() - junction.x) + math.abs(s:getY() - junction.y) >= 3
end)
local sprinkler
if sprinklerSquare then
    sprinkler = Changes.installUnit("sprinkler", sprinklerSquare, BU.WaterUnits.SPRINKLER_SPRITES.idle)
    Changes.connectUnit(sprinkler, panel, {})
    say("sprinkler at", sprinkler.x, sprinkler.y)
end

-- Each wired thing's route is on the floor: every square of it wants its utility's piece.
local wanted = BU.FloorLines.wanted()
for _, unit in ipairs({ junction, sprinkler }) do
    local line = Links.get(Links.unitRef(unit))
    local route, z, intoX, intoY = Links.route(line)
    say(unit.kind, "route", #route, "squares, from", route[1].x, route[1].y, "to", route[#route].x, route[#route].y,
        "into", tostring(intoX), tostring(intoY))
    local missing = 0
    for _, square in ipairs(route) do
        local at = wanted[square.x .. "," .. square.y .. "," .. z]
        if not (at and at[line.utility]) then missing = missing + 1 end
    end
    check(unit.kind .. ": every square of its route wants a piece", missing, 0)
    check(unit.kind .. ": the route ends where the line does", route[#route].x ~= unit.x or route[#route].y ~= unit.y, true)
end
BU.FloorLines.refresh()

player:setX(junction.x + 2.5) player:setY(junction.y + 2.5) player:setZ(0)
player:setLastX(junction.x + 2.5) player:setLastY(junction.y + 2.5) player:setLastZ(0)

function BUFLOOR_UNDO()
    if sprinkler then Changes.removeUnit(sprinkler) end
    Changes.removeUnit(junction)
    BU.Dev.setTier(panel, tierWas)
    player:setX(home.x) player:setY(home.y) player:setZ(home.z)
    player:setLastX(home.x) player:setLastY(home.y) player:setLastZ(home.z)
    say("undone")
end
say("done:", bad, "BAD")
