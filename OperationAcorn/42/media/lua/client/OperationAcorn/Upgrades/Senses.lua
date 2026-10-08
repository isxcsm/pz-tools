-- The scout tree's senses, drawn: 육감 (a moodle-like widget when zombies are near), 기척 감지 (a ring of faint marks
-- around the character, by direction and, at rank 2, by distance), 경보 읽기 (a mark over alarmed houses and cars
-- nearby) and 털이 기록 (how many containers of the building are still unopened). The work is done twice a second
-- by the shared timer (Pulse.lua), from the game's loaded zombie list; the drawing only reads what that left.
require "ISUI/ISPanel"
-- ISCoordConversion is a server-folder file, loaded after this one: it is used when drawing, not required here.
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Pulse"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Sense = OA.Upgrades.Sense
local Pulse = OA.Upgrades.Pulse
local Senses = {}
OA.Upgrades.Senses = Senses

-- What the last pulse found.
local S = {
    dirs = {}, radius = 0, distance = false, thumpSeen = false, extended = false,
    sixth = false, alarms = {}, sounds = {}, ring = false,
}
Senses.state = S

local ALARM_RANGE = 30
local ALARM_NEAR = 4
local announced = {}

-- ---- the HUD ---------------------------------------------------------------------------------------------------

local Hud = ISPanel:derive("ISOASenseHud")
ISOASenseHud = Hud

function Hud:new(playerNum)
    local o = ISPanel.new(self, getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum),
        getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum))
    o.playerNum = playerNum
    o.background = false
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.moveWithMouse = false
    return o
end

function Hud:prerender() end

local function moodleIcon(size)
    return getTexture("media/ui/Moodles/48/Mood_Scared.png"), getTexture("media/ui/Moodles/48/_Moodles_BGoutline.png")
end

function Hud:render()
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local cx, cy = self.width / 2, self.height / 2
    if S.ring then
        local ringR = fh * 5
        local mark = math.max(4, math.floor(fh * 0.6))
        for sector, e in pairs(S.dirs) do
            local ux, uy = Sense.direction(sector)
            local r, a = ringR, 0.55
            if S.distance and S.radius > 0 then
                local t = math.min(1, e.d / S.radius)
                r = ringR * (0.6 + 0.5 * t)
                a = 0.9 - 0.55 * t
            end
            local size = e.n > 3 and mark + 3 or mark
            local x, y = cx + ux * r, cy + uy * r * 0.6
            if e.thump then
                self:drawRect(x - size / 2, y - size / 2, size, size, a, 1.0, 0.6, 0.2)
            else
                self:drawRect(x - size / 2, y - size / 2, size, size, a, 0.75, 0.9, 1.0)
            end
        end
        local now = getTimestampMs()
        for _, sound in ipairs(S.sounds) do
            if sound.untilMs > now then
                local ux, uy = Sense.direction(sound.sector)
                local r = ringR * 1.35
                local size = mark + 2
                local x, y = cx + ux * r, cy + uy * r * 0.6
                if sound.kind == "alarm" then
                    self:drawRect(x - size / 2, y - size / 2, size, size, 0.8, 1.0, 0.3, 0.3)
                else
                    self:drawRect(x - size / 2, y - size / 2, size, size, 0.8, 1.0, 0.9, 0.3)
                end
            end
        end
    end
    if #S.alarms > 0 then
        local zoom = getCore():getZoom(self.playerNum)
        for _, spot in ipairs(S.alarms) do
            local sx, sy = ISCoordConversion.ToScreen(spot.x, spot.y, spot.z)
            sx, sy = sx / zoom - self.x, sy / zoom - self.y
            if sx > 0 and sy > 0 and sx < self.width and sy < self.height then
                local w = getTextManager():MeasureStringX(UIFont.Small, "!") + 8
                self:drawRect(sx - w / 2, sy - fh - 6, w, fh + 2, 0.7, 0.6, 0.05, 0.05)
                self:drawRectBorder(sx - w / 2, sy - fh - 6, w, fh + 2, 0.9, 1, 0.5, 0.5)
                self:drawTextCentre("!", sx, sy - fh - 5, 1, 1, 1, 1, UIFont.Small)
            end
        end
    end
    if S.sixth then
        local icon, back = moodleIcon()
        local moodle = UIManager.getMoodleUI(self.playerNum)
        local size = math.floor(fh * 3.2)
        local x, y = self.width - size - 8, fh * 8
        if moodle then
            x = moodle:getX() - self.x - size - 6
            y = moodle:getY() - self.y
        end
        if back then self:drawTextureScaled(back, x, y, size, size, 0.9, 0.9, 0.5, 0.5) end
        if icon then self:drawTextureScaled(icon, x, y, size, size, 1, 1, 0.6, 0.6) end
    end
