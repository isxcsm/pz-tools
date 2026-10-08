-- This week's request list (NUMBERS 2) and the table it is drawn from.
--
-- The candidates are the vanilla item kinds the house loot tables hand out and the team takes, found once from
-- the distribution tables at the first world start and kept in the world save (`requests` section):
--   types / score (parallel lists): candidate item types and their commonness score (the sum of the item's weights
--   in the house tables over the median of all candidates); kinds: every house loot kind (by base type) with its
--   category, and total: how many there are per category (the codex's category completion counts against these).
-- A record's list is drawn from the candidates by the stage it has reached: a score of 1 or more from the start,
-- 0.3 to 1 from stage 1, less than 0.3 from stage 2. The categories the team wants at that stage are twice as
-- likely. The list is the record's own, redrawn when the week changes, and grows (is topped up) with the stage.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Market"
local OA = OperationAcorn
local Requests = {}
OA.Requests = Requests

Requests.VERSION = 1
Requests.FIRST_UNITS = 20       -- units of an item per week that earn the bonus
Requests.DUE_PICKS = 2          -- items of a category that comes back after a refusal

-- The rooms that count as a house (NUMBERS 12): their containers' loot is the "house loot" of the design.
Requests.HOUSE_ROOMS = {
    "bedroom", "kidsbedroom", "livingroom", "kitchen", "bathroom", "closet", "hall", "laundry", "dining",
    "garagestorage", "attic", "shed", "sunroom", "storage", "hoarder", "hoarderbedroom", "hoarderkitchen",
    "hoarderoffice",
}

local function addList(into, list, mult)
    if type(list) ~= "table" then return end
    local items = list.items
    if type(items) == "table" then
        for i = 1, #items, 2 do
            local name, weight = items[i], items[i + 1]
            if type(name) == "string" and type(weight) == "number" then
                into[name] = (into[name] or 0) + weight * mult
            end
        end
    end
    if type(list.junk) == "table" then addList(into, list.junk, mult) end
end

-- The sum of weights per item name over the containers of the house rooms. `dist` is the merged distribution
-- table (room -> container -> { items, junk, procList }), `procedural` is ProceduralDistributions.list. A list that
-- several containers draw is read once and multiplied by how many do.
function Requests.weights(dist, procedural, rooms)
    local sums, refs = {}, {}
    for _, room in ipairs(rooms or Requests.HOUSE_ROOMS) do
        local containers = dist[room]
        if type(containers) == "table" then
            for _, container in pairs(containers) do
                if type(container) == "table" then
                    addList(sums, container, 1)
                    if type(container.procList) == "table" then
                        for _, p in ipairs(container.procList) do
                            if p.name then refs[p.name] = (refs[p.name] or 0) + 1 end
                        end
                    end
                end
            end
        end
    end
    for name, count in pairs(refs) do
        addList(sums, procedural and procedural[name], count)
    end
    return sums
end

-- The saved table from the weights: `infoOf(name)` gives the info of an item name (as OA.Value.infoFromScript does),
-- or nil for a name no item has. `accepts(info)` decides what the team takes.
function Requests.build(sums, infoOf, accepts)
    local kinds, total, list = {}, {}, {}
    local seenKind = {}
    local perType = {}
    for name, weight in pairs(sums) do
        local info = infoOf(name)
        if info then
            local cat = OA.Categories.of(info)
            if cat then
                if not seenKind[info.baseType] then
                    seenKind[info.baseType] = true
                    kinds[info.baseType] = cat
                    total[cat] = (total[cat] or 0) + 1
                end
                if accepts(info) then
                    perType[info.fullType] = (perType[info.fullType] or 0) + weight
                end
            end
        end
    end
    for fullType, weight in pairs(perType) do
        table.insert(list, { fullType = fullType, weight = weight })
    end
    -- A stable order (the table order of pairs() is not): by weight, then name.
    table.sort(list, function(a, b)
        if a.weight ~= b.weight then return a.weight > b.weight end
        return a.fullType < b.fullType
    end)
    local weights = {}
    for i, e in ipairs(list) do weights[i] = e.weight end
    local median = 1
    if #weights > 0 then
        local n = #weights
        median = (n % 2 == 1) and weights[(n + 1) / 2] or (weights[n / 2] + weights[n / 2 + 1]) / 2
        if median <= 0 then median = 1 end
    end
    local types, score = {}, {}
    for i, e in ipairs(list) do
        types[i] = e.fullType
        score[i] = math.floor(e.weight / median * 1000 + 0.5) / 1000
    end
    return { version = Requests.VERSION, types = types, score = score, kinds = kinds, total = total, n = #types }
end

-- Makes the table from the game's distributions (the real thing; tests call build with their own tables).
function Requests.scan()
    local dist = SuburbsDistributions or (Distributions and Distributions[1])
    local procedural = ProceduralDistributions and ProceduralDistributions.list
    if type(dist) ~= "table" then return nil end
    local sums = Requests.weights(dist, procedural)
    local manager = getScriptManager()
    local cache = {}
    local function infoOf(name)
        local hit = cache[name]
        if hit == nil then
            local script = manager:FindItem(name)
            hit = script and OA.Value.infoFromScript(script) or false
            cache[name] = hit
        end
        return hit or nil
    end
    return Requests.build(sums, infoOf, function(info) return OA.Value.accepts(info) end)
end

-- The world's table, built the first time (nil when the game's tables are not there, as on a client).
function Requests.data()
    local world = OA.Store.world("requests")
    if world.version ~= Requests.VERSION or not world.types then
        local made = Requests.scan()
        if not made then return nil end
        for k in pairs(world) do world[k] = nil end
        for k, v in pairs(made) do world[k] = v end
        OA.log("request candidates:", world.n, "house loot kinds:", Requests.kindCount(world))
    end
    return world
end

function Requests.kindCount(world)
    local n = 0
    for _, c in pairs(world.total or {}) do n = n + c end
    return n
end

-- Puts a built table in the world save (a test, or a part that made its own).
function Requests.install(made)
    local world = OA.Store.world("requests")
    for k in pairs(world) do world[k] = nil end
    for k, v in pairs(made) do world[k] = v end
    return world
end

-- The category of a house loot kind (by base type), or nil if the house tables never hand it out.
function Requests.kindCategory(baseType)
    local world = Requests.data()
    return world and world.kinds and world.kinds[baseType] or nil
end

-- How many house loot kinds a category has.
function Requests.categoryTotal(letter)
    local world = Requests.data()
    return world and world.total and world.total[letter] or 0
end

-- Whether a score may be drawn at a stage.
function Requests.eligible(score, stage)
    if score >= 1 then return true end
    if score >= 0.3 then return stage >= 1 end
    return stage >= 2
end

-- The record's request state: { week, items = { fullType ... }, used = { fullType = units this week } }.
local function state(record)
    local codex = OA.Store.section(record, "codex")
    return codex, codex.req
end

-- Draws `n` more items for a record into rq.items. Items already there, refused categories and (unless forced)
-- scores too rare for the stage are left out.
local function draw(record, rq, n, forcedCategory)
    local world = Requests.data()
    if not world or not world.types or world.n == 0 then return end
    local stage = record.trade and record.trade.stage or 0
    local wants = {}
    for _, c in ipairs(OA.Market.STAGE_WANTS[stage] or {}) do wants[c] = true end
    local have = {}
    for _, t in ipairs(rq.items) do have[t] = true end
    local pool, weights, sum = {}, {}, 0
    for i = 1, world.n do
        local t = world.types[i]
        if not have[t] then
            local cat = world.kinds[OA.Categories.baseType(t)]
            local ok
            if forcedCategory then
                ok = cat == forcedCategory
            else
                ok = Requests.eligible(world.score[i], stage) and not (cat and OA.Market.refused(cat))
            end
            if ok then
                local w = (cat and wants[cat]) and 2 or 1
                table.insert(pool, t)
                table.insert(weights, w)
                sum = sum + w
            end
        end
    end
    for _ = 1, n do
        if #pool == 0 then return end
        local roll = OA.randomFloat(0, sum)
        local pick = #pool
        local acc = 0
        for i = 1, #pool do
            acc = acc + weights[i]
            if roll < acc then
                pick = i
                break
            end
        end
        table.insert(rq.items, pool[pick])
        sum = sum - weights[pick]
        table.remove(pool, pick)
        table.remove(weights, pick)
    end
end

-- A fixed item for next week's list (the story hands one over after a hallucination).
function Requests.pinNext(record, fullType)
    local codex = OA.Store.section(record, "codex")
    codex.reqPin = fullType
end

-- Who wants to hear that a refused category came back as a request: fn(record, category).
local backListeners = {}
function Requests.listenBack(fn)
    table.insert(backListeners, fn)
end

-- The record's list for this week, drawn the first time the week is asked about and topped up as the stage grows.
-- A strange item the story part names for this week (the week after a hallucination) goes on the list in addition
-- to the usual count.
function Requests.list(record)
    local codex, rq = state(record)
    local week = OA.week()
    if not rq or rq.week ~= week then
        rq = { week = week, items = {}, used = {}, extra = 0 }
        codex.req = rq
        if codex.reqPin then
            table.insert(rq.items, codex.reqPin)
            codex.reqPin = nil
        end
        local story = OA.Story
        local strange = story and story.strangeItem and story.strangeItem(record) or nil
        if strange then
            local present = false
            for _, t in ipairs(rq.items) do if t == strange then present = true end end
            if not present then table.insert(rq.items, strange) end
            rq.extra = 1
            rq.strange = strange
        end
        -- Categories that were refused a few weeks ago come back.
        for _, cat in ipairs(OA.Market.dueRequests(week * 7, week * 7 + 6)) do
            draw(record, rq, Requests.DUE_PICKS, cat)
            for _, fn in ipairs(backListeners) do
                local ok, err = pcall(fn, record, cat)
                if not ok then OA.log("request listener failed:", tostring(err)) end
            end
        end
    end
    local want = OA.Trust.rewards(record).requestCount + (rq.extra or 0)
    if #rq.items < want then draw(record, rq, want - #rq.items) end
    return rq.items
end

-- Units of each item the record has had the bonus on this week.
function Requests.used(record)
    Requests.list(record)
    local _, rq = state(record)
    return rq.used
end

-- The request bonus of an item for a record (a fraction such as 0.5) and the units it still applies to; 0, 0 when
-- the item is not on the list or its units are used up.
function Requests.bonusFor(record, fullType)
    local items = Requests.list(record)
    local _, rq = state(record)
    for _, t in ipairs(items) do
        if t == fullType then
            local left = Requests.FIRST_UNITS - (rq.used[fullType] or 0)
            if left > 0 then return OA.Trust.rewards(record).requestBonus, left end
            return 0, 0
        end
    end
    return 0, 0
end

-- A flight used `n` units of an item's bonus.
function Requests.consume(record, fullType, n)
    local used = Requests.used(record)
    used[fullType] = (used[fullType] or 0) + n
end

-- Draws every record's list for the new week (the daily handler calls it): counters reset, lists redrawn.
function Requests.weekly()
    for _, record in pairs(OA.Store.players()) do Requests.list(record) end
end

return Requests
