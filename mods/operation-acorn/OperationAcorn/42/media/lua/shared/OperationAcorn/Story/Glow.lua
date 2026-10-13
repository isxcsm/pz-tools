-- The arithmetic of the hallucination overlay (client/Story/Hallucination): how bright it is at a moment, and which
-- edge of the screen faces a drop site. Pure, so it is tested outside the game.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Glow = {}
OA.Glow = Glow

-- The overlay's brightness 0 to 1 at a time into a run of `total` ms: rises fast, holds, falls slowly.
function Glow.envelope(t, total)
    if t <= 0 or t >= total then return 0 end
    local rise, fall = total * 0.12, total * 0.45
    if t < rise then return t / rise end
    if t > total - fall then
        local k = (total - t) / fall
        return k * k
    end
    return 1
end

-- Which screen edge faces a world offset (dx, dy): "left", "right", "top" or "bottom". The game's view is
-- isometric: east-south is to the right and down.
function Glow.edge(dx, dy)
    -- Screen x runs with east minus south, screen y with east plus south (a tile is twice as wide as tall, and
    -- the screen about 16:9, so the two meet near 0.9).
    local sx = dx - dy
    local sy = dx + dy
    if math.abs(sx) >= math.abs(sy) * 0.9 then
        return sx > 0 and "right" or "left"
    end
    return sy > 0 and "bottom" or "top"
end


return Glow
