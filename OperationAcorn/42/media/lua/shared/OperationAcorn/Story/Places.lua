-- Where things go (NUMBERS 9, 6; DESIGN 9, 3): which building a mission item goes in, which of a story mission's
-- candidate places is used, where the map circle sits, and where the meteor drop sites are. Pure: places are tables
-- { x, y } and the choices take the numbers they need, so tests need no map.
require "OperationAcorn/Core"
require "OperationAcorn/Story/Rewards"
local OA = OperationAcorn
local Places = {}
OA.Places = Places

-- Random numbers by the mod's own functions unless a test passes its own: int(a, b) both included, float(a, b).
local function randomInt(a, b) return OA.random(a, b) end

function Places.distance(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- How far a distance is outside the band (0 inside it).
function Places.bandGap(d, lo, hi)
    if d < lo then return lo - d end
    if d > hi then return d - hi end
    return 0
end

-- A building for a regular mission: one inside the band around the anchor (the terminal), at random. at(i) gives the
-- i-th building's x, y and whether it may be used (nil counts as yes); count is how many there are. The map has
-- thousands of buildings and the band holds a small part, so random picks come first and a scan over all of them only
-- when those miss. When nothing lies in the band the one nearest to it is taken. Returns the index, or nil.
function Places.pickBuilding(count, at, anchorX, anchorY, lo, hi, tries, int)
    int = int or randomInt
    if count <= 0 then return nil end
    for _ = 1, tries or 300 do
        local i = int(1, count)
        local x, y, ok = at(i)
        if x and ok ~= false then
            local d = Places.distance(x, y, anchorX, anchorY)
            if d >= lo and d <= hi then return i end
        end
    end
    -- A scan: reservoir sampling keeps one of the buildings in the band without a list; the nearest outside it is
    -- kept as the answer when there is none inside.
    local inBand, chosen = 0, nil
    local nearest, nearestGap = nil, nil
    for i = 1, count do
        local x, y, ok = at(i)
        if x and ok ~= false then
            local d = Places.distance(x, y, anchorX, anchorY)
            local gap = Places.bandGap(d, lo, hi)
            if gap == 0 then
                inBand = inBand + 1
                if int(1, inBand) == 1 then chosen = i end
            elseif not nearestGap or gap < nearestGap then
                nearest, nearestGap = i, gap
            end
        end
    end
    return chosen or nearest
end

-- A story mission's place among its candidates (NUMBERS 9). cands: { { x, y, ... }, ... }. First the ones within
-- BASE_EXCLUSION of the anchor are dropped (that is the base itself). Among the rest, one inside the band at random;
-- if none is, the one nearest to the band; a choice mission's far candidate (opts.ignoreBand) skips the band and any
-- of the rest is taken. When all are the base the farthest is used. Returns the index and why:
-- "band", "nearest", "any" or "farthest".
function Places.pickCandidate(cands, anchorX, anchorY, lo, hi, opts, int)
    opts = opts or {}
    int = int or randomInt
    local exclusion = opts.exclusion or OA.Rewards.BASE_EXCLUSION
    local pool, all = {}, {}
    for i, c in ipairs(cands) do
        if not c.closed then
            all[#all + 1] = i
            if Places.distance(c.x, c.y, anchorX, anchorY) >= exclusion then pool[#pool + 1] = i end
        end
    end
    if #all == 0 then return nil end
    if #pool == 0 then
        local best, bestD = nil, -1
        for _, i in ipairs(all) do
            local d = Places.distance(cands[i].x, cands[i].y, anchorX, anchorY)
            if d > bestD then best, bestD = i, d end
        end
        return best, "farthest"
    end
    if opts.ignoreBand then return pool[int(1, #pool)], "any" end
    local inside = {}
    for _, i in ipairs(pool) do
        local d = Places.distance(cands[i].x, cands[i].y, anchorX, anchorY)
        if d >= lo and d <= hi then inside[#inside + 1] = i end
    end
    if #inside > 0 then return inside[int(1, #inside)], "band" end
    local best, bestGap, bestD
    for _, i in ipairs(pool) do
        local d = Places.distance(cands[i].x, cands[i].y, anchorX, anchorY)
        local gap = Places.bandGap(d, lo, hi)
        if not bestGap or gap < bestGap or (gap == bestGap and d < bestD) then best, bestGap, bestD = i, gap, d end
    end
    return best, "nearest"
end

-- The map circle: centre moved off the place by up to a third of the radius, so that the building is somewhere in
-- the circle and not in its middle. Returns x, y, radius (squares).
function Places.circle(x, y, radius, float)
    float = float or OA.randomFloat
    local angle = float(0, 2 * math.pi)
    local off = float(0, radius / 3)
    return math.floor(x + math.cos(angle) * off + 0.5), math.floor(y + math.sin(angle) * off + 0.5), radius
end

-- A circle radius that fits a band: nearer places get a tighter circle (a base 60 squares, up to 100).
function Places.circleRadius(level)
    return 50 + 10 * math.min(level or 1, 5)
end

-- Is the point at least `spacing` from every point in the list.
function Places.farEnough(list, x, y, spacing)
    for _, p in ipairs(list) do
        if Places.distance(p.x, p.y, x, y) < spacing then return false end
    end
    return true
end

-- Meteor drop sites (NUMBERS 6): `count` points over the map's bounds { minX, minY, maxX, maxY } (squares), at least
-- `spacing` apart, each one passing accept(x, y) (the map has land there). `existing` points stay. A map too small
-- or crowded for the spacing relaxes it by a tenth every few hundred misses, down to a third, then gives up with what
-- it has. Returns the list (existing + new) and the spacing used.
function Places.layoutSites(bounds, count, spacing, accept, existing, int)
    int = int or randomInt
    local sites = {}
    for _, p in ipairs(existing or {}) do sites[#sites + 1] = p end
    local floor = spacing / 3
    local misses = 0
    local total = 0
    while #sites < count and total < 30000 do
        total = total + 1
        local x = int(bounds.minX, bounds.maxX)
        local y = int(bounds.minY, bounds.maxY)
        if (not accept or accept(x, y)) and Places.farEnough(sites, x, y, spacing) then
            sites[#sites + 1] = { x = x, y = y }
            misses = 0
        else
            misses = misses + 1
            if misses >= 400 and spacing > floor then
                spacing = math.max(floor, spacing * 0.9)
                misses = 0
            end
        end
    end
    return sites, spacing
end

return Places
