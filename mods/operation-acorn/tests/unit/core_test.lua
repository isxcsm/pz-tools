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

test("chunk work that takes out entries leaves the others waiting", function()
    local function chunkAt(x, y)
        return { getGridSquare = function() return { getX = function() return x end, getY = function() return y end } end }
    end
    local ran = {}
    -- "own" entries take out all of their group, as a placed piece does; "keep" ones are not done
    OA.Chunks.handle("grp", function(entry)
        ran[#ran + 1] = entry.n
        if entry.keep then return false end
        OA.Chunks.remove(function(e) return e.kind == "grp" and e.group == entry.group end)
        return true
    end)
    OA.Chunks.add({ kind = "grp", x = 40, y = 40, z = 0, n = 1, group = "a" })
    OA.Chunks.add({ kind = "grp", x = 41, y = 40, z = 0, n = 2, group = "b", keep = true })
    OA.Chunks.add({ kind = "grp", x = 42, y = 40, z = 0, n = 3, group = "a" })
    OA.Chunks.loaded(chunkAt(40, 40))
    eq(#ran, 2, "the group's other entry was taken out before its turn")
    local left = OA.Chunks.list("grp")
    eq(#left, 1)
    eq(left[1].n, 2, "the entry not done still waits")
    OA.Chunks.remove(function(e) return e.kind == "grp" end)
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

test("OA.try is pcall that writes the log once per site, and passes the results through", function()
    local lines = {}
    local print0 = print
    print = function(s) lines[#lines + 1] = s end
    local ok, a, b = OA.try("a site", function(x, y) return x + y, "two" end, 1, 2)
    eq(ok, true)
    eq(a, 3)
    eq(b, "two")
    eq(#lines, 0, "nothing to say")
    local failed = OA.try("another site", function() error("boom", 0) end)
    OA.try("another site", function() error("boom", 0) end)
    OA.try("a third site", function() error("bang", 0) end)
    print = print0
    eq(failed, false)
    eq(#lines, 2, "once per site")
    truthy(string.find(lines[1], "another site failed: boom", 1, true))
end)

test("a menu works on one item per entry of the selection: a stack's first, never every item of it", function()
    local hammer, nails = { name = "hammer" }, { name = "nails" }
    local stack = { items = { nails, { name = "more nails" }, { name = "and more" } } }
    local list = OA.menuItems({ hammer, stack })
    eq(#list, 2)
    eq(list[1], hammer)
    eq(list[2], nails)
end)

test("the outlines of models are declared to the API once, and an API without the point is told once in the log", function()
    local set = {}
    local function formulas(fn) return { version = OA.API_VERSION, client = function() return { id = "h" } end, formulas = { set = fn } } end
    PZExtAPI = nil
    eq(OA.declareOutlines(), false, "no API: nothing to declare")
    -- an API from before the point refuses it: logged once, tried again at the next start
    local logged = {}
    local log = OA.log
    OA.log = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end
    local function refuse() error("there is no point outline.models") end
    PZExtAPI = formulas(refuse)
    eq(OA.declareOutlines(), false)
    eq(OA.declareOutlines(), false)
    OA.log = log
    eq(#logged, 1, "told once")
    -- one that has it takes it, true, once
    PZExtAPI = formulas(function(handle, name, value) set[#set + 1] = { handle = handle, name = name, value = value } end)
    eq(OA.declareOutlines(), true)
    eq(OA.declareOutlines(), true)
    eq(#set, 1, "declared once")
    eq(set[1].name, "outline.models"); eq(set[1].value, true); eq(set[1].handle.id, "h")
    PZExtAPI = nil
end)

test("a bounded cache holds up to its cap, then starts again; a key put again or taken away is no new key", function()
    local c = OA.bounded(3)
    local a, b, d, e = {}, {}, {}, {}
    OA.put(c, a, 1)
    OA.put(c, b, 2)
    OA.put(c, a, 5)
    eq(c.n, 2, "the same key again is not counted")
    eq(c.t[a], 5)
    OA.put(c, d, 3)
    eq(c.n, 3)
    OA.drop(c, b)
    eq(c.n, 2)
    OA.drop(c, b)
    eq(c.n, 2, "a key that is not there is not counted down")
    OA.put(c, b, 2)
    eq(c.n, 3)
    OA.put(c, e, 4)
    eq(c.n, 1, "the cap was reached: the cache was emptied for the new key")
    eq(c.t[e], 4)
    eq(c.t[a], nil)
    eq(c.t[b], nil)
    eq(c.t[d], nil)
    OA.put(c, a, nil)
    eq(c.n, 1, "a nil value puts no key")
    local many = OA.bounded()
    eq(many.cap, OA.CACHE_CAP)
end)

test("a bounded cache of timed entries drops the expired ones as a new key is put", function()
    local c = OA.bounded(100)
    local keys = {}
    for i = 1, 40 do
        keys[i] = {}
        OA.putTimed(c, keys[i], { at = 1000 + i }, 1000 + i, 500)
    end
    eq(c.n, 40, "all live")
    -- a put after the ttl: the first sweep is due, and everything older than 500 ms goes
    OA.putTimed(c, {}, { at = 1600 }, 1600, 500)
    eq(c.n, 1, "only what is within the ttl is held")
    eq(c.t[keys[1]], nil)
    local fresh = {}
    OA.putTimed(c, fresh, { at = 1700 }, 1700, 500)
    eq(c.n, 2, "no sweep inside the ttl")
    -- a clock gone back counts as expired
    OA.putTimed(c, {}, { at = 100 }, 100, 500)
    eq(c.n, 1, "a clock gone back: the old entries are not live")
end)

test("without the API the mod is off: OA.on registers nothing", function()
    local calls = 0
    OA.off = true
    OA.on("OnTestOff", function() calls = calls + 1 end)
    TEST.fire("OnTestOff")
    eq(calls, 0, "off: not registered")
    OA.off = false
    OA.on("OnTestOff", function() calls = calls + 1 end)
    TEST.fire("OnTestOff")
    eq(calls, 1, "on: registered")
end)

-- Every .lua file under a folder of the mod, with its path.
local function luaFiles(dir, out)
    for _, name in ipairs(listfiles(dir)) do
        local path = dir .. "/" .. name
        if string.match(name, "%.lua$") then out[#out + 1] = path
        elseif not string.find(name, ".", 1, true) then luaFiles(path, out) end
    end
    return out
end

test("the mod hooks the game only through OA.on and behind OA.off (it changes nothing without the API)", function()
    local files = luaFiles("OperationAcorn/42/media/lua", {})
    assert(#files > 100, "the mod's files found")
    local bad = {}
    for _, path in ipairs(files) do
        local text = readfile(path)
        local guarded, named = false, false
        local n = 0
        for line in string.gmatch(text, "([^\n]*)\n?") do
            n = n + 1
            if string.match(line, "^local OA = OperationAcorn") then named = true end
            if string.find(line, "OA.off", 1, true) and not string.match(line, "^%s*%-%-") then
                guarded = true
                -- (a file the tests do not load fails here, not first in the game)
                if not named then bad[#bad + 1] = path .. ":" .. n .. " OA.off before local OA" end
            end
            if string.match(line, "^%s*Events%.[%w_]+%.Add%(") and not string.find(path, "NoApi.lua", 1, true) then
                bad[#bad + 1] = path .. ":" .. n .. " Events.Add (OA.on)"
            end
            -- a game function changed: function ISFoo:bar / ISFoo.bar = function (the mod's own ISOA classes aside)
            local class = string.match(line, "^%s*function (IS%w+)[.:]") or string.match(line, "^%s*(IS%w+)%.[%w_]+ = function")
            if class and not string.match(class, "^ISOA") and not guarded then
                bad[#bad + 1] = path .. ":" .. n .. " " .. class .. " changed before any OA.off"
            end
        end
    end
    eq(table.concat(bad, "\n"), "")
end)
