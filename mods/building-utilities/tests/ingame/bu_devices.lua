-- The water machines against the game's own water, at the test panel (bu_setup.lua): a pump finds water only beside a
-- source the game never runs dry (a well, clean as the game says; not a sink, a toilet or a bath); a sprinkler waters
-- the crops out in the open in its reach and not one under a roof beyond a wall. "[budev]" lines, each "ok" or "BAD",
-- ending with "done". What it puts down is taken away.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Units, WaterUnits, WaterRun = BU.Store, BU.Panels, BU.Changes, BU.Units, BU.WaterUnits,
    BU.WaterRun
local system = SFarmingSystem.instance
local bad = 0
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[budev] " .. table.concat(parts, " "))
end
local function check(label, got, want)
    local ok = got == want
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", label, got, "want", want)
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local cell = getCell()

-- The squares beside a kind of water object near the panel: { object's square, a free square beside it }.
local function besideOf(test)
    for dx = -30, 30 do
        for dy = -30, 30 do
            for z = 0, 1 do
                local s = cell:getGridSquare(panel.x + dx, panel.y + dy, z)
                local objects = s and s:getObjects()
                for i = 0, objects and objects:size() - 1 or -1 do
                    local object = objects:get(i)
                    local properties = object:getProperties()
                    if properties and properties:has("waterAmount") and test(tonumber(properties:get("waterAmount")) or 0, object) then
                        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                            local q = cell:getGridSquare(s:getX() + d[1], s:getY() + d[2], z)
                            if q and q:isFree(false) then return s, q, object end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- A pump's water: none beside a sink, a toilet or a bath; a well's, as the game says of it.
local _, besideSink, sink = besideOf(function(amount) return amount < 9999 end)
if besideSink then
    say("beside", sink:getSprite():getName())
    check("pump beside a sink, a toilet or a bath: no water", WaterUnits.waterBeside(besideSink), nil)
else
    say("no sink, toilet or bath with a free square beside it")
end
local _, besideWell, well = besideOf(function(amount) return amount >= 9999 end)
if besideWell then
    say("beside", well:getSprite():getName(), "tainted", tostring(well:isTaintedWater()))
    check("pump beside a well: its water", WaterUnits.waterBeside(besideWell), well:isTaintedWater() and "TaintedWater" or "Water")
else
    say("no well with a free square beside it")
end

-- A sprinkler outside a wall: a crop outside in its reach watered, one inside the wall not.
local sprinklerSquare, inside
for dx = -20, 20 do
    for dy = -20, 20 do
        local s = cell:getGridSquare(panel.x + dx, panel.y + dy, 0)
        if not sprinklerSquare and s and s:isOutside() and s:isFree(false) and Units.canInstall("sprinkler", s)
                and BU.Links.placeOn(panel, "water", s:getX(), s:getY(), 0) ~= nil
                and not system:getLuaObjectAt(s:getX(), s:getY(), 0) then
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }) do
                local q = cell:getGridSquare(s:getX() + d[1], s:getY() + d[2], 0)
                if not inside and q and not q:isOutside() and q:isFree(false) and not system:getLuaObjectAt(q:getX(), q:getY(), 0) then
                    sprinklerSquare, inside = s, q
                end
            end
        end
    end
end
local outsideSquare = sprinklerSquare and BUT.square(sprinklerSquare:getX(), sprinklerSquare:getY(), 0, 1, 2, function(q)
    return q:isOutside() and q:isFree(false) and not system:getLuaObjectAt(q:getX(), q:getY(), 0)
end)
if not (sprinklerSquare and inside and outsideSquare) then
    say("BAD no sprinkler square outside a wall"); bad = bad + 1
else
    local sprinkler = Changes.installUnit("sprinkler", sprinklerSquare, WaterUnits.SPRINKLER_SPRITES.idle)
    Changes.connectUnit(sprinkler, panel, {})
    local plants = {}
    for _, q in ipairs({ inside, outsideSquare }) do
        system:plow(q)
        local p = system:getLuaObjectAt(q:getX(), q:getY(), 0)
        p:seed("Carrots")
        p.waterLvl = 20
        plants[#plants + 1] = p
    end
    local tier = panel.tier
    if (panel.tier or 1) < 2 then BU.Dev.setTier(panel, 2) end
    local ok, failure = pcall(WaterRun.sprinklers, panel)
    if not ok then say("BAD sprinklers:", failure); bad = bad + 1 end
    say("raining", tostring(RainManager.isRaining()))
    if not RainManager.isRaining() then
        check("sprinkler: the crop outside watered", plants[2].waterLvl > 20, true)
        check("sprinkler: the crop under the roof not", plants[1].waterLvl, 20)
    end
    for _, p in ipairs(plants) do system:removePlant(p) end
    Changes.removeUnit(sprinkler)
    BU.Dev.setTier(panel, tier)
end
say("done:", bad, "BAD")
