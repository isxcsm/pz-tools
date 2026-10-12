-- What this mod draws on the maps (DESIGN-terminal 6.6, 8): the mission's area as a soft disc in a ring of dashes that
-- slowly march round it (teal; a story mission's sky blue) with a pulse running out of it, a pin dropped on its middle,
-- the way from the player to it as thick dashes marching toward it, the player's own pin, and the supply crates left
-- by the helicopter; once a piece is found, a pin where its item is instead of the circle (on the player while the
-- player carries it); and the world map opened to show the player and the circle together. The minimap shows less of
-- it, smaller: the disc, the ring, the way and the pin, still.
-- It is drawn by this mod over the game's map every frame a map is open: after the world map's own prerender (above
-- the map, its symbols and its darkening; below the map's panels and buttons, which are its children), and after the
-- minimap's, clipped to the minimap. Each place (the player, a circle's middle, a crate) is put where the map puts
-- it; a circle of the world is drawn as the map shows it (on the isometric view an ellipse): the map's view is a flat
-- projection, so the screen steps of one square east and one south shape it. Sizes are screen pixels at the UI scale,
-- whatever the zoom.
-- What there is to draw is worked out by Story/View (pure) when a map opens and when the mission or the crates change;
-- the dashes and the timing by Story/MapFx (pure). Each frame only places it: nothing is made, and with no map open or
-- nothing to show nothing runs.
require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/View"
require "OperationAcorn/Story/MapFx"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local View, Fx = OA.StoryView, OA.StoryMapFx
local Maps = {}
OA.StoryMaps = Maps

-- The margin kept from the screen's edge when the world map is fitted to the player and the circle, in pixels.
Maps.MARGIN = 96
local MAX_ZOOM = 24

-- The look (pixels at the UI scale 1; tools/map_art.py draws the pictures at twice these and repeats these numbers for
-- its mockups). The world map's, and the minimap's: smaller, no pulse, still pins, no crates or player's pin (the
-- minimap is centred on the player). A ring's dashes and the way's: length, gap, thickness and how fast they march
-- (pixels a second). The way starts a little off the player's pin. A circle less than min_r pixels in radius on the
-- screen is drawn that big. The fill's strength. `shape`: where a circle keeps its ring's shape for this map.
local WORLD = { ring_dash = 14, ring_gap = 9, ring_thick = 6, ring_speed = 10, path_dash = 20, path_gap = 12,
    path_thick = 8, path_speed = 34, path_start = 10, fill_a = 0.30, min_r = 12, pin_w = 32, pin_h = 44,
    pulse = true, anim = true, crates = true, me = true, shape = "worldShape" }
local MINI = { ring_dash = 10, ring_gap = 7, ring_thick = 4.5, ring_speed = 10, path_dash = 14, path_gap = 9,
    path_thick = 6, path_speed = 28, path_start = 4, fill_a = 0.30, min_r = 8, pin_w = 22, pin_h = 30,
    pulse = false, anim = false, crates = false, me = false, shape = "miniShape" }
-- A swap mission's second circle: its fill and ring this much as strong, with no pulse and no pin.
local DIM_FILL, DIM_RING = 0.55, 0.5
-- The pulse: a soft ring growing from PULSE_FROM to PULSE_TO of the circle and fading, every PULSE_MS. Its picture's
-- ring runs at PULSE_RING of the picture's half size.
local PULSE_MS, PULSE_FROM, PULSE_TO, PULSE_A, PULSE_RING = 2600, 0.96, 1.32, 0.75, 0.92
-- The destination pin drops in when the world map opens (DROP_H high, bouncing, over DROP_MS; a second pin a little
-- later), then bobs BOB_H up and down every BOB_MS, and each time it lands a ripple runs out from its tip.
local DROP_MS, DROP_H, DROP_STAGGER, DROP_FADE = 650, 48, 90, 120
local BOB_MS, BOB_H = 1700, 3.5
local TIP_FROM, TIP_TO, TIP_A = 3, 22, 1.0
-- The player's pin breathes: two ripples by turns run out from where the player stands, and the pin swells a little
-- as each one starts.
local ME_MS, ME_FROM, ME_TO, ME_A, ME_POP = 2200, 4, 26, 0.9, 0.08
local ME_W, ME_H = 26, 33
local CRATE_W = 20
-- The soft shadow under a pin, on the map (smaller and fainter while the pin is up).
local SHADOW_R, SHADOW_A = 8, 0.38
-- Where the tip of each pin is in its picture, up from the bottom, of the picture's height (tools/map_art.py).
local PIN_TIP, ME_TIP = 0.8 / 88, 0.8 / 66
local WHITE = { 1, 1, 1 }

