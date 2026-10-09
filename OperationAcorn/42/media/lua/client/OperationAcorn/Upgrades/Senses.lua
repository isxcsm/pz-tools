-- The scout tree's senses, drawn: 육감 (a moodle-like widget when zombies are near), 기척 감지 (glowing arcs on the
-- ground around the character, by direction and, at rank 2, by distance; the advanced rank 2 adds the noises around,
-- each with a sign of what made it and how far it is, as the Visual Sounds mod shows them), 경보 읽기 (a mark over alarmed houses and cars
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
    dirs = {}, radius = 0, distance = false, extended = false, hearing = 1,
    sixth = false, sixthDrawn = false, alarms = {}, sounds = {}, marks = {}, ring = false,
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

-- The presence marks, as Visual Sounds draws its cues: glowing arcs round the character, each facing its way, on an
-- ellipse laid as the ground lies round the body's middle (BODY of a floor above the feet, where the camera centres
-- the character). Every size is in tiles, so the marks grow and shrink with the zoom as the character does.
--   Zombies: one arc for every way they come from (Sense.scan merges what lies within 30 degrees, eight at most) on
--   the inner ring. Nearer is bigger and brighter, red near, amber at mid, green far (rank 2); one arc for a lone
--   zombie, two for a few, three for a crowd, the echoes outward. Zombies beating on a door, a window or a wall
--   (rank 2) shake their arc and put a burst of strokes on its outer side, in its colour. A chevron on the arc for
--   another floor (rank 2), upright and white.
--   Noises (rank 2): a thin arc in its exact way, its kind in its pattern (plain, a wheel for a vehicle, dots for a
--   radio, TV or generator, spikes for an alarm), white but for alarms, which draw every zombie around and are a deep
--   red. Distance is where and how big the mark is, as Visual Sounds puts a far sound farther out: near (under
--   Sense.NEAR tiles) close round the body, big and bright; mid farther out and smaller; far on the outer ring, small
--   and dim. An alarm also beats: fast when near, slowly at mid, still when far. At most Sense.NOISE_MARKS of them,
--   alarms first; a noise fades out over its last FADE_MS.
-- The pictures are white, tinted as they are drawn.
local BODY = 0.3
local RING = 1.6
local ZOMBIE_W = { 1.8, 1.55, 1.3 }
local ECHO = 0.2
local BANG_W = 0.85
local FLOOR_W = 0.42
local NOISE_RING = { 2.4, 3.2, 4.0 }
local NOISE_W = { 2.1, 1.75, 1.4 }
local NOISE_A = { 1.0, 0.85, 0.65 }
local ALARM_HZ = { 3, 1.5, 0 }
local SHAKE_HZ = 4
local FADE_MS = 700
local SOUND_MS = 2500
local SOUND_MAX = 12
-- Zombies by distance, as Visual Sounds colours them: red near, amber at mid, green far; without the distance rank one
-- pale colour.
local NEAR = { 1.00, 0.30, 0.22 }
local MID = { 1.00, 0.70, 0.22 }
local FAR = { 0.40, 0.92, 0.42 }
local PLAIN = { 0.80, 0.88, 1.00 }
local NOISE_TINT = { 0.95, 0.95, 0.90 }
local ALARM_TINT = { 0.95, 0.08, 0.06 }
local ZOMBIE_PICTURE = { "OA_Sense_Arc_L", "OA_Sense_Arc_M", "OA_Sense_Arc_S" }
local ZOMBIE_TINT = { NEAR, MID, FAR }
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

-- A beat between 0 and 1, `hz` times a second, counted from when the file loaded (getTimestampMs as it is is too big
-- a number to make a phase of).
local T0 = getTimestampMs()
local function beat(now, hz)
    return 0.5 + 0.5 * math.sin((now - T0) * 0.002 * math.pi * hz)
end

-- Draws a picture `w` pixels wide (as tall as its proportions say) centred at the screen point (x, y), turned so that
-- its top faces the screen direction (ux, uy), over a dark copy `shade` pixels lower and right so that a pale mark
-- still reads on a pale floor. UIElement.DrawTexture with four corners (top-left, top-right, bottom-right,
-- bottom-left, the order DrawTextureAngle passes them in) takes screen coordinates, not the panel's.
local function quad(ui, tex, x, y, ux, uy, w, c, a, shade)
    if not tex then return end
    local h = w * tex:getHeight() / tex:getWidth()
    local rx, ry = -uy * w / 2, ux * w / 2
    local tx, ty = ux * h / 2, uy * h / 2
    local x1, y1, x2, y2 = x - rx + tx, y - ry + ty, x + rx + tx, y + ry + ty
    local x3, y3, x4, y4 = x + rx - tx, y + ry - ty, x - rx - tx, y - ry - ty
    if shade > 0 then
        ui:DrawTexture(tex, x1 + shade, y1 + shade, x2 + shade, y2 + shade, x3 + shade, y3 + shade, x4 + shade,
            y4 + shade, 0, 0, 0, a * 0.55)
    end
    ui:DrawTexture(tex, x1, y1, x2, y2, x3, y3, x4, y4, c[1], c[2], c[3], a)
end

