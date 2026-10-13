-- The box's manual (BU.Manual): its chapters come as the box can do more (a tier's when it is raised to it, the
-- batteries' with a rack wired, water's with a water machine), a chapter read stays the reader's, and what is new marks
-- the tab.
require "BuildingUtilities/Core"
require "BuildingUtilities/Manual"
require "BuildingUtilities/WaterUnits"
require "BuildingUtilities/Rack"
local BU = BuildingUtilities
local Manual, Store = BU.Manual, BU.Store

local function character()
    local c = { data = {} }
    function c:getModData() return self.data end
    return c
end

local function has(list, key)
    for _, each in ipairs(list) do
        if each == key then return true end
    end
    return false
end

test("the basic chapters at first, a tier's as the box is raised to it", function()
    local panel = Store.newPanel(10, 10, 0, "box")
    local reader = character()
    local list = Manual.chapters(panel, reader)
    eq(#list, 3)
    eq(list[1], "connect")
    panel.tier = 3
    list = Manual.chapters(panel, reader)
    truthy(has(list, "tier2") and has(list, "tier3"), "tiers 2 and 3")
    eq(has(list, "tier4"), false)
end)

test("the batteries' chapter with a rack wired, water's with a water machine", function()
    local panel = Store.newPanel(20, 10, 0, "box")
    local reader = character()
    eq(has(Manual.chapters(panel, reader), "battery"), false)
    local rack = Store.newUnit("rack", 22, 10, 0, "rack")
    rack.panel = panel.id
    Store.unitsChanged()
    truthy(has(Manual.chapters(panel, reader), "battery"))
    eq(has(Manual.chapters(panel, reader), "water"), false)
    local pump = Store.newUnit("pump", 23, 10, 0, "pump")
    pump.panel = panel.id
    Store.unitsChanged()
    truthy(has(Manual.chapters(panel, reader), "water"))
end)

test("a chapter read stays the reader's at any box; new ones mark the tab", function()
    local panel = Store.newPanel(30, 10, 0, "box")
    local reader = character()
    eq(Manual.anyNew(panel, reader), true)
    for _, key in ipairs(Manual.chapters(panel, reader)) do Manual.keep(reader, key, true) end
    eq(Manual.anyNew(panel, reader), false)
    Manual.keep(reader, "tier4", false, 1.5)
    eq(Manual.state(reader, "tier4").t, 1.5, "a first reading left half way")
    truthy(has(Manual.chapters(panel, reader), "tier4"), "read before, at a box of tier 1")
    eq(Manual.anyNew(panel, reader), true, "not to its end")
    Manual.keep(reader, "tier4", true)
    Manual.keep(reader, "tier4", false, 0.5)
    eq(Manual.state(reader, "tier4"), true, "read to its end stays so")
end)

test("a tier's chapter carries its rated load and its relays", function()
    eq(Manual.text("tier2"), "IGUI_BU_Manual_tier2Text " .. string.format("%.2f", BU.capacity(2)) .. " 2")
    eq(Manual.title("water"), "IGUI_BU_Manual_water")
end)