-- The pictures (media/textures/OA_Map_*.png), loaded when first drawn.
local pictures = {}
local function picture(name)
    local t = pictures[name]
    if t == nil then
        t = getTexture("media/textures/" .. name .. ".png") or false
        pictures[name] = t
    end
    return t or nil
end
local DASH, FILL, PULSE, RIPPLE, SHADOW = "OA_Map_Dash", "OA_Map_Fill", "OA_Map_Pulse", "OA_Map_Ripple",
    "OA_Map_Shadow"
local PIN, PIN_DOT, ME, ME_GLYPH, CRATE = "OA_Map_Pin", "OA_Map_PinDot", "OA_Map_Me", "OA_Map_MeGlyph",
    "OA_Map_Crate"

-- What each player's maps show (View.scene), by the player's number.
local scenes = {}
-- When the world map was last shown to each player (ms since this file loaded): the pins drop in from then.
local shownAt = {}
-- The time animations count from: getTimestampMs is too large for Kahlua's % (MapFx.phase uses math.fmod on the
-- difference).
local BASE = getTimestampMs()

-- Where a found piece's item is now, in a game that has the items (single player: the missions' Game); elsewhere the
-- place the mission last kept.
local function whereNow()
    local game = OA.Missions and OA.Missions.game
    return game and game.whereNow or nil
end

-- Worked out again for a player: when a map opens, and when the mission or the crates change.
function Maps.rebuild(playerNum)
    local character = getSpecificPlayer(playerNum)
    scenes[playerNum] = character and View.scene(OA.Client.record(character), whereNow()) or nil
end

function Maps.refresh()
    for playerNum = 0, getNumActivePlayers() - 1 do Maps.rebuild(playerNum) end
end

-- Drawing (every frame a map is open) --------------------------------------------------------------------------------

-- The frame being drawn, kept in locals (nothing is made per frame): the map's API, the element's java object and its
-- place on the screen, the player's place in the world and on the element, and the screen steps of one square east
-- (ex) and one south (ey). `hs` is how many pixels a square is across the screen (on both views), `unit` its inverse.
local api, ui, absX, absY
local px, py, ox, oy, exX, exY, eyX, eyY, hs, unit
local viewW, viewH
-- The dashes worked out for a frame (MapFx writes into them).
local MAX_DASHES = 512
local dashes = {}

-- Where the world point (wx, wy) is on the element, as the map puts it.
local function screen(wx, wy)
    return api:worldToUIX(wx, wy), api:worldToUIY(wx, wy)
end

-- The map's view: where the player is, and the steps of a square east and south (measured over STEP squares from
-- whole squares near the player: the game takes the points in single precision, which holds whole numbers exactly).
-- False when the map has no data to place things on (the game then answers 0 for every point).
local STEP = 256
local function measure(character)
    px, py = character:getX(), character:getY()
    ox, oy = screen(px, py)
    local wx, wy = math.floor(px), math.floor(py)
    local x0, y0 = screen(wx, wy)
    exX = (api:worldToUIX(wx + STEP, wy) - x0) / STEP
    exY = (api:worldToUIY(wx + STEP, wy) - y0) / STEP
    eyX = (api:worldToUIX(wx, wy + STEP) - x0) / STEP
    eyY = (api:worldToUIY(wx, wy + STEP) - y0) / STEP
    hs = math.sqrt(exX * exX + eyX * eyX)
    if hs < 1e-6 then return false end
    unit = 1 / hs
    return true
end

