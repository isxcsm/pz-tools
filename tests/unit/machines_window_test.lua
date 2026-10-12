-- The machine window (client Machines/WindowModel.lua, WindowLayout.lua, Window.lua; mockups/machines/a-equipment.html):
-- the model's numbers and units (weight with no unit, fuel in L an hour from the load and the sandbox, noise in tiles,
-- hours of running left), which buttons each part shows, each kind's own section; the layout at the fonts of 16, 19
-- and 26 pixel screens (every text inside the window and none on another, the window inside a 1280 x 720 screen at
-- 16 px); the two columns of a machine with parts, whole in both languages at 720p, 900p and 1080p with no scroll;
-- and the window reading the machine a few times a second, not every frame, and looking through the bags
-- for parts only when a button is pressed.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data, Logic = Machines.Data, Machines.Logic

-- Texts ---------------------------------------------------------------------------------------------------------------
-- The English texts (their lengths are what the layout is checked with), the arguments put in as the game does.

local TEXTS
-- The language of the texts: "EN", or "KO" for the tests of the longest Korean lines.
local LANG = "EN"
local function loadTexts()
    TEXTS = { ContextMenu_Turn_On = "Turn on", ContextMenu_Turn_Off = "Turn off" }
    if LANG == "KO" then TEXTS = { ContextMenu_Turn_On = "켜기", ContextMenu_Turn_Off = "끄기" } end
    for _, name in ipairs({ "IG_UI", "ContextMenu" }) do
        local text = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. LANG .. "/" .. name .. ".json") or ""
        for line in string.gmatch(text, "[^\n]+") do
            local key, value = string.match(line, '^%s*"([^"]+)":%s*"(.*)",?%s*$')
            if key then TEXTS[key] = (string.gsub(value, '\\"', '"')) end
        end
    end
end

-- The middle dot the texts put between parts (as the test VM reads it: no letters past ASCII in Lua strings).
local DOT

local function englishText()
    loadTexts()
    DOT = string.match(TEXTS.IGUI_OA_Machine_Box_Note, "^%%1 (.-) %%2$")
    getText = function(key, ...)
        local s = TEXTS[key]
        if not s then return key end
        local args = { ... }
        s = string.gsub(s, "%%(%d)", function(n) return tostring(args[tonumber(n)]) end)
        return (string.gsub(s, "%%%%", "%%"))
    end
end

local function loadModel()
    englishText()
    require "OperationAcorn/Machines/WindowModel"
    return Machines.WindowModel
end

-- A status as Machines.status gives it, for a state table (no game object).
local function statusOf(state, extra)
    local fx = Logic.effects(state.kind, state.parts)
    local def = Data.KINDS[state.kind]
    local status = {
        kind = state.kind, on = state.on ~= false, running = state.running == true, reason = state.reason,
        powered = def.power and (extra and extra.powered == false and false or true) or nil,
        speed = fx.speed * fx.lanes, lanes = fx.lanes, load = Logic.load(state.kind, state.parts, true),
        noise = Logic.noiseRadius(state.kind, fx), stopped = fx.stopped, missing = fx.missing, broken = fx.broken,
        worn = fx.worn, parts = state.parts, rate = def.rate and def.rate * fx.speed * fx.lanes or nil,
    }
    for k, v in pairs(extra or {}) do status[k] = v end
    return status
end

-- The window's inputs for the scenes of the mockup.
local SCENES = {}

SCENES.running = function()
    local state = { kind = "cutter", on = true, running = true,
        parts = { motor = { tier = "modern", cond = 82 }, blade = { tier = "normal", cond = 61 } } }
    return { kind = "cutter", id = "m7", status = statusOf(state), hook = true, fuelRate = 0.1, inCount = 62,
        jobs = { { fullType = "Base.TrousersDenim", name = "Jeans", share = 0.72 },
            { fullType = "Base.HoodieWhite", name = "White Hoodie", share = 0.31 },
            { fullType = "Base.Tshirt", name = "T-shirt", share = 1.2 } },
        boxes = { { role = "in", type = "OAMachineIn", weight = 38.4, capacity = 100, count = 62 },
            { role = "out", type = "OAMachineOut", weight = 23.5, capacity = 100, count = 40 } },
        canOn = { ok = true } }
end

SCENES.idle = function()
    local state = { kind = "cutter", on = true, running = false, reason = "noInput",
        parts = { motor = { tier = "modern", cond = 80 }, blade = { tier = "normal", cond = 58 } } }
    return { kind = "cutter", id = "m7", status = statusOf(state), hook = true, fuelRate = 0.1, inCount = 0, jobs = {},
        boxes = { { role = "in", type = "OAMachineIn", weight = 0, capacity = 100, count = 0 },
            { role = "out", type = "OAMachineOut", weight = 31.2, capacity = 100, count = 52 } },
        canOn = { ok = true } }
end

SCENES.broken = function()
    local state = { kind = "cutter", on = true, running = false,
        parts = { motor = { tier = "old", cond = 18 }, blade = { tier = "old", cond = 0 } } }
    return { kind = "cutter", id = "m7", status = statusOf(state), hook = true, fuelRate = 0.1, inCount = 14, jobs = {},
        boxes = { { role = "in", type = "OAMachineIn", weight = 9.1, capacity = 100, count = 14 },
            { role = "out", type = "OAMachineOut", weight = 99, capacity = 100, count = 120 } },
        canOn = { ok = false, why = "Cannot switch on: the Blade is broken" } }
end

SCENES.saw = function()
    local state = { kind = "woodSaw", on = false, running = false,
        parts = { motor = { tier = "normal", cond = 100 }, blade = { tier = "modern", cond = 20 } } }
    return { kind = "woodSaw", id = "m3", status = statusOf(state), hook = false, fuelRate = 0.1, inCount = 3, jobs = {},
        boxes = { { role = "in", type = "OAMachineIn", weight = 27, capacity = 100, count = 3 },
            { role = "out", type = "OAMachineOut", weight = 0, capacity = 100, count = 0 } },
        canOn = { ok = true } }
end

SCENES.refiner = function()
    local state = { kind = "oilRefiner", on = true, running = true,
        parts = { motor = { tier = "old", cond = 100 }, catalyst = { tier = "normal", cond = 70 } } }
    return { kind = "oilRefiner", id = "m21", status = statusOf(state, { powered = false }), hook = true, fuelRate = 0.5,
        inCount = 2, jobs = {},
        boxes = { { role = "in", type = "OAMachineIn", weight = 2, capacity = 100, count = 2 },
            { role = "tank", type = "OAMachineTank", weight = 5, capacity = 100, count = 1 } },
        canOn = { ok = true } }
end

