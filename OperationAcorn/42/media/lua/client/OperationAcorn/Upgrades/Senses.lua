-- The scout tree's senses, drawn: 육감 (a moodle while an unseen zombie is near: Moodles.lua), 기척 감지 (the sounds zombies make
-- around the character, as glowing arcs where they were made, for a while, as the Visual Sounds mod shows its cues; at
-- rank 2 how far; the advanced rank 2 adds zombies breaking in, other floors and the noises around, each with a sign
-- of what made it), 경보 읽기 (a mark over alarmed houses and cars nearby) and 털이 기록 (how many containers of the
-- building are still unopened). The sounds come as they are made (the world sounds; the extension API's zombie
-- sounds: a target taken, a lunge, a strike), and the zombies' groans and, without the API, the rest are told twice a
-- second from the game's zombie list by the shared timer (Pulse.lua). The drawing works out every mark's way from
-- where the character stands, every frame.
require "ISUI/ISPanel"
-- ISCoordConversion is a server-folder file, loaded after this one: it is used when drawing, not required here.
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Pulse"
require "OperationAcorn/Upgrades/Moodles"
require "OperationAcorn/Upgrades/First"
require "OperationAcorn/Economy/Buildings"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local UI = OA.Trade.UI
local Rules = OA.Upgrades.Rules
local Sense = OA.Upgrades.Sense
local Pulse = OA.Upgrades.Pulse
local Moodles = OA.Upgrades.Moodles
local First = OA.Upgrades.First
local Senses = {}
OA.Upgrades.Senses = Senses

-- What the last pulse found.
local S = {
    radius = 0, distance = false, extended = false, hearing = 1,
    sixth = false, alarms = {}, zombies = {}, sounds = {}, ring = false,
}
Senses.state = S

local ALARM_RANGE = 30
local ALARM_NEAR = 4
local announced = {}

-- ---- the HUD ---------------------------------------------------------------------------------------------------

local Hud = ISPanel:derive("ISOASenseHud")
ISOASenseHud = Hud

-- The element is one pixel at the screen's corner and draws past its bounds (as Visual Sounds' does): the game gives a
-- click on any element under the mouse to it and not to the world, consuming events or not, so a full-screen one took
-- every click in the world. screenW and screenH are the player's screen it draws over.
function Hud:new(playerNum)
    local o = ISPanel.new(self, getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum), 1, 1)
    o.screenW, o.screenH = getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)
    o.playerNum = playerNum
    o.background = false
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.moveWithMouse = false
    return o
end

function Hud:prerender() end

-- The presence marks, drawn as Visual Sounds draws its cues: its pictures (tools/sense_art.py copies them), its sizes,
-- strengths and colours by its distance bands (Sense.cue), and its distance from the character (Sense.offset), all as
-- it has them: a UX many players have used. Each cue's line is Sense.offset(d) screen pixels from the character's
-- middle (BODY of a floor above the feet), and the marks laid on a cue (a chevron, brackets, a wheel) sit on its line,
-- the way to the place its sound comes from, worked out every frame (the
-- way on the screen as the view projects it: Visual Sounds turns the world by 45 degrees, which is off by up to 18 on
-- the game's 2:1 view), turned to face out. A zombie's sound follows the zombie (but its beating on something, which
-- is where it beats), and so does an alarm clock ringing on one, as Visual Sounds' do. A zombie the character sees
-- now is drawn faint (the cue is for what the eyes miss), whatever it is doing: as the game shows it (its target
-- alpha), so that turning away from it brings its cue back at once (Visual Sounds can hide only one coming for the
-- character, by its square, which leaves one behind the character hidden too). Sizes are screen pixels, as Visual Sounds draws them, whatever the zoom. A cue comes on over FADE_IN_MS
-- and fades out over its last FADE_MS.
--   Zombies: a thin arc with a soft trail on its inner side, red near through orange and yellow to green far, short
--   and strong near, wide and faint far. Without the distance rank one pale arc at one distance (nothing tells how
--   far). One beating on a door, a window or a wall (advanced rank 2) has brackets on it, ( ( ) ), orange.
--   Noises (advanced rank 2): a vehicle a flat line with a wheel, a machine (radio, TV, generator) a dotted cyan arc,
--   an alarm (it draws every zombie around) a row of red triangles, anything else a thin white arc.
--   A sound on the character's square: a soft red disc. A chevron on a cue for another floor, upright and white.
-- The pictures are white, tinted as they are drawn.
local BODY = 0.3
local FADE_IN_MS = 180
local FADE_MS = 700
-- A shadow under each cue, this many pixels down and right, so that a pale one reads on a pale floor.
local SHADE = 1
-- The cue of a band, from Visual Sounds' pictures: its picture, its width (pixels) and strength (its pictures' most
-- opaque pixel), and its colour, for bands 2 .. 8 (band 1 is SAME). Each picture is drawn at the band's width.
local function rgb(r, g, b) return { r / 255, g / 255, b / 255 } end
local function strengths(list)
    for i = 1, #list do list[i] = list[i] / 255 end
    return list
