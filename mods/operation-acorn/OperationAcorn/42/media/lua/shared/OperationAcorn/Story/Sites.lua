-- The meteor drop sites (DESIGN 3, NUMBERS 6, LORE 2 and 7). Three of them, decided once, when the first character
-- has a place in the world: in the ring of RING_LO to RING_HI squares around where it started, SPACING apart, so that
-- wherever a game starts the three are about as far (the capstones need them). Each holds one meteorite fragment of
-- its own kind, and each kind opens one tree's capstone (Upgrades Data.FRAGMENTS). They are kept in the world section
-- "sites". Whether a place is really land is found out when its chunk first loads (never by scanning squares): a
-- place that is not gets a new one, near it first (the survey zone the player may have been shown still holds it),
-- then anywhere in the ring. A site never gives up: each capstone needs its fragment, so a site is moved until it
-- stands somewhere (after LENIENT_AFTER moves any land square of a chunk will do). A site then gets its props (scorched ground, rocks, a survey stake with
-- its number and a date, and round them 2 or 3 things someone left) and its fragment, all through OA.Chunks. No sound
-- is changed around a site and nothing there gives light (FEASIBILITY: visual clues only).
-- A fragment is one of its kind in the world, and a character's capstone needs one: a kind the research team has had
-- once (any character's delivery) is had for good (Sites.received: the next character after a death is let through),
-- and a fragment that has left its site and reached nobody in LOST_DAYS is taken for lost (died with a character,
-- burnt, thrown away): the team finds another fall of its kind (Sites.relay), a new site in the ring.
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
-- Moves made near the old place first (squares from it), before the ring; moves after which a site takes a chunk's
-- first land square without its footprint; moves tried at once while the new places' chunks are loaded too (the rest
-- at the next look, Sites.kick).
Sites.NEAR_MOVES, Sites.NEAR_LO, Sites.NEAR_HI = 6, 16, 60
Sites.LENIENT_AFTER = 12
Sites.MOVES_AT_ONCE = 24
Sites.LOST_DAYS = 7
-- What someone left round a site (LORE 7, story-improvements 10), 2 or 3 of them: dark soil that looks wet, a second
-- stake with another date, a cut length of marker tape, an empty sample bag, stones laid in a row.
Sites.PROPS = { "soil", "stake", "tape", "bag", "stones" }
Sites.PROP_SPRITES = { soil = OA.Sprites.DAMP_SOIL, tape = OA.Sprites.CUT_TAPE, bag = OA.Sprites.SAMPLE_BAG,
                       stones = OA.Sprites.STONE_ROW }

local function section()
    return OA.Store.world("sites")
end

-- The sites, in number order: { { n =, x =, y =, kind =, stake =, date =, state = "pending" | "placed", tries = moves,
-- left = world hour its fragment was found gone from it, relaid = true once another site of its kind was laid } }.
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

-- Whether the square x, y is loaded now (LoadChunk will not come for it).
local function loaded(x, y)
    local sq = getCell and getCell() and getCell():getGridSquare(x, y, 0)
    return sq ~= nil and sq:getChunk() ~= nil
end

local settle

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
    if #points < Sites.COUNT then
        -- (a map with too few places that pass: the rest anywhere in the ring, judged as their chunks load)
        points = OA.Places.ringSites(origin, Sites.COUNT, Sites.RING_LO, Sites.RING_HI, Sites.SPACING, nil, points, int)
    end
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
    for _, site in ipairs(sec.list) do settle(site) end
    return sec.list
end

-- A point NEAR_LO to NEAR_HI squares from x, y that may hold a site, or nil.
local function nearPoint(x, y, accept, draw, int)
    for _ = 1, 20 do
        local px, py
        if draw then
            px, py = draw(x, y, Sites.NEAR_LO, Sites.NEAR_HI)
        else
            local a = math.rad(int(0, 359))
            local r = int(Sites.NEAR_LO, Sites.NEAR_HI)
            px, py = math.floor(x + r * math.cos(a) + 0.5), math.floor(y + r * math.sin(a) + 0.5)
        end
        if px and accept(px, py) then return { x = px, y = py } end
    end
    return nil
end

