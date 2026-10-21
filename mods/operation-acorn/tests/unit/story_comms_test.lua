-- The order of the team's calls (Story/Comms): firing, waiting, dropping, playing, the record, the field monologues.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Comms"
require "OperationAcorn/Story/Data"
local OA = OperationAcorn
local Comms, Data = OA.Comms, OA.CommsData

local function fresh() return { id = 1, number = 347 } end
local function day(h) return math.floor(h / 24) end
-- Every call that comes, played at `now`; the next looked for a while after (a short call waits its gap after the
-- last call).
local function playAll(r, now)
    local ids = {}
    local e = Comms.next(r, "terminal", now + Comms.SHORT_GAP)
    while e do
        ids[#ids + 1] = e.id
        Comms.played(r, e.id, Comms.section(r).tier, now)
        e = Comms.next(r, "terminal", now + Comms.SHORT_GAP)
    end
    return table.concat(ids, " ")
end

test("a short call comes no sooner than its gap after the last call played; a scene follows at once", function()
    local r = fresh()
    Comms.fire(r, "first", 0)
    eq(Comms.next(r, "terminal", 0).id, "S0")
    Comms.played(r, "S0", 1, 0)
    Comms.enterTier(r, 1, 0)
    Comms.fire(r, "settled", 5)
    eq(Comms.next(r, "terminal", 5).id, "S1")
    Comms.played(r, "S1", 1, 5)
    Comms.enterTier(r, 2, 5)
    eq(Comms.next(r, "terminal", 5 + Comms.SHORT_GAP - 0.1), nil, "the short call not yet")
    eq(Comms.next(r, "terminal", 5 + Comms.SHORT_GAP).id, "s2_filter")
end)

test("every entry is known by its id, waits for one that exists, and has lines when it is played", function()
    for _, e in ipairs(Data.ENTRIES) do
        eq(Data.BY_ID[e.id], e)
        if e.waits then truthy(Data.BY_ID[e.waits], e.id .. " waits for " .. e.waits) end
        if e.kind == "scene" or e.kind == "field" then truthy(#e.lines > 0, e.id .. " lines") end
    end
end)

test("the first contact plays when the terminal is first used, the first settlement's scene after it", function()
    local r = fresh()
    eq(Comms.next(r, "terminal"), nil)
    Comms.fire(r, "settled", 1)
    eq(Comms.next(r, "terminal"), nil, "S1 waits for S0")
    Comms.fire(r, "first", 2)
    eq(playAll(r, 3), "S0 S1")
    eq(#Comms.section(r).log, 2)
    eq(Comms.section(r).log[1].id, "S0")
end)

test("nobody answers from the day the line went dead until the next call: then the trade goes on by itself", function()
    local r = fresh()
    eq(Comms.silent(r), false)
    local s = Comms.section(r)
    s.played.S4 = 10
    eq(Comms.silent(r), true)
    s.played.S4B = 40
    eq(Comms.silent(r), false)
    s.played.S4B = nil
    s.dropped.S4B = true
    eq(Comms.silent(r), false, "a dropped S4B ends it too")
end)

test("a trigger fires once: a second settlement does not bring the first one's scene again", function()
    local r = fresh()
    Comms.fire(r, "first", 1)
    Comms.fire(r, "settled", 1)
    eq(playAll(r, 2), "S0 S1")
    eq(#Comms.fire(r, "settled", 3), 0)
    eq(Comms.next(r, "terminal"), nil)
end)

test("the serum's scene can fire before the first settlement and waits for it", function()
    local r = fresh()
    Comms.fire(r, "first", 1)
    eq(playAll(r, 1), "S0")
    Comms.fire(r, "serum", 2)
    eq(Comms.next(r, "terminal"), nil, "S2 waits for S1")
    Comms.fire(r, "settled", 3)
    eq(playAll(r, 4), "S1 S2")
end)

test("the temperature follows half a game day after the serum's scene, the next day's after the silent one", function()
    local r = fresh()
    Comms.fire(r, "first", 0)
    Comms.fire(r, "settled", 0)
    Comms.fire(r, "serum", 0)
    eq(playAll(r, 10), "S0 S1 S2")
    eq(#Comms.update(r, 21, day), 0, "11 hours")
    eq(Comms.update(r, 22, day)[1], "S2B")
    eq(playAll(r, 22), "S2B")
    Comms.enterTier(r, 1, 30)
    Comms.enterTier(r, 4, 40)
    eq(playAll(r, 41), "s2_filter S3 S4")
    eq(#Comms.update(r, 47, day), 0, "the same day (hour 47)")
    eq(Comms.update(r, 48, day)[1], "S4B")
    eq(playAll(r, 49), "S4B s4_committee")
end)

test("without the serum the stage 2 scenes are dropped when the third tier comes, and the third's does not wait", function()
    local r = fresh()
    Comms.fire(r, "first", 0)
    Comms.fire(r, "settled", 0)
    Comms.enterTier(r, 2, 1)
    eq(playAll(r, 1), "S0 S1 s2_filter")
    Comms.enterTier(r, 3, 5)
    local s = Comms.section(r)
    eq(s.dropped.S2, true)
    eq(s.dropped.S2B, true)
    eq(playAll(r, 6), "S3")
end)

test("a fired entry is never dropped, only one that never fired", function()
    local r = fresh()
    Comms.fire(r, "first", 0)
    Comms.fire(r, "serum", 0)
    Comms.enterTier(r, 3, 1)
    local s = Comms.section(r)
    eq(s.dropped.S2, nil, "fired, waiting for S1")
    eq(s.dropped.S1, true, "never fired")
    eq(playAll(r, 2), "S0 S2 s2_filter S3")
end)

test("a story mission's scene is never dropped and holds nothing up", function()
    local r = fresh()
    Comms.fire(r, "first", 0)
    Comms.fire(r, "settled", 0)
    eq(playAll(r, 0), "S0 S1")
    Comms.enterTier(r, 5, 1)
    local s = Comms.section(r)
    eq(s.dropped.S1F, nil)
    eq(s.dropped.S4F, nil)
    Comms.fire(r, "story:evidence", 2)
    eq(playAll(r, 2), "S1F s2_filter S3 S4 s4_committee S5")
end)

test("the calls on the spot play in the field, not in the terminal", function()
    local r = fresh()
    Comms.fire(r, "field:gym", 1)
    eq(Comms.next(r, "terminal"), nil)
    eq(Comms.next(r, "field").id, "S5F")
    Comms.played(r, "S5F", 5, 2)
    eq(Comms.next(r, "field"), nil)
end)

test("the waiting count is the terminal's entries ready to play", function()
    local r = fresh()
    eq(Comms.waiting(r), 0)
    Comms.fire(r, "first", 0)
    Comms.fire(r, "settled", 0)
    eq(Comms.waiting(r), 1, "S1 waits for S0")
    Comms.played(r, "S0", 0, 1)
    eq(Comms.waiting(r), 1)
    Comms.fire(r, "field:gym", 1)
    eq(Comms.waiting(r), 1, "a field call is not counted")
end)

test("after the handover the department's calls come one a tier, in turn, and stop after four", function()
    local r = fresh()
    Comms.enterTier(r, 8, 0)
    playAll(r, 0)
    Comms.fire(r, "story:handover", 1)
    Comms.fire(r, "handedover", 1)
    eq(playAll(r, 1), "S8 S9")
    Comms.enterTier(r, 9, 2)
    eq(playAll(r, 2), "K1")
    Comms.enterTier(r, 10, 3)
    Comms.enterTier(r, 11, 4)
    eq(Comms.section(r).dropped.K2, nil, "fired at its tier, kept")
    eq(playAll(r, 5), "K2 K3")
    Comms.enterTier(r, 12, 6)
    Comms.enterTier(r, 20, 7)
    eq(playAll(r, 8), "K4")
    eq(Comms.next(r, "terminal"), nil, "nothing after the fourth")
end)

test("a field monologue is said once; the comms record keeps only what went through the terminal", function()
    local r = fresh()
    eq(Comms.say(r, "evidence", "pickup", 1, 5), "S1F_pickup")
    eq(Comms.say(r, "evidence", "pickup", 1, 6), nil)
    eq(Comms.say(r, "evidence", "nothing", 1, 6), nil)
    eq(#Comms.section(r).log, 0)
    truthy(Comms.section(r).played.S1F_pickup)
end)

test("the after-handover monologues come in turn and end", function()
    local r = fresh()
    eq(Comms.afterSay(r, 9, 0), "A1")
    eq(Comms.afterSay(r, 9, 0), "A2")
    eq(Comms.afterSay(r, 10, 0), "A3")
    eq(Comms.afterSay(r, 11, 0), nil)
end)


test("every story mission has its briefing; a briefing fired plays before the calls waiting", function()
    for id, def in pairs(OA.StoryData.STORIES) do
        if def.kind == "soil" then
            truthy(Data.BRIEFS.soil_site and Data.BRIEFS.soil_plain, id)
        else
            truthy(Data.BRIEFS[id], id)
        end
    end
    for id in pairs(OA.StoryData.REVISITS) do truthy(Data.BRIEFS[id], id) end
    local r = fresh()
    Comms.fire(r, "first", 0)
    Comms.fire(r, "settled", 0)
    eq(playAll(r, 1), "S0 S1")
    Comms.fire(r, "brief:evidence", 1)
    eq(playAll(r, 1), "B1")
    Comms.enterTier(r, 2, 2)
    Comms.fire(r, "brief:clinic", 3)
    eq(playAll(r, 3), "B2 s2_filter")
    eq(Comms.done(r, "B2"), true)
end)

test("the static of a call waiting: the first bursts at their pace, then once a game hour; a new call starts again", function()
    require "OperationAcorn/Story/CommsAlert"
    local Alert = OA.CommsAlert
    local n = 7
    eq(Alert.burstDue(n, 1, 0), true)
    eq(Alert.burstDue(n, 1, 0.2), true)
    eq(Alert.burstDue(n, 1, 0.4), true)
    eq(Alert.burstDue(n, 1, 0.6), false, "after the first few, not within the hour")
    eq(Alert.burstDue(n, 1, 1.3), false)
    eq(Alert.burstDue(n, 1, 1.3999), true, "an hour after the last, as the ten-minute event lands it (0.9999)")
    eq(Alert.burstDue(n, 1, 1.6), false)
    eq(Alert.burstDue(n, 2, 1.7), true, "a new call: the bursts start again")
    eq(Alert.burstDue(n, 2, 1.8), true)
end)

-- The count worked out entry by entry, as the waiting count was before it was kept.
local function slowWaiting(r)
    local n = 0
    for _, e in ipairs(Data.ENTRIES) do
        if e.kind ~= "say" and e.kind ~= "field" and Comms.ready(r, e.id) then n = n + 1 end
    end
    return n
end

test("the kept waiting count follows every change of the entries and the gap of a short call", function()
    local r = fresh()
    local function same(what)
        eq(Comms.waiting(r), slowWaiting(r), what)
        eq(Comms.waiting(r), slowWaiting(r), what .. " (again)")
    end
    TEST.hours = 0
    same("nothing")
    Comms.fire(r, "first", 0)
    same("fired")
    Comms.played(r, "S0", 0, 0)
    same("played")
    Comms.fire(r, "settled", 0)
    same("S1 ready")
    Comms.played(r, "S1", 1, 0)
    same("S1 played")
    Comms.enterTier(r, 2, 0)
    -- the short call waits its gap after the last call played (hour 0)
    same("a short call held by the gap")
    eq(Comms.waiting(r), 0, "nothing yet")
    TEST.hours = Comms.SHORT_GAP - 0.1
    same("just before the gap ends")
    eq(Comms.waiting(r), 0)
    TEST.hours = Comms.SHORT_GAP
    same("the gap has ended")
    eq(Comms.waiting(r), 1, "the short call counts now")
    Comms.drop(r, "s2_filter")
    same("dropped")
    eq(Comms.waiting(r), 0)
    Comms.fire(r, "serum", TEST.hours)
    Comms.played(r, "S2", 2, TEST.hours)
    TEST.hours = TEST.hours + 12
    Comms.update(r, TEST.hours, day)
    same("S2B fired by the timer")
    eq(Comms.waiting(r), 1)
    -- another record keeps its own count
    local other = fresh()
    Comms.fire(other, "first", 0)
    eq(Comms.waiting(other), 1)
    eq(Comms.waiting(r), 1)
end)

test("the timed entries are listed once with their triggers parsed", function()
    local timed = {}
    for _, e in ipairs(Data.ENTRIES) do
        local ref, hours = string.match(e.trigger, "^after:(%w+):(%d+)$")
        local nd = string.match(e.trigger, "^nextday:(%w+)$")
        if ref or nd then
            timed[#timed + 1] = e
            eq(e.afterRef, ref, e.id)
            eq(e.afterHours, hours and tonumber(hours) or nil, e.id)
            eq(e.nextdayRef, nd, e.id)
        else
            eq(e.afterRef, nil, e.id)
            eq(e.nextdayRef, nil, e.id)
        end
    end
    eq(#Data.TIMED, #timed)
    for i, e in ipairs(timed) do eq(Data.TIMED[i], e) end
    truthy(#timed >= 2, "S2B and S4B at least")
end)
