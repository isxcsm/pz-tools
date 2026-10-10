-- The terminal window's attention rules (client Trade/TerminalWindow, DESIGN-terminal 11.1): a tab whose dot turns new
-- blinks until it is shown, the one API (blinkTab) the other parts use, what the tab on show keeps as seen (once per
-- value, and a screen of the status tab asks the window which it is), and which screen of a tab is on show. The game's
-- window and panel classes are stand-ins; the window is made without its widgets.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Terminal"
local OA = OperationAcorn
local Terminal = OA.Terminal

local function loadWindow()
    local function class(name)
        local c = { Type = name }
        c.derive = function(self, derived)
            local d = { Type = derived, super = self }
            d.derive = self.derive
            setmetatable(d, { __index = self })
            return d
        end
        c.new = function(self, x, y, w, h)
            local o = { x = x, y = y, width = w, height = h }
            return setmetatable(o, { __index = self })
        end
        return c
    end
    _G.ISPanel, _G.ISCollapsableWindow = class("ISPanel"), class("ISCollapsableWindow")
    _G.UIFont = { Small = "S", Medium = "M", Code = "C" }
    _G.getTextManager = function()
        return {
            getFontHeight = function() return 16 end,
            MeasureStringX = function(_, font, text) return #text * 2 end,
        }
    end
    OA.Client = OA.Client or {}
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Trade/UI"
        return real "OperationAcorn/Trade/TerminalWindow"
    end)
    require = real
    if not ok then error(err, 0) end
    return OATerminalWindow
end

-- A window as `new` makes it, without the widgets; the record is the one the stub of OA.Client gives.
local function makeWindow(record)
    local Window = loadWindow()
    OA.Client.record = function() return record end
    OA.Client.id = function() return "p1" end
    local character = { getX = function() return 0 end, getY = function() return 0 end }
    local window = setmetatable({ marks = {}, blink = {}, told = {}, views = {}, activeId = "status", character = character },
        { __index = Window })
    return window, Window
end

local function register(marks)
    Terminal.clear()
    for _, id in ipairs(Terminal.ORDER) do
        Terminal.addTab(id, function() end, { mark = function() return marks[id] end })
    end
end

test("a tab whose dot turns new blinks, once, until it is shown", function()
    local marks = { missions = "new", shop = nil, status = "bad" }
    register(marks)
    local window = makeWindow({})
    window:updateMarks({})
    eq(window.blink.missions, true, "new when the window opens")
    eq(window.blink.status, nil, "a red dot is not a blink, and the status tab is the one on show")
    eq(window.blink.shop, nil)
    window.views.missions = { setVisible = function() end }
    window:activate("missions")
    eq(window.blink.missions, nil, "shown: it stops")
    window.activeId = "status"
    window:updateMarks({})
    eq(window.blink.missions, nil, "the dot is still new, but not turned new again")
    marks.missions = nil
    window:updateMarks({})
    marks.missions = "new"
    window:updateMarks({})
    eq(window.blink.missions, true, "gone and new again: it blinks again")
    marks.shop = "new"
    window:updateMarks({})
    eq(window.blink.shop, true)
    Terminal.clear()
end)

test("blinkTab is the one way to blink a tab, and the tab on show does not", function()
    register({})
    local window = makeWindow({})
    window:blinkTab("shop")
    window:blinkTab("status")
    eq(window.blink.shop, true)
    eq(window.blink.status, nil, "the tab on show has nothing to blink for")
    Terminal.clear()
end)

test("which screen of a tab is on show", function()
    register({})
    local window = makeWindow({})
    eq(window:subOn("status"), nil, "not made yet")
    window.views.status = { sub = "progress" }
    window.views.shop = {}
    eq(window:subOn("status"), "progress")
    eq(window:subOn("shop"), nil, "a tab without sub-tabs")
end)