-- A site whose place is not land gets a new place: near it for its first NEAR_MOVES moves, else in the ring as far
-- from the others as they are from each other (any place of the ring when none passes).
function Sites.replace(site, accept, int)
    local sec = section()
    int = int or OA.random
    site.tries = (site.tries or 0) + 1
    local draw
    if not accept then accept, draw = acceptPoint, drawPoint end
    local p = site.tries <= Sites.NEAR_MOVES and nearPoint(site.x, site.y, accept, draw, int)
    if not p then
        local others = {}
        for _, s in ipairs(sec.list) do
            if s ~= site then others[#others + 1] = { x = s.x, y = s.y } end
        end
        local points = OA.Places.ringSites(sec.origin, #others + 1, Sites.RING_LO, Sites.RING_HI, Sites.SPACING, accept,
            others, int, draw)
        if #points <= #others then
            points = OA.Places.ringSites(sec.origin, #others + 1, Sites.RING_LO, Sites.RING_HI, Sites.SPACING, nil, others,
                int)
        end
        p = points[#points]
    end
    site.x, site.y = p.x, p.y
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
-- (it must not reach into a lake or onto a road). By kind. After LENIENT_AFTER moves: its middle on land, alone.
local LENIENT = { { offsets = { 0, 0 }, filter = LAND } }
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

-- A land square in the chunk of the site's place where it fits (fitFor; LENIENT after many moves), one at random: the
-- site is built there. False when none.
local function place(site)
    local size = OA.Chunks.SIZE
    local x1, y1 = math.floor(site.x / size) * size, math.floor(site.y / size) * size
    local parts = (site.tries or 0) >= Sites.LENIENT_AFTER and LENIENT or fitFor(site.kind)
    local sq = OA.api().squares.fit({ x1 = x1, y1 = y1, x2 = x1 + size - 1, y2 = y1 + size - 1, z = 0 }, parts,
        RANDOM_ORDER)
    if not sq then return false end
    site.x, site.y = sq:getX(), sq:getY()
    build(site, sq)
    site.state = "placed"
    OA.log("meteor site", site.n, site.kind, "placed at", site.x, site.y)
    OA.Sync.changed("sites", nil)
    return true
end

-- A pending site placed where it stands, or moved on until it is, or until its place waits for its chunk to load.
-- `here`: its chunk is loaded now (LoadChunk). Many loaded places in a row that are not land leave the rest to the next
-- look (Sites.kick).
settle = function(site, here)
    for _ = 1, Sites.MOVES_AT_ONCE do
        if not (here or loaded(site.x, site.y)) then
            OA.Chunks.add({ kind = "oa_site", site = site.n, x = site.x, y = site.y, z = 0 })
            return
        end
        here = false
        if place(site) then return end
        Sites.replace(site)
        OA.log("meteor site", site.n, "was not land, moved to", site.x, site.y)
    end
end

-- LoadChunk work: the chunk of a pending site's place loaded (a place it has left is let go).
function Sites.onChunk(entry, chunk)
    local site = Sites.byNumber(entry.site)
    if not site or site.state ~= "pending" or entry.x ~= site.x or entry.y ~= site.y then return true end
    settle(site, true)
    return true
end

-- The kind of a fragment's full type, or nil.
function Sites.kindOf(fullType)
    for kind, item in pairs(Sites.FRAGMENT) do
        if fullType == OA.StoryData.fullType(item) then return kind end
    end
    return nil
end

-- A fragment of a kind reached the research team (anyone's delivery): had for good.
function Sites.receive(fullType)
    local kind = Sites.kindOf(fullType)
    if not kind then return false end
    local sec = section()
    sec.received = sec.received or {}
    sec.received[kind] = true
    return true
end

function Sites.received(fullType)
    local kind = Sites.kindOf(fullType)
    local got = section().received
    return kind ~= nil and got ~= nil and got[kind] == true
end

-- Whether a placed site's fragment still lies on its square (loaded).
local function fragmentThere(site)
    local sq = getCell():getGridSquare(site.x, site.y, 0)
    local objects = sq and sq:getWorldObjects()
    if not objects then return true end
    local fullType = OA.StoryData.fullType(Sites.FRAGMENT[site.kind])
    for i = 0, objects:size() - 1 do
        local item = objects:get(i):getItem()
        if item and item:getFullType() == fullType then return true end
    end
    return false
end

-- Another fall of a lost fragment's kind: a new site in the ring, the old one's left as it stands. Returns it.
function Sites.relay(site, accept, int)
    local sec = section()
    int = int or OA.random
    local others = {}
    for _, s in ipairs(sec.list) do others[#others + 1] = { x = s.x, y = s.y } end
    local draw
    if not accept then accept, draw = acceptPoint, drawPoint end
    local points = OA.Places.ringSites(sec.origin, #others + 1, Sites.RING_LO, Sites.RING_HI, Sites.SPACING, accept,
        others, int, draw)
    if #points <= #others then
        points = OA.Places.ringSites(sec.origin, #others + 1, Sites.RING_LO, Sites.RING_HI, Sites.SPACING, nil, others, int)
    end
    local p = points[#points]
    local new = { n = #sec.list + 1, x = p.x, y = p.y, kind = site.kind, stake = newStake(sec.list, int),
        date = Sites.otherDate(site.date, int), state = "pending", tries = 0 }
    sec.list[#sec.list + 1] = new
    site.relaid = true
    OA.log("meteor site", site.n, "lost its fragment: site", new.n, "laid at", new.x, new.y)
    settle(new)
    OA.Sync.changed("sites", nil)
    if Sites.onRelaid then Sites.onRelaid(new) end
    return new
end

-- Every ten minutes: a pending site whose place is loaded and was left waiting (moves at once ran out, or its work
-- failed) is settled again; a placed one whose fragment has gone from its square is marked, and once it has reached
-- nobody in LOST_DAYS, its kind falls again (Sites.relay).
function Sites.kick(now)
    now = now or OA.hours()
    local got = section().received or {}
    for _, site in ipairs(Sites.list()) do
        if site.state == "pending" and loaded(site.x, site.y) then
            settle(site)
        elseif site.state == "placed" and not site.relaid and not got[site.kind] then
            if not site.left and loaded(site.x, site.y) and not fragmentThere(site) then site.left = now end
            if site.left and now - site.left >= Sites.LOST_DAYS * 24 then Sites.relay(site) end
        end
    end
end

OA.Chunks.handle("oa_site", function(entry, chunk)
    local ok, done = pcall(Sites.onChunk, entry, chunk)
    if not ok then
        -- (the site is not lost: it moves on, and stands where its next place loads)
        OA.log("meteor site failed:", tostring(done))
        local site = Sites.byNumber(entry.site)
        if site and site.state == "pending" then
            pcall(Sites.replace, site)
            OA.Chunks.add({ kind = "oa_site", site = site.n, x = site.x, y = site.y, z = 0 })
        end
        return true
    end
    return done
end)

return Sites
