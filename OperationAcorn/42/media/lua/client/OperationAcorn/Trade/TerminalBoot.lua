-- The console of the terminal window's boot sequence (DESIGN-terminal 12, Trade/BootSeq): a black panel over the strip
-- and the body, the lines printed one at a time with their dotted leaders, then the switch-off. The window owns the
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

-- The widest the lines go, the gap between rows, and the extra gap above the last line, in design units.
OATerminalBoot.WIDTH = 380
OATerminalBoot.ROW_GAP = 5
OATerminalBoot.LAST_GAP = 9
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

-- The rows, worked out when the panel is laid out (the words, the dotted leader that fills the room between a row's
-- words and what it ends with, and where each goes): the leaders are measured in the face, so that what each row ends
-- with stands at the same column.
function OATerminalBoot:layout()
    if self.laidW == self.width and self.laidH == self.height then return end
    local fh = UI.fontHeight()
    local gap = UI.spaceWidth()
    local bw = math.min(OATerminalBoot.WIDTH, self.width - 40)
    local rowH = fh + OATerminalBoot.ROW_GAP
    local rows = {}
    for i, line in ipairs(self.run.lines) do
        local row = { text = getText(line.key, self.number), bright = line.bright }
        if line.status then
            row.status = getText(line.status)
            local room = bw - UI.textWidth(row.text) - UI.textWidth(row.status) - gap * 2
            local dot = math.max(1, UI.textWidth("."))
            local n = math.max(0, math.floor(room / dot))
            while n > 0 and UI.textWidth(string.rep(".", n)) > room do n = n - 1 end
            row.leader = string.rep(".", n)
            row.leaderX = UI.textWidth(row.text) + gap
        end
        row.y = (i - 1) * rowH + (line.bright and OATerminalBoot.LAST_GAP or 0)
        rows[i] = row
    end
    local last = rows[#rows]
    self.rows = rows
    self.fh = fh
    self.blockH = last and last.y + fh or 0
    self.bx = math.floor((self.width - bw) / 2)
    self.bw = bw
    self.by = math.max(0, math.floor((self.height - self.blockH) / 2))
    self.skipText = self.run.first and getText("IGUI_OA_Status_Boot_Skip") or nil
    self.laidW, self.laidH = self.width, self.height
end

-- One row at y, in the palette: the words, the leader dim, what it ends with in the value colour; the last line
-- bright. `a` the brightness, `age` ms since the row appeared (the crude terminal's letters settle).
function OATerminalBoot:drawRow(row, i, y, a, age)
    local p = self.window.palette
    local text = row.text
    if self.run.crude then text = Seq.garble(text, i, age) end
    if row.bright then
        UI.text(self, text, self.bx, y, p.bright, nil, a)
        return
    end
    UI.text(self, text, self.bx, y, p.text, nil, a)
    UI.text(self, row.leader, self.bx + row.leaderX, y, p.dim, nil, a)
    UI.textRight(self, row.status, self.bx + self.bw, y, p.value, nil, a)
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
            local y = cy + (self.by + row.y + self.fh / 2 - cy) * k - self.fh / 2
            self:drawRow(row, i, y, a * k, 1e9)
        end
        self:clearStencilRect()
        local w = math.max(OATerminalBoot.DOT, self.width * lineW)
        UI.fill(self, (self.width - w) / 2, cy - OATerminalBoot.LINE / 2, w, OATerminalBoot.LINE, p.bright, lineA)
        return
    end
    for i = 1, shown do
        self:drawRow(self.rows[i], i, self.by + self.rows[i].y, a, e - Seq.appearAt(run, i))
    end
    if self.skipText then
        UI.textRight(self, self.skipText, self.width - 8, self.height - self.fh - 6, p.dim, nil, a)
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
