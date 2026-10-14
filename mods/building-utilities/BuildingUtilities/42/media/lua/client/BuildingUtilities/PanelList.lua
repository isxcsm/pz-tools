-- The breaker box window's list (one per tab), the strip of tabs over the lists and the divider between the list and
-- the plan. Each row is a table with a kind; the list draws it and passes clicks on to the window
-- (ISBUPanelWindow:onRow). A frame draws only the rows in view, with their buttons placed and their words measured once
-- for the row. The list is the game's (ISScrollingListBox, for its scrolling, in pixels); its rows are drawn in the UI
-- kit's design units and faces (PZUIKit: UI.designCanvas), as the window's other parts.
require "ISUI/ISScrollingListBox"
require "ISUI/ISPanel"
require "PZUIKit/RichText"
require "BuildingUtilities/PanelUi"
local BU = BuildingUtilities
local Store = BU.Store
local Ui = BU.PanelUi
local UI = Ui.UI
local FONT_HGT_SMALL, ROW, PAD, SCROLLBAR, ROOM_TICK_X, rowObjects, outline, unoutline = Ui.FONT_HGT_SMALL, Ui.ROW,
    Ui.PAD, Ui.SCROLLBAR, Ui.ROOM_TICK_X, Ui.rowObjects, Ui.outline, Ui.unoutline
local ACCENT, ease, approach, P = Ui.ACCENT, Ui.ease, Ui.approach, Ui.PALETTE
-- Rows that only tell: no light under the mouse.
local STILL = { header = true, note = true, filter = true, log = true, graph = true, columns = true,
    battery = true, pipeBuilding = true }

-- One tab's list. Each item is a row table with a kind; clicks act on the row and the part of it clicked.
ISBUPanelList = ISScrollingListBox:derive("ISBUPanelList")
-- The tooltips of a device row's buttons, by button: what a click does, over the button itself.
ISBUPanelList.BUTTON_TIPS = { timer = "IGUI_BU_TimerTip", pipe = "IGUI_BU_PipeChipTip", Pipe = "IGUI_BU_PipeChipTip",
    PipeIn = "IGUI_BU_PipeInTip", PipeOut = "IGUI_BU_PipeOutTip", roomPipe = "IGUI_BU_RoomPipeTip" }

local BUTTONS = { "Up", "Down" }
local OPTIONS = { "ActiveOnly", "ByLoad", "HideUnwired" }
local OPTION_NAMES = { ActiveOnly = true, ByLoad = true, HideUnwired = true }
-- Each option's flag in PanelWindow.options, and its label.
local OPTION_FLAGS = { ActiveOnly = "activeOnly", ByLoad = "byLoad", HideUnwired = "hideUnwired" }
local OPTION_LABELS = { ActiveOnly = "IGUI_BU_ActiveOnly", ByLoad = "IGUI_BU_ByLoad", HideUnwired = "IGUI_BU_HideUnwired" }
local BUTTON_W = 60
local TIMER_W, CHIP_W, SOURCE_W = 64, 34, 110
-- A pipe chip's buttons (BU.Water: its colour and number).
local CHIPS = { pipe = true, Pipe = true, PipeIn = true, PipeOut = true, roomPipe = true }

-- The texts of the rows' buttons and marks, looked up once.
local labels = {}
local function label(key)
    local text = labels[key]
    if not text then
        text = getText(key)
        labels[key] = text
    end
    return text
end

