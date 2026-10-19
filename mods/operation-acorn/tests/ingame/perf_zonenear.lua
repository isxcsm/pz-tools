-- The cost of the API's zoneNear condition where OA asks it: a roadside camp's middle searched on the rings 2 to 40
-- (every other ring) about the character, as Game.settleGround does. The worst case is a zone type that is nowhere (every
-- anchor looks all the way out); then OA's real filter, then each square of a 41x41 area once.
local say = function(...) print("[perfzone]", ...) end
local squares = OperationAcorn.api().squares
local p = getPlayer()
local x, y = math.floor(p:getX()), math.floor(p:getY())
local function ms(label, n, fn)
    local t0 = getTimestampMs()
    local r
    for _ = 1, n do r = fn() end
    say(label, string.format("%.1f ms a call", (getTimestampMs() - t0) / n), tostring(r))
end
local ground = { building = "none", outside = true, wet = false, natural = true }
local function with(near)
    local f = { free = true, zoneNear = near }
    for k, v in pairs(ground) do f[k] = v end
    return f
end
local nowhere = { { offsets = { 0, 0 }, filter = with({ type = "NoSuchZone", none = 5, some = 14 }) },
    { box = { -4, -4, 4, 4, 2 }, filter = ground } }
local roadside = { { offsets = { 0, 0 }, filter = with({ type = "Nav", none = 5, some = 14 }) },
    { box = { -4, -4, 4, 4, 2 }, filter = ground } }
local plain = { { offsets = { 0, 0 }, filter = with(nil) }, { box = { -4, -4, 4, 4, 2 }, filter = ground } }
local rings = { x = x, y = y, z = 0, from = 2, to = 40, step = 2 }
ms("rings, no zone anywhere (worst)", 5, function() return squares.fit(rings, nowhere) end)
ms("rings, roadside (OA)", 5, function() return squares.fit(rings, roadside) end)
ms("rings, plain camp middle", 5, function() return squares.fit(rings, plain) end)
local onlyNear = { { offsets = { 0, 0 }, filter = { zoneNear = { type = "NoSuchZone", none = 5, some = 14 } } } }
ms("41x41 area, zoneNear alone, every square", 3, function()
    return squares.fit({ x1 = x - 20, y1 = y - 20, x2 = x + 20, y2 = y + 20, z = 0 }, onlyNear)
end)
say("done")
