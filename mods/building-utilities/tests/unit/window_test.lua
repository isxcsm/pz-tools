-- The breaker box window's refresh (client/BuildingUtilities/PanelWindow.lua, PanelJob via BU.Job): done a few
-- milliseconds a frame, never a frame long; what is shown changes between two frames, not along them; a burst of
-- changes is one refresh; the player's own doing in the window takes over one under way; what costs a look through the
-- inventory is looked up once in a while; the plan is laid out again only when what it shows changed. The window is
-- stood on a modest house (window_scene.lua), the game's UI stood in for.
local Scene = loadstring(readfile("tests/unit/window_scene.lua"), "window_scene.lua")()

-- Whether two plain tables hold the same by value (shared references and what lies too deep count as the same).
local function same(a, b, depth)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if (depth or 0) > 7 then return true end
    for key, value in pairs(a) do
        if not same(value, b[key], (depth or 0) + 1) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- What a window shows of its lists and its plan.
local function shown(window)
    local lists = {}
    for name, list in pairs(window.lists) do
        local rows = {}
        for _, item in ipairs(list.items) do rows[#rows + 1] = item.item end
        lists[name] = rows
    end
    local plan = {}
    for _, field in ipairs({ "data", "cells", "labels", "dots", "squares", "strip", "legend", "edges", "walls", "lines",
            "grid", "map", "scale", "levels", "floor", "floorOn", "floorLoad", "toggles", "topH", "floorTitle" }) do
        plan[field] = window.plan[field]
    end
    return { lists = lists, plan = plan, title = window.title, status = window.status, load = window.load,
        waterSupply = window.waterSupply }
end

-- The frames of a refresh: the window's updates until its job is done; how many it took.
local function frames(window)
    local count = 0
    repeat
        window:update()
        count = count + 1
    until window.job == nil and not window.changedAt or count > 400
    return count
end

local function switchOff(window)
    local key = window.views.power.devices[1].key
    window.panel.power.excluded[key] = true
    window:changed()
    return key
end

test("a refresh in slices ends as the one at once does, and the rows are the old ones until it ends", function()
    local window = Scene.open()
    BuildingUtilities.PanelWindow.SLICE_MS = 0
    local before = shown(window)
    local key = switchOff(window)
    local seen, steps = {}, 0
    repeat
        window:update()
        steps = steps + 1
        if window.job then seen[#seen + 1] = shown(window).lists.power end
    until (window.job == nil and not window.changedAt) or steps > 400
    truthy(steps > 20, "spread over many frames: " .. steps)
    truthy(#seen > 5, "a job under way for frames")
    local after = shown(window)
    local changes = 0
    for index, rows in ipairs(seen) do
        local old, new = same(rows, before.lists.power), same(rows, after.lists.power)
        truthy(old or new, "the list is the old rows or the new, never between")
        if index > 1 and not same(rows, seen[index - 1]) then changes = changes + 1 end
    end
    truthy(changes <= 1, "changing once")
    truthy(not same(after.lists.power, before.lists.power), "the change shows")
    local found
    for _, row in ipairs(after.lists.power) do
        if row.device and row.device.key == key then found = row end
    end
    eq(found.state, "off", "the device is off in its row")
    window:refresh()
    truthy(same(shown(window), after), "what a refresh all at once gives")
end)

test("a burst of changes is one refresh, not one for each", function()
    local window = Scene.open()
    BuildingUtilities.PanelWindow.SLICE_MS = 3
    local refreshes = 0
    local tasks = ISBUPanelWindow.refreshTasks
    ISBUPanelWindow.refreshTasks = function(self)
        refreshes = refreshes + 1
        return tasks(self)
    end
    for _ = 1, 12 do
        window:changed()
        window:update()
    end
    frames(window)
    eq(refreshes, 1, "one refresh for the burst")
    window:changed()
    frames(window)
    -- (the next may wait for GAP_MS from the first: it is made all the same)
    eq(refreshes, 2)
end)

test("the player's own doing takes over a refresh under way, which begins again after", function()
    local window = Scene.open()
    BuildingUtilities.PanelWindow.SLICE_MS = 0
    switchOff(window)
    local steps = 0
    repeat
        window:update()
        steps = steps + 1
    until window.job or steps > 400
    truthy(window.job, "a refresh under way")
    -- a room folded: its rows made on the spot
    local row
    for _, item in ipairs(window.lists.power.items) do
        if item.item.kind == "room" then row = item.item break end
    end
    window:refill("power")
    eq(window.job, nil, "dropped")
    truthy(window.changedAt, "to begin again")
    frames(window)
    eq(window.job, nil)
    local key = window.views.power.devices[1].key
    local off
    for _, item in ipairs(window.lists.power.items) do
        if item.item.device and item.item.device.key == key then off = item.item end
    end
    eq(off.state, "off", "what the dropped refresh would have shown shows after the one that follows")
end)

test("a refresh answering the player's own click goes ahead at once with more time a frame", function()
    local window = Scene.open()
    local urgent
    local start = ISBUPanelWindow.startRefresh
    ISBUPanelWindow.startRefresh = function(self, now)
        urgent = now
        return start(self, now)
    end
    window.refreshNow = true
    window:prerender()
    eq(urgent, true)
    truthy(window.job == nil or window.job.urgent, "an urgent job")
end)

test("what costs a look through the inventory is looked up once in a while, not at every refresh", function()
    local window = Scene.open()
    BuildingUtilities.PanelWindow.SLICE_MS = 3
    TEST.scans = 0
    window:refresh()
    truthy(TEST.scans > 0, "a refresh all at once looks")
    local scans = TEST.scans
    for _ = 1, 3 do
        window:changed()
        frames(window)
    end
    eq(TEST.scans, scans, "the refreshes between do not")
    TEST.now = TEST.now + BuildingUtilities.PanelWindow.COST_MS + 1
    window:changed()
    frames(window)
    truthy(TEST.scans > scans, "after COST_MS they do")
end)

test("the plan is laid out again only when what it shows changed, and the same either way", function()
    local window = Scene.open()
    BuildingUtilities.PanelWindow.SLICE_MS = 3
    local laid = 0
    local layoutTasks = ISBUPlan.layoutTasks
    ISBUPlan.layoutTasks = function(self)
        laid = laid + 1
        return layoutTasks(self)
    end
    window:changed()
    frames(window)
    eq(laid, 0, "nothing changed: not laid out again")
    switchOff(window)
    frames(window)
    truthy(laid > 0, "a device off: laid out")
    -- what a layout in slices gives is what one at once does, in every field of the plan, in each way it can be shown
    local SKIP = { window = true, parent = true, children = true, epoch = true, scheme = true, outlines = true,
        rangeCache = true, switchedAt = true }
    local function snapshot()
        local result = {}
        for field, value in pairs(window.plan) do
            if type(value) ~= "function" and not SKIP[field] then result[field] = value end
        end
        return result
    end
    local function compare(what)
        local sliced = snapshot()
        window.plan:layout()
        local direct = snapshot()
        for field, value in pairs(sliced) do
            truthy(same(value, direct[field]), what .. ": the plan's " .. field .. " is the same laid out at once")
        end
        for field in pairs(direct) do truthy(sliced[field] ~= nil, what .. ": the plan's " .. field .. " was laid out") end
    end
    compare("a device off")
    BuildingUtilities.PanelWindow.legendShown = true
    window:changed()
    window.plan:layout()
    window.plan.data.rangeKey = nil
    window.rangeShown = true
    window:changed()
    frames(window)
    compare("legend open, range shown")
    window.zoneEditing = true
    window:changed()
    frames(window)
    compare("zones edited")
    window.tabs.activeView = { view = window.lists.water }
    window:prerender()
    window:changed()
    frames(window)
    compare("the water tab")
end)

test("a layout dropped when the plan was laid out otherwise meanwhile, and the window asked to refresh again", function()
    local window = Scene.open()
    BuildingUtilities.PanelWindow.SLICE_MS = 0
    switchOff(window)
    local steps = 0
    repeat
        window:update()
        steps = steps + 1
    until (window.job and window.job.i > #window.job.tasks - 8) or steps > 400
    -- the floor chosen on the plan: laid out on the spot
    window.plan:layout()
    frames(window)
    eq(window.job, nil)
    local key = window.views.power.devices[1].key
    local data
    for _, device in ipairs(window.plan.data.devices) do
        if device.key == key then data = device end
    end
    eq(data.state, "off", "the plan shows the change after the refresh that follows")
end)

test("the log's and the batteries' rows are made as their tab opens, not at every refresh", function()
    local window = Scene.open()
    local batteries = window.lists.batteries
    truthy(batteries, "a tab for the rack")
    window:refresh()
    eq(window.stale.batteries, true, "left while another tab is open")
    local measured = 0
    local measure = BuildingUtilities.RackWindow.measure
    BuildingUtilities.RackWindow.measure = function(unit)
        measured = measured + 1
        return measure(unit)
    end
    window:refresh()
    eq(measured, 0, "not looked at")
    window.tabs.activeView = { view = batteries }
    window:prerender()
    truthy(measured > 0, "made as the tab opens")
    eq(window.stale.batteries, nil)
    truthy(#batteries.items >= 2, "rows")
end)

test("a job runs its tasks in slices; a task over a list goes on where it was; tasks insert and stop", function()
    local window = Scene.open()
    local Job = BuildingUtilities.Job
    local log = {}
    local list = { "a", "b", "c", "d" }
    local job = Job.new({
        function() log[#log + 1] = "first" end,
        Job.each(function() return list end, function(item) log[#log + 1] = item end),
        function(_, each)
            Job.insert(each, { function() log[#log + 1] = "inserted" end })
            log[#log + 1] = "third"
        end,
        function() log[#log + 1] = "last" end,
    })
    -- no time: one item a slice
    local slices = 0
    repeat
        slices = slices + 1
    until Job.run(job, getTimestampMs()) or slices > 20
    eq(table.concat(log, ","), "first,a,b,c,d,third,inserted,last")
    truthy(slices >= 6, "slices: " .. slices)
    local stopped = Job.new({ function(_, each) Job.stop(each) end, function() log[#log + 1] = "never" end })
    eq(Job.run(stopped, nil), true)
    eq(table.concat(log, ","), "first,a,b,c,d,third,inserted,last", "the rest dropped")
end)

test("the box's list of what it could take, in slices, is the one made at once", function()
    local window, panel = Scene.open()
    local Store = BuildingUtilities.Store
    for i = 1, 6 do Store.newUnit("solar", 300 + i, 301, 0, "solar") end
    Store.unitsChanged()
    local whole = BuildingUtilities.Panels.unwiredProducers(panel, "power")
    truthy(#whole >= 6, "free units listed: " .. #whole)
    local out = {}
    local job = BuildingUtilities.Job.new(BuildingUtilities.Panels.unwiredTasks(panel, "power", out))
    local slices = 0
    repeat
        slices = slices + 1
    until BuildingUtilities.Job.run(job, getTimestampMs()) or slices > 100
    truthy(slices > 5, "in slices: " .. slices)
    truthy(same(out.result, whole), "the same list")
end)

test("dragging the plan moves it over without laying it out again until the button is up; the wheel's steps of a frame are one layout", function()
    local window = Scene.open()
    frames(window)
    local plan = window.plan
    local laid = 0
    local layoutTasks = ISBUPlan.layoutTasks
    ISBUPlan.layoutTasks = function(self)
        laid = laid + 1
        return layoutTasks(self)
    end
    plan:layout()
    truthy(plan.map, "laid out")
    plan.zoom = 2
    plan:layout()
    local map = plan.map
    local ox, oy, grid = map.ox, map.oy, plan.grid
    -- pressed on the map and moved far enough
    plan.pressed, plan.moved = true, 0
    laid = 0
    for _ = 1, 20 do plan:drag(4, 3) end
    eq(laid, 0, "no layout along the drag")
    eq(plan.dragX, 80)
    eq(plan.dragY, 60)
    truthy(plan.grid ~= grid, "the grid made for the new place")
    -- the plan is panned all the same: what the layout at the release gives is what a layout at each move gave
    local panX, panY = plan.panX, plan.panY
    truthy(panX < 0 or panX > 0, "panned")
    plan.dragged = true
    plan:onMouseUp(0, 0)
    eq(laid, 1, "laid out once, at the release")
    eq(plan.dragX, 0)
    truthy(math.abs(plan.map.ox - (ox + 80)) < 1e-6 and math.abs(plan.map.oy - (oy + 60)) < 1e-6, "the layout is where the drag left it")
    -- the same, a layout at each move
    local direct = plan.grid
    plan.panX, plan.panY, plan.pressed, plan.moved = 0, 0, true, 0
    plan:layout()
    local from = plan.map.ox
    for _ = 1, 20 do
        plan.panX = plan.panX - 4 / plan.map.scale
        plan.panY = plan.panY - 3 / plan.map.scale
        plan:layout()
    end
    truthy(math.abs(plan.map.ox - (from + 80)) < 1e-6, "a layout at each move ends where the drag did")
    -- a point is hit where it is drawn while dragged
    plan.zoom, plan.panX, plan.panY = 1, 0, 0
    plan:layout()
    local dot = plan.dots[1] or plan.squares[1]
    truthy(dot, "something on the plan")
    if dot then
        local x, y = dot.x + (dot.size and dot.size / 2 or 0), dot.y + (dot.size and dot.size / 2 or 0)
        local kind = plan:hit(x, y)
        truthy(kind == "dot" or kind == "square", "found where it was laid")
        plan.dragX, plan.dragY = 30, 20
        truthy(plan:hit(x + 30, y + 20) == kind, "and where it is drawn, dragged")
        plan.dragX, plan.dragY = 0, 0
    end
    -- the wheel: three steps in a frame, one layout, the same zoom and pan as a layout at each step
    plan.zoom, plan.panX, plan.panY = 1, 0, 0
    plan:layout()
    local steps = {}
    local midX, midY = plan.map.left + plan.map.w / 3, plan.map.top + plan.map.h / 3
    for _, factor in ipairs({ 1.25, 1.25, 0.8 }) do
        plan:zoomAt(midX, midY, factor)
        plan:layout()
    end
    local zoom, panX2, panY2, scale = plan.zoom, plan.panX, plan.panY, plan.map.scale
    plan.zoom, plan.panX, plan.panY = 1, 0, 0
    plan:layout()
    laid = 0
    for _, factor in ipairs({ 1.25, 1.25, 0.8 }) do plan:zoomAt(midX, midY, factor) end
    eq(laid, 0, "not laid out along the steps")
    eq(plan.relayout, true)
    local m = plan.map
    truthy(math.abs(m.ox - (m.left + m.w / 2 - (m.centreX - m.minX) * m.scale)) < 1e-9
        and math.abs(m.oy - (m.top + m.h / 2 - (m.centreY - m.minY) * m.scale)) < 1e-9,
        "the origin followed the scale and the centre in the step: hit tests and the focus ring read it before the layout")
    plan:prerender()
    eq(laid, 1, "once for the frame")
    eq(plan.relayout, false)
    local near = function(a, b) return math.abs(a - b) < 1e-9 end
    truthy(near(plan.zoom, zoom) and near(plan.panX, panX2) and near(plan.panY, panY2), "the same zoom and pan")
    truthy(near(plan.map.scale, scale), "the same scale")
    ISBUPlan.layoutTasks = layoutTasks
end)
