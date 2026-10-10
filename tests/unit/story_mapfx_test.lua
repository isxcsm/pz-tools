-- The geometry of the map overlay: the dashes along the way and around the ring, the ring as the map shows it, and
-- the animations' timing.
require "OperationAcorn/Core"
require "OperationAcorn/Story/MapFx"
local OA = OperationAcorn
local Fx = OA.StoryMapFx

local function dashesOf(out, n)
    local list = {}
    for i = 1, n do
        local o = i * 4
        list[i] = { out[o - 3], out[o - 2], out[o - 1], out[o] }
    end
    return list
end

local function length(d) return math.sqrt((d[3] - d[1]) ^ 2 + (d[4] - d[2]) ^ 2) end

test("a phase runs from 0 to 1 and over again, also from times as large as the clock's", function()
    near(Fx.phase(0, 1000), 0, 1e-9)
    near(Fx.phase(250, 1000), 0.25, 1e-9)
    near(Fx.phase(1250, 1000), 0.25, 1e-9)
    near(Fx.phase(-250, 1000), 0.75, 1e-9, "never below 0")
    near(Fx.phase(1760000000123, 1000), 0.123, 1e-6)
    near(Fx.wave(0), 0, 1e-9)
    near(Fx.wave(0.5), 1, 1e-9)
    near(Fx.easeOut(0), 0, 1e-9)
    near(Fx.easeOut(1), 1, 1e-9)
    truthy(Fx.easeOut(0.5) > 0.5, "fast at first")
end)

test("the drop starts up, lands at the end, and stays landed", function()
    eq(Fx.bounce(-1), 0)
    eq(Fx.bounce(0), 0)
    near(Fx.bounce(1), 1, 1e-9)
    eq(Fx.bounce(3), 1)
    for f = 0, 1, 0.01 do truthy(Fx.bounce(f) >= 0 and Fx.bounce(f) <= 1.0001, f) end
    near(Fx.bounce(1 / 2.75), 1, 1e-9, "the first landing")
    truthy(Fx.bounce(0.55) < 1, "then a bounce")
end)

test("a line is clipped to the view", function()
    local t0, t1 = Fx.clip(-50, 50, 150, 50, 0, 0, 100, 100)
    near(t0, 0.25, 1e-9)
    near(t1, 0.75, 1e-9)
    eq(Fx.clip(-50, -10, 150, -10, 0, 0, 100, 100), nil, "above the view")
    t0, t1 = Fx.clip(10, 10, 20, 20, 0, 0, 100, 100)
    eq(t0, 0)
    eq(t1, 1)
end)

test("the way's dashes lie on the line, evenly, the ends cut to it", function()
    local out = {}
    local n = Fx.lineDashes(0, 0, 100, 0, 10, 5, 0, -1000, -1000, 1000, 1000, out, 99)
    local list = dashesOf(out, n)
    eq(n, 7)
    for i, d in ipairs(list) do
        eq(d[2], 0)
        eq(d[4], 0)
        near(d[1], (i - 1) * 15, 1e-9)
        truthy(d[3] <= 100)
    end
    near(length(list[7]), 10, 1e-9)
    -- moved by 8: a dash grows out of the start, the one at the end is cut by it
    n = Fx.lineDashes(0, 0, 100, 0, 10, 5, 8, -1000, -1000, 1000, 1000, out, 99)
    list = dashesOf(out, n)
    near(list[1][1], 0, 1e-9)
    near(list[1][3], 3, 1e-9, "the dash from -7 shows from 0")
    near(list[2][1], 8, 1e-9)
    near(list[n][1], 98, 1e-9)
    near(list[n][3], 100, 1e-9, "the last one is cut at the end")
end)

test("the way's dashes march: a shift moves each along the line, a whole period is the same picture", function()
    local a, b = {}, {}
    local na = Fx.lineDashes(0, 0, 0, 300, 20, 12, 5, -1000, -1000, 1000, 1000, a, 99)
    local nb = Fx.lineDashes(0, 0, 0, 300, 20, 12, 5 + 32 * 7, -1000, -1000, 1000, 1000, b, 99)
    eq(na, nb)
    for i = 1, na * 4 do near(a[i], b[i], 1e-6) end
    Fx.lineDashes(0, 0, 0, 300, 20, 12, 6, -1000, -1000, 1000, 1000, b, 99)
    near(b[6] - a[6], 1, 1e-9, "one pixel further toward the end")
end)

test("only the dashes in the view are given, whatever the line's length", function()
    local out = {}
    local n = Fx.lineDashes(-1000000, 50, 1000000, 50, 20, 12, 0, 0, 0, 800, 600, out, 512)
    truthy(n > 20 and n < 30, n)
    for i = 1, n do
        local o = i * 4
        truthy(out[o - 1] >= -20 and out[o - 3] <= 820, "near the view")
    end
    eq(Fx.lineDashes(0, -50, 800, -50, 20, 12, 0, 0, 0, 800, 600, out, 512), 0, "a line above the view")
    eq(Fx.lineDashes(5, 5, 5.2, 5, 20, 12, 0, 0, 0, 800, 600, out, 512), 0, "no line")
    eq(Fx.lineDashes(0, 50, 800, 50, 2, 1, 0, 0, 0, 800, 600, out, 10), 10, "at most max")
end)

test("the edge of a circle is on the way to the player; none from inside", function()
    local x, y = Fx.edge(0, 0, 100, 0, 30)
    near(x, 70, 1e-9)
    near(y, 0, 1e-9)
    x, y = Fx.edge(100, 100, 100, 0, 30)
    near(x, 100, 1e-9)
    near(y, 30, 1e-9)
    eq(Fx.edge(100, 10, 100, 0, 30), nil)
end)

