-- The pipes' schematic, over the floor plan on the water tab while its switch is on (ISBUPlan): a diagram, not a map,
-- so it is as large as the floors times the pipes however big the buildings are (Water.schematic). Floors up the
-- side, the box's own building only; a column for each pipe, in its colour. In a cell: the water storage there (a tank
-- with how full it is, and its litres), a dot where water is taken (red, and the cell red, where it reaches no
-- storage). A booster pump is an arrow up its outlet's column as far as it lifts, a filter one across from its inlet's
-- column to its outlet's, a pump a mark where it fills. Water coming in from another building of the zone is an arrow
-- at the left of its column, at the floor it comes in at. The mouse over a cell or a mark tells what it is at the
-- bottom and outlines it in the world. What is drawn is laid out when the data or the size changes; a frame draws the
-- shapes laid out.
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "BuildingUtilities/PanelUi"
require "BuildingUtilities/Water"
local BU = BuildingUtilities
local Ui, Water, Units = BU.PanelUi, BU.Water, BU.Units
local UI, P = Ui.UI, Ui.PALETTE
local FONT_HGT_SMALL = Ui.FONT_HGT_SMALL

ISBUSchematic = ISPanel:derive("ISBUSchematic")

-- The floors' names' column, a pipe's column at least and at most, a floor's row, the head (design units).
local LABEL_W, MIN_COL, MAX_COL = 46, 40, 76
local ROW_H, HEAD_H, PAD = FONT_HGT_SMALL + 14, FONT_HGT_SMALL + 8, 6

function ISBUSchematic:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = true
    o.backgroundColor = { r = P.inset[1], g = P.inset[2], b = P.inset[3], a = 1 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.shapes, o.items = {}, {}
    return o
end

-- The diagram anew from the box's water (the window's refresh).
function ISBUSchematic:refresh(panel)
    local Networks = BU.Networks
    self.panel = panel
    self.data = Water.schematic(panel, Networks.waterLayout(panel), Networks.waterState)
    self:layout()
end

local function litres(value) return tostring(math.floor(value + 0.5)) end

