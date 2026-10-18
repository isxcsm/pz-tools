-- The codex, the building sweep and the kill count (NUMBERS 4, DESIGN 6): bonuses for finding things, in credits only.
-- A bonus is added to the record's trade.bonus, which the next helicopter settlement pays; a shared upgrade serum
-- goes to trade.sharedSerums. BonusMultiplier scales the credits (not the serums).
--
-- The record's `codex` section (shared with Requests and Value, which keep the week's list and the cells there):
--   kinds { [base type] = true }, n (how many), cat { [letter] = house loot kinds found }, paid { kinds, cats =
--   { [letter] = 0|1|2 }, buildings, kills } (how many milestones are paid), buildings { [key] = containers },
--   nb (how many), kills.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Requests"
require "OperationAcorn/Economy/Value"
local OA = OperationAcorn
local Codex = {}
OA.Codex = Codex

Codex.KIND_CREDITS = 100
Codex.KIND_STEPS = { 100, 250, 500, 750, 1000, 1250, 1500 }
Codex.KIND_PAY = { 10000, 25000, 50000, 100000, 150000, 225000, 300000 }
Codex.KIND_SERUM = { [500] = 1, [1000] = 1, [1500] = 1 }   -- by the step's kinds
Codex.CATEGORY_STEPS = { 0.5, 0.9 }
Codex.CATEGORY_PAY = { 50000, 150000 }
Codex.BUILDING_BASE, Codex.BUILDING_PER_CONTAINER = 100, 10
Codex.BUILDING_STEPS = { 25, 100, 250, 500, 1000, 2000 }
Codex.BUILDING_PAY = { 3000, 10000, 20000, 40000, 60000, 80000 }
-- The kills' milestones, worked back from a price a kill (NUMBERS 4): about 100 credits a kill to 1,000, 72 to 5,000,
-- 50 to 10,000, 40 to 25,000, then 30 (150,000 every 5,000 kills).
Codex.KILL_STEPS = { 50, 100, 250, 500, 750, 1000, 1500, 2000, 3000, 4000, 5000, 7500, 10000, 15000, 20000, 25000 }
Codex.KILL_PAY = { 5000, 5000, 15000, 25000, 25000, 25000, 40000, 40000, 70000, 70000, 70000, 125000, 125000, 200000,
    200000, 200000 }
Codex.KILL_EVERY, Codex.KILL_EVERY_PAY = 5000, 150000   -- after the last step, every 5,000 kills
-- The kill milestones up to this count are told by a brief title (they come every day or two at first); the ones
-- after it by the codex's big one.
Codex.KILL_BRIEF_UNTIL = 1000

-- The codex section of a record, with its fields made.
function Codex.section(record)
    OA.Trust.section(record)
    local c = OA.Store.section(record, "codex")
    c.kinds = c.kinds or {}
    c.n = c.n or 0
    c.cat = c.cat or {}
    c.paid = c.paid or {}
    c.paid.kinds = c.paid.kinds or 0
    c.paid.cats = c.paid.cats or {}
    c.paid.buildings = c.paid.buildings or 0
    c.paid.kills = c.paid.kills or 0
    c.buildings = c.buildings or {}
    c.nb = c.nb or 0
    c.kills = c.kills or 0
    return c
end

-- Adds a credit bonus (scaled by BonusMultiplier).
local function pay(record, credits)
    local t = OA.Trust.section(record)
    t.bonus = t.bonus + credits * (OA.option("BonusMultiplier") or 1.0)
end

local function serum(record, n)
    local t = OA.Trust.section(record)
    t.sharedSerums = t.sharedSerums + n
end

-- A milestone worth telling: the event goes back to the caller, and to `tell` below.
local function milestone(events, kind, credits, detail)
    local event = { kind = kind, credits = credits * (OA.option("BonusMultiplier") or 1.0) }
    for k, v in pairs(detail or {}) do event[k] = v end
    table.insert(events, event)
end

-- The style of each milestone's title: the codex's are finds, the counts plain.
Codex.TITLE_STYLE = { Kinds = "discovery", Category = "discovery", Buildings = "dust", Kills = "dust" }