-- x, y, width and height given in design units (the window's body is in them).
function ISBUPanelList:new(x, y, width, height, window, utility)
    local o = ISScrollingListBox.new(self, x, y, width, height)
    -- its clip taken back fully (inside the window's, the game leaves it a level up and the plan's would draw
    -- through it)
    o.doRepaintStencil = true
    o.window = window
    o.utility = utility
    o.font = UIFont.Small
    o.drawBorder = true
    o.backgroundColor = { r = P.inset[1], g = P.inset[2], b = P.inset[3], a = 0.9 }
    o.borderColor = { r = P.border[1], g = P.border[2], b = P.border[3], a = 1 }
    o.highlighted = {}
    return o
end

function ISBUPanelList:createChildren()
    ISScrollingListBox.createChildren(self)
    UI.rowHeight(self, ROW)
end

-- The buttons at the end of a device's row, from the right: a water fixture's pipe chip (with more than one pipe); for
-- power, its timer. Also where the row's own text on the right ends. Kept
-- on the row for the list's width (design units).
local function deviceButtons(width, row)
    if row.buttonsWidth == width then return row.buttons, row.textRight end
    local right = width - PAD - SCROLLBAR
    local result = {}
    if row.pipe then
        right = right - CHIP_W
        result[#result + 1] = { name = "pipe", x = right, w = CHIP_W }
        right = right - 4
    end
    if row.controls then
        right = right - TIMER_W
        result[#result + 1] = { name = "timer", x = right, w = TIMER_W }
        right = right - 4
    end
    if right < width - PAD - SCROLLBAR then right = right - 4 end
    row.buttons, row.textRight, row.buttonsWidth = result, right, width
    return result, right
end

-- Buttons of the given names, left to right, ending at the right of the list (clear of its scrollbar); kept on the
-- row for the list's width.
local function buttonsAtRight(width, row, names)
    if row.buttonsWidth == width then return row.buttons end
    local result, x = {}, width - PAD - SCROLLBAR
    for index = #names, 1, -1 do
        local name = names[index]
        local w = CHIPS[name] and CHIP_W or name == "UseSource" and SOURCE_W or OPTION_NAMES[name] and Ui.OPTION_W
            or BUTTON_W
        x = x - w - 4
        result[index] = { name = names[index], x = x, w = w }
    end
    row.buttons, row.buttonsWidth = result, width
    return result
end

-- The buttons at the end of a producer's row, left to right: for power Up and Down; for water its pipe chips (with
-- more than one pipe: row.chips, a tank's or a unit's Pipe, a filter's or a booster pump's PipeIn and PipeOut, each
-- pipe in row.pipes).
local function producerButtons(width, row)
    if row.unwired then return buttonsAtRight(width, row, {}) end
    return buttonsAtRight(width, row, not row.water and BUTTONS or row.chips or {})
end

-- A room's row's buttons: its pipe chip, for water with more than one pipe (row.pipe).
local function roomButtons(width, row) return buttonsAtRight(width, row, row.pipe and { "roomPipe" } or {}) end

-- A pipe's row's buttons, left to right: Settings, Rename, and Remove but for the first pipe.
local function pipeButtons(width, row)
    return buttonsAtRight(width, row, row.removable and { "Settings", "Rename", "Remove" } or { "Settings", "Rename" })
end

-- The view options on the list's first header (the supply's), left to right: devices drawing only, and by what they
-- draw.
local function optionButtons(width, row) return buttonsAtRight(width, row, row.options == true and OPTIONS or row.options) end

-- A source row's buttons: "Switch to solar" (while offered).
local function sourceButtons(width, row)
    return buttonsAtRight(width, row, row.useSource and { "UseSource" } or {})
end

-- Whether the mouse is over a part of the row being drawn, from x so wide (list.rowMouseX: on the lit row only).
local function under(list, x, w)
    local mx = list.rowMouseX
    return mx ~= nil and mx >= x and mx < x + w
end

-- A small button on a row, drawn as the kit's buttons are: a well with a border, lit as the mouse comes onto it and
-- flashed by a click (its light is keyed by the row and the button). tc is { r, g, b } for its text; on, it is lit in
-- the accent (an option that is on).
local function smallButton(list, c, key, x, y, w, text, tc, on)
    local k = UI.hoverLight(list, key, under(list, x, w))
    local f = UI.flashLevel(list, key)
    UI.fill(c, x, y + 2, w, ROW - 4, P.panel)
    if on then UI.fill(c, x, y + 2, w, ROW - 4, P.sel, 0.35) end
    if k > 0 or f > 0 then UI.fill(c, x, y + 2, w, ROW - 4, P.sel, 0.14 * k + 0.3 * f) end
    UI.frame(c, x, y + 2, w, ROW - 4, on and P.value or P.border)
    if k > 0 then UI.frame(c, x, y + 2, w, ROW - 4, P.sel, 0.75 * k) end
    UI.textCentre(c, text, x + w / 2, y + (ROW - FONT_HGT_SMALL) / 2, tc)
end

-- A pipe's colour square and its number (BU.Water), at x on a row.
local function pipeMark(c, x, y, id)
    local size = ROW - 12
    UI.fill(c, x, y + 6, size, size, BU.Water.colour(id))
    UI.frame(c, x, y + 6, size, size, P.border)
    UI.text(c, tostring(id), x + size + 3, y + (ROW - FONT_HGT_SMALL) / 2, P.text)
end

-- A pipe chip: a small button with the pipe's mark.
local function pipeChip(list, c, key, x, y, w, id)
    smallButton(list, c, key, x, y, w, "", P.text)
    pipeMark(c, x + 4, y, id)
end

-- A row's view options (optionButtons), each lit while it is on.
local function drawOptions(list, c, index, width, y, row)
    local options = BU.PanelWindow.options
    for _, button in ipairs(optionButtons(width, row)) do
        local on = options[OPTION_FLAGS[button.name]] == true
        local text = label(OPTION_LABELS[button.name])
        smallButton(list, c, index .. button.name, button.x, y, button.w, text, on and P.bright or P.text, on)
    end
end

-- A tick: "on", "off", or "some" for a room whose devices are partly connected; lit under the mouse.
local GREEN = { 0.45, 0.92, 0.5 }
local function tick(list, c, key, x, y, state)
    local size = ROW - 6
    local k = UI.hoverLight(list, key, under(list, x, size))
    UI.fill(c, x, y + 3, size, size, P.inset)
    if k > 0 then UI.fill(c, x, y + 3, size, size, P.sel, 0.18 * k) end
    UI.frame(c, x, y + 3, size, size, k > 0.5 and P.sel or P.dim)
    if state == "on" then
        UI.fill(c, x + 3, y + 6, size - 6, size - 6, GREEN)
    elseif state == "some" then
        UI.fill(c, x + 4, y + ROW / 2 - 2, size - 8, 4, GREEN)
    end
end

-- The energy graph: a column an hour, the last Store.ENERGY_HOURS of them and the hour going on; what the solar
-- panels made (yellow) and the load supplied (grey) against the largest of them, and the bank's charge (green, of
-- the full height).
local GRAPH_H = 96
local SUN, USED, CHARGE = { 1, 0.85, 0.2 }, { 0.75, 0.75, 0.75 }, { 0.3, 0.9, 0.4 }
local function drawGraph(c, y, width, row)
    local hours = row.hours
    local left, right = PAD, width - PAD - SCROLLBAR
    local top, bottom = y + FONT_HGT_SMALL + 6, y + GRAPH_H - 6
    local plotH = bottom - top
    local most = 0.05
    for _, hour in ipairs(hours) do most = math.max(most, hour.made or 0, hour.used or 0) end
    UI.text(c, getText("IGUI_BU_GraphTitle", #hours, string.format("%.2f", most)), left, y + 2, P.text)
    UI.fill(c, left, top, right - left, plotH, P.inset, 0.8)
    UI.frame(c, left, top, right - left, plotH, P.border)
    local columns = Store.ENERGY_HOURS + 1
    local w = (right - left) / columns
    local first = columns - #hours
    for index, hour in ipairs(hours) do
        local x = left + (first + index - 1) * w
        local made = (hour.made or 0) / most * plotH
        local used = (hour.used or 0) / most * plotH
        if made > 0 then UI.fill(c, x + 1, bottom - made, math.max(1, w / 2 - 1), made, SUN, 0.85) end
        if used > 0 then UI.fill(c, x + w / 2, bottom - used, math.max(1, w / 2 - 1), used, USED, 0.7) end
        if hour.charge then UI.fill(c, x, bottom - hour.charge * plotH - 1, math.max(2, w), 3, CHARGE) end
    end
end

-- Colours of the rows' texts.
local HEAD, LINK, OPEN = P.head, { 0.75, 0.85, 1 }, { 0.5, 0.75, 1 }
local NOTE, FILTER, LOG_TEXT, LOG_BAD, LOG_GOOD = { 0.7, 0.7, 0.7 }, { 1, 1, 0.6 }, { 0.9, 0.9, 0.9 }, { 1, 0.55, 0.5 },
    { 0.6, 1, 0.6 }
local IN_USE, OUT, PLAIN, MUTED, FLOOR_TEXT = { 0.5, 1, 0.5 }, { 1, 0.65, 0.3 }, { 0.9, 0.9, 0.9 }, { 0.5, 0.5, 0.5 },
    { 0.75, 0.9, 1 }
local HELD, DIM, RIGHT, FRESH = { 1, 0.65, 0.3 }, { 0.55, 0.55, 0.55 }, { 0.8, 0.8, 0.8 }, { 0.3, 0.9, 1 }
local TIMED, UNTIMED = { 0.6, 0.8, 1 }, { 0.8, 0.8, 0.8 }
local ROOM_RIGHT, FLOOR_BG, FLOOR_LINE = { 0.9, 0.85, 0.6 }, { 0.12, 0.2, 0.3 }, { 0.35, 0.5, 0.65 }
local WHITE = { 1, 1, 1 }

function ISBUPanelList:doDrawItem(y, item, alt)
    local row = item.item
    local design = row.kind == "graph" and GRAPH_H or ROW
    item.height = UI.px(design)
    -- Out of view: only its place, as the game's list does (y and the height in the list's pixels).
    local nextY = y + item.height
    local top = y + self:getYScroll()
    if top + item.height < 0 or top >= self:getHeight() then return nextY end
    local c = UI.designCanvas(self)
    local yd = c == self and y or UI.dp(y)
    local width = c == self and self:getWidth() or c.width
    if row.kind == "graph" then
        drawGraph(c, yd, width, row)
        return nextY
    end
    y = yd
    local textY = y + (ROW - FONT_HGT_SMALL) / 2
    local index = item.index
    -- The row under the mouse lit, coming in and fading as the mouse moves on (UI.placeLight), an accent at its left;
    -- a click flashes it; its buttons light as the mouse goes over them. The row chosen (clicked, or found from the
    -- plan) stays lit.
    local lit, flash = UI.placeLevels(self, index)
    if self.selected == index then lit = math.max(lit, 1) end
    if lit > 0.01 or flash > 0.01 then
        UI.fill(c, 0, y, width, ROW, P.sel, 0.1 * lit + 0.22 * flash)
        UI.fill(c, 0, y + 1, 3, ROW - 2, P.sel, 0.9 * math.max(lit, flash))
    end
    self.rowMouseX = (index == self.hoverIndex or row.options and index == self.overIndex) and self.mouseDX or nil
    -- What the mouse is over on the plan.
    local window = self.window
    local planned = row.key ~= nil and row.key == window.planHoverKey
        or row.kind == "room" and window.planHoverRoom ~= nil and row.id == window.planHoverRoom
    if planned then UI.frame(c, 1, y, width - SCROLLBAR - 2, ROW, P.warn) end
    local rightX = width - PAD - SCROLLBAR
    if row.kind == "header" then
        UI.fill(c, 0, y, width, ROW, P.panel, 0.95)
        UI.fill(c, 0, y + ROW - 1, width, 1, P.border, 0.8)
        UI.text(c, row.text, PAD, textY, HEAD)
        if row.options then drawOptions(self, c, index, width, y, row) end
        if row.right then UI.textRight(c, row.right, rightX, textY, HEAD) end
    elseif row.kind == "floor" then
        UI.fill(c, 0, y, width, ROW, FLOOR_BG, 0.6)
        UI.fill(c, 0, y + ROW - 1, width, 1, FLOOR_LINE, 0.7)
        UI.text(c, row.folded and "+" or "-", PAD, textY, FLOOR_TEXT)
        UI.text(c, row.text, PAD * 3, textY, FLOOR_TEXT)
        if row.right then UI.textRight(c, row.right, rightX, textY, FLOOR_TEXT) end
    elseif row.kind == "room" then
        UI.fill(c, 0, y, width, ROW, P.panel, 0.7)
        UI.text(c, row.folded and "+" or "-", PAD, textY, HEAD)
        local x = ROOM_TICK_X
        -- Below the tier that cuts devices the tick's place stays empty.
        if row.state then
            if not row.fixed then tick(self, c, index .. "tick", x, y, row.state) end
            x = x + ROW + 4
        end
        UI.text(c, row.text, x, textY, HEAD)
        local right = rightX
        for _, button in ipairs(roomButtons(width, row)) do
            pipeChip(self, c, index .. button.name, button.x, y, button.w, row.pipe)
            right = math.min(right, button.x - 6)
        end
        if row.right then UI.textRight(c, row.right, right, textY, ROOM_RIGHT) end
    elseif row.kind == "columns" then
        local cols = BU.RackWindow.COLUMNS
        UI.text(c, label("IGUI_BU_Rack_ColKind"), PAD + cols.kind, textY, NOTE)
        UI.text(c, label("IGUI_BU_Rack_ColCondition"), PAD + cols.condition, textY, NOTE)
        UI.text(c, label("IGUI_BU_Rack_ColStored"), PAD + cols.stored, textY, NOTE)
        UI.text(c, label("IGUI_BU_Rack_ColOutput"), PAD + cols.output, textY, NOTE)
    elseif row.kind == "rack" then
        UI.fill(c, 0, y, width, ROW, P.panel, 0.7)
        UI.text(c, row.folded and "+" or "-", PAD, textY, HEAD)
        BU.RackWindow.drawSummary(c, y, row.view, row.text, PAD, PAD * 3, rightX)
    elseif row.kind == "battery" then
        BU.RackWindow.drawBattery(c, y, row.battery, PAD)
    elseif row.kind == "note" or row.kind == "filter" then
        UI.text(c, row.text, PAD * 2, textY, row.kind == "filter" and FILTER or row.dead and OUT or NOTE)
    elseif row.kind == "log" then
        UI.text(c, row.text, PAD, textY, row.bad and LOG_BAD or row.good and LOG_GOOD or LOG_TEXT)
        UI.textRight(c, row.right, rightX, textY, NOTE)
    elseif row.kind == "source" then
        UI.text(c, row.text, PAD * 2, textY, row.inUse and IN_USE or PLAIN)
        for _, button in ipairs(sourceButtons(width, row)) do
            -- Switching to solar before the source is ready is greyed (its tooltip says why).
            local ready = button.name ~= "UseSource" or row.useSourceReady
            smallButton(self, c, index .. button.name, button.x, y, button.w, label("IGUI_BU_UseSource"),
                ready and WHITE or MUTED)
        end
    elseif row.kind == "producer" and row.nested then
        -- Water's tank or unit under its room: its name where a device's is, what it holds or does on the right (in use
        -- in green, what keeps it from water in red), its pipe chips after.
        local muted = row.unwired or row.cut
        UI.text(c, row.text, PAD * 3 + ROW + 4, textY, muted and MUTED or PLAIN)
        local textRight = rightX
        for _, button in ipairs(producerButtons(width, row)) do
            pipeChip(self, c, index .. button.name, button.x, y, button.w, row.pipes[button.name])
            textRight = math.min(textRight, button.x - 8)
        end
        if row.right then
            UI.textRight(c, row.right, textRight, textY, row.bad and LOG_BAD or muted and MUTED or row.inUse and IN_USE
                or RIGHT)
        end
    elseif row.kind == "producer" then
        -- In use in green, out of service (switched off by hand) in amber, what keeps it from water in red.
        UI.text(c, row.text, PAD * 2, textY, (row.unwired or row.cut) and MUTED or row.bad and LOG_BAD or row.inUse and IN_USE
            or row.out and OUT or PLAIN)
        for _, button in ipairs(producerButtons(width, row)) do
            if CHIPS[button.name] then
                pipeChip(self, c, index .. button.name, button.x, y, button.w, row.pipes[button.name])
            else
                smallButton(self, c, index .. button.name, button.x, y, button.w, label("IGUI_BU_" .. button.name), WHITE)
            end
        end
    elseif row.kind == "waterPipe" then
        UI.fill(c, 0, y, width, ROW, P.panel, 0.7)
        UI.fill(c, 0, y + 1, 3, ROW - 2, BU.Water.colour(row.pipe))
        pipeMark(c, PAD * 2, y, row.pipe)
        local x = PAD * 2 + ROW - 6 + UI.textWidth(tostring(row.pipe)) + 8
        UI.text(c, row.text, x, textY, WHITE)
        local buttons = pipeButtons(width, row)
        for _, button in ipairs(buttons) do
            smallButton(self, c, index .. button.name, button.x, y, button.w, label("IGUI_BU_" .. button.name), WHITE)
        end
        if row.right then UI.textRight(c, row.right, buttons[1].x - 8, textY, row.bad and LOG_BAD or LINK) end
    elseif row.kind == "pipeBuilding" then
        UI.text(c, row.text, PAD * 4, textY, row.bad and LOG_BAD or NOTE)
        if row.right then UI.textRight(c, row.right, rightX, textY, NOTE) end
    elseif row.kind == "addPipe" then
        UI.text(c, row.text, PAD * 2, textY, row.reason and MUTED or OPEN)
        if row.right then UI.textRight(c, row.right, rightX, textY, row.reason and LOG_BAD or NOTE) end
    elseif row.kind == "device" or row.kind == "all" then
        local indent = row.kind == "device" and PAD * 3 or PAD * 2
        -- a device outside the box has no line to has no tick: there is nothing to switch at the box; below the tier
        -- that cuts devices none has
        if not row.unwired and not row.fixed then tick(self, c, index .. "tick", indent, y, row.state == "on" and "on" or "off") end
        UI.text(c, row.text, indent + ROW + 4, textY, (row.state == "other" or row.unwired) and MUTED or PLAIN)
        if row.fresh then
            if not row.freshX or row.freshEra ~= UI.era then
                row.freshX, row.freshEra = indent + ROW + 4 + UI.textWidth(row.text) + 6, UI.era
            end
            UI.text(c, label("IGUI_BU_New"), row.freshX, textY, FRESH)
        end
        local buttons, textRight = deviceButtons(width, row)
        for _, button in ipairs(buttons) do
            local key = index .. button.name
            if button.name == "pipe" then
                pipeChip(self, c, key, button.x, y, button.w, row.pipe)
            else
                local timed = row.device.schedule ~= "always"
                smallButton(self, c, key, button.x, y, button.w, label("IGUI_BU_Schedule_" .. row.device.schedule),
                    timed and TIMED or UNTIMED)
            end
        end
        if row.right then
            UI.textRight(c, row.right, textRight, textY, row.bad and LOG_BAD or row.held and HELD or row.dim and DIM or RIGHT)
        end
    end
    return nextY
end

-- The list's content slides in from the side it came from as its tab opens (dir: 1 from the right, -1 from the
-- left), fading in; followed each frame while it moves (UI.live).
local function slideFrame(list, now)
    local t = list.switchedAt and (now - list.switchedAt) / Ui.SWITCH_MS or 1
    if t >= 1 then return nil end
    return math.floor(t * 100)
