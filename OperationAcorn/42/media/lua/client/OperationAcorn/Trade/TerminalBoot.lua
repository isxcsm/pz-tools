-- The console of the terminal window's boot sequence (DESIGN-terminal 12, Trade/BootSeq): a black panel over the strip
-- and the body, the lines printed one at a time (the words, a blinking cursor, then what the line ends with), then
-- the switch-off. The window owns the
-- run and takes this panel off when the fade-in starts (the fade itself is drawn by the window, over its tabs, so
-- that the tabs are usable through it). A click or a key skips it.
require "ISUI/ISPanel"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/BootSeq"
require "OperationAcorn/Trade/UI"
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
    return o
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
    if self.run.crude and not row.bright then text = Seq.garble(text, i, age) end
    if row.bright then
        UI.textCentre(self, text, self.bx + self.bw / 2, y, p.bright, UI.titleFont(), a)
        return
    end
    UI.text(self, text, self.bx, y, p.text, OATerminalBoot.FONT, a)
    if ended then
        if row.status then UI.text(self, row.status, self.bx + row.statusX, y, p.value, OATerminalBoot.FONT, a) end
    elseif Seq.cursorOn(age) then
        UI.fill(self, self.bx + row.statusX, y + self.fh * 0.12, self.cursorW, self.fh * 0.76, p.text, a)
    end
end

function OATerminalBoot:prerender()
    local run = self.run
    local phase, shown, t, e = Seq.state(run, getTimestampMs())
    UI.fill(self, 0, 0, self.width, self.height, BLACK)
    if phase == "fade" or phase == "done" then return end
    self:layout()
    local p = self.window.palette
    local a = run.crude and Seq.flicker(e) or 1
    local cy = self.by + self.blockH / 2
    if phase == "collapse" then
        -- The lines fall towards the middle, seen through a band that narrows to the line.
        local k, lineW, lineA = Seq.switchOff(t)
        local band = math.max(OATerminalBoot.LINE, self.blockH * k)
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
    for i = 1, shown do
        self:drawRow(self.rows[i], i, self.by + self.rows[i].y, a, e - Seq.appearAt(run, i), e >= Seq.statusAt(run, i))
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