-- A picture on the parallelogram with these corners (on the element): top left, top right, bottom right, bottom left.
-- UIElement.DrawTexture takes the screen's coordinates, as fractions (a moving thing does not jump pixel to pixel).
local function quad(name, x1, y1, x2, y2, x3, y3, x4, y4, c, a)
    local tex = picture(name)
    if not tex or a <= 0.003 then return end
    ui:DrawTexture(tex, absX + x1, absY + y1, absX + x2, absY + y2, absX + x3, absY + y3, absX + x4, absY + y4,
        c[1], c[2], c[3], a)
end

-- A picture laid flat on the map around (cx, cy): rx by ry pixels across its half-axes as the map's view turns and
-- squashes it (an ellipse on the isometric view), the size taken across the screen.
local function flat(name, cx, cy, rx, ry, c, a)
    local ax, ay = exX * unit * rx, exY * unit * rx
    local bx, by = eyX * unit * ry, eyY * unit * ry
    quad(name, cx - ax - bx, cy - ay - by, cx + ax - bx, cy + ay - by, cx + ax + bx, cy + ay + by,
        cx - ax + bx, cy - ay + by, c, a)
end

-- A picture standing upright, w by h, its bottom middle at (x, y).
local function upright(name, x, y, w, h, c, a)
    local l = x - w / 2
    quad(name, l, y - h, l + w, y - h, l + w, y, l, y, c, a)
end

-- One dash from (x1, y1) to (x2, y2), `thick` pixels thick.
local function dash(x1, y1, x2, y2, thick, c, a)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.01 then return end
    local nx, ny = -dy / len * thick / 2, dx / len * thick / 2
    quad(DASH, x1 - nx, y1 - ny, x2 - nx, y2 - ny, x2 + nx, y2 + ny, x1 + nx, y1 + ny, c, a)
end

-- Each circle's place this frame, set on it by place(): its middle on the element (sx, sy), its radius as drawn in
-- squares (dr: at least min_r pixels on the screen), and whether any of it is in the view (seen).
local function place(circle, style, s)
    circle.sx, circle.sy = screen(circle.x, circle.y)
    local least = style.min_r * s / hs
    local r = circle.r < least and least or circle.r
    circle.dr = r
    local wx = (math.abs(exX) + math.abs(eyX)) * r
    local wy = (math.abs(exY) + math.abs(eyY)) * r
    local cx, cy = circle.sx, circle.sy
    circle.seen = cx + wx >= 0 and cx - wx <= viewW and cy + wy >= 0 and cy - wy <= viewH
end

-- The dashes of a ring or a way (the first `count` of `dashes`, four numbers each) in one colour, `thick` pixels thick.
-- With the extension API's quads call they go as one list of quads and one call (a ring has dozens, drawn every frame
-- on each map open); an API without it, or one whose call failed (said once, and not tried again), has them drawn one
-- by one.
local dashQuads = {}
local quadsFailed = false
local function drawDashes(count, thick, c, a)
    if count == 0 then return end
    local draw = not quadsFailed and OA.drawCall("quads") or nil
    local tex = draw and picture(DASH)
    if tex and a > 0.003 then
        local list, k = dashQuads, 0
        local r, g, b = c[1], c[2], c[3]
        local half = thick / 2
        for i = 1, count do
            local o = i * 4
            local x1, y1, x2, y2 = dashes[o - 3], dashes[o - 2], dashes[o - 1], dashes[o]
            local dx, dy = x2 - x1, y2 - y1
            local len = math.sqrt(dx * dx + dy * dy)
            if len >= 0.01 then
                local nx, ny = -dy / len * half, dx / len * half
                local at = k * 12
                list[at + 1], list[at + 2] = absX + x1 - nx, absY + y1 - ny
                list[at + 3], list[at + 4] = absX + x2 - nx, absY + y2 - ny
                list[at + 5], list[at + 6] = absX + x2 + nx, absY + y2 + ny
                list[at + 7], list[at + 8] = absX + x1 + nx, absY + y1 + ny
                list[at + 9], list[at + 10], list[at + 11], list[at + 12] = r, g, b, a
                k = k + 1
            end
        end
        if k == 0 then return end
        local ok, err = pcall(draw, ui, tex, list, k)
        if ok then return end
        quadsFailed = true
        OA.log("map dashes: the API's quads failed, drawn one by one:", tostring(err))
    end
    for i = 1, count do
        local o = i * 4
        dash(dashes[o - 3], dashes[o - 2], dashes[o - 1], dashes[o], thick, c, a)
    end
