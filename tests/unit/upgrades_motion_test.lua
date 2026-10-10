-- The research tab's motions (shared Upgrades/Motion): a click's pop, shrink and shake, the ring of a pop, a padlock
-- coming off, the light on the lines and the opening: their curves start and end where the tab expects them, take
-- the time the eye needs, and the lights on the lines keep out of step.
require "OperationAcorn/Upgrades/Motion"
local OA = OperationAcorn
local Motion = OA.Upgrades.Motion

-- The largest and smallest values of f over 0..ms, a millisecond apart, and when the largest comes.
local function span(f, ms)
    local hi, lo, at = -math.huge, math.huge, 0
    for t = 0, ms do
        local v = f(t)
        if v > hi then hi, at = v, t end
        if v < lo then lo = v end
    end
    return hi, lo, at
end

test("an ease out runs from 0 to 1, fast first, and holds at its ends", function()
    eq(Motion.easeOut(-1), 0)
    eq(Motion.easeOut(0), 0)
    eq(Motion.easeOut(1), 1)
    eq(Motion.easeOut(2), 1)
    truthy(Motion.easeOut(0.5) > 0.75, "most of the way by the middle")
    local last = 0
    for i = 1, 20 do
        local v = Motion.easeOut(i / 20)
        truthy(v >= last, "never back")
        last = v
    end
end)

test("a pop swells the node by its share early and settles back; a shrink does the same inward", function()
    eq(Motion.pop(-1), 1)
    eq(Motion.pop(0), 1)
    eq(Motion.pop(Motion.POP_MS), 1)
    local hi, lo, at = span(Motion.pop, Motion.POP_MS)
    near(hi, 1 + Motion.POP_SCALE, 0.002, "the top")
    truthy(lo >= 1, "never smaller")
    truthy(at < Motion.POP_MS / 3, "the jump is quick, the settling longer")
    truthy(Motion.POP_MS >= 220 and Motion.POP_MS <= 300, "long enough to catch")
    truthy(Motion.POP_SCALE >= 0.15, "large enough to catch")
    eq(Motion.shrink(Motion.SHRINK_MS), 1)
    hi, lo = span(Motion.shrink, Motion.SHRINK_MS)
    near(lo, 1 - Motion.SHRINK_SCALE, 0.002, "the bottom")
    truthy(hi <= 1, "never larger")
end)

test("a pop's ring goes out from the frame, bright and thick at first, thinning and fading, then is gone", function()
    local grow, a, w = Motion.ripple(0)
    eq(grow, 0)
    eq(a, 1, "full at first")
    eq(w, Motion.RIPPLE_WIDTH)
    local lastGrow, lastA, lastW = grow, a, w
    for t = 10, Motion.RIPPLE_MS - 1, 10 do
        grow, a, w = Motion.ripple(t)
        truthy(grow >= lastGrow and a <= lastA and w <= lastW, "out, fading and thinning at " .. t)
        lastGrow, lastA, lastW = grow, a, w
    end
    truthy(lastGrow > Motion.RIPPLE_GROW * 0.95 and lastA < 0.05, "nearly out and gone at the end")
    truthy(lastW >= Motion.RIPPLE_WIDTH / 2, "never thinner than half")
    eq(Motion.ripple(Motion.RIPPLE_MS), nil)
    eq(Motion.ripple(-1), nil)
end)

test("a click's answer lasts as long as its longest part: the ring, the floating number, the pip's flash", function()
    eq(Motion.fxMs("pop"), math.max(Motion.POP_MS, Motion.RIPPLE_MS, Motion.FLOAT_MS, Motion.PIP_MS))
    eq(Motion.fxMs("shrink"), math.max(Motion.SHRINK_MS, Motion.FLOAT_MS, Motion.PIP_MS))
    eq(Motion.fxMs("shake"), Motion.SHAKE_MS)
    -- stretched in game to look at it slowly, it lasts longer at once
    local saved = Motion.FLOAT_MS
    Motion.FLOAT_MS = 6000
    eq(Motion.fxMs("pop"), 6000)
    Motion.FLOAT_MS = saved
end)

