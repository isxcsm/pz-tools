-- The titles of a character's firsts with the boxes (client/BuildingUtilities/Titles.lua): the first box seen powered by
-- its own supplies, each tier first raised to; once for each character, none without the API's text (and still to
-- come then).
require "BuildingUtilities/Core"
require "BuildingUtilities/Networks"
local BU = BuildingUtilities
TEST.gameFile("BuildingUtilities/PanelUi")
BU.PanelUi = { ACCENT = { 0.4, 0.75, 1 } }
require "BuildingUtilities/Titles"
local Titles, Networks = BU.Titles, BU.Networks

local shown = {}
local function withText()
    shown = {}
    PZExtAPI.text = {
        status = function() return "applied" end,
        title = function(_, spec) shown[#shown + 1] = spec end,
    }
end

local function character()
    local c = { data = {} }
    function c:getModData() return self.data end
    function c:getPlayerNum() return 0 end
    return c
end

test("each title once for each character, in its style", function()
    withText()
    local one, two = character(), character()
    eq(Titles.show(one, "tier", 2), true)
    eq(shown[1].style, "notice")
    eq(shown[1].text, "IGUI_BU_Title_Tier2")
    eq(shown[1].subtitle, "IGUI_BU_Title_Tier2Sub")
    eq(Titles.show(one, "tier", 2), false, "seen")
    eq(Titles.show(one, "tier", 3), true, "another tier")
    eq(Titles.show(two, "tier", 2), true, "another character")
    eq(#shown, 3)
end)

test("without the API's text, no title, and it is still to come", function()
    PZExtAPI.text = nil
    local one = character()
    eq(Titles.show(one, "tier", 2), false)
    withText()
    PZExtAPI.text.status = function() return "missing" end
    eq(Titles.show(one, "tier", 2), false, "its hook not in")
    withText()
    eq(Titles.show(one, "tier", 2), true)
end)

test("the first box seen powered: by its own supplies, its breaker up and its switch on", function()
    withText()
    local supplied = false
    Networks.state = function() return { supplied = supplied } end
    local one = character()
    local panel = {}
    Titles.lit(one, panel)
    eq(#shown, 0, "no power yet")
    supplied = true
    panel.tripped = true
    Titles.lit(one, panel)
    eq(#shown, 0, "tripped")
    panel.tripped = nil
    Titles.lit(one, panel)
    eq(#shown, 1)
    eq(shown[1].style, "unveil")
    Titles.lit(one, panel)
    eq(#shown, 1, "once")
end)
