-- The trade part's name and what other parts hook into: items queued for the next supply crate, the events a sealed
-- box and a settlement raise, and finding the character a record belongs to (DESIGN 9).
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
local OA = OperationAcorn
local Store = OA.Store
local Trade = OA.Trade or {}
OA.Trade = Trade

-- The account part of a record's trade section (P1 shares it): missing numbers start at zero.
function Trade.account(record)
    local t = Store.section(record, "trade")
    t.credits = t.credits or 0
    t.trust = t.trust or 0
    t.stage = t.stage or 0
    t.milestones = t.milestones or 0
    t.bonus = t.bonus or 0
    t.sharedSerums = t.sharedSerums or 0
    return t
end

-- Where the record's terminal stands (the last one it put down), as x, y, z; nothing before the first. The story part
-- measures its distance bands from it.
function Trade.terminalPosition(record)
    local t = record.heli and record.heli.terminal
    if t then return t.x, t.y, t.z end
    return nil
end

-- Whether the record owes credits (a negative balance is a debt, DESIGN 9).
function Trade.inDebt(record)
    local t = record.trade
    return t ~= nil and (t.credits or 0) < 0
end

-- The sections this part keeps, made empty the first time.
function Trade.boxes(record) return Store.section(record, "boxes") end
function Trade.heli(record) return Store.section(record, "heli") end
function Trade.orders(record) return Store.section(record, "orders") end

-- Events for other parts (server side): fn(record, boxId, entries) when a box is sealed, fn(record, result) when a
-- helicopter has settled a delivery. A failing listener does not stop the others.
local sealedHooks, settledHooks = {}, {}

function Trade.onSealed(fn) table.insert(sealedHooks, fn) end
function Trade.onSettled(fn) table.insert(settledHooks, fn) end

local function fire(list, ...)
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then OA.log("trade hook failed:", tostring(err)) end
    end
end

function Trade.fireSealed(record, boxId, entries) fire(sealedHooks, record, boxId, entries) end
function Trade.fireSettled(record, result) fire(settledHooks, record, result) end

-- Notes for the manifest: fn(record, draft) returns a translation key, its arguments and what the remark encloses
-- ({ items = { { type, count } } }, or nil), or nil for no note. The first that answers writes the team's line (the
-- story part puts its ordered lines in front of the general ones). `draft` is what the settlement knows of the crate
-- by then: { kind, boxes, credits, trust, orders (the order results), cargo (the item specs so far), lines (the
-- settled lines), serial (the number this manifest gets), lastSerial, events }.
local noteProviders = {}

function Trade.addNoteProvider(fn, first)
    if first then table.insert(noteProviders, 1, fn) else table.insert(noteProviders, fn) end
end

function Trade.noteFor(record, draft)
    for _, fn in ipairs(noteProviders) do
        local ok, key, args, fx = pcall(fn, record, draft)
        if ok and key then return key, args, fx end
    end
    return nil
end

-- Papers and the like for one crate: fn(record, draft) returns a list of item specs (as Trade.addToDrop takes them) to
-- put in this crate, or nil. The story part sends its papers this way, one for each crate, when their time has come.
local crateProviders = {}

function Trade.addCrateProvider(fn)
    table.insert(crateProviders, fn)
end

function Trade.crateExtras(record, draft)
    local specs = {}
    for _, fn in ipairs(crateProviders) do
        local ok, list = pcall(fn, record, draft)
        if ok and type(list) == "table" then
            for _, item in ipairs(list) do
                local spec = Trade.dropSpec(item)
                if spec then specs[#specs + 1] = spec end
            end
        elseif not ok then
            OA.log("crate provider failed:", tostring(list))
        end
    end
    return specs
end

-- A drop item: a type name, or { type, count, mod = { key = value }, condition, used, fluid, amount, receipt, name }.
-- Written out as a table of these fields only, so that it can wait in the save: `mod` is item modData to set,
-- `condition` the item's condition, `used` a drainable's use delta (0 to 1, set after `mod`, which may change its
-- uses), `fluid` and `amount` fill a fluid container, `empty` makes a container empty, `receipt` a supply manifest's
-- contents, `name` the translation key of the name the item is given.
local SPEC_FIELDS = { "type", "count", "mod", "condition", "used", "fluid", "amount", "empty", "receipt", "name" }
local function dropSpec(item)
    if type(item) == "string" then return { type = item, count = 1 } end
    if type(item) ~= "table" or type(item.type) ~= "string" then return nil end
    local spec = {}
    for _, k in ipairs(SPEC_FIELDS) do
        local v = item[k]
        if type(v) == "table" then
            local copy = {}
            for mk, mv in pairs(v) do copy[mk] = mv end
            v = copy
        end
        spec[k] = v
    end
    spec.count = math.max(1, math.floor(spec.count or 1))
    return spec
end
Trade.dropSpec = dropSpec

-- Queues items for this record's next supply crate (story papers, parts, shared serums).
function Trade.addToDrop(record, items)
    local heli = Trade.heli(record)
    heli.drop = heli.drop or {}
    for _, item in ipairs(items or {}) do
        local spec = dropSpec(item)
        if spec then table.insert(heli.drop, spec) end
    end
end

-- Takes the queued items out (the helicopter does, as it loads the crate).
function Trade.takeDrop(record)
    local heli = Trade.heli(record)
    local list = heli.drop or {}
    heli.drop = {}
    return list
end

-- A copy of a table with its tables (plain values only: what the save keeps), so that two places in the save do not
-- share one table.
function Trade.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = Trade.copy(v) end
    return result
end

-- Whether a player character is the one a record belongs to.
function Trade.owns(record, character)
    return record ~= nil and character ~= nil and OA.Store.idOf(character) == record.id
end

-- Calls fn(character) for every player character in the game: the online players on a server, the local ones alone.
function Trade.eachCharacter(fn)
    if isServer() then
        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do fn(players:get(i)) end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local character = getSpecificPlayer(i)
            if character then fn(character) end
        end
    end
end

-- The character a record belongs to, when it is in the game now.
function Trade.characterOf(record)
    local found
    Trade.eachCharacter(function(character)
        if not found and not character:isDead() and Trade.owns(record, character) then found = character end
    end)
    return found
end

-- A time in the terminal's words: days and hours from a number of hours (rounded up to the quarter hour is not needed).
function Trade.clockText(hours)
    local day = OA.day(hours)
    local tod = OA.remainder(hours + OA.remainder(getGameTime():getTimeOfDay() - OA.hours(), 24), 24)
    local h = math.floor(tod)
    local m = math.floor((tod - h) * 60)
    return day, h, m
end

return Trade
