-- What is near a player: the boxes whose network (the box, its lines and what hangs on them) comes within RADIUS
-- squares of one, and the units there. Near, a box is "hot": its minute's work runs every minute and its objects show
-- what changed; far, it is "cold" and the server runs it now and then (Server.lua), as nothing about it changes then
-- but time. Worked out of a grid of CELL squares kept while the lines, the boxes and the units are the same
-- (Store.linkVersion), so a minute asks only the cells about the players, not every box.
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Store = BU.Store
local Nearby = {}
BU.Nearby = Nearby

-- About the squares the game keeps loaded about a player, and some more.
Nearby.RADIUS = 80
local CELL = 128

local token, panelCells, unitCells, bounds = nil, {}, {}, {}

local function cellOf(x, y) return math.floor(x / CELL) .. "," .. math.floor(y / CELL) end

local function index()
    local now = Store.linkVersion()
    if token == now then return end
    token, panelCells, unitCells, bounds = now, {}, {}, {}
    -- Each box's bounds: its square, and both ends of each of its lines.
    for _, panel in ipairs(Store.list()) do
        bounds[panel.id] = { panel.x, panel.y, panel.x, panel.y, panel = panel }
    end
    for _, line in pairs(BU.Links.all()) do
        local box = line.panel and bounds[line.panel]
        if box then
            local wx, wy = line.x, line.y
            if line.wall then wx, wy = BU.parsePlace(line.wall) end
            box[1] = math.min(box[1], line.x, wx or line.x)
            box[2] = math.min(box[2], line.y, wy or line.y)
            box[3] = math.max(box[3], line.x, wx or line.x)
            box[4] = math.max(box[4], line.y, wy or line.y)
        end
    end
    for _, box in pairs(bounds) do
        local seen = {}
        for cx = math.floor((box[1] - Nearby.RADIUS) / CELL), math.floor((box[3] + Nearby.RADIUS) / CELL) do
            for cy = math.floor((box[2] - Nearby.RADIUS) / CELL), math.floor((box[4] + Nearby.RADIUS) / CELL) do
                local key = cx .. "," .. cy
                if not seen[key] then
                    seen[key] = true
                    panelCells[key] = panelCells[key] or {}
                    table.insert(panelCells[key], box)
                end
            end
        end
    end
    for _, unit in ipairs(Store.unitList()) do
        local key = cellOf(unit.x, unit.y)
        unitCells[key] = unitCells[key] or {}
        table.insert(unitCells[key], unit)
    end
end

-- Where the players are: { { x, y } }; the server's players in multiplayer, the local ones else.
function Nearby.players()
    local result = {}
    local online = isServer() and getOnlinePlayers and getOnlinePlayers()
    if online then
        for i = 0, online:size() - 1 do
            local player = online:get(i)
            result[#result + 1] = { player:getX(), player:getY() }
        end
        return result
    end
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player then result[#result + 1] = { player:getX(), player:getY() } end
    end
    return result
end

-- The hot boxes, by id, and their list: those whose bounds come within RADIUS of a player. players: Nearby.players().
function Nearby.hotPanels(players)
    index()
    local set, list = {}, {}
    for _, at in ipairs(players or Nearby.players()) do
        local px, py = at[1], at[2]
        for _, box in ipairs(panelCells[cellOf(px, py)] or {}) do
            local id = box.panel.id
            if not set[id] and px >= box[1] - Nearby.RADIUS and px <= box[3] + Nearby.RADIUS
                    and py >= box[2] - Nearby.RADIUS and py <= box[4] + Nearby.RADIUS then
                set[id] = true
                list[#list + 1] = box.panel
            end
        end
    end
    return set, list
end

-- The units within RADIUS of a player (each once).
function Nearby.units(players)
    index()
    local result, seen = {}, {}
    local reach = math.ceil(Nearby.RADIUS / CELL)
    for _, at in ipairs(players or Nearby.players()) do
        local cx, cy = math.floor(at[1] / CELL), math.floor(at[2] / CELL)
        for x = cx - reach, cx + reach do
            for y = cy - reach, cy + reach do
                for _, unit in ipairs(unitCells[x .. "," .. y] or {}) do
                    if not seen[unit] and math.abs(unit.x - at[1]) <= Nearby.RADIUS
                            and math.abs(unit.y - at[2]) <= Nearby.RADIUS then
                        seen[unit] = true
                        result[#result + 1] = unit
                    end
                end
            end
        end
    end
    return result
end

return Nearby
