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

-- A place among candidates (a drop site's stake for a contract). cands: { { x, y, ... }, ... }. First the ones within
-- opts.exclusion (BASE_EXCLUSION by default) of the anchor are dropped (that is the base itself). Among the rest, one
-- inside the band at random; if none is, the one nearest to the band. When all are the base the farthest is used.
-- Returns the index and why: "band", "nearest" or "farthest".
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

-- The rooms of a plain building, one the authorities could take over without it being a place of its own: a house,
-- an office, a warehouse, a church, a school, a factory, a farm's barn. Not a shop, a restaurant, a gas station, a
-- bank, a bar, a police station, a clinic, a motel, a derelict or a site under construction, and none of the map's
-- own story houses (their rooms have names of their own).
Places.PLAIN_ROOMS = {}
for _, name in ipairs({
    -- a house's
    "bathroom", "bedroom", "bedroom4", "kidsbedroom", "livingroom", "kitchen", "diningroom", "dining", "closet",
    "laundry", "garage", "garagestorage", "attic", "balcony", "hall", "hallway", "corridor", "foyer", "stairwell",
    "storage", "empty", "emptyoutside", "room1", "elevator", "janitor",
    -- an office's, a warehouse's, a factory's
    "office", "officestorage", "breakroom", "lobby", "meetingroom", "storageunit", "warehouse", "factory",
    "factorystorage", "security", "changeroom", "lockerroom", "showers", "vacated",
    -- a church's, a school's
    "church", "officechurch", "lobbychurch", "classroom", "elementaryclassroom", "secondaryclassroom",
    "universityclassroom", "elementaryhall", "secondaryhall", "schoolstorage", "gym", "gymstorage", "schoolgymstorage",
    "recreation",
    -- a farm's
    "barn", "farmstorage", "shed",
}) do Places.PLAIN_ROOMS[name] = true end

-- The rooms that serve the others: a building's count of rooms leaves them out (a block of toilets is not a building
-- of many rooms).
Places.SERVICE_ROOMS = { bathroom = true, closet = true, janitor = true, laundry = true, elevator = true,
    stairwell = true, balcony = true, attic = true }

-- How many of a building's rooms (names, a list) are not SERVICE_ROOMS ones: the rooms a stage has to work with.
function Places.mainRooms(names)
    local n = 0
    for _, name in ipairs(names) do
        if not Places.SERVICE_ROOMS[name] then n = n + 1 end
    end
    return n
end

-- The rooms only a home has: a building with one is a house (a cabin of a living room, a kitchen and a bathroom has no
-- room the map names a bedroom).
Places.HOME_ROOMS = { bedroom = true, bedroom4 = true, kidsbedroom = true, livingroom = true }

