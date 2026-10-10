-- How the research tab moves, besides the approval stamp (Plan): a node's answer to a click (a pop with a ring for a
-- rank raised, a shrink for one taken back, a shake for a click refused; a floating +1 or -1, the pip and the tree's
-- points flashing), the light on the node under the mouse, the light that runs down a met prerequisite's line, a
-- padlock coming off, and the trees coming up when the tab opens or switches to the board. Only the timing and the
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
-- design units out from its frame (RIPPLE_WIDTH thick at first); a rank taken back shrinks it by SHRINK_SCALE; a
-- refused click shakes it sideways by up to SHAKE_DU. Either way a "+1" or "-1" floats FLOAT_RISE up from the node
-- and fades, the pip that changed flashes (growing to 1 + PIP_GROW times its size), and the tree's points left hop
-- BUMP_HOP up and light. Long enough for the eye to catch which node did what, short enough not to hold the next click.
Motion.POP_MS, Motion.POP_SCALE = 260, 0.20
Motion.RIPPLE_MS, Motion.RIPPLE_GROW, Motion.RIPPLE_WIDTH = 450, 22, 2
Motion.SHRINK_MS, Motion.SHRINK_SCALE = 170, 0.10
Motion.SHAKE_MS, Motion.SHAKE_DU = 220, 3
Motion.FLOAT_MS, Motion.FLOAT_RISE, Motion.FLOAT_HOLD = 600, 14, 0.35
Motion.PIP_MS, Motion.PIP_GROW = 420, 1.4
Motion.BUMP_MS, Motion.BUMP_HOP = 380, 3

-- How long each answer moves (read from the numbers above each time, so that they can be stretched in game to look
-- at one slowly).
function Motion.fxMs(kind)
    if kind == "pop" then return max(Motion.POP_MS, Motion.RIPPLE_MS, Motion.FLOAT_MS, Motion.PIP_MS) end
    if kind == "shrink" then return max(Motion.SHRINK_MS, Motion.FLOAT_MS, Motion.PIP_MS) end
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

-- The ring of a pop `age` ms in: how far past the node's frame, how strong, and how thick (design units); nil once it
-- is gone. Bright and thick at first, thinning and fading as it goes out.
function Motion.ripple(age)
    if age < 0 or age >= Motion.RIPPLE_MS then return nil end
    local u = age / Motion.RIPPLE_MS
    local fade = 1 - u
    return Motion.RIPPLE_GROW * Motion.easeOut(u), fade * math.sqrt(fade), Motion.RIPPLE_WIDTH * (1 - 0.5 * u)
end

-- A refused node's sideways offset `age` ms in (design units): two and a half swings, dying away; 0 outside.
function Motion.shake(age)
    if age < 0 or age >= Motion.SHAKE_MS then return 0 end
    local u = age / Motion.SHAKE_MS
    return Motion.SHAKE_DU * (1 - u) * sin(5 * pi * u)
end

-- The "+1" or "-1" of a click `age` ms in: how far it has risen (design units, easing out) and how strong it is (full
-- for FLOAT_HOLD of its time, then fading); nil once it is gone.
function Motion.float(age)
    if age < 0 or age >= Motion.FLOAT_MS then return nil end
    local u = age / Motion.FLOAT_MS
    local a = 1
    if u > Motion.FLOAT_HOLD then
        local v = (u - Motion.FLOAT_HOLD) / (1 - Motion.FLOAT_HOLD)
        a = 1 - v * v
    end
    return Motion.FLOAT_RISE * Motion.easeOut(u), a
end

-- The flash of a pip that changed `age` ms in: its size as a share of the pip's (growing) and its strength (dying
-- out); nil once it is gone.
function Motion.pipFlash(age)
    if age < 0 or age >= Motion.PIP_MS then return nil end
    local u = age / Motion.PIP_MS
    local fade = 1 - u
    return 1 + Motion.PIP_GROW * Motion.easeOut(u), fade * fade
end

-- The points left of a tree `age` ms after they changed: how far the number hops up (design units: up and back) and
-- how lit it and the bar's changed segment are; nil once it is over.
function Motion.bump(age)
    if age < 0 or age >= Motion.BUMP_MS then return nil end
    local u = age / Motion.BUMP_MS
    local fade = 1 - u
    return Motion.BUMP_HOP * sin(pi * Motion.easeOut(u)), fade * fade
end

-- ---- the light under the mouse ------------------------------------------------------------------------------------
-- A node under the mouse (or the gamepad's cursor) lights as it comes up (Trade/UI's place lights: their timing): it
-- grows by HOVER_GROW of its size, brightens by HOVER_LIGHT and takes a thin light frame.
Motion.HOVER_GROW, Motion.HOVER_LIGHT = 0.03, 0.14

-- ---- a padlock coming off -----------------------------------------------------------------------------------------
-- Milliseconds: the whole, the padlock's (and the grey's) fade, the frame's flash rising to its top; and, after a
-- click that opened nodes, the wait behind the clicked node's pop (the eye goes from the click to what it opened).
-- The flash sends a ring out to UNLOCK_RING design units.
Motion.UNLOCK_MS = 600
Motion.UNLOCK_RING = 10
Motion.UNLOCK_LOCK_MS = 280
Motion.UNLOCK_PEAK_MS = 70
Motion.UNLOCK_DELAY_MS = 120

