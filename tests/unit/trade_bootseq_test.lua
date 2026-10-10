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
    eq(select(2, phaseAt(run, 399)), 0)
    eq(select(2, phaseAt(run, 400)), 1)
    eq(Seq.statusAt(run, 1), 1100, "the cursor blinks 0.7 s before the status")
    eq(select(2, phaseAt(run, 1349)), 1)
    eq(select(2, phaseAt(run, 1350)), 2, "the next line 0.25 s after the status")
    eq(Seq.appearAt(run, 3), 2300); eq(Seq.statusAt(run, 3), 3000)
    eq(select(2, phaseAt(run, 3599)), 3, "a beat before the welcome")
    eq(select(2, phaseAt(run, 3600)), 4)
    eq(Seq.statusAt(run, 4), 3600, "the welcome has no cursor")
    eq(phaseAt(run, 4799), "console", "the welcome is held")
    eq(run.consoleEnd, 4800)
    phase, shown = phaseAt(run, 4800)
    eq(phase, "collapse"); eq(shown, 4, "all the lines are still there as the switch-off starts")
    eq(run.fadeAt, 5080)
    local _, _, t = phaseAt(run, 4940)
    near(t, 0.5, 1e-9, "halfway through the switch-off")
    phase, _, t = phaseAt(run, 5080)
    eq(phase, "fade"); eq(t, 0)
    near(select(3, phaseAt(run, 5255)), 0.5, 1e-9)
    eq(phaseAt(run, 5429), "fade")
    eq(phaseAt(run, 5430), "done", "the fade-in lasts 0.35 s")
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
    eq(select(2, Seq.state(run, 5000 + 2300)), 3)
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
    eq((Seq.state(run, 4900)), "collapse")
    Seq.skip(run, 4900)
    eq((Seq.state(run, 4900)), "fade")
    -- before the first frame
    run = Seq.new(false, false)
    Seq.skip(run, 700)
    eq((Seq.state(run, 700)), "fade")
end)

test("the first open of a field terminal is the long version, about 8 s (skippable, and only once)", function()
    local run = Seq.new(true, false)
    eq(#run.lines, 7, "three more self-tests than an ordinary open")
    local keys = {}
    for i, line in ipairs(run.lines) do keys[i] = line.key end
    eq(keys[2], "IGUI_OA_Boot_Storage"); eq(keys[3], "IGUI_OA_Boot_Clock"); eq(keys[5], "IGUI_OA_Boot_Server")
    eq(keys[7], "IGUI_OA_Boot_Welcome")
    truthy(run.fadeAt >= 7900 and run.fadeAt <= 8500, "fade-in starts at " .. run.fadeAt)
    eq(select(2, phaseAt(run, 499)), 0)
    eq(select(2, phaseAt(run, 500)), 1)
    eq(select(2, phaseAt(run, 6549)), 6)
    eq(select(2, phaseAt(run, 6550)), 7, "the welcome at 6.55 s")
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
