-- The terminal window's boot sequence (client Trade/BootSeq, DESIGN-terminal 12): which phase it is in at which time, the
-- line count, the click that skips it, the long version of a field terminal's first open, the crude terminal's extra line, garbled letters and flicker, and the switch-off's
-- numbers.
require "OperationAcorn/Core"
require "OperationAcorn/Trade/BootSeq"
local Seq = OperationAcorn.Trade.BootSeq

local function phaseAt(run, e)
    run.start = 1000
    local phase, shown, t = Seq.state(run, 1000 + e)
    return phase, shown, t
end

test("an ordinary open: black, each line with its cursor then its status, a beat, the welcome, the switch-off, the fade-in", function()
    local run = Seq.new(false, false)
    eq(#run.lines, 4, "check, link, collection point, welcome")
    eq(run.lines[1].key, "IGUI_OA_Boot_Check")
    eq(run.lines[4].key, "IGUI_OA_Boot_Welcome")
    eq(run.lines[4].bright, true, "the last line is the bright one")
    local phase, shown = phaseAt(run, 0)
    eq(phase, "console"); eq(shown, 0, "a black beat first")
    eq(select(2, phaseAt(run, 499)), 0)
    eq(select(2, phaseAt(run, 500)), 1)
    eq(Seq.statusAt(run, 1), 1400, "the cursor blinks 0.9 s before the status")
    eq(select(2, phaseAt(run, 2499)), 1)
    eq(select(2, phaseAt(run, 2500)), 2, "the status is seen 1.1 s before the next line")
    eq(Seq.appearAt(run, 3), 4500); eq(Seq.statusAt(run, 3), 5400)
    eq(select(2, phaseAt(run, 6199)), 3, "a beat before the welcome")
    eq(select(2, phaseAt(run, 6200)), 4)
    eq(Seq.statusAt(run, 4), 6200, "the welcome has no cursor")
    eq(phaseAt(run, 9199), "console", "the welcome is held 3 s")
    eq(run.consoleEnd, 9200)
    phase, shown = phaseAt(run, 9200)
    eq(phase, "collapse"); eq(shown, 4, "all the lines are still there as the switch-off starts")
    eq(run.fadeAt, 9480)
    local _, _, t = phaseAt(run, 9340)
    near(t, 0.5, 1e-9, "halfway through the switch-off")
    phase, _, t = phaseAt(run, 9480)
    eq(phase, "fade"); eq(t, 0)
    near(select(3, phaseAt(run, 9655)), 0.5, 1e-9)
    eq(phaseAt(run, 9829), "fade")
    eq(phaseAt(run, 9830), "done", "the fade-in lasts 0.35 s")
    eq(phaseAt(run, 99999), "done")
end)

test("the cursor blinks from on", function()
    eq(Seq.cursorOn(0), true)
    eq(Seq.cursorOn(Seq.BLINK_MS - 1), true)
    eq(Seq.cursorOn(Seq.BLINK_MS), false)
    eq(Seq.cursorOn(2 * Seq.BLINK_MS), true)
end)

test("the run counts from the first frame that asks, and a clock gone back is the start", function()
    local run = Seq.new(false, false)
    eq(run.start, nil, "not started when made")
    local phase, shown = Seq.state(run, 5000)
    eq(run.start, 5000); eq(phase, "console"); eq(shown, 0)
    eq(select(2, Seq.state(run, 4000)), 0, "an earlier time reads as the start")
    eq(select(2, Seq.state(run, 5000 + 4500)), 3)
end)

test("a click or a key skips straight to the fade-in, once", function()
    local run = Seq.new(false, false)
    Seq.state(run, 1000)
    Seq.skip(run, 1200)
    local phase, _, t = Seq.state(run, 1200)
    eq(phase, "fade"); eq(t, 0, "the fade starts at the click")
    eq((Seq.state(run, 1200 + 350)), "done")
    Seq.skip(run, 1300)
    eq((Seq.state(run, 1300)), "fade", "a click while fading does not start it again")
    Seq.skip(run, 5000)
    eq((Seq.state(run, 5000)), "done", "and one after it is over changes nothing")
    -- during the switch-off too
    run = Seq.new(false, false)
    Seq.state(run, 0)
    eq((Seq.state(run, 9300)), "collapse")
    Seq.skip(run, 9300)
    eq((Seq.state(run, 9300)), "fade")
    -- before the first frame
    run = Seq.new(false, false)
    Seq.skip(run, 700)
    eq((Seq.state(run, 700)), "fade")
end)

test("the first open of a field terminal is the long version, about 15.5 s (skippable, and only once)", function()
    local run = Seq.new(true, false)
    eq(#run.lines, 7, "three more self-tests than an ordinary open")
    local keys = {}
    for i, line in ipairs(run.lines) do keys[i] = line.key end
    eq(keys[2], "IGUI_OA_Boot_Storage"); eq(keys[3], "IGUI_OA_Boot_Clock"); eq(keys[5], "IGUI_OA_Boot_Server")
    eq(keys[7], "IGUI_OA_Boot_Welcome")
    truthy(run.fadeAt >= 15000 and run.fadeAt <= 16000, "fade-in starts at " .. run.fadeAt)
    eq(select(2, phaseAt(run, 599)), 0)
    eq(select(2, phaseAt(run, 600)), 1)
    eq(select(2, phaseAt(run, 12299)), 6)
    eq(select(2, phaseAt(run, 12300)), 7, "the welcome at 12.3 s")
    eq(phaseAt(run, run.consoleEnd - 1), "console")
    eq(phaseAt(run, run.consoleEnd), "collapse")
    Seq.skip(run, 1000 + 300)
    eq((Seq.state(run, 1300)), "fade", "a click skips the long one too")
    -- the crude one adds its retry line: still inside the range
    local crude = Seq.new(true, true)
    eq(#crude.lines, 8)
    eq(crude.fadeAt - run.fadeAt, Seq.WEAK_WAIT_MS + Seq.GAP_MS, "the weak signal's long wait")
end)

test("the crude terminal reads one line longer, and the field terminal is clean", function()
    local crude = Seq.new(false, true)
    eq(#crude.lines, 5)
    eq(crude.lines[2].key, "IGUI_OA_Boot_Weak", "the retry comes before the link line")
    eq(crude.lines[3].key, "IGUI_OA_Boot_Link")
    eq(crude.crude, true)
    local field = Seq.new(false, false)
    eq(field.crude, false)
    for _, line in ipairs(field.lines) do truthy(line.key ~= "IGUI_OA_Boot_Weak") end
    truthy(crude.fadeAt > field.fadeAt, "one more line to print")
    eq(crude.fadeAt - field.fadeAt, Seq.WEAK_WAIT_MS + Seq.GAP_MS, "the weak signal's line, its cursor longer")
    eq(Seq.statusAt(crude, 2) - Seq.appearAt(crude, 2), Seq.WEAK_WAIT_MS)
    truthy(Seq.WEAK_WAIT_MS >= 2 * Seq.WAIT_MS, "clearly longer than the others")
    -- every line has words, and all but the last end with a status
    for _, line in ipairs(crude.lines) do
        truthy(line.key, "words")
        if not line.bright then truthy(line.status, "a status") end
    end
end)

test("garbled letters change for a moment and settle, the same every time", function()
    local text = "채집점 0347 인증"
    eq(Seq.garble(text, 3, Seq.SETTLE_MS), text, "settled")
    eq(Seq.garble(text, 3, 5000), text)
    eq(Seq.garble(text, 3, -1), text, "not there yet")
    local early = Seq.garble(text, 3, 0)
    truthy(early ~= text, "garbled at first")
    eq(Seq.garble(text, 3, 0), early, "no random state")
    -- the game's strings hold a Korean letter as one character: it is replaced whole by one ASCII glyph
    eq(#early, #text, "the same number of characters")
    local function differs(a)
        local n = 0
        for i = 1, #text do
            if string.sub(a, i, i) ~= string.sub(text, i, i) then n = n + 1 end
        end
        return n
    end
    truthy(differs(early) >= 1 and differs(early) <= Seq.GARBLE_MAX)
    truthy(differs(Seq.garble(text, 3, 250)) <= 1, "one left near the end")
    -- spaces are left as they are
    for age = 0, 290, 10 do
        local g = Seq.garble("a b", 1, age)
        eq(string.sub(g, 2, 2), " ")
    end
end)

test("the crude terminal's flicker dips now and then and is the same each time", function()
    local dips, full = 0, 0
    for e = 0, 2000, 15 do
        local f = Seq.flicker(e)
        truthy(f > 0 and f <= 1)
        if f < 1 then dips = dips + 1 else full = full + 1 end
        eq(Seq.flicker(e), f)
    end
    truthy(dips > 0, "it flickers")
    truthy(full > dips * 3, "slightly: most of the time it is steady")
end)

test("the switch-off: the content falls to a line, the line shrinks to a dot and goes out", function()
    local k, w, a = Seq.switchOff(0)
    eq(k, 1); eq(w, 1); eq(a, 0)
    k, w, a = Seq.switchOff(Seq.SPLIT)
    eq(k, 0, "the content is a line at the split"); eq(w, 1); near(a, 1, 1e-9)
    local k2, w2 = Seq.switchOff(Seq.SPLIT + (1 - Seq.SPLIT) / 2)
    eq(k2, 0); truthy(w2 < 1 and w2 > 0, "the line is shrinking")
    k, w, a = Seq.switchOff(1)
    eq(k, 0); eq(w, 0); near(a, 0, 1e-9)
    local last = 1
    for i = 0, 10 do
        local kk = Seq.switchOff(i / 10 * Seq.SPLIT)
        truthy(kk <= last, "never grows")
        last = kk
    end
end)

test("what the console shows changes exactly when its drawing does: a line, its end, the cursor's blink", function()
    local run = Seq.new(false, false)
    run.start = 0
    local last, lastSig, changes = nil, nil, 0
    for e = 0, run.consoleEnd - 1, 5 do
        local phase, shown = Seq.state(run, e)
        eq(phase, "console")
        local sig = tostring(shown)
        if shown > 0 then
            if e >= Seq.statusAt(run, shown) then sig = sig .. ":ended"
            else sig = sig .. ":" .. tostring(Seq.cursorOn(e - Seq.appearAt(run, shown))) end
        end
        local look = Seq.look(run, phase, shown, e)
        eq(look ~= last, sig ~= lastSig, "at " .. e .. " ms")
        if look ~= last then changes = changes + 1 end
        last, lastSig = look, sig
    end
    truthy(changes > 8 and changes < 40, "a few dozen changes, not one a frame")
    local phase, shown, _, e = Seq.state(run, run.consoleEnd + 10)
    eq(phase, "collapse")
    eq(Seq.look(run, phase, shown, e), e, "the switch-off moves every frame")
    truthy(e > last)
    local crude = Seq.new(false, true)
    crude.start = 0
    phase, shown, _, e = Seq.state(crude, 1234)
    eq(Seq.look(crude, phase, shown, e), 1234, "the crude console flickers: every frame")
end)

test("the crude screen jolts now and then: short bursts, a few units, dying out, the same every time", function()
    local bursts, inBurst, still, maxX, maxY = 0, false, 0, 0, 0
    for e = 0, 12000, 10 do
        local dx, dy = Seq.shake(e)
        eq(dx, math.floor(dx)); eq(dy, math.floor(dy))
        local x2, y2 = Seq.shake(e)
        eq(x2, dx); eq(y2, dy)
        maxX, maxY = math.max(maxX, math.abs(dx)), math.max(maxY, math.abs(dy))
        local moving = dx ~= 0 or dy ~= 0
        if moving and not inBurst then bursts = bursts + 1 end
        inBurst = moving
        if not moving then still = still + 1 end
    end
    truthy(bursts >= 4 and bursts <= 9, "now and then over a crude boot: " .. bursts)
    truthy(still > 1000, "still most of the time")
    truthy(maxX <= Seq.SHAKE_UNITS and maxY <= Seq.SHAKE_UNITS, "a few units")
    truthy(maxX >= 2, "and visible")
end)
