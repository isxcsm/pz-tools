-- How a box and the units face as they are put down: toward the character, or to the side the player turned the place
-- cursor to (BU.SIDES), a kind with fewer looks giving one look for several sides; and which sprites a kind may stand as
-- on a square (a sprite a client asks for is checked).
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
    eq(BU.panelSpriteFacing(s, at(10.5, 13)), BU.PANEL_SPRITES[1], "south")
    eq(BU.panelSprite("W"), BU.PANEL_SPRITES[4])
end)

test("a solar panel has two looks on the ground and one above it", function()
    local s = square(10, 10)
    eq(Units.spriteFacing("solar", s, "E"), Units.spriteFacing("solar", s, "W"))
    eq(Units.spriteFacing("solar", s, "N"), Units.spriteFacing("solar", s, "S"))
    truthy(Units.spriteFacing("solar", s, "N") ~= Units.spriteFacing("solar", s, "W"))
    eq(Units.spriteFor("solar", s, at(13, 10.5)), Solar.SPRITES.W, "facing the character")
    truthy(Units.canFace("solar", s, Solar.SPRITES.N))
    eq(Units.canFace("solar", s, Solar.SPRITES.flat), false, "flat only above the ground")
    eq(Units.spriteFacing("solar", square(10, 10, 1), "N"), Solar.SPRITES.flat)
end)

test("a booster faces any side; a pump without water turns its suction away", function()
    local s = square(10, 10)
    for _, side in ipairs(BU.SIDES) do
        truthy(Units.canFace("booster", s, Units.spriteFacing("booster", s, side)), side)
    end
    WaterUnits.waterBeside = function() return nil end
    eq(Units.spriteFacing("pump", s, "W"), WaterUnits.PUMP_SPRITES.E)
end)
