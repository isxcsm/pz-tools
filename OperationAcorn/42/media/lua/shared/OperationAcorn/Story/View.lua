-- What the player sees of a mission and of the supply crates out in the world (DESIGN-terminal 6.6, 8, 9): the colour
-- of a mission, the circle and the dots to it on the map, the zoom that shows the player and the circle together, the
-- pieces a mission left in the world and when one is near enough to be lit. Pure: tables in, tables out, so it is
-- tested outside the game. The client parts that put these on the map (Story/Maps) and on the objects
-- (Story/Highlight) only apply them.
require "OperationAcorn/Core"
local OA = OperationAcorn
local View = {}
OA.StoryView = View

-- The colours (6.6): the regular, contract and special missions are teal (the search ledger's amber outline is its
-- own), a story mission sky blue.
View.TEAL = { 0.30, 0.90, 0.85 }
View.SKY = { 0.55, 0.78, 1.0 }
View.CRATE = { 1.0, 0.62, 0.15 }

function View.color(kind)
    if kind == "story" then return View.SKY end
    return View.TEAL
end

-- The map markers' alphas: a circle is a pale area, a dot and a crate are solid. The second circle (the other copy)
-- is dimmer.
View.CIRCLE_ALPHA, View.DIM = 0.55, 0.6
View.DOT_ALPHA, View.CRATE_ALPHA = 0.85, 0.9

-- Smallest size a marker keeps on the screen, in pixels of radius. The game's own is 64: a dot or a crate would be a
-- large disc, and a circle drawn far out would not be its size.
View.CIRCLE_MIN_PX, View.DOT_MIN_PX, View.CRATE_MIN_PX = 12, 2, 8

-- The mission whose area the map shows: the record's active one, once it is taken (not while it is offered or its
-- field device is being called).
function View.shown(record)
    local m = record and record.missions and record.missions.active
    if not m or m.state == "offer" or m.state == "calling" then return nil end
    return m
end

