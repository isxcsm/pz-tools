-- The research plan (DESIGN 8), as the 강화 (Enhancement) tab of the character info window, beside the game's skills
-- and health, drawn as the field terminal is (mockups/upgrades): an opaque body in the terminal's palette, the three
-- trees side by side, each a column with a header strip in its colour (its name, its points as a bar, a reset button)
-- over a grid of icon nodes (four columns, five rows opened by the points spent in the tree, the capstone last and a
-- little larger) with the prerequisite lines between them; the 2nd board in their place. Above: the two modes and
-- chips for the shared points and the meteorite fragments; below: a bar that says what approving the selection spends,
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
-- When the server's approval comes back while the tab is open, the selected nodes light one by one with a short sound
-- and a red seal is pressed on them for a moment (Plan.stamp has the timing; the tab's own render draws it, so it costs
-- nothing when the tab is closed).
-- What a frame does: the states of the nodes and lines are worked out when the record or the selection changes
-- (refresh); a frame only paints them, with the pulse and the dashes from the clock.
require "ISUI/ISPanelJoypad"
require "ISUI/ISPanel"
require "ISUI/ISModalDialog" -- oa-widget: ok (the gamepad's confirm, View:ask)
require "ISUI/ISContextMenu"
require "XpSystem/ISUI/ISCharacterInfoWindow"
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Texts"
require "OperationAcorn/Upgrades/Links"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/Confirm"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Plan = OA.Upgrades.Plan
local Effects = OA.Upgrades.Effects
local Texts = OA.Upgrades.Texts
local Links = OA.Upgrades.Links
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
local RED = { 0.88, 0.16, 0.12 }           -- the approval seal
local WHITE = { 1, 1, 1 }
local DARK = { 0.03, 0.03, 0.03 }
-- Each tree's colour (its icons' plate colour, a little lifted) and its light tint for texts; the strip is the colour
-- mixed into the body.
local TREE = {
    scout = { c = { 0.25, 0.66, 0.70 }, light = { 0.62, 0.90, 0.95 } },
    load = { c = { 0.86, 0.55, 0.22 }, light = { 1.0, 0.80, 0.52 } },
    survival = { c = { 0.46, 0.74, 0.32 }, light = { 0.70, 0.93, 0.58 } },
}
for _, t in pairs(TREE) do
    t.strip = {}
    for i = 1, 3 do t.strip[i] = P.bg[i] * 0.74 + t.c[i] * 0.26 end
end

-- ---- layout (design units) ----------------------------------------------------------------------------------------
local L = {
    PAD = 8, TOP = 28, GAP = 8,
    COL_W = 238, COL_GAP = 6, STRIP = 44,
    ICON = 40, CAP = 48, GX = 18, ROW = 64, PIPS = 10, GRID_PAD = 12,
    PLAN = 36, BUTTON_H = 26,
    TIP_W = 300, TIP_PAD = 10,
}
L.GRID_H = L.GRID_PAD + 4 * L.ROW + L.CAP + L.PIPS + 4
L.VIEW_W = 2 * L.PAD + 3 * L.COL_W + 2 * L.COL_GAP
L.COL_Y = L.PAD + L.TOP + L.GAP
L.PLAN_Y = L.COL_Y + L.STRIP + L.GRID_H + L.GAP
L.VIEW_H = L.PLAN_Y + L.PLAN + L.PAD
Window.LAYOUT = L
-- The pulse of a node that can be taken (seconds a cycle), and the selected path's dashes: dash, gap (design units)
-- and how fast they flow (design units a second).
Window.PULSE_S = 1.6
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

local function rectPx(el, x, y, w, h, c, a)
    if w <= 0 or h <= 0 then return end
    ISUIElement.drawRect(el, x, y, w, h, a or 1, c[1], c[2], c[3])
end

local function texPx(el, tex, x, y, w, h, c, a)
    if not tex then return end
    c = c or WHITE
    ISUIElement.drawTextureScaled(el, tex, x, y, w, h, a or 1, c[1], c[2], c[3])
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