end
local CUES = {
    zombie = {
        pictures = { nil, "OA_Sense_Arc_Near", "OA_Sense_Arc_Mid", "OA_Sense_Arc_Mid", "OA_Sense_Arc_Far",
            "OA_Sense_Arc_Far", "OA_Sense_Arc_Far", "OA_Sense_Arc_Far" },
        w = { 0, 83, 100, 110, 120, 130, 126, 126 },
        a = strengths({ 0, 186, 173, 158, 143, 125, 107, 89 }),
        c = { nil, rgb(255, 0, 0), rgb(255, 66, 0), rgb(255, 120, 0), rgb(255, 174, 0), rgb(255, 234, 0),
            rgb(180, 255, 0), rgb(0, 255, 47) },
    },
    vehicle = {
        w = { 0, 80, 70, 65, 60, 55, 48, 82 },
        a = strengths({ 0, 243, 243, 243, 243, 243, 243, 243 }),
    },
    device = {
        w = { 0, 140, 130, 120, 110, 93, 84, 139 },
        a = strengths({ 0, 126, 151, 177, 202, 227, 252, 101 }),
    },
    noise = {
        w = { 0, 140, 130, 120, 110, 93, 84, 139 },
        a = strengths({ 0, 127, 147, 166, 181, 133, 209, 104 }),
    },
    alarm = {
        pictures = { nil, "OA_Sense_Alarm_L", "OA_Sense_Alarm_L", "OA_Sense_Alarm_L", "OA_Sense_Alarm_M",
            "OA_Sense_Alarm_M", "OA_Sense_Alarm_S", "OA_Sense_Alarm_S" },
        w = { 0, 126, 121, 120, 110, 93, 84, 84 },
        a = strengths({ 0, 128, 153, 179, 204, 230, 255, 255 }),
    },
}
CUES.vehicle.picture, CUES.device.picture, CUES.noise.picture = "OA_Sense_Line", "OA_Sense_Dots", "OA_Sense_Noise"
-- Where each picture's line runs, above the picture's middle, of its height (tools/sense_art.py prints them): an arc's
-- trail hangs below its line, so the picture is drawn that much further in.
local LINE = { OA_Sense_Arc_Near = 0.354, OA_Sense_Arc_Mid = 0.364, OA_Sense_Arc_Far = 0.373, OA_Sense_Dots = 0.25,
    OA_Sense_Noise = 0.281, OA_Sense_Alarm_L = 0.226, OA_Sense_Alarm_M = 0.183, OA_Sense_Alarm_S = 0.114 }
local WHITE = { 1, 1, 1 }
local CUE_TINT = { vehicle = WHITE, device = rgb(0, 186, 254), noise = WHITE, alarm = rgb(255, 0, 0) }
-- The vehicle's wheel, the thump's brackets, the square's disc and the floor chevrons: one size each, upright.
local WHEEL_W = 16
local THUMP_W, THUMP_A, THUMP_TINT = 32, 224 / 255, rgb(255, 106, 0)
local SAME_W, SAME_A, SAME_TINT = 46, 83 / 255, rgb(255, 0, 0)
local FLOOR_W = 22
-- Without the distance rank: one pale arc, as a mid band's, at one distance.
local PLAIN = { 0.80, 0.88, 1.00 }
local PLAIN_BAND = 4
local PLAIN_D = 6.5
local pictures = {}
local function picture(name)
    local t = pictures[name]
    if t == nil then
        t = getTexture("media/textures/" .. name .. ".png") or false
        pictures[name] = t
    end
    return t or nil
end

-- Draws a picture `w` pixels wide (as tall as its proportions say) centred at the screen point (x, y), turned so that
-- its top faces the screen direction (ux, uy) (0, -1: upright), over a dark copy SHADE pixels lower and right.
-- UIElement.DrawTexture with four corners (top-left, top-right, bottom-right, bottom-left, the order DrawTextureAngle
-- passes them in) takes screen coordinates, not the panel's.
local function quad(ui, tex, x, y, ux, uy, w, c, a)
    if not tex then return end
    local h = w * tex:getHeight() / tex:getWidth()
    local rx, ry = -uy * w / 2, ux * w / 2
    local tx, ty = ux * h / 2, uy * h / 2
    local x1, y1, x2, y2 = x - rx + tx, y - ry + ty, x + rx + tx, y + ry + ty
    local x3, y3, x4, y4 = x + rx - tx, y + ry - ty, x - rx - tx, y - ry - ty
    ui:DrawTexture(tex, x1 + SHADE, y1 + SHADE, x2 + SHADE, y2 + SHADE, x3 + SHADE, y3 + SHADE, x4 + SHADE,
        y4 + SHADE, 0, 0, 0, a * 0.55)
    ui:DrawTexture(tex, x1, y1, x2, y2, x3, y3, x4, y4, c[1], c[2], c[3], a)
