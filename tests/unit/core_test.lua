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

-- The upgrades of records saved by an older version.

local function stepsReset()
    OA.Store.UPGRADES = {}
end

test("an upgrade step runs once for a record, in the order it was added", function()
    stepsReset()
    local ran = {}
    OA.Store.addUpgrade("one", function(record) ran[#ran + 1] = "one:" .. record.id end)
    OA.Store.addUpgrade("two", function(record) ran[#ran + 1] = "two:" .. record.id end)
    eq(#OA.Store.UPGRADES, 2)
    eq(OA.Store.UPGRADES[1].name, "one")
    -- A record saved by an older version has no upgrades table.
    local record = { id = "old", number = 1234 }
    OA.Store.upgrade(record)
    eq(table.concat(ran, ","), "one:old,two:old")
    eq(record.upgrades.one, true)
    eq(record.upgrades.two, true)
    OA.Store.upgrade(record)
    eq(#ran, 2, "not again")
    -- A step added later (a newer version) is the only one run next time.
    OA.Store.addUpgrade("three", function(r) ran[#ran + 1] = "three" end)
    OA.Store.upgrade(record)
    eq(#ran, 3)
    eq(ran[3], "three")
end)

test("a failing upgrade step is logged, left undone and tried again; the others still run", function()
    stepsReset()
    local attempts, later = 0, 0
    local broken = true
    OA.Store.addUpgrade("bad", function() attempts = attempts + 1; if broken then error("boom") end end)
    OA.Store.addUpgrade("after", function() later = later + 1 end)
    local record = { id = "r", number = 1 }
    OA.Store.upgrade(record)
    eq(attempts, 1)
    eq(record.upgrades.bad, nil, "not marked done")
    eq(record.upgrades.after, true, "the step after it ran")
    OA.Store.upgrade(record)
    eq(attempts, 2, "tried again at the next start")
    eq(later, 1, "the done step is not repeated")
    broken = false
    OA.Store.upgrade(record)
    eq(attempts, 3)
    eq(record.upgrades.bad, true)
    OA.Store.upgrade(record)
    eq(attempts, 3, "done now")
end)

test("a new record has every registered upgrade marked done", function()
    stepsReset()
    local ran = 0
    OA.Store.addUpgrade("old_shape", function() ran = ran + 1 end)
    OA.Store.addUpgrade("older_shape", function() ran = ran + 1 end)
    local record = OA.Store.ensure("fresh", "F")
    eq(record.upgrades.old_shape, true)
    eq(record.upgrades.older_shape, true)
    OA.Store.upgrade(record)
    eq(ran, 0, "nothing to bring up to date")
    -- A step that comes with a later version is run for it.
    OA.Store.addUpgrade("newer_shape", function() ran = ran + 1 end)
    OA.Store.upgrade(record)
    eq(ran, 1)
end)

test("upgradeAll goes through every record in the save", function()
    stepsReset()
    local seen = {}
    OA.Store.ensure("a", "A")
    OA.Store.ensure("b", "B")
    OA.Store.addUpgrade("late", function(record) seen[#seen + 1] = record.id end)
    OA.Store.upgradeAll()
    table.sort(seen)
    eq(table.concat(seen, ","), "a,b")
    OA.Store.upgradeAll()
    eq(#seen, 2, "each once")
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