-- The circles to draw for a mission: { { x =, y =, r =, dim = bool }, ... } (a sealed or finished mission has none).
function View.circles(m)
    local list = {}
    if not m or m.state == "sealed" then return list end
    if m.area then list[#list + 1] = { x = m.area.x, y = m.area.y, r = m.area.r } end
    if m.area2 then list[#list + 1] = { x = m.area2.x, y = m.area2.y, r = m.area2.r, dim = true } end
    return list
end

-- The dots from a player to the edge of a circle (8): COUNT of them, evenly spread, the last short of the edge. Each
-- is { x, y, r } with r in squares, a share of the distance, so that on the screen (the zoom is chosen from the
-- distance) it is about the same size for any mission. None inside the circle.
View.DOT_COUNT, View.DOT_SHARE = 10, 0.006
function View.dots(px, py, circle)
    local list = {}
    if not circle then return list end
    local dx, dy = circle.x - px, circle.y - py
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= circle.r then return list end
    local reach = d - circle.r
    local r = math.max(1, math.floor(View.DOT_SHARE * d + 0.5))
    for i = 1, View.DOT_COUNT do
        local f = (i / (View.DOT_COUNT + 0.5)) * reach / d
        list[i] = { x = math.floor(px + dx * f + 0.5), y = math.floor(py + dy * f + 0.5), r = r }
    end
    return list
end

-- The crates and boxes the helicopter left that are not picked up (record.heli.markers): { { x, y, kind } }.
function View.crates(record)
    local list = {}
    local marks = record and record.heli and record.heli.markers
    for i = 1, marks and #marks or 0 do
        local mark = marks[i]
        if mark.x and mark.y then list[#list + 1] = { x = mark.x, y = mark.y, kind = mark.kind } end
    end
    return list
end

-- Everything a map shows for a record, as markers: { kind = "circle" | "dot" | "crate", x, y, r (squares), color,
-- alpha, minPx }. The player stands at (px, py); the dots and the crates are for the world map only (`world`).
function View.markers(record, px, py, world)
    local list = {}
    local m = View.shown(record)
    local circles = View.circles(m)
    local color = View.color(m and m.kind)
    for _, c in ipairs(circles) do
        list[#list + 1] = { kind = "circle", x = math.floor(c.x), y = math.floor(c.y), r = math.floor(c.r), color = color,
            alpha = c.dim and View.CIRCLE_ALPHA * View.DIM or View.CIRCLE_ALPHA, minPx = View.CIRCLE_MIN_PX }
    end
    if not world then return list end
    if px and py then
        for _, d in ipairs(View.dots(px, py, circles[1])) do
            list[#list + 1] = { kind = "dot", x = d.x, y = d.y, r = d.r, color = color, alpha = View.DOT_ALPHA,
                minPx = View.DOT_MIN_PX }
        end
    end
    for _, c in ipairs(View.crates(record)) do
        list[#list + 1] = { kind = "crate", x = math.floor(c.x), y = math.floor(c.y), r = 1, color = View.CRATE,
            alpha = View.CRATE_ALPHA, minPx = View.CRATE_MIN_PX }
    end
    return list
end

-- A text that is the same for the same markers: the map is not touched again when nothing changed.
function View.signature(list)
    local parts = {}
    for i, k in ipairs(list) do
        parts[i] = k.kind .. k.x .. "," .. k.y .. "," .. k.r .. "," .. k.color[1] .. k.color[2] .. k.color[3] .. "," .. k.alpha
    end
    return table.concat(parts, ";")
end

-- The zoom the map takes to show the player and the circle together (8): the largest at which both, the circle to its
-- radius, are inside a margin of the screen's edge, centred on the midpoint of the two. The game's zoom is a level
-- (each one doubles the scale); the scale in pixels a square is 2^zoom * height / 40075016.69 for a map `height` high
-- (the game's MapProjection.metersPerPixelAtZoom). `view` = { width, height, margin, minZoom, maxZoom, isometric }:
-- the isometric view turns the map, so the extent is taken by the larger bound it can have. Returns x, y, zoom.
View.EARTH = 40075016.685578
function View.fit(px, py, circle, view)
    local cx, cy = (px + circle.x) / 2, (py + circle.y) / 2
    local ax, ay = math.abs(circle.x - px) / 2, math.abs(circle.y - py) / 2
    local halfX, halfY = ax + circle.r, ay + circle.r
    if view.isometric then
        halfX = ax + ay + circle.r * 1.4143
        halfY = halfX
    end
    local scale = math.min((view.width / 2 - view.margin) / halfX, (view.height / 2 - view.margin) / halfY)
    local zoom = math.log(scale * View.EARTH / view.height) / math.log(2)
    zoom = math.floor(zoom * 100) / 100
    return cx, cy, OA.clamp(zoom, view.minZoom, view.maxZoom)
end

-- What a mission left in the world (9) --------------------------------------------------------------------------------

-- The distance, in squares, within which a mission's container is lit, and how often it is looked at (real time).
View.RANGE, View.EVERY_MS = 6, 500

-- Whether a mission piece lies in the world where this mod put it (a container's square, or the floor), to be lit: it
-- is placed, was given a square, and is a piece of the mission (the key to a locked room is plain).
function View.isLit(it)
    return it.placed == true and it.at ~= nil and not it.plain
end

-- Whether a square is near enough: the same floor and within RANGE squares of the player (squares' centres).
function View.near(px, py, pz, at)
    if at.z ~= math.floor(pz) then return false end
    local dx, dy = at.x + 0.5 - px, at.y + 0.5 - py
    return dx * dx + dy * dy <= View.RANGE * View.RANGE
end

-- Whether an item's OA_Mission names this mission (the id, or the id and a piece after "#"). A tooltip asks every
-- frame: the prefix is made once for a mission, and nothing is made to compare.
local prefixOf, prefix = nil, nil
function View.owns(m, id)
    if not m or type(id) ~= "string" then return false end
    local mine = m.id
    if id == mine then return true end
    if prefixOf ~= mine then prefixOf, prefix = mine, mine .. "#" end
    return string.find(id, prefix, 1, true) == 1
end

return View
