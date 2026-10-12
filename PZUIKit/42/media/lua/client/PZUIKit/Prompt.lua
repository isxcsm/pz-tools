-- Asking for a line of text (UI.prompt), the kit's in place of the game's ISTextBox, which draws in the game's look: a
-- panel in design units and the kit's faces (UI.lua), in the palette of the window it is asked from, over that window's
-- middle (else the mouse), kept inside the screen. Its question is broken at its line ends and to its width; under it
-- the game's entry box in the palette, then OK and Cancel. Enter confirms, Escape cancels. It fades in and out
-- (UI.fadeIn, UI.fadeOut).
require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"
require "PZUIKit/UI"
require "PZUIKit/Button"
local UI = PZUIKit.UI

PZUIPrompt = ISPanel:derive("PZUIPrompt")

-- The width (design units), the margin and the buttons' width, as the confirm's.
PZUIPrompt.WIDTH = 360
PZUIPrompt.PAD = 10
PZUIPrompt.BUTTON_W = 100

-- `onOk(text)` runs when OK is pressed or Enter (after the dialog has begun to go).
function PZUIPrompt:new(question, text, palette, onOk)
    local F = PZUIPrompt
    local lines = UI.wrap(question, F.WIDTH - 2 * F.PAD)
    local fh, bh = UI.fontHeight(), UI.buttonHeight()
    local h = F.PAD * 2 + #lines * fh + F.PAD + bh + F.PAD + bh + F.PAD
    local o = ISPanel.new(self, 0, 0, F.WIDTH, h)
    o.lines, o.text, o.palette, o.onOk = lines, text or "", palette, onOk
    o.background = false
    return o
end

function PZUIPrompt:createChildren()
    local F, p = PZUIPrompt, self.palette
    local fh, bh = UI.fontHeight(), UI.buttonHeight()
    local entryY = F.PAD * 2 + #self.lines * fh + F.PAD
    self.entry = ISTextEntryBox:new(self.text, 0, 0, 100, 20)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry.backgroundColor = { r = p.inset and p.inset[1] or 0, g = p.inset and p.inset[2] or 0,
        b = p.inset and p.inset[3] or 0, a = 1 }
    self.entry.borderColor = { r = p.border[1], g = p.border[2], b = p.border[3], a = 1 }
    self.entry.onCommandEntered = function() self:onOkButton() end
    self.entry.onOtherKey = function(_, key)
        if key == Keyboard.KEY_ESCAPE then self:onCancelButton() end
    end
    self:addChild(self.entry)
    UI.place(self.entry, F.PAD, entryY, self.width - F.PAD * 2, bh)
    local y = self.height - F.PAD - bh
    self.ok = PZUIButton:new((self.width - F.PAD) / 2 - F.BUTTON_W, y, F.BUTTON_W, bh, getText("UI_Ok"), p, self,
        PZUIPrompt.onOkButton, "strong")
    self.cancel = PZUIButton:new((self.width + F.PAD) / 2, y, F.BUTTON_W, bh, getText("UI_Cancel"), p, self,
        PZUIPrompt.onCancelButton)
    for _, b in ipairs({ self.ok, self.cancel }) do
        b:initialise()
        b:instantiate()
        self:addChild(b)
    end
end

function PZUIPrompt:prerender()
    local p = self.palette
    UI.fill(self, 0, 0, self.width, self.height, p.bg, 0.95)
    UI.frame(self, 0, 0, self.width, self.height, p.border)
    local fh = UI.fontHeight()
    for i, line in ipairs(self.lines) do
        UI.textCentre(self, line, self.width / 2, PZUIPrompt.PAD * 2 + (i - 1) * fh, p.text)
    end
end

function PZUIPrompt:destroy()
    self.entry:unfocus()
    UI.fadeOut(self)
end

function PZUIPrompt:onOkButton()
    if self.gone then return end
    self.gone = true
    local text = self.entry:getText()
    self:destroy()
    if self.onOk then self.onOk(text) end
end

function PZUIPrompt:onCancelButton()
    if self.gone then return end
    self.gone = true
    self:destroy()
end

UI.scaled(PZUIPrompt, ISPanel)

-- Asks for a line of text, `text` in the box to begin with; onOk(target, text) runs on OK. In the palette of
-- `target`'s window, else UI.DEFAULT_PALETTE; over `over` (an element, its middle) or else at the mouse, inside the
-- screen; the box takes the keys.
function UI.prompt(character, question, text, target, onOk, over)
    UI.refreshScale()
    local palette = (type(target) == "table" and UI.paletteOf(target)) or UI.DEFAULT_PALETTE
    local modal = PZUIPrompt:new(question, text, palette, function(entered) onOk(target, entered) end)
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    local cx, cy = UI.dp(getMouseX()), UI.dp(getMouseY())
    if over then
        cx = UI.dp(over:getAbsoluteX() + over.javaObject:getWidth() / 2)
        cy = UI.dp(over:getAbsoluteY() + over.javaObject:getHeight() / 2)
    end
    modal.x = math.max(0, math.min(cx - modal.width / 2, screenW - modal.width))
    modal.y = math.max(0, math.min(cy - modal.height / 2, screenH - modal.height))
    modal:initialise()
    modal:addToUIManager()
    modal:bringToTop()
    UI.fadeIn(modal)
    modal.entry:focus()
    modal.entry:selectAll()
    return modal
end

return PZUIPrompt
