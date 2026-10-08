-- Small helpers for the trade part's windows: the same few widgets (a label, a button, a list, a rich text) with the
-- sizes the game's own windows use.
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISRichTextPanel"
require "OperationAcorn/Trade/Text"
local OA = OperationAcorn
local UI = {}
OA.Trade.UI = UI

UI.PAD = 10

function UI.fontHeight(font)
    return getTextManager():getFontHeight(font or UIFont.Small)
end

function UI.buttonHeight()
    return UI.fontHeight(UIFont.Small) + 10
end

function UI.textWidth(text, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, text)
end

-- The text cut to a width with "..." at the end (whole when it fits). The game's strings are per character, so a cut
-- never splits a letter.
function UI.fit(text, width, font)
    if UI.textWidth(text, font) <= width then return text end
    local cut = text
    while #cut > 1 and UI.textWidth(cut .. "...", font) > width do
        cut = string.sub(cut, 1, #cut - 1)
    end
    return cut .. "..."
end

-- A label at x, y.
function UI.label(parent, x, y, text, color, font)
    color = color or { r = 0.9, g = 0.9, b = 0.9, a = 1 }
    local label = ISLabel:new(x, y, UI.fontHeight(font), text, color.r, color.g, color.b, color.a, font or UIFont.Small, true)
    label:initialise()
    label:instantiate()
    parent:addChild(label)
    return label
end

-- A button whose click calls onclick(target, button).
function UI.button(parent, x, y, width, title, target, onclick)
    local button = ISButton:new(x, y, width, UI.buttonHeight(), title, target, onclick)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
    parent:addChild(button)
    return button
end

-- A list with rows drawn by `drawRow(list, y, item, alt)`, which returns the y of the next row. The row's own height
-- is the list's itemheight.
function UI.list(parent, x, y, width, height, drawRow, target, onclick)
    local list = ISScrollingListBox:new(x, y, width, height)
    list:initialise()
    list:instantiate()
    list.font = UIFont.Small
    list.fontHgt = UI.fontHeight(UIFont.Small)
    list.itemPadY = 3
    list.itemheight = list.fontHgt + list.itemPadY * 2 + 2
    list.drawBorder = true
    list.doDrawItem = function(self, rowY, item, alt)
        if rowY + self:getYScroll() + item.height < 0 or rowY + self:getYScroll() >= self.height then
            return rowY + item.height
        end
        if self.selected == item.index then
            self:drawSelection(0, rowY, self:getWidth(), item.height - 1)
        elseif self.mouseoverselected == item.index and self:isMouseOver() and not self:isMouseOverScrollBar() then
            self:drawMouseOverHighlight(0, rowY, self:getWidth(), item.height - 1)
        end
        drawRow(self, rowY, item, alt)
        return rowY + item.height
    end
    if onclick then list:setOnMouseDownFunction(target, onclick) end
    parent:addChild(list)
    return list
end

-- A scrolling rich text panel.
function UI.rich(parent, x, y, width, height)
    local panel = ISRichTextPanel:new(x, y, width, height)
    panel:initialise()
    panel:instantiate()
    panel.autosetheight = false
    panel.clip = true
    panel.marginLeft = 8
    panel.marginRight = 8
    panel.marginTop = 6
    panel.marginBottom = 6
    panel:addScrollBars()
    panel.backgroundColor = { r = 0, g = 0, b = 0, a = 0.35 }
    panel.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.9 }
    parent:addChild(panel)
    return panel
end

function UI.setRich(panel, text)
    panel.text = text
    panel:paginate()
end

-- Rich text colors for the receipt kinds.
UI.KIND_TAG = {
    head = " <H2> <RGB:1,1,1> ",
    line = " <TEXT> <RGB:0.85,0.85,0.85> ",
    good = " <TEXT> <RGB:0.55,0.9,0.55> ",
    bad = " <TEXT> <RGB:0.95,0.55,0.45> ",
    note = " <TEXT> <RGB:0.8,0.75,0.55> ",
    total = " <TEXT> <RGB:1,1,1> ",
}

-- Text lines { kind, text } as rich text.
function UI.richLines(lines)
    local parts = {}
    for _, line in ipairs(lines) do
        parts[#parts + 1] = (UI.KIND_TAG[line.kind] or UI.KIND_TAG.line) .. line.text .. " <LINE> "
    end
    return table.concat(parts)
end

-- Asks yes or no; onYes(target, a, b) runs on yes.
function UI.confirm(character, text, target, onYes, a, b)
    local modal = ISModalDialog:new(0, 0, 360, 150, text, true, nil, function(_, button)
        if button.internal == "YES" then onYes(target, a, b) end
    end, character:getPlayerNum())
    modal:initialise()
    modal:addToUIManager()
    return modal
end

-- A context menu at the mouse for the player: returns it.
function UI.menu(character)
    local x, y = getMouseX(), getMouseY()
    return ISContextMenu.get(character:getPlayerNum(), x, y)
end

return UI
