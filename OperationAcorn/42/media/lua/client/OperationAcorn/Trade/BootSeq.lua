-- The terminal window's boot sequence (DESIGN-terminal 12): the timing and the state of it, with no drawing and no
-- game calls (Trade/TerminalBoot draws it, Trade/TerminalWindow runs it). Every open the window body is black and
-- console lines print one at a time; then the content collapses into a bright line that shrinks to a dot (the switch-off
-- of a tube), and the tabs fade in from black. The first open of a field terminal is the long version, with a few more
-- self-test lines; the crude terminal reads rougher (an extra line, garbled letters that settle, a flicker). A terminal
-- opened again within a minute of closing it only fades in. A click or a key skips the console. Nothing is saved.
--
-- It is all arithmetic on the time since the run began, which the draw works out from the clock each frame while the
-- sequence lasts: no timer, nothing after it has ended. Times are in ms, taken by subtracting timestamps only
-- (Kahlua's % is wrong at their size; the % below is on small whole numbers).
require "OperationAcorn/Core"
local OA = OperationAcorn
OA.Trade = OA.Trade or {}
local Seq = {}
OA.Trade.BootSeq = Seq

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

-- A terminal opened again within this long of its window closing skips the console (real time).
Seq.REOPEN_MS = 60000

-- The console: a black beat, a line every `step`, and `hold` after the last line before the switch-off. The long
-- one is the first open of a field terminal.
Seq.SHORT = { black = 120, step = 180, hold = 260 }
Seq.LONG = { black = 200, step = 220, hold = 450 }
-- The switch-off and the fade-in. The tabs are usable as soon as the fade starts.
Seq.COLLAPSE_MS, Seq.FADE_MS = 150, 250
-- The share of the switch-off the content takes to become the line (the rest is the line shrinking to a dot).
Seq.SPLIT = 0.6

-- Every line the console can print: the key of its words, the key of what it ends with (nil: none), and whether it
-- takes the collection point's number or is the bright last line.
local LINES = {
    check = { key = "IGUI_OA_Boot_Check", status = "IGUI_OA_Boot_Normal" },
    storage = { key = "IGUI_OA_Boot_Storage", status = "IGUI_OA_Boot_Normal" },
    clock = { key = "IGUI_OA_Boot_Clock", status = "IGUI_OA_Boot_Done" },
    weak = { key = "IGUI_OA_Boot_Weak", status = "IGUI_OA_Boot_Done" },
    link = { key = "IGUI_OA_Boot_Link", status = "IGUI_OA_Boot_Done" },
    server = { key = "IGUI_OA_Boot_Server", status = "IGUI_OA_Boot_Done" },
    point = { key = "IGUI_OA_Boot_Point", status = "IGUI_OA_Boot_Done", number = true },
    welcome = { key = "IGUI_OA_Boot_Welcome", number = true, bright = true },
}

-- The lines of a boot, in order: the first open of a field terminal adds the self-tests, the crude terminal a weak
-- signal that needed a retry.
function Seq.lines(first, crude)
    local out = {}
    local function add(id) out[#out + 1] = LINES[id] end
    add("check")
    if first then
        add("storage")
        add("clock")
    end
    if crude then add("weak") end
    add("link")
    if first then add("server") end
    add("point")
    add("welcome")
    return out
end

-- A run: `first` the long version, `crude` the rough one, `quick` only the fade-in (a terminal opened again within a
-- minute). It starts counting at the first frame that asks (Seq.state), not when it was made.
function Seq.new(first, crude, quick)
    local run = { first = first and true or false, crude = crude and true or false, quick = quick and true or false }
    if quick then
        run.lines, run.black, run.step, run.consoleEnd, run.collapse = {}, 0, 0, 0, 0
    else
        local t = first and Seq.LONG or Seq.SHORT
        run.lines = Seq.lines(first, crude)
        run.black, run.step = t.black, t.step
        run.consoleEnd = t.black + (#run.lines - 1) * t.step + t.hold
        run.collapse = Seq.COLLAPSE_MS
    end
    run.fadeAt = run.consoleEnd + run.collapse
    run.endAt = run.fadeAt + Seq.FADE_MS
    return run
end

-- When line i appears (ms after the start).
function Seq.appearAt(run, i)
    return run.black + (i - 1) * run.step
end

-- The phase `now` is in: "console" (and how many lines are printed), "collapse", "fade" (usable) or "done"; how far
-- through the phase it is (0 to 1, for the last three), and the ms since the start. A clock gone back counts as the
-- start.
function Seq.state(run, now)
    if not run.start then run.start = now end
    local e = now - run.start
    if e < 0 then e = 0 end
    local n = #run.lines
    if e < run.consoleEnd then
        local shown = 0
        if e >= run.black then shown = min(n, floor((e - run.black) / run.step) + 1) end
        return "console", shown, 0, e
    end
    if e < run.fadeAt then return "collapse", n, (e - run.consoleEnd) / run.collapse, e end
    if e < run.endAt then return "fade", n, (e - run.fadeAt) / Seq.FADE_MS, e end
    return "done", n, 1, e
end

-- A click or a key: the fade-in starts now (a run that is already fading or done is left alone).
function Seq.skip(run, now)
    local phase = Seq.state(run, now)
    if phase == "console" or phase == "collapse" then run.start = now - run.fadeAt end
end

-- Whether a terminal closed at `closedAt` (nil: never) and opened at `now` is a reopening: within the minute, and the
-- clock has not gone back.
function Seq.reopened(closedAt, now)
    if not closedAt then return false end
    local since = now - closedAt
    return since >= 0 and since <= Seq.REOPEN_MS
end

-- The switch-off at progress t (0 to 1) of the collapse: the height the content has left (1 to 0), the line's width
-- (1 to 0: the dot) and its brightness. The content falls to the line in the first SPLIT of it, quickly at the end;
-- the line then shrinks to the dot and goes out.
function Seq.switchOff(t)
    local a = min(1, t / Seq.SPLIT)
    local u = max(0, (t - Seq.SPLIT) / (1 - Seq.SPLIT))
    local k = (1 - a) * (1 - a)
    return k, 1 - u * u, min(1, a * 3) * (1 - u * u * u)
end

-- The crude terminal's garbling ---------------------------------------------------------------------------------

-- How long a line takes to settle after it appears, and the most letters garbled at the start.
Seq.SETTLE_MS, Seq.GARBLE_MAX, Seq.GARBLE_STEP_MS = 300, 3, 60
local GLYPHS = "#%&*+=?/<>"

-- A text split into its characters (the game's Lua strings are Java strings: a Korean letter is one character).
local function chars(text)
    local out = {}
    for i = 1, #text do out[i] = string.sub(text, i, i) end
    return out
end

-- A line's text `age` ms after it appeared, as the crude terminal prints it: a few characters wrong, changing every
-- GARBLE_STEP_MS and fewer as the line settles, then the text itself. The same line at the same age is always the same
-- (no random state).
function Seq.garble(text, line, age)
    if age < 0 or age >= Seq.SETTLE_MS then return text end
    local parts = chars(text)
    local count = #parts
    local step = floor(age / Seq.GARBLE_STEP_MS)
    local wrong = max(1, ceil(Seq.GARBLE_MAX * (1 - age / Seq.SETTLE_MS)))
    for j = 1, wrong do
        local at = (line * 7 + step * 13 + j * 5 + line * j) % count + 1
        if parts[at] ~= " " then
            local g = (line * 3 + step * 11 + j * 7) % #GLYPHS + 1
            parts[at] = string.sub(GLYPHS, g, g)
        end
    end
    return table.concat(parts)
end

-- The crude screen's flicker: how bright the console is at `elapsed` ms (1 mostly, a dip now and then, the same
-- every time).
function Seq.flicker(elapsed)
    local r = (floor(elapsed / 45) * 7 + 3) % 11
    if r == 0 then return 0.6 end
    if r == 1 then return 0.8 end
    return 1
end

return Seq
