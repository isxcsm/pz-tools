-- The floor plan beside a breaker box window: the building's rooms on one floor from above, north up, coloured by
-- what their devices do; the devices as dots, the producers as squares and the box itself. A strip on the left picks
-- the floor, a legend in a box at the bottom tells the colours (its header folds it). It shares hover and clicks with the
-- window's list: a row under the mouse marks its room or dot here and the other way round, a room clicked here shows
-- only that room there, a dot clicked here finds its row, and a right click offers what the row would. Rooms of the
-- building outside the box's zone are dim; the Zone switch at the top shows the zones instead, and a click there
-- takes a room in or out. Devices not connected are hollow; lines run from the building to the producers and the
-- devices outside it is connected to; dots run along them the way power or water goes now, from the producers in
-- use (or a bank charged from the box) through the building to the box, and out to devices outside. While the
-- window shows the range, the plan does too: an outline where devices outside join (blue) and where producers do
-- (yellow), and on the power plan how far each generator is heard (red, dim while it is off). The supply lines' switch
-- at the top shows them with their dots, the lines alone, or none (the player's choice, kept between games); without
-- dots or lines, the mouse over a producer shows its line. Supply that crosses floors shows too: on a producer's
-- floor its line runs on to a riser under (or over) the box, which tells the box's floor; by the box, a badge for each
-- other floor that supplies it tells how many come from there (the mouse over it, what); a click on either goes to
-- that floor. The floor strip marks the floors with producers, in their colour. While devices outside are chosen to
-- connect, a click on one chooses it. The wheel zooms at the mouse, dragging moves the plan, Fit goes back. Over the floor strip the wheel
-- scrolls the floors (arrows page them); the floor's name at the top lists every floor to jump to. A room is drawn as
-- one shape, its outline only where it meets another room or the outside. The top bar also shows the range (as the
-- window's range button would). Everything is laid out when the window refreshes or the plan is resized; a frame only
-- draws the rectangles laid out, inside the map.
require "ISUI/ISPanel"
require "PZAPI/ModOptions"
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
local ZONE_W = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_BU_Zone")) + 10
local FIT_W = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_BU_PlanFit")) + 10
local MIN_ZOOM, MAX_ZOOM, MAX_ZOOM_SCALE, DRAG = 0.5, 8, 48, 4
local RANGE_W = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_BU_PlanRange")) + 10
-- Wheel notches over the floor strip scroll it by so many floors.
local STRIP_SCROLL = 3
-- Flow dots: so far apart, so many pixels a second, so big.
local FLOW_GAP, FLOW_SPEED, FLOW_DOT = 14, 24, 4

ISBUPlan = ISPanel:derive("ISBUPlan")

-- How the plan shows the producers' supply lines, a view preference of the player's: "flow" (the lines and dots
-- running along them, the default), "lines" (the lines alone) or "off" (none, but the line of the producer under the
-- mouse). The game's mod options keep it (PZAPI.ModOptions, by its place in FLOW_STATES, in Zomboid\Lua\ModOptions.ini
-- as their screen writes it), so it lasts between games and saves, is the player's own in multiplayer, and shows on
-- that screen too. Without that API, for the session.
ISBUPlan.FLOW_STATES = { "flow", "lines", "off" }
local FLOW_STATES = ISBUPlan.FLOW_STATES
local FLOW_W = 0
for _, state in ipairs(FLOW_STATES) do
    FLOW_W = math.max(FLOW_W, getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_BU_PlanFlow_" .. state)) + 10)
end
local flowOption, flowSession = nil, 1
if PZAPI and PZAPI.ModOptions then
    local options = PZAPI.ModOptions:getOptions(BU.MOD) or PZAPI.ModOptions:create(BU.MOD, "IGUI_BU_ModOptions")
    flowOption = options:getOption("planFlow")
    if not flowOption then
        flowOption = options:addComboBox("planFlow", "IGUI_BU_PlanFlowOption", "IGUI_BU_PlanFlowHint")
        for index, state in ipairs(FLOW_STATES) do flowOption:addItem("IGUI_BU_PlanFlow_" .. state, index == 1) end
    end
end

function ISBUPlan.flowState()
    local index = flowOption and tonumber(flowOption:getValue()) or flowSession
    return FLOW_STATES[index] or FLOW_STATES[1]
end

function ISBUPlan.setFlowState(state)
    local index = 1
    for each, name in ipairs(FLOW_STATES) do
        if name == state then index = each end
    end
    if not flowOption then flowSession = index; return end
    flowOption:setValue(index)
    PZAPI.ModOptions:save()
end

-- The state after a state, as the switch goes round.
local function nextFlowState(state)
    for index, name in ipairs(FLOW_STATES) do
        if name == state then return FLOW_STATES[index % #FLOW_STATES + 1] end
    end
    return FLOW_STATES[1]
end

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
    zoneFar = { 0.12, 0.12, 0.12 },
    mixed = { 0.8, 0.8, 0.8 },
}

-- A producer's colour: its own (a tank's group's), a unit's (its kind's, Units.define), a tank's or a generator's.
local function producerColour(data, producer)
    if producer.colour then return producer.colour end
    if producer.unit then return BU.Units.definition(producer.unit).colour end
    return data.utility == "water" and COLOURS.tank or COLOURS.producer
end

-- What a producer is, in a word: its unit's kind, a water tank or a generator.
local function producerKind(data, producer)
    if producer.unit then return getText("IGUI_BU_Unit_" .. producer.unit) end
    return getText(data.utility == "water" and "IGUI_BU_Legend_tank" or "IGUI_BU_Legend_producer")
end

-- Whether two colours are the same, by value (each producer may have its own table).
local function sameColour(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end

-- Which way another floor is from a floor: "^" above, "v" below (as the floor strip's arrows).
local function arrow(level, from) return level > from and "^" or "v" end

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
        for _, name in ipairs({ "zoneMine", "zoneFree", "zoneTaken", "zoneFar" }) do add(name, true) end
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
    -- A floor with producers and no rooms (a roof) is shown too.
    for _, producer in ipairs(data.producers) do levels[producer.z] = true end
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
    self:layoutFloors()
    self:layout()
    -- What the status line says of the thing under the mouse may have changed with the data.
    if self.status then self:onMouseMove(0, 0) end
end

-- Supply across floors, worked out once for the data: each floor's producers' colour for the strip (a neutral one when
-- they differ), the riser of each floor with producers away from the box (its text and what it tells the mouse), and
-- for the box's floor what arrives from each other floor, highest first (a badge each: its text, width and colour,
-- the way its supply runs, and what comes, for the mouse).
function ISBUPlan:layoutFloors()
    local data = self.data
    local boxZ = data.box.z
    self.floorProducers, self.risers, self.arrivals = {}, {}, {}
    local byLevel = {}
    for _, producer in ipairs(data.producers) do
        local level, colour = producer.z, producerColour(data, producer)
        local seen = self.floorProducers[level]
        if not seen then self.floorProducers[level] = colour
        elseif not sameColour(seen, colour) then self.floorProducers[level] = COLOURS.mixed end
        if level ~= boxZ then
            local group = byLevel[level]
            if not group then
                group = { level = level, count = 0, kinds = {}, kindOrder = {}, colour = colour }
                byLevel[level] = group
                self.arrivals[#self.arrivals + 1] = group
            end
            group.count = group.count + 1
            if not sameColour(group.colour, colour) then group.colour = COLOURS.mixed end
            local kind = producerKind(data, producer)
            if not group.kinds[kind] then
                group.kinds[kind] = 0
                group.kindOrder[#group.kindOrder + 1] = kind
            end
            group.kinds[kind] = group.kinds[kind] + 1
            -- Dots run to the box while any of them supplies it, from it while one takes from it.
            if (producer.flow or 0) > 0 then group.flow = 1
            elseif producer.flow and not group.flow then group.flow = -1 end
        end
    end
    table.sort(self.arrivals, function(a, b) return a.level > b.level end)
    local measure = getTextManager()
    for _, group in ipairs(self.arrivals) do
        local parts = {}
        for _, kind in ipairs(group.kindOrder) do parts[#parts + 1] = getText("IGUI_BU_PlanKindCount", kind, group.kinds[kind]) end
        group.text = getText("IGUI_BU_PlanArrive", arrow(group.level, boxZ), BU.floorName(group.level), group.count)
        group.w = measure:MeasureStringX(UIFont.Small, group.text) + 6
        group.tip = getText("IGUI_BU_PlanArriveTip", BU.floorName(group.level), table.concat(parts, ", "))
        local text = getText("IGUI_BU_PlanRiser", arrow(boxZ, group.level), BU.floorName(boxZ))
        self.risers[group.level] = { text = text, w = measure:MeasureStringX(UIFont.Small, text) + 6,
            tip = getText("IGUI_BU_PlanRiserTip", BU.floorName(boxZ)) }
    end
end

function ISBUPlan:legendShown() return BU.PanelWindow.legendShown ~= false end

-- The legend's box from x: its header (the fold), and while it is open its entries in columns. Returns the height
-- it takes above the status line, with the gap over it.
function ISBUPlan:layoutLegend(x, entries)
    local measure = getTextManager()
    local shown = self:legendShown()
    local header = getText("IGUI_BU_LegendTitle") .. (shown and "  v" or "  >")
    local columnW = 0
    for _, entry in ipairs(entries) do columnW = math.max(columnW, measure:MeasureStringX(UIFont.Small, entry.text) + 14 + PAD * 2) end
    local maxW = math.max(40, self.width - x - PAD)
    local columns = math.max(1, math.min(3, #entries, math.floor((maxW - PAD * 2) / math.max(1, columnW))))
    local rows = shown and math.ceil(#entries / columns) or 0
    local headerW = measure:MeasureStringX(UIFont.Small, header) + PAD * 2
    local w = math.min(maxW, math.max(headerW, shown and columns * columnW + PAD * 2 - PAD or headerW))
    local h = LEGEND_ROW + 4 + (rows > 0 and rows * LEGEND_ROW + 4 or 0)
    local y = self.height - FONT_HGT_SMALL - PAD * 2 - h
    self.legendBox = { x = x, y = y, w = w, h = h, header = header, headerH = LEGEND_ROW + 4, shown = shown }
    if shown then
        for index, entry in ipairs(entries) do
            local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
            entry.x, entry.y = x + PAD + column * columnW, y + LEGEND_ROW + 4 + row * LEGEND_ROW
            self.legend[#self.legend + 1] = entry
        end
    end
    return h + PAD
end

-- Whether a point is on the legend's header, which folds it.
function ISBUPlan:onLegendHeader(x, y)
    local box = self.legendBox
    return box ~= nil and x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.headerH
end

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
    self.flows, self.walls, self.hoverLine, self.badges, self.riser, self.legendBox = {}, {}, nil, {}, nil, nil
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
    local top = self.topH
    -- The legend: a box above the status line, a gap from the floor strip, under a header that folds it. Its entries
    -- in as many columns (up to three) of the widest one as fit.
    local legendH = self:layoutLegend(left + PAD, legendEntries(data.utility, data.zoneEdit, data.ranges))
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
    -- The lines: from the building's outline (this floor's, else any) to each producer and device outside it takes;
    -- the producers' as the supply lines' switch has them (ISBUPlan.flowState).
    local floorRects, allRects = Geometry.roomRects(data.rooms, self.floor)
    local flowState = ISBUPlan.flowState()
    -- The box's place, on its floor; on another, the riser's under or over it.
    local boxFloor = data.box.z == self.floor
    local boxX, boxY = ox + (data.box.x + 0.5 - minX) * scale, oy + (data.box.y + 0.5 - minY) * scale
    -- The dots' path along points, to the box's end (flow 1) or from it (-1), brighter than the line.
    local function addFlow(points, colour, flow)
        local length, lengths = 0, {}
        for index = 2, #points do
            local a, b = points[index - 1], points[index]
            local dx, dy = b[1] - a[1], b[2] - a[2]
            lengths[index] = math.sqrt(dx * dx + dy * dy)
            length = length + lengths[index]
        end
        if length < 1 then return end
        self.flows[#self.flows + 1] = { points = points, lengths = lengths, length = length, toBox = flow > 0,
            r = math.min(1, colour[1] + 0.3), g = math.min(1, colour[2] + 0.3), b = math.min(1, colour[3] + 0.3) }
    end
    -- A line, drawn when shown: from the thing to the building, and for a producer on another floor than the box's on
    -- to its riser (x3, y3); while the switch shows the flow, with a flow, dots run along it, on to the box (or the
    -- riser). Returns the line, for the mouse over a producer.
    local function addLine(x, y, colour, flow, shown, producer)
        local px, py = nearestPoint(#floorRects > 0 and floorRects or allRects, x + 0.5, y + 0.5)
        if not px then return nil end
        local line = { x1 = ox + (x + 0.5 - minX) * scale, y1 = oy + (y + 0.5 - minY) * scale,
            x2 = ox + (px - minX) * scale, y2 = oy + (py - minY) * scale, r = colour[1], g = colour[2], b = colour[3] }
        local onward = boxFloor or producer
        if onward and not boxFloor then line.x3, line.y3 = boxX, boxY end
        if shown then self.lines[#self.lines + 1] = line end
        if flow and shown and flowState == "flow" then
            local points = { { line.x1, line.y1 }, { line.x2, line.y2 } }
            if onward then points[3] = { boxX, boxY } end
            addFlow(points, colour, flow)
        end
        return line
    end
    for _, device in ipairs(data.devices) do
        if device.z == self.floor and not device.inside and device.state == "on" then
            addLine(device.x, device.y, COLOURS.idle, device.flow, true)
        end
    end
    local producerLines = {}
    for index, producer in ipairs(data.producers) do
        if producer.z == self.floor then
            producerLines[index] = addLine(producer.x, producer.y, producerColour(data, producer), producer.flow,
                flowState ~= "off", true)
        end
    end
    -- On a floor of producers away from the box, the riser their lines end at; on the box's, a badge for each other
    -- floor that supplies it, with a stub into the box (and its dots) while the switch shows lines.
    local riser = not boxFloor and self.risers[self.floor]
    if riser then
        self.riser = { x = math.floor(boxX - riser.w / 2), y = math.floor(boxY - FONT_HGT_SMALL / 2 - 1), w = riser.w,
            h = FONT_HGT_SMALL + 2, text = riser.text, tip = riser.tip, level = data.box.z }
    end
    if boxFloor then
        local badgeX, badgeY = math.floor(boxX + math.max(scale, 8) / 2 + 16), math.floor(boxY - FONT_HGT_SMALL / 2 - 1)
        for index, group in ipairs(self.arrivals) do
            local badge = { x = badgeX, y = badgeY + (index - 1) * (FONT_HGT_SMALL + 4), w = group.w, h = FONT_HGT_SMALL + 2,
                text = group.text, tip = group.tip, colour = group.colour, level = group.level }
            self.badges[#self.badges + 1] = badge
            if flowState ~= "off" then
                local c = group.colour
                local stub = { x1 = badge.x, y1 = badge.y + badge.h / 2, x2 = boxX, y2 = boxY, r = c[1], g = c[2], b = c[3] }
                self.lines[#self.lines + 1] = stub
                if flowState == "flow" and group.flow then
                    addFlow({ { stub.x1, stub.y1 }, { boxX, boxY } }, c, group.flow)
                end
            end
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
                local colour = state == "mine" and COLOURS.zoneMine or state == "taken" and COLOURS.zoneTaken
                    or state == "far" and COLOURS.zoneFar or COLOURS.zoneFree
                r, g, b = colour[1], colour[2], colour[3]
            elseif state == "mine" then
                r, g, b = roomColour(roomState[room.id] or { on = 0, held = 0 }, data.supplied)
            else
                local colour = state == "taken" and COLOURS.zoneTaken or state == "far" and COLOURS.zoneFar or COLOURS.zoneFree
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
    for index, producer in ipairs(data.producers) do
        if producer.z == self.floor then
            local colour = producerColour(data, producer)
            self.squares[#self.squares + 1] = { x = sx(producer.x), y = sy(producer.y), size = math.max(scale, 8),
                r = colour[1], g = colour[2], b = colour[3], ring = producer.inUse, text = producer.text,
                line = producerLines[index] }
        end
    end
    if data.box.z == self.floor then
        self.squares[#self.squares + 1] = { x = sx(data.box.x), y = sy(data.box.y), size = math.max(scale, 8),
            r = 1, g = 1, b = 1, ring = false, text = data.boxText }
    end
    self:layoutStrip()
end

-- Whether a floor is beyond what the box's zone can take (data.reached: the lowest and the highest it can).
function ISBUPlan:farFloor(level)
    local reached = self.data and self.data.reached
    return reached ~= nil and (level < reached[1] or level > reached[2])
end

-- The floor strip: the floors top down, as many as fit, around the one shown or where the player scrolled it. With more
-- than fit, an arrow at each end pages them.
function ISBUPlan:layoutStrip()
    self.strip = {}
    if #self.levels < 2 then return end
    local top = self.topH or FONT_HGT_SMALL + PAD * 2
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
            text = BU.floorShort(level), on = (self.floorOn[level] or 0) > 0, box = self.data and self.data.box.z == level,
            producer = self.floorProducers and self.floorProducers[level], far = self:farFloor(level) }
        y = y + CELL_H
    end
    if overflow then arrow(1, first + fit - 1 < #downward) end
end

-- The top bar, laid out with the rest: the floor shown with what its devices draw (with several floors, a click on
-- it lists them) and the switches, right to left: the legend, the zone (where zones can be edited), the range, the
-- supply lines, Fit (zoomed or moved), each { name, x, y, w, text }. Nothing overlaps at any width or font size: the
-- switches that do not fit go to a row below, and the floor's name keeps the middle while it fits beside them, else
-- moves into the room they leave, without the load where that is too narrow (the status line then has it all), and
-- takes a row of its own above them when even its name does not fit. The bar's height is topH.
function ISBUPlan:layoutTop()
    local data = self.data
    local measure = getTextManager()
    local function width(text) return measure:MeasureStringX(UIFont.Small, text) end
    local name = BU.floorName(self.floor or 0)
    local full = name
    if data and data.utility == "power" then
        full = getText("IGUI_BU_FloorLoad", full, string.format("%.2f", self.floorLoad and self.floorLoad[self.floor] or 0))
    end
    local more = #(self.levels or {}) > 1 and "  v" or ""
    -- The switches, in rows from the top, right to left.
    local toggles, row, right, rights = {}, 0, self.width - PAD, {}
    local function add(toggleName, w, label)
        if right - w < PAD and #toggles > 0 then row, right = row + 1, self.width - PAD end
        right = right - w
        toggles[#toggles + 1] = { name = toggleName, x = right, row = row, w = w, text = label }
        right = right - 4
        rights[row] = right
    end
    if data and data.zoneEditable then add("zone", ZONE_W, getText("IGUI_BU_Zone")) end
    add("range", RANGE_W, getText("IGUI_BU_PlanRange"))
    add("flow", FLOW_W, getText("IGUI_BU_PlanFlow_" .. ISBUPlan.flowState()))
    if (self.zoom or 1) ~= 1 or (self.panX or 0) ~= 0 or (self.panY or 0) ~= 0 then add("fit", FIT_W, getText("IGUI_BU_PlanFit")) end
    -- The floor's name: beside the first row's switches, else a row of its own (cut short only if even that is too
    -- narrow).
    local text, roomRight = full .. more, rights[0]
    if width(text) > roomRight - PAD then text = name .. more end
    local own = width(text) > roomRight - PAD
    if own then
        roomRight = self.width - PAD
        text = width(full .. more) <= roomRight - PAD and full .. more or name .. more
        local cut = name
        while width(text) > roomRight - PAD and #cut > 1 do
            cut = cut:sub(1, -2)
            text = cut .. "..." .. more
        end
        for _, toggle in ipairs(toggles) do toggle.row = toggle.row + 1 end
        row = row + 1
    end
    local rowH = FONT_HGT_SMALL + 6
    for _, toggle in ipairs(toggles) do toggle.y = PAD - 1 + toggle.row * rowH end
    local titleW = width(text)
    local titleX = math.floor((self.width - titleW) / 2)
    if titleX < PAD or titleX + titleW > roomRight then titleX = math.floor(PAD + (roomRight - PAD - titleW) / 2) end
    self.floorTitle, self.titleX, self.titleW = text, titleX, titleW
    -- The whole title for the status line when the bar shows less.
    self.titleFull = text ~= full .. more and full or nil
    self.toggles = toggles
    self.topH = FONT_HGT_SMALL + PAD * 2 + row * rowH
end

function ISBUPlan:prerender()
    ISPanel.prerender(self)
    if not self.floorTitle then self:layoutTop() end
    self:drawText(self.floorTitle, self.titleX, PAD, 1, 1, 1, 1, UIFont.Small)
    for _, toggle in ipairs(self.toggles) do
        local on = toggle.name == "zone" and self.data.zoneEdit or toggle.name == "range" and self.window.rangeShown
            or toggle.name == "flow" and ISBUPlan.flowState() ~= "off"
        if on then self:drawRect(toggle.x, toggle.y, toggle.w, FONT_HGT_SMALL + 2, 0.8, 0.2, 0.5, 0.6) end
        self:drawRectBorder(toggle.x, toggle.y, toggle.w, FONT_HGT_SMALL + 2, 1, 0.6, 0.6, 0.6)
        self:drawTextCentre(toggle.text, toggle.x + toggle.w / 2, toggle.y + 1, 1, 0.9, 0.5, 0.9, UIFont.Small)
    end
end

-- Which part of the top bar is under the mouse: a switch's name, "title" (the floor's name) or nil.
function ISBUPlan:toggleAt(x, y)
    if not self.floorTitle then self:layoutTop() end
    if y >= self.topH - PAD + 2 then return nil end
    for _, toggle in ipairs(self.toggles) do
        if x >= toggle.x and x < toggle.x + toggle.w and y >= toggle.y and y < toggle.y + FONT_HGT_SMALL + 2 then
            return toggle.name
        end
    end
    if x >= self.titleX - 4 and x <= self.titleX + self.titleW + 4 and y < PAD + FONT_HGT_SMALL + 2 then return "title" end
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
        if line.x3 then self:drawLine(WHITE, line.x2, line.y2, line.x3, line.y3, 1, 0.8, line.r, line.g, line.b) end
    end
    -- The line of the producer under the mouse, brighter, while the switch shows no dots.
    local hover = self.hoverLine
    if hover then
        local r, g, b = math.min(1, hover.r + 0.3), math.min(1, hover.g + 0.3), math.min(1, hover.b + 0.3)
        self:drawLine(WHITE, hover.x1, hover.y1, hover.x2, hover.y2, 2, 1, r, g, b)
        if hover.x3 then self:drawLine(WHITE, hover.x2, hover.y2, hover.x3, hover.y3, 2, 1, r, g, b) end
    end
    for _, square in ipairs(self.squares) do
        local size = square.size
        self:drawRect(square.x, square.y, size, size, 1, square.r, square.g, square.b)
        if square.ring then self:drawRectBorder(square.x - 2, square.y - 2, size + 4, size + 4, 1, 1, 1, 1) end
    end
    -- The flows: dots along each path, moving with the clock, over the squares they run between (none laid out while
    -- the Flow switch is off).
    local moved = #self.flows > 0 and getTimestampMs() / 1000 * FLOW_SPEED
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
    -- The riser and the badges: a dark box, framed in their colour, with their text.
    local riser = self.riser
    if riser then
        self:drawRect(riser.x, riser.y, riser.w, riser.h, 0.85, 0, 0, 0)
        self:drawRectBorder(riser.x, riser.y, riser.w, riser.h, 1, 1, 1, 1)
        self:drawText(riser.text, riser.x + 3, riser.y + 1, 1, 1, 1, 1, UIFont.Small)
    end
    for _, badge in ipairs(self.badges) do
        local c = badge.colour
        self:drawRect(badge.x, badge.y, badge.w, badge.h, 0.85, 0, 0, 0)
        self:drawRectBorder(badge.x, badge.y, badge.w, badge.h, 1, c[1], c[2], c[3])
        self:drawText(badge.text, badge.x + 3, badge.y + 1, c[1], c[2], c[3], 1, UIFont.Small)
    end
    if map then self:clearStencilRect() end
    for _, cell in ipairs(self.strip) do
        local current = cell.level ~= nil and cell.level == self.floor
        self:drawRect(cell.x, cell.y, cell.w, cell.h, current and 0.8 or 0.4, current and 0.35 or 0.15, current and 0.35 or 0.15, current and 0.35 or 0.15)
        self:drawRectBorder(cell.x, cell.y, cell.w, cell.h, 1, 0.5, 0.5, 0.5)
        if cell.on then self:drawRect(cell.x + 1, cell.y + 1, 3, cell.h - 2, 1, 0.4, 0.9, 0.4) end
        -- The box's floor, so the player finds the way back.
        if cell.box then self:drawRect(cell.x + cell.w - 5, cell.y + 2, 3, 3, 1, 1, 1, 1) end
        -- Its producers, in their colour.
        local producer = cell.producer
        if producer then self:drawRect(cell.x + cell.w - 5, cell.y + cell.h - 5, 3, 3, 1, producer[1], producer[2], producer[3]) end
        local shade = cell.arrow and (cell.enabled and 1 or 0.35) or current and 1 or cell.far and 0.4 or 0.75
        self:drawTextCentre(cell.text, cell.x + cell.w / 2, cell.y + 1, 1, 1, 1, shade, UIFont.Small)
    end
    local box = self.legendBox
    if box then
        self:drawRect(box.x, box.y, box.w, box.h, 0.6, 0.06, 0.06, 0.06)
        self:drawRectBorder(box.x, box.y, box.w, box.h, 0.8, 0.4, 0.4, 0.4)
        if box.shown then self:drawRect(box.x + 1, box.y + box.headerH - 1, box.w - 2, 1, 0.6, 0.4, 0.4, 0.4) end
        self:drawText(box.header, box.x + PAD, box.y + 2, 0.9, 0.85, 0.6, 1, UIFont.Small)
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
    for _, badge in ipairs(self.badges) do
        if x >= badge.x and x <= badge.x + badge.w and y >= badge.y and y <= badge.y + badge.h then return "badge", badge end
    end
    local riser = self.riser
    if riser and x >= riser.x and x <= riser.x + riser.w and y >= riser.y and y <= riser.y + riser.h then
        return "badge", riser
    end
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
    -- A producer's line, as laid out with the rest, while the switch shows no dots.
    self.hoverLine = kind == "square" and ISBUPlan.flowState() ~= "flow" and thing.line or nil
    if kind == "dot" or kind == "square" then
        self.status = thing.text
    elseif kind == "badge" then
        self.status = thing.tip
    elseif kind == "room" then
        self.status = self.window:roomStatus(thing.room)
        local zone = self.data and self.data.zone and self.data.zone[thing.room]
        if zone and zone.state == "taken" then
            self.status = self.status .. "  (" .. getText("IGUI_BU_ZoneTaken", zone.owner or "") .. ")"
        elseif zone and zone.state == "free" then
            self.status = self.status .. "  (" .. getText("IGUI_BU_Legend_zoneFree") .. ")"
        elseif zone and zone.state == "far" then
            self.status = self.status .. "  (" .. (self.data.farNote or getText("IGUI_BU_Legend_zoneFar")) .. ")"
        end
    elseif kind == "floor" and thing.arrow then
        self.status = getText("IGUI_BU_StripScroll")
    elseif kind == "floor" then
        self.status = BU.floorName(thing.level)
        if thing.far and self.data.farNote then self.status = self.status .. "  (" .. self.data.farNote .. ")" end
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "zone" then
        self.status = self.data.zoneNote
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "flow" then
        self.status = getText("IGUI_BU_PlanFlowHint")
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "range" then
        self.status = getText("IGUI_BU_PlanRangeHint")
    elseif self:onLegendHeader(self:getMouseX(), self:getMouseY()) then
        self.status = getText(self:legendShown() and "IGUI_BU_LegendFold" or "IGUI_BU_LegendUnfold")
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "title" and #(self.levels or {}) > 1 then
        self.status = (self.titleFull and self.titleFull .. "  " or "") .. getText("IGUI_BU_FloorMenuHint")
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "title" and self.titleFull then
        self.status = self.titleFull
    elseif self:inMap(self:getMouseX(), self:getMouseY()) then
        self.status = getText(#(self.levels or {}) > 1 and "IGUI_BU_PlanHint" or "IGUI_BU_PlanHintOne")
    else
        self.status = nil
    end
    self:drag(dx, dy)
end

function ISBUPlan:onMouseMoveOutside(dx, dy)
    if self.hoverKey or self.hoverRoom then self:setHover(nil, nil) end
    self.hoverLine = nil
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
    if self.window.planFloorChanged then self.window:planFloorChanged(level) end
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
    if self:onLegendHeader(x, y) then
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
    elseif toggle == "flow" then
        ISBUPlan.setFlowState(nextFlowState(ISBUPlan.flowState()))
        self:layout()
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
    elseif kind == "floor" or kind == "badge" then
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
