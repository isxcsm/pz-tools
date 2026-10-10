-- What the player sees of a mission and of the crates on the map and in the world: colours, the markers of a map, the
-- dots, the zoom that fits the player and the circle, and the pieces to light.
require "OperationAcorn/Core"
require "OperationAcorn/Story/View"
local OA = OperationAcorn
local View = OA.StoryView

local function mission(kind, state)
    return { id = "M1-1", kind = kind or "regular", state = state or "open", level = 1,
        area = { x = 1000, y = 2000, r = 60 }, items = {} }
end

test("a story mission is sky blue, every other kind teal, and teal is not the ledger's amber", function()
    eq(View.color("story"), View.SKY)
    for _, kind in ipairs({ "regular", "contract", "special", "anything" }) do eq(View.color(kind), View.TEAL, kind) end
    eq(View.color(nil), View.TEAL)
    near(View.TEAL[1], 0.30, 1e-9)
    near(View.TEAL[2], 0.90, 1e-9)
    near(View.TEAL[3], 0.85, 1e-9)
    truthy(View.TEAL[1] < 0.5 and View.TEAL[3] > 0.5, "teal has little red and much blue; the ledger's amber the opposite")
end)

test("the mission the map shows is the active one once it is taken", function()
    eq(View.shown(nil), nil)
    eq(View.shown({}), nil)
    eq(View.shown({ missions = { active = mission("regular", "offer") } }), nil, "an offer has no circle yet")
    eq(View.shown({ missions = { active = mission("regular", "calling") } }), nil)
    local m = mission()
    eq(View.shown({ missions = { active = m } }), m)
end)