-- Tells the player of the milestones one action made, with one title: the last (highest) milestone, and the bonus of
-- all of them under it.
local function tell(record, events)
    local last = events[#events]
    if not last then return end
    local credits = 0
    for _, event in ipairs(events) do credits = credits + event.credits end
    local key, args = "IGUI_OA_Title_Codex" .. last.kind, { last.count or 0 }
    if last.letter then
        key = key .. "_" .. tostring(last.index)
        args = { { key = OA.Categories.nameKey(last.letter) } }
    end
    local style = Codex.TITLE_STYLE[last.kind]
    if last.kind == "Kills" and (last.count or 0) <= Codex.KILL_BRIEF_UNTIL then style = "brief" end
    local ok, err = pcall(OA.Sync.title, record.id, { key = key, args = args, sub = "IGUI_OA_Title_Bonus",
        subArgs = { { credits = math.floor(credits + 0.5) } }, style = style, fallback = "good" })
    if not ok then OA.log("title failed:", tostring(err)) end
end

-- The codex counts a kind the first time a character gets it. `info` as in ARCHITECTURE 5. Returns true when the
-- kind is new, and the milestone events it made. Before the first contact (Trust.contacted) the kind is counted and
-- nothing is paid or told: a milestone passed then is passed for good (the team was not there to see it).
function Codex.acquire(record, info)
    local events = {}
    local c = Codex.section(record)
    if not OA.Categories.isLoot(info) then return false, events end
    local key = info.baseType
    if not key or c.kinds[key] then return false, events end
    local live = OA.Trust.contacted(record)
    c.kinds[key] = true
    c.n = c.n + 1
    if live then pay(record, Codex.KIND_CREDITS) end
    -- A house loot kind counts toward its category.
    local letter = OA.Requests.kindCategory(key)
    if letter then
        c.cat[letter] = (c.cat[letter] or 0) + 1
        local total = OA.Requests.categoryTotal(letter)
        local paid = c.paid.cats[letter] or 0
        while paid < #Codex.CATEGORY_STEPS and c.cat[letter] >= math.ceil(Codex.CATEGORY_STEPS[paid + 1] * total) do
            paid = paid + 1
            if live then
                pay(record, Codex.CATEGORY_PAY[paid])
                milestone(events, "Category", Codex.CATEGORY_PAY[paid], { letter = letter, index = paid })
            end
        end
        c.paid.cats[letter] = paid
    end
    while c.paid.kinds < #Codex.KIND_STEPS and c.n >= Codex.KIND_STEPS[c.paid.kinds + 1] do
        c.paid.kinds = c.paid.kinds + 1
        if live then
            local step = Codex.KIND_STEPS[c.paid.kinds]
            pay(record, Codex.KIND_PAY[c.paid.kinds])
            local extra = Codex.KIND_SERUM[step]
            if extra then serum(record, extra) end
            milestone(events, "Kinds", Codex.KIND_PAY[c.paid.kinds], { count = step, sharedSerums = extra or 0 })
        end
    end
    tell(record, events)
    return true, events
end

-- The same for an item type that is not in hand (found while foraging): from its script.
function Codex.acquireType(record, fullType)
    local script = getScriptManager():FindItem(fullType)
    if not script then return false, {} end
    return Codex.acquire(record, OA.Value.infoFromScript(script))
end

-- The kinds counted, and the next milestone: { kinds, next (kinds needed or nil), buildings, kills }.
function Codex.summary(record)
    local c = Codex.section(record)
    return {
        kinds = c.n, nextKinds = Codex.KIND_STEPS[c.paid.kinds + 1],
        buildings = c.nb, nextBuildings = Codex.BUILDING_STEPS[c.paid.buildings + 1],
        kills = c.kills, nextKills = Codex.killThreshold(c.paid.kills + 1),
    }
end

-- How far a category is filled: kinds found, kinds there are (house loot).
function Codex.categoryProgress(record, letter)
    local c = Codex.section(record)
    return c.cat[letter] or 0, OA.Requests.categoryTotal(letter)
end

-- A building whose containers were all searched (once per building): 100 credits and 10 for each container, with no
-- cap (every container of a big one must be opened, which is cap enough), times `mult` (the search ledger's rank 3: more; 1 when left out), and the building count milestones. `key`
-- names the building (the API's key or the map's), `containers` how many it has. Returns the credits it made (before
-- BonusMultiplier) or nil if it was counted before, or before the first contact (counted, nothing paid or told, as
-- the codex's kinds).
function Codex.buildingSearched(record, key, containers, mult)
    local c = Codex.section(record)
    key = tostring(key)
    if c.buildings[key] then return nil end
    containers = math.max(0, containers or 0)
    c.buildings[key] = containers
    c.nb = c.nb + 1
    local live = OA.Trust.contacted(record)
    local credits = (Codex.BUILDING_BASE + Codex.BUILDING_PER_CONTAINER * containers) * (mult or 1)
    if live then pay(record, credits) end
    local events = {}
    while c.paid.buildings < #Codex.BUILDING_STEPS and c.nb >= Codex.BUILDING_STEPS[c.paid.buildings + 1] do
        c.paid.buildings = c.paid.buildings + 1
        if live then
            pay(record, Codex.BUILDING_PAY[c.paid.buildings])
            milestone(events, "Buildings", Codex.BUILDING_PAY[c.paid.buildings],
                { count = Codex.BUILDING_STEPS[c.paid.buildings] })
        end
    end
    tell(record, events)
    if not live then return nil, events end
    return credits, events
end

-- The kills a milestone needs (1 is the first), past the table every 5,000.
function Codex.killThreshold(index)
    if index <= #Codex.KILL_STEPS then return Codex.KILL_STEPS[index] end
    return Codex.KILL_STEPS[#Codex.KILL_STEPS] + Codex.KILL_EVERY * (index - #Codex.KILL_STEPS)
end

function Codex.killPay(index)
    if index <= #Codex.KILL_PAY then return Codex.KILL_PAY[index] end
    return Codex.KILL_EVERY_PAY
end

-- `n` zombies killed (one by default). Counted from the first contact on (Trust.contacted): the team's tally.
function Codex.kill(record, n)
    if not OA.Trust.contacted(record) then return {} end
    local c = Codex.section(record)
    c.kills = c.kills + (n or 1)
    local events = {}
    while c.kills >= Codex.killThreshold(c.paid.kills + 1) do
        c.paid.kills = c.paid.kills + 1
        local credits = Codex.killPay(c.paid.kills)
        pay(record, credits)
        milestone(events, "Kills", credits, { count = Codex.killThreshold(c.paid.kills) })
    end
    tell(record, events)
    return events
end

return Codex
