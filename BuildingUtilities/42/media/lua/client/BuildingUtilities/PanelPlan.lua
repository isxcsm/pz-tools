-- The floor plan beside a breaker box window: the building's rooms on one floor from above, north up, coloured by
-- what their devices do; the devices as dots, the producers as squares and the box itself. A strip on the left picks
-- the floor (or the mouse wheel), a legend at the bottom tells the colours. It shares hover and clicks with the
-- window's list: a row under the mouse marks its room or dot here and the other way round, a room clicked here shows
-- only that room there, a dot clicked here finds its row, and a right click offers what the row would. Rooms of the
-- building outside the box's zone are dim; the Zone switch at the top shows the zones instead, and a click there
-- takes a room in or out. Devices not connected are hollow; lines run from the building to the producers and the
-- devices outside it is connected to. While the window shows the range, the plan does too: an outline where devices
-- outside join (blue) and where producers do (yellow). While devices outside are chosen to connect, a click on one
-- chooses it. Ctrl and the wheel (or the wheel alone for one floor) zoom at the mouse, dragging moves the plan, Fit
-- goes back. Everything is laid out when the window refreshes or the plan is resized; a frame only draws the
-- rectangles laid out, inside the map.
require "ISUI/ISPanel"
local BU = BuildingUtilities

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local PAD = 8
local MAX_SCALE = 14
local DOT = 6
local HIT = 5
local STRIP_W = 34
local CELL_H = FONT_HGT_SMALL + 4
local LEGEND_ROW = FONT_HGT_SMALL + 2
local TOGGLE_W = 18
local ZONE_W = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_BU_Zone")) + 10
local FIT_W = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_BU_PlanFit")) + 10
local MAX_ZOOM, MAX_ZOOM_SCALE, DRAG = 8, 48, 4

ISBUPlan = ISPanel:derive("ISBUPlan")

local WHITE = Texture.getWhite()

function ISBUPlan:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.cells, o.labels, o.dots, o.squares, o.strip, o.legend, o.lines, o.edges = {}, {}, {}, {}, {}, {}, {}, {}
    o.rangeCache = {}
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

local COLOURS = {
    other = { 0.6, 0.4, 0.8 }, off = { 0.45, 0.45, 0.45 }, shed = { 1, 0.6, 0.2 }, timer = { 0.4, 0.6, 1 },
    unsupplied = { 0.6, 0.65, 0.75 }, using = { 0.4, 1, 0.4 }, idle = { 0.25, 0.6, 0.3 },
    producer = { 1, 0.85, 0.2 }, tank = { 0.3, 0.6, 1 }, box = { 1, 1, 1 }, chosen = { 0.4, 0.8, 1 },
    rangeOutside = { 0.3, 0.6, 1 }, rangeProducer = { 1, 0.85, 0.2 },
    zoneMine = { 0.2, 0.5, 0.6 }, zoneFree = { 0.25, 0.25, 0.25 }, zoneTaken = { 0.5, 0.3, 0.6 },
}

local function dotColour(device, supplied)
    local colour
    if device.state == "other" then colour = COLOURS.other
    elseif device.state ~= "on" then colour = COLOURS.off
    elseif device.held == "shed" then colour = COLOURS.shed
    elseif device.held == "timer" then colour = COLOURS.timer
    elseif not supplied then colour = COLOURS.unsupplied
    elseif (device.power or 0) > 0 or device.utility == "water" then colour = COLOURS.using
    else colour = COLOURS.idle end
    return colour[1], colour[2], colour[3]
end

-- What the legend lists for a utility, or for the zones: a colour, dot or square, and its text.
local function legendEntries(utility, zones, ranges)
    local result = {}
    local function add(name, square, hollow)
        local colour = COLOURS[name]
        result[#result + 1] = { r = colour[1], g = colour[2], b = colour[3], square = square, hollow = hollow,
            text = getText("IGUI_BU_Legend_" .. name) }
    end
    if zones then
        for _, name in ipairs({ "zoneMine", "zoneFree", "zoneTaken" }) do add(name, true) end
    elseif utility == "power" then
        for _, name in ipairs({ "using", "idle", "shed", "timer", "unsupplied", "other" }) do add(name) end
        add("off", false, true)
        add("producer", true)
    else
        for _, name in ipairs({ "using", "other" }) do add(name) end
        add("off", false, true)
        add("tank", true)
    end
    add("box", true)
    if ranges and not zones then
        if ranges.exterior then add("rangeOutside", "line") end
        if ranges.producer then add("rangeProducer", "line") end
    end
    return result
