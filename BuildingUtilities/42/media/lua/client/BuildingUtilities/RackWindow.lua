-- A battery rack's window, opened at the rack (its world menu): only that rack, to read, not to work. Its status line
-- (charging, drawn, or not wired), its charge large, what it stores, what goes in or out of it now and what its
-- batteries add to its box's limit (BU.Panels.limit); then a line per battery, by what it gives and its condition; at
-- the foot how many it holds and what cold locks. Batteries go in and out through the rack's container, and the rack
-- is wired as a unit, at itself. The window closes once its player is far from the rack, dies or another takes their
-- place, as a box's does.
require "TimedActions/ISBaseTimedAction"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "BuildingUtilities/PanelUi"
require "BuildingUtilities/Rack"
local BU = BuildingUtilities
local Store, Panels, Networks, Energy, Rack = BU.Store, BU.Panels, BU.Networks, BU.Energy, BU.Rack
local Ui = BU.PanelUi
local UI, P = Ui.UI, Ui.PALETTE
local FONT_HGT_SMALL, ROW, PAD, load2 = Ui.FONT_HGT_SMALL, Ui.ROW, Ui.PAD, Ui.load2

local RackWindow = {}
BU.RackWindow = RackWindow
local open = {}

-- Sizes (design units): the window, the header under the status line, the columns of the list (from its left).
RackWindow.WIDTH, RackWindow.HEIGHT, RackWindow.HEAD_H = 380, 400, 52
RackWindow.COLUMNS = { kind = 8, condition = 140, stored = 250, output = 305 }
-- Condition: amber below this, red below the bank's WEAK (the battery drains it).
RackWindow.FAIR = 50
local SETTLE_MS = 100

-- What the window shows of a rack now: its batteries sorted (by output, then condition), what they store and give,
-- its charge, the flow in or out of it (its share of its bank's, panel.bankFlow) and how long that lasts, the share
-- cold locks, and its state for the status line.
function RackWindow.measure(unit)
    local panel = Store.get(unit.panel)
    local bank = panel and Energy.bank(panel) or nil
    local cold = bank and bank.cold or Energy.coldShare({ unit })
    local view = { panel = panel, bank = bank, cold = cold, batteries = {}, capacity = 0, energy = 0, output = 0 }
    for _, record in ipairs(unit.batteries or {}) do
        local capacity, output = Energy.batteryCapacity(record), Energy.batteryOutput(record) * (1 - cold)
        view.batteries[#view.batteries + 1] = { record = record, kind = Rack.batteryKind(record.type),
            capacity = capacity, output = output, condition = record.condition or 100 }
        view.capacity = view.capacity + capacity
        view.energy = view.energy + capacity * (record.charge or 0)
        view.output = view.output + output
    end
    table.sort(view.batteries, function(a, b)
        if math.abs(a.output - b.output) > 1e-6 then return a.output > b.output end
        return a.condition > b.condition
    end)
    view.charge = view.capacity > 0 and view.energy / view.capacity or 0
    view.state = "idle"
    if not panel then
        view.state = "unwired"
    elseif bank and view.capacity > 0 then
        local flow = (panel.bankFlow or 0) * view.capacity / bank.capacity
        view.flow = flow
        local state = Networks.state(panel, "power")
        if flow < -0.0005 and state then
            view.state = "out"
            local rules = Energy.rules(panel, state)
            local floor = Energy.overDraw(panel, state, rules, bank) > 0 and Energy.boostFloor(panel) or rules.floor
            view.hours = Energy.bankHoursLeft(bank, floor, panel.bankFlow)
        elseif flow > 0.0005 and bank.energy < bank.capacity then
            view.state = "in"
            view.hours = (bank.capacity - bank.energy) / panel.bankFlow
        end
        view.boosting = Energy.boost(panel, bank) > 0
    end
    return view
end

local STATE_TEXT = { out = "IGUI_BU_Rack_Out", ["in"] = "IGUI_BU_Rack_In", idle = "IGUI_BU_Rack_Idle",
    unwired = "IGUI_BU_Rack_Unwired" }

local function stateColour(state)
    if state == "out" then return P.value end
    if state == "in" then return P.good end
    if state == "unwired" then return P.warn end
    return P.dim
end

local function conditionColour(condition)
    if condition < Energy.WEAK then return P.bad end
    if condition < RackWindow.FAIR then return P.warn end
    return P.text
end

-- The window.
ISBURackWindow = ISCollapsableWindow:derive("ISBURackWindow")

function ISBURackWindow:new(x, y, playerObj, unit)
    UI.refreshScale()
    local chrome = UI.titleBarHeight() + UI.resizeWidgetHeight()
    local o = ISCollapsableWindow.new(self, x, y, UI.px(RackWindow.WIDTH), UI.px(RackWindow.HEIGHT) + chrome)
    o.playerObj = playerObj
    o.unitId = unit.id
    o.unit = unit
    o.era = UI.era
    o.palette = P
    o.resizable = true
    o.minimumWidth = UI.px(RackWindow.WIDTH)
    o.minimumHeight = UI.px(240) + chrome
    o:setTitle(BU.Units.name(unit))
    return o
end

function ISBURackWindow:titleBarHeight() return UI.titleBarHeight() end
function ISBURackWindow:resizeWidgetHeight() return UI.resizeWidgetHeight() end

-- The body, in design units: it draws the status line, the header, the list's column titles and the foot.
ISBURackBody = ISPanel:derive("ISBURackBody")

function ISBURackBody:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = false
    return o
end

function ISBURackBody:prerender() self.window:drawBody(self) end

UI.scaled(ISBURackBody, ISPanel)

-- A battery's line from x (0 when not given; the box's battery tab too): its kind (the larger kinds lit), its condition
-- with a short bar, what it stores and gives.
function RackWindow.drawBattery(c, y, battery, x)
    x = x or 0
    local cols = RackWindow.COLUMNS
    local textY = y + math.floor((ROW - FONT_HGT_SMALL) / 2)
    UI.text(c, getText("IGUI_VehicleType_" .. battery.kind), x + cols.kind, textY, battery.kind == 1 and P.text or P.value)
    local condition = math.floor(battery.condition + 0.5)
    local colour = conditionColour(battery.condition)
    local barW = 40
    local barY = y + math.floor(ROW / 2) - 2
    UI.fill(c, x + cols.condition, barY, barW, 4, P.inset)
    local filled = math.floor(barW * math.max(0, math.min(100, battery.condition)) / 100)
    UI.fill(c, x + cols.condition, barY, filled, 4, colour, 0.9)
    UI.frame(c, x + cols.condition, barY, barW, 4, P.border)
    UI.text(c, tostring(condition), x + cols.condition + barW + 6, textY, colour)
    UI.text(c, string.format("%.1f", battery.capacity), x + cols.stored, textY, P.text)
    UI.text(c, load2(battery.output), x + cols.output, textY, battery.output > 0 and P.text or P.dim)