end

function ISBUPanelList:switched(dir)
    self.switchedAt, self.switchDir = getTimestampMs(), dir
    UI.live(self, slideFrame)
end

-- The row under the mouse outlines its objects in the world and marks them on the plan, until the mouse leaves it;
-- it is lit (UI.placeLight) unless it only tells, and its tooltip (row.tip, rich text) shows in the kit's
-- (PZUIRichTip).
function ISBUPanelList:prerender()
    local index = self:isVisible() and self:isMouseOver() and not self:isMouseOverScrollBar() and self.mouseoverselected or nil
    local item = index and self.items[index]
    local row = item and item.item
    self.mouseDX = UI.dp(self:getMouseX())
    self.window.listHoverKey = row and row.key or nil
    self.window.listHoverRoom = row and (row.device and row.device.roomId or row.kind == "room" and row.id) or nil
    local lit = row and not STILL[row.kind] and index or nil
    self.overIndex = index
    self.hoverIndex = lit
    UI.placeLight(self, lit)
    -- over a button that says what it does, its own tooltip; else the row's
    local tip = row and row.tip
    for _, button in ipairs(row and row.buttons or {}) do
        local key = ISBUPanelList.BUTTON_TIPS[button.name]
        if key and self.mouseDX >= button.x and self.mouseDX < button.x + button.w then tip = getText(key) end
    end
    if tip then PZUIRichTip.show(self, tip, P) else PZUIRichTip.hide(self) end
    local outlined = row and (row.device or row.at or row.unit or row.members) and index or nil
    if outlined ~= self.hovered then
        self:unhighlight()
        self.hovered = outlined
        if outlined then
            -- A pipe's card: what is on the pipe, in its colour.
            local colour = row.colour and row.members and ColorInfo.new(row.colour[1], row.colour[2], row.colour[3], 1)
                or getCore():getGoodHighlitedColor()
            outline(self.window.playerObj:getPlayerNum(), rowObjects(row), colour, self.highlighted)
        end
    end
    local now = getTimestampMs()
    -- Its content slid by the game's scroll across (its drawing moves, its scroll bar and its clip stay); the
    -- background and the border drawn here in place meanwhile.
    local t = self.switchedAt and (now - self.switchedAt) / Ui.SWITCH_MS or 1
    if t >= 1 then self.switchedAt = nil end
    local slide = t < 1 and math.floor((1 - ease(t)) * UI.px(Ui.SLIDE) * (self.switchDir or 1)) or 0
    -- straight on the game's element: the list's own setXScroll keeps it within what it can scroll (none)
    if self:getXScroll() ~= slide then self.javaObject:setXScroll(slide) end
    local bg, yScroll = self.backgroundColor, -self:getYScroll()
    local alpha, border = bg.a, self.drawBorder
    if slide ~= 0 then
        self:drawRect(-slide, yScroll, self.width, self.height, alpha, bg.r, bg.g, bg.b)
        bg.a, self.drawBorder = 0, false
    end
    ISScrollingListBox.prerender(self)
    bg.a, self.drawBorder = alpha, border
    if t < 1 then
        self:drawRect(-slide, yScroll, self.width, self.height, (1 - ease(t)) * 0.85, bg.r, bg.g, bg.b)
        if border then
            local b = self.borderColor
            self:drawRectBorder(-slide, yScroll, self.width, self.height, b.a, b.r, b.g, b.b)
        end
    end
