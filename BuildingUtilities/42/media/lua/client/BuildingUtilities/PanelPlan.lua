-- The floor plan beside a breaker box window: the building's rooms on one floor from above, north up, coloured by
-- what their devices do; the devices as dots, the producers as squares and the box itself. A strip on the left picks
-- the floor, a legend at the bottom tells the colours. It shares hover and clicks with the
-- window's list: a row under the mouse marks its room or dot here and the other way round, a room clicked here shows
-- only that room there, a dot clicked here finds its row, and a right click offers what the row would. Rooms of the
-- building outside the box's zone are dim; the Zone switch at the top shows the zones instead, and a click there
-- takes a room in or out. Devices not connected are hollow; lines run from the building to the producers and the
-- devices outside it is connected to; dots run along them the way power or water goes now, from the producers in
-- use (or a bank charged from the box) through the building to the box, and out to devices outside. While the
-- window shows the range, the plan does too: an outline where devices outside join (blue) and where producers do
-- (yellow), and on the power plan how far each generator is heard (red, dim while it is off). While devices outside
-- are chosen to connect, a click on one
-- chooses it. The wheel zooms at the mouse, dragging moves the plan, Fit goes back. Over the floor strip the wheel
-- scrolls the floors (arrows page them); the floor's name at the top lists every floor to jump to. A room is drawn as
-- one shape, its outline only where it meets another room or the outside. The top bar also shows the range (as the
-- window's range button would). Everything is laid out when the window refreshes or the plan is resized; a frame only
-- draws the rectangles laid out, inside the map.
require "ISUI/ISPanel"
require "BuildingUtilities/Geometry"
local BU = BuildingUtilities
local Geometry = BU.Geometry

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
local MIN_ZOOM, MAX_ZOOM, MAX_ZOOM_SCALE, DRAG = 0.5, 8, 48, 4
local RANGE_W = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_BU_PlanRange")) + 10
-- Wheel notches over the floor strip scroll it by so many floors.
local STRIP_SCROLL = 3
-- Flow dots: so far apart, so many pixels a second, so big.
local FLOW_GAP, FLOW_SPEED, FLOW_DOT = 14, 24, 4

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
    rangeOutside = { 0.3, 0.6, 1 }, rangeProducer = { 1, 0.85, 0.2 }, rangeNoise = { 1, 0.35, 0.3 },
    rangeNoiseIdle = { 0.6, 0.3, 0.3 },
    zoneMine = { 0.2, 0.5, 0.6 }, zoneFree = { 0.25, 0.25, 0.25 }, zoneTaken = { 0.5, 0.3, 0.6 },
}

local function dotColour(device, supplied)
    local colour
    if device.state == "other" then colour = COLOURS.other
    elseif device.state ~= "on" then colour = COLOURS.off
    elseif device.held == "shed" or device.held == "saving" then colour = COLOURS.shed
    elseif device.held == "timer" or device.held == "blackout" then colour = COLOURS.timer
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
        if ranges.noise and #ranges.noise > 0 then add("rangeNoise", "line") end
    end
    return result
end

-- An area's edges (Geometry.reach, Geometry.disc), between squares in it and out of it: { x, y, len, across } in
-- squares (across: along x).
local function areaEdges(area)
    if not area then return {} end
    local minX, minY, w, h, cells = area.minX, area.minY, area.w, area.h, area.cells
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

-- Where a range reaches around rectangles, as its area's edges.
local function rangeEdges(rects, range)
    return areaEdges(range > 0 and Geometry.reach(rects, range) or nil)
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
-- state, held, power, name, status, flow } }, producers = { { x, y, z, inUse, text, unit = its kind for a unit, colour
-- or nil, flow } } (flow: 1 to the box, -1 from it, nil none), box = { x, y, z }, filter = room id, zone = room id to
-- { state = "mine", "free" or "taken", owner = a name }, zoneEditable, zoneEdit, zoneNote, ranges = { exterior =
-- steps, producer = steps or nil, noise = for power { { x, y, z, radius, running } } } while the range is shown,
-- rangeKey (the building, tier and generators' noise the ranges are of),
-- choosing (devices outside are being chosen) }. A device may be chosen and choosable.
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
    local floorRects, allRects = Geometry.roomRects(data.rooms, floor)
    -- Devices outside join by the floor's own rooms (as the API finds them); producers by the whole outline.
    cached = { exterior = rangeEdges(floorRects, data.ranges.exterior or 0),
        producer = data.ranges.producer and rangeEdges(allRects, data.ranges.producer) or {}, noise = {} }
    -- How far the generators on this floor are heard.
    for _, noise in ipairs(data.ranges.noise or {}) do
        if noise.z == floor then
            cached.noise[#cached.noise + 1] = { edges = areaEdges(Geometry.disc(noise.x, noise.y, noise.radius)),
                running = noise.running }
        end
    end
    self.rangeCache[floor] = cached
    return cached
