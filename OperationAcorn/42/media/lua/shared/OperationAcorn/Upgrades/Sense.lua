-- The senses as pure functions (육감, 기척 감지): which way and how far the zombies and the noises around are, from
-- plain lists of positions, so that the unit tests can run them. The screen part (Senses.lua in the client folder) feeds
-- them the game's zombie list twice a second and the world sounds as they are made.
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Sense = {}
OA.Upgrades.Sense = Sense

-- How few marks the senses draw, as Visual Sounds caps its cues: things less than 30 degrees apart on the screen are
-- one mark (a crowd, or noises from one way), and at most this many marks show at once.
Sense.MERGE_COS = math.cos(math.pi / 6)
Sense.ZOMBIE_MARKS = 8
Sense.NOISE_MARKS = 4
-- A noise's distance band (tiles): near below NEAR, mid below MID, far beyond. An alarm in the near band is one the
-- zombies around are coming to; past MID it draws another street's.
Sense.NEAR = 12
Sense.MID = 35

-- The unit screen direction of a world offset. The isometric view shows world x to the lower right and world y to the
-- lower left, so the screen offset is (dx - dy, (dx + dy) / 2) (x right, y down). No offset counts as the screen's left.
function Sense.screen(dx, dy)
    local sx, sy = dx - dy, (dx + dy) / 2
    local len = math.sqrt(sx * sx + sy * sy)
    if len == 0 then return -1, 0 end
    return sx / len, sy / len
end

-- The band of a noise `d` tiles away: 1 near, 2 mid, 3 far.
function Sense.band(d)
    if d < Sense.NEAR then return 1 end
    if d < Sense.MID then return 2 end
    return 3
end

-- Of marks[1..count] (only those of `band`, when it is given), the one whose screen direction is nearest (sx, sy), and
-- the cosine between the two (-2 when there is none).
local function closest(marks, count, sx, sy, band)
    local best, bestDot = nil, -2
    for i = 1, count do
        local m = marks[i]
        if band == nil or m.band == band then
            local dot = m.sx * sx + m.sy * sy
            if dot > bestDot then best, bestDot = m, dot end
        end
    end
    return best, bestDot
end

-- Whether the presence sense shows now, given how the character moves (TREES: crouched and not running; the
-- advanced node lets it work walking upright at rank 1, running at rank 3).
function Sense.active(u, sneaking, running, sprinting)
    if Rules.rank(u, "sense") < 1 then return false end
    local plus = Rules.rank(u, "sensePlus")
    if running or sprinting then return plus >= 3 end
    return sneaking or plus >= 1
end

-- Whether the sense also tells breaking-in, other floors and the noises around (advanced rank 2).
function Sense.extended(u)
    return Rules.rank(u, "sensePlus") >= 2
end

-- Whether the sense tells how far (rank 2 of the node itself).
function Sense.distance(u)
    return Rules.rank(u, "sense") >= 2
end

local function nearerFirst(a, b) return a.d < b.d end

