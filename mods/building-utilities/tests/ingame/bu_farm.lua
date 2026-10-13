-- A sprinkler on a real field, against the game's farming, at the test panel (bu_setup.lua): a sprinkler put down in
-- the yard and wired; carrots and tomatoes plowed and seeded by the farming system in its reach (5 by 5) and one of
-- each beyond it; all a little under what they need. Then two game days at the fastest speed, and a storm: each hour
-- the plants' water, what they need (and their most), their health and stage, the uses the sprinkler gave and the
-- litres it drew. Checks: in reach never below what slows growth (water needed / 1.1) after the first look, never over
-- the most a plant likes; out of reach they dry as the game dries them; no watering while it rains; each use the
-- litres of a watering can's. "[bufarm]" lines; "done" at the end, some minutes later. What it put down is taken
-- away, the speed and the tier put back.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Units, WaterUnits = BU.Store, BU.Panels, BU.Changes, BU.Units, BU.WaterUnits
local player = getPlayer()
local system = SFarmingSystem.instance
local bad = 0
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bufarm] " .. table.concat(parts, " "))
end
local function check(label, got, want)
    local ok = got == want
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", label, got, "want", want)
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local tierWas = panel.tier or 1
local DAYS_HOURS, STORM_HOURS = 48, 3
local MULTIPLIERS = { 1, 5, 20, 40 }
local function speed(n)
    UIManager.getSpeedControls():SetCurrentGameSpeed(n)
    getGameTime():setMultiplier(MULTIPLIERS[n])
end

-- The field: a sprinkler square with, around it, the squares the plants go on, all outside, free and bare.
local IN_REACH = { { 1, 0, "Carrots" }, { -2, 2, "Carrots" }, { 0, -2, "Tomato" }, { 2, 1, "Tomato" } }
local OUT_OF_REACH = { { 4, 0, "Carrots" }, { -4, 1, "Tomato" } }
local function bare(s)
    return s and s:isOutside() and s:isFree(false) and s:getObjects():size() <= 2 and not system:getLuaObjectAt(s:getX(), s:getY(), s:getZ())
        and not Panels.buildingAt(s:getX(), s:getY(), 0)
end
local cell = getCell()
local centre = BUT.square(panel.x, panel.y, 0, 4, 18, function(s)
    if not bare(s) or not Units.canInstall("sprinkler", s) then return false end
    for _, list in ipairs({ IN_REACH, OUT_OF_REACH }) do
        for _, at in ipairs(list) do
            if not bare(cell:getGridSquare(s:getX() + at[1], s:getY() + at[2], 0)) then return false end
        end
    end
    return true
end)
if not centre then say("BAD no field square"); return end
local sx, sy = centre:getX(), centre:getY()
BU.Dev.setTier(panel, 2)
local sprinkler = Changes.installUnit("sprinkler", centre, WaterUnits.SPRINKLER_SPRITES.idle)
Changes.connectUnit(sprinkler, panel, {})
say("sprinkler at", sx, sy)

local plants = {}
local function plant(at, inReach)
    local square = cell:getGridSquare(sx + at[1], sy + at[2], 0)
    system:plow(square)
    local p = system:getLuaObjectAt(square:getX(), square:getY(), 0)
    p:seed(at[3])
    p.waterLvl = math.max(0, (p.waterNeeded or 0) - 5)
    p:saveData()
    plants[#plants + 1] = { x = square:getX(), y = square:getY(), kind = at[3], inReach = inReach, min = 101, max = -1,
        start = p.waterLvl, health0 = p.health }
end
for _, at in ipairs(IN_REACH) do plant(at, true) end
for _, at in ipairs(OUT_OF_REACH) do plant(at, false) end
for _, p in ipairs(plants) do
    local o = system:getLuaObjectAt(p.x, p.y, 0)
    say("planted", p.kind, p.inReach and "in reach" or "out of reach", "water", o.waterLvl, "needs", o.waterNeeded,
        "most", tostring(o.waterNeededMax), "health", o.health)
