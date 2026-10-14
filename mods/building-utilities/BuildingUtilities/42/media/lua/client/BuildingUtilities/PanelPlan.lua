-- The floor plan beside a breaker box window: the rooms its zone can have on one floor from above (its own building's
-- and those of the buildings its relays stand in, one plan), north up, coloured by what their devices do; the devices
-- as dots, the producers, units, relays and the box itself as squares, each told by its colour; and the box's lines,
-- each from its thing to what it hangs on (a wall square, a relay, a device), grey where it supplies nothing.
-- A strip on the left picks the floor, a legend in a box at the bottom tells the colours (its header folds it). It
-- shares hover and clicks with the window's list: a row under the mouse marks its room or dot here and the other way
-- round, a room clicked here shows only that room there, a dot or a producer's, unit's or relay's square clicked here
-- finds its row (selected, kept so as the list fills again; one key for both, ISBUPanelWindow.rowKey), and a right
-- click offers what the row would. Rooms of the building outside the box's zone are dim; the Zone switch at the top shows the zones
-- instead, and a click there takes a room in or out. Devices in reach not connected are grey; the mouse over a thing
-- with a line brings its line up. The Range switch shows the range here and in the world: an outline where devices
-- outside, producers and units join from the zone's walls and from the relays, and on the power plan how far each
-- generator is heard (red, dim while it is off). A square shown from the window (a relay, a branch that supplies
-- nothing) is zoomed to and marked a moment. The floor strip marks the floors with producers, in their colour. The
-- wheel zooms at the mouse, dragging moves the plan, Fit goes back. Over the floor strip the wheel scrolls the floors (arrows page
-- them); the floor's name at the top lists every floor to jump to. A room is drawn as one shape, its outline only
-- where it meets another room or the outside. Everything is laid out when the window refreshes or the plan is
-- resized; a frame only draws the rectangles laid out, inside the map. The plan is drawn with the shared UI kit
-- (PZUIKit), as the window: in design units (its numbers, its mouse) and the kit's faces. On the water tab the
-- Schematic switch puts the pipes' schematic (BuildingUtilities/PanelSchematic) over the map in its place.
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "PZUIKit/RichText"
require "BuildingUtilities/Geometry"
require "BuildingUtilities/PanelUi"
require "BuildingUtilities/Relays"
require "BuildingUtilities/PanelSchematic"
local BU = BuildingUtilities
local Geometry = BU.Geometry
local UI = PZUIKit.UI
local P = BU.PanelUi.PALETTE

local FONT_HGT_SMALL = BU.PanelUi.FONT_HGT_SMALL
local PAD = 8
local MAX_SCALE = 14
local DOT = 6
-- A producer's, a unit's and the box's square, a little larger than a device's dot: its colour tells what it is.
local SQUARE = 9
local HIT = 5
local STRIP_W = 34
local CELL_H = FONT_HGT_SMALL + 4
local LEGEND_ROW = FONT_HGT_SMALL + 2
-- The top bar's switches' widths, measured in the kit's faces for the scale they were made in (measureSwitches).
local ZONE_W, FIT_W, RANGE_W, SCHEME_W, measuredEra = 0, 0, 0, 0, nil
local MIN_ZOOM, MAX_ZOOM, MAX_ZOOM_SCALE, DRAG = 0.5, 8, 48, 4
-- Wheel notches over the floor strip scroll it by so many floors.
local STRIP_SCROLL = 3
-- The rooms' outlines are WALL_PX wide, whatever the zoom; the line of the thing under the mouse LINE_PX over a dark
-- casing CASING_PX wide, so that it reads over any room or the grid.
local WALL_PX, LINE_PX, CASING_PX = 2, 1, 3
-- A square shown from the window is marked so long.
local FOCUS_MS = 1600
-- The legend: its header's fold mark so wide, and it folds or opens over LEGEND_MS.
local CHEVRON_W, LEGEND_MS = 12, 220
-- The pipe combo's colour square.
local SWATCH = 8

ISBUPlan = ISPanel:derive("ISBUPlan")

local function measureSwitches()
    if measuredEra == UI.era then return end
    measuredEra = UI.era
    ZONE_W = UI.textWidth(getText("IGUI_BU_Zone")) + 10
    FIT_W = UI.textWidth(getText("IGUI_BU_PlanFit")) + 10
    RANGE_W = UI.textWidth(getText("IGUI_BU_PlanRange")) + 10
    SCHEME_W = UI.textWidth(getText("IGUI_BU_Scheme")) + 10
end

local WHITE = Texture.getWhite()

function ISBUPlan:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = true
    o.backgroundColor = { r = P.inset[1], g = P.inset[2], b = P.inset[3], a = 0.92 }
    o.borderColor = { r = P.border[1], g = P.border[2], b = P.border[3], a = 1 }
    o.cells, o.labels, o.dots, o.squares, o.strip, o.legend, o.edges = {}, {}, {}, {}, {}, {}, {}
    o.rangeCache, o.lines, o.lineByRef = {}, {}, {}
    return o
end

-- The colour of a room: kept off by the box (amber), supplied and in use (green), connected without supply (grey
-- blue), all switched off at the box (dark); one with nothing of the utility in it in the zone's own colour, faint.
local function roomColour(room, supplied)
    if room.count == 0 then return 0.15, 0.32, 0.38 end
    if room.held > 0 then return 0.85, 0.55, 0.15 end
    if room.on > 0 then
        if supplied then return 0.25, 0.68, 0.45 end
        return 0.38, 0.46, 0.6
    end
    return 0.3, 0.33, 0.38
end

-- How bright a fixture's dot (in its pipe's colour), a tank's or a unit's square is while it is off.
local PIPE_OFF = 0.35

local COLOURS = {
    other = { 0.6, 0.4, 0.8 }, off = { 0.45, 0.45, 0.45 }, timer = { 0.4, 0.6, 1 },
    unsupplied = { 0.6, 0.65, 0.75 }, using = { 0.4, 1, 0.4 }, idle = { 0.25, 0.6, 0.3 },
    producer = { 1, 0.5, 0.15 }, tank = { 0.3, 0.6, 1 }, box = { 0.86, 0.88, 0.9 },
    range = { 0.3, 0.6, 1 }, rangeNoise = { 1, 0.35, 0.3 },
    rangeNoiseIdle = { 0.6, 0.3, 0.3 },
    zoneMine = { 0.2, 0.5, 0.6 }, zoneFree = { 0.25, 0.25, 0.25 }, zoneTaken = { 0.5, 0.3, 0.6 },
    zoneFar = { 0.12, 0.12, 0.12 },
    mixed = { 0.8, 0.8, 0.8 },
    -- the legend's shapes of water with several pipes, apart from the box's white
    shape = { 0.55, 0.58, 0.63 },
    junction = BU.Units.definition("junction").colour, hydrant = BU.Units.definition("hydrant").colour,
    solar = BU.Units.definition("solar").colour, rack = BU.Units.definition("rack").colour,
    linePower = { 0.95, 0.72, 0.3 }, lineWater = { 0.45, 0.78, 0.86 }, lineCut = { 0.42, 0.42, 0.44 },
}