-- Scans zombies { x, y, z, thump } around (px, py, pz) within radius (only the character's own floor unless `floors`,
-- the advanced rank, lets the other floors count) into at most ZOMBIE_MARKS marks, nearest first: { wx, wy = the world
-- unit direction of the mark's nearest zombie, sx, sy = the same on the screen, n = zombies in it, d = the nearest's
-- distance, thump = any is breaking in, up / down = any is on a floor above / below }. A zombie within the merge angle
-- of a mark joins it; past the cap it joins the mark nearest its way. The plain positions are given d, dx and dy.
function Sense.scan(zombies, px, py, pz, radius, floors)
    local within = {}
    local r2 = radius * radius
    for i = 1, #zombies do
        local z = zombies[i]
        local dx, dy = z.x - px, z.y - py
        local d2 = dx * dx + dy * dy
        if d2 <= r2 and (floors or math.abs(z.z - pz) < 0.5) then
            z.d, z.dx, z.dy = math.sqrt(d2), dx, dy
            within[#within + 1] = z
        end
    end
    table.sort(within, nearerFirst)
    local out = {}
    for i = 1, #within do
        local z = within[i]
        local sx, sy = Sense.screen(z.dx, z.dy)
        local m, dot = closest(out, #out, sx, sy)
        if not m or (dot < Sense.MERGE_COS and #out < Sense.ZOMBIE_MARKS) then
            local wx, wy = -math.sqrt(0.5), math.sqrt(0.5)
            if z.d > 0 then wx, wy = z.dx / z.d, z.dy / z.d end
            m = { wx = wx, wy = wy, sx = sx, sy = sy, n = 0, d = z.d, thump = false }
            out[#out + 1] = m
        end
        m.n = m.n + 1
        if z.thump then m.thump = true end
        if z.z - pz >= 0.5 then m.up = true elseif pz - z.z >= 0.5 then m.down = true end
    end
    return out
end

-- How far the character hears a world sound, as a share of its reach: the vanilla hearing traits (Visual Sounds
-- uses the same shares).
function Sense.hearing(deaf, keen, hard)
    if deaf then return 0 end
    if keen then return 1.2 end
    if hard then return 0.8 end
    return 1
end

-- Whether noise `a` leaves the full list before `b`: any other noise before an alarm, else the one running out first.
local function goesBefore(a, b)
    local aa, ba = a.kind == "alarm", b.kind == "alarm"
    if aa ~= ba then return ba end
    return a.untilMs < b.untilMs
end

-- Puts a heard noise in the list of noises (in place), until `untilMs`. A source heard again (a running engine or a
-- ringing alarm is, many times a second) keeps its one entry, moved and lasting longer; noises that ran out leave, and
-- past `max` the one closest to running out goes, an alarm last. `key` is what made it (the source, or its square).
-- Returns the list and whether the noise is a new entry.
function Sense.heard(list, key, kind, x, y, z, now, untilMs, max)
    local n = 0
    local found
    for i = 1, #list do
        local s = list[i]
        if s.untilMs > now then
            n = n + 1
            list[n] = s
            if s.key == key then found = s end
        end
    end
    for i = #list, n + 1, -1 do list[i] = nil end
    local new = not found
    if new then
        if n >= max then
            local drop = 1
            for i = 2, n do
                if goesBefore(list[i], list[drop]) then drop = i end
            end
            table.remove(list, drop)
        end
        found = { key = key }
        list[#list + 1] = found
    end
    found.kind, found.x, found.y, found.z, found.untilMs = kind, x, y, z, untilMs
    return list, new
end

local live = {}
local function alarmsThenNearer(a, b)
    local aa, ba = a.kind == "alarm", b.kind == "alarm"
    if aa ~= ba then return aa end
    return a.d < b.d
end

-- The marks of the noises heard (Sense.heard's list) as seen from (px, py) at `now`, into `out` (reused; returned):
-- at most NOISE_MARKS, alarms first, then the nearer. A noise within the merge angle of a mark of its own distance
-- band joins it (the mark lasts while any of them does); one that finds no room is left out. A mark is { kind, x, y,
-- z = its first noise's, d, band, n = noises in it, untilMs, sx, sy }. The noises are given d.
function Sense.marks(sounds, px, py, now, out)
    local n = 0
    for i = 1, #sounds do
        local s = sounds[i]
        if s.untilMs > now then
            local dx, dy = s.x - px, s.y - py
            s.d = math.sqrt(dx * dx + dy * dy)
            n = n + 1
            live[n] = s
        end
    end
    table.sort(live, alarmsThenNearer)
    local count = 0
    for i = 1, n do
        local s = live[i]
        local band = Sense.band(s.d)
        local sx, sy = Sense.screen(s.x - px, s.y - py)
        local m, dot = closest(out, count, sx, sy, band)
        if m and dot >= Sense.MERGE_COS then
            m.n = m.n + 1
            if s.untilMs > m.untilMs then m.untilMs = s.untilMs end
        elseif count < Sense.NOISE_MARKS then
            count = count + 1
            m = out[count] or {}
            out[count] = m
            m.kind, m.x, m.y, m.z, m.d, m.band = s.kind, s.x, s.y, s.z, s.d, band
            m.n, m.untilMs, m.sx, m.sy = 1, s.untilMs, sx, sy
        end
        live[i] = nil
    end
    for i = #out, count + 1, -1 do out[i] = nil end
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
