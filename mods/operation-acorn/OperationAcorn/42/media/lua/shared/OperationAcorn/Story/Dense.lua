-- The dense places (NUMBERS 7 'Dense places'): where the map puts many zombies, found once a world by the extension API
-- (PZExtAPI.zombies.dense) and kept in the world store. Each place is given one kind of weapon kit, rotating in the order
-- of density (the densest first): damage, critical, repair, damage ... A character gets its place's reward once, when it
-- clears the place (the zombies in its circle fall to a tenth of the most counted there) or stands in the circle of a
-- place that is already cleared in this world (by an earlier character); the shop reads the rewards (a kind's restock is
-- the places of its kind a record got, and none is sold before the first). Shown on the maps from trust level 6, until the record has its reward (a
-- place an earlier character cleared stays on a new one's maps: its reward waits there).
--
-- Kept in the world, "dense": made, list = { { id, x, y, r, chunks, kind } }, baseline[id] (the most zombies counted
-- there before it was cleared), cleared[id] = { by (the record's id), at (world hours) }. Kept in a record, "dense": got[id] = kind.
-- The only thing that runs more than once is the look (Dense.look, a game minute's event, at most once a real second):
-- a few distances, and only near a place the count of zombies.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Dense = {}
OA.Dense = Dense

-- The data. A place is a group of at least CHUNKS map chunks of a zombie intensity of at least MIN (as the map has it: B42's
-- vanilla map runs 0 to 10). Tuned in the game on the vanilla map (2026-10-19): 7 and 20 give 24 places spread over the towns
-- (Louisville's many, West Point, Rosewood and March Ridge, Brandenburg, Irvington, Ekron); 8 gave 14, nearly all in
-- Louisville; 7 with 6 chunks gave 49, too many circles. The overlapping ones made one (Dense.merge), the 24 are 20
-- (Louisville's four in its middle one). The list is made once a world, so a change is for new worlds.
Dense.MIN = 7
Dense.CHUNKS = 20
-- The kinds of reward, in the order the places take them.
Dense.KINDS = { "damage", "crit", "critDamage", "repair" }
-- Trust level from which the places are shown and cleared.
Dense.TIER = 6
-- A place is looked at when the character stands in its circle (within NEAR squares of its middle at least: a place made
-- of two may have an empty street there); the zombies counted are those within its circle (at least COUNT_R squares) of
-- the middle on the ground floor.
Dense.NEAR = 20
Dense.COUNT_R = 40
-- It is cleared when the count falls to this share of the most counted, if that was at least LEAST.
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

-- How many places of a kind a record got (the shop's restock of that kind).
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

-- The API's places with those whose circles overlap made one (two groups of chunks a street apart would show as circles
-- of two kits over each other): its middle the chunk-weighted one, its circle round both, in the place of the denser
-- (the earlier). { { x, y, r, chunks } } in the density order.
function Dense.merge(found)
    local list = {}
    for i, p in ipairs(found) do
        list[i] = { x = p.x, y = p.y, r = p.r or 0, chunks = p.chunks or 1 }
    end
    local merged = true
    while merged do
        merged = false
        for i = 1, #list do
            for j = i + 1, #list do
                local a, b = list[i], list[j]
                local dx, dy = b.x - a.x, b.y - a.y
                if dx * dx + dy * dy < (a.r + b.r) * (a.r + b.r) then
                    local n = a.chunks + b.chunks
                    local x, y = (a.x * a.chunks + b.x * b.chunks) / n, (a.y * a.chunks + b.y * b.chunks) / n
                    local function reach(p) return math.sqrt((p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)) + p.r end
                    list[i] = { x = x, y = y, r = math.max(reach(a), reach(b)), chunks = n }
                    table.remove(list, j)
                    merged = true
                    break
                end
            end
            if merged then break end
        end
    end
    return list
end

-- The places of this world: the API's (overlapping ones made one: Dense.merge), asked once and kept. Nil while the API
-- has no answer (asked again then). The ids are "D1", "D2" ... in the density order.
function Dense.ensure()
    local w = world()
    if w.made then return w.list end
    local api = OA.api()
    local zombies = api and api.zombies
    if type(zombies) ~= "table" or type(zombies.dense) ~= "function" then return nil end
    local ok, found = OA.try("dense: the API's dense places", zombies.dense, { min = Dense.MIN, minChunks = Dense.CHUNKS })
    if not ok or type(found) ~= "table" then return nil end
    w.list, w.baseline, w.cleared = {}, w.baseline or {}, w.cleared or {}
    for i, p in ipairs(Dense.merge(found)) do
        w.list[i] = { id = "D" .. i, x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5), r = math.ceil(p.r),
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

-- The sandbox's zombie population that means none (SandboxVars.Zombies, 1 insane to 6 none).
Dense.NO_ZOMBIES = 6

-- Whether the world has no zombies: its places never reach a baseline to clear, so they are neither shown nor looked at.
function Dense.zombieless()
    return SandboxVars ~= nil and SandboxVars.Zombies == Dense.NO_ZOMBIES
end

-- The places the maps show a record: { { id, x, y, r, kind } }, from the trust level on, those it has no reward from.
function Dense.shown(record)
    local list = {}
    if OA.Trust.tier(record) < Dense.TIER or Dense.zombieless() then return list end
    local got = Dense.got(record)
    for _, p in ipairs(Dense.list()) do
        if not got[p.id] then list[#list + 1] = p end
    end
    return list
end

-- The zombies on the ground floor within r squares (COUNT_R when not given) of x, y, or nil when the API cannot say. (The
-- game adapter: a test sets another.)
function Dense.countAt(x, y, r)
    local api = OA.api()
    local zombies = api and api.zombies
    if type(zombies) ~= "table" or type(zombies.near) ~= "function" then return nil end
    local ok, count = OA.try("dense: the API's zombie count", zombies.near, x, y, 0, r or Dense.COUNT_R, 0)
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

-- A record stands near a place it has no reward from. In a place already cleared the reward is its own; else the count
-- raises the baseline (the most seen: zombies still streaming in as the character arrives would leave a first count low)
-- or, at a tenth of it, clears the place.
local function visit(record, p)
    local w = world()
    if Dense.cleared(p.id) then
        give(record, p, true)
        return
    end
    local count = Dense.countAt(p.x, p.y, math.max(Dense.COUNT_R, p.r or 0))
    if not count then return end
    w.baseline, w.cleared = w.baseline or {}, w.cleared or {}
    local base = w.baseline[p.id] or 0
    if count > base then
        w.baseline[p.id] = count
        return
    end
    if base >= Dense.LEAST and count <= base * Dense.CLEARED_SHARE then
        w.cleared[p.id] = { by = record.id, at = OA.hours() }
        give(record, p, false)
    end
end

-- The list of places a look is to go over, or nil: not until a real second has passed since the last look, below the
-- trust level, or with no place about.
local function lookList(record)
    if not OA.due(looks, record.id, getTimestampMs(), Dense.LOOK_MS) then return nil end
    local list = world().list
    if not list or #list == 0 or OA.Trust.tier(record) < Dense.TIER or Dense.zombieless() then return nil end
    return list
end

local function lookOver(record, list, x, y)
    local got = Dense.got(record)
    for _, p in ipairs(list) do
        local dx, dy, near = p.x - x, p.y - y, math.max(Dense.NEAR, p.r or 0)
        if dx * dx + dy * dy <= near * near and not got[p.id] then visit(record, p) end
    end
end

-- A look at where a record's character stands (x, y): the places whose circle it stands in (NEAR at least) that the
-- record has no reward from. Called on the minute; does nothing until a real second has passed since the last look, below the trust level, or
-- with no place about.
function Dense.look(record, x, y)
    local list = lookList(record)
    if list then lookOver(record, list, x, y) end
end

-- The same, for the minute's event: `position(record)` gives the character's x, y (nil without one) and is asked only
-- once a look is due, so a record that would not look costs no search for its character.
function Dense.minute(record, position)
    local list = lookList(record)
    if not list then return end
    local x, y = position(record)
    if x then lookOver(record, list, x, y) end
end

return Dense