-- A producer's colour: its own (a tank's group's), a unit's (its kind's, Units.define), a tank's or a generator's.
local function producerColour(data, producer)
    if producer.unwired or producer.cut then return COLOURS.off end
    if producer.colour then return producer.colour end
    if producer.unit then return BU.Units.definition(producer.unit).colour end
    return data.utility == "water" and COLOURS.tank or COLOURS.producer
end

-- Whether two colours are the same, by value (each producer may have its own table).
local function sameColour(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end

-- What a device's dot tells (its legend entry): "pipe" for water with more than one pipe (its pipe's colour), else a
-- name of COLOURS.
local function dotKind(device, supplied)
    if device.state == "other" then return "other" end
    if device.pipeColour and device.wired and not device.cut then return "pipe" end
    if device.state ~= "on" or device.cut then return device.wired and not device.cut and "idle" or "off" end
    if device.held == "timer" then return "timer" end
    if device.held == "exterior" or not supplied then return "unsupplied" end
    if (device.power or 0) > 0 or device.utility == "water" then return "using" end
    return "idle"
end

local function dotColour(device, supplied)
    local kind = dotKind(device, supplied)
    if kind == "pipe" then
        -- its pipe's colour, dark while it is off
        local pipe, k = device.pipeColour, device.state == "on" and 1 or PIPE_OFF
        return pipe[1] * k, pipe[2] * k, pipe[3] * k
    end
    local colour = COLOURS[kind]
    return colour[1], colour[2], colour[3]
end

-- A relay's mark on its square: a dark hole in the middle, a hub the lines meet at (a stroke down the middle read as
-- the digit 1). The plan and the legend draw it alike.
local function relayMark(plan, x, y, size, alpha)
    local hole = math.max(3, math.floor(size / 3))
    local at = math.floor((size - hole) / 2)
    plan:drawRect(x + at, y + at, hole, hole, 0.85 * alpha, 0.1, 0.08, 0.06)
end

