-- Missions (DESIGN 9, NUMBERS 9, LORE 4 and 7). One at a time per player. The next comes MissionInterval days after the
-- last ended; a regular one picks a building in the stage's distance band, a story one a place from its candidates.
-- The item goes in a container of the building (Story/Placer, through the game adapter below), a circle marks the area
-- on the map, the deadline is judged when the box is sealed, and the reward is paid at the settlement.
--
-- Everything that touches the game's objects goes through `Missions.game` (made in Story/Game): the buildings of the
-- map, where the player is, the item in their inventory, placing items. Tests give it fakes.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Rewards"
require "OperationAcorn/Economy/Support"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/View"
require "OperationAcorn/Story/Comms"
local OA = OperationAcorn
local Data, Rewards, Places, Story, Docs = OA.StoryData, OA.Rewards, OA.Places, OA.Story, OA.StoryDocs
local View = OA.StoryView
local Missions = {}
OA.Missions = Missions

Missions.game = nil

local function game()
    return Missions.game
end

-- A record's `missions` section: { active = mission | nil, nextAt = world age, seq = n, results = { done =, expired =,
-- lost = }, streak = missions done in time in a row, bestStreak = the longest, reroll = { week = } when a mission was
-- taken again this week, special = the special request's slot (Missions.special) }.
function Missions.state(record)
    local s = OA.Store.section(record, "missions")
    if not s.version then
        s.version = 1
        s.seq = 0
        s.nextAt = 0
        s.results = { done = 0, expired = 0, lost = 0 }
        s.streak = 0
        s.bestStreak = 0
    end
    return s
end

function Missions.active(record)
    return Missions.state(record).active
end

-- The special request's slot (DESIGN-terminal 6.3), a mission of its own beside the main one: { nextAt = world age the
-- next offer may come, offer = { seq, at, a = option, b = option } while two are offered, mission = the one taken,
-- last = the ids of the last offer }. An option is { id, form, place, area, danger }.
function Missions.special(record)
    local s = Missions.state(record)
    if not s.special then s.special = { nextAt = 0, last = {} } end
    return s.special
end

