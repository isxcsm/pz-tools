-- How the research tab moves, besides the approval stamp (Plan): a node's answer to a click (a pop with a ring for a
-- rank raised, a small shrink for one taken back, a shake for a click refused), the light that runs down a met
-- prerequisite's line, a padlock coming off, and the columns coming in when the tab opens. Only the timing and the
-- curves, in milliseconds and design units, so that the unit tests can check them; the tab draws them (Window.lua).
-- Each function takes how long ago its effect started and gives plain numbers, so that a frame makes nothing. No `%`:
-- Kahlua's misbehaves on large numbers, and a remainder is taken with floor.
require "OperationAcorn/Core"
local Motion = {}
OperationAcorn.Upgrades = OperationAcorn.Upgrades or {}
OperationAcorn.Upgrades.Motion = Motion

local floor, min, max, sin, pi = math.floor, math.min, math.max, math.sin, math.pi

-- A curve fast at first that settles at the end (u from 0 to 1; held at its ends outside).
function Motion.easeOut(u)
    if u <= 0 then return 0 end
    if u >= 1 then return 1 end
    local v = 1 - u
    return 1 - v * v * v
end

-- ---- a click's answer ---------------------------------------------------------------------------------------------
-- Milliseconds and sizes: a rank raised swells the node by POP_SCALE of its size and sends a cyan ring RIPPLE_GROW
-- design units out from its frame; a rank taken back shrinks it by SHRINK_SCALE; a refused click shakes it sideways by
-- up to SHAKE_DU. Short enough to answer the click at once, long enough for the eye to see which node did.
Motion.POP_MS, Motion.POP_SCALE = 180, 0.12
Motion.RIPPLE_MS, Motion.RIPPLE_GROW = 320, 14
Motion.SHRINK_MS, Motion.SHRINK_SCALE = 150, 0.08
Motion.SHAKE_MS, Motion.SHAKE_DU = 220, 3

-- How long each answer moves (read from the numbers above each time, so that they can be stretched in game to look
-- at one slowly).
function Motion.fxMs(kind)
    if kind == "pop" then return max(Motion.POP_MS, Motion.RIPPLE_MS) end
    if kind == "shrink" then return Motion.SHRINK_MS end
    if kind == "shake" then return Motion.SHAKE_MS end
    return 0
end

-- One swell out and back: its top comes early (the ease out of the time), so that the node jumps and then settles.
local function swell(age, ms, by)
    if age < 0 or age >= ms then return 1 end
    return 1 + by * sin(pi * Motion.easeOut(age / ms))
end

-- A node's scale `age` ms into a pop (a rank raised), and into a shrink (one taken back); 1 outside them.
function Motion.pop(age)
    return swell(age, Motion.POP_MS, Motion.POP_SCALE)
end

function Motion.shrink(age)
    return swell(age, Motion.SHRINK_MS, -Motion.SHRINK_SCALE)
end

-- The ring of a pop `age` ms in: how far past the node's frame (design units) and how strong; nil once it is gone.
function Motion.ripple(age)
    if age < 0 or age >= Motion.RIPPLE_MS then return nil end
    local u = age / Motion.RIPPLE_MS
    local fade = 1 - u
    return Motion.RIPPLE_GROW * Motion.easeOut(u), 0.85 * fade * fade
end

-- A refused node's sideways offset `age` ms in (design units): two and a half swings, dying away; 0 outside.
function Motion.shake(age)
    if age < 0 or age >= Motion.SHAKE_MS then return 0 end
    local u = age / Motion.SHAKE_MS
    return Motion.SHAKE_DU * (1 - u) * sin(5 * pi * u)
end

-- ---- a padlock coming off -----------------------------------------------------------------------------------------
-- Milliseconds: the whole, the padlock's (and the grey's) fade, the frame's flash rising to its top; and, after a
-- click that opened nodes, the wait behind the clicked node's pop (the eye goes from the click to what it opened).
Motion.UNLOCK_MS = 520
Motion.UNLOCK_LOCK_MS = 280
Motion.UNLOCK_PEAK_MS = 70
Motion.UNLOCK_DELAY_MS = 120

