-- A story site's stage (Story/Stage): the rooms' roles, when a building is set up and what once, the zombies when the
-- player comes, what wakes on an event, and the mission's item left to the stage.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Scene"
require "OperationAcorn/Story/Stage"
local OA = OperationAcorn
local Stage = OA.Stage
local M = OA.Missions

local function room(name, area, z, x, y, x2, y2, edge)
    return { name = name, area = area, z = z, x = x, y = y, x2 = x2, y2 = y2, edge = edge }
end

-- A building of five rooms on the ground floor and one upstairs, its two outer doors.
local function layout()
    return {
        rooms = {
            room("office", 20, 0, 0, 0, 4, 4, true),
            room("policestorage", 12, 0, 5, 5, 8, 8, false),
            room("lobby", 60, 0, 10, 0, 20, 6, true),
            room("hall", 16, 0, 0, 5, 4, 9, true),
            room("bathroom", 6, 0, 9, 7, 10, 9, true),
            room("bedroom", 30, 1, 0, 0, 6, 6, true),
        },
        doors = { { x = 15, y = 7, z = 0, north = true }, { x = 0, y = 9, z = 0, north = false } },
    }
end

test("the rooms' roles: the largest below, one inside, the hall, another, and the door by the big room", function()
    local roles = Stage.roles(layout(), function(a) return a end)
    eq(roles.big, 3)
    eq(roles.inner, 2, "the one away from the outline")
    eq(roles.hall, 4)
    eq(roles.other, 1)
    eq(roles.entrance, 1)
    for _ = 1, 20 do
        local r = Stage.roles(layout())
        truthy(r.other == 1 or r.other == 5, "another ground floor room")
    end
end)

test("with no room inside the inner one is the farthest from the big room; no ground floor is the lowest", function()
    local l = layout()
    l.rooms[2].edge = true
    local roles = Stage.roles(l, function(a) return a end)
    eq(roles.inner, 1, "the office is farthest from the lobby")
    local up = { rooms = { room("a", 10, 1, 0, 0, 3, 3, true), room("b", 20, 2, 0, 0, 5, 5, true) } }
    eq(Stage.roles(up).big, 1, "the lowest floor's largest")
    local one = Stage.roles({ rooms = { room("shop", 40, 0, 0, 0, 8, 8, true) } })
    eq(one.big, 1)
    eq(one.inner, nil)
    eq(one.other, 1, "a building of one room: the other room is the big one")
    eq(one.entrance, nil, "no door")
end)

test("rooms of one square (a map's pillars) get no role; the big one is still the largest", function()
    local l = { rooms = {
        room("furnitureshowroom", 228, 0, 0, 0, 16, 16, true),
        room("empty", 1, 0, 15, 10, 16, 11, false),
        room("empty", 1, 0, 5, 0, 6, 1, true),
        room("office", 16, 0, 5, 13, 11, 16, false),
        room("bathroom", 2, 0, 9, 15, 11, 16, false),
        room("furniturestorage", 192, 0, 0, 16, 16, 28, true),
    } }
    local roles = Stage.roles(l, function(a) return a end)
    eq(roles.big, 1)
    eq(roles.inner, 4, "the office, not a pillar inside")
    eq(roles.other, 6)
    eq(roles.hall, 6, "no hall: the other room")
end)

test("the inner room is one with a door when the layout counts them; with none such, as before", function()
    local l = layout()
    for _, r in ipairs(l.rooms) do r.doors = 1 end
    l.rooms[2].doors = 0
    local roles = Stage.roles(l, function(a) return a end)
    eq(roles.inner, 1, "the room inside has no door: the farthest one with a door")
    for _, r in ipairs(l.rooms) do r.doors = 0 end
    eq(Stage.roles(l, function(a) return a end).inner, 2, "no room has one: the room inside")
end)

test("the inner room is a bathroom or a closet only when no other room will do", function()
    local l = layout()
    l.rooms[2].name = "bathroom"
    local roles = Stage.roles(l, function(a) return a end)
    eq(roles.inner, 1, "the room inside is a bathroom: the farthest other one")
    for i, r in ipairs(l.rooms) do if i ~= 2 and i ~= 3 then r.name = "closet" end end
    eq(Stage.roles(l, function(a) return a end).inner, 2, "all of them are: the room inside")
end)

