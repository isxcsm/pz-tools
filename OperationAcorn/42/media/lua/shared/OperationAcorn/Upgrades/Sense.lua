-- The senses as pure functions (육감, 기척 감지): the sounds heard around, kept where they were made for a while as
-- Visual Sounds keeps its cues, and the zombie sounds told from plain lists of zombies, so that the unit tests can run
-- them. The screen part (Senses.lua in the client folder) feeds them the world sounds as they are made, the extension
-- API's zombie sounds, or the game's zombie list twice a second.
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Sense = {}
OA.Upgrades.Sense = Sense

-- How many sounds are kept at once: zombies' and the other noises' (each one mark, on the one ring).
Sense.ZOMBIE_MARKS = 8
Sense.NOISE_MARKS = 4
-- How long a sound shows (ms), by kind; one heard again lasts from then. A zombie beating on something is heard at
-- every blow, about once a second, so it shows while it goes on.
Sense.LIFE = { zombie = 2000, aggro = 2200, attack = 2200, thump = 1300, alarm = 2500, vehicle = 2500, device = 2500,
    noise = 2500 }
-- Without the extension API's zombie sounds, how often a zombie is taken to make one (ms): idle, and after a target.
Sense.IDLE_MS = 5000
Sense.HUNT_MS = 2000
-- The first sound of a zombie newly in reach comes within this (ms), spread over the zombies.
Sense.FIRST_MS = 1500
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

-- How far the character hears a world sound, as a share of its reach: the vanilla hearing traits (Visual Sounds
-- uses the same shares).
function Sense.hearing(deaf, keen, hard)
    if deaf then return 0 end
    if keen then return 1.2 end
    if hard then return 0.8 end
    return 1
end

-- What a full list keeps longest: an alarm, then a zombie coming or striking, then one beating on something.
local KEEP = { alarm = 4, aggro = 3, attack = 3, thump = 2 }

-- Whether sound `a` leaves the full list before `b`: the one kept less, else the one running out first.
local function goesBefore(a, b)
    local ka, kb = KEEP[a.kind] or 1, KEEP[b.kind] or 1
    if ka ~= kb then return ka < kb end
    return a.untilMs < b.untilMs
end

-- Puts a heard sound in a list of sounds (in place), until `untilMs`. A source heard again (a running engine or a
-- ringing alarm is, many times a second) keeps its one entry, moved and lasting longer (it keeps when it was first
-- heard, `born`, so it does not come on again); sounds that ran out leave, and past `max` the one kept least and closest
-- to running out goes (goesBefore). `key` is what made it (the source, or its square). Returns the list and whether
-- the sound is a new entry.
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
        found = { key = key, born = now }
        list[#list + 1] = found
    end
    found.kind, found.x, found.y, found.z, found.untilMs = kind, x, y, z, untilMs
    return list, new
end

-- The zombie sounds told from the zombies around, without the extension API's: a zombie newly in reach makes one soon
-- (within FIRST_MS, spread by when it came), then one every IDLE_MS (HUNT_MS once it has a target), its time spread by
-- its number so that a crowd does not call at once; one that takes a target ("aggro") or lunges or strikes ("attack")
-- makes one at once. `zombies` are { ref, x, y, z, hunt, attack } (ref: what stays the same for a zombie); only those
-- within `radius` of (px, py), on the floor of pz unless `floors`, are heard. `memo` (kept by the caller) remembers
-- each zombie; ones not in reach are forgotten. Returns the sounds as { kind, key = ref, x, y, z } in `out` (reused).
function Sense.voices(zombies, memo, px, py, pz, radius, floors, now, out)
    local n = 0
    local r2 = radius * radius
    memo.count = memo.count or 0
    memo.seen = (memo.seen or 0) + 1
    local seen = memo.seen
    local by = memo.by or {}
    memo.by = by
    for i = 1, #zombies do
        local z = zombies[i]
        local dx, dy = z.x - px, z.y - py
        if dx * dx + dy * dy <= r2 and (floors or math.abs(z.z - pz) < 0.5) then
            local m = by[z.ref]
            local kind
            if not m then
                memo.count = memo.count + 1
                m = { number = memo.count, hunt = z.hunt, attack = z.attack }
                m.due = now + (m.number * 397) % Sense.FIRST_MS
                by[z.ref] = m
            elseif z.attack and not m.attack then
                kind = "attack"
            elseif z.hunt and not m.hunt then
                kind = "aggro"
            end
            m.hunt, m.attack, m.seen = z.hunt, z.attack, seen
            if not kind and now >= m.due then kind = "zombie" end
            if kind then
                local every = z.hunt and Sense.HUNT_MS or Sense.IDLE_MS
                -- a quarter of the time either way, by the zombie's number
                m.due = now + every * (0.75 + 0.5 * ((m.number * 0.618034) % 1))
                n = n + 1
                local e = out[n] or {}
                out[n] = e
                e.kind, e.key, e.x, e.y, e.z = kind, z.ref, z.x, z.y, z.z
            end
        end
    end
    -- forgotten after the walk (the game's tables do not take a key taken away while they are walked)
    local gone = memo.gone or {}
    memo.gone = gone
    local g = 0
    for ref, m in pairs(by) do
        if m.seen ~= seen then g = g + 1 gone[g] = ref end
    end
    for i = 1, g do by[gone[i]] = nil gone[i] = nil end
    for i = #out, n + 1, -1 do out[i] = nil end
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
