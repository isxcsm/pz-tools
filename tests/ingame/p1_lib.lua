-- Helpers the P1 checks share (P1T). Each check runs RUN("p1_lib.lua") first.
P1T = {}

-- A print function for a check's lines: its arguments as text with spaces between, after the tag ("[p1value] ").
function P1T.say(tag)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        print("[" .. tag .. "] " .. table.concat(parts, " "))
    end
end

-- Prints "ok" or "BAD" with the label; returns the condition.
function P1T.check(say, label, condition, detail)
    say(label, condition and "ok" or "BAD", detail ~= nil and tostring(detail) or "")
    return condition and true or false
end

-- Whether two numbers are within eps.
function P1T.near(a, b, eps)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-6)
end

-- The local character and its record (made by the first hello), or nil and a message.
function P1T.record()
    local player = getPlayer()
    local id = player:getModData().OA_Id
    local record = id and OperationAcorn.Store.player(id)
    return record, player
end

-- An item of a type made in the character's inventory.
function P1T.give(type)
    return getPlayer():getInventory():AddItem(type)
end

-- Milliseconds, for timing.
function P1T.ms()
    return getTimestampMs()
end
