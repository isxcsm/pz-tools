-- The dense places (NUMBERS 7 'Dense places'): where the map puts many zombies, found once a world by the extension API
-- (PZExtAPI.zombies.dense) and kept in the world store. Each place is given one kind of weapon kit, rotating in the order
-- of density (the densest first): damage, critical, repair, damage ... A character gets its place's reward once, when it
-- clears the place (the zombies near its middle fall to a tenth of what they were when the place was first looked at) or
-- stands at the middle of a place that is already cleared in this world (by an earlier character); the shop reads the
-- rewards (a kind's restock is 1 plus the places of its kind a record got). Shown on the maps from trust level 6, until
-- the place is cleared.
--
-- Kept in the world, "dense": made, list = { { id, x, y, r, chunks, kind } }, baseline[id] (the zombie count at the
-- first look), cleared[id] = { by (the record's id), at (world hours) }. Kept in a record, "dense": got[id] = kind.
-- The only thing that runs more than once is the look (Dense.look, a game minute's event, at most once a real second):
-- a few distances, and only near a place the count of zombies.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Dense = {}
OA.Dense = Dense

-- The data. A place is a group of at least CHUNKS map chunks of a zombie intensity of at least MIN (0 to 255, as the map
-- has it). Both need tuning in the game: how many places a map gives, and whether they are dense enough to be worth the
-- trip. The list is made once a world, so a change is for new worlds.
Dense.MIN = 160
Dense.CHUNKS = 6
-- The kinds of reward, in the order the places take them.
Dense.KINDS = { "damage", "crit", "repair" }
-- Trust level from which the places are shown and cleared.
Dense.TIER = 6
-- A place is looked at when the character stands within NEAR squares of its middle; the zombies counted are those within
-- COUNT_R squares of the middle on the ground floor.
Dense.NEAR = 20
Dense.COUNT_R = 40
-- It is cleared when the count falls to this share of the first count, if that was at least LEAST.
Dense.CLEARED_SHARE = 0.10
Dense.LEAST = 20
-- The least real time (ms) between two looks of a record.
Dense.LOOK_MS = 1000

local looks = {}

local function world()
    return OA.Store.world("dense")
end

-- The record's rewards: { [place id] = kind }.
function Dense.got(record)
    local s = OA.Store.section(record, "dense")
    s.got = s.got or {}
    return s.got
end

-- How many places of a kind a record got (the shop's restock of that kind is 1 plus this).
function Dense.count(record, kind)
    local n = 0
    for _, k in pairs(Dense.got(record)) do
        if k == kind then n = n + 1 end
    end
    return n
end

-- The kind of the place in the nth place of the density order.
function Dense.kindAt(i)
    return Dense.KINDS[OA.remainder(i - 1, #Dense.KINDS) + 1]
end

-- The places of this world: the API's, asked once and kept. Nil while the API has no answer (asked again then). The ids
-- are "D1", "D2" ... in the API's order, which is the density order.
function Dense.ensure()
    local w = world()
    if w.made then return w.list end
    local api = OA.api()
    local zombies = api and api.zombies
    if type(zombies) ~= "table" or type(zombies.dense) ~= "function" then return nil end
    local ok, found = OA.try("dense: the API's dense places", zombies.dense, { min = Dense.MIN, minChunks = Dense.CHUNKS })
    if not ok or type(found) ~= "table" then return nil end
    w.list, w.baseline, w.cleared = {}, w.baseline or {}, w.cleared or {}
    for i, p in ipairs(found) do
        w.list[i] = { id = "D" .. i, x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5), r = math.ceil(p.r or 0),
            chunks = p.chunks, kind = Dense.kindAt(i) }
    end
    w.made = true
    OA.log("dense places:", #w.list)
    return w.list
end

-- The places made so far (empty before they are).
function Dense.list()
    return world().list or {}
end

-- Whether a place is cleared in this world, and by whom and when: { by, at }, or nil.
function Dense.cleared(id)
    local c = world().cleared
    return c and c[id] or nil
end

-- The places the maps show a record: { { id, x, y, r, kind } }, from the trust level on, not the cleared ones.
function Dense.shown(record)
    local list = {}
    if OA.Trust.tier(record) < Dense.TIER then return list end
    for _, p in ipairs(Dense.list()) do
        if not Dense.cleared(p.id) then list[#list + 1] = p end
    end
    return list
end

-- The zombies on the ground floor within COUNT_R of a place's middle, or nil when the API cannot say. (The game adapter:
-- a test sets another.)
function Dense.countAt(x, y)
    local api = OA.api()
    local zombies = api and api.zombies
    if type(zombies) ~= "table" or type(zombies.near) ~= "function" then return nil end
    local ok, count = OA.try("dense: the API's zombie count", zombies.near, x, y, 0, Dense.COUNT_R, 0)
    if ok and type(count) == "number" then return count end
    return nil
end

-- A record gets a place's reward: noted, told in a title (the other sub line when the place was cleared before), and the
-- shop and the maps asked to look again.
local function give(record, p, before)
    Dense.got(record)[p.id] = p.kind
    OA.Sync.title(record.id, { key = "IGUI_OA_Title_DenseCleared",
        sub = before and "IGUI_OA_Title_DenseHadSub" or "IGUI_OA_Title_DenseClearedSub",
        subArgs = { { key = "IGUI_OA_Dense_Kit_" .. p.kind } }, style = "discovery", fallback = "good" })
    OA.Sync.changed("trade", record.id)
end

-- A record stands near a place it has no reward from. In a place already cleared the reward is its own; else the first
-- look is the baseline (a count of none is no baseline: nothing was there to count yet), and a later one is the clearing.
local function visit(record, p)
    local w = world()
    if Dense.cleared(p.id) then
        give(record, p, true)
        return
    end
    local count = Dense.countAt(p.x, p.y)
    if not count then return end
    w.baseline, w.cleared = w.baseline or {}, w.cleared or {}
    local base = w.baseline[p.id]
    if not base then
        if count > 0 then w.baseline[p.id] = count end
        return
    end
    if base >= Dense.LEAST and count <= base * Dense.CLEARED_SHARE then
        w.cleared[p.id] = { by = record.id, at = OA.hours() }
        give(record, p, false)
    end
end

-- A look at where a record's character stands (x, y): the places within NEAR squares of it that the record has no reward
-- from. Called on the minute; does nothing until a real second has passed since the last look, below the trust level, or
-- with no place about.
function Dense.look(record, x, y)
    if not OA.due(looks, record.id, getTimestampMs(), Dense.LOOK_MS) then return end
    local list = world().list
    if not list or #list == 0 or OA.Trust.tier(record) < Dense.TIER then return end
    local got = Dense.got(record)
    local least = Dense.NEAR * Dense.NEAR
    for _, p in ipairs(list) do
        local dx, dy = p.x - x, p.y - y
        if dx * dx + dy * dy <= least and not got[p.id] then visit(record, p) end
    end
end

return Dense
