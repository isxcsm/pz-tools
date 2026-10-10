-- A mission's place (Story/Scene): the survivor's chance and no repeat, its outfit by date, its look and what it
-- carried, the things left, the keepers' outfits by place, the arrival lines, the one-minute look with a fake world,
-- the survivor known again as it dies, the drop sites' first visit and their props.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Scene"
require "OperationAcorn/Story/Sites"
local OA = OperationAcorn
local Scene = OA.Scene

-- A random source that gives the listed numbers first (each clamped into the range asked), then the low end.
local function seq(list)
    local i = 0
    return function(a, b)
        i = i + 1
        local v = list[i]
        if v == nil then return a end
        return math.max(a, math.min(b, v))
    end
end

local function inList(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

test("a survivor a quarter of the time, never two missions in a row", function()
    local sec = { last = false }
    eq(Scene.survivorRoll(sec, seq({ 25 })), true, "25 of 100")
    eq(Scene.survivorRoll(sec, seq({ 1 })), false, "the next mission never")
    eq(Scene.survivorRoll(sec, seq({ 26 })), false, "26 of 100")
    local yes, last = 0, false
    for _ = 1, 4000 do
        local now = Scene.survivorRoll(sec)
        truthy(not (now and last), "two in a row")
        if now then yes = yes + 1 end
        last = now
    end
    -- 25% on the missions after one without: 0.25 / 1.25 of all
    truthy(yes > 4000 * 0.17 and yes < 4000 * 0.23, "about a fifth of all missions: " .. yes)
end)

test("the survivalist outfit and its _Mid and _Late looks by the days since the outbreak", function()
    eq(Scene.survivorOutfit(0, seq({ 1 })), "Survivalist")
    eq(Scene.survivorOutfit(29.9, seq({ 5 })), "Survivalist05")
    eq(Scene.survivorOutfit(30, seq({ 2 })), "Survivalist02_Mid")
    eq(Scene.survivorOutfit(89, seq({ 3 })), "Survivalist03_Mid")
    eq(Scene.survivorOutfit(90, seq({ 4 })), "Survivalist04_Late")
    for _ = 1, 50 do
        local name = Scene.survivorOutfit(0)
        truthy(inList(Scene.SURVIVOR_OUTFITS, name), name)
    end
end)

test("the survivor's look is one of four", function()
    for i, look in ipairs({ "fakeDead", "sitting", "crawler", "standing" }) do eq(Scene.survivorLook(seq({ i })), look) end
    for _ = 1, 50 do truthy(inList(Scene.LOOKS, Scene.survivorLook())) end
end)

test("what the survivor carried: one to eat and one other, a second other from the third level, by level", function()
    local first = Scene.carried(1, seq({ 2, 3 }))
    eq(#first, 2)
    eq(first[1], Scene.CARRIED[1].food[2])
    eq(first[2], Scene.CARRIED[1].kit[3])
    local third = Scene.carried(3, seq({ 1, 2, 1, 2 }))
    eq(#third, 3, "the second other")
    eq(third[2], Scene.CARRIED[3].kit[2])
    eq(third[3], Scene.CARRIED[3].kit[3], "never the same one twice")
    eq(#Scene.carried(3, seq({ 1, 1, 2 })), 2, "half the time only one")
    local far = Scene.carried(12, seq({ 1, 1, 2 }))
    eq(far[1], Scene.CARRIED[5].food[1], "levels past 5 use the 5th")
    for level = 1, 6 do
        for _ = 1, 20 do
            local list = Scene.carried(level)
            truthy(#list >= 2 and #list <= 3)
            for _, t in ipairs(list) do truthy(string.find(t, "^Base%.") ~= nil, t) end
        end
    end
end)

test("the things left: 1 to 3 that fit anywhere in a regular building, a story place's own two and one other", function()
    for _ = 1, 50 do
        local props = Scene.props(nil)
        truthy(#props >= 1 and #props <= 3)
        local types = {}
        for _, p in ipairs(props) do
            truthy(not types[p.type], "no type twice")
            types[p.type] = true
        end
    end
    for _ = 1, 50 do
        local props = Scene.props("muldraugh_pd")
        eq(#props, 3)
        local own = {}
        for _, p in ipairs(Scene.PROPS.police) do own[p.type] = true end
        truthy(own[props[1].type] and own[props[2].type], "two of the police things")
        truthy(props[3].type ~= props[1].type and props[3].type ~= props[2].type)
    end
    local torch = Scene.props(nil, seq({ 1, 1 }))
    eq(torch[1].type, "Base.HandTorch")
    eq(torch[1].left, 0, "the torch's battery is flat")
    eq(Scene.placeKind("westpoint_clinic"), "medical")
    eq(Scene.placeKind("nowhere"), nil)
end)

test("the keepers wear what fits the place, or the game's own outfit at a regular building", function()
    eq(Scene.guardOutfit("muldraugh_pd"), "Police")
    local outfit, female = Scene.guardOutfit("rosewood_prison", seq({ 1 }))
    eq(outfit, "Inmate")
    eq(female, 0, "inmates are men only in the game's outfits")
    truthy(inList({ "Doctor", "Nurse" }, (Scene.guardOutfit("westpoint_clinic"))))
    truthy(inList({ "Nurse", "Doctor", "HospitalPatient" }, (Scene.guardOutfit("louisville_hospital"))))
    eq(Scene.guardOutfit("valley_camp"), "ArmyCamoGreen")
    eq(Scene.guardOutfit("riverside_farm"), "Farmer")
    eq(Scene.guardOutfit(nil), nil)
    eq(Scene.guardOutfit("marchridge_shed"), nil, "a shed: the game's own")
    for _ = 1, 30 do
        local n = Scene.guardCount(1, nil, 1)
        truthy(n >= 8 and n <= 12)
        n = Scene.guardCount(5, nil, 1)
        truthy(n >= 30 and n <= 34)
        n = Scene.guardCount(9, nil, 1)
        truthy(n >= 38 and n <= 42, "past 5 up to KEEPERS_MOST")
    end
    eq(Scene.guardCount(3, seq({ 0 }), 0.5), 10, "half the population, half the keepers")
    eq(Scene.guardCount(3, seq({ 0 }), 0), 0, "a world without zombies has none")
    eq(Scene.guardLook(seq({ 2 })), nil)
    eq(Scene.guardLook(seq({ 1, 1 })), "fakeDead")
    eq(Scene.guardLook(seq({ 1, 2 })), "sitting")
    -- every place a story mission can use has its kind, and its kind has things to leave
    for id in pairs(OA.StoryData.PLACES) do
        local kind = Scene.placeKind(id)
        truthy(kind, id .. " has a kind")
        truthy(Scene.KIND_PROPS[kind], id .. " has things")
    end
end)

test("night is before dawn and from dusk", function()
    eq(Scene.isNight(5.5, 6, 21), true)
    eq(Scene.isNight(6, 6, 21), false)
    eq(Scene.isNight(20.9, 6, 21), false)
    eq(Scene.isNight(21, 6, 21), true)
end)

test("every story place has its own arrival line, said once; then the general ones for the hour", function()
    local record = OA.Store.ensure("p1", "P")
    for id in pairs(OA.StoryData.PLACES) do truthy(inList(Scene.PLACE_LINES, id), id .. " has a line") end
    local m = { place = "westpoint_pd" }
    local id, ctx = Scene.arrivalLine(record, m, true)
    eq(id, "ArrivePlace")
    eq(ctx.place, "westpoint_pd")
    id, ctx = Scene.arrivalLine(record, m, true)
    eq(id, "Arrive", "the second time there")
    eq(ctx.night, true)
    id, ctx = Scene.arrivalLine(record, {}, false)
    eq(id, "Arrive")
    eq(ctx.night, false)
    -- the place's line is the one its tag names
    local n = nil
    for i, p in ipairs(Scene.PLACE_LINES) do if p == "westpoint_pd" then n = i end end
    truthy(OA.Say.fits("ArrivePlace", n, { place = "westpoint_pd" }))
    eq(OA.Say.fits("ArrivePlace", n, { place = "muldraugh_pd" }), false)
    eq(OA.Say.fits("Arrive", 1, { night = false }), false, "a night line by day")
end)

-- A fake world: where the player is, what is loaded, what was made.
local function fakeWorld()
    local g = { said = {}, props = 0, guards = 0, survivors = 0, px = 0, py = 0, loadedAt = true, night = false }
    g.playerPosition = function() return g.px, g.py, 0 end
    g.isNight = function() return g.night end
    g.days = function() return 40 end
    g.say = function(record, id, ctx) g.said[#g.said + 1] = { id = id, ctx = ctx } end
    g.loaded = function() return g.loadedAt end
    g.placeProps = function(it, props) g.props = g.props + #props end
    g.spawnGuards = function(it, guards, px, py, near) g.guards, g.near = g.guards + #guards, near end
    g.spawnSurvivor = function(it, s) g.survivors = g.survivors + 1; return -2147155967 end
    Scene.game = g
    return g
end

local function mission(record, place)
    local m = { id = "M1-1", state = "open", level = 2, place = place, area = { x = 100, y = 100, r = 60 },
                items = { { key = "A", x = 100, y = 100, z = 0, x1 = 95, y1 = 95, x2 = 105, y2 = 105, placed = false } } }
    OA.Missions.state(record).active = m
    return m
end

test("a mission begun gets its scene once; an offer only when it is taken", function()
    local record = OA.Store.ensure("p1", "P")
    local m = mission(record, "muldraugh_pd")
    OA.Missions.begin(record, m)
    truthy(m.scene, "planned as it begins")
    eq(#m.scene.props, 3)
    truthy(#m.scene.guards >= 2)
    eq(m.scene.guards[1].outfit, "Police")
    local scene = m.scene
    OA.Missions.begin(record, m)
    eq(m.scene, scene, "never planned again")
    local offer = { id = "M1-2", state = "offer", items = {} }
    OA.Missions.begin(record, offer)
    eq(offer.scene, nil)
    -- a drop site's stake (no building) only has its line
    local stake = { id = "M1-3", state = "open", items = { { key = "A", x = 5, y = 5, x1 = 5, y1 = 5, x2 = 5, y2 = 5 } } }
    OA.Missions.begin(record, stake)
    eq(stake.scene.built, true)
    eq(stake.scene.survivor, nil)
end)

test("the minute look: the line on entering the circle, the scene once its piece is in place, loaded and near", function()
    local g = fakeWorld()
    local record = OA.Store.ensure("p1", "P")
    Scene.section(record).last = false
    local m = mission(record, "westpoint_clinic")
    m.scene = Scene.plan(record, m, 40, seq({}))
    m.scene.survivor = { outfit = "Survivalist_Mid", look = "sitting", carried = { "Base.TinnedBeans", "Base.Bandage" } }
    g.px, g.py = 300, 300
    Scene.minute(record)
    eq(#g.said, 0, "outside the circle")
    g.px, g.py = 150, 130
    Scene.minute(record)
    eq(#g.said, 1)
    eq(g.said[1].id, "ArrivePlace")
    eq(m.scene.built, false, "the piece is not in place yet")
    Scene.minute(record)
    eq(#g.said, 1, "said once")
    m.items[1].placed, m.items[1].at = true, { x = 100, y = 100, z = 0 }
    g.loadedAt = false
    Scene.minute(record)
    eq(m.scene.built, false, "its square not loaded")
    g.loadedAt = true
    Scene.minute(record)
    eq(m.scene.built, false, "the player not near yet (58 squares)")
    g.px, g.py = 125, 120
    Scene.minute(record)
    eq(m.scene.built, true)
    eq(g.near, Scene.NEAR)
    eq(g.props, 3)
    truthy(g.guards >= 2)
    eq(g.survivors, 1)
    Scene.minute(record)
    eq(g.survivors, 1, "made once")
    local list = Scene.section(record).survivors
    eq(#list, 1)
    eq(list[1].outfit, -2147155967)
    eq(list[1].mission, "M1-1")
end)

test("the keepers stay away with the option off", function()
    local g = fakeWorld()
    local record = OA.Store.ensure("p1", "P")
    SandboxVars.OperationAcorn.MissionGuards = false
    local m = mission(record, nil)
    m.scene = Scene.plan(record, m, 0)
    m.items[1].placed, m.items[1].at = true, { x = 100, y = 100, z = 0 }
    g.px, g.py = 108, 104
    Scene.minute(record)
    eq(m.scene.built, true, "made when the player came nearer than NEAR at once")
    eq(g.guards, 0)
    truthy(g.props >= 1)
    SandboxVars.OperationAcorn.MissionGuards = true
end)

test("a player who came nearer than NEAR between two looks still gets the keepers, made CLOSE away", function()
    local g = fakeWorld()
    local record = OA.Store.ensure("p1", "P")
    local m = mission(record, nil)
    m.scene = Scene.plan(record, m, 0)
    m.items[1].placed, m.items[1].at = true, { x = 100, y = 100, z = 0 }
    g.px, g.py = 108, 104
    Scene.minute(record)
    eq(m.scene.built, true)
    truthy(g.guards >= 2)
    eq(g.near, Scene.CLOSE)
end)

test("a dying survivor is known by its outfit id near its building; the first thing taken says the line once", function()
    local g = fakeWorld()
    local record = OA.Store.ensure("p1", "P")
    local m = { id = "M1-5", scene = { survivor = { carried = { "Base.TinnedBeans", "Base.Bandage" } } } }
    Scene.addSurvivor(record, m, 77, { x = 100, y = 100, z = 0 })
    eq(Scene.survivorDied(78, 100, 100), nil, "another outfit id")
    eq(Scene.survivorDied(77, 900, 900), nil, "the same id far away is another zombie")
    local r, s = Scene.survivorDied(77, 130, 90)
    eq(r, record)
    eq(s.carried[2], "Base.Bandage")
    eq(Scene.survivorDied(77, 130, 90), nil, "only once")
    -- only the last few are remembered
    for i = 1, 6 do Scene.addSurvivor(record, m, i, { x = 0, y = 0, z = 0 }) end
    eq(#Scene.section(record).survivors, Scene.SURVIVORS_KEPT)
    local function item(data) return { getModData = function() return data end } end
    Scene.pickedUp(record, item({}))
    eq(#g.said, 0)
    Scene.pickedUp(record, item({ OA_Carried = "M1-5" }))
    Scene.pickedUp(record, item({ OA_Carried = "M1-5" }))
    eq(#g.said, 1)
    eq(g.said[1].id, "Survivor")
    Scene.pickedUp(record, item({ OA_Carried = "M1-9" }))
    eq(#g.said, 2, "another mission's survivor")
end)

test("a drop site stood at says its line once", function()
    local record = OA.Store.ensure("p1", "P")
    local sites = { { n = 1, x = 0, y = 0, state = "placed" }, { n = 2, x = 50, y = 50, state = "pending" } }
    eq(Scene.touchSite(record, 10, 0, sites), nil, "too far")
    eq(Scene.touchSite(record, 2, 3, sites), 1)
    eq(Scene.touchSite(record, 0, 0, sites), nil, "once")
    eq(Scene.touchSite(record, 50, 50, sites), nil, "a site not yet put down")
end)

test("a drop site gets 2 or 3 different things round it, and the second stake another date", function()
    local seen = {}
    for _ = 1, 200 do
        local kinds = OA.Sites.propKinds()
        truthy(#kinds >= 2 and #kinds <= 3)
        local once = {}
        for _, k in ipairs(kinds) do
            truthy(not once[k], "different kinds")
            once[k] = true
            seen[k] = true
            truthy(k == "stake" or OA.Sites.PROP_SPRITES[k], k .. " has a tile")
        end
    end
    for _, k in ipairs(OA.Sites.PROPS) do truthy(seen[k], k .. " comes") end
    for date = 1, OA.Sites.DATES do
        for _ = 1, 20 do
            local other = OA.Sites.otherDate(date)
            truthy(other ~= date and other >= 1 and other <= OA.Sites.DATES)
        end
    end
end)

test("self-talk the server asks for is said by the player's own client", function()
    local said, data = {}, {}
    local player = { getModData = function() return data end, Say = function(_, t) said[#said + 1] = t end }
    getPlayer = function() return player end
    getTextOrNull = function(key) if key == "IGUI_OA_Say_SiteFirst_1" then return key end return nil end
    OA.Store.idOf = function() return "p1" end
    OA.Say.tell("p1", "SiteFirst", nil)
    eq(said[1], "IGUI_OA_Say_SiteFirst_1")
    OA.Say.tell("p2", "SiteFirst", nil)
    eq(#said, 1, "another player's")
end)
