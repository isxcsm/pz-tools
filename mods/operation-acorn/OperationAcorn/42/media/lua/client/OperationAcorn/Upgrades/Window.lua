-- The research plan (DESIGN 8), as the 적응 (Adaptation) tab of the character info window, beside the game's skills
-- and health, drawn as the field terminal is (mockups/upgrades): an opaque body in the terminal's palette, the three
-- trees side by side, each a column with a header strip in its colour (its name, its points as a bar, a reset button)
-- over a grid of icon nodes (four columns, five rows opened by the points spent in the tree, the capstone last and a
-- little larger) with the prerequisite lines between them; in their place the 2nd board, a band across for each tree
-- (its name at the top left, its nodes in one row across its middle, each kind of them on a tray of its own). Above: the
-- two modes and
-- a chip for the shared points; below: a bar that says what approving the selection spends,
-- with the approve and clear buttons.
-- A node shows its state at a glance: grey with a padlock while it cannot be taken, a frame in its tree's colour that
-- pulses gently when it can, gold when it is full, a cyan dashed frame with "+n" for selected ranks; its ranks are pips
-- under it. A line is lit in the tree's colour when its prerequisite is met, flows in cyan dashes when only the
-- selection meets it. A click selects a rank (a right click takes it back); the selection is only a selection until
-- "research approval" sends it to the server. What a node gives now and next, and what it needs as a checklist, shows in
-- a tooltip beside it (the mouse) or beside the gamepad's cursor.
-- Sizes: the tab is a game panel in pixels (the character window's tab panel places it); its body is ours, in design
-- units and our faces (Trade/UI.lua), made again when the scale changes, so the tab grows with the screen as the
-- terminal does. Icons are drawn at whole pixel sizes from their 128 px pictures, the small signs (pips, checks, the
-- reset arrow) from textures made at each pixel size (tools/ui_glyphs.py), so nothing is blurred by scaling.
-- When the server's answer to an applied selection comes back while the tab is open, the body takes it: a scan runs
-- over the applied nodes (each pops and bursts in its tree's colour with a short sound, its selected ranks settling
-- into solid pips), a light runs from each up its lines to its tree's header, which flashes as it arrives, and then a
-- light runs round the frame of each column that took points, both ways, lighting it in its tree's colour (Plan.take*
-- have the timing; the tab's own render draws it,
-- so it costs nothing when the tab is closed). The nodes it opened (their padlocks gone) then flash in their tree's
-- colour with a ring, as the nodes a click opens do (a row opened by the points selected) just behind the click.
-- Smaller motions (Motion.lua has their timing): a rank raised makes its node pop with a cyan ring going out and a
-- "+1" floating up, one taken back shrinks it with a "-1", a refused click shakes it; the pip that changed flashes and
-- the tree's points left hop with the bar's segment lit. The node under the mouse lights and grows a little. A lit line
-- carries a light from the prerequisite down to its node every few seconds, the lines out of step. When the tab comes
-- on the screen its columns rise into place one after the other, their nodes pop in row by row, the lines draw
-- themselves down and the bars fill; a switch between the trees and the board plays the same, quicker (only the
-- drawing: a click works at once).
-- What a frame does: the states of the nodes and lines are worked out when the record or the selection changes
-- (refresh); a frame only paints them, with the motions from the clock. The body paints the tab's state, which is kept
-- on the tab and not on the body: each change of it is written to the body as well (View:changed), and the short
-- motions (a click's answer, the light under the mouse, a padlock, the opening, the take) are followed each frame
-- while they play (Trade/UI live, View.tick: one frame function for all of them), so that PZ Optimization's retained
-- UI draws them at once; then the body is let go and its drawing kept. What moves all the time (the pulse, the
-- dashes, the lines' lights) is drawn by the flow, a thin panel over the body (OAResearchFlow), which alone is drawn
-- afresh each frame; the nodes' pulse by a second such panel over it, drawn afresh only when the pulse has moved on a
-- step (PULSE_LEVELS from its low to its top) or a node held back starts to pulse.
require "ISUI/ISPanelJoypad"
require "ISUI/ISPanel"
require "ISUI/ISModalDialog" -- oa-widget: ok (the gamepad's confirm, View:ask)
require "ISUI/ISContextMenu"
require "XpSystem/ISUI/ISCharacterInfoWindow"
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Texts"
require "OperationAcorn/Upgrades/Links"
require "OperationAcorn/Upgrades/Motion"
require "OperationAcorn/Trade/UI"
require "PZUIKit/Confirm"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Plan = OA.Upgrades.Plan
local Effects = OA.Upgrades.Effects
local Texts = OA.Upgrades.Texts
local Links = OA.Upgrades.Links
local Motion = OA.Upgrades.Motion
local UI = OA.Trade.UI
local Window = {}
OA.Upgrades.Window = Window

local floor = math.floor

-- ---- colours ------------------------------------------------------------------------------------------------------
local P = UI.palette("field")
local GOLD = { 1.0, 0.84, 0.30 }           -- a full node
local CYAN = { 0.40, 0.95, 1.0 }           -- the selection
local LINE_DIM = { 0.30, 0.32, 0.25 }      -- a line whose prerequisite is not met
local NOTE = { 0.85, 0.78, 0.55 }          -- the research team's line
local API = { 1.0, 0.6, 0.3 }              -- a node that needs the extension API
local WHITE = { 1, 1, 1 }
local DARK = { 0.03, 0.03, 0.03 }
local BLACK = { 0, 0, 0 }
local CLOSED_TEXT = { 1, 0.9, 0.5 }          -- why a tree is closed
local PLUS_TEXT = { 0.04, 0.10, 0.12 }       -- the +n of selected ranks
-- Each tree's colour (its icons' plate colour, a little lifted) and its light tint for texts; the strip is the colour
-- mixed into the body, and the column under it the same colour more faintly (the trees told apart at a glance, as the
-- old tab's tinted columns did, without their muddy brown).
local TREE = {
    scout = { c = { 0.25, 0.66, 0.70 }, light = { 0.62, 0.90, 0.95 } },
    load = { c = { 0.86, 0.55, 0.22 }, light = { 1.0, 0.80, 0.52 } },
    survival = { c = { 0.46, 0.74, 0.32 }, light = { 0.70, 0.93, 0.58 } },
}
for _, t in pairs(TREE) do
    t.strip = {}
    t.body = {}
    t.core = {}                                -- the core of a line's light: the light colour, mostly white
    for i = 1, 3 do
        t.strip[i] = P.bg[i] * 0.83 + t.c[i] * 0.17
        t.body[i] = P.inset[i] * 0.925 + t.c[i] * 0.075
        t.core[i] = t.light[i] * 0.4 + 0.6
    end
end

-- ---- layout (design units) ----------------------------------------------------------------------------------------
local L = {
    PAD = 8, TOP = 28, GAP = 8,
    COL_W = 194, COL_GAP = 6, STRIP = 58,
    ICON = 32, CAP = 40, GX = 14, ROW = 52, PIPS = 10, GRID_PAD = 12,
    PLAN = 36, BUTTON_H = 26,
    TIP_W = 300, TIP_PAD = 10,
}
L.GRID_H = L.GRID_PAD + 4 * L.ROW + L.CAP + L.PIPS + 4
L.VIEW_W = 2 * L.PAD + 3 * L.COL_W + 2 * L.COL_GAP
L.COL_Y = L.PAD + L.TOP + L.GAP
L.PLAN_Y = L.COL_Y + L.STRIP + L.GRID_H + L.GAP
L.VIEW_H = L.PLAN_Y + L.PLAN + L.PAD
-- The 2nd board's bands: the columns' room shared by three, each a header strip over its row of nodes; the nodes'
-- spacing, the wider gap where their kind changes, and how far a kind's tray reaches round its nodes.
L.BAND_GAP, L.BAND_STRIP, L.BAND_GX, L.KIND_GAP, L.TRAY_PAD = 7, 30, 18, 34, 8
L.BAND_W = L.VIEW_W - 2 * L.PAD
L.BAND_H = (L.STRIP + L.GRID_H - 2 * L.BAND_GAP) / 3
Window.LAYOUT = L
-- Where a band's nodes change kind: after these places in its row (load: lightening, gear, carrying; survival:
-- resistance, the rest).
local KIND_ENDS = { load = { [4] = true, [6] = true }, survival = { [4] = true } }
-- The pulse of a node that can be taken (seconds a cycle), and the selected path's dashes: dash, gap (design units)
-- and how fast they flow (design units a second).
Window.PULSE_S = 1.6
-- The steps the pulse is drawn in, from its low point to its top (a step of the frame's strength is 1/24 of its range).
Window.PULSE_LEVELS = 24
Window.DASH, Window.DASH_GAP, Window.FLOW = 6, 4, 20
-- The points a tree's bar counts (every rank of the tree), and where its rows open on it.
local TREE_POINTS = {}
for _, tree in ipairs(Data.TREES) do
    local n = 0
    for _, node in ipairs(Data.treeNodes(tree)) do n = n + node.ranks end
    TREE_POINTS[tree] = n
end

local View = ISPanelJoypad:derive("ISOAResearchView")
ISOAResearchView = View

local views = {}       -- by player number

local function tabName() return getText("IGUI_OA_Tree_TabName") end

-- ---- pixels -------------------------------------------------------------------------------------------------------
-- The body draws in design units (UI.scaled); these draw what must land on whole pixels (the icons, the signs, the
-- lines and frames thicker than one pixel) in the body's own pixels, through the class without the scaling.
local S = 1
local function X(v) return floor(v * S + 0.5) end
-- The frame's clock (View:paint sets them): now in ms, and ms since the tab was made.
local NOW, CLOCK = 0, 0
-- What the parts of a frame share (View:frameState sets them as the body's or the flow's frame begins): the opening's
-- age in its own time (nil while it does not play), and each column's rise (design units below its place, in the
-- opening) and how much of it shows. Kept here: a frame makes nothing.
local OPEN_AGE = nil
local RISE, SHOWN = { 0, 0, 0 }, { 1, 1, 1 }

-- Under this a colour changes no pixel (half a step of the 8 bits a pixel has): it is not drawn.
local INVISIBLE = 0.002
-- A soft light is at its strongest in its middle and fades out to its edge: under this much (3 steps of 255) at its
-- middle, a few pixels across, it is not seen either.
local GLOW_INVISIBLE = 0.012

-- The rectangles of the flow's and the pulse's frames (View:paintFlow, View:paintPulses: a line's dashes and lights are
-- dozens a frame) go to the extension API's rects call as one list of numbers (8 each: x, y, w, h, r, g, b, a) instead of
-- a drawRect for each, in the order they were asked: a picture asked between (texPx) has the rectangles before it
-- drawn first. The list is kept between frames. An API without the call, or one whose call failed (said once, and not
-- tried again: the frame's rectangles are drawn one by one), leaves every rectangle a drawRect.
local rectList, rectCount, rectEl, rectDraw = {}, 0, nil, nil
local rectsFailed = false

local function drawRects()
    local n = rectCount
    if n == 0 then return end
    rectCount = 0
    local list = rectList
    local ok, err = pcall(rectDraw, rectEl, list, n)
    if ok then return end
    rectsFailed = true
    OA.log("research flow: the API's rects failed, drawn one by one:", tostring(err))
    for i = 0, n - 1 do
        local at = i * 8
        ISUIElement.drawRect(rectEl, list[at + 1], list[at + 2], list[at + 3], list[at + 4], list[at + 8], list[at + 5],
            list[at + 6], list[at + 7])
    end
end

-- Starts a frame's batch for the element `el` (every rectangle of the frame is drawn on it), and ends it (what is left
-- is drawn). Nothing is batched outside a frame, or without the API's call.
local function beginRects(el)
    rectCount = 0
    rectDraw = not rectsFailed and OA.drawCall("rects") or nil
    rectEl = rectDraw and el or nil
end

local function endRects()
    if rectEl then drawRects() end
    rectEl, rectDraw = nil, nil
end

local function rectPx(el, x, y, w, h, c, a)
    if w <= 0 or h <= 0 or (a and a < INVISIBLE) then return end
    if el == rectEl then
        local l, at = rectList, rectCount * 8
        l[at + 1], l[at + 2], l[at + 3], l[at + 4] = x, y, w, h
        l[at + 5], l[at + 6], l[at + 7], l[at + 8] = c[1], c[2], c[3], a or 1
        rectCount = rectCount + 1
        return
    end
    ISUIElement.drawRect(el, x, y, w, h, a or 1, c[1], c[2], c[3])
end

local function texPx(el, tex, x, y, w, h, c, a)
    if not tex or (a and a < INVISIBLE) then return end
    c = c or WHITE
    if el == rectEl then drawRects() end
    ISUIElement.drawTextureScaled(el, tex, x, y, w, h, a or 1, c[1], c[2], c[3])
end

-- A texture tiled at its own pixels over a rectangle (pixels), after the rectangles waiting before it.
local function tiledPx(el, tex, x, y, w, h, c, a)
    if not tex or w <= 0 or h <= 0 or (a and a < INVISIBLE) then return end
    c = c or WHITE
    if el == rectEl then drawRects() end
    ISUIElement.drawTextureTiled(el, tex, x, y, w, h, c[1], c[2], c[3], a or 1)
end

-- A steady pseudo-random number in [0, 1) for a whole number (the same number, the same answer): what picks a
-- rough frame's pieces and a panel's chips, so they stay put between frames.
local function rnd(i)
    local v = math.sin(i * 12.9898 + 78.233) * 43758.5453
    return v - floor(v)
end

-- The grit's film: a motion that should look rough moves on in steps of FILM_MS (twelve frames a second), and a
-- rough frame's pieces change with each step.
Window.FILM_MS = 83
local function film(age) return floor(age / Window.FILM_MS) * Window.FILM_MS end
local function filmStep(age) return floor(age / Window.FILM_MS) end

-- A frame (as framePx) drawn rough, as by a worn stamp or a weak signal: each side in short pieces of varying
-- strength, a few missing and some a pixel off the line. `seed` picks the pieces: the same seed, the same frame.
Window.ROUGH_PIECE = 6
local function roughFramePx(el, x, y, w, h, c, a, t, out, seed)
    out = out or 0
    local x0, y0, x1, y1 = X(x - out), X(y - out), X(x + w + out), X(y + h + out)
    local piece = math.max(3, X(Window.ROUGH_PIECE))
    local k = 0
    local function side(across, fixed, from, to)
        local p = from
        while p < to do
            k = k + 1
            local r = rnd(seed * 97 + k)
            local e = math.min(to, p + piece - floor(r * piece * 0.5))
            if r > 0.12 then
                local off = r > 0.82 and 1 or (r < 0.24 and -1 or 0)
                local pa = a * (0.45 + 0.55 * rnd(seed * 53 + k * 7))
                if across then rectPx(el, p, fixed + off, e - p, t, c, pa)
                else rectPx(el, fixed + off, p, t, e - p, c, pa) end
            end
            p = e
        end
    end
    side(true, y0, x0, x1)
    side(true, y1 - t, x0, x1)
    side(false, x0, y0 + t, y1 - t)
    side(false, x1 - t, y0 + t, y1 - t)
end

-- The terminals' static (tools/static_art.py) as a burst over a node, the tile swapped with each film step.
local staticTex = {}
local function staticBurst(el, x, y, w, h, c, a, step)
    local i = (step - floor(step / 2) * 2) + 1
    if staticTex[i] == nil then staticTex[i] = getTexture("media/textures/OA_Static_" .. i .. ".png") or false end
    texPx(el, staticTex[i] or nil, X(x), X(y), X(x + w) - X(x), X(y + h) - X(y), c, a)
end

-- The grit (tools/grain_art.py's tiles, drawn tiled at their own pixels): the print's wear (stains, specks, hairline
-- scratches, dark) at BG_GRIME_A, the film grain (light specks) over it at BG_GRAIN_A. Over the strips as well as the
-- grids, the 2nd board's bands too.
Window.BG_GRAIN_A, Window.BG_GRIME_A = 0.08, 0.75
-- A column's frame is chipped: CHIPS short gaps along it, each CHIP_MIN..CHIP_MAX design units long, where it was.
Window.CHIPS, Window.CHIP_MIN, Window.CHIP_MAX = 9, 2, 9

local grimeTex = nil
local function grime()
    if grimeTex == nil then grimeTex = getTexture("media/textures/OA_Grime.png") or false end
    return grimeTex or nil
end
local grainTex = nil
local function grain()
    if grainTex == nil then grainTex = getTexture("media/textures/OA_Grain.png") or false end
    return grainTex or nil
end

-- The grit over a rectangle (design units): the wear, then the grain.
local function paintGrit(el, x, y, w, h)
    local x0, y0 = X(x), X(y)
    local pw, ph = X(x + w) - x0, X(y + h) - y0
    tiledPx(el, grime(), x0, y0, pw, ph, BLACK, Window.BG_GRIME_A)
    tiledPx(el, grain(), x0, y0, pw, ph, WHITE, Window.BG_GRAIN_A)
end
Window.paintGrit = paintGrit

-- A column's frame chipped (drawn over it): short gaps in the tab's background colour, the same places each frame
-- (`seed`: the column).
local function chipFrame(el, x, y, w, h, seed)
    local t = math.max(1, X(1))
    for k = 1, Window.CHIPS do
        local r1, r2 = rnd(seed * 131 + k), rnd(seed * 71 + k * 13)
        local len = Window.CHIP_MIN + (Window.CHIP_MAX - Window.CHIP_MIN) * r2
        local side = floor(r1 * 4)
        local along = (r1 * 4 - side)
        if side < 2 then
            local px = X(x + (w - len) * along)
            rectPx(el, px, side == 0 and X(y) or X(y + h) - t, X(len), t, P.bg, 0.9)
        else
            local py = X(y + (h - len) * along)
            rectPx(el, side == 2 and X(x) or X(x + w) - t, py, t, X(len), P.bg, 0.9)
        end
    end
end

-- The signs' textures: tools/ui_glyphs.py writes each at every pixel size in these ranges.
local GLYPH_SIZES = { Pip = { 4, 48 }, Ring = { 4, 24 }, Check = { 8, 40 }, Cross = { 8, 40 }, Reset = { 10, 48 } }
local glyphs = {}

local function glyphTex(name, px)
    local range = GLYPH_SIZES[name]
    px = math.max(range[1], math.min(range[2], px))
    local key = name .. px
    local tex = glyphs[key]
    if tex == nil then
        tex = getTexture("media/textures/OA_UI/OA_UI_" .. name .. "_" .. px .. ".png") or false
        glyphs[key] = tex
    end
    return tex or nil, px
end

-- A sign centred on design point cx, cy, `size` design units across, at its own pixel size.
local function glyph(el, name, cx, cy, size, c, a)
    local tex, px = glyphTex(name, floor(size * S + 0.5))
    texPx(el, tex, X(cx) - floor(px / 2), X(cy) - floor(px / 2), px, px, c, a)
end

-- A node icon's pixel size for a design size: whole multiples of 8 pixels, never more than asked, from the 128 px
-- pictures (shrunk by no more than about 2 on the screens the game runs at).
local function iconPx(size)
    return math.max(16, 8 * floor(size * S / 8))
end

-- An item icon's texture for a pixel size: the 32 px inventory icon, or its 64 px copy (tools/icon_art.py) when it is
-- drawn larger; each found once.
local smallIcons, bigIcons = {}, {}
local function itemTexture(name, px)
    local big = px > 34
    local known = big and bigIcons or smallIcons
    local tex = known[name]
    if tex == nil then
        tex = getTexture(big and ("media/textures/OA_ItemHi/OA_" .. name .. "_64.png")
            or ("media/textures/Item_OA_" .. name .. ".png")) or false
        known[name] = tex
    end
    return tex or nil
end

-- A frame `t` pixels thick around a design box, `out` design units outside it.
local function framePx(el, x, y, w, h, c, a, t, out)
    out = out or 0
    local x0, y0, x1, y1 = X(x - out), X(y - out), X(x + w + out), X(y + h + out)
    rectPx(el, x0, y0, x1 - x0, t, c, a)
    rectPx(el, x0, y1 - t, x1 - x0, t, c, a)
    rectPx(el, x0, y0 + t, t, y1 - y0 - 2 * t, c, a)
    rectPx(el, x1 - t, y0 + t, t, y1 - y0 - 2 * t, c, a)
end

-- The same dashed (a selected node).
local function dashedPx(el, x, y, w, h, c, a, t, out)
    local x0, y0, x1, y1 = X(x - out), X(y - out), X(x + w + out), X(y + h + out)
    local dash, gap = math.max(2, X(5)), math.max(1, X(3))
    local px = x0
    while px < x1 do
        local e = math.min(px + dash, x1)
        rectPx(el, px, y0, e - px, t, c, a)
        rectPx(el, px, y1 - t, e - px, t, c, a)
        px = px + dash + gap
    end
    local py = y0
    while py < y1 do
        local e = math.min(py + dash, y1)
        rectPx(el, x0, py, t, e - py, c, a)
        rectPx(el, x1 - t, py, t, e - py, c, a)
        py = py + dash + gap
    end
end

local function thick()
    return math.max(2, floor(S * 1.25 + 0.5))
end

local function remainder(v, m)
    return v - floor(v / m) * m
end

-- Where segment k of a bar of `total` segments from pixel x0 to x1 starts (pixels).
local function segX(x0, x1, k, total)
    return x0 + floor((x1 - x0) * k / total + 0.5)
end

-- A text made with a number put in by getText, cut where the number goes: before, after (the number drawn apart in
-- its own colour, in any language's order). Kept once cut (a frame asks).
local cut = {}
local function around(key)
    local known = cut[key]
    if known then return known[1], known[2] end
    local mark = string.char(1)
    local s = getText(key, mark)
    local at = string.find(s, mark, 1, true)
    known = at and { string.sub(s, 1, at - 1), string.sub(s, at + 1) } or { s, "" }
    cut[key] = known
    return known[1], known[2]
end

-- ---- the body: our element, in design units ----------------------------------------------------------------------
OAResearchBody = ISPanel:derive("OAResearchBody")

function OAResearchBody:new(view)
    local o = ISPanel.new(self, 0, 0, L.VIEW_W, L.VIEW_H)
    o.view = view
    o.background = false
    o.palette = P
    return o
end

function OAResearchBody:prerender()
    self.view:paint(self)
end

function OAResearchBody:onMouseMove(dx, dy)
    self.view:setHover(self:itemAtMouse())
end

function OAResearchBody:onMouseMoveOutside(dx, dy)
    self.view:setHover(nil)
end

function OAResearchBody:itemAtMouse()
    return self.view:itemAt(self:getMouseX(), self:getMouseY())
end

function OAResearchBody:onMouseDown(x, y)
    return true
end

function OAResearchBody:onMouseUp(x, y)
    local item = self.view:itemAt(x, y)
    if item then self.view:press(item) end
    return true
end

-- A right click takes a selected rank back (the flow over the body passes it on: OAResearchFlow).
function View:rightClick(x, y)
    local item = self:itemAt(x, y)
    if item and item.id then self:unplan(item.id) end
    return true
end

function OAResearchBody:onRightMouseDown(x, y)
    return true
end

function OAResearchBody:onRightMouseUp(x, y)
    return self.view:rightClick(x, y)
end

UI.scaled(OAResearchBody, ISPanel)

-- ---- the flow: what moves by itself, over the body ----------------------------------------------------------------
-- The nodes' pulse, the selection's dashes and the lit lines' lights move all the time the tab shows. Drawn by the body
-- they would have PZ Optimization draw all of it (every icon, text and pip) afresh each frame; drawn by a thin panel of
-- their own over it, only this panel is. It is the body's sibling, not its child (a child followed each frame would
-- mark the body changed as well, Trade/UI live), the same size, made with it, and takes no clicks: the body under it
-- gets them.
OAResearchFlow = ISPanel:derive("OAResearchFlow")

function OAResearchFlow:new(view, pulses)
    local o = ISPanel.new(self, 0, 0, L.VIEW_W, L.VIEW_H)
    o.view = view
    o.pulses = pulses or false     -- the one that draws the nodes' pulse (View:paintPulses), not the lights
    o.background = false
    return o
end

function OAResearchFlow:createChildren()
    self.javaObject:setConsumeMouseEvents(false)
end

-- The game hands a right click to the element on top whether or not it takes mouse events: the flow passes it on to
-- the body's (the same place: their coordinates are the same).
function OAResearchFlow:onRightMouseDown(x, y)
    return true
end

function OAResearchFlow:onRightMouseUp(x, y)
    return self.view:rightClick(x, y)
end

function OAResearchFlow:prerender()
    local view = self.view
    -- shown again some way that did not register it (its window shown as a whole): followed from now on
    if self.pulses then
        if view.pulsingOn then UI.live(self, View.pulseTick) end
        view:paintPulses(self)
    else
        if view.lighting then UI.live(self, View.flowTick) end
        view:paintFlow(self)
    end
end

UI.scaled(OAResearchFlow, ISPanel)

-- ---- the tooltip: ours, in the terminal tooltip's look -------------------------------------------------------------
OAResearchTip = ISPanel:derive("OAResearchTip")

function OAResearchTip:new()
    local o = ISPanel.new(self, 0, 0, L.TIP_W, 40)
    o.background = false
    o.rows = {}
    return o
end

-- The rows' heights (design units): a title in the Medium face, a separator, a line of the Small face otherwise.
local function rowHeight(row, fh)
    if row.kind == "title" then return UI.fontHeight(UIFont.Medium) + 4 end
    if row.kind == "sep" then return 9 end
    if row.lines then return #row.lines * fh end
    return fh + 2
end

-- Sets the rows (wrapped to the width here) and the height.
function OAResearchTip:setRows(rows)
    local inner = L.TIP_W - 2 * L.TIP_PAD
    local labelW = 0
    for _, row in ipairs(rows) do
        if row.kind == "pair" then labelW = math.max(labelW, UI.textWidth(row.label)) end
    end
    self.labelW = labelW > 0 and labelW + 8 or 0
    for _, row in ipairs(rows) do
        if row.kind == "para" then
            row.lines = UI.wrap(row.text, inner)
        elseif row.kind == "pair" then
            row.lines = UI.wrap(row.text, inner - self.labelW)
        elseif row.kind == "check" then
            row.lines = UI.wrap(row.text, inner - 18)
        end
    end
    self.rows = rows
    local fh = UI.fontHeight()
    local h = 2 * L.TIP_PAD - 2
    for _, row in ipairs(rows) do h = h + rowHeight(row, fh) end
    self:setHeight(h)
end

function OAResearchTip:prerender()
    UI.fill(self, 0, 0, self.width, self.height, { 0, 0, 0 }, 0.92)
    UI.frame(self, 0, 0, self.width, self.height, P.border)
    local fh = UI.fontHeight()
    local pad = L.TIP_PAD
    local inner = self.width - 2 * pad
    local y = pad - 2
    for _, row in ipairs(self.rows) do
        local k = row.kind
        if k == "title" then
            UI.text(self, row.text, pad, y, P.bright, UIFont.Medium)
            if row.sub then
                local fm = UI.fontHeight(UIFont.Medium)
                UI.textRight(self, row.sub, pad + inner, y + fm - fh, row.subc or P.dim)
            end
        elseif k == "stage" then
            UI.text(self, row.text, pad, y, P.dim)
            if row.n and row.n > 0 then
                Window.pips(self, pad + UI.textWidth(row.text) + 10, y + fh / 2, row.n, row.full, row.planned,
                    row.color, "left")
            end
        elseif k == "sep" then
            UI.fill(self, pad, y + 4, inner, 1 / S, P.border, 0.8)
        elseif k == "label" then
            UI.text(self, row.text, pad, y, row.c or P.value)
        elseif k == "para" then
            for i, line in ipairs(row.lines) do UI.text(self, line, pad, y + (i - 1) * fh, row.c or P.text) end
        elseif k == "pair" then
            UI.text(self, row.label, pad, y, row.lc or P.dim)
            for i, line in ipairs(row.lines) do
                UI.text(self, line, pad + self.labelW, y + (i - 1) * fh, row.c or P.text)
            end
        elseif k == "check" then
            if row.ok then
                glyph(self, "Check", pad + 6, y + fh / 2, 11, P.good)
            else
                glyph(self, "Cross", pad + 6, y + fh / 2, 9, P.bad)
            end
            for i, line in ipairs(row.lines) do
                UI.text(self, line, pad + 18, y + (i - 1) * fh, row.ok and P.text or P.bad, nil, row.ok and 0.85 or 1)
            end
        end
        y = y + rowHeight(row, fh)
    end
end

UI.scaled(OAResearchTip, ISPanel)

-- ---- the tab ----------------------------------------------------------------------------------------------------------

function View:new(playerNum)
    local o = ISPanelJoypad.new(self, 0, 0, 100, 100)
    o.playerNum = playerNum
    o.player = getSpecificPlayer(playerNum)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.palette = P
    o.mode = "trees"
    o.steps, o.counts = {}, {}
    o.revealed = {}
    o.items, o.lines, o.panels = {}, {}, {}
    o.nodes = {}
    o.t0 = getTimestampMs()
    o:measure()
    o:setWidth(o.wantW)
    o:setHeight(o.wantH)
    return o
end

-- The scale now (for a screen or font changed since), and the tab's size in pixels.
function View:measure()
    local ok, err = pcall(UI.refreshScale)
    if not ok then OA.log("research tab: no scale", tostring(err)) end
    S = UI.S
    self.wantW, self.wantH = UI.px(L.VIEW_W), UI.px(L.VIEW_H)
    self.gridW = L.COL_W
end

function View:createChildren()
    ISPanelJoypad.createChildren(self)
    self:makeBody()
end

-- The body, the flow over it (added after it, so drawn over it) and the tooltip for the scale now; made again when it
-- changed (UI.era).
function View:makeBody()
    if self.body then
        self:removeChild(self.body)
        self.body = nil
    end
    if self.flow then
        self:removeChild(self.flow)
        self.flow = nil
    end
    if self.pulse then
        self:removeChild(self.pulse)
        self.pulse = nil
    end
    if self.tip then
        self:hideTip()
        self.tip = nil
    end
    self.era = UI.era
    local body = OAResearchBody:new(self)
    body:initialise()
    body:instantiate()
    self:addChild(body)
    self.body = body
    local flow = OAResearchFlow:new(self)
    flow:initialise()
    flow:instantiate()
    self:addChild(flow)
    self.flow = flow
    local pulse = OAResearchFlow:new(self, true)
    pulse:initialise()
    pulse:instantiate()
    self:addChild(pulse)
    self.pulse = pulse
    self:layout()
    -- (the new layout's lines and lists of what moves, at once)
    if self.sim then self:workOut() end
    self:animate()
end

-- Before the tab shows: the scale again, and a new body when it changed.
function View:checkScale()
    self:measure()
    if not self.body or self.era ~= UI.era then self:makeBody() end
end

function View:panelX(i)
    return L.PAD + (i - 1) * (L.COL_W + L.COL_GAP)
end

-- ---- layout (design units) ----------------------------------------------------------------------------------------

-- A node's box in its column's grid: x, y, size.
local function cell(col, row, capstone)
    if capstone then
        local cx = L.GRID_PAD + (col - 1) * (L.ICON + L.GX) + L.ICON / 2
        return cx - L.CAP / 2, L.GRID_PAD + (row - 1) * L.ROW, L.CAP
    end
    return L.GRID_PAD + (col - 1) * (L.ICON + L.GX), L.GRID_PAD + (row - 1) * L.ROW, L.ICON
end

-- A waypoint of a link (Links.lua) in its column's grid.
local function waypoint(p)
    local x
    if p.x == "gutter" then
        x = L.GRID_PAD + p.c * (L.ICON + L.GX) - L.GX / 2
    else
        x = L.GRID_PAD + (p.c - 1) * (L.ICON + L.GX) + L.ICON / 2
    end
    local top = L.GRID_PAD + (p.r - 1) * L.ROW
    local size = (p.r >= Data.ROWS) and L.CAP or L.ICON
    local y
    if p.y == "top" then
        y = top
    elseif p.y == "bottom" then
        y = top + size + L.PIPS
    else
        y = top + size + L.PIPS + (L.ROW - L.ICON - L.PIPS) / 2
    end
    return x, y
end

-- What can be pointed at: the nodes, the lines between them, and the buttons (the gamepad's cursor reaches these too).
-- Each item has a key (the node id, or "mode:trees" and the like), its box, and what pressing it does.
function View:layout()
    self.items, self.lines, self.panels = {}, {}, {}
    local items = self.items
    local groups = (self.mode == "board") and Data.BOARD_GROUPS or Data.TREES
    for i, tree in ipairs(groups) do
        if self.mode == "board" then
            -- a band: its nodes in a row across its middle (they pop in four at a time in the opening), each kind of
            -- them on a tray
            local px, py = L.PAD, L.COL_Y + (i - 1) * (L.BAND_H + L.BAND_GAP)
            local panel = { tree = tree, x = px, y = py, w = L.BAND_W, strip = L.BAND_STRIP, gridH = L.BAND_H - L.BAND_STRIP,
                gx = px, gy = py + L.BAND_STRIP, trays = {} }
            self.panels[#self.panels + 1] = panel
            local nodes, ends = Data.boardGroup(tree), KIND_ENDS[tree] or {}
            local rowW = #nodes * L.ICON
            for k = 1, #nodes - 1 do rowW = rowW + (ends[k] and L.KIND_GAP or L.BAND_GX) end
            local x, y = px + (L.BAND_W - rowW) / 2, panel.gy + (panel.gridH - L.ICON - L.PIPS) / 2
            local from = x
            for k, node in ipairs(nodes) do
                items[#items + 1] = { key = node.id, id = node.id, tree = tree, x = x, y = y, w = L.ICON, h = L.ICON,
                    col = i, row = floor((k - 1) / 4) + 1 }
                x = x + L.ICON
                if ends[k] or k == #nodes then
                    panel.trays[#panel.trays + 1] = { x = from - L.TRAY_PAD, y = y - L.TRAY_PAD, w = x - from + 2 * L.TRAY_PAD,
                        h = L.ICON + L.PIPS + 2 * L.TRAY_PAD }
                    x = x + L.KIND_GAP
                    from = x
                else
                    x = x + L.BAND_GX
                end
            end
        else
            local px, py = self:panelX(i), L.COL_Y
            local gx, gy = px, py + L.STRIP
            self.panels[#self.panels + 1] = { tree = tree, x = px, y = py, w = L.COL_W, strip = L.STRIP, gridH = L.GRID_H,
                gx = gx, gy = gy }
            for _, node in ipairs(Data.treeNodes(tree)) do
                local x, y, s = cell(node.col, node.row, node.capstone)
                items[#items + 1] = { key = node.id, id = node.id, tree = tree, x = gx + x, y = gy + y, w = s, h = s,
                    col = i, row = node.row }
            end
            for _, link in ipairs(Links.tree(tree)) do
                local pts, len = {}, 0
                for k, p in ipairs(link.points) do
                    local x, y = waypoint(p)
                    pts[k] = { gx + x, gy + y }
                    local prev = pts[k - 1]
                    if prev then len = len + math.abs(pts[k][1] - prev[1]) + math.abs(pts[k][2] - prev[2]) end
                end
                -- its number and length time the light that runs down it (Motion.comet); its column and its node's
                -- row, when it draws itself in the opening; its node, which its light arrives at
                local index = #self.lines + 1
                self.lines[index] = { need = link.need, tree = tree, points = pts, index = index, len = len, col = i,
                    row = Data.byId[link.to].row, to = link.to }
            end
            -- the reset button at the strip's right
            local bs = 22
            items[#items + 1] = { key = "reset:" .. tree, kind = "reset", tree = tree,
                x = px + L.COL_W - 10 - bs, y = py + 5, w = bs, h = bs }
        end
    end
    -- the modes
    local y, h = L.PAD + 1, L.TOP - 2
    local w1 = UI.textWidth(getText("IGUI_OA_Tree_ModeTrees")) + 28
    items[#items + 1] = { key = "mode:trees", kind = "mode", mode = "trees", x = L.PAD, y = y, w = w1, h = h }
    local boardW = self:boardTabWidth()
    items[#items + 1] = { key = "mode:board", kind = "mode", mode = "board", x = L.PAD + w1 + 6, y = y, w = boardW, h = h }
    -- the bar's buttons
    local bh = L.BUTTON_H
    local by = L.PLAN_Y + (L.PLAN - bh) / 2
    local wa = UI.textWidth(getText("IGUI_OA_Tree_Approve")) + 36
    local wc = UI.textWidth(getText("IGUI_OA_Tree_ClearPlan")) + 24
    local ax = L.VIEW_W - L.PAD - 6 - wa
    items[#items + 1] = { key = "clear", kind = "clear", x = ax - 6 - wc, y = by, w = wc, h = bh }
    items[#items + 1] = { key = "approve", kind = "approve", x = ax, y = by, w = wa, h = bh }
    self.byKey = {}
    for _, item in ipairs(items) do self.byKey[item.key] = item end
end

-- The board tab's text and width: the board's name once open, else ??? (n/3) with a padlock and a segment a tree.
function View:boardTabText()
    local sim = self.sim
    if sim and Rules.boardOpen(sim) then return Texts.treeName(Data.BOARD), false end
    local n = sim and Rules.capstones(sim) or 0
    return UI.str("IGUI_OA_Tree_BoardClosedTab", n, #Data.TREES), true
end

function View:boardTabWidth()
    local text, closed = self:boardTabText()
    local w = UI.textWidth(text) + 28
    if closed then w = w + 14 + 3 * 14 + 4 end
    return w
end

function View:itemOf(key)
    return self.byKey and self.byKey[key] or nil
end

-- The item at a design point (only what can be pressed now).
function View:itemAt(x, y)
    for _, item in ipairs(self.items) do
        if x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h and self:reachable(item) then
            return item
        end
    end
    return nil
end

-- Whether an item can be pointed at now: the reset of a tree with something spent in it, every other.
function View:reachable(item)
    if item.kind == "reset" then return self.u ~= nil and Rules.treeSpent(self.u, item.tree) > 0 end
    return true
end

-- Whether pressing a button does something now.
function View:enabled(item)
    local hasPlan = #self.steps > 0
    if item.kind == "approve" or item.kind == "clear" then return hasPlan end
    if item.kind == "reset" then return not hasPlan and self:reachable(item) end
    return true
end

function View:setHover(item)
    local key = (item and not self:asking()) and item.key or nil
    if key ~= self.hover then
        self.hover = key
        self:changed()
    end
end

-- What the body shows changed (the nodes, the hover, the cursor, a refusal): the tooltip is made again, and a count
-- is written to the body, which PZ Optimization watches (the state is the tab's; the body only paints it).
function View:changed()
    self.tipDirty = true
    local body = self.body
    if body then body.rev = (body.rev or 0) + 1 end
    self:lightFocus()
    self:animate()
end

-- The node under the mouse or the gamepad's cursor lights (Trade/UI place lights, by node id on the body: the one
-- left goes down). The lights register their own frame function on the body; View:animate puts ours back after, which
-- follows them too (View.tick).
function View:lightFocus()
    local body = self.body
    if not body then return end
    local key = self.hover or (self.joypad and self.cursor) or nil
    local item = key and self:itemOf(key)
    UI.placeLight(body, item and item.id or nil)
end

-- ---- state -----------------------------------------------------------------------------------------------------

function View:record()
    return OA.Client.record(self.player)
end

-- Reads the record again and re-simulates the plan on it, and works out what each node and line shows.
function View:refresh()
    self.player = getSpecificPlayer(self.playerNum) or self.player
    local record = self.player and self:record()
    if not record then return end
    self.u = Rules.section(record)
    local sim, kept = Plan.simulate(self.u, self.steps)
    self.sim, self.steps = sim, kept
    self.counts = Plan.counts(kept)
    self.spentPlan = Plan.spent(self.u, sim)
    self.revealed = {}
    for _, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        if cap and Rules.rank(sim, cap.id) >= 1 then self.revealed[tree] = true end
    end
    self:layout()
    self:workOut()
    self:changed()
end

-- Whether a node's state shows it locked: grey, with a padlock.
local function greyed(n)
    return n.state == "locked" or n.treeLocked == true
end

-- What each node and line shows, from the record and the simulation (once a change, not each frame); and what of it
-- moves by itself, which the flow draws (View:paintFlow walks only these lists): the nodes that pulse, the lines in
-- dashes, the lit lines with their lights.
function View:workOut()
    local nodes = self:nodeStates(self.sim, self.counts)
    self.nodes = nodes
    local pulsing, planLines, litLines = {}, {}, {}
    for _, item in ipairs(self.items) do
        local n = item.id and nodes[item.id]
        if n and n.state == "avail" and not n.treeLocked and not n.hidden then pulsing[#pulsing + 1] = item end
    end
    local u, sim = self.u, self.sim
    for _, line in ipairs(self.lines) do
        local need, k = line.need[1], line.need[2]
        local into = nodes[line.to]
        if into and into.hidden then
            -- a sealed capstone shows no way into it
            line.state = "hidden"
        elseif Rules.rank(u, need) >= k then
            line.state = "lit"
            litLines[#litLines + 1] = line
            local n = nodes[line.to]
            line.target, line.targetLocked = self.byKey[line.to], n ~= nil and greyed(n)
        elseif Rules.rank(sim, need) >= k then
            line.state = "plan"
            planLines[#planLines + 1] = line
        else
            line.state = "dim"
        end
    end
    self.pulsing, self.planLines, self.litLines = pulsing, planLines, litLines
    self.pulsingOn = #pulsing > 0
    self.lighting = #planLines > 0 or #litLines > 0
    self.flowing = self.pulsingOn or self.lighting
end

-- The state of each node on the screen on a simulation, with `counts` ranks of each selected.
function View:nodeStates(sim, counts)
    local u = self.u
    local nodes = {}
    local boardOpen = Rules.boardOpen(sim)
    for _, item in ipairs(self.items) do
        if item.id then
            local node = Data.byId[item.id]
            local rank = Rules.rank(sim, node.id)
            local planned = counts[node.id] or 0
            local n = { rank = rank, planned = planned, full = rank - planned }
            if node.board then
                n.hidden = not boardOpen and not self.revealed[node.group]
                if not boardOpen then
                    n.state = "locked"
                elseif planned > 0 then
                    n.state = "planned"
                elseif not Rules.blocked(sim, node.id, "A") then
                    n.state = "avail"
                elseif rank > 0 then
                    n.state = "owned"
                else
                    n.state = "dim"
                end
            else
                n.treeLocked = not Rules.treeOpen(u, node.tree)
                -- a capstone is an outline (???) until its tree is unsealed: what opens it, and what it does, are
                -- told when it happens (the research team's memo)
                n.hidden = node.capstone and not Rules.unsealed(sim, node.tree) or nil
                local why = Rules.blocked(sim, node.id, "A")
                if planned > 0 then
                    n.state = "planned"
                elseif rank >= node.ranks then
                    n.state = "maxed"
                elseif not why then
                    n.state = "avail"
                elseif rank > 0 then
                    n.state = "owned"
                else
                    n.state = "locked"
                end
            end
            n.api = node.kind == "api" and Effects.status(node.id) ~= "ok"
            nodes[node.id] = n
        end
    end
    return nodes
end

function View:onMode(button)
    if self.mode == button.internal then return end
    self.mode = button.internal
    self.hover = nil
    self:layout()
    if self.sim then self:workOut() end
    if self.joypad then self.cursor = (self:firstNode() or {}).key or self.cursor end
    self:changed()
    -- the other trees come up as the tab's do when it opens, quicker
    self:startOpen(Motion.SWITCH_PACE)
end

function View:firstNode()
    for _, item in ipairs(self.items) do
        if item.id then return item end
    end
    return nil
end

-- A press on an item: a node selects a rank, a button does its job (when it can).
function View:press(item)
    if item.id then return self:plan(item.id) end
    if not self:enabled(item) then return end
    getSoundManager():playUISound("UIActivateButton")
    if item.kind == "mode" then
        self:onMode({ internal = item.mode })
    elseif item.kind == "reset" then
        self:onReset({ internal = item.tree })
    elseif item.kind == "clear" then
        self:onClear()
    elseif item.kind == "approve" then
        self:onApprove()
    end
end

-- ---- planning --------------------------------------------------------------------------------------------------

function View:plan(id)
    if not self.sim then return end
    local steps, why = Plan.add(self.u, self.steps, id)
    if not steps then
        self.refusal = { id = id, why = why }
        self:startFx(id, "shake")
        self:changed()
        return
    end
    self.refusal = nil
    self.steps = steps
    local before = self.nodes
    self:startFx(id, "pop")
    -- (a node still waiting for a take to open it opens now: it is being used)
    if self.unlocks then self.unlocks[id] = nil end
    self:refresh()
    self:markChange(id, false)
    self:unlockSince(before, getTimestampMs() + Motion.UNLOCK_DELAY_MS)
end

-- Takes a selected rank back (the node shrinks a moment), or shakes the node when it has none selected.
function View:unplan(id)
    if not self.sim then return end
    local steps = Plan.remove(self.u, self.steps, id)
    local back = steps ~= self.steps
    self:startFx(id, back and "shrink" or "shake")
    self.steps = steps
    self.refusal = nil
    self:refresh()
    if back then self:markChange(id, true) end
end

-- After a rank selected or taken `back`: the pip that changed flashes with the click's answer, and the tree's points
-- left hop with the segment of its bar that changed (View.bump).
function View:markChange(id, back)
    local node = Data.byId[id]
    local n = self.nodes and self.nodes[id]
    if not n or node.board then return end
    local f = self.fx and self.fx[id]
    if f then f.pip = n.full + n.planned + (back and 1 or 0) end
    local tree = node.tree
    local planned = self.spentPlan and self.spentPlan[tree] or 0
    local seg = Rules.treeSpent(self.u, tree) + planned - (back and 0 or 1)
    self.bump = { tree = tree, seg = seg, at = getTimestampMs() }
    self:animate()
end

-- A yes-or-no question: ours with the mouse; the game's dialog with the gamepad (ours takes no gamepad).
function View:ask(text, onYes, arg)
    if self.joypad then
        -- oa-widget: ok (the gamepad: our confirm has no gamepad focus)
        local modal = ISModalDialog:new(0, 0, 360, 190, text, true, self, View.onAnswer, self.playerNum, onYes, arg)
        modal:initialise()
        modal:addToUIManager()
        modal:setX(self:getAbsoluteX() + (self.width - modal.width) / 2)
        modal:setY(self:getAbsoluteY() + (self.height - modal.height) / 2)
        setJoypadFocus(self.playerNum, modal)
        self.question = modal
    else
        self.question = UI.confirm(self.player, text, self, onYes, arg)
    end
    self:setHover(nil)
    self:hideTip()
end

-- Whether a question of the tab's is on the screen: nothing under it is hovered or explained meanwhile (the tooltip,
-- kept on top each frame, covered the question; seen in game, the reset's).
function View:asking()
    local q = self.question
    if q and q:isVisible() then return true end
    self.question = nil
    return false
end

function View:onAnswer(button, onYes, arg)
    if button.internal == "YES" then onYes(self, arg) end
    if self.joypad then setJoypadFocus(self.playerNum, self) end
end

-- The approval asks first: an approved rank is taken back only by a reset, which costs credits.
function View:onApprove()
    if #self.steps == 0 then return end
    self:ask(getText("IGUI_OA_Tree_ApproveConfirm", #self.steps), View.approve)
end

function View:approve()
    if #self.steps == 0 then return end
    -- what the plan was and what it spends in each tree, for the take that plays when the answer comes back (alone,
    -- that is at once, inside the send), and the nodes the record shows locked, of which those it opens lose their
    -- padlocks after it
    self.approved = { steps = self.steps, at = getTimestampMs(), locked = self:lockedOnRecord(),
        spent = self.spentPlan }
    OA.Sync.send(self.player, "upgrades.approve", { steps = self.steps })
    self.steps = {}
    self.refusal = nil
    self:refresh()
end

function View:onClear()
    self.steps = {}
    self.refusal = nil
    self:refresh()
end

function View:onReset(button)
    local tree = button.internal
    if not self.u then return end
    local cost = Rules.resetCost(self.u, tree)
    local credits = (OA.Store.section(self:record(), "trade").credits) or 0
    self:ask(getText("IGUI_OA_Tree_ResetConfirm", Texts.treeName(tree), cost, credits), View.reset, tree)
end

function View:reset(tree)
    OA.Sync.send(self.player, "upgrades.reset", { tree = tree })
end

-- ---- the tooltip -----------------------------------------------------------------------------------------------

-- The rows of a node's tooltip: its name and tree, its rank, what it does now and what the next rank does, where it
-- does not apply, the conditions of the next rank still missing, the research team's line on a capstone.
function View:tipRows(id)
    local sim = self.sim
    local node = Data.byId[id]
    local rows = {}
    local tree = node.board and node.group or node.tree
    local tc = TREE[tree]
    local function add(row) rows[#rows + 1] = row end
    if node.board and not Rules.boardOpen(sim) then
        add({ kind = "title", text = self.revealed[node.group] and Texts.nodeName(id) or "???" })
        add({ kind = "para", text = getText("IGUI_OA_Tree_BoardHidden", Rules.capstones(sim), #Data.TREES), c = P.text })
        return rows
    end
    if node.capstone and not Rules.unsealed(sim, node.tree) then
        add({ kind = "title", text = "???", sub = getText("IGUI_OA_Tree_Short_" .. tree), subc = tc.light })
        add({ kind = "para", text = getText("IGUI_OA_Tree_CapstoneHidden"), c = P.text })
        return rows
    end
    local sub = node.board and Texts.treeName(Data.BOARD) or getText("IGUI_OA_Tree_Short_" .. tree)
    if node.capstone then sub = sub .. getText("IGUI_OA_Tree_Sep") .. getText("IGUI_OA_Tree_CapstoneTag") end
    add({ kind = "title", text = Texts.nodeName(id), sub = sub, subc = node.board and GOLD or tc.light })
    local rank = Rules.rank(sim, id)
    local planned = self.counts[id] or 0
    local maxed = Rules.maxed(sim, id)
    local stage
    if node.board then
        stage = getText("IGUI_OA_Tree_StageBoard", rank, Rules.cost(sim, id))
    else
        stage = getText("IGUI_OA_Tree_Stage", rank, node.ranks)
    end
    if planned > 0 then stage = stage .. " " .. getText("IGUI_OA_Tree_StagePlanned", planned) end
    add({ kind = "stage", text = stage, n = (not node.board) and node.ranks or 0, full = rank - planned, planned = planned,
        color = maxed and GOLD or tc.c })
    add({ kind = "sep" })
    -- what every rank taken gives (a later rank's text adds to the earlier ones' or replaces them), and of the next
    -- rank only what it adds or changes
    local now = Texts.lines(node, rank, sim)
    local nextLines = {}
    if not maxed then
        -- the next rank as it would read: on a copy of the plan that takes it
        local after = Plan.add(self.u, self.steps, id)
        local lines
        if after then
            local simAfter = Plan.simulate(self.u, after)
            lines = Texts.lines(node, Rules.rank(simAfter, id), simAfter)
        else
            lines = Texts.lines(node, math.min(rank + 1, node.ranks or rank + 1), sim)
        end
        nextLines = Texts.newLines(now, lines)
    end
    if #now > 0 and #nextLines > 0 then
        for i, one in ipairs(now) do
            add({ kind = "pair", label = i == 1 and getText("IGUI_OA_Tree_NowLabel") or "", text = one })
        end
        for i, one in ipairs(nextLines) do
            add({ kind = "pair", label = i == 1 and getText("IGUI_OA_Tree_NextLabel") or "", lc = P.value, text = one })
        end
    elseif #now > 0 then
        for _, one in ipairs(now) do add({ kind = "para", text = one }) end
    else
        add({ kind = "label", text = getText("IGUI_OA_Tree_Next") })
        for _, one in ipairs(nextLines) do add({ kind = "para", text = one }) end
    end
    local desc = Texts.desc(id)
    if desc then add({ kind = "para", text = desc, c = P.dim }) end
    -- the bite shield as it is now (the record's, not the plan's)
    local bite, armed = Texts.biteStatus(node, self.u, OA.hours())
    if bite then add({ kind = "para", text = bite, c = armed and P.good or P.warn }) end
    if not maxed then
        -- only what is still missing: a condition met is noise
        local sep = false
        for _, c in ipairs(Texts.conditions(sim, node)) do
            if not c.ok then
                if not sep then
                    add({ kind = "sep" })
                    sep = true
                end
                add({ kind = "check", ok = false, text = c.text })
            end
        end
    end
    local note = Texts.note(id)
    if note then
        add({ kind = "sep" })
        add({ kind = "para", text = note, c = NOTE })
    end
    local api = Texts.apiNote(id)
    if api and node.kind == "api" then add({ kind = "para", text = api, c = API }) end
    if self.refusal and self.refusal.id == id then
        add({ kind = "para", text = Texts.reason(self.refusal.why), c = P.bad })
    end
    return rows
end

-- The rows of a button's tooltip, or nil.
function View:buttonTipRows(item)
    if item.kind == "mode" and item.mode == "board" and self.sim and not Rules.boardOpen(self.sim) then
        return { { kind = "title", text = "???" },
            { kind = "para", text = getText("IGUI_OA_Tree_BoardHidden", Rules.capstones(self.sim), #Data.TREES) } }
    end
    if item.kind == "reset" and self.u then
        local rows = { { kind = "title", text = getText("IGUI_OA_Tree_Reset"), sub = Texts.treeName(item.tree),
            subc = TREE[item.tree].light },
            { kind = "para", text = getText("IGUI_OA_Tree_ResetCost", Rules.resetCost(self.u, item.tree)), c = P.text } }
        if #self.steps > 0 then rows[#rows + 1] = { kind = "para", text = getText("IGUI_OA_Tree_ResetBlocked"), c = P.bad } end
        return rows
    end
    return nil
end

-- A node's name and its tooltip as plain text (the in-game checks read it for raw keys and leftover parameters).
function View:tipFor(id)
    local parts = {}
    for _, row in ipairs(self:tipRows(id)) do
        if row.label and row.label ~= "" then parts[#parts + 1] = row.label end
        if row.text then parts[#parts + 1] = row.text end
        if row.sub then parts[#parts + 1] = row.sub end
    end
    return Texts.nodeName(id), table.concat(parts, " ")
end

-- The item the tooltip is about: the one under the mouse, or the gamepad cursor's.
function View:focusItem()
    if self.hover then return self:itemOf(self.hover) end
    if self.joypad and self.cursor then return self:itemOf(self.cursor) end
    return nil
end

function View:hideTip()
    if self.tip and self.tipShown then
        self.tip:setVisible(false)
        self.tip:removeFromUIManager()
        self.tipShown = false
    end
    self.tipKey = nil
end

-- Shows the tooltip beside the focused item: on its right, or on its left where the screen ends; kept on the screen.
function View:updateTip()
    local item = not self:asking() and self:focusItem()
    if not item or not self.sim or not self.body then return self:hideTip() end
    if item.key ~= self.tipKey or self.tipDirty then
        local rows
        if item.id then rows = self:tipRows(item.id) else rows = self:buttonTipRows(item) end
        if not rows then return self:hideTip() end
        if not self.tip then
            self.tip = OAResearchTip:new()
            self.tip:initialise()
            self.tip:instantiate()
        end
        self.tip:setRows(rows)
        self.tipKey, self.tipDirty = item.key, false
        self.tip.description = select(2, self:tipText(rows))
    end
    local tip = self.tip
    if not self.tipShown then
        tip:setVisible(true)
        tip:addToUIManager()
        self.tipShown = true
    end
    tip:bringToTop()
    local bx, by = UI.dp(self.body:getAbsoluteX()), UI.dp(self.body:getAbsoluteY())
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    local x = bx + item.x + item.w + 10
    if x + tip.width > screenW then x = bx + item.x - 10 - tip.width end
    local y = math.max(0, math.min(by + item.y - 4, screenH - tip.height))
    tip:setX(math.max(0, x))
    tip:setY(y)
end

function View:tipText(rows)
    local parts = {}
    for _, row in ipairs(rows) do
        if row.text then parts[#parts + 1] = row.text end
    end
    return nil, table.concat(parts, " ")
end

-- ---- drawing ---------------------------------------------------------------------------------------------------

function View:prerender()
    -- the screen or the font changed under the open tab: the scale and the body again
    if self.era ~= UI.era then self:checkScale() end
    -- the tab sizes its window while it shows, as the game's own tabs do (another tab may have sized it last)
    local parent = self.parent
    if self.width ~= self.wantW or (parent and parent.width ~= self.x + self.wantW) then
        self:setWidthAndParentWidth(self.wantW)
    end
    if self.height ~= self.wantH or (parent and parent.height ~= self.y + self.wantH) then
        self:setHeightAndParentHeight(self.wantH)
    end
    ISPanelJoypad.prerender(self)
end

-- Rank pips centred on (or, align "left", starting at) x, at height y (their middle): `full` in `color`, then
-- `planned` in cyan, then hollow.
function Window.pips(el, x, y, n, full, planned, color, align)
    local d = n <= 3 and 5 or 4.5
    local gap = n <= 3 and 3 or 2.5
    local total = n * d + (n - 1) * gap
    local x0 = align == "left" and x or x - total / 2
    for i = 1, n do
        local cx = x0 + (i - 1) * (d + gap) + d / 2
        if i <= full then
            glyph(el, "Pip", cx, y, d, color)
        elseif i <= full + planned then
            glyph(el, "Pip", cx, y, d, CYAN)
        else
            glyph(el, "Ring", cx, y, d, P.dim, 0.6)
        end
    end
end

-- Where pip i of n centred on x stands (its middle), and its size: as Window.pips lays them.
local function pipAt(x, n, i)
    local d = n <= 3 and 5 or 4.5
    local gap = n <= 3 and 3 or 2.5
    return x - (n * d + (n - 1) * gap) / 2 + (i - 1) * (d + gap) + d / 2, d
end

local function pulse(t)
    return 0.5 + 0.5 * math.sin(2 * math.pi * t / Window.PULSE_S)
end

-- A node that can be taken: its frame's strength at the pulse's low point (the body draws it, still), and how much
-- the pulse adds at its top. The flow draws the frame again over it at the pulse's own strength p: one frame of a
-- colour at PULSE_BASE under one at p shows as one at PULSE_BASE + (1 - PULSE_BASE) * p, the pulse as it was drawn
-- in one piece.
local PULSE_BASE, PULSE_HALO = 0.55, 0.22

-- A button drawn as the terminal's (Trade/Button.lua): normal, strong, or off.
local function button(el, item, label, style, hover)
    local x, y, w, h = item.x, item.y, item.w, item.h
    if style == "off" then
        UI.fill(el, x, y, w, h, P.panel, 0.6)
        UI.frame(el, x, y, w, h, P.border, 0.5)
    elseif style == "strong" then
        UI.fill(el, x, y, w, h, P.sel, hover and 0.42 or 0.30)
        UI.frame(el, x, y, w, h, P.sel, 0.95)
    elseif hover then
        UI.fill(el, x, y, w, h, P.sel, 0.14)
        UI.frame(el, x, y, w, h, P.sel, 0.7)
    else
        UI.fill(el, x, y, w, h, P.panel)
        UI.frame(el, x, y, w, h, P.border)
    end
    if label then
        local fh = UI.fontHeight()
        local c = (style == "off" and P.dim) or (style == "strong" and P.bright) or P.text
        UI.textCentre(el, label, x + w / 2, y + (h - fh) / 2, c, nil, style == "off" and 0.6 or 1)
    end
end

-- A chip at the top right ending at `right`: an item icon (or none), a text with its number in the value colour.
-- Returns its left edge.
local function chip(el, right, y, h, icon, key, value)
    local pre, post = around(key)
    local v = tostring(value)
    local isz = icon and UI.iconSize(20, 22) or 0
    local w = 8 + (icon and isz + 5 or 0) + UI.textWidth(pre) + UI.textWidth(v) + UI.textWidth(post) + 9
    local x = right - w
    UI.fill(el, x, y, w, h, P.panel)
    UI.frame(el, x, y, w, h, P.border)
    local tx = x + 8
    if icon then
        UI.icon(el, itemTexture(icon, X(isz)), tx, y + (h - isz) / 2, isz)
        tx = tx + isz + 5
    end
    local ty = y + (h - UI.fontHeight()) / 2
    UI.text(el, pre, tx, ty, P.dim)
    tx = tx + UI.textWidth(pre)
    UI.text(el, v, tx, ty, P.value)
    tx = tx + UI.textWidth(v)
    UI.text(el, post, tx, ty, P.dim)
    return x
end

local MODE_KEYS = { "mode:trees", "mode:board" }

function View:paintTop(el)
    local hoverKey = self.hover
    for _, key in ipairs(MODE_KEYS) do
        local item = self.byKey[key]
        local on = self.mode == item.mode
        local style = on and "strong" or "normal"
        if key == "mode:trees" then
            button(el, item, UI.str("IGUI_OA_Tree_ModeTrees"), style, hoverKey == key)
        else
            local text, closed = self:boardTabText()
            button(el, item, nil, style, hoverKey == key)
            local fh = UI.fontHeight()
            local tx = item.x + 14
            local ty = item.y + (item.h - fh) / 2
            if closed then
                UI.lock(el, tx, item.y + (item.h - 9 * UI.dot()) / 2, P.dim)
                tx = tx + 14
            end
            UI.text(el, text, tx, ty, on and P.bright or P.text)
            if closed then
                tx = tx + UI.textWidth(text) + 8
                for _, tree in ipairs(Data.TREES) do
                    local cap = Data.capstone(tree)
                    local lit = cap and Rules.rank(self.sim, cap.id) >= 1
                    UI.fill(el, tx, item.y + item.h / 2 - 2.5, 12, 5, lit and TREE[tree].c or P.border, lit and 1 or 0.35)
                    tx = tx + 14
                end
            end
        end
    end
    local y, h = L.PAD + 1, L.TOP - 2
    local right = L.VIEW_W - L.PAD
    right = chip(el, right, y, h, "UpgradeSerumShared", "IGUI_OA_Tree_BadgeShared", Rules.sharedPool(self.sim)) - 6
    if self.mode == "board" and Rules.boardOpen(self.sim) then
        right = chip(el, right, y, h, nil, "IGUI_OA_Tree_BadgeBoard", Rules.boardLeft(self.sim)) - 6
    end
    local planned = self.spentPlan.board
    for _, tree in ipairs(Data.TREES) do planned = planned + self.spentPlan[tree] end
    if planned > 0 then
        local pre, post = around("IGUI_OA_Tree_BadgePlan")
        local v = tostring(planned)
        local w = UI.textWidth(pre) + UI.textWidth(v) + UI.textWidth(post) + 16
        local x = right - w
        UI.fill(el, x, y, w, h, CYAN, 0.14)
        UI.frame(el, x, y, w, h, CYAN, 0.8)
        UI.text(el, pre .. v .. post, x + 8, y + (h - UI.fontHeight()) / 2, CYAN)
    end
end

-- A tree's header strip, three rows: its name and the reset button; the points left and what is kept for the 2nd
-- board; its points as a bar the strip's width (spent in its colour, selected in cyan, still to spend pale, the rows'
-- openings as ticks). Column i: it rises with its column and its bar fills in the opening; its points left hop and the
-- bar's changed segment lights when a click changed them (View.bump).
function View:paintStrip(el, panel, i)
    local tree = panel.tree
    local tc = TREE[tree]
    local dy = RISE[i]
    local x, y = panel.x, panel.y + dy
    UI.fill(el, x, y, panel.w, panel.strip, tc.strip)
    -- a take's light arriving: the strip flashes in the tree's colour
    local take = self.take
    local flash = take and self:takeHeader(tree) or 0
    if flash > 0 then UI.fill(el, x, y, panel.w, panel.strip, tc.c, 0.32 * flash) end
    paintGrit(el, x, y, panel.w, panel.strip)
    UI.fill(el, x, y, panel.w, 2, flash > 0 and tc.light or tc.c)
    UI.text(el, Texts.treeName(tree), x + 10, y + 5, tc.light, UIFont.Medium)
    if self.mode ~= "trees" then return end
    -- the reset
    local item = self.byKey["reset:" .. tree]
    if item and self:reachable(item) then
        local on = self:enabled(item)
        local hover = on and self.hover == item.key
        local iy = item.y + dy
        UI.fill(el, item.x, iy, item.w, item.h, hover and tc.c or P.bg, hover and 0.35 or 0.5)
        UI.frame(el, item.x, iy, item.w, item.h, tc.light, on and 0.6 or 0.25)
        glyph(el, "Reset", item.x + item.w / 2, iy + item.h / 2, item.w - 8, tc.light, on and 0.95 or 0.35)
    end
    -- a click's mark on the points
    local hop, lit, seg = 0, 0, -1
    local bump = self.bump
    if bump and bump.tree == tree then
        local h, l = Motion.bump(NOW - bump.at)
        if h then hop, lit, seg = h, l, bump.seg end
    end
    -- the points left, and what is kept for the 2nd board at the right
    local usable, surplus = Rules.ownSplit(self.sim, tree)
    local left = UI.str("IGUI_OA_Tree_OwnLeft", usable)
    UI.text(el, left, x + 10, y + 27 - hop, usable > 0 and P.value or P.dim)
    if lit > 0 then UI.text(el, left, x + 10, y + 27 - hop, WHITE, nil, 0.8 * lit) end
    if surplus > 0 then
        UI.textRight(el, UI.str("IGUI_OA_Tree_BoardShare", surplus), x + panel.w - 10, y + 27, P.dim)
    end
    local bh = 7
    local bx, by, bw = x + 10, y + panel.strip - bh - 6, panel.w - 20
    UI.fill(el, bx, by, bw, bh, P.inset)
    local total = TREE_POINTS[tree]
    local spent = Rules.treeSpent(self.u, tree)
    local plan = self.spentPlan[tree] or 0
    -- in the opening the bar fills from nothing to what it shows
    local filled = spent + plan + usable
    if OPEN_AGE then filled = filled * Motion.openBar(OPEN_AGE, i) end
    -- a take's points: selected (cyan) until its first light reaches the strip, then the tree's colour, flashing
    local newFrom, newPending = spent, false
    if take then
        newFrom = spent - (take.points[tree] or 0)
        newPending = NOW - take.start < (take.first[tree] or 0)
    end
    local x0, x1 = X(bx), X(bx + bw)
    local y0, y1 = X(by), X(by + bh)
    for k = 0, total - 1 do
        local a, b = segX(x0, x1, k, total), segX(x0, x1, k + 1, total) - 1
        local c, alpha
        if k >= filled then
            c, alpha = P.border, 0.22
        elseif k >= newFrom and k < spent and newPending then
            c, alpha = CYAN, 1
        elseif k < spent then
            c, alpha = tc.c, 1
        elseif k < spent + plan then
            c, alpha = CYAN, 1
        else
            c, alpha = tc.light, 0.35
        end
        rectPx(el, a, y0, b - a, y1 - y0, c, alpha)
        if k == seg then rectPx(el, a, y0 - X(1), b - a, y1 - y0 + 2 * X(1), WHITE, 0.85 * lit) end
        if flash > 0 and k >= newFrom and k < spent then
            rectPx(el, a, y0 - X(1), b - a, y1 - y0 + 2 * X(1), WHITE, 0.8 * flash)
        end
    end
    local tw = math.max(1, floor(S * 0.7 + 0.5))
    for row = 2, Data.ROWS do
        local need = Rules.rowNeed(row)
        if need < total then
            local px = segX(x0, x1, need, total) - 1
            rectPx(el, px, y0 - X(3), tw, y1 - y0 + X(3) + X(1), P.text, 0.75)
        end
    end
end

-- A piece of a line from s0 to s1 along the segment xa, ya - xb, yb (len long, axis-aligned), lw pixels wide.
local function linePiece(el, xa, ya, xb, yb, len, s0, s1, lw, c, a)
    local X1, Y1 = X(xa + (xb - xa) * s0 / len), X(ya + (yb - ya) * s0 / len)
    local X2, Y2 = X(xa + (xb - xa) * s1 / len), X(ya + (yb - ya) * s1 / len)
    local half = floor(lw / 2)
    if X1 == X2 then
        rectPx(el, X1 - half, math.min(Y1, Y2), lw, math.abs(Y2 - Y1), c, a)
    else
        rectPx(el, math.min(X1, X2), Y1 - half, math.abs(X2 - X1), lw, c, a)
    end
end

-- A prerequisite line drawn one way (`mode`): "solid" or "dashes" (flowing with the clock `t`, seconds); a small
-- arrowhead into the node. `dy` moves it down (its column rising); `upto` (design units, nil for all) draws only its
-- start, the arrowhead once it is all there.
local function drawLine(el, line, mode, c, a, t, dy, upto)
    dy = dy or 0
    local lw = math.max(2, floor(1.5 * S + 0.5))
    local pts = line.points
    -- the arrowhead's height in pixels; the line stops where it starts
    local k = math.max(3, floor(3 * S + 0.5))
    local tip = k / S
    local period = Window.DASH + Window.DASH_GAP
    local phase = mode == "dashes" and remainder(t * Window.FLOW, period) or 0
    local dist = 0
    for i = 1, #pts - 1 do
        local xa, ya = pts[i][1], pts[i][2] + dy
        local xb, yb = pts[i + 1][1], pts[i + 1][2] + dy
        if i == #pts - 1 then yb = yb - tip end
        local len = math.abs(xb - xa) + math.abs(yb - ya)
        local room = upto and math.min(len, upto - dist) or len
        if upto and room <= 0 then return end
        if len > 0 then
            if mode == "solid" then
                linePiece(el, xa, ya, xb, yb, len, 0, room, lw, c, a)
            else
                local s0 = -remainder(dist - phase, period)
                while s0 < room do
                    local a0, a1 = math.max(0, s0), math.min(room, s0 + Window.DASH)
                    if a1 > a0 then linePiece(el, xa, ya, xb, yb, len, a0, a1, lw, c, a) end
                    s0 = s0 + period
                end
            end
        end
        dist = dist + len
    end
    if upto and upto < dist then return end
    -- the arrowhead, rows of whole pixels
    local cx, top = X(pts[#pts][1]), X(pts[#pts][2] + dy) - k
    for i = 0, k - 1 do
        local w = 2 * (k - i) - 1
        rectPx(el, cx - floor(w / 2), top + i, w, 1, c, a)
    end
end

-- The soft round light (tools/glow_art.py), found once.
local glowTex = nil
local function glow()
    if glowTex == nil then glowTex = getTexture("media/textures/OA_Glow.png") or false end
    return glowTex or nil
end

-- The glow centred on design point x, y, `px` pixels across, tinted.
local function glowAt(el, tex, x, y, px, c, a)
    if a < GLOW_INVISIBLE then return end
    px = math.max(2, floor(px + 0.5))
    texPx(el, tex, X(x) - floor(px / 2), X(y) - floor(px / 2), px, px, c, math.min(1, a))
end

-- The design point `at` design units along a line (from its start; held at its ends), moved down by dy.
local function pointOn(line, at, dy)
    local pts = line.points
    local dist = 0
    for i = 1, #pts - 1 do
        local xa, ya, xb, yb = pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2]
        local len = math.abs(xb - xa) + math.abs(yb - ya)
        if at <= dist + len and len > 0 then
            local f = math.max(0, at - dist) / len
            return xa + (xb - xa) * f, ya + (yb - ya) * f + dy
        end
        dist = dist + len
    end
    local last = pts[#pts]
    return last[1], last[2] + dy
end

-- The pieces of a line between `s0` and `s1` (design units along it, clipped to it), lw pixels wide.
local function lineSpan(el, line, s0, s1, dy, lw, c, a)
    if a < INVISIBLE then return end
    local pts = line.points
    local dist = 0
    for i = 1, #pts - 1 do
        local xa, ya, xb, yb = pts[i][1], pts[i][2] + dy, pts[i + 1][1], pts[i + 1][2] + dy
        local len = math.abs(xb - xa) + math.abs(yb - ya)
        local a0, a1 = math.max(0, s0 - dist), math.min(len, s1 - dist)
        if a1 > a0 then linePiece(el, xa, ya, xb, yb, len, a0, a1, lw, c, a) end
        dist = dist + len
        if dist >= s1 then return end
    end
end

-- A lit line's light (Motion.comet), `a` times its strength: behind the head the line brightened where it has passed
-- (fading), the tail's steps fainter and its soft lights smaller the further back, the head a round glow with a
-- bright core; arriving, a soft light on the arrowhead and on the node's frame (fainter into a locked node).
local function drawComet(el, line, dy, a)
    local head, strength, tail, after, arrive = Motion.comet(CLOCK, line.index, line.len)
    if not head then return end
    local tex = glow()
    local tc = TREE[line.tree]
    local lw = math.max(2, floor(1.5 * S + 0.5))
    local len = line.len - math.max(3, floor(3 * S + 0.5)) / S       -- the line's drawn part, up to the arrowhead
    strength = strength * a
    for i = 0, 2 do
        lineSpan(el, line, head - after * (i + 1) / 3, math.min(len, head - after * i / 3), dy, lw, tc.light,
            0.22 * (1 - i / 3) * a)
    end
    local n = Motion.COMET_STEPS
    for i = 0, n - 1 do
        local f = 1 - i / n
        lineSpan(el, line, head - tail * (i + 1) / n, math.min(len, head - tail * i / n), dy, lw, tc.light,
            strength * f * f * 0.7)
    end
    if tex then
        for i = 1, n do
            local back = head - tail * i / n
            if back >= 0 and back <= len then
                local f = 1 - i / (n + 1)
                local x, y = pointOn(line, back, dy)
                glowAt(el, tex, x, y, lw * Motion.COMET_HEAD * (0.35 + 0.55 * f), tc.light, strength * f * f * 0.55)
            end
        end
        if head <= len then
            local x, y = pointOn(line, head, dy)
            glowAt(el, tex, x, y, lw * Motion.COMET_HEAD, tc.light, strength * 0.85)
            glowAt(el, tex, x, y, lw * Motion.COMET_CORE, tc.core, strength)
        end
    end
    if arrive > 0 then
        local k = arrive * a * (line.targetLocked and Motion.COMET_LOCKED or 1)
        local ex, ey = pointOn(line, line.len, dy)
        if tex then glowAt(el, tex, ex, ey, lw * Motion.COMET_ARRIVE, tc.light, 0.7 * k) end
        local item = line.target
        if item then framePx(el, item.x, item.y + dy, item.w, item.h, tc.light, 0.8 * k, 2, 2) end
    end
end

-- How much of a line shows in the opening: nil for all of it, else the design units drawn (0: none yet).
local function lineUpto(line)
    if not OPEN_AGE then return nil end
    local share = Motion.openLine(OPEN_AGE, line.col, line.row)
    if share >= 1 then return nil end
    return share * line.len
end

-- A prerequisite line as the body draws it: lit in the tree's colour, or dim. A line only the selection meets is the
-- flow's (its cyan dashes move: View:paintFlow), as are the lit lines' lights. In the opening it draws itself down.
function View:paintLine(el, line)
    if line.state == "plan" or line.state == "hidden" then return end
    local upto = lineUpto(line)
    if upto == 0 then return end
    local dy = RISE[line.col]
    if line.state == "lit" then
        drawLine(el, line, "solid", TREE[line.tree].c, 0.95, 0, dy, upto)
    else
        drawLine(el, line, "solid", LINE_DIM, 1, 0, dy, upto)
    end
end

-- The padlock of a locked node, in a dark disc at its bottom right (`a`: how much of it shows, as it comes off).
local function lockBadge(el, x, y, s, a)
    a = a or 1
    local r = 7.5
    local cx, cy = x + s - r + 1, y + s - r + 1
    glyph(el, "Pip", cx, cy, 2 * r, DARK, 0.92 * a)
    local u = UI.dot()
    UI.lock(el, cx - 4 * u, cy - 4.5 * u, P.text, 0.9 * a)
end

-- The cyan "+n" of selected ranks at a node's top right.
local function plusChip(el, x, y, n)
    local s = "+" .. n
    local fh = UI.fontHeight()
    local w = UI.textWidth(s) + 8
    local cx, cy = x - w + 5, y - 7
    UI.fill(el, cx, cy, w, fh, CYAN)
    UI.textCentre(el, s, cx + w / 2, cy, PLUS_TEXT)
end

-- One node: its icon (grey while it cannot be taken) with no well around it, a frame for its state, its ranks as pips
-- (a number on the endless board). It rises with its column and pops in with its row in the opening; a click's
-- answer moves or scales it (not its pips), floats a +1 or -1 up from it and flashes the pip that changed; a take
-- keeps its selection on it until the scan reaches it, then pops it and settles its ranks into pips; the mouse lights
-- it; a padlock coming off fades with the grey, flashes the frame
-- in the tree's colour and sends a ring out.
function View:paintNode(el, item)
    local node = Data.byId[item.id]
    local n = self.nodes[item.id]
    if not n then return end
    local grow, shown = 1, 1
    if OPEN_AGE then
        grow, shown = Motion.openNode(OPEN_AGE, item.col, item.row)
        if shown <= 0 then return end
    end
    -- where it stands (its pips stay there), and where it is drawn
    local bx, by, bs = item.x, item.y + RISE[item.col], item.w
    local x, y, s = bx, by, bs
    local ring, ringA, ringW
    local f = self.fx and self.fx[item.id]
    local age = f and NOW - f.start
    if f then
        if f.kind == "shake" then
            x = x + Motion.shake(age)
        else
            grow = grow * (f.kind == "pop" and Motion.pop(age) or Motion.shrink(age))
            -- the ripple goes on in film steps (the click's own grow stays smooth: it answers the hand)
            if f.kind == "pop" then ring, ringA, ringW = Motion.ripple(film(age)) end
        end
    end
    -- a take: the ranks it took show selected until the scan reaches the node (takeAge < 0)
    local take = self.take
    local place = take and take.index[item.id]
    local takeAge = place and NOW - take.start - (place - 1) * take.step
    if takeAge then grow = grow * Plan.takePop(takeAge) end
    -- the light under the mouse (only the lit place asks the clock)
    local hover = 0
    local lights = el.fx
    if lights then
        local cur, fade = lights.cur, lights.fade
        if (cur and cur.place == item.id) or (fade and fade.place == item.id) then
            hover = UI.placeLevels(el, item.id)
        end
    end
    grow = grow * (1 + Motion.HOVER_GROW * hover)
    if grow ~= 1 then x, y, s = x - s * (grow - 1) / 2, y - s * (grow - 1) / 2, s * grow end
    local tree = item.tree
    local tc = TREE[tree].c
    local th = thick()
    local out = 2
    if n.hidden then
        -- a sealed capstone: a question mark on a capstone's badge, grey and locked as a node not yet open
        local ipx = iconPx(item.w)
        if s ~= item.w then ipx = floor(ipx * s / item.w + 0.5) end
        local ix, iy = X(x + s / 2) - floor(ipx / 2), X(y + s / 2) - floor(ipx / 2)
        texPx(el, getTexture(Data.SEALED_ICON[tree]), ix, iy, ipx, ipx, nil, 0.8)
        if hover > 0 then UI.fill(el, x, y, s, s, WHITE, Motion.HOVER_LIGHT * hover) end
        framePx(el, x, y, s, s, P.border, 0.45, 1, out)
        lockBadge(el, x, y, s)
        if shown < 1 then UI.fill(el, x - 4, y - 4, s + 8, s + 8, TREE[tree].body, 1 - shown) end
        return
    end
    local state = n.state
    local grey = greyed(n)
    local full, planned = n.full, n.planned
    local gained = takeAge and take.gained[item.id] or 0
    if takeAge and takeAge < 0 then
        state, grey, full, planned = "planned", false, full - gained, gained
    end
    -- a padlock coming off (or waiting to: drawn locked meanwhile)
    local lockA, flashA, unlockRing = 0, 0, 0
    local opening = not grey and self.unlocks and self.unlocks[item.id]
    local openStep = 0
    if opening then
        openStep = filmStep(NOW - opening)
        lockA, flashA, unlockRing = Motion.unlock(film(NOW - opening))
        if not lockA then
            lockA, flashA, unlockRing = 0, 0, 0
        elseif lockA >= 1 then
            grey, state, lockA = true, "locked", 0
        end
    end
    -- the icon at its whole pixel size (only a motion scales it a moment)
    local ipx = iconPx(item.w)
    if s ~= item.w then ipx = floor(ipx * s / item.w + 0.5) end
    local ix, iy = X(x + s / 2) - floor(ipx / 2), X(y + s / 2) - floor(ipx / 2)
    texPx(el, getTexture((grey and node.iconGray) or node.icon), ix, iy, ipx, ipx, nil, grey and 0.8 or 1)
    if lockA > 0 then texPx(el, getTexture(node.iconGray), ix, iy, ipx, ipx, nil, 0.8 * lockA) end
    if hover > 0 then UI.fill(el, x, y, s, s, WHITE, Motion.HOVER_LIGHT * hover) end
    if n.treeLocked then
        framePx(el, x, y, s, s, P.border, 0.45, 1, out)
    elseif state == "avail" then
        -- the pulse's low point; the flow lays the rest of the pulse over it (View:paintFlow)
        framePx(el, x, y, s, s, tc, PULSE_BASE, th, out)
    elseif state == "maxed" then
        framePx(el, x, y, s, s, GOLD, 1, th, out)
    elseif state == "planned" then
        dashedPx(el, x, y, s, s, CYAN, 1, th, out)
        plusChip(el, x + s + out, y - out, planned)
    elseif state == "owned" then
        framePx(el, x, y, s, s, tc, 0.45, th, out)
    else
        framePx(el, x, y, s, s, P.border, 0.45, 1, out)
    end
    if grey then lockBadge(el, x, y, s) end
    if lockA > 0 then lockBadge(el, x, y, s, lockA) end
    -- the unlock and the ripple are rough: a burst of static over the node, frames in broken pieces that change with
    -- each film step (the seed: the node's place and the step)
    local seed = (item.col or 0) * 1000 + (item.row or 0) * 37
    if flashA > 0 then
        local light = TREE[tree].light
        UI.fill(el, x, y, s, s, light, 0.22 * flashA)
        staticBurst(el, x, y, s, s, light, 0.85 * flashA, openStep)
        roughFramePx(el, x, y, s, s, light, flashA, th + 1, out, seed + openStep)
        roughFramePx(el, x, y, s, s, light, 0.6 * flashA, th, out + th / S + 1 + unlockRing, seed + openStep * 7 + 3)
    end
    if f and f.kind == "shrink" then
        -- a rank taken back: the node's print flickers out a moment
        local step = filmStep(age)
        if step < 3 then
            staticBurst(el, x, y, s, s, P.dim, 0.5 * (1 - step / 3), step)
            roughFramePx(el, x, y, s, s, P.dim, 0.7 * (1 - step / 3), th, out, seed + step)
        end
    end
    if ring then
        local step = filmStep(age)
        if step < 3 then staticBurst(el, x, y, s, s, CYAN, 0.55 * (1 - step / 3), step) end
        roughFramePx(el, x, y, s, s, CYAN, ringA, math.max(1, floor(ringW * S + 0.5)), out + th / S + 1 + ring,
            seed + step)
    end
    if n.api and not grey then
        local fh = UI.fontHeight()
        UI.fill(el, x - 1, y - 1, 12, fh, { 0.35, 0.15, 0.05 }, 0.95)
        UI.textCentre(el, "!", x + 5, y - 1, API)
    end
    if node.board then
        if Rules.boardOpen(self.sim) then
            local base = tostring(full)
            if planned > 0 then
                local more = " +" .. planned
                local w = UI.textWidth(base) + UI.textWidth(more)
                local tx = bx + (bs - w) / 2
                UI.text(el, base, tx, by + bs + 1, P.text)
                UI.text(el, more, tx + UI.textWidth(base), by + bs + 1, CYAN)
            else
                UI.textCentre(el, base, bx + bs / 2, by + bs + 1, n.rank > 0 and P.text or P.dim)
            end
        end
    elseif not n.treeLocked then
        Window.pips(el, bx + bs / 2, by + bs + 6.5, node.ranks, full, planned, state == "maxed" and GOLD or tc)
        -- the ranks a take gave settle: their pips flash as they turn solid
        local k = takeAge and Plan.takePip(takeAge)
        if k then
            for p = math.max(1, full - gained + 1), math.min(node.ranks, full) do
                local cx, d = pipAt(bx + bs / 2, node.ranks, p)
                glyph(el, "Pip", cx, by + bs + 6.5, d * (1 + 0.5 * k), WHITE, k)
            end
        end
        -- the pip a click changed flashes
        if f and f.pip and f.pip >= 1 and f.pip <= node.ranks then
            local k, pa = Motion.pipFlash(age)
            if k then
                local cx, d = pipAt(bx + bs / 2, node.ranks, f.pip)
                glyph(el, "Pip", cx, by + bs + 6.5, d * k, f.kind == "pop" and CYAN or WHITE, pa)
            end
        end
    end
    if hover > 0 then framePx(el, x, y, s, s, WHITE, hover, 1, out + th / S + 1) end
    -- a click's +1 or -1 floating up
    if f and f.kind ~= "shake" then
        local rise, fa = Motion.float(age)
        if rise then
            local up = f.kind == "pop"
            UI.textCentre(el, up and "+1" or "-1", bx + bs / 2, by - UI.fontHeight() - 2 - rise, up and CYAN or P.dim,
                UIFont.Medium, fa)
        end
    end
    -- the opening: the node fades in over its column
    if shown < 1 then
        local x0, y0 = math.min(x, bx) - 4, math.min(y, by) - 8
        UI.fill(el, x0, y0, math.max(s, bs) + 8, by + bs + L.PIPS + 2 - y0, TREE[tree].body, 1 - shown)
    end
end

-- The bottom bar: what approving the selection spends (only the trees with something selected), or how to select;
-- the clear and approve buttons.
function View:paintPlanBar(el)
    local x, y, w, h = L.PAD, L.PLAN_Y, L.VIEW_W - 2 * L.PAD, L.PLAN
    local has = #self.steps > 0
    UI.fill(el, x, y, w, h, P.panel)
    paintGrit(el, x, y, w, h)
    UI.frame(el, x, y, w, h, has and CYAN or P.border, has and 0.55 or 1)
    if has then UI.fill(el, x, y, 3, h, CYAN) end
    local fh = UI.fontHeight()
    local ty = y + (h - fh) / 2
    if has then
        -- what the selection spends, as text parts: made again only when the selection's spending is
        local parts = self.planParts
        if self.planPartsFor ~= self.spentPlan then
            parts = {}
            for _, tree in ipairs(Data.TREES) do
                local n = self.spentPlan[tree] or 0
                if n > 0 then
                    parts[#parts + 1] = { getText("IGUI_OA_Tree_PlanPart", getText("IGUI_OA_Tree_Short_" .. tree), n), TREE[tree].light }
                end
            end
            if (self.spentPlan.board or 0) > 0 then
                parts[#parts + 1] = { getText("IGUI_OA_Tree_PlanPart", Texts.treeName(Data.BOARD), self.spentPlan.board), GOLD }
            end
            self.planParts, self.planPartsFor = parts, self.spentPlan
        end
        local pre, post = around("IGUI_OA_Tree_PlanUses")
        local sep = UI.str("IGUI_OA_Tree_Sep")
        local tx = x + 14
        UI.text(el, pre, tx, ty, P.text)
        tx = tx + UI.textWidth(pre)
        for i, part in ipairs(parts) do
            if i > 1 then
                UI.text(el, sep, tx, ty, P.dim)
                tx = tx + UI.textWidth(sep)
            end
            UI.text(el, part[1], tx, ty, part[2])
            tx = tx + UI.textWidth(part[1])
        end
        UI.text(el, post, tx, ty, P.text)
    else
        local hint = UI.str(self.joypad and "IGUI_OA_Tree_PadHint" or "IGUI_OA_Tree_Hint")
        local room = self.byKey.clear.x - x - 24
        UI.text(el, UI.fitMemo(hint, room), x + 14, ty, P.dim)
    end
    local clear, approve = self.byKey.clear, self.byKey.approve
    button(el, clear, UI.str("IGUI_OA_Tree_ClearPlan"), has and "normal" or "off", has and self.hover == "clear")
    button(el, approve, UI.str("IGUI_OA_Tree_Approve"), has and "strong" or "off", has and self.hover == "approve")
end

-- The 2nd board while closed: what opens it, the three capstones with the approved ones lit.
local BANNER_BG = { 0.02, 0.02, 0.02 }

function View:paintBoardBanner(el)
    local bw, bh = 520, 92
    local bx, by = (L.VIEW_W - bw) / 2, L.COL_Y + L.STRIP + L.GRID_H - bh - 16   -- low in the columns, inside them
    UI.fill(el, bx, by, bw, bh, BANNER_BG, 0.92)
    UI.frame(el, bx, by, bw, bh, P.border)
    UI.lock(el, bx + 16, by + 16, P.value)
    UI.text(el, "???", bx + 40, by + 10, P.value, UIFont.Medium)
    local text = UI.str("IGUI_OA_Tree_BoardHidden", Rules.capstones(self.sim), #Data.TREES)
    UI.text(el, UI.fitMemo(text, bw - 56), bx + 40, by + 36, P.text)
    local segW = (bw - 56 - 16) / 3
    for i, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        local lit = Rules.rank(self.sim, cap.id) >= 1
        local sx = bx + 40 + (i - 1) * (segW + 8)
        UI.fill(el, sx, by + 60, segW, 6, lit and TREE[tree].c or P.border, lit and 1 or 0.35)
        UI.text(el, UI.fitMemo(Texts.nodeName(cap.id), segW), sx, by + 68, lit and TREE[tree].light or P.dim)
    end
end

-- ---- the columns' background --------------------------------------------------------------------------------------
-- Under a column's grid: a faint light falling from its header in the tree's light colour (BG_LIGHT_A at the top, gone
-- BG_LIGHT_END of the way down), a vignette darkening its sides (BG_SIDE_W design units in) and its bottom
-- (BG_BOTTOM of the grid), at most BG_VIGNETTE_A, and the grit (paintGrit). Light and vignette are thin bands of plain
-- fills, their strengths worked out once; it is all still, drawn with the body. The tab is Ashdown's research plan, a
-- field document: kept dim and worn, the trees' colours only a cast on it.
Window.BG_LIGHT_A, Window.BG_LIGHT_END = 0.06, 0.4
Window.BG_VIGNETTE_A, Window.BG_SIDE_W, Window.BG_BOTTOM = 0.55, 26, 0.45
local BG_BANDS, BG_SIDES = 10, 5
local LIGHT_K, BOTTOM_K, SIDE_K = {}, {}, {}
for k = 1, BG_BANDS do
    local v = (k - 0.5) / BG_BANDS
    LIGHT_K[k] = (1 - v * v * (3 - 2 * v)) ^ 1.6
    BOTTOM_K[k] = v ^ 1.6
end
for j = 1, BG_SIDES do
    local v = 1 - (j - 0.5) / BG_SIDES
    SIDE_K[j] = 0.75 * v * v
end

-- A column's background over its grid (its body already filled), `dy` design units down.
local function paintColumnBack(el, panel, dy, tc)
    local x0, x1 = X(panel.x), X(panel.x + panel.w)
    local top, bottom = panel.gy + dy, panel.gy + dy + panel.gridH
    local lh = panel.gridH * Window.BG_LIGHT_END
    local bh = panel.gridH * Window.BG_BOTTOM
    local vig = Window.BG_VIGNETTE_A
    for k = 1, BG_BANDS do
        local ya, yb = X(top + lh * (k - 1) / BG_BANDS), X(top + lh * k / BG_BANDS)
        rectPx(el, x0, ya, x1 - x0, yb - ya, tc.light, Window.BG_LIGHT_A * LIGHT_K[k])
        ya, yb = X(bottom - bh + bh * (k - 1) / BG_BANDS), X(bottom - bh + bh * k / BG_BANDS)
        rectPx(el, x0, ya, x1 - x0, yb - ya, DARK, vig * BOTTOM_K[k])
    end
    local y0, y1 = X(top), X(bottom)
    local sw = Window.BG_SIDE_W
    for j = 1, BG_SIDES do
        local a = vig * SIDE_K[j]
        local xa, xb = X(panel.x + sw * (j - 1) / BG_SIDES), X(panel.x + sw * j / BG_SIDES)
        rectPx(el, xa, y0, xb - xa, y1 - y0, DARK, a)
        xa, xb = X(panel.x + panel.w - sw * j / BG_SIDES), X(panel.x + panel.w - sw * (j - 1) / BG_SIDES)
        rectPx(el, xa, y0, xb - xa, y1 - y0, DARK, a)
    end
    paintGrit(el, panel.x, top, panel.w, panel.gridH)
    -- a band's trays, one under each kind of its nodes: sunk a little, rimmed faintly in the tree's light
    local trays = panel.trays
    if trays then
        for _, t in ipairs(trays) do
            local tx0, ty0 = X(t.x), X(t.y + dy)
            local tw, th = X(t.x + t.w) - tx0, X(t.y + dy + t.h) - ty0
            rectPx(el, tx0, ty0, tw, th, DARK, 0.28)
            rectPx(el, tx0, ty0, tw, 1, DARK, 0.35)
            framePx(el, t.x, t.y + dy, t.w, t.h, tc.light, 0.14, 1)
        end
    end
end

-- Sets what the parts of a frame share at `now` (OPEN_AGE, RISE, SHOWN): the opening (or the switch to the board, at
-- its pace).
function View:frameState(now)
    local age = nil
    if self.openAt then
        age = (now - self.openAt) / (self.openPace or 1)
        if age >= Motion.openEnd(#self.panels, Data.ROWS) then age = nil end
    end
    OPEN_AGE = age
    for i = 1, #self.panels do
        local rise, shown = 0, 1
        if age then rise, shown = Motion.openColumn(age, i) end
        RISE[i], SHOWN[i] = rise, shown
    end
end

-- The opening's veil over each column still coming in: the tab's background, thinning as the column shows.
function View:paintCovers(el)
    for i, panel in ipairs(self.panels) do
        local hidden = 1 - SHOWN[i]
        if hidden > 0 then UI.fill(el, panel.x, panel.y + RISE[i], panel.w, panel.strip + panel.gridH, P.bg, hidden) end
    end
end

function View:paint(el)
    S = UI.S
    UI.fill(el, 0, 0, L.VIEW_W, L.VIEW_H, P.bg)           -- opaque: nothing behind shows through
    paintGrit(el, 0, 0, L.VIEW_W, L.VIEW_H)
    if not self.sim then
        UI.textCentre(el, UI.str("IGUI_OA_Tree_NoRecord"), L.VIEW_W / 2, L.VIEW_H / 2, P.text)
        return
    end
    -- the clock for the motions (kept here, not on the tab: a write to the tab each frame would have PZ Optimization
    -- draw it afresh each frame)
    local now = getTimestampMs()
    NOW, CLOCK = now, now - self.t0
    self:frameState(now)
    for i, panel in ipairs(self.panels) do
        UI.fill(el, panel.x, panel.y + RISE[i], panel.w, panel.strip + panel.gridH, TREE[panel.tree].body)
        paintColumnBack(el, panel, RISE[i], TREE[panel.tree])
        self:paintStrip(el, panel, i)
    end
    for _, line in ipairs(self.lines) do self:paintLine(el, line) end
    for _, item in ipairs(self.items) do
        if item.id then self:paintNode(el, item) end
    end
    local fh = UI.fontHeight()
    for p, panel in ipairs(self.panels) do
        local dy = RISE[p]
        -- a tree not opened yet: dark, with why
        if self.mode == "trees" and not Rules.treeOpen(self.u, panel.tree) then
            UI.fill(el, panel.gx, panel.gy + dy, panel.w, panel.gridH, BLACK, 0.6)
            local lines = UI.wrapMemo(UI.str("IGUI_OA_Tree_TreeClosed"), panel.w - 2 * L.GRID_PAD)
            local ty = panel.gy + dy + (panel.gridH - #lines * fh) / 2
            for i, line in ipairs(lines) do
                UI.textCentre(el, line, panel.gx + panel.w / 2, ty + (i - 1) * fh, CLOSED_TEXT)
            end
        end
        UI.frame(el, panel.x, panel.y + dy, panel.w, panel.strip + panel.gridH, P.border)
        chipFrame(el, panel.x, panel.y + dy, panel.w, panel.strip + panel.gridH, p)
    end
    if self.mode == "board" and not Rules.boardOpen(self.sim) then self:paintBoardBanner(el) end
    if OPEN_AGE then self:paintCovers(el) end
    self:paintTop(el)
    self:paintPlanBar(el)
    if self.take then self:drawTake(el) end
    -- the gamepad cursor on a button
    if self.joypad and self.cursor then
        local item = self.byKey[self.cursor]
        if item and not item.id then framePx(el, item.x, item.y, item.w, item.h, WHITE, 1, 2, 2) end
    end
    self:updateTip()
end

-- ---- motion ----------------------------------------------------------------------------------------------------
-- What moves by the clock is kept on the tab: `fx` (a click's answer by node id: its kind, start and length, the pip
-- it changed), `bump` (the tree whose points a click changed, the bar's segment, when), `unlocks` (by node id, when
-- its padlock starts to come off) with the span they cover (unlockFrom, unlockEnd), `openAt` and `openPace` (when the
-- tab came on the screen or switched, at what pace), and `flowing` (workOut: a pulse, dashes or a line's light to
-- show). The light under the mouse is Trade/UI's, on the body (View:lightFocus).

-- Follows the body each frame (View.tick) while a motion plays, and the flow (View.flowTick) while anything moves by
-- itself; a frame function already there is replaced, not added, so this is called whenever something may have
-- started.
function View:animate()
    if self.body then UI.live(self.body, View.tick) end
    if self.flow and self.lighting then UI.live(self.flow, View.flowTick) end
    if self.pulse and self.pulsingOn then UI.live(self.pulse, View.pulseTick) end
end

-- A node's answer to a click (Motion): "pop" (a rank raised), "shrink" (one taken back) or "shake" (refused).
function View:startFx(id, kind)
    local fx = self.fx or {}
    self.fx = fx
    fx[id] = { kind = kind, start = getTimestampMs(), ms = Motion.fxMs(kind) }
    self:animate()
end

-- A node's padlock comes off at `start` (ms); until then it is drawn locked, whatever its state.
function View:addUnlock(id, start)
    local unlocks = self.unlocks or {}
    self.unlocks = unlocks
    unlocks[id] = start
    self.unlockFrom = math.min(self.unlockFrom or start, start)
    self.unlockEnd = math.max(self.unlockEnd or 0, start + Motion.UNLOCK_MS)
end

-- The nodes locked in `before` (the nodes' states before a change) that are not any more lose their padlocks from
-- `start` (ms).
function View:unlockSince(before, start)
    if not before or before == self.nodes then return end
    local any = false
    for id, n in pairs(self.nodes) do
        local was = before[id]
        if was and greyed(was) and not greyed(n) then
            self:addUnlock(id, start)
            any = true
        end
    end
    if any then self:animate() end
end

-- The nodes on the screen that the record alone (no selection) shows locked: the approval of a selection that opens
-- some of them takes their padlocks off once its take is over.
function View:lockedOnRecord()
    local locked = {}
    if not self.u then return locked end
    for id, n in pairs(self:nodeStates(self.u, {})) do
        if greyed(n) then locked[id] = true end
    end
    return locked
end

-- The tab came on the screen (or switched between the trees and the board, at `pace`, a share of the time): its
-- columns come up (Motion.open*). Only the drawing; a click works at once.
function View:startOpen(pace)
    self.openAt, self.openPace = getTimestampMs(), pace or 1
    self:animate()
end

-- Each frame while the tab shows, before the UI draws (Trade/UI live): one number for PZ Optimization that changes
-- exactly when the body's drawing does. The tab's clock while a motion plays (a click's answer and its marks, the
-- light under the mouse, a padlock coming off, the opening, a take), a constant while a padlock waits for its time,
-- nil when none plays (the body is let go, whatever the flow
-- does; the next change registers it again). Motions that are over are dropped here, so that the frame drawn next is
-- without them.
function View.tick(body, now)
    local view = body.view
    if view.body ~= body then return nil end           -- a body made again for a new scale
    local moving = UI.fxFrame(body, now) ~= nil
    local look
    local take = view.take
    if take then
        if now - take.start < take.ends then moving = true else view.take = nil end
    end
    local fx = view.fx
    if fx then
        local any = false
        for _, f in pairs(fx) do
            if now - f.start < f.ms then any = true end
        end
        if any then moving = true else view.fx = nil end
    end
    local bump = view.bump
    if bump then
        if now - bump.at < Motion.BUMP_MS then moving = true else view.bump = nil end
    end
    if view.unlockEnd then
        if now >= view.unlockEnd then
            view.unlocks, view.unlockFrom, view.unlockEnd = nil, nil, nil
        elseif now >= view.unlockFrom then
            moving = true
        else
            look = look or -2
        end
    end
    if view.openAt then
        local ends = Motion.openEnd(#view.panels, Data.ROWS) * (view.openPace or 1)
        if now - view.openAt < ends then moving = true else view.openAt = nil end
    end
    if moving then return now - view.t0 end
    return look
end

-- Each frame for the flow (Trade/UI live): the tab's clock while anything moves by itself, a constant while a take
-- plays (the flow holds still: the take draws its own lights), nil when nothing moves (let go; workOut's next change
-- registers it).
function View.flowTick(flow, now)
    local view = flow.view
    if view.flow ~= flow or not view.lighting then return nil end
    if view.take then return -1 end
    return now - view.t0
end

-- Each frame for the pulse panel (Trade/UI live): a number that changes exactly when its drawing does. The pulse is
-- drawn in PULSE_LEVELS steps, so it moves on a step at a time, not on each frame (what is between steps
-- is replayed, not drawn); with it, which nodes wait (a click's answer, a padlock, the opening) and the light of the
-- node under the mouse. In the opening, where the columns rise, each frame. -1 while a take plays, nil when no node
-- pulses (let go; workOut's next change registers it).
function View.pulseTick(panel, now)
    local view = panel.view
    if view.pulse ~= panel or not view.pulsingOn then return nil end
    if view.take then return -1 end
    local level = floor(pulse((now - view.t0) / 1000) * Window.PULSE_LEVELS + 0.5)
    view.pulseLevel = level
    view:frameState(now)
    if OPEN_AGE then return now - view.t0 end
    -- (the nodes held back, told apart by their numbers in the list)
    local held = 0
    local items = view.pulsing
    for i = 1, #items do
        if view:pulseHeld(items[i], now) then held = remainder(held * 31 + i, 1000003) end
    end
    local focus = view.hover or (view.joypad and view.cursor)
    local light = 0
    local item = focus and view.byKey[focus]
    if item and item.id then light = floor(UI.placeLevels(view.body, item.id) * 32 + 0.5) end
    return (held * 64 + light) * 64 + level
end

-- Whether a node's pulse waits: a click's answer moves the node (the body draws its frame then), its padlock has not
-- come off yet, or it has not popped in with the opening.
function View:pulseHeld(item, now)
    local id = item.id
    local f = self.fx and self.fx[id]
    if f and now - f.start < f.ms then return true end
    local at = self.unlocks and self.unlocks[id]
    if at ~= nil and now < at then return true end
    if OPEN_AGE then
        local _, shown = Motion.openNode(OPEN_AGE, item.col, item.row)
        return shown < 1
    end
    return false
end

-- The flow's frame: the cyan dashes of the lines only the selection meets, the lights running down the lit lines. It
-- walks only the lists workOut made and makes nothing. Nothing while a take plays; in the opening the dashes draw
-- themselves down with the lines, and the lights wait for the end.
local function flowLines(self, el, t)
    for _, line in ipairs(self.planLines) do
        local upto = lineUpto(line)
        if upto ~= 0 then drawLine(el, line, "dashes", CYAN, SHOWN[line.col], t, RISE[line.col], upto) end
    end
    if not OPEN_AGE then
        for _, line in ipairs(self.litLines) do drawComet(el, line, RISE[line.col], 1) end
    end
end

function View:paintFlow(el)
    if not self.sim or self.take or not self.lighting then return end
    S = UI.S
    local now = getTimestampMs()
    NOW, CLOCK = now, now - self.t0
    self:frameState(now)
    -- (the batch of rectangles is ended whatever happens in the frame)
    beginRects(el)
    local ok, err = pcall(flowLines, self, el, CLOCK / 1000)
    endRects()
    if not ok then error(err, 0) end
end

-- The pulse panel's frame: the pulse of the nodes that can be taken (the body has drawn their frames at the pulse's
-- low point), at the step View.pulseTick found; the light frame of the node under the mouse stays over the halo, as
-- the body drew it. In the opening the pulses wait for their nodes.
local function pulseFrames(self, el, now)
    local steps = Window.PULSE_LEVELS
    local p = (self.pulseLevel or floor(pulse(CLOCK / 1000) * steps + 0.5)) / steps
    local th = thick()
    local halo = 2 + th / S + 1
    local focus = self.hover or (self.joypad and self.cursor)
    for _, item in ipairs(self.pulsing) do
        if not self:pulseHeld(item, now) then
            local tc = TREE[item.tree].c
            local x, y, s = item.x, item.y + RISE[item.col], item.w
            framePx(el, x, y, s, s, tc, p, th, 2)
            framePx(el, x, y, s, s, tc, PULSE_HALO * p, th, halo)
            if item.key == focus then
                local k = UI.placeLevels(self.body, item.id)
                if k > 0 then framePx(el, x, y, s, s, WHITE, k, 1, halo) end
            end
        end
    end
end

function View:paintPulses(el)
    if not self.sim or self.take or not self.pulsingOn then return end
    S = UI.S
    local now = getTimestampMs()
    NOW, CLOCK = now, now - self.t0
    self:frameState(now)
    beginRects(el)
    local ok, err = pcall(pulseFrames, self, el, now)
    endRects()
    if not ok then error(err, 0) end
end

-- ---- the body taking an applied selection -------------------------------------------------------------------------

-- Milliseconds an applied selection may take to come back and still be played.
View.TAKE_WAIT_MS = 10000

-- The picture of a column's soft light (tools/glow_art.py: a soft band, stretched over the column), found once; its
-- strength at the most, the frame's line (design units) and the size of the running light's head (design units: its
-- glow, and the bright core in it).
local bandTex = nil
local function band()
    if bandTex == nil then bandTex = getTexture("media/textures/OA_Wave.png") or false end
    return bandTex or nil
end
Window.TAKE_GLOW_A, Window.TAKE_LINE, Window.TAKE_HEAD, Window.TAKE_HEAD_CORE = 0.10, 2, 30, 9

-- The light round a column's frame (x, y, w, h, design units) `along` of the way (0 at the middle of its top, 1 where
-- the two ways meet at the bottom's middle): the frame it has passed lit, a head of light at each end of it.
local function traceFrame(el, x, y, w, h, along, c, a, core, tex)
    local d, th, mid = along * (w + h), Window.TAKE_LINE, x + w / 2
    local top = math.min(d, w / 2)
    UI.fill(el, mid - top, y, 2 * top, th, c, a)
    local side = math.min(math.max(0, d - w / 2), h)
    if side > 0 then
        UI.fill(el, x, y, th, side, c, a)
        UI.fill(el, x + w - th, y, th, side, c, a)
    end
    local bottom = math.max(0, d - w / 2 - h)
    if bottom > 0 then
        UI.fill(el, x, y + h - th, bottom, th, c, a)
        UI.fill(el, x + w - bottom, y + h - th, bottom, th, c, a)
    end
    if not tex then return end
    -- the heads, the right way's and its mirror; they fade as they meet
    local hx, hy
    if d <= w / 2 then hx, hy = mid + d, y
    elseif d <= w / 2 + h then hx, hy = x + w, y + d - w / 2
    else hx, hy = x + w - bottom, y + h end
    local ha = a * (1 - along ^ 4)
    for _, px in ipairs({ hx, 2 * mid - hx }) do
        glowAt(el, tex, px, hy, Window.TAKE_HEAD * S, c, 0.9 * ha)
        glowAt(el, tex, px, hy, Window.TAKE_HEAD_CORE * S, core, ha)
    end
end

-- The way a node's light runs up to its tree's header: its lit line, then its prerequisite's, and so on (through each
-- node on the way). Returns the lines (nil for none), where each starts on the way (design units from the node) and
-- the way's length.
function View:wayUp(id)
    local lines, offs, len = nil, nil, 0
    local cur = id
    for _ = 1, Data.ROWS do
        local into = nil
        for _, line in ipairs(self.lines) do
            if line.to == cur and line.state == "lit" then
                into = line
                break
            end
        end
        if not into then break end
        if lines then
            -- across the node between: from the top of the last line's start node (its end) to the bottom of its pips
            local prev = lines[#lines]
            len = len + math.max(0, prev.points[1][2] - into.points[#into.points][2])
        else
            lines, offs = {}, {}
        end
        lines[#lines + 1], offs[#lines + 1] = into, len
        len = len + into.len
        cur = into.need[1]
    end
    return lines, offs, len
end

-- The applied selection came back: starts the take on the nodes of it that are on the screen. Not when the tab is
-- closed. Everything a frame reads is made here (a frame makes nothing): each node's place in the scan and the ranks
-- it took, the way of its light and when it arrives, each tree's points and its first arrival, the columns that took
-- points, when the columns glow and when it is all over.
function View:startTake()
    local approved = self.approved
    self.approved = nil
    if not approved or not self:getIsVisible() or not self.sim then return end
    if getTimestampMs() - approved.at > View.TAKE_WAIT_MS then return end
    local shown = {}
    for _, item in ipairs(self.items) do
        if item.id then shown[item.id] = true end
    end
    local order = Plan.takeOrder(approved.steps, shown)
    local n = #order
    local step = Plan.takeStep(n)
    local index, ways, arrive, first, cols = {}, {}, {}, {}, {}
    local last = 0
    for i, id in ipairs(order) do
        index[id] = i
        local item = self:itemOf(id)
        local lines, offs, len = self:wayUp(id)
        ways[i] = { lines = lines, offs = offs, len = len, item = item }
        arrive[i] = (i - 1) * step + Plan.takeArrive(len)
        last = math.max(last, arrive[i])
        local tree = item.tree
        if first[tree] == nil or arrive[i] < first[tree] then first[tree] = arrive[i] end
        cols[item.col] = true
    end
    local start = getTimestampMs()
    self.take = { order = order, start = start, lit = 0, index = index, step = step, ways = ways, arrive = arrive,
        first = first, cols = cols, gained = Plan.counts(approved.steps), points = approved.spent or {},
        glowFrom = Plan.takeGlowAt(n, last), ends = Plan.takeEnd(n, last) }
    -- the nodes it opens stay locked to the eye until it is over, then their padlocks come off (those still locked
    -- then are drawn locked anyway); not the ones it took ranks of, which it lights itself
    if approved.locked then
        local at = start + self.take.ends
        local taken = self.take.gained
        for id in pairs(approved.locked) do
            if not taken[id] then self:addUnlock(id, at) end
        end
    end
    -- every frame while it plays (View.tick)
    self:animate()
end

-- How strongly a tree's header flashes now: the strongest of its nodes' lights arriving.
function View:takeHeader(tree)
    local take = self.take
    local t = NOW - take.start
    local k = 0
    for i = 1, #take.order do
        if take.ways[i].item.tree == tree then k = math.max(k, Plan.takeHeader(t - take.arrive[i])) end
    end
    return k
end

-- A node's light running up its way, `age` ms after it was taken: on each line its part, the head a glow with a
-- bright core and the tail fading towards the node.
local function drawRun(el, way, age)
    local head, a = Plan.takeRun(age, way.len)
    if not head then return end
    local tex = glow()
    local tc = TREE[way.item.tree]
    local lw = math.max(2, floor(1.5 * S + 0.5))
    local tail = Plan.TAKE_TAIL
    local steps = Motion.COMET_STEPS
    for k, line in ipairs(way.lines) do
        local dy = RISE[line.col]
        -- the head's place on the line (design units from its start; it runs towards 0)
        local at = line.len - (head - way.offs[k])
        if at < line.len + tail and at + tail > 0 then
            for i = 0, steps - 1 do
                local f = 1 - i / steps
                lineSpan(el, line, at + tail * i / steps, at + tail * (i + 1) / steps, dy, lw + 1, tc.light,
                    a * f * f * 0.9)
            end
            if tex and at >= 0 and at <= line.len then
                local x, y = pointOn(line, at, dy)
                glowAt(el, tex, x, y, lw * 7, tc.light, a)
                glowAt(el, tex, x, y, lw * 3, tc.core, a)
            end
        end
    end
end

-- One frame of the take: each node taken bursts (a growing glow in its tree's colour, a bright core flash) and sends
-- its light up its way (with a short sound as the scan reaches it); then a light runs round the frame of each column
-- that took points. The nodes pop and settle their pips themselves (View:paintNode), the headers
-- flash (View:paintStrip).
function View:drawTake(el)
    local take = self.take
    local n = #take.order
    local t = NOW - take.start
    if t >= take.ends then
        self.take = nil
        return
    end
    local tex = glow()
    local lit = Plan.takeLit(n, t)
    for i = 1, lit do
        local way = take.ways[i]
        local item = way.item
        local age = t - (i - 1) * take.step
        if way.lines then drawRun(el, way, age) end
        local size, a, core = Plan.takeBurst(age)
        if size then
            local tc = TREE[item.tree]
            local dy = RISE[item.col]
            local cx, cy = item.x + item.w / 2, item.y + dy + item.h / 2
            if tex then glowAt(el, tex, cx, cy, item.w * S * size, tc.light, 0.9 * a) end
            if core > 0 then
                UI.fill(el, item.x, item.y + dy, item.w, item.h, tc.core, 0.5 * core)
                if tex then glowAt(el, tex, cx, cy, item.w * S * 1.5, tc.core, core) end
                -- the rank burns in rough: static over the node, its frame in broken pieces, both by film steps
                local step = filmStep(age)
                staticBurst(el, item.x, item.y + dy, item.w, item.h, tc.light, 0.8 * core, step)
                roughFramePx(el, item.x, item.y + dy, item.w, item.h, tc.light, core, thick() + 1, 3,
                    (item.col or 0) * 1000 + (item.row or 0) * 37 + step)
            end
        end
    end
    if lit > take.lit then
        take.lit = lit
        getSoundManager():playUISound("UISelectListItem")
    end
    -- the frame: a light runs round each column that took points, the column lighting softly behind it
    local along, line, fill = Plan.takeGlow(t - take.glowFrom)
    if along and line > 0 then
        local soft = band()
        for i, panel in ipairs(self.panels) do
            if take.cols[i] then
                local tc = TREE[panel.tree]
                local top, h = panel.y + RISE[i], panel.strip + panel.gridH
                if soft and fill > 0 then
                    local x0, y0 = X(panel.x), X(top)
                    texPx(el, soft, x0, y0, X(panel.x + panel.w) - x0, X(top + h) - y0, tc.light, Window.TAKE_GLOW_A * fill)
                end
                traceFrame(el, panel.x, top, panel.w, h, along, tc.light, line, tc.core, tex)
                -- the column's frame flickers rough behind the running light
                roughFramePx(el, panel.x, top, panel.w, h, tc.light, 0.45 * line, math.max(1, X(1)), 0,
                    i * 7919 + filmStep(t))
            end
        end
    end
end

function View:setVisible(visible, joypadData)
    if visible then self:checkScale() end
    ISPanelJoypad.setVisible(self, visible, joypadData)
    if visible then
        self:refresh()
        self:startOpen()
    else
        self:hideTip()
        self.take, self.approved = nil, nil
        self.fx, self.openAt, self.bump = nil, nil, nil
        self.unlocks, self.unlockFrom, self.unlockEnd = nil, nil, nil
    end
end

-- ---- gamepad ---------------------------------------------------------------------------------------------------

function View:onGainJoypadFocus(joypadData)
    ISPanelJoypad.onGainJoypadFocus(self, joypadData)
    self.joypad = true
    if not self.cursor then self.cursor = (self:firstNode() or {}).key end
    self:changed()
end

function View:onLoseJoypadFocus(joypadData)
    ISPanelJoypad.onLoseJoypadFocus(self, joypadData)
    self.joypad = false
    self:hideTip()
    self:changed()
end

-- The nearest item (a node or a button) in a direction from the cursor: dx, dy are -1, 0 or 1.
function View:step(dx, dy)
    local from = self.cursor and self:itemOf(self.cursor)
    if not from then
        self.cursor = (self:firstNode() or {}).key
        self:changed()
        return
    end
    local fx, fy = from.x + from.w / 2, from.y + from.h / 2
    local best, bestScore = nil, nil
    for _, item in ipairs(self.items) do
        if item ~= from and self:reachable(item) then
            local rx, ry = item.x + item.w / 2 - fx, item.y + item.h / 2 - fy
            local along = rx * dx + ry * dy
            if along > 1 then
                local across = math.abs(rx * dy) + math.abs(ry * dx)
                local score = along + across * 2
                if not bestScore or score < bestScore then best, bestScore = item, score end
            end
        end
    end
    if best then
        self.cursor = best.key
        self:changed()
    end
end

function View:onJoypadDirLeft(joypadData) self:step(-1, 0) end
function View:onJoypadDirRight(joypadData) self:step(1, 0) end
function View:onJoypadDirUp(joypadData) self:step(0, -1) end
function View:onJoypadDirDown(joypadData) self:step(0, 1) end

function View:onJoypadDown(button, joypadData)
    if button == Joypad.AButton then
        local item = self.cursor and self:itemOf(self.cursor)
        if item then self:press(item) end
    elseif button == Joypad.XButton then
        local item = self.cursor and self:itemOf(self.cursor)
        if item and item.id then self:unplan(item.id) end
    elseif button == Joypad.YButton then
        self:onApprove()
    elseif button == Joypad.BButton then
        local info = getPlayerInfoPanel(self.playerNum)
        if info then info:toggleView(tabName()) end
        setJoypadFocus(self.playerNum, nil)
    elseif button == Joypad.LBumper or button == Joypad.RBumper then
        local info = getPlayerInfoPanel(self.playerNum)
        if info then info:onJoypadDown(button) end
    end
end

-- ---- the tab in the character info window ----------------------------------------------------------------------

-- Adds the tab to each character info window as the game makes it (once a player).
local baseCreate = ISCharacterInfoWindow.createChildren
function ISCharacterInfoWindow:createChildren()
    baseCreate(self)
    local ok, err = pcall(function()
        local view = View:new(self.playerNum)
        view:initialise()
        self.panel:addView(tabName(), view)
        views[self.playerNum] = view
        -- the game restores the window's layout while making it, before this tab is there (see RestoreLayout)
        if self.oaResearchOpen then self.panel:activateView(tabName()) end
    end)
    if not ok then OA.log("research tab failed:", tostring(err)) end
end

-- The game remembers which of its own tabs was open when the game was left; this remembers the research tab too.
local baseSave = ISCharacterInfoWindow.SaveLayout
function ISCharacterInfoWindow:SaveLayout(name, layout)
    baseSave(self, name, layout)
    local view = views[self.playerNum]
    layout.oaResearch = (view and view.parent == self.panel and self.panel:getActiveView() == view) and "true" or nil
end

local baseRestore = ISCharacterInfoWindow.RestoreLayout
function ISCharacterInfoWindow:RestoreLayout(name, layout)
    baseRestore(self, name, layout)
    self.oaResearchOpen = layout.oaResearch == "true"
end

-- Shows the research tab of a local player's character info window (the first player when not named), or hides it
-- when it shows. Returns the tab when it shows.
function Window.open(playerNum)
    playerNum = playerNum or 0
    local info = getPlayerInfoPanel(playerNum)
    local view = views[playerNum]
    if not info or not view then return nil end
    local shown
    if view.parent == info.panel then
        info:toggleView(tabName())
        shown = info:getIsVisible() and info.panel:getActiveView() == view
    elseif view.parent then
        -- torn off into a window of its own
        local window = view.parent
        shown = not window:getIsVisible()
        window:setVisible(shown)
        if shown then
            window:addToUIManager()
            window:bringToTop()
        end
    end
    -- (not isReallyVisible: a window added outside the UI's own update joins the UI manager only on the next frame)
    if not shown then return nil end
    view:checkScale()
    view:refresh()
    -- (shown in the window, the tab's setVisible started it already; torn off, only the window was shown)
    if view.parent ~= info.panel then view:startOpen() end
    if getJoypadData(playerNum) then setJoypadFocus(playerNum, view) end
    return view
end

-- The research tab of a player, shown or not.
function Window.view(playerNum)
    return views[playerNum or 0]
end

OA.Upgrades.open = Window.open

-- The record changed (an approval, a reset, a serum): the tabs read it again.
local function onChanged(playerId, detail)
    local approved = type(detail) == "table" and detail.kind == "approve"
    for _, view in pairs(views) do
        if view:getIsVisible() then
            view:refresh()
            if approved then view:startTake() end
        end
    end
end
OA.Sync.listen("upgrades", onChanged)
OA.Sync.listen("trade", onChanged)
OA.Sync.listen("all", onChanged)

return Window
