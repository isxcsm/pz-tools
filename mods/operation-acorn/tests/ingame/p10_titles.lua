-- P10 titles: one title of each style through OA.Titles.show (Titles.now false), timed with the real clock, to compare with
-- the title lab's timings (the player finds the game faster than the lab).
-- What the API shows of a title's life is only PZExtAPI.text.shown(handle, key): whether it is still on the screen or in the
-- queue. So the moments of the title's own clock (enter start, land, leave start) are not observable from Lua; what is
-- logged is the real time (getTimestampMs) at which the title was shown, the real time at which the API reports it gone,
-- the frames drawn between and the longest one, and, beside them, the schedule the API's design table gives (PZ Extension
-- API docs/design.md, titles: the enter time, 5 s held, the leave time) so that the measured total can be set against it.
-- A frame longer than 0.1 s counts for 0.1 s of a title's clock, so a slow game shows as a longer total, never a shorter one.
--   1. each style shown alone (one after the other, each once the one before has gone): total real time against the
--      design's sum for the styles whose table row gives all three times, and no frame over 100 ms while it ran;
--   2. a title cut short by one shown with now (Titles.now = true): the one on the screen is gone within 0.7 s of it;
--   3. a pause: the game paused for 4 s in the middle of a stamp; the title's total, less the pause, is what it was without.
-- The title sounds (enter, land, hold, leave, the fade at the cut, silence in the pause) are heard, not measured here:
-- listen to them in these runs (the sounds play as the titles show).
-- Setup: nothing on the screen; about 3 minutes (the styles last 8 to 16 s each, ten of them, and the two tests).
-- Prints "[p10titles]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

-- The design table's times in seconds: enter (land), held, leave. A style whose row does not give all three has no total.
-- (The "dust" title style is the API's still and leaves by "burn" over 10 s: the paper burn, "dust-paper" in the title lab.
-- Only the leave named "dust" (the crumbling) is gone from the API and the lab; this file asks for no leave of its own.)
local DESIGN = {
    stamp = { 0.6, 5, 6 }, discovery = { 2.2, 5, 4.5 }, notice = { 0.7, 5, 4.5 }, unveil = { 3.6, 5, 5 },
    dust = { 1.2, 5, 10 }, bleed = { 1.9, 5, 6 }, sink = { 1.6, 5, 9 }, ["type"] = { 1.3, 5, 5.5 },
    pulse = { 0.9 }, brief = { 0.45, 4, 3.5 },
}
local ORDER = { "stamp", "discovery", "notice", "unveil", "dust", "bleed", "sink", "type", "pulse", "brief" }

