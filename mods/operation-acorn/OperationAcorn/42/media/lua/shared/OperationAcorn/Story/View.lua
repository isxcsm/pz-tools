-- What the player sees of a mission and of the supply crates out in the world (DESIGN-terminal 6.6, 8, 9): the colour
-- of a mission, what the maps show of it (its circle, the way to it, the crates), the zoom that shows the player and
-- the circle together, the pieces a mission left in the world and when one is near enough to be lit. Pure: tables in,
-- tables out, so it is tested outside the game. The client parts that draw these on the maps (Story/Maps, with the
-- geometry of Story/MapFx) and on the objects (Story/Highlight) only apply them.
require "OperationAcorn/Core"
local OA = OperationAcorn
local View = {}
OA.StoryView = View

-- The colours (6.6): the regular, contract and special missions are teal (the search ledger's amber outline is its
-- own), a story mission sky blue. They light objects and names in the world and in the loot window.
View.TEAL = { 0.30, 0.90, 0.85 }
View.SKY = { 0.55, 0.78, 1.0 }

function View.color(kind)
    if kind == "story" then return View.SKY end
    return View.TEAL
end

-- The same two on the maps, deeper and more saturated: drawn over the pale paper map (and its darker styles) with a
-- dark outline, the pale ones above washed out on it. The crates are orange, the player's own pin coral (near the
-- game's red player dot, apart from both mission colours and the crates).
View.MAP_TEAL = { 0.08, 0.84, 0.76 }
View.MAP_SKY = { 0.30, 0.62, 1.0 }
View.MAP_CRATE = { 1.0, 0.58, 0.12 }
View.MAP_ME = { 1.0, 0.36, 0.38 }
-- A drop site's survey zone (Story/Survey): the capstones' gold.
View.MAP_SURVEY = { 0.92, 0.74, 0.26 }
-- A dense place's circle (Story/Dense), by the weapon kit it gives: crimson for the damage kit, magenta for the
-- critical kit, lime for the repair kit; none is near the missions' teal and sky blue, the crates' orange or the survey zone's
-- gold.
View.MAP_DENSE = { damage = { 0.82, 0.18, 0.24 }, crit = { 0.86, 0.30, 0.80 }, repair = { 0.62, 0.84, 0.22 } }

function View.mapColor(kind)
    if kind == "story" then return View.MAP_SKY end
    return View.MAP_TEAL
end

-- Whether a mission is taken: not one waiting for the player to start it, nor one whose briefing call is playing.
function View.taken(m)
    return m ~= nil and m.state ~= "waiting" and m.state ~= "briefing"
end

-- The mission whose area the map shows: the record's active one, once it is taken (not while its field device is being
-- called).
function View.shown(record)
    local m = record and record.missions and record.missions.active
    if not View.taken(m) or m.state == "calling" then return nil end
    return m
end

-- The special request running beside it (DESIGN-terminal 6.3), shown on the same terms.
function View.shownSpecial(record)
    local m = record and record.missions and record.missions.special and record.missions.special.mission
    if not m or m.state == "calling" then return nil end
    return m
end

