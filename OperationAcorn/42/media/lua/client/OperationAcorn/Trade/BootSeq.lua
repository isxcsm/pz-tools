-- The terminal window's boot sequence (DESIGN-terminal 12): the timing and the state of it, with no drawing and no
-- game calls (Trade/TerminalBoot draws it, Trade/TerminalWindow runs it). Every open the window body is black and
-- console lines print one at a time; then the content collapses into a bright line that shrinks to a dot (the switch-off
-- of a tube), and the tabs fade in from black. Each check line prints its words, a cursor blinks after them, and then
-- what it ends with stands where the cursor was. The first open of a field terminal is the long version, with a few more
-- self-test lines; the crude terminal reads rougher (an extra line, garbled letters that settle, a flicker). It plays on
-- every open, slow enough to be read; a click or a key skips the console. Nothing is saved.
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

-- The console, paced for the eye: a black beat, then each line: its words and the cursor blinking WAIT_MS (time to read
-- them and wait; the crude terminal's weak signal WEAK_WAIT_MS), what it ends with, held GAP_MS before the next line
-- takes the eye away (time to see the result); WELCOME_MS after the last result the welcome, held `hold` before the
-- switch-off. The long one is the first open of a field terminal. The cursor is on and off BLINK_MS each (a blink, not
-- a flicker).
Seq.SHORT = { black = 500, hold = 3000 }
Seq.LONG = { black = 600, hold = 3000 }
Seq.WAIT_MS, Seq.WEAK_WAIT_MS, Seq.GAP_MS, Seq.WELCOME_MS, Seq.BLINK_MS = 900, 2400, 1100, 800, 280
-- The switch-off and the fade-in. The tabs are usable as soon as the fade starts.
Seq.COLLAPSE_MS, Seq.FADE_MS = 280, 350
-- The share of the switch-off the content takes to become the line (the rest is the line shrinking to a dot).
Seq.SPLIT = 0.6

-- Every line the console can print: the key of its words, the key of what it ends with (nil: none), and whether it
-- takes the collection point's number or is the bright last line.
local LINES = {
    check = { key = "IGUI_OA_Boot_Check", status = "IGUI_OA_Boot_Normal" },
    storage = { key = "IGUI_OA_Boot_Storage", status = "IGUI_OA_Boot_Normal" },
    clock = { key = "IGUI_OA_Boot_Clock", status = "IGUI_OA_Boot_Done" },
    weak = { key = "IGUI_OA_Boot_Weak", status = "IGUI_OA_Boot_Done", weak = true },
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

-- A run: `first` the long version, `crude` the rough one. It starts counting at the first frame that asks (Seq.state),
-- not when it was made.
function Seq.new(first, crude)
    local run = { first = first and true or false, crude = crude and true or false }
    local t = first and Seq.LONG or Seq.SHORT
    run.lines = Seq.lines(first, crude)
    -- when each line appears and when what it ends with replaces the cursor (ms after the start)
    run.at, run.statusAt = {}, {}
    local now = t.black
    for i, line in ipairs(run.lines) do
        if line.status then
            run.at[i] = now
            run.statusAt[i] = now + (line.weak and Seq.WEAK_WAIT_MS or Seq.WAIT_MS)
            now = run.statusAt[i] + Seq.GAP_MS
        else
            run.at[i] = now - Seq.GAP_MS + Seq.WELCOME_MS
            run.statusAt[i] = run.at[i]
            now = run.at[i]
        end
    end
    run.consoleEnd = run.at[#run.lines] + t.hold
    run.collapse = Seq.COLLAPSE_MS
    run.fadeAt = run.consoleEnd + run.collapse
    run.endAt = run.fadeAt + Seq.FADE_MS
    return run
end

-- When line i appears, and when what it ends with stands in place of the cursor (ms after the start).
function Seq.appearAt(run, i)
    return run.at[i]
end

function Seq.statusAt(run, i)
    return run.statusAt[i]
end

-- Whether the cursor shows `age` ms after its line appeared (it starts on).
function Seq.cursorOn(age)
    return floor(age / Seq.BLINK_MS) % 2 == 0
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
        while shown < n and Seq.appearAt(run, shown + 1) <= e do shown = shown + 1 end
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