test("the +1 or -1 rises easing out, holds full a while, then fades out and is gone", function()
    local rise, a = Motion.float(0)
    eq(rise, 0)
    eq(a, 1)
    rise, a = Motion.float(Motion.FLOAT_MS * Motion.FLOAT_HOLD)
    eq(a, 1, "still full at the end of its hold")
    truthy(rise > Motion.FLOAT_RISE * 0.6, "most of its rise done by then")
    local lastRise, lastA = 0, 1
    for t = 10, Motion.FLOAT_MS - 1, 10 do
        rise, a = Motion.float(t)
        truthy(rise >= lastRise and a <= lastA, "up and fading at " .. t)
        lastRise, lastA = rise, a
    end
    truthy(lastA < 0.1 and lastRise > Motion.FLOAT_RISE * 0.99)
    eq(Motion.float(Motion.FLOAT_MS), nil)
    eq(Motion.float(-1), nil)
end)

test("a pip's flash grows out from the pip and dies out", function()
    local k, a = Motion.pipFlash(0)
    eq(k, 1)
    eq(a, 1)
    k, a = Motion.pipFlash(Motion.PIP_MS - 1)
    truthy(k > 1 + Motion.PIP_GROW * 0.99 and a < 0.01)
    eq(Motion.pipFlash(Motion.PIP_MS), nil)
end)

test("the points left hop up and back and light, then are still", function()
    local hi, lo = span(function(t) return (Motion.bump(t)) end, Motion.BUMP_MS - 1)
    near(hi, Motion.BUMP_HOP, 0.01, "the top of the hop")
    truthy(lo >= 0, "never below its place")
    local hop, lit = Motion.bump(0)
    eq(hop, 0)
    eq(lit, 1)
    eq(Motion.bump(Motion.BUMP_MS), nil)
end)

test("a refusal shakes the node both ways, a few design units at most, and leaves it where it was", function()
    eq(Motion.shake(0), 0)
    eq(Motion.shake(Motion.SHAKE_MS), 0)
    eq(Motion.shake(-5), 0)
    local hi, lo = span(Motion.shake, Motion.SHAKE_MS)
    truthy(hi > 1 and lo < -1, "both ways")
    truthy(hi <= Motion.SHAKE_DU and -lo <= Motion.SHAKE_DU)
    truthy(math.abs(Motion.shake(Motion.SHAKE_MS - 1)) < 0.1, "still at the end")
    eq(Motion.fxMs("nothing"), 0)
end)

test("a padlock waits locked, fades out while the frame flashes once and sends a ring out, then is over", function()
    local lock, flash, ring = Motion.unlock(-100)
    eq(lock, 1, "before its time: locked")
    eq(flash, 0)
    eq(ring, 0)
    local _, _, late = Motion.unlock(Motion.UNLOCK_MS - 1)
    truthy(late > Motion.UNLOCK_RING * 0.99, "the ring out by the end")
    lock, flash = Motion.unlock(0)
    eq(lock, 1)
    eq(flash, 0)
    lock, flash = Motion.unlock(Motion.UNLOCK_PEAK_MS)
    near(flash, 1, 1e-9, "the flash's top")
    truthy(lock > 0.5, "the padlock still there at the flash's top")
    lock = Motion.unlock(Motion.UNLOCK_LOCK_MS)
    eq(lock, 0, "the padlock gone")
    lock, flash = Motion.unlock(Motion.UNLOCK_MS - 1)
    truthy(flash < 0.01, "the flash gone by the end")
    eq(Motion.unlock(Motion.UNLOCK_MS), nil)
    truthy(Motion.UNLOCK_MS >= 400 and Motion.UNLOCK_MS <= 600)
    truthy(Motion.UNLOCK_DELAY_MS < Motion.POP_MS, "behind the pop's top, not after its end")
end)

