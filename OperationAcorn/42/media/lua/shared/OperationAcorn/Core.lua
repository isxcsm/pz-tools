-- Operation Acorn: a research team on the radio trades with the player for what they gather, and pays in credits,
-- trust, upgrades and supplies. This file holds what every part shares: the name, the log, the API, time and options.
OperationAcorn = OperationAcorn or {}
local OA = OperationAcorn

OA.MOD = "OperationAcorn"
-- Every key this mod keeps in a save (global ModData, player and object modData) starts with this.
OA.PREFIX = "OA_"
OA.API_VERSION = 1

function OA.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[OperationAcorn] " .. table.concat(parts, " "))
end

-- The extension API, or nil with the reason it is missing: PZ Tools not installed in startup mode, or another
-- version. Without it the mod changes nothing and only explains (DESIGN 2).
function OA.api()
    local api = PZToolsAPI
    if type(api) ~= "table" or type(api.client) ~= "function" then return nil, "missing" end
    if api.version ~= OA.API_VERSION then return nil, "version" end
    return api
end

-- This mod's handle: every declaration to the API goes through it.
function OA.handle()
    local api = OA.api()
    return api and api.client(OA.MOD) or nil
end

-- A sandbox option by name (media/sandbox-options.txt, page OperationAcorn...).
function OA.option(name)
    local vars = SandboxVars and SandboxVars.OperationAcorn
    return vars and vars[name]
end

-- Time. The world age in hours is the clock every record uses: it grows while the game runs and is saved.
function OA.hours()
    return getGameTime():getWorldAgeHours()
end

-- The game day a world age falls on: day 0 is the world's first (partial) day, and the day changes at 00:00.
function OA.day(hours)
    local now = OA.hours()
    -- The hour of day at world age 0.
    local start = OA.remainder(getGameTime():getTimeOfDay() - now, 24)
    return math.floor(((hours or now) + start) / 24 + 1e-6)
end

-- The week a day falls in (weeks of seven days from day 0): the request list changes with it.
function OA.week(day)
    return math.floor((day or OA.day()) / 7)
end

-- A whole random number from a to b, both included; or from 0 to a - 1 with one argument (as ZombRand).
function OA.random(a, b)
    if b == nil then return ZombRand(a) end
    return ZombRand(a, b + 1)
end

-- A random number from a to b.
function OA.randomFloat(a, b)
    return ZombRandFloat(a, b)
end

-- Rounds half away from zero, for the one rounding a settlement does (NUMBERS 1).
function OA.round(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

-- The vehicles of the loaded cell, as a list Lua can index. B42's IsoCell.getVehicles() is a Set, which has no get(i)
-- (found in game: "tried to call nil"); the vehicles are copied into `into` (a reused ArrayList) or a new one.
function OA.vehicles(into)
    local list = into or ArrayList.new()
    list:clear()
    local cell = getCell()
    if cell then list:addAll(cell:getVehicles()) end
    return list
end

-- Whether a table has no entries. The game's Lua has no next(), so this is a pairs loop that stops at once.
function OA.isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

function OA.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

-- Kahlua's % gives wrong results for negative numbers and for large values such as getTimestampMs(): this is the
-- remainder with the sign of b.
function OA.remainder(a, b)
    return a - math.floor(a / b) * b
end

return OA
