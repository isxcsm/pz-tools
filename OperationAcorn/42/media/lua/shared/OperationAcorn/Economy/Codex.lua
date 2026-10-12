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
local OA = OperationAcorn
local Codex = {}
OA.Codex = Codex

Codex.KIND_CREDITS = 20
Codex.KIND_STEPS = { 100, 250, 500, 750, 1000, 1250, 1500 }
Codex.KIND_PAY = { 2000, 5000, 10000, 20000, 30000, 45000, 60000 }
Codex.KIND_SERUM = { [500] = 1, [1000] = 1, [1500] = 1 }   -- by the step's kinds
Codex.CATEGORY_STEPS = { 0.5, 0.9 }
Codex.CATEGORY_PAY = { 10000, 30000 }
Codex.BUILDING_BASE, Codex.BUILDING_PER_CONTAINER = 100, 10
Codex.BUILDING_STEPS = { 25, 100, 250, 500, 1000, 2000 }
Codex.BUILDING_PAY = { 3000, 10000, 20000, 40000, 60000, 80000 }
Codex.KILL_STEPS = { 100, 500, 1000, 2500, 5000, 10000, 25000, 50000 }
Codex.KILL_PAY = { 2000, 5000, 10000, 20000, 35000, 50000, 80000, 120000 }
Codex.KILL_EVERY, Codex.KILL_EVERY_PAY = 50000, 120000   -- after the last step, every 50,000 kills

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

-- The style of each milestone's title: the codex's are finds, the counts things done.
Codex.TITLE_STYLE = { Kinds = "discovery", Category = "discovery", Buildings = "stamp", Kills = "stamp" }

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
    local ok, err = pcall(OA.Sync.title, record.id, { key = key, args = args, sub = "IGUI_OA_Title_Bonus",
        subArgs = { math.floor(credits + 0.5) }, style = Codex.TITLE_STYLE[last.kind], fallback = "good" })
    if not ok then OA.log("title failed:", tostring(err)) end
end

-- The codex counts a kind the first time a character gets it. `info` as in ARCHITECTURE 5. Returns true when the
-- kind is new, and the milestone events it made.
function Codex.acquire(record, info)
    local events = {}
    local c = Codex.section(record)
    if not OA.Categories.isLoot(info) then return false, events end
    local key = info.baseType
    if not key or c.kinds[key] then return false, events end
    c.kinds[key] = true
    c.n = c.n + 1
    pay(record, Codex.KIND_CREDITS)
    -- A house loot kind counts toward its category.
    local letter = OA.Requests.kindCategory(key)
    if letter then
        c.cat[letter] = (c.cat[letter] or 0) + 1
        local total = OA.Requests.categoryTotal(letter)
        local paid = c.paid.cats[letter] or 0
        while paid < #Codex.CATEGORY_STEPS and c.cat[letter] >= math.ceil(Codex.CATEGORY_STEPS[paid + 1] * total) do
            paid = paid + 1
            pay(record, Codex.CATEGORY_PAY[paid])
            milestone(events, "Category", Codex.CATEGORY_PAY[paid], { letter = letter, index = paid })
        end
        c.paid.cats[letter] = paid
    end
    while c.paid.kinds < #Codex.KIND_STEPS and c.n >= Codex.KIND_STEPS[c.paid.kinds + 1] do
        c.paid.kinds = c.paid.kinds + 1
        local step = Codex.KIND_STEPS[c.paid.kinds]
        pay(record, Codex.KIND_PAY[c.paid.kinds])
        local extra = Codex.KIND_SERUM[step]
        if extra then serum(record, extra) end
        milestone(events, "Kinds", Codex.KIND_PAY[c.paid.kinds], { count = step, sharedSerums = extra or 0 })
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
-- BonusMultiplier) or nil if it was counted before.
function Codex.buildingSearched(record, key, containers, mult)
    local c = Codex.section(record)
    key = tostring(key)
    if c.buildings[key] then return nil end
    containers = math.max(0, containers or 0)
    c.buildings[key] = containers
    c.nb = c.nb + 1
    local credits = (Codex.BUILDING_BASE + Codex.BUILDING_PER_CONTAINER * containers) * (mult or 1)
    pay(record, credits)
    local events = {}
    while c.paid.buildings < #Codex.BUILDING_STEPS and c.nb >= Codex.BUILDING_STEPS[c.paid.buildings + 1] do
        c.paid.buildings = c.paid.buildings + 1
        pay(record, Codex.BUILDING_PAY[c.paid.buildings])
        milestone(events, "Buildings", Codex.BUILDING_PAY[c.paid.buildings],
            { count = Codex.BUILDING_STEPS[c.paid.buildings] })
    end
    tell(record, events)
    return credits, events
end

-- Searched and total containers of a building for a record: for a building already counted, all of them. The
-- sweep that watches the player's building (server wiring) fills the progress of the one in hand.
local progress = {}
function Codex.setBuildingProgress(key, searched, total)
    progress[tostring(key)] = { searched = searched, total = total }
end

function Codex.buildingProgress(record, buildingKey)
    local key = tostring(buildingKey)
    local c = Codex.section(record)
    local done = c.buildings[key]
    if done then return done, done end
    local p = progress[key]
    if p then return p.searched, p.total end
    return nil, nil
end

-- The kills a milestone needs (1 is the first), past the table every 50,000.
function Codex.killThreshold(index)
    if index <= #Codex.KILL_STEPS then return Codex.KILL_STEPS[index] end
    return Codex.KILL_STEPS[#Codex.KILL_STEPS] + Codex.KILL_EVERY * (index - #Codex.KILL_STEPS)
end

function Codex.killPay(index)
    if index <= #Codex.KILL_PAY then return Codex.KILL_PAY[index] end
    return Codex.KILL_EVERY_PAY
end

-- `n` zombies killed (one by default).
function Codex.kill(record, n)
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
