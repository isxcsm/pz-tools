-- 돌파 질주 (the survival capstone): while sprinting, a zombie in the way is thrown down, at the cost of endurance.
-- It is always on, no button. Nothing runs on every tick: the shared timer notices a sprint start every quarter
-- second, and only while the character sprints a handler looks at the two squares ahead, ten times a second.
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Pulse"
require "OperationAcorn/Upgrades/First"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Pulse = OA.Upgrades.Pulse
local First = OA.Upgrades.First
local Dash = {}
OA.Upgrades.Dash = Dash

-- Endurance one zombie costs at fitness 0 (the endurance bar runs 0 to 1), and the share each fitness level takes off.
Dash.COST = 0.05
Dash.FITNESS_SHARE = 0.05
-- Hit check interval while sprinting, and how long a zombie thrown is left alone (ms).
Dash.INTERVAL = 100
Dash.COOLDOWN = 2000
-- How far ahead (tiles) the two squares are looked at.
Dash.REACH = { 0.9, 1.8 }

local attached = false
local nextHit = 0

-- The endurance one zombie costs this character.
function Dash.cost(player, u)
    local fitness = player:getPerkLevel(Perks.Fitness)
    return Dash.COST * math.max(0.25, 1 - Dash.FITNESS_SHARE * fitness) * Rules.dashCost(u)
end

-- The zombies in the way: on the two squares ahead, upright, not behind a wall. The list is kept between looks (ten a
-- second while sprinting): it is the answer of the last one.
local found = {}
local function ahead(player)
    for i = #found, 1, -1 do found[i] = nil end
    local cell = getCell()
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local fx, fy = player:getForwardDirectionX(), player:getForwardDirectionY()
    local from = player:getCurrentSquare()
    if not from then return found end
    local previous = from
    for _, reach in ipairs(Dash.REACH) do
        local sq = cell:getGridSquare(math.floor(px + fx * reach), math.floor(py + fy * reach), pz)
        if sq and sq ~= previous then
            if previous:isBlockedTo(sq) then break end
            local objects = sq:getMovingObjects()
            for i = 0, objects:size() - 1 do
                local o = objects:get(i)
                if instanceof(o, "IsoZombie") and not o:isDead() and not o:isOnFloor() and not o:isKnockedDown()
                    and not o:isCrawling() then
                    found[#found + 1] = o
                end
            end
            previous = sq
        end
    end
    return found
end

local function onPlayerUpdate(player)
    if player ~= getPlayer() then return end
    local now = getTimestampMs()
    if now < nextHit then return end
    nextHit = now + Dash.INTERVAL
    if not player:isSprinting() or player:getVehicle() then return end
    local record = OA.Client.record(player)
    if not record then return end
    local u = Rules.section(record)
    if Rules.rank(u, "dash") < 1 then return end
    local stats = player:getStats()
    for _, zombie in ipairs(ahead(player)) do
        local data = zombie:getModData()
        if not data.OA_Dash or now - data.OA_Dash > Dash.COOLDOWN then
            local cost = Dash.cost(player, u)
            -- too tired: it does not throw them, and they hit like any other
            if stats:get(CharacterStat.ENDURANCE) < cost then return end
            stats:remove(CharacterStat.ENDURANCE, cost)
            data.OA_Dash = now
            zombie:knockDown(false)
            First.report("dash", player)
        end
    end
end

-- Attach the handler while the character sprints, detach when it stops.
local function setAttached(on)
    if on and not attached then
        attached = true
        Events.OnPlayerUpdate.Add(onPlayerUpdate)
    elseif not on and attached then
        attached = false
        Events.OnPlayerUpdate.Remove(onPlayerUpdate)
    end
end

local function job(now)
    local player = getPlayer()
    if not player or player:isDead() then setAttached(false) return end
    local record = OA.Client.record(player)
    if not record or Rules.rank(Rules.section(record), "dash") < 1 then setAttached(false) return end
    setAttached(player:isSprinting() and not player:getVehicle())
end

function Dash.needs(u)
    return Rules.rank(u, "dash") > 0
end

Pulse.job("dash", 250, job)

return Dash
