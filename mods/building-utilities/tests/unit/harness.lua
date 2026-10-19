-- Unit test harness: stubs the game functions and the PZ Extension API the tested modules touch, loads the mod's
-- files the way the game's require does, and runs every tests/unit/*_test.lua. Each case starts from a fresh mod, a
-- fresh save and a fresh API. Run through ../tools/LuaTest.java (it gives readfile, listfiles and TEST_FILTER).

local MEDIA = "BuildingUtilities/42/media/"
local ROOTS = { MEDIA .. "lua/shared/", MEDIA .. "lua/server/", MEDIA .. "lua/client/",
    "BuildingUtilitiesDev/42/media/lua/client/",
    -- the shared UI kit (PZUIKit), from its repository beside this one
    "../pz-ui-kit/PZUIKit/42/media/lua/shared/", "../pz-ui-kit/PZUIKit/42/media/lua/client/" }

-- The game's Lua has no next(), and neither has the test VM: a use of it fails here as it does there.
next = nil

-- A list as the game's Java lists read from Lua (size, get from 0).
local function javaList(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end,
        isEmpty = function() return #items == 0 end }
end
TEST_javaList = javaList

-- java.util.ArrayList as the mod hands one to the game to fill (getSpriteGridObjectsIncludingSelf): add, size, get.
ArrayList = { new = function()
    local list = { items = {} }
    function list:add(v) self.items[#self.items + 1] = v return true end
    function list:size() return #self.items end
    function list:get(i) return self.items[i + 1] end
    return list
end }

-- The PZ Extension API (PZExtAPI) as the tested modules call it. TEST.api holds what a test sets and what the
-- calls counted:
--   buildings: by key, { building = <at's table>, rooms = <rooms list>, attached = <list or nil>,
--     attachedObjects = { power = <list>, water = <list> }, objects = { power, water }, near = { power, water },
--     producers = { power, water } };
--   squares: "x,y,z" -> building key, for at;
--   version: buildings.version();
--   calls: by function name, how many times it was called.
local function newApi()
    -- Setting buildingsVersion is a change the mod sees at the next tick (BU.buildingsVersion reads it once a tick).
    local seen = 1
    local api = setmetatable({ version = 1, calls = {}, buildingsByKey = {}, squares = {} }, {
        __index = function(_, name) if name == "buildingsVersion" then return seen end end,
        __newindex = function(t, name, value)
            if name ~= "buildingsVersion" then return rawset(t, name, value) end
            seen = value
            if TEST.fire then TEST.fire("OnTick") end
        end })
    local function count(name) api.calls[name] = (api.calls[name] or 0) + 1 end
    local function entry(key) return api.buildingsByKey[key] end
    local buildings = {
        version = function() count("version"); return api.buildingsVersion end,
        at = function(x, y, z)
            count("at")
            local key = api.squares[x .. "," .. y .. "," .. z]
            return key and entry(key) and entry(key).building or nil
        end,
        rooms = function(key) count("rooms"); return entry(key) and entry(key).rooms or nil end,
        attached = function(key) count("attached"); return entry(key) and entry(key).attached or nil end,
        attachedObjects = function(key, filter)
            count("attachedObjects")
            local known = entry(key)
            if not (known and known.attached) then return nil, false end
            return (known.attachedObjects or {})[filter] or {}, true
        end,
        objects = function(key, filter)
            count("objects")
            local known = entry(key)
            return known and (known.objects or {})[filter] or {}, true
        end,
        near = function(key, tiles, filter)
            count("near")
            local known = entry(key)
            return known and (known.near or {})[filter] or {}, true
        end,
        producers = function(key, tiles, filter)
            count("producers")
            local known = entry(key)
            return known and (known.producers or {})[filter] or {}, true
        end,
    }
    -- Network changes are counted by name and do nothing; state is nil.
    local networks = setmetatable({ state = function() return nil end }, { __index = function(t, name)
        local fn = function() count("networks." .. name) TEST.netChanges = (TEST.netChanges or 0) + 1 return true end
        rawset(t, name, fn)
        return fn
    end })
    -- The world queries the mod calls. objects.byData: the object of TEST.squares' square whose mod data key is the
    -- value, false when the square is there with none, "unloaded" when it is not. squares.list: a room's squares
    -- (getSquares) that have a floor (floor = true) and no stairs (stairs = false).
    local objects = {
        byData = function(key, list)
            count("objects.byData")
            local result = {}
            for i = 1, #list, 4 do
                local square = TEST.squares[list[i] .. "," .. list[i + 1] .. "," .. list[i + 2]]
                local found = "unloaded"
                if square then
                    found = false
                    for _, object in ipairs(square.objects or {}) do
                        if object:hasModData() and object:getModData()[key] == list[i + 3] then found = object; break end
                    end
                end
                result[#result + 1] = found
            end
            return result
        end,
    }
    local squares = {
        -- one square against the conditions, as the API answers it (mods/tools/FakeSquareFilter.lua)
        test = function(square, filter) return TEST.squareFilter.test(square, filter) end,
        why = function(square, filter) return TEST.squareFilter.why(square, filter) end,
        list = function(area, filter)
            count("squares.list")
            local result, all = {}, area.room:getSquares()
            for i = 0, all:size() - 1 do
                local square = all:get(i)
                if (not filter.floor or square:getFloor() ~= nil) and (filter.stairs ~= false or not square:HasStairs()) then
                    result[#result + 1] = square
                end
            end
            return result
        end,
        -- squares.path as design.md says it: A* over (square, direction entered by). A step costs cost.inside onto a
        -- square of a building (api.squares, as buildings.at has it) else cost.outside, 1 onto `to`; cost.blocked more
        -- over an edge between loaded squares that isBlockedTo; cost.turn for a change of direction, and once more for a
        -- last step not along `into`. A loaded square meets `pass` (floor, stairs, waterFlag, noFlags); the ends and
        -- unloaded squares are open. The flat list x1, y1, ... and its cost, or nil.
        path = function(from, to, options)
            count("squares.path")
            local pass, cost, margin, into = options.pass or {}, options.cost or {}, options.margin or 12, options.into
            local outside, inside, blocked, turn = cost.outside or 1, cost.inside or 1, cost.blocked or 0, cost.turn or 0
            local minX, minY = math.min(from.x, to.x) - margin, math.min(from.y, to.y) - margin
            local maxX, maxY = math.max(from.x, to.x) + margin, math.max(from.y, to.y) + margin
            local z, high = from.z, maxY - minY + 1
            local cheapest = math.min(outside, inside, 1)
            local DX, DY = { 1, -1, 0, 0 }, { 0, 0, 1, -1 }
            local cell, known, entering = getCell(), {}, {}
            local function squareAt(x, y)
                local at = (x - minX) * high + y - minY
                if known[at] == nil then known[at] = cell:getGridSquare(x, y, z) or false end
                return known[at] or nil
            end
            local function enter(x, y)
                local at = (x - minX) * high + y - minY
                local c = entering[at]
                if c == nil then
                    if x == to.x and y == to.y then c = 1
                    else
                        local open, square = true, squareAt(x, y)
                        if square and not (x == from.x and y == from.y) then
                            local props = square:getProperties()
                            if pass.floor ~= nil and (square:getFloor() ~= nil) ~= pass.floor then open = false end
                            if pass.stairs ~= nil and square:HasStairs() ~= pass.stairs then open = false end
                            if pass.waterFlag ~= nil and props:has(IsoFlagType.water) ~= pass.waterFlag then open = false end
                            for _, name in ipairs(pass.noFlags or {}) do
                                if props:has(IsoFlagType[name]) then open = false end
                            end
                        end
                        c = open and (api.squares[x .. "," .. y .. "," .. z] and inside or outside) or false
                    end
                    entering[at] = c
                end
                return c
            end
            local function estimate(x, y) return cheapest * (math.abs(x - to.x) + math.abs(y - to.y)) end
            -- a binary heap of { estimate, cost, state } by estimate; a state is a square and its direction (0: none)
            local queue = {}
            local function push(item)
                local i = #queue + 1
                queue[i] = item
                while i > 1 and queue[math.floor(i / 2)][1] > item[1] do
                    queue[i] = queue[math.floor(i / 2)]
                    i = math.floor(i / 2)
                    queue[i] = item
                end
            end
            local function pop()
                local top, last = queue[1], table.remove(queue)
                if #queue > 0 then
                    queue[1] = last
                    local i = 1
                    while true do
                        local child = i * 2
                        if child > #queue then break end
                        if child < #queue and queue[child + 1][1] < queue[child][1] then child = child + 1 end
                        if queue[child][1] >= last[1] then break end
                        queue[i], queue[child] = queue[child], last
                        i = child
                    end
                end
                return top
            end
            local best, via = {}, {}
            local start = ((from.x - minX) * high + from.y - minY) * 5
            best[start] = 0
            push({ estimate(from.x, from.y), 0, start })
            while #queue > 0 do
                local item = pop()
                local total, state = item[2], item[3]
                if total == best[state] then
                    local at = math.floor(state / 5)
                    local d = state - at * 5
                    local column = math.floor(at / high)
                    local x, y = minX + column, minY + at - column * high
                    if x == to.x and y == to.y then
                        local flat, s = {}, state
                        while s do
                            local index = math.floor(s / 5)
                            local col = math.floor(index / high)
                            table.insert(flat, 1, minY + index - col * high)
                            table.insert(flat, 1, minX + col)
                            s = via[s]
                        end
                        return flat, total
                    end
                    for nd = 1, 4 do
                        local nx, ny = x + DX[nd], y + DY[nd]
                        local c = nx >= minX and nx <= maxX and ny >= minY and ny <= maxY and enter(nx, ny)
                        if c then
                            if d ~= 0 and nd ~= d then c = c + turn end
                            if into and nx == to.x and ny == to.y and (DX[nd] ~= into.dx or DY[nd] ~= into.dy) then c = c + turn end
                            if blocked > 0 then
                                local a, b = squareAt(x, y), squareAt(nx, ny)
                                if a and b and a:isBlockedTo(b) then c = c + blocked end
                            end
                            local after = ((nx - minX) * high + ny - minY) * 5 + nd
                            if not best[after] or total + c < best[after] then
                                best[after], via[after] = total + c, state
                                push({ total + c + estimate(nx, ny), total + c, after })
                            end
                        end
                    end
                end
            end
            return nil
        end,
    }
    networks.draw = function() return 0 end
    -- No revision unless a test gives one: the states are kept for the millisecond, as an older API has them.
    networks.revision = function() return nil end
    api.table = {
        version = 1,
        buildings = buildings,
        objects = objects,
        squares = squares,
        networks = networks,
        client = function() return {} end,
        hooks = function() return {} end,
    }
    return api
end

-- Game stubs. TEST holds what a test sets.
TEST = {}
-- The API's square conditions as the fake API answers squares.test and squares.why (mods/tools/FakeSquareFilter.lua).
TEST.squareFilter = loadstring(readfile("../tools/FakeSquareFilter.lua"), "FakeSquareFilter")()
local function resetGame()
    SandboxVars = {}
    local store = {}
    ModData = {
        getOrCreate = function(key) store[key] = store[key] or {}; return store[key] end,
        get = function(key) return store[key] end,
        exists = function(key) return store[key] ~= nil end,
        add = function(key, t) store[key] = t end,
        remove = function(key) store[key] = nil end,
        transmit = function() end,
        request = function() end,
    }
    local handlers = {}
    Events = setmetatable({}, { __index = function(t, name)
        local e = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
                    Remove = function() end }
        rawset(t, name, e)
        return e
    end })
    TEST.fire = function(name, ...)
        for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    end
    TEST.hours = 0
    getGameTime = function()
        return { getWorldAgeHours = function() return TEST.hours end, getHour = function() return 12 end,
            getTimeOfDay = function() return 12 end }
    end
    TEST.ms = 1000000000
    getTimestampMs = function() TEST.ms = TEST.ms + 1000; return TEST.ms end
    isServer = function() return false end
    isClient = function() return false end
    getText = function(key, ...)
        local parts = { key }
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        return table.concat(parts, " ")
    end
    -- No translation is known: the mod's own fallbacks show.
    getTextOrNull = function() return nil end
    sendServerCommand = function() end
    sendClientCommand = function() end
    -- No square is loaded unless a test puts one in TEST.squares ("x,y,z" -> { objects = { ... } }; room: a name, the
    -- squares of one name in one room (getRoom), none for no room; roof: a tile over the square below that lets no rain through; flags: { burning = true }; movers).
    -- A fire put out takes the square's burning flag (stopped counts the times).
    TEST.squares = {}
    local rooms = {}
    getCell = function()
        return { getGridSquare = function(_, x, y, z)
            local square = TEST.squares[x .. "," .. y .. "," .. z]
            if not square then return nil end
            return {
                getX = function() return x end, getY = function() return y end, getZ = function() return z end,
                getObjects = function() return javaList(square.objects or {}) end,
                getRoom = function()
                    if square.room == nil then return nil end
                    rooms[square.room] = rooms[square.room] or { name = square.room }
                    return rooms[square.room]
                end,
                has = function(_, flag) return square.flags ~= nil and square.flags[flag] == true end,
                hasRainBlockingTile = function() return square.roof == true end,
                getMovingObjects = function() return javaList(square.movers or {}) end,
                stopFire = function()
                    if square.flags then square.flags.burning = nil end
                    square.stopped = (square.stopped or 0) + 1
                end,
                -- a floor unless the test says none ({ noFloor = true }), of a sprite when the test names one (floor; else
                -- the game's grass, natural ground); flags as { water = true }; water by its floor's material (waterSquare)
                getFloor = function()
                    if square.noFloor then return nil end
                    return { getSprite = function()
                        return { getName = function() return square.floor or "blends_natural_01_16" end }
                    end }
                end,
                isWaterSquare = function() return square.waterSquare == true end,
                HasStairs = function() return square.stairs == true end,
                getProperties = function() return { has = function(_, flag) return square.flags ~= nil and square.flags[flag] == true end } end,
                isBlockedTo = function() return false end,
            }
        end }
    end
    IsoFlagType = { water = "water", burning = "burning", FloorHeightOneThird = "FloorHeightOneThird",
        FloorHeightTwoThirds = "FloorHeightTwoThirds" }
    -- No fire burns unless a test lists one (TEST.burn).
    IsoFireManager = { FireStack = javaList({}) }
    getWorld = function()
        return { getMetaGrid = function() return { getRoomAt = function() return nil end } end,
            isHydroPowerOn = function() return false end }
    end
    getNumActivePlayers = function() return 0 end
    getSpecificPlayer = function() return nil end
    instanceof = function() return false end
    -- Squares never load: the callbacks the mod registers are not kept.
    MapObjects = { OnLoadWithSprite = function() end, OnNewWithSprite = function() end }
    TEST.api = newApi()
    PZExtAPI = TEST.api.table
end

-- require as the game does it: by path under media/lua/shared, server or client, each file once.
local loaded
-- A file of the game itself a test stands in for (its globals set by the test): required as if loaded.
function TEST.gameFile(name) loaded[name] = true end
function require(name)
    if loaded[name] ~= nil then return loaded[name] end
    for _, root in ipairs(ROOTS) do
        local text = readfile(root .. name .. ".lua")
        if text then
            local chunk, err = loadstring(text, name)
            if not chunk then error("cannot compile " .. name .. ": " .. tostring(err), 2) end
            loaded[name] = true
            local result = chunk()
            if result ~= nil then loaded[name] = result end
            return loaded[name]
        end
    end
    error("require: no file for " .. name, 2)
end

-- Assertions.
local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end
function eq(actual, expected, what)
    if actual ~= expected then
        error((what and (what .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
    end
end
function truthy(v, what)
    if not v then error((what or "expected a true value") .. ", got " .. show(v), 2) end
end

-- Run.
local cases
function test(name, fn) table.insert(cases, { name = name, fn = fn }) end

TEST_FAILED = 0
local passed = 0
local DIR, PATTERN = "tests/unit/", "_test%.lua$"
if TEST_SUITE == "bench" or TEST_SUITE == "profile" then DIR, PATTERN = "tests/bench/", "_bench%.lua$" end
for _, file in ipairs(listfiles(DIR)) do
    if string.match(file, PATTERN) and (TEST_FILTER == "" or string.find(file, TEST_FILTER, 1, true)) then
        cases = {}
        local text = readfile(DIR .. file)
        local chunk, err = loadstring(text, file)
        if not chunk then
            TEST_FAILED = TEST_FAILED + 1
            print("FAIL " .. file .. ": " .. tostring(err))
        else
            -- Each case runs from a fresh game and mod: the file runs again first (its top-level requires too).
            local function fresh()
                cases = {}
                loaded = {}
                BuildingUtilities = nil
                resetGame()
                chunk()
            end
            local ok0, msg0 = pcall(fresh)
            if not ok0 then
                TEST_FAILED = TEST_FAILED + 1
                print("FAIL " .. file .. ": " .. tostring(msg0))
            end
            for i = 1, ok0 and #cases or 0 do
                local before = {}
                for k, v in pairs(_G) do before[k] = v end
                fresh()
                local case = cases[i]
                local ok, msg = pcall(case.fn)
                local added = {}
                for k in pairs(_G) do if before[k] == nil then added[#added + 1] = k end end
                for _, k in ipairs(added) do _G[k] = nil end
                for k, v in pairs(before) do _G[k] = v end
                if ok then
                    passed = passed + 1
                else
                    TEST_FAILED = TEST_FAILED + 1
                    print("FAIL " .. file .. " / " .. case.name .. ": " .. tostring(msg))
                end
            end
        end
    end
end
print(string.format("%d passed, %d failed", passed, TEST_FAILED))
