-- Unit test harness: stubs the game functions the mod's logic touches, loads the mod's files the way the game's
-- require does, and runs every tests/unit/*_test.lua. Each test file starts from a fresh mod and a fresh save.
-- Run through tools/LuaTest.java (it gives readfile, listfiles and TEST_FILTER).

local MEDIA = "OperationAcorn/42/media/"
local ROOTS = { MEDIA .. "lua/shared/", MEDIA .. "lua/server/", MEDIA .. "lua/client/" }

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
local function resetGame()
    TEST.hours = 0
    TEST.random = 1
    TEST.sent = {}
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
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        return table.concat(parts, " ")
    end
    sendClientCommand = function(player, module, command, args)
        table.insert(TEST.sent, { module = module, command = command, args = args })
        TEST.fire("OnClientCommand", module, command, player, args)
    end
    sendServerCommand = function() end
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
                OperationAcorn = nil
                resetGame()
                chunk()
            end
            local ok0, msg0 = pcall(fresh)
            if not ok0 then
                TEST_FAILED = TEST_FAILED + 1
                print("FAIL " .. file .. ": " .. tostring(msg0))
            end
            for i = 1, ok0 and #cases or 0 do
                fresh()
                local case = cases[i]
                local ok, msg = pcall(case.fn)
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