P10T.start("p10titles", function(a)
    local Titles = OA.Titles
    if not a.check("the API draws titles (text applied)", Titles.textApi() ~= nil) then return end
    if not a.check("the title call is watched", P10T.tap() and P10T.tapped ~= nil) then return end
    local player = getPlayer()
    local id = OA.Store.idOf(player)
    local wasNow = Titles.now
    Titles.now = false
    local speedControls = UIManager.getSpeedControls()
    local wasSpeed = speedControls:getCurrentGameSpeed()
    local watching = {}
    a.cleanup(function()
        Titles.now = wasNow
        speedControls:SetCurrentGameSpeed(wasSpeed)
        P10T.onFrame = nil
    end)

    -- every frame: the frames of each title being watched, the longest, and when the API stops reporting it
    P10T.onFrame = function()
        local now = getTimestampMs()
        for _, w in ipairs(watching) do
            if not w.gone then
                local dt = now - w.last
                w.last = now
                w.frames = w.frames + 1
                if dt > w.max then w.max = dt end
                if not P10T.shown(w.key) then w.gone = now end
            end
        end
    end

    local function showTitle(style)
        local before = #P10T.titleKeys
        local t0 = getTimestampMs()
        local how = Titles.show(id, { key = "IGUI_OA_Title_Sealed", sub = "IGUI_OA_Title_Marked", style = style })
        local entry = P10T.titleKeys[before + 1]
        a.check(style .. " is shown through OA.Titles.show", how == "title" and entry ~= nil and entry.key ~= nil,
            tostring(how) .. " keys " .. (#P10T.titleKeys - before))
        local w = { style = style, key = entry and entry.key, t0 = t0, frames = 0, max = 0, last = t0 }
        if not w.key then w.gone = t0 end
        watching[#watching + 1] = w
        return w
    end

    local measured = {}
    local steps = {}
    steps[#steps + 1] = { after = 200, name = "wait for the queue", within = 120000,
        ready = function() return P10T.titlesPending() == 0 end,
        run = function(_, timedOut)
            a.check("the titles shown before this have gone", not timedOut, P10T.titlesPending())
            a.say("starting at real time", getTimestampMs(), "ms; styles", #ORDER)
        end }

    -- 1. each style
    for _, style in ipairs(ORDER) do
        local w
        steps[#steps + 1] = { after = 600, name = "show " .. style, run = function() w = showTitle(style) end }
        steps[#steps + 1] = { after = 100, name = "gone " .. style, within = 45000,
            ready = function() return w == nil or w.gone ~= nil end,
            run = function(_, timedOut)
                if not w then return end
                local total = ((w.gone or getTimestampMs()) - w.t0) / 1000
                measured[style] = total
                local d = DESIGN[style]
                local sum = d and d[2] and d[3] and (d[1] + d[2] + d[3]) or nil
                a.say(style, "shown at", w.t0, "ms, gone at", w.gone or "never", "ms; total", string.format("%.2f", total), "s;",
                    w.frames, "frames, average", string.format("%.1f", total * 1000 / math.max(1, w.frames)), "ms, longest", w.max, "ms")
                if d then
                    a.say(style, "design schedule: enter", d[1], "s", d[2] and ("held " .. d[2] .. " s, leave " .. tostring(d[3]) .. " s") or "(rest not in the table)",
                        sum and ("-> land at +" .. d[1] .. " s, leave starts at +" .. (d[1] + d[2]) .. " s, gone at +" .. sum .. " s") or "")
                end
                a.check(style .. " goes within its time", not timedOut and w.gone ~= nil, timedOut and "never gone" or "")
                if sum then
                    a.check(style .. " total " .. string.format("%.1f", total) .. " s against the design's " .. sum .. " s (-8% to +3 s)",
                        total >= sum * 0.92 and total <= sum + 3, string.format("%.2f vs %.2f", total, sum))
                end
                a.check(style .. " no frame over 100 ms while it ran", w.max <= 100, w.max)
            end }
    end

    -- 2. a title cut short by one with now
    local first, second
    steps[#steps + 1] = { after = 1000, name = "cut: show", run = function() first = showTitle("stamp") end }
    steps[#steps + 1] = { after = 3000, name = "cut: now", run = function()
        Titles.now = true
        second = showTitle("notice")
        Titles.now = false
    end }
    steps[#steps + 1] = { after = 100, name = "cut: gone", within = 10000,
        ready = function() return first == nil or first.gone ~= nil end,
        run = function(_, timedOut)
            local ms = first.gone and second and (first.gone - second.t0) or nil
            a.check("the title on the screen is gone within 0.7 s of one shown with now", not timedOut and ms ~= nil and ms <= 700,
                ms and (ms .. " ms") or "never")
        end }
    steps[#steps + 1] = { after = 100, name = "cut: the second goes on", within = 30000,
        ready = function() return second == nil or second.gone ~= nil end,
        run = function(_, timedOut)
            a.check("the title that cut it in goes its own time", not timedOut, second and string.format("%.1f s", ((second.gone or 0) - second.t0) / 1000) or "")
        end }

    -- 3. a pause in the middle of a stamp
    local paused, pauseFrom, pauseTo
    steps[#steps + 1] = { after = 1500, name = "pause: show", run = function() paused = showTitle("stamp") end }
    steps[#steps + 1] = { after = 2000, name = "pause: stop", run = function()
        speedControls:SetCurrentGameSpeed(0)
        pauseFrom = getTimestampMs()
        a.say("the game is paused for 4 s at real time", pauseFrom)
    end }
    steps[#steps + 1] = { after = 4000, name = "pause: go on", run = function()
        a.check("the title is still there after the pause", paused.gone == nil, paused.gone and "gone during the pause" or "")
        speedControls:SetCurrentGameSpeed(wasSpeed)
        pauseTo = getTimestampMs()
    end }
    steps[#steps + 1] = { after = 100, name = "pause: gone", within = 45000,
        ready = function() return paused.gone ~= nil end,
        run = function(_, timedOut)
            local total = ((paused.gone or getTimestampMs()) - paused.t0) / 1000
            local held = (pauseTo - pauseFrom) / 1000
            local effective = total - held
            local plain = measured.stamp
            a.say("stamp with a pause: total", string.format("%.2f", total), "s, paused", string.format("%.2f", held), "s, less the pause",
                string.format("%.2f", effective), "s; without a pause", plain and string.format("%.2f", plain) or "not measured")
            a.check("the title's clock stood still in the pause (within 1.2 s of the unpaused total)", not timedOut and plain ~= nil
                and math.abs(effective - plain) <= 1.2, string.format("%.2f vs %.2f", effective, plain or 0))
        end }
    steps[#steps + 1] = { after = 200, name = "end", run = function()
        a.say("not measured here: the sounds at enter, land, hold and leave, the hold's fade to 0, the 0.15 s fade at a cut, the")
        a.say("silence in the pause, and the level against the game's UI clicks: listen in the runs above and in a pause")
    end }
    P10T.run(a, steps)
end)