end

-- A circle's soft fill and its pulse.
local function drawFill(circle, style, now)
    if not circle.seen then return end
    local cx, cy, r = circle.sx, circle.sy, circle.dr
    local ax, ay, bx, by = exX * r, exY * r, eyX * r, eyY * r
    local c = circle.color
    quad(FILL, cx - ax - bx, cy - ay - by, cx + ax - bx, cy + ay - by, cx + ax + bx, cy + ay + by, cx - ax + bx,
        cy - ay + by, c, style.fill_a * (circle.dim and DIM_FILL or 1))
    if not style.pulse or circle.dim then return end
    local f = Fx.phase(now, PULSE_MS)
    local k = (PULSE_FROM + (PULSE_TO - PULSE_FROM) * Fx.easeOut(f)) / PULSE_RING
    ax, ay, bx, by = ax * k, ay * k, bx * k, by * k
    quad(PULSE, cx - ax - bx, cy - ay - by, cx + ax - bx, cy + ay - by, cx + ax + bx, cy + ay + by, cx - ax + bx,
        cy - ay + by, c, PULSE_A * (1 - f) * (1 - f))
end

-- A circle's ring of marching dashes. Its shape is kept on the circle, one for each style (the world map and the
-- minimap are drawn in the same frame at their own zooms), made again when that map zooms or turns.
local function drawRing(circle, style, s, now)
    if not circle.seen then return end
    local r = circle.dr
    local ax, ay, bx, by = exX * r, exY * r, eyX * r, eyY * r
    local shape = circle[style.shape]
    if not shape then
        shape = {}
        circle[style.shape] = shape
    end
    Fx.shape(shape, ax, ay, bx, by)
    local thick = style.ring_thick * s
    local count = Fx.ringDashes(shape, circle.sx, circle.sy, style.ring_dash * s, style.ring_gap * s,
        now * style.ring_speed * s / 1000, 0, 0, viewW, viewH, thick, dashes, MAX_DASHES)
    drawDashes(count, thick, circle.color, circle.dim and DIM_RING or 1)
end

-- The way from the player to the edge of the circle it leads to, marching toward it.
local function drawPath(circle, style, s, now)
    local wx, wy = Fx.edge(px, py, circle.x, circle.y, circle.dr)
    if not wx then return end
    wx, wy = wx - circle.x, wy - circle.y
    local ex, ey = circle.sx + wx * exX + wy * eyX, circle.sy + wx * exY + wy * eyY
    local dx, dy = ex - ox, ey - oy
    local len = math.sqrt(dx * dx + dy * dy)
    local start = style.path_start * s
    if len <= start then return end
    local sx, sy = ox + dx / len * start, oy + dy / len * start
    local count = Fx.lineDashes(sx, sy, ex, ey, style.path_dash * s, style.path_gap * s,
        now * style.path_speed * s / 1000, 0, 0, viewW, viewH, dashes, MAX_DASHES)
    drawDashes(count, style.path_thick * s, circle.color, 1)
end

local function drawCrates(scene, s)
    local w = CRATE_W * s
    for i = 1, #scene.crates do
        local crate = scene.crates[i]
        local x, y = screen(crate.x, crate.y)
        if x > -w and x < viewW + w and y > -w and y < viewH + w then
            flat(SHADOW, x, y + s, 9 * s, 9 * s, WHITE, 0.3)
            quad(CRATE, x - w / 2, y - w / 2, x + w / 2, y - w / 2, x + w / 2, y + w / 2, x - w / 2, y + w / 2,
                View.MAP_CRATE, 1)
        end
    end
end

