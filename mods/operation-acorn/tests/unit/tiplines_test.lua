-- The lines this mod adds to an item's tooltip: one wrapper of the game's tooltip for every part, one escape, and the
-- text kept per item for a short real time instead of made every frame.
local drawn
ISToolTipInv = { render = function(self) drawn = self.item.tip end }
local real = require
require = function(name)
    if string.find(name, "^ISUI/") then return true end
    return real(name)
end
require "OperationAcorn/Core"
require "OperationAcorn/TipLines"
require = real
local OA = OperationAcorn
local TipLines = OA.TipLines

local function newItem(tip)
    local item = { tip = tip }
    function item:getTooltip() return self.tip end
    function item:setTooltip(t) self.tip = t end
    return item
end

local function draw(item)
    drawn = nil
    ISToolTipInv.render({ item = item })
    return drawn
end

test("the lines of every part follow the item's own text, escaped once", function()
    OA.TipLines.add("one", function(item) return { "first 10%" } end)
    OA.TipLines.add("two", function(item) return { "second" } end)
    local item = newItem("Tooltip_Own")
    eq(draw(item), "Tooltip_Own\nfirst 10%%\nsecond")
    eq(item.tip, "Tooltip_Own", "taken off after the draw")
end)

test("an item no part has lines for is drawn as it is", function()
    OA.TipLines.add("none", function() return nil end)
    local item = newItem("Tooltip_Own")
    eq(draw(item), "Tooltip_Own")
end)

test("the text is kept for KEEP_MS and made again after", function()
    local clock, made = 1000, 0
    getTimestampMs = function() return clock end
    OA.TipLines.add("counted", function() made = made + 1 return { "n" .. made } end)
    local item = newItem(nil)
    eq(draw(item), "n1")
    clock = clock + 100
    eq(draw(item), "n1")
    eq(made, 1, "a frame later: looked up, not made")
    clock = clock + TipLines.KEEP_MS
    eq(draw(item), "n2")
    local other = newItem(nil)
    eq(draw(other), "n3", "kept per item")
end)

test("a part that fails is told once and does not break the tooltip", function()
    local lines = {}
    local print0 = print
    print = function(s) lines[#lines + 1] = s end
    local clock = 1000
    getTimestampMs = function() return clock end
    OA.TipLines.add("broken", function() error("no", 0) end)
    OA.TipLines.add("fine", function() return { "ok" } end)
    local item = newItem(nil)
    eq(draw(item), "ok")
    clock = clock + TipLines.KEEP_MS
    eq(draw(item), "ok")
    print = print0
    eq(#lines, 1)
    truthy(string.find(lines[1], "broken", 1, true))
end)

test("the texts kept are those of the last KEEP_MS: a hovered item that is not hovered again is let go", function()
    local clock = 50000
    getTimestampMs = function() return clock end
    OA.TipLines.add("any", function() return { "x" } end)
    local first = {}
    for i = 1, 200 do
        first[i] = newItem(nil)
        draw(first[i])
        clock = clock + 1
    end
    eq(TipLines.kept.n, 200, "all within the time")
    clock = clock + TipLines.KEEP_MS
    local later = newItem(nil)
    draw(later)
    eq(TipLines.kept.n, 1, "the expired ones went as a new text was kept")
    eq(TipLines.kept.t[first[1]], nil)
    truthy(TipLines.kept.t[later] ~= nil)
end)
