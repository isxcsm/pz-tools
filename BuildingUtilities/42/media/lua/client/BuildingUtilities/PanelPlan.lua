-- The floor plan beside a breaker box window: the building's rooms on one floor from above, north up, coloured by
-- what their devices do; the devices as dots, the producers as squares and the box itself. It shares hover and
-- clicks with the window's list: a row under the mouse marks its room or dot here, a room clicked here shows only
-- that room there, a dot clicked here finds its row. Everything is laid out when the window refreshes; a frame only
-- draws the rectangles laid out, a few dozen.
require "ISUI/ISPanel"
local BU = BuildingUtilities

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local MAX_SCALE = 14
local DOT = 6
local HIT = 5

ISBUPlan = ISPanel:derive("ISBUPlan")

function ISBUPlan:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.cells, o.labels, o.dots, o.squares = {}, {}, {}, {}
    return o
end

-- The colour of a room: kept off by the box (amber), supplied and in use (green), connected without supply (grey
-- blue), all switched off at the box (dark).
local function roomColour(room, supplied)
    if room.held > 0 then return 0.75, 0.45, 0.1 end
    if room.on > 0 then
        if supplied then return 0.2, 0.55, 0.25 end
        return 0.3, 0.35, 0.45
    end
    return 0.22, 0.22, 0.22
end

local function dotColour(device, supplied)
    if device.state == "other" then return 0.6, 0.4, 0.8 end
    if device.state ~= "on" then return 0.45, 0.45, 0.45 end
    if device.held == "shed" then return 1, 0.6, 0.2 end
    if device.held == "timer" then return 0.4, 0.6, 1 end
    if not supplied then return 0.6, 0.65, 0.75 end
    if (device.power or 0) > 0 or device.utility == "water" then return 0.4, 1, 0.4 end
    return 0.25, 0.6, 0.3
end