end

-- A rack's line in sum, in the battery columns from x (the box's battery tab): its title from titleX, its state, what
-- it stores and gives; at rightX how long the flow lasts and its charge.
function RackWindow.drawSummary(c, y, view, title, x, titleX, rightX)
    local cols = RackWindow.COLUMNS
    local textY = y + math.floor((ROW - FONT_HGT_SMALL) / 2)
    UI.text(c, UI.fitMemo(title, x + cols.condition - titleX - 8), titleX, textY, P.head)
    UI.text(c, getText(STATE_TEXT[view.state]), x + cols.condition, textY, stateColour(view.state))
    UI.text(c, string.format("%.1f", view.capacity), x + cols.stored, textY, P.text)
    UI.text(c, load2(view.output), x + cols.output, textY, view.output > 0 and P.text or P.dim)
    local charge = BU.percent(view.charge * 100)
    UI.textRight(c, charge, rightX, textY, P.head)
    if view.hours then
        UI.textRight(c, Ui.duration(view.hours), rightX - UI.textWidth(charge) - 12, textY, stateColour(view.state))
    end
end

function ISBURackWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    for _, b in ipairs({ self.pinButton, self.collapseButton, self.infoButton }) do
        if b then b:setVisible(false) end
    end
    UI.closeBox(self, P)
    local th, rh = self:titleBarHeight(), self:resizeWidgetHeight()
    local body = ISBURackBody:new(0, UI.dp(th), UI.dp(self.width), UI.dp(self.height - th - rh), self)
    body:initialise()
    body:instantiate()
    body:setAnchorRight(true)
    body:setAnchorBottom(true)
    self:addChild(body)
    self.body = body
    self.statusY = PAD
    self.headY = self.statusY + FONT_HGT_SMALL + 8
    self.columnsY = self.headY + RackWindow.HEAD_H + 6
    local listY = self.columnsY + FONT_HGT_SMALL + 4
    local listH = body:getHeight() - listY - FONT_HGT_SMALL - PAD - 6
    local list = UI.list(body, PAD, listY, body:getWidth() - PAD * 2, listH,
        function(c, y, item) RackWindow.drawBattery(c, y, item.item) end)
    list:setAnchorRight(true)
    list:setAnchorBottom(true)
    list.backgroundColor = { r = P.inset[1], g = P.inset[2], b = P.inset[3], a = 1 }
    list.borderColor = { r = P.border[1], g = P.border[2], b = P.border[3], a = 1 }
    list.mouseOverHighlightColor = { r = P.value[1], g = P.value[2], b = P.value[3], a = 0.06 }
    list.drawSelection = function() end
    UI.rowHeight(list, ROW)
    self.list = list
    self:refresh()
