-- The zombie missions (DESIGN 9 '좀비 임무', NUMBERS 9): an area clear (the whole group killed) and a target sample (a
-- mission sample from each target, Story/Harvest). The mission (Missions: createZombies) keeps only counts; the group is
-- in the world only while the player is about. Its zombies carry the API's mark of the mission's id (Story/Game), which
-- the world keeps with them. Coming within NEAR of the circle once its squares are loaded brings what is missing of it,
-- at squares the player cannot see yet; going LEAVE farther ends the visit (the API's hold dissolves the group as its
-- chunks unload, so nothing of it is left virtual). While the mission runs the API holds the group to the circle. When
-- it ends, what is left of the group goes.
--
-- What touches the game goes through the game adapter (Missions.game, Story/Game): holdZombies, releaseZombies,
-- areaLoaded, countMarked, spawnZombies. Tests give it fakes.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Rewards"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Missions"
local OA = OperationAcorn
local Data, Rewards, Places, Missions = OA.StoryData, OA.Rewards, OA.Places, OA.Missions
local Zombies = {}
OA.ZombieMissions = Zombies

-- A corpse is harvested within this many hours of death (Story/Harvest): a target killed and left longer is lost, and
-- another comes in its place.
Zombies.FRESH_HOURS = 24

-- What this session did for each mission (not saved: a world loaded again starts over): held = the API holds its group,
-- ready = its squares were loaded at the last look, here = the group was brought for this visit.
local held, ready, here = {}, {}, {}

local function game()
    return Missions.game
end

-- The record's zombie mission that is running (taken, not sealed), or nil.
function Zombies.running(record)
    for _, m in ipairs(Missions.live(record)) do
        if m.zombies and m.state == "open" then return m end
    end
    return nil
end

-- How many of the group should be alive now: an area clear's not killed; a target mission's not harvested and not lying
-- dead and still fresh (a target dead longer is forgotten: another comes).
function Zombies.wanted(m, now)
    local z = m.zombies
    if z.kind == "clear" then return math.max(0, z.total - z.killed) end
    for i = #z.dead, 1, -1 do
        if now - z.dead[i] > Zombies.FRESH_HOURS then table.remove(z.dead, i) end
    end
    return math.max(0, z.total - z.taken - #z.dead)
end

-- A zombie marked with `key` (a mission's id) died (OnZombieDead), at world hour `now`. An area clear counts it wherever
-- it died, and is done with the last one (paid at once: there is nothing to send); a target mission notes the death for
-- its corpse.
function Zombies.died(key, now)
    for _, record in pairs(OA.Store.players()) do
        local m = Zombies.running(record)
        local z = m and m.zombies
        if z and m.id == key then
            if z.kind == "clear" then
                z.killed = math.min(z.total, z.killed + 1)
                if z.killed >= z.total then
                    if Rewards.judge(m.deadline, now) == "ok" then
                        Missions.pay(record, m)
                    else
                        Missions.finish(record, m, "expired")
                    end
                else
                    OA.Sync.changed("missions", record.id)
                end
            else
                z.dead[#z.dead + 1] = now
            end
        end
    end
end

-- A target's corpse was harvested (Story/Harvest), dead since `death` (world hours) and marked with `key`: the running
-- target mission of that id takes it as its next sample. Returns the mission, the new piece and the sample's OA_Mission,
-- or nil when the corpse is not one of its targets.
function Zombies.takeTarget(record, key, death)
    local m = Zombies.running(record)
    local z = m and m.zombies
    if not (z and z.kind == "target" and key ~= nil and m.id == key) then return nil end
    -- the death noted for this corpse is let go (the nearest in time; none when it died unseen)
    local best, bestD
    for i, t in ipairs(z.dead) do
        local d = math.abs(t - (death or t))
        if not bestD or d < bestD then best, bestD = i, d end
    end
    if best then table.remove(z.dead, best) end
    z.taken = z.taken + 1
    z.seq = z.seq + 1
    local it = { key = "T" .. tostring(z.seq), type = Data.fullType("TissueTarget"), mode = "given", placed = true }
    m.items[#m.items + 1] = it
    OA.Sync.changed("missions", record.id)
    return m, it, m.id .. "#" .. it.key
end

-- Every game minute (the server): each running zombie mission is held, and its group brought when the player comes
-- near, or the visit ended when they have gone.
function Zombies.tick(now)
    local g = game()
    if not g then return end
    for _, record in pairs(OA.Store.players()) do
        local m = Zombies.running(record)
        if m then Zombies.look(record, m, now) end
    end
end

function Zombies.look(record, m, now)
    local g = game()
    if not held[m.id] and g.holdZombies then
        g.holdZombies(m)
        held[m.id] = true
    end
    local px, py = g.playerPosition(record)
    if not px then return end
    local d = Places.distance(px, py, m.area.x, m.area.y)
    if d <= m.area.r + Data.ZOMBIE_NEAR then
        if here[m.id] then return end
        if not g.areaLoaded(m.area) then
            ready[m.id] = nil
            return
        end
        -- the population first brings back what it kept of the group (a world saved with it about): counted a look later
        if not ready[m.id] then
            ready[m.id] = true
            return
        end
        -- the visit's group is brought once; short of it (every open square within ZOMBIE_AWAY of the player, as when
        -- they stand in a small yard), the rest is tried again each look while they are about
        local missing = Zombies.wanted(m, now) - g.countMarked(m.id)
        local made = missing > 0 and g.spawnZombies(m.area, m.zombies.outfit, m.id, missing, px, py) or 0
        here[m.id] = made >= missing or nil
        if made > 0 then OA.log("mission", m.id, "brought", tostring(made), "of", missing, m.zombies.outfit) end
    elseif d > m.area.r + Data.ZOMBIE_NEAR + Data.ZOMBIE_LEAVE then
        here[m.id], ready[m.id] = nil, nil
    end
end

-- The mission ended or was sealed (Game.release): its group is let go and what is left of it goes.
function Zombies.release(m)
    if not m.zombies then return end
    held[m.id], ready[m.id], here[m.id] = nil, nil, nil
    local g = game()
    if g and g.releaseZombies then g.releaseZombies(m) end
end

-- Forgets what the session did (tests, a new world).
function Zombies.reset()
    held, ready, here = {}, {}, {}
end

return Zombies