-- A node opening `age` ms in: how much of its padlock and grey still shows (1 before its start: the node still looks
-- locked meanwhile), how strong the flash of its frame is, and how far its ring has gone; nil once it is over.
function Motion.unlock(age)
    if age >= Motion.UNLOCK_MS then return nil end
    if age < 0 then return 1, 0, 0 end
    local u = min(1, age / Motion.UNLOCK_LOCK_MS)
    local lock = 1 - u * u * (3 - 2 * u)
    local flash
    if age < Motion.UNLOCK_PEAK_MS then
        flash = age / Motion.UNLOCK_PEAK_MS
    else
        local v = 1 - (age - Motion.UNLOCK_PEAK_MS) / (Motion.UNLOCK_MS - Motion.UNLOCK_PEAK_MS)
        flash = v * v
    end
    return lock, flash, Motion.UNLOCK_RING * Motion.easeOut(age / Motion.UNLOCK_MS)
end

-- ---- the light on the lines ---------------------------------------------------------------------------------------
-- A met prerequisite's line carries a light from the prerequisite down to its node, one pass every BEAD_PERIOD_MS, at
-- BEAD_SPEED design units a second (a short line's pass still lasts BEAD_MIN_MS, a long one's no more than
-- BEAD_MAX_SHARE of the period); BEAD_LEN design units long with its tail (never more than half the line), the head
-- BEAD_HEAD of it, at most BEAD_ALPHA strong; under it a glow BEAD_GLOW_WIDTH times the line's width, BEAD_GLOW as
-- strong as the light.
Motion.BEAD_PERIOD_MS = 2600
Motion.BEAD_SPEED = 60
Motion.BEAD_MIN_MS = 450
Motion.BEAD_MAX_SHARE = 0.8
Motion.BEAD_LEN, Motion.BEAD_HEAD = 18, 6
Motion.BEAD_ALPHA = 0.85
Motion.BEAD_GLOW, Motion.BEAD_GLOW_WIDTH = 0.28, 3
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
    local a = Motion.BEAD_ALPHA * min(1, u / 0.15, (1 - u) / 0.25)
    return len * u, a, min(Motion.BEAD_LEN, len / 2)
end

-- ---- the opening --------------------------------------------------------------------------------------------------
-- When the tab comes on the screen its columns come up from OPEN_RISE design units lower while fading in, OPEN_COL_MS
-- apart, over OPEN_FADE_MS each; inside a column the nodes pop in row by row (OPEN_ROW_MS apart, from OPEN_NODE_WAIT_MS
-- after the column, from OPEN_NODE_FROM of their size to their size and from nothing to full over OPEN_NODE_MS); a
-- line draws itself down from its prerequisite once its node is OPEN_LINE_LAG into its pop, over OPEN_LINE_MS; the
-- strip's bar fills from nothing over OPEN_BAR_MS, OPEN_BAR_WAIT_MS after its column. A switch between the trees and
-- the board plays the same at SWITCH_PACE of the time. Clicks work all along: only the drawing waits.
Motion.OPEN_COL_MS = 90
Motion.OPEN_RISE = 8
Motion.OPEN_FADE_MS = 260
Motion.OPEN_NODE_WAIT_MS = 80
Motion.OPEN_ROW_MS = 45
Motion.OPEN_NODE_MS = 220
Motion.OPEN_NODE_FROM = 0.7
Motion.OPEN_LINE_LAG = 0.6
Motion.OPEN_LINE_MS = 200
Motion.OPEN_BAR_WAIT_MS = 60
Motion.OPEN_BAR_MS = 420
Motion.SWITCH_PACE = 0.5

local function share(age, start, ms)
    return Motion.easeOut((age - start) / ms)
end

local function nodeStart(c, r)
    return (c - 1) * Motion.OPEN_COL_MS + Motion.OPEN_NODE_WAIT_MS + (r - 1) * Motion.OPEN_ROW_MS
end

-- When the opening of `cols` columns of `rows` rows is over (ms).
function Motion.openEnd(cols, rows)
    local col = (cols - 1) * Motion.OPEN_COL_MS
    local lastNode = nodeStart(cols, rows)
    return max(col + Motion.OPEN_FADE_MS, lastNode + Motion.OPEN_NODE_MS,
        lastNode + Motion.OPEN_LINE_LAG * Motion.OPEN_NODE_MS + Motion.OPEN_LINE_MS,
        col + Motion.OPEN_BAR_WAIT_MS + Motion.OPEN_BAR_MS)
end

-- Column c (from 1) `age` ms into the opening: how far below its place it still is (design units) and how much of
-- it shows (0 to 1).
function Motion.openColumn(age, c)
    local e = share(age, (c - 1) * Motion.OPEN_COL_MS, Motion.OPEN_FADE_MS)
    return Motion.OPEN_RISE * (1 - e), e
end

-- A node of column c, row r, `age` ms into the opening: its scale and how much of it shows.
function Motion.openNode(age, c, r)
    local e = share(age, nodeStart(c, r), Motion.OPEN_NODE_MS)
    return Motion.OPEN_NODE_FROM + (1 - Motion.OPEN_NODE_FROM) * e, e
end

-- How much of a line of column c down to a node of row r has drawn itself `age` ms into the opening (0 to 1).
function Motion.openLine(age, c, r)
    return share(age, nodeStart(c, r) + Motion.OPEN_LINE_LAG * Motion.OPEN_NODE_MS, Motion.OPEN_LINE_MS)
end

-- How much of column c's bar has filled `age` ms into the opening (0 to 1).
function Motion.openBar(age, c)
    return share(age, (c - 1) * Motion.OPEN_COL_MS + Motion.OPEN_BAR_WAIT_MS, Motion.OPEN_BAR_MS)
end

return Motion
