-- How a box and the units face as they are put down: toward the character, or to the side the furniture cursor is
-- turned to (BU.SIDES), a kind with fewer looks giving one look for several sides.
require "BuildingUtilities/Core"
require "BuildingUtilities/Solar"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Units, Solar, WaterUnits = BU.Units, BU.Solar, BU.WaterUnits

local function square(x, y, z)
    return { getX = function() return x end, getY = function() return y end, getZ = function() return z or 0 end }
end

local function at(x, y) return { getX = function() return x end, getY = function() return y end } end

test("the side a character stands on, and the box facing it or a side", function()
    local s = square(10, 10)
    eq(BU.sideOf(s, at(12, 10.5)), "E")
    eq(BU.sideOf(s, at(10.5, 8)), "N")
    eq(BU.sideOf(s, at(10.5, 13)), "S")
    eq(BU.panelSprite("S"), "bu_water_01_72", "tier 1 indoors, facing south")
    eq(BU.panelSprite("W", 4), "bu_water_01_35", "tier 4 indoors, facing west")
    eq(BU.panelSprite("E", 2, true), "bu_water_01_137", "tier 2 outdoors, facing east")
end)

test("a solar panel has two looks on the ground and one above it", function()
    local s = square(10, 10)
    eq(Units.spriteFacing("solar", s, "E"), Units.spriteFacing("solar", s, "W"))
    eq(Units.spriteFacing("solar", s, "N"), Units.spriteFacing("solar", s, "S"))
    truthy(Units.spriteFacing("solar", s, "N") ~= Units.spriteFacing("solar", s, "W"))
    eq(Units.spriteFor("solar", s, at(13, 10.5)), Solar.SPRITES.W, "facing the character")
    eq(Units.spriteFacing("solar", square(10, 10, 1), "N"), Solar.SPRITES.flat, "flat above the ground")
    eq(Units.spriteFacing("solar", nil, "N"), Solar.SPRITES.N, "the furniture tool's faces: no square")
end)

test("a booster faces any side; a pump without water turns its suction away", function()
    local s = square(10, 10)
    local seen = {}
    for _, side in ipairs(BU.SIDES) do seen[Units.spriteFacing("booster", s, side)] = true end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    eq(count, 4, "four looks")
    WaterUnits.waterBeside = function() return nil end
    eq(Units.spriteFacing("pump", s, "W"), WaterUnits.PUMP_SPRITES.E)
end)
