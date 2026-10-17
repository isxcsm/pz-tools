-- Spawned boxes (BU.Spawned): a box in a room the game rolls a generator for, as often and on its own, on a square of
-- the room with nothing on it but floor and plain walls, not a doorway nor before a door, against a wall where a free
-- square has one, else on any. Where each stands is kept by its cell and found again near a character. Also:
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

-- A grid of squares by "x,y": { walls = { "N", "W" }, door = "N"/"W" (an opening in that wall),
-- doorway = true, things = n (other objects), lying = n (items on the floor), stairs = true, noFloor = true }.
local function grid(spec)
    IsoFlagType = setmetatable({}, { __index = function(_, k) return k end })
    local squares, added = {}, {}
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
        local square
        square = {
            getX = function() return x end, getY = function() return y end, getZ = function() return 0 end,
            getFloor = function() return not s.noFloor and objects[1] or nil end,
            HasStairs = function() return s.stairs == true end,
            isDoorSquare = function() return s.doorway == true end,
            getWorldObjects = function() return list(s.lying and { 1 } or {}) end,
            getObjects = function() return list(objects) end,
            getWall = function(_, north) return walls[north and "N" or "W"] end,
            isDoorTo = function(_, other)
                local ox, oy = other:getX(), other:getY()
                if ox == x and oy == y - 1 then return s.door == "N" end
                if ox == x - 1 and oy == y then return s.door == "W" end
                local o = spec[ox .. "," .. oy]
                if ox == x and oy == y + 1 then return o ~= nil and o.door == "N" end
                if ox == x + 1 and oy == y then return o ~= nil and o.door == "W" end
                return false
            end,
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
-- south.
local function room(extra)
    local spec = {}
    for x = -1, 5 do
        for y = -1, 5 do
            local inside = x >= 0 and x <= 4 and y >= 0 and y <= 4
            local s = {}
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

-- The game's room of the grid's squares of the room's name (kind: its name, garage when not given).
local function gameRoom(at, kind)
    local squares = {}
    for x = 0, 4 do for y = 0, 4 do squares[#squares + 1] = at(x, y) end end
    return { getName = function() return kind or "garage" end, getSquares = function() return list(squares) end }
end

local function keys(choices)
    local result = {}
    for _, c in ipairs(choices) do result[#result + 1] = c.square:getX() .. "," .. c.square:getY() .. c.side end
    table.sort(result)
    return " " .. table.concat(result, " ") .. " "
end

test("a box takes a free square of the room against a wall, facing away from it", function()
    local at = grid(room())
    local places = keys(Spawned.places(gameRoom(at)))
    for _, want in ipairs({ "2,0S", "0,2E", "4,2W", "2,4N", "0,0S" }) do
        truthy(places:find(" " .. want .. " ", 1, true), want .. " in" .. places)
    end
    eq(places:find(" 2,2", 1, true), nil, "the middle has no wall: not while walled ones are free")
    eq(#Spawned.places(gameRoom(at)), 16, "the squares along the walls")
end)

test("not a doorway, not before a door, not a square with things or items on it; else any free square", function()
    local at = grid(room({
        ["0,1"] = { walls = { "W" }, door = "W" },
        ["2,0"] = { walls = { "N" }, things = 1 },
        ["0,0"] = { walls = { "N", "W" }, lying = true },
        ["3,3"] = { doorway = true },
    }))
    local places = keys(Spawned.places(gameRoom(at)))
    for _, out in ipairs({ "0,1", "2,0", "0,0" }) do eq(places:find(" " .. out, 1, true), nil, out .. " is out") end
    local full = {}
    for x = 0, 4 do
        for y = 0, 4 do
            if x == 0 or y == 0 or x == 4 or y == 4 then full[x .. "," .. y] = { things = 1 } end
        end
    end
    at = grid(room(full))
    eq(keys(Spawned.places(gameRoom(at))), " 1,1S 1,2S 1,3S 2,1S 2,2S 2,3S 3,1S 3,2S 3,3S ",
        "shelves along every wall: any free square, facing south")
end)

test("as often as the game's generator in the room's kind, by its option, scaled by BreakerBoxLoot from its default", function()
    SandboxVars.GeneratorSpawning = nil
    eq(Spawned.chance("garage"), 1 / 7)
    eq(Spawned.chance("shed"), 1 / 4)
    eq(Spawned.chance("bedroom"), 0, "a kind the game rolls no generator for")
    SandboxVars.GeneratorSpawning = 1
    eq(Spawned.chance("garage"), 0, "generators at none")
    SandboxVars.GeneratorSpawning = 2
    eq(Spawned.chance("garage"), 1 / 27)
    SandboxVars.GeneratorSpawning = 7
    eq(Spawned.chance("shed"), 1, "one in 1")
    SandboxVars.GeneratorSpawning = 5
    SandboxVars.BuildingUtilities = { BreakerBoxLoot = Spawned.LOOT_DEFAULT * 2 }
    eq(Spawned.chance("garage"), 2 / 7, "twice at twice its default")
    SandboxVars.BuildingUtilities = { BreakerBoxLoot = 0 }
    eq(Spawned.chance("garage"), 0)
    SandboxVars.BuildingUtilities = {}
end)

test("rolled on its own: a box put down bare, of tier 1, indoors, and kept", function()
    local at, added = grid(room())
    SandboxVars.GeneratorSpawning = 5
    local roll = 0.5
    ZombRandFloat = function() return roll end
    ZombRand = function() return 0 end
    eq(Spawned.inRoom(gameRoom(at)), nil, "0.5 is past one in 7")
    roll = 0.1
    local square = Spawned.inRoom(gameRoom(at))
    truthy(square)
    eq(#added, 1)
    local first = Spawned.places(gameRoom(at))[1]
    eq(added[1].object.sprite, BU.panelSprite(first.side, 1, false))
    eq(#Spawned.near(square:getX(), square:getY(), 0, 0), 1, "kept where it stands")
    eq(Spawned.inRoom(gameRoom(at, "bedroom")), nil, "not in a kind the game rolls none for")
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
