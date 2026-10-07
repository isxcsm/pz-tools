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