-- A destination pin on the middle of a circle: the `index`th (they drop one after another). `since` is how long the
-- world map has been open (nil: still, as on the minimap).
local function drawPin(circle, index, style, s, since)
    local cx, cy = circle.sx, circle.sy
    local w, h = style.pin_w * s, style.pin_h * s
    if cx < -w or cx > viewW + w or cy < -s * DROP_H or cy > viewH + h then return end
    local up, a, tip = 0, 1, nil
    if since then
        local t = since - (index - 1) * DROP_STAGGER
        if t < DROP_MS then
            if t < 0 then t = 0 end
            up = DROP_H * s * (1 - Fx.bounce(t / DROP_MS))
            a = math.min(1, t / DROP_FADE)
        else
            tip = Fx.phase(t - DROP_MS, BOB_MS)
            up = BOB_H * s * Fx.wave(tip)
        end
    end
    local high = up / (DROP_H * s)
    local shadow = SHADOW_R * s * (1 - 0.35 * high)
    flat(SHADOW, cx, cy, shadow, shadow, WHITE, SHADOW_A * (1 - 0.5 * high) * a)
    if tip then
        local rr = (TIP_FROM + (TIP_TO - TIP_FROM) * Fx.easeOut(tip)) * s
        flat(RIPPLE, cx, cy, rr, rr, circle.color, TIP_A * (1 - tip) ^ 1.6)
    end
    local bottom = cy - up + h * PIN_TIP
    upright(PIN, cx, bottom, w, h, circle.color, a)
    upright(PIN_DOT, cx, bottom, w, h, WHITE, a)
end

-- The player's pin, at (ox, oy).
local function drawMe(s, now)
    for i = 0, 1 do
        local f = Fx.phase(now + i * ME_MS / 2, ME_MS)
        local rr = (ME_FROM + (ME_TO - ME_FROM) * Fx.easeOut(f)) * s
        flat(RIPPLE, ox, oy, rr, rr, View.MAP_ME, ME_A * (1 - f) ^ 1.8)
    end
    flat(SHADOW, ox, oy, 6 * s, 6 * s, WHITE, SHADOW_A)
    local k = 1 + ME_POP * (1 - Fx.phase(now, ME_MS)) ^ 4
    local w, h = ME_W * s * k, ME_H * s * k
    local bottom = oy + h * ME_TIP
    upright(ME, ox, bottom, w, h, View.MAP_ME, 1)
    upright(ME_GLYPH, ox, bottom, w, h, WHITE, 1)
end

-- Everything of a scene over a map element `el` (its mapAPI), for `character`, in a style. `since`: how long the world
-- map has been open (the pins drop in), nil on the minimap.
local function draw(el, scene, character, style, since)
    api = el.mapAPI
    if not measure(character) then return end
    ui = el.javaObject
    absX, absY = el:getAbsoluteX(), el:getAbsoluteY()
    viewW, viewH = el.width, el.height
    local UI = OA.Trade.UI
    local s = UI and UI.S or 1
    local now = getTimestampMs() - BASE
    local circles, points = scene.circles, scene.points
    for i = 1, #circles do place(circles[i], style, s) end
    -- A piece the player carries is where the player is, this frame.
    local carried = false
    for i = 1, #points do
        local point = points[i]
        if point.carried then
            point.x, point.y = px, py
            carried = true
        end
        place(point, style, s)
    end
    for i = 1, #circles do drawFill(circles[i], style, now) end
    for i = 1, #circles do drawRing(circles[i], style, s, now) end
    if scene.lead then drawPath(scene.lead, style, s, now) end
    if style.crates then drawCrates(scene, s) end
    local index = 0
    for i = 1, #circles do
        local circle = circles[i]
        if not circle.dim then
            index = index + 1
            drawPin(circle, index, style, s, since)
        end
    end
    -- The pieces' pins; the one the player carries stands in for the player's own pin.
    for i = 1, #points do
        index = index + 1
        drawPin(points[i], index, style, s, since)
    end
    if style.me and not carried and (#circles > 0 or #points > 0) then drawMe(s, now) end
end

-- After the world map's prerender (which draws over the map: its print media, stash maps and darkening).
local worldPrerender = ISWorldMap.prerender
function ISWorldMap:prerender()
    worldPrerender(self)
    local playerNum = self.playerNum or 0
    local scene = scenes[playerNum]
    if not scene or scene.empty or not self.mapAPI then return end
    local character = getSpecificPlayer(playerNum)
    if not character then return end
    draw(self, scene, character, WORLD, getTimestampMs() - BASE - (shownAt[playerNum] or -1e9))
end

-- After the minimap's prerender, clipped to it (the game's own clip of the minimap ends before its prerender). A
-- failure is told once and the clip is taken off whatever happens: left on, it would hide the rest of the screen.
local miniPrerender = ISMiniMapInner.prerender
local miniFailed = false
function ISMiniMapInner:prerender()
    miniPrerender(self)
    local playerNum = self.playerNum or 0
    local scene = scenes[playerNum]
    if not scene or scene.empty or not self.mapAPI then return end
    local character = getSpecificPlayer(playerNum)
    if not character then return end
    self:setStencilRect(0, 0, self.width, self.height)
    local ok, err = pcall(draw, self, scene, character, MINI, nil)
    -- taken back fully: inside another clip the game leaves it a level up (Trade.UI.unclip)
    self:clearStencilRect()
    self:repaintStencilRect(0, 0, self.width, self.height)
    if not ok and not miniFailed then
        miniFailed = true
        OA.log("minimap overlay failed:", tostring(err))
    end
