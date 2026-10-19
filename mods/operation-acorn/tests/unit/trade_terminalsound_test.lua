-- The terminal window's sounds (client Trade/TerminalSound, SOUND-SYSTEM.md S8): each terminal's own cues; the boot's
-- beats each once at their moment (the switch, each line's result, the welcome, the switch-off; the crude console's
-- jolts), a skip sounding only the switch-off; the bed under the boot following the static's loudness and stopped with
-- the console; the crude terminal's weak signal spells; the switch-off once as the window goes.
require "OperationAcorn/Core"
require "PZUIKit/Sound"
require "OperationAcorn/Trade/BootSeq"
require "OperationAcorn/Trade/TerminalSound"
local OA = OperationAcorn
local Seq, TS = OA.Trade.BootSeq, OA.Trade.TerminalSound
local Sound = PZUIKit.Sound

local heard, held
local function stub()
    heard, held = {}, {}
    Sound.ui = function(cue) heard[#heard + 1] = cue end
    Sound.uiHeld = function(cue, v)
        local h = { cue = cue, volumes = { v }, stopped = false }
        held[#held + 1] = h
        return h
    end
    Sound.setHeld = function(h, v) h.volumes[#h.volumes + 1] = v end
    Sound.stopHeld = function(h) h.stopped = true end
    Sound.paused = function() return false end
end

local function count(cue)
    local n = 0
    for _, c in ipairs(heard) do if c == cue then n = n + 1 end end
    return n
end

-- A boot played frame by frame (every `step` ms) up to `to` ms; returns the window.
local function play(tier, first, to, step, from)
    local window = { tier = tier }
    local run = Seq.new(first, tier == "crude")
    TS.bootStart(window)
    run.start = 0
    for e = from or 0, to, step or 16 do
        local phase, _, t = Seq.state(run, e)
        TS.bootFrame(window, run, phase, t, e)
    end
    return window, run
end

test("each terminal sounds its own cues", function()
    stub()
    play("field", false, 20000)
    eq(heard[1], "oa.term.field.power")
    eq(held[1].cue, "oa.term.field.hum")
    stub()
    play("crude", false, 20000)
    eq(heard[1], "oa.term.crude.power")
    eq(held[1].cue, "oa.term.crude.hum")
end)

test("the boot's beats, each once: the switch, a line's result, the welcome, the switch-off", function()
    stub()
    local _, run = play("field", true, 30000)
    local results = 0
    for _, line in ipairs(run.lines) do if line.status then results = results + 1 end end
    eq(count("oa.term.field.power"), 1)
    eq(count("oa.term.field.line"), results, "each check line's result")
    eq(count("oa.term.field.ready"), 1, "the welcome")
    eq(count("oa.term.field.off"), 1, "the switch-off")
    eq(count("oa.term.field.jolt"), 0, "the field terminal does not jolt")
    eq(heard[#heard], "oa.term.field.off", "the switch-off is the last")
end)

test("the crude console's jolts: one at each burst of its shake while the console prints", function()
    stub()
    local _, run = play("crude", false, 30000)
    local bursts = 0
    for slot = 0, math.floor(run.consoleEnd / Seq.SHAKE_EVERY_MS) do
        local at = Seq.shakeStart(slot)
        if at and at >= Seq.POWER_MS and at < run.consoleEnd then bursts = bursts + 1 end
    end
    truthy(bursts > 0, "a crude boot shakes")
    eq(count("oa.term.crude.jolt"), bursts)
    -- each jolt at a burst: the shake is moving right after it
    for slot = 0, 10 do
        local at = Seq.shakeStart(slot)
        if at then
            local dx, dy = Seq.shake(at)
            truthy(dx ~= 0 or dy ~= 0 or Seq.shake(at + Seq.SHAKE_STEP_MS) ~= 0, "the picture moves at the burst " .. slot)
        end
    end
end)

test("the bed follows the static: loud as the screen opens, its level through the console, falling, stopped", function()
    stub()
    local window, run = play("field", false, 400)
    local bed = held[1]
    eq(bed.volumes[1], 0, "silent before the switch")
    near(bed.volumes[#bed.volumes], 1, 1e-9, "the static at its loudest as the screen opens")
    eq(TS.bedVolume("console", 0, 50), 0, "dark for the switch's beat")
    near(TS.bedVolume("console", 0, 3000), 1 / Seq.LOUD, 1e-9, "its own level through the console")
    near(TS.bedVolume("collapse", 0.3, 9000), Seq.switchOff(0.3) / Seq.LOUD, 1e-9, "falling with the switch-off")
    for e = 416, run.endAt + 100, 16 do
        local phase, _, t = Seq.state(run, e)
        TS.bootFrame(window, run, phase, t, e)
    end
    eq(bed.stopped, true, "stopped once the console is over")
end)

test("a skip sounds the switch-off alone, not the beats it jumps over", function()
    stub()
    local window = { tier = "field" }
    local run = Seq.new(false, false)
    TS.bootStart(window)
    TS.bootFrame(window, run, "console", 0, 1600)
    -- the click: the run jumps to its fade
    TS.bootFrame(window, run, "fade", 0, run.fadeAt)
    eq(count("oa.term.field.line"), 0)
    eq(count("oa.term.field.ready"), 0)
    eq(count("oa.term.field.off"), 1)
    eq(held[1].stopped, true)
end)

test("the crude terminal's weak signal: a spell's noise at its fade, from its start to its end", function()
    stub()
    local window = { tier = "crude" }
    TS.weakFrame(window, nil)
    eq(#held, 0, "nothing between spells")
    TS.weakFrame(window, Seq.WEAK_FADE * 0.5)
    eq(held[1].cue, "oa.term.crude.spell")
    near(held[1].volumes[1], 0.5, 1e-9)
    TS.weakFrame(window, Seq.WEAK_FADE)
    near(held[1].volumes[2], 1, 1e-9)
    TS.weakFrame(window, nil)
    eq(held[1].stopped, true, "stopped as the spell ends")
    TS.weakFrame(window, 0.1)
    eq(#held, 2, "the next spell its own")
end)

test("the window goes: what loops stops, the switch-off once", function()
    stub()
    local window = { tier = "crude" }
    TS.bootStart(window)
    TS.weakFrame(window, 0.3)
    TS.close(window)
    TS.close(window)
    eq(count("oa.term.crude.off"), 1, "once, though the window is told again as it fades")
    eq(held[1].stopped, true); eq(held[2].stopped, true)
    TS.weakFrame(window, 0.3)
    TS.bootFrame(window, Seq.new(false, true), "console", 0, 5000)
    eq(#held, 2, "nothing starts after it went")
end)

test("the loops are silent while the game is paused, back after", function()
    stub()
    local window = { tier = "crude" }
    TS.weakFrame(window, Seq.WEAK_FADE)
    Sound.paused = function() return true end
    TS.weakFrame(window, Seq.WEAK_FADE)
    eq(held[1].volumes[2], 0, "paused")
    Sound.paused = function() return false end
    TS.weakFrame(window, Seq.WEAK_FADE)
    near(held[1].volumes[3], 1, 1e-9, "back")
end)
