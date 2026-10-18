-- The developer sub-mod's E2E director (E2E-DEBUG.md): each beat puts the record where the play stands just before its
-- scene (the calls before it played, the level, the mission offered), quietly and the same however often it is set;
-- the timers are set to fire at the next looks, on the game's own paths.
isDebugEnabled = function() return true end
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/CommsScript"
require "OperationAcorn/Trade/Trade"
local OA = OperationAcorn
local Comms, Story, Missions = OA.Comms, OA.Story, OA.Missions

local given
local player = { mod = { OA_Id = "p1" } }
function player:getModData() return self.mod end
function player:getInventory()
    return { AddItem = function(_, full) given[#given + 1] = full; return true end }
end

PZExtDev = { section = function() end }
do
    local real = require
    require = function(file)
        if file == "PZExtDev/Panel" then return true end
        return real(file)
    end
    require "OperationAcorn/Dev/Dev"
    require "OperationAcorn/Dev/Features"
    require "OperationAcorn/Dev/E2E"
    require = real
end
local Dev = OA.Dev
local E2E = Dev.E2E

-- The record of a character that played on its own a while (a mission running, calls in the log), and the titles and
-- notices shown from now on.
local titles
local function setup()
    getPlayer = function() return player end
    given = {}
    local r = OA.Store.ensure("p1", "P")
    r.trade = { stage = 2, milestones = 0, credits = 500, trust = 0 }
    Story.setAnchor(r, 0, 0, 0)
    Missions.game = { release = function() end }
    Comms.played(r, "S0", 1)
    Comms.played(r, "S1", 1)
    Missions.state(r).active = { id = "old", state = "open", deadline = 50, issued = 0 }
    titles = {}
    OA.Sync.title = function(_, t) titles[#titles + 1] = t.key end
    OA.Sync.notice = function(_, key) titles[#titles + 1] = key end
    return r
end

local function logIds(r)
    local ids = {}
    for _, entry in ipairs(Comms.section(r).log) do ids[#ids + 1] = entry.id end
    return table.concat(ids, " ")
end

local BRIEFED = { B1 = "evidence", B4 = "cooler", BS1 = "soil" }

test("every story beat: the calls before its first played, its own not, the level and what is offered", function()
    for _, beat in ipairs(E2E.BEATS) do
        if beat.from then
            local r = setup()
            E2E.set(beat.id, { place = false })
            local s = Comms.section(r)
            local upTo
            for i, id in ipairs(E2E.ORDER) do
                if id == beat.from then upTo = i end
            end
            truthy(upTo, beat.id .. ": its call is in the order")
            for i = 1, upTo - 1 do
                truthy(Comms.done(r, E2E.ORDER[i]), beat.id .. ": " .. E2E.ORDER[i] .. " behind")
            end
            eq(Comms.done(r, beat.from), false, beat.id .. ": " .. beat.from .. " to come")
            eq(r.trade.stage, beat.stage, beat.id .. " stage")
            eq(r.trade.milestones, beat.milestones or 0, beat.id .. " milestones")
            eq(Story.section(r).seenStage, beat.stage, beat.id .. " entered")
            local e = OA.CommsData.BY_ID[beat.from]
            if string.match(e.trigger, "^tier:") then
                local ready = Comms.next(r, "terminal")
                eq(ready and ready.id, beat.from, beat.id .. ": the terminal plays it next")
            else
                eq(Comms.next(r, "terminal"), nil, beat.id .. ": nothing else waits at the terminal")
            end
            local m = Missions.active(r)
            if beat.offer then
                truthy(m and m.state == "waiting", beat.id .. ": a mission offered")
                if BRIEFED[beat.from] then eq(m.story, BRIEFED[beat.from], beat.id .. ": its story") end
            else
                eq(m, nil, beat.id .. ": nothing offered")
                truthy(Missions.state(r).nextAt > OA.hours() + 24 * 300, beat.id .. ": no regular mission comes")
            end
            eq(#titles, 0, beat.id .. ": no title: " .. table.concat(titles, " "))
            eq(r.first.done, true, beat.id .. ": registered")
            eq(OA.Trade.registered(r), true)
        end
    end
end)

test("the story missions before a beat are done, a choice's option kept, their field lines said", function()
    local r = setup()
    E2E.set("09", { place = false })
    local s = Story.section(r)
    eq(s.done.evidence, "done")
    eq(s.done.clinic, "done")
    eq(s.done.observation, "done")
    eq(s.chosen.observation, "a")
    eq(s.done.cooler, "done")
    eq(s.done.gym, nil, "its own to come")
    truthy(Comms.done(r, "S2F_put"))
    truthy(Comms.done(r, "P3a_enter"))
    eq(Comms.done(r, "P3b_enter"), false, "the other option's not")
    truthy(Comms.section(r).dropped.B3b, "the other briefing dropped")
    eq(Comms.done(r, "P5_enter"), false)
    -- the papers of the levels before are read, none waits for a crate again
    truthy(s.sent.reply_first)
    truthy(s.docs.reply_first)
    eq(s.docStage.reply_first, 2)
end)

test("setting a beat again, or an earlier one after a later, gives the same record", function()
    local r = setup()
    E2E.set("06", { place = false })
    local first = logIds(r)
    local story = Missions.active(r).story
    E2E.set("06", { place = false })
    eq(logIds(r), first)
    eq(Missions.active(r).story, story)
    E2E.set("13", { place = false })
    E2E.set("06", { place = false })
    eq(logIds(r), first)
    eq(Story.section(r).handover, false)
    eq(r.trade.stage, 3)
end)

test("the first supply beats: a record the terminal does not know, its first supply far off", function()
    local r = setup()
    E2E.set("01", { place = false })
    eq(OA.Trade.registered(r), false)
    eq(r.first.done, false)
    eq(r.first.mode, "window")
    eq(Missions.active(r), nil)
    eq(logIds(r), "")
    E2E.set("01L", { place = false })
    eq(r.first.mode, "late")
    E2E.set("01N", { place = false })
    eq(r.first.mode, "none", "a world without the game's helicopter")
    eq(#titles, 0)
end)

test("the first beat: the game's helicopter comes first, the supply as it goes; another beat calls it off", function()
    setup()
    local ms, ticks, flown, ended, dropped = 0, {}, 0, 0, 0
    getTimestampMs = function() return ms end
    Events.OnTick = { Add = function(fn) ticks[fn] = true end, Remove = function(fn) ticks[fn] = nil end }
    testHelicopter = function() flown = flown + 1 end
    endHelicopter = function() ended = ended + 1 end
    local realSupply = E2E.firstSupply
    E2E.firstSupply = function() dropped = dropped + 1 end
    local function tick() for fn in pairs(ticks) do fn() end end
    E2E.heliThenSupply()
    eq(flown, 1)
    ms = (E2E.HELI_SECONDS - 1) * 1000
    tick()
    eq(dropped, 0, "not while it flies")
    ms = E2E.HELI_SECONDS * 1000
    tick()
    eq(ended, 1)
    eq(dropped, 1, "the supply as it goes")
    tick()
    eq(dropped, 1, "once")
    E2E.heliThenSupply()
    E2E.set("01L", { place = false })
    eq(ended, 2, "another beat sends it away")
    ms = ms + E2E.HELI_SECONDS * 1000
    tick()
    eq(dropped, 1, "and no supply comes of it")
    E2E.firstSupply = realSupply
end)

test("the join beats: the world's tier as the record came in, after the handover with 관리 7", function()
    local r = setup()
    E2E.set("J4", { place = false })
    eq(Story.joinedTier(r), 4)
    eq(Story.joinedAfterHandover(r), false)
    truthy(Comms.done(r, "S4"))
    eq(Comms.done(r, "S0"), false)
    eq(OA.Trade.registered(r), false)
    E2E.set("J7", { place = false })
    eq(Story.joinedTier(r), 7)
    truthy(Comms.done(r, "S7"))
    E2E.set("JH", { place = false })
    eq(Story.joinedAfterHandover(r), true)
    eq(Comms.section(r).era, "admin")
    truthy(Comms.done(r, "S0"), "the team's calls are dropped")
    eq(Comms.done(r, "K0"), false)
    -- and back to a world of its own
    E2E.set("03", { place = false })
    eq(Story.joinedTier(r), 0)
    eq(Comms.section(r).era, nil)
end)

test("the handover beat: the handover over, its papers read, 관리 7's first call next", function()
    local r = setup()
    E2E.set("13", { place = false })
    local s = Story.section(r)
    eq(s.handover, true)
    eq(s.docStage.status_table, OA.StoryData.TRANSFER_TIER)
    eq(Comms.next(r, "terminal").id, "K1")
end)

test("the serum beat gives a serum; the X beat sets nothing", function()
    local r = setup()
    E2E.set("04", { place = false })
    eq(given[1], "OperationAcorn.UpgradeSerumShared")
    local log = logIds(r)
    E2E.set("X", { place = false })
    eq(logIds(r), log)
    eq(E2E.current, "X")
end)

test("next: the beat after the one set last", function()
    setup()
    E2E.current = "02"
    -- (E2E.next places the character; this test's record has no terminal, so the move is said and skipped)
    local beat = E2E.next()
    eq(beat.id, "03")
end)

test("the deadline timers: set to fire at the next looks, the day-left warning on the game's path", function()
    local r = setup()
    TEST.hours = 100
    local m = { id = "m1", state = "open", issued = 100, deadline = 172 }
    Missions.state(r).active = m
    local ids = {}
    for _, t in ipairs(E2E.timers(r)) do ids[#ids + 1] = t.id end
    eq(table.concat(ids, " "), "mainDeadline dayLeft")
    E2E.timerSoon("dayLeft")
    TEST.hours = 100 + E2E.LEAD + 0.01
    Missions.warnDeadline(r, m, OA.hours())
    eq(titles[#titles], "IGUI_OA_Title_DayLeft")
    E2E.timerSoon("mainDeadline")
    eq(m.deadline, TEST.hours + E2E.LEAD)
end)

test("the timed calls: S2B half a day after S2, S4B the next day, both fire at the next looks", function()
    local r = setup()
    TEST.hours = 30
    Comms.played(r, "S2", 2)
    local t = E2E.timers(r)
    local found
    for _, x in ipairs(t) do if x.id == "call_S2B" then found = x end end
    truthy(found)
    eq(found.left, 12)
    E2E.timerSoon("call_S2B")
    TEST.hours = 30 + E2E.LEAD
    eq(table.concat(Comms.update(r), " "), "S2B")
    Comms.played(r, "S2B", 2)
    Comms.played(r, "S4", 4)
    E2E.timerSoon("call_S4B")
    TEST.hours = TEST.hours + 0.1
    eq(table.concat(Comms.update(r), " "), "S4B")
end)

test("the helicopter, the sealed box and the waits: set to fire at the next looks", function()
    local r = setup()
    TEST.hours = 200
    local heli = OA.Trade.heli(r)
    heli.call = { arrive = 230 }
    heli.next = 260
    local m = { id = "m2", state = "sealed", sealedAt = 190, swap = { stage = "waiting", waited = 0.5 } }
    Missions.state(r).active = m
    for _, id in ipairs({ "heli", "heliNext", "sealed", "swap" }) do truthy(E2E.timerSoon(id), id) end
    eq(heli.call.arrive, 200 + E2E.LEAD)
    eq(heli.next, nil)
    eq(m.sealedAt + OA.Rewards.hours(OA.StoryData.SEALED_LOST_DAYS), 200 + E2E.LEAD)
    eq(m.swap.waited, OA.StoryData.SWAP_WAIT_HOURS - E2E.LEAD)
    eq(E2E.timerSoon("field"), false, "not running")
end)

test("outside the circle: past its edge toward the base, north when the base is inside", function()
    local area = { x = 100, y = 100, r = 20 }
    local x, y = E2E.outsidePoint(area, 400, 100)
    eq(x, 100 + 20 + E2E.OUTSIDE)
    eq(y, 100)
    x, y = E2E.outsidePoint(area, 105, 100)
    eq(x, 100)
    eq(y, 100 - 20 - E2E.OUTSIDE)
end)
