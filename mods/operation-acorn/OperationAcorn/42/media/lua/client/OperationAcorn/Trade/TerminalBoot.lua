-- The console of the terminal window's boot sequence (DESIGN-terminal 12, Trade/BootSeq): a black panel over the strip
-- and the body, the screen coming on, the terminal's static behind it all (Trade/TerminalStatic's tiles, scrolling as
-- they do in the window), the lines printed one at a time (the words, a blinking cursor, then what the line ends with), then
-- the switch-off. The crude terminal's console flickers, garbles and now and then jolts (Seq.shake). The window owns the
-- run and takes this panel off when the fade-in starts (the fade itself is drawn by the window, over its tabs, so
-- that the tabs are usable through it). A click or a key skips it, from the terminal's second open on.
require "ISUI/ISPanel"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/BootSeq"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/TerminalStatic"
local OA = OperationAcorn
local Seq, UI = OA.Trade.BootSeq, OA.Trade.UI

local BLACK = { 0, 0, 0 }

OATerminalBoot = ISPanel:derive("OATerminalBoot")

-- The face of the lines (the welcome is in UI.titleFont), the gap between rows, the extra gap above the welcome (design
-- units).
OATerminalBoot.FONT = UIFont.Large
OATerminalBoot.ROW_GAP = 6
OATerminalBoot.LAST_GAP = 16
-- The bright line's thickness and the dot's width.
OATerminalBoot.LINE = 2
OATerminalBoot.DOT = 4

function OATerminalBoot:new(x, y, width, height, window, run)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.window = window
    o.run = run
    o.background = false
    local record = OA.Client.record(window.character)
    o.number = string.format("%04d", record and record.number or 0)
    o.tiles = { getTexture(OATerminalStatic.TILES[1]), getTexture(OATerminalStatic.TILES[2]) }
    return o
end

-- The lit screen over the rows y to y + h: the window's background and, on a screen that has them, its scan lines (as
-- the window draws them behind its tabs).
function OATerminalBoot:drawScreen(y, h)
    if h <= 0 then return end
    local p = self.window.palette
    UI.fill(self, 0, y, self.width, h, p.bg)
    local lines = self.window.scanline
    if p.scanlines and lines then
        local c = p.text
        self:drawTextureTiled(lines, 0, y, self.width, h, c[1], c[2], c[3], 0.07)
    end
end

-- The static at `e` ms over the rows y to y + h (k: how loud, 1 its level in the boot), as the window's static panel
-- draws it: its tiles keep their own size in pixels. The boot's empty screen shows it louder than the window does.
function OATerminalBoot:drawStatic(e, y, h, k)
    local S = OATerminalStatic
    local tex = self.tiles[OA.remainder(math.floor(e / S.SWAP_MS), 2) + 1]
    if not tex or h <= 0 or k <= 0 then return end
    local c = self.window.palette.text
    local tile = S.TILE / UI.S
    local off = OA.remainder(math.floor(e * S.SPEED / 1000), S.TILE) / UI.S - tile
    local a = math.min(1, S.alphaOf(self.window.tier) * S.BOOT * k)
    self:setStencilRect(0, y, self.width, h)
    self:drawTextureTiled(tex, 0, y + off, self.width, h + tile, c[1], c[2], c[3], a)
    UI.unclip(self, 0, y, self.width, h)
end

-- The screen coming on (Seq.powerOn): the raster opening from the middle, its static loud, its leading edges a soft
-- glow in the screen's colour (a few rows thinning inwards, no hard line), a faint warmth over it, then the band that
-- rolls down once.
OATerminalBoot.EDGE_ROWS = 5

function OATerminalBoot:drawPowerOn(e, open, edge, warm, loud, roll)
    local p = self.window.palette
    local band = open * self.height
    if band <= 0 then return end
    local top = (self.height - band) / 2
    self:drawScreen(top, band)
    self:drawStatic(e, top, band, loud)
    if warm > 0 then UI.fill(self, 0, top, self.width, band, p.text, warm) end
    if roll then
        local rh = self.height / 5
        local ry = roll * (self.height + rh) - rh
        local y0, y1 = math.max(top, ry), math.min(top + band, ry + rh)
        if y1 > y0 then UI.fill(self, 0, y0, self.width, y1 - y0, p.text, 0.05 * (1 - roll * 0.5)) end
    end
    if edge > 0 then
        local n = OATerminalBoot.EDGE_ROWS
        local row = math.max(1, math.min(3, band / (2 * n)))
        for i = 0, n - 1 do
            local a = edge * (1 - i / n) * (1 - i / n)
            UI.fill(self, 0, top + i * row, self.width, row, p.text, a)
            UI.fill(self, 0, top + band - (i + 1) * row, self.width, row, p.text, a)
        end
    end
end