-- Whether a building (its rooms' names, a list) is a house.
function Places.home(names)
    for _, name in ipairs(names) do
        if Places.HOME_ROOMS[name] then return true end
    end
    return false
end

-- The rooms of a building things were kept in: a row of lock-up garages, a self-storage's units, a shed, a barn. A
-- building mostly of these is no post, clinic or shelter (Places.pickSite takes it last): no one was taken in there.
-- (A self-storage has an office and a hall too; a house has a garage among more rooms.)
Places.STORE_ROOMS = { garage = true, garagestorage = true, storage = true, storageunit = true, shed = true,
    barn = true, farmstorage = true }

-- The rooms the map names for no use (a barn's loft): they say nothing of what a building was.
Places.EMPTY_ROOMS = { empty = true, emptyoutside = true }

-- Whether more than half the rooms of a building (names, a list) are STORE_ROOMS ones, its EMPTY_ROOMS left out.
function Places.mostlyStores(names)
    local n, counted = 0, 0
    for _, name in ipairs(names) do
        if Places.STORE_ROOMS[name] then n = n + 1 end
        if not Places.EMPTY_ROOMS[name] then counted = counted + 1 end
    end
    return n * 2 > counted
end

-- Whether a building is plain: every room of it (names, a list) is a plain one, and it is no diner: a kitchen in a
-- building that is no home is a place that fed people (a map may name a diner's rooms as a house's: room1, kitchen and
-- bathrooms).
function Places.plain(names)
    local kitchen = false
    for _, name in ipairs(names) do
        if not Places.PLAIN_ROOMS[name] then return false end
        if name == "kitchen" then kitchen = true end
    end
    if kitchen and not Places.home(names) then return false end
    return #names > 0
end

-- A story site among the map's buildings (SCENES.md 5 '장소 고르기'): the authorities took any building for a post, a
-- clinic, a shelter. `list` is the buildings that may be used, all in the band: { x, y, area, rooms (Places.mainRooms), home (a house:
-- Places.home), stores (Places.mostlyStores: lock-ups, a shed; taken last), dist (from the base) }. `want`:
--   "public"  a public building (a shop, a church, a warehouse, an office) of PUBLIC_ROOMS rooms or more, else a
--             house (its rooms: an inner one to lock, a hall), else a smaller public one (a garage of one room has no
--             room for a stage's roles);
--   "largest" the largest public building, else the largest house;
--   "near" / "far" a house in the inner or outer third of the band's houses by distance, else any house, else a public
--             building.
-- Returns the index, or nil when the list is empty.
Places.PUBLIC_ROOMS = 3

local function anyOf(pool, int)
    if #pool == 0 then return nil end
    return pool[int(1, #pool)]
end

local function largestOf(list, pool)
    local best
    for _, i in ipairs(pool) do
        if not best or list[i].area > list[best].area then best = i end
    end
    return best
end

function Places.pickSite(list, want, int)
    int = int or randomInt
    local public, roomy, homes, stores = {}, {}, {}, {}
    for i, b in ipairs(list) do
        if b.home then
            homes[#homes + 1] = i
        elseif b.stores then
            stores[#stores + 1] = i
        else
            public[#public + 1] = i
            if (b.rooms or 0) >= Places.PUBLIC_ROOMS then roomy[#roomy + 1] = i end
        end
    end
    if want == "largest" then return largestOf(list, public) or largestOf(list, homes) or largestOf(list, stores) end
    if want == "near" or want == "far" then
        if #homes == 0 then return anyOf(public, int) end
        table.sort(homes, function(a, b) return list[a].dist < list[b].dist end)
        local third = math.max(1, math.floor(#homes / 3))
        local from = want == "near" and 1 or #homes - third + 1
        return homes[int(from, from + third - 1)]
    end
    return anyOf(roomy, int) or anyOf(homes, int) or anyOf(public, int) or anyOf(stores, int)
end

-- How far the map circle's centre may be from the place, of the radius: the place is anywhere in the circle but its
-- outer ring (a building there still lies inside).
Places.CIRCLE_OFF = 0.7

-- The map circle: centre moved off the place so that the place is anywhere in the inner CIRCLE_OFF of the circle with
-- the same chance (the offset's square root of a uniform draw; a uniform offset keeps the place near the middle, and the
-- middle would tell it). Returns x, y, radius (squares).
function Places.circle(x, y, radius, float)
    float = float or OA.randomFloat
    local angle = float(0, 2 * math.pi)
    local off = radius * Places.CIRCLE_OFF * math.sqrt(float(0, 1))
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

-- Meteor drop sites (NUMBERS 6): `count` points in the ring from `lo` to `hi` squares around `origin` { x, y } (the
-- first character's start), at least `spacing` apart, each one passing accept(x, y) (the map has land there).
-- `existing` points stay. Where the ring is too crowded (water, town, the map's edge) the spacing relaxes by a tenth
-- every few hundred misses, down to a third, and then the ring widens outward, up to three times `hi`; past that it
-- gives up with what it has. Returns the list (existing + new).
function Places.ringSites(origin, count, lo, hi, spacing, accept, existing, int)
    int = int or randomInt
    local sites = {}
    for _, p in ipairs(existing or {}) do sites[#sites + 1] = p end
    local floor, far = spacing / 3, hi * 3
    local misses, total = 0, 0
    while #sites < count and total < 30000 do
        total = total + 1
        local a = math.rad(int(0, 359))
        local r = int(lo, math.floor(hi))
        local x = math.floor(origin.x + r * math.cos(a) + 0.5)
        local y = math.floor(origin.y + r * math.sin(a) + 0.5)
        if (not accept or accept(x, y)) and Places.farEnough(sites, x, y, spacing) then
            sites[#sites + 1] = { x = x, y = y }
            misses = 0
        else
            misses = misses + 1
            if misses >= 400 then
                misses = 0
                if spacing > floor then
                    spacing = math.max(floor, spacing * 0.9)
                elseif hi < far then
                    hi = math.min(far, hi * 1.25)
                end
            end
        end
    end
    return sites
end

-- The compass point (one of "N", "NE", "E", "SE", "S", "SW", "W", "NW") of a place seen from another. The game's y
-- grows to the south. nil when they are the same square.
local POINTS = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
function Places.bearing(ax, ay, x, y)
    local dx, dy = x - ax, y - ay
    if dx == 0 and dy == 0 then return nil end
    local angle = math.atan2(dy, dx)
    local sector = math.floor(angle / (math.pi / 4) + 0.5)
    if sector < 0 then sector = sector + 8 end
    if sector >= 8 then sector = sector - 8 end
    return POINTS[sector + 1]
end

-- Where a place is from the player, in words (DESIGN-terminal 6.5): "현재 위치에서 북동쪽 약 2.4km". A square counts as
-- a metre. Inside `radius` (a mission's area) the player is told so; under 100 m it is "close by"; then 50 m steps up to
-- a kilometre, 0.1 km steps up to 10 km, whole kilometres beyond. Returns the translation key and its arguments: the
-- compass point's key (translated by the caller) and the distance as a string.
function Places.whereKey(px, py, x, y, radius)
    local dx, dy = x - px, y - py
    local d = math.sqrt(dx * dx + dy * dy)
    if radius and d <= radius then return "IGUI_OA_Place_Inside", {} end
    if d < 100 then return "IGUI_OA_Place_Near", {} end
    local point = "IGUI_OA_Place_Dir_" .. Places.bearing(px, py, x, y)
    local metres = math.floor(d / 50 + 0.5) * 50
    if metres < 1000 then return "IGUI_OA_Place_Metres", { point, tostring(metres) } end
    local tenths = math.floor(d / 100 + 0.5)
    if tenths < 100 then return "IGUI_OA_Place_Km", { point, string.format("%.1f", tenths / 10) } end
    return "IGUI_OA_Place_Km", { point, tostring(math.floor(d / 1000 + 0.5)) }
end

-- The same as a text (the compass point translated too).
function Places.whereText(px, py, x, y, radius)
    local key, args = Places.whereKey(px, py, x, y, radius)
    if args[1] then return getText(key, getText(args[1]), args[2]) end
    return getText(key)
end

return Places
