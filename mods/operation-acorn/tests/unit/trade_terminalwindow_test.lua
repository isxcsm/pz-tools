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

test("a terminal's first open at all, either tier, is claimed once (its boot cannot be skipped)", function()
    local data = {}
    local object = { getModData = function() return data end, transmitModData = function() end }
    _G.isClient = function() return false end
    local Window = loadWindow()
    eq(Window.claimOpened(object), true)
    eq(data.OA_Opened, true)
    eq(Window.claimOpened(object), false, "only the first")
    eq(Window.claimOpened(nil), false)
end)

test("the window keeps the console up, takes it off when the fade starts, and lets the run go when it is over", function()
    local window, setNow, heard = bootWindow(false, false)
    setNow(1000)
    eq(window:bootTick(), 0, "what the window shows: the time into the boot")
    eq(window.overlay.gone, false, "the first frame starts the run")
    eq(window.bootAlpha, nil)
    eq(window.overlay.look, 0, "written to the console")
    setNow(1000 + 1600)
    eq(window:bootTick(), 1600, "every frame differs: the static scrolls")
    eq(window.overlay.look, 1600)
    setNow(1000 + 10199)
    window:bootTick()
    eq(window.overlay.gone, false)
    setNow(1000 + 10300)
    window:bootTick()
    eq(window.overlay.gone, false, "still the switch-off")
    setNow(1000 + 10480 + 175)
    near(window:bootTick(), 0.5, 1e-9, "then the fade")
    eq(window.overlay.gone, true, "the fade started: the console is off and the tabs are usable")
    eq(window.bootOverlay, nil)
    eq(heard(), 1, "the status tab is told")
    near(window.bootAlpha, 0.5, 1e-9)
    window:bootTick()
    eq(heard(), 1, "once")
    setNow(1000 + 10480 + 350)
    eq(window:bootTick(), nil, "then nothing")
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


test("the boot runs every frame before the UI draws, and what it shows is written where PZ Optimization sees it", function()
    local window, setNow = bootWindow(false, false)
    local added, handler = 0, nil
    local saved = _G.Events
    _G.Events = { OnPreUIDraw = { Add = function(fn) added = added + 1; handler = fn end } }
    local savedBoot = _G.OATerminalBoot
    local console = { gone = false }
    for _, k in ipairs({ "initialise", "instantiate", "setAnchorRight", "setAnchorBottom" }) do console[k] = function() end end
    _G.OATerminalBoot = { new = function() return console end }
    window.width, window.height = 1000, 700
    window.titleBarHeight = function() return 20 end
    window.resizeWidgetHeight = function() return 10 end
    window.addChild = function(self, child) self.added = child end
    local shown = true
    window.isVisible = function() return shown end
    local screen = { isVisible = function() return true end }
    window.parent = screen
    local lines = window.boot.lines
    window.boot.lines = {}
    window:startBoot()
    eq(window.added, nil, "a run without lines has no console")
    window.boot.lines = lines
    window:startBoot()
    eq(window.added, console)
    local UI = OperationAcorn.Trade.UI
    eq(UI.liveFrame, handler)
    truthy(added <= 1, "the handler is added once")
    setNow(1000)
    handler()
    eq(window.liveLook, 0, "the frame ticks the run and writes its look")
    eq(console.look, 0)
    local count = screen.liveCount
    truthy(count, "and a count to what the window is in")
    handler()
    eq(screen.liveCount, count, "the same frame again: nothing written")
    setNow(1000 + 600)
    handler()
    eq(window.liveLook, 600, "the time into the boot: the static scrolls every frame")
    truthy(screen.liveCount > count)
    setNow(1000 + 20000)
    handler()
    eq(window.boot, nil, "the run is over")
    eq(console.gone, true)
    eq(window.liveLook, nil, "and the window let go")
    -- a window closed during its boot is let go too
    local other, set2 = bootWindow(false, false)
    other.width, other.height = 1000, 700
    other.titleBarHeight, other.resizeWidgetHeight = window.titleBarHeight, window.resizeWidgetHeight
    other.addChild = window.addChild
    local open = true
    other.isVisible = function() return open end
    other:startBoot()
    set2(1000)
    handler()
    set2(1600)
    handler()
    eq(other.liveLook, 600)
    open = false
    set2(1700)
    handler()
    eq(other.liveLook, 600, "hidden (the game hides every window for its pause menu): it waits")
    open = true
    other.uiGone = true
    handler()
    eq(other.liveLook, nil, "taken out of the UI: let go")
    other.uiGone = nil
    set2(3000)
    handler()
    eq(other.liveLook, nil, "not ticked any more")
    _G.Events, _G.OATerminalBoot = saved, savedBoot
end)

test("the strip draws the window's tabs, dots and blinks: each change of them is written to it, which PZ Optimization watches", function()
    local marks = {}
    register(marks)
    local window = makeWindow({})
    window.strip = {}
    window:updateMarks({})
    eq(window.strip.rev, nil, "no dot, no blink: nothing changed")
    marks.missions = "new"
    window:updateMarks({})
    local rev = window.strip.rev
    truthy(rev, "a dot that blinks")
    window:updateMarks({})
    eq(window.strip.rev, rev, "the same dots: nothing")
    window:blinkTab("missions")
    eq(window.strip.rev, rev, "already blinking: nothing")
    window.views.missions = { setVisible = function() end }
    window:activate("missions")
    truthy(window.strip.rev > rev, "the tab on show, its blink gone")
    rev = window.strip.rev
    window:activate("missions")
    eq(window.strip.rev, rev, "the tab already on show: nothing")
end)

test("after its boot the crude window keeps a weak signal going, the field one is let go", function()
    local crude, setNow = bootWindow(false, true)
    crude.tier = "crude"
    crude.x = 100
    crude.getX = function(self) return self.x end
    crude.setX = function(self, x) self.x = x end
    local Window = getmetatable(crude).__index
    setNow(1000)
    truthy(Window.liveFrame(crude, 1000) ~= nil, "the boot")
    local seen, still, jolted = false, 0, false
    for t = 20000, 60000, 20 do
        setNow(t)
        local look = Window.liveFrame(crude, t)
        truthy(look ~= nil, "followed while open")
        if crude.signalFade then seen = true else still = still + 1 end
        if crude.x ~= 100 then jolted = true end
        truthy(math.abs(crude.x - 100) <= 3, "a pixel or two")
        if not crude.signalFade then eq(crude.x, 100, "and back between spells") end
    end
    eq(crude.boot, nil)
    truthy(seen, "a spell came")
    truthy(jolted, "the window jolted in it")
    truthy(still > 1500, "and it is quiet most of the time")
    -- dragged during a jolt: left where the player put it
    crude.moving = true
    Window.liveFrame(crude, 60020)
    eq(crude.joltX, 0)
    local field, set2 = bootWindow(false, false)
    field.tier = "field"
    set2(1000)
    Window.liveFrame(field, 1000)
    set2(30000)
    eq(Window.liveFrame(field, 30000), nil, "the field terminal moves by itself no more")
    eq(field.signalFade, nil)
end)

test("the crude terminal's static scrolls and swaps its two tiles, counted from its first frame", function()
    loadWindow()
    local S = OATerminalStatic
    local panel = {}
    local clock = 1760000000000
    local looks = {}
    eq(S.frame(panel, clock), 0, "from its first frame (the clock itself is too large for Kahlua's %)")
    for t = 0, 2000, 10 do
        local look = S.frame(panel, clock + t)
        truthy(panel.tileIndex == 1 or panel.tileIndex == 2)
        truthy(panel.offset >= 0 and panel.offset < S.TILE)
        looks[look] = true
    end
    eq(panel.offset, math.floor(2000 * S.SPEED / 1000) % S.TILE, "it scrolls at SPEED")
    local n = 0
    for _ in pairs(looks) do n = n + 1 end
    truthy(n > 50, "a new look as it moves: " .. n)
end)

test("a screen put on show comes up over REVEAL_MS, drawn afresh every frame, then the window is let go", function()
    local window, setNow = bootWindow(false, false)
    window.tier = "field"
    local Window = getmetatable(window).__index
    window.boot = nil
    setNow(5000)
    local shown = true
    local tab = { isVisible = function() return shown end }
    local screen = { isVisible = function() return true end, parent = tab }
    window:reveal(tab)
    eq(window.revealT, 0)
    window:reveal(screen)
    eq(window.revealing.el, tab, "a tab opened on one of its screens: the whole tab comes up")
    local looks, last = {}, nil
    for t = 5000, 5000 + Window.REVEAL_MS - 1, 16 do
        local look = Window.liveFrame(window, t)
        truthy(look ~= nil and look ~= last, "a new look every frame")
        truthy(window.revealT >= 0 and window.revealT < 1)
        last = look
    end
    eq(Window.liveFrame(window, 5000 + Window.REVEAL_MS), nil, "over: the field window is let go")
    eq(window.revealing, nil)
    eq(window.revealT, nil)
    -- a screen taken off before it is up stops at once
    setNow(9000)
    window:reveal(screen)
    eq(window.revealing.el, screen, "later, a screen of its own")
    shown = false
    local tick = window:revealTick(9010)
    eq(tick, nil)
    -- not in the boot: its fade brings the first screen up
    window.boot = Seq.new(false, false)
    window:reveal(tab)
    eq(window.revealing, nil)
end)

test("hover and press lights: eased, one key can have both, and the element is followed only while one moves", function()
    loadWindow()
    local UI = OperationAcorn.Trade.UI
    local now = 1000
    _G.getTimestampMs = function() return now end
    _G.Events = _G.Events or { OnPreUIDraw = { Add = function() end } }
    local el = {}
    eq(UI.hoverLight(el, "a", false), 0)
    eq(el.fx, nil, "nothing kept for an element never hovered")
    eq(UI.hoverLight(el, "a", true), 0, "comes up from nothing")
    now = now + UI.HOVER_IN_MS / 2
    local mid = UI.hoverLight(el, "a", true)
    truthy(mid > 0.5 and mid < 1, "eased out: past half at half the time " .. mid)
    eq(UI.flashLevel(el, "a"), 0, "the hover is not a flash")
    UI.flash(el, "a")
    eq(UI.flashLevel(el, "a"), 1)
    truthy(UI.fxFrame(el, now) ~= nil, "moving")
    now = now + UI.FLASH_MS
    eq(UI.hoverLight(el, "a", true), 1, "and the flash leaves the hover as it was")
    eq(UI.flashLevel(el, "a"), 0)
    eq(UI.fxFrame(el, now), nil, "all still: let go")
    UI.hoverLight(el, "a", false)
    now = now + UI.HOVER_OUT_MS / 2
    local down = UI.hoverLight(el, "a", false)
    truthy(down > 0 and down < 0.5, "going down " .. down)
end)

test("places lit one at a time: the one under the mouse comes up, the one left goes down, a click flashes one", function()
    loadWindow()
    local UI = OperationAcorn.Trade.UI
    local now = 1000
    _G.getTimestampMs = function() return now end
    _G.Events = _G.Events or { OnPreUIDraw = { Add = function() end } }
    local el = {}
    UI.placeLight(el, nil)
    eq(el.fx, nil, "nothing kept while nothing is hovered")
    UI.placeLight(el, "a", "data a")
    now = now + UI.HOVER_IN_MS
    eq(UI.placeLevels(el, "a"), 1)
    UI.placeLight(el, "a", "data a2")
    eq(el.fx.cur.data, "data a2", "the same place: its data follows, nothing restarts")
    UI.placeLight(el, "b")
    now = now + UI.HOVER_OUT_MS / 2
    local a, b = UI.placeLevels(el, "a"), UI.placeLevels(el, "b")
    truthy(a > 0 and a < 1, "a goes down " .. a)
    eq(b, 1, "b is up")
    UI.placeLight(el, "a")
    local back = UI.placeLevels(el, "a")
    eq(back, a, "back onto a: it comes up from where it was")
    UI.placeFlash(el, "c")
    local k, f = UI.placeLevels(el, "c")
    eq(k, 0); eq(f, 1)
    now = now + UI.FLASH_MS + UI.HOVER_OUT_MS
    eq(UI.fxFrame(el, now), nil, "all still: let go")
end)