end

-- Opening the world map to show the player and the mission's circle (8) ---------------------------------------------

-- The map's size, its smallest zoom and its view setting, as the open map has them (or as it will open).
local function viewOf()
    local map = ISWorldMap_instance
    local api = map and map.mapAPI
    return {
        width = map and map:getWidth() or getCore():getScreenWidth(),
        height = map and map:getHeight() or getCore():getScreenHeight(),
        margin = Maps.MARGIN,
        minZoom = api and api:getBaseZoom() or 12,
        maxZoom = MAX_ZOOM,
        -- The map's own view setting is read as it opens; the isometric bound is the safe one until it is known.
        isometric = api == nil or api:getBoolean("Isometric"),
    }
end

-- The area of FOUND_R squares round a found piece's item that the world map is fitted to.
local FOUND_R = 30

-- Opens the world map centred between the character and the circle of its mission (the special request's when `which`
-- is "special"), or the place of a piece found, at the zoom that shows both.
function Maps.show(character, which)
    local record = OA.Client.record(character)
    local m = which == "special" and View.shownSpecial(record) or View.shown(record)
    local px, py = character:getX(), character:getY()
    local circle = View.circles(m)[1]
    if not circle then
        local point = View.points(record, m, whereNow())[1]
        if point then
            if point.carried then point.x, point.y = px, py end
            circle = { x = point.x + 0.5, y = point.y + 0.5, r = FOUND_R }
        end
    end
    if not circle or not (ISWorldMap and ISWorldMap.ShowWorldMap) then return end
    local cx, cy, zoom = View.fit(px, py, circle, viewOf())
    ISWorldMap.ShowWorldMap(character:getPlayerNum(), cx, cy, zoom)
    -- What the map has now (its saved view setting is applied as it opens): fitted again when that changes the zoom.
    local map = ISWorldMap_instance
    if not (map and map.mapAPI) then return end
    local _, _, again = View.fit(px, py, circle, viewOf())
    if math.abs(again - zoom) > 0.005 then
        map.mapAPI:centerOn(cx, cy)
        map.mapAPI:setZoom(again)
    end
end

-- Hooks: the world map when it is shown (its pins drop in), the minimap when it is built.
local showWorldMap = ISWorldMap.ShowWorldMap
ISWorldMap.ShowWorldMap = function(playerNum, ...)
    showWorldMap(playerNum, ...)
    Maps.rebuild(playerNum)
    shownAt[playerNum] = getTimestampMs() - BASE
end

local instantiate = ISMiniMapInner.instantiate
ISMiniMapInner.instantiate = function(self, ...)
    instantiate(self, ...)
    Maps.rebuild(self.playerNum or 0)
end

OA.Sync.listen("missions", function() Maps.refresh() end)
OA.Sync.listen("trade", function() Maps.refresh() end)
OA.Sync.listen("all", function() Maps.refresh() end)
Events.OnCreatePlayer.Add(function() Maps.refresh() end)

return Maps