end

function ISBUPanelList:unhighlight()
    unoutline(self.window.playerObj:getPlayerNum(), self.highlighted)
    self.highlighted = {}
end

function ISBUPanelList:hideTooltip()
    PZUIRichTip.hide(self)
end

-- A click: the row flashes, its button too, and the window acts on it (x in design units, as the rows are drawn).
function ISBUPanelList:onMouseDown(x, y)
    local index = self:rowAt(x, y)
    local item = index and index > 0 and self.items[index]
    if item then
        local dx, width = UI.dp(x), UI.dp(self:getWidth())
        if not STILL[item.item.kind] then UI.placeFlash(self, index) end
        -- the row clicked is the one chosen now (none, for a row that stands for no thing)
        self.window:chooseRow(self.utility, item.item.key, true)
        for _, button in ipairs(item.item.buttons or {}) do
            if dx >= button.x and dx < button.x + button.w then UI.flash(self, index .. button.name) end
        end
        self.window:onRow(self.utility, item.item, dx, width)
    end
    return true
end

-- The window's tabs: a strip over the lists in the window's palette, as Operation Acorn's terminal draws its tabs (the
-- open one on the background with the accent line under it, gliding to a tab as it opens; the one under the mouse
-- lit, a click flashing). It keeps the lists as its views below the strip (game lists, placed in pixels from design
-- units), under the open tab's head (setHead). The calls the window makes are the game's tab panel's: addView,
-- activateView, getActiveViewIndex, activeView, tabHeight, getWidthOfAllTabs; and setDot, a tab marked for something
-- new in it.
ISBUTabs = ISPanel:derive("ISBUTabs")