test("what the tab on show has seen is told to the server once a value, and by the screen on show", function()
    local sent = {}
    OA.Sync.send = function(character, command, args) sent[#sent + 1] = { command = command, key = args.key, value = args.value } end
    Terminal.clear()
    Terminal.addTab("status", function() end, { seen = function(record, window)
        if window:subOn("status") == "progress" then return "road", 4 end
        return nil
    end })
    Terminal.addTab("shop", function() end, { seen = function() return "tier", 4 end })
    local record = {}
    local window = makeWindow(record)
    window.views.status = { sub = "heli" }
    window:markSeen(record)
    eq(#sent, 0, "the heli screen shows no level")
    window.views.status.sub = "progress"
    window:markSeen(record)
    eq(#sent, 1); eq(sent[1].command, "terminalSeen"); eq(sent[1].key, "road"); eq(sent[1].value, 4)
    window:markSeen(record)
    eq(#sent, 1, "told once while the record has not answered yet")
    Terminal.setSeen(record, "road", 4)
    window:markSeen(record)
    eq(#sent, 1, "and not again when it has")
    window.activeId = "shop"
    window:markSeen(record)
    eq(#sent, 2); eq(sent[2].key, "tier")
    Terminal.clear()
end)

-- The boot sequence's part in the window (the timing itself is trade_bootseq_test) ---------------------------------

require "OperationAcorn/Trade/BootSeq"
local Seq = OperationAcorn.Trade.BootSeq

local function bootWindow(first, crude)
    local window, Window = makeWindow({})
    local now = 1000
    _G.getTimestampMs = function() return now end
    window.boot = Seq.new(first, crude)
    window.views = {}
    local heard = 0
    window.views.status = { consoleOver = function() heard = heard + 1 end }
    window.overlay = { gone = false }
    window.bootOverlay = window.overlay
    window.removeChild = function(self, child) child.gone = true end
    window.keys = true
    window.setWantKeyEvents = function(self, want) self.keys = want end
    return window, function(ms) now = ms end, function() return heard end
end

test("the first open of a field terminal is claimed once, in the object's modData", function()
    local data = {}
    local object = { getModData = function() return data end, transmitModData = function() end }
    _G.isClient = function() return false end
    local Window = loadWindow()
    eq(Window.claimFirst(object, "field"), true)
    eq(data.OA_Booted, true)
    eq(Window.claimFirst(object, "field"), false, "only the first")
    local crudeData = {}
    local crude = { getModData = function() return crudeData end }
    eq(Window.claimFirst(crude, "crude"), false, "the crude terminal has none (an upgrade is the same object)")
    eq(crudeData.OA_Booted, nil, "and leaves the flag for the upgrade's first open")
    eq(Window.claimFirst(nil, "field"), false)
end)

test("the window keeps the console up, takes it off when the fade starts, and lets the run go when it is over", function()
    local window, setNow, heard = bootWindow(false, false)
    setNow(1000)
    window:bootTick()
    eq(window.overlay.gone, false, "the first frame starts the run")
    eq(window.bootAlpha, nil)
    setNow(1000 + 8699)
    window:bootTick()
    eq(window.overlay.gone, false)
    setNow(1000 + 8800)
    window:bootTick()
    eq(window.overlay.gone, false, "still the switch-off")
    setNow(1000 + 8980 + 175)
    window:bootTick()
    eq(window.overlay.gone, true, "the fade started: the console is off and the tabs are usable")
    eq(window.bootOverlay, nil)
    eq(heard(), 1, "the status tab is told")
    near(window.bootAlpha, 0.5, 1e-9)
    window:bootTick()
    eq(heard(), 1, "once")
    setNow(1000 + 8980 + 350)
    window:bootTick()
    eq(window.boot, nil, "over: nothing left to run")
    eq(window.bootAlpha, nil)
    eq(window.keys, false, "and no keys wanted")
end)

test("a click or a key skips the console and starts the fade at once", function()
    local window, setNow, heard = bootWindow(true, false)
    setNow(1000)
    window:bootTick()
    setNow(1300)
    window:bootSkip()
    eq(window.overlay.gone, true)
    eq(heard(), 1)
    eq(window.bootAlpha, 1, "the fade starts from black")
    -- a key does the same
    local other, set2 = bootWindow(false, true)
    set2(2000)
    other:bootTick()
    set2(2100)
    other:onKeyPress(30)
    eq(other.overlay.gone, true)
    -- and after it is over a key does nothing
    set2(9999)
    other:bootTick()
    eq(other.boot, nil)
    other:onKeyPress(30)
    other:bootSkip()
end)