-- The zombies' arcs. (cx, cy) is the ring's centre on the screen; (exX, exY) and (eyX, eyY) the screen offsets of one
-- tile east and south; `tile` the length of the first.
local function drawZombies(ui, now, cx, cy, exX, exY, eyX, eyY, tile, shade)
    local dirs = S.dirs
    for i = 1, #dirs do
        local e = dirs[i]
        local gx, gy = (e.wx * exX + e.wy * eyX) * RING, (e.wx * exY + e.wy * eyY) * RING
        local len = math.max(0.01, math.sqrt(gx * gx + gy * gy))
        local ux, uy = gx / len, gy / len
        -- without the distance rank: one middle size, pale
        local band, c, a = 2, PLAIN, 0.8
        if S.distance and S.radius > 0 then
            local t = math.min(1, e.d / S.radius)
            band = (t < 0.34) and 1 or ((t < 0.67) and 2 or 3)
            c, a = ZOMBIE_TINT[band], 1.0 - 0.45 * t
        end
        local tex = picture(ZOMBIE_PICTURE[band])
        local w = ZOMBIE_W[band] * tile
        if e.thump then w = w * (1 + 0.08 * beat(now, SHAKE_HZ)) end
        local x, y = cx + gx, cy + gy
        local arcs = (e.n >= 4) and 3 or ((e.n >= 2) and 2 or 1)
        local step = ECHO * tile
        for k = 0, arcs - 1 do
            quad(ui, tex, x + ux * step * k, y + uy * step * k, ux, uy, w, c, a * (1 - 0.25 * k), shade)
        end
        local bang = e.thump and picture("OA_Sense_Bang")
        if bang and tex then
            -- just past the crest of the outermost echo (the crest is about a quarter of the picture above its middle)
            local bw = BANG_W * tile
            local off = step * (arcs - 1) + w * tex:getHeight() / tex:getWidth() * 0.3
                + bw * bang:getHeight() / bang:getWidth() * 0.45
            quad(ui, bang, x + ux * off, y + uy * off, ux, uy, bw, c, 1, shade)
        end
        if e.up or e.down then
            -- white on the coloured arc (in the arc's colour it melted into it)
            quad(ui, picture(e.up and "OA_Sense_Up" or "OA_Sense_Down"), x, y, 0, -1, FLOOR_W * tile, NOISE_TINT, 1, shade)
        end
    end
end

-- The noises' marks, seen from the character at (px, py, pz).
local function drawNoises(ui, now, px, py, pz, cx, cy, exX, exY, eyX, eyY, tile, shade)
    local marks = S.marks
    for i = 1, #marks do
        local m = marks[i]
        local left = m.untilMs - now
        if left > 0 then
            local dx, dy = m.x - px, m.y - py
            local band = m.band
            local r = NOISE_RING[band] / math.max(0.01, math.sqrt(dx * dx + dy * dy))
            local gx, gy = (dx * exX + dy * eyX) * r, (dx * exY + dy * eyY) * r
            local len = math.max(0.01, math.sqrt(gx * gx + gy * gy))
            local ux, uy = gx / len, gy / len
            local alarm = m.kind == "alarm"
            local a = NOISE_A[band] * math.min(1, left / FADE_MS)
            local w = NOISE_W[band] * tile
            if alarm and ALARM_HZ[band] > 0 then
                local b = beat(now, ALARM_HZ[band])
                a = a * (0.6 + 0.4 * b)
                w = w * (1 + 0.1 * b)
            end
            local x, y = cx + gx, cy + gy
            local tex = picture(NOISE_PICTURE[m.kind])
            local tint = alarm and ALARM_TINT or NOISE_TINT
            quad(ui, tex, x, y, ux, uy, w, tint, a, shade)
            if alarm then
                -- drawn twice: one red pass is thin on a pale floor
                quad(ui, tex, x, y, ux, uy, w, tint, a, 0)
            end
            if math.abs(m.z - pz) >= 0.5 then
                quad(ui, picture(m.z > pz and "OA_Sense_Up" or "OA_Sense_Down"), x, y, 0, -1, FLOOR_W * tile,
                    NOISE_TINT, 1, shade)
            end
        end
    end
end

function Hud:render()
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local player = getSpecificPlayer(self.playerNum)
    if S.ring and player and (#S.dirs > 0 or #S.marks > 0) then
        local n, px, py, pz = self.playerNum, player:getX(), player:getY(), player:getZ()
        local ox, oy = isoToScreenX(n, px, py, pz), isoToScreenY(n, px, py, pz)
        local exX, exY = isoToScreenX(n, px + 1, py, pz) - ox, isoToScreenY(n, px + 1, py, pz) - oy
        local eyX, eyY = isoToScreenX(n, px, py + 1, pz) - ox, isoToScreenY(n, px, py + 1, pz) - oy
        -- screen coordinates, as isoToScreen gives them and the quads take them
        local cx, cy = ox, isoToScreenY(n, px, py, pz + BODY)
        local tile = math.sqrt(exX * exX + exY * exY)
        local shade = math.max(1, tile / 48)
        local now = getTimestampMs()
        local ui = self.javaObject
        drawZombies(ui, now, cx, cy, exX, exY, eyX, eyY, tile, shade)
        drawNoises(ui, now, px, py, pz, cx, cy, exX, exY, eyX, eyY, tile, shade)
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

-- A zombie as a plain position. It is beating on something while it is in ThumpState (IsoZombie.getThumpTimer is the
-- wait the state sets as it leaves: counting down, it is the blows that stopped, not the ones going on).
local thumpState = nil
local function plain(z)
    thumpState = thumpState or ThumpState.instance()
    return { x = z:getX(), y = z:getY(), z = z:getZ(), thump = z:isCurrentState(thumpState) }
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
            for _, e in ipairs(S.dirs) do e.thump = false end
        end
        -- the noises' marks follow the character (and drop what ran out)
        if extended then Sense.marks(S.sounds, px, py, now, S.marks) end
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
    local _, new = Sense.heard(S.sounds, key, kind, x + 0.5, y + 0.5, z, now, now + SOUND_MS, SOUND_MAX)
    -- a new noise shows at once; one heard again is moved by the next pulse
    if new then Sense.marks(S.sounds, player:getX(), player:getY(), now, S.marks) end
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
