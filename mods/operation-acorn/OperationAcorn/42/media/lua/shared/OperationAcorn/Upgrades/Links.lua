-- How a prerequisite's line runs on a tree's grid, without crossing a node: a pure function of the grid's cells, so
-- that the unit tests can check every link of the data. The research tab turns the waypoints into pixels.
--
-- A waypoint is { x = kind, c = column, y = kind, r = row }:
--   x "center": the middle of column c;  x "gutter": the gap right of column c (between c and c + 1).
--   y "bottom": the lower edge of row r; y "below": the middle of the gap under row r; y "top": the upper edge of row r.
require "OperationAcorn/Upgrades/Data"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Links = {}
OA.Upgrades.Links = Links

local function point(x, c, y, r) return { x = x, c = c, y = y, r = r } end

-- Whether no node of the tree stands in column c on the rows strictly between r1 and r2.
local function clear(cells, c, r1, r2)
    for r = r1 + 1, r2 - 1 do
        if cells[r .. "," .. c] then return false end
    end
    return true
end

-- The cells of a tree's nodes, as a set of "row,col".
function Links.cells(tree)
    local cells = {}
    for _, n in ipairs(Data.treeNodes(tree)) do cells[n.row .. "," .. n.col] = n.id end
    return cells
end

-- The line from the node at (c1, r1) down to the node at (c2, r2) (r2 > r1): its kind ("straight", "elbow" or
-- "gutter") and its waypoints, from the bottom of the first to the top of the second.
function Links.route(cells, c1, r1, c2, r2)
    local from, to = point("center", c1, "bottom", r1), point("center", c2, "top", r2)
    if c1 == c2 and clear(cells, c1, r1, r2) then
        return "straight", { from, to }
    end
    if clear(cells, c2, r1, r2) then
        return "elbow", { from, point("center", c1, "below", r1), point("center", c2, "below", r1), to }
    end
    -- down the gap beside the target's column, on the side the line comes from
    local g = (c1 < c2) and (c2 - 1) or c2
    return "gutter", {
        from, point("center", c1, "below", r1), point("gutter", g, "below", r1),
        point("gutter", g, "below", r2 - 1), point("center", c2, "below", r2 - 1), to,
    }
end

-- Every link of a tree: { from = id, to = id, need = { id, rank }, kind, points }.
function Links.tree(tree)
    local cells = Links.cells(tree)
    local list = {}
    for _, n in ipairs(Data.treeNodes(tree)) do
        for _, need in ipairs(n.req) do
            local other = Data.byId[need[1]]
            local kind, points = Links.route(cells, other.col, other.row, n.col, n.row)
            list[#list + 1] = { from = other.id, to = n.id, need = need, kind = kind, points = points }
        end
    end
    return list
end

return Links
