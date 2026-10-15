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
    eq(OA.option("CallIntervalMultiplier"), 1.0)
    eq(OA.option("HiddenZombieFix"), true)
    eq(OA.reissueCost(), 10000)
end)

test("the balance options are multipliers of the mod's numbers, never the numbers", function()
    eq(OA.scaled(7, "MissionDeadlineMultiplier"), 7)
    SandboxVars.OperationAcorn.MissionDeadlineMultiplier = 2
    eq(OA.scaled(7, "MissionDeadlineMultiplier"), 14)
    SandboxVars.OperationAcorn.MissionDeadlineMultiplier = 1.0
    eq(OA.scaled(5, "NoSuchOption"), 5, "a missing option is 1")
    local text = readfile("OperationAcorn/42/media/sandbox-options.txt")
    for name, body in string.gmatch(text, "option OperationAcorn%.(%w+)%s*(%b{})") do
        local kind = string.match(body, "type = (%w+)")
        local default = string.match(body, "default = ([%w%.]+)")
        -- a number option is a multiplier (default 1) or a percentage (default 100); counts are named as such
        if kind == "double" then eq(default, "1.0", name .. " is a multiplier") end
        if kind == "integer" then
            truthy(default == "100" or name == "SharedSerumMilestones", name .. " keeps a number of the mod's balance")
        end
    end
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

test("a record whose character died goes still once; the record stays", function()
    local a = OA.Store.ensure("dead1", "A")
    eq(OA.Store.alive(a), true)
    eq(OA.Store.retire(a), true)
    eq(OA.Store.alive(a), false)
    truthy(a.dead ~= nil, "the world age it died at")
    eq(OA.Store.retire(a), false, "once")
    eq(OA.Store.player("dead1"), a, "kept")
    eq(OA.Store.alive(nil), false)
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

test("the shared wrap and cut: the rules the windows' own copies had", function()
    local chars = function(s) return #s end
    -- spaces only; a word wider than a line stays whole
    local lines = OA.wrap("aaa bbb ccc ddd", 7, chars)
    eq(#lines, 2); eq(lines[1], "aaa bbb"); eq(lines[2], "ccc ddd")
    eq(OA.wrap("abcdefghij kl", 5, chars)[1], "abcdefghij")
    eq(#OA.wrap("", 5, chars), 0, "no text, no line")
    eq(#OA.wrap("one\ntwo", 20, chars), 1, "line ends are spaces unless paragraphs")
    -- paragraphs: a line end ends a line, a blank paragraph is an empty line
    local rows = OA.wrap("one\n\ntwo", 20, chars, { paragraphs = true })
    eq(#rows, 3); eq(rows[2], "")
    -- a margin: a width a hair under the text's own still takes it
    eq(#OA.wrap("aaaa bbbb", 9 - 0.0005, chars, { eps = 0.001 }), 1)
    eq(#OA.wrap("aaaa bbbb", 9 - 0.0005, chars), 2)
    -- words cut between letters
    local cut = OA.wrap("abcdefghij kl", 4, chars, { breakWords = true })
    eq(cut[1], "abcd"); eq(cut[2], "efgh"); eq(cut[3], "ij"); eq(cut[4], "kl")
    -- at most n lines, the last ending in "..."
    local few = OA.wrap("aaa bbb ccc ddd eee", 3, chars, { breakWords = true, maxLines = 2 })
    eq(#few, 2); eq(few[1], "aaa"); eq(few[2], "b...", "one letter is kept at the least")
    local fewer = OA.wrap("aaaa bbbb cccc", 6, chars, { maxLines = 2 })
    eq(fewer[2], "bbb...", "the last line cut so that the dots fit")
    -- the cut
    eq(OA.fitText("abcdef", 6, chars), "abcdef")
    eq(OA.fitText("abcdefg", 6, chars), "abc...")
    eq(OA.cutFor("abcdefg", 6, chars), "abc")
    eq(OA.fitText("ab", 1, chars), "a...", "one letter is kept at the least")
end)

test("the shared ease out", function()
    eq(OA.easeOut(-1), 0); eq(OA.easeOut(0), 0); eq(OA.easeOut(1), 1); eq(OA.easeOut(2), 1)
    near(OA.easeOut(0.5), 0.875, 1e-12)
end)
