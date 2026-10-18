-- What the trade part asks of the world through the extension API: whether a square is free or clear, the nearest clear
-- spot for a box, a place beside the crate's, and the boxes that are gone. The API is a fake that records the area and
-- the conditions of each call and answers from a script; what the fake game square tells is only used for the reasons.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Things"
local OA = OperationAcorn
local Objects, Things, Boxes = OA.Trade.Objects, OA.Trade.Things, OA.Trade.Boxes

local calls, answer, byData

-- `reply(area, filter)` gives the square (and ring) the fake nearest finds, or nil.
local function api(reply)
    calls = {}
    answer = reply
    PZExtAPI = { version = OA.API_VERSION, client = function() return "h" end,
        squares = { nearest = function(area, filter)
            calls[#calls + 1] = { area = area, filter = filter }
            return answer(area, filter)
        end },
        objects = { byData = function(key, where) return byData(key, where) end } }
end

local function square(fields)
    local sq = { x = 10, y = 20, z = 0, outside = true, water = false, floor = true, vehicle = false, free = true }
    for k, v in pairs(fields or {}) do sq[k] = v end
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return self.z end
    function sq:isOutside() return self.outside end
    function sq:isWaterSquare() return self.water end
    function sq:TreatAsSolidFloor() return self.floor end
    function sq:isVehicleIntersecting() return self.vehicle end
    function sq:getVehicleContainer() return nil end
    function sq:isFree() return self.free end
    return sq
end

local function none() return nil end

test("a square is free when the API finds it among its own: one call, the free conditions", function()
    local sq = square()
    api(function() return sq end)
    eq(Objects.free(sq), true)
    eq(Objects.isFree(sq), true)
    eq(#calls, 2)
    eq(calls[1].area.list[1], 10)
    eq(calls[1].area.list[2], 20)
    eq(calls[1].area.list[3], 0)
    local f = calls[1].filter
    eq(f.free, true)
    eq(f.solidFloor, true)
    eq(f.water, false)
    eq(f.vehicle, false)
    eq(f.noObjectData, Objects.KIND)
    truthy(calls[1].filter == calls[2].filter, "the same table every time")
end)

test("a square that is not free says why, in the order the game stops at it", function()
    api(none)
    local ok, why = Objects.free(nil)
    eq(ok, false)
    eq(why, "notLoaded")
    eq(select(2, Objects.free(square({ water = true }))), "water")
    eq(select(2, Objects.free(square({ floor = false }))), "floor")
    eq(select(2, Objects.free(square({ vehicle = true }))), "vehicle")
    eq(select(2, Objects.free(square({ free = false }))), "blocked")
    eq(select(2, Objects.free(square())), "occupied")
    eq(Objects.isFree(square()), false)
    eq(Objects.isFree(nil), false)
end)

test("a square can be come up to when one of the eight round it is free", function()
    api(function() return square() end)
    eq(Objects.reachable(square()), true)
    truthy(calls[1].filter.around ~= nil)
    eq(calls[1].filter.around.free, true)
    eq(calls[1].filter.around.noObjectData, Objects.KIND)
    api(none)
    eq(Objects.reachable(square()), false)
end)

test("a box is clear on the ground floor with open ground round it: one call, then the reason", function()
    local sq = square()
    api(function() return sq end)
    eq(Objects.clearSquare(sq), true)
    eq(#calls, 1)
    local f = calls[1].filter
    eq(f.outside, true)
    eq(f.free, true)
    eq(f.around.free, true)
    eq(f.clear.r, Objects.CLEAR_RADIUS)
    eq(f.clear.filter.building, "none")
    eq(f.clear.filter.room, "none")
    eq(f.clear.filter.tree, false)
    eq(Objects.isClear(sq), true)
    truthy(calls[1].filter == calls[2].filter, "the same table every time")
    eq(Objects.isClear(square({ z = 1 })), false)
    eq(#calls, 2, "another level is told without asking")
    local ok, why = Objects.clearSquare(square({ z = 1 }))
    eq(why, "level")
    eq(select(2, Objects.clearSquare(nil)), "notLoaded")
end)

-- Which test of a square a condition table is: the whole clearance, one part of it, or the squares round it.
local function kindOf(filter)
    local c = filter.clear
    if c then
        if c.filter.building and c.filter.tree ~= nil then return "whole" end
        if c.filter.building then return "building" end
        if c.filter.tree ~= nil then return "tree" end
        return "notLoaded"
    end
    if filter.around and filter.free == nil then return "reachable" end
    return "free"
end

test("a box that is not clear says why: indoors, not free, not reachable, then the parts of the clearance", function()
    local sq = square()
    -- the whole clearance fails, and so does the part named
    local function failing(part)
        return function(area, filter)
            local kind = kindOf(filter)
            if kind == "whole" or kind == part then return nil end
            return sq
        end
    end
    api(failing("building"))
    eq(select(2, Objects.clearSquare(sq)), "building")
    api(failing("tree"))
    eq(select(2, Objects.clearSquare(sq)), "tree")
    api(failing("notLoaded"))
    eq(select(2, Objects.clearSquare(sq)), "notLoaded")
    api(failing("reachable"))
    eq(select(2, Objects.clearSquare(sq)), "blocked")
    api(failing("free"))
    eq(select(2, Objects.clearSquare(sq)), "occupied")
    api(none)
    eq(select(2, Objects.clearSquare(square({ outside = false }))), "inside")
    eq(select(2, Objects.clearSquare(square({ water = true }))), "water")
end)

test("a spot for a box is looked for with the full clearance first, then less", function()
    local found = square({ x = 12, y = 20 })
    api(function(area, filter)
        if filter.clear.r == 1 then return found, 5 end
        return nil
    end)
    local sq, clearance, r = Objects.findClear(10, 20, 30)
    eq(sq, found)
    eq(clearance, 1)
    eq(r, 5)
    eq(#calls, 3)
    eq(calls[1].filter.clear.r, 3)
    eq(calls[2].filter.clear.r, 2)
    eq(calls[3].filter.clear.r, 1)
    eq(calls[1].area.x, 10)
    eq(calls[1].area.y, 20)
    eq(calls[1].area.z, 0)
    eq(calls[1].area.to, 30)
    eq(calls[1].filter.moving, nil)
    Objects.findClear(10, 20, nil, true)
    eq(calls[4].area.to, 30, "30 tiles unless told")
    eq(calls[4].filter.moving, false, "empty: no one on it")
    api(none)
    eq(Objects.findClear(10, 20, 8), nil)
    eq(#calls, 4, "all four clearances")
    eq(calls[4].filter.clear.r, 0)
    eq(calls[4].area.to, 8)
end)

test("a place beside the crate's: outdoors first, then anywhere, the spot itself left out", function()
    local indoors, outdoors = square({ x = 11 }), square({ x = 12 })
    api(function(area, filter)
        if filter.outside then return nil end
        return indoors
    end)
    eq(Objects.findBeside(10, 20, 0), indoors)
    eq(#calls, 2)
    eq(calls[1].filter.outside, true)
    eq(calls[2].filter.outside, nil)
    eq(calls[1].area.from, 1, "ring 0 is the spot itself")
    eq(calls[1].area.to, 4)
    eq(calls[1].area.x, 10)
    eq(calls[1].filter.moving, false)
    eq(calls[1].filter.around.free, true)
    api(function() return outdoors end)
    eq(Objects.findBeside(10, 20, 0, 5), outdoors)
    eq(#calls, 1, "the outdoor one needs no second call")
    eq(calls[1].area.to, 5)
    api(none)
    eq(Objects.findBeside(10, 20, 0), nil)
end)

test("the nearest free square with no one on it", function()
    local found = square()
    api(function() return found, 3 end)
    local sq, r = Objects.findFree(10, 20, 0, 12)
    eq(sq, found)
    eq(r, 3)
    eq(calls[1].area.to, 12)
    eq(calls[1].filter.moving, false)
    eq(calls[1].filter.free, true)
end)

test("the boxes whose squares are loaded and have no object are destroyed, the ones on unloaded squares are left", function()
    local record = OA.Store.ensure("wq1", "Tester")
    local here = Boxes.add(record, { x = 10, y = 20, z = 0 })
    local gone = Boxes.add(record, { x = 11, y = 20, z = 0 })
    local away = Boxes.add(record, { x = 500, y = 20, z = 0 })
    local carried = Boxes.add(record, { state = "carried", x = 12, y = 20, z = 0 })
    api(none)
    local asked
    byData = function(key, where)
        asked = { key = key, where = where }
        local found = {}
        for i = 1, #where, 4 do
            local x = where[i]
            found[#found + 1] = x == 10 and {} or (x == 500 and "unloaded" or false)
        end
        return found
    end
    local destroyed = {}
    local real = Things.destroyed
    Things.destroyed = function(thing) destroyed[#destroyed + 1] = thing end
    local n = Things.reconcile(record)
    Things.destroyed = real
    eq(n, 1)
    eq(destroyed[1].box, gone.id)
    eq(destroyed[1].x, 11)
    eq(destroyed[1].data[Objects.OWNER], record.id)
    eq(asked.key, Objects.BOX)
    eq(#asked.where, 12, "three boxes: the carried one is not asked about")
    eq(asked.where[4], here.id)
    eq(asked.where[8], gone.id)
    eq(asked.where[12], away.id)
    eq(carried.state, "carried")
    -- nothing placed: no call at all
    local empty = OA.Store.ensure("wq2", "Tester")
    byData = function() error("no call wanted") end
    eq(Things.reconcile(empty), 0)
end)
