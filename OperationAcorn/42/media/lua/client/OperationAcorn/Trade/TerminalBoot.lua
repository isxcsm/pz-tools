-- The console of the terminal window's boot sequence (DESIGN-terminal 12, Trade/BootSeq): a black panel over the strip
-- and the body, the screen coming on, the terminal's static behind it all (Trade/TerminalStatic's tiles, scrolling as
-- they do in the window), the lines printed one at a time (the words, a blinking cursor, then what the line ends with), then
-- the switch-off. The crude terminal's console flickers, garbles and now and then jolts (Seq.shake). The window owns the
-- run and takes this panel off when the fade-in starts (the fade itself is drawn by the window, over its tabs, so
-- that the tabs are usable through it). A click or a key skips it.
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

-- The static at `e` ms over the rows y to y + h (k: how much of it shows), as the window's static panel draws it: its
-- tiles keep their own size in pixels.
function OATerminalBoot:drawStatic(e, y, h, k)
    local S = OATerminalStatic
    local tex = self.tiles[math.floor(e / S.SWAP_MS) % 2 + 1]
    if not tex or h <= 0 or k <= 0 then return end
    local c = self.window.palette.text
    local tile = S.TILE / UI.S
    local off = (math.floor(e * S.SPEED / 1000) % S.TILE) / UI.S - tile
    self:setStencilRect(0, y, self.width, h)
    self:drawTextureTiled(tex, 0, y + off, self.width, h + tile, c[1], c[2], c[3], S.alphaOf(self.window.tier) * k)
    self:clearStencilRect()
end

-- The screen coming on (Seq.powerOn): the bright line from a dot across the middle, opening into the screen in a flash
-- that dies down, the static showing in what is open.
function OATerminalBoot:drawPowerOn(e, lineW, band, lineA, flash)
    local p = self.window.palette
    local cy = self.height / 2
    local open = band * self.height
    if open > 0 then
        self:drawStatic(e, cy - open / 2, open, 1)
        if flash > 0 then UI.fill(self, 0, cy - open / 2, self.width, open, p.bright, flash) end
    end
    if lineA > 0 then
        local w = math.max(OATerminalBoot.DOT, self.width * lineW)
        UI.fill(self, (self.width - w) / 2, cy - OATerminalBoot.LINE / 2, w, OATerminalBoot.LINE, p.bright, lineA)
    end
end

-- The rows, worked out when the panel is laid out: the words, where what the line ends with (and the cursor before
-- it) stands, and the row's place; the block is as wide as its widest row and stands in the middle.
function OATerminalBoot:layout()
    if self.laidW == self.width and self.laidH == self.height then return end
    local font = OATerminalBoot.FONT
    local fh = UI.fontHeight(font)
    local gap = UI.spaceWidth(font)
    local rowH = fh + OATerminalBoot.ROW_GAP
    local rows, bw = {}, 0
    for i, line in ipairs(self.run.lines) do
        local row = { text = getText(line.key, self.number), bright = line.bright }
        local w
        if line.bright then
            w = UI.textWidth(row.text, UI.titleFont())
            row.h = UI.fontHeight(UI.titleFont())
        else
            row.status = line.status and getText(line.status) or nil
            row.statusX = UI.textWidth(row.text, font) + gap
            w = row.statusX + (row.status and UI.textWidth(row.status, font) or 0)
            row.h = fh
        end
        bw = math.max(bw, w)
        row.y = (i - 1) * rowH + (line.bright and OATerminalBoot.LAST_GAP or 0)
        rows[i] = row
    end
    local last = rows[#rows]
    self.rows = rows
    self.fh = fh
    self.cursorW = math.max(2, math.floor(fh * 0.45))
    self.blockH = last and last.y + last.h or 0
    self.bw = math.min(bw, self.width - 40)
    self.bx = math.floor((self.width - self.bw) / 2)
    self.by = math.max(0, math.floor((self.height - self.blockH) / 2))
    self.skipText = self.run.first and getText("IGUI_OA_Status_Boot_Skip") or nil
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
        UI.textCentre(self, text, bx + self.bw / 2, y, p.bright, UI.titleFont(), a)
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
    local lineW, band, lineA, flash = Seq.powerOn(e)
    if lineW then return self:drawPowerOn(e, lineW, band, lineA, flash) end
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
        self:drawStatic(e, cy - screen / 2, screen, k)
        self:setStencilRect(0, cy - band / 2, self.width, band)
        for i = 1, shown do
            local row = self.rows[i]
            local y = cy + (self.by + row.y + row.h / 2 - cy) * k - row.h / 2
            self:drawRow(row, i, y, a * k, 1e9, true)
        end
        self:clearStencilRect()
        local w = math.max(OATerminalBoot.DOT, self.width * lineW)
        UI.fill(self, (self.width - w) / 2, cy - OATerminalBoot.LINE / 2, w, OATerminalBoot.LINE, p.bright, lineA)
        return
    end
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