end

function ISBURackWindow:prerender()
    local th = self:titleBarHeight()
    UI.fill(self, 0, 0, self.width, self.height, P.bg, P.bgAlpha)
    UI.fill(self, 0, 0, self.width, th, P.title)
    UI.fill(self, 0, th - 1, self.width, 1, P.border)
    UI.windowTitle(self, self.title, P.text)
end

function ISBURackWindow:render()
    local rh = self:resizeWidgetHeight()
    local w, h = self.width, self.height
    UI.fill(self, 0, h - rh, w, 1, P.border, 0.6)
    for i = 0, 2 do
        for j = 0, i do UI.fill(self, w - 5 - 4 * j, h - rh + 3 + 4 * (2 - i), 2, 2, P.dim) end
    end
    UI.frame(self, 0, 0, w, h, P.border)
end

-- The rack as the data has it now (received anew on a multiplayer client): its view and its list.
function ISBURackWindow:refresh()
    self.refreshedAt, self.changedAt = getTimestampMs(), nil
    local unit = Store.unit(self.unitId)
    if not unit then return end
    self.unit = unit
    local view = RackWindow.measure(unit)
    self.view = view
    local list = self.list
    list:clear()
    for _, battery in ipairs(view.batteries) do list:addItem(battery.record.type, battery) end
    -- the status line: its state, and the box it is wired to (or how it is wired)
    self.stateText = getText(STATE_TEXT[view.state])
    self.stateWhere = view.panel and getText("IGUI_BU_Rack_WiredTo", Panels.name(view.panel))
        or getText("IGUI_BU_Rack_WireHint")
    -- the header's lines: label and value, each with its colour
    local muted = view.panel == nil
    local flowText, flowColour = getText("IGUI_BU_Rack_FlowNone"), P.dim
    if view.state == "out" or view.state == "in" then
        flowText = load2(math.abs(view.flow))
        if view.hours then flowText = getText("IGUI_BU_Rack_FlowFor", flowText, Ui.duration(view.hours)) end
        flowColour = stateColour(view.state)
    end
    self.lines = {
        { getText("IGUI_BU_Rack_Stored"),
            string.format("%.1f / %.1f", view.energy, view.capacity), muted and P.dim or P.text },
        { getText(view.state == "in" and "IGUI_BU_Rack_NowIn" or "IGUI_BU_Rack_NowOut"), flowText, flowColour },
        { getText("IGUI_BU_Rack_Output"), getText("IGUI_BU_Rack_OutputBoost", load2(view.output)),
            (muted or not view.boosting) and P.dim or P.value },
    }
    local foot = getText("IGUI_BU_Rack_Count", #view.batteries)
    if view.cold > 0 then foot = foot .. "  " .. getText("IGUI_BU_Rack_Cold", BU.percent(view.cold * 100)) end
    self.foot = foot
end

-- The status line, the header (the charge large, its lines beside it), the list's column titles, the foot; an empty
-- rack says so where its list is.
function ISBURackWindow:drawBody(body)
    local view = self.view
    if not view then return end
    local colour = stateColour(view.state)
    local dot = FONT_HGT_SMALL - 6
    UI.fill(body, PAD, self.statusY + 3, dot, dot, colour)
    local x = PAD + dot + 6
    UI.text(body, self.stateText, x, self.statusY, colour)
    x = x + UI.textWidth(self.stateText) + 12
    UI.text(body, "- " .. self.stateWhere, x, self.statusY, P.dim)
    -- the charge, large, with its sign small on its baseline and its name under it
    local top = self.headY
    local big = tostring(math.floor(view.charge * 100 + 0.5))
    local bigW = UI.textWidth("100", UIFont.Large)
    local chargeColour = view.panel and (view.charge < 0.15 and P.bad or P.bright) or P.dim
    UI.textRight(body, big, PAD + bigW, top, chargeColour, UIFont.Large)
    UI.text(body, "%", PAD + bigW + 1, top + UI.baselineDrop(UIFont.Large, UIFont.Small), chargeColour)
    UI.text(body, getText("IGUI_BU_Rack_Charge"), PAD, top + UI.fontHeight(UIFont.Large), P.dim)
    local labelX = PAD + bigW + UI.textWidth("%") + 24
    local valueX = labelX
    for _, line in ipairs(self.lines) do valueX = math.max(valueX, labelX + UI.textWidth(line[1]) + 12) end
    for index, line in ipairs(self.lines) do
        local y = top + (index - 1) * (FONT_HGT_SMALL + 2)
        UI.text(body, line[1], labelX, y, P.dim)
        UI.text(body, line[2], valueX, y, line[3])
    end
    -- the column titles over the list
    local cols, listX = RackWindow.COLUMNS, PAD
    UI.text(body, getText("IGUI_BU_Rack_ColKind"), listX + cols.kind, self.columnsY, P.dim)
    UI.text(body, getText("IGUI_BU_Rack_ColCondition"), listX + cols.condition, self.columnsY, P.dim)
    UI.text(body, getText("IGUI_BU_Rack_ColStored"), listX + cols.stored, self.columnsY, P.dim)
    UI.text(body, getText("IGUI_BU_Rack_ColOutput"), listX + cols.output, self.columnsY, P.dim)
    local list = self.list
    local listY, listH = UI.dp(list:getY()), UI.dp(list:getHeight())
    if #view.batteries == 0 then
        UI.textCentre(body, getText("IGUI_BU_Rack_Empty"), PAD + UI.dp(list:getWidth()) / 2,
            listY + math.floor((listH - FONT_HGT_SMALL) / 2), P.dim)
    end
    UI.text(body, self.foot, PAD, listY + listH + 4, P.dim)
end

function ISBURackWindow:update()
    ISCollapsableWindow.update(self)
    local unit = Store.unit(self.unitId)
    if not unit or unit.kind ~= "rack" then self:close(); return end
    if self.era ~= UI.era then
        local x, y = self:getX(), self:getY()
        self:close()
        local window = RackWindow.open(self.playerObj, unit)
        window:setX(x)
        window:setY(y)
        return
    end
    local player = self.playerObj
    if player:isDead() or getSpecificPlayer(player:getPlayerNum()) ~= player then self:close(); return end
    local away = math.max(math.abs(player:getX() - unit.x - 0.5), math.abs(player:getY() - unit.y - 0.5))
        + math.abs(player:getZ() - unit.z) * BU.PanelWindow.TILES_PER_FLOOR
    if away > BU.PanelWindow.CLOSE_RANGE and not ISTimedActionQueue.isPlayerDoingAction(player) then
        self:close()
        return
    end
    local now = getTimestampMs()
    if self.changedAt and now - self.changedAt >= SETTLE_MS or now - (self.refreshedAt or 0) > Ui.REFRESH_MS then
        self:refresh()
    end
end

function ISBURackWindow:changed() self.changedAt = self.changedAt or getTimestampMs() end

function ISBURackWindow:close()
    open[self.unitId] = nil
    UI.fadeOut(self)
end

-- A rack's window: brought up where it is open, else made in the middle of the screen, fading in.
function RackWindow.open(playerObj, unit)
    local window = open[unit.id]
    if window then
        window:bringToTop()
        window:refresh()
        return window
    end
    window = ISBURackWindow:new(0, 0, playerObj, unit)
    window:setX(math.max(0, (getCore():getScreenWidth() - window.width) / 2))
    window:setY(math.max(0, (getCore():getScreenHeight() - window.height) / 2))
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    UI.fadeIn(window)
    open[unit.id] = window
    return window
end

function RackWindow.get(unitId) return open[unitId] end

-- The data changed: every rack window refreshes once that settles.
function RackWindow.refreshAll()
    for _, window in pairs(open) do window:changed() end
end

-- Opening a rack's window: the player walks to the rack first (BU.ContextMenu.queueAt).
ISBUOpenRack = ISBaseTimedAction:derive("ISBUOpenRack")

function ISBUOpenRack:isValid() return Store.unit(self.unitId) ~= nil end

function ISBUOpenRack:perform()
    local unit = Store.unit(self.unitId)
    if unit then RackWindow.open(self.character, unit) end
    ISBaseTimedAction.perform(self)
end

function ISBUOpenRack:new(character, unit)
    local o = ISBaseTimedAction.new(self, character)
    o.unitId = unit.id
    o.maxTime = 0
    return o
end

return RackWindow
