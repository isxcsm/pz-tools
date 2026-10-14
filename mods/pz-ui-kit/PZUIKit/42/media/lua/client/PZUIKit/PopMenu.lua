-- A menu at the mouse in its window's palette, the kit's in place of the game's ISContextMenu for a window's own
-- menus (the world's menu stays the game's, PZUIKit.Menu): rows of choices under dim heads, over everything, the
-- tooltip of a choice in the kit's (PZUIRichTip) while no other is shown. A click on a choice closes it and calls
-- fn(target, a, b, c, d); a click anywhere else closes it; so does its owner leaving the screen. In design units and the
-- kit's faces (UI.lua).
--   local menu = UI.menu(window, palette)
--   menu:addHead(text)
--   local option = menu:addOption(text, target, fn, a, b, c, d)
--   option.current = true   -- the one in use: marked, not offered
--   option.off = true       -- not offered now (dim); option.tip says why (rich text)
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "PZUIKit/RichText"
local UI = PZUIKit.UI

PZUIPopMenu = ISPanel:derive("PZUIPopMenu")

-- A row's margin above and below its text, the room left and right of it, and the gap over a head after the first.
PZUIPopMenu.ROW_PAD = 3
PZUIPopMenu.SIDE = 10
PZUIPopMenu.GAP = 4

-- The one menu open (a new one closes it).
local open

function PZUIPopMenu:new(owner, palette)
    local o = ISPanel.new(self, UI.dp(getMouseX()), UI.dp(getMouseY()), 1, 1)
    o.owner, o.palette = owner, palette or UI.DEFAULT_PALETTE
    o.rows = {}
    o.rowH = UI.fontHeight() + 2 * PZUIPopMenu.ROW_PAD
    o.atX, o.atY = o.x, o.y
    o.background = false
    return o
end

-- Size and place by the rows: by the mouse where it was opened, inside the screen.
function PZUIPopMenu:layout()
    local width, height = 0, 2
    for index, row in ipairs(self.rows) do
        width = math.max(width, UI.textWidth(row.text))
        row.y = height + (row.head and index > 1 and PZUIPopMenu.GAP or 0)
        height = row.y + self.rowH
    end
    width = width + 2 * PZUIPopMenu.SIDE
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    self:setWidth(math.min(width, screenW))
    self:setHeight(height + 1)
    self:setX(math.max(0, math.min(self.atX, screenW - self.width)))
    self:setY(math.max(0, math.min(self.atY, screenH - self.height)))
end

function PZUIPopMenu:addHead(text)
    local row = { text = text or "", head = true }
    self.rows[#self.rows + 1] = row
    self:layout()
    return row
end

function PZUIPopMenu:addOption(text, target, fn, a, b, c, d)
    local row = { text = text or "", target = target, fn = fn, args = { a, b, c, d } }
    self.rows[#self.rows + 1] = row
    self:layout()
    return row
end

local function offered(row)
    return row and not row.head and not row.off and not row.current
end

-- The row under y (design units from the menu's top), or nil.
function PZUIPopMenu:rowAt(y)
    for _, row in ipairs(self.rows) do
        if y >= row.y and y < row.y + self.rowH then return row end
    end
    return nil
end

function PZUIPopMenu:prerender()
    local owner = self.owner
    if open ~= self or owner and not owner:isReallyVisible() then return self:close() end
    self.drawn = true
    local p = self.palette
    local w = self.width
    UI.fill(self, 0, 0, w, self.height, p.bg, 0.98)
    UI.frame(self, 0, 0, w, self.height, p.border)
    local over = self:isMouseOver() and self:rowAt(self:getMouseY()) or nil
    local fh = UI.fontHeight()
    for index, row in ipairs(self.rows) do
        local y = row.y
        if row.head and index > 1 then
            UI.fill(self, 1, y - math.floor(PZUIPopMenu.GAP / 2) - 1, w - 2, 1, p.border, 0.8)
        end
        local colour = p.text
        if row.head or row.off then
            colour = p.dim
        elseif row.current then
            UI.fill(self, 1, y, w - 2, self.rowH, p.sel, 0.25)
            colour = p.bright
        elseif row == over then
            UI.fill(self, 1, y, w - 2, self.rowH, p.sel, 0.12)
        end
        UI.text(self, row.text, PZUIPopMenu.SIDE, y + (self.rowH - fh) / 2, colour)
    end
    if over and over.tip then PZUIRichTip.show(self, over.tip, p) else PZUIRichTip.hide(self) end
end

function PZUIPopMenu:onMouseDown(x, y)
    local row = self:rowAt(y)
    if not offered(row) then return true end
    self:close()
    getSoundManager():playUISound("UISelectListItem")
    if row.fn then
        local args = row.args
        row.fn(row.target, args[1], args[2], args[3], args[4])
    end
    return true
end

function PZUIPopMenu:onRightMouseDown()
    return true
end

-- The click that opened it reaches it too, outside it, before it is first drawn: that one leaves it open.
function PZUIPopMenu:onMouseDownOutside()
    if self.drawn then self:close() end
end

function PZUIPopMenu:onRightMouseDownOutside()
    if self.drawn then self:close() end
end

function PZUIPopMenu:close()
    if open == self then
        open = nil
        PZUIRichTip.hold(nil)
    end
    PZUIRichTip.hide(self)
    self:setVisible(false)
    self:removeFromUIManager()
end

UI.scaled(PZUIPopMenu, ISPanel)

-- A menu at the mouse for owner (an element: the menu goes with it), in the palette (the kit's by default): empty,
-- on show at once; its rows are added after.
function UI.menu(owner, palette)
    if open then open:close() end
    local menu = PZUIPopMenu:new(owner, palette)
    menu:initialise()
    menu:addToUIManager()
    menu:setAlwaysOnTop(true)
    open = menu
    PZUIRichTip.hide()
    PZUIRichTip.hold(menu)
    return menu
end

return PZUIPopMenu
