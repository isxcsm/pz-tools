-- A story site's stage (SCENES.md 5): what the authorities set up in the building they took for a facility, and what was
-- left of it. The pieces of each facility are data (Story/StageData); this part decides where they go and when, and the
-- world's hands (`Stage.game`, Story/StageGame) put them there. Tests give the hands fakes.
--
-- Which: the stage of a story mission is its story's (a choice's by its option, `<story>_<option>`; a revisit's the
-- stage of the story whose site it goes back to), when the site is the kind the stage is for (a building, or open
-- ground for a stage with `ground`).
--
-- When: a story mission whose site has a stage gets one as it begins (m.stage). The building is set up
-- once it is all loaded (BuildingDef.isFullyStreamedIn), or once the player is READY near when it is too large to be
-- loaded whole (what is not loaded then is left out): the things, the locks, the bodies, the
-- mission's own item. Its zombies come once the player is READY near, made away from the player as the mission scene's
-- keepers are (Story/Scene). A building is set up once in a world (Store.world "stages"): a later mission there (a
-- revisit) only puts its item. A piece that cannot be put (no room of its kind, its square taken) is left out.
-- Open ground is set up the same way once the squares round the site are loaded.
--
-- Afterwards: what waits for an event (Stage.event: "pickup", "heli") wakes then, all at once or one after another
-- (`stagger` seconds apart); what is spread over a span (Stage.progress: "wait", the swap's wait from 0 to 1) wakes
-- one by one across it (`during`), and a door boarded with `drop` loses a plank at that point of it.
--
-- Where: the hands read the building's layout as it loads: its rooms ({ name, area, z, x, y, x2, y2, edge = touches the
-- building's outline }) and its outer doors and windows on the ground floor. The rooms get roles (Stage.roles): "big"
-- (the largest on the ground floor), "inner" (one inside, away from the outline), "other" (another), "hall" (a hall or
-- corridor, or another one), none of them but the big one smaller than ROOM_AREA; "entrance" is the outer door nearest
-- the big room, "back" the one farthest from it. A piece names the role it goes to (`at`); "yard" is the ground outside
-- the entrance, and on open ground "ground" is the site's own, the piece's place given from its middle (`dx`, `dy`).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/StageData"
local OA = OperationAcorn
local Places = OA.Places
local Stage = {}
OA.Stage = Stage

Stage.game = nil

-- The kinds put as the building loads; the rest (zombies) wait for the player.
Stage.PLACE_KINDS = { tile = true, set = true, item = true, vehicle = true, barricade = true, lock = true,
    corpse = true, blood = true, piece = true, board = true, lockout = true, generator = true, window = true, line = true }
Stage.GROUND_RADIUS = 12   -- open ground is set up once the squares this far round the site are loaded
Stage.READY = 40   -- the zombies are made once the player is this near the site (as the mission scene's, Story/Scene)
Stage.ROOM_AREA = 4   -- the least area of a room with a role but the big one (a map has rooms of one square: pillars)

-- The stage data of a mission: its story's (by its option; a revisit's, the story's it goes back to), when its site is
-- the kind the stage is for; nil otherwise.
function Stage.defOf(m)
    if not (m and m.story and m.site) then return nil end
    local key = m.chosen and (m.story .. "_" .. m.chosen) or m.story
    local revisits = OA.StoryData and OA.StoryData.REVISITS
    local back = revisits and revisits[m.story]
    local def = OA.StageData[key] or (back and back.from and OA.StageData[back.from])
    if not def or (def.ground == true) ~= (m.site.ground == true) then return nil end
    return def
end

-- The buildings set up in this world: site key -> true.
function Stage.world()
    return OA.Store.world("stages")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Roles.

local function centre(r)
    return (r.x + r.x2) / 2, (r.y + r.y2) / 2
end

local HALL = { hall = true, hallway = true, corridor = true, entrance = true, lobby = true }

-- The rooms' roles in a layout: { big, inner, other, hall } as indexes of layout.rooms, and entrance as an index of
-- layout.doors; any of them nil when the building has no room for it. The ground floor is z 0, or the lowest there is.
function Stage.roles(layout, int)
    int = int or OA.random
    local rooms = layout.rooms or {}
    local floor
    for _, r in ipairs(rooms) do
        if r.z == 0 then floor = 0 end
    end
    if not floor then
        for _, r in ipairs(rooms) do
            if not floor or r.z < floor then floor = r.z end
        end
    end
    local ground = {}
    for i, r in ipairs(rooms) do
        if r.z == floor then ground[#ground + 1] = i end
    end
    local roles = {}
    for _, i in ipairs(ground) do
        if not roles.big or rooms[i].area > rooms[roles.big].area then roles.big = i end
    end
    -- the rooms too small for a role count as taken
    local taken = {}
    for i, r in ipairs(rooms) do
        if (r.area or 0) < Stage.ROOM_AREA then taken[i] = true end
    end
    if roles.big then taken[roles.big] = true end
    -- the inner room: one away from the outline, else the one farthest from the big room; of the rooms with a door
    -- first, when the layout counts them (a room's `doors`: one to be locked)
    local function inner(skip)
        local list = {}
        for _, i in ipairs(ground) do
            if not skip(i) and not rooms[i].edge then list[#list + 1] = i end
        end
        if #list > 0 then return list[int(1, #list)] end
        if not roles.big then return nil end
        local bx, by = centre(rooms[roles.big])
        local best, bestD
        for _, i in ipairs(ground) do
            if not skip(i) then
                local x, y = centre(rooms[i])
                local d = Places.distance(bx, by, x, y)
                if not bestD or d > bestD then best, bestD = i, d end
            end
        end
        return best
    end
    local function passed(i) return taken[i] or HALL[rooms[i].name or ""] end
    roles.inner = inner(function(i) return passed(i) or (rooms[i].doors or 1) == 0 end) or inner(passed)
    if roles.inner then taken[roles.inner] = true end
    -- the hall: one named so, on the ground floor
    for _, i in ipairs(ground) do
        if not roles.hall and not taken[i] and HALL[rooms[i].name or ""] then roles.hall = i end
    end
    if roles.hall then taken[roles.hall] = true end
    -- another room: on the ground floor first, then anywhere
    local rest = {}
    for _, i in ipairs(ground) do
        if not taken[i] then rest[#rest + 1] = i end
    end
    if #rest == 0 then
        for i in ipairs(rooms) do
            if not taken[i] then rest[#rest + 1] = i end
        end
    end
    if #rest > 0 then roles.other = rest[int(1, #rest)] end
    roles.hall = roles.hall or roles.other
    -- the entrance: the outer door nearest the big room; the back: the farthest other one
    local doors = layout.doors or {}
    if #doors > 0 then
        local bx, by = 0, 0
        if roles.big then bx, by = centre(rooms[roles.big]) end
        local best, bestD, far, farD
        for i, d in ipairs(doors) do
            local dist = Places.distance(bx, by, d.x, d.y)
            if not bestD or dist < bestD then best, bestD = i, dist end
            if not farD or dist > farD then far, farD = i, dist end
        end
        roles.entrance = best
        if far ~= best then roles.back = far end
    end
    return roles
end

-- ---------------------------------------------------------------------------------------------------------------
-- In the course of a mission.

-- The mission began: a story mission at a building gets a stage, and the pieces the stage puts are left out of the
-- usual placing (Story/Game: it.staged).
function Stage.begin(record, m)
    if m.stage or m.state == "offer" then return end
    local def = Stage.defOf(m)
    if not def then return end
    m.stage = { placed = false, kept = false, wake = {} }
    for _, p in ipairs(def.pieces) do
        if p.kind == "piece" then
            for _, it in ipairs(m.items or {}) do
                if it.key == p.key and not it.placed then it.staged = true end
            end
        end
    end
end

local function run(ctx, p)
    local g = Stage.game
    local fn = g and g[p.kind]
    if not fn then return nil end
    local ok, result = pcall(fn, ctx, p)
    if not ok then
        OA.log("stage piece", p.kind, "failed:", tostring(result))
        return nil
    end
    return result
end

-- Puts the building's pieces (once its layout is read): all of them the first time the building is set up, the
-- mission's own item only when it was set up before.
function Stage.place(record, m, layout, int)
    local def = Stage.defOf(m)
    local st = m.stage
    if not (def and st) or st.placed then return end
    local fresh = not Stage.world()[m.site.key]
    local ctx = { record = record, m = m, layout = layout, roles = Stage.roles(layout, int) }
    st.roles = ctx.roles
    for _, p in ipairs(def.pieces) do
        if Stage.PLACE_KINDS[p.kind] and (fresh or p.kind == "piece") then
            local result = run(ctx, p)
            if p.kind == "lock" and result then ctx.keyId = result end
            -- a boarded door that loses a plank at a point of a span
            if p.drop and type(result) == "table" then
                st.during = st.during or {}
                st.during[#st.during + 1] = { name = p.drop.during, at = p.drop.at, plank = result }
            end
        end
    end
    -- a piece the stage could not put goes the usual way
    for _, it in ipairs(m.items or {}) do
        if it.staged then
            it.staged = nil
            if not it.placed and Stage.game and Stage.game.request then Stage.game.request(record, m, it) end
        end
    end
    st.placed = true
    st.fresh = fresh
    Stage.world()[m.site.key] = true
end

-- Makes the stage's zombies (a building set up before has none of its own any more). Those that wake on an event are
-- remembered by where they lie: st.wake[event] = { { x, y, z }, ... }.
function Stage.keep(record, m, px, py, near)
    local def = Stage.defOf(m)
    local st = m.stage
    if not (def and st) or st.kept or not st.placed then return end
    st.kept = true
    if not st.fresh then return end
    local g = Stage.game
    local ctx = { record = record, m = m, roles = st.roles, px = px, py = py, near = near,
        layout = g and g.layout and g.layout(m.site) }
    for _, p in ipairs(def.pieces) do
        if not Stage.PLACE_KINDS[p.kind] then
            local points = run(ctx, p)
            if p.wake and type(points) == "table" then
                local list = st.wake[p.wake] or {}
                for _, at in ipairs(points) do list[#list + 1] = at end
                st.wake[p.wake] = list
                if p.stagger then
                    st.stagger = st.stagger or {}
                    st.stagger[p.wake] = p.stagger
                end
            end
            -- spread over a span: the i-th of n wakes at i / (n + 1) of it
            if p.during and type(points) == "table" then
                st.during = st.during or {}
                for i, at in ipairs(points) do
                    st.during[#st.during + 1] = { name = p.during, at = i / (#points + 1), points = { at } }
                end
            end
        end
    end
end

-- The one-minute look (Story/Scene, for each running mission): set up the building once it is loaded, the zombies
-- once the player is near. `near` is how far from the player they are made.
function Stage.look(record, m, px, py, near)
    local st = m.stage
    local g = Stage.game
    if not (st and g) or st.kept then return end
    local close = Places.distance(px, py, m.site.x, m.site.y) <= Stage.READY
    if not st.placed then
        if not g.siteLoaded(m.site, close) then return end
        Stage.place(record, m, g.layout(m.site))
    end
    if close then Stage.keep(record, m, px, py, near) end
end

-- Something happened at the stage ("pickup": its item first taken): what waits for it wakes.
function Stage.event(record, m, name)
    local st = m and m.stage
    local list = st and st.wake and st.wake[name]
    if not list then return end
    st.wake[name] = nil
    local g = Stage.game
    if g and g.wake then pcall(g.wake, list, st.stagger and st.stagger[name]) end
end

-- A span at the stage has come to `f` (0 to 1; "wait": the swap's wait): what is spread over it up to there happens,
-- each once.
function Stage.progress(record, m, name, f)
    local st = m and m.stage
    local list = st and st.during
    if not list then return end
    local g = Stage.game
    local i = 1
    while i <= #list do
        local e = list[i]
        if e.name == name and f >= e.at then
            table.remove(list, i)
            if g and e.points and g.wake then pcall(g.wake, e.points) end
            if g and e.plank and g.unplank then pcall(g.unplank, e.plank) end
        else
            i = i + 1
        end
    end
end

return Stage