-- A node opening `age` ms in: how much of its padlock and grey still shows (1 before its start: the node still looks
-- locked meanwhile) and how strong the flash of its frame is; nil once it is over.
function Motion.unlock(age)
    if age >= Motion.UNLOCK_MS then return nil end
    if age < 0 then return 1, 0 end
    local u = min(1, age / Motion.UNLOCK_LOCK_MS)
    local lock = 1 - u * u * (3 - 2 * u)
    local flash
    if age < Motion.UNLOCK_PEAK_MS then
        flash = age / Motion.UNLOCK_PEAK_MS
    else
        local v = 1 - (age - Motion.UNLOCK_PEAK_MS) / (Motion.UNLOCK_MS - Motion.UNLOCK_PEAK_MS)
        flash = v * v
    end
    return lock, flash
end

-- ---- the light on the lines ---------------------------------------------------------------------------------------
-- A met prerequisite's line carries a faint light from the prerequisite down to its node, one pass every
-- BEAD_PERIOD_MS, at BEAD_SPEED design units a second (a short line's pass still lasts BEAD_MIN_MS, a long one's no
-- more than BEAD_MAX_SHARE of the period); BEAD_LEN design units long with its tail (never more than half the line),
-- the head BEAD_HEAD of it; at most BEAD_ALPHA strong.
Motion.BEAD_PERIOD_MS = 3600
Motion.BEAD_SPEED = 55
Motion.BEAD_MIN_MS = 450
Motion.BEAD_MAX_SHARE = 0.8
Motion.BEAD_LEN, Motion.BEAD_HEAD = 10, 4
Motion.BEAD_ALPHA = 0.5
-- The share of the period a line's passes are put off by, for line i: steps of the golden ratio, so that lines next
-- to each other never move together and none waits long for the next.
local GOLDEN = 0.6180339887

-- Line i's light `ms` into the tab's clock (small numbers: from when the tab was made), on a line `len` design units
-- long: the head's distance from the line's start, its strength, and the light's length; nil between passes.
function Motion.bead(ms, i, len)
    local period = Motion.BEAD_PERIOD_MS
    local travel = min(period * Motion.BEAD_MAX_SHARE, max(Motion.BEAD_MIN_MS, len * 1000 / Motion.BEAD_SPEED))
    local share = i * GOLDEN
    local at = ms + (share - floor(share)) * period
    local phase = at - floor(at / period) * period
    if phase >= travel then return nil end
    local u = phase / travel
    local a = Motion.BEAD_ALPHA * min(1, u / 0.2, (1 - u) / 0.3)
    return len * u, a, min(Motion.BEAD_LEN, len / 2)
end

-- ---- the opening --------------------------------------------------------------------------------------------------
-- When the tab comes on the screen its columns come in from the left, OPEN_COL_MS apart, each fading in over
-- OPEN_FADE_MS; inside a column the rows light from the top, OPEN_ROW_MS apart, starting OPEN_ROW_WAIT_MS after the
-- column and taking OPEN_ROW_FADE_MS each. Quick: a glance, not a wait (clicks work all along).
Motion.OPEN_COL_MS = 100
Motion.OPEN_FADE_MS = 160
Motion.OPEN_ROW_MS = 25
Motion.OPEN_ROW_WAIT_MS = 20
Motion.OPEN_ROW_FADE_MS = 80

-- When the opening of `cols` columns of `rows` rows is over (ms).
function Motion.openEnd(cols, rows)
    local column = max(Motion.OPEN_FADE_MS, Motion.OPEN_ROW_WAIT_MS + (rows - 1) * Motion.OPEN_ROW_MS
        + Motion.OPEN_ROW_FADE_MS)
    return (cols - 1) * Motion.OPEN_COL_MS + column
end

-- How much of column c (from 1) is still hidden `age` ms into the opening: 1 hidden, 0 shown.
function Motion.openColumn(age, c)
    return 1 - Motion.easeOut((age - (c - 1) * Motion.OPEN_COL_MS) / Motion.OPEN_FADE_MS)
end

-- How much of row r of column c is still dark `age` ms into the opening: 1 dark, 0 lit.
function Motion.openRow(age, c, r)
    local start = (c - 1) * Motion.OPEN_COL_MS + Motion.OPEN_ROW_WAIT_MS + (r - 1) * Motion.OPEN_ROW_MS
    return 1 - Motion.easeOut((age - start) / Motion.OPEN_ROW_FADE_MS)
end

return Motion
