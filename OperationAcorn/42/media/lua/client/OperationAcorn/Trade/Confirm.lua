-- Asking yes or no (UI.confirm): the terminal's questions (a call, a reissue, a cancelled upgrade) and the seal of a
-- delivery box. Ours in place of the game's ISModalDialog, which draws in the game's font: a panel in design units and
-- our faces (Trade/UI.lua), in the palette of the window it is asked from (the field terminal's from the world), at the
-- mouse as the game's dialog opens, kept inside the screen. Its text is broken at its line ends and to its width.
require "ISUI/ISPanel"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/Button"
local UI = OperationAcorn.Trade.UI

OAConfirm = ISPanel:derive("OAConfirm")

-- The width (design units; a text that needs more breaks into lines), the margin and the buttons' width (the game's
-- dialog's numbers).
OAConfirm.WIDTH = 360
OAConfirm.PAD = 10
OAConfirm.BUTTON_W = 100
OAConfirm.TEXT_TOP = 20

-- `onYes()` runs when yes is pressed (after the dialog has gone).
function OAConfirm:new(text, palette, onYes)
    local F = OAConfirm
    local lines = UI.wrap(text, F.WIDTH - 2 * F.PAD)
    local fh, bh = UI.fontHeight(), UI.buttonHeight()
    local h = F.TEXT_TOP + #lines * fh + 20 + bh + F.PAD
    local o = ISPanel.new(self, 0, 0, F.WIDTH, h)
    o.lines, o.palette, o.onYes = lines, palette, onYes
    o.background = false
    return o
end

function OAConfirm:createChildren()
    local F, p = OAConfirm, self.palette
    local bh = UI.buttonHeight()
    local y = self.height - F.PAD - bh - 1
    self.yes = OAMButton:new((self.width - F.PAD) / 2 - F.BUTTON_W, y, F.BUTTON_W, bh, getText("UI_Yes"), p, self,
        OAConfirm.onYesButton, "strong")
    self.no = OAMButton:new((self.width + F.PAD) / 2, y, F.BUTTON_W, bh, getText("UI_No"), p, self, OAConfirm.onNoButton)
    for _, b in ipairs({ self.yes, self.no }) do
        b:initialise()
        b:instantiate()
        self:addChild(b)
    end
end

function OAConfirm:prerender()
    local p = self.palette
    UI.fill(self, 0, 0, self.width, self.height, p.bg, 0.95)
    UI.frame(self, 0, 0, self.width, self.height, p.border)
    local fh = UI.fontHeight()
    for i, line in ipairs(self.lines) do
        UI.textCentre(self, line, self.width / 2, OAConfirm.TEXT_TOP + (i - 1) * fh, p.text)
    end
end

function OAConfirm:destroy()
    self:setVisible(false)
    self:removeFromUIManager()
end

function OAConfirm:onYesButton()
    self:destroy()
    if self.onYes then self.onYes() end
end

function OAConfirm:onNoButton()
    self:destroy()
end

UI.scaled(OAConfirm, ISPanel)

-- Asks yes or no; onYes(target, a, b) runs on yes. In the palette of `target`'s window (a tab's), else the field
-- terminal's; at the mouse, inside the screen.
function UI.confirm(character, text, target, onYes, a, b)
    UI.refreshScale()
    local palette = (type(target) == "table" and UI.paletteOf(target)) or UI.palette("field")
    local modal = OAConfirm:new(text, palette, function() onYes(target, a, b) end)
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    modal.x = math.max(0, math.min(UI.dp(getMouseX()) - modal.width / 2, screenW - modal.width))
    modal.y = math.max(0, math.min(UI.dp(getMouseY()) - modal.height / 2, screenH - modal.height))
    modal:initialise()
    modal:addToUIManager()
    modal:bringToTop()
    return modal
end

return OAConfirm
