-- PZ Extension API Dev: the game's environment for tests of any mod (time, weather, the character, zombies), the
-- functions the "Environment" page calls. They also run from the Lua console (PZExtDev.Env.time(2) ...). Each prints
-- what it did as a "[dev] ..." line and returns something a check can test. Debug mode only; they change the save.
if not isDebugEnabled() then return end
PZExtDev = PZExtDev or {}
local Env = {}
PZExtDev.Env = Env

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[dev] " .. table.concat(parts, " "))
end
Env.say = say

-- ---- time ----------------------------------------------------------------------------------------------------------

local frozenAt = nil   -- the hour the clock is held at, or nil

-- The hour of the day (0..24), at once.
function Env.time(hour)
    if hour >= 24 then hour = 23.99 end
    getGameTime():setTimeOfDay(hour)
    if frozenAt then frozenAt = hour end
    say("time", hour)
end

-- The hour of the day now (0..24).
function Env.hour()
    return getGameTime():getTimeOfDay()
end

-- Holds the clock at the hour it is now while the game runs on (the light stays; the day does not move).
-- Env.freeze(false) lets it go.
function Env.freeze(on)
    if on == false then
        frozenAt = nil
        say("time released")
    else
        frozenAt = getGameTime():getTimeOfDay()
        say("time held at", string.format("%.2f", frozenAt))
    end
    return frozenAt ~= nil
end

function Env.frozen()
    return frozenAt ~= nil
end

Events.OnTick.Add(function()
    if frozenAt then getGameTime():setTimeOfDay(frozenAt) end
end)

-- The game speed: 1 normal, 2..4 the fast-forward steps (the speed buttons), 0 paused.
function Env.speed(n)
    UIManager.getSpeedControls():SetCurrentGameSpeed(n)
    say("speed", n)
end

-- ---- weather -------------------------------------------------------------------------------------------------------

local function stage(name, fallback)
    return WeatherPeriod and WeatherPeriod[name] or fallback
end

-- Stops rain, snow and thunder.
function Env.clearWeather()
    getClimateManager():stopWeatherAndThunder()
    say("weather cleared")
end

-- Rain (showers) for some hours.
function Env.rain(hours)
    getClimateManager():triggerCustomWeatherStage(stage("STAGE_SHOWERS", 1), hours or 3)
    say("rain", hours or 3)
end

-- A thunderstorm for some hours.
function Env.storm(hours)
    getClimateManager():triggerCustomWeatherStage(stage("STAGE_STORM", 3), hours or 3)
    say("storm", hours or 3)
end

-- Snow for some hours: a blizzard with the air held below freezing (the game snows only when it is cold).
function Env.snow(hours)
    Env.temperature(-8)
    getClimateManager():triggerCustomWeatherStage(stage("STAGE_BLIZZARD", 7), hours or 3)
    say("snow", hours or 3)
end

local function temperatureFloat()
    local index = ClimateManager and ClimateManager.FLOAT_TEMPERATURE or 4
    return getClimateManager():getClimateFloat(index)
end

-- Holds the air temperature at a value (degrees C); nil lets the game's own come back.
function Env.temperature(degrees)
    local f = temperatureFloat()
    if degrees == nil then
        f:setEnableAdmin(false)
        say("temperature released")
    else
        f:setEnableAdmin(true)
        f:setAdminValue(degrees)
        say("temperature held at", degrees)
    end
end

-- The temperature now, and whether it is held.
function Env.temperatureNow()
    local f = temperatureFloat()
    return getClimateManager():getTemperature(), f:isEnableAdmin()
end

-- A short line of the weather: rain intensity, snow on the ground, daylight.
function Env.weatherNow()
    local cm = getClimateManager()
    return cm:getPrecipitationIntensity(), cm:getSnowFracNow(), cm:getDayLightStrength(), cm:isRaining(), cm:isSnowing()
end

-- ---- the character ---------------------------------------------------------------------------------------------

-- Whether god mode, invisibility and no clip are on: three booleans.
function Env.flags()
    local player = getPlayer()
    return player:isGodMod(), player:isInvisible(), player:isNoClip()
end

function Env.godMode(on)
    getPlayer():setGodMod(on == true)
    say("god mode", on == true)
    return getPlayer():isGodMod()
end

function Env.invisible(on)
    getPlayer():setInvisible(on == true)
    say("invisible", on == true)
    return getPlayer():isInvisible()
end

function Env.noClip(on)
    getPlayer():setNoClip(on == true)
    say("no clip", on == true)
    return getPlayer():isNoClip()
end

-- Heals every wound and refills the character's health.
function Env.heal()
    getPlayer():getBodyDamage():RestoreToFullHealth()
    say("healed")
end

-- Takes hunger, thirst, tiredness, panic and stress away.
function Env.refresh()
    local stats = getPlayer():getStats()
    local CS = CharacterStat
    if CS then
        for _, name in ipairs({ "HUNGER", "THIRST", "FATIGUE", "PANIC", "STRESS", "ENDURANCE" }) do
            if CS[name] then stats:set(CS[name], name == "ENDURANCE" and 1 or 0) end
        end
    end
    say("needs refreshed")
end

-- Teleports the character to x, y, z.
function Env.teleport(x, y, z)
    getPlayer():teleportTo(x + 0.5, y + 0.5, z or 0)
    say("at", x, y, z or 0)
end

-- Where the character stands: x, y, z (whole squares).
function Env.where()
    local p = getPlayer()
    return math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
end

-- ---- zombies ----------------------------------------------------------------------------------------------------

-- n zombies 4..9 squares from the character (an outfit name, or nil for any), made harmless and still when
-- `harmless`. Returns how many.
function Env.spawn(n, outfit, harmless)
    local player = getPlayer()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local made = 0
    for _ = 1, n do
        for _ = 1, 12 do
            local dx, dy = ZombRand(4, 10), ZombRand(4, 10)
            if ZombRand(2) == 0 then dx = -dx end
            if ZombRand(2) == 0 then dy = -dy end
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            if sq and sq:isFree(false) then
                local list = addZombiesInOutfit(px + dx, py + dy, pz, 1, outfit, 50)
                for i = 0, list:size() - 1 do
                    if harmless then list:get(i):setUseless(true) end
                    made = made + 1
                end
                break
            end
        end
    end
    say("zombies spawned", made)
    return made
end

-- Removes the zombies within a radius of the character (all loaded ones without a radius). Returns how many.
function Env.clearZombies(radius)
    local player = getPlayer()
    local list = getCell():getZombieList()
    local gone = 0
    for i = list:size() - 1, 0, -1 do
        local z = list:get(i)
        if not radius or IsoUtils.DistanceTo(z:getX(), z:getY(), player:getX(), player:getY()) <= radius then
            z:removeFromWorld()
            z:removeFromSquare()
            gone = gone + 1
        end
    end
    say("zombies removed", gone)
    return gone
end

-- How many loaded zombies are within a radius of the character.
function Env.zombiesNear(radius)
    local player = getPlayer()
    local list = getCell():getZombieList()
    local n = 0
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if IsoUtils.DistanceTo(z:getX(), z:getY(), player:getX(), player:getY()) <= radius then n = n + 1 end
    end
    return n
end

-- A world sound at an offset from the character (what zombies hear).
function Env.sound(dx, dy, radius, volume)
    local player = getPlayer()
    local x, y, z = math.floor(player:getX()) + dx, math.floor(player:getY()) + dy, math.floor(player:getZ())
    addSound(nil, x, y, z, radius or 30, volume or 30)
    say("sound at", dx, dy)
end

return Env