-- Every mission whose area is shown: the main one, then the special request.
function View.shownList(record)
    local list = {}
    local main, special = View.shown(record), View.shownSpecial(record)
    if main then list[#list + 1] = main end
    if special then list[#list + 1] = special end
    return list
end

-- The missions running, shown or not (an item's tooltip tells it is a mission item whatever the mission's state).
function View.live(record)
    local list = {}
    local missions = record and record.missions
    if missions and View.taken(missions.active) then list[#list + 1] = missions.active end
    if missions and missions.special and missions.special.mission then list[#list + 1] = missions.special.mission end
    return list
end

-- Whether a piece is one the player fetches (the map's circle goes once each of these is found): not a plain one (the
-- key of a locked room) and not the case a swap is left in.
function View.fetched(m, it)
    if it.plain then return false end
    if m.swap and it.key == "CASE" then return false end
    return true
end

-- Whether every piece the player fetches is found (false for a mission with none yet: a swap before its record).
function View.allFound(m)
    local any = false
    for _, it in ipairs(m.items or {}) do
        if View.fetched(m, it) then
            if not it.found then return false end
            any = true
        end
    end
    return any
end

-- The circles to draw for a mission: { { x =, y =, r =, dim = bool }, ... } (a sealed or finished mission has none).
-- A circle goes once what it is for is found, and the maps show the item instead (View.points): a second circle (two
-- buildings compared) is the second piece's, the first is the first piece's then, else every piece's. A field mission
-- keeps its circle: the call is made in it; so does a zombie mission: its group is there.
function View.circles(m)
    local list = {}
    if not m or m.state == "sealed" then return list end
    local keep = m.field ~= nil or m.zombies ~= nil
    local items = m.items or {}
    local first
    if m.area2 then first = items[1] and items[1].found else first = View.allFound(m) end
    if m.area and (keep or not first) then list[#list + 1] = { x = m.area.x, y = m.area.y, r = m.area.r } end
    if m.area2 and (keep or not (items[2] and items[2].found)) then
        list[#list + 1] = { x = m.area2.x, y = m.area2.y, r = m.area2.r, dim = true }
    end
    return list
end

-- Where the found pieces of a mission are: { { x =, y =, z =, carried = bool }, ... } (a sealed mission has none). `where`
-- (optional; Game.whereNow in a game that has the items) tells it now; else the place the mission last kept.
function View.points(record, m, where)
    local list = {}
    if not m or m.state == "sealed" then return list end
    for _, it in ipairs(m.items or {}) do
        if it.found and View.fetched(m, it) then
            local x, y, z, carried
            if where then x, y, z, carried = where(record, m, it) end
            if not x and it.where then x, y, z, carried = it.where.x, it.where.y, it.where.z, it.where.carried end
            if x then list[#list + 1] = { x = x, y = y, z = z, carried = carried == true } end
        end
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

-- What the maps show for a record (8): the circles of the missions shown, each { x, y, r, color, dim } (the second
-- circle of a swap mission dim, a drop site's survey zone, Story/Survey, dim in gold, and the dense places not yet cleared,
-- Story/Dense, dim in the colour of the kit they give), the circle the way from the player leads to (`lead`: the main mission's first one,
-- else the special request's), the crates left ({ x, y }), and whether there is nothing (`empty`: the maps draw
-- nothing then). Places are the middles of their squares. Worked out when a map opens and when the mission or the
-- crates change; the maps draw it every frame (the way from where the player stands then).
function View.scene(record, where)
    local scene = { circles = {}, crates = {}, points = {} }
    for _, m in ipairs(View.shownList(record)) do
        local color = View.mapColor(m.kind)
        for _, c in ipairs(View.circles(m)) do
            local circle = { x = c.x + 0.5, y = c.y + 0.5, r = c.r, color = color, dim = c.dim == true }
            scene.circles[#scene.circles + 1] = circle
            if not scene.lead and not circle.dim then scene.lead = circle end
        end
        local carried = false
        for _, p in ipairs(View.points(record, m, where)) do
            -- What the player carries is one pin on the player, however many pieces.
            if not (p.carried and carried) then
                carried = carried or p.carried
                scene.points[#scene.points + 1] = { x = p.x + 0.5, y = p.y + 0.5, r = 0, color = color, carried = p.carried }
            end
        end
    end
    -- With no circle to go to, the way leads to the first piece the player does not carry.
    if not scene.lead then
        for _, p in ipairs(scene.points) do
            if not p.carried then scene.lead = p; break end
        end
    end
    for _, c in ipairs(View.crates(record)) do
        scene.crates[#scene.crates + 1] = { x = c.x + 0.5, y = c.y + 0.5 }
    end
    for _, z in ipairs(OA.StorySurvey and OA.StorySurvey.zones(record) or {}) do
        scene.circles[#scene.circles + 1] = { x = z.x + 0.5, y = z.y + 0.5, r = z.r, color = View.MAP_SURVEY, dim = true }
    end
    for _, d in ipairs(OA.Dense and OA.Dense.shown(record) or {}) do
        scene.circles[#scene.circles + 1] = { x = d.x + 0.5, y = d.y + 0.5, r = d.r, color = View.MAP_DENSE[d.kind],
            dim = true }
    end
    scene.empty = #scene.circles == 0 and #scene.crates == 0 and #scene.points == 0
    return scene
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
-- frame, for each mission running: the prefix is made once for a mission, and nothing is made to compare.
local prefixes, prefixCount = {}, 0
function View.owns(m, id)
    if not m or type(id) ~= "string" then return false end
    local mine = m.id
    if id == mine then return true end
    local prefix = prefixes[mine]
    if not prefix then
        if prefixCount >= 8 then prefixes, prefixCount = {}, 0 end
        prefix = mine .. "#"
        prefixes[mine] = prefix
        prefixCount = prefixCount + 1
    end
    return string.find(id, prefix, 1, true) == 1
end

-- The running mission an item's OA_Mission belongs to (the main one, or the special request), or nil. Nothing is made.
function View.ownerOf(record, id)
    local missions = record and record.missions
    if not missions or type(id) ~= "string" then return nil end
    if View.taken(missions.active) and View.owns(missions.active, id) then return missions.active end
    local special = missions.special and missions.special.mission
    if View.owns(special, id) then return special end
    return nil
end

return View