test("a mission has a circle, a swap mission a dimmer second one, a sealed mission none", function()
    eq(#View.circles(nil), 0)
    eq(#View.circles(mission("regular", "sealed")), 0)
    local m = mission()
    eq(#View.circles(m), 1)
    m.area2 = { x = 5, y = 6, r = 70 }
    local list = View.circles(m)
    eq(#list, 2)
    eq(list[1].dim, nil)
    eq(list[2].dim, true)
    eq(list[2].r, 70)
end)

test("ten dots go from the player to the circle's edge, evenly, the last short of it", function()
    local dots = View.dots(0, 0, { x = 1200, y = 0, r = 100 })
    eq(#dots, 10)
    local step = dots[2].x - dots[1].x
    for i = 1, 10 do
        eq(dots[i].y, 0)
        truthy(dots[i].x > 0 and dots[i].x < 1100, "between the player and the edge")
        if i > 1 then near(dots[i].x - dots[i - 1].x, step, 1, "even steps") end
        eq(dots[i].r, 7, "0.6% of 1200")
    end
    truthy(1200 - dots[10].x > 100, "the last dot is outside the circle")
    truthy(dots[1].x < step * 1.1, "the first is one step from the player")
end)

test("a dot's radius follows the distance, and no dot is under one square", function()
    eq(View.dots(0, 0, { x = 6400, y = 0, r = 100 })[1].r, 38)
    eq(View.dots(0, 0, { x = 130, y = 0, r = 100 })[1].r, 1)
end)

test("no dots inside the circle, and none without one", function()
    eq(#View.dots(1010, 2000, { x = 1000, y = 2000, r = 60 }), 0)
    eq(#View.dots(0, 0, nil), 0)
end)

test("dots lie on the line to a circle in any direction", function()
    local dots = View.dots(100, 100, { x = 100, y = -900, r = 50 })
    for _, d in ipairs(dots) do eq(d.x, 100) end
    truthy(dots[1].y < 100 and dots[10].y > -850)
end)

test("the crates are the helicopter's marks that are left", function()
    eq(#View.crates(nil), 0)
    eq(#View.crates({ heli = {} }), 0)
    local list = View.crates({ heli = { markers = { { kind = "crate", x = 10, y = 20, z = 0 }, { kind = "first", x = 30, y = 40 },
        { kind = "crate" } } } })
    eq(#list, 2, "a mark without a place is skipped")
    eq(list[1].kind, "crate")
    eq(list[2].x, 30)
end)

test("the world map gets the circle, the dots and the crates; the minimap the circle only", function()
    local record = { missions = { active = mission() }, heli = { markers = { { kind = "crate", x = 7, y = 8, z = 0 } } } }
    local world = View.markers(record, 0, 0, true)
    local counts = { circle = 0, dot = 0, crate = 0 }
    for _, k in ipairs(world) do counts[k.kind] = counts[k.kind] + 1 end
    eq(counts.circle, 1)
    eq(counts.dot, 10)
    eq(counts.crate, 1)
    local mini = View.markers(record, 0, 0, false)
    eq(#mini, 1)
    eq(mini[1].kind, "circle")
    eq(mini[1].color, View.TEAL)
    eq(mini[1].minPx, View.CIRCLE_MIN_PX)
    eq(world[2].minPx, View.DOT_MIN_PX, "a dot stays small: the game's own smallest is 64 px")
end)

test("the circle's colour follows the mission and the crates keep their own", function()
    local story = mission("story")
    local record = { missions = { active = story }, heli = { markers = { { kind = "crate", x = 7, y = 8, z = 0 } } } }
    local list = View.markers(record, 0, 0, true)
    eq(list[1].color, View.SKY)
    eq(list[#list].color, View.CRATE)
    eq(list[#list].kind, "crate")
end)

test("a record with nothing to show has no markers", function()
    eq(#View.markers({}, 5, 5, true), 0)
    eq(#View.markers(nil, 5, 5, false), 0)
end)

test("the second circle is dimmer", function()
    local m = mission()
    m.area2 = { x = 5, y = 6, r = 70 }
    local list = View.markers({ missions = { active = m } }, nil, nil, false)
    eq(#list, 2)
    truthy(list[2].alpha < list[1].alpha)
end)

test("the signature is the same for the same markers and differs when one changes", function()
    local record = { missions = { active = mission() } }
    local a = View.signature(View.markers(record, 0, 0, true))
    eq(View.signature(View.markers(record, 0, 0, true)), a)
    truthy(View.signature(View.markers(record, 50, 0, true)) ~= a, "the player moved: the dots moved")
    record.heli = { markers = { { kind = "crate", x = 1, y = 2, z = 0 } } }
    truthy(View.signature(View.markers(record, 0, 0, true)) ~= a, "a crate")
    eq(View.signature({}), "")
end)

-- The zoom: the game's scale in pixels a square is 2^zoom * height / EARTH.
local function scaleOf(zoom, height) return 2 ^ zoom * height / View.EARTH end

local function view(extra)
    local v = { width = 1280, height = 720, margin = 96, minZoom = 12, maxZoom = 24, isometric = false }
    for k, val in pairs(extra or {}) do v[k] = val end
    return v
end

test("the fit puts the centre between the player and the circle", function()
    local x, y = View.fit(10600, 9800, { x = 11450, y = 8950, r = 70 }, view())
    eq(x, 11025)
    eq(y, 9375)
end)

test("the fit's zoom keeps both inside the margin, and is the largest that does (the mockup's 1.2 km scene)", function()
    local circle = { x = 11450, y = 8950, r = 70 }
    local _, _, zoom = View.fit(10600, 9800, circle, view())
    local s = scaleOf(zoom, 720)
    truthy(s <= 0.5334 and s > 0.5334 * 0.99, "the 0.533 px/square of the mockup, got " .. s)
    -- both ends inside: the half extent in pixels is at most half the screen less the margin
    truthy((425 + 70) * s <= 360 - 96 + 1e-6)
    -- and a 2% larger scale would not fit
    truthy((425 + 70) * s * 1.02 > 360 - 96)
end)

test("a far mission is fitted at a lower zoom, never under the map's smallest", function()
    local circle = { x = 6100, y = 14350, r = 100 }
    local _, _, zoom = View.fit(10600, 9800, circle, view())
    truthy(zoom < 14.86 and zoom >= 12)
    local _, _, clamped = View.fit(0, 0, { x = 90000, y = 0, r = 100 }, view())
    eq(clamped, 12)
end)

test("a mission at the player's feet is not zoomed past the largest zoom", function()
    local _, _, zoom = View.fit(100, 100, { x = 100, y = 100, r = 1 }, view({ maxZoom = 20 }))
    eq(zoom, 20)
end)

test("an isometric map, turned, takes a lower zoom for the same two points", function()
    local circle = { x = 11450, y = 8950, r = 70 }
    local _, _, flat = View.fit(10600, 9800, circle, view())
    local _, _, iso = View.fit(10600, 9800, circle, view({ isometric = true }))
    truthy(iso <= flat, "the turned view is never tighter")
end)

test("only a placed piece with a square is lit, and not the plain key", function()
    eq(View.isLit({ placed = true, at = { x = 1, y = 2, z = 0 } }), true)
    eq(View.isLit({ placed = false, at = { x = 1, y = 2, z = 0 } }), false)
    eq(View.isLit({ placed = true }), false)
    eq(View.isLit({ placed = true, at = { x = 1, y = 2, z = 0 }, plain = true }), false)
end)

test("a square is near on the player's floor within six squares", function()
    local at = { x = 100, y = 100, z = 0 }
    eq(View.near(100.5, 100.5, 0, at), true)
    eq(View.near(106, 100.5, 0, at), true, "5.5 squares")
    eq(View.near(107, 100.5, 0, at), false, "6.5 squares")
    eq(View.near(100.5, 100.5, 1, at), false, "another floor")
    eq(View.near(100.5, 100.5, 0.7, at), true, "a character mid-stair is still on its floor")
    eq(View.near(104, 104, 0, at), true, "diagonal 4.9")
    eq(View.near(106, 106, 0, at), false, "diagonal 7.8")
end)

test("an item belongs to a mission by its id, or by the id and a piece", function()
    local m = { id = "M7-3" }
    eq(View.owns(m, "M7-3"), true)
    eq(View.owns(m, "M7-3#A"), true)
    eq(View.owns(m, "M7-30"), false, "another mission whose id starts the same")
    eq(View.owns(m, "M7-2"), false)
    eq(View.owns(m, nil), false)
    eq(View.owns(nil, "M7-3"), false)
    eq(View.owns({ id = "M7-30" }, "M7-30#B"), true, "the prefix follows the mission")
end)
