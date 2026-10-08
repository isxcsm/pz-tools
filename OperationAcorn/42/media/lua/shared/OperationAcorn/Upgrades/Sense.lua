-- The senses as pure functions (육감, 기척 감지): which way and how far the zombies around are, from plain lists of
-- positions, so that the unit tests can run them. The screen part (Senses.lua in the client folder) feeds them the
-- game's zombie list twice a second.
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Sense = {}
OA.Upgrades.Sense = Sense

-- The ring is cut into this many sectors, counted from the screen's left, clockwise (screen y grows downward).
Sense.SECTORS = 12

-- The sector a world offset falls in. The isometric view shows world x to the lower right and world y to the lower
-- left, so the screen offset is (dx - dy, (dx + dy) / 2).
function Sense.sector(dx, dy)
    local sx, sy = dx - dy, (dx + dy) / 2
    if sx == 0 and sy == 0 then return 1 end
    local angle = math.atan2(sy, sx) + math.pi
    local n = math.floor(angle / (2 * math.pi) * Sense.SECTORS + 0.5)
    if n >= Sense.SECTORS then n = 0 end
    return n + 1
end

-- (Sector 1 is centred on the screen's left, the others follow clockwise.)
-- The unit screen direction of a sector's middle (x right, y down).
function Sense.direction(sector)
    local angle = ((sector - 1) / Sense.SECTORS) * 2 * math.pi - math.pi
    return math.cos(angle), math.sin(angle)
end

-- Whether the presence sense shows now, given how the character moves (TREES: crouched and not running; the
-- advanced node lets it work walking upright at rank 1, running at rank 3).
function Sense.active(u, sneaking, running, sprinting)
    if Rules.rank(u, "sense") < 1 then return false end
    local plus = Rules.rank(u, "sensePlus")
    if running or sprinting then return plus >= 3 end
    return sneaking or plus >= 1
end

-- Whether the sense also tells breaking-in, other floors and vehicle or alarm noises (advanced rank 2).
function Sense.extended(u)
    return Rules.rank(u, "sensePlus") >= 2
end

-- Whether the sense tells how far (rank 2 of the node itself).
function Sense.distance(u)
    return Rules.rank(u, "sense") >= 2
end

-- Scans zombies { x, y, z, thump } around (px, py, pz) within radius: the sectors that have any, as
-- { [sector] = { n = count, d = nearest distance, thump = any is breaking in } }. Only the character's own floor
-- unless `floors` (the advanced rank) lets the floors above and below count.
function Sense.scan(zombies, px, py, pz, radius, floors)
    local out = {}
    local r2 = radius * radius
    for i = 1, #zombies do
        local z = zombies[i]
        local dx, dy = z.x - px, z.y - py
        local d2 = dx * dx + dy * dy
        if d2 <= r2 and (floors or math.abs(z.z - pz) < 0.5) then
            local s = Sense.sector(dx, dy)
            local e = out[s]
            local d = math.sqrt(d2)
            if not e then
                e = { n = 0, d = d, thump = false }
                out[s] = e
            end
            e.n = e.n + 1
            if d < e.d then e.d = d end
            if z.thump then e.thump = true end
        end
    end
    return out
end

-- The sixth sense: whether any zombie is within radius on the character's floor or the one beside it.
function Sense.hunch(zombies, px, py, pz, radius)
    local r2 = radius * radius
    for i = 1, #zombies do
        local z = zombies[i]
        local dx, dy = z.x - px, z.y - py
        if dx * dx + dy * dy <= r2 and math.abs(z.z - pz) <= 1.01 then return true end
    end
    return false
end

return Sense