SCENES.rain = function()
    local state = { kind = "rainStorage", parts = {} }
    return { kind = "rainStorage", id = "m3", status = statusOf(state, { water = 2860, capacity = 4000 }),
        canEmpty = true, canTransfer = true }
end

SCENES.lure = function()
    local state = { kind = "lure", parts = {}, running = true }
    return { kind = "lure", id = "m12", status = statusOf(state, { left = 24 - 7.65, spent = false }) }
end

SCENES.spent = function()
    local state = { kind = "lure", parts = {} }
    return { kind = "lure", id = "m9", status = statusOf(state, { left = 0, spent = true }) }
end

local function texts(model)
    return Machines.WindowModel.key(model)
end

-- The model ----------------------------------------------------------------------------------------------------------

test("a running cutter: rate in weight an hour with no unit, times the old motor, the power load, fuel only in the tip", function()
    local Model = loadModel()
    local m = Model.build(SCENES.running())
    eq(m.title, "Fabric Cutter")
    eq(m.tag, "Research team equipment " .. DOT .. " unit 7")
    eq(m.light.text, "Running"); eq(m.light.tone, "good")
    eq(m.switch.label, "Turn off"); truthy(m.switch.enabled)
    eq(m.strip.tone, "good")
    -- the rate: 36 an hour with the old motor, x1.3 speed and 3 lanes = 140.4
    local rate = m.perf.cells[1]
    eq(rate.value, "140 weight/h")
    eq(rate.sub, "3.9x old motor")
    eq(rate.tip[#rate.tip].s, "In all: 140 weight/h")
    eq(rate.tip[2], "One old motor: 36 weight/h")
    -- power: load 0.4 x the modern motor's 1.5 = 0.6; on a generator x 0.1 L an hour (the tooltip only: grid or solar
    -- power burns no fuel)
    eq(m.perf.cells[2].value, "Power load 0.6")
    eq(m.perf.cells[2].sub, "about 5 fridges")
    truthy(string.find(m.perf.cells[2].tip[3], "On a generator it burns about 0.06 L of fuel an hour (load 0.6 ", 1, true), "the fuel in the tip")
    eq(m.perf.cells[3].value, "Noise 40 tiles")
    eq(m.perf.cells[3].sub, "generator: 20")
    eq(m.perf.right, nil, "no 'while running' note while it runs")
    truthy(not string.find(texts(m), "kg", 1, true), "no weight unit anywhere")
    -- the jobs: a row a lane, the share cut at 100 %, and a due job asks the machine to work
    eq(#m.jobs.rows, 3)
    eq(m.jobs.rows[1].pct, "72%")
    eq(m.jobs.rows[3].share, 1)
    truthy(m.due)
    eq(m.jobs.right, "3 at a time")
    -- the bins: weight with no unit, the time the input takes at the rate (38.4 / 140.4 h = 16 min)
    eq(m.boxes[1].title, "Input"); eq(m.boxes[1].amount, "38.4"); eq(m.boxes[1].capacity, "100")
    eq(m.boxes[1].note, "62 things " .. DOT .. " done in about 16 min")
    near(m.boxes[1].frac, 0.384, 1e-9)
    eq(m.boxes[2].note, "40 things " .. DOT .. " stops when full")
end)

test("hours of running a part has left: its condition over its wear an hour on that kind", function()
    local Model = loadModel()
    local m = Model.build(SCENES.running())
    -- the cutter wears parts 36 / 30 = 1.2 times; the modern motor loses 1 an hour, the normal blade 1.5
    eq(m.parts[1].life, "68 h of running left")
    eq(m.parts[2].life, "33 h of running left")
    eq(m.parts[1].effect, "3 at a time " .. DOT .. " speed x1.3 " .. DOT .. " power x1.5")
    eq(m.parts[2].effect, "+0.5 pieces a garment (on average)")
    eq(m.parts[1].tier, "Modern"); eq(m.parts[1].pct, "82%")
    near(Model.hoursLeft("woodSaw", Data.PARTS.motor.tiers.old, 100), 100 / (2 * 180 / 30), 1e-9)
end)

test("the buttons a part shows: remove when it is in, replace too when worn or broken, install when the slot is empty", function()
    local Model = loadModel()
    local function ids(card)
        local out = {}
        for _, b in ipairs(card.buttons) do out[#out + 1] = b.id end
        return table.concat(out, ",")
    end
    local m = Model.build(SCENES.running())
    eq(ids(m.parts[1]), "remove"); eq(ids(m.parts[2]), "remove")
    truthy(m.parts[1].buttons[1].tip, "removing says it switches the machine off")
    m = Model.build(SCENES.broken())
    eq(ids(m.parts[1]), "replace,remove", "the worn motor")
    eq(m.parts[1].effectTone, "warn")
    eq(ids(m.parts[2]), "replace,remove", "the broken blade")
    truthy(m.parts[2].buttons[1].strong, "replacing a broken part is the strong button")
    eq(m.parts[2].life, "broken"); eq(m.parts[2].lifeTone, "bad")
    -- the saw's cover: empty, optional
    m = Model.build(SCENES.saw())
    eq(#m.parts, 3)
    eq(ids(m.parts[3]), "install")
    truthy(m.parts[3].empty)
    eq(m.parts[3].effectTone, nil, "a cover it runs without is no fault")
    -- a missing motor is one
    local input = SCENES.idle()
    input.status.parts = { blade = { tier = "normal", cond = 50 } }
    local state = { kind = "cutter", on = true, parts = input.status.parts }
    input.status = statusOf(state)
    m = Model.build(input)
    eq(ids(m.parts[1]), "install"); eq(m.parts[1].effectTone, "bad"); truthy(m.parts[1].buttons[1].strong)
    eq(m.light.tone, "bad")
end)

test("stopped, switched off, without power: the light, the strip and the switch say why and what to do", function()
    local Model = loadModel()
    local m = Model.build(SCENES.broken())
    eq(m.light.text, "Stopped: the Blade is broken"); eq(m.light.tone, "bad")
    eq(m.strip.text, "The Blade is broken: replace it below to run again.")
    eq(m.perf.right, "while running")
    eq(m.perf.cells[2].sub, "none now")
    eq(m.perf.cells[3].sub, "quiet now")
    eq(m.perf.cells[1].sub, "half: worn part"); eq(m.perf.cells[1].subTone, "warn")
    eq(m.jobs.empty[1], "Work has stopped."); eq(m.jobs.empty[2], "14 left in the input.")
    eq(m.boxes[1].note, "14 things " .. DOT .. " goes on once the part is fixed")
    eq(m.boxes[2].tone, "bad", "an output 99 % full")
    -- off: the switch turns it on, and says why it cannot
    local input = SCENES.broken()
    input.status.on = false
    m = Model.build(input)
    eq(m.switch.label, "Turn on"); eq(m.switch.enabled, false)
    eq(m.switch.tip, "Cannot switch on: the Blade is broken")
    truthy(m.light.hollow)
    -- the saw switched off, no extension API: no fuel is burnt without it
    m = Model.build(SCENES.saw())
    eq(m.strip.text, "Switched off. Switch it on to work on what is in the input.")
    eq(m.perf.cells[2].sub, "none (no API)")
    eq(m.boxes[1].note, "3 things " .. DOT .. " starts when switched on")
    -- without power
    m = Model.build(SCENES.refiner())
    eq(m.light.tone, "bad"); eq(m.strip.text, "No electricity. Run a generator nearby.")
end)

test("idle and empty: the strip says what to put in, the input's open button stands out", function()
    local Model = loadModel()
    local m = Model.build(SCENES.idle())
    eq(m.light.text, "Nothing to work on"); eq(m.light.tone, "warn")
    eq(m.strip.text, getText("IGUI_OA_Machine_Hint_cutter"))
    eq(m.jobs.empty[1], "Nothing to work on.")
    truthy(m.boxes[1].strong)
    eq(m.boxes[1].note, "empty " .. DOT .. " starts when filled")
    eq(m.due, nil)
    -- something put in while it waits: it may start now
    local input = SCENES.idle()
    input.inCount = 4
    input.status.reason = nil
    m = Model.build(input)
    truthy(m.idleWithInput)
    eq(m.jobs.empty[1], "Starting soon.")
end)

test("the oil refiner works in litres; its second bin is the fill box; no time to empty from weight", function()
    local Model = loadModel()
    local input = SCENES.refiner()
    input.status.powered = true
    local m = Model.build(input)
    eq(m.perf.cells[1].value, "0.5 L oil/h")
    eq(m.boxes[2].title, "Fill Box")
    eq(m.boxes[2].note, "1 things " .. DOT .. " keep empty tanks here")
    eq(m.boxes[1].note, "2 things " .. DOT .. " Running")
    -- the fuel at a sandbox of 0.5 L for a load of 1: 0.3 x 0.5
    eq(m.perf.cells[2].value, "Power load 0.3")
end)

test("the rain storage: its share on the light, the water and the room, its buttons; no parts, jobs or bins", function()
    local Model = loadModel()
    local m = Model.build(SCENES.rain())
    eq(m.light.text, "72% full"); eq(m.light.tone, "water")
    eq(m.switch, nil)
    eq(m.jobs, nil); eq(m.boxes, nil); eq(m.perf, nil); eq(m.parts, nil); eq(m.lure, nil)
    eq(m.rain.water, "2,860"); eq(m.rain.capacity, "4,000")
    eq(m.rain.right, "of 4,000 L")
    eq(m.rain.rows[1][2], "1,140 L")
    eq(m.rain.rows[2][2], "about 72 L an hour in heavy rain", "litres an hour, not a ratio: the game's collectors differ in size")
    eq(m.rain.ticks[1], "1,000"); eq(m.rain.ticks[3], "3,000")
    truthy(m.rain.canEmpty); truthy(m.rain.canTransfer)
    local input = SCENES.rain()
    input.status.water = 0
    eq(Model.build(input).rain.canEmpty, false, "nothing to pour out")
end)

test("the lure: hours left, the next noise, take back while it works and clear once spent", function()
    local Model = loadModel()
    local m = Model.build(SCENES.lure())
    eq(m.light.text, "Running")
    eq(m.lure.big, "16 h 21 min left")
    near(m.lure.left, 16.35, 1e-9)
    -- 7.65 hours in: the last noise at 7.5, the next at 7.75
    eq(m.lure.rows[1][2], "in about 6 min (every 15 min)")
    eq(m.lure.rows[2][2], "60 tiles (a noise trap: 17)")
    eq(m.lure.button.id, "lure:take")
    eq(m.parts, nil); eq(m.perf, nil); eq(m.rain, nil)
    m = Model.build(SCENES.spent())
    eq(m.light.tone, "off"); truthy(m.light.hollow)
    eq(m.lure.big, "0 h left")
    eq(m.lure.rows[1][2], "none")
    eq(m.lure.button.id, "lure:clear")
end)

test("number formats: amounts, thousands, durations, a machine's number", function()
    local Model = loadModel()
    eq(Model.amount(140.4), "140"); eq(Model.amount(38.4), "38.4"); eq(Model.amount(36), "36"); eq(Model.amount(2.0), "2"); eq(Model.amount(0.068), "0.07")
    eq(Model.amount(0), "0")
    eq(Model.grouped(4000), "4,000"); eq(Model.grouped(1234567), "1,234,567"); eq(Model.grouped(999), "999")
    eq(Model.decimal(1.30, 2), "1.3"); eq(Model.decimal(0.06, 2), "0.06"); eq(Model.decimal(10, 2), "10")
    eq(Model.duration(0.25), "15 min"); eq(Model.duration(2), "2 h"); eq(Model.duration(16.35), "16 h 21 min")
    eq(Model.duration(0), "1 min", "never under a minute")
    eq(Model.number("m12"), 12)
end)

test("the key changes with what shows, not with what does not", function()
    local Model = loadModel()
    local a = Model.key(Model.build(SCENES.running()))
    eq(Model.key(Model.build(SCENES.running())), a)
    local input = SCENES.running()
    input.jobs[1].share = 0.7201
    eq(Model.key(Model.build(input)), a, "the same hundredth")
    input.jobs[1].share = 0.75
    truthy(Model.key(Model.build(input)) ~= a)
end)

-- Reading the game ----------------------------------------------------------------------------------------------------

local function fakeContainer(kind, weight, count)
    local c = { type = kind }
    function c:getType() return self.type end
    function c:getItems() return { size = function() return count end } end
    function c:getCapacityWeight() return weight end
    function c:getCapacity() return 100 end
    function c:getParent() return nil end
    return c
end

local function fakeMachine(state, opts)
    opts = opts or {}
    local square = {}
    function square:haveElectricity() return opts.power ~= false end
    function square:hasGridPower() return false end
    function square:getRoom() return nil end
    function square:getX() return 10 end
    function square:getY() return 20 end
    function square:getZ() return 0 end
    local object = { mod = { [Data.KEY] = state }, containers = opts.containers or {}, index = 0 }
    function object:hasModData() return true end
    function object:getModData() return self.mod end
    function object:getSquare() return square end
    function object:checkObjectPowered() return opts.power ~= false end
    function object:getContainerByType(t) return self.containers[t] end
    function object:getObjectIndex() return self.index end
    return object
end

local function cutterState()
    return { id = "m7", kind = "cutter", on = true, running = false, idle = true, reason = "noInput", last = 0, lanes = {},
        parts = { motor = { tier = "normal", cond = 90 }, blade = { tier = "old", cond = 40 } } }
end

test("reading a machine asks its status once, and its bins' weight and count without walking their items", function()
    local Model = loadModel()
    local object = fakeMachine(cutterState(), { containers = {
        OAMachineIn = fakeContainer("OAMachineIn", 12.5, 9), OAMachineOut = fakeContainer("OAMachineOut", 3, 2) } })
    local calls = 0
    local status = Machines.status
    Machines.status = function(o) calls = calls + 1 return status(o) end
    local input = Model.read(object)
    eq(calls, 1)
    eq(input.kind, "cutter"); eq(input.id, "m7")
    eq(input.inCount, 9)
    eq(#input.boxes, 2)
    eq(input.boxes[1].weight, 12.5); eq(input.boxes[2].role, "out")
    truthy(input.canOn.ok)
    eq(input.fuelRate, 0.1, "the sandbox's default when it has none")
    eq(input.hook, false, "no extension API in the tests")
    local m = Model.build(input)
    eq(m.boxes[1].amount, "12.5")
    eq(m.tag, "Research team equipment " .. DOT .. " unit 7")
end)

-- The layout ------------------------------------------------------------------------------------------------------------
-- The game's elements as far as the window uses them (the terminal's scale test has the same), and the fonts of the
-- screen sizes (the Korean line heights; Medium at 16 px is a guess).

local FONTS = {
    [16] = { S = 16, M = 22 },
    [19] = { S = 19, M = 29 },
    [26] = { S = 26, M = 33 },
}
local font

local function stubFonts(px)
    font = FONTS[px]
    _G.UIFont = { Small = "S", Medium = "M", Code = "C", NewSmall = "S" }
    _G.getTextManager = function()
        return {
            getFontHeight = function(_, f) return font[f] or font.S end,
            MeasureStringX = function(_, f, s) return #tostring(s) * 7 * (font[f] or font.S) / 16 end,
        }
    end
end

local function javaObject()
    local j = { x = 0, y = 0, w = 0, h = 0 }
    function j:setX(v) self.x = v end
    function j:setY(v) self.y = v end
    function j:setWidth(v) self.w = v end
    function j:setHeight(v) self.h = v end
    function j:getX() return self.x end
    function j:getY() return self.y end
    function j:getWidth() return self.w end
    function j:getHeight() return self.h end
    function j:getAbsoluteX() return self.x end
    function j:getAbsoluteY() return self.y end
    for _, name in ipairs({ "setAnchorLeft", "setAnchorRight", "setAnchorTop", "setAnchorBottom", "setWantKeyEvents",
        "setConsumeMouseEvents", "setWantExtraMouseEvents", "setForceCursorVisible", "setVisible" }) do
        j[name] = function() end
    end
    return j
end

local function gameClasses()
    local E = {}
    E.__index = E
    function E:derive(name)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o.Type = name
        return o
    end
    function E:new(x, y, w, h)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o.x, o.y, o.width, o.height = x, y, w, h
        o.children, o.drawn = {}, {}
        o.visible = true
        return o
    end
    function E:initialise() self.children = {} end
    function E:instantiate()
        local j = javaObject()
        self.javaObject = j
        j:setX(self.x); j:setY(self.y); j:setHeight(self.height); j:setWidth(self.width)
        self:createChildren()
    end
    function E:createChildren() end
    function E:addChild(c)
        if not c.javaObject then c:instantiate() end
        c.parent = self
        self.children[#self.children + 1] = c
    end
    function E:addToUIManager()
        if not self.javaObject then self:instantiate() end
        TEST.ui = TEST.ui or {}
        TEST.ui[#TEST.ui + 1] = self
    end
    function E:removeFromUIManager() self.removed = true end
    function E:setX(x) self.x = x; if self.javaObject then self.javaObject:setX(x) end end
    function E:setY(y) self.y = y; if self.javaObject then self.javaObject:setY(y) end end
    function E:setWidth(w) self.width = w; if self.javaObject then self.javaObject:setWidth(w) end end
    function E:setHeight(h) self.height = h; if self.javaObject then self.javaObject:setHeight(h) end end
    function E:getX() return self.javaObject:getX() end
    function E:getY() return self.javaObject:getY() end
    function E:getWidth() return self.javaObject:getWidth() end
    function E:getHeight() return self.javaObject:getHeight() end
    function E:getAbsoluteX() return self.javaObject:getAbsoluteX() end
    function E:getAbsoluteY() return self.javaObject:getAbsoluteY() end
    function E:getMouseX() return 0 end
    function E:getMouseY() return 0 end
    function E:isMouseOver() return false end
    function E:setAlwaysOnTop(v) self.alwaysOnTop = v end
    function E:setVisible(v) self.visible = v end
    function E:getIsVisible() return self.visible end
    function E:setAnchorRight(v) self.anchorRight = v end
    function E:setAnchorBottom(v) self.anchorBottom = v end
    function E:setResizable(v) self.resizable = v end
    function E:update() end
    local function rec(kind)
        return function(self, ...)
            self.drawn = self.drawn or {}
            self.drawn[#self.drawn + 1] = { kind, ... }
        end
    end
    E.drawRect, E.drawRectBorder = rec("rect"), rec("frame")
    E.drawText, E.drawTextCentre, E.drawTextRight = rec("text"), rec("centre"), rec("right")
    E.drawTextureScaledAspect, E.drawTextureScaled = rec("icon"), rec("texture")
    E.setStencilRect, E.clearStencilRect = rec("clip"), rec("unclip")
    function E.repaintStencilRect() end
    local Panel = E:derive("ISPanel")
    local Window = Panel:derive("ISCollapsableWindow")
    function Window:titleBarHeight() return font.S + 1 end
    _G.ISUIElement, _G.ISPanel, _G.ISCollapsableWindow = E, Panel, Window
    _G.ISButton, _G.ISLabel, _G.ISScrollingListBox, _G.ISRichTextPanel = Panel:derive("ISButton"),
        Panel:derive("ISLabel"), Panel:derive("ISScrollingListBox"), Panel:derive("ISRichTextPanel")
    _G.UIElement = { new = function() return javaObject() end }
    _G.OATab = Panel:derive("OATab")
    _G.ISBaseTimedAction = E:derive("ISBaseTimedAction")
end

-- Loads the window's files with the game's classes stubbed (and the terminal window the drawing needs).
local function loadWindow(px)
    englishText()
    stubFonts(px)
    gameClasses()
    _G.getScriptManager = function() return { FindItem = function() return nil end } end
    _G.getCore = function()
        return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 720 end }
    end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or string.find(name, "^TimedActions/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Trade/UI"
        OA.Trade.UI.scaled(OATab, ISPanel)
        real "OperationAcorn/Machines/Window"
    end)
    require = real
    if not ok then error(err, 0) end
    OA.Trade.UI.refreshScale()
    return OA.Trade.UI, OA.Trade.Draw, Machines.WindowModel, Machines.WindowLayout
end

local function useFonts(UI, px)
    font = FONTS[px]
    UI.refreshScale()
end

-- The texts a list draws, in design units: { s, x, y, w, h }.
local function textBoxes(UI, L)
    local out = {}
    for _, op in ipairs(L.ops) do
        if op[1] == 3 then
            local s, f = op[2], op[7]
            out[#out + 1] = { s = s, x = op[3], y = op[4], w = UI.textWidth(s, f), h = UI.fontHeight(f) }
        end
    end
    return out
end

local function overlap(a, b)
    local ox = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
    local oy = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
    return math.max(0, math.min(ox, oy))
end

-- A scene laid out at its kind's width: the list, its height and its width.
local function layOut(UI, Draw, Model, Layout, scene)
    local L = Draw.list(UI.palette("field"))
    local input = SCENES[scene]()
    local width = Layout.widthOf(input.kind)
    local h = Layout.build(L, Model.build(input), width)
    return L, h, width
end

for _, px in ipairs({ 16, 19, 26 }) do
    test("the window at " .. px .. " px: every text inside it and none on another, every scene", function()
        local UI, Draw, Model, Layout = loadWindow(px)
        useFonts(UI, px)
        for name in pairs(SCENES) do
            local L, h, width = layOut(UI, Draw, Model, Layout, name)
            local list = textBoxes(UI, L)
            truthy(#list > 10, name .. ": texts drawn")
            for _, t in ipairs(list) do
                truthy(t.x >= 0 and t.x + t.w <= width + 0.5,
                    name .. " " .. px .. " px: '" .. t.s .. "' inside the width (" .. t.x .. ", " .. t.w .. ")")
                truthy(t.y >= 0 and t.y + t.h <= h + 0.5, name .. " " .. px .. " px: '" .. t.s .. "' inside the height")
            end
            for i = 1, #list do
                for j = i + 1, #list do
                    local a, b = list[i], list[j]
                    truthy(overlap(a, b) <= 1, name .. " " .. px .. " px: '" .. a.s .. "' at " .. a.x .. "," .. a.y
                        .. " and '" .. b.s .. "' at " .. b.x .. "," .. b.y)
                end
            end
            -- every button and card inside the window
            for _, hit in ipairs(L.hits) do
                truthy(hit.x >= 0 and hit.x + hit.w <= width and hit.y >= 0 and hit.y + hit.h <= h,
                    name .. ": a hit inside the window")
            end
        end
    end)
end

test("the window fits a 1280 x 720 screen at the 16 px font, with room to spare; it grows with the font", function()
    local UI, Draw, Model, Layout = loadWindow(16)
    local tallest, tallestAt = 0, nil
    for name in pairs(SCENES) do
        useFonts(UI, 16)
        local _, h = layOut(UI, Draw, Model, Layout, name)
        local px = font.S + 1 + h
        if px > tallest then tallest, tallestAt = px, name end
        truthy(px <= 720 * 0.85, name .. ": " .. px .. " px high at 16 px")
        truthy(Layout.widthOf(SCENES[name]().kind) <= 1280 * 0.55)
        -- at 19 px (1080p) and 26 px (1440p) the window is the same design times the scale, inside those screens
        for _, size in ipairs({ { 19, 1080 }, { 26, 1440 } }) do
            useFonts(UI, size[1])
            local _, h2 = layOut(UI, Draw, Model, Layout, name)
            truthy(math.abs(h2 - h) <= 24, name .. ": the same design at " .. size[1] .. " px (" .. h .. ", " .. h2 .. ")")
            truthy(font.S + 1 + UI.px(h2) <= size[2] * 0.85, name .. " at " .. size[1] .. " px")
        end
    end
    local slots = #OperationAcorn.Machines.Data.KINDS[SCENES[tallestAt]().kind].slots
    eq(slots, 3, "a machine with three parts is the tallest: " .. tostring(tallestAt) .. " " .. tallest)
end)

test("the section heights do not jump as jobs come and go (the lanes' room is kept)", function()
    local UI, Draw, Model, Layout = loadWindow(16)
    local input = SCENES.running()
    local L = Draw.list(UI.palette("field"))
    local width = Layout.widthOf(input.kind)
    local busy = Layout.build(L, Model.build(input), width)
    input.jobs = { input.jobs[1] }
    L = Draw.list(UI.palette("field"))
    eq(Layout.build(L, Model.build(input), width), busy, "one job")
    input.jobs = {}
    L = Draw.list(UI.palette("field"))
    eq(Layout.build(L, Model.build(input), width), busy, "none")
end)

-- The window ------------------------------------------------------------------------------------------------------------

local function character(items)
    local inventory = { items = items or {} }
    function inventory:getItems()
        local list = self.items
        return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
    end
    local c = {}
    function c:getPlayerNum() return 0 end
    function c:isDead() return false end
    -- standing by the machine (its square is 10, 20)
    function c:getX() return 11.5 end
    function c:getY() return 20.5 end
    function c:getInventory() return inventory end
    local mod = {}
    function c:getModData() return mod end
    return c
end

local function partItem(name, cond)
    local item = { name = name, cond = cond }
    function item:getType() return self.name end
    function item:getFullType() return "OperationAcorn." .. self.name end
    function item:getName() return self.name end
    function item:getCondition() return self.cond end
    function item:getConditionMax() return 100 end
    return item
end

local function openWindow(px, items)
    local UI = loadWindow(px)
    _G.instanceof = function() return false end
    local object = fakeMachine(cutterState(), { containers = {
        OAMachineIn = fakeContainer("OAMachineIn", 12.5, 9), OAMachineOut = fakeContainer("OAMachineOut", 3, 2) } })
    local window = OAMachineWindow:new(0, 0, character(items), object)
    window:initialise()
    window:instantiate()
    return UI, window, object
end

test("the window closes when the character walks away from the machine", function()
    local now = 5000
    _G.getTimestampMs = function() return now end
    local _, window = openWindow(19)
    window:update()
    truthy(not window.removed, "open while near")
    window.character.getX = function() return 30 end
    now = now + OAMachineWindow.NEAR_MS
    window:update()
    truthy(window.removed, "gone once out of reach")
end)

test("a large machine is walked up to at the square of its footprint nearest the character", function()
    openWindow(19)
    local squares = {}
    _G.getCell = function()
        return { getGridSquare = function(_, x, y, z)
            local key = x .. "," .. y
            squares[key] = squares[key] or { x = x, y = y, getX = function(s) return s.x end,
                getY = function(s) return s.y end, getZ = function() return z end }
            return squares[key]
        end }
    end
    local anchor = { x = 10, y = 20, getX = function(s) return s.x end, getY = function(s) return s.y end,
        getZ = function() return 0 end }
    local object = { getSquare = function() return anchor end }
    Machines.state = function() return { kind = "propaneRefiner", dir = "S" } end
    Machines.tiles = function() return { { dx = 0, dy = 0 }, { dx = 1, dy = 0 }, { dx = 0, dy = 1 }, { dx = 1, dy = 1 } } end
    local character = { getX = function() return 12.5 end, getY = function() return 22.5 end }
    local square = Machines.nearSquare(object, character)
    eq(square.x, 11); eq(square.y, 21)
    character.getX = function() return 9.5 end
    character.getY = function() return 19.5 end
    square = Machines.nearSquare(object, character)
    eq(square.x, 10, "from the back corner's side, the anchor's square"); eq(square.y, 20)
end)

test("a machine's reach counts from the nearest square of its footprint", function()
    openWindow(19)
    local within = OAMachineWindow.within
    truthy(within(13.5, 20.5, 10, 20, 2, 2, 3), "1.5 squares off a 2x2's far side")
    truthy(within(14.9, 21, 10, 20, 2, 2, 3), "just under 3")
    truthy(not within(15.5, 21, 10, 20, 2, 2, 3), "3.5 squares off")
    truthy(not within(14.5, 24.5, 10, 20, 2, 2, 3), "diagonal: 2.5 and 2.5")
end)

test("an open window reads its machine a few times a second, and each frame only paints", function()
    local now = 5000
    _G.getTimestampMs = function() return now end
    local UI, window = openWindow(19)
    truthy(window.body.list, "laid out as it opens")
    eq(window.height, font.S + 1 + UI.px(window.body.height), "the window takes the body's height")
    local calls = 0
    local status = Machines.status
    Machines.status = function(o) calls = calls + 1 return status(o) end
    local list = window.body.list
    for _ = 1, 30 do
        window:update()
        window.body:prerender()
        window.body:render()
    end
    eq(calls, 1, "one read in the frames of the same quarter second")
    eq(window.body.list, list, "nothing changed: the same list, not laid out again")
    now = now + OAMachineWindow.READ_MS
    window:update()
    eq(calls, 2)
    -- what it shows changed: laid out again
    local state = Machines.state(window.object)
    state.parts.blade.cond = 10
    now = now + OAMachineWindow.READ_MS
    window:update()
    truthy(window.body.list ~= list, "laid out again")
    -- the machine is gone: the window closes
    window.object.index = -1
    window:update()
    truthy(window.removed)
end)

test("the bags are looked through for parts only when a part's button is pressed", function()
    _G.getTimestampMs = function() return 1 end
    local items = { partItem("CutBladeModern", 100), partItem("CutBladeOld", 74), partItem("MotorModern", 100) }
    local collects = 0
    local collect = Machines.collect
    Machines.collect = function(...) collects = collects + 1 return collect(...) end
    local UI, window = openWindow(16, items)
    for _ = 1, 10 do
        window:update()
        window.body:prerender()
    end
    eq(collects, 0, "not to open, read or paint the window")
    local hit
    for _, h in ipairs(window.body.list.hits) do
        if h.id == "part" and h.slot == "blade" then hit = h end
    end
    truthy(hit, "the blade's button")
    eq(hit.action, "remove", "a blade at 40 has only remove")
    window:onHit({ id = "part", action = "replace", slot = "blade", x = hit.x, y = hit.y, w = hit.w, h = hit.h })
    eq(collects, 1)
    local picker = window.picker
    truthy(picker, "the picker opens")
    eq(#picker.entries, 2, "the two blades that fit, not the motor")
    eq(picker.entries[1].item:getType(), "CutBladeModern", "the best first")
    truthy(picker.y >= 0 and picker.y + picker.height <= UI.dp(720), "inside the screen")
    truthy(picker.alwaysOnTop, "over the window, which the click brings to the front")
    picker:onMouseDownOutside()
    eq(window.picker, nil)
end)

test("the window steps aside while its part action is under way, whatever the mouse does, and is back after it", function()
    local now = 1
    _G.getTimestampMs = function() return now end
    local mx, my = 100, 100
    local saved = { getMouseX, getMouseY, ISTimedActionQueue, luautils, Machines.nearSquare }
    _G.getMouseX = function() return mx end
    _G.getMouseY = function() return my end
    local queued = {}
    _G.ISTimedActionQueue = { add = function(a) queued[a] = true end, hasAction = function(a) return queued[a] == true end }
    _G.luautils = { walkAdj = function() return true end }
    Machines.nearSquare = function()
        return { getX = function() return 1 end, getY = function() return 1 end, getZ = function() return 0 end }
    end
    local _, window = openWindow(16)
    window.isMouseOver = function() return true end
    _G.ISOAMachinePartOut = { new = function() return {} end }
    local function frames(n) for _ = 1, n do now = now + 100; window:stepAside(now) end end
    window:doRemove("blade")
    frames(5)
    eq(window.fade, OAMachineWindow.ASIDE, "thin, though the mouse rests on the button it pressed")
    mx = 140
    frames(3)
    eq(window.fade, OAMachineWindow.ASIDE, "still thin under a moving mouse")
    queued = {}
    frames(5)
    eq(window.fade, 1, "back when the action is done")
    eq(window.busy, nil)
    _G.getMouseX, _G.getMouseY, _G.ISTimedActionQueue, _G.luautils, Machines.nearSquare =
        saved[1], saved[2], saved[3], saved[4], saved[5]
end)

-- With the extension API's UI fonts the window follows the screen (Trade/UI.lua): it keeps to nine tenths of the
-- screen's height, and a body taller than that scrolls.
local function koApi()
    _G.PZExtAPI = { version = OA.API_VERSION, client = function() return "h" end, text = {
        font = function(_, px) return px end,
        fontHeight = function(_, key) return key end,
        -- a letter 5.5 wide at 16, a Hangul syllable 10.5: the API's Small measured in game (a letter about 5.1 on
        -- average in English text, a syllable about 9.8), with a margin
        measure = function(_, key, s)
            local w = 0
            for i = 1, #tostring(s) do w = w + (string.byte(s, i) >= 0x1100 and 10.5 or 5.5) end
            return w * key / 16
        end,
        draw = function() end,
    } }
end

for _, screenH in ipairs({ 300, 400, 720, 900, 1080, 1440 }) do
    test("with the API's fonts at " .. screenH .. "p the window keeps inside the screen, its body scrolling when taller", function()
        _G.getTimestampMs = function() return 1 end
        local UI = loadWindow(16)
        koApi()
        _G.getCore = function()
            return { getScreenWidth = function() return screenH * 16 / 9 end, getScreenHeight = function() return screenH end }
        end
        _G.instanceof = function() return false end
        UI.refreshScale()
        eq(UI.facesOn, true)
        local object = fakeMachine(cutterState(), { containers = {
            OAMachineIn = fakeContainer("OAMachineIn", 12.5, 9), OAMachineOut = fakeContainer("OAMachineOut", 3, 2) } })
        local window = OAMachineWindow:new(0, 0, character(), object)
        window:initialise()
        window:instantiate()
        truthy(window.height <= math.floor(screenH * 0.9), screenH .. ": " .. window.height .. " px high")
        if screenH < 400 then truthy(window.body.contentH > window.body.height, "taller than a small screen allows") end
        local body = window.body
        if body.contentH > body.height then
            truthy(body:onMouseWheel(1), "the wheel scrolls it")
            eq(body.scroll, math.min(OAMachineWindow.WHEEL, body.contentH - body.height))
            body:onMouseWheel(100)
            eq(body.scroll, body.contentH - body.height, "to its end and no further")
        else
            eq(body:onMouseWheel(1), false, "all of it shows: nothing to scroll")
        end
    end)
end

-- The wide window of a machine with parts ------------------------------------------------------------------------------
-- A machine with parts has its performance across the window, then two columns (the jobs and the bins left, the parts
-- right), wide enough for the longest lines of both languages in a column; none scrolls at 720p, 900p or 1080p at the
-- 16 px font.

local WIDE_KINDS = { "bulkShredder", "cutter", "propaneRefiner", "oilRefiner", "woodSaw" }
local BOX_TYPES = { ["in"] = "OAMachineIn", out = "OAMachineOut", tank = "OAMachineTank" }

-- A machine of a kind with every slot filled at `cond` of the tier (or empty: cond nil), running with a job a lane
-- (the motor's lanes: three with the modern one), its bins as full as they go.
local function partsScene(kind, tier, cond)
    local def = Data.KINDS[kind]
    local parts = {}
    for _, slot in ipairs(def.slots) do
        if cond then parts[slot] = { tier = slot == "cover" and "normal" or tier, cond = cond } end
    end
    local state = { kind = kind, on = true, running = cond ~= nil and cond > 0, parts = parts }
    local status = statusOf(state)
    local jobs = {}
    for i = 1, status.lanes do
        jobs[i] = { fullType = "Base.Log", name = "Log " .. i, share = 0.3 * i }
    end
    local boxes = {}
    for i, role in ipairs(def.containers) do
        boxes[i] = { role = role, type = BOX_TYPES[role], weight = 100, capacity = 100, count = 1200 }
    end
    return { kind = kind, id = "m7", status = status, hook = true, fuelRate = 0.1, inCount = 1200, jobs = jobs,
        boxes = boxes, canOn = { ok = true } }
end

-- Every text inside the width and the height, none on another and none cut short ("..."), every button and card
-- inside. Returns the texts.
local function checkList(UI, L, h, width, label)
    local list = textBoxes(UI, L)
    for _, t in ipairs(list) do
        truthy(t.x >= 0 and t.x + t.w <= width + 0.5, label .. ": '" .. t.s .. "' inside the width (" .. t.x .. ", " .. t.w .. ")")
        truthy(t.y >= 0 and t.y + t.h <= h + 0.5, label .. ": '" .. t.s .. "' inside the height")
        truthy(string.sub(t.s, -3) ~= "...", label .. ": '" .. t.s .. "' was cut short")
    end
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i], list[j]
            truthy(overlap(a, b) <= 1, label .. ": '" .. a.s .. "' and '" .. b.s .. "' on one another")
        end
    end
    for _, hit in ipairs(L.hits) do
        truthy(hit.x >= 0 and hit.x + hit.w <= width and hit.y >= 0 and hit.y + hit.h <= h, label .. ": a hit inside the window")
    end
    return list
end

-- The bins' amounts and the parts' tier chips are left out of a row that has no room for them (not cut), so the list
-- is checked to have them.
local function hasText(list, s)
    for _, t in ipairs(list) do
        if t.s == s then return true end
    end
    return false
end

-- Runs `fn` with the texts of a language (the window's files loaded with them), the language put back after.
local function inLanguage(lang, fn)
    LANG = lang
    local ok, err = pcall(fn)
    LANG = "EN"
    if not ok then error(err, 0) end
end

local function onScreen(UI, screenH)
    koApi()
    _G.getCore = function()
        return { getScreenWidth = function() return screenH * 16 / 9 end, getScreenHeight = function() return screenH end }
    end
    UI.refreshScale()
    eq(UI.facesOn, true)
end

test("a machine with parts is wider than one without; the window's width is the layout's", function()
    local _, _, _, Layout = loadWindow(16)
    for _, kind in ipairs(WIDE_KINDS) do
        eq(Layout.widthOf(kind), Layout.WIDE, kind)
    end
    for kind, def in pairs(Data.KINDS) do
        if #def.slots == 0 then eq(Layout.widthOf(kind), Layout.WIDTH, kind) end
    end
    truthy(Layout.WIDE > Layout.WIDTH and Layout.WIDE <= 700, "700 at the most")
end)

for _, lang in ipairs({ "EN", "KO" }) do
    for _, screenH in ipairs({ 720, 900, 1080 }) do
        test("every machine with parts shows whole in " .. lang .. " at " .. screenH .. "p: no scroll, nothing cut", function()
            inLanguage(lang, function()
                _G.getTimestampMs = function() return 1 end
                local UI, Draw, Model, Layout = loadWindow(16)
                onScreen(UI, screenH)
                local room = UI.dp(math.floor(screenH * 0.9) - UI.titleBarHeight())
                for _, kind in ipairs(WIDE_KINDS) do
                    -- fresh, standard, worn, broken and empty parts
                    for _, v in ipairs({ { "modern", 82 }, { "normal", 61 }, { "normal", 15 }, { "old", 0 }, { "old", false } }) do
                        local label = kind .. " " .. lang .. " " .. screenH .. "p " .. tostring(v[1]) .. "/" .. tostring(v[2])
                        local model = Model.build(partsScene(kind, v[1], v[2] or nil))
                        local L = Draw.list(UI.palette("field"))
                        local width = Layout.widthOf(kind)
                        local h = Layout.build(L, model, width)
                        local list = checkList(UI, L, h, width, label)
                        truthy(h <= room, label .. ": " .. h .. " high, " .. room .. " of room")
                        for _, box in ipairs(model.boxes) do
                            truthy(hasText(list, box.amount), label .. ": the amount of " .. box.title)
                        end
                        for _, card in ipairs(model.parts) do
                            truthy(hasText(list, card.tier), label .. ": the chip of the " .. card.name)
                        end
                        -- the saw with three lanes of jobs, the most there is
                        if kind == "woodSaw" and v[1] == "modern" and v[2] == 82 then
                            eq(#model.jobs.rows, 3, "three lanes of jobs")
                        end
                    end
                end
            end)
        end)
    end
end

test("the performance across, then two columns: the jobs and the bins on the left, the parts on the right", function()
    local UI, Draw, Model, Layout = loadWindow(16)
    useFonts(UI, 16)
    for _, kind in ipairs(WIDE_KINDS) do
        local width = Layout.widthOf(kind)
        local L = Draw.list(UI.palette("field"))
        local h = Layout.build(L, Model.build(partsScene(kind, "modern", 82)), width)
        local w = width - 2 * Layout.PAD
        local leftEnd = Layout.PAD + Layout.LEFT
        local rightStart = leftEnd + Layout.COLUMN_GAP
        truthy(rightStart < Layout.PAD + w and w - Layout.LEFT - Layout.COLUMN_GAP >= 380,
            kind .. ": the right column is wide enough for a part's card")
                -- the columns start at the Jobs head; the plate and the strip above are the whole width
        local top, perfTop, partsTop
        for _, t in ipairs(textBoxes(UI, L)) do
            if t.s == getText("IGUI_OA_Machine_Jobs") then top = t.y end
            if t.s == getText("IGUI_OA_Machine_Perf") then perfTop = t.y end
            if t.s == getText("IGUI_OA_Machine_Parts") then partsTop = t.y end
        end
        truthy(top, kind .. ": the jobs head")
        truthy(perfTop and perfTop < top, kind .. ": the performance above the columns")
        eq(partsTop, top, kind .. ": both columns begin with a head on the same line")
        for _, t in ipairs(textBoxes(UI, L)) do
            if t.y >= top then
                truthy(t.x + t.w <= leftEnd + 0.5 or t.x >= rightStart - 0.5, kind .. ": '" .. t.s .. "' across the columns")
            end
        end
        local perfs, opens, cards, ys, perfYs = 0, 0, 0, {}, {}
        for _, hit in ipairs(L.hits) do
            if hit.y >= top then
                truthy(hit.x + hit.w <= leftEnd + 0.5 or hit.x >= rightStart - 0.5, kind .. ": a hit across the columns")
            end
            if hit.hover and not hit.id then
                perfs = perfs + 1
                perfYs[#perfYs + 1] = hit.y
                truthy(hit.y < top, kind .. ": a performance cell above the columns")
            elseif hit.id == "open" then
                opens = opens + 1
                ys[#ys + 1] = hit.y
                truthy(hit.x + hit.w <= leftEnd + 0.5, kind .. ": a bin on the left")
            elseif hit.id == "part" then
                cards = cards + 1
                truthy(hit.x >= rightStart, kind .. ": a part on the right")
            end
        end
        eq(perfs, 3, kind .. ": three performance cells")
        eq(opens, 2, kind .. ": two bins")
        truthy(cards >= #Data.KINDS[kind].slots, kind .. ": a button a part")
        truthy(ys[2] > ys[1], kind .. ": the bins one above the other")
        truthy(perfYs[1] == perfYs[2] and perfYs[2] == perfYs[3], kind .. ": the performance on one row")
        truthy(h > top, kind .. ": a body")
    end
end)

test("the columns are rows whose edges line up; an empty slot is a card like the others, its part faint", function()
    local UI, Draw, Model, Layout = loadWindow(16)
    useFonts(UI, 16)
    for _, kind in ipairs(WIDE_KINDS) do
        for _, scene in ipairs({ "full", "running", "noCover" }) do
            local width = Layout.widthOf(kind)
            local input = partsScene(kind, scene == "running" and "modern" or "old", 82)
            if scene == "noCover" then input.status.parts.cover = nil end
            if scene ~= "running" then input.jobs = {} end
            local m = Model.build(input)
            local L = Draw.list(UI.palette("field"))
            local itemTexture = Draw.itemTexture
            Draw.itemTexture = function() return {} end
            Layout.build(L, m, width)
            Draw.itemTexture = itemTexture
            local w = width - 2 * Layout.PAD
            local rightStart = Layout.PAD + Layout.LEFT + Layout.COLUMN_GAP
            local rw = w - Layout.LEFT - Layout.COLUMN_GAP
            local top
            for _, t in ipairs(textBoxes(UI, L)) do
                if t.s == getText("IGUI_OA_Machine_Parts") then top = t.y end
            end
            -- the blocks' frames: the left column's as wide as it, the right's as wide as it, below the heads
            local left, right = {}, {}
            for _, op in ipairs(L.ops) do
                if op[1] == 2 and op[3] > top then
                    if op[2] == Layout.PAD and op[4] == Layout.LEFT then left[#left + 1] = op end
                    if op[2] == rightStart and op[4] == rw then right[#right + 1] = op end
                end
            end
            local label = kind .. " " .. scene
            eq(#left, 3, label .. ": the jobs and two bins")
            eq(#right, 3, label .. ": three parts")
            for k = 1, 3 do
                eq(left[k][3], right[k][3], label .. ": row " .. k .. " begins level")
                eq(left[k][5], right[k][5], label .. ": row " .. k .. " is as tall on both sides")
            end
            if scene == "noCover" then
                local c = m.parts[#m.parts]
                eq(c.slot, "cover")
                truthy(c.empty and c.icon, label .. ": the empty cover shows the part it takes")
                local faint
                for _, op in ipairs(L.ops) do
                    if op[1] == 4 and op.item == c.icon then faint = op[7] end
                end
                truthy(faint and faint < 1, label .. ": drawn faint")
            end
        end
    end
end)

test("a kind without parts keeps one column of the usual width", function()
    local UI, Draw, Model, Layout = loadWindow(16)
    useFonts(UI, 16)
    for _, scene in ipairs({ "rain", "lure", "spent" }) do
        local _, h, width = layOut(UI, Draw, Model, Layout, scene)
        eq(width, Layout.WIDTH, scene)
        truthy(h > 0)
    end
end)

test("the window opens as wide as its kind, in the middle of the screen", function()
    _G.getTimestampMs = function() return 1 end
    local UI = loadWindow(16)
    _G.instanceof = function() return false end
    local object = fakeMachine(cutterState(), { containers = {
        OAMachineIn = fakeContainer("OAMachineIn", 12.5, 9), OAMachineOut = fakeContainer("OAMachineOut", 3, 2) } })
    local window = OAMachineWindow.open(character(), object)
    local width = UI.px(Machines.WindowLayout.WIDE)
    eq(window.width, width)
    eq(window.body.width, Machines.WindowLayout.WIDE)
    eq(window.x, (1280 - width) / 2)
    eq(window.y, math.max(0, (720 - window.height) / 2))
end)
