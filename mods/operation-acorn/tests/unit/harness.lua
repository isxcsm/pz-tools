-- Unit test harness: stubs the game functions the mod's logic touches, loads the mod's files the way the game's
-- require does, and runs every tests/unit/*_test.lua. Each test file starts from a fresh mod and a fresh save.
-- Run through ../tools/LuaTest.java (it gives readfile, listfiles and TEST_FILTER).

local MEDIA = "OperationAcorn/42/media/"
local ROOTS = { MEDIA .. "lua/shared/", MEDIA .. "lua/server/", MEDIA .. "lua/client/",
    -- the developer sub-mod (its client files; its tests are dev_*_test.lua)
    "OperationAcornDev/42/media/lua/client/",
    -- the shared UI kit (PZUIKit), from its repository beside this one
    "../pz-ui-kit/PZUIKit/42/media/lua/shared/", "../pz-ui-kit/PZUIKit/42/media/lua/client/" }

-- The sandbox options with their defaults, read from sandbox-options.txt as the game would.
local function sandboxDefaults()
    local vars = {}
    local text = readfile(MEDIA .. "sandbox-options.txt") or ""
    for page, name, body in string.gmatch(text, "option%s+(%w+)%.([%w_]+)%s*(%b{})") do
        vars[page] = vars[page] or {}
        local kind = string.match(body, "type%s*=%s*(%w+)")
        local default = string.match(body, "default%s*=%s*([^,%s}]+)")
        if kind == "boolean" then vars[page][name] = default == "true"
        elseif kind == "enum" or kind == "integer" or kind == "double" then vars[page][name] = tonumber(default)
        else vars[page][name] = default end
    end
    return vars
end

-- The game's Lua has no next() (found in game: a call failed with "tried to call nil"), and neither has the test VM:
-- a use of it fails here as it does there.
next = nil

-- java.util.ArrayList as the mod uses it (OA.vehicles copies a Set into one). A Set stub is { items = { ... } }.
ArrayList = { new = function()
    local list = { items = {} }
    function list:clear() self.items = {} end
    function list:addAll(from)
        local src = from.items or {}
        for _, v in ipairs(src) do self.items[#self.items + 1] = v end
        if not from.items and from.size then
            for i = 0, from:size() - 1 do self.items[#self.items + 1] = from:get(i) end
        end
        return true
    end
    function list:add(v) self.items[#self.items + 1] = v return true end
    function list:size() return #self.items end
    function list:get(i) return self.items[i + 1] end
    function list:isEmpty() return #self.items == 0 end
    return list
end }

-- Game stubs. TEST holds what a test sets: the world age, the time of day.
TEST = {}

-- Sets a flight support level of a record outright, as buying it would leave it (Support.levels, the revision that
-- makes what is worked out from the levels be worked out again).
function TEST.setSupportLevel(record, id, level)
    OperationAcorn.Support.levels(record)[id] = level > 0 and level or nil
    local t = OperationAcorn.Store.section(record, "trade")
    t.levelsRev = (t.levelsRev or 0) + 1
end

-- The levels trust alone would reach: every level whose tier it has reached (the tables before flight support).
function TEST.levelsForTier(tier)
    local levels = {}
    for _, u in ipairs(OperationAcorn.Support.LIST) do
        local n = 0
        while true do
            local s = OperationAcorn.Support.step(u.id, n + 1)
            if not s or s.tier > tier then break end
            n = n + 1
        end
        if n > 0 then levels[u.id] = n end
    end
    return levels
end

local function resetGame()
    TEST.hours = 0
    TEST.random = 1
    -- the game's UI sounds answered, silently (a click sounds: PZUIKit UI.clickSound)
    getSoundManager = function() return { playUISound = function() end } end
    -- the player a test stands in: none unless it gives one (a file's own must not reach the next)
    getPlayer = nil
    TEST.sent = {}
    TEST.month = nil
    SandboxVars = sandboxDefaults()
    local store = {}
    ModData = {
        getOrCreate = function(key) store[key] = store[key] or {}; return store[key] end,
        get = function(key) return store[key] end,
        exists = function(key) return store[key] ~= nil end,
        add = function(key, t) store[key] = t end,
        remove = function(key) store[key] = nil end,
        transmit = function() end,
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
    getGameTime = function()
        return {
            getWorldAgeHours = function() return TEST.hours end,
            getTimeOfDay = function() return (TEST.hours + 9) % 24 end,
            getHour = function() return math.floor((TEST.hours + 9) % 24) end,
            -- The month, counted from 0 as the game does (TEST.month, July at the start).
            getMonth = function() return TEST.month or 6 end,
        }
    end
    -- A fixed pseudo-random sequence (a linear congruential generator), so that tests repeat.
    ZombRand = function(a, b)
        TEST.random = (TEST.random * 1103515245 + 12345) % 2147483648
        if b == nil then a, b = 0, a end
        if b <= a then return a end
        return a + TEST.random % (b - a)
    end
    ZombRandFloat = function(a, b)
        TEST.random = (TEST.random * 1103515245 + 12345) % 2147483648
        return a + (b - a) * (TEST.random / 2147483648)
    end
    -- The real clock (ms): an hour on at each call, so a real-time throttle (OA.due) never holds back a test that does
    -- not mean to try it. A test of a throttle sets its own getTimestampMs.
    TEST.ms = 1000000000
    getTimestampMs = function()
        TEST.ms = TEST.ms + 3600000
        return TEST.ms
    end
    isServer = function() return false end
    isClient = function() return false end
    getText = function(key, ...)
        local parts = { key }
        -- trailing nils are no arguments (UI.str passes its two whether given or not)
        local last = select("#", ...)
        while last > 0 and select(last, ...) == nil do last = last - 1 end
        for i = 1, last do parts[#parts + 1] = tostring(select(i, ...)) end
        return table.concat(parts, " ")
    end
    sendClientCommand = function(player, module, command, args)
        table.insert(TEST.sent, { module = module, command = command, args = args })
        TEST.fire("OnClientCommand", module, command, player, args)
    end
    sendServerCommand = function() end
    -- The world's sound manager: the sounds zombies would hear are kept in TEST.worldSounds.
    TEST.worldSounds = {}
    getWorldSoundManager = function()
        return { addSound = function(_, source, x, y, z, radius, volume)
            table.insert(TEST.worldSounds, { x = x, y = y, z = z, radius = radius, volume = volume })
        end }
    end
end

-- require as the game does it: by path under media/lua/shared, server or client, each file once.
local loaded
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
function near(actual, expected, eps, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > (eps or 1e-9) then
        error((what and (what .. ": ") or "") .. "expected about " .. show(expected) .. ", got " .. show(actual), 2)
    end
end
function truthy(v, what)
    if not v then error((what or "expected a true value") .. ", got " .. show(v), 2) end
end
function fails(fn, what)
    local ok = pcall(fn)
    if ok then error((what or "expected an error") .. ", but it ran", 2) end
end

-- A fake game's buildings (Game.buildingsIn) and story sites (Game.sitesInBand, groundInBand, buildingKeyAt) over its
-- building list g.list: every second building a house, the rooms 1 to 5 by turn, the area 36 unless the entry has its
-- own. The open ground is the band's middle due east of the anchor; g.noGround takes it away.
function fakeSites(g)
    g.buildingsIn = function(x, y, lo, hi)
        local out = {}
        for _, b in ipairs(g.list) do
            local dx, dy = b.x - x, b.y - y
            local d = math.sqrt(dx * dx + dy * dy)
            if d >= lo and d <= hi then out[#out + 1] = b end
        end
        return out
    end
    g.sitesInBand = function(ax, ay, lo, hi, skip)
        local out = {}
        for i, b in ipairs(g.list) do
            local dx, dy = b.x - ax, b.y - ay
            local d = math.sqrt(dx * dx + dy * dy)
            local key = tostring(b.x) .. "," .. tostring(b.y)
            if d >= lo and d <= hi and not (skip and skip[key]) then
                local info = {}
                for k, v in pairs(b) do info[k] = v end
                info.key, info.dist = key, d
                info.area = b.area or 36
                info.rooms = b.rooms or (i - math.floor((i - 1) / 5) * 5)
                if b.home == nil then info.home = i - math.floor(i / 2) * 2 == 0 else info.home = b.home end
                out[#out + 1] = info
            end
        end
        return out
    end
    g.groundInBand = function(ax, ay, lo, hi)
        if g.noGround then return nil end
        return math.floor(ax + (lo + hi) / 2), math.floor(ay)
    end
    g.buildingKeyAt = function() return g.baseKey end
    return g
end

-- Run.
local cases
function test(name, fn) table.insert(cases, { name = name, fn = fn }) end

TEST_FAILED = 0
local passed = 0
for _, file in ipairs(listfiles("tests/unit")) do
    if string.match(file, "_test%.lua$") and (TEST_FILTER == "" or string.find(file, TEST_FILTER, 1, true)) then
        cases = {}
        local text = readfile("tests/unit/" .. file)
        local chunk, err = loadstring(text, file)
        if not chunk then
            TEST_FAILED = TEST_FAILED + 1
            print("FAIL " .. file .. ": " .. tostring(err))
        else
            -- Each case runs from a fresh game and mod: the file runs again first (its top-level requires too).
            local function fresh()
                cases = {}
                loaded = {}
                -- (the mod as with the API: a test that wants it missing clears PZExtAPI, and OA.off stays as set here)
                OperationAcorn = { off = false }
                resetGame()
                chunk()
            end
            local ok0, msg0 = pcall(fresh)
            if not ok0 then
                TEST_FAILED = TEST_FAILED + 1
                print("FAIL " .. file .. ": " .. tostring(msg0))
            end
            for i = 1, ok0 and #cases or 0 do
                -- A case may set game stubs of its own (a script manager, a tooltip class): they are taken back after it,
                -- so that the next case, in any file, starts from the harness's stubs only.
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
