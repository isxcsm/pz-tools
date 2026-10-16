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

-- Takes the next rank of a node as a player would get there: a point given when the tree has none free, the rows
-- before it filled with other nodes of the tree, its prerequisites taken first, its capstone fragment counted in; a
-- board node opens the board (the three capstones) and gets shared points. A node already at its last rank is fine.
-- Returns true, or false and why it could not.
function P3T.buy(u, id)
    local Rules, Data = OperationAcorn.Upgrades.Rules, OperationAcorn.Upgrades.Data
    local node = Data.byId[id]
    if not node then return false, "unknown" end
    for _ = 1, 60 do
        local why = Rules.blocked(u, id)
        if not why then return Rules.buy(u, id) end
        if why == "maxed" then return true end
        if why == "points" and node.board then
            Rules.injectShared(u)
        elseif why == "boardClosed" then
            -- the board opens with the three capstones
            for _, tree in ipairs(Data.TREES) do
                local cap = Data.capstone(tree)
                local ok, w = P3T.buy(u, cap.id)
                if not ok then return false, "capstone " .. cap.id .. " " .. tostring(w) end
            end
        elseif why == "points" or why == "treeClosed" then
            Rules.inject(u, node.tree)
        elseif why == "prereq" then
            for _, need in ipairs(node.req) do
                if Rules.rank(u, need[1]) < need[2] then
                    local ok, w = P3T.buy(u, need[1])
                    if not ok then return false, "prereq " .. need[1] .. " " .. tostring(w) end
                end
            end
        elseif why == "row" then
            -- a rank of another node of an earlier row (free points first)
            local filler
            for _, other in ipairs(Data.treeNodes(node.tree)) do
                if not filler and other.id ~= id and other.row < node.row and not Rules.blocked(u, other.id) then
                    filler = other.id
                end
            end
            if not filler then
                Rules.inject(u, node.tree)
                for _, other in ipairs(Data.treeNodes(node.tree)) do
                    if not filler and other.id ~= id and other.row < node.row and not Rules.blocked(u, other.id) then
                        filler = other.id
                    end
                end
            end
            if not filler then return false, "row" end
            Rules.buy(u, filler)
        elseif why == "sealed" then
            Rules.unseal(u, node.tree)
        else
            return false, why
        end
    end
    return false, "too many steps"
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
