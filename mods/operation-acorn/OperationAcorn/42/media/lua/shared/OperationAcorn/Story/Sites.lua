-- The meteor drop sites (DESIGN 3, NUMBERS 6, LORE 2 and 7). Three of them, decided once, when the first character
-- has a place in the world: in the ring of RING_LO to RING_HI squares around where it started, SPACING apart, so that
-- wherever a game starts the three are about as far (the capstones need them). Each holds one meteorite fragment of
-- its own kind, and each kind opens one tree's capstone (Upgrades Data.FRAGMENTS). They are kept in the world section
-- "sites". Whether a place is really land is found out when its chunk first loads (never by scanning squares): a
-- place that is not gets a new one in the ring. A site then gets its props (scorched ground, rocks, a survey stake with
-- its number and a date, and round them 2 or 3 things someone left) and its fragment, all through OA.Chunks. No sound
-- is changed around a site and nothing there gives light (FEASIBILITY: visual clues only).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Chunks"
require "OperationAcorn/Sprites"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Game"
local OA = OperationAcorn
local Game = OA.StoryGame
local Sites = {}
OA.Sites = Sites

Sites.COUNT = 3
Sites.RING_LO, Sites.RING_HI = 500, 1500
Sites.SPACING = 400
-- The kinds of fragment, one site each, and the item each leaves (Story Data names). The kinds look different on the
-- ground too: how many squares the fall scorched round the middle (the stony one broke up and spread; the iron one
-- punched in).
Sites.KINDS = { "stony", "iron", "stonyIron" }
Sites.FRAGMENT = { stony = "MeteorFragment", iron = "MeteorFragmentIron", stonyIron = "MeteorFragmentStonyIron" }
Sites.SCORCH = { stony = 9, iron = 5, stonyIron = 7 }
-- Zone types a site never lies in (judged where the zones are known: B42 loads a cell's zones with the cell).
Sites.NOT = { "TownZone", "WaterZone", "WaterFlow", "Basement", "TrailerPark" }
Sites.DATES = 8
Sites.MAX_RETRIES = 12
-- What someone left round a site (LORE 7, story-improvements 10), 2 or 3 of them: dark soil that looks wet, a second
-- stake with another date, a cut length of marker tape, an empty sample bag, stones laid in a row.
Sites.PROPS = { "soil", "stake", "tape", "bag", "stones" }
Sites.PROP_SPRITES = { soil = OA.Sprites.DAMP_SOIL, tape = OA.Sprites.CUT_TAPE, bag = OA.Sprites.SAMPLE_BAG,
                       stones = OA.Sprites.STONE_ROW }

local function section()
    return OA.Store.world("sites")
end

-- The sites, in number order: { { n =, x =, y =, kind =, stake =, date =, state = "pending" | "placed" | "failed" } }.
function Sites.list()
    return section().list or {}
end

function Sites.byNumber(n)
    for _, site in ipairs(Sites.list()) do
        if site.n == n then return site end
    end
    return nil
end

-- The sites a record has been near (site number -> true).
function Sites.seenOf(record)
    return OA.Story.section(record).sitesSeen
end

-- The things left round a site: 2 or 3 different kinds of Sites.PROPS.
function Sites.propKinds(int)
    int = int or OA.random
    local pool = {}
    for i, kind in ipairs(Sites.PROPS) do pool[i] = kind end
    local out = {}
    for _ = 1, int(2, 3) do out[#out + 1] = table.remove(pool, int(1, #pool)) end
    return out
end

-- A stake date other than the site's own (1 to DATES), for the second stake.
function Sites.otherDate(date, int)
    int = int or OA.random
    local d = int(1, Sites.DATES - 1)
    if d >= (date or 0) then d = d + 1 end
    return d
end

-- `n` different picks of a list, in a random order.
local function shuffled(list, n, int)
    local pool = {}
    for i, v in ipairs(list) do pool[i] = v end
    local out = {}
    for _ = 1, math.min(n, #pool) do out[#out + 1] = table.remove(pool, int(1, #pool)) end
    return out
end

-- The map's cell size in squares (B42).
local CELL = 256

-- A map point that may hold a site: a cell of the drawn map, and (drawPoint) no building and no zone there that says
-- town or water. B42 keeps a cell's zones only once the cell has loaded, so far from the player there are mostly none:
-- the land is then judged when the site's chunk loads (Sites.onChunk), and a site that is not on land moves.
local function acceptPoint(x, y)
    return getWorld():getMetaGrid():getCellData(math.floor(x / CELL), math.floor(y / CELL)) ~= nil
end

local SITE_POINTS = { count = 1, ["not"] = Sites.NOT }

-- A point of the ring lo to hi squares round x, y at random that may hold a site, or nil.
local function drawPoint(x, y, lo, hi)
    local p = OA.api().zones.points(x, y, lo, hi, SITE_POINTS)[1]
    if not p then return nil end
    return math.floor(p.x), math.floor(p.y)
end

-- Work for a site's square: done now when its chunk is loaded (LoadChunk will not come for it), else when it loads.
local function register(site)
    local entry = { kind = "oa_site", site = site.n, x = site.x, y = site.y, z = 0 }
    local sq = getCell and getCell() and getCell():getGridSquare(site.x, site.y, 0)
    if sq and sq:getChunk() then
        Sites.onChunk(entry, sq:getChunk())
    else
        OA.Chunks.add(entry)
    end
end

-- A new site's stake number: one nobody else has.
local function newStake(list, int)
    local taken = {}
    for _, s in ipairs(list) do taken[s.stake or 0] = true end
    local stake
    repeat stake = int(101, 987) until not taken[stake]
    return stake
end

-- ---------------------------------------------------------------------------------------------------------------
-- Laying them out.

-- Decides the sites around `origin` { x, y } (the first character's place), once a world. Returns the list, or nil
-- while there is no origin yet (the caller asks again later).
function Sites.ensure(origin, accept, int)
    local sec = section()
    if sec.made then return sec.list end
    if not (origin and origin.x and origin.y) then return nil end
    int = int or OA.random
    local draw
    if not accept then accept, draw = acceptPoint, drawPoint end
    local points = OA.Places.ringSites(origin, Sites.COUNT, Sites.RING_LO, Sites.RING_HI, Sites.SPACING, accept, nil, int,
        draw)
    local kinds = shuffled(Sites.KINDS, #points, int)
    local dates = {}
    for i = 1, Sites.DATES do dates[i] = i end
    dates = shuffled(dates, #points, int)
    sec.origin = { x = origin.x, y = origin.y }
    sec.list = {}
    for i, p in ipairs(points) do
        sec.list[i] = { n = i, x = p.x, y = p.y, kind = kinds[i], stake = newStake(sec.list, int), date = dates[i],
                        state = "pending", tries = 0 }
    end
    sec.made = true
    OA.log("meteor sites:", #sec.list, "around", origin.x, origin.y)
    for _, site in ipairs(sec.list) do register(site) end
    return sec.list
end

-- A site whose place is not land gets a new place in the ring, as far from the others as they are from each other.
function Sites.replace(site, accept, int)
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
    local draw
    if not accept then accept, draw = acceptPoint, drawPoint end
    local points = OA.Places.ringSites(sec.origin, #others + 1, Sites.RING_LO, Sites.RING_HI, Sites.SPACING, accept,
        others, int, draw)
    if #points <= #others then
        site.state = "failed"
        return false
    end
    local p = points[#points]
    site.x, site.y = p.x, p.y
    return true
end

-- Has the player been near a site (within `range`): the soil sample mission may then use it. A site seen for the first
-- time has a title (one, however many came into range at once).
function Sites.visit(record, x, y, range)
    local seen = Sites.seenOf(record)
    local changed = false
    for _, site in ipairs(Sites.list()) do
        if site.state == "placed" and not seen[site.n]
            and OA.Places.distance(x, y, site.x, site.y) <= (range or 80) then
            seen[site.n] = true
            changed = true
        end
    end
    if changed then
        OA.Sync.title(record.id, { key = "IGUI_OA_Title_Site", sub = "IGUI_OA_Title_SiteSub", style = "discovery" })
    end
    return changed
end

-- ---------------------------------------------------------------------------------------------------------------
-- In the game: when a site's chunk loads.

-- Land a site stands on: open natural ground (Game.GROUND) that is free, solid, bare of trees and in no town or water
-- zone (judged here: the square's cell is loaded, so are its zones).
local LAND = Game.groundWith({ free = true, solidFloor = true, tree = false, zonesNot = Sites.NOT })

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

-- The squares round the middle the fall scorched, nearest first.
local SCORCH_AROUND = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }

-- How many squares the fall of a kind scorched.
local function scorchOf(kind)
    return Sites.SCORCH[kind] or 5
end

-- What a site fits: its middle and the squares east and south of it land, and every square the fall scorched open ground
-- (it must not reach into a lake or onto a road). By kind.
local fits = {}
local function fitFor(kind)
    local parts = fits[kind or ""]
    if not parts then
        local scorched = {}
        for i = 1, scorchOf(kind) do
            scorched[#scorched + 1] = SCORCH_AROUND[i][1]
            scorched[#scorched + 1] = SCORCH_AROUND[i][2]
        end
        parts = { { offsets = { 0, 0, 1, 0, 0, 1 }, filter = LAND }, { offsets = scorched, filter = Game.GROUND } }
        fits[kind or ""] = parts
    end
    return parts
end

-- The anchors of a fit are tried in a random order.
local RANDOM_ORDER = { order = "random" }

-- The props and the fragment of one site at the chosen square.
local function build(site, sq)
    local c = getCell()
    local squares = OA.api().squares
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for i = 1, scorchOf(site.kind) do
        local o = SCORCH_AROUND[i]
        addObject(c:getGridSquare(x + o[1], y + o[2], z), OA.Sprites.SCORCHED_GROUND)
    end
    addObject(sq, OA.Sprites.METEOR_ROCKS, { OA_Site = site.n })
    local stakeSq = squares.nearest({ list = { x + 2, y, z, x, y + 2, z, x - 2, y, z, x, y - 2, z } }, LAND) or sq
    addObject(stakeSq, OA.Sprites.SITE_STAKE, { OA_Site = site.n, OA_StakeNo = site.stake, OA_StakeDate = site.date })
    -- What someone left: each on its own land square 2 to 4 out from the middle, not the stake's.
    local kinds = Sites.propKinds()
    local ring = {}
    for _, cand in ipairs(squares.list({ x = x, y = y, z = z, from = 2, to = 4 }, LAND, { random = #kinds + 1 })) do
        if cand ~= stakeSq then ring[#ring + 1] = cand end
    end
    for i, kind in ipairs(kinds) do
        local s = ring[i]
        if not s then break end
        if kind == "stake" then
            addObject(s, OA.Sprites.SITE_STAKE, { OA_Site = site.n, OA_StakeNo = site.stake,
                OA_StakeDate = Sites.otherDate(site.date) })
        else
            addObject(s, Sites.PROP_SPRITES[kind])
        end
    end
    local item = sq:AddWorldInventoryItem(OA.StoryData.fullType(Sites.FRAGMENT[site.kind]),
        0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), 0)
    if item then
        OA.try("sites: marking the fragment", function() item:getWorldItem():setIgnoreRemoveSandbox(true) end)
    end
end

-- LoadChunk work: the chunk of a pending site loaded. A land square in the chunk where the site fits (fitFor) is looked
-- for, one at random; none means the point was not land and the site moves.
function Sites.onChunk(entry, chunk)
    local site = Sites.byNumber(entry.site)
    if not site or site.state ~= "pending" then return true end
    local size = OA.Chunks.SIZE
    local x1, y1 = math.floor(entry.x / size) * size, math.floor(entry.y / size) * size
    local sq = OA.api().squares.fit({ x1 = x1, y1 = y1, x2 = x1 + size - 1, y2 = y1 + size - 1, z = 0 }, fitFor(site.kind),
        RANDOM_ORDER)
    if sq then
        site.x, site.y = sq:getX(), sq:getY()
        build(site, sq)
        site.state = "placed"
        OA.log("meteor site", site.n, site.kind, "placed at", site.x, site.y)
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
