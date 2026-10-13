-- The geometry of what this mod draws over the world map and the minimap (DESIGN-terminal 8; Story/Maps draws it): the
-- dashes of the way to the mission and of its circle's ring, the ring as the map shows it, and the animations' timing.
-- Pure: numbers in, numbers out, the lists written into tables the caller keeps (the drawing runs every frame a map is
-- open and makes nothing), so it is tested outside the game. Every length here is in screen pixels.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Fx = {}
OA.StoryMapFx = Fx

local sqrt, floor, ceil, fmod, abs = math.sqrt, math.floor, math.ceil, math.fmod, math.abs
local cos, sin, pi = math.cos, math.sin, math.pi

-- Timing ----------------------------------------------------------------------------------------------------------

-- How far into a repeating animation of `period` ms the time `t` (ms) is, 0 to 1. math.fmod, not %: Kahlua's % goes
-- wrong on numbers as large as getTimestampMs (the caller passes the time since the file loaded anyway).
function Fx.phase(t, period)
    local f = fmod(t, period) / period
    if f < 0 then f = f + 1 end
    return f
end

-- A smooth rise and fall over one phase: 0 at 0 and 1, 1 at the half.
function Fx.wave(f)
    return 0.5 - 0.5 * cos(2 * pi * f)
end

-- Fast at first, slowing to a stop at 1: how a ripple or a pulse grows.
function Fx.easeOut(f)
    return 1 - (1 - f) * (1 - f)
end

-- A fall that lands and bounces (an ease-out bounce): 0 at f = 0, 1 (landed) from f = 1 on.
function Fx.bounce(f)
    if f <= 0 then return 0 end
    if f >= 1 then return 1 end
    local n, d = 7.5625, 2.75
    if f < 1 / d then return n * f * f end
    if f < 2 / d then
        f = f - 1.5 / d
        return n * f * f + 0.75
    end
    if f < 2.5 / d then
        f = f - 2.25 / d
        return n * f * f + 0.9375
    end
    f = f - 2.625 / d
    return n * f * f + 0.984375
end

-- Lines -----------------------------------------------------------------------------------------------------------

-- One edge of the clip below: the part of the line's [t0, t1] on the inner side of it.
local function cut(p, q, t0, t1)
    if p == 0 then
        if q < 0 then return nil end
        return t0, t1
    end
    local r = q / p
    if p < 0 then
        if r > t1 then return nil end
        if r > t0 then t0 = r end
    else
        if r < t0 then return nil end
        if r < t1 then t1 = r end
    end
    return t0, t1
end

-- The part of the line from (x1, y1) to (x2, y2) inside the rectangle, as the share of the line where it goes in and
-- where it comes out (0 to 1), or nil when none of it is inside.
function Fx.clip(x1, y1, x2, y2, minX, minY, maxX, maxY)
    local dx, dy = x2 - x1, y2 - y1
    local t0, t1 = cut(-dx, x1 - minX, 0, 1)
    if t0 then t0, t1 = cut(dx, maxX - x1, t0, t1) end
    if t0 then t0, t1 = cut(-dy, y1 - minY, t0, t1) end
    if t0 then t0, t1 = cut(dy, maxY - y1, t0, t1) end
    return t0, t1
end

