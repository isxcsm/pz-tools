-- The lines on an item's tooltip (DESIGN-terminal 9 and 10): "mission item" first, in the mission's colour, and under
-- the tooltip "requested · 660 each · this week 6/10" (amber) and "not seen before" (green). The tooltip's text is one
-- label of one colour, so the lines are drawn as strips of the panel's own look above and below it (as the appraisal's
-- is); the game draws the tooltip itself. What the lines say is made once an item type (Economy/ItemTip); a frame
-- looks tables up and draws.
require "ISUI/ISToolTipInv"
require "OperationAcorn/Client"
require "OperationAcorn/Story/View"
require "OperationAcorn/Economy/ItemTip"
require "OperationAcorn/Trade/UI"
-- the appraisal wraps the tooltip first, so that this draws after it and knows what room it took
require "OperationAcorn/Trade/Appraisal"
local OA = OperationAcorn
local View, ItemTip, UI = OA.StoryView, OA.ItemTip, OA.Trade.UI

local font = UIFont.Small
local lineHeight

-- The item type of an item, asked of the game once per item (bounded: OA.bounded).
local NO_ROWS = {}
local typeOf = OA.bounded()

-- A strip of rows at the panel's y: its own background and border, as wide as the panel or its widest line.
local function strip(panel, rows, y)
    local w = panel.width
    for i = 1, #rows do
        local row = rows[i]
        local rw = row.w
        if not rw then
            rw = UI.textWidthPx(row.text, font) + 16
            row.w = rw
        end
        if rw > w then w = rw end
    end
    local h = #rows * lineHeight + 8
    local bg, border = panel.backgroundColor, panel.borderColor
    panel:drawRect(0, y, w, h, bg.a, bg.r, bg.g, bg.b)
    panel:drawRectBorder(0, y, w, h, border.a, border.r, border.g, border.b)
    for i = 1, #rows do
        local row = rows[i]
        local c = row.color
        panel:drawText(row.text, 8, y + 4 + (i - 1) * lineHeight, c[1], c[2], c[3], 1, font)
    end
end

local function draw(panel, item)
    local player = getPlayer()
    local record = player and OA.Client.record(player)
    if not record then return end
    local fullType = typeOf.t[item]
    if not fullType then
        fullType = item:getFullType()
        OA.put(typeOf, item, fullType)
    end
    local data = item:hasModData() and item:getModData() or nil
    local id = data and data.OA_Mission
    local owner = id and View.ownerOf(record, id) or nil
    local mission = owner and ItemTip.missionRows(View.color(owner.kind)) or nil
    -- (the codex's and the requests' lines only once the team is met: the terminal used)
    local rows = OA.Trust.contacted(record) and ItemTip.rows(record, fullType, data and data.OA_Bought) or NO_ROWS
    if not mission and #rows == 0 then return end
    lineHeight = lineHeight or UI.fontHeightPx(font)
    local top = mission and lineHeight + 8 or 0
    local bottom = #rows > 0 and #rows * lineHeight + 8 or 0
    local topY, bottomY = ItemTip.place(panel:getY(), panel.height, getCore():getScreenHeight(), panel.oaAbove or 0,
        panel.oaBelow or 0, top, bottom)
    if topY then strip(panel, mission, topY) end
    if bottomY then strip(panel, rows, bottomY) end
end

-- The game's functions below are left as they are while the mod is off (OA.off).
if OA.off then return end

local originalRender = ISToolTipInv.render
function ISToolTipInv:render(...)
    self.oaAbove, self.oaBelow = 0, 0
    originalRender(self, ...)
    local item = self.item
    if not item or not self:isVisible() then return end
    if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end
    OA.try("item tooltip lines", draw, self, item)
end
