-- This week's request list (NUMBERS 2) and the table it is drawn from.
--
-- A request is a group one level above the item type: "charcoal" takes the looted and the kiln-made kind, "skill
-- books" any skill book, "canned food" any sealed tin, "hats" any hat. The groups and how easy each is to come by are made from the game's files by
-- tools/request_groups.py (RequestGroups.lua; the rules head the tool): a group's key is its id, or the item type
-- itself for a group of one. A type no group has (a strange item the story names) is a group of one with no score.
-- The world save (`requests` section) keeps the candidates found at the first world start:
--   types / score / cat (parallel lists): the candidate groups' keys, their commonness score and category;
--   kinds: every house loot kind (by base type) with its category, and total: how many there are per category (the
--   codex's category completion counts against these).
-- A record's list is drawn from the candidates by the stage it has reached: a score of 1 or more from the start,
-- 0.3 to 1 from stage 1, less than 0.3 from stage 2. The categories the team wants at that stage are twice as
-- likely. The list is the record's own, redrawn when the week changes, and grows (is topped up) with the stage. A
-- group is on it once.
-- A group on the list is bought at a fixed price for each unit, by its commonness (NUMBERS 2): the first `qty` units
-- of the week at `price` (times the request price reward), and a bonus of trust once the line is full. The price is
-- never below what the group's dearest member is worth by weight (Requests.floorOf), and a unit never fetches less
-- than it would unrequested at the day's index (Value.appraiseLine). Units over the quantity and items not on the
-- list are valued as any other item.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Market"
require "OperationAcorn/Economy/RequestGroups"
local OA = OperationAcorn
local Requests = {}
OA.Requests = Requests

-- 2: the candidates are groups (1 had item types). 3: the ids of the groups that vanilla's name typos split are joined
-- (the saved candidates hold the old ids). The table is made again too when RequestGroups.lua is (its stamp): a save
-- holds the group ids and scores of the table it was made from.
Requests.VERSION = 3
Requests.DUE_PICKS = 2          -- items of a category that comes back after a refusal

-- The commonness bands: from this score up (1 and more common, 0.3 to 1 normal, less than 0.3 rare). A band has the
-- price of a unit, the units a week takes at it and the trust a full line gives (NUMBERS 2).
Requests.COMMON_FROM, Requests.NORMAL_FROM = 1, 0.3
Requests.BANDS = {
    common = { price = 600, qty = 10, trust = 5 },
    normal = { price = 1500, qty = 5, trust = 10 },
    rare = { price = 4000, qty = 3, trust = 20 },
}
Requests.BAND_ORDER = { "common", "normal", "rare" }

-- The rooms that count as a house (NUMBERS 12): their containers' loot is the "house loot" of the design.
Requests.HOUSE_ROOMS = {
    "bedroom", "kidsbedroom", "livingroom", "kitchen", "bathroom", "closet", "hall", "laundry", "dining",
    "garagestorage", "attic", "shed", "sunroom", "storage", "hoarder", "hoarderbedroom", "hoarderkitchen",
    "hoarderoffice",
}

-- The groups ------------------------------------------------------------------------------------------------

-- The rows in use (RequestGroups.lua's, or a test's) and what is looked up in them, made once for the rows: byKey
-- (key -> row) and keyOfType (member type -> key); names, member names and floors are made once for a key.
local rows, byKey, keyOfType, aliasOf
local names, memberNames, floors = {}, {}, {}

local function index()
    local now = OA.RequestGroups or {}
    if rows ~= now then
        rows, byKey, keyOfType, aliasOf = now, {}, {}, {}
        names, memberNames, floors = {}, {}, {}
        for _, row in ipairs(rows) do
            byKey[row.id] = row
            for _, t in ipairs(row.items) do keyOfType[t] = row.id end
        end
        -- The ids a group had before the table was made again (`was`), that a save may still hold.
        for _, row in ipairs(rows) do
            for _, old in ipairs(row.was or {}) do
                if not byKey[old] then aliasOf[old] = row.id end
            end
        end
    end
    return byKey, keyOfType, aliasOf
end

-- Puts other rows in place of the generated ones (a test with its own item names; {} for none).
function Requests.useGroups(list)
    OA.RequestGroups = list
    index()
end

-- The key of the group an item type belongs to: the group's id, or the type itself. An id the table no longer has
-- (a group that was joined to another) is the key of the group that took it over.
function Requests.keyOf(fullType)
    local _, ofType, alias = index()
    return ofType[fullType] or alias[fullType] or fullType
end

-- The group's row ({ id, score, wt, dc, items, name, icon }), or nil for a type no group has.
function Requests.group(key)
    local rowOf = index()
    return rowOf[key]
end

-- The item types a group takes (a list not to be changed).
function Requests.members(key)
    local row = Requests.group(key)
    return row and row.items or { key }
end

-- The item type whose picture stands for the group.
function Requests.iconType(key)
    local row = Requests.group(key)
    return row and (row.icon or row.items[1]) or key
end

local function itemName(fullType)
    local ok, name = pcall(getItemNameFromFullType, fullType)
    if ok and name and name ~= "" then return name end
    return tostring(fullType)
end

-- A name less its stray brackets (a "]" with no "[" before it, a "[" never closed: vanilla's Korean names have a few,
-- "끈 없는 브라]") and with single spaces. The tool works names out the same way.
local function clean(name)
    local out, opens = {}, {}
    for i = 1, #name do
        local c = string.sub(name, i, i)
        if c == "[" then
            opens[#opens + 1] = #out + 1
            out[#out + 1] = c
        elseif c == "]" then
            if #opens > 0 then
                opens[#opens] = nil
                out[#out + 1] = c
            end
        else
            out[#out + 1] = c
        end
    end
    for i = #opens, 1, -1 do table.remove(out, opens[i]) end
    local words = {}
    for w in string.gmatch(table.concat(out), "%S+") do words[#words + 1] = w end
    return table.concat(words, " ")
end

-- A name less its variant (" [white]") and its stray brackets.
local function plain(name)
    local text = string.gsub(clean(name), "%s*%[[^%]]*%]%s*$", "")
    return (string.gsub(text, "^%s+", ""))
end

local function wordsOf(name)
    local words = {}
    for w in string.gmatch(name, "%S+") do words[#words + 1] = w end
    return words
end

-- Whether the words of `small` are in `big` in the same order.
local function inside(small, big)
    local at = 0
    for _, w in ipairs(small) do
        repeat at = at + 1 until at > #big or big[at] == w
        if at > #big then return false end
    end
    return true
end

-- The name a group of several kinds shows (the tool works it out the same way, to merge the groups that would show
-- one name twice). In this order: the shortest of the kinds' names (less the variant) that all the others have inside
-- them in order ("끈 없는 브라" for "끈 없는 프릴 브라"); else the words all the names start with, less a trailing " -"
-- or a word with an open bracket; else the words they all end with, less a leading " -"; else the first name.
local function displayName(list)
    local plains, splits = {}, {}
    for i, name in ipairs(list) do
        plains[i] = plain(name)
        splits[i] = wordsOf(plains[i])
    end
    local best
    for i = 1, #list do
        if #splits[i] > 0 and (not best or #splits[i] < #splits[best]) then
            local fits = true
            for j = 1, #list do
                if not inside(splits[i], splits[j]) then fits = false break end
            end
            if fits then best = i end
        end
    end
    if best then return plains[best] end
    local common
    for _, name in ipairs(list) do
        local words = wordsOf(clean(name))
        if not common then
            common = words
        else
            local n = 0
            while n < #common and n < #words and common[n + 1] == words[n + 1] do n = n + 1 end
            for i = #common, n + 1, -1 do common[i] = nil end
        end
    end
    while common and #common > 0 do
        local last = common[#common]
        if not (string.find(last, "^[%-:%(%[]") or string.find(last, "[%[%(]")) then break end
        common[#common] = nil
    end
    if common and #common > 0 then return table.concat(common, " ") end
    local tail
    for i = 1, #list do
        local words = splits[i]
        if not tail then
            tail = {}
            for k = #words, 1, -1 do tail[#tail + 1] = words[k] end
        else
            local n = 0
            while n < #tail and n < #words and tail[n + 1] == words[#words - n] do n = n + 1 end
            for k = #tail, n + 1, -1 do tail[k] = nil end
        end
    end
    while tail and #tail > 0 do
        local last = tail[#tail]
        if not (string.find(last, "^[%-:%)%]]") or string.find(last, "[%)%]]")) then break end
        tail[#tail] = nil
    end
    if tail and #tail > 0 then
        local out = {}
        for k = #tail, 1, -1 do out[#out + 1] = tail[k] end
        return table.concat(out, " ")
    end
    return plains[1]
end

-- The name the list shows for a group, made once: a family's own text; else, for several kinds, the name worked out
-- from theirs (displayName: "Bowling Shirt [Blue]" and "[Brown]" are "Bowling Shirt"); else the kind's name without
-- its variant. The tool merged the groups that would show the same name (it works the name out the same way).
function Requests.nameOf(key)
    index()
    local hit = names[key]
    if hit then return hit end
    local row = Requests.group(key)
    if row and row.name then
        hit = getText(row.name)
    else
        local items = row and row.items or { key }
        if #items > 1 then
            local list = {}
            for i, t in ipairs(items) do list[i] = itemName(t) end
            hit = displayName(list)
        else
            hit = plain(itemName(items[1]))
        end
    end
    names[key] = hit
    return hit
end

-- The names of the kinds a group takes, in its order, each once (made once; a list not to be changed).
function Requests.memberNames(key)
    index()
    local hit = memberNames[key]
    if not hit then
        hit = {}
        local seen = {}
        for _, t in ipairs(Requests.members(key)) do
            local name = itemName(t)
            if not seen[name] then
                seen[name] = true
                hit[#hit + 1] = name
            end
        end
        memberNames[key] = hit
    end
    return hit
end

-- What the group's dearest member is worth by weight at index 1 (its weight times its category's credits): the
-- request price is never below it (a television is worth 6,000; a common line pays 600). 0 for a type no group has.
function Requests.floorOf(key)
    index()
    local hit = floors[key]
    if hit == nil then
        hit = 0
        local row = Requests.group(key)
        if row and row.wt then
            local cat = OA.Categories.of({ fullType = row.items[1], weight = row.wt, displayCategory = row.dc })
            if cat then hit = row.wt * OA.Categories.UNIT[cat] end
        end
        floors[key] = hit
    end
    return hit
end

-- The table -------------------------------------------------------------------------------------------------

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

-- The saved table: kinds and total from the house loot's weights (`infoOf(name)` gives the info of an item name as
-- OA.Value.infoFromScript does, or nil for a name no item has), and the candidates from the group rows (as
-- RequestGroups.lua has them; `exists(fullType)`, when given, tells a type the game has: a group none of whose
-- members it has is left out). A candidate's category is its first existing member's.
function Requests.build(sums, infoOf, groups, exists)
    local kinds, total = {}, {}
    for name in pairs(sums) do
        local info = infoOf(name)
        if info then
            local cat = OA.Categories.of(info)
            if cat and not kinds[info.baseType] then
                kinds[info.baseType] = cat
                total[cat] = (total[cat] or 0) + 1
            end
        end
    end
    local types, score, cats = {}, {}, {}
    for _, row in ipairs(groups or {}) do
        local first
        for _, t in ipairs(row.items) do
            if not exists or exists(t) then
                first = t
                break
            end
        end
        if first then
            local n = #types + 1
            types[n], score[n] = row.id, row.score
            cats[n] = OA.Categories.of({ fullType = first, weight = row.wt, displayCategory = row.dc }) or "E"
        end
    end
    return { version = Requests.VERSION, stamp = OA.RequestGroupsStamp, types = types, score = score, cat = cats,
        kinds = kinds, total = total, n = #types }
end

-- Makes the table from the game's distributions and the groups (the real thing; tests call build with their own).
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
    index()
    return Requests.build(sums, infoOf, rows, function(t) return infoOf(t) ~= nil end)
end

-- The world's table, built the first time and again when a save from before the groups has one of item types or one
-- made from another RequestGroups.lua (nil when the game's tables are not there, as on a client).
function Requests.data()
    local world = OA.Store.world("requests")
    if world.version ~= Requests.VERSION or not world.types or (world.stamp and world.stamp ~= OA.RequestGroupsStamp) then
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

-- Puts a built table in the world save (a test, or a part that made its own) as the current one.
function Requests.install(made)
    local world = OA.Store.world("requests")
    for k in pairs(world) do world[k] = nil end
    for k, v in pairs(made) do world[k] = v end
    world.version = Requests.VERSION
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

-- The band of a commonness score.
function Requests.band(score)
    if score >= Requests.COMMON_FROM then return "common" end
    if score >= Requests.NORMAL_FROM then return "normal" end
    return "rare"
end

-- Whether a score may be drawn at a stage.
function Requests.eligible(score, stage)
    if score >= Requests.COMMON_FROM then return true end
    if score >= Requests.NORMAL_FROM then return stage >= 1 end
    return stage >= 2
end

-- The commonness score of a group (by key): from the world's table, 0 (the rarest band) for one that is no candidate
-- (a strange item the story names). The lookup table is made once for the world's table.
local indexOf, indexFrom
function Requests.scoreOf(key)
    local world = Requests.data()
    if not world or not world.types then return 0 end
    if indexFrom ~= world.types then
        indexOf, indexFrom = {}, world.types
        for i = 1, world.n or #world.types do indexOf[world.types[i]] = world.score[i] end
    end
    return indexOf[key] or 0
end

-- A list saved before the groups named item types: each becomes its group's key, a group named twice is kept once
-- and the units the week settled of its types add up. The pinned item and the strange one too.
function Requests.migrate(record)
    local codex = record.codex
    if not codex then return end
    local old = codex.req and not codex.req.groups
    if old then codex.req.groups = true end
    Requests.rekey(codex, old)
end

-- The lists whose keys were checked against the rows in use (a list is checked again when the table changes).
local checked = setmetatable({}, { __mode = "k" })

-- Puts the keys a record holds (the week's list, what was settled, the strange item, the pinned one) in the table's
-- terms: a type becomes its group's key, an id the table dropped becomes that of the group that took it over (the
-- tool keeps these as `was`), a group named twice is kept once and its settled units add up. `force` for a list of item
-- types from before the groups (it has no `groups` mark); a list is otherwise checked once for the rows in use.
function Requests.rekey(codex, force)
    index()
    if codex.reqPin then codex.reqPin = Requests.keyOf(codex.reqPin) end
    local rq = codex.req
    if not rq or (checked[rq] == rows and not force) then return end
    local items, seen, used = {}, {}, {}
    for _, t in ipairs(rq.items or {}) do
        local key = Requests.keyOf(t)
        if not seen[key] then
            seen[key] = true
            items[#items + 1] = key
        end
    end
    for t, n in pairs(rq.used or {}) do
        local key = Requests.keyOf(t)
        used[key] = (used[key] or 0) + n
    end
    rq.items, rq.used = items, used
    if rq.strange then rq.strange = Requests.keyOf(rq.strange) end
    checked[rq] = rows
end

OA.Store.addUpgrade("requests.groups", Requests.migrate)

-- The record's request state: { week, items = { key ... }, used = { key = units this week }, groups = true }. A list
-- of item types from before (a save not upgraded yet) is moved to groups first.
local function state(record)
    local codex = OA.Store.section(record, "codex")
    if codex.req and not codex.req.groups then Requests.migrate(record) else Requests.rekey(codex) end
    return codex, codex.req
end

-- Draws `n` more groups for a record into rq.items. Groups already there, refused categories and (unless forced)
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
            local cat = world.cat and world.cat[i] or world.kinds[OA.Categories.baseType(t)]
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

-- A fixed item for next week's list (the story hands one over after a hallucination): its group goes on it.
function Requests.pinNext(record, fullType)
    local codex = OA.Store.section(record, "codex")
    codex.reqPin = Requests.keyOf(fullType)
end

-- The record's list for this week (group keys), drawn the first time the week is asked about and topped up as the
-- stage grows. The group of a strange item the story part names for this week (the week after a hallucination) goes
-- on the list in addition to the normal count.
function Requests.list(record)
    local codex, rq = state(record)
    local week = OA.week()
    if not rq or rq.week ~= week then
        rq = { week = week, items = {}, used = {}, extra = 0, groups = true }
        codex.req = rq
        if codex.reqPin then
            table.insert(rq.items, codex.reqPin)
            codex.reqPin = nil
        end
        local story = OA.Story
        local strange = story and story.strangeItem and story.strangeItem(record) or nil
        if strange then
            strange = Requests.keyOf(strange)
            local present = false
            for _, t in ipairs(rq.items) do if t == strange then present = true end end
            if not present then table.insert(rq.items, strange) end
            rq.extra = 1
            rq.strange = strange
        end
        -- Categories that were refused a few weeks ago come back.
        for _, cat in ipairs(OA.Market.dueRequests(week * 7, week * 7 + 6)) do
            draw(record, rq, Requests.DUE_PICKS, cat)
        end
    end
    local want = OA.Trust.rewards(record).requestCount + (rq.extra or 0)
    if #rq.items < want then draw(record, rq, want - #rq.items) end
    return rq.items
end

-- Units of each group (by key) the record has had settled as requests this week.
function Requests.used(record)
    Requests.list(record)
    local _, rq = state(record)
    return rq.used
end

-- The price of a unit of a band for a record: the band's price (or `floor` when that is more) times the request
-- price reward, to ten credits.
function Requests.unitPrice(record, band, floor)
    local base = math.max(Requests.BANDS[band].price, floor or 0)
    return math.floor(base * OA.Trust.rewards(record).requestPrice / 10 + 0.5) * 10
end

-- The line of a group on the list (by key), its weekly count read from `used` (the list itself is not looked at, so
-- the client can call it on its copy without drawing anything). `fullType` is the key too (the name the parts that
-- show a line have read it by).
function Requests.line(record, key, used)
    local band = Requests.band(Requests.scoreOf(key))
    local def = Requests.BANDS[band]
    local n = used[key] or 0
    return { key = key, fullType = key, band = band, price = Requests.unitPrice(record, band, Requests.floorOf(key)),
        qty = def.qty, trust = def.trust, used = n, left = math.max(0, def.qty - n), full = n >= def.qty }
end

-- The record's line of a group on this week's list, by its key or a member's type: { key, fullType (the key), band,
-- price (a unit), qty (the week's units), trust (for a full line), used, left, full }; nil when it is not on the list.
function Requests.entry(record, keyOrType)
    local key = Requests.keyOf(keyOrType)
    local items = Requests.list(record)
    local _, rq = state(record)
    for _, t in ipairs(items) do
        if t == key then return Requests.line(record, key, rq.used) end
    end
    return nil
end

-- All the lines of this week's list, by band (common first) and in the order the list was drawn within a band.
function Requests.entries(record)
    local items = Requests.list(record)
    local _, rq = state(record)
    local lines = {}
    for i, t in ipairs(items) do
        local line = Requests.line(record, t, rq.used)
        line.order = i
        lines[#lines + 1] = line
    end
    local rank = { common = 1, normal = 2, rare = 3 }
    table.sort(lines, function(a, b)
        if a.band ~= b.band then return rank[a.band] < rank[b.band] end
        return a.order < b.order
    end)
    return lines
end

-- A flight settled `n` units of a group (by key) as requests.
function Requests.consume(record, key, n)
    local used = Requests.used(record)
    used[key] = (used[key] or 0) + n
end

-- Draws every record's list for the new week (the daily handler calls it): counters reset, lists redrawn.
function Requests.weekly()
    for _, record in pairs(OA.Store.players()) do Requests.list(record) end
end

return Requests