function ISBUTabs:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.background = false
    o.tabHeight = ROW + 2
    o.viewList, o.slots = {}, {}
    return o
end

function ISBUTabs:addView(name, view)
    local entry = { name = name, view = view, w = UI.textWidth(name) + 28 }
    self.viewList[#self.viewList + 1] = entry
    self:addChild(view)
    local top = self.tabHeight + (self.headH or 0)
    UI.place(view, 0, top, self.width, self.height - top)
    view:setVisible(#self.viewList == 1)
    if #self.viewList == 1 then self.activeView = entry end
end

function ISBUTabs:getActiveViewIndex()
    for index, entry in ipairs(self.viewList) do
        if entry == self.activeView then return index end
    end
    return nil
end

function ISBUTabs:activateView(name)
    for _, entry in ipairs(self.viewList) do
        if entry.name == name then
            if self.activeView ~= entry then
                if self.activeView then self.activeView.view:setVisible(false) end
                self.activeView = entry
                entry.view:setVisible(true)
                UI.live(self, ISBUTabs.glideFrame)
            end
            return true
        end
    end
    return false
end

function ISBUTabs:getWidthOfAllTabs()
    local w = 4
    for _, entry in ipairs(self.viewList) do w = w + entry.w + 3 end
    return w
end

-- The strip and its views made so wide and high (design units in, the lists' pixels out).
function ISBUTabs:resize(w, h)
    self:setWidth(w)
    self:setHeight(h)
    local top = self.tabHeight + (self.headH or 0)
    for _, entry in ipairs(self.viewList) do UI.place(entry.view, 0, top, w, h - top) end
end

-- A view's tab marked (a small square at its corner) or not.
function ISBUTabs:setDot(view, on)
    for _, entry in ipairs(self.viewList) do
        if entry.view == view then entry.dot = on or nil end
    end
end

-- Room under the strip for the open tab's head (the window draws it there); the views start under it.
function ISBUTabs:setHead(h)
    if self.headH == h then return end
    self.headH = h
    self:resize(self.width, self.height)
end

-- The accent line's place, gliding toward the open tab (followed each frame while it moves). The open tab's slot is
-- found by its index: a tab just opened is followed before it is drawn (its slot still the last one drawn open).
function ISBUTabs.glideFrame(self, now)
    local index = self:getActiveViewIndex()
    local slot = index and self.slots[index]
    if not (slot and self.lineX) then return nil end
    if math.abs(self.lineX - slot.x) < 0.5 and math.abs(self.lineW - slot.w) < 0.5 then return nil end
    return math.floor(self.lineX * 10)
end

function ISBUTabs:prerender()
    local h = self.tabHeight
    UI.fill(self, 0, 0, self.width, h, P.tabStrip)
    local fh = FONT_HGT_SMALL
    local mx = self:isMouseOver() and self:getMouseY() < h and self:getMouseX() or -1
    local x = 4
    local slots = self.slots
    local now = getTimestampMs()
    local ms = math.min(100, now - (self.frameAt or now))
    self.frameAt = now
    for index, entry in ipairs(self.viewList) do
        local on = entry == self.activeView
        local tw = entry.w
        local k = UI.hoverLight(self, index, not on and mx >= x and mx < x + tw)
        local f = UI.flashLevel(self, index)
        if on then
            UI.fill(self, x, 2, tw, h - 2, P.bg)
        elseif k > 0 then
            UI.fill(self, x, 2, tw, h - 2, P.bg, 0.6 * k)
        end
        if f > 0 then UI.fill(self, x, 2, tw, h - 2, P.sel, 0.25 * f) end
        UI.textCentre(self, entry.name, x + tw / 2, (h - fh) / 2 + 1, (on or k > 0.5) and P.bright or P.dim)
        if entry.dot then UI.fill(self, x + tw - 8, 5, 4, 4, P.warn) end
        local slot = slots[index] or {}
        slots[index] = slot
        slot.x, slot.w, slot.name = x, tw, entry.name
        if on then self.activeSlot = slot end
        x = x + tw + 3
    end
    for i = #slots, #self.viewList + 1, -1 do slots[i] = nil end
    local slot = self.activeSlot
    if slot then
        if not self.lineX then self.lineX, self.lineW = slot.x, slot.w end
        self.lineX, self.lineW = approach(self.lineX, slot.x, ms, 45), approach(self.lineW, slot.w, ms, 45)
        UI.fill(self, self.lineX + 2, h - 3, self.lineW - 4, 2, P.value)
    end
    UI.fill(self, 0, h - 1, self.width, 1, P.border)
end

function ISBUTabs:onMouseDown(x, y)
    if y >= self.tabHeight then return false end
    for index, slot in ipairs(self.slots) do
        if x >= slot.x and x < slot.x + slot.w then
            UI.flash(self, index)
            self:activateView(slot.name)
            return true
        end
    end
    return true
end

UI.scaled(ISBUTabs, ISPanel)

-- The divider between the list and the plan: dragged, it moves the share of the window the plan takes. A grip in its
-- middle, lit under the mouse and while dragged.
ISBUSplitter = ISPanel:derive("ISBUSplitter")

function ISBUSplitter:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = false
    return o
end

function ISBUSplitter:render()
    local k = UI.hoverLight(self, "hover", self.dragging or self:isMouseOver())
    local w, middle = self.width, math.floor(self.height / 2)
    if k > 0 then UI.fill(self, w / 2 - 1, 0, 2, self.height, P.sel, 0.25 * k) end
    for i = -2, 2 do UI.fill(self, w / 2 - 1, middle - 1 + i * 5, 2, 2, k > 0.5 and P.sel or P.dim) end
end

function ISBUSplitter:onMouseDown(x, y)
    self.dragging = true
    return true
end

-- The window's mouse in the body's design units.
function ISBUSplitter:drag()
    if self.dragging then self.window:dragDivider(UI.dp(self.window:getMouseX()) - self.width / 2) end
end

function ISBUSplitter:onMouseMove(dx, dy) self:drag() end
function ISBUSplitter:onMouseMoveOutside(dx, dy) self:drag() end

function ISBUSplitter:onMouseUp(x, y)
    self.dragging = false
    return true
end

function ISBUSplitter:onMouseUpOutside(x, y) self.dragging = false end

UI.scaled(ISBUSplitter, ISPanel)

Ui.deviceButtons = deviceButtons
Ui.producerButtons = producerButtons
Ui.pipeButtons = pipeButtons
Ui.roomButtons = roomButtons
Ui.sourceButtons = sourceButtons
Ui.optionButtons = optionButtons