end

local hud = nil

local function showHud(on)
    if on and not hud then
        hud = Hud:new(0)
        hud:initialise()
        hud:instantiate()
        hud.javaObject:setConsumeMouseEvents(false)
        hud:addToUIManager()
    end
    if hud then
        hud:setVisible(on)
        if on then
            hud:setX(getPlayerScreenLeft(0))
            hud:setY(getPlayerScreenTop(0))
            hud:setWidth(getPlayerScreenWidth(0))
            hud:setHeight(getPlayerScreenHeight(0))
        end
    end
end

-- ---- the 0.5 second pulse: zombies ------------------------------------------------------------------------------

local function section(player)
    local record = OA.Client.record(player)
    return record and Rules.section(record) or nil
end

local function plain(z)
    return { x = z:getX(), y = z:getY(), z = z:getZ(), thump = z:getThumpTimer() > 0 }
end

-- The zombies near the character from the extension API's spatial query (PZToolsAPI.zombies.near), when it has one;
-- nil when it has not, or when the answer is not a list of zombies (then the scan below does it).
local function collectFromApi(player, radius)
    local api = OA.api()
    local zombies = api and api.zombies
    if type(zombies) ~= "table" or type(zombies.near) ~= "function" then return nil end
    local ok, found = pcall(function()
        local result = zombies.near(player:getX(), player:getY(), player:getZ(), radius)
        local list = {}
        if type(result) ~= "table" and type(result) ~= "userdata" then return nil end
        if type(result) == "table" then
            for _, z in ipairs(result) do
                if instanceof(z, "IsoZombie") and not z:isDead() then list[#list + 1] = plain(z) end
            end
        else
            for i = 0, result:size() - 1 do
                local z = result:get(i)
                if instanceof(z, "IsoZombie") and not z:isDead() then list[#list + 1] = plain(z) end
            end
        end
        return list
    end)
    if ok then return found end
    return nil
end

-- The loaded zombies near (px, py) as plain positions, for the pure scanners.
local function collect(player, radius)
    local fromApi = collectFromApi(player, radius)
    if fromApi then return fromApi end
    local list = {}
    local zs = getCell():getZombieList()
    local px, py = player:getX(), player:getY()
    for i = 0, zs:size() - 1 do
        local z = zs:get(i)
        local zx, zy = z:getX(), z:getY()
        if zx - px <= radius and px - zx <= radius and zy - py <= radius and py - zy <= radius and not z:isDead() then
            list[#list + 1] = plain(z)
        end
    end
    return list
end

local function senseJob(now)
    local player = getPlayer()
    if not player or player:isDead() then S.ring, S.sixth = false, false showHud(false) return end
    local u = section(player)
    if not u then return end
    local sixthR = Rules.sixthRadius(u)
    local senseR = Rules.senseRadius(u)
    local active = senseR > 0 and Sense.active(u, player:isSneaking(), player:isRunning(), player:isSprinting())
    S.ring = active
    S.sixth = false
    if sixthR <= 0 and not active then
        S.dirs = {}
        showHud(#S.alarms > 0)
        return
    end
    local extended = Sense.extended(u)
    local list = collect(player, math.max(sixthR, senseR))
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    if sixthR > 0 then S.sixth = Sense.hunch(list, px, py, pz, sixthR) end
    if active then
        S.radius = senseR
        S.distance = Sense.distance(u)
        S.extended = extended
        S.dirs = Sense.scan(list, px, py, pz, senseR, extended)
        if not extended then
            for _, e in pairs(S.dirs) do e.thump = false end
        end
    else
        S.dirs = {}
    end
    showHud(S.ring or S.sixth or #S.alarms > 0)
end

-- ---- world sounds (advanced presence sense, rank 2) --------------------------------------------------------------

local function onWorldSound(x, y, z, radius, volume, source)
    if not S.ring or not S.extended then return end
    local player = getPlayer()
    if not player then return end
    local kind
    if instanceof(source, "BaseVehicle") then
        kind = "vehicle"
    elseif radius >= 40 and not instanceof(source, "IsoZombie") and not instanceof(source, "IsoPlayer") then
        kind = "alarm"
    else
        return
    end
    local dx, dy = x - player:getX(), y - player:getY()
    if dx * dx + dy * dy > S.radius * S.radius * 2.25 then return end
    local now = getTimestampMs()
    local list = {}
    for _, s in ipairs(S.sounds) do
        if s.untilMs > now then list[#list + 1] = s end
    end
    if #list >= 8 then table.remove(list, 1) end
    list[#list + 1] = { sector = Sense.sector(dx, dy), kind = kind, untilMs = now + 4000 }
    S.sounds = list
end

-- ---- alarms (once a second) --------------------------------------------------------------------------------------

local buildingList = nil

local vehicleList
local function alarmJob(now)
    local player = getPlayer()
    if not player or player:isDead() then return end
    local u = section(player)
    if not u or Rules.rank(u, "alarm") < 1 then
        if #S.alarms > 0 then S.alarms = {} end
        return
    end
    local spots = {}
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    vehicleList = OA.vehicles(vehicleList)
    local vehicles = vehicleList
    for i = 0, vehicles:size() - 1 do
        local v = vehicles:get(i)
        if v:isAlarmed() then
            local dx, dy = v:getX() - px, v:getY() - py
            local d2 = dx * dx + dy * dy
            if d2 <= ALARM_RANGE * ALARM_RANGE then
                spots[#spots + 1] = { x = v:getX(), y = v:getY(), z = v:getZ(), d2 = d2, key = "v" .. tostring(v:getId()), car = true }
            end
        end
    end
    buildingList = buildingList or ArrayList.new()
    buildingList:clear()
    getWorld():getMetaGrid():getBuildingsIntersecting(math.floor(px - ALARM_RANGE), math.floor(py - ALARM_RANGE),
        ALARM_RANGE * 2, ALARM_RANGE * 2, buildingList)
    for i = 0, buildingList:size() - 1 do
        local def = buildingList:get(i)
        if def:isAlarmed() then
            local x, y = def:getX() + def:getW() / 2, def:getY() + def:getH() / 2
            local dx, dy = x - px, y - py
            spots[#spots + 1] = { x = x, y = y, z = 0, d2 = dx * dx + dy * dy, key = "b" .. tostring(def:getID()) }
        end
    end
    table.sort(spots, function(a, b) return a.d2 < b.d2 end)
    while #spots > 6 do table.remove(spots) end
    S.alarms = spots
    -- told once when it is close, before the player touches anything
    for _, spot in ipairs(spots) do
        if spot.d2 <= ALARM_NEAR * ALARM_NEAR and not announced[spot.key] then
            announced[spot.key] = true
            HaloTextHelper.addBadText(player, getText(spot.car and "IGUI_OA_Tree_AlarmCar" or "IGUI_OA_Tree_AlarmHouse"))
        end
    end
    showHud(S.ring or S.sixth or #S.alarms > 0)
end

-- ---- the building's containers (털이 기록) ----------------------------------------------------------------------

local ledger = { key = nil, nextCount = 0, total = 0, opened = 0, done = false, complete = false }
Senses.ledger = ledger

-- Counts a building's containers: total, opened, and whether every room was loaded (so that it can be judged).
local function countBuilding(def)
    local total, opened, complete = 0, 0, true
    local rooms = def:getRooms()
    for i = 0, rooms:size() - 1 do
        local iso = rooms:get(i):getIsoRoom()
        if not iso then
            complete = false
        else
            local containers = iso:getContainer()
            for j = 0, containers:size() - 1 do
                local c = containers:get(j)
                if c:getType() ~= "floor" then
                    total = total + 1
                    if c:isExplored() then opened = opened + 1 end
                end
            end
        end
    end
    return total, opened, complete
end

local function ledgerJob(now)
    local player = getPlayer()
    if not player or player:isDead() then return end
    local record = OA.Client.record(player)
    if not record then return end
    local u = Rules.section(record)
    local rank = Rules.rank(u, "ledger")
    if rank < 1 then ledger.key = nil return end
    local def = player:getCurrentBuildingDef()
    if not def then ledger.key = nil return end
    local key = def:getID()
    local entering = key ~= ledger.key
    if not entering and (rank < 2 or ledger.done or now < ledger.nextCount) then return end
    ledger.nextCount = now + 5000
    local total, opened, complete = countBuilding(def)
    -- the economy part keeps its own count of the building (it leaves out what the player placed): use it when it has one
    if OA.Codex and OA.Codex.buildingProgress and OA.Buildings and OA.Buildings.keyAt then
        local ok, searched, all = pcall(function()
            local square = player:getCurrentSquare()
            local buildingKey = square and OA.Buildings.keyAt(square)
            if not buildingKey then return nil, nil end
            return OA.Codex.buildingProgress(record, buildingKey)
        end)
        if ok and type(searched) == "number" and type(all) == "number" then
            total, opened = all, searched
        end
    end
    ledger.total, ledger.opened, ledger.complete = total, opened, complete
    local left = total - opened
    if entering then
        ledger.key = key
        ledger.done = false
        if complete and total > 0 and left == 0 then
            ledger.done = true
            if rank >= 3 then HaloTextHelper.addGoodText(player, getText("IGUI_OA_Tree_LedgerAlreadyDone")) end
        elseif rank >= 1 then
            HaloTextHelper.addText(player, getText("IGUI_OA_Tree_LedgerLeft", left))
        end
    elseif complete and total > 0 and left == 0 then
        ledger.done = true
        HaloTextHelper.addGoodText(player, getText("IGUI_OA_Tree_LedgerDone"))
    end
end

-- ---- starting --------------------------------------------------------------------------------------------------

local soundHooked = false

-- Sets the sound hook by what the character has (called when ranks change); returns whether the shared timer is
-- needed for the senses.
function Senses.refresh()
    local player = getPlayer()
    local u = player and section(player)
    if not u then return false end
    local need = Rules.rank(u, "sixth") > 0 or Rules.rank(u, "sense") > 0 or Rules.rank(u, "alarm") > 0
        or Rules.rank(u, "ledger") > 0
    local wantSound = Sense.extended(u)
    if wantSound and not soundHooked then
        soundHooked = true
        Events.OnWorldSound.Add(onWorldSound)
    elseif not wantSound and soundHooked then
        soundHooked = false
        Events.OnWorldSound.Remove(onWorldSound)
    end
    if not need then
        S.ring, S.sixth, S.alarms, S.dirs = false, false, {}, {}
        showHud(false)
    end
    return need
end

Pulse.job("senses", 500, senseJob)
Pulse.job("alarms", 1000, alarmJob)
Pulse.job("ledger", 1000, ledgerJob)

return Senses
