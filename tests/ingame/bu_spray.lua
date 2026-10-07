-- The sprinkler's spray going round (client/BuildingUtilities/SprinklerSpray.lua): a sprinkler put down near the
-- player and wired to the test panel, as if it had just watered; its sprite read over a second and a half.
-- "[buspray]" lines. BUSPRAY_CLEAN() takes it away.
local BU = BuildingUtilities
local Store, Changes, Units, WaterUnits = BU.Store, BU.Changes, BU.Units, BU.WaterUnits
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
local p = getPlayer():getSquare()
local square
for r = 1, 6 do
    for dy = -r, r do
        for dx = -r, r do
            local q = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, 0)
            if not square and q and q:isOutside() and q:getObjects():size() == 1 and q:isFree(false) then square = q end
        end
    end
end
for _, name in ipairs(WaterUnits.SPRINKLER_SPRITES.spraying) do
    local sprite = getSprite(name)
    if not sprite or not sprite:getTextureForCurrentFrame(IsoDirections.N) then print("[buspray] missing", name) end
end
local unit = Changes.installUnit("sprinkler", square, WaterUnits.SPRINKLER_SPRITES.idle)
Changes.connectUnit(unit, panel, {})
unit.sprayedAt = getGameTime():getWorldAgeHours()
Units.definition("sprinkler").sync(unit, Units.object(unit))
print("[buspray] sprinkler at", unit.x, unit.y, "spraying", WaterUnits.spraying(unit), "sprite", Units.object(unit):getSprite():getName())
local seen, started = {}, getTimestampMs()
local function watch()
    local object = Units.object(unit)
    if object then seen[object:getSprite():getName()] = true end
    if getTimestampMs() - started > 1500 then
        Events.OnTick.Remove(watch)
        local names = {}
        for name in pairs(seen) do names[#names + 1] = name end
        table.sort(names)
        print("[buspray] frames seen", #names, table.concat(names, " "))
    end
end
Events.OnTick.Add(watch)
function BUSPRAY_CLEAN()
    Changes.removeUnit(unit)
    print("[buspray] cleaned")
end
