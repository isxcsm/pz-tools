-- Building Utilities Dev: timing what throwing a box's lever sets off, to find a hitch. The steps the mod runs are
-- wrapped and each that takes PERF_MS or more is printed ("[BU perf] step ms"); for WATCH_MS after the lever is thrown
-- every frame longer than FRAME_MS is printed too, so that time spent outside the mod's Lua (the API, the game's
-- lights and generators) shows as frames longer than the steps inside them. Debug mode only.
if not isDebugEnabled() then return end
local BU = BuildingUtilities
local Perf = {}
BU.DevPerf = Perf

Perf.PERF_MS, Perf.FRAME_MS, Perf.WATCH_MS = 2, 25, 4000
local watchUntil, lastTick = 0, nil

local function say(...) print("[BU perf] " .. table.concat({ ... }, " ")) end

-- Wraps a function of a table: each call taking PERF_MS or more is printed with its name.
local function wrap(owner, key, name)
    local fn = owner and owner[key]
    if type(fn) ~= "function" then return end
    owner[key] = function(...)
        local start = getTimestampMs()
        local a, b, c, d = fn(...)
        local took = getTimestampMs() - start
        if took >= Perf.PERF_MS then say(name, took .. "ms") end
        return a, b, c, d
    end
end

local function onTick()
    local now = getTimestampMs()
    if lastTick and now < watchUntil and now - lastTick >= Perf.FRAME_MS then say("frame", (now - lastTick) .. "ms") end
    lastTick = now
end

local function install()
    local Changes = BU.Changes
    local setLever = Changes.setLever
    Changes.setLever = function(panel, up)
        watchUntil = getTimestampMs() + Perf.WATCH_MS
        say("lever", up and "up" or "down", panel.id)
        local start = getTimestampMs()
        setLever(panel, up)
        say("setLever", (getTimestampMs() - start) .. "ms")
    end
    wrap(BU.Networks, "applyEnabled", "Networks.applyEnabled")
    wrap(BU.Networks, "setSource", "Networks.setSource")
    wrap(BU, "onChanged", "onChanged")
    wrap(BU, "onNotice", "onNotice")
    wrap(BU.PanelLook, "show", "PanelLook.show")
    wrap(BU.Overload, "check", "Overload.check")
    wrap(BU.RackWindow, "refreshAll", "RackWindow.refreshAll")
    wrap(ISBUPanelWindow, "refresh", "window.refresh")
    -- a refresh between frames is slices (BU.Job): this is what one frame of it takes
    wrap(ISBUPanelWindow, "stepJob", "window.slice")
    wrap(ISBUPanelWindow, "updatePlan", "window.updatePlan")
    wrap(ISBUPanelWindow, "fill", "window.fill")
    wrap(ISBUPanelWindow, "updateStatus", "window.updateStatus")
    wrap(ISBUPanelWindow, "checkRange", "window.checkRange")
    wrap(ISBUPlan, "layout", "plan.layout")
    Events.OnTick.Add(onTick)
    say("installed")
end

Events.OnGameStart.Add(install)

return Perf
