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

test("an ordinary open: the screen comes on, a black beat, each line with its cursor then its status, a beat, the welcome, the switch-off, the fade-in", function()
    local run = Seq.new(false, false)
    eq(Seq.POWER_MS, 1000, "the screen comes on in a second")
    eq(#run.lines, 4, "check, link, collection point, welcome")
    eq(run.lines[1].key, "IGUI_OA_Boot_Check")
    eq(run.lines[4].key, "IGUI_OA_Boot_Welcome")
    eq(run.lines[4].bright, true, "the last line is the bright one")
    local phase, shown = phaseAt(run, 0)
    eq(phase, "console"); eq(shown, 0, "the screen coming on first")
    eq(select(2, phaseAt(run, 1499)), 0, "then a black beat")
    eq(select(2, phaseAt(run, 1500)), 1)
    eq(Seq.statusAt(run, 1), 2400, "the cursor blinks 0.9 s before the status")
    eq(select(2, phaseAt(run, 3499)), 1)
    eq(select(2, phaseAt(run, 3500)), 2, "the status is seen 1.1 s before the next line")
    eq(Seq.appearAt(run, 3), 5500); eq(Seq.statusAt(run, 3), 6400)
    eq(select(2, phaseAt(run, 7199)), 3, "a beat before the welcome")
    eq(select(2, phaseAt(run, 7200)), 4)
    eq(Seq.statusAt(run, 4), 7200, "the welcome has no cursor")
    eq(phaseAt(run, 10199), "console", "the welcome is held 3 s")
    eq(run.consoleEnd, 10200)
    phase, shown = phaseAt(run, 10200)
    eq(phase, "collapse"); eq(shown, 4, "all the lines are still there as the switch-off starts")
    eq(run.fadeAt, 10480)
    local _, _, t = phaseAt(run, 10340)
    near(t, 0.5, 1e-9, "halfway through the switch-off")
    phase, _, t = phaseAt(run, 10480)
    eq(phase, "fade"); eq(t, 0)
    near(select(3, phaseAt(run, 10655)), 0.5, 1e-9)
    eq(phaseAt(run, 10829), "fade")
    eq(phaseAt(run, 10830), "done", "the fade-in lasts 0.35 s")
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
    eq(select(2, Seq.state(run, 5000 + 5500)), 3)
end)

test("a locked run (the terminal's first open) is not skipped", function()
    local run = Seq.new(false, false)
    run.locked = true
    Seq.state(run, 1000)
    Seq.skip(run, 1200)
    eq((Seq.state(run, 1200)), "console", "the click changes nothing")
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
    eq((Seq.state(run, 10300)), "collapse")
    Seq.skip(run, 10300)
    eq((Seq.state(run, 10300)), "fade")
    -- before the first frame
    run = Seq.new(false, false)
    Seq.skip(run, 700)
    eq((Seq.state(run, 700)), "fade")
end)

test("the first open of a field terminal is the long version, about 16.5 s (skippable, and only once)", function()
    local run = Seq.new(true, false)
    eq(#run.lines, 7, "three more self-tests than an ordinary open")
    local keys = {}
    for i, line in ipairs(run.lines) do keys[i] = line.key end
    eq(keys[2], "IGUI_OA_Boot_Storage"); eq(keys[3], "IGUI_OA_Boot_Clock"); eq(keys[5], "IGUI_OA_Boot_Server")
    eq(keys[7], "IGUI_OA_Boot_Welcome")
    truthy(run.fadeAt >= 16000 and run.fadeAt <= 17000, "fade-in starts at " .. run.fadeAt)
    eq(select(2, phaseAt(run, 1599)), 0)
    eq(select(2, phaseAt(run, 1600)), 1)
    eq(select(2, phaseAt(run, 13299)), 6)
    eq(select(2, phaseAt(run, 13300)), 7, "the welcome at 13.3 s")
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

test("what the console shows moves every frame: the screen coming on, the static behind the lines, the switch-off", function()
    for _, crude in ipairs({ false, true }) do
        local run = Seq.new(false, crude)
        run.start = 0
        for _, at in ipairs({ 0, 300, 1234, run.consoleEnd + 10 }) do
            local phase, shown, _, e = Seq.state(run, at)
            eq(Seq.look(run, phase, shown, e), at)
        end
    end
end)

test("the screen comes on: dark, the raster opening from the middle with its static loud, settling, then nothing", function()
    local open, edge, warm, loud, roll = Seq.powerOn(0)
    eq(open, 0, "dark at the switch"); eq(edge, 0); eq(warm, 0); eq(roll, nil)
    open, edge, warm, loud = Seq.powerOn(Seq.CLICK_MS + Seq.OPEN_MS / 2)
    truthy(open > 0.5 and open < 1, "opening")
    truthy(edge > 0, "its edges lit"); eq(loud, Seq.LOUD, "the static loud")
    truthy(warm < 0.2, "a faint warmth, not a flash")
    local at = Seq.CLICK_MS + Seq.OPEN_MS
    open, edge, warm, loud, roll = Seq.powerOn(at)
    eq(open, 1); eq(roll, 0, "the band starts rolling once open")
    open, edge, warm, loud, roll = Seq.powerOn(Seq.POWER_MS - 1)
    truthy(edge < 0.01 and warm < 0.01, "settled"); truthy(loud < 1.01, "the static at its own level")
    truthy(roll > 0.99, "the band rolled down")
    eq(Seq.powerOn(Seq.POWER_MS), nil, "on")
    local last = 0
    for e = 0, Seq.POWER_MS - 1, 10 do
        local o = Seq.powerOn(e)
        truthy(o >= last, "never closes again")
        last = o
    end
    truthy(Seq.POWER_MS < Seq.appearAt(Seq.new(false, false), 1), "the first line comes after it")
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
    truthy(bursts >= 2 and bursts <= 4, "now and then over a crude boot (two in its 13 s): " .. bursts)
    truthy(still > 1000, "still most of the time")
    truthy(maxX <= Seq.SHAKE_UNITS and maxY <= Seq.SHAKE_UNITS, "a few units")
    truthy(maxX >= 2, "and visible")
end)

test("the crude terminal's weak signal: a spell of half a second to a second now and then, fading in and out", function()
    local spells, inSpell, longest, len, maxFade = 0, false, 0, 0, 0
    for e = 0, 140000, 10 do
        local fade, step = Seq.weakSignal(e)
        local x2, s2 = Seq.weakSignal(e)
        eq(x2, fade); eq(s2, step)
        if fade then
            truthy(fade >= 0 and fade <= Seq.WEAK_FADE)
            maxFade = math.max(maxFade, fade)
            if not inSpell then spells, len = spells + 1, 0 end
            len = len + 10
            longest = math.max(longest, len)
        end
        inSpell = fade ~= nil
    end
    eq(spells, 10, "one a 14 s stretch")
    truthy(longest >= 500 and longest <= 1110, "half a second to a second: " .. longest)
    truthy(maxFade > Seq.WEAK_FADE * 0.7, "it does fade")
    eq(Seq.weakSignal(0), nil, "not at once")
end)
