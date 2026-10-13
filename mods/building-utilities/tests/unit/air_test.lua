-- The air at a box or unit away from the player: the difference from the air outside its square last showed, on the
-- air outside now. A far basement's rack and a far heated building's pipes keep what they had over the weather.
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Store, Energy, Water = BU.Store, BU.Energy, BU.Water

TEST.outside, TEST.air = 10, {}
getClimateManager = function()
    return { getTemperature = function() return TEST.outside end, getDayLightStrength = function() return 0 end,
        getAirTemperatureForSquare = function(_, square)
            return TEST.air[square:getX() .. "," .. square:getY() .. "," .. square:getZ()] or TEST.outside
        end }
end

test("a square's warmth is kept and used while it is not loaded", function()
    local panel = Store.newPanel(10, 10, 0, BU.panelSprite("S"))
    eq(BU.airAt(panel), 10, "never seen: the air outside")
    TEST.squares["10,10,0"] = {}
    TEST.air["10,10,0"] = 18.04
    eq(BU.airAt(panel), 18.04, "loaded: its square's")
    eq(panel.warmth, 8, "kept to a tenth")
    TEST.squares["10,10,0"] = nil
    TEST.outside = -20
    eq(BU.airAt(panel), -12, "away in winter: outside and the warmth")
    eq(Water.pipeTemperature(panel), -12, "the pipes")
    TEST.squares["10,10,0"] = {}
    TEST.air["10,10,0"] = -20
    BU.airAt(panel)
    eq(panel.warmth, nil, "no longer warmer: nothing kept")
end)

test("cold locks a far rack by its own air", function()
    local rack = Store.newUnit("rack", 11, 10, 0, BU.Rack.SPRITE)
    rack.warmth = 15
    TEST.outside = -10
    TEST.squares = {}
    eq(Energy.coldShare({ rack }), 0, "a basement 15 above: not frozen")
    rack.warmth = nil
    truthy(Energy.coldShare({ rack }) > 0, "outside: frozen")
end)
