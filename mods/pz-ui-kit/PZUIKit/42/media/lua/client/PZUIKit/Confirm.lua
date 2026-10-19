-- Asking yes or no (UI.confirm), the kit's in place of the game's ISModalDialog, which draws in the game's font: a panel
-- in design units and the kit's faces (UI.lua), in the palette of the window it is asked from (UI.DEFAULT_PALETTE from
-- the world), at the
-- mouse as the game's dialog opens, kept inside the screen. Its text is broken at its line ends and to its width. A
-- note under the question (what it comes to: what a thing taken apart gives back) is in the palette's dim tone.
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "PZUIKit/Button"
local UI = PZUIKit.UI

PZUIConfirm = ISPanel:derive("PZUIConfirm")

-- The width (design units; a text that needs more breaks into lines), the margin and the buttons' width (the game's
-- dialog's numbers).
PZUIConfirm.WIDTH = 360
PZUIConfirm.PAD = 10
PZUIConfirm.BUTTON_W = 100
PZUIConfirm.TEXT_TOP = 20
PZUIConfirm.NOTE_GAP = 4   -- between the question and its note

-- `onYes()` runs when yes is pressed (after the dialog has gone). `note`, when given, goes under the text.
function PZUIConfirm:new(text, palette, onYes, note)
    local F = PZUIConfirm
    local lines = UI.wrap(text, F.WIDTH - 2 * F.PAD)
    local noteLines = note and UI.wrap(note, F.WIDTH - 2 * F.PAD) or {}
    local fh, bh = UI.fontHeight(), UI.buttonHeight()
    local h = F.TEXT_TOP + #lines * fh + (#noteLines > 0 and F.NOTE_GAP + #noteLines * fh or 0) + 20 + bh + F.PAD
    local o = ISPanel.new(self, 0, 0, F.WIDTH, h)
    o.lines, o.noteLines, o.palette, o.onYes = lines, noteLines, palette, onYes
    o.background = false
    return o
end

function PZUIConfirm:createChildren()
    local F, p = PZUIConfirm, self.palette
    local bh = UI.buttonHeight()
    local y = self.height - F.PAD - bh - 1
    self.yes = PZUIButton:new((self.width - F.PAD) / 2 - F.BUTTON_W, y, F.BUTTON_W, bh, getText("UI_Yes"), p, self,
        PZUIConfirm.onYesButton, "strong")
    self.no = PZUIButton:new((self.width + F.PAD) / 2, y, F.BUTTON_W, bh, getText("UI_No"), p, self, PZUIConfirm.onNoButton)
    for _, b in ipairs({ self.yes, self.no }) do
        b:initialise()
        b:instantiate()
        self:addChild(b)
    end
end

function PZUIConfirm:prerender()
    local p = self.palette
    UI.fill(self, 0, 0, self.width, self.height, p.bg, 0.95)
    UI.frame(self, 0, 0, self.width, self.height, p.border)
    local fh = UI.fontHeight()
    local y = PZUIConfirm.TEXT_TOP
    for _, line in ipairs(self.lines) do
        UI.textCentre(self, line, self.width / 2, y, p.text)
        y = y + fh
    end
    y = y + PZUIConfirm.NOTE_GAP
    for _, line in ipairs(self.noteLines) do
        UI.textCentre(self, line, self.width / 2, y, p.dim)
        y = y + fh
    end
end

function PZUIConfirm:destroy()
    self:setVisible(false)
    self:removeFromUIManager()
    if PZUIConfirm.open == self then PZUIConfirm.open = nil end
end

function PZUIConfirm:onYesButton()
    self:destroy()
    if self.onYes then self.onYes() end
end

function PZUIConfirm:onNoButton()
    self:destroy()
end

UI.scaled(PZUIConfirm, ISPanel)

-- Asks yes or no; onYes(target, a, b) runs on yes. In the palette of `target`'s window, else UI.DEFAULT_PALETTE; at
-- the mouse, inside the screen, above the windows opened after it. One question at a time: a new one closes the one
-- still open, whose yes would act on what has changed since. `text` is the question, or { question, note }: the note
-- under it in the dim tone.
function UI.confirm(character, text, target, onYes, a, b)
    if PZUIConfirm.open then PZUIConfirm.open:destroy() end
    UI.refreshScale()
    local palette = (type(target) == "table" and UI.paletteOf(target)) or UI.DEFAULT_PALETTE
    local question, note = text, nil
    if type(text) == "table" then question, note = text[1], text[2] end
    local modal = PZUIConfirm:new(question, palette, function() onYes(target, a, b) end, note)
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    modal.x = math.max(0, math.min(UI.dp(getMouseX()) - modal.width / 2, screenW - modal.width))
    modal.y = math.max(0, math.min(UI.dp(getMouseY()) - modal.height / 2, screenH - modal.height))
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    modal:bringToTop()
    PZUIConfirm.open = modal
    return modal
end

return PZUIConfirm
