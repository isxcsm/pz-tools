-- The order of the team's calls (Story/Comms): firing, waiting, dropping, playing, the record, the field monologues.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Comms"
local OA = OperationAcorn
local Comms, Data = OA.Comms, OA.CommsData

local function fresh() return { id = 1, number = 347 } end
local function day(h) return math.floor(h / 24) end
local function playAll(r, now)
    local ids = {}
    local e = Comms.next(r, "terminal")
    while e do
        ids[#ids + 1] = e.id
        Comms.played(r, e.id, Comms.section(r).tier, now)
        e = Comms.next(r, "terminal")
    end
    return table.concat(ids, " ")
end

test("every entry is known by its id, waits for one that exists, and has lines when it is played", function()
    for _, e in ipairs(Data.ENTRIES) do
        eq(Data.BY_ID[e.id], e)
        if e.waits then truthy(Data.BY_ID[e.waits], e.id .. " waits for " .. e.waits) end
        if e.kind == "scene" or e.kind == "field" then truthy(#e.lines > 0 and #e.lines <= 12, e.id .. " lines") end
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
    eq(playAll(r, 41), "s1_bedding s2_filter S3 s3_meteor S4")
    eq(#Comms.update(r, 47, day), 0, "the same day (hour 47)")
    eq(Comms.update(r, 48, day)[1], "S4B")
    eq(playAll(r, 49), "S4B s4_committee")
end)

test("without the serum the stage 2 scenes are dropped when the third tier comes, and the third's does not wait", function()
    local r = fresh()
    Comms.fire(r, "first", 0)
    Comms.fire(r, "settled", 0)
    Comms.enterTier(r, 2, 1)
    eq(playAll(r, 1), "S0 S1 s1_bedding s2_filter")
    Comms.enterTier(r, 3, 5)
    local s = Comms.section(r)
    eq(s.dropped.S2, true)
    eq(s.dropped.S2B, true)
    eq(playAll(r, 6), "S3 s3_meteor")
end)

test("a fired entry is never dropped, only one that never fired", function()
    local r = fresh()
    Comms.fire(r, "first", 0)
    Comms.fire(r, "serum", 0)
    Comms.enterTier(r, 3, 1)
    local s = Comms.section(r)
    eq(s.dropped.S2, nil, "fired, waiting for S1")
    eq(s.dropped.S1, true, "never fired")
    eq(playAll(r, 2), "S0 s1_bedding S2 s2_filter S3 s3_meteor")
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
    eq(playAll(r, 2), "s1_bedding S1F s2_filter S3 s3_meteor S4 s4_committee S5")
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

test("a field monologue is said once and kept in the record", function()
    local r = fresh()
    eq(Comms.say(r, "evidence", "pickup", 1, 5), "S1F_pickup")
    eq(Comms.say(r, "evidence", "pickup", 1, 6), nil)
    eq(Comms.say(r, "evidence", "nothing", 1, 6), nil)
    local log = Comms.section(r).log
    eq(log[1].id, "S1F_pickup")
    eq(log[1].tier, 1)
end)

test("the after-handover monologues come in turn and end", function()
    local r = fresh()
    eq(Comms.afterSay(r, 9, 0), "A1")
    eq(Comms.afterSay(r, 9, 0), "A2")
    eq(Comms.afterSay(r, 10, 0), "A3")
    eq(Comms.afterSay(r, 11, 0), "A4")
    eq(Comms.afterSay(r, 12, 0), nil)
end)

test("greetings: tiers 1 to 4 have one, 5 to 8 open with the number", function()
    eq(Comms.greetingKey(1), "IGUI_OA_Story_Greeting_1")
    eq(Comms.greetingKey(4), "IGUI_OA_Story_Greeting_4")
    eq(Comms.greetingKey(5), nil)
    eq(Comms.greetingKey(8), nil)
    eq(Comms.greetingKey(0), nil)
end)
