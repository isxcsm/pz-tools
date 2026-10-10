-- The hallucination overlay (client Story/Hallucination) with PZ Optimization's retained UI: its frame (Trade/UI live)
-- runs before the UI draws, steps the ringing, gives a look that holds while the glow holds and moves when it falls, and
-- takes the overlay off after its last run; the drawing only paints. The game's panel is a stand-in.
require "OperationAcorn/Core"
local OA = OperationAcorn

-- The game's panel: made as a table, the calls the overlay makes recorded.
local function panelClass()
    local c = {}
    c.derive = function(self)
        local d = setmetatable({}, { __index = self })
        d.__index = d
        return d
    end
    c.new = function(self, x, y, w, h)
        return setmetatable({ x = x, y = y, width = w, height = h, rects = 0 }, { __index = self })
    end
    c.initialise = function() end
    c.instantiate = function(self)
        self.javaObject = { setConsumeMouseEvents = function() end, setIgnoreLossControl = function() end }
    end
    c.setAlwaysOnTop = function() end
    c.addToUIManager = function(self) self.added = true end
    c.removeFromUIManager = function(self) self.removed = true end
    c.isVisible = function() return true end
    c.drawRect = function(self) self.rects = self.rects + 1 end
    return c
end

local now
local volumes, stopped

local function load()
    ISPanel = panelClass()
    UIFont = UIFont or setmetatable({}, { __index = function(_, k) return k end })
    now = 5000000
    getTimestampMs = function() return now end
    getPlayerScreenLeft = function() return 0 end
    getPlayerScreenTop = function() return 0 end
    getPlayerScreenWidth = function() return 1920 end
    getPlayerScreenHeight = function() return 1080 end
    volumes, stopped = {}, 0
    local emitter = {
        playSound = function() return 7 end,
        setVolume = function(_, id, v) volumes[#volumes + 1] = v end,
        stopSound = function() stopped = stopped + 1 end,
    }
    getSpecificPlayer = function() return { getEmitter = function() return emitter end } end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Story/Hallucination")
    require = real
    if not ok then error(err, 0) end
    return OA.Hallucination
end

test("the overlay's frame runs before the UI draws: the ringing steps, the glow holds still then falls on time", function()
    local H = load()
    local UI = OA.Trade.UI
    local start = now
    H.start(0, {})
    local ui = H.overlays[0]
    truthy(ui and ui.added, "the overlay is up")
    UI.liveFrame()
    eq(ui.liveLook, 0, "nothing lit at the start")
    now = start + 300
    UI.liveFrame()
    near(volumes[#volumes], H.RING_VOLUME * 300 / H.RING_MS[1], 1e-9, "the ringing rises with no frame drawn")
    truthy(ui.liveLook > 0, "the glow rises")
    -- the short run holds from 12% to 55% of its 5 s
    now = start + 1000
    UI.liveFrame()
    local held = ui.liveLook
    now = start + 2500
    UI.liveFrame()
    eq(ui.liveLook, held, "the glow holds: nothing to draw afresh")
    now = start + 2800
    UI.liveFrame()
    truthy(ui.liveLook < held, "the fall starts on time")
    eq(stopped, 0)
    now = start + H.RING_MS[1] + H.RING_MS[2] + H.RING_MS[3]
    UI.liveFrame()
    eq(stopped, 1, "the ringing stopped at its end")
    eq(ui.rects, 0, "all of it without a frame drawn")
    now = start + H.SHORT_MS * 1.5
    UI.liveFrame()
    eq(ui.removed, true, "the last run over: the overlay goes")
    eq(H.overlays[0], nil)
    eq(ui.liveLook, nil, "and is let go")
end)

test("the overlay's drawing only paints: it neither rings nor takes the overlay off", function()
    local H = load()
    local start = now
    H.start(0, { long = true, dx = 10, dy = 0 })
    local ui = H.overlays[0]
    local before = #volumes
    now = start + 3000
    ui:prerender()
    truthy(ui.rects > 0, "the glow is drawn")
    eq(#volumes, before, "no volume set while drawing")
    now = start + H.LONG_MS * 2
    ui:prerender()
    eq(ui.removed, nil, "not taken off from the drawing")
    eq(stopped, 0)
end)

test("the site's edge keeps the look moving after the faint light is gone", function()
    local H = load()
    local UI = OA.Trade.UI
    local start = now
    H.start(0, { long = false, dx = 10, dy = 0 })
    local ui = H.overlays[0]
    now = start + H.SHORT_MS + 100
    UI.liveFrame()
    local a = ui.liveLook
    now = start + H.SHORT_MS + 400
    UI.liveFrame()
    truthy(ui.liveLook < a and ui.liveLook > 0, "the site's light still falls")
    eq(ui.removed, nil)
end)
