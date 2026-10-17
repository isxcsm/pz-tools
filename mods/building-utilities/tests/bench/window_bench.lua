-- A box's window (client/BuildingUtilities/PanelWindow.lua with the plan, the lists and the status line) on a modest
-- house: five rooms, thirteen devices on the power tab and the water tab, a few units (tests/unit/window_scene.lua).
-- Times what a refresh of the window costs the frame it is in: all at once (a window just opened, one opened anew),
-- and as the window does it between frames (a periodic refresh, a burst of changes), the work cut to slices of at
-- most SLICE_MS, the longest frame being what a player feels. The tasks a refresh is made of are timed on their own
-- too. The Java side (the game's squares, texts, text widths, the inventory) is not in these numbers (the game's is
-- several times slower than this VM's, where the time is mostly the Lua code's): its calls are counted.
--   java -cp projectzomboid.jar ../tools/LuaTest.java window bench     (the times)
--   java -cp projectzomboid.jar ../tools/LuaTest.java window profile   (and where the time goes, by function)
-- Prints "[bench] window ..." lines.
local Scene = loadstring(readfile("tests/unit/window_scene.lua"), "window_scene.lua")()
local BU

local function opened()
    local window, panel = Scene.open()
    BU = BuildingUtilities
    return window, panel
end

local function ms(fn)
    local started = nanotime()
    fn()
    return nanotime() - started
end

local function report(what, value) print(string.format("[bench] window %-60s %s", what, value)) end

local function stats(times)
    local total, longest = 0, 0
    for _, t in ipairs(times) do total, longest = total + t, math.max(longest, t) end
    return total / #times, longest
end

-- A frame: the window's update, 16 ms of the game's clock after the last (the work in it counts as it is).
local function framer(window)
    local offset = 0
    getTimestampMs = function() return offset + nanotime() end
    return function()
        offset = offset + 16
        return ms(function() window:update() end)
    end
end

