-- The towns (NUMBERS 7, 'Restock items'): a town searched through makes the shop restock sooner. Event-driven only:
-- nothing here runs on a tick.
--
-- The index. A town is a cluster of the map's TownZone zones with at least MIN_BUILDINGS buildings (the extension API's
-- zones.clusters, read once a world and kept in the world store). The world's `towns` section:
--   built (the index was read), list = { [town] = { n (its buildings), x1, y1, x2, y2, rects = { x, y, w, h ... } } },
--   of = { [building key] = town }, seen = { [key] = true } (the town buildings searched through, by any character),
--   found = { [town] = how many of them }, done = { [town] = true }, ndone.
-- A building's key is the API's (buildings.at) as text, which is the key the codex keeps (Codex.buildingSearched).
-- A basement is a building of its own to the API, so it counts in its town's total but is never searched under its own
-- key: the share of 90% leaves room for it.
--
-- A town is done for the world when its searched buildings reach SHARE of its buildings. A record takes the town's
-- share (Shop.townDone: the windows after the current one shorter) once: when its own search is the one that completes
-- the town, or later by coming into a town the world has done already (Towns.enter, asked about a position).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
local Towns = {}
OA.Towns = Towns

Towns.MIN_BUILDINGS = 20
Towns.SHARE = 0.9
Towns.CELL = 100        -- the coarse grid's cell, in squares
Towns.COLS = 4096       -- more cells than a map has in a row

local failed = false    -- the API could not give the towns this session: not asked again
local grid, gridOf      -- the cells the towns' rectangles touch (cx * COLS + cy -> towns), and the section it was made from

-- Forgets what was kept in memory (a new world, the tests).
function Towns.reset()
    failed, grid, gridOf = false, nil, nil
end

-- The world's towns section, with the index read from the API the first time: nil when it cannot be read.
function Towns.index()
    local w = OA.Store.world("towns")
    if w.built then return w end
    if failed then return nil end
    local api = OA.api()
    local zones = api and api.zones
    if not (zones and type(zones.clusters) == "function") then
        failed = true
        return nil
    end
    local ok, clusters = pcall(zones.clusters, "TownZone", { buildings = true })
    if not ok or type(clusters) ~= "table" then
        failed = true
        OA.log("towns not read:", tostring(clusters))
        return nil
    end
    w.list, w.of, w.seen, w.found, w.done, w.ndone = {}, {}, {}, {}, {}, 0
    for _, c in ipairs(clusters) do
        local keys = c.buildings or {}
        if #keys >= Towns.MIN_BUILDINGS then
            local town = #w.list + 1
            local rects = {}
            for i, v in ipairs(c.rects or {}) do rects[i] = v end
            w.list[town] = { n = #keys, x1 = c.x1, y1 = c.y1, x2 = c.x2, y2 = c.y2, rects = rects }
            for _, key in ipairs(keys) do w.of[tostring(key)] = town end
        end
    end
    w.built = true
    return w
end

-- The cells of the grid over the towns' rectangles.
local function cellsOf(w)
    if grid and gridOf == w then return grid end
    grid, gridOf = {}, w
    local cell = Towns.CELL
    for town, t in ipairs(w.list) do
        local r = t.rects
        for i = 1, #r - 3, 4 do
            for cx = math.floor(r[i] / cell), math.floor((r[i] + r[i + 2] - 1) / cell) do
                for cy = math.floor(r[i + 1] / cell), math.floor((r[i + 1] + r[i + 3] - 1) / cell) do
                    local key = cx * Towns.COLS + cy
                    local list = grid[key]
                    if not list then
                        list = {}
                        grid[key] = list
                    end
                    if list[#list] ~= town then list[#list + 1] = town end
                end
            end
        end
    end
    return grid
end

-- The town a position is in, or nil: the grid's cell names the candidates, their rectangles decide.
function Towns.at(w, x, y)
    local list = cellsOf(w)[math.floor(x / Towns.CELL) * Towns.COLS + math.floor(y / Towns.CELL)]
    for _, town in ipairs(list or {}) do
        local r = w.list[town].rects
        for i = 1, #r - 3, 4 do
            if x >= r[i] and x < r[i] + r[i + 2] and y >= r[i + 1] and y < r[i + 1] + r[i + 3] then return town end
        end
    end
    return nil
end

-- Tells the record its town came sooner restocking (told once a town, to a record that has met the team).
local function tell(record, sub)
    if not OA.Trust.contacted(record) then return end
    local ok, err = pcall(OA.Sync.title, record.id, { key = "IGUI_OA_Title_TownSearched", sub = sub, style = "discovery",
        fallback = "good" })
    if not ok then OA.log("title failed:", tostring(err)) end
end

-- The record takes the town's share; true when it was new to it.
local function take(record, town, sub)
    if not OA.Shop.townDone(record, town) then return false end
    tell(record, sub)
    return true
end

-- A building was searched through by a record for the first time (Codex.buildingSearched): it counts for its town, and
-- the town is done once it has SHARE of its buildings searched. The record that completes it takes its share.
function Towns.searched(record, key)
    local w = Towns.index()
    if not w then return end
    key = tostring(key)
    local town = w.of[key]
    if not town or w.seen[key] then return end
    w.seen[key] = true
    w.found[town] = (w.found[town] or 0) + 1
    if w.done[town] then
        take(record, town, "IGUI_OA_Title_TownSearchedSubKnown")
    elseif w.found[town] >= math.ceil(Towns.SHARE * w.list[town].n) then
        w.done[town] = true
        w.ndone = w.ndone + 1
        take(record, town, "IGUI_OA_Title_TownSearchedSub")
    end
end

-- A record's character is at (x, y): when that is in a town the world has done, the record takes its share. Cheap
-- (nothing at all while the world has done no town); the caller keeps it to a call a second.
function Towns.enter(record, x, y)
    local w = OA.Store.world("towns")
    if not w.built or (w.ndone or 0) == 0 then return false end
    local town = Towns.at(w, x, y)
    if not town or not w.done[town] then return false end
    local r = record.shop and record.shop.restock
    if r and r.towns[town] then return false end
    return take(record, town, "IGUI_OA_Title_TownSearchedSubKnown")
end

return Towns
