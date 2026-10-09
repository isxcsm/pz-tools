-- The scout tree's senses, drawn: 육감 (a moodle-like widget when zombies are near), 기척 감지 (glowing arcs on the
-- ground around the character, by direction and, at rank 2, by distance; the advanced rank 2 adds the noises around,
-- each with a sign of what made it, as the Visual Sounds mod shows them), 경보 읽기 (a mark over alarmed houses and cars
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
    dirs = {}, radius = 0, distance = false, thumpSeen = false, extended = false, hearing = 1,
    sixth = false, sixthDrawn = false, alarms = {}, sounds = {}, ring = false,
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

-- ---- the sixth sense's moodle ----------------------------------------------------------------------------------

-- A moodle of the game's own column, through the extension API (PZToolsAPI.moodles): the game draws it, places it,
-- wiggles it and shows its tooltip (Translate/<lang>/Moodles.json). In a game without the API's moodle hooks the HUD
-- draws a stand-in beside the column instead (drawStandIn).
local MOODLE = "sixth"
local MOODLE_PICTURE = "media/textures/OA_Moodle_Sixth_{size}.png"
local MOODLE_SIZES = { 32, 48, 64, 80, 96, 128 }
local moodle = { state = nil, level = 0 }   -- state: nil until decided, "api" or "draw"

-- Whether the hooks the API's moodles need went in: true, false, or nil while their classes have not loaded.
local function moodleHooks(api)
    local ok, hooks = pcall(api.hooks)
    if not ok or type(hooks) ~= "table" then return false end
    local level, picture = hooks["Moodle.Update:level"], hooks["MoodlesUI.render"]
    if level == "applied" and picture == "applied" then return true end
    if level == "not-loaded" or picture == "not-loaded" then return nil end
    return false
end

-- Shows or hides the sixth sense's moodle. Returns whether the game's column shows it (else the HUD draws it).
local function setSixth(on)
    if moodle.state == nil then
        local api, handle = OA.api(), OA.handle()
        if not (api and handle and type(api.moodles) == "table") then
            moodle.state = "draw"
        else
            local hooked = moodleHooks(api)
            if hooked == nil then return false end
            moodle.state = "draw"
            if hooked then
                local ok, err = pcall(api.moodles.define, handle, MOODLE, { kind = "neutral", picture = MOODLE_PICTURE })
                if ok then moodle.state = "api" else OA.log("sixth sense moodle:", tostring(err)) end
            end
        end
    end
    if moodle.state ~= "api" then return false end
    local level = on and 1 or 0
    if level ~= moodle.level then
        local ok, err = pcall(PZToolsAPI.moodles.set, OA.handle(), MOODLE, level)
        if ok then moodle.level = level else OA.log("sixth sense moodle:", tostring(err)) end
    end
    return true
end

-- The stand-in: the moodle's picture on the game's moodle background, at the moodle size option, left of the
-- game's column, with the moodle's name and text when the mouse is over it.
local function drawStandIn(self)
    local option = getCore():getOptionMoodleSize()
    local size = MOODLE_SIZES[option] or ((getCore():getScreenHeight() > 1200) and 64 or 48)
    local column = UIManager.getMoodleUI(self.playerNum)
    local x, y = self.width - size - 8, size * 2
    if column then
        x = column:getX() - self.x - size - 6
        y = column:getY() - self.y
    end
    local back = getTexture("media/ui/Moodles/" .. size .. "/_Moodles_BGsolid.png")
    local icon = getTexture(string.gsub(MOODLE_PICTURE, "{size}", tostring(size)))
    if back then self:drawTextureScaled(back, x, y, size, size, 0.9, 0.42, 0.42, 0.42) end
    if icon then self:drawTextureScaled(icon, x, y, size, size, 1, 1, 1, 1) end
    local mx, my = getMouseX() - self.x, getMouseY() - self.y
    if mx >= x and mx < x + size and my >= y and my < y + size then
        local name = getText("Moodles_" .. OA.MOD .. ":" .. MOODLE .. "_lvl1")
        local text = getText("Moodles_" .. OA.MOD .. ":" .. MOODLE .. "_desc_lvl1")
        local tm = getTextManager()
        local w = math.max(tm:MeasureStringX(UIFont.Small, name), tm:MeasureStringX(UIFont.Small, text)) + 16
        local fh = tm:getFontHeight(UIFont.Small)
        local tx = x - w - 6
        self:drawRect(tx, y, w, fh * 2 + 12, 0.75, 0, 0, 0)
        self:drawText(name, tx + 8, y + 4, 1, 1, 1, 1, UIFont.Small)
        self:drawText(text, tx + 8, y + 6 + fh, 0.8, 0.8, 0.8, 1, UIFont.Small)
    end
end

-- The presence marks: glowing arcs round the character (an ellipse of RING tiles laid as the ground lies, so it follows
-- the zoom and the view's slant), each turned to face its way. The ellipse is centred on the body's middle, BODY of a
-- floor above the feet, where the camera centres the character (as Visual Sounds centres on the screen): round the
-- feet it all hung low. Nearer is bigger, warmer and brighter; one arc for a
-- lone zombie, two for a few, three for a crowd; rings for zombies beating on something and a chevron for another
-- floor (rank 2), drawn upright on the mark itself as Visual Sounds draws its arrows. A noise heard (rank 2) is a
-- thin arc on a wider ring, its kind in its pattern as Visual Sounds draws them (plain, a wheel for a vehicle, dots for
-- a radio, TV or generator, spikes for an alarm), in one white (colour belongs to the zombies' arcs) but for alarms:
-- those draw every zombie around, so they are a deep red at full strength, as Visual Sounds marks them. The pictures
-- are white, tinted as they are drawn.
local RING = 1.7
local BODY = 0.3
local SOUND_RING = 2.6
local SOUND_MS = 2500
local SOUND_MAX = 8
local NEAR = { 1.00, 0.36, 0.24 }
local MID = { 1.00, 0.72, 0.28 }
local FAR = { 0.80, 0.88, 1.00 }
local THUMP = { 1.00, 0.58, 0.18 }
local NOISE_TINT = { 0.95, 0.95, 0.90 }
local ALARM_TINT = { 0.95, 0.08, 0.06 }
local NOISE_PICTURE = { vehicle = "OA_Sense_Car", alarm = "OA_Sense_Alarm", device = "OA_Sense_Dots", noise = "OA_Sense_Noise" }
local pictures = {}
local function picture(name)
    local t = pictures[name]
    if t == nil then
        t = getTexture("media/textures/" .. name .. ".png") or false
        pictures[name] = t
    end
    return t or nil
end

-- Draws a picture centred at (x, y), turned so that its top faces the screen direction (dx, dy), over a dark copy a
-- pixel lower and right so that a pale mark still reads on a pale floor.
local function turned(self, tex, x, y, dx, dy, c, a)
    if not tex then return end
    local angle = math.deg(math.atan2(dy, dx)) + 90
    local ui = self.javaObject
    ui:DrawTextureAngle(tex, x + 1, y + 1, angle, 0, 0, 0, a * 0.55)
    ui:DrawTextureAngle(tex, x, y, angle, c[1], c[2], c[3], a)
end

-- The screen offset of a sector's mark on the ground ellipse of `tiles`, from the screen offsets of one tile east
-- (exX, exY) and south (eyX, eyY). The sector's direction is in the slanted screen space of Sense.sector; it is
-- turned back into the world to put it at the same distance in every direction.
local function onGround(sector, tiles, exX, exY, eyX, eyY)
    local ux, uy = Sense.direction(sector)
    local wx, wy = uy + ux / 2, uy - ux / 2
    local len = math.sqrt(wx * wx + wy * wy)
    wx, wy = wx / len * tiles, wy / len * tiles
    return wx * exX + wy * eyX, wx * exY + wy * eyY
end

function Hud:render()
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local player = getSpecificPlayer(self.playerNum)
    if S.ring and player then
        local n, px, py, pz = self.playerNum, player:getX(), player:getY(), player:getZ()
        local ox, oy = isoToScreenX(n, px, py, pz), isoToScreenY(n, px, py, pz)
        local exX, exY = isoToScreenX(n, px + 1, py, pz) - ox, isoToScreenY(n, px + 1, py, pz) - oy
        local eyX, eyY = isoToScreenX(n, px, py + 1, pz) - ox, isoToScreenY(n, px, py + 1, pz) - oy
        local cx, cy = ox - self.x, isoToScreenY(n, px, py, pz + BODY) - self.y
        for sector, e in pairs(S.dirs) do
            local gx, gy = onGround(sector, RING, exX, exY, eyX, eyY)
            local len = math.sqrt(gx * gx + gy * gy)
            local ux, uy = gx / len, gy / len
            local tex, c, a = picture("OA_Sense_Arc_M"), FAR, 0.8
            if S.distance and S.radius > 0 then
                local t = math.min(1, e.d / S.radius)
                if t < 0.34 then
                    tex, c = picture("OA_Sense_Arc_L"), NEAR
                elseif t < 0.67 then
                    tex, c = picture("OA_Sense_Arc_M"), MID
                else
                    tex, c = picture("OA_Sense_Arc_S"), FAR
                end
                a = 1.0 - 0.45 * t
            end
            local arcs = (e.n >= 4) and 3 or ((e.n >= 2) and 2 or 1)
            local step = tex and tex:getHeight() * 0.55 or 6
            for k = 0, arcs - 1 do
                turned(self, tex, cx + gx + ux * step * k, cy + gy + uy * step * k, ux, uy, c, a * (1 - 0.25 * k))
            end
            if e.thump then
                turned(self, picture("OA_Sense_Thump"), cx + gx - ux * step * 1.4, cy + gy - uy * step * 1.4, 0, -1, THUMP, 0.95)
            end
            if e.up or e.down then
                -- white on the coloured arc (in the arc's colour it melted into it)
                turned(self, picture(e.up and "OA_Sense_Up" or "OA_Sense_Down"), cx + gx, cy + gy, 0, -1, NOISE_TINT, 1)
            end
        end
        local now = getTimestampMs()
        local reach = S.radius > 0 and S.radius or 1
        for _, sound in ipairs(S.sounds) do
            if sound.untilMs > now then
                local dx, dy = sound.x - px, sound.y - py
                local d = math.max(0.01, math.sqrt(dx * dx + dy * dy))
                -- its own direction (not the zombies' sectors), on the ground ellipse
                local wx, wy = dx / d * SOUND_RING, dy / d * SOUND_RING
                local gx, gy = wx * exX + wy * eyX, wx * exY + wy * eyY
                local len = math.max(0.01, math.sqrt(gx * gx + gy * gy))
                local ux, uy = gx / len, gy / len
                local alarm = sound.kind == "alarm"
                local tint = alarm and ALARM_TINT or NOISE_TINT
                local a = alarm and 1 or (S.distance and (1.0 - 0.45 * math.min(1, d / (reach * 2))) or 0.9)
                local x, y = cx + gx, cy + gy
                turned(self, picture(NOISE_PICTURE[sound.kind]), x, y, ux, uy, tint, a)
                if alarm then
                    -- drawn twice: one red pass is thin on a pale floor
                    turned(self, picture(NOISE_PICTURE[sound.kind]), x, y, ux, uy, tint, a)
                end
                if math.abs(sound.z - pz) >= 0.5 then
                    turned(self, picture(sound.z > pz and "OA_Sense_Up" or "OA_Sense_Down"), x, y, 0, -1, NOISE_TINT, 1)
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
    if S.sixthDrawn then drawStandIn(self) end
end

local hud = nil

local function showHud(on)
    if on and not hud then
        hud = Hud:new(0)
        hud:initialise()
        hud:instantiate()
        hud.javaObject:setConsumeMouseEvents(false)
        hud:addToUIManager()
        -- marks on the world: under every window and the game's own HUD
        hud:backMost()
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

-- The sixth sense shown as S.sixth says: the game's moodle, or the HUD's stand-in (S.sixthDrawn). Nothing is defined
-- for a character that never had it on.
local function updateSixth()
    if S.sixth or moodle.level > 0 then
        S.sixthDrawn = S.sixth and not setSixth(S.sixth)
    else
        S.sixthDrawn = false
    end
end

local function senseJob(now)
    local player = getPlayer()
    if not player or player:isDead() then
        S.ring, S.sixth = false, false
        updateSixth()
        showHud(false)
        return
    end
    local u = section(player)
    if not u then return end
    local sixthR = Rules.sixthRadius(u)
    local senseR = Rules.senseRadius(u)
    local active = senseR > 0 and Sense.active(u, player:isSneaking(), player:isRunning(), player:isSprinting())
    S.ring = active
    S.sixth = false
    if sixthR <= 0 and not active then
        S.dirs = {}
        updateSixth()
        showHud(#S.alarms > 0)
        return
    end
    local extended = Sense.extended(u)
    local list = collect(player, math.max(sixthR, senseR))
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    if sixthR > 0 then S.sixth = Sense.hunch(list, px, py, pz, sixthR) end
    if active then
        if extended then
            S.hearing = Sense.hearing(player:hasTrait(CharacterTrait.DEAF), player:hasTrait(CharacterTrait.KEEN_HEARING),
                player:hasTrait(CharacterTrait.HARD_OF_HEARING))
        end
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
    updateSixth()
    showHud(S.ring or S.sixthDrawn or #S.alarms > 0)
end

-- ---- world sounds (advanced presence sense, rank 2) --------------------------------------------------------------

-- What made a world sound, as Visual Sounds sorts them: "vehicle", "alarm" (a house alarm, a car alarm going off, an
-- alarm clock ringing on a zombie), "device" (a radio, a TV, a generator, a jukebox), "noise" (anything else: a
-- helicopter, a far shot, a smashed window), or nil for what the sense leaves out (zombies, which the arcs show, and
-- the character's own noise). Returns the kind and a key for the source (the source, or its square's place).
local function soundKind(source, x, y, z, player)
    if source == player then return nil end
    if source == nil then
        -- a source-less sound: what stands on its square (Visual Sounds looks the same way)
        local square = getCell():getGridSquare(x, y, z)
        if not square then return "noise", x .. "," .. y .. "," .. z end
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            if instanceof(o, "IsoRadio") or instanceof(o, "IsoTelevision") or instanceof(o, "IsoGenerator") then
                return "device", o
            end
        end
        local vehicle = square:getVehicleContainer()
        if not vehicle then
            -- an alarm clock rings with no source, on its carrier's square
            local movers = square:getMovingObjects()
            for i = 0, movers:size() - 1 do
                local m = movers:get(i)
                if m == player then return nil end
                if instanceof(m, "IsoZombie") then return "alarm", m end
            end
            return "noise", x .. "," .. y .. "," .. z
        end
        source = vehicle
    end
    if instanceof(source, "BaseVehicle") then
        if source:getSeat(player) ~= -1 then return nil end
        return source:isAlarmSounding() and "alarm" or "vehicle", source
    end
    if instanceof(source, "IsoZombie") then return nil end
    if instanceof(source, "IsoRadio") or instanceof(source, "IsoTelevision") or instanceof(source, "IsoGenerator")
        or instanceof(source, "IsoJukebox") then
        return "device", source
    end
    if string.find(tostring(source), "iso.Alarm", 1, true) then return "alarm", source end
    return "noise", source
end

local function onWorldSound(x, y, z, radius, volume, source)
    if not S.ring or not S.extended then return end
    local player = getPlayer()
    if not player then return end
    -- heard at all (the hearing traits change how far), and not under the character's feet
    local dx, dy = x - player:getX(), y - player:getY()
    local d2 = dx * dx + dy * dy
    local reach = radius * S.hearing
    if d2 >= reach * reach or d2 < 1 then return end
    local kind, key = soundKind(source, x, y, z, player)
    if not kind then return end
    local now = getTimestampMs()
    Sense.heard(S.sounds, key, kind, x + 0.5, y + 0.5, z, now, now + SOUND_MS, SOUND_MAX)
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
    showHud(S.ring or S.sixthDrawn or #S.alarms > 0)
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
        updateSixth()
        showHud(false)
    end
    return need
end

Pulse.job("senses", 500, senseJob)
Pulse.job("alarms", 1000, alarmJob)
Pulse.job("ledger", 1000, ledgerJob)

return Senses
