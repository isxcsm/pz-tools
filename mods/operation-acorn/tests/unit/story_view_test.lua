-- What the player sees of a mission and of the crates on the map and in the world: colours, what the maps show, the
-- zoom that fits the player and the circle, and the pieces to light.
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
    eq(View.shown({ missions = { active = mission("regular", "waiting") } }), nil, "an offer has no circle yet")
    eq(View.shown({ missions = { active = mission("story", "briefing") } }), nil, "nor one being briefed")
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

test("the crates are the helicopter's marks that are left", function()
    eq(#View.crates(nil), 0)
    eq(#View.crates({ heli = {} }), 0)
    local list = View.crates({ heli = { markers = { { kind = "crate", x = 10, y = 20, z = 0 }, { kind = "crate", x = 30, y = 40 },
        { kind = "crate" } } } })
    eq(#list, 2, "a mark without a place is skipped")
    eq(list[1].kind, "crate")
    eq(list[2].x, 30)
end)

test("the delivery boxes are shown where they last stood; one packed in a crate is the crate's mark", function()
    eq(#View.boxes(nil), 0)
    eq(#View.boxes({ boxes = { list = {} } }), 0)
    local record = { heli = { markers = { { kind = "crate", x = 50, y = 60 } } }, boxes = { list = {
        ["1-1"] = { id = "1-1", state = "placed", x = 10, y = 20 },
        ["1-2"] = { id = "1-2", state = "sealed", x = 30, y = 40 },
        ["1-3"] = { id = "1-3", state = "carried", x = 70, y = 80 },
        ["1-4"] = { id = "1-4", state = "carried", x = 50, y = 60 },
        ["1-5"] = { id = "1-5", state = "carried" },
    } } }
    local list = View.boxes(record)
    eq(#list, 3, "standing, sealed, carried off from its last spot; not the one in its crate, nor one with no spot")
    eq(list[1].x, 10); eq(list[2].x, 30); eq(list[3].x, 70)
    local scene = View.scene(record)
    eq(#scene.boxes, 3)
    eq(scene.boxes[1].x, 10.5); eq(scene.boxes[1].y, 20.5)
    eq(View.scene({ boxes = { list = { a = { id = "a", state = "placed", x = 1, y = 2 } } } }).empty, false,
        "a box alone is shown")
    -- a crate that came down beside the spot asked for: its mark names the box packed in it
    local beside = { heli = { markers = { { kind = "crate", x = 91, y = 90, box = "2-1" } } }, boxes = { list = {
        ["2-1"] = { id = "2-1", state = "carried", x = 88, y = 90 } } } }
    eq(#View.boxes(beside), 0, "one mark for the crate and the box in it")
    truthy(View.inCrate(beside, beside.boxes.list["2-1"]))
    beside.heli.markers = {}
    eq(#View.boxes(beside), 1, "taken out of the crate: the box's own mark")
end)

test("the maps show the circle, the way's end and the crates, from the middles of their squares", function()
    local record = { missions = { active = mission() }, heli = { markers = { { kind = "crate", x = 7, y = 8, z = 0 } } } }
    local scene = View.scene(record)
    eq(#scene.circles, 1)
    local c = scene.circles[1]
    eq(c.x, 1000.5)
    eq(c.y, 2000.5)
    eq(c.r, 60)
    eq(c.dim, false)
    eq(c.color, View.MAP_TEAL)
    eq(scene.lead, c, "the way leads to it")
    eq(#scene.crates, 1)
    eq(scene.crates[1].x, 7.5)
    eq(scene.crates[1].y, 8.5)
    eq(scene.empty, false)
end)

test("on the maps the colours are deeper than in the world, the kinds told apart as there", function()
    eq(View.mapColor("story"), View.MAP_SKY)
    for _, kind in ipairs({ "regular", "contract", "special", "anything" }) do
        eq(View.mapColor(kind), View.MAP_TEAL, kind)
    end
    truthy(View.MAP_TEAL[1] < View.TEAL[1] and View.MAP_SKY[1] < View.SKY[1], "more saturated")
    truthy(View.MAP_TEAL[2] > View.MAP_TEAL[3] and View.MAP_SKY[3] > View.MAP_SKY[2], "the same hues")
    local scene = View.scene({ missions = { active = mission("story") }, heli = { markers = { { x = 7, y = 8 } } } })
    eq(scene.circles[1].color, View.MAP_SKY)
end)

test("a record with nothing to show is empty: the maps draw nothing", function()
    eq(View.scene({}).empty, true)
    eq(View.scene(nil).empty, true)
    eq(View.scene({ missions = { active = mission("regular", "waiting") } }).empty, true)
    eq(View.scene({ missions = { active = mission("regular", "sealed") } }).empty, true)
    local crates = View.scene({ heli = { markers = { { kind = "crate", x = 1, y = 2 } } } })
    eq(crates.empty, false, "crates alone are shown")
    eq(crates.lead, nil)
end)

test("the second circle is dim and the way never leads to it", function()
    local m = mission()
    m.area2 = { x = 5, y = 6, r = 70 }
    local scene = View.scene({ missions = { active = m } })
    eq(#scene.circles, 2)
    eq(scene.circles[2].dim, true)
    eq(scene.lead, scene.circles[1])
end)

test("once its piece is found a circle goes and the item's place is shown; one the player carries has no pin", function()
    local m = mission()
    m.items = { { key = "A", found = true, where = { x = 40, y = 50, z = 1 } }, { key = "KEY", plain = true } }
    eq(#View.circles(m), 0, "the key is no piece to fetch")
    local points = View.points({}, m)
    eq(#points, 1)
    eq(points[1].x, 40)
    eq(points[1].carried, false)
    -- The game's place now goes before the place kept.
    points = View.points({}, m, function() return 7, 8, 0, true end)
    eq(points[1].x, 7)
    eq(points[1].carried, true)
    local scene = View.scene({ missions = { active = m } })
    eq(#scene.circles, 0)
    eq(#scene.points, 1)
    eq(scene.points[1].x, 40.5)
    eq(scene.lead, scene.points[1], "the way leads to the item")
    eq(scene.empty, false)
    m.items[2] = { key = "B", found = true, where = { x = 1, y = 2, z = 0, carried = true } }
    m.items[1].where.carried = true
    scene = View.scene({ missions = { active = m } })
    eq(#scene.points, 0, "no pin for what the player carries")
    eq(scene.lead, nil, "no way to what the player carries")
    m.items[1].where.carried = nil
    scene = View.scene({ missions = { active = m } })
    eq(#scene.points, 1, "dropped: its pin again")
    eq(scene.lead, scene.points[1])
    -- A piece not yet found keeps the circle.
    m.items[2].found = nil
    eq(#View.circles(m), 1)
    -- Two buildings compared: each circle goes with its own piece.
    m.items = { { key = "A", found = true }, { key = "B" } }
    m.area2 = { x = 5, y = 6, r = 70 }
    local list = View.circles(m)
    eq(#list, 1)
    eq(list[1].dim, true)
    -- A field mission keeps its circle: the call is made in it.
    m.area2 = nil
    m.items = { { key = "A", found = true } }
    m.field = { stage = "needdevice" }
    eq(#View.circles(m), 1)
    -- A swap's case is not fetched: before its record there is nothing found, and the circle stays.
    m.field = nil
    m.swap = { stage = "needcase" }
    m.items = { { key = "CASE", found = true } }
    eq(#View.circles(m), 1)
    eq(#View.points({}, m), 0)
    eq(#View.points({}, mission("regular", "sealed")), 0)
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

-- The special request beside the main mission (DESIGN-terminal 6.3) -----------------------------------------------------

local function special(state)
    local m = mission("special", state)
    m.id = "M1-2"
    m.area = { x = 3000, y = 4000, r = 70 }
    return m
end

test("the special request running is shown with the main mission, once it is taken", function()
    local main, sp = mission(), special()
    local record = { missions = { active = main, special = { mission = sp } } }
    eq(View.shownSpecial(record), sp)
    local list = View.shownList(record)
    eq(#list, 2)
    eq(list[1], main)
    eq(list[2], sp)
    eq(View.shownSpecial({ missions = { special = { mission = special("calling") } } }), nil)
    eq(View.shownSpecial({ missions = { special = { offer = {} } } }), nil, "an offer has no circle")
    eq(#View.shownList({ missions = { special = { mission = sp } } }), 1, "the request alone")
    eq(#View.shownList({}), 0)
    eq(#View.shownList(nil), 0)
end)

test("both missions' circles are shown and the way leads to the main mission's", function()
    local main, sp = mission(), special()
    local scene = View.scene({ missions = { active = main, special = { mission = sp } } })
    eq(#scene.circles, 2)
    eq(scene.circles[1].x, 1000.5)
    eq(scene.circles[2].x, 3000.5)
    eq(scene.circles[2].color, View.MAP_TEAL)
    eq(scene.circles[2].dim, false, "the request's circle is its own, with its pin")
    eq(scene.lead, scene.circles[1])
    local alone = View.scene({ missions = { special = { mission = sp } } })
    eq(alone.lead.x, 3000.5, "no main mission: the way leads to the request's")
end)

test("an item belongs to the main mission or the special request by its OA_Mission, and to no other", function()
    local main, sp = mission(), special()
    local record = { missions = { active = main, special = { mission = sp } } }
    eq(View.ownerOf(record, "M1-1"), main)
    eq(View.ownerOf(record, "M1-1#A"), main)
    eq(View.ownerOf(record, "M1-2"), sp)
    eq(View.ownerOf(record, "M1-2#B"), sp)
    eq(View.ownerOf(record, "M1-22"), nil)
    eq(View.ownerOf(record, "M9-9"), nil)
    eq(View.ownerOf(record, nil), nil)
    eq(View.ownerOf({}, "M1-1"), nil)
    eq(View.ownerOf(nil, "M1-1"), nil)
    eq(#View.live(record), 2)
    eq(#View.live({ missions = { active = main } }), 1)
    eq(#View.live(nil), 0)
end)
