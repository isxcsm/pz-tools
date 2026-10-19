-- The extension API's square conditions (extension-api docs/design.md, "Conditions on a square"; SquareFilter.java) as
-- the mods' unit tests answer them: squares.test and squares.why over a test's fake squares, asked through the same
-- game methods the API asks (a method a fake lacks answers as an ordinary square would: nothing there). The conditions
-- that look at other squares (around, clear) and distance are not here: a test that needs them fakes its answer.
-- Loaded by the harnesses (OA, BU): TEST.squares = loadstring(readfile("../tools/FakeSquareFilter.lua"))().
local Fake = {}

local NATURAL = { "floors_exterior_natural", "blends_natural_01" }
-- SquareFilter.WHY_ORDER
Fake.WHY_ORDER = { "wet", "water", "waterFlag", "floor", "solidFloor", "natural", "floorPrefix", "floorAvoid", "stairs",
    "tree", "vehicle", "free", "moving", "noObjectData", "outside", "room", "building", "doorEdge", "flags", "noFlags",
    "zonesNot", "distance", "around", "clear" }

local function ask(square, method, ...)
    local f = square[method]
    if f then return f(square, ...) end
    return nil
end

local function floorName(square)
    local floor = ask(square, "getFloor")
    if not floor then return nil end
    local sprite = floor.getSprite and floor:getSprite()
    if sprite and sprite.getName then return sprite:getName() end
    return floor.getSpriteName and floor:getSpriteName() or nil
end

local function starts(text, prefixes)
    for _, p in ipairs(prefixes) do
        if string.sub(text, 1, #p) == p then return true end
    end
    return false
end

local function waterFlag(square)
    local props = ask(square, "getProperties")
    return props ~= nil and IsoFlagType ~= nil and props:has(IsoFlagType.water) == true
end

local function hasData(square, key)
    local objects = ask(square, "getObjects")
    if not objects then return false end
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if (not o.hasModData or o:hasModData()) and o.getModData and o:getModData()[key] ~= nil then return true end
    end
    return false
end

-- Each condition: (square, value) -> met.
local CHECKS = {
    free = function(s, v) return (ask(s, "isFree", false) == true) == v end,
    solidFloor = function(s, v) return (ask(s, "TreatAsSolidFloor") == true) == v end,
    floor = function(s, v) return (ask(s, "getFloor") ~= nil) == v end,
    floorPrefix = function(s, v) local n = floorName(s); return n ~= nil and starts(n, v) end,
    floorAvoid = function(s, v)
        local n = floorName(s)
        if not n then return true end
        for _, part in ipairs(v) do if string.find(n, part, 1, true) then return false end end
        return true
    end,
    water = function(s, v) return (ask(s, "isWaterSquare") == true) == v end,
    waterFlag = function(s, v) return waterFlag(s) == v end,
    wet = function(s, v) return (ask(s, "isWaterSquare") == true or waterFlag(s)) == v end,
    natural = function(s, v) local n = floorName(s); return (n ~= nil and starts(n, NATURAL)) == v end,
    outside = function(s, v) return (ask(s, "isOutside") == true) == v end,
    stairs = function(s, v) return (ask(s, "HasStairs") == true) == v end,
    tree = function(s, v) return (ask(s, "HasTree") == true) == v end,
    vehicle = function(s, v)
        return (ask(s, "isVehicleIntersecting") == true or ask(s, "getVehicleContainer") ~= nil) == v
    end,
    moving = function(s, v) local m = ask(s, "getMovingObjects"); return (m ~= nil and not m:isEmpty()) == v end,
    noObjectData = function(s, v) return not hasData(s, v) end,
    room = function(s, v)
        local r = ask(s, "getRoom")
        if v == "none" then return r == nil elseif v == "any" then return r ~= nil end
        return r == v
    end,
    building = function(s, v)
        local b = ask(s, "getBuilding")
        if v == "none" then return b == nil elseif v == "any" then return b ~= nil end
        return b == v
    end,
}

local function check(key)
    local c = CHECKS[key]
    if not c then error("FakeSquareFilter: no fake for the condition " .. tostring(key), 3) end
    return c
end

-- squares.test(square, filter)
function Fake.test(square, filter)
    if type(square) ~= "table" then error("squares.test: square must be a loaded square", 2) end
    for key, value in pairs(filter or {}) do
        if not check(key)(square, value) then return false end
    end
    return true
end

-- squares.why(square, filter): the key of the first condition failed, in WHY_ORDER, or nil.
function Fake.why(square, filter)
    if type(square) ~= "table" then error("squares.why: square must be a loaded square", 2) end
    filter = filter or {}
    for _, key in ipairs(Fake.WHY_ORDER) do
        if filter[key] ~= nil and not check(key)(square, filter[key]) then return key end
    end
    for key, value in pairs(filter) do
        if not check(key)(square, value) then return key end
    end
    return nil
end

return Fake