end

-- The sprinkler's uses: the farming system's water() with no source (as the sprinkler calls it).
local uses, usesInRain, raining = 0, 0, false
local waterOf = SPlantGlobalObject.water
SPlantGlobalObject.water = function(self, source, n)
    if source == nil then
        uses = uses + (n or 0)
        if raining then usesInRain = usesInRain + (n or 0) end
    end
    return waterOf(self, source, n)
end
local function tankLitres()
    local total = 0
    for _, at in ipairs(panel.water.producers) do
        local storage = Panels.waterStorage(at.x, at.y, at.z)
        if storage then total = total + storage:getAmount() end
    end
    return total
end
local litres0 = tankLitres()

local function look(hour)
    local parts = {}
    for _, p in ipairs(plants) do
        local o = system:getLuaObjectAt(p.x, p.y, 0)
        if o then
            local w = o.waterLvl or 0
            if hour >= 1 then p.min, p.max = math.min(p.min, w), math.max(p.max, w) end
            p.needs, p.most, p.last, p.health, p.state, p.grow = o.waterNeeded, o.waterNeededMax, w, o.health, o.state, o.nbOfGrow
            parts[#parts + 1] = string.format("%s%s %d/%s", p.kind:sub(1, 1), p.inReach and "" or "*", w, tostring(o.waterNeeded))
        end
    end
    say("hour", hour, table.concat(parts, "  "), "uses", uses, "tank", string.format("%.1f", tankLitres()),
        "raining", tostring(RainManager.isRaining()))
end

local function finish()
    speed(1)
    SPlantGlobalObject.water = waterOf
    for _, p in ipairs(plants) do
        local o = system:getLuaObjectAt(p.x, p.y, 0)
        if o then system:removePlant(o) end
    end
    Changes.removeUnit(sprinkler)
    BU.Dev.setTier(panel, tierWas)
    say("done:", bad, "BAD")
end

local start = getGameTime():getWorldAgeHours()
local hour, phase, stormAt, usesBeforeStorm = 0, "days", nil, 0
look(0)
speed(4)
local function onMinute()
    raining = RainManager.isRaining()
    local now = getGameTime():getWorldAgeHours() - start
    if now < hour + 1 then return end
    hour = hour + 1
    look(hour)
    if phase == "days" and hour >= DAYS_HOURS then
        for _, p in ipairs(plants) do
            local o = system:getLuaObjectAt(p.x, p.y, 0)
            local slow = math.floor((p.needs or 0) / 1.10)
            if p.inReach then
                check(p.kind .. " in reach: never below what slows it (" .. slow .. ")", p.min >= slow, true)
                check(p.kind .. " in reach: never over its most", p.max <= (p.most or 100), true)
            end
            say(p.kind, p.inReach and "in reach" or "out of reach", "water from", p.start, "low", p.min, "high", p.max,
                "now", p.last, "health", p.health0, "->", p.health, "state", p.state, "stage", p.grow)
        end
        local drawn = litres0 - tankLitres()
        say("two days: uses", uses, "=", string.format("%.1f", uses * WaterUnits.LITRES_PER_USE), "L by the can's measure;",
            "the tanks went down", string.format("%.1f", drawn), "L (pumps and rain may add)")
        say("a plant in reach a day:", string.format("%.2f", uses * WaterUnits.LITRES_PER_USE / #IN_REACH / (DAYS_HOURS / 24)), "L")
        usesBeforeStorm = uses
        getClimateManager():triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM, STORM_HOURS)
        phase, stormAt = "storm", hour
    elseif phase == "storm" then
        if hour >= stormAt + STORM_HOURS then
            Events.EveryOneMinute.Remove(onMinute)
            say("storm: uses while raining", usesInRain, "rain seen", tostring(raining))
            check("no watering while it rains", usesInRain, 0)
            finish()
        end
    end
end
Events.EveryOneMinute.Add(onMinute)