-- The cost of the refresh done all at once, and of its parts.
test("a box's window on a modest house: the refresh all at once", function()
    local window, panel = opened()
    getTimestampMs = function() return nanotime() end
    -- warmed up first (the code the VM has compiled by then)
    for _ = 1, 150 do window:refresh() end
    local times = {}
    for _ = 1, 100 do times[#times + 1] = ms(function() window:refresh() end) end
    local avg, longest = stats(times)
    report("refresh, all at once (avg / longest of 100)", string.format("%.2f / %.2f ms", avg, longest))
    local parts = { { "fill power", function() window:fill("power", window.states.power) end },
        { "fill water", function() window:fill("water", window.states.water) end },
        { "updatePlan", function() window:updatePlan() end },
        { "plan:layout", function() window.plan:layout() end },
        { "updateStatus", function() window:updateStatus() end },
        { "measureLoad", function() window:measureLoad(panel, window.states.power) end },
        { "Panels.devices power", function() BU.Panels.devices(panel, "power") end },
        { "Panels.devices water", function() BU.Panels.devices(panel, "water") end },
        { "Panels.unwiredProducers", function() BU.Panels.unwiredProducers(panel, "power") end } }
    for _, part in ipairs(parts) do
        for _ = 1, 3 do part[2]() end
        local each = {}
        for _ = 1, 100 do each[#each + 1] = ms(part[2]) end
        report("  " .. part[1], string.format("%.2f ms", (stats(each))))
    end
    TEST.javaCalls.getText, TEST.javaCalls.measure, TEST.scans = 0, 0, 0
    TEST.api.calls = {}
    window:refresh()
    report("  Java side per refresh: getText / text widths / inventory scans",
        TEST.javaCalls.getText .. " / " .. TEST.javaCalls.measure .. " / " .. TEST.scans)
    local calls = {}
    for name, n in pairs(TEST.api.calls) do calls[#calls + 1] = name .. " " .. n end
    table.sort(calls)
    report("  API calls per refresh", table.concat(calls, ", "))
end)

-- A refresh as the window does it between frames: a change told, the frames after it until the refresh is done. The
-- longest frame, the frames and the time they took in all, over N changes.
local function sliced(window, budget, changes)
    local frame = framer(window)
    BU.PanelWindow.SLICE_MS = budget
    for _ = 1, 40 do window:changed(); for _ = 1, 40 do frame() end end
    local longest, frames, total = 0, 0, 0
    TEST.scans = 0
    for _ = 1, changes do
        window:changed()
        local mine, started = {}, false
        for _ = 1, 120 do
            local was, stamp = window.job ~= nil, window.refreshedAt
            local took = frame()
            if was or window.job ~= nil or window.refreshedAt ~= stamp then
                started = true
                mine[#mine + 1] = took
            elseif started then break end
        end
        local sum, top = 0, 0
        for _, t in ipairs(mine) do sum, top = sum + t, math.max(top, t) end
        frames, total, longest = frames + #mine, total + sum, math.max(longest, top)
    end
    return longest, frames / changes, total / changes, TEST.scans / changes
end

for _, budget in ipairs({ 3, 0.6, 0 }) do
    test("a box's window on a modest house: a change refreshed in slices of " .. budget .. " ms", function()
        local window = opened()
        for _ = 1, 100 do window:refresh() end
        local longest, frames, total, scans = sliced(window, budget, 40)
        report(string.format("change -> refresh in slices of %s ms: longest frame / frames / time / scans", budget),
            string.format("%.2f ms / %.1f / %.2f ms / %.1f", longest, frames, total, scans))
        eq(window.job, nil)
    end)
end

-- The tasks of a refresh, each named by where it comes from and its place in its list: what one costs a refresh in
-- all (the average), and the longest single call of it (an item of a task over a list is a call).
test("a box's window on a modest house: the tasks of a refresh", function()
    local window = opened()
    getTimestampMs = function() return nanotime() end
    local record = {}
    local function label(name)
        local original = ISBUPanelWindow[name]
        ISBUPanelWindow[name] = function(self, ...)
            local tasks = original(self, ...)
            local utility = ...
            for i, task in ipairs(tasks) do
                local key = string.format("%s %s#%02d", (name:gsub("Tasks", "")), type(utility) == "string" and utility or "", i)
                tasks[i] = function(deadline, job)
                    local started = nanotime()
                    local done = task(deadline, job)
                    local took = nanotime() - started
                    local entry = record[key] or { sum = 0, most = 0 }
                    record[key] = entry
                    entry.sum, entry.most = entry.sum + took, math.max(entry.most, took)
                    return done
                end
            end
            return tasks
        end
    end
    label("refreshTasks")
    label("fillTasks")
    label("planTasks")
    for _ = 1, 150 do window:refresh() end
    record = {}
    local runs = 200
    for _ = 1, runs do window:refresh() end
    local list = {}
    for key, entry in pairs(record) do list[#list + 1] = { key = key, avg = entry.sum / runs, most = entry.most } end
    table.sort(list, function(a, b) return a.avg > b.avg end)
    local total = 0
    for _, e in ipairs(list) do total = total + e.avg end
    report("tasks of a refresh, in all", string.format("%.2f ms", total))
    for i = 1, math.min(12, #list) do
        report("  " .. list[i].key, string.format("avg %.3f ms, longest call %.3f ms", list[i].avg, list[i].most))
    end
end)

-- Where a refresh goes: every function of the mod's modules and of the window's classes wrapped to add up its time
-- (with what it calls) and its calls, and its own time without them; the most costly printed.
local function profiled(run)
    local spent, own, calls, wrapped = {}, {}, {}, {}
    local under = { 0 }
    local function wrap(label, module)
        for name, fn in pairs(module) do
            if type(fn) == "function" and type(name) == "string" then
                local full = label .. "." .. name
                wrapped[#wrapped + 1] = { module, name, fn }
                module[name] = function(...)
                    calls[full] = (calls[full] or 0) + 1
                    under[#under + 1] = 0
                    local started = nanotime()
                    local a, b, c, d, e = fn(...)
                    local took = nanotime() - started
                    local inner = table.remove(under)
                    under[#under] = under[#under] + took
                    spent[full] = (spent[full] or 0) + took
                    own[full] = (own[full] or 0) + took - inner
                    return a, b, c, d, e
                end
            end
        end
    end
    for name, module in pairs(BU) do
        if type(module) == "table" then wrap(name, module) end
    end
    for _, name in ipairs({ "ISBUPanelWindow", "ISBUPlan", "ISBUPanelList" }) do wrap(name, _G[name]) end
    wrap("UI", PZUIKit.UI)
    local started = nanotime()
    run()
    local total = nanotime() - started
    for _, entry in ipairs(wrapped) do entry[1][entry[2]] = entry[3] end
    local function top(by, title)
        local list = {}
        for label, t in pairs(by) do list[#list + 1] = { label, t } end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        print("[bench]   " .. title)
        for i = 1, math.min(22, #list) do
            print(string.format("[bench]   %-40s %9.2f ms %8d calls", list[i][1], list[i][2], calls[list[i][1]]))
        end
    end
    print(string.format("[bench]   all %.1f ms", total))
    top(spent, "with what they call")
    top(own, "their own")
end

if TEST_SUITE == "profile" then
    test("where 20 refreshes of a box's window go", function()
        local window = opened()
        getTimestampMs = function() return nanotime() end
        for _ = 1, 100 do window:refresh() end
        profiled(function() for _ = 1, 20 do window:refresh() end end)
    end)
end

-- Units set down and not yet wired (the burst of a base being built): the list of what the box could take, all at once
-- and the longest step of it in slices.
test("a box's window on a modest house: many units not yet wired", function()
    local window, panel = opened()
    getTimestampMs = function() return nanotime() end
    local Store = BU.Store
    for i = 1, 100 do Store.newUnit("solar", 300 + BU.remainder(i, 10), 300 + math.floor(i / 10), 0, "solar") end
    Store.unitsChanged()
    for _ = 1, 3 do BU.Panels.unwiredProducers(panel, "power") end
    local whole = {}
    for _ = 1, 20 do whole[#whole + 1] = ms(function() BU.Panels.unwiredProducers(panel, "power") end) end
    local out = {}
    local job = BU.Job.new(BU.Panels.unwiredTasks(panel, "power", out))
    local most, steps = 0, 0
    repeat
        local took = ms(function() BU.Job.run(job, 0) end)
        most, steps = math.max(most, took), steps + 1
    until job.i > #job.tasks
    report("100 free units: list all at once / longest step of the sliced / steps", string.format("%.2f ms / %.3f ms / %d",
        (stats(whole)), most, steps))
    eq(#out.result, #BU.Panels.unwiredProducers(panel, "power"))
end)
