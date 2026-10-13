-- Helpers the P2 checks share (P2T). Each check runs RUN("p2_lib.lua") first.
P2T = {}

function P2T.say(tag)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        print("[" .. tag .. "] " .. table.concat(parts, " "))
    end
end

function P2T.check(say, label, condition, detail)
    say(label, condition and "ok" or "BAD", detail ~= nil and tostring(detail) or "")
    return condition and true or false
end

-- The local character's record (made by the first hello) and the character.
function P2T.record()
    local player = getPlayer()
    local id = player:getModData().OA_Id
    return id and OperationAcorn.Store.player(id), player
end

-- A clear outdoor square for a delivery box near the character, or the nearest free one.
function P2T.spot()
    local T = OperationAcorn.Trade.Objects
    local player = getPlayer()
    local x, y = math.floor(player:getX()), math.floor(player:getY())
    return T.findClear(x, y, 25) or T.search(x, y, 0, 15, function(s) return T.free(s) end)
end

-- Objects made by a check are listed here so that P2_CLEAN() removes them.
P2T.made = P2T.made or {}
function P2T.keep(object) P2T.made[#P2T.made + 1] = object; return object end

function P2_CLEAN()
    local Objects = OperationAcorn.Trade.Objects
    for _, object in ipairs(P2T.made) do
        if object:getSquare() then Objects.remove(object) end
    end
    P2T.made = {}
    print("[p2] cleaned")
end
