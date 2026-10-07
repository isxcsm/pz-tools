-- Distances and directions between squares and buildings. Pure functions: no game calls.
require "BuildingUtilities/Core"
local Geometry = {}
BuildingUtilities.Geometry = Geometry

-- Steps from a square to the nearest square of a rectangle, a diagonal step counting as one (as buildings.near counts).
function Geometry.toRect(x, y, rect)
    local dx = 0
    if x < rect.x then dx = rect.x - x elseif x > rect.x + rect.w - 1 then dx = x - (rect.x + rect.w - 1) end
    local dy = 0
    if y < rect.y then dy = rect.y - y elseif y > rect.y + rect.h - 1 then dy = y - (rect.y + rect.h - 1) end
    return math.max(dx, dy)
end

-- The squares within range steps of rectangles, a diagonal step counting as one (as Geometry.toRect): { minX, minY, w,
-- h, cells (true by (y - minY) * w + (x - minX)) }, or nil without rectangles. The rectangles grown row by row, then
-- column by column. Kept by the rectangles and the range: a building's do not change while its range is shown, and
-- the plan and the world ask for the same.
local areas, areaCount = {}, 0
function Geometry.reach(rects, range)
    if #rects == 0 then return nil end
    local parts = { range }
    for _, rect in ipairs(rects) do parts[#parts + 1] = rect.x .. "," .. rect.y .. "," .. rect.w .. "," .. rect.h end
    local key = table.concat(parts, ";")
    if areas[key] then return areas[key] end
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
    if areaCount >= 16 then areas, areaCount = {}, 0 end
    areas[key] = { minX = minX, minY = minY, w = w, h = h, cells = cells }
    areaCount = areaCount + 1
    return areas[key]
end

-- The squares whose middle is within a radius of a square's middle, as the game measures how far a sound carries:
-- an area as Geometry.reach gives (and kept with those).
function Geometry.disc(x, y, radius)
    local key = "disc;" .. x .. "," .. y .. "," .. radius
    if areas[key] then return areas[key] end
    local w = radius * 2 + 1
    local cells = {}
    for row = 0, w - 1 do
        for col = 0, w - 1 do
            local dx, dy = col - radius, row - radius
            if dx * dx + dy * dy <= radius * radius then cells[row * w + col] = true end
        end
    end
    if areaCount >= 16 then areas, areaCount = {}, 0 end
    areas[key] = { minX = x - radius, minY = y - radius, w = w, h = w, cells = cells }
    areaCount = areaCount + 1
    return areas[key]
end

-- Whether a square is in an area of Geometry.reach.
function Geometry.reached(area, x, y)
    if not area then return false end
    local col, row = x - area.minX, y - area.minY
    return col >= 0 and row >= 0 and col < area.w and row < area.h and area.cells[row * area.w + col] == true
end

-- Whether a square of an area is on its edge: a neighbour across a side is out of it. These are the squares the
-- range reaches exactly.
function Geometry.onEdge(area, x, y)
    return Geometry.reached(area, x, y) and not (Geometry.reached(area, x - 1, y) and Geometry.reached(area, x + 1, y)
        and Geometry.reached(area, x, y - 1) and Geometry.reached(area, x, y + 1))
end

-- Steps from a square to a building's outline: its rooms on any level, as buildings.rooms lists them. 0 inside.
function Geometry.toBuilding(x, y, rooms)
    local best
    for _, room in ipairs(rooms) do
        for _, rect in ipairs(room.rects) do
            local steps = Geometry.toRect(x, y, rect)
            if not best or steps < best then best = steps end
        end
    end
    return best
end

-- Steps between two buildings' outlines.
function Geometry.betweenBuildings(roomsA, roomsB)
    local best
    for _, a in ipairs(roomsA) do
        for _, ra in ipairs(a.rects) do
            for _, b in ipairs(roomsB) do
                for _, rb in ipairs(b.rects) do
                    local dx = math.max(0, ra.x - (rb.x + rb.w - 1), rb.x - (ra.x + ra.w - 1))
                    local dy = math.max(0, ra.y - (rb.y + rb.h - 1), rb.y - (ra.y + ra.h - 1))
                    local steps = math.max(dx, dy)
                    if not best or steps < best then best = steps end
                end
            end
        end
    end
    return best
end

-- The centre of a building's lowest level, for directions.
function Geometry.centre(building)
    return (building.minX + building.maxX) / 2, (building.minY + building.maxY) / 2
end

-- One of eight compass points from one place to another; the game's north is -y and east is +x.
function Geometry.direction(fromX, fromY, toX, toY)
    local dx, dy = toX - fromX, toY - fromY
    if dx == 0 and dy == 0 then return nil end
    -- No % on negative numbers: Kahlua's differs from Lua's there.
    local angle = math.deg(math.atan2(dx, -dy))
    if angle < 0 then angle = angle + 360 end
    local index = math.floor((angle + 22.5) / 45)
    if index >= 8 then index = index - 8 end
    local points = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
    return points[index + 1]
end

return Geometry
