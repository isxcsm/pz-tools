-- The shared UI kit's following of elements frame by frame (PZUIKit UI.live, for PZ Optimization's retained UI): an
-- element followed for several things at once keeps each until it stops, and is let go when none goes on.
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
