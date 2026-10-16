-- The outlines of models: the mod tells the API once that it outlines devices (formulas point outline.models), and
-- says in the log once when the API has no such point.
require "BuildingUtilities/Core"
local BU = BuildingUtilities

test("declared to the API once, with this mod's handle", function()
    local set = {}
    PZExtAPI.client = function() return { id = "h" } end
    PZExtAPI.formulas = { set = function(handle, name, value) set[#set + 1] = { handle = handle, name = name, value = value } end }
    eq(BU.declareOutlines(), true)
    eq(BU.declareOutlines(), true)
    eq(#set, 1, "once")
    eq(set[1].name, "outline.models"); eq(set[1].value, true); eq(set[1].handle.id, "h")
end)

test("an API without the point, or without formulas, is told once and does no harm", function()
    eq(BU.declareOutlines(), false, "no formulas")
    local lines = {}
    local print = print
    _G.print = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
    local function refuse() error("there is no point outline.models") end
    PZExtAPI.formulas = { set = refuse }
    eq(BU.declareOutlines(), false)
    eq(BU.declareOutlines(), false)
    _G.print = print
    eq(#lines, 1, "told once")
    truthy(string.find(lines[1], "outlines of models not declared", 1, true))
end)
