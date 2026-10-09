-- The shared base: time, the save's records, the chunk waiting table.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Chunks"
local OA = OperationAcorn

test("day changes at midnight", function()
    -- The harness starts the world at 09:00.
    TEST.hours = 0
    eq(OA.day(), 0)
    TEST.hours = 14.9
    eq(OA.day(), 0, "23:54")
    TEST.hours = 15
    eq(OA.day(), 1, "00:00 next day")
    eq(OA.day(39), 2)
    eq(OA.week(13), 1)
end)

test("sandbox defaults load", function()
    eq(OA.option("CallInterval"), 3.0)
    eq(OA.option("HiddenZombieFix"), true)
    eq(OA.option("BoxReissueCost"), 10000)
end)

test("player records get unique numbers", function()
    local a = OA.Store.ensure("a", "A")
    local b = OA.Store.ensure("b", "B")
    truthy(a.number >= 1000 and a.number <= 9999, "four digits")
    truthy(a.number ~= b.number, "different numbers")
    eq(OA.Store.ensure("a", "A"), a, "same record again")
    OA.Store.section(a, "trade").credits = 5
    eq(OA.Store.player("a").trade.credits, 5)
end)

test("chunk work runs once its chunk loads", function()
    local ran = 0
    OA.Chunks.handle("probe", function(entry) ran = ran + entry.n; return true end)
    OA.Chunks.add({ kind = "probe", x = 17, y = 9, z = 0, n = 2 })
    local function chunkAt(x, y)
        return { getGridSquare = function() return { getX = function() return x end, getY = function() return y end } end }
    end
    OA.Chunks.loaded(chunkAt(0, 0))
    eq(ran, 0, "other chunk")
    OA.Chunks.loaded(chunkAt(16, 8))
    eq(ran, 2, "its chunk")
    OA.Chunks.loaded(chunkAt(16, 8))
    eq(ran, 2, "done entries leave the table")
    eq(#OA.Chunks.list("probe"), 0)
end)

test("a real-time throttle is due once each interval, per key", function()
    local last = {}
    -- getTimestampMs-sized numbers: only subtraction is used on them
    local t = 1760000000000
    truthy(OA.due(last, "a", t, 5000), "the first time")
    eq(OA.due(last, "a", t + 4999, 5000), false, "within the interval")
    truthy(OA.due(last, "b", t + 4999, 5000), "another key keeps its own time")
    truthy(OA.due(last, "a", t + 5000, 5000), "the interval passed")
    eq(OA.due(last, "a", t + 5001, 5000), false, "counted from the last due time")
    truthy(OA.due(last, "a", t - 1, 5000), "a clock that went back is due at once")
    eq(OA.due(last, "a", t, 5000), false)
end)