end

-- Draws the picture `name` of a cue `w` pixels wide with its line at (x, y), facing out the way (ux, uy).
local function cue(ui, name, x, y, ux, uy, w, c, a)
    local tex = picture(name)
    if not tex then return end
    local back = (LINE[name] or 0) * w * tex:getHeight() / tex:getWidth()
    quad(ui, tex, x - ux * back, y - uy * back, ux, uy, w, c, a)
end

-- Moves a cue that follows a zombie (m.follow) to where the zombie is now; a dead one leaves it where it was.
local function follow(m)
    local z = m.follow
    if not z then return end
    if z:isDead() then
        m.follow = nil
    else
        m.x, m.y, m.z = z:getX(), z:getY(), z:getZ()
    end
end

-- How faint the cue of a zombie the character sees is drawn (1 would hide it).
local SEEN_DIM = 0.7

-- How much of a cue shows at `now`: coming on, then fading out at the end.
local function shown(m, now)
    local a = math.min(1, (now - m.born) / FADE_IN_MS)
    local left = m.untilMs - now
    if left < FADE_MS then a = a * math.max(0, left / FADE_MS) end
    return a
end

-- The way on the screen from the character at (px, py) to the place (x, y), a unit vector, and the distance in tiles.
-- (exX, exY) and (eyX, eyY) are the screen offsets of one tile east and south.
local function way(x, y, px, py, exX, exY, eyX, eyY)
    local dx, dy = x - px, y - py
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.01 then return -1, 0, 0 end
    local gx, gy = dx * exX + dy * eyX, dx * exY + dy * eyY
    local len = math.max(0.01, math.sqrt(gx * gx + gy * gy))
    return gx / len, gy / len, d
end

-- The chevron for a cue at (x, y) a floor above or below the character.
local function floorMark(ui, x, y, z, pz, a)
    if math.abs(z - pz) >= 0.5 then
        quad(ui, picture(z > pz and "OA_Sense_Up" or "OA_Sense_Down"), x, y, 0, -1, FLOOR_W, WHITE, a)
    end
end

