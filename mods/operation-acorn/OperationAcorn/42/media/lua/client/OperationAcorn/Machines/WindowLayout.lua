-- The machine window laid out (mockups/machines/a-equipment.html, made to fit a 1280 x 720 screen at its smallest font):
-- the window's model (WindowModel.lua) becomes a list of drawing steps with the places that answer a click or show a
-- tooltip (Trade/StatusDraw.lua), in design units (Trade/UI.lua: a 16 pixel Small font), in the field terminal's
-- palette. Laid out when the model changes; each frame only paints the list. From the top: the name plate (icon,
-- name, number, the light and the switch), the strip (what it does or what to do), then per kind: the jobs a lane each,
-- the two bins, the three numbers of its performance, the water gauge, the lure's hours, and a card a part.
-- A machine with parts is wide (one column of the jobs, the bins, the performance and three parts was taller than a
-- 900p screen allows): under the plate and the strip the performance across the window (its three numbers on a row),
-- then two columns: on the left the jobs and under them the bins one above the other, on the right a card a part,
-- in rows whose edges line up across (Layout's columns). The others (no parts: the locker, the rain storage, the lure)
-- are one column. The window's width is the layout's (Layout.widthOf). The hand bench has a window of its own
-- (Layout.bench): the plate and the strip, then what the character carries a row a kind, what the chosen take and give,
-- and the buttons that start and stop the work.
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local UI, Draw = OA.Trade.UI, OA.Trade.Draw
local Machines = OA.Machines
local Data = Machines.Data
local Layout = {}
Machines.WindowLayout = Layout

-- The window's width of a machine without parts and of one with (two columns), its margin, the room between blocks
-- and before a section, and between the two columns (design units). In the wide one the left column (the jobs and the
-- bins) is as wide as a bin's longest note needs ("1200 things · goes on once the output is emptied"), and the right
-- (the performance and the cards of the parts) about as wide as the single column's body: a card needs it for a name,
-- its tier, two buttons and the longest of its lines, in either language.
Layout.WIDTH = 420
Layout.WIDE = 690
Layout.LEFT = 270
Layout.PAD = 10
Layout.GAP = 6
Layout.SECTION = 8
Layout.COLUMN_GAP = 10
-- The part picker's width.
Layout.PICKER_WIDTH = 300
-- The bench window's width: a row needs an icon, a name with its chip, the weight and the count with its two buttons.
Layout.BENCH = 480
-- A bar's height and a job's icon.
local BAR = 8
local ICON = 16
-- The room between two blocks of a column (the bins, the cards of the parts).
local ROW_GAP = 4

local floor = math.floor

-- The width of a kind's window: wide for a machine with parts.
function Layout.widthOf(kind)
    local def = Data.KINDS[kind]
    if def.hand then return Layout.BENCH end
    return #def.slots > 0 and Layout.WIDE or Layout.WIDTH
end

-- A button's height: smaller than the terminal's (the window is short), still a line and a margin.
function Layout.buttonHeight()
    return UI.fontHeight() + 6
end

local function buttonWidth(label)
    return math.max(44, math.ceil(UI.textWidth(label)) + 18)
end

local function colour(p, tone)
    return tone and p[tone] or p.dim
end

-- A tooltip from the model's lines: texts, { s, tone } and "-" (a rule).
local function tipOf(p, lines)
    if not lines then return nil end
    local out = {}
    for i, line in ipairs(lines) do
        if type(line) == "table" then out[i] = { s = line.s, c = colour(p, line.tone) } else out[i] = line end
    end
    return Draw.tip(p, out)
end

-- A section's head: its name, a rule, and a note on the right.
local function head(L, x, y, w, label, right)
    local p, fh = L.p, L.fh
    local lw = Draw.fit(L, label, x, y, floor(w / 2), p.head)
    local rw = 0
    if right then rw = Draw.fit(L, right, x + lw + 12, y, w - lw - 12, p.dim, nil, nil, "right") end
    local rule = w - lw - 6 - (right and rw + 6 or 0)
    Draw.rect(L, x + lw + 6, y + floor(fh / 2), rule, 1, p.border)
    return y + fh + 4
end

-- The name plate: the machine's icon, its name and number, the light with the state, the switch.
local function plate(L, m, x, y, w)
    local p, fh = L.p, L.fh
    local lm = UI.fontHeight(UIFont.Medium)
    local btn = Layout.buttonHeight()
    local h = math.max(6 + lm + fh + 6, 6 + fh + 2 + btn + 4)
    Draw.panel(L, x, y, w, h)
    for _, at in ipairs({ { x + 3, y + 3 }, { x + w - 6, y + 3 }, { x + 3, y + h - 6 }, { x + w - 6, y + h - 6 } }) do
        Draw.rect(L, at[1], at[2], 3, 3, p.border)
    end
    local ib = UI.iconSize(h - 12, h - 8)
    Draw.item(L, m.icon, x + 10, y + floor((h - ib) / 2), ib)
    local right = x + w - 10
    local light = m.light
    local lc = colour(p, light.tone)
    local lightW = math.max(170, floor(w * 0.4))
    local sw = Draw.fit(L, light.text, right - lightW, y + 6, lightW, lc, nil, nil, "right")
    local d = 8
    local lx, ly = right - sw - d - 6, y + 6 + floor((fh - d) / 2)
    if light.hollow then Draw.frame(L, lx, ly, d, d, lc) else Draw.rect(L, lx, ly, d, d, lc) end
    local used = sw + d + 6
    local switchW = 0
    if m.switch then
        switchW = buttonWidth(m.switch.label)
        local tip = m.switch.tip and Draw.tip(p, { m.switch.tip }) or nil
        Draw.button(L, right - switchW, y + h - 4 - btn, switchW, btn, m.switch.label,
            m.switch.enabled and "normal" or "disabled", nil, "switch", tip)
    end
    local nx = x + 10 + ib + 10
    Draw.fit(L, m.title, nx, y + 6, right - used - 10 - nx, p.bright, UIFont.Medium)
    Draw.fit(L, m.tag, nx, y + 6 + lm, right - (switchW > 0 and switchW + 10 or 0) - nx, p.dim)
    return y + h
end

-- What it does, or what to do next, against a bar of the state's colour (broken at spaces to the width).
local function strip(L, s, x, y, w)
    local p, fh = L.p, L.fh
    local c = colour(p, s.tone)
    local lines = Draw.wrap(s.text, w - 16)
    local h = math.max(1, #lines) * fh + 6
    Draw.rect(L, x, y, w, h, c, 0.10)
    Draw.rect(L, x, y, 3, h, c)
    for i, line in ipairs(lines) do Draw.fit(L, line, x + 10, y + 3 + (i - 1) * fh, w - 16, p.text) end
    return y + h
end

-- The jobs, a lane each, in a panel (the room of the motor's lanes is kept, so the window does not jump as jobs come
-- and go). Its height for the lanes, and the panel drawn `h` high (its rows in the middle).
local function laneRow(L)
    return math.max(L.fh, ICON) + 4
end

local function jobsHeight(L, j)
    return 6 + math.max(j.lanes or 1, 2) * laneRow(L) + 2
end

local function jobsPanel(L, j, x, y, w, h)
    local p, fh = L.p, L.fh
    local row = laneRow(L)
    local rows = math.max(j.lanes or 1, 2)
    if j.empty then
        Draw.box(L, x, y, w, h, p.inset, 0.6, p.border, 0.7)
        local cy = y + floor((h - 2 * fh) / 2)
        Draw.fit(L, j.empty[1], x + 8, cy, w - 16, p.text, nil, nil, "centre")
        Draw.fit(L, j.empty[2], x + 8, cy + fh, w - 16, p.dim, nil, nil, "centre")
        return
    end
    Draw.panel(L, x, y, w, h)
    local pctW = UI.textWidth("100%") + 4
    local ix, iw = x + 8, w - 16
    local nameW = floor(iw * 0.3)
    local top = y + floor((h - rows * row) / 2) + 2
    for i, r in ipairs(j.rows) do
        if i > rows then break end
        local ry = top + (i - 1) * row
        Draw.item(L, r.icon, ix, ry + floor((row - ICON) / 2), ICON)
        local nx = ix + ICON + 6
        Draw.fit(L, r.name, nx, ry + floor((row - fh) / 2), nameW, p.text)
        local bx = nx + nameW + 6
        Draw.progress(L, bx, ry + floor((row - BAR) / 2), ix + iw - pctW - 6 - bx, BAR, r.share, p.value)
        Draw.fit(L, r.pct, ix + iw - pctW, ry + floor((row - fh) / 2), pctW, p.value, nil, nil, "right")
    end
end

local function jobs(L, j, x, y, w)
    y = head(L, x, y, w, getText("IGUI_OA_Machine_Jobs"), j.right)
    local h = jobsHeight(L, j)
    jobsPanel(L, j, x, y, w, h)
    return y + h
end

-- A bin: the name, the weight in it of what it holds ("38.4 / 100", the game's weight, no unit), the button that opens
-- it in the loot window, its fill, and a note (how many things, what it waits for). Drawn `h` high, its lines in the
-- middle.
local function binHeight(L)
    return 5 + Layout.buttonHeight() + 3 + BAR + 3 + L.fh + 5
end

local function bin(L, b, x, y, w, h)
    local p, fh = L.p, L.fh
    local btn = Layout.buttonHeight()
    Draw.panel(L, x, y, w, h)
    local by = y + floor((h - binHeight(L)) / 2)
    local open = getText("IGUI_OA_Machine_Open")
    local ow = buttonWidth(open)
    local hit = Draw.button(L, x + w - 8 - ow, by + 5, ow, btn, open, b.strong and "strong" or "normal", nil,
        "open", Draw.tip(p, { getText("IGUI_OA_Machine_OpenTip") }))
    hit.role = b.role
    local ty = by + 5 + floor((btn - fh) / 2)
    local room = w - 16 - ow - 6
    local tw = Draw.fit(L, b.title, x + 8, ty, room, p.bright)
    if room - tw > 24 then
        Draw.run(L, { { s = b.amount, c = p.value, pad = 8 }, { s = " / " .. b.capacity, c = p.dim } },
            x + 8 + tw, ty, room - tw)
    end
    local yy = by + 5 + btn + 3
    Draw.progress(L, x + 8, yy, w - 16, BAR, b.frac, colour(p, b.tone))
    Draw.fit(L, b.note, x + 8, yy + BAR + 3, w - 16, p.dim)
end

-- The bins one above the other.
local function boxes(L, list, x, y, w)
    local h = binHeight(L)
    for i, b in ipairs(list) do bin(L, b, x, y + (i - 1) * (h + ROW_GAP), w, h) end
    return y + #list * h + (#list - 1) * ROW_GAP
end

-- Cells on a row, a number and a line under it (the tooltip of one, when it has a tip, says how it is made).
local function cells(L, list, x, y, w)
    local p, fh = L.p, L.fh
    local n = #list
    local cw = floor((w - (n - 1) * Layout.GAP) / n)
    local h = 5 + 2 * fh + 5
    for i, c in ipairs(list) do
        local cx = x + (i - 1) * (cw + Layout.GAP)
        Draw.panel(L, cx, y, cw, h)
        Draw.fit(L, c.value, cx + 7, y + 5, cw - 14, p.value)
        Draw.fit(L, c.sub, cx + 7, y + 5 + fh, cw - 14, colour(p, c.subTone))
        if c.tip then
            local hit = Draw.hit(L, cx, y, cw, h, nil, tipOf(p, c.tip))
            hit.hover = true
        end
    end
    return y + h
end

-- The performance: three cells on a row.
local function perf(L, pf, x, y, w)
    y = head(L, x, y, w, getText("IGUI_OA_Machine_Perf"), pf.right)
    return cells(L, pf.cells, x, y, w)
end

-- A card a part: its icon (no well: a whole multiple of its pixels, UI.iconSize), the slot and the tier, the buttons that
-- make sense, its condition with the line under which it is worn, the hours of running it has left, and what it does
-- (or what is wrong with it). An empty slot shows a bare socket, the part it takes a dark ghost in it, and what it is
-- for. Drawn `h` high, its lines in the middle.
local function cardHeight(L)
    return 3 + Layout.buttonHeight() + 1 + L.fh + L.fh + 3
end

local function card(L, c, x, y, w, h)
    local p, fh = L.p, L.fh
    local btn = Layout.buttonHeight()
    local ch = cardHeight(L)
    local ib = UI.iconSize(40, ch - 12)
    Draw.panel(L, x, y, w, h)
    local iy = y + floor((h - ib) / 2)
    if c.empty then
        -- a sunken well in a dashed frame (3 on, 3 off), the part it takes a dark ghost in it
        local sx, sy, ss = x + 7, iy - 3, ib + 6
        Draw.rect(L, sx, sy, ss, ss, p.inset)
        for d = 0, ss - 1, 6 do
            local n = math.min(3, ss - d)
            Draw.rect(L, sx + d, sy, n, 1, p.dim, 0.7)
            Draw.rect(L, sx + d, sy + ss - 1, n, 1, p.dim, 0.7)
            Draw.rect(L, sx, sy + d, 1, n, p.dim, 0.7)
            Draw.rect(L, sx + ss - 1, sy + d, 1, n, p.dim, 0.7)
        end
        if c.icon then Draw.item(L, c.icon, x + 10, iy, ib, 0.35, { p.dim[1] * 0.5, p.dim[2] * 0.5, p.dim[3] * 0.5 }) end
    elseif c.icon then
        Draw.item(L, c.icon, x + 10, iy, ib, c.broken and 0.45 or 1)
    end
    y = y + floor((h - ch) / 2)
    local tx = x + 10 + ib + 10
    local right = x + w - 6
    local bx = right
    for k = #c.buttons, 1, -1 do
        local b = c.buttons[k]
        local bw = buttonWidth(b.label)
        bx = bx - bw
        local hit = Draw.button(L, bx, y + 3, bw, btn, b.label, b.strong and "strong" or "normal", nil, "part",
            b.tip and Draw.tip(p, { b.tip }) or nil)
        hit.slot, hit.action = c.slot, b.id
        bx = bx - 6
    end
    local ry = y + 3 + floor((btn - fh) / 2)
    local nw = Draw.fit(L, c.name, tx, ry, math.max(0, bx - 4 - tx), p.bright)
    local chipW = UI.textWidth(c.tier) + 12
    local cx = tx + nw + 6
    if cx + chipW <= bx - 4 then
        Draw.rect(L, cx, ry + 1, chipW, fh - 2, c.empty and p.inset or p.title)
        Draw.fit(L, c.tier, cx, ry, chipW, c.empty and p.dim or p.text, nil, nil, "centre")
    end
    local y2 = y + 3 + btn + 1
    if c.empty then
        -- one line, in the middle of the two a part's card has under its name
        Draw.fit(L, c.effect, tx, y2 + floor(fh / 2), right - tx, colour(p, c.effectTone))
        return
    end
    local tone = colour(p, c.tone)
    local pctW = UI.textWidth("100%") + 4
    local lifeW = math.min(UI.textWidth(c.life), floor((right - tx) / 2))
    local barW = right - tx - pctW - lifeW - 16
    local by = y2 + floor((fh - BAR) / 2)
    Draw.progress(L, tx, by, barW, BAR, c.frac, tone)
    Draw.rect(L, tx + floor(barW * Data.WORN_BELOW / Data.CONDITION_MAX), by - 3, 1, BAR + 6, p.warn, 0.9)
    Draw.fit(L, c.pct, tx + barW + 4, y2, pctW, tone, nil, nil, "right")
    Draw.fit(L, c.life, right - lifeW, y2, lifeW, colour(p, c.lifeTone), nil, nil, "right")
    Draw.fit(L, c.effect, tx, y2 + fh, right - tx, colour(p, c.effectTone))
end

-- The rain storage: a gauge with its marks, what it holds and has room for, and the game's own two ways with its water.
local function rain(L, r, x, y, w)
    local p, fh = L.p, L.fh
    local lm = UI.fontHeight(UIFont.Medium)
    local btn = Layout.buttonHeight()
    y = head(L, x, y, w, getText("IGUI_OA_Machine_Water"), r.right)
    local gw, gh = 56, 4 * fh + 16
    local gx, gy = x + 4, y + 2
    Draw.box(L, gx, gy, gw, gh, p.inset, 1, p.border)
    local level = floor((gh - 2) * r.frac)
    if level > 0 then
        Draw.rect(L, gx + 1, gy + gh - 1 - level, gw - 2, level, p.water, 0.55)
        Draw.rect(L, gx + 1, gy + gh - 1 - level, gw - 2, math.min(2, level), p.water, 0.95)
    end
    local markW = 0
    for _, t in ipairs(r.ticks) do markW = math.max(markW, UI.textWidth(t)) end
    for k = 1, #r.ticks do
        local ky = gy + gh - floor(gh * k / 4)
        Draw.rect(L, gx + gw - 10, ky, 10, 1, p.text, 0.7)
        Draw.text(L, r.ticks[k], gx + gw + 6, ky - floor(fh / 2), p.dim)
    end
    local rx = gx + gw + 6 + markW + 16
    local rw = x + w - rx
    local yy = gy
    Draw.fit(L, getText("IGUI_OA_Machine_Rain_Collected"), rx, yy, rw, p.dim)
    yy = yy + fh
    Draw.run(L, { { s = r.water .. " L", c = p.value, font = UIFont.Medium },
        { s = " / " .. r.capacity .. " L", c = p.dim, font = UIFont.Medium } }, rx, yy, rw)
    yy = yy + lm + 4
    local lw = 0
    for _, row in ipairs(r.rows) do lw = math.max(lw, UI.textWidth(row[1])) end
    lw = math.min(lw + 10, floor(rw / 2))
    for _, row in ipairs(r.rows) do
        Draw.fit(L, row[1], rx, yy, lw - 4, p.dim)
        Draw.fit(L, row[2], rx + lw, yy, rw - lw, p.text)
        yy = yy + fh + 2
    end
    y = math.max(gy + gh, yy) + 8
    local bx = x
    for _, b in ipairs({ { id = "rain:transfer", key = "IGUI_OA_Machine_Rain_Transfer", on = r.canTransfer },
        { id = "rain:empty", key = "IGUI_OA_Machine_Rain_Empty", on = r.canEmpty } }) do
        local label = getText(b.key)
        local bw = buttonWidth(label)
        Draw.button(L, bx, y, bw, btn, label, b.on and "normal" or "disabled", nil, b.id)
        bx = bx + bw + 6
    end
    Draw.fit(L, getText("IGUI_OA_Machine_Rain_Note"), bx + 4, y + floor((btn - fh) / 2), x + w - bx - 4, p.dim)
    return y + btn
end

-- The lure: the hours it has left, an hour a cell, when it sounds next and how far, and taking it back or clearing it.
local function lure(L, u, x, y, w)
    local p, fh = L.p, L.fh
    local lm = UI.fontHeight(UIFont.Medium)
    local btn = Layout.buttonHeight()
    y = head(L, x, y, w, getText("IGUI_OA_Machine_LureLeft"), u.right)
    Draw.fit(L, u.big, x, y, w, u.left > 0 and p.value or p.dim, UIFont.Medium)
    y = y + lm + 4
    local cells, ch = u.hours, 12
    for i = 0, cells - 1 do
        local cx = x + floor(i * w / cells)
        local cw = floor((i + 1) * w / cells) - floor(i * w / cells) - 2
        Draw.box(L, cx, y, cw, ch, p.inset, 1, p.border, 0.7)
        local fill = OA.clamp(u.left - i, 0, 1)
        local fh2 = floor((ch - 2) * fill)
        if fh2 > 0 then Draw.rect(L, cx + 1, y + ch - 1 - fh2, cw - 2, fh2, p.good, 0.85) end
    end
    y = y + ch + 2
    Draw.text(L, u.ends[1], x, y, p.dim)
    Draw.textCentre(L, u.ends[2], x + floor(w / 2), y, p.dim)
    Draw.textRight(L, u.ends[3], x + w, y, p.dim)
    y = y + fh + 4
    local lw = 0
    for _, row in ipairs(u.rows) do lw = math.max(lw, UI.textWidth(row[1])) end
    lw = math.min(lw + 12, floor(w / 2))
    for _, row in ipairs(u.rows) do
        Draw.fit(L, row[1], x, y, lw - 4, p.dim)
        Draw.fit(L, row[2], x + lw, y, w - lw, u.spent and p.dim or p.text)
        y = y + fh + 2
    end
    y = y + 6
    local b = u.button
    local bw = buttonWidth(b.label)
    Draw.button(L, x, y, bw, btn, b.label, "normal", nil, b.id)
    Draw.fit(L, b.note, x + bw + 10, y + floor((btn - fh) / 2), w - bw - 10, p.dim)
    return y + btn
end

-- The two columns of a machine with parts, from y, under their heads on one line: on the left the jobs and the bins,
-- on the right a card a part, in rows: a row is as tall as the taller of its two blocks, both drawn that tall, so that
-- the edges of the two columns line up (the jobs beside the motor, the bins beside the other parts). No kind with parts
-- has the rain's or the lure's section. Returns the lower end.
local function columns(L, m, x, y, w)
    local lw = Layout.LEFT
    local rx = x + lw + Layout.COLUMN_GAP
    local rw = w - lw - Layout.COLUMN_GAP
    local top = head(L, x, y, lw, getText("IGUI_OA_Machine_Jobs"), m.jobs and m.jobs.right)
    head(L, rx, y, rw, getText("IGUI_OA_Machine_Parts"), getText("IGUI_OA_Machine_Parts_WornLine"))
    local left, right = {}, {}
    if m.jobs then
        left[#left + 1] = { h = jobsHeight(L, m.jobs), draw = function(yy, hh) jobsPanel(L, m.jobs, x, yy, lw, hh) end }
    end
    for _, b in ipairs(m.boxes or {}) do
        left[#left + 1] = { h = binHeight(L), draw = function(yy, hh) bin(L, b, x, yy, lw, hh) end }
    end
    for _, c in ipairs(m.parts) do
        right[#right + 1] = { h = cardHeight(L), draw = function(yy, hh) card(L, c, rx, yy, rw, hh) end }
    end
    local yy = top
    for k = 1, math.max(#left, #right) do
        local hh = math.max(left[k] and left[k].h or 0, right[k] and right[k].h or 0)
        if left[k] then left[k].draw(yy, hh) end
        if right[k] then right[k].draw(yy, hh) end
        yy = yy + hh + ROW_GAP
    end
    return yy - ROW_GAP
end

-- The bench ----------------------------------------------------------------------------------------------------------

-- A row of the bench's list: as tall as its icon or a button, with room around.
local BENCH_ICON = 24

function Layout.benchRow(L)
    return math.max(L.fh, BENCH_ICON, Layout.buttonHeight()) + 6
end

-- A kind's row: its icon, its name (bright when some of it is chosen) with a chip when it was never shredded, the
-- weight of one, and on the right how many to shred between [-] and [+]. A click on the row picks all of it, or none
-- when all is picked. A chosen row is tinted, a bar on its left.
local function benchRow(L, r, x, y, w, h, locked)
    local p, fh = L.p, L.fh
    local btn = Layout.buttonHeight()
    if r.chosen > 0 then
        Draw.rect(L, x, y, w, h, p.value, 0.08)
        Draw.rect(L, x, y, 2, h, p.value)
    end
    local row = Draw.hit(L, x, y, w, h, "row", nil, not locked)
    row.index, row.hover = r.index, not locked
    Draw.item(L, r.icon, x + 8, y + floor((h - BENCH_ICON) / 2), BENCH_ICON, r.chosen > 0 and 1 or 0.75)
    local by = y + floor((h - btn) / 2)
    local ty = y + floor((h - fh) / 2)
    local right = x + w - 6
    local plus = Draw.button(L, right - btn, by, btn, btn, "+", r.canMore and "normal" or "disabled", nil, "more")
    plus.index = r.index
    local numW = UI.textWidth("000 / 000") + 8
    local nx = right - btn - numW
    local pickW, ofW = UI.textWidth(r.pick), UI.textWidth(r.of)
    local sx = nx + floor((numW - pickW - ofW) / 2)
    Draw.text(L, r.pick, sx, ty, r.chosen > 0 and p.value or p.dim)
    Draw.text(L, r.of, sx + pickW, ty, p.dim)
    local minus = Draw.button(L, nx - btn, by, btn, btn, "-", r.canLess and "normal" or "disabled", nil, "less")
    minus.index = r.index
    local tx = x + 8 + BENCH_ICON + 8
    local room = nx - btn - 10 - tx
    local weightW = math.min(UI.textWidth(r.weight), floor(room / 3))
    Draw.fit(L, r.weight, tx + room - weightW, ty, weightW, p.dim, nil, nil, "right")
    local chipW = r.first and UI.textWidth(r.first) + 12 or 0
    local nameRoom = room - weightW - 8 - (chipW > 0 and chipW + 6 or 0)
    local nw = Draw.fit(L, r.name, tx, ty, math.max(0, nameRoom), r.chosen > 0 and p.bright or p.text)
    if r.first then
        local cx = tx + nw + 6
        Draw.rect(L, cx, ty + 1, chipW, fh - 2, p.good, 0.22)
        Draw.fit(L, r.first, cx, ty, chipW, p.good, nil, nil, "centre")
        local chip = Draw.hit(L, cx, ty, chipW, fh, "row", Draw.tip(p, { r.firstTip }), not locked)
        chip.index, chip.hover = r.index, not locked
    end
end

-- The list: the rows in a panel kept as tall as its rows shown (the window does not jump as kinds come and go), a bar on
-- the right when there are more. Its place is kept on the list (L.benchList) for the mouse wheel.
local function benchList(L, list, x, y, w)
    local p, fh = L.p, L.fh
    local rh = Layout.benchRow(L)
    local h = 4 + list.shown * rh + 4
    Draw.panel(L, x, y, w, h)
    L.benchList = { x = x, y = y, w = w, h = h }
    if list.empty then
        Draw.fit(L, list.empty, x + 8, y + floor((h - fh) / 2), w - 16, p.dim, nil, nil, "centre")
        return y + h
    end
    local rw = w - 8
    if list.total > list.shown then
        rw = w - 16
        local span = list.total - list.shown
        Draw.scrollbar(L, x + w - 10, y + 4, h - 8, (list.top - 1) / span, list.shown / list.total)
    end
    for i, r in ipairs(list.rows) do
        benchRow(L, r, x + 4, y + 4 + (i - 1) * rh, rw, rh, list.locked)
    end
    return y + h
end

-- The buttons under the list: picking all or none and starting, or while it works how far it is and stopping.
local function benchActions(L, m, x, y, w)
    local p, fh = L.p, L.fh
    local btn = Layout.buttonHeight()
    local ty = y + floor((btn - fh) / 2)
    if m.work then
        -- how many are done, then a bar as tall as the button, filled by the time done, the time left written in it
        local stop = getText("IGUI_OA_Bench_Stop")
        local sw = buttonWidth(stop)
        Draw.button(L, x + w - sw, y, sw, btn, stop, m.work.finished and "disabled" or "normal", nil, "stop")
        local room = w - sw - 10
        local tw = Draw.fit(L, m.work.text, x, ty, floor(room / 3), p.text)
        local bx = x + tw + 10
        local bw = room - tw - 10
        Draw.rect(L, bx, y, bw, btn, p.inset)
        Draw.rect(L, bx, y, floor(bw * m.work.share), btn, p.good, 0.35)
        Draw.frame(L, bx, y, bw, btn, p.border)
        if m.work.left ~= "" then Draw.fit(L, m.work.left, bx + 4, ty, bw - 8, p.bright, nil, nil, "centre") end
        return y + btn
    end
    local bx = x
    for _, b in ipairs({ { id = "all", key = "IGUI_OA_Bench_All", on = m.canAll },
        { id = "none", key = "IGUI_OA_Bench_None", on = m.canNone } }) do
        local label = getText(b.key)
        local bw = buttonWidth(label)
        Draw.button(L, bx, y, bw, btn, label, b.on and "normal" or "disabled", nil, b.id)
        bx = bx + bw + 6
    end
    local start = getText("IGUI_OA_Bench_Start")
    local sw = math.max(buttonWidth(start), 96)
    Draw.button(L, x + w - sw, y, sw, btn, start, m.canStart and "strong" or "disabled", nil, "start")
    return y + btn
end

-- Lays the bench's model (BenchModel.lua) out for a body `width` wide; returns the height it takes.
function Layout.bench(L, m, width)
    local x, w = Layout.PAD, width - 2 * Layout.PAD
    local y = plate(L, m, x, Layout.PAD, w) + Layout.GAP
    y = strip(L, m.strip, x, y, w)
    y = head(L, x, y + Layout.SECTION, w, getText("IGUI_OA_Bench_Carried"), m.list.right)
    y = benchList(L, m.list, x, y, w)
    y = cells(L, m.cells, x, y + Layout.GAP, w)
    y = benchActions(L, m, x, y + Layout.SECTION, w)
    return y + Layout.PAD
end

-- Lays a model out into a list for a body `width` wide (Layout.widthOf); returns the height it takes.
function Layout.build(L, m, width)
    local x, w = Layout.PAD, width - 2 * Layout.PAD
    local y = plate(L, m, x, Layout.PAD, w) + Layout.GAP
    y = strip(L, m.strip, x, y, w)
    if m.parts then
        if m.perf then y = perf(L, m.perf, x, y + Layout.SECTION, w) end
        return columns(L, m, x, y + Layout.SECTION, w) + Layout.PAD
    end
    if m.jobs then y = jobs(L, m.jobs, x, y + Layout.SECTION, w) end
    if m.boxes and #m.boxes > 0 then y = boxes(L, m.boxes, x, y + Layout.GAP, w) end
    if m.perf then y = perf(L, m.perf, x, y + Layout.SECTION, w) end
    if m.rain then y = rain(L, m.rain, x, y + Layout.SECTION, w) end
    if m.lure then y = lure(L, m.lure, x, y + Layout.SECTION, w) end
    return y + Layout.PAD
end

-- The part picker: the parts the character carries that fit a slot, a row each (icon, name, condition, what it does).
-- pick = { title, none (the text when there is none), rows = { { icon, name, cond, tone, effect } } }. Returns its
-- height; a row's hit is "pick" with its index.
function Layout.picker(L, pick, w)
    local p, fh = L.p, L.fh
    local rh = 2 * fh + 6
    local top = 4 + fh + 4
    local h = top + math.max(1, #pick.rows) * rh + 4
    Draw.box(L, 0, 0, w, h, p.bg, 0.98, p.value, 0.8)
    Draw.fit(L, pick.title, 8, 4, w - 16, p.dim)
    if #pick.rows == 0 then
        Draw.fit(L, pick.none, 8, top + floor((rh - fh) / 2), w - 16, p.text)
        return h
    end
    local cw = UI.textWidth("100%") + 4
    local y = top
    for i, r in ipairs(pick.rows) do
        local hit = Draw.hit(L, 2, y, w - 4, rh, "pick", nil, true)
        hit.index, hit.hover = i, true
        Draw.item(L, r.icon, 8, y + floor((rh - 28) / 2), 28)
        Draw.fit(L, r.name, 44, y + 3, w - 44 - cw - 12, p.bright)
        Draw.fit(L, r.cond, w - 8 - cw, y + 3, cw, colour(p, r.tone), nil, nil, "right")
        Draw.fit(L, r.effect, 44, y + 3 + fh, w - 52, p.dim)
        y = y + rh
    end
    return h
end

return Layout
