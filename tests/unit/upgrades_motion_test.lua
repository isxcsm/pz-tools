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
    truthy(Motion.POP_MS >= 150 and Motion.POP_MS <= 200)
    eq(Motion.shrink(Motion.SHRINK_MS), 1)
    hi, lo = span(Motion.shrink, Motion.SHRINK_MS)
    near(lo, 1 - Motion.SHRINK_SCALE, 0.002, "the bottom")
    truthy(hi <= 1, "never larger")
end)

test("a pop's ring goes out from the frame and fades, then is gone", function()
    local grow, a = Motion.ripple(0)
    eq(grow, 0)
    near(a, 0.85, 1e-9)
    local lastGrow, lastA = grow, a
    for t = 10, Motion.RIPPLE_MS - 1, 10 do
        grow, a = Motion.ripple(t)
        truthy(grow >= lastGrow and a <= lastA, "out and fading at " .. t)
        lastGrow, lastA = grow, a
    end
    truthy(lastGrow > Motion.RIPPLE_GROW * 0.95 and lastA < 0.05, "nearly out and gone at the end")
    eq(Motion.ripple(Motion.RIPPLE_MS), nil)
    eq(Motion.ripple(-1), nil)
    eq(Motion.fxMs("pop"), math.max(Motion.POP_MS, Motion.RIPPLE_MS), "a pop lasts as long as its ring")
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

test("a padlock waits locked, fades out while the frame flashes once, then is over", function()
    local lock, flash = Motion.unlock(-100)
    eq(lock, 1, "before its time: locked")
    eq(flash, 0)
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

test("the opening brings the columns in a step apart from the left, the rows from the top, in about 400 ms", function()
    local cols, rows = 3, 5
    local ends = Motion.openEnd(cols, rows)
    truthy(ends <= 450, "quick: " .. ends)
    for c = 1, cols do
        local start = (c - 1) * Motion.OPEN_COL_MS
        eq(Motion.openColumn(start, c), 1, "column " .. c .. " hidden until its turn")
        eq(Motion.openColumn(ends, c), 0, "and shown by the end")
        if c > 1 then truthy(Motion.openColumn(start, c - 1) < 0.5, "the one before mostly in") end
        for r = 1, rows do
            eq(Motion.openRow(start, c, r), 1, "row " .. r .. " dark at first")
            eq(Motion.openRow(ends, c, r), 0, "and lit by the end")
            if r > 1 then
                local t = start + Motion.OPEN_ROW_WAIT_MS + (r - 1) * Motion.OPEN_ROW_MS
                truthy(Motion.openRow(t, c, r - 1) < Motion.openRow(t, c, r), "row " .. (r - 1) .. " before " .. r)
            end
        end
    end
end)
