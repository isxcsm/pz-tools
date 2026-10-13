-- Helpers the checks share (BUT): a check runs RUN("bu_lib.lua") first, as it runs bu_rack.lua for BURACK.
BUT = {}

-- A print function for a check's lines: its arguments as text with spaces between, after the check's tag ("[bu12] ").
function BUT.say(tag)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        print("[" .. tag .. "] " .. table.concat(parts, " "))
    end
end

-- A number with three places, "nil" for none.
function BUT.f(value) return value and string.format("%.3f", value) or "nil" end

-- Litres with the given places, "-" for none.
function BUT.litres(value, places) return value and string.format("%." .. places .. "f", value) or "-" end

-- The first panel in the store within 60 squares of the player (by x and y).
function BUT.nearPanel()
    local player = getPlayer()
    for _, panel in ipairs(BuildingUtilities.Store.list()) do
        if math.abs(panel.x - player:getX()) + math.abs(panel.y - player:getY()) < 60 then
            return panel
        end
    end
end

-- The first square around (x, y) on level z, square ring by ring from radius from to radius to, that test(square)
-- takes; nil when none does.
function BUT.square(x, y, z, from, to, test)
    local cell = getCell()
    for r = from, to do
        for dx = -r, r do
            for dy = -r, r do
                local q = cell:getGridSquare(x + dx, y + dy, z)
                if q and test(q) then return q end
            end
        end
    end
end

-- The first square around the player on the ground (BUT.square).
function BUT.squareNear(from, to, test)
    local p = getPlayer():getSquare()
    return BUT.square(p:getX(), p:getY(), 0, from, to, test)
end

-- An outside square with only its floor on it and no one on it.
function BUT.freeOutside(q)
    return q:isOutside() and q:getObjects():size() == 1 and q:isFree(false) and q:getMovingObjects():size() == 0
end

-- Where the mod's Lua is, for reloadLuaFile: BU_LUA_DIR when set, else the active mod's own folder.
function BUT.luaDir()
    if BU_LUA_DIR then return BU_LUA_DIR end
    local info = getModInfoByID("BuildingUtilities")
    return info and info:getVersionDir() and (info:getVersionDir() .. "/media/lua/")
end
