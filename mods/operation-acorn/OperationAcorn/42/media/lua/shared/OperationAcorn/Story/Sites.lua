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
local OA = OperationAcorn
local Sites = {}
OA.Sites = Sites

Sites.COUNT = 3
Sites.RING_LO, Sites.RING_HI = 500, 1500
Sites.SPACING = 400
-- The layout's version: a world laid out before (24 sites over the whole map) has its sites taken away and is laid
-- out again (Sites.ensure).
Sites.VERSION = 2
-- The kinds of fragment, one site each, and the item each leaves (Story Data names). The kinds look different on the
-- ground too: how many squares the fall scorched round the middle (the stony one broke up and spread; the iron one
-- punched in).
Sites.KINDS = { "stony", "iron", "stonyIron" }
Sites.FRAGMENT = { stony = "MeteorFragment", iron = "MeteorFragmentIron", stonyIron = "MeteorFragmentStonyIron" }
Sites.SCORCH = { stony = 9, iron = 5, stonyIron = 7 }
-- Zone types a site never lies in (judged where the zones are known: B42 loads a cell's zones with the cell).
Sites.NOT = { TownZone = true, WaterZone = true, WaterFlow = true, Basement = true, TrailerPark = true, Nav = false }
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
    local sec = section()
    if sec.v ~= Sites.VERSION then return {} end
    return sec.list or {}
end

function Sites.byNumber(n)
    for _, site in ipairs(Sites.list()) do
        if site.n == n then return site end
    end
    return nil
end

-- The layout the sites are of (a number that changes when they are laid out again), or nil before there are any. A
-- record keeps the sites it has seen under it (Sites.seenOf).
function Sites.generation()
    local sec = section()
    return sec.v == Sites.VERSION and sec.gen or nil
end

-- The sites a record has been near (site number -> true) and the stakes it has read: emptied when the sites were laid
-- out again since.
function Sites.seenOf(record)
    local s = OA.Story.section(record)
    local gen = Sites.generation()
    if s.sitesGen ~= gen then
        s.sitesGen = gen
        s.sitesSeen = {}
        s.sitesSearched = {}
    end
    return s.sitesSeen
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

-- A map point that may hold a site: a cell of the drawn map, and no zone there that says town or water. B42 keeps a
-- cell's zones only once the cell has loaded, so far from the player there are mostly none: the land is then judged
-- when the site's chunk loads (Sites.onChunk), and a site that is not on land moves.
local function acceptPoint(x, y)
    local grid = getWorld():getMetaGrid()
    if not grid:getCellData(math.floor(x / CELL), math.floor(y / CELL)) then return false end
    local zones = grid:getZonesAt(x, y, 0)
    if zones then
        for i = 0, zones:size() - 1 do
            if Sites.NOT[zones:get(i):getType()] then return false end
        end
    end
    return true
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
-- The sites of the first layout (24 over the whole map, before VERSION 2): what was put down at them goes when their
-- chunk loads, and the work still waiting for them is dropped.

local oldSpriteSet

local function oldSprites()
    if not oldSpriteSet then
        oldSpriteSet = {}
        for _, name in ipairs({ OA.Sprites.SCORCHED_GROUND, OA.Sprites.METEOR_ROCKS, OA.Sprites.SITE_STAKE,
                                OA.Sprites.DAMP_SOIL, OA.Sprites.CUT_TAPE, OA.Sprites.SAMPLE_BAG, OA.Sprites.STONE_ROW }) do
            oldSpriteSet[name] = true
        end
    end
    return oldSpriteSet
end

-- Takes away the props and the fragments of an old site around x, y (its chunk is loaded).
function Sites.clearOld(x, y)
    local cell = getCell()
    local sprites = oldSprites()
    local fragment = OA.StoryData.fullType(Sites.FRAGMENT.stony)
    for dx = -4, 4 do
        for dy = -4, 4 do
            local sq = cell:getGridSquare(x + dx, y + dy, 0)
            if sq then
                local objects = sq:getObjects()
                for i = objects:size() - 1, 0, -1 do
                    local obj = objects:get(i)
                    local sprite = obj:getSprite() and obj:getSprite():getName()
                    local item = instanceof(obj, "IsoWorldInventoryObject") and obj:getItem()
                    if (sprite and sprites[sprite]) or (item and item:getFullType() == fragment) then
                        sq:transmitRemoveItemFromSquare(obj)
                    end
                end
            end
        end
    end
end

local function migrate(sec)
    OA.Chunks.remove(function(e) return e.kind == "oa_site" end)
    for _, site in ipairs(sec.list or {}) do
        if site.state == "placed" then
            local sq = getCell and getCell() and getCell():getGridSquare(site.x, site.y, 0)
            if sq then
                Sites.clearOld(site.x, site.y)
            else
                OA.Chunks.add({ kind = "oa_site_old", x = site.x, y = site.y, z = 0 })
            end
        end
    end
    OA.log("meteor sites: the first layout's", #(sec.list or {}), "sites taken away")
    sec.list, sec.made, sec.spacing = nil, nil, nil
end

OA.Chunks.handle("oa_site_old", function(entry)
    local ok, err = pcall(Sites.clearOld, entry.x, entry.y)
    if not ok then OA.log("old meteor site not cleared:", tostring(err)) end
    return true
end)

-- ---------------------------------------------------------------------------------------------------------------
-- Laying them out.

-- Decides the sites around `origin` { x, y } (the first character's place), once a world. Returns the list, or nil
-- while there is no origin yet (the caller asks again later).
function Sites.ensure(origin, accept, int)
    local sec = section()
    if sec.v == Sites.VERSION and sec.made then return sec.list end
    if sec.made and sec.v ~= Sites.VERSION then migrate(sec) end
    if not (origin and origin.x and origin.y) then return nil end
    int = int or OA.random
    local points = OA.Places.ringSites(origin, Sites.COUNT, Sites.RING_LO, Sites.RING_HI, Sites.SPACING,
        accept or acceptPoint, nil, int)
    local kinds = shuffled(Sites.KINDS, #points, int)
    local dates = {}
    for i = 1, Sites.DATES do dates[i] = i end
    dates = shuffled(dates, #points, int)
    sec.v = Sites.VERSION
    sec.gen = (sec.gen or 0) + 1
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
    local points = OA.Places.ringSites(sec.origin, #others + 1, Sites.RING_LO, Sites.RING_HI, Sites.SPACING,
        accept or acceptPoint, others, int)
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
        OA.Sync.title(record.id, { key = "IGUI_OA_Title_Site", sub = "IGUI_OA_Title_SiteSub", style = "discovery",
            fallback = "good" })
    end
    return changed
end

-- ---------------------------------------------------------------------------------------------------------------
-- In the game: when a site's chunk loads.

local function isLand(sq)
    if not sq then return false end
    if sq:getBuilding() or not sq:isOutside() then return false end
    -- the square's cell is loaded, so are its zones: no town, no water
    local zones = getWorld():getMetaGrid():getZonesAt(sq:getX(), sq:getY(), 0)
    if zones then
        for i = 0, zones:size() - 1 do
            if Sites.NOT[zones:get(i):getType()] then return false end
        end
    end
    if not sq:isFree(false) or not sq:TreatAsSolidFloor() or sq:HasTree() then return false end
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

-- The squares round the middle the fall scorched, nearest first.
local SCORCH_AROUND = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }

-- The props and the fragment of one site at the chosen square.
local function build(site, sq)
    local c = getCell()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for i = 1, Sites.SCORCH[site.kind] or 5 do
        local o = SCORCH_AROUND[i]
        local s = c:getGridSquare(x + o[1], y + o[2], z)
        if s and s:isOutside() and not s:getBuilding() then addObject(s, OA.Sprites.SCORCHED_GROUND) end
    end
    addObject(sq, OA.Sprites.METEOR_ROCKS, { OA_Site = site.n })
    local stakeSq
    for _, o in ipairs({ { 2, 0 }, { 0, 2 }, { -2, 0 }, { 0, -2 } }) do
        local s = c:getGridSquare(x + o[1], y + o[2], z)
        if isLand(s) then stakeSq = s break end
    end
    stakeSq = stakeSq or sq
    addObject(stakeSq, OA.Sprites.SITE_STAKE, { OA_Site = site.n, OA_StakeNo = site.stake, OA_StakeDate = site.date })
    -- What someone left: each on its own land square 2 to 4 out from the middle, not the stake's.
    local ring = {}
    for dx = -4, 4 do
        for dy = -4, 4 do
            if math.max(math.abs(dx), math.abs(dy)) >= 2 then ring[#ring + 1] = { dx, dy } end
        end
    end
    for _, kind in ipairs(Sites.propKinds()) do
        local s
        while not s and #ring > 0 do
            local o = table.remove(ring, OA.random(1, #ring))
            local cand = c:getGridSquare(x + o[1], y + o[2], z)
            if cand ~= stakeSq and isLand(cand) then s = cand end
        end
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
    if item then pcall(function() item:getWorldItem():setIgnoreRemoveSandbox(true) end) end
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
