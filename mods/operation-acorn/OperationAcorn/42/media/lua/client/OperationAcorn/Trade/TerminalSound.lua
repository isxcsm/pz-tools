-- The terminal window's sounds (SOUND-SYSTEM.md S8), each terminal its own (cues oa.term.<tier>.<name>: the field
-- terminal a solid issued set, the crude one salvaged parts on a weak signal). Only the picture's big beats sound
-- (Trade/BootSeq): the switch as the screen comes on, each check line's result, the welcome, the switch-off (also when the
-- window goes); the crude console's jolts. A bed loops under the boot, its volume following the static's loudness (loud
-- as the screen opens, its own level through the console, falling with the switch-off), and the crude terminal's weak
-- signal spells (Seq.weakSignal) loop their noise at the spell's fade. The loops are silent while the game is paused
-- (SOUND-SYSTEM.md 4: a loop stops with the pause; the picture goes on). A cue with no sound is silent.
require "PZUIKit/Sound"
require "OperationAcorn/Trade/BootSeq"
local OA = OperationAcorn
local Seq = OA.Trade.BootSeq
local Sound = PZUIKit.Sound

local TS = {}
OA.Trade.TerminalSound = TS

-- A step of the boot's clock longer than this (ms) is a jump (a skip), not a frame: the beats it jumps over do not sound.
TS.JUMP_MS = 250

local function cue(window, name)
    return "oa.term." .. tostring(window.tier) .. "." .. name
end

local function state(window)
    local s = window.termSound
    if not s then
        s = { lastE = -1 }
        window.termSound = s
    end
    return s
end

-- A loop's volume now: none while the game is paused.
local function loopVolume(v)
    return Sound.paused() and 0 or v
end

local function stopBed(s)
    if s.bed then Sound.stopHeld(s.bed) end
    s.bed = nil
end

-- The boot begins: the switch, and the bed under it (silent until the screen opens).
function TS.bootStart(window)
    local s = state(window)
    Sound.ui(cue(window, "power"))
    s.bed = Sound.uiHeld(cue(window, "hum"), 0)
end

-- The bed's volume at `e` ms of the boot in `phase` (Seq.state's, with `t` its progress): the static's loudness over its
-- loudest (Seq.powerOn), 1 / LOUD through the console, falling with the switch-off.
function TS.bedVolume(phase, t, e)
    if phase == "fade" or phase == "done" then return 0 end
    local open, _, _, loud = Seq.powerOn(e)
    local v = (open and loud or 1) / Seq.LOUD
    if phase == "collapse" then v = v * Seq.switchOff(t) end
    return v
end

-- A frame of the boot (OATerminalWindow:bootTick): the beats passed since the last frame, the bed's volume; the bed
-- stops once the console is over.
function TS.bootFrame(window, run, phase, t, e)
    local s = state(window)
    if s.closed then return end
    local from = s.lastE
    s.lastE = e
    local jump = from >= 0 and e - from > TS.JUMP_MS
    if not jump and from < run.consoleEnd then
        for i, line in ipairs(run.lines) do
            if line.status and run.statusAt[i] > from and run.statusAt[i] <= e then Sound.ui(cue(window, "line")) end
            if line.bright and run.at[i] > from and run.at[i] <= e then Sound.ui(cue(window, "ready")) end
        end
        if run.crude and e < run.consoleEnd then
            local at = Seq.shakeStart(math.floor(e / Seq.SHAKE_EVERY_MS))
            if at and at > from and at <= e and at >= Seq.POWER_MS then Sound.ui(cue(window, "jolt")) end
        end
    end
    if run.consoleEnd > from and run.consoleEnd <= e then Sound.ui(cue(window, "off")) end
    if phase == "console" or phase == "collapse" then
        if s.bed then Sound.setHeld(s.bed, loopVolume(TS.bedVolume(phase, t, e))) end
    else
        stopBed(s)
    end
end

-- A frame of the crude terminal's weak signal (Seq.weakSignal's fade, nil between spells): the spell's noise at its
-- fade, started as a spell begins and stopped as it ends.
function TS.weakFrame(window, fade)
    local s = state(window)
    if s.closed then return end
    if fade then
        local v = loopVolume(fade / Seq.WEAK_FADE)
        if s.spell then
            Sound.setHeld(s.spell, v)
        elseif not s.spellTried then
            -- (once a spell: a cue with no sound is not asked again every frame)
            s.spellTried = true
            s.spell = Sound.uiHeld(cue(window, "spell"), v)
        end
    else
        s.spellTried = nil
        if s.spell then Sound.stopHeld(s.spell) end
        s.spell = nil
    end
end

-- The window goes: what loops stops, and the screen switches off (once: the window draws on while it fades out).
function TS.close(window)
    local s = state(window)
    if s.closed then return end
    s.closed = true
    stopBed(s)
    if s.spell then Sound.stopHeld(s.spell) end
    s.spell = nil
    Sound.ui(cue(window, "off"))
end

return TS