-- What the legend lists for a utility, or for the zones, of what the floor shown has: a colour, dot or square, and its
-- text. Water with more than one pipe tells its pipes' colours instead of what the devices do, and shapes in a plain
-- colour. ranges: the floor's outlines (ISBUPlan:ranges) while the range is shown.
local function legendEntries(utility, zones, ranges, data, floor)
    local result = {}
    local pipes = not zones and utility == "water" and data.pipes or nil
    local function add(name, square)
        local colour = COLOURS[name]
        if pipes and (name == "tank" or name == "lineWater") then colour = COLOURS.shape end
        result[#result + 1] = { r = colour[1], g = colour[2], b = colour[3], square = square,
            text = getText("IGUI_BU_Legend_" .. name) }
    end
    -- What the floor has: the dots' kinds, the squares' kinds, the pipe colours drawn, a dark one, two halves.
    local has, colours, dark, halves = {}, {}, false, nil
    local function drawn(colour)
        if colour then colours[#colours + 1] = colour end
    end
    if zones then
        for _, room in ipairs(data.rooms) do
            if room.level == floor then
                local zone = data.zone and data.zone[room.id]
                local state = zone and zone.state or "mine"
                has["zone" .. state:sub(1, 1):upper() .. state:sub(2)] = true
            end
        end
    end
    for _, device in ipairs(data.devices) do
        if device.z == floor then
            local kind = dotKind(device, data.supplied)
            has[kind] = true
            if kind == "pipe" then
                drawn(device.pipeColour)
                if device.state ~= "on" then dark = true end
            end
        end
    end
    for _, producer in ipairs(data.producers) do
        if producer.z == floor then
            if producer.unwired or producer.cut then
                has.off = true
            else
                has[producer.unit or (utility == "water" and "tank" or "producer")] = true
                drawn(producer.colour)
                drawn(producer.colour2)
                if producer.off then dark = true end
                if producer.colour2 and not halves then halves = producer end
            end
            -- a storage's square is one whatever its colour
            if not producer.unit and utility == "water" then has.tank = true end
        end
    end
    for _, relay in ipairs(data.relays or {}) do
        if relay.z == floor then
            has.relay = true
            if relay.cut then has.off = true end
        end
    end
    for _, line in ipairs(data.lines or {}) do
        if line.z1 == floor or line.z2 == floor then
            if line.live then
                has.live = true
                drawn(line.colour)
                drawn(line.colour2)
            else
                has.dead = true
            end
        end
    end
    for _, room in ipairs(data.rooms) do
        if room.level == floor then drawn(room.pipeColour) end
    end
    for _, box in ipairs(data.boxes) do
        if box.z == floor then has.box = true end
    end
    local function addIf(name, square)
        if has[name] then add(name, square) end
    end
    if zones then
        for _, name in ipairs({ "zoneMine", "zoneFree", "zoneTaken", "zoneFar" }) do addIf(name, true) end
    elseif pipes then
        -- each pipe's colour drawn here, what is on it is drawn in (a dot a fixture, a square a storage or a unit)
        local firstShown
        for _, pipe in ipairs(pipes) do
            local c = pipe.colour
            for _, seen in ipairs(colours) do
                if sameColour(seen, c) then
                    result[#result + 1] = { r = c[1], g = c[2], b = c[3], square = true, text = pipe.name }
                    firstShown = firstShown or c
                    break
                end
            end
        end
        if dark and firstShown then
            result[#result + 1] = { r = firstShown[1] * PIPE_OFF, g = firstShown[2] * PIPE_OFF,
                b = firstShown[3] * PIPE_OFF, text = getText("IGUI_BU_Legend_pipeOff") }
        end
        for _, name in ipairs({ "using", "idle", "unsupplied", "off", "other" }) do addIf(name) end
        addIf("tank", true)
        -- a filter's or a booster pump's square: its inlet's pipe left, its outlet's right
        if halves then
            local first = halves.colour or COLOURS.shape
            result[#result + 1] = { r = first[1], g = first[2], b = first[3], square = true, second = halves.colour2,
                text = getText("IGUI_BU_Legend_unitHalves") }
        end
    else
        for _, name in ipairs({ "using", "idle", "timer", "unsupplied", "other", "off" }) do addIf(name) end
        -- the sources: generators or storages, and the solar panels and battery racks
        for _, name in ipairs({ "producer", "tank", "solar", "rack" }) do addIf(name, true) end
    end
    addIf("box", true)
    if not zones then
        if has.relay then
            add(utility == "water" and "hydrant" or "junction", true)
            result[#result].relay = true
        end
        if has.live then add(utility == "water" and "lineWater" or "linePower", "line") end
        if has.dead then add("lineCut", "line") end
    end
    if ranges and not zones then
        local shown = #ranges.reach > 0
        for _, edges in ipairs(ranges.relays) do shown = shown or #edges > 0 end
        if shown then add("range", "line") end
        if #ranges.noise > 0 then add("rangeNoise", "line") end
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


-- data: { utility, supplied, rooms = { { id, title, level, rects, pipeColour (while a pipe is put on rooms) } }, devices = { { key, x, y, z, roomId, inside,
-- state, held, cut, power, name, status, ref, pipeColour (water with more than one pipe: its pipe's, or nil) } }, producers = { { x, y, z, inUse,
-- text, unit = its kind for a unit, colour or nil, cut, ref } }, relays = { { x, y, z, kind, cut, text, ref } }, lines =
-- { { ref, x1, y1, z1 (its thing), x2, y2, z2 (what it hangs on), way (its corners on the ground, Links.way, or nil),
-- live, colour (a water pipe's, or nil) } }, box = { x, y, z }, outdoor, boxes = { { x, y, z, own, text } } (the
-- boxes whose zones can have these rooms, this window's own), filter = room id, zone = room id to { state = "mine",
-- "free", "taken" or "far", owner = a name, note = why a far room cannot be taken }, zoneEditable, zoneEdit, zoneNote,
-- farLevels (the floors with no room the zone can take, a set), waterSupply (by floor, "dry", for water),
-- ranges = { reach = steps, relayReach = steps, relays = { { x, y, z } }, noise = for power { { x, y, z, radius,
-- running } } } while the range is shown, rangeKey (what the ranges are of), pipes = { { colour, name } } (water with
-- more than one pipe, for the legend), pipeCombo (water with more than one pipe:
-- the switch that puts a pipe on rooms), pipePaint = { id, colour, name } (the pipe a click puts on a room, or nil) }.
function ISBUPlan:setData(data)
    -- Another utility shown: the plan fades in anew.
    if self.data and self.data.utility ~= data.utility then self.switchedAt = getTimestampMs() end
    self.data = data
    local levels = {}
    for _, room in ipairs(data.rooms) do levels[room.level] = true end
    -- A floor with producers, relays or lines and no rooms (a roof, an outdoor box) is shown too.
    for _, producer in ipairs(data.producers) do levels[producer.z] = true end
    for _, relay in ipairs(data.relays or {}) do levels[relay.z] = true end
    for _, line in ipairs(data.lines or {}) do levels[line.z1], levels[line.z2] = true, true end
    levels[data.box.z] = true
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
    self:placeScheme()
    -- What the status line says of the thing under the mouse may have changed with the data.
    if self.status then self:onMouseMove(0, 0) end
end

-- Each floor's producers' colour for the strip, worked out once for the data (a neutral one when they differ).
function ISBUPlan:layoutFloors()
    local data = self.data
    self.floorProducers = {}
    for _, producer in ipairs(data.producers) do
        local level, colour = producer.z, producerColour(data, producer)
        local seen = self.floorProducers[level]
        if not seen then self.floorProducers[level] = colour
        elseif not sameColour(seen, colour) then self.floorProducers[level] = COLOURS.mixed end
    end
end

-- The legend is folded until the player opens it (kept while the game runs).
function ISBUPlan:legendShown() return BU.PanelWindow.legendShown == true end

-- The legend's box from x: its header (the fold), and while it is open its entries in columns. Returns the height
-- it takes above the status line, with the gap over it.
function ISBUPlan:layoutLegend(x, entries)
    local shown = self:legendShown()
    local header = getText("IGUI_BU_LegendTitle")
    local columnW = 0
    for _, entry in ipairs(entries) do columnW = math.max(columnW, UI.textWidth(entry.text) + 14 + PAD * 2) end
    local maxW = math.max(40, self.width - x - PAD)
    local columns = math.max(1, math.min(3, #entries, math.floor((maxW - PAD * 2) / math.max(1, columnW))))
    local rows = shown and math.ceil(#entries / columns) or 0
    local headerW = UI.textWidth(header) + PAD * 2 + CHEVRON_W
    local w = math.min(maxW, math.max(headerW, shown and columns * columnW + PAD * 2 - PAD or headerW))
    local h = LEGEND_ROW + 4 + (rows > 0 and rows * LEGEND_ROW + 4 or 0)
    local y = self.height - FONT_HGT_SMALL - PAD * 2 - h
    self.legendBox = { x = x, y = y, w = w, h = h, header = header, headerH = LEGEND_ROW + 4, shown = shown }
    if shown then
        for index, entry in ipairs(entries) do
            local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
            entry.x, entry.y = x + PAD + column * columnW, y + LEGEND_ROW + 4 + row * LEGEND_ROW
            entry.w, entry.fx = columnW - PAD, "e" .. index
            self.legend[#self.legend + 1] = entry
        end
    end
    return h + PAD
end

-- Whether a point is on the legend's header, which folds it.
function ISBUPlan:onLegendHeader(x, y)
    local box = self.legendBox
    local top = box and (box.top or box.y)
    return box ~= nil and x >= box.x and x < box.x + (box.drawnW or box.w) and y >= top and y < top + box.headerH
end

-- The range outlines of a floor, worked out once for a building, tier and floor.
function ISBUPlan:ranges(floor)
    local data = self.data
    if not data.ranges then return nil end
    if self.rangeKey ~= data.rangeKey then self.rangeCache, self.rangeKey = {}, data.rangeKey end
    local cached = self.rangeCache[floor]
    if cached then return cached end
    -- Devices outside, producers and units join by the zone's rooms of the floor (as the API finds devices), the whole
    -- zone's outline on a floor without them (a roof); an outdoor box by its own square. A relay's lines reach about it.
    local mine = {}
    for _, room in ipairs(data.rooms) do
        local zone = data.zone and data.zone[room.id]
        if not zone or zone.state == "mine" then mine[#mine + 1] = room end
    end
    local floorRects, allRects = Geometry.roomRects(mine, floor)
    if data.outdoor then floorRects = { { x = data.box.x, y = data.box.y, w = 1, h = 1 } } end
    cached = { reach = rangeEdges(#floorRects > 0 and floorRects or allRects, data.ranges.reach), noise = {}, relays = {} }
    for _, relay in ipairs(data.ranges.relays or {}) do
        if relay.z == floor then
            cached.relays[#cached.relays + 1] = rangeEdges({ { x = relay.x, y = relay.y, w = 1, h = 1 } },
                data.ranges.relayReach)
        end
    end
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
    self.cells, self.labels, self.dots, self.squares, self.strip, self.legend, self.edges = {}, {}, {}, {}, {}, {}, {}
    self.walls, self.legendBox, self.hoverLine = {}, nil, nil
    self.lines, self.lineByRef = {}, {}
    self.grid = {}
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
    for _, relay in ipairs(data.relays or {}) do cover(relay.x, relay.y, 1, 1) end
    for _, line in ipairs(data.lines or {}) do
        cover(line.x1, line.y1, 1, 1)
        cover(line.x2, line.y2, 1, 1)
        for _, point in ipairs(line.way or {}) do cover(point[1] - 0.5, point[2] - 0.5, 1, 1) end
    end
    cover(data.box.x, data.box.y, 1, 1)
    if not minX then return end
    -- With the range shown, the plan takes in where devices outside and producers join, and where generators are heard.
    local ranges = self:ranges(self.floor)
    local rangeSets = ranges and { ranges.reach } or {}
    for _, noise in ipairs(ranges and ranges.noise or {}) do rangeSets[#rangeSets + 1] = noise.edges end
    for _, edges in ipairs(ranges and ranges.relays or {}) do rangeSets[#rangeSets + 1] = edges end
    for _, edges in ipairs(rangeSets) do
        for _, edge in ipairs(edges) do cover(edge.x, edge.y, edge.across and edge.len or 0, edge.across and 0 or edge.len) end
    end
    local left = PAD + (#self.levels > 1 and STRIP_W or 0)
    local top = self.topH
    -- The legend: a box above the status line, a gap from the floor strip, under a header that folds it. Its entries
    -- in as many columns (up to three) of the widest one as fit.
    local legendH = self:layoutLegend(left + PAD, legendEntries(data.utility, data.zoneEdit, ranges, data, self.floor))
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
        baseX = baseX, baseY = baseY, ox = ox, oy = oy, minX = minX, minY = minY }
    local function sx(x) return math.floor(ox + (x - minX) * scale) end
    local function sy(y) return math.floor(oy + (y - minY) * scale) end
    self.scale = scale
    local wall = WALL_PX / (UI.S or 1)
    -- A faint grid of the squares under the plan, as on drawing paper: every square once they are big enough to tell
    -- apart, else every fifth; none when even those crowd.
    local step = scale >= 7 and 1 or 5
    self.grid = {}
    if scale * step >= 7 then
        local first = math.ceil((minX + (left - ox) / scale) / step) * step
        for x = first, minX + (left + availW - ox) / scale, step do
            self.grid[#self.grid + 1] = { x = sx(x), y = top, w = 1, h = availH, major = x % 10 == 0 }
        end
        first = math.ceil((minY + (top - oy) / scale) / step) * step
        for y = first, minY + (top + availH - oy) / scale, step do
            self.grid[#self.grid + 1] = { x = left, y = sy(y), w = availW, h = 1, major = y % 10 == 0 }
        end
    end
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
        addEdges(ranges.reach, COLOURS.range)
        for _, edges in ipairs(ranges.relays) do addEdges(edges, COLOURS.range) end
    end
    -- The lines with an end on this floor, the way they lie on the ground (else square middle to square middle), in
    -- their utility's colour (a water pipe's own) or grey; each found by its thing's ref for the mouse.
    local lineColour = data.utility == "water" and COLOURS.lineWater or COLOURS.linePower
    for _, line in ipairs(data.lines or {}) do
        if line.z1 == self.floor or line.z2 == self.floor then
            local colour = line.live and (line.colour or lineColour) or COLOURS.lineCut
            local second = line.live and line.colour2 or nil
            local points = {}
            for _, point in ipairs(line.way or { { line.x1 + 0.5, line.y1 + 0.5 }, { line.x2 + 0.5, line.y2 + 0.5 } }) do
                local x, y = ox + (point[1] - minX) * scale, oy + (point[2] - minY) * scale
                local last = points[#points]
                if not last or last[1] ~= x or last[2] ~= y then points[#points + 1] = { x, y } end
            end
            local drawn = { points = points, live = line.live, r = colour[1], g = colour[2], b = colour[3], second = second }
            self.lines[#self.lines + 1] = drawn
            self.lineByRef[line.ref] = drawn
        end
    end
    self:layoutRooms(sx, sy, wall)
    self:layoutThings(sx, sy, scale)
    self:layoutStrip()
end

-- The rooms of this floor (cells, walls, labels), placed by layout's sx and sy. Out of layout, which would otherwise
-- be past the 200 locals a function may declare in the game's debug mode.
function ISBUPlan:layoutRooms(sx, sy, wall)
    local data = self.data
    -- Rooms on this floor, with what their devices do.
    local roomState = {}
    for _, device in ipairs(data.devices) do
        if device.inside then
            local state = roomState[device.roomId] or { on = 0, held = 0, count = 0 }
            roomState[device.roomId] = state
            state.count = state.count + 1
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
            elseif state == "mine" and room.pipeColour then
                local c = room.pipeColour
                r, g, b = c[1] * 0.7, c[2] * 0.7, c[3] * 0.7
            elseif state == "mine" then
                r, g, b = roomColour(roomState[room.id] or { on = 0, held = 0, count = 0 }, data.supplied)
            else
                local colour = state == "taken" and COLOURS.zoneTaken or state == "far" and COLOURS.zoneFar or COLOURS.zoneFree
                r, g, b = colour[1] * 0.5, colour[2] * 0.5, colour[3] * 0.5
            end
            local dim = state ~= "mine" and not data.zoneEdit
            -- its light's key, and its outline in a light tint of its colour
            local fx = "r" .. tostring(room.id)
            local wr, wg, wb = r + (1 - r) * 0.45, g + (1 - g) * 0.45, b + (1 - b) * 0.45
            -- The label goes on its largest rectangle, by its squares (by its pixels, two of a size took turns as the
            -- plan was dragged, the label flickering between them and gone when the narrower one won).
            local largest
            for _, rect in ipairs(room.rects) do
                local cell = { x = sx(rect.x), y = sy(rect.y), room = room.id, r = r, g = g, b = b, dim = dim, fx = fx,
                    area = rect.w * rect.h }
                cell.w, cell.h = sx(rect.x + rect.w) - cell.x, sy(rect.y + rect.h) - cell.y
                self.cells[#self.cells + 1] = cell
                if not largest or cell.area > largest.area then largest = cell end
            end
            for _, edge in ipairs(self:roomOutline(room)) do
                local x1, y1 = sx(edge.x), sy(edge.y)
                -- centred on the edge, and on over the corners so that two walls meet square
                self.walls[#self.walls + 1] = { room = room.id, dim = dim, r = wr, g = wg, b = wb,
                    x = x1 - wall / 2, y = y1 - wall / 2,
                    w = edge.across and sx(edge.x + edge.len) - x1 + wall or wall,
                    h = edge.across and wall or sy(edge.y + edge.len) - y1 + wall }
            end
            if largest and UI.textWidth(room.title) < largest.w - 4
                    and largest.h > FONT_HGT_SMALL + 2 then
                self.labels[#self.labels + 1] = { text = room.title, x = largest.x + largest.w / 2,
                    y = largest.y + (largest.h - FONT_HGT_SMALL) / 2, dim = dim }
            end
        end
    end
end

-- The devices, producers, relays and boxes of this floor, placed by layout's sx and sy.
function ISBUPlan:layoutThings(sx, sy, scale)
    local data = self.data
    for _, device in ipairs(data.devices) do
        if device.z == self.floor then
            local r, g, b = dotColour(device, data.supplied)
            self.dots[#self.dots + 1] = { key = device.key, room = device.inside and device.roomId or nil,
                x = math.floor(sx(device.x) + scale / 2), y = math.floor(sy(device.y) + scale / 2), r = r, g = g, b = b,
                text = device.name .. "  " .. (device.status or ""), fresh = device.fresh, ref = device.ref }
        end
    end
    for _, producer in ipairs(data.producers) do
        if producer.z == self.floor then
            local colour = producerColour(data, producer)
            -- a unit between two pipes: its right half in its outlet's colour; one shut or off at the box dark
            local second = not (producer.unwired or producer.cut) and producer.colour2 or nil
            if producer.off and not (producer.unwired or producer.cut) then
                colour = { colour[1] * PIPE_OFF, colour[2] * PIPE_OFF, colour[3] * PIPE_OFF }
                second = second and { second[1] * PIPE_OFF, second[2] * PIPE_OFF, second[3] * PIPE_OFF }
            end
            self.squares[#self.squares + 1] = { x = math.floor(sx(producer.x) + (scale - SQUARE) / 2),
                y = math.floor(sy(producer.y) + (scale - SQUARE) / 2), size = SQUARE,
                r = colour[1], g = colour[2], b = colour[3], second = second, ring = producer.inUse, text = producer.text,
                ref = producer.ref, key = producer.key }
        end
    end
    -- The relays: a square in their kind's colour (grey while they supply nothing), a hole in its middle.
    for _, relay in ipairs(data.relays or {}) do
        if relay.z == self.floor then
            local colour = relay.cut and COLOURS.off or COLOURS[relay.kind]
            self.squares[#self.squares + 1] = { x = math.floor(sx(relay.x) + (scale - SQUARE) / 2),
                y = math.floor(sy(relay.y) + (scale - SQUARE) / 2), size = SQUARE, relay = true,
                r = colour[1], g = colour[2], b = colour[3], text = relay.text, ref = relay.ref, key = relay.key }
        end
    end
    -- The boxes of the building; this window's ringed.
    for _, box in ipairs(data.boxes) do
        if box.z == self.floor then
            local colour = COLOURS.box
            self.squares[#self.squares + 1] = { x = math.floor(sx(box.x) + (scale - SQUARE) / 2),
                y = math.floor(sy(box.y) + (scale - SQUARE) / 2), size = SQUARE,
                r = colour[1], g = colour[2], b = colour[3], ring = box.own, text = box.text }
        end
    end
end

-- Whether a floor has rooms and none the box's zone can take (data.farLevels).
function ISBUPlan:farFloor(level)
    return self.data ~= nil and self.data.farLevels ~= nil and self.data.farLevels[level] == true
end

-- Why the zone can take no room of a floor: a far room's note there.
function ISBUPlan:farNote(level)
    for _, room in ipairs(self.data and self.data.rooms or {}) do
        local zone = room.level == level and self.data.zone and self.data.zone[room.id]
        if zone and zone.note then return zone.note end
    end
    return nil
end

-- Followed while a square shown from the window is marked.
local function focusFrame(plan, now)
    local focus = plan.focus
    if not focus or now - focus.at >= FOCUS_MS then
        plan.focus = nil
        return nil
    end
    return math.floor((now - focus.at) / 16)
end

-- Shows a square: its floor, the plan zoomed in (at least threefold) and centred on it, marked a moment.
function ISBUPlan:focusOn(x, y, z)
    if not self.data then return end
    if z ~= self.floor then self:showFloor(z) end
    self.zoom = math.max(self.zoom or 1, 3)
    self:layout()
    local map = self.map
    if not map then return end
    self.panX, self.panY = x + 0.5 - map.baseX, y + 0.5 - map.baseY
    self.focus = { x = x, y = y, z = z, at = getTimestampMs() }
    self:layout()
    UI.live(self, focusFrame)
end

-- The floor strip: the floors top down, as many as fit, around the one shown or where the player scrolled it. With more
-- than fit, an arrow at each end pages them.
function ISBUPlan:layoutStrip()
    self.strip = {}
    if #self.levels < 2 then return end
    local top = self.topH or FONT_HGT_SMALL + PAD * 2
    -- down to the status line at the bottom, which it leaves clear
    local rows = math.max(3, math.floor((self.height - top - FONT_HGT_SMALL - PAD * 2) / CELL_H))
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
            h = CELL_H - 2, text = direction < 0 and "^" or "v", fx = direction < 0 and "sUp" or "sDown" }
        y = y + CELL_H
    end
    if overflow then arrow(-1, first > 1) end
    for index = first, math.min(#downward, first + fit - 1) do
        local level = downward[index]
        self.strip[#self.strip + 1] = { level = level, x = PAD, y = y, w = STRIP_W - 6, h = CELL_H - 2,
            text = BU.floorShort(level), on = (self.floorOn[level] or 0) > 0, box = self.data and self.data.box.z == level,
            producer = self.floorProducers and self.floorProducers[level], far = self:farFloor(level),
            supply = self.data and self.data.waterSupply and self.data.waterSupply[level], fx = "s" .. level }
        y = y + CELL_H
    end
    if overflow then arrow(1, first + fit - 1 < #downward) end
end

-- The top bar, laid out with the rest: the floor shown with what its devices draw (the strip at the left picks the
-- floor) and the switches, right to left: the zone (where zones can be edited), the range, Fit (zoomed or
-- moved), each { name, x, y, w, text }. Nothing overlaps at any width or font size: the
-- switches that do not fit go to a row below, and the floor's name keeps the middle while it fits beside them, else
-- moves into the room they leave, without the load where that is too narrow (the status line then has it all), and
-- takes a row of its own above them when even its name does not fit. The bar's height is topH.
function ISBUPlan:layoutTop()
    measureSwitches()
    local data = self.data
    local function width(text) return UI.textWidth(text) end
    local name = BU.floorName(self.floor or 0)
    local full = name
    if data and data.utility == "power" then
        full = getText("IGUI_BU_FloorLoad", full, string.format("%.2f", self.floorLoad and self.floorLoad[self.floor] or 0))
    end
    -- The switches, in rows from the top, right to left.
    local toggles, row, right, rights = {}, 0, self.width - PAD, {}
    local function add(toggleName, w, label)
        if right - w < PAD and #toggles > 0 then row, right = row + 1, self.width - PAD end
        right = right - w
        toggles[#toggles + 1] = { name = toggleName, x = right, row = row, w = w, text = label, fx = "t" .. toggleName }
        right = right - 4
        rights[row] = right
    end
    if data and data.utility == "water" then add("scheme", SCHEME_W, getText("IGUI_BU_Scheme")) end
    -- A combo: the pipe being put on rooms (its colour before its name), or what it is for.
    if data and data.pipeCombo then
        local paint = data.pipePaint
        local label = (paint and paint.name or getText("IGUI_BU_PlanPipe")) .. "  v"
        add("pipe", UI.textWidth(label) + 10 + (paint and SWATCH + 4 or 0), label)
        toggles[#toggles].swatch = paint and paint.colour or nil
    end
    if data and data.zoneEditable then add("zone", ZONE_W, getText("IGUI_BU_Zone")) end
    add("range", RANGE_W, getText("IGUI_BU_PlanRange"))
    if (self.zoom or 1) ~= 1 or (self.panX or 0) ~= 0 or (self.panY or 0) ~= 0 then add("fit", FIT_W, getText("IGUI_BU_PlanFit")) end
    -- The floor's name: beside the first row's switches, else a row of its own (cut short only if even that is too
    -- narrow).
    local text, roomRight = full, rights[0]
    if width(text) > roomRight - PAD then text = name end
    local own = width(text) > roomRight - PAD
    if own then
        roomRight = self.width - PAD
        text = width(full) <= roomRight - PAD and full or name
        local cut = name
        while width(text) > roomRight - PAD and #cut > 1 do
            cut = cut:sub(1, -2)
            text = cut .. "..."
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
    self.titleFull = text ~= full and full or nil
    self.toggles = toggles
    self.topH = FONT_HGT_SMALL + PAD * 2 + row * rowH
end

function ISBUPlan:prerender()
    ISPanel.prerender(self)
    if not self.floorTitle then self:layoutTop() end
    -- The top bar: the floor's name and the switches, in the window's buttons' look: on ones in the accent, the one
    -- under the mouse lit, a click flashing.
    local over = self:isMouseOver() and self:toggleAt(self:getMouseX(), self:getMouseY()) or nil
    self:drawText(self.floorTitle, self.titleX, PAD, 0.85, 0.85, 0.85, 1, UIFont.Small)
    local h = FONT_HGT_SMALL + 2
    for _, toggle in ipairs(self.toggles) do
        local on = toggle.name == "zone" and self.data.zoneEdit or toggle.name == "range" and self.window.rangeShown == true
            or toggle.name == "scheme" and self:schemeShown() or toggle.name == "pipe" and self.data.pipePaint ~= nil
        local k = UI.hoverLight(self, toggle.fx, over == toggle.name)
        local f = UI.flashLevel(self, toggle.fx)
        UI.fill(self, toggle.x, toggle.y, toggle.w, h, on and P.sel or P.panel, on and 0.75 or 0.6)
        if k > 0 or f > 0 then UI.fill(self, toggle.x, toggle.y, toggle.w, h, P.bright, 0.1 * k + 0.25 * f) end
        UI.frame(self, toggle.x, toggle.y, toggle.w, h, (on or k > 0.5) and P.value or P.border, 1)
        local textX = toggle.x + toggle.w / 2
        if toggle.swatch then
            local s = toggle.swatch
            UI.fill(self, toggle.x + 5, toggle.y + math.floor((h - SWATCH) / 2), SWATCH, SWATCH, s, 1)
            textX = textX + (SWATCH + 4) / 2
        end
        UI.textCentre(self, toggle.text, textX, toggle.y + 1, (on or k > 0.5) and P.bright or P.text)
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


-- Followed while the legend folds or opens.
local function legendFrame(plan, now)
    local anim = plan.legendAnim
    if not anim then return nil end
    local t = (now - anim.at) / LEGEND_MS
    if t >= 1 then
        plan.legendAnim = nil
        return nil
    end
    return math.floor(t * 100)
end

-- The legend's fold mark: a small solid triangle drawn pixel by pixel (lines drawn this small blur into a blob),
-- pointing right while folded and down while open, the one fading into the other as it opens (open 0 to 1). `px`: a
-- pixel in design units.
local function drawChevron(plan, cx, cy, open, px, c)
    local S = 1 / px
    cx, cy = math.floor(cx * S + 0.5) * px, math.floor(cy * S + 0.5) * px
    local size = 4
    if open < 1 then
        for i = 0, size - 1 do
            local h = (size - 1 - i) * 2 + 1
            plan:drawRect(cx + (i - 2) * px, cy - (size - 1 - i) * px, px, h * px, 1 - open, c[1], c[2], c[3])
        end
    end
    if open > 0 then
        for i = 0, size - 1 do
            local w = (size - 1 - i) * 2 + 1
            plan:drawRect(cx - (size - 1 - i) * px, cy + (i - 2) * px, w * px, px, open, c[1], c[2], c[3])
        end
    end
end

-- The legend: a box rising from the status line, its header (a fold mark and the title) lit under the mouse and
-- flashing on a click; it grows or shrinks over LEGEND_MS as it opens or folds, the entries showing as it uncovers
-- them. The entry under the mouse is lit, and marks on the plan the dots or squares it names (legendHover).
function ISBUPlan:drawLegend(now, mx, my, px)
    local box = self.legendBox
    self.legendHover = nil
    if not box then return end
    local anim = self.legendAnim
    local e = anim and BU.PanelUi.ease(math.min(1, (now - anim.at) / LEGEND_MS)) or 1
    local h = anim and anim.fromH + (box.h - anim.fromH) * e or box.h
    local w = anim and anim.fromW + (box.w - anim.fromW) * e or box.w
    local top = box.y + box.h - h
    box.top, box.drawnW = top, w
    local headerH = box.headerH
    local overHeader = mx >= box.x and mx < box.x + w and my >= top and my < top + headerH
    local k = UI.hoverLight(self, "legend", overHeader)
    local f = UI.flashLevel(self, "legend")
    UI.fill(self, box.x, top, w, h, P.panel, 0.88)
    if k > 0 or f > 0 then UI.fill(self, box.x + 1, top + 1, w - 2, headerH - 2, P.sel, 0.25 * k + 0.35 * f) end
    UI.frame(self, box.x, top, w, h, k > 0.5 and P.value or P.border, 1)
    local open = box.shown and e or 1 - e
    local head = P.head
    local c = { head[1] + (1 - head[1]) * 0.4 * k, head[2] + (1 - head[2]) * 0.4 * k, head[3] + (1 - head[3]) * 0.4 * k }
    drawChevron(self, box.x + PAD + 3, top + headerH / 2, open, px, c)
    self:drawText(box.header, box.x + PAD + CHEVRON_W, top + 2, c[1], c[2], c[3], 1, UIFont.Small)
    if h > headerH + 1 then UI.fill(self, box.x + 1, top + headerH - 1, w - 2, 1, P.border, 0.8) end
    -- The entries: those laid out while it is open, or, while it folds, the ones it had.
    local entries, alpha = self.legend, box.shown and e or 1
    if anim and not box.shown then entries, alpha = anim.entries, 1 - e end
    for _, entry in ipairs(entries) do
        if entry.y >= top + headerH - 1 then
            local over = box.shown and not anim and mx >= entry.x - 3 and mx < entry.x - 3 + entry.w and my >= entry.y
                and my < entry.y + LEGEND_ROW
            if over then self.legendHover = entry end
            local lit = UI.hoverLight(self, entry.fx, over)
            if lit > 0 then UI.fill(self, entry.x - 3, entry.y, entry.w, LEGEND_ROW, P.sel, 0.22 * lit) end
            local middle = entry.y + LEGEND_ROW / 2
            if entry.square == "line" then
                self:drawRect(entry.x, middle, 10, 1, alpha, entry.r, entry.g, entry.b)
            elseif entry.square then
                self:drawRect(entry.x, middle - 4, 9, 9, alpha, entry.r, entry.g, entry.b)
                local second = entry.second
                if second then self:drawRect(entry.x + 4.5, middle - 4, 4.5, 9, alpha, second[1], second[2], second[3]) end
                if entry.relay then relayMark(self, entry.x, middle - 4, 9, alpha) end
            else
                self:drawRect(entry.x + 1, middle - DOT / 2, DOT, DOT, alpha, entry.r, entry.g, entry.b)
            end
            local shade = 0.8 + 0.2 * lit
            self:drawText(entry.text, entry.x + 14, entry.y + 1, shade, shade, shade, alpha, UIFont.Small)
        end
    end
end

-- Folds or opens the legend, from the box it has now.
function ISBUPlan:toggleLegend()
    local box = self.legendBox
    local shown = self:legendShown()
    self.legendAnim = box and { at = getTimestampMs(), fromH = box.top and box.y + box.h - box.top or box.h,
        fromW = box.drawnW or box.w, entries = shown and self.legend or {} } or nil
    BU.PanelWindow.legendShown = not shown
    UI.flash(self, "legend")
    self:layout()
    if self.legendAnim then UI.live(self, legendFrame) end
end

-- Whether the pipes' schematic is over the map: on the water tab, its switch on.
function ISBUPlan:schemeShown()
    return BU.PanelWindow.schemeShown == true and self.data ~= nil and self.data.utility == "water"
end

-- The schematic under the top bar, shown or hidden, and drawn anew from the box's water while it shows.
function ISBUPlan:placeScheme()
    local shown = self:schemeShown()
    if shown and not self.scheme then
        self.scheme = ISBUSchematic:new(0, 0, 10, 10, self.window)
        self.scheme:initialise()
        self.scheme:instantiate()
        self:addChild(self.scheme)
    end
    if not self.scheme then return end
    self.scheme:setVisible(shown)
    if not shown then
        self.scheme:setHover(nil)
        return
    end
    local top = self.topH or 0
    UI.place(self.scheme, 1, top, self.width - 2, math.max(10, self.height - top - 1))
    self.scheme:refresh(self.window.panel)
end

function ISBUPlan:render()
    ISPanel.render(self)
    -- the schematic in the map's place: nothing of the map is drawn
    if self.scheme and self.scheme:isVisible() then return end
    local window = self.window
    local hoverRoom = self.hoverRoom or window.listHoverRoom
    local hoverKey = self.hoverKey or window.listHoverKey
    local filter = self.data and self.data.filter
    local map = self.map
    local now = getTimestampMs()
    local px = 1 / (UI.S or 1)
    local mx, my = -1, -1
    if self:isMouseOver() then mx, my = self:getMouseX(), self:getMouseY() end
    if map then
        self:setStencilRect(map.left, map.top, map.w, map.h)
        for _, line in ipairs(self.grid) do
            UI.fill(self, line.x, line.y, line.w, line.h, P.border, line.major and 0.2 or 0.09)
        end
    end
    -- The rooms: a wash of what their devices do, the one under the mouse coming up.
    for _, cell in ipairs(self.cells) do
        local k = UI.hoverLight(self, cell.fx, cell.room == hoverRoom)
        local a = (cell.dim and 0.14 or 0.3) + (cell.room == filter and 0.2 or 0) + 0.25 * k
        self:drawRect(cell.x, cell.y, cell.w, cell.h, a, cell.r, cell.g, cell.b)
    end
    -- The rooms' outlines in a light tint of their colour; the room under the mouse or filtered drawn last, bright.
    local brightWalls = {}
    for _, wall in ipairs(self.walls) do
        if wall.room == hoverRoom or wall.room == filter then
            brightWalls[#brightWalls + 1] = wall
        else
            self:drawRect(wall.x, wall.y, wall.w, wall.h, wall.dim and 0.35 or 0.8, wall.r, wall.g, wall.b)
        end
    end
    for _, wall in ipairs(brightWalls) do UI.fill(self, wall.x, wall.y, wall.w, wall.h, P.bright, 1) end
    for _, label in ipairs(self.labels) do
        self:drawTextCentre(label.text, label.x, label.y, P.text[1], P.text[2], P.text[3], label.dim and 0.35 or 0.8, UIFont.Small)
    end
    for _, edge in ipairs(self.edges) do self:drawRect(edge.x, edge.y, edge.w, edge.h, 0.7, edge.r, edge.g, edge.b) end
    -- The lines, at their fixed width under the squares; the one of the thing under the mouse over a dark casing in a
    -- light tint of its colour.
    local lw, cw = LINE_PX * px, CASING_PX * px
    for _, line in ipairs(self.lines) do
        local second, p = line.second, line.points
        for i = 2, #p do
            local x1, y1, x2, y2 = p[i - 1][1], p[i - 1][2], p[i][1], p[i][2]
            if second then
                -- a machine's inlet and outlet, side by side
                local sx, sy = BU.Links.besideOffset(x2 - x1, y2 - y1, lw * 1.5)
                self:drawLine(WHITE, x1 - sx, y1 - sy, x2 - sx, y2 - sy, lw, 0.8, line.r, line.g, line.b)
                self:drawLine(WHITE, x1 + sx, y1 + sy, x2 + sx, y2 + sy, lw, 0.8, second[1], second[2], second[3])
            else
                self:drawLine(WHITE, x1, y1, x2, y2, lw, line.live and 0.8 or 0.55, line.r, line.g, line.b)
            end
        end
    end
    local hover = self.hoverLine
    if hover then
        local r, g, b = hover.r + (1 - hover.r) * 0.45, hover.g + (1 - hover.g) * 0.45, hover.b + (1 - hover.b) * 0.45
        local p = hover.points
        for i = 2, #p do self:drawLine(WHITE, p[i - 1][1], p[i - 1][2], p[i][1], p[i][2], cw, 0.7, 0.02, 0.03, 0.05) end
        for i = 2, #p do self:drawLine(WHITE, p[i - 1][1], p[i - 1][2], p[i][1], p[i][2], lw, 1, r, g, b) end
    end
    -- The legend's entry under the mouse marks what it names.
    local marked = self.legendHover
    for _, square in ipairs(self.squares) do
        local size = square.size
        self:drawRect(square.x - 1, square.y - 1, size + 2, size + 2, 0.9, 0.02, 0.03, 0.05)
        self:drawRect(square.x, square.y, size, size, 1, square.r, square.g, square.b)
        local second = square.second
        if second then
            self:drawRect(square.x + size / 2, square.y, size / 2, size, 1, second[1], second[2], second[3])
        end
        self:drawRect(square.x, square.y, size, px, 0.45, 1, 1, 1)
        if square.relay then relayMark(self, square.x, square.y, size, 1) end
        if square.ring then
            self:drawRectBorder(square.x - 3, square.y - 3, size + 6, size + 6, 0.9,
                math.min(1, square.r + 0.3), math.min(1, square.g + 0.3), math.min(1, square.b + 0.3))
        end
        if square.key and square.key == hoverKey or marked and marked.square and marked.square ~= "line"
                and marked.r == square.r and marked.g == square.g and marked.b == square.b then
            UI.frame(self, square.x - 4, square.y - 4, size + 8, size + 8, P.bright, 1)
        end
    end
    for _, dot in ipairs(self.dots) do
        local half = DOT / 2
        self:drawRect(dot.x - half - 1, dot.y - half - 1, DOT + 2, DOT + 2, 0.85, 0.02, 0.03, 0.05)
        self:drawRect(dot.x - half, dot.y - half, DOT, DOT, 1, dot.r, dot.g, dot.b)
        if dot.fresh then self:drawRect(dot.x + half, dot.y - half - 3, 3, 3, 1, 0.3, 0.9, 1) end
        if dot.key == hoverKey or marked and not marked.square and marked.r == dot.r
                and marked.g == dot.g and marked.b == dot.b then
            UI.frame(self, dot.x - DOT - 1, dot.y - DOT - 1, DOT * 2 + 2, DOT * 2 + 2, P.bright, 1)
        end
    end
    -- A square shown from the window: a frame closing in on it as the mark fades.
    local focus = self.focus
    if focus and map and map.ox and focus.z == self.floor then
        local t = math.min(1, (now - focus.at) / FOCUS_MS)
        local fx = map.ox + (focus.x + 0.5 - map.minX) * map.scale
        local fy = map.oy + (focus.y + 0.5 - map.minY) * map.scale
        local half = SQUARE + 10 * (1 - BU.PanelUi.ease(math.min(1, t * 2)))
        UI.frame(self, fx - half, fy - half, half * 2, half * 2, P.warn, 1 - t)
    end
    -- Fading in after a switch of utility or floor.
    local t = self.switchedAt and (now - self.switchedAt) / BU.PanelUi.SWITCH_MS or 1
    if t >= 1 then self.switchedAt = nil end
    if map and t < 1 then
        self:drawRect(map.left, map.top, map.w, map.h, (1 - BU.PanelUi.ease(t)) * 0.9, 0.04, 0.04, 0.05)
    end
    -- taken back with repaintStencilRect too: the game leaves a clip inside the window's a level up, where a later
    -- clip in the window would let drawing through
    if map then
        self:clearStencilRect()
        self:repaintStencilRect(map.left, map.top, map.w, map.h)
    end
    for _, cell in ipairs(self.strip) do
        local current = cell.level ~= nil and cell.level == self.floor
        local k = UI.hoverLight(self, cell.fx, not current and mx >= cell.x and mx <= cell.x + cell.w and my >= cell.y
            and my <= cell.y + cell.h)
        UI.fill(self, cell.x, cell.y, cell.w, cell.h, current and P.sel or P.panel, current and 0.55 or 0.5 + 0.3 * k)
        UI.frame(self, cell.x, cell.y, cell.w, cell.h, current and P.value or P.border, 1)
        if cell.on then self:drawRect(cell.x + 1, cell.y + 1, 3, cell.h - 2, 1, 0.4, 0.9, 0.4) end
        -- Water: a floor with a fixture no tank reaches (red), along its foot.
        if cell.supply == "dry" then self:drawRect(cell.x + 5, cell.y + cell.h - 3, cell.w - 12, 2, 1, 0.9, 0.3, 0.25) end
        -- The box's floor, so the player finds the way back.
        if cell.box then self:drawRect(cell.x + cell.w - 5, cell.y + 2, 3, 3, 1, 1, 1, 1) end
        -- Its producers, in their colour.
        local producer = cell.producer
        if producer then self:drawRect(cell.x + cell.w - 5, cell.y + cell.h - 5, 3, 3, 1, producer[1], producer[2], producer[3]) end
        local shade = cell.arrow and (cell.enabled and 1 or 0.35) or current and 1 or cell.far and 0.4 or 0.75 + 0.25 * k
        self:drawTextCentre(cell.text, cell.x + cell.w / 2, cell.y + 1, 1, 1, 1, shade, UIFont.Small)
    end
    self:drawLegend(now, mx, my, px)
    -- The status line; a text too long for it shows whole in a tooltip at the mouse instead (measured once a text).
    local status = self.status or (self.data and self.data.zoneEdit and getText("IGUI_BU_ZoneHint"))
        or (self.data and self.data.pipePaint and getText("IGUI_BU_PlanPipeHint"))
    local long = false
    if status then
        if status ~= self.statusText or self.statusEra ~= UI.era or self.statusW ~= self.width then
            self.statusText, self.statusEra, self.statusW = status, UI.era, self.width
            self.statusLong = UI.textWidth(status) > self.width - PAD * 2
        end
        long = self.statusLong
        if not long then self:drawText(status, PAD, self.height - FONT_HGT_SMALL - PAD, 1, 1, 1, 1, UIFont.Small) end
    end
    if long then
        PZUIRichTip.show(self, status, P)
        self.statusTipped = true
    elseif self.statusTipped then
        PZUIRichTip.hide(self)
        self.statusTipped = false
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

-- The thing under the mouse, for the plan and for the list: its dot or square (by its key), and its room.
function ISBUPlan:setHover(key, room)
    if key ~= self.hoverKey then self.window:outlineThing(key) end
    self.hoverKey, self.hoverRoom = key, room
    self.window.planHoverKey, self.window.planHoverRoom = key, room
end

function ISBUPlan:onMouseMove(dx, dy)
    local kind, thing = self:hit(self:getMouseX(), self:getMouseY())
    self:setHover((kind == "dot" or kind == "square") and thing.key or nil,
        (kind == "room" or kind == "dot") and thing.room or nil)
    self.hoverLine = (kind == "square" or kind == "dot") and thing.ref and self.lineByRef[thing.ref] or nil
    if kind == "dot" or kind == "square" then
        self.status = thing.text
    elseif kind == "room" then
        self.status = self.window:roomStatus(thing.room)
        local zone = self.data and self.data.zone and self.data.zone[thing.room]
        if zone and zone.state == "taken" then
            self.status = self.status .. "  (" .. getText("IGUI_BU_ZoneTaken", zone.owner or "") .. ")"
        elseif zone and zone.state == "free" then
            self.status = self.status .. "  (" .. getText("IGUI_BU_Legend_zoneFree") .. ")"
        elseif zone and zone.state == "far" then
            self.status = self.status .. "  (" .. (zone.note or getText("IGUI_BU_Legend_zoneFar")) .. ")"
        end
    elseif kind == "floor" and thing.arrow then
        self.status = getText("IGUI_BU_StripScroll")
    elseif kind == "floor" then
        self.status = BU.floorName(thing.level)
        if thing.supply then self.status = self.status .. "  (" .. getText("IGUI_BU_FloorWater_" .. thing.supply) .. ")" end
        local note = thing.far and self:farNote(thing.level)
        if note then self.status = self.status .. "  (" .. note .. ")" end
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "zone" then
        self.status = self.data.zoneNote
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "range" then
        self.status = getText("IGUI_BU_PlanRangeHint")
    elseif self:toggleAt(self:getMouseX(), self:getMouseY()) == "pipe" then
        self.status = getText("IGUI_BU_PlanPipeTip")
    elseif self:onLegendHeader(self:getMouseX(), self:getMouseY()) then
        self.status = getText(self:legendShown() and "IGUI_BU_LegendFold" or "IGUI_BU_LegendUnfold")
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
    self.switchedAt = getTimestampMs()
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

function ISBUPlan:onMouseDown(x, y)
    local toggle = self:toggleAt(x, y)
    if toggle and toggle ~= "title" then UI.flash(self, "t" .. toggle) end
    if self:onLegendHeader(x, y) then
        self:toggleLegend()
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
    elseif toggle == "scheme" then
        BU.PanelWindow.schemeShown = not BU.PanelWindow.schemeShown
        self:placeScheme()
        return true
    elseif toggle == "title" then
        return true
    elseif toggle == "pipe" then
        self.window:pipePaintMenu()
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
    if self.data and self.data.pipePaint and kind ~= "floor" then
        -- Putting a pipe on rooms: a room, or the room of a dot, takes it.
        if thing and thing.room then self.window:paintRoomPipe(thing.room) end
        return true
    end
    if kind == "floor" and thing.arrow then
        self:scrollStrip(thing.arrow * thing.page)
    elseif kind == "floor" then
        self:showFloor(thing.level)
    elseif (kind == "dot" or kind == "square") and thing.key then
        -- a device, a producer, a unit or a relay: its row
        self.window:showThing(thing.key)
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
    self:placeScheme()
end

-- The plan is the kit's: in design units (UI.lua).
UI.scaled(ISBUPlan, ISPanel)