-- The dashes along the line from (x1, y1) to (x2, y2): `dash` long with `gap` between, the pattern moved `shift`
-- along the line (a shift that grows makes them march from the start to the end). A dash the line's ends cut is cut
-- (it grows out of the start and shrinks into the end); only the dashes in the view (minX .. maxY, grown by a dash) are
-- given, whole, at most `max`. Written into `out` as x1, y1, x2, y2 for each; returns how many.
function Fx.lineDashes(x1, y1, x2, y2, dash, gap, shift, minX, minY, maxX, maxY, out, max)
    local dx, dy = x2 - x1, y2 - y1
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.5 then return 0 end
    local t0, t1 = Fx.clip(x1, y1, x2, y2, minX - dash, minY - dash, maxX + dash, maxY + dash)
    if not t0 then return 0 end
    local period = dash + gap
    shift = fmod(shift, period)
    if shift < 0 then shift = shift + period end
    local a, b = t0 * len, t1 * len
    local ux, uy = dx / len, dy / len
    local s = shift + floor((a - shift - dash) / period) * period
    local got = 0
    while s < b and got < max do
        local e = s + dash
        if e > a then
            local cs = s < 0 and 0 or s
            local ce = e > len and len or e
            if ce > cs then
                got = got + 1
                local o = got * 4
                out[o - 3], out[o - 2], out[o - 1], out[o] = x1 + ux * cs, y1 + uy * cs, x1 + ux * ce, y1 + uy * ce
            end
        end
        s = s + period
    end
    return got
end

-- The point of a circle (x, y, r) nearest to (px, py): where the way from there to the circle meets its edge. Nil
-- when (px, py) is inside the circle.
function Fx.edge(px, py, x, y, r)
    local dx, dy = px - x, py - y
    local d = sqrt(dx * dx + dy * dy)
    if d <= r then return nil end
    return x + dx * r / d, y + dy * r / d
end

-- Rings -----------------------------------------------------------------------------------------------------------

-- A ring is a circle of the world as the map shows it: (cx, cy) + cos t * (ax, ay) + sin t * (bx, by), the two
-- vectors being the circle's radius along the world's x and y on the screen (on the flat view a circle, on the
-- isometric one an ellipse). It is drawn through points sampled around it; a larger ring on the screen takes more of
-- them (each a power of two up to SAMPLES, so the angles come from one table), enough that the straight piece between
-- two points stays within about half a pixel of the ring (the map's largest zoom makes a mission's ring tens of
-- thousands of pixels across).
Fx.SAMPLES = 1024
local COS, SIN = {}, {}
for i = 0, Fx.SAMPLES do
    COS[i] = cos(2 * pi * i / Fx.SAMPLES)
    SIN[i] = sin(2 * pi * i / Fx.SAMPLES)
end

-- How many points a ring `radius` pixels across (its larger half-axis) is drawn through.
function Fx.samples(radius)
    if radius < 120 then return 32 end
    if radius < 500 then return 64 end
    if radius < 2000 then return 128 end
    if radius < 8000 then return 256 end
    if radius < 32000 then return 512 end
    return Fx.SAMPLES
end

-- The pieces are looked at in runs of BLOCK, each with its box: a run off the view is passed over whole, so a ring far
-- larger than the screen costs little more than its visible arc.
Fx.BLOCK = 32
local BLOCK = Fx.BLOCK

-- A ring's shape, in a table the caller keeps for it: the points around it from its middle (xs, ys, 1 .. n + 1, the
-- last the first again), the length along it to each (lens) and the box of each run of pieces. Worked out again only
-- when its half-axes change (the map zooms or turns), not when the map pans or the player moves (the axes measured
-- then differ by the game's rounding only: a hundredth of a pixel, and a millionth of the size, is the same shape).
-- Returns the table.
function Fx.shape(ring, ax, ay, bx, by)
    if ring.n then
        local still = 0.01 + 1e-6 * (abs(ax) + abs(ay) + abs(bx) + abs(by))
        if abs(ring.ax - ax) < still and abs(ring.ay - ay) < still and abs(ring.bx - bx) < still
                and abs(ring.by - by) < still then
            return ring
        end
    end
    local n = Fx.samples(math.max(sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)))
    ring.ax, ring.ay, ring.bx, ring.by, ring.n = ax, ay, bx, by, n
    local xs, ys, lens = ring.xs or {}, ring.ys or {}, ring.lens or {}
    ring.xs, ring.ys, ring.lens = xs, ys, lens
    local step = Fx.SAMPLES / n
    for i = 0, n do
        local c, s = COS[i * step], SIN[i * step]
        xs[i + 1] = c * ax + s * bx
        ys[i + 1] = c * ay + s * by
    end
    lens[1] = 0
    for i = 1, n do
        local dx, dy = xs[i + 1] - xs[i], ys[i + 1] - ys[i]
        lens[i + 1] = lens[i] + sqrt(dx * dx + dy * dy)
    end
    local boxes = ring.boxes or {}
    ring.boxes = boxes
    for b = 0, n / BLOCK - 1 do
        local first = b * BLOCK + 1
        local x0, y0, x1, y1 = xs[first], ys[first], xs[first], ys[first]
        for i = first + 1, first + BLOCK do
            local x, y = xs[i], ys[i]
            if x < x0 then x0 = x elseif x > x1 then x1 = x end
            if y < y0 then y0 = y elseif y > y1 then y1 = y end
        end
        local o = b * 4
        boxes[o + 1], boxes[o + 2], boxes[o + 3], boxes[o + 4] = x0, y0, x1, y1
    end
    return ring