-- A story mission at a building, the stage data of its facility given by the test, and fake hands that log the pieces.
local function setup(pieces)
    OA.StageData.evidence = { pieces = pieces }
    local record = OA.Store.ensure("p1", "P")
    record.trade = { stage = 1, milestones = 0, credits = 0, trust = 0 }
    local g = { calls = {}, loaded = true, requested = {}, woke = {} }
    Stage.game = g
    g.siteLoaded = function() return g.loaded end
    g.layout = function() return layout() end
    g.request = function(rec, m, it) g.requested[#g.requested + 1] = it.key end
    g.wake = function(list) g.woke[#g.woke + 1] = list end
    for _, kind in ipairs({ "tile", "item", "vehicle", "barricade", "corpse", "blood" }) do
        g[kind] = function(ctx, p)
            g.calls[#g.calls + 1] = kind .. (p.key and (ctx.keyId and ":key" .. ctx.keyId or ":nokey") or "")
            return true
        end
    end
    g.lock = function(ctx, p) g.calls[#g.calls + 1] = "lock"; return 77 end
    g.piece = function(ctx, p)
        g.calls[#g.calls + 1] = "piece"
        for _, it in ipairs(ctx.m.items) do
            if it.key == p.key and it.staged and not g.noRoom then it.staged = nil; it.placed = true end
        end
        return true
    end
    g.zombies = function(ctx, p)
        g.calls[#g.calls + 1] = "zombies"
        return { { x = 1, y = 2, z = 0 } }
    end
    local m = { id = "M1-1", story = "evidence", facility = "police", state = "open", level = 1,
        site = { x = 500, y = 0, z = 0, key = "500,0" }, items = { { key = "A", placed = false } } }
    return record, m, g
end

local POLICE = {
    { kind = "tile", sprite = "x", at = "entrance" },
    { kind = "lock", at = "inner" },
    { kind = "corpse", outfit = "Police", at = "other", key = true },
    { kind = "piece", key = "A", at = "inner" },
    { kind = "zombies", outfit = "Police", at = "hall", look = "fakeDead", wake = "pickup" },
}

test("a story mission at a building gets a stage and leaves its item to it; open ground and other missions do not", function()
    local record, m = setup(POLICE)
    Stage.begin(record, m)
    truthy(m.stage)
    eq(m.items[1].staged, true)
    local ground = { story = "evidence", facility = "police", site = { x = 1, y = 1, ground = true }, items = {} }
    Stage.begin(record, ground)
    eq(ground.stage, nil)
    local regular = { facility = "police", site = { x = 1, y = 1 }, items = {} }
    Stage.begin(record, regular)
    eq(regular.stage, nil)
    OA.StageData.evidence = nil
    local none = { story = "evidence", facility = "police", site = { x = 1, y = 1 }, items = {} }
    Stage.begin(record, none)
    eq(none.stage, nil, "a facility without stage data")
end)

test("the building is set up once it is loaded, in order, the key going to the body; zombies when the player is near", function()
    local record, m, g = setup(POLICE)
    Stage.begin(record, m)
    g.loaded = false
    Stage.look(record, m, 2000, 0, 20)
    eq(#g.calls, 0, "not loaded")
    g.loaded = true
    Stage.look(record, m, 2000, 0, 20)
    eq(table.concat(g.calls, ","), "tile,lock,corpse:key77,piece")
    eq(m.items[1].placed, true)
    eq(Stage.world()["500,0"], true)
    Stage.look(record, m, 2000, 0, 20)
    eq(#g.calls, 4, "once")
    Stage.look(record, m, 530, 0, 20)
    eq(g.calls[5], "zombies", "near enough")
    eq(m.stage.kept, true)
    eq(m.stage.wake.pickup[1].y, 2)
    Stage.look(record, m, 530, 0, 20)
    eq(#g.calls, 5)
end)

test("the rooms a set goes to are cleared first, before any piece; not outdoors, not a building set up before", function()
    local record, m, g = setup({
        { kind = "tile", sprite = "x", at = "entrance" },
        { kind = "set", at = "big", tiles = {} },
        { kind = "set", at = "yard", tiles = {} },
        { kind = "set", up = true, tiles = {} },
    })
    g.set = function() g.calls[#g.calls + 1] = "set"; return true end
    g.clear = function(ctx, p) g.calls[#g.calls + 1] = "clear:" .. tostring(p.at) .. (p.up and ":up" or "") end
    Stage.begin(record, m)
    Stage.look(record, m, 2000, 0, 20)
    eq(table.concat(g.calls, ","), "clear:big,clear:nil:up,tile,set,set,set")
    local again, m2, g2 = setup({ { kind = "set", at = "big", tiles = {} } })
    g2.set = function() return true end
    g2.clear = function() g2.calls[#g2.calls + 1] = "clear" end
    Stage.begin(again, m2)
    Stage.look(again, m2, 2000, 0, 20)
    eq(#g2.calls, 0, "set up before")
end)

test("a building's entrance is unlocked first, once; not on open ground", function()
    local record, m, g = setup(POLICE)
    g.unlock = function(ctx, p) g.calls[#g.calls + 1] = "unlock:" .. p.at end
    Stage.begin(record, m)
    Stage.look(record, m, 2000, 0, 20)
    eq(table.concat(g.calls, ","), "unlock:entrance,tile,lock,corpse:key77,piece")
    local ground, m2, g2 = setup({ { kind = "set", at = "ground", tiles = {} } })
    OA.StageData.evidence.ground = true
    m2.site.ground = true
    g2.unlock = function() g2.calls[#g2.calls + 1] = "unlock" end
    Stage.begin(ground, m2)
    Stage.look(ground, m2, 2000, 0, 20)
    eq(#g2.calls, 0, "open ground")
end)

test("open ground is cleared of its trees first, its sets with it, before any piece", function()
    local record, m, g = setup({ { kind = "set", at = "ground", tiles = {} } })
    OA.StageData.evidence.ground = true
    m.site.ground = true
    g.set = function() g.calls[#g.calls + 1] = "set"; return true end
    g.clear = function(ctx, p) g.calls[#g.calls + 1] = "clear:" .. tostring(p.at) end
    Stage.begin(record, m)
    Stage.look(record, m, 2000, 0, 20)
    eq(table.concat(g.calls, ","), "clear:ground,set")
end)

test("a building not set up before is claimed as the stage begins; one taken before the stage gets the item alone", function()
    local record, m, g = setup(POLICE)
    local claimed = {}
    g.claim = function(site) claimed[#claimed + 1] = site.key end
    g.occupied = function() return true end
    Stage.begin(record, m)
    eq(claimed[1], "500,0")
    Stage.look(record, m, 500, 0, 20)
    eq(table.concat(g.calls, ","), "piece")
    eq(m.stage.fresh, false)
    local again, m2, g2 = setup(POLICE)
    local none = 0
    g2.claim = function() none = none + 1 end
    Stage.begin(again, m2)
    eq(none, 0, "set up before: nothing to claim")
end)

test("a building set up before only gets the mission's item, and no zombies of its own", function()
    local record, m, g = setup(POLICE)
    Stage.world()["500,0"] = true
    Stage.begin(record, m)
    Stage.look(record, m, 500, 0, 20)
    eq(table.concat(g.calls, ","), "piece")
    eq(m.stage.kept, true)
end)

test("a piece that fails is left out; the item the stage could not put goes the usual way", function()
    local record, m, g = setup(POLICE)
    g.tile = function() error("square taken") end
    g.noRoom = true
    Stage.begin(record, m)
    Stage.look(record, m, 2000, 0, 20)
    eq(table.concat(g.calls, ","), "lock,corpse:key77,piece")
    eq(m.items[1].staged, nil)
    eq(g.requested[1], "A")
end)

test("what waits for an event wakes once", function()
    local record, m, g = setup(POLICE)
    Stage.begin(record, m)
    Stage.look(record, m, 530, 0, 20)
    Stage.event(record, m, "put")
    eq(#g.woke, 0)
    Stage.event(record, m, "pickup")
    eq(#g.woke, 1)
    eq(g.woke[1][1].x, 1)
    Stage.event(record, m, "pickup")
    eq(#g.woke, 1)
end)

test("a story's item first in hands says its monologue and wakes the stage", function()
    local record, m, g = setup(POLICE)
    Stage.begin(record, m)
    Stage.look(record, m, 530, 0, 20)
    M.state(record).active = m
    M.found(record, m, m.items[1], nil)
    eq(#g.woke, 1)
    truthy(OA.Comms.section(record).played.S1F_pickup, "the pickup monologue")
end)

test("the usual placing leaves a staged piece to the stage", function()
    require "OperationAcorn/Story/Game"
    local it = { key = "A", staged = true }
    OA.StoryGame.request(OA.Store.ensure("p1", "P"), { id = "M" }, it)
    eq(it.placed, nil)
end)

test("a building too large to load whole is set up once the player is near, with what is loaded", function()
    local record, m, g = setup(POLICE)
    local asked = {}
    g.siteLoaded = function(site, close) asked[#asked + 1] = close; return close end
    Stage.begin(record, m)
    Stage.look(record, m, 2000, 0, 20)
    eq(asked[1], false)
    eq(m.stage.placed, false)
    Stage.look(record, m, 530, 0, 20)
    eq(asked[2], true)
    eq(m.stage.placed, true)
end)

test("every piece of the stage data has hands in the game and goes to a place there is", function()
    require "OperationAcorn/Story/StageGame"
    require "OperationAcorn/Story/Data"
    local building = { big = true, inner = true, other = true, hall = true, entrance = true, back = true, yard = true }
    local ground = { ground = true }
    local n = 0
    for id, def in pairs(OA.StageData) do
        local places = def.ground and ground or building
        for i, p in ipairs(def.pieces) do
            local what = id .. " " .. i .. " " .. tostring(p.kind)
            truthy(type(OA.StageGame[p.kind]) == "function", what .. " has hands")
            truthy(p.kind == "barricade" or p.kind == "lockout" or places[p.at], what .. " goes to a place")
            truthy(Stage.PLACE_KINDS[p.kind] or p.kind == "zombies", what .. " is put at some time")
            if p.kind == "piece" then truthy(p.key, what .. " names its piece") end
            if p.kind == "line" then truthy(def.ground and p.step and p.length, what .. " runs on open ground") end
            if p.drop then truthy(p.kind == "board" and p.drop.during and p.drop.at, what .. " drops in a span") end
            n = n + 1
        end
        -- the stage belongs to a story (or a choice's option) whose site is of its kind
        local story, option = id:match("^(.-)_(%a)$")
        local sdef = OA.StoryData.STORIES[option and story or id]
        truthy(sdef, id .. " is a story's")
        local site = option and sdef.options[option].site or sdef.site
        eq(def.ground == true, site.ground == true, id .. ": open ground as its site")
    end
    truthy(n > 0)
    for _, id in ipairs({ "evidence", "clinic", "observation_a", "observation_b", "cooler", "gym", "ward", "cells",
        "handover" }) do
        truthy(OA.StageData[id], id .. " has its stage")
    end
end)

test("the stage is the story's, a choice's by its option, a revisit's the story's it goes back to; of its site's kind", function()
    require "OperationAcorn/Story/Data"
    local a, ground = { pieces = {} }, { ground = true, pieces = {} }
    OA.StageData.t_story, OA.StageData.t_choice_a, OA.StageData.t_ground = a, a, ground
    OA.StoryData.REVISITS.t_revisit = { from = "t_story" }
    local building = { x = 1, y = 1 }
    eq(Stage.defOf({ story = "t_story", site = building }), a)
    eq(Stage.defOf({ story = "t_choice", chosen = "a", site = building }), a)
    eq(Stage.defOf({ story = "t_choice", chosen = "b", site = building }), nil, "no stage for the other option")
    eq(Stage.defOf({ story = "t_revisit", site = building }), a)
    eq(Stage.defOf({ story = "t_story", site = { x = 1, y = 1, ground = true } }), nil, "a building's stage on open ground")
    eq(Stage.defOf({ story = "t_ground", site = { x = 1, y = 1, ground = true } }), ground)
    eq(Stage.defOf({ story = "t_ground", site = building }), nil)
    eq(Stage.defOf({ site = building }), nil, "not a story")
    OA.StageData.t_story, OA.StageData.t_choice_a, OA.StageData.t_ground = nil, nil, nil
    OA.StoryData.REVISITS.t_revisit = nil
end)

test("a small building: the other room is a roomy one first; with no hall and nothing roomy, the hall is the big room", function()
    -- a laundromat as the map has it: its main room, a back room, a closet and a bathroom
    local l = { rooms = {
        room("laundry", 84, 0, 0, 8, 6, 23, true),
        room("vacated", 42, 0, 0, 0, 6, 8, true),
        room("vacated", 6, 0, 0, 6, 3, 8, true),
        room("bathroom", 6, 0, 0, 8, 3, 10, true),
    } }
    for _ = 1, 10 do
        local roles = Stage.roles(l)
        eq(roles.big, 1)
        eq(roles.inner, 2, "the farthest from the big room")
        truthy(roles.other == 3 or roles.other == 4)
        eq(roles.hall, 1, "the big room: nothing roomy left")
    end
    l.rooms[#l.rooms + 1] = room("office", 20, 0, 6, 0, 10, 5, true)
    local roles = Stage.roles(l, function(a) return a end)
    eq(roles.inner, 5, "the office is now the farthest")
    eq(roles.other, 2, "the roomy one left")
    eq(roles.hall, 2)
end)

test("the back door is the outer door farthest from the big room, when there are two", function()
    local roles = Stage.roles(layout(), function(a) return a end)
    eq(roles.entrance, 1)
    eq(roles.back, 2)
    local one = layout()
    one.doors = { one.doors[1] }
    eq(Stage.roles(one).back, nil)
end)

test("what is spread over the wait wakes one by one across it, a plank falls at its point; each once", function()
    local record, m, g = setup({
        { kind = "board", at = "inner", drop = { during = "wait", at = 0.85 } },
        { kind = "zombies", at = "big", count = 3, during = "wait" },
    })
    g.board = function(ctx, p) return { x = 7, y = 7, z = 0, north = true } end
    g.zombies = function(ctx, p) return { { x = 1, y = 0, z = 0 }, { x = 2, y = 0, z = 0 }, { x = 3, y = 0, z = 0 } } end
    local planks = {}
    g.unplank = function(at) planks[#planks + 1] = at end
    Stage.begin(record, m)
    Stage.look(record, m, 530, 0, 20)
    Stage.progress(record, m, "wait", 0.1)
    eq(#g.woke, 0)
    Stage.progress(record, m, "wait", 0.3)
    eq(#g.woke, 1, "the first at a quarter")
    eq(g.woke[1][1].x, 1)
    Stage.progress(record, m, "other", 1)
    eq(#g.woke, 1, "another span")
    Stage.progress(record, m, "wait", 0.8)
    eq(#g.woke, 3, "the second at half, the third at three quarters")
    eq(#planks, 0)
    Stage.progress(record, m, "wait", 1)
    eq(#planks, 1)
    eq(planks[1].y, 7)
    Stage.progress(record, m, "wait", 1)
    eq(#g.woke, 3)
    eq(#planks, 1, "once")
end)

test("an event wakes its zombies with the stagger their piece gives", function()
    local record, m, g = setup({ { kind = "zombies", at = "other", count = 2, wake = "heli", stagger = 8 } })
    local staggers = {}
    g.wake = function(list, stagger) staggers[#staggers + 1] = stagger end
    Stage.begin(record, m)
    Stage.look(record, m, 530, 0, 20)
    Stage.event(record, m, "heli")
    eq(staggers[1], 8)
end)

test("a thing that sounds on an event sounds once, also when the event came before the stage was put", function()
    local CALL = { { kind = "call", at = "big", sprite = "radio", on = "enter", sound = "oa.stage.radio", secs = 6 } }
    local record, m, g = setup(CALL)
    local sounded = {}
    g.call = function() return { x = 4, y = 5, z = 0 } end
    g.sound = function(list) sounded[#sounded + 1] = list end
    Stage.begin(record, m)
    Stage.look(record, m, 2000, 0, 20)
    Stage.event(record, m, "pickup")
    eq(#sounded, 0, "another event")
    Stage.event(record, m, "enter")
    eq(#sounded, 1)
    eq(sounded[1][1].x, 4)
    eq(sounded[1][1].sound, "oa.stage.radio")
    eq(sounded[1][1].secs, 6)
    Stage.event(record, m, "enter")
    eq(#sounded, 1, "once")
    -- the circle entered while the ground was not loaded yet: it sounds as the stage is put (another building)
    record, m, g = setup(CALL)
    sounded = {}
    g.call = function() return { x = 4, y = 5, z = 0 } end
    g.sound = function(list) sounded[#sounded + 1] = list end
    g.loaded = false
    m.site.key = "600,0"
    Stage.begin(record, m)
    Stage.event(record, m, "enter")
    eq(#sounded, 0)
    g.loaded = true
    Stage.look(record, m, 2000, 0, 20)
    eq(#sounded, 1)
    -- a set that did not go down: nothing to sound
    record, m, g = setup(CALL)
    g.call = function() return nil end
    g.sound = function() error("no sound") end
    Stage.begin(record, m)
    Stage.look(record, m, 2000, 0, 20)
    Stage.event(record, m, "enter")
end)

test("doors boarded with `last`: the last plank off one of them makes the event and the monologue once", function()
    local record, m, g = setup({ { kind = "board", at = "hall", last = "plank" },
        { kind = "zombies", at = "other", wake = "plank" } })
    m.story = "cells"
    OA.StageData.cells = OA.StageData.evidence
    local bare = { false, false }
    g.board = function()
        return { x = 1, y = 1, z = 0, all = { { x = 1, y = 1, z = 0 }, { x = 2, y = 1, z = 0 } } }
    end
    g.unboardedAt = function(at) return bare[at.x] end
    Stage.begin(record, m)
    Stage.look(record, m, 530, 0, 20)
    M.state(record).active = m
    record.missions = record.missions or {}
    local live = OA.Missions.live
    OA.Missions.live = function() return { m } end
    Stage.unboarded(record)
    eq(#g.woke, 0, "planks left on both")
    bare[2] = true
    Stage.unboarded(record)
    eq(#g.woke, 1, "one door freed")
    truthy(OA.Comms.section(record).played.S7F_plank, "the monologue")
    bare[1] = true
    Stage.unboarded(record)
    eq(#g.woke, 1, "once")
    OA.Missions.live = live
end)

test("two boarded rooms with `last`: a door of either freed makes the event", function()
    local record, m, g = setup({ { kind = "board", at = "other", last = "plank" },
        { kind = "board", at = "inner", last = "plank" }, { kind = "zombies", at = "other", wake = "plank" } })
    m.story = "cells"
    OA.StageData.cells = OA.StageData.evidence
    local n = 0
    g.board = function()
        n = n + 1
        return { x = n, y = 1, z = 0, all = { { x = n, y = 1, z = 0 } } }
    end
    local bare = {}
    g.unboardedAt = function(at) return bare[at.x] end
    Stage.begin(record, m)
    Stage.look(record, m, 530, 0, 20)
    eq(#m.stage.boarded.doors, 2, "both rooms' doors")
    local live = OA.Missions.live
    OA.Missions.live = function() return { m } end
    bare[1] = true
    Stage.unboarded(record)
    eq(#g.woke, 1, "the first room's door")
    OA.Missions.live = live
end)

test("a container filling outside the building a piece waits for costs no search of the records", function()
    require "OperationAcorn/Story/Game"
    local record = OA.Store.ensure("p1", "P")
    record.missions = { active = { id = "M", items = { { key = "A", mode = "container", placed = false,
        x = 15, y = 15, x1 = 10, y1 = 10, z1 = 0, x2 = 20, y2 = 20, z2 = 0 } } } }
    OA.StoryGame.rebuildWaiting()
    local searched, players = 0, OA.Store.players
    OA.Store.players = function() searched = searched + 1; return players() end
    local was = instanceof
    instanceof = function() return true end
    local function container(x, y)
        local sq = { getBuilding = function() return true end, getX = function() return x end,
            getY = function() return y end, getZ = function() return 0 end }
        return { getSourceGrid = function() return sq end, hasRoomFor = function() return false end }
    end
    OA.StoryGame.onFill("kitchen", "crate", container(50, 50))
    eq(searched, 0, "outside the box: only comparisons")
    OA.StoryGame.onFill("kitchen", "crate", container(15, 15))
    eq(searched, 1, "inside the box the record is looked up")
    record.missions.active.items[1].placed = true
    OA.StoryGame.onFill("kitchen", "crate", container(15, 15))
    OA.StoryGame.onFill("kitchen", "crate", container(15, 15))
    eq(searched, 2, "a piece placed meanwhile is dropped from the waiting list at the first fill")
    OA.Store.players = players
    instanceof = was
end)