-- An item icon's texture for a pixel size: the 32 px inventory icon, or its high-res copy (tools/icon_art.py) when it
-- is drawn larger.
local function itemTexture(name, px)
    if px <= 34 then return getTexture("media/textures/Item_OA_" .. name .. ".png") end
    local size = px <= 66 and 64 or 128
    return getTexture("media/textures/OA_ItemHi/OA_" .. name .. "_" .. size .. ".png")
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

function OAResearchBody:onRightMouseUp(x, y)
    local item = self.view:itemAt(x, y)
    if item and item.id then self.view:unplan(item.id) end
    return true
end

UI.scaled(OAResearchBody, ISPanel)

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
    o.fragments, o.fragmentsLeft = 0, 0
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

-- The body (and the tooltip) for the scale now; made again when it changed (UI.era).
function View:makeBody()
    if self.body then
        self:removeChild(self.body)
        self.body = nil
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
    self:layout()
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
        local px, py = self:panelX(i), L.COL_Y
        local gx, gy = px, py + L.STRIP
        self.panels[#self.panels + 1] = { tree = tree, x = px, y = py, gx = gx, gy = gy }
        if self.mode == "board" then
            for k, node in ipairs(Data.boardGroup(tree)) do
                local c, r = (k - 1) % Data.COLS + 1, floor((k - 1) / Data.COLS) + 1
                local x, y, s = cell(c, r)
                items[#items + 1] = { key = node.id, id = node.id, tree = tree, x = gx + x, y = gy + y, w = s, h = s }
            end
        else
            for _, node in ipairs(Data.treeNodes(tree)) do
                local x, y, s = cell(node.col, node.row, node.capstone)
                items[#items + 1] = { key = node.id, id = node.id, tree = tree, x = gx + x, y = gy + y, w = s, h = s }
            end
            for _, link in ipairs(Links.tree(tree)) do
                local pts = {}
                for k, p in ipairs(link.points) do
                    local x, y = waypoint(p)
                    pts[k] = { gx + x, gy + y }
                end
                self.lines[#self.lines + 1] = { need = link.need, tree = tree, points = pts }
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
    return getText("IGUI_OA_Tree_BoardClosedTab", n, #Data.TREES), true
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
    local key = item and item.key or nil
    if key ~= self.hover then
        self.hover = key
        self.tipDirty = true
    end
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
    self:countFragments(true)
    local sim, kept, used = Plan.simulate(self.u, self.steps, self.fragments)
    self.sim, self.steps = sim, kept
    self.counts = Plan.counts(kept)
    self.fragmentsLeft = self.fragments - used
    self.spentPlan = Plan.spent(self.u, sim)
    self.revealed = {}
    for _, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        if cap and Rules.rank(sim, cap.id) >= 1 then self.revealed[tree] = true end
    end
    self:layout()
    self:workOut()
    self.tipDirty = true
end

-- What each node and line shows, from the record and the simulation (once a change, not each frame).
function View:workOut()
    local u, sim = self.u, self.sim
    local nodes = {}
    local boardOpen = Rules.boardOpen(sim)
    for _, item in ipairs(self.items) do
        if item.id then
            local node = Data.byId[item.id]
            local rank = Rules.rank(sim, node.id)
            local planned = self.counts[node.id] or 0
            local n = { rank = rank, planned = planned, full = rank - planned }
            if node.board then
                n.hidden = not boardOpen and not self.revealed[node.group]
                if not boardOpen then
                    n.state = "locked"
                elseif planned > 0 then
                    n.state = "planned"
                elseif not Rules.blocked(sim, node.id, { fragments = self.fragmentsLeft }, "A") then
                    n.state = "avail"
                elseif rank > 0 then
                    n.state = "owned"
                else
                    n.state = "dim"
                end
            else
                n.treeLocked = not Rules.treeOpen(u, node.tree)
                local why = Rules.blocked(sim, node.id, { fragments = self.fragmentsLeft }, "A")
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
    self.nodes = nodes
    for _, line in ipairs(self.lines) do
        local need, k = line.need[1], line.need[2]
        if Rules.rank(u, need) >= k then
            line.state = "lit"
        elseif Rules.rank(sim, need) >= k then
            line.state = "plan"
        else
            line.state = "dim"
        end
    end
end

-- The fragments the character carries, in any bag. The window looks again every second, and the inventory may hold
-- thousands of items: the count is made again only when the inventory's signature (OA.signature: how many items, what
-- they weigh) is not the one it was made under, or when `force` is given (the window opens, the plan is changed).
function View:countFragments(force)
    local inventory = self.player:getInventory()
    local key = OA.signature(inventory)
    if force or key ~= self.fragmentKey then
        self.fragmentKey = key
        -- oa-scan: ok (a new signature, or the player's own act)
        self.fragments = inventory:getCountTypeRecurse(Data.FRAGMENT)
    end
    self.nextCount = getTimestampMs() + 1000
end

function View:onMode(button)
    if self.mode == button.internal then return end
    self.mode = button.internal
    self.hover = nil
    self:layout()
    if self.sim then self:workOut() end
    if self.joypad then self.cursor = (self:firstNode() or {}).key or self.cursor end
    self.tipDirty = true
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

function View:plan(id, choice)
    if not self.sim then return end
    local node = Data.byId[id]
    if node.board and node.choose and not choice then
        return self:chooseFamily(id)
    end
    local steps, why = Plan.add(self.u, self.steps, id, choice, self.fragments)
    if not steps then
        self.refusal = { id = id, why = why }
        self.tipDirty = true
        return
    end
    self.refusal = nil
    self.steps = steps
    self:refresh()
end

function View:unplan(id)
    if not self.sim then return end
    self.steps = Plan.remove(self.u, self.steps, id, self.fragments)
    self.refusal = nil
    self:refresh()
end

-- The family weight node asks which family the point is for.
function View:chooseFamily(id)
    local context = ISContextMenu.get(self.playerNum, getMouseX(), getMouseY())
    for _, family in ipairs(Data.FAMILY_ORDER) do
        local n = self.sim.board.family[family] or 0
        local label = Texts.familyName(family)
        if n > 0 then label = label .. " (" .. Texts.number(Rules.familyAmount(self.sim, family) * 100) .. "%)" end
        -- oa-menu: bottom (the window's own menu at the mouse, not one of the game's)
        context:addOption(label, self, View.onFamily, id, family)
    end
    if self.joypad then
        context.origin = self
        setJoypadFocus(self.playerNum, context)
    end
end

function View:onFamily(id, family)
    self:plan(id, family)
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
        return
    end
    UI.confirm(self.player, text, self, onYes, arg)
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
    -- what the plan was, for the stamp that plays when the approval comes back (alone, that is at once, inside the send)
    self.approved = { steps = self.steps, at = getTimestampMs() }
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
-- does not apply, the conditions of the next rank as a checklist, the research team's line on a capstone.
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
        if node.board and node.choose then
            nextLines[1] = getText("IGUI_OA_Tree_NextFamily")
        else
            -- the next rank as it would read: on a copy of the plan that takes it
            local after = Plan.add(self.u, self.steps, id, node.choose and "A" or nil, self.fragments)
            local lines
            if after then
                local simAfter = Plan.simulate(self.u, after, self.fragments)
                lines = Texts.lines(node, Rules.rank(simAfter, id), simAfter)
            else
                lines = Texts.lines(node, math.min(rank + 1, node.ranks or rank + 1), sim)
            end
            nextLines = Texts.newLines(now, lines)
        end
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
        local conditions = Texts.conditions(sim, node, { fragments = self.fragmentsLeft })
        if #conditions > 0 then
            add({ kind = "sep" })
            for _, c in ipairs(conditions) do add({ kind = "check", ok = c.ok, text = c.text }) end
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
    local item = self:focusItem()
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

local function pulse(t)
    return 0.5 + 0.5 * math.sin(2 * math.pi * t / Window.PULSE_S)
end

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

function View:paintTop(el)
    local hoverKey = self.hover
    for _, key in ipairs({ "mode:trees", "mode:board" }) do
        local item = self.byKey[key]
        local on = self.mode == item.mode
        local style = on and "strong" or "normal"
        if key == "mode:trees" then
            button(el, item, getText("IGUI_OA_Tree_ModeTrees"), style, hoverKey == key)
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
    right = chip(el, right, y, h, "MeteorFragment", "IGUI_OA_Tree_BadgeFragments", self.fragmentsLeft) - 6
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

-- A tree's header strip: its name, the reset button, its points as a bar (spent in its colour, selected in cyan, still
-- to spend pale, the rows' openings as ticks) and the points left.
function View:paintStrip(el, panel)
    local tree = panel.tree
    local tc = TREE[tree]
    local x, y = panel.x, panel.y
    UI.fill(el, x, y, L.COL_W, L.STRIP, tc.strip)
    UI.fill(el, x, y, L.COL_W, 2, tc.c)
    UI.text(el, Texts.treeName(tree), x + 10, y + 5, tc.light, UIFont.Medium)
    local fh = UI.fontHeight()
    if self.mode ~= "trees" then
        local cap = Data.capstone(tree)
        local done = cap and Rules.rank(self.sim, cap.id) >= 1
        local sub = done and getText("IGUI_OA_Tree_CapstoneDone", Texts.nodeName(cap.id)) or "???"
        UI.text(el, sub, x + 10, y + 26, done and P.text or P.dim, nil, 0.9)
        return
    end
    -- the reset
    local item = self.byKey["reset:" .. tree]
    if item and self:reachable(item) then
        local on = self:enabled(item)
        local hover = on and self.hover == item.key
        UI.fill(el, item.x, item.y, item.w, item.h, hover and tc.c or P.bg, hover and 0.35 or 0.5)
        UI.frame(el, item.x, item.y, item.w, item.h, tc.light, on and 0.6 or 0.25)
        glyph(el, "Reset", item.x + item.w / 2, item.y + item.h / 2, item.w - 8, tc.light, on and 0.95 or 0.35)
    end
    -- the bar
    local usable, surplus = Rules.ownSplit(self.sim, tree)
    local label = surplus > 0 and getText("IGUI_OA_Tree_OwnLeftBoard", usable, surplus) or getText("IGUI_OA_Tree_OwnLeft", usable)
    local lw = UI.textWidth(label)
    local bx, by, bh = x + 10, y + 31, 7
    local bw = L.COL_W - 20 - lw - 10
    UI.text(el, label, x + L.COL_W - 10 - lw, y + 26, usable > 0 and P.value or P.dim)
    if bw < 30 then return end
    UI.fill(el, bx, by, bw, bh, P.inset)
    local total = TREE_POINTS[tree]
    local spent = Rules.treeSpent(self.u, tree)
    local plan = self.spentPlan[tree] or 0
    local x0, x1 = X(bx), X(bx + bw)
    local y0, y1 = X(by), X(by + bh)
    local function segX(k) return x0 + floor((x1 - x0) * k / total + 0.5) end
    for k = 0, total - 1 do
        local a, b = segX(k), segX(k + 1) - 1
        local c, alpha
        if k < spent then
            c, alpha = tc.c, 1
        elseif k < spent + plan then
            c, alpha = CYAN, 1
        elseif k < spent + plan + usable then
            c, alpha = tc.light, 0.35
        else
            c, alpha = P.border, 0.22
        end
        rectPx(el, a, y0, b - a, y1 - y0, c, alpha)
    end
    local tw = math.max(1, floor(S * 0.7 + 0.5))
    for row = 2, Data.ROWS do
        local need = Rules.rowNeed(row)
        if need < total then
            local px = segX(need) - 1
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

-- A prerequisite line: lit in the tree's colour, dim, or the selection's flowing cyan dashes; a small arrowhead into
-- the node.
function View:paintLine(el, line, t)
    local c, a
    if line.state == "lit" then
        c, a = TREE[line.tree].c, 0.95
    elseif line.state == "plan" then
        c, a = CYAN, 1
    else
        c, a = LINE_DIM, 1
    end
    local lw = math.max(2, floor(1.5 * S + 0.5))
    local pts = line.points
    -- the arrowhead's height in pixels; the line stops where it starts
    local k = math.max(3, floor(3 * S + 0.5))
    local tip = k / S
    local ex, ey = pts[#pts][1], pts[#pts][2]
    local dashed = line.state == "plan"
    local period = Window.DASH + Window.DASH_GAP
    local phase = remainder(t * Window.FLOW, period)
    local dist = 0
    for i = 1, #pts - 1 do
        local xa, ya = pts[i][1], pts[i][2]
        local xb, yb = pts[i + 1][1], pts[i + 1][2]
        if i == #pts - 1 then yb = yb - tip end
        local len = math.abs(xb - xa) + math.abs(yb - ya)
        if len > 0 then
            if not dashed then
                linePiece(el, xa, ya, xb, yb, len, 0, len, lw, c, a)
            else
                local s0 = -remainder(dist - phase, period)
                while s0 < len do
                    local a0, a1 = math.max(0, s0), math.min(len, s0 + Window.DASH)
                    if a1 > a0 then linePiece(el, xa, ya, xb, yb, len, a0, a1, lw, c, a) end
                    s0 = s0 + period
                end
            end
        end
        dist = dist + len
    end
    -- the arrowhead, rows of whole pixels
    local cx, top = X(ex), X(ey) - k
    for i = 0, k - 1 do
        local w = 2 * (k - i) - 1
        rectPx(el, cx - floor(w / 2), top + i, w, 1, c, a)
    end
end

-- The padlock of a locked node, in a dark disc at its bottom right.
local function lockBadge(el, x, y, s)
    local r = 7.5
    local cx, cy = x + s - r + 1, y + s - r + 1
    glyph(el, "Pip", cx, cy, 2 * r, DARK, 0.92)
    local u = UI.dot()
    UI.lock(el, cx - 4 * u, cy - 4.5 * u, P.text, 0.9)
end

-- The cyan "+n" of selected ranks at a node's top right.
local function plusChip(el, x, y, n)
    local s = "+" .. n
    local fh = UI.fontHeight()
    local w = UI.textWidth(s) + 8
    local cx, cy = x - w + 5, y - 7
    UI.fill(el, cx, cy, w, fh, CYAN)
    UI.textCentre(el, s, cx + w / 2, cy, { 0.04, 0.10, 0.12 })
end

-- One node: its icon (grey while it cannot be taken) with no well around it, a frame for its state, its ranks as pips
-- (a number on the endless board).
function View:paintNode(el, item, t)
    local node = Data.byId[item.id]
    local n = self.nodes[item.id]
    if not n then return end
    local x, y, s = item.x, item.y, item.w
    local tree = item.tree
    local tc = TREE[tree].c
    local th = thick()
    local out = 2
    if n.hidden then
        UI.fill(el, x, y, s, s, { 0.13, 0.135, 0.11 })
        UI.frame(el, x, y, s, s, P.border, 0.6)
        local fm = UI.fontHeight(UIFont.Medium)
        UI.textCentre(el, "?", x + s / 2, y + (s - fm) / 2, P.dim, UIFont.Medium)
        return
    end
    local grey = n.state == "locked" or n.treeLocked
    local tex = getTexture((grey and node.iconGray) or node.icon)
    local ipx = iconPx(s)
    local ix, iy = X(x + s / 2) - floor(ipx / 2), X(y + s / 2) - floor(ipx / 2)
    texPx(el, tex, ix, iy, ipx, ipx, nil, grey and 0.8 or 1)
    local state = n.state
    if n.treeLocked then
        framePx(el, x, y, s, s, P.border, 0.45, 1, out)
    elseif state == "avail" then
        local p = pulse(t)
        framePx(el, x, y, s, s, tc, 0.55 + 0.45 * p, th, out)
        framePx(el, x, y, s, s, tc, 0.22 * p, th, out + th / S + 1)
    elseif state == "maxed" then
        framePx(el, x, y, s, s, GOLD, 1, th, out)
    elseif state == "planned" then
        dashedPx(el, x, y, s, s, CYAN, 1, th, out)
        plusChip(el, x + s + out, y - out, n.planned)
    elseif state == "owned" then
        framePx(el, x, y, s, s, tc, 0.45, th, out)
    else
        framePx(el, x, y, s, s, P.border, 0.45, 1, out)
    end
    if grey then lockBadge(el, x, y, s) end
    if n.api and not grey then
        local fh = UI.fontHeight()
        UI.fill(el, x - 1, y - 1, 12, fh, { 0.35, 0.15, 0.05 }, 0.95)
        UI.textCentre(el, "!", x + 5, y - 1, API)
    end
    if node.board then
        if Rules.boardOpen(self.sim) then
            local base = tostring(n.full)
            if n.planned > 0 then
                local more = " +" .. n.planned
                local w = UI.textWidth(base) + UI.textWidth(more)
                local tx = x + (s - w) / 2
                UI.text(el, base, tx, y + s + 1, P.text)
                UI.text(el, more, tx + UI.textWidth(base), y + s + 1, CYAN)
            else
                UI.textCentre(el, base, x + s / 2, y + s + 1, n.rank > 0 and P.text or P.dim)
            end
        end
    elseif not n.treeLocked then
        Window.pips(el, x + s / 2, y + s + 6.5, node.ranks, n.full, n.planned, state == "maxed" and GOLD or tc)
    end
    local focus = (self.hover == item.key) or (self.joypad and self.cursor == item.key)
    if focus then framePx(el, x, y, s, s, WHITE, 1, 1, out + th / S + 1) end
end

-- The bottom bar: what approving the selection spends (only the trees with something selected), or how to select;
-- the clear and approve buttons.
function View:paintPlanBar(el)
    local x, y, w, h = L.PAD, L.PLAN_Y, L.VIEW_W - 2 * L.PAD, L.PLAN
    local has = #self.steps > 0
    UI.fill(el, x, y, w, h, P.panel)
    UI.frame(el, x, y, w, h, has and CYAN or P.border, has and 0.55 or 1)
    if has then UI.fill(el, x, y, 3, h, CYAN) end
    local fh = UI.fontHeight()
    local ty = y + (h - fh) / 2
    if has then
        local parts = {}
        for _, tree in ipairs(Data.TREES) do
            local n = self.spentPlan[tree] or 0
            if n > 0 then
                parts[#parts + 1] = { getText("IGUI_OA_Tree_PlanPart", getText("IGUI_OA_Tree_Short_" .. tree), n), TREE[tree].light }
            end
        end
        if (self.spentPlan.board or 0) > 0 then
            parts[#parts + 1] = { getText("IGUI_OA_Tree_PlanPart", Texts.treeName(Data.BOARD), self.spentPlan.board), GOLD }
        end
        local pre, post = around("IGUI_OA_Tree_PlanUses")
        local sep = getText("IGUI_OA_Tree_Sep")
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
        local hint = getText(self.joypad and "IGUI_OA_Tree_PadHint" or "IGUI_OA_Tree_Hint")
        local room = self.byKey.clear.x - x - 24
        UI.text(el, UI.fit(hint, room), x + 14, ty, P.dim)
    end
    local clear, approve = self.byKey.clear, self.byKey.approve
    button(el, clear, getText("IGUI_OA_Tree_ClearPlan"), has and "normal" or "off", has and self.hover == "clear")
    button(el, approve, getText("IGUI_OA_Tree_Approve"), has and "strong" or "off", has and self.hover == "approve")
end

-- The 2nd board while closed: what opens it, the three capstones with the approved ones lit.
function View:paintBoardBanner(el)
    local bw, bh = 520, 92
    local bx, by = (L.VIEW_W - bw) / 2, L.COL_Y + L.STRIP + L.GRID_PAD + 3 * L.ROW + 24
    UI.fill(el, bx, by, bw, bh, { 0.02, 0.02, 0.02 }, 0.92)
    UI.frame(el, bx, by, bw, bh, P.border)
    UI.lock(el, bx + 16, by + 16, P.value)
    UI.text(el, "???", bx + 40, by + 10, P.value, UIFont.Medium)
    local text = getText("IGUI_OA_Tree_BoardHidden", Rules.capstones(self.sim), #Data.TREES)
    UI.text(el, UI.fit(text, bw - 56), bx + 40, by + 36, P.text)
    local segW = (bw - 56 - 16) / 3
    for i, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        local lit = Rules.rank(self.sim, cap.id) >= 1
        local sx = bx + 40 + (i - 1) * (segW + 8)
        UI.fill(el, sx, by + 60, segW, 6, lit and TREE[tree].c or P.border, lit and 1 or 0.35)
        UI.text(el, UI.fit(Texts.nodeName(cap.id), segW), sx, by + 68, lit and TREE[tree].light or P.dim)
    end
end

function View:paint(el)
    S = UI.S
    UI.fill(el, 0, 0, L.VIEW_W, L.VIEW_H, P.bg)           -- opaque: nothing behind shows through
    if not self.sim then
        UI.textCentre(el, getText("IGUI_OA_Tree_NoRecord"), L.VIEW_W / 2, L.VIEW_H / 2, P.text)
        return
    end
    local t = (getTimestampMs() - self.t0) / 1000
    for _, panel in ipairs(self.panels) do
        UI.fill(el, panel.x, panel.y, L.COL_W, L.STRIP + L.GRID_H, P.inset)
        self:paintStrip(el, panel)
    end
    for _, line in ipairs(self.lines) do self:paintLine(el, line, t) end
    for _, item in ipairs(self.items) do
        if item.id then self:paintNode(el, item, t) end
    end
    local fh = UI.fontHeight()
    for _, panel in ipairs(self.panels) do
        -- a tree not opened yet: dark, with why
        if self.mode == "trees" and not Rules.treeOpen(self.u, panel.tree) then
            UI.fill(el, panel.gx, panel.gy, L.COL_W, L.GRID_H, { 0, 0, 0 }, 0.6)
            local lines = UI.wrap(getText("IGUI_OA_Tree_TreeClosed"), L.COL_W - 2 * L.GRID_PAD)
            local ty = panel.gy + (L.GRID_H - #lines * fh) / 2
            for i, line in ipairs(lines) do
                UI.textCentre(el, line, panel.gx + L.COL_W / 2, ty + (i - 1) * fh, { 1, 0.9, 0.5 })
            end
        end
        UI.frame(el, panel.x, panel.y, L.COL_W, L.STRIP + L.GRID_H, P.border)
    end
    if self.mode == "board" and not Rules.boardOpen(self.sim) then self:paintBoardBanner(el) end
    self:paintTop(el)
    self:paintPlanBar(el)
    if self.stamp then self:drawStamp(el) end
    -- the gamepad cursor on a button
    if self.joypad and self.cursor then
        local item = self.byKey[self.cursor]
        if item and not item.id then framePx(el, item.x, item.y, item.w, item.h, WHITE, 1, 2, 2) end
    end
    self:updateTip()
end

-- ---- the approval stamp ----------------------------------------------------------------------------------------

-- Milliseconds an approval may take to come back and still be stamped.
View.STAMP_WAIT_MS = 10000

-- The approval came back: starts the stamp on the nodes of the plan that are on the screen. Not when the tab is closed.
function View:startStamp()
    local approved = self.approved
    self.approved = nil
    if not approved or not self:getIsVisible() or not self.sim then return end
    if getTimestampMs() - approved.at > View.STAMP_WAIT_MS then return end
    local shown = {}
    for _, item in ipairs(self.items) do
        if item.id then shown[item.id] = true end
    end
    local order = Plan.stampOrder(approved.steps, shown)
    self.stamp = { order = order, start = getTimestampMs(), lit = 0, pressed = false }
end

-- The red seal (the 2반's `[직인 ORDWAY]`) over the middle of the trees, `age` ms after it was pressed: it lands from a
-- little larger and fades at the end.
function View:drawSeal(el, age)
    local word, mark = getText("IGUI_OA_Tree_Seal"), getText("IGUI_OA_Tree_SealMark")
    local fl, fh = UI.fontHeight(UIFont.Large), UI.fontHeight()
    local pad = 10
    local w = math.max(UI.textWidth(word, UIFont.Large), UI.textWidth(mark)) + pad * 4
    local h = fl + fh + pad * 3
    local cx = L.VIEW_W / 2
    local cy = L.COL_Y + (L.STRIP + L.GRID_H) / 2
    local a = 1
    local left = Plan.SEAL_MS - age
    if left < Plan.SEAL_FADE_MS then a = math.max(0, left / Plan.SEAL_FADE_MS) end
    local grow = 0
    if age < Plan.SEAL_PRESS_MS then grow = (1 - age / Plan.SEAL_PRESS_MS) * pad * 2 end
    local x, y, bw, bh = cx - w / 2 - grow, cy - h / 2 - grow, w + grow * 2, h + grow * 2
    UI.fill(el, x, y, bw, bh, { 0.02, 0.02, 0.03 }, 0.6 * a)
    framePx(el, x, y, bw, bh, RED, 0.95 * a, math.max(2, floor(1.5 * S + 0.5)), 0)
    framePx(el, x + 6, y + 6, bw - 12, bh - 12, RED, 0.8 * a, 1, 0)
    UI.textCentre(el, word, cx, y + pad + grow, RED, UIFont.Large, a)
    UI.textCentre(el, mark, cx, y + pad * 2 + fl + grow, RED, nil, 0.9 * a)
end

-- One frame of the stamp: the nodes not lit yet keep their selection frame, a node lit flashes (with a short sound),
-- and the seal is pressed over the trees.
function View:drawStamp(el)
    local stamp = self.stamp
    local n = #stamp.order
    local t = getTimestampMs() - stamp.start
    local state = Plan.stamp(n, t)
    if state.over then
        self.stamp = nil
        return
    end
    local th = thick()
    local step = Plan.stampStep(n)
    for i, id in ipairs(stamp.order) do
        local item = self:itemOf(id)
        if item then
            if i > state.lit then
                framePx(el, item.x, item.y, item.w, item.h, CYAN, 1, th, 2)
            else
                local age = t - (i - 1) * step
                local a = 1 - age / Plan.STAMP_FLASH_MS
                if a > 0 then
                    UI.fill(el, item.x, item.y, item.w, item.h, GOLD, 0.45 * a)
                    framePx(el, item.x, item.y, item.w, item.h, GOLD, a, th, 3)
                end
            end
        end
    end
    if state.lit > stamp.lit then
        stamp.lit = state.lit
        getSoundManager():playUISound("UISelectListItem")
    end
    if state.sealAge then
        if not stamp.pressed then
            stamp.pressed = true
            getSoundManager():playUISound("UIObjectMenuObjectPlace")
        end
        self:drawSeal(el, state.sealAge)
    end
end

function View:update()
    ISPanelJoypad.update(self)
    if self.nextCount and getTimestampMs() >= self.nextCount and self.player then
        local before = self.fragments
        self:countFragments()
        if before ~= self.fragments then self:refresh() end
    end
end

function View:setVisible(visible, joypadData)
    if visible then self:checkScale() end
    ISPanelJoypad.setVisible(self, visible, joypadData)
    if visible then self:refresh() else
        self:hideTip()
        self.stamp, self.approved = nil, nil
    end
end

-- ---- gamepad ---------------------------------------------------------------------------------------------------

function View:onGainJoypadFocus(joypadData)
    ISPanelJoypad.onGainJoypadFocus(self, joypadData)
    self.joypad = true
    if not self.cursor then self.cursor = (self:firstNode() or {}).key end
    self.tipDirty = true
end

function View:onLoseJoypadFocus(joypadData)
    ISPanelJoypad.onLoseJoypadFocus(self, joypadData)
    self.joypad = false
    self:hideTip()
end

-- The nearest item (a node or a button) in a direction from the cursor: dx, dy are -1, 0 or 1.
function View:step(dx, dy)
    local from = self.cursor and self:itemOf(self.cursor)
    if not from then
        self.cursor = (self:firstNode() or {}).key
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
        self.tipDirty = true
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
            if approved then view:startStamp() end
        end
    end
end
OA.Sync.listen("upgrades", onChanged)
OA.Sync.listen("trade", onChanged)
OA.Sync.listen("all", onChanged)

return Window
