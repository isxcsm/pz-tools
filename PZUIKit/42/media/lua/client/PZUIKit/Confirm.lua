-- Asking yes or no (UI.confirm), the kit's in place of the game's ISModalDialog, which draws in the game's font: a panel
-- in design units and the kit's faces (UI.lua), in the palette of the window it is asked from (UI.DEFAULT_PALETTE from
-- the world), at the
-- mouse as the game's dialog opens, kept inside the screen. Its text is broken at its line ends and to its width.
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

-- `onYes()` runs when yes is pressed (after the dialog has gone).
function PZUIConfirm:new(text, palette, onYes)
    local F = PZUIConfirm
    local lines = UI.wrap(text, F.WIDTH - 2 * F.PAD)
    local fh, bh = UI.fontHeight(), UI.buttonHeight()
    local h = F.TEXT_TOP + #lines * fh + 20 + bh + F.PAD
    local o = ISPanel.new(self, 0, 0, F.WIDTH, h)
    o.lines, o.palette, o.onYes = lines, palette, onYes
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
    for i, line in ipairs(self.lines) do
        UI.textCentre(self, line, self.width / 2, PZUIConfirm.TEXT_TOP + (i - 1) * fh, p.text)
    end
end

function PZUIConfirm:destroy()
    self:setVisible(false)
    self:removeFromUIManager()
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
-- the mouse, inside the screen.
function UI.confirm(character, text, target, onYes, a, b)
    UI.refreshScale()
    local palette = (type(target) == "table" and UI.paletteOf(target)) or UI.DEFAULT_PALETTE
    local modal = PZUIConfirm:new(text, palette, function() onYes(target, a, b) end)
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    modal.x = math.max(0, math.min(UI.dp(getMouseX()) - modal.width / 2, screenW - modal.width))
    modal.y = math.max(0, math.min(UI.dp(getMouseY()) - modal.height / 2, screenH - modal.height))
    modal:initialise()
    modal:addToUIManager()
    modal:bringToTop()
    return modal
end

return PZUIConfirm
