-- Light from the mod's things (a terminal's screen, a machine's lamps): a game light source on the thing's square (the
-- cell's lamppost list) while it is lit, only where the game draws. The game saves none of these and drops one whose
-- square leaves the loaded area (LightingJNI.checkLights), so a thing sets its light again whenever it shows its look
-- (its chunk loading, its power, a switch); setting the light it already has costs a look in that list. A light goes
-- when its thing is taken off the square (OnObjectAboutToBeRemoved). Nothing runs per tick.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Lights = {}
OA.Lights = Lights

-- "x,y,z" -> { source, object, spec }; how many there are (the removal handler returns at once while none).
local lit, count = {}, 0

local function keyOf(square)
    return square:getX() .. "," .. square:getY() .. "," .. square:getZ()
end

local function drop(key)
    local entry = lit[key]
    if not entry then return end
    lit[key] = nil
    count = count - 1
    local cell = getCell and getCell()
    if cell then cell:removeLamppost(entry.source) end
end

-- `object` gives off `spec` ({ r, g, b, radius in squares }, a table kept as a constant) around its square, or no
-- light (nil).
function Lights.set(object, spec)
    if isServer() then return end
    local square = object and object:getSquare()
    local cell = getCell and getCell()
    if not (square and cell and cell.addLamppost) then return end
    local key = keyOf(square)
    local entry = lit[key]
    if entry and spec and entry.spec == spec and entry.object == object
        and cell:getLamppostPositions():contains(entry.source) then
        return
    end
    drop(key)
    if not spec then return end
    local source = cell:addLamppost(square:getX(), square:getY(), square:getZ(), spec[1], spec[2], spec[3], spec[4])
    lit[key] = { source = source, object = object, spec = spec }
    count = count + 1
end

-- The light an object gives off now, or nil (the tests, a window that asks).
function Lights.of(object)
    local square = object and object:getSquare()
    local entry = square and lit[keyOf(square)]
    if entry and entry.object == object then return entry.spec end
    return nil
end

function Lights.onRemoved(object)
    if count == 0 or not object then return end
    local square = object:getSquare()
    if not square then return end
    local key = keyOf(square)
    local entry = lit[key]
    if entry and entry.object == object then drop(key) end
end

if not isServer() then OA.on("OnObjectAboutToBeRemoved", Lights.onRemoved) end

return Lights