end

-- A room's outline in squares, as the edges where its squares meet a square of no room or another room: { x, y, len,
-- across } (across: along x). The rectangles a room is made of meet without a line. Worked out once for the rooms the
-- data has.
function ISBUPlan:roomOutline(room)
    if self.outlineRooms ~= self.data.rooms then self.outlineRooms, self.outlines = self.data.rooms, {} end
    local cached = self.outlines[room.id]
    if cached then return cached end
    local inside = {}
    local function key(x, y) return x * 65536 + y end
    for _, rect in ipairs(room.rects) do
        for y = rect.y, rect.y + rect.h - 1 do
            for x = rect.x, rect.x + rect.w - 1 do inside[key(x, y)] = true end
        end
    end
    -- The edges square by square, by the line they lie on, then joined where they run on.
    local rows, cols = {}, {}
    local function mark(lines, line, at)
        lines[line] = lines[line] or {}
        lines[line][#lines[line] + 1] = at
    end
    for _, rect in ipairs(room.rects) do
        for y = rect.y, rect.y + rect.h - 1 do
            for x = rect.x, rect.x + rect.w - 1 do
                if not inside[key(x, y - 1)] then mark(rows, y, x) end
                if not inside[key(x, y + 1)] then mark(rows, y + 1, x) end
                if not inside[key(x - 1, y)] then mark(cols, x, y) end
                if not inside[key(x + 1, y)] then mark(cols, x + 1, y) end
            end
        end
    end
    local edges = {}
    local function join(lines, across)
        for line, list in pairs(lines) do
            table.sort(list)
            local start, last = list[1], list[1]
            for index = 2, #list + 1 do
                local at = list[index]
                if at ~= last + 1 then
                    if across then edges[#edges + 1] = { x = start, y = line, len = last - start + 1, across = true }
                    else edges[#edges + 1] = { x = line, y = start, len = last - start + 1, across = false } end
                    start = at
                end
                last = at
            end
        end
    end
    join(rows, true)
    join(cols, false)
    self.outlines[room.id] = edges
    return edges
end

function ISBUPlan:layout()
    local data = self.data
    self.cells, self.labels, self.dots, self.squares, self.strip, self.legend, self.lines, self.edges = {}, {}, {}, {}, {}, {}, {}, {}
    self.flows, self.walls = {}, {}
    self:layoutTop()
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
    -- With the range shown, the plan takes in where devices outside and producers join, and where generators are heard.
    local ranges = self:ranges(self.floor)
    local rangeSets = ranges and { ranges.exterior, ranges.producer } or {}
    for _, noise in ipairs(ranges and ranges.noise or {}) do rangeSets[#rangeSets + 1] = noise.edges end
    for _, edges in ipairs(rangeSets) do
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
        for _, noise in ipairs(ranges.noise) do
            addEdges(noise.edges, noise.running and COLOURS.rangeNoise or COLOURS.rangeNoiseIdle)
        end
        addEdges(ranges.producer, COLOURS.rangeProducer)
        addEdges(ranges.exterior, COLOURS.rangeOutside)
    end
    -- The lines: from the building's outline (this floor's, else any) to each producer and device outside it takes.
    local floorRects, allRects = Geometry.roomRects(data.rooms, self.floor)
    -- A line, and with a flow the dots' path: from the thing to the building, on to the box when it is on this floor;
    -- they run along it to the box (flow 1) or from it (-1).
    local function addLine(x, y, colour, flow)
        local px, py = nearestPoint(#floorRects > 0 and floorRects or allRects, x + 0.5, y + 0.5)
        if not px then return end
        local line = { x1 = ox + (x + 0.5 - minX) * scale, y1 = oy + (y + 0.5 - minY) * scale,
            x2 = ox + (px - minX) * scale, y2 = oy + (py - minY) * scale, r = colour[1], g = colour[2], b = colour[3] }
        self.lines[#self.lines + 1] = line
        if not flow then return end
        local points = { { line.x1, line.y1 }, { line.x2, line.y2 } }
        if data.box.z == self.floor then
            points[3] = { ox + (data.box.x + 0.5 - minX) * scale, oy + (data.box.y + 0.5 - minY) * scale }
        end
        local length, lengths = 0, {}
        for index = 2, #points do
            local a, b = points[index - 1], points[index]
            local dx, dy = b[1] - a[1], b[2] - a[2]
            lengths[index] = math.sqrt(dx * dx + dy * dy)
            length = length + lengths[index]
        end
        if length < 1 then return end
        -- Brighter than the line, so the dots show on it.
        self.flows[#self.flows + 1] = { points = points, lengths = lengths, length = length, toBox = flow > 0,
            r = math.min(1, colour[1] + 0.3), g = math.min(1, colour[2] + 0.3), b = math.min(1, colour[3] + 0.3) }
    end
    for _, device in ipairs(data.devices) do
        if device.z == self.floor and not device.inside and device.state == "on" then
            addLine(device.x, device.y, COLOURS.idle, device.flow)
        end
    end
    -- A producer's colour: its own (a tank's group's), a unit's (its kind's, Units.define), a tank's or a generator's.
    local function producerColour(producer)
        if producer.colour then return producer.colour end
        if producer.unit then return BU.Units.definition(producer.unit).colour end
        return data.utility == "water" and COLOURS.tank or COLOURS.producer
    end
    for _, producer in ipairs(data.producers) do
        if producer.z == self.floor then addLine(producer.x, producer.y, producerColour(producer), producer.flow) end
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
            for _, edge in ipairs(self:roomOutline(room)) do
                local x1, y1 = sx(edge.x), sy(edge.y)
                self.walls[#self.walls + 1] = { room = room.id, dim = dim, x = x1, y = y1,
                    w = edge.across and sx(edge.x + edge.len) - x1 or 1, h = edge.across and 1 or sy(edge.y + edge.len) - y1 }
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
            local colour = producerColour(producer)
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

-- The floor strip: the floors top down, as many as fit, around the one shown or where the player scrolled it. With more
-- than fit, an arrow at each end pages them.
function ISBUPlan:layoutStrip()
    self.strip = {}
    if #self.levels < 2 then return end
    local top = FONT_HGT_SMALL + PAD * 2
    local rows = math.max(3, math.floor((self.height - top - PAD) / CELL_H))
    local downward = {}
    for index = #self.levels, 1, -1 do downward[#downward + 1] = self.levels[index] end
    local overflow = #downward > rows
    local fit = overflow and rows - 2 or rows
    local current = 1
    for index, level in ipairs(downward) do if level == self.floor then current = index end end
    local first = self.stripFirst or current - math.floor(fit / 2)
    first = math.max(1, math.min(first, #downward - fit + 1))
    self.stripFirst = first
    local y = top
    local function arrow(direction, enabled)
        self.strip[#self.strip + 1] = { arrow = direction, page = fit, enabled = enabled, x = PAD, y = y, w = STRIP_W - 6,
            h = CELL_H - 2, text = direction < 0 and "^" or "v" }
        y = y + CELL_H
    end
    if overflow then arrow(-1, first > 1) end
    for index = first, math.min(#downward, first + fit - 1) do
        local level = downward[index]
        self.strip[#self.strip + 1] = { level = level, x = PAD, y = y, w = STRIP_W - 6, h = CELL_H - 2,
            text = BU.floorShort(level), on = (self.floorOn[level] or 0) > 0, box = self.data and self.data.box.z == level }
        y = y + CELL_H
    end
    if overflow then arrow(1, first + fit - 1 < #downward) end
end

-- The top bar, laid out with the rest: the floor shown with what its devices draw (with several floors, a click on
-- it lists them) and how far its name reaches either side of the middle; the switches, right to left: the legend,
-- the zone (where zones can be edited), the range, Fit (zoomed or moved), each { name, x, w, text }.
function ISBUPlan:layoutTop()
    local data = self.data
    local name = BU.floorName(self.floor or 0)
    local text = name
    if data and data.utility == "power" then
        text = getText("IGUI_BU_FloorLoad", text, string.format("%.2f", self.floorLoad and self.floorLoad[self.floor] or 0))
    end
    if #(self.levels or {}) > 1 then text = text .. "  v" end
    self.floorTitle, self.titleHalf = text, getTextManager():MeasureStringX(UIFont.Small, name) / 2 + 60
    local toggles, right = {}, self.width - PAD
    local function add(toggleName, w, label)
        right = right - w
        toggles[#toggles + 1] = { name = toggleName, x = right, w = w, text = label }
        right = right - 4
    end
    add("legend", TOGGLE_W, "?")
    if data and data.zoneEditable then add("zone", ZONE_W, getText("IGUI_BU_Zone")) end
    add("range", RANGE_W, getText("IGUI_BU_PlanRange"))
    if (self.zoom or 1) ~= 1 or (self.panX or 0) ~= 0 or (self.panY or 0) ~= 0 then add("fit", FIT_W, getText("IGUI_BU_PlanFit")) end
    self.toggles = toggles
end

function ISBUPlan:prerender()
    ISPanel.prerender(self)
    if not self.floorTitle then self:layoutTop() end
    self:drawTextCentre(self.floorTitle, self.width / 2, PAD, 1, 1, 1, 1, UIFont.Small)
    local legend = self:legendShown()
    for _, toggle in ipairs(self.toggles) do
        local on = toggle.name == "zone" and self.data.zoneEdit or toggle.name == "range" and self.window.rangeShown
        if on then self:drawRect(toggle.x, PAD - 1, toggle.w, FONT_HGT_SMALL + 2, 0.8, 0.2, 0.5, 0.6) end
        self:drawRectBorder(toggle.x, PAD - 1, toggle.w, FONT_HGT_SMALL + 2, 1, 0.6, 0.6, 0.6)
        local lit = toggle.name ~= "legend" or legend
        self:drawTextCentre(toggle.text, toggle.x + toggle.w / 2, PAD, 1, lit and 0.9 or 0.6, lit and 0.5 or 0.6,
            toggle.name == "legend" and 1 or 0.9, UIFont.Small)
    end
end

-- Which part of the top bar is under the mouse: a switch's name, "title" (the floor's name) or nil.
function ISBUPlan:toggleAt(x, y)
    if y >= PAD + FONT_HGT_SMALL + 2 then return nil end
    if not self.floorTitle then self:layoutTop() end
    for _, toggle in ipairs(self.toggles) do
        if x >= toggle.x and x < toggle.x + toggle.w then return toggle.name end
    end
    if math.abs(x - self.width / 2) <= self.titleHalf then return "title" end
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
    local zoom = math.max(MIN_ZOOM, math.min(MAX_ZOOM, (self.zoom or 1) * factor))
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
        self:drawRect(cell.x, cell.y, cell.w, cell.h, bright and 0.85 or cell.dim and 0.4 or 0.6, cell.r, cell.g, cell.b)
    end
    -- The rooms' outlines; the room under the mouse or filtered drawn last, bright.
    local brightWalls = {}
    for _, wall in ipairs(self.walls) do
        if wall.room == hoverRoom or wall.room == filter then
            brightWalls[#brightWalls + 1] = wall
        else
            local edge = wall.dim and 0.3 or 0.55
            self:drawRect(wall.x, wall.y, wall.w, wall.h, 1, edge, edge, edge)
        end
    end
    for _, wall in ipairs(brightWalls) do self:drawRect(wall.x, wall.y, wall.w, wall.h, 1, 1, 1, 1) end
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
    -- The flows: dots along each path, moving with the clock, over the squares they run between.
    local moved = getTimestampMs() / 1000 * FLOW_SPEED
    for _, flow in ipairs(self.flows) do
        local points, lengths = flow.points, flow.lengths
        -- A short path closer, so that it still shows a few.
        local gap = math.max(5, math.min(FLOW_GAP, flow.length / 3))
        local distance = BU.remainder(moved, gap)
        while distance < flow.length do
            local along = flow.toBox and distance or flow.length - distance
            local index = 2
            while index < #points and along > lengths[index] do
                along = along - lengths[index]
                index = index + 1
            end
            local a, b = points[index - 1], points[index]
            local t = lengths[index] > 0 and math.min(1, along / lengths[index]) or 0
            local x, y = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
            -- A dark rim, so a dot shows on a square of its own colour too.
            self:drawRect(x - FLOW_DOT / 2 - 1, y - FLOW_DOT / 2 - 1, FLOW_DOT + 2, FLOW_DOT + 2, 0.8, 0, 0, 0)
            self:drawRect(x - FLOW_DOT / 2, y - FLOW_DOT / 2, FLOW_DOT, FLOW_DOT, 1, flow.r, flow.g, flow.b)
            distance = distance + gap
        end
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
        local current = cell.level ~= nil and cell.level == self.floor
        self:drawRect(cell.x, cell.y, cell.w, cell.h, current and 0.8 or 0.4, current and 0.35 or 0.15, current and 0.35 or 0.15, current and 0.35 or 0.15)
        self:drawRectBorder(cell.x, cell.y, cell.w, cell.h, 1, 0.5, 0.5, 0.5)
        if cell.on then self:drawRect(cell.x + 1, cell.y + 1, 3, cell.h - 2, 1, 0.4, 0.9, 0.4) end
        -- The box's floor, so the player finds the way back.
        if cell.box then self:drawRect(cell.x + cell.w - 5, cell.y + 2, 3, 3, 1, 1, 1, 1) end
        local shade = cell.arrow and (cell.enabled and 1 or 0.35) or current and 1 or 0.75
        self:drawTextCentre(cell.text, cell.x + cell.w / 2, cell.y + 1, 1, 1, 1, shade, UIFont.Small)
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
    elseif kind == "floor" and thing.arrow then
        self.status = getText("IGUI_BU_StripScroll")
    elseif kind == "floor" then
        self.status = BU.floorName(thing.level)
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "zone" then
        self.status = self.data.zoneNote
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "range" then
        self.status = getText("IGUI_BU_PlanRangeHint")
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "title" and #(self.levels or {}) > 1 then
        self.status = getText("IGUI_BU_FloorMenuHint")
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
    if self.moved < DRAG or not self.map then return end
    self.dragged = true
    self.panX = (self.panX or 0) - dx / self.map.scale
    self.panY = (self.panY or 0) - dy / self.map.scale
    self:layout()
end

function ISBUPlan:showFloor(level)
    if level == nil or level == self.floor then return end
    self.floor = level
    -- The strip centres on it again.
    self.stripFirst = nil
    self:layout()
end

-- Over the floor strip the wheel scrolls the floors (up the wheel, up the building); elsewhere it zooms at the mouse
-- (up the wheel, closer).
function ISBUPlan:onMouseWheel(delta)
    local x, y = self:getMouseX(), self:getMouseY()
    if #self.strip > 0 and x < PAD + STRIP_W then
        self:scrollStrip(delta * STRIP_SCROLL)
        return true
    end
    self:zoomAt(x, y, delta < 0 and 1.25 or 0.8)
    return true
end

-- The floors the strip shows moved by so many (down the building for more).
function ISBUPlan:scrollStrip(by)
    self.stripFirst = (self.stripFirst or 1) + by
    self:layoutStrip()
end

-- Every floor in a menu at the mouse, top down, with how many devices are connected there; the one shown is not
-- offered.
function ISBUPlan:floorMenu()
    local menu = ISContextMenu.get(self.window.playerObj:getPlayerNum(), getMouseX(), getMouseY())
    for index = #self.levels, 1, -1 do
        local level = self.levels[index]
        local text = BU.floorName(level)
        if (self.floorOn[level] or 0) > 0 then text = text .. "  (" .. self.floorOn[level] .. ")" end
        if self.data and self.data.box.z == level then text = text .. "  " .. getText("IGUI_BU_FloorBox") end
        local option = menu:addOption(text, nil, function() self:showFloor(level) end)
        if level == self.floor then option.notAvailable = true end
    end
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
        self.zoom, self.panX, self.panY = 1, 0, 0
        self:layout()
        return true
    elseif toggle == "range" then
        self.window:onRange()
        return true
    elseif toggle == "title" then
        if #(self.levels or {}) > 1 then self:floorMenu() end
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
    if kind == "floor" and thing.arrow then
        self:scrollStrip(thing.arrow * thing.page)
    elseif kind == "floor" then
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