-- The shapes a frame draws and the things the mouse finds, laid out.
function ISBUSchematic:fill(x, y, w, h, c, a) self.shapes[#self.shapes + 1] = { "fill", x, y, w, h, c, a or 1 } end
function ISBUSchematic:frame(x, y, w, h, c, a) self.shapes[#self.shapes + 1] = { "frame", x, y, w, h, c, a or 1 } end
function ISBUSchematic:text(text, x, y, c) self.shapes[#self.shapes + 1] = { "text", text, x, y, c } end
function ISBUSchematic:centre(text, x, y, c) self.shapes[#self.shapes + 1] = { "centre", text, x, y, c } end
function ISBUSchematic:item(x, y, w, h, text, rows)
    self.items[#self.items + 1] = { x = x, y = y, w = w, h = h, text = text, rows = rows }
end

-- The cell of a pipe on a floor (x, y), or nil when the pipe or the floor is not shown.
function ISBUSchematic:cellAt(pipe, level)
    local x, y = self.colX[pipe], self.rows[level]
    if not (x and y) then return nil end
    return x, y
end

-- Where each floor's row and each pipe's column are, and what is drawn, from the data and the size.
function ISBUSchematic:layout()
    self.laidW, self.laidH = self.width, self.height
    self.shapes, self.items = {}, {}
    local data, panel = self.data, self.panel
    if not data then return end
    local col = math.max(MIN_COL, math.min(MAX_COL,
        math.floor((self.width - LABEL_W - PAD * 2) / math.max(1, #data.pipes))))
    self.col, self.rows, self.colX = col, {}, {}
    for index, pipe in ipairs(data.pipes) do self.colX[pipe] = PAD + LABEL_W + (index - 1) * col end
    local y = PAD + HEAD_H
    for level = data.high, data.low, -1 do
        self.rows[level] = y
        y = y + ROW_H
    end
    -- The pipes' heads: a chip of each colour with its number.
    for _, pipe in ipairs(data.pipes) do
        local x = self.colX[pipe]
        self:fill(x + 4, PAD + 3, col - 8, HEAD_H - 8, Water.colour(pipe), 0.85)
        self:centre(tostring(pipe), x + col / 2, PAD + (HEAD_H - FONT_HGT_SMALL) / 2 - 1, P.dark)
        self:item(x, PAD, col, HEAD_H, Water.pipeName(panel, pipe), {})
    end
    -- The floors: their names, the grid, the pipes running up their columns, the cells.
    for level = data.high, data.low, -1 do
        local ry = self.rows[level]
        self:text(BU.floorName(level), PAD, ry + (ROW_H - FONT_HGT_SMALL) / 2, level == panel.z and P.bright or P.dim)
        self:fill(PAD, ry + ROW_H - 1, LABEL_W + col * #data.pipes, 1, P.border, 0.5)
        local row = data.cells[level] or {}
        for _, pipe in ipairs(data.pipes) do
            local x = self.colX[pipe]
            self:fill(x + col / 2, ry, 1, ROW_H, Water.colour(pipe), 0.25)
            if row[pipe] then self:cell(row[pipe], pipe, level) end
        end
    end
    for _, arrival in ipairs(data.arrivals) do self:arrival(arrival) end
    for _, machine in ipairs(data.machines) do self:machine(machine) end
    self.hoverItem = nil
end

-- A cell: its storage as a tank filled as far as it is, with its litres; a dot where water is taken.
function ISBUSchematic:cell(cell, pipe, level)
    local x, y = self:cellAt(pipe, level)
    local col, c = self.col, Water.colour(pipe)
    if cell.dry then self:fill(x + 1, y + 1, col - 2, ROW_H - 2, P.bad, 0.18) end
    local texts, rows = {}, {}
    if #cell.tanks > 0 then
        local tw, th = 10, ROW_H - 10
        local tx, ty = x + 6, y + 5
        local share = cell.capacity > 0 and math.min(1, cell.amount / cell.capacity) or 0
        self:frame(tx, ty, tw, th, c, 0.9)
        if share > 0 then self:fill(tx + 1, ty + 1 + (th - 2) * (1 - share), tw - 2, (th - 2) * share, c, 0.85) end
        self:text(litres(cell.amount), tx + tw + 3, y + (ROW_H - FONT_HGT_SMALL) / 2, P.text)
        texts[#texts + 1] = getText("IGUI_BU_SchemeTanks", #cell.tanks, litres(cell.amount), litres(cell.capacity))
        for _, at in ipairs(cell.tanks) do rows[#rows + 1] = { at = at } end
    end
    if cell.uses > 0 then
        local d = 6
        self:fill(x + col - d - 5, y + (ROW_H - d) / 2, d, d, cell.dry and P.bad or c, 1)
        texts[#texts + 1] = getText(cell.dry and "IGUI_BU_SchemeDry" or "IGUI_BU_SchemeUses")
    end
    if #texts > 0 then
        self:item(x, y, col, ROW_H, getText("IGUI_BU_SchemeCell", Water.pipeName(self.panel, pipe),
            BU.floorName(level), table.concat(texts, ", ")), rows)
    end
end

-- An arrowhead of four strokes at x, y pointing one way: "right", "left" or "up".
function ISBUSchematic:head(x, y, way, c)
    for i = 0, 3 do
        local span = 7 - i * 2
        if way == "up" then
            self:fill(x - span / 2, y + i, span, 1, c, 1)
        else
            self:fill(way == "right" and x - i or x + i, y - span / 2, 1, span, c, 1)
        end
    end
end

-- Water from another building: an arrow into the left of its pipe's column at the floor it comes in at (the top
-- floor shown when it comes in higher).
function ISBUSchematic:arrival(arrival)
    local data = self.data
    local level = math.max(data.low, math.min(data.high, arrival.level))
    local x, y = self:cellAt(arrival.pipe, level)
    if not x then return end
    local c, my = Water.colour(arrival.pipe), y + ROW_H / 2
    self:fill(x - 12, my - 1, 8, 2, c, 1)
    self:head(x - 3, my, "right", c)
    self:item(x - 12, y, 12, ROW_H, getText("IGUI_BU_SchemeArrival", Water.pipeName(self.panel, arrival.pipe),
        BU.floorName(arrival.level)), {})
end

-- An arrow across a floor's row from one pipe's column to another's.
function ISBUSchematic:across(from, to, level)
    local x1 = self:cellAt(from, level)
    local x2, y = self:cellAt(to, level)
    if not (x1 and x2) then return end
    local a, b = x1 + self.col / 2, x2 + self.col / 2
    local my, c = y + ROW_H - 5, Water.colour(from)
    self:fill(math.min(a, b), my - 1, math.abs(b - a), 2, c, 0.9)
    self:head(b > a and b - 1 or b + 1, my, b > a and "right" or "left", c)
end

-- A machine: a booster pump an arrow up its outlet's column, a filter one across, a pump a mark where it fills.
function ISBUSchematic:machine(machine)
    local data, col, panel = self.data, self.col, self.panel
    local level, outlet, inlet = machine.level, machine.outlet, machine.inlet or machine.outlet
    local x, y = self:cellAt(outlet, level)
    if not x then return end
    local c = Water.colour(outlet)
    local rows = { { unit = machine.unit } }
    local name = Units.name(machine.unit)
    if machine.kind == "booster" then
        local top = math.min(data.high, machine.top)
        local _, topY = self:cellAt(outlet, top)
        local ax = x + col / 2 + 6
        local y1, y2 = topY + 3, y + ROW_H / 2
        self:fill(ax - 1, y1 + 4, 3, math.max(2, y2 - y1 - 4), c, 1)
        self:head(ax + 0.5, y1, "up", c)
        if inlet ~= outlet then self:across(inlet, outlet, level) end
        self:item(ax - 5, y1, 10, y2 - y1, getText("IGUI_BU_SchemeBooster", name, Water.pipeName(panel, inlet),
            Water.pipeName(panel, outlet), BU.floorName(top)), rows)
    elseif machine.kind == "filter" then
        if inlet ~= outlet then self:across(inlet, outlet, level) end
        local fx = x + col / 2 - 4
        self:frame(fx, y + ROW_H - 9, 8, 6, c, 1)
        self:item(fx - 2, y + ROW_H - 11, 12, 10, getText("IGUI_BU_SchemeFilter", name, Water.pipeName(panel, inlet),
            Water.pipeName(panel, outlet)), rows)
    else
        local px = x + col / 2
        self:head(px, y + 2, "up", c)
        self:item(px - 6, y, 12, 8, getText("IGUI_BU_SchemePump", name, Water.pipeName(panel, outlet)), rows)
    end
end

function ISBUSchematic:prerender()
    ISPanel.prerender(self)
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
end

function ISBUSchematic:render()
    for _, s in ipairs(self.shapes) do
        local kind = s[1]
        if kind == "fill" then UI.fill(self, s[2], s[3], s[4], s[5], s[6], s[7])
        elseif kind == "frame" then UI.frame(self, s[2], s[3], s[4], s[5], s[6], s[7])
        elseif kind == "text" then UI.text(self, s[2], s[3], s[4], s[5])
        else UI.textCentre(self, s[2], s[3], s[4], s[5]) end
    end
    local found = self.hoverItem
    if found then
        UI.frame(self, found.x, found.y, found.w, found.h, P.value, 0.8)
        UI.text(self, found.text, PAD, self.height - FONT_HGT_SMALL - PAD, P.text)
    end
end

-- The thing under the mouse, outlined in the world while it stays there.
function ISBUSchematic:setHover(found)
    if found == self.hoverItem then return end
    self.hoverItem = found
    self.window:outlineRows(found and found.rows or {})
end

function ISBUSchematic:onMouseMove()
    local mx, my = self:getMouseX(), self:getMouseY()
    local found = nil
    for index = #self.items, 1, -1 do
        local each = self.items[index]
        if mx >= each.x and mx < each.x + each.w and my >= each.y and my < each.y + each.h then
            found = each
            break
        end
    end
    self:setHover(found)
end

function ISBUSchematic:onMouseMoveOutside() self:setHover(nil) end

UI.scaled(ISBUSchematic, ISPanel)

return ISBUSchematic
