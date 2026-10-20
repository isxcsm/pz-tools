-- The shared UI kit's following of elements frame by frame (PZUIKit UI.live, for PZ Optimization's retained UI): an
-- element followed for several things at once keeps each until it stops, and is let go when none goes on; one hidden
-- waits, and one taken out of the UI is let go.
require "OperationAcorn/Core"

local now

local function load()
    -- the game's panel, as far as the kit's file asks of it as it loads
    local panel = {}
    panel.derive = function(self)
        local d = setmetatable({}, { __index = self })
        d.__index = d
        return d
    end
    ISPanel = panel
    UIFont = UIFont or setmetatable({}, { __index = function(_, k) return k end })
    now = 1000
    getTimestampMs = function() return now end
    Events = Events or {}
    Events.OnPreUIDraw = Events.OnPreUIDraw or { Add = function() end }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "PZUIKit/UI")
    require = real
    if not ok then error(err, 0) end
    return PZUIKit.UI
end

local function element(parent)
    return { parent = parent, isVisible = function() return true end }
end

test("an element followed for two things keeps the one still going when the other stops", function()
    local UI = load()
    local window = element(nil)
    local el = element(window)
    local slideEnds, glowEnds = 1100, 1300
    local function slide(_, t) return t < slideEnds and t or nil end
    local function glow(_, t) return t < glowEnds and -t or nil end
    UI.live(el, slide)
    UI.live(el, glow)
    UI.live(el, slide) -- once
    UI.liveFrame()
    truthy(el.liveLook ~= nil, "followed")
    local count = window.liveCount
    now = 1200
    UI.liveFrame()
    eq(el.liveLook, -1200, "the slide stopped, the glow goes on")
    truthy(window.liveCount > count, "the window it is in is told")
    count = window.liveCount
    now = 1250
    UI.liveFrame()
    truthy(window.liveCount > count, "still followed after the first stopped")
    now = 1300
    UI.liveFrame()
    eq(el.liveLook, nil, "let go once neither goes on")
    count = window.liveCount
    now = 1400
    UI.liveFrame()
    eq(window.liveCount, count, "and nothing more")
end)

test("a window hidden for the game's pause menu waits and goes on once shown; one taken out of the UI is let go", function()
    local UI = load()
    local shown = true
    local window = { isVisible = function() return shown end }
    local el = element(window)
    local asked = 0
    UI.live(el, function(_, t) asked = asked + 1; return t end)
    UI.liveFrame()
    eq(el.liveLook, 1000)
    shown = false
    now = 1100
    UI.liveFrame()
    eq(asked, 1, "hidden: not asked")
    eq(el.liveLook, 1000, "and kept as it was")
    shown = true
    now = 1200
    UI.liveFrame()
    eq(el.liveLook, 1200, "shown again: it goes on (the static moves again after the pause menu)")
    window.uiGone = true
    now = 1300
    UI.liveFrame()
    eq(el.liveLook, nil, "taken out of the UI: let go")
    window.uiGone = nil
    now = 1400
    UI.liveFrame()
    eq(el.liveLook, nil, "and not followed again by itself")
end)

test("an element's entries are dropped with its last one: nothing animated stays kept", function()
    local UI = load()
    local window = element(nil)
    local a, b = element(window), element(window)
    local function until1100(_, t) return t < 1100 and t or nil end
    local function until1200(_, t) return t < 1200 and t or nil end
    UI.live(a, until1100)
    UI.live(a, until1200)
    UI.live(b, until1100)
    local entries, kept = UI.liveSize()
    eq(entries, 3)
    eq(kept, 2)
    UI.liveFrame()
    now = 1100
    UI.liveFrame()
    entries, kept = UI.liveSize()
    eq(entries, 1, "a's second entry goes on")
    eq(kept, 1, "b is let go with its only entry")
    -- the same function again once let go is a new entry (the once is for entries followed)
    UI.live(b, until1100)
    entries, kept = UI.liveSize()
    eq(entries, 2)
    eq(kept, 2)
    now = 1200
    UI.liveFrame()
    now = 1300
    UI.liveFrame()
    entries, kept = UI.liveSize()
    eq(entries, 0)
    eq(kept, 0, "no element is kept once every entry has ended")
end)

test("an element draws at the frame its look last changed in: no clock read once it holds still", function()
    local UI = load()
    local el = element(element(nil))
    local ends = 1100
    UI.live(el, function(_, t) return t < ends and t or nil end)
    now = 1050
    UI.liveFrame()
    eq(UI.frameNow(el), 1050, "moving: the frame's time")
    now = 1100
    UI.liveFrame()
    eq(UI.frameNow(el), 1100, "the frame it stopped in")
    now = 5000
    UI.liveFrame()
    eq(UI.frameNow(el), 1100, "still: it stands")
    -- a light that has come up is read at that time, without the clock
    local lit = element(element(nil))
    eq(UI.hoverLight(lit, "a", true), 0, "comes up from nothing")
    for _ = 1, 20 do
        now = now + 16
        UI.liveFrame()
    end
    eq(UI.hoverLight(lit, "a", true), 1, "up")
    local reads = 0
    getTimestampMs = function() reads = reads + 1; return now end
    now = now + 1000
    eq(UI.hoverLight(lit, "a", true), 1, "held up")
    eq(select(1, UI.placeLevels(lit, "x")), 0)
    eq(reads, 0, "a still light reads no clock")
    eq(UI.hoverLight(lit, "a", false), 1, "going down starts where it was")
    truthy(reads > 0, "a light set off reads the clock")
end)