-- The rows, worked out when the panel is laid out: the words, where what the line ends with (and the cursor before
-- it) stands, and the row's place. The welcome, larger, is centred; the console's rows are a block, left aligned, set
-- as if halfway between their widest row and the welcome in width: under the welcome's left edge it looks left of the
-- middle, centred by its widest row (its other rows' ends ragged) right of it.
function OATerminalBoot:layout()
    if self.laidW == self.width and self.laidH == self.height then return end
    local font = OATerminalBoot.FONT
    local fh = UI.fontHeight(font)
    local gap = UI.spaceWidth(font)
    local rowH = fh + OATerminalBoot.ROW_GAP
    local rows, bw, welcome = {}, 0, 0
    for i, line in ipairs(self.run.lines) do
        local row = { text = getText(line.key, self.number), bright = line.bright }
        if line.bright then
            welcome = math.max(welcome, UI.textWidth(row.text, UI.titleFont()))
            row.h = UI.fontHeight(UI.titleFont())
        else
            row.status = line.status and getText(line.status) or nil
            row.statusX = UI.textWidth(row.text, font) + gap
            bw = math.max(bw, row.statusX + (row.status and UI.textWidth(row.status, font) or 0))
            row.h = fh
        end
        row.y = (i - 1) * rowH + (line.bright and OATerminalBoot.LAST_GAP or 0)
        rows[i] = row
    end
    local last = rows[#rows]
    self.rows = rows
    self.fh = fh
    self.cursorW = math.max(2, math.floor(fh * 0.45))
    self.blockH = last and last.y + last.h or 0
    self.bw = math.min(bw, self.width - 40)
    local seen = (self.bw + math.max(welcome, self.bw)) / 2
    self.bx = math.max(20, math.floor((self.width - seen) / 2))
    self.by = math.max(0, math.floor((self.height - self.blockH) / 2))
    self.skipText = not self.run.locked and getText("IGUI_OA_Status_Boot_Skip") or nil
    self.laidW, self.laidH = self.width, self.height
end

-- One row at y, in the palette: the words, then the cursor while it blinks or what the line ends with in the value
-- colour; the welcome bright, larger and centred. `a` the brightness, `age` ms since the row appeared, `ended` whether
-- what it ends with is up.
function OATerminalBoot:drawRow(row, i, y, a, age, ended)
    local p = self.window.palette
    local text = row.text
    local bx = self.bx + self.shiftX
    if self.run.crude and not row.bright then text = Seq.garble(text, i, age) end
    if row.bright then
        UI.textCentre(self, text, self.width / 2 + self.shiftX, y, p.bright, UI.titleFont(), a)
        return
    end
    UI.text(self, text, bx, y, p.text, OATerminalBoot.FONT, a)
    if ended then
        if row.status then UI.text(self, row.status, bx + row.statusX, y, p.value, OATerminalBoot.FONT, a) end
    elseif Seq.cursorOn(age) then
        UI.fill(self, bx + row.statusX, y + self.fh * 0.12, self.cursorW, self.fh * 0.76, p.text, a)
    end
end

function OATerminalBoot:prerender()
    local run = self.run
    local phase, shown, t, e = Seq.state(run, getTimestampMs())
    UI.fill(self, 0, 0, self.width, self.height, BLACK)
    if phase == "fade" or phase == "done" then return end
    local open, edge, warm, loud, roll = Seq.powerOn(e)
    if open then return self:drawPowerOn(e, open, edge, warm, loud, roll) end
    self:layout()
    local p = self.window.palette
    local a = run.crude and Seq.flicker(e) or 1
    -- the crude screen jolts now and then while it prints (the switch-off stays still)
    local shiftY = 0
    self.shiftX = 0
    if run.crude and phase == "console" then self.shiftX, shiftY = Seq.shake(e) end
    local cy = self.by + self.blockH / 2
    if phase == "collapse" then
        -- The lines fall towards the middle, seen through a band that narrows to the line.
        local k, lineW, lineA = Seq.switchOff(t)
        local band = math.max(OATerminalBoot.LINE, self.blockH * k)
        -- the static goes with the picture: the whole screen's, falling to the line
        local screen = self.height * k
        self:drawScreen(cy - screen / 2, screen)
        self:drawStatic(e, cy - screen / 2, screen, k)
        self:setStencilRect(0, cy - band / 2, self.width, band)
        for i = 1, shown do
            local row = self.rows[i]
            local y = cy + (self.by + row.y + row.h / 2 - cy) * k - row.h / 2
            self:drawRow(row, i, y, a * k, 1e9, true)
        end
        UI.unclip(self, 0, cy - band / 2, self.width, band)
        local w = math.max(OATerminalBoot.DOT, self.width * lineW)
        UI.fill(self, (self.width - w) / 2, cy - OATerminalBoot.LINE / 2, w, OATerminalBoot.LINE, p.bright, lineA)
        return
    end
    self:drawScreen(0, self.height)
    self:drawStatic(e, 0, self.height, a)
    for i = 1, shown do
        local row = self.rows[i]
        self:drawRow(row, i, self.by + shiftY + row.y, a, e - Seq.appearAt(run, i), e >= Seq.statusAt(run, i))
    end
    if self.skipText then
        UI.textRight(self, self.skipText, self.width - 8, self.height - UI.fontHeight() - 6, p.dim, nil, a)
    end
end

-- The console is all there is to click on: a click anywhere skips it.
function OATerminalBoot:onMouseDown()
    self.window:bootSkip()
    return true
end

function OATerminalBoot:onRightMouseDown()
    self.window:bootSkip()
    return true
end

function OATerminalBoot:onMouseWheel()
    return true
end

UI.scaled(OATerminalBoot, ISPanel)

return OATerminalBoot
