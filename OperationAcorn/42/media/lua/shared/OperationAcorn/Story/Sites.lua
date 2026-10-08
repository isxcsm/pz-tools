-- The meteor drop sites (DESIGN 3, NUMBERS 6, LORE 2 and 7). Where they are is decided once, when the world is first
-- opened: 24 times the MeteorSites option of them, over the whole map, more than 300 squares apart, in the world
-- section "sites". Whether a place is really land is found out when its chunk first loads (never by scanning squares):
-- a place that is not gets a new one elsewhere. A site then gets its props (scorched ground, rocks, a survey stake with
-- its number and a date) and 1 to 3 meteorite fragments numbered by the stake, all through OA.Chunks. No sound is
-- changed around a site (FEASIBILITY: visual clues only).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Chunks"
require "OperationAcorn/Sprites"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
local OA = OperationAcorn
local Sites = {}
OA.Sites = Sites

Sites.COUNT = 24
Sites.SPACING = 300
-- Zone types the map gives land its outdoors: a site may start in these, never in a town or on water.
Sites.LAND = { Forest = true, DeepForest = true, Vegitation = true, FarmLand = true, Ranch = true, Farm = true }
Sites.NOT = { TownZone = true, WaterZone = true, WaterFlow = true, Basement = true, TrailerPark = true, Nav = false }
Sites.DATES = 8
Sites.MAX_RETRIES = 12

local function section()
    return OA.Store.world("sites")
end

-- The sites, in number order: { { n =, x =, y =, stake =, date =, state = "pending" | "placed" | "failed" } }.
function Sites.list()
    return section().list or {}
end

function Sites.byNumber(n)
    for _, site in ipairs(Sites.list()) do
        if site.n == n then return site end
    end
    return nil
end

-- How many sites a world gets.
function Sites.count()
    local scale = OA.option("MeteorSites") or 1
    return math.max(0, OA.round(Sites.COUNT * scale))
end

-- The fragments one site holds: 1 to 3, multiplied by 1 plus the upgrade bonus (눈썰미 and the research board; +0.5
-- is half as many again), rounded at random so that the expectation is kept.
function Sites.fragmentCount(bonus, int, float)
    int = int or OA.random
    float = float or OA.randomFloat
    local base = int(1, 3)
    local expected = base * (1 + (bonus or 0))
    local whole = math.floor(expected)
    if float(0, 1) < expected - whole then whole = whole + 1 end
    return whole
end

