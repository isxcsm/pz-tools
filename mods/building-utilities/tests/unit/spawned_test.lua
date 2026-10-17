-- Spawned boxes (BU.Spawned): a box beside a map's generator, rolled for on its own, on a square of the generator's
-- room with nothing on it but floor and plain walls, not a doorway nor before a door, indoors against a wall where a
-- free square has one, else on any; the generator keeping another free square. Where each stands is kept by its cell and found again near a character. Also:
-- a sprite's load functions all run (BU.onLoadSprite), a bare box (Panels.isBare), and a unit's state lost with its
-- record reads as spent (Units.lost).
require "BuildingUtilities/Core"
require "BuildingUtilities/Spawned"
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Spawned, Panels = BU.Spawned, BU.Panels

local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end

local function flags(names)
    local set = {}
    for _, name in ipairs(names or {}) do set[name] = true end
    return { has = function(_, flag) return set[flag] == true end }
end

-- A grid of squares by "x,y": { room = <name or nil>, walls = { "N", "W" }, door = "N"/"W" (an opening in that wall),
-- doorway = true, things = n (other objects), lying = n (items on the floor), stairs = true, noFloor = true }.
local function grid(spec)
    IsoFlagType = setmetatable({}, { __index = function(_, k) return k end })
    local squares, added = {}, {}
    local rooms = {}
    local function at(x, y) return squares[x .. "," .. y] end
    for key, s in pairs(spec) do
        local x, y = key:match("(-?%d+),(-?%d+)")
        x, y = tonumber(x), tonumber(y)
        local walls = {}
        for _, side in ipairs(s.walls or {}) do
            local names = { side == "N" and "WallN" or "WallW" }
            if s.door == side then names[#names + 1] = side == "N" and "DoorWallN" or "DoorWallW" end
            walls[side] = { getProperties = function() return flags(names) end, isFloor = function() return false end }
        end
        local objects = { { isFloor = function() return true end, getProperties = function() return flags() end } }
        for _, side in ipairs({ "N", "W" }) do if walls[side] then objects[#objects + 1] = walls[side] end end
        for _ = 1, s.things or 0 do
            objects[#objects + 1] = { isFloor = function() return false end, getProperties = function() return flags({ "solidtrans" }) end }
        end
        if s.room then rooms[s.room] = rooms[s.room] or {} end
        local square
        square = {
            getX = function() return x end, getY = function() return y end, getZ = function() return 0 end,
            getRoom = function() return s.room and rooms[s.room] or nil end,
            getBuilding = function() return s.room and {} or nil end,
            getFloor = function() return not s.noFloor and objects[1] or nil end,
            HasStairs = function() return s.stairs == true end,
            isDoorSquare = function() return s.doorway == true end,
            getWorldObjects = function() return list(s.lying and { 1 } or {}) end,
            getObjects = function() return list(objects) end,
            getWall = function(_, north) return walls[north and "N" or "W"] end,
            -- a wall between two squares next to each other: the north one's south is the south one's N wall
            isWallTo = function(_, other)
                local ox, oy = other:getX(), other:getY()
                if ox == x and oy == y - 1 then return walls.N ~= nil end
                if ox == x - 1 and oy == y then return walls.W ~= nil end
                if ox == x and oy == y + 1 then return other:getWall(true) ~= nil end
                if ox == x + 1 and oy == y then return other:getWall(false) ~= nil end
                return false
            end,
            isDoorTo = function(_, other)
                local ox, oy = other:getX(), other:getY()
                if ox == x and oy == y - 1 then return s.door == "N" end
                if ox == x - 1 and oy == y then return s.door == "W" end
                local o = spec[ox .. "," .. oy]
                if ox == x and oy == y + 1 then return o ~= nil and o.door == "N" end
                if ox == x + 1 and oy == y then return o ~= nil and o.door == "W" end
                return false
            end,
            isWindowTo = function() return false end,
            AddTileObject = function(_, object) added[#added + 1] = { x = x, y = y, object = object } end,
        }
        squares[x .. "," .. y] = square
    end
    getCell = function()
        return { getGridSquare = function(_, x, y, z) return z == 0 and at(x, y) or nil end }
    end
    IsoObject = { new = function(_, sprite) return { sprite = sprite } end }
    return at, added
end

-- A room of 5 by 5 (0..4), walls on its north (y 0) and west (x 0) edges and, from the squares past it, east and
-- south; the generator in the middle unless the test moves it.
local function room(extra)
    local spec = {}
    for x = -1, 5 do
        for y = -1, 5 do
            local inside = x >= 0 and x <= 4 and y >= 0 and y <= 4
            local s = { room = inside and "garage" or nil }
            if inside then
                s.walls = {}
                if y == 0 then s.walls[#s.walls + 1] = "N" end
                if x == 0 then s.walls[#s.walls + 1] = "W" end
            elseif x == 5 and y >= 0 and y <= 4 then
                s.walls = { "W" }
            elseif y == 5 and x >= 0 and x <= 4 then
                s.walls = { "N" }
            end
            spec[x .. "," .. y] = s
        end
    end
    for key, s in pairs(extra or {}) do spec[key] = s end
    return spec
end

local function keys(choices)
    local result = {}
    for _, c in ipairs(choices) do
        result[#result + 1] = c.square:getX() .. "," .. c.square:getY() .. c.side .. (c.outdoor and "o" or "")
    end
    table.sort(result)
    return table.concat(result, " ")
end

test("indoors a box takes a free square beside the generator against a wall, facing away from it", function()
    local at = grid(room())
    -- the generator in the north-west corner's neighbour: (1,0) against the north wall
    eq(keys(Spawned.places(at(1, 0))), "0,0S 0,1E 2,0S", "against the north wall, the west wall, or the corner")
    local middle = Spawned.places(at(2, 2))
    eq(#middle, 8, "in the middle of the room no square beside it has a wall: any free one")
    eq(middle[1].outdoor, false, "indoors: its indoor look, on the floor")
end)

test("not a doorway, not before a door, not another room, not a square with things or items on it", function()
    local spec = room({
        ["0,1"] = { room = "garage", walls = { "W" }, door = "W" },
        ["2,0"] = { room = "garage", walls = { "N" }, things = 1 },
        ["0,0"] = { room = "garage", walls = { "N", "W" }, lying = true },
    })
    local at = grid(spec)
    eq(keys(Spawned.places(at(1, 0))), "1,1S 2,1S",
        "the door's square, the shelf's and the one with an item on it are out; no wall left: any free one")
    spec["2,0"] = { room = "hall", walls = { "N" } }
    spec["2,1"] = { room = "hall" }
    at = grid(spec)
    eq(keys(Spawned.places(at(1, 0))), "", "another room is out, and one free square is the generator's")
end)

test("outdoors any free square beside it, facing south without a wall", function()
    local spec = {}
    for x = 0, 2 do for y = 0, 2 do spec[x .. "," .. y] = {} end end
    spec["0,0"].things = 1
    local at = grid(spec)
    eq(#Spawned.places(at(1, 1)), 7, "all but the one with a thing on it")
    eq(Spawned.places(at(1, 1))[1].side, "S")
    truthy(Spawned.places(at(1, 1))[1].outdoor)
end)

test("rolled as often as the generator stands there, by the option; none when one free square is left", function()
    local at, added = grid(room())
    local roll = 0.5
    ZombRandFloat = function() return roll end
    ZombRand = function() return 0 end
    eq(Spawned.chance(), 1, "a map's generator is always there")
    truthy(Spawned.beside(at(1, 0)), "a box at 1")
    eq(#added, 1)
    eq(added[1].object.sprite, BU.panelSprite("S", 1, false), "tier 1, indoors, facing away from the wall")
    SandboxVars.BuildingUtilities = { BreakerBoxLoot = 0.4 }
    eq(Spawned.beside(at(1, 0)), nil, "0.5 is past 0.4")
    roll = 0.1
    truthy(Spawned.beside(at(1, 0)))
    SandboxVars.BuildingUtilities = { BreakerBoxLoot = 0 }
    eq(Spawned.beside(at(1, 0)), nil, "none at 0")
    SandboxVars.BuildingUtilities = {}
    local spec = room({ ["1,0"] = { room = "garage", walls = { "N" }, things = 1 },
        ["0,1"] = { room = "garage", walls = { "W" }, things = 1 } })
    at, added = grid(spec)
    eq(Spawned.beside(at(0, 0)), nil, "in the corner one free square is left: the generator keeps it")
    eq(#added, 0)
    at, added = grid(room())
    truthy(Spawned.beside(at(2, 2)))
    eq(added[1].object.sprite, BU.panelSprite("S", 1, false), "no wall beside it: still its indoor look")
end)

test("where each stands is kept by its cell and found near a character, and forgotten", function()
    Spawned.keep(12, 15, 0)
    Spawned.keep(19, 15, 0)
    Spawned.keep(30, 30, 0)
    Spawned.keep(12, 15, 1)
    eq(#Spawned.near(14, 14, 0, 6), 2, "both near, across the cells' border; not the far one nor upstairs")
    Spawned.forget({ x = 19, y = 15, z = 0 })
    eq(#Spawned.near(14, 14, 0, 6), 1)
    eq(#Spawned.near(-3, -3, 0, 6), 0, "a cell west and north of the origin")
end)

test("every load function of a sprite runs, one failing not keeping the others", function()
    local registered = {}
    MapObjects = { OnLoadWithSprite = function(sprite, fn, priority)
        registered[#registered + 1] = { sprite = sprite, fn = fn, priority = priority }
    end }
    local ran = {}
    BU.onLoadSprite("bu_test_0", function() ran[#ran + 1] = "a" end)
    BU.onLoadSprite("bu_test_0", function() error("broken") end)
    BU.onLoadSprite("bu_test_0", function() ran[#ran + 1] = "c" end)
    eq(#registered, 1, "one registration for the sprite: a second at its priority would replace the first")
    registered[1].fn({})
    eq(table.concat(ran, ","), "a,c")
end)

test("a box's tile without a record is bare; a unit's lost state reads as spent", function()
    local sprite = BU.panelSprite("S", 1, false)
    local tile = { hasModData = function() return false end,
        getSprite = function() return { getName = function() return sprite end } end }
    truthy(Panels.isBare(tile))
    local other = { hasModData = function() return false end,
        getSprite = function() return { getName = function() return "appliances_misc_01_0" end } end }
    eq(Panels.isBare(other), false, "another tile")
    eq(BU.Units.lost("filter").media, 0)
    eq(BU.Units.lost("solar"), nil, "a kind that keeps nothing")
end)

test("a bare box activated where it stands: put down there with its tier and its side", function()
    require "BuildingUtilities/Changes"
    local Changes = BU.Changes
    local install, installed, removed = Changes.install, nil, nil
    Changes.install = function(_, side, kept)
        installed = { side = side, kept = kept }
        return {}
    end
    local square = { transmitRemoveItemFromSquare = function(_, object) removed = object end }
    local function tile(sprite)
        return { getSquare = function() return square end,
            getSprite = function() return { getName = function() return sprite end } end }
    end
    local post = tile(BU.panelSprite("E", 1, true))
    Changes.activate(post)
    eq(removed, post, "the bare tile goes")
    eq(installed.side, "E")
    eq(installed.kept.tier, 1)
    Changes.activate(tile(BU.panelSprite("N", 1, false)))
    eq(installed.side, "N")
    Changes.install = install
end)
