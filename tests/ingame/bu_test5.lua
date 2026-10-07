-- The plan toggled, checked a few frames later (anchors move children a frame after a resize), and a tripped box's
-- mark in the world. Uses the box of bu_test4.lua. "[bu5]" lines in console.txt.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU4TEST")
local player = getPlayer()
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu5] " .. table.concat(parts, " "))
end
local panel = BU.Store.get(MD.panel)
local steps, current, waitTicks = {}, 1, 0
local w
local function layout(label)
    say(label, "window", w.width, "tabs", w.tabs:getWidth(), "list", w.lists.power:getWidth(), "plan", w.plan:getIsVisible(),
        w.plan:getX(), "options", w.activeButton:getX(), w.loadSortButton:getX(), "range", w.rangeButton:getX())
end

steps[#steps + 1] = function()
    BU.PanelWindow.planShown = true
    if BU.PanelWindow.isOpen(panel.id) then BU.PanelWindow.open(player, panel):close() end
    w = BU.PanelWindow.open(player, panel)
    waitTicks = 10
end
steps[#steps + 1] = function() layout("opened"); w:onPlan(); waitTicks = 10 end
steps[#steps + 1] = function() layout("hidden"); w:onPlan(); waitTicks = 10 end
steps[#steps + 1] = function() layout("shown again"); BU.Changes.trip(panel); waitTicks = 30 end
steps[#steps + 1] = function()
    local object = BU.Panels.object(panel)
    say("tripped", panel.tripped, "highlighted", object:isHighlighted(0), "blink", object:isBlink(0))
    say("done")
end

local function tick()
    if waitTicks > 0 then waitTicks = waitTicks - 1; return end
    local step = steps[current]
    if not step then Events.OnTick.Remove(tick); return end
    current = current + 1
    local ok, problem = pcall(step)
    if not ok then say("FAIL in step", current - 1, problem) end
end
Events.OnTick.Add(tick)