-- The best fragment bonus among the records (the site is the world's, the fragments are placed once).
function Sites.bestBonus()
    local best = 0
    if not (OA.Upgrades and OA.Upgrades.fragmentBonus) then return 0 end
    for _, record in pairs(OA.Store.players()) do
        local ok, bonus = pcall(OA.Upgrades.fragmentBonus, record)
        if ok and type(bonus) == "number" and bonus > best then best = bonus end
    end
    return best
end

-- A map point that may hold a site: the map has land there (decided by zones, not by squares).
local function acceptPoint(x, y)
    local grid = getWorld():getMetaGrid()
    if not grid:isValidSquare(x, y) then return false end
    local zones = grid:getZonesAt(x, y, 0)
    if not zones then return false end
    local land = false
    for i = 0, zones:size() - 1 do
        local t = zones:get(i):getType()
        if Sites.NOT[t] then return false end
        if Sites.LAND[t] then land = true end
    end
    return land
end

-- The map's extent in squares: the metagrid reports cells (or squares, when a version says so).
function Sites.bounds()
    local grid = getWorld():getMetaGrid()
    local size = 256
    local minX, minY, maxX, maxY = grid:getMinX(), grid:getMinY(), grid:getMaxX(), grid:getMaxY()
    if maxX < 2000 then
        return { minX = minX * size, minY = minY * size, maxX = (maxX + 1) * size - 1, maxY = (maxY + 1) * size - 1 }
    end
    return { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

local function register(site)
    OA.Chunks.add({ kind = "oa_site", site = site.n, x = site.x, y = site.y, z = 0 })
end

-- A new site's marks: a stake number nobody else has, and the date on the stake.
local function newMarks(list)
    local taken = {}
    for _, s in ipairs(list) do taken[s.stake or 0] = true end
    local stake
    repeat stake = OA.random(101, 987) until not taken[stake]
    return stake, OA.random(1, Sites.DATES)
end

-- Decides the sites, once. Returns the list.
function Sites.ensure(bounds, accept)
    local sec = section()
    if sec.made then return sec.list end
    bounds = bounds or Sites.bounds()
    local points, spacing = OA.Places.layoutSites(bounds, Sites.count(), Sites.SPACING, accept or acceptPoint, nil)
    sec.list = {}
    sec.spacing = spacing
    for i, p in ipairs(points) do
        local stake, date = newMarks(sec.list)
        local site = { n = i, x = p.x, y = p.y, stake = stake, date = date, state = "pending", tries = 0 }
        sec.list[#sec.list + 1] = site
        register(site)
    end
    sec.made = true
    OA.log("meteor sites:", #sec.list, "spacing", spacing)
    return sec.list
end

-- A site whose place is not land gets a new place elsewhere, as far from the others as the rest are from each other.
function Sites.replace(site, bounds, accept, int)
    local sec = section()
    site.tries = (site.tries or 0) + 1
    if site.tries > Sites.MAX_RETRIES then
        site.state = "failed"
        return false
    end
    local others = {}
    for _, s in ipairs(sec.list) do
        if s ~= site then others[#others + 1] = { x = s.x, y = s.y } end
    end
    local points = OA.Places.layoutSites(bounds or Sites.bounds(), #others + 1, sec.spacing or Sites.SPACING,
        accept or acceptPoint, others, int)
    local p = points[#points]
    if #points <= #others then
        site.state = "failed"
        return false
    end
    site.x, site.y = p.x, p.y
    return true
end

-- Has the player been near a site (within `range`): the soil sample mission may then use it.
function Sites.visit(record, x, y, range)
    local s = OA.Story.section(record)
    local changed = false
    for _, site in ipairs(Sites.list()) do
        if site.state == "placed" and not s.sitesSeen[site.n]
            and OA.Places.distance(x, y, site.x, site.y) <= (range or 80) then
            s.sitesSeen[site.n] = true
            changed = true
        end
    end
    return changed
end

-- ---------------------------------------------------------------------------------------------------------------
-- In the game: when a site's chunk loads.

local function isLand(sq)
    if not sq then return false end
    if sq:getBuilding() or not sq:isOutside() then return false end
    if not sq:isFree(false) or not sq:TreatAsSolidFloor() then return false end
    local ok, water = pcall(function() return sq:isWaterSquare() end)
    if ok and water then return false end
    local floor = sq:getFloor()
    local sprite = floor and floor:getSprite() and floor:getSprite():getName() or ""
    if string.find(sprite, "street", 1, true) or string.find(sprite, "road", 1, true) or string.find(sprite, "water", 1, true) then
        return false
    end
    return true
end

local function addObject(sq, spriteName, modData)
    local ok, obj = pcall(function()
        local o = IsoObject.new(getCell(), sq, spriteName)
        sq:AddTileObject(o)
        return o
    end)
    if not ok or not obj then
        OA.log("cannot add", spriteName, "(", tostring(obj), ")")
        return nil
    end
    if modData then
        local md = obj:getModData()
        for k, v in pairs(modData) do md[k] = v end
    end
    if isServer() then obj:transmitCompleteItemToClients() end
    return obj
end

-- The props and fragments of one site at the chosen square.
local function build(site, sq, chunkSquare)
    local c = getCell()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    -- Scorched ground over a few squares around the middle.
    local offsets = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 } }
    for i, o in ipairs(offsets) do
        if i <= 4 or OA.random(1, 2) == 1 then
            local s = c:getGridSquare(x + o[1], y + o[2], z)
            if s and s:isOutside() and not s:getBuilding() then addObject(s, OA.Sprites.SCORCHED_GROUND) end
        end
    end
    addObject(sq, OA.Sprites.METEOR_ROCKS, { OA_Site = site.n })
    local stakeSq
    for _, o in ipairs({ { 2, 0 }, { 0, 2 }, { -2, 0 }, { 0, -2 } }) do
        local s = c:getGridSquare(x + o[1], y + o[2], z)
        if isLand(s) then stakeSq = s break end
    end
    stakeSq = stakeSq or sq
    addObject(stakeSq, OA.Sprites.SITE_STAKE, { OA_Site = site.n, OA_StakeNo = site.stake, OA_StakeDate = site.date })
    local count = Sites.fragmentCount(Sites.bestBonus())
    site.fragments = count
    for _ = 1, count do
        local item = sq:AddWorldInventoryItem(OA.StoryData.fullType("MeteorFragment"), 0.2 + OA.randomFloat(0, 0.6),
            0.2 + OA.randomFloat(0, 0.6), 0)
        if item then
            item:getModData().OA_Stake = site.stake
            item:setName(getText("IGUI_OA_Story_FragmentName", site.stake))
            item:setCustomName(true)
            pcall(function() item:getWorldItem():setIgnoreRemoveSandbox(true) end)
        end
    end
end

-- LoadChunk work: the chunk of a pending site loaded. A land square near the site's point is looked for in the
-- chunk; none means the point was not land and the site moves.
function Sites.onChunk(entry, chunk)
    local site = Sites.byNumber(entry.site)
    if not site or site.state ~= "pending" then return true end
    local sq
    local start = OA.random(0, 63)
    for i = 0, 63 do
        local idx = OA.remainder(start + i, 64)
        local s = chunk:getGridSquare(idx % 8, math.floor(idx / 8), 0)
        if isLand(s) then
            -- A bit of open ground around it: the middle must have free neighbours.
            if isLand(getCell():getGridSquare(s:getX() + 1, s:getY(), 0)) and isLand(getCell():getGridSquare(s:getX(), s:getY() + 1, 0)) then
                sq = s
                break
            end
        end
    end
    if sq then
        site.x, site.y = sq:getX(), sq:getY()
        build(site, sq)
        site.state = "placed"
        OA.log("meteor site", site.n, "placed at", site.x, site.y, "fragments", site.fragments)
        OA.Sync.changed("sites", nil)
        return true
    end
    if Sites.replace(site) then
        register(site)
        OA.log("meteor site", site.n, "was not land, moved to", site.x, site.y)
    else
        OA.log("meteor site", site.n, "dropped")
    end
    return true
end

OA.Chunks.handle("oa_site", function(entry, chunk)
    local ok, done = pcall(Sites.onChunk, entry, chunk)
    if not ok then
        OA.log("meteor site failed:", tostring(done))
        return true
    end
    return done
end)

return Sites