-- The zombies' sounds. (cx, cy) is the character's middle on the screen.
local function drawZombies(ui, now, n, px, py, pz, cx, cy, exX, exY, eyX, eyY)
    local list = S.zombies
    local cues = CUES.zombie
    for i = 1, #list do
        local m = list[i]
        local a = shown(m, now)
        if a > 0 then
            follow(m)
            -- one the character sees, faint (m.follow: a zombie's own sound, not its beating on something)
            if m.follow then a = a * (1 - SEEN_DIM * math.min(1, m.follow:getTargetAlpha(n))) end
            local ux, uy, d = way(m.x, m.y, px, py, exX, exY, eyX, eyY)
            local band, c = PLAIN_BAND, PLAIN
            if S.distance then
                band = Sense.cue(d)
                c = cues.c[band]
            else
                d = PLAIN_D
            end
            local r = Sense.offset(d)
            local x, y = cx + ux * r, cy + uy * r
            if band == 1 then
                quad(ui, picture("OA_Sense_Same"), x, y, 0, -1, SAME_W, SAME_TINT, a * SAME_A)
            else
                cue(ui, cues.pictures[band], x, y, ux, uy, cues.w[band], c, a * cues.a[band])
            end
            if m.kind == "thump" then
                quad(ui, picture("OA_Sense_Thump"), x, y, 0, -1, THUMP_W, THUMP_TINT, a * THUMP_A)
            end
            if S.extended then floorMark(ui, x, y, m.z, pz, a) end
        end
    end
end

-- The noises' cues, seen from the character at (px, py, pz).
local function drawNoises(ui, now, px, py, pz, cx, cy, exX, exY, eyX, eyY)
    local list = S.sounds
    for i = 1, #list do
        local m = list[i]
        local a = shown(m, now)
        if a > 0 then
            follow(m)
            local ux, uy, d = way(m.x, m.y, px, py, exX, exY, eyX, eyY)
            local band = Sense.cue(d)
            local r = Sense.offset(d)
            local x, y = cx + ux * r, cy + uy * r
            local cues = CUES[m.kind] or CUES.noise
            if band == 1 then
                quad(ui, picture("OA_Sense_Same"), x, y, 0, -1, SAME_W, SAME_TINT, a * SAME_A)
            else
                local strength = a * cues.a[band]
                cue(ui, cues.pictures and cues.pictures[band] or cues.picture, x, y, ux, uy, cues.w[band],
                    CUE_TINT[m.kind] or WHITE, strength)
                if m.kind == "vehicle" then
                    quad(ui, picture("OA_Sense_Wheel"), x, y, 0, -1, WHEEL_W, WHITE, strength)
                end
            end
            floorMark(ui, x, y, m.z, pz, a)
        end
    end
end

function Hud:render()
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local player = getSpecificPlayer(self.playerNum)
    if S.ring and player and (#S.zombies > 0 or #S.sounds > 0) then
        local n, px, py, pz = self.playerNum, player:getX(), player:getY(), player:getZ()
        local ox, oy = isoToScreenX(n, px, py, pz), isoToScreenY(n, px, py, pz)
        local exX, exY = isoToScreenX(n, px + 1, py, pz) - ox, isoToScreenY(n, px + 1, py, pz) - oy
        local eyX, eyY = isoToScreenX(n, px, py + 1, pz) - ox, isoToScreenY(n, px, py + 1, pz) - oy
        -- screen coordinates, as isoToScreen gives them and the quads take them
        local cx, cy = ox, isoToScreenY(n, px, py, pz + BODY)
        local now = getTimestampMs()
        local ui = self.javaObject
        drawZombies(ui, now, n, px, py, pz, cx, cy, exX, exY, eyX, eyY)
        drawNoises(ui, now, px, py, pz, cx, cy, exX, exY, eyX, eyY)
    end
    if #S.alarms > 0 then
        local zoom = getCore():getZoom(self.playerNum)
        for _, spot in ipairs(S.alarms) do
            local sx, sy = ISCoordConversion.ToScreen(spot.x, spot.y, spot.z)
            sx, sy = sx / zoom - self.x, sy / zoom - self.y
            if sx > 0 and sy > 0 and sx < self.screenW and sy < self.screenH then
                local w = getTextManager():MeasureStringX(UIFont.Small, "!") + 8
                self:drawRect(sx - w / 2, sy - fh - 6, w, fh + 2, 0.7, 0.6, 0.05, 0.05)
                self:drawRectBorder(sx - w / 2, sy - fh - 6, w, fh + 2, 0.9, 1, 0.5, 0.5)
                self:drawTextCentre("!", sx, sy - fh - 5, 1, 1, 1, 1, UIFont.Small)
            end
        end
    end
end

-- Whether a mark is on show at `now`: a cue that has not run out (the lists keep run-out ones until the next sound),
-- or an alarm's mark.
local function marking(now)
    if #S.alarms > 0 then return true end
    if not S.ring then return false end
    local list = S.zombies
    for i = 1, #list do
        if list[i].untilMs > now then return true end
    end
    list = S.sounds
    for i = 1, #list do
        if list[i].untilMs > now then return true end
    end
    return false
end

-- Each frame, before the UI draws (Trade/UI live): the marks are placed from where the character, the camera and the
-- zombies they follow are, which move without telling the HUD, and a cue fades by the clock, so while a mark is on
-- show the HUD is drawn every frame (`now`), as it is without PZ Optimization; with none, it holds still (0) and a new
-- cue shows at once.
function Hud.tick(el, now)
    return marking(now) and now or 0
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
            hud.screenW, hud.screenH = getPlayerScreenWidth(0), getPlayerScreenHeight(0)
            -- followed each frame while it shows (a hidden HUD was let go)
            UI.live(hud, Hud.tick)
        end
    end
end

-- ---- the 0.5 second pulse: zombies ------------------------------------------------------------------------------

local function section(player)
    local record = OA.Client.record(player)
    return record and Rules.section(record) or nil
end

-- A zombie as a plain position, and (`acts`) whether it has a target and whether it lunges or strikes, for the zombie
-- sounds told without the extension API's (Sense.voices). Within `look` (a squared distance from (lx, ly); 0 for
-- none), whether player `n` sees it, for the sixth sense: the game fades a zombie it finds unseen out (its target alpha
-- for that player 0, IsoGameCharacter.updateSeenVisibility), so that is one read and no sight line of ours.
local lungeState, attackState
local SEEN_ALPHA = 0.05

-- The plain zombies of the last look, reused from one look to the next (a look is twice a second): `collected` holds
-- `count` of them; the tables past it are kept for the next look and are not in the list.
local collected, kept = {}, {}

local function plain(count, z, x, y, acts, n, look, lx, ly)
    local p = kept[count]
    if not p then
        p = {}
        kept[count] = p
    end
    collected[count] = p
    p.ref, p.x, p.y, p.z, p.seen, p.hunt, p.attack = z, x, y, z:getZ(), nil, nil, nil
    if look > 0 then
        local dx, dy = x - lx, y - ly
        if dx * dx + dy * dy <= look then p.seen = z:getTargetAlpha(n) >= SEEN_ALPHA end
    end
    if acts then
        lungeState = lungeState or LungeState.instance()
        attackState = attackState or AttackState.instance()
        p.hunt = z:getTarget() ~= nil
        p.attack = z:isCurrentState(lungeState) or z:isCurrentState(attackState)
    end
end

-- Ends a look of `count` zombies: the list holds them alone.
local function ended(count)
    for i = #collected, count + 1, -1 do collected[i] = nil end
    return collected
end

-- The zombies near the character from the extension API's spatial query (PZToolsAPI.zombies.near: `count, list`, one
-- whole level a call, the nearest `limit`), on its floor and the ones beside it; nil when the API has none or its
-- answer is not what it should be (then the scan below does it).
local NEAR_LIMIT = 64
local function fromApi(near, n, px, py, pz, radius, acts, look)
    pz = math.floor(pz)
    local count = 0
    for level = pz - 1, pz + 1 do
        local _, result = near(px, py, level, radius, NEAR_LIMIT)
        if type(result) ~= "table" then return nil end
        for k = 1, #result do
            local z = result[k].zombie
            if z and not z:isDead() then
                count = count + 1
                plain(count, z, z:getX(), z:getY(), acts, n, look, px, py)
            end
        end
    end
    return ended(count)