-- data: { utility, supplied, rooms = { { id, title, level, rects } }, devices = { { key, x, y, z, roomId, inside,
-- state, held, power, name, status } }, producers = { { x, y, z, inUse } }, box = { x, y, z }, filter = room id }.
function ISBUPlan:setData(data)
    self.data = data
    local levels = {}
    for _, room in ipairs(data.rooms) do levels[room.level] = true end
    self.levels = {}
    for level in pairs(levels) do self.levels[#self.levels + 1] = level end
    table.sort(self.levels)
    if not self.floor or not levels[self.floor] then
        self.floor = levels[data.box.z] and data.box.z or self.levels[1] or 0
    end
    self:layout()
end

function ISBUPlan:layout()
    local data = self.data
    self.cells, self.labels, self.dots, self.squares = {}, {}, {}, {}
    if not data then return end
    -- One scale for every floor: the building and all that is connected around it.
    local minX, minY, maxX, maxY
    local function cover(x, y, w, h)
        minX, minY = math.min(minX or x, x), math.min(minY or y, y)
        maxX, maxY = math.max(maxX or x + w, x + w), math.max(maxY or y + h, y + h)
    end
    for _, room in ipairs(data.rooms) do
        for _, rect in ipairs(room.rects) do cover(rect.x, rect.y, rect.w, rect.h) end
    end
    for _, device in ipairs(data.devices) do cover(device.x, device.y, 1, 1) end
    for _, producer in ipairs(data.producers) do cover(producer.x, producer.y, 1, 1) end
    cover(data.box.x, data.box.y, 1, 1)
    if not minX then return end
    local top = FONT_HGT_SMALL + PAD * 2
    local availW, availH = self.width - PAD * 2, self.height - top - FONT_HGT_SMALL - PAD * 2
    local scale = math.min(availW / (maxX - minX), availH / (maxY - minY), MAX_SCALE)
    local ox = PAD + (availW - (maxX - minX) * scale) / 2
    local oy = top + (availH - (maxY - minY) * scale) / 2
    local function sx(x) return math.floor(ox + (x - minX) * scale) end
    local function sy(y) return math.floor(oy + (y - minY) * scale) end
    self.scale = scale
    -- Rooms on this floor, with what their devices do.
    local roomState = {}
    for _, device in ipairs(data.devices) do
        if device.inside then
            local state = roomState[device.roomId] or { on = 0, held = 0 }
            roomState[device.roomId] = state
            if device.state == "on" then
                state.on = state.on + 1
                if device.held then state.held = state.held + 1 end
            end
        end
    end
    for _, room in ipairs(data.rooms) do
        if room.level == self.floor then
            local r, g, b = roomColour(roomState[room.id] or { on = 0, held = 0 }, data.supplied)
            local largest
            for _, rect in ipairs(room.rects) do
                local cell = { x = sx(rect.x), y = sy(rect.y), room = room.id, r = r, g = g, b = b }
                cell.w, cell.h = sx(rect.x + rect.w) - cell.x, sy(rect.y + rect.h) - cell.y
                self.cells[#self.cells + 1] = cell
                if not largest or cell.w * cell.h > largest.w * largest.h then largest = cell end
            end
            if largest and getTextManager():MeasureStringX(UIFont.Small, room.title) < largest.w - 4
                    and largest.h > FONT_HGT_SMALL + 2 then
                self.labels[#self.labels + 1] = { text = room.title, x = largest.x + largest.w / 2,
                    y = largest.y + (largest.h - FONT_HGT_SMALL) / 2 }
            end
        end
    end
    for _, device in ipairs(data.devices) do
        if device.z == self.floor then
            local r, g, b = dotColour(device, data.supplied)
            self.dots[#self.dots + 1] = { key = device.key, room = device.roomId, x = math.floor(sx(device.x) + scale / 2),
                y = math.floor(sy(device.y) + scale / 2), r = r, g = g, b = b, text = device.name .. "  " .. (device.status or "") }
        end
    end
    for _, producer in ipairs(data.producers) do
        if producer.z == self.floor then
            local r, g, b = 1, 0.85, 0.2
            if data.utility == "water" then r, g, b = 0.3, 0.6, 1 end
            self.squares[#self.squares + 1] = { x = sx(producer.x), y = sy(producer.y), size = math.max(scale, 8),
                r = r, g = g, b = b, ring = producer.inUse, text = producer.text }
        end
    end
    if data.box.z == self.floor then
        self.squares[#self.squares + 1] = { x = sx(data.box.x), y = sy(data.box.y), size = math.max(scale, 8),
            r = 1, g = 1, b = 1, ring = false, text = data.boxText }
    end
end

function ISBUPlan:floorText()
    return BU.floorName(self.floor or 0)
end

function ISBUPlan:prerender()
    ISPanel.prerender(self)
    -- The floor and arrows to the next ones, when there are.
    local text = self:floorText()
    local middle = self.width / 2
    self:drawTextCentre(text, middle, PAD, 1, 1, 1, 1, UIFont.Small)
    if #(self.levels or {}) > 1 then
        self:drawTextCentre("<", PAD * 2, PAD, 0.9, 0.9, 0.9, 1, UIFont.Small)
        self:drawTextCentre(">", self.width - PAD * 2, PAD, 0.9, 0.9, 0.9, 1, UIFont.Small)
    end
end

function ISBUPlan:render()
    ISPanel.render(self)
    local window = self.window
    local hoverRoom = self.hoverRoom or window.listHoverRoom
    local hoverKey = self.hoverKey or window.listHoverKey
    local filter = self.data and self.data.filter
    for _, cell in ipairs(self.cells) do
        local bright = cell.room == hoverRoom or cell.room == filter
        self:drawRect(cell.x, cell.y, cell.w, cell.h, bright and 0.85 or 0.6, cell.r, cell.g, cell.b)
        self:drawRectBorder(cell.x, cell.y, cell.w, cell.h, 1, bright and 1 or 0.55, bright and 1 or 0.55, bright and 1 or 0.55)
    end
    for _, label in ipairs(self.labels) do
        self:drawTextCentre(label.text, label.x, label.y, 1, 1, 1, 0.85, UIFont.Small)
    end
    for _, square in ipairs(self.squares) do
        local size = square.size
        self:drawRect(square.x, square.y, size, size, 1, square.r, square.g, square.b)
        if square.ring then self:drawRectBorder(square.x - 2, square.y - 2, size + 4, size + 4, 1, 1, 1, 1) end
    end
    for _, dot in ipairs(self.dots) do
        self:drawRect(dot.x - DOT / 2, dot.y - DOT / 2, DOT, DOT, 1, dot.r, dot.g, dot.b)
        if dot.key == hoverKey then self:drawRectBorder(dot.x - DOT, dot.y - DOT, DOT * 2, DOT * 2, 1, 1, 1, 1) end
    end
    if self.status then
        self:drawText(self.status, PAD, self.height - FONT_HGT_SMALL - PAD, 1, 1, 1, 1, UIFont.Small)
    end
end

-- What is under the mouse: a dot, a square (producer or box) or a room.
function ISBUPlan:hit(x, y)
    for _, dot in ipairs(self.dots) do
        if math.abs(x - dot.x) <= HIT and math.abs(y - dot.y) <= HIT then return "dot", dot end
    end
    for _, square in ipairs(self.squares) do
        if x >= square.x and x <= square.x + square.size and y >= square.y and y <= square.y + square.size then return "square", square end
    end
    for _, cell in ipairs(self.cells) do
        if x >= cell.x and x < cell.x + cell.w and y >= cell.y and y < cell.y + cell.h then return "room", cell end
    end
    return nil
end

function ISBUPlan:onMouseMove(dx, dy)
    local kind, thing = self:hit(self:getMouseX(), self:getMouseY())
    local key = kind == "dot" and thing.key or nil
    local room = kind == "room" and thing.room or kind == "dot" and thing.room or nil
    if key ~= self.hoverKey then self.window:outlineDevice(key) end
    self.hoverKey, self.hoverRoom = key, room
    if kind == "dot" or kind == "square" then
        self.status = thing.text
    elseif kind == "room" then
        self.status = self.window:roomStatus(thing.room)
    else
        self.status = nil
    end
end

function ISBUPlan:onMouseMoveOutside(dx, dy)
    if self.hoverKey then self.window:outlineDevice(nil) end
    self.hoverKey, self.hoverRoom, self.status = nil, nil, nil
end

function ISBUPlan:onMouseDown(x, y)
    if y < PAD + FONT_HGT_SMALL + 4 and #(self.levels or {}) > 1 then
        local index = 1
        for i, level in ipairs(self.levels) do if level == self.floor then index = i end end
        if x < PAD * 4 then index = math.max(1, index - 1) elseif x > self.width - PAD * 4 then index = math.min(#self.levels, index + 1) end
        self.floor = self.levels[index]
        self:layout()
        return true
    end
    local kind, thing = self:hit(x, y)
    if kind == "dot" then
        self.window:showDevice(thing.key)
    elseif kind == "room" then
        self.window:filterRoom(thing.room ~= (self.data and self.data.filter) and thing.room or nil)
    elseif kind == nil then
        self.window:filterRoom(nil)
    end
    return true
end

function ISBUPlan:onResize()
    if ISPanel.onResize then ISPanel.onResize(self) end
    self:layout()
end
