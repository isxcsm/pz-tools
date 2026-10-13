-- The light of the mod's things (shared Lights): one game light source a square while lit, set again only when it is
-- gone from the game's list or changed, taken off with its thing; a terminal's screen and a machine's lamps by look.
require "OperationAcorn/Core"
require "OperationAcorn/Lights"
require "OperationAcorn/Machines/Data"
local OA = OperationAcorn
local Lights, Data = OA.Lights, OA.Machines.Data

local function fakeCell()
    local list, added, removed = {}, 0, 0
    local positions = {
        contains = function(self, source)
            for _, s in ipairs(list) do if s == source then return true end end
            return false
        end,
    }
    local cell = {
        getLamppostPositions = function() return positions end,
        addLamppost = function(self, x, y, z, r, g, b, radius)
            added = added + 1
            local source = { x = x, y = y, z = z, r = r, radius = radius }
            list[#list + 1] = source
            return source
        end,
        removeLamppost = function(self, source)
            removed = removed + 1
            for i = #list, 1, -1 do if list[i] == source then table.remove(list, i) end end
        end,
    }
    _G.getCell = function() return cell end
    return {
        list = list,
        added = function() return added end,
        removed = function() return removed end,
        -- the game drops a light whose square left the loaded area
        forget = function() for i = #list, 1, -1 do list[i] = nil end end,
    }
end

local function thing(x, y)
    local square = { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end }
    return { getSquare = function() return square end }
end

local RED, BLUE = { 1, 0, 0, 3 }, { 0, 0, 1, 4 }

test("a thing's light is set once, changed when its look does, and put back when the game dropped it", function()
    local cell = fakeCell()
    local a = thing(10, 20)
    Lights.set(a, RED)
    eq(cell.added(), 1)
    eq(cell.list[1].x, 10); eq(cell.list[1].radius, 3)
    Lights.set(a, RED)
    eq(cell.added(), 1, "the same light again is nothing")
    eq(Lights.of(a), RED)
    Lights.set(a, BLUE)
    eq(cell.added(), 2); eq(cell.removed(), 1, "a changed light replaces the old one")
    eq(#cell.list, 1)
    cell.forget()
    Lights.set(a, BLUE)
    eq(cell.added(), 3, "the square came back: the light is set again")
    Lights.set(a, nil)
    eq(#cell.list, 0, "off")
    eq(Lights.of(a), nil)
end)

test("a light goes with its thing, not with another thing taken off the square", function()
    local cell = fakeCell()
    local a = thing(1, 2)
    Lights.set(a, RED)
    local other = { getSquare = a.getSquare }
    Lights.onRemoved(other)
    eq(#cell.list, 1, "something else on the square")
    Lights.onRemoved(a)
    eq(#cell.list, 0)
    eq(Lights.of(a), nil)
    Lights.onRemoved(a)
    eq(cell.removed(), 1, "once")
end)

test("nothing is lit on the server, and without a cell nothing breaks", function()
    local cell = fakeCell()
    local saved = _G.isServer
    _G.isServer = function() return true end
    Lights.set(thing(5, 5), RED)
    _G.isServer = saved
    eq(cell.added(), 0)
    _G.getCell = function() return nil end
    Lights.set(thing(6, 6), RED)
end)

test("the machines with lamps light by their look; the others never", function()
    for _, kind in ipairs({ "bulkShredder", "cutter", "woodSaw", "propaneRefiner", "oilRefiner" }) do
        local running, ready = Data.lightOf(kind, true), Data.lightOf(kind, "ready")
        truthy(running and ready, kind)
        truthy(running[4] > ready[4], kind .. ": running lights further than waiting")
        eq(Data.lightOf(kind, false), nil)
    end
    for _, kind in ipairs({ "shredBench", "researchStorage", "rainStorage", "lure" }) do
        eq(Data.lightOf(kind, true), nil, kind)
        eq(Data.lightOf(kind, "ready"), nil, kind)
    end
end)
