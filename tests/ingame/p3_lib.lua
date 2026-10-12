-- Helpers the P3 (upgrades) checks share (P3T). Each check runs RUN("p3_lib.lua") first.
-- Run from the debug console after defining RUN (see the README of tests/ingame). Single player, the mod and PZ Extension API on.
P3T = {}

-- A print function for a check's lines: its arguments as text with spaces between, after the tag ("[p3api] ").
function P3T.say(tag)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        print("[" .. tag .. "] " .. table.concat(parts, " "))
    end
end

-- Prints "ok" or "BAD" with the label; returns the condition.
function P3T.check(say, label, condition, detail)
    say(label, condition and "ok" or "BAD", detail ~= nil and tostring(detail) or "")
    return condition and true or false
end

function P3T.near(a, b, eps)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-6)
end

-- The local character, its record, its upgrades section and the record id.
function P3T.record()
    local player = getPlayer()
    local id = player:getModData().OA_Id
    local record = id and OperationAcorn.Store.player(id)
    local u = record and OperationAcorn.Upgrades.Rules.section(record)
    return record, player, u, id
end

-- Empties the upgrades section (keeps the table, so u stays the record's): a check that spends points starts from
-- nothing, whatever an earlier run left.
function P3T.fresh(u)
    for k in pairs(u) do u[k] = nil end
    OperationAcorn.Upgrades.Rules.fill(u)
end

-- An item of a type made in the character's inventory.
function P3T.give(type)
    return getPlayer():getInventory():AddItem(type)
end

-- Gives the record n points of a tree (the first one opens it) without the items.
function P3T.points(u, tree, n)
    for _ = 1, n do OperationAcorn.Upgrades.Rules.inject(u, tree) end
end

-- A plan from a list of ids (one rank each); the choice goes with every step.
function P3T.steps(ids, choice)
    local steps = {}
    for _, id in ipairs(ids) do steps[#steps + 1] = { id = id, choice = choice } end
    return steps
end

-- Tells the screens the record changed.
function P3T.changed(record)
    OperationAcorn.Sync.changed("upgrades", record.id)
end
