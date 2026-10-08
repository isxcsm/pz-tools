-- Helpers the P5 (base machines) checks share. Each check runs RUN("p5_lib.lua") first. Single player, a character
-- standing in open ground with a clear 20 x 20 patch to the east and south (the checks put machines down there).
P5T = P5T or {}

function P5T.say(tag)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        print("[" .. tag .. "] " .. table.concat(parts, " "))
    end
end

-- Prints "ok" or "BAD" with the label; returns the condition.
function P5T.check(say, label, condition, detail)
    say(label, condition and "ok" or "BAD", detail ~= nil and tostring(detail) or "")
    return condition and true or false
end

function P5T.near(a, b, eps)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-6)
end

function P5T.machines() return OperationAcorn.Machines end

-- The square at an offset from the character (x east, y south), same floor.
function P5T.square(dx, dy)
    local p = getPlayer()
    return getCell():getGridSquare(math.floor(p:getX()) + dx, math.floor(p:getY()) + dy, math.floor(p:getZ()))
end

function P5T.give(fullType, count)
    local inv = getPlayer():getInventory()
    local last
    for _ = 1, count or 1 do last = inv:AddItem(fullType) end
    return last
end

-- Every machine put down by a check, to take away with P5_CLEAN().
P5T.placed = P5T.placed or {}

-- Puts a machine down at the offset (the anchor square), facing dir; returns the anchor object or nil and a reason.
function P5T.place(kind, dx, dy, dir)
    local M = P5T.machines()
    local square = P5T.square(dx, dy)
    local ok, reason = M.canPlace(kind, square, dir or "S")
    if not ok then return nil, reason end
    local item = P5T.give(M.itemFullType(kind))
    local object = M.place(kind, square, getPlayer(), item, dir or "S")
    item:getContainer():Remove(item)
    P5T.placed[#P5T.placed + 1] = object
    return object
end

-- Pretends the machines have electricity (the work checks) until P5T.realPower() is called.
function P5T.fakePower()
    local M = P5T.machines()
    if not P5T.realHasPower then P5T.realHasPower = M.hasPower end
    M.hasPower = function() return true end
end

function P5T.realPower()
    if P5T.realHasPower then
        P5T.machines().hasPower = P5T.realHasPower
        P5T.realHasPower = nil
    end
end

-- Lets a machine work `hours` of world time without waiting: starts its clock, sets it back, works it.
function P5T.work(object, hours)
    local M = P5T.machines()
    M.update(object)
    local state = M.state(object)
    state.last = state.last - hours
    return M.update(object)
end

-- How many items of a full type a machine container holds.
function P5T.count(container, fullType)
    local n = 0
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        if items:get(i):getFullType() == fullType then n = n + 1 end
    end
    return n
end

function P5_CLEAN()
    local M = P5T.machines()
    P5T.realPower()
    for _, object in ipairs(P5T.placed) do
        if M.state(object) then M.remove(object) end
    end
    P5T.placed = {}
    print("[p5] cleaned")
end