end

-- The dashes around a ring (its shape from Fx.shape) whose middle is at (cx, cy): as near `dash` long with `gap`
-- between as a whole number of them fits around (at least three), so there is no seam; the pattern moved `shift`
-- along (a shift that grows makes them march around). Only the dashes starting on pieces in the view (minX .. maxY,
-- grown by a dash and `pad`) are given, at most `max`; each goes from its start to its end in a straight line.
-- Written into `out` as x1, y1, x2, y2 for each; returns how many.
function Fx.ringDashes(ring, cx, cy, dash, gap, shift, minX, minY, maxX, maxY, pad, out, max)
    local xs, ys, lens, boxes, n = ring.xs, ring.ys, ring.lens, ring.boxes, ring.n
    local total = lens[n + 1]
    if total <= 0 then return 0 end
    local count = floor(total / (dash + gap) + 0.5)
    if count < 3 then count = 3 end
    local period = total / count
    local d = dash * period / (dash + gap)
    shift = fmod(shift, period)
    if shift < 0 then shift = shift + period end
    -- the view, grown and taken relative to the ring's middle
    local grow = d + pad
    minX, minY, maxX, maxY = minX - grow - cx, minY - grow - cy, maxX + grow - cx, maxY + grow - cy
    local got = 0
    for b = 0, n / BLOCK - 1 do
        local o = b * 4
        if boxes[o + 3] >= minX and boxes[o + 1] <= maxX and boxes[o + 4] >= minY and boxes[o + 2] <= maxY then
            for i = b * BLOCK + 1, b * BLOCK + BLOCK do
                local ax, ay, bx, by = xs[i], ys[i], xs[i + 1], ys[i + 1]
                if not ((ax < minX and bx < minX) or (ax > maxX and bx > maxX) or (ay < minY and by < minY)
                        or (ay > maxY and by > maxY)) then
                    local s0, s1 = lens[i], lens[i + 1]
                    local k = ceil((s0 - shift) / period)
                    if k < 0 then k = 0 end
                    local s = shift + k * period
                    while s < s1 and k < count do
                        if got >= max then return got end
                        local f = (s - s0) / (s1 - s0)
                        local sx, sy = ax + (bx - ax) * f, ay + (by - ay) * f
                        -- the dash's end: on this piece or one further on (past the last point, round to the first)
                        local e = s + d
                        local m = i
                        if e >= total then
                            e = e - total
                            m = 1
                        end
                        while m < n and lens[m + 1] < e do m = m + 1 end
                        local g = lens[m + 1] - lens[m]
                        f = g > 0 and (e - lens[m]) / g or 0
                        got = got + 1
                        local w = got * 4
                        out[w - 3], out[w - 2] = cx + sx, cy + sy
                        out[w - 1] = cx + xs[m] + (xs[m + 1] - xs[m]) * f
                        out[w] = cy + ys[m] + (ys[m + 1] - ys[m]) * f
                        k = k + 1
                        s = s + period
                    end
                end
            end
        end
    end
    return got
end

return Fx