test("a ring takes more points the larger it is on the screen", function()
    eq(Fx.samples(40), 32)
    eq(Fx.samples(300), 64)
    eq(Fx.samples(1000), 128)
    eq(Fx.samples(50000), Fx.SAMPLES)
    for _, r in ipairs({ 40, 119, 300, 499, 1000, 1999, 7999, 31999, 70000 }) do
        local n = Fx.samples(r)
        eq(Fx.SAMPLES % n, 0)
        eq(n % Fx.BLOCK, 0, "whole runs")
        truthy(r * (1 - math.cos(math.pi / n)) < 0.7, "a piece stays near the ring at " .. r)
    end
end)

test("a circle of the world is a circle on the flat view and an ellipse twice as wide on the isometric one", function()
    local ring = Fx.shape({}, 50, 0, 0, 50)
    eq(ring.n, 32)
    eq(#ring.xs, 33)
    near(ring.xs[1], ring.xs[33], 1e-9, "closed")
    for i = 1, 33 do near(math.sqrt(ring.xs[i] ^ 2 + ring.ys[i] ^ 2), 50, 1e-9) end
    near(ring.lens[33], 2 * math.pi * 50, 0.6, "the pieces stay within half a pixel")
    -- the game's isometric view: a square east is (0.707, 0.354) on the screen, a square south (-0.707, 0.354)
    ring = Fx.shape({}, 70.71, 35.36, -70.71, 35.36)
    local wide, high = 0, 0
    for i = 1, ring.n + 1 do
        wide = math.max(wide, math.abs(ring.xs[i]))
        high = math.max(high, math.abs(ring.ys[i]))
    end
    near(wide, 100, 0.5)
    near(high, 50, 0.5)
end)

test("a ring's shape is kept while its size stays, and made again when the map zooms", function()
    local ring = Fx.shape({}, 100, 0, 0, 100)
    local xs = ring.xs
    eq(Fx.shape(ring, 100.004, 0, 0, 99.997), ring)
    near(ring.xs[1], 100, 1e-12, "rounding: the same shape")
    Fx.shape(ring, 200, 0, 0, 200)
    near(ring.xs[1], 200, 1e-12, "zoomed: made again")
    eq(ring.xs, xs, "in the same tables")
    eq(ring.n, 64)
end)

local function ringOf(r, cx, cy, dash, gap, shift, view, max)
    local ring = Fx.shape({}, r, 0, 0, r)
    local out = {}
    local n = Fx.ringDashes(ring, cx, cy, dash, gap, shift, view[1], view[2], view[3], view[4], 6, out, max or 512)
    return dashesOf(out, n), ring
end

local WIDE = { -100000, -100000, 100000, 100000 }

test("a ring's dashes fit round it a whole number of times, evenly, and march round", function()
    local list, ring = ringOf(100, 500, 400, 14, 9, 0, WIDE)
    local around = ring.lens[ring.n + 1]
    eq(#list, math.floor(around / 23 + 0.5))
    local period = around / #list
    for _, d in ipairs(list) do
        near(math.sqrt((d[1] - 500) ^ 2 + (d[2] - 400) ^ 2), 100, 0.5, "on the ring, round its middle")
        near(length(d), 14 * period / 23, 0.3, "the same length")
    end
    for i = 2, #list do
        near(math.sqrt((list[i][1] - list[i - 1][1]) ^ 2 + (list[i][2] - list[i - 1][2]) ^ 2), period, 0.6, "even")
    end
    local moved = ringOf(100, 500, 400, 14, 9, period, WIDE)
    for i = 1, #list do
        for j = 1, 4 do near(moved[i][j], list[i][j], 1e-6, "a whole period round: the same") end
    end
    moved = ringOf(100, 500, 400, 14, 9, 3, WIDE)
    eq(#moved, #list)
    truthy(math.abs(moved[1][1] - list[1][1]) + math.abs(moved[1][2] - list[1][2]) > 1, "a shift moves them")
end)

test("a ring's dash over its first point joins its end to its start", function()
    local list, ring = ringOf(100, 0, 0, 14, 9, -5, WIDE)
    local last = list[#list]
    truthy(last[2] < 0 and last[4] > 0, "from below the first point (y < 0 at the end of the ring) to above it")
    near(length(last), 14 * (ring.lens[ring.n + 1] / #list) / 23, 0.3)
end)

test("a ring far larger than the view gives only the dashes near it", function()
    -- a ring 20000 pixels across round a point off the screen, its edge across an 800 x 600 view
    local list, ring = ringOf(10000, 400, 10300, 14, 9, 0, { 0, 0, 800, 600 })
    eq(ring.n, 512)
    truthy(#list > 20 and #list < 80, #list)
    -- the pieces are about 120 pixels long: a dash on a piece that reaches into the view is given
    for _, d in ipairs(list) do
        truthy(d[1] > -200 and d[1] < 1000 and d[2] > -200 and d[2] < 800, "near the view")
    end
    eq(#ringOf(10000, 400, 10300, 14, 9, 0, { 0, 0, 800, 600 }, 5), 5, "at most max")
    eq(#ringOf(100, 5000, 5000, 14, 9, 0, { 0, 0, 800, 600 }), 0, "a ring off the view")
end)

test("a tiny ring still has three dashes", function()
    eq(#ringOf(4, 50, 50, 14, 9, 0, { 0, 0, 100, 100 }), 3)
end)