-- The missions running now (a list: the main one once it is taken, then the special request), for what works on every
-- one of them.
function Missions.live(record)
    local missions = record and record.missions
    local list = {}
    if missions and View.taken(missions.active) then list[#list + 1] = missions.active end
    if missions and missions.special and missions.special.mission then list[#list + 1] = missions.special.mission end
    return list
end

local function weighted(list, int)
    int = int or OA.random
    local total = 0
    for _, e in ipairs(list) do total = total + (e.weight or 1) end
    local roll = int(1, total)
    for _, e in ipairs(list) do
        roll = roll - (e.weight or 1)
        if roll <= 0 then return e end
    end
    return list[#list]
end

local function creditScale()
    return OA.option("CreditMultiplier") or 1
end

-- A story mission's days over a regular one's.
Missions.STORY_EXTRA_DAYS = 7

-- A mission's days (14, more with the flight support's mission days; a story's STORY_EXTRA_DAYS more), as hours.
local function deadlineHours(record, story)
    local days = OA.Support.value(record, "mdays") + (story and Missions.STORY_EXTRA_DAYS or 0)
    return Rewards.hours(OA.scaled(days, "MissionDeadlineMultiplier"))
end

local function intervalHours()
    return Rewards.hours(OA.scaled(3, "MissionIntervalMultiplier"))
end

-- The terminal's position (the base), for the distance band: the trade part's if it tells, else the record's own
-- note of it (Story.setAnchor), else where the player is now. Returns x, y or nil.
function Missions.anchor(record)
    local story = record.story
    if story and story.anchor and story.anchor.x then return story.anchor.x, story.anchor.y end
    if OA.Trade and OA.Trade.terminalPosition then
        local x, y = OA.Trade.terminalPosition(record)
        if x then return x, y end
    end
    local g = game()
    local px, py
    if g and g.playerPosition then px, py = g.playerPosition(record) end
    -- The terminals placed (the trade part keeps them as waiting entries): the one nearest the character is the
    -- base; it is kept, so the distance bands do not move when the terminal does.
    if OA.Chunks and OA.Chunks.list then
        local best, bestD
        for _, e in ipairs(OA.Chunks.list("trade.terminal")) do
            local d = px and Places.distance(px, py, e.x, e.y) or 0
            if not bestD or d < bestD then best, bestD = e, d end
        end
        if best then
            Story.setAnchor(record, best.x, best.y, best.z)
            return best.x, best.y
        end
    end
    local t = record.trade or {}
    local home = t.terminal or t.home
    if home and home.x then return home.x, home.y end
    return px, py
end

-- ---------------------------------------------------------------------------------------------------------------
-- Building a mission.

local function newMission(record, kind, level, story)
    local s = Missions.state(record)
    s.seq = s.seq + 1
    local now = OA.hours()
    local isStory = story ~= nil
    local credits, trust = Rewards.reward(level, isStory, 1, creditScale())
    return {
        id = "M" .. tostring(record.number or 0) .. "-" .. tostring(s.seq),
        seq = s.seq,            -- the terminal's dot remembers the last one it showed (ui.seen.mission)
        kind = kind,            -- "regular" | "story" | "contract"
        story = story,
        level = level,
        state = "open",
        issued = now,
        deadline = now + deadlineHours(record, isStory),
        credits = credits, trust = trust,
        items = {},
    }
end

local function placementFrom(itemName, key, p, mods, mode)
    return {
        key = key, type = Data.fullType(itemName), mode = mode or "container",
        x = p.x, y = p.y, z = p.z or 0,
        x1 = p.x1 or p.x, y1 = p.y1 or p.y, x2 = p.x2 or p.x, y2 = p.y2 or p.y,
        z1 = p.z1 or p.z or 0, z2 = p.z2 or p.z or 0,
        room = p.room, mods = mods or {}, placed = false,
    }
end

-- The item's identity as the economy reads it (OA_Mission): the mission's id, with the piece's key when a mission has
-- several pieces.
function Missions.itemId(m, key)
    if #m.items > 1 and key then return m.id .. "#" .. key end
    return m.id
end

local function circleFor(m, x, y)
    local r = Places.circleRadius(m.level)
    local cx, cy = Places.circle(x, y, r)
    m.area = { x = cx, y = cy, r = r }
end

-- How far from the first building a scattered mission's other buildings may be, of the circle's radius.
local SCATTER_REACH = 0.5

-- One circle that holds several places (a scattered mission's buildings), 10 squares in from its edge: moved off their
-- middle as Places.circle moves it off one place, tried a few times; their middle when no try holds them.
local function circleAround(m, places, level)
    local r = Places.circleRadius(level)
    local sx, sy = 0, 0
    for _, p in ipairs(places) do sx, sy = sx + p.x, sy + p.y end
    local mx, my = sx / #places, sy / #places
    for _ = 1, 8 do
        local cx, cy = Places.circle(mx, my, r)
        local holds = true
        for _, p in ipairs(places) do
            if Places.distance(p.x, p.y, cx, cy) > r - 10 then holds = false end
        end
        if holds then
            m.area = { x = cx, y = cy, r = r }
            return
        end
    end
    m.area = { x = math.floor(mx + 0.5), y = math.floor(my + 0.5), r = r }
end

-- The points a mission's zombie density is read at: the middle of its circle and four points round it (a few chunks of
-- the area; read once, when the mission is made).
function Missions.samplePoints(area)
    local d = area.r * 0.6
    local x, y = math.floor(area.x), math.floor(area.y)
    return {
        { x, y }, { math.floor(area.x + d), y }, { math.floor(area.x - d), y },
        { x, math.floor(area.y + d) }, { x, math.floor(area.y - d) },
    }
end

-- The danger pay of some areas (circles): the average density the game gives at their sample points, as a fraction
-- (Rewards.dangerPay). 0 when the game cannot say.
function Missions.dangerOf(areas)
    local g = game()
    if not (g and g.zombieIntensity) then return 0 end
    local sum, n = 0, 0
    for _, area in ipairs(areas) do
        for _, p in ipairs(Missions.samplePoints(area)) do
            local v = g.zombieIntensity(p[1], p[2])
            if v then sum, n = sum + v, n + 1 end
        end
    end
    if n == 0 then return 0 end
    return Rewards.dangerPay(sum / n)
end

-- The distance pay of an area (Rewards.farPay): how far into the band of `level` it lies from the base. 0 without a base.
function Missions.farOf(record, area, level)
    if not area then return 0 end
    local ax, ay = Missions.anchor(record)
    if not ax then return 0 end
    local lo, hi = Rewards.band(level)
    return Rewards.farPay(Places.distance(ax, ay, area.x, area.y), lo, hi)
end

-- The flight support's mission pay (a fraction) and the streak's cap it raises.
local function supportPay(record) return OA.Support.value(record, "mpay") end
local function streakCap(record) return OA.Support.value(record, "mstreak") end

-- Makes the mission's reward of its parts (DESIGN-terminal 7.2): `base` the credits the kind is worth and `trustBase` its
-- trust; the danger pay of its area and the distance pay (how far into its band it lies) on both; the streak the record
-- has now and the flight support's mission pay on the credits only. The card shows the parts. `danger` (the special
-- request's offer read it already) is read when not given.
function Missions.price(record, m, danger)
    local areas = {}
    if m.area then areas[#areas + 1] = m.area end
    if m.area2 then areas[#areas + 1] = m.area2 end
    m.base = m.base or m.credits
    m.trustBase = m.trustBase or m.trust
    m.danger = danger or Missions.dangerOf(areas)
    m.far = Missions.farOf(record, m.area, m.special and Rewards.specialBandLevel(m.level) or m.level)
    m.streak = m.special and 0 or Missions.state(record).streak
    m.streakPay = Rewards.streakBonus(m.streak, streakCap(record))
    m.support = supportPay(record)
    m.credits = Rewards.withBonus(m.base, m.danger, m.streak, m.far, m.support, streakCap(record))
    m.trust = Rewards.trustWithBonus(m.trustBase, m.danger, m.far)
end

-- A place table of a regular mission's building from the game adapter.
local function buildingPlace(info)
    return {
        x = info.x, y = info.y, z = info.z or 0,
        x1 = info.x1, y1 = info.y1, x2 = info.x2, y2 = info.y2, z1 = info.z1 or 0, z2 = info.z2 or 0,
    }
end

-- Picks a building in the band; returns its place table or nil.
local function pickBuildingPlace(record, level)
    local g = game()
    if not (g and g.buildingCount) then return nil end
    local ax, ay = Missions.anchor(record)
    if not ax then return nil end
    local lo, hi = Rewards.band(level)
    local idx = Places.pickBuilding(g.buildingCount(), g.building, ax, ay, lo, hi)
    if not idx then return nil end
    return buildingPlace(g.buildingInfo(idx)), ax, ay
end

-- The field note an item may carry: the ones the record has not read come first, the read ones again when all are read.
local function fieldNoteId(record)
    if OA.random(1, 100) > Data.FIELD_NOTE_CHANCE then return nil end
    local read = Story.section(record).docs
    local fresh = {}
    for n = 1, Data.FIELD_NOTES do
        if not read["note_" .. n] then fresh[#fresh + 1] = n end
    end
    if #fresh == 0 then return "note_" .. tostring(OA.random(1, Data.FIELD_NOTES)) end
    return "note_" .. tostring(fresh[OA.random(1, #fresh)])
end

-- The site of a story mission, a special request or a contract errand (SCENES.md 5 '장소 고르기', LORE 4): a building
-- of the band taken for a temporary facility, or open ground when the spec wants it or no building is left. `spec`:
-- { want = Places.pickSite's want, ground = true (open ground only), up = true (of more than one floor first) }. Not the base's building, not a site a story has
-- used in this world, not a building a player has searched, not the site of a special request on offer, nor `taken` (a
-- key). No building in the band: the band's outer edge reaches further out (SITE_WIDER) before open ground. Returns { x, y, z, x1, y1, x2, y2, z1, z2, key } (a building's), { x, y, z = 0, key, ground = true } or nil (no
-- base known, or nothing found).
Missions.SITE_WIDER = { 1, 1.5, 2 }   -- the band's outer edge, times these in turn, before open ground
function Missions.pickSite(record, level, spec, taken)
    local g = game()
    local ax, ay = Missions.anchor(record)
    if not (g and ax) then return nil end
    local lo, hi = Rewards.band(level)
    if not spec.ground and g.sitesInBand then
        local skip = Story.siteSkips(g.buildingKeyAt and g.buildingKeyAt(ax, ay))
        local offer = Missions.special(record).offer
        if offer then
            for _, key in ipairs({ "a", "b" }) do
                local site = offer[key] and offer[key].site
                if site then skip[site.key] = true end
            end
        end
        if taken then skip[taken] = true end
        -- with no building in the band (a base out in the woods) the band reaches further out before open ground
        for _, wider in ipairs(Missions.SITE_WIDER) do
            local list = g.sitesInBand(ax, ay, lo, hi * wider, skip)
            -- `up`: a building of more than one floor first
            if spec.up then
                local tall = {}
                for _, b in ipairs(list) do
                    if (b.z2 or 0) > math.max(b.z1 or 0, 0) then tall[#tall + 1] = b end
                end
                if #tall > 0 then list = tall end
            end
            local i = Places.pickSite(list, spec.want or "public")
            if i then
                local b = list[i]
                return { x = b.x, y = b.y, z = b.z, x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z1 = b.z1, z2 = b.z2,
                    key = b.key }
            end
        end
    end
    if not g.groundInBand then return nil end
    local x, y = g.groundInBand(ax, ay, lo, hi)
    if not x then return nil end
    return { x = x, y = y, z = 0, key = "g:" .. tostring(x) .. "," .. tostring(y), ground = true }
end

local function storyMission(record, def, id, level)
    local m = newMission(record, "story", level, id)
    m.title = id
    m.facility = def.facility
    local ax, ay = Missions.anchor(record)
    if ax then m.anchor = { x = ax, y = ay } end
    return m
end

-- One piece at a mission's site (on its floor when the site is open ground); the circle round the site.
local function placeAtSite(m, itemName, key, site, mods, mode)
    m.site = site
    local it = placementFrom(itemName, key, site, mods, site.ground and "floor" or mode)
    m.items[#m.items + 1] = it
    circleFor(m, site.x, site.y)
    return it
end

-- A story mission's site: a revisit goes back to the site of the story it names (`from`) when that one had one, the
-- others pick a new one and keep it in the world's used sites and in the record (for the revisit).
local function storySite(record, def, id, level, spec)
    local s = Story.section(record)
    local back = def.from and s.sites[def.from]
    if back then return back end
    local site = Missions.pickSite(record, level, spec or def.site or {})
    if not site then return nil end
    Story.useSite(site.key)
    s.sites[id] = site
    return site
end

local function createSwap(record, def, id, level)
    local m = storyMission(record, def, id, level)
    local site = storySite(record, def, id, level)
    if not site then return nil end
    local it = placeAtSite(m, "DeadDropCase", "CASE", site, { OA_Drop = "" }, "floor")
    it.mode = "case"
    m.swap = { stage = "needcase", waited = 0, item = def.item }
    -- The sealed case comes in the next supply crate: the deadline starts later.
    m.deadline = m.deadline + Rewards.hours(Data.SWAP_SLACK_DAYS)
    Story.queueSupply(record, "SampleCase", nil)
    return m
end

local function createFetch(record, def, id, level)
    local m = storyMission(record, def, id, level)
    local site = storySite(record, def, id, level)
    if not site then return nil end
    local mods = { OA_Variant = def.facility }
    -- A revisit's item carries the new office's paper, not the old one the item has.
    if def.doc then mods.OA_Doc, mods.OA_Only = def.doc, true end
    local it = placeAtSite(m, def.item, "A", site, mods)
    if def.condition == "locked" and not site.ground then it.lock = true end
    if def.kind == "carry" then m.carry = {} end
    return m
end

local function createField(record, def, id, level)
    local m = createFetch(record, def, id, level)
    if not m then return nil end
    m.field = { stage = "needdevice" }
    m.deadline = m.deadline + Rewards.hours(Data.SWAP_SLACK_DAYS)
    Story.queueSupply(record, "FieldCallDevice", nil)
    return m
end

-- A choice: the option it was started with (Missions.launch) becomes the mission, the other closes for good.
local function createChoice(record, def, id, level, option)
    local opt = def.options and def.options[option]
    if not opt then return nil end
    local m = storyMission(record, def, id, level)
    local site = storySite(record, def, id, level, opt.site)
    if not site then return nil end
    m.chosen = option
    m.facility = opt.facility or def.facility
    placeAtSite(m, opt.item, "A", site, { OA_Variant = m.facility })
    m.title = id .. "_" .. option
    Story.section(record).chosen[id] = option
    return m
end

-- Two copies, one original: the original's serial is what the terminal copy shows. A contract mission, or `kind`.
local function createCompare(record, entry, level, kind)
    local m = newMission(record, kind or "contract", level, nil)
    m.title = "compare"
    local serial = OA.random(100, 899)
    m.compare = { serial = serial, right = (OA.random(1, 2) == 1) and "A" or "B" }
    local ax, ay = Missions.anchor(record)
    if not ax then return nil end
    m.anchor = { x = ax, y = ay }
    for i, key in ipairs({ "A", "B" }) do
        local p = pickBuildingPlace(record, level)
        if not p then return nil end
        local number = key == m.compare.right and serial or (serial + OA.random(11, 87))
        m.items[i] = placementFrom(entry.item, key, p, { OA_Serial = number })
    end
    -- One circle around the first building; the second building is a second circle.
    circleFor(m, m.items[1].x, m.items[1].y)
    local cx, cy, r = Places.circle(m.items[2].x, m.items[2].y, Places.circleRadius(level))
    m.area2 = { x = cx, y = cy, r = r }
    return m
end

-- A contract mission at a drop site's stake: the number tag lies by the stake. It leads to a site the player has not
-- been to while there is one (the three sites are how the capstones open).
local function createStake(record, entry, level)
    local sites = OA.Sites
    if not (sites and sites.list) then return nil end
    local ax, ay = Missions.anchor(record)
    if not ax then return nil end
    local lo, hi = Rewards.band(level)
    local seen = sites.seenOf(record)
    local cands, fresh = {}, {}
    for _, site in ipairs(sites.list()) do
        if site.state ~= "failed" then
            local c = { x = site.x, y = site.y, id = site.n }
            cands[#cands + 1] = c
            if not seen[site.n] then fresh[#fresh + 1] = c end
        end
    end
    if #fresh > 0 then cands = fresh end
    if #cands == 0 then return nil end
    local i = Places.pickCandidate(cands, ax, ay, lo, hi, { exclusion = 0 })
    if not i then return nil end
    local site = sites.byNumber(cands[i].id)
    local m = newMission(record, "contract", level, nil)
    m.title = "stake"
    m.anchor = { x = ax, y = ay }
    m.stake = site.n
    m.stakeNo = site.stake
    local p = { x = site.x, y = site.y, z = 0 }
    local it = placementFrom(entry.item, "A", p, { OA_Stake = site.stake })
    it.mode = "floor"
    m.items[1] = it
    circleFor(m, site.x, site.y)
    return m
end

-- A contract mission: a comparison, a stake, an errand at a site taken for a facility, or any building.
local function createContract(record, level)
    local entry = weighted(Data.CONTRACTS)
    local m
    if entry.kind == "compare" then
        m = createCompare(record, entry, level)
    elseif entry.kind == "stake" then
        m = createStake(record, entry, level)
    elseif entry.kind == "place" then
        m = newMission(record, "contract", level, nil)
        m.title = entry.id
        m.facility = entry.facility
        local site = Missions.pickSite(record, level, entry.site or {})
        if site then
            placeAtSite(m, entry.item, "A", site, { OA_Variant = entry.facility })
            local ax, ay = Missions.anchor(record)
            if ax then m.anchor = { x = ax, y = ay } end
        else
            m = nil
        end
    else
        local p, ax, ay = pickBuildingPlace(record, level)
        if p then
            m = newMission(record, "contract", level, nil)
            m.title = entry.id
            m.anchor = { x = ax, y = ay }
            m.items[1] = placementFrom(entry.item, "A", p, {})
            circleFor(m, p.x, p.y)
        end
    end
    if m then m.contract = entry.id end
    return m
end

-- The soil sample (milestone choice): from a drop site the player has been to, or from any bare ground.
-- The drop sites the player has been to.
local function seenSites(record)
    local sites = OA.Sites
    local seen = {}
    for n in pairs(sites and sites.seenOf and sites.seenOf(record) or {}) do
        local site = sites and sites.byNumber and sites.byNumber(n)
        if site then seen[#seen + 1] = site end
    end
    return seen
end

local function createSoil(record, def, id, level)
    local m = storyMission(record, def, id, level)
    local seen = seenSites(record)
    if #seen > 0 then
        local site = seen[OA.random(1, #seen)]
        m.soil = { site = site.n, stake = site.stake, x = site.x, y = site.y, variant = "site" }
        circleFor(m, site.x, site.y)
        m.title = "soil_site"
    else
        m.soil = { variant = "plain" }
        m.title = "soil_plain"
    end
    return m
end

-- ---------------------------------------------------------------------------------------------------------------
-- The regular missions (DESIGN-terminal 7.2): one item in a building of the band, and the kinds mixed in.

local function createItem(record, level, kind)
    local p, ax, ay = pickBuildingPlace(record, level)
    if not p then return nil end
    local m = newMission(record, "regular", level, nil)
    m.title = kind.item
    m.anchor = { x = ax, y = ay }
    local mods = {}
    if Data.ITEMS[kind.item].note then mods.OA_Note = fieldNoteId(record) end
    m.items[1] = placementFrom(kind.item, "A", p, mods)
    circleFor(m, p.x, p.y)
    if kind.kind == "heavy" then m.heavy = Data.HEAVY_WEIGHT end
    return m
end

-- The soil sample of bare ground, among the regular missions: no place, no circle; the sample is taken anywhere outdoors.
local function createPlainSoil(record, level)
    local m = newMission(record, "regular", level, nil)
    m.title = "soil"
    local ax, ay = Missions.anchor(record)
    if ax then m.anchor = { x = ax, y = ay } end
    m.soil = { variant = "plain" }
    return m
end

-- Is a point the centre of one of the buildings in the list.
local function usedBuilding(list, x, y)
    for _, p in ipairs(list) do
        if p.x == x and p.y == y then return true end
    end
    return false
end

-- Pieces of one item in two or three buildings of the circle. The whole set pays more, a part pays by the share
-- found (Missions.scatterPay). When the area holds no second building it is an ordinary pickup.
local function createScatter(record, level, kind)
    local g = game()
    local p, ax, ay = pickBuildingPlace(record, level)
    if not p then return nil end
    local m = newMission(record, "regular", level, nil)
    m.title = kind.item
    m.anchor = { x = ax, y = ay }
    local pieces = { p }
    local want = OA.random(Data.SCATTER_PIECES[1], Data.SCATTER_PIECES[2])
    local reach = Places.circleRadius(level) * SCATTER_REACH
    local function at(i)
        local x, y, ok = g.building(i)
        if x and usedBuilding(pieces, x, y) then return nil end
        return x, y, ok
    end
    for _ = 2, want do
        local idx = Places.pickBuilding(g.buildingCount(), at, p.x, p.y, 0, reach, 200)
        local info = idx and g.buildingInfo(idx)
        -- a building the search had to take from farther is not one of the area
        if not info or Places.distance(info.x, info.y, p.x, p.y) > reach then break end
        pieces[#pieces + 1] = buildingPlace(info)
    end
    circleAround(m, pieces, level)
    local mods = { OA_Note = Data.ITEMS[kind.item].note and fieldNoteId(record) or nil }
    for i, piece in ipairs(pieces) do
        m.items[i] = placementFrom(kind.item, string.sub("ABC", i, i), piece, i == 1 and mods or {})
    end
    if #pieces >= 2 then
        m.title = "scatter"
        m.scatter = { total = #pieces, found = {} }
        -- the whole set's price (a part pays by its share of the price without the extra)
        m.credits = OA.round(m.credits * (1 + Rewards.SCATTER_BONUS))
        m.trust = OA.round(m.trust * (1 + Rewards.SCATTER_BONUS))
    end
    return m
end

-- A zombie mission (Data.ZOMBIES): a small circle in the open near a building of the band; the group appears when the
-- player comes near (Story/Zombies). `zombies` = { kind, outfit (its look), total, killed (an area clear's kills), taken (the target
-- samples harvested), seq (the last sample's number), dead = { the death hours of targets killed and not harvested },
-- sealed = { [sample key] = true } }.
local function createZombies(record, level, kind)
    local p, ax, ay = pickBuildingPlace(record, level)
    if not p then return nil end
    local def = Data.ZOMBIES[kind.kind]
    local m = newMission(record, "regular", level, nil)
    m.title = kind.id
    m.anchor = { x = ax, y = ay }
    local cx, cy, r = Places.circle(p.x, p.y, Data.ZOMBIE_RADIUS)
    m.area = { x = cx, y = cy, r = r }
    m.zombies = { kind = kind.kind, outfit = def.outfit, total = def.counts[math.min(level, #def.counts)],
        killed = 0, taken = 0, seq = 0, dead = {}, sealed = {} }
    return m
end

local REGULAR_BUILDERS = {
    item = createItem, heavy = createItem, scatter = createScatter, clear = createZombies, target = createZombies,
    compare = function(record, level, kind) return createCompare(record, kind, level, "regular") end,
    soil = function(record, level) return createPlainSoil(record, level) end,
}

-- The regular kinds; the zombie ones only when the game can mark their group (an API without the marks: not offered).
local function regularKinds()
    local g = Missions.game
    if not (g and g.canMarkZombies and not g.canMarkZombies()) then return Data.REGULAR end
    local kinds = {}
    for _, e in ipairs(Data.REGULAR) do
        if not Data.ZOMBIES[e.kind or ""] then kinds[#kinds + 1] = e end
    end
    return kinds
end

local function createRegular(record, level)
    local kind = weighted(regularKinds())
    return REGULAR_BUILDERS[kind.kind or "item"](record, level, kind)
end

-- An urgent mission (one in URGENT_CHANCE): a day to do it, and it pays more. Not for the kinds that need more than
-- one place or one carry.
local function makeUrgent(m)
    if m.compare or m.scatter or m.heavy or m.soil or m.zombies then return end
    if OA.random(1, 100) > Rewards.URGENT_CHANCE then return end
    m.urgent = true
    m.deadline = m.issued + Rewards.URGENT_HOURS
    m.credits = OA.round(m.credits * Rewards.URGENT_MULTIPLIER)
    m.trust = OA.round(m.trust * Rewards.URGENT_MULTIPLIER)
end

-- Runs a builder `make(record, ...)`; a builder that makes no mission gives back the number it took (newMission).
local function unburnt(make, record, ...)
    local state = Missions.state(record)
    local before = state.seq
    local m = make(record, ...)
    if not m then state.seq = before end
    return m
end

-- The next mission that is not a story's: a contract one after the handover, else a regular one.
local function createPlain(record, level)
    local m
    if Story.handedOver(record) then m = unburnt(createContract, record, level) end
    if not m then m = unburnt(createRegular, record, level) end
    if m then makeUrgent(m) end
    return m
end

local STORY_BUILDERS = {
    fetch = createFetch, carry = createFetch, swap = createSwap, field = createField,
    choice = createChoice, soil = createSoil,
}

local function storyDef(id)
    return Data.STORIES[id] or Data.REVISITS[id]
end

local function createStoryMission(record, id, level, option)
    local def = storyDef(id)
    local build = def and STORY_BUILDERS[def.kind]
    if not build then return nil end
    return unburnt(build, record, def, id, level, option)
end

-- A story mission offered: what the card tells of it (its title, place and base reward) until it is started. It is
-- made when its briefing call is over (Missions.briefed), and its site picked then. A choice offers the options not
-- closed yet (one, when it is offered again after it was missed).
local function storyOffer(record, entry, level)
    local def = storyDef(entry.id)
    if not (def and STORY_BUILDERS[def.kind]) then return nil end
    local m = newMission(record, "story", level, entry.id)
    m.title = entry.id
    m.facility = def.facility
    if def.kind == "choice" then
        local chosen = Story.section(record).chosen[entry.id]
        m.options = chosen and { [chosen] = true } or { a = true, b = true }
    end
    return m
end

-- ---------------------------------------------------------------------------------------------------------------
-- Offering, starting, running and ending.

-- The call that tells what the missions are (CommsData S1M, after the first settlement's; 관리 7's K0M for a record
-- that came into the world after the handover): none is offered before it has been played.
Missions.OPENING_CALL = "S1M"
Missions.ADMIN_OPENING_CALL = "K0M"

function Missions.opened(record)
    local id = Story.joinedAfterHandover(record) and Missions.ADMIN_OPENING_CALL or Missions.OPENING_CALL
    return OA.Comms.done(record, id)
end

-- A mission offered waits for the player to start it: no deadline yet, its days kept for then (`span`, hours).
local function toWaiting(m)
    m.state = "waiting"
    m.span = m.deadline - m.issued
    m.deadline = nil
end

-- The mission is on its way: kept in the record, its items waiting for their places, the map told.
function Missions.begin(record, m)
    local s = Missions.state(record)
    s.active = m
    -- What its place will show (Story/Scene): decided once, as it begins.
    if OA.Scene then OA.Scene.begin(record, m) end
    local g = game()
    for _, it in ipairs(m.items) do
        if not it.placed and g and g.request then g.request(record, m, it) end
    end
    OA.Sync.changed("missions", record.id)
end

-- The short title of a regular or contract mission started: "임무 착수" over its title (a story one has its briefing).
local function launchedTitle(record, m)
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_Launched", sub = (Missions.keys(m)), style = "notice" })
end

-- The translation keys of a mission's title and brief by its kind (the title is the story id, the item or the contract
-- id). `m` is a mission or the tab's description of one.
function Missions.keys(m)
    local prefix, brief = "Title_", "Brief_"
    if m.kind == "regular" and m.title ~= "compare" then
        prefix, brief = "RegTitle_", "RegBrief_"
    elseif m.kind == "contract" or m.kind == "regular" then
        -- (the comparison among the regular missions is told in the contract's words)
        prefix, brief = "ConTitle_", "ConBrief_"
    elseif m.kind == "special" then
        prefix, brief = "SpecialTitle_", "SpecialBrief_"
    end
    return "IGUI_OA_Story_" .. prefix .. tostring(m.title), "IGUI_OA_Story_" .. brief .. tostring(m.title)
end

-- Offers the next mission if one is due: it waits in the missions tab until the player starts it (Missions.launch).
-- Returns it.
function Missions.start(record)
    local stage, milestones = Story.progress(record)
    local level = Rewards.level(stage, milestones)
    if not level then return nil end
    local m
    local story = Story.nextStory(record)
    if story then m = storyOffer(record, story, level) end
    if not m then
        m = createPlain(record, level)
        if not m then return nil end
        Missions.price(record, m)
    end
    toWaiting(m)
    Missions.state(record).active = m
    OA.Sync.changed("missions", record.id)
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_NewRequest", sub = "IGUI_OA_Title_CheckTerminal", style = "notice" })
    OA.log("mission", m.id, m.story or m.title, "offered to", record.number)
    return m
end

-- The briefing call of a story mission (CommsData.BRIEFS): by the story's id, a choice's option, the soil sample's
-- place (a drop site the player has been to, or any bare ground).
function Missions.briefOf(record, m, option)
    local def = storyDef(m.story)
    local key = m.story
    if def and def.kind == "choice" then
        key = m.story .. "_" .. tostring(option)
    elseif def and def.kind == "soil" then
        key = #seenSites(record) > 0 and "soil_site" or "soil_plain"
    end
    return OA.CommsData.BRIEFS[key]
end

-- A story mission is made from its offer once its briefing is over, and begins. With no place for it now (rare: no
-- building in its band) it goes back to the queue and comes again after a regular mission.
local function buildStory(record, offer)
    local s = Missions.state(record)
    local m = createStoryMission(record, offer.story, offer.level, offer.option)
    if not m then
        s.active = nil
        Story.queueStory(record, offer.story, false)
        OA.Sync.notice(record.id, "IGUI_OA_Story_LaunchFail", {})
        OA.Sync.changed("missions", record.id)
        return nil
    end
    -- the number the card was offered under (the tab's dot has seen it)
    m.id, m.seq = offer.id, offer.seq
    Missions.price(record, m)
    Missions.begin(record, m)
    -- the briefing is over: the title says the mission is on (it would cover the call earlier)
    launchedTitle(record, m)
    OA.log("mission", m.id, m.title, "started by", record.number)
    return m
end

-- The player starts the mission offered (the card's 착수 button; a choice with one of its options). A regular or
-- contract one is on its way at once, its days from now. A story one has its briefing call fired: the terminal plays it
-- in the comms tab, and the mission begins when the call is over or skipped (Missions.briefed). Returns true, and
-- "brief" when a call is to play.
function Missions.launch(record, option)
    local s = Missions.state(record)
    local m = s.active
    if not (m and m.state == "waiting") then return false end
    if m.kind ~= "story" then
        m.state = "open"
        m.issued = OA.hours()
        m.deadline = m.issued + m.span
        m.span = nil
        Missions.begin(record, m)
        launchedTitle(record, m)
        OA.log("mission", m.id, m.title, "started by", record.number)
        return true
    end
    if m.options and not m.options[option] then return false end
    m.option = m.options and option or nil
    local brief = Missions.briefOf(record, m, option)
    -- a briefing played before (the mission went back to the queue) is not played again
    if not brief or OA.Comms.done(record, brief) then return buildStory(record, m) ~= nil end
    m.state = "briefing"
    m.brief = brief
    OA.Comms.fire(record, OA.CommsData.BY_ID[brief].trigger)
    OA.Sync.changed("comms", record.id)
    OA.Sync.changed("missions", record.id)
    return true, "brief"
end

-- A call was played in the comms tab (or skipped): the briefing of the mission being started lets it begin.
function Missions.briefed(record, id)
    local m = Missions.state(record).active
    if m and m.state == "briefing" and m.brief == id then buildStory(record, m) end
end

-- The streak (DESIGN-terminal 7.2): a mission done in time adds one, one past its deadline ends it; a lost one and a taken
-- again one leave it. The special request is a slot of its own and neither counts nor ends it.
local function countStreak(s, result)
    if result == "done" then
        s.streak = s.streak + 1
        if s.streak > s.bestStreak then s.bestStreak = s.streak end
    elseif result == "expired" then
        s.streak = 0
    end
end

-- The special request ends: its slot waits SPECIAL_GAP_DAYS for the next offer.
local function finishSpecial(record, m, result)
    local s = Missions.state(record)
    local g = game()
    if g and g.release then g.release(m) end
    local sp = Missions.special(record)
    sp.mission = nil
    sp.nextAt = OA.hours() + Rewards.hours(Rewards.SPECIAL_GAP_DAYS)
    s.results[result] = (s.results[result] or 0) + 1
    if result == "expired" then
        OA.Sync.title(record.id, { key = "IGUI_OA_Title_Expired", sub = (Missions.keys(m)), style = "sink",
            fallback = "bad" })
    end
    OA.Sync.changed("missions", record.id)
end

-- The mission ends: only its result stays (DESIGN 12). `result`: "done" | "expired" | "lost".
function Missions.finish(record, m, result)
    if m.special then return finishSpecial(record, m, result) end
    local s = Missions.state(record)
    local g = game()
    if g and g.release then g.release(m) end
    s.active = nil
    s.nextAt = OA.hours() + intervalHours()
    s.results[result] = (s.results[result] or 0) + 1
    s.last = { id = m.id, story = m.story, result = result, at = OA.hours() }
    countStreak(s, result)
    if result == "expired" then
        OA.Sync.title(record.id, { key = "IGUI_OA_Title_Expired", sub = (Missions.keys(m)), style = "sink",
            fallback = "bad" })
    end
    Story.missionEnded(record, m, result)
    OA.Sync.changed("missions", record.id)
end

-- The reward goes in, and the player sees the request done: its own title, or, when its trust brings a level with a
-- title, that title with the request under it (one title for the one event).
function Missions.pay(record, m)
    local credits, trust = m.pay and m.pay.credits or m.credits, m.pay and m.pay.trust or m.trust
    local detail = { key = "IGUI_OA_Title_Paid", sub = (Missions.keys(m)), style = "dust", fallback = "good" }
    if credits and credits > 0 then
        detail.sub, detail.subArgs = "IGUI_OA_Title_PaidSub", { { key = detail.sub }, { credits = math.floor(credits + 0.5) } }
    end
    -- The economy values a mission item that is in time at nothing (P1: "MissionItem"); the whole reward is paid here.
    Story.addCredits(record, credits)
    if not Story.addTrust(record, trust, detail) then OA.Sync.title(record.id, detail) end
    if m.swap then Story.queueNote(record, "case_confirmed") end
    if m.cooler then Story.queueNote(record, "cooler_" .. (m.cooler.grade or "good")) end
    -- The team sends the delivered papers' copies back: they are in the folder from now on.
    Story.returnCopies(record, Missions.documentsOf(m))
    Missions.finish(record, m, "done")
end

-- The papers of what a mission delivered: { { id =, variant =, extra = } } as the item shows them (Docs.forItem). Of a
-- contract with two copies only the original counts; the sealed case of an exchange is not a paper.
function Missions.documentsOf(m)
    local list = {}
    local function add(name, mods)
        for _, doc in ipairs(Docs.forItem(nil, name, mods)) do list[#list + 1] = doc end
    end
    if m.soil then
        add("SoilSample", { OA_Stake = m.soil.stake })
        return list
    end
    for _, it in ipairs(m.items or {}) do
        local name = Data.itemName(it.type)
        local mods = it.mods or {}
        if it.mode == "case" then
            -- the case that was left, or the case of a drop that holds the paper
            name = it.inside
        end
        if name and not (m.compare and it.key ~= m.compare.right) then add(name, mods) end
    end
    return list
end

-- Every ten minutes, for each record (the server's tick calls this).
function Missions.tick(record)
    local now = OA.hours()
    local stage, milestones = Story.progress(record)
    local story = Story.section(record)
    if stage > story.seenStage or milestones > story.seenMilestones then
        Story.onStage(record, stage, milestones)
    end
    Story.flushSupply(record)
    local s = Missions.state(record)
    local m = s.active
    if not m then
        if Rewards.level(stage, milestones) and now >= (s.nextAt or 0) and Missions.opened(record) then
            Missions.start(record)
        end
    elseif m.state == "waiting" and not m.story and Story.freshQueued(record) then
        -- a stage's story mission comes before a regular one not started yet
        s.active = nil
        Missions.start(record)
    else
        Missions.tickOne(record, m, now)
    end
    Missions.tickSpecial(record, now)
end

-- Hours left at which an open mission warns once of its deadline ("기한 하루 남음"), and the time a mission must have had
-- for it (a shorter one is short all along: its card says so).
Missions.WARN_HOURS = 24
Missions.WARN_SPAN = 48

-- The deadline's warning, once for each deadline (one moved later, by a lost piece or a swap's slack, warns again).
function Missions.warnDeadline(record, m, now)
    if not m.deadline or m.warned == m.deadline then return end
    local left = m.deadline - now
    if left > Missions.WARN_HOURS or left <= 0 or m.deadline - (m.issued or now) < Missions.WARN_SPAN then return end
    m.warned = m.deadline
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_DayLeft", sub = (Missions.keys(m)), style = "notice",
        fallback = "bad" })
end

-- Real milliseconds at least between two looks at where the found pieces are, from the ten-minute event (it comes many
-- times a real second fast-forwarded; the pieces move on a scale of seconds). A piece found is looked at at once.
Missions.WHERE_MS = 2000

local whereLooks = {}  -- by mission id: the real time (ms) of the last look

-- One running mission: its deadline, how long a sealed box may wait, and the steps that go by time.
function Missions.tickOne(record, m, now)
    if m.state == "open" or m.state == "calling" then
        if m.state ~= "calling" and now > m.deadline then
            if m.scatter then
                Missions.settleScatter(record, m, now)
            else
                Missions.finish(record, m, "expired")
            end
            return
        end
    elseif m.state == "sealed" then
        if now > (m.sealedAt or now) + Rewards.hours(Data.SEALED_LOST_DAYS) then
            Missions.finish(record, m, "lost")
            return
        end
    end
    if m.state == "open" then Missions.warnDeadline(record, m, now) end
    local g = game()
    if m.swap and (m.swap.stage == "waiting" or m.swap.stage == "ready") then Missions.tickSwap(record, m, now) end
    if m.carry and g and g.findItem then Missions.tickCarry(record, m, now) end
    if m.field and m.field.stage == "calling" then Missions.tickField(record, m, now) end
    if m.state == "open" and OA.due(whereLooks, m.id, getTimestampMs(), Missions.WHERE_MS)
        and Missions.lookWhere(record, m) then
        OA.Sync.changed("missions", record.id)
    end
end

-- The record's character died: its running missions end without a result. Nothing waits for their pieces any more;
-- what was placed stays in the world and reads as an expired mission's (Missions.expired). A slot that had a mission
-- waits for its next offer as after any ending (a record the character comes back to, Server's hello, does not get an
-- offer at once); a new character has a record of its own and starts from the first (CANON S19).
function Missions.retire(record)
    local s = record.missions
    if not s then return end
    local g = game()
    for _, m in ipairs(Missions.live(record)) do
        if g and g.release then g.release(m) end
    end
    if s.active then s.nextAt = OA.hours() + intervalHours() end
    s.active = nil
    if s.special and s.special.mission then s.special.nextAt = OA.hours() + Rewards.hours(Rewards.SPECIAL_GAP_DAYS) end
    if s.special then s.special.mission = nil end
    OA.Sync.changed("missions", record.id)
end

-- ---------------------------------------------------------------------------------------------------------------
-- A piece lost in the world.

-- The running mission (taken, not sealed) an item's OA_Mission belongs to, and the piece it is, or nil. An id without a
-- key is the first piece's (a mission's key piece is added after its first was made); a key no piece has is the record
-- inside a case, which comes with the case.
function Missions.pieceOf(record, id)
    local base, key = Missions.parseId(id)
    if not base then return nil end
    for _, m in ipairs(Missions.live(record)) do
        if m.id == base then
            if m.state ~= "open" then return nil end
            local inside
            for _, it in ipairs(m.items or {}) do
                if key == nil or it.key == key then return m, it end
                if it.inside then inside = it end
            end
            if inside then return m, inside end
            return nil
        end
    end
    return nil
end

-- A piece of a running mission was destroyed (a fire emptied the container it was in): the mission goes on, and the
-- player gets the piece again the way it was got. One to be found turns up again at its place; the soil sample is taken
-- again; the exchanged record is waited for again where it was handed over; a target's sample comes from another target.
-- The deadline leaves as much time as the
-- mission had from the start (never less than it had), and a cooler's warming starts again with the new one.
function Missions.replacePiece(record, m, it)
    local g = game()
    it.found, it.where = nil, nil
    if g and g.untrack then g.untrack(m, it) end
    local sub
    if it.mode == "container" or it.mode == "floor" or it.mode == "case" then
        it.placed, it.at = false, nil
        if g and g.placeAgain then g.placeAgain(record, m, it) end
        sub = "IGUI_OA_Title_LostSub_Find"
    elseif m.soil and it.mode == "given" then
        m.soil.taken = false
        sub = "IGUI_OA_Title_LostSub_Soil"
    elseif m.zombies and it.mode == "given" then
        -- a target's sample: another target comes for it (Zombies.wanted)
        for i = #m.items, 1, -1 do
            if m.items[i] == it then table.remove(m.items, i) end
        end
        m.zombies.taken = math.max(0, m.zombies.taken - 1)
        sub = "IGUI_OA_Title_LostSub_Target"
    elseif m.swap and it.mode == "inside" then
        for i = #m.items, 1, -1 do
            if m.items[i] == it then table.remove(m.items, i) end
        end
        m.swap.stage, m.swap.waited, m.swap.at = "waiting", 0, nil
        sub = "IGUI_OA_Title_LostSub_Swap"
    else
        return
    end
    local now = OA.hours()
    -- The time the mission had, as the first loss found it: a second loss gives no more than the first.
    m.span = m.span or (m.deadline - (m.issued or now))
    m.deadline = math.max(m.deadline, now + m.span)
    if m.carry then
        m.carry.start, m.carry.looked = nil, nil
    end
    OA.log("mission", m.id, "piece", tostring(it.key), "destroyed: replaced")
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_Lost", sub = sub, style = "sink", fallback = "bad" })
    OA.Sync.changed("missions", record.id)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Sealing and settling.

-- Which mission an item belongs to: the id from OA_Mission, and the piece's key after '#'.
function Missions.parseId(id)
    if type(id) ~= "string" then return nil end
    local base, key = string.match(id, "^([^#]+)#(%w+)$")
    if base then return base, key end
    return id, nil
end

-- The trade part sealed a box: the mission item in it is judged now (the deadline counts at sealing). entries:
-- { { info = { mission = ..., count = ...}, count = n }, ... }.
function Missions.onSealed(record, boxId, entries)
    local now = OA.hours()
    for _, m in ipairs(Missions.live(record)) do
        if m.state == "open" then Missions.sealedIn(record, m, boxId, entries, now) end
    end
end

-- The pieces of a mission among a sealed box's entries, judged now. A scattered mission counts every piece it finds, a
-- target mission every sample, and is done when it has them all.
function Missions.sealedIn(record, m, boxId, entries, now)
    local found
    for _, entry in ipairs(entries or {}) do
        local info = entry.info or {}
        local base, key = Missions.parseId(info.mission)
        if base == m.id then
            local right = true
            if m.compare then right = (key == m.compare.right) end
            if right then
                if Rewards.judge(m.deadline, now) ~= "ok" then
                    -- Too late: a plain item, no penalty. The mission is over (what a scattered one found pays).
                    if m.scatter then
                        Missions.settleScatter(record, m, now)
                    else
                        Missions.finish(record, m, "expired")
                    end
                    return
                end
                local set = Missions.sealedSet(m)
                if not set then
                    Missions.sealedOk(record, m, boxId, now)
                    return
                end
                if key and set[key] == nil then
                    set[key] = true
                    found = true
                end
            end
        end
    end
    if found then
        m.box = boxId
        if Missions.sealedCount(m) >= Missions.sealedTotal(m) then
            Missions.sealedOk(record, m, boxId, now)
        else
            OA.Sync.changed("missions", record.id)
        end
    end
end

-- The pieces of a mission of several that are sealed in time so far, by key: a scattered mission's, a target mission's
-- samples. Nil for a mission of one piece.
function Missions.sealedSet(m)
    if m.scatter then return m.scatter.found end
    if m.zombies and m.zombies.kind == "target" then return m.zombies.sealed end
    return nil
end

function Missions.sealedCount(m)
    local n = 0
    for _ in pairs(Missions.sealedSet(m) or {}) do n = n + 1 end
    return n
end

function Missions.sealedTotal(m)
    if m.scatter then return m.scatter.total end
    return m.zombies.total
end

-- The pieces of a scattered mission found (sealed in time) so far.
function Missions.scatterCount(m)
    if not m.scatter then return 0 end
    return Missions.sealedCount(m)
end

-- What a scattered mission pays for the pieces it has: the whole set the price (which has the extra in it), a part its
-- share of the price without the extra.
function Missions.scatterPay(m)
    local share = Rewards.scatterShare(Missions.scatterCount(m), m.scatter.total)
    local k = share / (1 + Rewards.SCATTER_BONUS)
    return OA.round(m.credits * k), OA.round(m.trust * k)
end

-- A scattered mission whose time is out: the pieces found are paid at the next settlement, none is an expired mission.
function Missions.settleScatter(record, m, now)
    if Missions.scatterCount(m) == 0 then return Missions.finish(record, m, "expired") end
    Missions.sealedOk(record, m, nil, now)
end

-- What the sample cooler pays sealed at `now`: its state then (the temperature's quality) with the mission's extras.
-- Returns credits, trust and the temperature.
function Missions.carryPay(m, now)
    local temp = Missions.coolerTemp(m, now)
    local credits, trust = Rewards.reward(m.level, true, Rewards.coolerQuality(temp), creditScale())
    credits = OA.round(credits * (1 + (m.danger or 0) + (m.streakPay or 0) + (m.far or 0) + (m.support or 0)))
    return credits, Rewards.trustWithBonus(trust, m.danger, m.far), temp
end

function Missions.sealedOk(record, m, boxId, now)
    local credits, trust = m.credits, m.trust
    if m.carry then
        local temp
        credits, trust, temp = Missions.carryPay(m, now)
        m.cooler = { temp = temp, grade = Rewards.coolerGrade(temp) }
    elseif m.scatter then
        credits, trust = Missions.scatterPay(m)
    end
    m.pay = { credits = credits, trust = trust }
    m.state = "sealed"
    m.sealedAt = now
    m.box = boxId
    local g = game()
    if g and g.release then g.release(m) end
    OA.Sync.changed("missions", record.id)
end

-- The missions a box about to be sealed has items of, open and in time (the seal confirmation tells their reward):
-- { { m, credits, trust } }: the sample cooler's as its state now makes it, nil where pieces still to come decide it
-- (a scattered mission's, a target mission's).
function Missions.sealing(record, infos, now)
    now = now or OA.hours()
    local out, seen = {}, {}
    for _, info in ipairs(infos or {}) do
        local base = Missions.parseId(info.mission)
        for _, m in ipairs(base and Missions.live(record) or {}) do
            if m.id == base and not seen[m] and m.state == "open" and Rewards.judge(m.deadline, now) == "ok" then
                seen[m] = true
                local credits, trust
                if m.carry then
                    credits, trust = Missions.carryPay(m, now)
                elseif not Missions.sealedSet(m) then
                    credits, trust = m.credits, m.trust
                end
                out[#out + 1] = { m = m, credits = credits, trust = trust }
            end
        end
    end
    return out
end

-- The credits the sealed missions pay at the next settlement (Missions.pay).
function Missions.sealedPay(record)
    local sum = 0
    for _, m in ipairs(Missions.live(record)) do
        if m.state == "sealed" then sum = sum + OA.round(m.pay and m.pay.credits or m.credits or 0) end
    end
    return sum
end

-- The trade part settled a helicopter's delivery: every sealed mission is paid. The arrival settles all of a record's
-- sealed boxes at once; `result.boxes` is how many it took (none: nothing sealed was in it, nothing is paid).
function Missions.onSettled(record, result)
    if result and result.boxes and result.boxes <= 0 then return end
    for _, m in ipairs(Missions.live(record)) do
        if m.state == "sealed" then Missions.pay(record, m) end
    end
end

-- The economy asks, as it values a mission item: is it a plain item now (1,000 credits and 5 trust, no mission)?
-- True for an item whose mission is over, past its time, or not this character's; false while the mission is open and
-- in time, and while its box waits for the helicopter.
function Missions.expired(id)
    local base = Missions.parseId(id)
    local number = string.match(tostring(base), "^M(%d+)%-%d+$")
    if not number then return true end
    for _, record in pairs(OA.Store.players()) do
        if tostring(record.number or 0) == number then
            for _, m in ipairs(Missions.live(record)) do
                if m.id == base then
                    if m.state == "sealed" or m.state == "calling" then return false end
                    return Rewards.judge(m.deadline, OA.hours()) ~= "ok"
                end
            end
            return true
        end
    end
    return true
end

function Story.missionExpired(id)
    return Missions.expired(id)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Special steps.

-- The sample cooler: its clock starts when it is first in the player's hands.
function Missions.coolerTemp(m, now)
    local start = m.carry and m.carry.start
    if not start then return Rewards.COOLER_START end
    return Rewards.coolerTemp(now - start)
end

-- An item came into a character's things (the economy's pickup hook, as it happens): the sample cooler's clock
-- starts now, whatever the rate of the ten-minute look below.
function Missions.pickedUp(record, item)
    -- A survivor's things (Story/Scene): the first one taken says a line.
    if OA.Scene then OA.Scene.pickedUp(record, item) end
    Missions.lookForPiece(record, item)
    local m = record.missions and record.missions.active
    if not (m and m.carry) or m.carry.start then return end
    local g = game()
    if g and g.holds and g.holds(item, m.id) then m.carry.start = OA.hours() end
end

-- ---------------------------------------------------------------------------------------------------------------
-- A piece found: from then on the maps show where the item is instead of the mission's circle.

Missions.allFound = OA.StoryView.allFound

-- A piece is in the player's hands for the first time (picked up, taken, handed over): it is found, and its item is
-- followed (Game.track) for the maps.
function Missions.found(record, m, it, item)
    local g = game()
    if g and g.track then g.track(m, it, item) end
    if it.found then return end
    it.found = true
    Missions.securedTitle(record, m, it)
    -- A story's item first in hands: its monologue (CommsData "say:<story>:pickup") and what waits at its stage (not
    -- for what the player does not fetch: an exchange's drop case, the record inside it is the item).
    if m.story and View.fetched(m, it) then
        if OA.Story then OA.Story.monologue(record, m.chosen and (m.story .. "_" .. m.chosen) or m.story, "pickup") end
        if OA.Stage then OA.Stage.event(record, m, "pickup") end
    end
    Missions.lookWhere(record, m)
    OA.Sync.changed("missions", record.id)
end

-- How many of a mission's fetched pieces are found.
function Missions.foundCount(m)
    local n = 0
    for _, it in ipairs(m.items or {}) do
        if it.found and View.fetched(m, it) then n = n + 1 end
    end
    return n
end

-- The title of a piece first in hands: "요청 물품 확보" over the mission's title, with how many of how many for a mission
-- of several. Not for a plain piece, the case a swap leaves, or the comparison (either of its two is picked up alike).
function Missions.securedTitle(record, m, it)
    if m.compare or not View.fetched(m, it) then return end
    local titleKey = (Missions.keys(m))
    local total = (m.scatter and m.scatter.total) or (m.zombies and m.zombies.kind == "target" and m.zombies.total) or nil
    local detail = { key = "IGUI_OA_Title_Secured", sub = titleKey, style = "discovery", size = "minor",
        fallback = "good" }
    if total then
        detail.sub, detail.subArgs = "IGUI_OA_Title_SecuredOf", { { key = titleKey }, Missions.foundCount(m), total }
    end
    OA.Sync.title(record.id, detail)
end

-- An item came into the player's things: a running mission's piece, or a bag that holds one not found yet (an
-- exchange's drop case, a piece itself, holds the record). A bag is looked into only while a piece is still to be found.
function Missions.lookForPiece(record, item)
    local md = item:hasModData() and item:getModData() or nil
    local id = md and md.OA_Mission
    if id then
        local m, it = Missions.pieceOf(record, id)
        if it then Missions.found(record, m, it, item) end
        if not it or View.fetched(m, it) then return end
    end
    local g = game()
    if not (g and g.pieceIn and instanceof(item, "InventoryContainer")) then return end
    for _, m in ipairs(Missions.live(record)) do
        if m.state == "open" and not Missions.allFound(m) then
            local inner = g.pieceIn(item, m.id)
            local innerId = inner and inner:getModData().OA_Mission
            local found, it = Missions.pieceOf(record, innerId)
            if it then Missions.found(record, found, it, inner) end
        end
    end
end

-- Where the found pieces are now (Game.whereNow: the item followed), kept on each piece as `where` = { x, y, z,
-- carried } for the maps and saved with the mission. A piece whose item is not followed (a world loaded since) keeps
-- the last place until its item is followed again: carried, or picked up. True when a place changed.
function Missions.lookWhere(record, m)
    local g = game()
    if not (g and g.whereNow) then return false end
    local changed = false
    for _, it in ipairs(m.items or {}) do
        if it.found then
            local x, y, z, carried = g.whereNow(record, m, it)
            if x then
                local w = it.where
                if not w or w.x ~= x or w.y ~= y or w.z ~= z or (w.carried == true) ~= carried then
                    it.where = { x = x, y = y, z = z, carried = carried or nil }
                    changed = true
                end
            end
        end
    end
    return changed
end

-- Real milliseconds at least between two looks for the sample cooler in a character's things. A look walks the whole
-- inventory and only shows the warmth on the item (the warmth itself is counted from carry.start), and ten game
-- minutes are 25 s of real time at the default day length but some 0.6 s fast-forwarded (x40) and less asleep.
Missions.CARRY_LOOK_MS = 5000

local carryLooks = {}  -- by record id: the real time (ms) of the last look for the cooler

-- The look also starts the clock of a cooler that came into the player's hands some way the pickup hook does not see:
-- from the last look that did not find it (carry.looked, world hours), so that the warming never loses time.
function Missions.tickCarry(record, m, now)
    if not OA.due(carryLooks, record.id, getTimestampMs(), Missions.CARRY_LOOK_MS) then return end
    local g = game()
    local item = g.findItem(record, m.id)
    if not item then
        if not m.carry.start then m.carry.looked = now end
        return
    end
    if not m.carry.start then m.carry.start = m.carry.looked or now end
    if g.setCoolerText then g.setCoolerText(item, Missions.coolerTemp(m, now)) end
end

-- The sealed case is put in the drop (the player holds it, in reach of the place): the wait begins, and the player has
-- to stay about for the record to appear.
function Missions.swap(record, character)
    local g = game()
    local x, y = g.playerPosition(record)
    -- (the story's clinic and a special request may both wait for a case: the one the player stands at)
    for _, m in ipairs(Missions.live(record)) do
        if m.swap and m.swap.stage == "needcase" and m.state == "open" then
            local p = m.site
            if x and p and Places.distance(x, y, p.x, p.y) <= Data.CASE_RANGE then
                if g.takeItem and not g.takeItem(character, "SampleCase") then return false end
                m.swap.stage = "waiting"
                m.swap.waited = 0
                m.swap.at = OA.hours()
                if m.story then Story.monologue(record, m.story, "put") end
                OA.Sync.changed("missions", record.id)
                return true
            end
        end
    end
    return false
end

-- The wait (waited, hours) adds up the game time from each look that found the player near (swap.at) to the next, not
-- a sixth of an hour a look: the ten-minute event comes many times a real second fast-forwarded and may be skipped
-- or come in a batch. A look that finds the player away (or nowhere) stops the count until one finds them near again.
-- The stage follows the wait (Stage.progress "wait"). When it is over the player says so, wherever they are, and the
-- record is swapped in at the next look that finds the drop out of their sight (stage "ready"): someone came by.
function Missions.tickSwap(record, m, now)
    local g = game()
    if not g then return end
    if m.swap.stage == "ready" then
        if not g.dropSeen or not g.dropSeen(record, m) then Missions.deliverSwap(record, m) end
        return
    end
    local x, y = g.playerPosition(record)
    local p = m.site
    if not x or not p or Places.distance(x, y, p.x, p.y) > Data.CASE_RANGE then
        m.swap.at = nil
        return
    end
    if m.swap.at and now > m.swap.at then m.swap.waited = m.swap.waited + (now - m.swap.at) end
    m.swap.at = now
    if OA.Stage then OA.Stage.progress(record, m, "wait", math.min(1, m.swap.waited / Data.SWAP_WAIT_HOURS)) end
    if m.swap.waited >= Data.SWAP_WAIT_HOURS then
        m.swap.stage = "ready"
        if m.story then Story.monologue(record, m.story, "waited") end
        OA.Sync.changed("missions", record.id)
        if not g.dropSeen or not g.dropSeen(record, m) then Missions.deliverSwap(record, m) end
    end
end

-- The record appears in the case (or in the player's hands when the case is gone).
function Missions.deliverSwap(record, m)
    local g = game()
    local p = m.site
    m.swap.stage = "done"
    local it = { key = "A", type = Data.fullType(m.swap.item), mode = "inside", placed = false,
                 mods = { OA_Variant = m.facility }, x = p.x, y = p.y, z = p.z }
    m.items[#m.items + 1] = it
    if g and g.deliverInside then g.deliverInside(record, m, it) end
    OA.Sync.changed("missions", record.id)
end

-- The field call device is used at the place: the mission item is sealed on the spot and the helicopter comes.
local CALL_REASONS = { none = 0, range = 1, device = 2, item = 3 }

function Missions.fieldCall(record, character)
    -- (the story's field trade and a special request may both be open: the one the player stands at; when none can
    -- be called, the reason of the one that came furthest)
    local why = "none"
    for _, m in ipairs(Missions.live(record)) do
        if m.field and m.state == "open" then
            local ok, reason = Missions.callField(record, character, m)
            if ok then return true end
            if (CALL_REASONS[reason] or 0) > CALL_REASONS[why] then why = reason end
        end
    end
    return false, why
end

function Missions.callField(record, character, m)
    local g = game()
    local x, y, z = g.playerPosition(record)
    if not x or not m.area then return false, "range" end
    if Places.distance(x, y, m.area.x, m.area.y) > m.area.r + Data.FIELD_RANGE then return false, "range" end
    if g.takeItem and not g.takeItem(character, "FieldCallDevice") then return false, "device" end
    if g.takeMissionItem and not g.takeMissionItem(character, m.id) then return false, "item" end
    local now = OA.hours()
    local lo, hi = Data.FIELD_ARRIVAL_HOURS[1], Data.FIELD_ARRIVAL_HOURS[2]
    local rewards = OA.Trust and OA.Trust.rewards and OA.Trust.rewards(record)
    if rewards and rewards.arrival then lo, hi = rewards.arrival.min or lo, rewards.arrival.max or hi end
    m.field.stage = "calling"
    m.field.x, m.field.y, m.field.z = x, y, z
    m.field.arrive = now + lo + (hi - lo) * OA.randomFloat(0, 1)
    if Rewards.judge(m.deadline, now) ~= "ok" then
        m.field.late = true
    end
    m.state = "calling"
    if g.release then g.release(m) end
    -- a story mission's call on the spot, as the helicopter comes (S5F, S8F); what waits for it at the stage wakes
    if m.story then Story.call(record, "field:" .. m.story) end
    if OA.Stage then OA.Stage.event(record, m, "heli") end
    OA.Sync.notice(record.id, "IGUI_OA_Story_UI_Field_calling", {})
    OA.Sync.changed("missions", record.id)
    return true
end

-- While the helicopter is on its way its noise goes out every ten minutes; when it comes the box is taken and paid.
function Missions.tickField(record, m, now)
    local g = game()
    if g and g.noise then g.noise(record, m.field.x, m.field.y, m.field.z) end
    if now >= m.field.arrive then
        if m.field.late then
            Missions.finish(record, m, "expired")
        else
            Missions.pay(record, m)
        end
    end
end

-- The player took the soil sample (a drop site's rocks, or bare ground): it becomes the mission item.
function Missions.soil(record, character)
    local s = Missions.state(record)
    local m = s.active
    if not (m and m.soil and m.state == "open" and not m.soil.taken) then return false end
    local g = game()
    if m.soil.variant == "site" then
        local x, y = g.playerPosition(record)
        if not x or Places.distance(x, y, m.soil.x, m.soil.y) > Data.SOIL_RANGE then return false end
    end
    local item
    if g.giveMissionItem then
        item = g.giveMissionItem(character, Data.fullType("SoilSample"), m.id, { OA_Stake = m.soil.stake }, record)
    end
    m.soil.taken = true
    m.items[1] = { key = "A", type = Data.fullType("SoilSample"), mode = "given", placed = true }
    if item then Missions.found(record, m, m.items[1], item) end
    OA.Sync.changed("missions", record.id)
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Taking another mission (DESIGN-terminal 7.2).

-- Whether the card offers 'take another' for a mission, and at what price: { trust = the trust it costs, left = how many
-- there are left this week (0 or 1) } or nil. Only a regular or contract mission offered or open, and one of several
-- pieces only until a piece is sealed (it would be left a plain item).
function Missions.rerollOffer(record, m)
    if not m or m.special or (m.state ~= "open" and m.state ~= "waiting") then return nil end
    if m.kind ~= "regular" and m.kind ~= "contract" then return nil end
    if Missions.sealedCount(m) > 0 then return nil end
    local s = Missions.state(record)
    local used = s.reroll ~= nil and s.reroll.week == OA.week()
    return { trust = Rewards.rerollCost(m.level), left = used and 0 or 1 }
end

-- The mission is given back for another one, once a week, for some trust. The new one is made first: when none can be
-- made nothing is lost. What the old one left in the world stays and counts as a plain item. An offer not started gives
-- another offer. Returns true when taken.
function Missions.reroll(record)
    local s = Missions.state(record)
    local m = s.active
    local offer = Missions.rerollOffer(record, m)
    if not offer or offer.left <= 0 then return false end
    local stage, milestones = Story.progress(record)
    local level = Rewards.level(stage, milestones)
    if not level then return false end
    local fresh = createPlain(record, level)
    if not fresh then return false end
    Missions.price(record, fresh)
    local g = game()
    if g and g.release then g.release(m) end
    Story.loseTrust(record, offer.trust)
    s.reroll = { week = OA.week() }
    OA.Sync.changed("trade", record.id)
    if m.state == "waiting" then
        toWaiting(fresh)
        s.active = fresh
        OA.Sync.changed("missions", record.id)
    else
        Missions.begin(record, fresh)
    end
    OA.log("mission", m.id, "taken again as", fresh.id, "for", record.number)
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- The special request (DESIGN-terminal 6.3): two offered at a time at the field terminal, one taken. It runs in a slot of
-- its own beside the main mission (Missions.live), with the story's exchange, retrieve and field-trade steps.

-- Is the slot open for the record: a field line (record.heli.line) and the second level. Returns that, and the level.
function Missions.specialOpen(record)
    local stage, milestones = Story.progress(record)
    local level = Rewards.level(stage, milestones)
    if not level or level < 2 then return false, level end
    return (record.heli ~= nil and record.heli.line == true), level
end

-- Two different requests for an offer, not the ones of the last offer; the ones whose request copy has not come yet
-- are likelier, and the second is of another form when there is one. Returns the two entries of Data.SPECIALS.
function Missions.pickSpecials(record, int)
    local sp = Missions.special(record)
    local sent = {}
    for _, req in ipairs(Story.section(record).requests or {}) do sent[req.id] = true end
    local skip = {}
    for _, id in ipairs(sp.last or {}) do skip[id] = true end
    local pool = {}
    for _, entry in ipairs(Data.SPECIALS) do
        if not skip[entry.id] then pool[#pool + 1] = { entry = entry, weight = sent[entry.request] and 1 or 3 } end
    end
    if #pool < 2 then
        pool = {}
        for _, entry in ipairs(Data.SPECIALS) do pool[#pool + 1] = { entry = entry, weight = 1 } end
    end
    local first = weighted(pool, int)
    local others, same = {}, {}
    for _, e in ipairs(pool) do
        if e ~= first then
            if e.entry.form ~= first.entry.form then others[#others + 1] = e else same[#same + 1] = e end
        end
    end
    local second = weighted(#others > 0 and others or same, int)
    return first.entry, second.entry
end

-- One offered request: where it is (a site in the band of the level above, its circle) and the danger there.
local function specialOption(record, entry, level, taken)
    local site = Missions.pickSite(record, Rewards.specialBandLevel(level), entry.site or {}, taken)
    if not site then return nil end
    local cx, cy, r = Places.circle(site.x, site.y, Places.circleRadius(level))
    local area = { x = cx, y = cy, r = r }
    return { id = entry.id, form = entry.form, site = site, facility = entry.facility, area = area,
        danger = Missions.dangerOf({ area }) }
end

-- Two requests are offered. False when two cannot be made now.
function Missions.offerSpecial(record, level)
    local first, second = Missions.pickSpecials(record)
    local a = specialOption(record, first, level)
    local b = a and specialOption(record, second, level, a.site.key)
    if not (a and b) then return false end
    local s = Missions.state(record)
    s.seq = s.seq + 1
    Missions.special(record).offer = { seq = s.seq, at = OA.hours(), a = a, b = b }
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_NewRequest", sub = "IGUI_OA_Title_CheckTerminal", style = "notice" })
    OA.log("special request offered to", record.number, a.id, b.id)
    OA.Sync.changed("missions", record.id)
    return true
end

-- The request taken, as a mission: its form's steps, the level's reward doubled in credits, the fourteen days, the
-- circle that was offered.
local function createSpecial(record, opt, level)
    local entry = Data.SPECIAL_BY_ID[opt.id]
    if not (entry and opt.site) then return nil end
    local m = newMission(record, "special", level, nil)
    m.special = true
    m.facility = entry.facility
    Story.useSite(opt.site.key)
    m.form = entry.form
    m.title = entry.id
    m.credits, m.trust = Rewards.specialReward(level, creditScale())
    m.deadline = m.issued + Rewards.hours(Rewards.SPECIAL_DAYS)
    local ax, ay = Missions.anchor(record)
    if ax then m.anchor = { x = ax, y = ay } end
    if entry.form == "exchange" then
        local it = placeAtSite(m, "DeadDropCase", "CASE", opt.site, { OA_Drop = "" }, "floor")
        it.mode = "case"
        m.swap = { stage = "needcase", waited = 0, item = entry.item }
        Story.queueSupply(record, "SampleCase", nil)
    elseif entry.form == "fetch" then
        local it = placeAtSite(m, "DeadDropCase", "CASE", opt.site,
            { OA_Variant = entry.facility, OA_Inside = entry.item }, "floor")
        it.mode = "case"
        it.inside = entry.item
        m.drop = { item = entry.item }
    else
        placeAtSite(m, entry.item, "A", opt.site, { OA_Variant = entry.facility })
        m.field = { stage = "needdevice" }
        Story.queueSupply(record, "FieldCallDevice", nil)
    end
    m.area = { x = opt.area.x, y = opt.area.y, r = opt.area.r }
    Missions.price(record, m, opt.danger)
    return m
end

-- The terminal chose one of the two offered ('a' or 'b'): it becomes the request, the other closes, the staff's request
-- copy goes to the folder. Returns true when taken.
function Missions.acceptSpecial(record, option)
    local open, level = Missions.specialOpen(record)
    if not open then return false end
    local sp = Missions.special(record)
    local offer = sp.offer
    local opt = offer and (option == "a" or option == "b") and offer[option] or nil
    if not opt or sp.mission then return false end
    local m = createSpecial(record, opt, level)
    if not m then return false end
    sp.last = { offer.a.id, offer.b.id }
    sp.offer = nil
    sp.mission = m
    if OA.Scene then OA.Scene.begin(record, m) end
    local entry = Data.SPECIAL_BY_ID[opt.id]
    local req = Story.addRequestCopy(record, entry.form, entry.request)
    m.request = req and req.no or nil
    local g = game()
    for _, it in ipairs(m.items) do
        if not it.placed and g and g.request then g.request(record, m, it) end
    end
    OA.log("special request", m.id, m.title, "taken by", record.number)
    OA.Sync.changed("missions", record.id)
    return true
end

-- Every ten minutes: the request running is looked after like any mission; with none, and none offered, the next offer
-- comes when its time has.
function Missions.tickSpecial(record, now)
    local sp = record.missions and record.missions.special
    if sp and sp.mission then return Missions.tickOne(record, sp.mission, now) end
    if sp and sp.offer then return end
    local open, level = Missions.specialOpen(record)
    if not open then return end
    if now >= (sp and sp.nextAt or 0) then Missions.offerSpecial(record, level) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- What the windows read.

-- A plain description of a mission for the tab: strings and numbers, no text (the tab translates).
local function describeMission(m, now)
    local info = {}
    info.id = m.id
    info.kind = m.kind
    info.story = m.story
    info.title = m.title
    info.state = m.state
    info.facility = m.facility
    info.area = m.area
    info.area2 = m.area2
    -- the time left once started; an offer's days for then
    info.left = m.deadline and (m.deadline - now) or nil
    info.span = m.span
    info.credits = (m.pay and m.pay.credits) or m.credits
    info.trust = (m.pay and m.pay.trust) or m.trust
    info.options = m.options
    info.swap = m.swap and m.swap.stage
    info.field = m.field and m.field.stage
    info.compare = m.compare and m.compare.serial
    info.stakeNo = m.stakeNo
    info.contract = m.contract
    info.soil = m.soil and m.soil.variant
    info.cooler = m.carry and { temp = Missions.coolerTemp(m, now), started = m.carry.start ~= nil }
    info.level = m.level
    info.seq = m.seq
    -- What the reward is made of, for the card's line under the story: the base credits, the danger pay and the distance
    -- pay (fractions, 0 to 0.3), the streak it was made at and its bonus, the flight support's pay, the urgent flag.
    info.base, info.danger, info.streak, info.urgent = m.base, m.danger, m.streak, m.urgent
    info.far, info.streakPay, info.support = m.far, m.streakPay, m.support
    -- The scattered pieces (how many of how many are found), the weight of a heavy sample, a special request's form
    -- and its request copy's number (the folder's R-number).
    info.scatter = m.scatter and { total = m.scatter.total, found = Missions.scatterCount(m) } or nil
    info.heavy = m.heavy
    -- A zombie mission's count: { kind, total, done } (the kills of an area clear, the samples taken from targets).
    if m.zombies then
        local z = m.zombies
        info.zombies = { kind = z.kind, total = z.total, done = z.kind == "clear" and z.killed or z.taken }
    end
    info.form = m.form
    info.request = m.request
    -- The item to find: the first piece the player fetches (not the case a swap leaves); before there is one (an offer,
    -- a swap waiting for its case), the item the story or the pickup is for, when there is one only.
    local first
    for _, it in ipairs(m.items or {}) do
        if not first and View.fetched(m, it) then first = it end
    end
    if first then
        info.item = Data.itemName(first.type)
    else
        local story = m.story and Data.STORIES[m.story]
        info.item = (story and not story.options and story.item) or (Data.ITEMS[tostring(m.title)] and m.title) or nil
    end
    -- A found piece not sealed yet (`held`), and whether every piece wanted is found (`gathered`): the card's next step.
    -- The comparison tells neither (which of its two is the one is the player's to judge).
    if m.state == "open" and not m.compare then
        local sealed = Missions.sealedSet(m) or {}
        for _, it in ipairs(m.items or {}) do
            if it.found and View.fetched(m, it) and not sealed[it.key] then info.held = true end
        end
        local z = m.zombies
        info.gathered = Missions.allFound(m) and not (z and z.kind == "target" and z.taken < z.total)
    end
    return info
end

function Missions.describe(record)
    local s = Missions.state(record)
    local m = s.active
    local now = OA.hours()
    local info = { nextIn = math.max(0, (s.nextAt or 0) - now), results = s.results }
    info.special = Missions.specialSlot(record)
    if not m then return info end
    for k, v in pairs(describeMission(m, now)) do info[k] = v end
    -- The card's 'take another' button: { trust = what it costs, left = how many this week } or nil when the mission
    -- cannot be swapped.
    info.reroll = Missions.rerollOffer(record, m)
    return info
end

-- The special request's slot for the tab: nil while the record has none (no field line, or below the second level), else
-- { state = "mission", mission = (describe's table) }, { state = "offer", options = { a = {...}, b = {...} } } or
-- { state = "wait", nextIn = hours to the next offer }. An option is { id, form, place, area, danger, credits, trust,
-- days }.
function Missions.specialSlot(record)
    local sp = record.missions and record.missions.special
    local now = OA.hours()
    if sp and sp.mission then return { state = "mission", mission = describeMission(sp.mission, now) } end
    local open, level = Missions.specialOpen(record)
    if not open then return nil end
    if sp and sp.offer then
        local credits, trust = Rewards.specialReward(level, creditScale())
        local options = {}
        for _, key in ipairs({ "a", "b" }) do
            local opt = sp.offer[key]
            local far = Missions.farOf(record, opt.area, Rewards.specialBandLevel(level))
            options[key] = { id = opt.id, form = opt.form, facility = opt.facility, area = opt.area, danger = opt.danger, far = far,
                credits = Rewards.withBonus(credits, opt.danger, 0, far, supportPay(record)),
                trust = Rewards.trustWithBonus(trust, opt.danger, far), days = Rewards.SPECIAL_DAYS }
        end
        return { state = "offer", options = options, seq = sp.offer.seq }
    end
    return { state = "wait", nextIn = math.max(0, (sp and sp.nextAt or 0) - now) }
end

return Missions