test("a line's light passes once a period, from the line's start to its end, faint, and gone between passes", function()
    local period = Motion.BEAD_PERIOD_MS
    for _, len in ipairs({ 6, 10, 56, 160 }) do
        local passes, lastHead, on = 0, nil, false
        for ms = 0, 3 * period - 1, 5 do
            local head, a, blen = Motion.bead(ms, 3, len)
            if head then
                if not on then passes = passes + 1 end
                truthy(head >= 0 and head <= len, "on the line")
                truthy(a >= 0 and a <= Motion.BEAD_ALPHA, "faint")
                truthy(blen <= len / 2 and blen <= Motion.BEAD_LEN, "short")
                if on then truthy(head >= lastHead, "down the line, never back") end
                lastHead = head
            end
            on = head ~= nil
        end
        truthy(passes >= 3 and passes <= 4, "once a period for " .. len .. " (" .. passes .. ")")
    end
    -- the same on a clock hours on (a remainder taken with floor, no `%`)
    local at = 0
    while Motion.bead(at, 7, 80) == nil do at = at + 10 end
    at = at + 100
    local h1, a1 = Motion.bead(at, 7, 80)
    local h2, a2 = Motion.bead(at + 5000 * period, 7, 80)
    near(h2, h1, 1e-6)
    near(a2, a1, 1e-6)
end)

test("the lines' lights are out of step: neighbours start their passes far apart", function()
    local period = Motion.BEAD_PERIOD_MS
    -- when line i's pass starts within a period
    local function startOf(i)
        local last = Motion.bead(period - 1, i, 50) ~= nil
        for ms = 0, period - 1 do
            local on = Motion.bead(ms, i, 50) ~= nil
            if on and not last then return ms end
            last = on
        end
        return nil
    end
    local starts = {}
    for i = 1, 12 do
        starts[i] = startOf(i)
        truthy(starts[i] ~= nil, "line " .. i .. " passes")
    end
    for i = 2, 12 do
        local d = math.abs(starts[i] - starts[i - 1])
        d = math.min(d, period - d)
        truthy(d >= period / 5, "lines " .. (i - 1) .. " and " .. i .. " apart (" .. d .. " ms)")
    end
end)

test("the opening: columns rise in a step apart, nodes pop in row by row, lines draw after their nodes", function()
    local cols, rows = 3, 5
    local ends = Motion.openEnd(cols, rows)
    truthy(ends >= 700 and ends <= 900, "a staged entrance, not a wait: " .. ends)
    for c = 1, cols do
        local start = (c - 1) * Motion.OPEN_COL_MS
        local rise, shown = Motion.openColumn(start, c)
        eq(rise, Motion.OPEN_RISE, "column " .. c .. " below its place until its turn")
        eq(shown, 0)
        rise, shown = Motion.openColumn(ends, c)
        eq(rise, 0, "in place by the end")
        eq(shown, 1)
        if c > 1 then
            local _, before = Motion.openColumn(start, c - 1)
            truthy(before > 0.5, "the column before mostly in")
        end
        eq(Motion.openBar(start, c), 0, "the bar empty at first")
        eq(Motion.openBar(ends, c), 1, "and full by the end")
        for r = 1, rows do
            local k, e = Motion.openNode(start, c, r)
            eq(e, 0, "row " .. r .. " not in at first")
            eq(k, Motion.OPEN_NODE_FROM, "and small")
            k, e = Motion.openNode(ends, c, r)
            eq(k, 1)
            eq(e, 1)
            eq(Motion.openLine(ends, c, r), 1, "its lines drawn by the end")
            if r > 1 then
                local nodeStart = start + Motion.OPEN_NODE_WAIT_MS + (r - 1) * Motion.OPEN_ROW_MS
                local _, above = Motion.openNode(nodeStart, c, r - 1)
                truthy(above > 0, "row " .. (r - 1) .. " before row " .. r)
                eq(Motion.openLine(nodeStart, c, r), 0, "a line waits for its node")
                local _, half = Motion.openNode(nodeStart + Motion.OPEN_LINE_LAG * Motion.OPEN_NODE_MS, c, r)
                truthy(half > 0.8, "and starts once its node is mostly in")
            end
        end
    end
end)
