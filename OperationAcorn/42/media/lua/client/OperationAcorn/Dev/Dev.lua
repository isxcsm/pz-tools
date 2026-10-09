-- Debug only: helpers for checking each part in a running game (single player), meant to be called through the
-- command channel (Dev/Remote.lua, tools/pzdev.py) or the Lua console. They change the save: use a test save.
-- Each prints what it did as "[dev] ..." lines and returns something a check can test.
if not isDebugEnabled() then return end
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Dev = {}
OA.Dev = Dev

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[dev] " .. table.concat(parts, " "))
end
Dev.say = say

-- ---- the character and its record ------------------------------------------------------------------------------

function Dev.player()
    return getPlayer()
end

-- The local character's record (made by the mod's first hello), or nil.
function Dev.record()
    local player = getPlayer()
    local id = player and player:getModData().OA_Id
    return id and OA.Store.player(id) or nil
end

-- Tells the screens and the effects a section of the record changed.
function Dev.changed(section)
    local record = Dev.record()
    if record then OA.Sync.changed(section or "all", record.id) end
end

-- ---- research --------------------------------------------------------------------------------------------------

local function upgrades()
    local record = Dev.record()
    if not record then error("no record yet", 3) end
    return OA.Upgrades.Rules.section(record), record
end

-- Sets research ranks as given ({ night = 3, nightEye = 1, bSense = 4 }; 0 takes a node away). The trees of the
-- ranks open; nothing is paid. Applies the effects at once.
function Dev.ranks(list)
    local u, record = upgrades()
    local Data = OA.Upgrades.Data
    for id, rank in pairs(list) do
        local node = Data.byId[id]
        if not node then error("no node " .. tostring(id), 2) end
        local value = rank > 0 and rank or nil
        if node.board then
            u.board.ranks[id] = value
        else
            u.ranks[id] = value
            u.opened[node.tree] = true
        end
    end
    OA.Sync.changed("upgrades", record.id)
    if OA.Upgrades.Effects then OA.Upgrades.Effects.apply(record) end
    say("ranks", Dev.describe(list))
    return u
end

-- Takes every rank away and empties the points (a fresh research record).
function Dev.clearResearch()
    local u, record = upgrades()
    for k in pairs(u) do u[k] = nil end
    OA.Upgrades.Rules.fill(u)
    OA.Sync.changed("upgrades", record.id)
    if OA.Upgrades.Effects then OA.Upgrades.Effects.apply(record) end
    say("research cleared")
    return u
end

-- Gives points of a tree ("scout", "load", "survival"; "shared" for shared serums) as if that many were injected.
function Dev.points(tree, n)
    local u, record = upgrades()
    local Rules = OA.Upgrades.Rules
    for _ = 1, n do
        if tree == "shared" then Rules.injectShared(u) else Rules.inject(u, tree) end
    end
    OA.Sync.changed("upgrades", record.id)
    say("points", tree, n)
    return u
end

-- ---- trade -----------------------------------------------------------------------------------------------------

function Dev.credits(n)
    local record = Dev.record()
    OA.Store.section(record, "trade").credits = n
    OA.Sync.changed("trade", record.id)
    say("credits", n)
end

-- Sets trust to an amount, with the stage and milestones it makes (the rewards of passing them are not given).
function Dev.trust(amount)
    local record = Dev.record()
    local trade = OA.Store.section(record, "trade")
    trade.trust = amount
    trade.stage, trade.milestones = OA.Trust.levelFor(amount)
    OA.Sync.changed("trade", record.id)
    say("trust", amount, "stage", trade.stage, "milestones", trade.milestones)
end

-- ---- the world -------------------------------------------------------------------------------------------------

-- The hour of the day (0..24), at once.
function Dev.time(hour)
    getGameTime():setTimeOfDay(hour)
    say("time", hour)
end

-- The game speed: 1 normal, 2..4 the fast-forward steps (the speed buttons), 0 paused.
function Dev.speed(n)
    UIManager.getSpeedControls():SetCurrentGameSpeed(n)
    say("speed", n)
end

-- Stops rain, snow and thunder.
function Dev.clearWeather()
    getClimateManager():stopWeatherAndThunder()
    say("weather cleared")
end

local DIRS = { N = "N", NE = "NE", E = "E", SE = "SE", S = "S", SW = "SW", W = "W", NW = "NW" }

-- Turns the character to face a compass way ("N", "SE" ...: the map's north is up and to the right on screen).
function Dev.face(dir)
    local player = getPlayer()
    local d = IsoDirections[DIRS[dir] or "S"]
    player:setDir(d)
    if player.setForwardDirection then player:setForwardDirection(d:ToVector()) end
    say("face", dir)
end

-- Zombies at offsets from the character, made harmless and still (useless): { { dx, dy, n }, ... }, dz optional as a
-- fourth number. Returns how many.
function Dev.zombies(spots)
    local player = getPlayer()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local made = 0
    for _, s in ipairs(spots) do
        local list = addZombiesInOutfit(px + s[1], py + s[2], pz + (s[4] or 0), s[3] or 1, "Generic01", 50)
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            z:setUseless(true)
            made = made + 1
        end
    end
    say("zombies", made)
    return made
end

-- Removes the zombies within a radius of the character (all loaded ones without a radius). Returns how many.
function Dev.clearZombies(radius)
    local player = getPlayer()
    local list = getCell():getZombieList()
    local gone = 0
    for i = list:size() - 1, 0, -1 do
        local z = list:get(i)
        if not radius or IsoUtils.DistanceTo(z:getX(), z:getY(), player:getX(), player:getY()) <= radius then
            z:removeFromWorld()
            z:removeFromSquare()
            gone = gone + 1
        end
    end
    say("zombies removed", gone)
    return gone
end

-- A world sound at an offset from the character (what zombies and the presence marks hear).
function Dev.sound(dx, dy, radius, volume)
    local player = getPlayer()
    local x, y, z = math.floor(player:getX()) + dx, math.floor(player:getY()) + dy, math.floor(player:getZ())
    addSound(nil, x, y, z, radius or 30, volume or 30)
    say("sound at", dx, dy)
end

-- ---- screens ---------------------------------------------------------------------------------------------------

-- Shows or hides the game's Lua console (the channel needs none; a picture should not have it).
function Dev.console(show)
    local console = UIManager.getDebugConsole()
    if console then console:setVisible(show == true) end
end

-- Closes the character info window (where the research tab is) and the Lua console.
function Dev.closeWindows()
    local info = getPlayerInfoPanel(0)
    if info and info:getIsVisible() then info:close() end
    Dev.console(false)
    say("windows closed")
end

-- A short state line: time, speed, weather, the character's place and facing, zombies near.
function Dev.state()
    local player = getPlayer()
    local near = 0
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if IsoUtils.DistanceTo(z:getX(), z:getY(), player:getX(), player:getY()) <= 30 then near = near + 1 end
    end
    say("time", string.format("%.2f", getGameTime():getTimeOfDay()), "speed", getGameTime():getTrueMultiplier(),
        "daylight", string.format("%.2f", getClimateManager():getDayLightStrength()),
        "at", math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()),
        "facing", tostring(player:getDir()), "zombies within 30", near)
end

function Dev.describe(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(parts)
    return table.concat(parts, " ")
end

return Dev
