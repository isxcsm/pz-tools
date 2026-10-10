-- A button drawn in the terminal's palette (DESIGN-terminal 1.3): the missions tab's. A box with a one pixel border and
-- the title in the middle; "strong" is the one to press, a disabled one is dim. It is an ISButton, so a click, the
-- tooltip and `enable` work as the game's own; only the drawing is the palette's.
require "ISUI/ISButton"
require "OperationAcorn/Trade/UI"
local UI = OperationAcorn.Trade.UI

OAMButton = ISButton:derive("OAMButton")

-- `style`: "normal" or "strong".
function OAMButton:new(x, y, width, height, title, palette, target, onclick, style)
    local o = ISButton.new(self, x, y, width, height, title, target, onclick)
    -- The game's button widens to its title measured in pixels; this one is in design units (Trade/UI.lua).
    o.width = math.max(width, UI.textWidth(title) + 10)
    o.palette = palette
    o.style = style or "normal"
    return o
end

function OAMButton:prerender()
    local p = self.palette
    local w, h = self.width, self.height
    local hover = self.enable and (self.mouseOver or self.pressed) and self:isMouseOver()
    if not self.enable then
        if p.panel then UI.fill(self, 0, 0, w, h, p.panel, 0.6) end
        UI.frame(self, 0, 0, w, h, p.border, 0.5)
    elseif self.style == "strong" then
        UI.fill(self, 0, 0, w, h, p.sel, hover and 0.34 or 0.22)
        UI.frame(self, 0, 0, w, h, p.sel, 0.9)
    elseif hover then
        UI.fill(self, 0, 0, w, h, p.sel, 0.14)
        UI.frame(self, 0, 0, w, h, p.sel, 0.7)
    else
        if p.panel then UI.fill(self, 0, 0, w, h, p.panel) else UI.fill(self, 0, 0, w, h, p.sel, 0.06) end
        UI.frame(self, 0, 0, w, h, p.border)
    end
    self:updateTooltip()
end

function OAMButton:render()
    local p = self.palette
    local fh = UI.fontHeight()
    local c, a = p.text, 1
    if not self.enable then
        c, a = p.dim, 0.6
    elseif self.style == "strong" then
        c = p.bright
    end
    UI.textCentre(self, self.title, self.width / 2, (self.height - fh) / 2, c, nil, a)
end

-- The game's tooltip goes under the button by its height, which is in design units here: put back in pixels.
function OAMButton:updateTooltip()
    ISButton.updateTooltip(self)
    local tip = self.tooltipUI
    if tip and self.tooltip and tip:getIsVisible() then
        local x = self:isMouseOver() and getMouseX() or self:getAbsoluteX()
        tip:setDesiredPosition(x, self:getAbsoluteY() + UI.px(self.height) + 8)
    end
end

-- The button is ours: in design units (Trade/UI.lua), placed and sized as the screens' other parts.
UI.scaled(OAMButton, ISButton)

return OAMButton
