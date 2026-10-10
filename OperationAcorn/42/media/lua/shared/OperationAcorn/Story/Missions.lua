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
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Story"
local OA = OperationAcorn
local Data, Rewards, Places, Story = OA.StoryData, OA.Rewards, OA.Places, OA.Story
local Missions = {}
OA.Missions = Missions

Missions.game = nil

local function game()
    return Missions.game
end

-- A record's `missions` section: { active = mission | nil, nextAt = world age, seq = n, results = { done =, expired =,
-- lost = } }.
function Missions.state(record)
    local s = OA.Store.section(record, "missions")
    if not s.version then
        s.version = 1
        s.seq = 0
        s.nextAt = 0
        s.results = { done = 0, expired = 0, lost = 0 }
    end
    return s
end

function Missions.active(record)
    return Missions.state(record).active
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

local function deadlineHours()
    return Rewards.hours(OA.option("MissionDeadline") or 7)
end

local function intervalHours()
    return Rewards.hours(OA.option("MissionInterval") or 3)
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

-- The trade part (or the player's first mission) fixes the base's position: kept for the band.
function Story.setAnchor(record, x, y, z)
    Story.section(record).anchor = { x = x, y = y, z = z or 0 }
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
        kind = kind,            -- "regular" | "story" | "contract"
        story = story,
        level = level,
        state = "open",
        issued = now,
        deadline = now + deadlineHours(),
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

local function fieldNoteId()
    if OA.random(1, 100) <= Data.FIELD_NOTE_CHANCE then
        return "note_" .. tostring(OA.random(1, Data.FIELD_NOTES))
    end
    return nil
end

local function createRegular(record, level)
    local p, ax, ay = pickBuildingPlace(record, level)
    if not p then return nil end
    local kind = weighted(Data.REGULAR)
    local m = newMission(record, "regular", level, nil)
    m.title = kind.item
    m.anchor = { x = ax, y = ay }
    local mods = {}
    if Data.ITEMS[kind.item].note then mods.OA_Note = fieldNoteId() end
    m.items[1] = placementFrom(kind.item, "A", p, mods)
    circleFor(m, p.x, p.y)
    return m
end

-- The candidate list of a story as Places wants it ({ x, y, id }).
local function candidatesOf(ids, closed)
    local list = {}
    for _, id in ipairs(ids) do
        local p = Data.PLACES[id]
        if p then list[#list + 1] = { x = p.x, y = p.y, id = id, closed = closed and closed[id] } end
    end
    return list
end

-- Picks a place of a story mission among its candidates: the id, and why.
function Missions.pickStoryPlace(record, ids, level, opts)
    local ax, ay = Missions.anchor(record)
    if not ax then
        -- No base known: any candidate.
        local id = ids[OA.random(1, #ids)]
        return id, "any"
    end
    local lo, hi = Rewards.band(level)
    local cands = candidatesOf(ids)
    local i, why = Places.pickCandidate(cands, ax, ay, lo, hi, opts)
    if not i then return nil end
    return cands[i].id, why
end

local function storyMission(record, def, id, level)
    local m = newMission(record, "story", level, id)
    m.title = id
    local ax, ay = Missions.anchor(record)
    if ax then m.anchor = { x = ax, y = ay } end
    return m
end

-- One piece at a candidate place of a story.
local function placeStoryPiece(m, itemName, key, placeId, mods, mode)
    local p = Data.PLACES[placeId]
    m.place = placeId
    local it = placementFrom(itemName, key, p, mods, mode)
    m.items[#m.items + 1] = it
    circleFor(m, p.x, p.y)
    return it
end

-- Is there a building at the place on the map (the bunker may not be one the game lets us use).
local function placeUsable(placeId)
    local g = game()
    local p = Data.PLACES[placeId]
    if g and g.buildingExists and p then return g.buildingExists(p.x, p.y, p.z) end
    return true
end

local function createSwap(record, def, id, level)
    local m = storyMission(record, def, id, level)
    local placeId = Missions.pickStoryPlace(record, def.places, level)
    if not placeId then return nil end
    local it = placeStoryPiece(m, "DeadDropCase", "CASE", placeId, { OA_Drop = "" }, "floor")
    it.mode = "case"
    m.swap = { stage = "needcase", waited = 0, item = def.item }
    -- The sealed case comes in the next supply crate: the deadline starts later.
    m.deadline = m.deadline + Rewards.hours(Data.SWAP_SLACK_DAYS)
    Story.queueSupply(record, "SampleCase", nil)
    return m
end

local function createFetch(record, def, id, level, itemOverride, placeIds, opts)
    local m = storyMission(record, def, id, level)
    local placeId = Missions.pickStoryPlace(record, placeIds or def.places, level, opts or { ignoreBand = def.ignoreBand })
    if not placeId then return nil end
    local item = itemOverride or def.item
    local it = placeStoryPiece(m, item, "A", placeId, { OA_Variant = placeId })
    if def.condition == "locked" then it.lock = true end
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

local function createDropFetch(record, def, id, level)
    local m = storyMission(record, def, id, level)
    local placeId = def.places[1]
    if not placeUsable(placeId) then placeId = def.fallback end
    local it = placeStoryPiece(m, "DeadDropCase", "CASE", placeId, { OA_Variant = placeId, OA_Inside = def.item }, "floor")
    it.mode = "case"
    it.inside = def.item
    m.drop = { item = def.item }
    return m
end

local function createChoice(record, def, id, level)
    local m = storyMission(record, def, id, level)
    m.state = "offer"
    m.options = { a = true, b = true }
    return m
end

-- The terminal chose: the picked option becomes the mission, the other closes for good.
function Missions.choose(record, option)
    local s = Missions.state(record)
    local m = s.active
    if not (m and m.state == "offer" and m.options and m.options[option]) then return false end
    local def = Data.STORIES[m.story]
    local opt = def and def.options and def.options[option]
    if not opt then return false end
    local placeId = Missions.pickStoryPlace(record, opt.places, m.level, { ignoreBand = opt.ignoreBand })
    if not placeId then return false end
    m.chosen = option
    m.options = nil
    m.state = "open"
    m.deadline = OA.hours() + deadlineHours()
    placeStoryPiece(m, opt.item, "A", placeId, { OA_Variant = placeId })
    m.title = m.story .. "_" .. option
    Story.section(record).chosen[m.story] = option
    Missions.begin(record, m)
    return true
end

-- Two copies, one original: the original's serial is what the terminal copy shows.
local function createCompare(record, entry, level)
    local g = game()
    local m = newMission(record, "contract", level, nil)
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

-- A contract mission at a drop site's stake: the number tag lies by the stake.
local function createStake(record, entry, level)
    local sites = OA.Sites
    if not (sites and sites.list) then return nil end
    local ax, ay = Missions.anchor(record)
    if not ax then return nil end
    local lo, hi = Rewards.band(level)
    local cands = {}
    for _, site in ipairs(sites.list()) do
        if site.state ~= "failed" then cands[#cands + 1] = { x = site.x, y = site.y, id = site.n } end
    end
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

-- A contract mission at one of its places or any building.
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
        local placeId = Missions.pickStoryPlace(record, entry.places, level)
        if placeId then
            placeStoryPiece(m, entry.item, "A", placeId, { OA_Variant = placeId })
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
local function createSoil(record, def, id, level)
    local m = storyMission(record, def, id, level)
    local s = Story.section(record)
    local sites = OA.Sites
    local seen = {}
    for n in pairs(s.sitesSeen) do
        local site = sites and sites.byNumber and sites.byNumber(n)
        if site then seen[#seen + 1] = site end
    end
    if #seen > 0 then
        local site = seen[OA.random(1, #seen)]
        m.soil = { site = site.n, stake = site.stake, x = site.x, y = site.y, variant = "site" }
        m.place = nil
        circleFor(m, site.x, site.y)
        m.title = "soil_site"
    else
        m.soil = { variant = "plain" }
        m.title = "soil_plain"
    end
    return m
end

local STORY_BUILDERS = {
    fetch = createFetch, carry = createFetch, swap = createSwap, field = createField,
    dropfetch = createDropFetch, choice = createChoice, soil = createSoil,
}

local function createStoryMission(record, entry, level)
    local def = Data.STORIES[entry.id] or Data.REVISITS[entry.id]
    if not def then return nil end
    local build = STORY_BUILDERS[def.kind]
    if not build then return nil end
    return build(record, def, entry.id, level)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Starting, running and ending.

-- The mission is on its way: kept in the record, its items waiting for their places, the map told.
function Missions.begin(record, m)
    local s = Missions.state(record)
    s.active = m
    if m.state ~= "offer" then
        local g = game()
        for _, it in ipairs(m.items) do
            if not it.placed and g and g.request then g.request(record, m, it) end
        end
    end
    OA.Sync.changed("missions", record.id)
end

-- The translation keys of a mission's title and brief by its kind (the title is the story id, the item or the contract
-- id). `m` is a mission or the tab's description of one.
function Missions.keys(m)
    local prefix, brief = "Title_", "Brief_"
    if m.kind == "regular" then
        prefix, brief = "RegTitle_", "RegBrief_"
    elseif m.kind == "contract" then
        prefix, brief = "ConTitle_", "ConBrief_"
    end
    return "IGUI_OA_Story_" .. prefix .. tostring(m.title), "IGUI_OA_Story_" .. brief .. tostring(m.title)
end

-- Starts the next mission if one is due. Returns it.
function Missions.start(record)
    local stage, milestones = Story.progress(record)
    local level = Rewards.level(stage, milestones)
    if not level then return nil end
    local m
    local story = Story.nextStory(record)
    if story then
        m = createStoryMission(record, story, level)
        if not m then
            -- Could not place it now: keep it for the next time.
            Story.queueStory(record, story.id, story.fresh)
        end
    end
    if not m then
        if Story.handedOver(record) then
            m = createContract(record, level)
        end
        if not m then m = createRegular(record, level) end
    end
    if not m then return nil end
    Missions.begin(record, m)
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_NewRequest", sub = "IGUI_OA_Title_CheckTerminal",
        style = "notice" })
    OA.log("mission", m.id, m.story or m.title, "for", record.number)
    return m
end

-- The mission ends: only its result stays (DESIGN 12). `result`: "done" | "expired" | "lost".
function Missions.finish(record, m, result)
    local s = Missions.state(record)
    local g = game()
    if g and g.release then g.release(m) end
    s.active = nil
    s.nextAt = OA.hours() + intervalHours()
    s.results[result] = (s.results[result] or 0) + 1
    s.last = { id = m.id, story = m.story, result = result, at = OA.hours() }
    if result == "expired" then
        OA.Sync.title(record.id, { key = "IGUI_OA_Title_Expired", sub = (Missions.keys(m)), style = "notice",
            tone = "red", fallback = "bad" })
    end
    Story.missionEnded(record, m, result)
    OA.Sync.changed("missions", record.id)
end

-- The reward goes in, and the player sees the request done (before the title of a stage its trust may bring).
function Missions.pay(record, m)
    local credits, trust = m.pay and m.pay.credits or m.credits, m.pay and m.pay.trust or m.trust
    local detail = { key = "IGUI_OA_Title_Paid", sub = (Missions.keys(m)), style = "stamp", fallback = "good" }
    if credits and credits > 0 then
        detail.sub, detail.subArgs = "IGUI_OA_Title_PaidSub", { { key = detail.sub }, math.floor(credits + 0.5) }
    end
    OA.Sync.title(record.id, detail)
    -- The economy values a mission item that is in time at nothing (P1: "MissionItem"); the whole reward is paid here.
    Story.addCredits(record, credits)
    Story.addTrust(record, trust)
    if m.swap then Story.queueNote(record, "case_confirmed") end
    if m.cooler then Story.queueNote(record, "cooler_" .. (m.cooler.grade or "good")) end
    Missions.finish(record, m, "done")
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
        if Rewards.level(stage, milestones) and now >= (s.nextAt or 0) then Missions.start(record) end
        return
    end
    if m.state == "offer" or m.state == "open" or m.state == "calling" then
        if m.state ~= "calling" and now > m.deadline then
            Missions.finish(record, m, "expired")
            return
        end
    elseif m.state == "sealed" then
        if now > (m.sealedAt or now) + Rewards.hours(Data.SEALED_LOST_DAYS) then
            Missions.finish(record, m, "lost")
            return
        end
    end
    local g = game()
    if m.swap and m.swap.stage == "waiting" then Missions.tickSwap(record, m, now) end
    if m.carry and g and g.findItem then Missions.tickCarry(record, m, now) end
    if m.field and m.field.stage == "calling" then Missions.tickField(record, m, now) end
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
    local s = Missions.state(record)
    local m = s.active
    if not m or m.state ~= "open" then return end
    local now = OA.hours()
    for _, entry in ipairs(entries or {}) do
        local info = entry.info or {}
        local base, key = Missions.parseId(info.mission)
        if base == m.id then
            local right = true
            if m.compare then right = (key == m.compare.right) end
            if right then
                if Rewards.judge(m.deadline, now) ~= "ok" then
                    -- Too late: a plain item, no penalty. The mission is over.
                    Missions.finish(record, m, "expired")
                    return
                end
                Missions.sealedOk(record, m, boxId, now)
                return
            end
        end
    end
end

function Missions.sealedOk(record, m, boxId, now)
    local credits, trust = m.credits, m.trust
    if m.carry then
        local temp = Missions.coolerTemp(m, now)
        local q = Rewards.coolerQuality(temp)
        m.cooler = { temp = temp, grade = Rewards.coolerGrade(temp) }
        credits, trust = Rewards.reward(m.level, true, q, creditScale())
    end
    m.pay = { credits = credits, trust = trust }
    m.state = "sealed"
    m.sealedAt = now
    m.box = boxId
    local g = game()
    if g and g.release then g.release(m) end
    OA.Sync.changed("missions", record.id)
end

-- The trade part settled a helicopter's delivery: a sealed mission is paid. `result.boxes` (when given) names the
-- boxes the settlement covered.
function Missions.onSettled(record, result)
    local s = Missions.state(record)
    local m = s.active
    if not m or m.state ~= "sealed" then return end
    -- The trade part settles all of a record's sealed boxes in one arrival and says how many it took (a number).
    if result and type(result.boxes) == "number" and result.boxes <= 0 then return end
    local covered = result and (result.boxes or result.boxIds)
    if type(covered) == "table" and m.box ~= nil then
        local found = false
        for k, v in pairs(covered) do
            if v == m.box or k == m.box then found = true end
        end
        if not found then return end
    end
    Missions.pay(record, m)
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
            local m = record.missions and record.missions.active
            if not (m and m.id == base) then return true end
            if m.state == "sealed" or m.state == "calling" then return false end
            return Rewards.judge(m.deadline, OA.hours()) ~= "ok"
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
    local m = record.missions and record.missions.active
    if not (m and m.carry) or m.carry.start then return end
    local g = game()
    if g and g.holds and g.holds(item, m.id) then m.carry.start = OA.hours() end
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
    local s = Missions.state(record)
    local m = s.active
    if not (m and m.swap and m.swap.stage == "needcase" and m.state == "open") then return false end
    local g = game()
    local x, y = g.playerPosition(record)
    local p = Data.PLACES[m.place]
    if not x or not p or Places.distance(x, y, p.x, p.y) > Data.CASE_RANGE then return false end
    if g.takeItem and not g.takeItem(character, "SampleCase") then return false end
    m.swap.stage = "waiting"
    m.swap.waited = 0
    m.swap.at = OA.hours()
    OA.Sync.changed("missions", record.id)
    return true
end

-- The wait (waited, hours) adds up the game time from each look that found the player near (swap.at) to the next, not
-- a sixth of an hour a look: the ten-minute event comes many times a real second fast-forwarded and may be skipped
-- or come in a batch. A look that finds the player away (or nowhere) stops the count until one finds them near again.
function Missions.tickSwap(record, m, now)
    local g = game()
    if not g then return end
    local x, y = g.playerPosition(record)
    local p = Data.PLACES[m.place]
    if not x or not p or Places.distance(x, y, p.x, p.y) > Data.CASE_RANGE then
        m.swap.at = nil
        return
    end
    if m.swap.at and now > m.swap.at then m.swap.waited = m.swap.waited + (now - m.swap.at) end
    m.swap.at = now
    if m.swap.waited >= Data.SWAP_WAIT_HOURS then
        m.swap.stage = "done"
        -- The record appears in the case (or in the player's hands when the case is gone).
        local it = { key = "A", type = Data.fullType(m.swap.item), mode = "inside", placed = false,
                     mods = { OA_Variant = m.place }, x = p.x, y = p.y, z = p.z }
        m.items[#m.items + 1] = it
        if g.deliverInside then g.deliverInside(record, m, it) end
        OA.Sync.changed("missions", record.id)
    end
end

-- The field call device is used at the place: the mission item is sealed on the spot and the helicopter comes.
function Missions.fieldCall(record, character)
    local s = Missions.state(record)
    local m = s.active
    if not (m and m.field and m.state == "open") then return false, "none" end
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
            m.pay = { credits = m.credits, trust = m.trust }
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
        if not x or Places.distance(x, y, m.soil.x, m.soil.y) > 25 then return false end
    end
    if g.giveMissionItem then
        g.giveMissionItem(character, Data.fullType("SoilSample"), m.id, { OA_Stake = m.soil.stake })
    end
    m.soil.taken = true
    m.items[1] = { key = "A", type = Data.fullType("SoilSample"), mode = "given", placed = true }
    OA.Sync.changed("missions", record.id)
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- What the windows read.

-- A plain description of a mission for the tab: strings and numbers, no text (the tab translates).
function Missions.describe(record)
    local s = Missions.state(record)
    local m = s.active
    local now = OA.hours()
    local info = { nextIn = math.max(0, (s.nextAt or 0) - now), results = s.results }
    if not m then return info end
    info.id = m.id
    info.kind = m.kind
    info.story = m.story
    info.title = m.title
    info.state = m.state
    info.place = m.place
    info.area = m.area
    info.area2 = m.area2
    info.anchor = m.anchor
    info.left = m.deadline - now
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
    local first = m.items and m.items[1]
    if first then info.item = Data.itemName(first.type) end
    return info
end

return Missions
