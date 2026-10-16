-- The search watch (client/OperationAcorn/Economy/Searched.lua) on a fake loot window: the containers it lists are
-- marked, a look is made only on coming into a building or a container marked, and what a look found waits until the
-- character steps away from the containers that made it.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Buildings"
local OA = OperationAcorn

local function list(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end

function instanceof(object, class)
    return type(object) == "table" and object.classes ~= nil and object.classes[class] == true
end

-- A world object holding `n` containers, its mod data made on asking as the game does.
local function furniture(n)
    local o = { classes = { IsoObject = true }, containers = {} }
    o.hasModData = function() return o.data ~= nil end
    o.getModData = function()
        o.data = o.data or {}
        return o.data
    end
    o.getContainerCount = function() return #o.containers end
    o.getContainerByIndex = function(_, i) return o.containers[i + 1] end
    o.getSquare = function() return o.square end
    for i = 1, n or 1 do o.containers[i] = { getParent = function() return o end } end
    return o
end

-- One building of one room over `squares` (lists of objects), keyed by its def ("v:700,800" without the API).
local function building(squares)
    local def
    local b = { getDef = function() return def end }
    local sqs = {}
    for i, objects in ipairs(squares) do
        sqs[i] = { getObjects = function() return list(objects) end, getZ = function() return 0 end,
            getBuilding = function() return b end }
        for _, o in ipairs(objects) do o.square = sqs[i] end
    end
    local iso = { getSquares = function() return list(sqs) end }
    def = { getRooms = function() return list({ { getIsoRoom = function() return iso end } }) end,
        isFullyStreamedIn = function() return true end, getX = function() return 700 end, getY = function() return 800 end }
    return { getBuilding = function() return b end }
end

-- The character, standing on a square of `room` (nil: outside), the square changed by `step`.
local function character()
    local c = { said = {}, n = 0 }
    c.getPlayerNum = function() return 0 end
    c.isDead = function() return false end
    c.isLocalPlayer = function() return true end
    c.getZ = function() return 0 end
    c.getModData = function() return { OA_Id = "w" } end
    c.Say = function(_, text) c.said[#c.said + 1] = text end
    c.getCurrentSquare = function() return c.square end
    -- onto a square of `room` (nil: outside, or with `indoor` a roofed square with no room, as a stairwell), on floor z
    c.step = function(room, z, indoor)
        c.n = c.n + 1
        local n = c.n
        c.square = { getRoom = function() return room end, getX = function() return n end, getY = function() return 0 end,
            getZ = function() return z or 0 end, isOutside = function() return room == nil and not indoor end }
    end
    return c
end

local page, ch, sent, touched, looks

-- A fake loot window (the watch wraps it once): its refresh lists `page.near` (containers), asking checkExplored about
-- each.
local function load()
    if OA.SearchWatch then return end
    local vanilla = {}
    function vanilla:checkExplored() end
    function vanilla:refreshBackpacks()
        for _, c in ipairs(self.near) do self:checkExplored(c, ch) end
    end
    ISInventoryPage = vanilla
    local real = require
    require = function(file)
        if string.find(file, "^ISUI/") then return true end
        return real(file)
    end
    local ok, err = pcall(real, "OperationAcorn/Economy/Searched")
    require = real
    if not ok then error(err, 0) end
end

local function setup()
    PZExtAPI = nil
    OA.Buildings.reset()
    ch = character()
    getSpecificPlayer = function() return ch end
    getTimestampMs = function() return 1000000 end
    load()
    OA.SearchWatch.reset()
    page = setmetatable({ player = 0, onCharacter = false, near = {} }, { __index = ISInventoryPage })
    sent, touched = {}, {}
    OA.Sync.send = function(_, command, args)
        if command == "story_touched" then
            touched[#touched + 1] = args.key
        else
            sent[#sent + 1] = { command = command, key = args.key }
        end
    end
    looks = 0
    local tick = OA.Buildings.tick
    OA.Buildings.tick = function(...)
        looks = looks + 1
        return tick(...)
    end
    return tick
end

local function refresh(near)
    page.near = near or {}
    page:refreshBackpacks()
end

test("a container the loot window lists is marked once, and the building looked at only as something changes", function()
    local tick = setup()
    local a, b = furniture(2), furniture(1)
    local room = building({ { a }, { b } })
    ch.step(room)
    refresh({})
    eq(looks, 1, "coming in is a look")
    refresh({})
    eq(looks, 1, "a turn on the same square, nothing new: no look")
    refresh({ a.containers[1], a.containers[2] })
    eq(OA.Buildings.opened(a.containers[1]), true)
    eq(looks, 2, "a container marked is a look")
    refresh({ a.containers[1], a.containers[2] })
    eq(looks, 2, "marked already: no look")
    eq(#touched, 1, "the story is told the building was searched, once")
    eq(touched[1], "700,800", "by its def's corner")
    refresh({ b.containers[1] })
    eq(#touched, 1, "once a session")
    OA.Buildings.tick = tick
end)

test("the building all searched is told as the character steps away from the last containers, not before", function()
    local tick = setup()
    local a, b = furniture(1), furniture(1)
    local room = building({ { a }, { b } })
    ch.step(room)
    refresh({ a.containers[1] })
    refresh({ b.containers[1] })
    eq(#sent, 0, "still at the last one")
    refresh({ b.containers[1] })
    eq(#sent, 0, "a turn there")
    ch.step(room)
    refresh({ a.containers[1] })
    eq(#sent, 1, "stepped away from it (another one in reach does not hold it)")
    eq(sent[1].command, "searched"); eq(sent[1].key, "v:700,800")
    ch.step(room)
    refresh({})
    eq(#sent, 1, "told once")
    OA.Buildings.tick = tick
end)

test("stepping out of the building from beside the last container tells it", function()
    local tick = setup()
    local a = furniture(1)
    local room = building({ { a } })
    ch.step(room)
    refresh({ a.containers[1] })
    eq(#sent, 0)
    ch.step(nil)
    refresh({})
    eq(#sent, 1)
    eq(sent[1].key, "v:700,800")
    OA.Buildings.tick = tick
end)

test("a building all searched before the character comes in is asked about at once, once", function()
    local tick = setup()
    local a = furniture(1)
    OA.Buildings.mark(a.containers[1])
    local room = building({ { a } })
    ch.step(room)
    refresh({})
    eq(#sent, 1, "asked on coming in")
    ch.step(room)
    refresh({})
    eq(#sent, 1)
    OA.Buildings.tick = tick
end)

test("a floor's stage line waits for the step away, and goes with the building", function()
    local tick = setup()
    local said = {}
    OA.Upgrades = OA.Upgrades or {}
    local senses = OA.Upgrades.Senses
    OA.Upgrades.Senses = {
        ledgerLook = function(_, _, opened) return opened > 0 and "LINE" or nil end,
        ledgerSay = function(_, line) said[#said + 1] = line return true end,
        ledgerOutline = function() return false end,
        ledgerLeave = function() end,
    }
    local a, b, c = furniture(1), furniture(1), furniture(1)
    local room = building({ { a }, { b }, { c } })
    ch.step(room)
    refresh({ a.containers[1] })
    eq(#said, 0, "not while looting it")
    ch.step(room)
    refresh({})
    eq(said[1], "LINE")
    -- held, then the character leaves: a floor's line is out of place outside
    refresh({ b.containers[1] })
    ch.step(nil)
    refresh({})
    eq(#said, 1)
    OA.Upgrades.Senses = senses
    OA.Buildings.tick = tick
end)

test("a stairwell is still the building: going up is another floor, not leaving and coming in", function()
    local tick = setup()
    local calls = { leave = 0, floor = 0, look = 0 }
    OA.Upgrades = OA.Upgrades or {}
    local senses = OA.Upgrades.Senses
    OA.Upgrades.Senses = {
        ledgerLook = function() calls.look = calls.look + 1 return nil end,
        ledgerSay = function() return true end,
        ledgerOutline = function() return false end,
        ledgerLeave = function() calls.leave = calls.leave + 1 end,
        ledgerFloor = function() calls.floor = calls.floor + 1 end,
        ledgerDone = function() end,
    }
    local a = furniture(1)
    local room = building({ { a } })
    ch.step(room, 0)
    refresh({})
    eq(calls.leave, 1, "coming in")
    ch.step(nil, 0, true)
    refresh({})
    eq(calls.leave, 1, "the stairwell is not leaving")
    eq(calls.floor, 0)
    ch.step(room, 1)
    refresh({})
    eq(calls.leave, 1)
    eq(calls.floor, 1, "another floor of the same building")
    ch.step(room, 1)
    refresh({})
    eq(calls.floor, 1, "the same floor")
    ch.step(nil, 0)
    refresh({})
    eq(calls.leave, 2, "out under the sky: left")
    OA.Upgrades.Senses = senses
    OA.Buildings.tick = tick
end)

test("the building all searched says so with the economy's check", function()
    local tick = setup()
    local done = 0
    OA.Upgrades = OA.Upgrades or {}
    local senses = OA.Upgrades.Senses
    OA.Upgrades.Senses = {
        ledgerLook = function() return nil end,
        ledgerSay = function() return true end,
        ledgerOutline = function() return false end,
        ledgerLeave = function() end,
        ledgerFloor = function() end,
        ledgerDone = function() done = done + 1 end,
    }
    local a = furniture(1)
    local room = building({ { a } })
    ch.step(room)
    refresh({ a.containers[1] })
    eq(done, 0)
    ch.step(room)
    refresh({})
    eq(done, 1)
    eq(#sent, 1)
    OA.Upgrades.Senses = senses
    OA.Buildings.tick = tick
end)

test("the character's own inventory page is left alone", function()
    local tick = setup()
    local a = furniture(1)
    ch.step(building({ { a } }))
    page.onCharacter = true
    refresh({ a.containers[1] })
    eq(looks, 0)
    OA.Buildings.tick = tick
end)