end

-- Where a range reaches around rectangles, as the edges between squares in it and out of it: { x, y, len, across }
-- in squares (across: along x). A square is in range within so many steps of a rectangle, a diagonal step counting as
-- one: the rectangles grown row by row, then column by column.
local function rangeEdges(rects, range)
    if #rects == 0 or range <= 0 then return {} end
    local minX, minY, maxX, maxY
    for _, rect in ipairs(rects) do
        minX, minY = math.min(minX or rect.x, rect.x), math.min(minY or rect.y, rect.y)
        maxX, maxY = math.max(maxX or rect.x + rect.w - 1, rect.x + rect.w - 1), math.max(maxY or rect.y + rect.h - 1, rect.y + rect.h - 1)
    end
    minX, minY, maxX, maxY = minX - range, minY - range, maxX + range, maxY + range
    local w, h = maxX - minX + 1, maxY - minY + 1
    local base, rows, cells = {}, {}, {}
    for _, rect in ipairs(rects) do
        for y = rect.y, rect.y + rect.h - 1 do
            for x = rect.x, rect.x + rect.w - 1 do base[(y - minY) * w + (x - minX)] = true end
        end
    end
    for row = 0, h - 1 do
        local last = -range - 1
        for col = 0, w - 1 do
            if base[row * w + col] then last = col end
            if col - last <= range then rows[row * w + col] = true end
        end
        last = w + range
        for col = w - 1, 0, -1 do
            if base[row * w + col] then last = col end
            if last - col <= range then rows[row * w + col] = true end
        end
    end
    for col = 0, w - 1 do
        local last = -range - 1
        for row = 0, h - 1 do
            if rows[row * w + col] then last = row end
            if row - last <= range then cells[row * w + col] = true end
        end
        last = h + range
        for row = h - 1, 0, -1 do
            if rows[row * w + col] then last = row end
            if last - row <= range then cells[row * w + col] = true end
        end
    end
    local function at(col, row)
        return col >= 0 and col < w and row >= 0 and row < h and cells[row * w + col] == true
    end
    local edges = {}
    for row = 0, h do
        local start
        for col = 0, w do
            local edge = col < w and at(col, row - 1) ~= at(col, row)
            if edge and not start then start = col
            elseif not edge and start then
                edges[#edges + 1] = { x = minX + start, y = minY + row, len = col - start, across = true }
                start = nil
            end
        end
    end
    for col = 0, w do
        local start
        for row = 0, h do
            local edge = row < h and at(col - 1, row) ~= at(col, row)
            if edge and not start then start = row
            elseif not edge and start then
                edges[#edges + 1] = { x = minX + col, y = minY + start, len = row - start, across = false }
                start = nil
            end
        end
    end
    return edges
end

-- The point of the rectangles nearest a square's middle, in squares.
local function nearestPoint(rects, x, y)
    local best, bestX, bestY
    for _, rect in ipairs(rects) do
        local px = math.max(rect.x, math.min(x, rect.x + rect.w))
        local py = math.max(rect.y, math.min(y, rect.y + rect.h))
        local d = (px - x) * (px - x) + (py - y) * (py - y)
        if not best or d < best then best, bestX, bestY = d, px, py end
    end
    return bestX, bestY
end

-- data: { utility, supplied, rooms = { { id, title, level, rects } }, devices = { { key, x, y, z, roomId, inside,
-- state, held, power, name, status } }, producers = { { x, y, z, inUse } }, box = { x, y, z }, filter = room id,
-- zone = room id to { state = "mine", "free" or "taken", owner = a name }, zoneEditable, zoneEdit, zoneNote,
-- ranges = { exterior = steps, producer = steps or nil } while the range is shown, rangeKey (the building and tier the
-- ranges are of), choosing (devices outside are being chosen) }. A device may be chosen and choosable.
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
    -- What each floor's connected devices do: how many, and what they draw.
    self.floorOn, self.floorLoad = {}, {}
    for _, device in ipairs(data.devices) do
        if device.state == "on" then
            self.floorOn[device.z] = (self.floorOn[device.z] or 0) + 1
            if not device.held then self.floorLoad[device.z] = (self.floorLoad[device.z] or 0) + (device.power or 0) end
        end
    end
    self:layout()
    -- What the status line says of the thing under the mouse may have changed with the data.
    if self.status then self:onMouseMove(0, 0) end
end

function ISBUPlan:legendShown() return BU.PanelWindow.legendShown ~= false end

-- The range outlines of a floor, worked out once for a building, tier and floor.
function ISBUPlan:ranges(floor)
    local data = self.data
    if not data.ranges then return nil end
    if self.rangeKey ~= data.rangeKey then self.rangeCache, self.rangeKey = {}, data.rangeKey end
    local cached = self.rangeCache[floor]
    if cached then return cached end
    local floorRects, allRects = {}, {}
    for _, room in ipairs(data.rooms) do
        for _, rect in ipairs(room.rects) do
            allRects[#allRects + 1] = rect
            if room.level == floor then floorRects[#floorRects + 1] = rect end
        end
    end
    -- Devices outside join by the floor's own rooms (as the API finds them); producers by the whole outline.
    cached = { exterior = rangeEdges(floorRects, data.ranges.exterior or 0),
        producer = data.ranges.producer and rangeEdges(allRects, data.ranges.producer) or {} }
    self.rangeCache[floor] = cached
    return cached
end

function ISBUPlan:layout()
    local data = self.data
    self.cells, self.labels, self.dots, self.squares, self.strip, self.legend, self.lines, self.edges = {}, {}, {}, {}, {}, {}, {}, {}
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
    -- With the range shown, the plan takes in where devices outside and producers join.
    local ranges = self:ranges(self.floor)
    for _, edges in ipairs(ranges and { ranges.exterior, ranges.producer } or {}) do
        for _, edge in ipairs(edges) do cover(edge.x, edge.y, edge.across and edge.len or 0, edge.across and 0 or edge.len) end
    end
    local left = PAD + (#self.levels > 1 and STRIP_W or 0)
    local top = FONT_HGT_SMALL + PAD * 2
    -- The legend, in two columns at the bottom, above the status line.
    local legendH = 0
    if self:legendShown() then
        local entries = legendEntries(data.utility, data.zoneEdit, data.ranges)
        local rows = math.ceil(#entries / 2)
        legendH = rows * LEGEND_ROW + PAD
        local columnW = (self.width - left - PAD) / 2
        local legendY = self.height - FONT_HGT_SMALL - PAD * 2 - legendH + PAD
        for index, entry in ipairs(entries) do
            local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
            entry.x, entry.y = left + column * columnW, legendY + row * LEGEND_ROW
            self.legend[#self.legend + 1] = entry
        end
    end
    local availW, availH = self.width - left - PAD, self.height - top - FONT_HGT_SMALL - PAD * 2 - legendH
    -- The whole fits at zoom 1; zoomed, the plan centres on the place the player moved it to.
    local fit = math.max(1, math.min(availW / (maxX - minX), availH / (maxY - minY), MAX_SCALE))
    local zoom = self.zoom or 1
    if zoom <= 1 then self.panX, self.panY = 0, 0 end
    local scale = math.min(fit * zoom, math.max(fit, MAX_ZOOM_SCALE))
    local baseX, baseY = (minX + maxX) / 2, (minY + maxY) / 2
    local centreX, centreY = baseX + (self.panX or 0), baseY + (self.panY or 0)
    local ox = left + availW / 2 - (centreX - minX) * scale
    local oy = top + availH / 2 - (centreY - minY) * scale
    self.map = { left = left, top = top, w = availW, h = availH, scale = scale, fit = fit, centreX = centreX, centreY = centreY,
        baseX = baseX, baseY = baseY }
    local function sx(x) return math.floor(ox + (x - minX) * scale) end
    local function sy(y) return math.floor(oy + (y - minY) * scale) end
    self.scale = scale
    -- The range outlines, cut to the map.
    local mapLeft, mapTop, mapRight, mapBottom = left, top, left + availW, top + availH
    local function addEdges(edges, colour)
        for _, edge in ipairs(edges) do
            local x1, y1 = sx(edge.x), sy(edge.y)
            local x2 = edge.across and sx(edge.x + edge.len) or x1 + 1
            local y2 = edge.across and y1 + 1 or sy(edge.y + edge.len)
            x1, y1 = math.max(x1, mapLeft), math.max(y1, mapTop)
            x2, y2 = math.min(x2, mapRight), math.min(y2, mapBottom)
            if x2 > x1 and y2 > y1 then
                self.edges[#self.edges + 1] = { x = x1, y = y1, w = x2 - x1, h = y2 - y1, r = colour[1], g = colour[2], b = colour[3] }
            end
        end
    end
    if ranges then
        addEdges(ranges.producer, COLOURS.rangeProducer)
        addEdges(ranges.exterior, COLOURS.rangeOutside)
    end
    -- The lines: from the building's outline (this floor's, else any) to each producer and device outside it takes.
    local floorRects, allRects = {}, {}
    for _, room in ipairs(data.rooms) do
        for _, rect in ipairs(room.rects) do
            allRects[#allRects + 1] = rect
            if room.level == self.floor then floorRects[#floorRects + 1] = rect end
        end
    end
    local function addLine(x, y, colour)
        local px, py = nearestPoint(#floorRects > 0 and floorRects or allRects, x + 0.5, y + 0.5)
        if not px then return end
        self.lines[#self.lines + 1] = { x1 = ox + (x + 0.5 - minX) * scale, y1 = oy + (y + 0.5 - minY) * scale,
            x2 = ox + (px - minX) * scale, y2 = oy + (py - minY) * scale, r = colour[1], g = colour[2], b = colour[3] }
    end
    for _, device in ipairs(data.devices) do
        if device.z == self.floor and not device.inside and device.state == "on" then addLine(device.x, device.y, COLOURS.idle) end
    end
    for _, producer in ipairs(data.producers) do
        if producer.z == self.floor then
            addLine(producer.x, producer.y, data.utility == "water" and COLOURS.tank or COLOURS.producer)
        end
    end
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
            -- In the zone: what its devices do; out of it dim, or the zones' colours while they are edited.
            local zone = data.zone and data.zone[room.id]
            local state = zone and zone.state or "mine"
            local r, g, b
            if data.zoneEdit then
                local colour = state == "mine" and COLOURS.zoneMine or state == "taken" and COLOURS.zoneTaken or COLOURS.zoneFree
                r, g, b = colour[1], colour[2], colour[3]
            elseif state == "mine" then
                r, g, b = roomColour(roomState[room.id] or { on = 0, held = 0 }, data.supplied)
            else
                local colour = state == "taken" and COLOURS.zoneTaken or COLOURS.zoneFree
                r, g, b = colour[1] * 0.5, colour[2] * 0.5, colour[3] * 0.5
            end
            local dim = state ~= "mine" and not data.zoneEdit
            local largest
            for _, rect in ipairs(room.rects) do
                local cell = { x = sx(rect.x), y = sy(rect.y), room = room.id, r = r, g = g, b = b, dim = dim }
                cell.w, cell.h = sx(rect.x + rect.w) - cell.x, sy(rect.y + rect.h) - cell.y
                self.cells[#self.cells + 1] = cell
                if not largest or cell.w * cell.h > largest.w * largest.h then largest = cell end
            end
            if largest and getTextManager():MeasureStringX(UIFont.Small, room.title) < largest.w - 4
                    and largest.h > FONT_HGT_SMALL + 2 then
                self.labels[#self.labels + 1] = { text = room.title, x = largest.x + largest.w / 2,
                    y = largest.y + (largest.h - FONT_HGT_SMALL) / 2, dim = dim }
            end
        end
    end
    for _, device in ipairs(data.devices) do
        if device.z == self.floor then
            local r, g, b = dotColour(device, data.supplied)
            self.dots[#self.dots + 1] = { key = device.key, room = device.inside and device.roomId or nil,
                x = math.floor(sx(device.x) + scale / 2), y = math.floor(sy(device.y) + scale / 2), r = r, g = g, b = b,
                text = device.name .. "  " .. (device.status or ""), hollow = device.state == "off",
                chosen = device.chosen, choosable = device.choosable, fresh = device.fresh }
        end
    end
    for _, producer in ipairs(data.producers) do
        if producer.z == self.floor then
            local colour = data.utility == "water" and COLOURS.tank or COLOURS.producer
            self.squares[#self.squares + 1] = { x = sx(producer.x), y = sy(producer.y), size = math.max(scale, 8),
                r = colour[1], g = colour[2], b = colour[3], ring = producer.inUse, text = producer.text }
        end
    end
    if data.box.z == self.floor then
        self.squares[#self.squares + 1] = { x = sx(data.box.x), y = sy(data.box.y), size = math.max(scale, 8),
            r = 1, g = 1, b = 1, ring = false, text = data.boxText }
    end
    self:layoutStrip()
end

-- The floor strip: the floors top down, as many as fit, the one shown among them.
function ISBUPlan:layoutStrip()
    self.strip = {}
    if #self.levels < 2 then return end
    local top = FONT_HGT_SMALL + PAD * 2
    local fit = math.max(1, math.floor((self.height - top - PAD) / CELL_H))
    local downward = {}
    for index = #self.levels, 1, -1 do downward[#downward + 1] = self.levels[index] end
    local current = 1
    for index, level in ipairs(downward) do if level == self.floor then current = index end end
    local first = math.max(1, math.min(current - math.floor(fit / 2), #downward - fit + 1))
    for index = first, math.min(#downward, first + fit - 1) do
        local level = downward[index]
        self.strip[#self.strip + 1] = { level = level, x = PAD, y = top + (index - first) * CELL_H, w = STRIP_W - 6, h = CELL_H - 2,
            text = BU.floorShort(level), on = (self.floorOn[level] or 0) > 0 }
    end
end

function ISBUPlan:prerender()
    ISPanel.prerender(self)
    -- The floor shown, with what its devices draw; the legend's switch on the right.
    local text = BU.floorName(self.floor or 0)
    local data = self.data
    if data and data.utility == "power" then
        text = getText("IGUI_BU_FloorLoad", text, string.format("%.2f", self.floorLoad and self.floorLoad[self.floor] or 0))
    end
    self:drawTextCentre(text, self.width / 2, PAD, 1, 1, 1, 1, UIFont.Small)
    local shown = self:legendShown()
    self:drawRectBorder(self.width - PAD - TOGGLE_W, PAD - 1, TOGGLE_W, FONT_HGT_SMALL + 2, 1, 0.6, 0.6, 0.6)
    self:drawTextCentre("?", self.width - PAD - TOGGLE_W / 2, PAD, shown and 1 or 0.6, shown and 0.9 or 0.6, shown and 0.5 or 0.6, 1, UIFont.Small)
    if data and data.zoneEditable then
        local x, editing = self:zoneToggleX(), data.zoneEdit
        if editing then self:drawRect(x, PAD - 1, ZONE_W, FONT_HGT_SMALL + 2, 0.8, 0.2, 0.5, 0.6) end
        self:drawRectBorder(x, PAD - 1, ZONE_W, FONT_HGT_SMALL + 2, 1, 0.6, 0.6, 0.6)
        self:drawTextCentre(getText("IGUI_BU_Zone"), x + ZONE_W / 2, PAD, 1, 1, 1, editing and 1 or 0.75, UIFont.Small)
    end
    if (self.zoom or 1) > 1 then
        local x = self:fitToggleX()
        self:drawRectBorder(x, PAD - 1, FIT_W, FONT_HGT_SMALL + 2, 1, 0.6, 0.6, 0.6)
        self:drawTextCentre(getText("IGUI_BU_PlanFit"), x + FIT_W / 2, PAD, 1, 1, 1, 0.9, UIFont.Small)
    end
end

function ISBUPlan:zoneToggleX() return self.width - PAD - TOGGLE_W - 4 - ZONE_W end

function ISBUPlan:fitToggleX()
    local right = self.data and self.data.zoneEditable and self:zoneToggleX() or self.width - PAD - TOGGLE_W
    return right - 4 - FIT_W
end

-- Which switch at the top is under the mouse: "legend", "zone", "fit" or nil.
function ISBUPlan:toggleAt(x, y)
    if y >= PAD + FONT_HGT_SMALL + 2 then return nil end
    if x >= self.width - PAD - TOGGLE_W then return "legend" end
    local zoneX = self:zoneToggleX()
    if self.data and self.data.zoneEditable and x >= zoneX and x < zoneX + ZONE_W then return "zone" end
    local fitX = self:fitToggleX()
    if (self.zoom or 1) > 1 and x >= fitX and x < fitX + FIT_W then return "fit" end
    return nil
end

-- Whether a point is on the map, where rooms, dots and lines are drawn.
function ISBUPlan:inMap(x, y)
    local map = self.map
    return map ~= nil and x >= map.left and x < map.left + map.w and y >= map.top and y < map.top + map.h
end

-- Zooms by a factor, keeping the square under the point where it is.
function ISBUPlan:zoomAt(x, y, factor)
    local map = self.map
    if not map then return end
    local zoom = math.max(1, math.min(MAX_ZOOM, (self.zoom or 1) * factor))
    local midX, midY = map.left + map.w / 2, map.top + map.h / 2
    local worldX = map.centreX + (x - midX) / map.scale
    local worldY = map.centreY + (y - midY) / map.scale
    local scale = math.min(map.fit * zoom, math.max(map.fit, MAX_ZOOM_SCALE))
    self.zoom = zoom
    self.panX = worldX - (x - midX) / scale - map.baseX
    self.panY = worldY - (y - midY) / scale - map.baseY
    self:layout()
end

function ISBUPlan:render()
    ISPanel.render(self)
    local window = self.window
    local hoverRoom = self.hoverRoom or window.listHoverRoom
    local hoverKey = self.hoverKey or window.listHoverKey
    local filter = self.data and self.data.filter
    local map = self.map
    if map then self:setStencilRect(map.left, map.top, map.w, map.h) end
    for _, cell in ipairs(self.cells) do
        local bright = cell.room == hoverRoom or cell.room == filter
        local edge = bright and 1 or cell.dim and 0.3 or 0.55
        self:drawRect(cell.x, cell.y, cell.w, cell.h, bright and 0.85 or cell.dim and 0.4 or 0.6, cell.r, cell.g, cell.b)
        self:drawRectBorder(cell.x, cell.y, cell.w, cell.h, 1, edge, edge, edge)
    end
    for _, label in ipairs(self.labels) do
        self:drawTextCentre(label.text, label.x, label.y, 1, 1, 1, label.dim and 0.4 or 0.85, UIFont.Small)
    end
    for _, edge in ipairs(self.edges) do self:drawRect(edge.x, edge.y, edge.w, edge.h, 0.7, edge.r, edge.g, edge.b) end
    for _, line in ipairs(self.lines) do
        self:drawLine(WHITE, line.x1, line.y1, line.x2, line.y2, 1, 0.8, line.r, line.g, line.b)
    end
    for _, square in ipairs(self.squares) do
        local size = square.size
        self:drawRect(square.x, square.y, size, size, 1, square.r, square.g, square.b)
        if square.ring then self:drawRectBorder(square.x - 2, square.y - 2, size + 4, size + 4, 1, 1, 1, 1) end
    end
    local choosing = self.data and self.data.choosing
    for _, dot in ipairs(self.dots) do
        if dot.hollow then
            self:drawRect(dot.x - DOT / 2, dot.y - DOT / 2, DOT, DOT, 0.6, 0, 0, 0)
            self:drawRectBorder(dot.x - DOT / 2, dot.y - DOT / 2, DOT, DOT, 1, dot.r, dot.g, dot.b)
        else
            self:drawRect(dot.x - DOT / 2, dot.y - DOT / 2, DOT, DOT, 1, dot.r, dot.g, dot.b)
        end
        if dot.chosen then
            local c = COLOURS.chosen
            self:drawRectBorder(dot.x - DOT + 1, dot.y - DOT + 1, DOT * 2 - 2, DOT * 2 - 2, 1, c[1], c[2], c[3])
            self:drawRectBorder(dot.x - DOT, dot.y - DOT, DOT * 2, DOT * 2, 1, c[1], c[2], c[3])
        elseif choosing and dot.choosable then
            local c = COLOURS.chosen
            self:drawRectBorder(dot.x - DOT, dot.y - DOT, DOT * 2, DOT * 2, 0.5, c[1], c[2], c[3])
        end
        if dot.fresh then self:drawRect(dot.x + DOT / 2, dot.y - DOT / 2 - 3, 3, 3, 1, 0.3, 0.9, 1) end
        if dot.key == hoverKey then self:drawRectBorder(dot.x - DOT - 1, dot.y - DOT - 1, DOT * 2 + 2, DOT * 2 + 2, 1, 1, 1, 1) end
    end
    if map then self:clearStencilRect() end
    for _, cell in ipairs(self.strip) do
        local current = cell.level == self.floor
        self:drawRect(cell.x, cell.y, cell.w, cell.h, current and 0.8 or 0.4, current and 0.35 or 0.15, current and 0.35 or 0.15, current and 0.35 or 0.15)
        self:drawRectBorder(cell.x, cell.y, cell.w, cell.h, 1, 0.5, 0.5, 0.5)
        if cell.on then self:drawRect(cell.x + 1, cell.y + 1, 3, cell.h - 2, 1, 0.4, 0.9, 0.4) end
        self:drawTextCentre(cell.text, cell.x + cell.w / 2, cell.y + 1, 1, 1, 1, current and 1 or 0.75, UIFont.Small)
    end
    for _, entry in ipairs(self.legend) do
        local middle = entry.y + LEGEND_ROW / 2
        if entry.square == "line" then
            self:drawRect(entry.x, middle, 10, 1, 1, entry.r, entry.g, entry.b)
        elseif entry.square then
            self:drawRect(entry.x, middle - 4, 8, 8, 1, entry.r, entry.g, entry.b)
        elseif entry.hollow then
            self:drawRectBorder(entry.x + 1, middle - DOT / 2, DOT, DOT, 1, entry.r, entry.g, entry.b)
        else
            self:drawRect(entry.x + 1, middle - DOT / 2, DOT, DOT, 1, entry.r, entry.g, entry.b)
        end
        self:drawText(entry.text, entry.x + 14, entry.y + 1, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end
    local status = self.status or (self.data and self.data.zoneEdit and getText("IGUI_BU_ZoneHint"))
    if status then
        self:drawText(status, PAD, self.height - FONT_HGT_SMALL - PAD, 1, 1, 1, 1, UIFont.Small)
    end
end

-- What is under the mouse: a floor of the strip, a dot, a square (producer or box) or a room.
function ISBUPlan:hit(x, y)
    for _, cell in ipairs(self.strip) do
        if x >= cell.x and x <= cell.x + cell.w and y >= cell.y and y <= cell.y + cell.h then return "floor", cell end
    end
    if not self:inMap(x, y) then return nil end
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

-- The thing under the mouse, for the plan and for the list: its dot and room.
function ISBUPlan:setHover(key, room)
    if key ~= self.hoverKey then self.window:outlineDevice(key) end
    self.hoverKey, self.hoverRoom = key, room
    self.window.planHoverKey, self.window.planHoverRoom = key, room
end

function ISBUPlan:onMouseMove(dx, dy)
    local kind, thing = self:hit(self:getMouseX(), self:getMouseY())
    self:setHover(kind == "dot" and thing.key or nil, (kind == "room" or kind == "dot") and thing.room or nil)
    if kind == "dot" or kind == "square" then
        self.status = thing.text
    elseif kind == "room" then
        self.status = self.window:roomStatus(thing.room)
        local zone = self.data and self.data.zone and self.data.zone[thing.room]
        if zone and zone.state == "taken" then
            self.status = self.status .. "  (" .. getText("IGUI_BU_ZoneTaken", zone.owner or "") .. ")"
        elseif zone and zone.state == "free" then
            self.status = self.status .. "  (" .. getText("IGUI_BU_Legend_zoneFree") .. ")"
        end
    elseif kind == "floor" then
        self.status = BU.floorName(thing.level)
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "zone" then
        self.status = self.data.zoneNote
    elseif self:inMap(self:getMouseX(), self:getMouseY()) then
        self.status = getText(#(self.levels or {}) > 1 and "IGUI_BU_PlanHint" or "IGUI_BU_PlanHintOne")
    else
        self.status = nil
    end
    self:drag(dx, dy)
end

function ISBUPlan:onMouseMoveOutside(dx, dy)
    if self.hoverKey or self.hoverRoom then self:setHover(nil, nil) end
    self.status = nil
    self:drag(dx, dy)
end

-- A press on the map that moves far enough moves the plan instead of clicking.
function ISBUPlan:drag(dx, dy)
    if not self.pressed then return end
    self.moved = (self.moved or 0) + math.abs(dx) + math.abs(dy)
    if self.moved < DRAG or (self.zoom or 1) <= 1 or not self.map then return end
    self.dragged = true
    self.panX = (self.panX or 0) - dx / self.map.scale
    self.panY = (self.panY or 0) - dy / self.map.scale
    self:layout()
end

function ISBUPlan:showFloor(level)
    if level == nil or level == self.floor then return end
    self.floor = level
    self:layout()
end

function ISBUPlan:onMouseWheel(delta)
    -- Ctrl (or a building of one floor): zoom; up the wheel, closer.
    if isCtrlKeyDown() or #(self.levels or {}) < 2 then
        self:zoomAt(self:getMouseX(), self:getMouseY(), delta < 0 and 1.25 or 0.8)
        return true
    end
    local index = 1
    for i, level in ipairs(self.levels) do if level == self.floor then index = i end end
    -- Up the wheel, up the building.
    index = math.max(1, math.min(#self.levels, index - delta))
    self:showFloor(self.levels[index])
    return true
end

function ISBUPlan:onMouseDown(x, y)
    local toggle = self:toggleAt(x, y)
    if toggle == "legend" then
        BU.PanelWindow.legendShown = not self:legendShown()
        self:layout()
        return true
    elseif toggle == "zone" then
        self.window:setZoneEditing(not self.data.zoneEdit)
        return true
    elseif toggle == "fit" then
        self.zoom = 1
        self:layout()
        return true
    end
    -- On the map, a click is known when the button comes up without the plan moved.
    if self:inMap(x, y) then
        self.pressed, self.moved, self.dragged = true, 0, false
        return true
    end
    self:click(x, y)
    return true
end

function ISBUPlan:onMouseUp(x, y)
    local wasPressed, dragged = self.pressed, self.dragged
    self.pressed, self.dragged = false, false
    if wasPressed and not dragged then self:click(x, y) end
    return true
end

function ISBUPlan:onMouseUpOutside(x, y) self.pressed, self.dragged = false, false end

function ISBUPlan:click(x, y)
    local kind, thing = self:hit(x, y)
    if self.data and self.data.zoneEdit and kind ~= "floor" then
        -- Editing the zone: a room, or the room of a dot, goes in or out.
        if thing and thing.room then self.window:toggleZoneRoom(thing.room) end
        return true
    end
    if kind == "floor" then
        self:showFloor(thing.level)
    elseif kind == "dot" and self.data.choosing and thing.choosable then
        self.window:toggleChosen(thing.key)
    elseif kind == "dot" then
        self.window:showDevice(thing.key)
    elseif kind == "room" then
        self.window:filterRoom(thing.room ~= (self.data and self.data.filter) and thing.room or nil)
    elseif kind == nil then
        self.window:filterRoom(nil)
    end
    return true
end

-- A right click: what the list's row would offer, for a dot or a room.
function ISBUPlan:onRightMouseDown(x, y)
    local kind, thing = self:hit(x, y)
    if self.data and self.data.zoneEdit then
        self.window:zoneMenu(self.floor)
    elseif kind == "dot" then
        self.window:deviceMenu(thing.key)
    elseif kind == "room" then
        self.window:roomMenu(thing.room)
    end
    return true
end

function ISBUPlan:onResize()
    if ISPanel.onResize then ISPanel.onResize(self) end
    self:layout()
end
