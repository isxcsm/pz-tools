-- The window's manual tab (client/BuildingUtilities/PanelManual.lua), with the kit's typed text panel and the window
-- stood in for: a new chapter opens printed a row at a time, a click may bring it to its end, one read shows whole,
-- a first reading left half way goes on where it was left, and the tab is marked while a chapter is new.
require "BuildingUtilities/Core"
require "BuildingUtilities/Manual"
require "PZUIKit/Typing"
local BU = BuildingUtilities
local Manual, Store, Typing = BU.Manual, BU.Store, PZUIKit.Typing

-- The game's panel and the kit's pieces the tab uses, doing nothing.
local function load()
    ISPanel = { derive = function()
        local c = {}
        c.__index = c
        return c
    end, new = function(self, x, y, w, h) return setmetatable({ x = x, y = y, width = w, height = h }, self) end }
    local body = {}
    function body:new() return setmetatable({}, { __index = self }) end
    function body:paginate() self.paginated = true end
    function body:setYScroll() end
    PZUITypedText = body
    BU.PanelUi = { UI = { rich = function(_, _, _, _, _, class) return class:new() end, place = function() end,
        scaled = function() end }, PALETTE = { text = { 1, 1, 1 }, head = { 1, 1, 0 }, dim = { 0.5, 0.5, 0.5 } },
        ROW = 22, PAD = 8, MANUAL = "manual" }
    local real = require
    require = function(name)
        if name == "ISUI/ISPanel" or name == "PZUIKit/UI" or name == "PZUIKit/TypedText"
            or name == "BuildingUtilities/PanelUi" then return true end
        return real(name)
    end
    local ok, err = pcall(real, "BuildingUtilities/PanelManual")
    require = real
    if not ok then error(err, 0) end
end

-- A tab in a window of a character at a box.
local function tab(panel)
    load()
    local character = { data = {} }
    function character:getModData() return self.data end
    local window = { playerObj = character, panel = panel, tabs = {} }
    function window.tabs:setDot(_, on) self.dot = on end
    local manual = ISBUManual:new(0, 0, 300, 200, window)
    manual:createChildren()
    return manual, character, window
end

test("a new chapter is printed a row at a time, and a click may bring it to its end", function()
    local manual, _, window = tab(Store.newPanel(10, 10, 0, "box"))
    manual:refresh(window.panel)
    eq(manual.key, "connect", "the first new chapter opens")
    local run = manual.body.run
    truthy(run, "printed")
    eq(run.step, Typing.LINE_STEP)
    eq(run.clock, 0)
    eq(run.seen, run.parse.n, "all of it may be brought on at once")
    eq(window.tabs.dot, true, "the tab is marked")
end)

test("a chapter printed to its end is read: it shows whole after, and the mark goes with the last new one", function()
    local manual, character, window = tab(Store.newPanel(20, 10, 0, "box"))
    manual:refresh(window.panel)
    ISBUManual.onPrinted(manual, manual.body.run)
    eq(Manual.state(character, "connect"), true)
    manual:show("connect")
    eq(manual.body.run, nil, "whole at once")
    for _, key in ipairs({ "breaker", "care" }) do
        manual:show(key)
        ISBUManual.onPrinted(manual, manual.body.run)
    end
    eq(window.tabs.dot, false)
end)

test("a first reading left half way goes on where it was left; one never drawn keeps nothing", function()
    local manual, character, window = tab(Store.newPanel(30, 10, 0, "box"))
    manual:refresh(window.panel)
    manual:show("breaker")
    eq(Manual.state(character, "connect"), nil, "never drawn")
    local run = manual.body.run
    run.last, run.clock = 1000, 0.75
    manual:show("care")
    eq(Manual.state(character, "breaker").t, 0.75)
    manual:show("breaker")
    eq(manual.body.run.clock, 0.75)
end)
