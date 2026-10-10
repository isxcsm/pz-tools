-- A button drawn in the terminal's palette (DESIGN-terminal 1.3), for every button of our windows: a box with a one
-- pixel border and the title in the middle in our face. "strong" is the one to press, a disabled one (enable = false)
-- is dim and does nothing, an "off" one looks disabled but a click on it calls onOff(target) (the shop's add button says
-- why it is off). It is an ISButton, so a click and `enable` work as the game's own; the drawing and the tooltip are
-- ours (the game's draw in the game's font).
require "ISUI/ISButton"
require "ISUI/ISPanel"
require "OperationAcorn/Trade/UI"
local UI = OperationAcorn.Trade.UI

OAMButton = ISButton:derive("OAMButton")

-- `style`: "normal", "strong" or "off".
function OAMButton:new(x, y, width, height, title, palette, target, onclick, style)
    local o = ISButton.new(self, x, y, width, height, title, target, onclick)
    -- The game's button widens to its title measured in pixels; this one is in design units (Trade/UI.lua).
    o.width = math.max(width, UI.textWidth(title) + 10)
    o.palette = palette
    o.style = style or "normal"
    return o
end

function OAMButton:setStyle(style)
    self.style = style
end

function OAMButton:onMouseDown(x, y)
    if self.style ~= "off" then
        if self.enable then UI.flash(self, "press") end
        return ISButton.onMouseDown(self, x, y)
    end
end

function OAMButton:onMouseUp(x, y)
    if self.style ~= "off" then return ISButton.onMouseUp(self, x, y) end
    self.pressed = false
    if self.onOff then self.onOff(self.target) end
end

-- The mouse over it brings a light up (UI.hoverLight) and a click flashes it (UI.flash), both eased.
function OAMButton:prerender()
    local p = self.palette
    local w, h = self.width, self.height
    local live = self.enable and self.style ~= "off"
    local k = UI.hoverLight(self, "hover", live and (self.mouseOver or self.pressed) and self:isMouseOver())
    local f = UI.flashLevel(self, "press")
    if not live then
        if p.panel then UI.fill(self, 0, 0, w, h, p.panel, 0.6) end
        UI.frame(self, 0, 0, w, h, p.border, 0.5)
    elseif self.style == "strong" then
        UI.fill(self, 0, 0, w, h, p.sel, 0.22 + 0.12 * k + 0.3 * f)
        UI.frame(self, 0, 0, w, h, p.sel, 0.9)
    else
        if p.panel then UI.fill(self, 0, 0, w, h, p.panel) else UI.fill(self, 0, 0, w, h, p.sel, 0.06) end
        if k > 0 or f > 0 then UI.fill(self, 0, 0, w, h, p.sel, 0.12 * k + 0.3 * f) end
        UI.frame(self, 0, 0, w, h, p.border)
        if k > 0 then UI.frame(self, 0, 0, w, h, p.sel, 0.7 * k) end
    end
    self:updateTooltip()
end

function OAMButton:render()
    local p = self.palette
    local fh = UI.fontHeight()
    local c, a = p.text, 1
    if not self.enable or self.style == "off" then
        c, a = p.dim, 0.6
    elseif self.style == "strong" then
        c = p.bright
    end
    UI.textCentre(self, self.title, self.width / 2, (self.height - fh) / 2, c, nil, a)
end

-- The tooltip: ours, under the button where the mouse is (the game's ISToolTip would draw in the game's font).
function OAMButton:updateTooltip()
    if self.tooltip and self:isMouseOver() then
        OATip.show(self, self.tooltip, self.palette)
    else
        OATip.hide(self)
    end
end

function OAMButton:setVisible(visible)
    if not visible then OATip.hide(self) end
    ISButton.setVisible(self, visible)
end

-- The button is ours: in design units (Trade/UI.lua), placed and sized as the screens' other parts.
UI.scaled(OAMButton, ISButton)

-- The tooltip of our buttons: one panel over everything, shown for one button at a time, its text broken to a width
-- and measured once a text. It hides itself when its button is no longer under the mouse or on show.
OATip = ISPanel:derive("OATip")

OATip.MAX_W = 300
OATip.PAD = 6

local tip

function OATip:prerender()
    local owner = self.owner
    if not (owner and owner:isReallyVisible() and owner:isMouseOver()) then return OATip.hide(owner) end
    local p = self.palette
    UI.fill(self, 0, 0, self.width, self.height, p.bg, 0.97)
    UI.frame(self, 0, 0, self.width, self.height, p.border)
    local fh = UI.fontHeight()
    for i, line in ipairs(self.lines) do UI.text(self, line, OATip.PAD, OATip.PAD / 2 + (i - 1) * fh, p.bright) end
end

UI.scaled(OATip, ISPanel)

-- Shows `text` for the button `owner` (design units: the screen's pixels / UI.S), under it at the mouse.
function OATip.show(owner, text, palette)
    if not tip then
        tip = OATip:new(0, 0, 10, 10)
        tip.background = false
        tip:initialise()
        tip:instantiate()
        tip:setAlwaysOnTop(true)
    end
    if tip.text ~= text or tip.era ~= UI.era then
        tip.text, tip.era = text, UI.era
        tip.lines = UI.wrap(text, OATip.MAX_W - 2 * OATip.PAD)
        local w = 0
        for _, line in ipairs(tip.lines) do w = math.max(w, UI.textWidth(line)) end
        tip:setWidth(math.ceil(w) + 2 * OATip.PAD)
        tip:setHeight(#tip.lines * UI.fontHeight() + OATip.PAD)
    end
    tip.owner, tip.palette = owner, palette
    local screenW = UI.dp(getCore():getScreenWidth())
    local x = math.max(0, math.min(UI.dp(getMouseX()), screenW - tip.width))
    tip:setX(x)
    tip:setY(UI.dp(owner:getAbsoluteY()) + owner.height + 8)
    if not tip.shown then
        tip.shown = true
        tip:addToUIManager()
        tip:setVisible(true)
    end
end

-- Hides the tooltip if it is `owner`'s (nil: whoever's).
function OATip.hide(owner)
    if not (tip and tip.shown) or (owner and tip.owner ~= owner) then return end
    tip.shown, tip.owner = false, nil
    tip:setVisible(false)
    tip:removeFromUIManager()
end

return OAMButton