end

-- The loaded zombies near the character (player number n, at px, py, pz: read once by the caller) as plain positions,
-- for the pure parts (the list is the one of every look). A zombie's place is read once in a look.
local function collect(n, px, py, pz, radius, acts, look)
    local api = OA.api()
    local zombies = api and api.zombies
    if type(zombies) == "table" and type(zombies.near) == "function" then
        local ok, list = pcall(fromApi, zombies.near, n, px, py, pz, radius, acts, look)
        if ok and list then return list end
    end
    local zs = getCell():getZombieList()
    local count = 0
    for i = 0, zs:size() - 1 do
        local z = zs:get(i)
        local zx, zy = z:getX(), z:getY()
        if zx - px <= radius and px - zx <= radius and zy - py <= radius and py - zy <= radius and not z:isDead() then
            count = count + 1
            plain(count, z, zx, zy, acts, n, look, px, py)
        end
    end
    return ended(count)
end

-- The sixth sense's moodle as S.sixth says (Moodles: the game's column, or a stand-in beside it).
local function updateSixth()
    Moodles.set("sixth", S.sixth and 1 or 0)
end

-- Puts a zombie's sound in the list, heard where it was made; but for its beating on something (where it beats), it
-- follows the zombie (`key`, when it is one) from then.
local function zombieHeard(kind, key, x, y, z, now)
    local _, _, m = Sense.heard(S.zombies, key, kind, x, y, z, now, now + Sense.LIFE[kind], Sense.ZOMBIE_MARKS)
    m.follow = kind ~= "thump" and type(key) == "userdata" and key or nil
    First.report("sense")
end

local voiceMemo, voiceOut = {}, {}

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
    if not active and S.ring then
        -- off: what was heard goes with it
        S.zombies, S.sounds = {}, {}
        voiceMemo = {}
    end
    S.ring = active
    S.sixth = false
    if sixthR <= 0 and not active then
        updateSixth()
        showHud(#S.alarms > 0)
        return
    end
    local extended = Sense.extended(u)
    if active then
        S.hearing = Sense.hearing(player:hasTrait(CharacterTrait.DEAF), player:hasTrait(CharacterTrait.KEEN_HEARING),
            player:hasTrait(CharacterTrait.HARD_OF_HEARING))
        S.radius = senseR * S.hearing
        S.distance = Sense.distance(u)
        S.extended = extended
    end
    local tell = active and S.hearing > 0
    local reach = math.max(sixthR, tell and S.radius or 0)
    if reach > 0 then
        local px, py, pz = player:getX(), player:getY(), player:getZ()
        local list = collect(player:getPlayerNum(), px, py, pz, reach, tell, sixthR * sixthR)
        if sixthR > 0 then S.sixth = Sense.hunch(list, px, py, pz, sixthR) end
        if tell then
            local heard = Sense.voices(list, voiceMemo, px, py, pz, S.radius, extended, now, voiceOut)
            for i = 1, #heard do
                local e = heard[i]
                zombieHeard(e.kind, e.key, e.x, e.y, e.z, now)
            end
        end
    end
    updateSixth()
    showHud(S.ring or #S.alarms > 0)
end

-- ---- world sounds (advanced presence sense, rank 2) --------------------------------------------------------------

-- What made a world sound, as Visual Sounds sorts them: "thump" (a zombie beating on a door, a window or a wall: the
-- sound is at the place it beats on), "vehicle", "alarm" (a house alarm, a car alarm going off, an alarm clock ringing
-- on a zombie), "device" (a radio or a TV), "noise" (anything else: a generator, a jukebox, a helicopter, a far shot,
-- a smashed window, a door broken down: Visual Sounds shows a generator so too), or nil for what the sense leaves out (the character's own noise). Returns the
-- kind and a key for the source (the source, or its square's place).
local ALARM_CLOCK_VOLUME = 3
local function soundKind(source, x, y, z, volume, player)
    if source == player then return nil end
    if source == nil then
        -- a source-less sound: what stands on its square (Visual Sounds looks the same way)
        local square = getCell():getGridSquare(x, y, z)
        if not square then return "noise", x .. "," .. y .. "," .. z end
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            if instanceof(o, "IsoRadio") or instanceof(o, "IsoTelevision") then return "device", o end
            if instanceof(o, "IsoGenerator") then return "noise", o end
        end
        local vehicle = square:getVehicleContainer()
        if not vehicle then
            -- an alarm clock rings with no source, on its carrier's square, at its own low volume (what breaks a door or
            -- a window down has none either, and is louder)
            local movers = square:getMovingObjects()
            for i = 0, movers:size() - 1 do
                local m = movers:get(i)
                if m == player then return nil end
                if volume == ALARM_CLOCK_VOLUME and instanceof(m, "IsoZombie") then return "alarm", m end
            end
            return "noise", x .. "," .. y .. "," .. z
        end
        source = vehicle
    end
    if instanceof(source, "BaseVehicle") then
        if source:getSeat(player) ~= -1 then return nil end
        return source:isAlarmSounding() and "alarm" or "vehicle", source
    end
    if instanceof(source, "IsoZombie") then return "thump", source end
    if instanceof(source, "IsoRadio") or instanceof(source, "IsoTelevision") then return "device", source end
    if string.find(tostring(source), "iso.Alarm", 1, true) then return "alarm", source end
    return "noise", source
end

-- What a source is, kept for the sources that sound again and again (an alarm or an engine, every frame): the kind
-- and key soundKind found. Emptied now and then so that it keeps no source long.
local kindOf, kindKey, kindsAt = {}, {}, 0
local KINDS_MS = 5000
-- At most SOUNDS_PER_WINDOW world sounds heard each SOUND_WINDOW_MS, as Visual Sounds caps the sounds it handles: the
-- game calls this inside its sound list's lock (PZ Optimize) for every sound, an alarm every frame, so a burst (a
-- crowd beating on doors, gunfire) costs no more than this; one heard again later shows again.
local SOUNDS_PER_WINDOW = 16
local SOUND_WINDOW_MS = 250
local windowAt, windowCount = 0, 0

local function onWorldSound(x, y, z, radius, volume, source)
    if not S.ring or S.hearing <= 0 then return end
    local player = getPlayer()
    if not player or source == player then return end
    -- heard at all (the hearing traits change how far), and not under the character's feet
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local dx, dy = x - px, y - py
    local d2 = dx * dx + dy * dy
    local reach = radius * S.hearing
    if d2 >= reach * reach or d2 < 1 then return end
    local now = getTimestampMs()
    if now - windowAt >= SOUND_WINDOW_MS or now < windowAt then
        windowAt, windowCount = now, 0
    end
    if windowCount >= SOUNDS_PER_WINDOW then return end
    windowCount = windowCount + 1
    local kind, key
    if source ~= nil then
        if now - kindsAt > KINDS_MS then kindOf, kindKey, kindsAt = {}, {}, now end
        kind, key = kindOf[source], kindKey[source]
        if kind == nil then
            kind, key = soundKind(source, x, y, z, volume, player)
            kindOf[source], kindKey[source] = kind or false, key
        end
    else
        kind, key = soundKind(nil, x, y, z, volume, player)
    end
    if not kind then return end
    if kind == "thump" then
        -- a zombie's: within the sense's reach, on the character's floor unless the advanced rank tells floors; beating
        -- on something only with the advanced rank, else a zombie's sound
        if d2 > S.radius * S.radius or (not S.extended and math.abs(z - pz) >= 0.5) then return end
        zombieHeard(S.extended and "thump" or "zombie", key, x + 0.5, y + 0.5, z, now)
        return
    end
    if not S.extended then return end
    local _, _, m = Sense.heard(S.sounds, key, kind, x + 0.5, y + 0.5, z, now, now + Sense.LIFE[kind], Sense.NOISE_MARKS)
    -- an alarm clock ringing on a zombie goes where it goes
    m.follow = kind == "alarm" and type(key) == "userdata" and instanceof(key, "IsoZombie") and key or nil
end

-- The zombies' own sounds from the extension API (a groan, taking a target, a lunge or a strike, a fall): heard where
-- the zombie was, within the sense's reach.
local API_KIND = { voice = "zombie", aggro = "aggro", lunge = "attack", attack = "attack", hit = "zombie",
    death = "zombie", fall = "zombie" }
local function onZombieSound(kind, x, y, z, loudness, zombie)
    if not S.ring or S.hearing <= 0 then return end
    local player = getPlayer()
    if not player then return end
    local dx, dy = x - player:getX(), y - player:getY()
    if dx * dx + dy * dy > S.radius * S.radius then return end
    if not S.extended and math.abs(z - player:getZ()) >= 0.5 then return end
    zombieHeard(API_KIND[kind] or "zombie", zombie or (x .. "," .. y .. "," .. z), x, y, z, getTimestampMs())
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
    showHud(S.ring or #S.alarms > 0)
end

-- ---- the building's containers (털이 기록) ----------------------------------------------------------------------
-- Rank 1: on entering a building, how many containers are left unopened, or that it was searched (the title of a
-- building searched comes from the economy, with its bonus). Rank 2: the unopened containers within LEDGER_NEAR on the
-- character's floor, on squares in its line of sight (whichever way it faces: no outline comes and goes as it turns),
-- are outlined (the game's own object outline, for this player). One behind a wall is not: the game draws its outline
-- through the wall, in another colour, and it told what the eyes cannot. Rank 3 is the economy's (a bigger
-- bonus). The building and its containers are the economy's walk (OA.Buildings: square by square, a part a look; the
-- game's IsoRoom:getContainer() lists none in B42), looked at from here every LEDGER_MS.

local ledger = { key = nil, total = 0, opened = 0, done = false, complete = false, told = true, since = 0 }
Senses.ledger = ledger
-- A building not all counted yet is told once it is, or after LEDGER_WAIT_MS with what was found (a count of 0 then is
-- not told: it could be squares not loaded).
local LEDGER_WAIT_MS = 5000
local LEDGER_NEAR = 6
local OUTLINE = { 1.00, 0.80, 0.40, 0.85 }

-- The objects outlined now (object -> true) and for which player.
local outlined, outlinedFor = {}, 0

local function setOutline(object, on, playerNum)
    if on then
        object:setOutlineHighlightCol(playerNum, OUTLINE[1], OUTLINE[2], OUTLINE[3], OUTLINE[4])
    end
    object:setOutlineHighlight(playerNum, on)
end

-- Outlines the objects in `want` (object -> true) and no others.
local function outlineOnly(want, playerNum)
    for object in pairs(outlined) do
        if not want[object] or playerNum ~= outlinedFor then setOutline(object, false, outlinedFor) end
    end
    for object in pairs(want) do
        if not outlined[object] or playerNum ~= outlinedFor then setOutline(object, true, playerNum) end
    end
    outlined, outlinedFor = want, playerNum
end

local none = {}
local function clearOutlines()
    if outlinedFor ~= nil then outlineOnly(none, outlinedFor) end
    outlined = {}
end
Senses.clearOutlines = clearOutlines

-- The objects of the unopened containers within LEDGER_NEAR of the character on its floor, in its line of sight, into
-- a new set.
local function nearUnopened(open, player)
    local want = {}
    local n = player:getPlayerNum()
    -- a container a mission lights is outlined in the mission's colour, not this one
    local mission = OA.StoryHighlight and OA.StoryHighlight.lit[n] or none
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local r2 = LEDGER_NEAR * LEDGER_NEAR
    for i = 1, #open do
        local object = open[i]:getParent()
        local square = object and object:getSquare()
        if square and square:getZ() == pz then
            local dx, dy = square:getX() + 0.5 - px, square:getY() + 0.5 - py
            if dx * dx + dy * dy <= r2 and not mission[object] and square:isCouldSee(n) then want[object] = true end
        end
    end
    return want
end

-- The look at the building (the walk over its squares, the containers asked whether they are opened) is made at most
-- once each Buildings.LOOK_MS, as the economy's minute check makes it; between looks the job works from what the last
-- look found (`look`), and the outlines are made again only when the character has moved to another square.
local lookAt = {}      -- OA.due's clock of the look
local look = { key = nil, opened = 0, total = 0, complete = false, stamp = 0 }
local outlinedAt = { x = nil, y = nil, z = nil, stamp = -1 }

local function ledgerJob(now)
    local player = getPlayer()
    local record = player and not player:isDead() and OA.Client.record(player)
    local rank = record and Rules.rank(Rules.section(record), "ledger") or 0
    if rank >= 1 then
        if OA.due(lookAt, "look", now, OA.Buildings.LOOK_MS) then
            look.key, look.opened, look.total, look.complete = OA.Buildings.tick(player)
            look.stamp = look.stamp + 1
        end
    else
        lookAt.look, look.key = nil, nil
    end
    local key, opened, total, complete = look.key, look.opened, look.total, look.complete
    if not key then
        ledger.key = nil
        outlinedAt.x = nil
        clearOutlines()
        return
    end
    if rank >= 2 then
        local square = player:getCurrentSquare()
        local x, y, z = square and square:getX(), square and square:getY(), square and square:getZ()
        if outlinedAt.stamp ~= look.stamp or outlinedAt.x ~= x or outlinedAt.y ~= y or outlinedAt.z ~= z
            or not square then
            outlinedAt.x, outlinedAt.y, outlinedAt.z, outlinedAt.stamp = x, y, z, look.stamp
            local want = nearUnopened(OA.Buildings.unopened(player) or none, player)
            outlineOnly(want, player:getPlayerNum())
            for _ in pairs(want) do
                First.report("ledger", player)
                break
            end
        end
    else
        outlinedAt.x = nil
        clearOutlines()
    end
    if key ~= ledger.key then
        ledger.key, ledger.done, ledger.told, ledger.since = key, false, false, now
    end
    ledger.total, ledger.opened, ledger.complete = total, opened, complete
    if ledger.told then return end
    -- told once on entering: how many are left, or that it is searched (never "0 left"); one with no containers is not
    if not complete and now - ledger.since < LEDGER_WAIT_MS and now >= ledger.since then return end
    ledger.told = true
    local left = total - opened
    if total > 0 and left == 0 then
        if complete then
            ledger.done = true
            HaloTextHelper.addGoodText(player, getText("IGUI_OA_Tree_LedgerAlreadyDone"))
        end
    elseif left > 0 then
        HaloTextHelper.addText(player, getText("IGUI_OA_Tree_LedgerLeft", left))
        First.report("ledger", player)
    end
end

-- ---- starting --------------------------------------------------------------------------------------------------

local soundHooked = false
local zombiesListened = 0   -- the radius the API listens for zombie sounds within, 0 when it does not

-- Has the extension API tell the zombies' sounds within the sense's reach (PZToolsAPI.zombies.listen and the event
-- OnPZToolsZombieSound), when it can: taking a target, a lunge, a strike, a fall as they happen. A zombie's groan is
-- one looping sound to the game (the API tells it once, as it starts: seen in game), so the groans now and then are
-- still told from the zombie list (Sense.voices).
local function listenZombies(want, u)
    local api, handle = OA.api(), OA.handle()
    local zombies = api and api.zombies
    local can = handle and type(zombies) == "table" and type(zombies.listen) == "function"
        and Events.OnPZToolsZombieSound ~= nil
    local radius = (want and can) and math.ceil(Rules.senseRadius(u) * 1.2) or 0
    if radius == zombiesListened then return end
    if can then
        local ok, err = pcall(zombies.listen, handle, radius)
        if not ok then
            OA.log("zombie sounds:", tostring(err))
            radius = 0
        end
    end
    if radius > 0 and zombiesListened == 0 then Events.OnPZToolsZombieSound.Add(onZombieSound) end
    if radius == 0 and zombiesListened > 0 then Events.OnPZToolsZombieSound.Remove(onZombieSound) end
    zombiesListened = radius
end

-- Sets the sound hook by what the character has (called when ranks change); returns whether the shared timer is
-- needed for the senses.
function Senses.refresh()
    local player = getPlayer()
    local u = player and section(player)
    if not u then return false end
    local need = Rules.rank(u, "sixth") > 0 or Rules.rank(u, "sense") > 0 or Rules.rank(u, "alarm") > 0
        or Rules.rank(u, "ledger") > 0
    local wantSound = Rules.rank(u, "sense") > 0
    if wantSound and not soundHooked then
        soundHooked = true
        Events.OnWorldSound.Add(onWorldSound)
    elseif not wantSound and soundHooked then
        soundHooked = false
        Events.OnWorldSound.Remove(onWorldSound)
    end
    listenZombies(wantSound, u)
    if not need then
        S.ring, S.sixth, S.alarms, S.zombies, S.sounds = false, false, {}, {}, {}
        updateSixth()
        showHud(false)
    end
    return need
end

Pulse.job("senses", 500, senseJob)
Pulse.job("alarms", 1000, alarmJob)
Pulse.job("ledger", 500, ledgerJob)

return Senses
