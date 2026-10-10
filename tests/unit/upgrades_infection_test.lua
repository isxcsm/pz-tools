-- The infection and its medicines (DESIGN 10, DESIGN-terminal 17): the record's state, the delay drug that holds the
-- infection (the pause maths, one at a time), the reversal, the test kit, the cure that tells nothing to someone
-- who is not infected, and the finding of a new zombie wound (with fake body parts). The fee is in the settlement tests.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/Server"
local OA = OperationAcorn
local Infection = OA.Infection
local Serums = OA.Upgrades.Serums

CharacterStat = { ZOMBIE_INFECTION = "inf", ZOMBIE_FEVER = "fever", FOOD_SICKNESS = "sick", FATIGUE = "fatigue" }
instanceof = function(object, name) return type(object) == "table" and object.class == name end

-- A body part with the flags and times the watch reads; `reads` counts how often a flag was asked.
local function newPart()
    local p = { b = false, s = false, c = false, bt = 0, st = 0, ct = 0, reads = 0 }
    p.object = {
        bitten = function() p.reads = p.reads + 1; return p.b end,
        scratched = function() p.reads = p.reads + 1; return p.s end,
        isCut = function() p.reads = p.reads + 1; return p.c end,
        getBiteTime = function() return p.bt end,
        getScratchTime = function() return p.st end,
        getCutTime = function() return p.ct end,
        SetInfected = function() end,
        IsFakeInfected = function() return false end,
    }
    return p
end

-- A character with a body of `n` parts, an infection and the counters the watch and the serums read.
local function newCharacter(n)
    local c = { hours = 100, since = 100000, by = nil, infected = false, time = -1, stats = {}, parts = {}, dead = false,
        data = {} }
    local objects = {}
    for i = 1, n or 3 do
        c.parts[i] = newPart()
        objects[i] = c.parts[i].object
    end
    local list = { size = function() return #objects end, get = function(_, i) return objects[i + 1] end }
    local body = {
        IsInfected = function() return c.infected end,
        IsFakeInfected = function() return false end,
        getInfectionTime = function() return c.time end,
        setInfectionTime = function(_, t) c.time = t end,
        setInfected = function(_, v) c.infected = v end,
        setInfectionMortalityDuration = function() end,
        setIsFakeInfected = function() end,
        getBodyParts = function() return list end,
    }
    c.body = body
    c.getBodyDamage = function() return body end
    c.getStats = function()
        return {
            get = function(_, stat) return c.stats[stat] or 0 end,
            set = function(_, stat, v) c.stats[stat] = v end,
            reset = function(_, stat) c.stats[stat] = nil end,
        }
    end
    c.getHoursSurvived = function() return c.hours end
    c.getTimeSinceZombieAttack = function() return c.since end
    c.getAttackedBy = function() return c.by end
    c.getModData = function() return c.data end
    c.getUsername = function() return "tester" end
    c.isDead = function() return c.dead end
    return c
end

-- An item of a type, and how many times it was taken out of its container.
local function newItem(itemType)
    local item = { removed = 0, data = {} }
    local container = { DoRemoveItem = function() item.removed = item.removed + 1 end }
    item.getType = function() return itemType end
    item.getContainer = function() return container end
    item.getModData = function() return item.data end
    return item
end

-- What the player was told: notices, titles, and the infection changes.
local function listen()
    local told = { notices = {}, titles = {}, changes = {}, says = {} }
    OA.Sync.listen("notice", function(id, d) told.notices[#told.notices + 1] = d end)
    OA.Sync.listen("title", function(id, d) told.titles[#told.titles + 1] = d end)
    OA.Sync.listen("infection", function(id, d) told.changes[#told.changes + 1] = d end)
    OA.Sync.listen("say", function(id, d) told.says[#told.says + 1] = d end)
    return told
end

-- The first title with a key, or nil.
local function titleOf(told, key)
    for _, t in ipairs(told.titles) do
        if t.key == key then return t end
    end
    return nil
end

local function record(id)
    return OA.Store.ensure(id or "inf", "tester")
end

-- ---- the record's state ------------------------------------------------------------------------------------------

test("a record with nothing to tell has no state, and no fee", function()
    local r = record()
    eq(Infection.state(r, 0), nil)
    eq(Infection.feeRate(r), 0)
    Infection.section(r)
    eq(Infection.state(r, 0), nil, "an empty section tells nothing")
end)

test("state: untested, known and the drug, each as designed; progress only after a positive test", function()
    local r = record()
    Infection.wounded(r, "scratch", 10)
    local s = Infection.state(r, 10)
    eq(s.untested, true)
    eq(s.infected, false)
    eq(s.progress, nil, "no number before a test")
    eq(s.drug, nil)
    eq(s.fee, 0.3)
    Infection.tested(r, true, 0.38)
    s = Infection.state(r, 10)
    eq(s.infected, true)
    eq(s.untested, false)
    near(s.progress, 0.38)
    eq(s.fee, 0.3)
    Infection.dose(r, "long", 10, 5)
    s = Infection.state(r, 10)
    eq(s.drug.kind, "long")
    near(s.drug.hoursLeft, 168)
    s = Infection.state(r, 10 + 100)
    near(s.drug.hoursLeft, 68)
    s = Infection.state(r, 10 + 168)
    eq(s.drug, nil, "the drug is over")
    eq(s.infected, true)
end)

test("a negative test takes the fee away; a drug alone has no fee", function()
    local r = record()
    Infection.wounded(r, "cut", 0)
    eq(Infection.feeRate(r), 0.3)
    Infection.tested(r, false)
    eq(Infection.feeRate(r), 0)
    eq(Infection.state(r, 0), nil)
    Infection.dose(r, "short", 0, nil)
    local s = Infection.state(r, 1)
    eq(s.drug.kind, "short")
    eq(s.fee, nil)
    eq(s.untested, false)
end)

test("the fee: a share of the credits, whole, never on nothing", function()
    local r = record()
    eq((Infection.fee(r, 1000)), 0)
    Infection.wounded(r, "scratch", 0)
    local fee, rate = Infection.fee(r, 1000)
    eq(fee, 300)
    eq(rate, 0.3)
    eq((Infection.fee(r, 1005)), 302)
    eq((Infection.fee(r, 0)), 0)
    eq((Infection.fee(r, -50)), 0)
end)

test("the moodle level for a drug: a day or less, up to 3, 5 and 7 days", function()
    eq(Infection.drugLevel(5), 1)
    eq(Infection.drugLevel(24), 1)
    eq(Infection.drugLevel(25), 2)
    eq(Infection.drugLevel(72), 2)
    eq(Infection.drugLevel(73), 3)
    eq(Infection.drugLevel(120), 3)
    eq(Infection.drugLevel(121), 4)
    eq(Infection.drugLevel(168), 4)
end)

-- ---- the delay drug ----------------------------------------------------------------------------------------------

test("a delay drug lasts its days and a new dose replaces it (the time does not add up)", function()
    local r = record()
    local d = Infection.dose(r, "long", 100, 12)
    eq(d.till, 100 + 168)
    eq(d.age, 12)
    d = Infection.dose(r, "short", 130, 99)
    eq(d.till, 130 + 24, "the new drug's own time, not added to the old")
    eq(d.kind, "short")
    eq(d.age, 12, "a drug that holds keeps its age: the new dose does not let it drift")
    d = Infection.dose(r, "long", 400, 20)
    eq(d.age, 20, "an ended drug does not")
    eq(Infection.dose(r, "monthly", 0, 0), nil)
end)

test("the hold: the infection's start time is set so its age stays what it was", function()
    local c = newCharacter()
    local r = record()
    c.infected, c.hours, c.time = true, 100, 87.5      -- 12.5 hours old
    local item = newItem("DelayDrugLong")
    TEST.hours = 50
    truthy(Serums.use(c, item, "inf"))
    eq(item.removed, 1)
    local d = r.infection.drug
    eq(d.kind, "long")
    eq(d.age, 12.5)
    eq(d.till, 50 + 168)
    -- an hour later, then a day, then days: the age stays 12.5, the progress with it
    for _, later in ipairs({ 1, 24, 100, 167.9 }) do
        c.hours = 100 + later
        TEST.hours = 50 + later
        truthy(Serums.holdInfection(c, r, TEST.hours))
        near(c.hours - c.time, 12.5, 1e-9)
    end
    -- past the end of the drug nothing is held, and the infection runs on from where the last hold left it
    TEST.hours = 50 + 168
    c.hours = 100 + 168
    eq(Serums.holdInfection(c, r, TEST.hours), false)
    near(c.hours - c.time, 12.6, 1e-9, "a tenth of an hour since the last hold")
    c.hours = c.hours + 10
    near(c.hours - c.time, 22.6, 1e-9, "and the age grows again after")
end)

test("the hold does nothing without a drug, without an infection or for a body with no start time", function()
    local c = newCharacter()
    local r = record()
    c.infected, c.hours, c.time = true, 100, 90
    eq(Serums.holdInfection(c, r, 0), false, "no drug")
    Infection.dose(r, "short", 0, 10)
    c.infected = false
    eq(Serums.holdInfection(c, r, 1), false, "not infected")
    c.infected, c.time = true, -1
    eq(Serums.holdInfection(c, r, 1), false, "no start time")
    c.time = 90
    truthy(Serums.holdInfection(c, r, 1))
    near(c.time, 90)
    Infection.dose(r, "short", 100, nil)
    eq(Serums.holdInfection(c, r, 101), false, "a drug taken without an infection holds nothing")
end)

test("a delay drug taken without an infection is used up, recorded without an age, and nothing says no", function()
    local c = newCharacter()
    local told = listen()
    local item = newItem("DelayDrug")
    TEST.hours = 10
    truthy(Serums.use(c, item, "inf"))
    eq(item.removed, 1)
    local d = record().infection.drug
    eq(d.kind, "short")
    eq(d.age, nil)
    eq(#told.notices, 1)
    eq(told.notices[1].key, "IGUI_OA_Tree_DelayDone", "the same words as with an infection")
    eq(told.notices[1].args[1], 1)
    local s = Infection.state(record(), 11)
    eq(s.drug.kind, "short", "the moodle shows either way")
end)

test("taking a second drug while one holds replaces it and keeps the hold's age", function()
    local c = newCharacter()
    c.infected, c.hours, c.time = true, 100, 90
    TEST.hours = 0
    Serums.use(c, newItem("DelayDrugLong"), "inf")
    TEST.hours = 24
    c.hours = 124
    Serums.holdInfection(c, record(), TEST.hours)
    Serums.use(c, newItem("DelayDrug"), "inf")
    local d = record().infection.drug
    eq(d.kind, "short")
    eq(d.till, 24 + 24)
    near(d.age, 10)
end)

test("the delay drug's notice tells its days", function()
    local c = newCharacter()
    local told = listen()
    Serums.use(c, newItem("DelayDrugLong"), "inf")
    eq(told.notices[1].args[1], 7)
end)

-- ---- reversal, test, cure ----------------------------------------------------------------------------------------

test("a reversal starts the infection over: its start is now, the progress is nothing, a drug's age too", function()
    local c = newCharacter()
    local r = record()
    c.infected, c.hours, c.time = true, 200, 100
    c.stats[CharacterStat.ZOMBIE_INFECTION] = 55
    Infection.tested(r, true, 0.55)
    Infection.dose(r, "long", 0, 100)
    local item = newItem("InfectionReversal")
    truthy(Serums.use(c, item, "inf"))
    eq(item.removed, 1)
    eq(c.time, 200)
    eq(c.stats[CharacterStat.ZOMBIE_INFECTION], 0)
    eq(c.infected, true, "the infection stays")
    eq(r.infection.progress, 0)
    eq(r.infection.drug.age, 0)
    -- the drug goes on holding it at the new start
    c.hours = 230
    truthy(Serums.holdInfection(c, r, 50))
    near(c.hours - c.time, 0)
end)

test("a reversal without an infection is used up and the player is told the same", function()
    local c = newCharacter()
    local told = listen()
    local item = newItem("InfectionReversal")
    truthy(Serums.use(c, item, "inf"))
    eq(item.removed, 1)
    eq(c.time, -1, "nothing was set")
    eq(told.notices[1], nil, "no notice: the title and a line")
    eq(told.titles[1].key, "IGUI_OA_Title_Reversal")
    eq(told.titles[1].style, "notice")
    eq(told.says[1].id, "Reversal")
end)

test("a test kit finds the real infection: positive is known with its progress, negative lifts the wound's fee", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.wounded(r, "scratch", 0)
    c.infected = true
    c.stats[CharacterStat.ZOMBIE_INFECTION] = 38
    local item = newItem("InfectionTestKit")
    truthy(Serums.use(c, item, "inf"))
    eq(item.removed, 1)
    eq(r.infection.known, true)
    eq(r.infection.untested, nil)
    near(r.infection.progress, 0.38)
    eq(told.titles[1].key, "IGUI_OA_Title_TestPositive")
    eq(told.titles[1].tone, "red")
    eq(told.titles[1].style, "stamp")
    eq(told.says[1].id, "TestPositive")
    eq(told.says[1].ctx.first, true)
    -- another wound after a negative test makes it untested again
    c.infected = false
    r = record("other")
    Infection.wounded(r, "cut", 0)
    truthy(Serums.use(c, newItem("InfectionTestKit"), "other"))
    eq(r.infection.untested, nil)
    eq(r.infection.known, nil)
    eq(Infection.feeRate(r), 0)
    local negative = titleOf(told, "IGUI_OA_Title_TestNegative")
    eq(negative.sub, "IGUI_OA_Title_TestNegativeSub")
    eq(negative.style, "notice")
    eq(told.says[#told.says].id, "TestNegative")
    Infection.wounded(r, "bite", 0)
    eq(Infection.feeRate(r), 0.3)
end)

test("a cure serum used up by someone who is not infected says nothing and changes nothing", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.wounded(r, "scratch", 0)
    local item = newItem("CureSerum")
    Serums.cureStatus = function() return "ok", 3 end
    eq(Serums.use(c, item, "inf"), false)
    eq(item.removed, 1, "it is used up")
    eq(#told.notices, 0)
    eq(#told.titles, 0)
    eq(r.infection.untested, true, "the wound is still untested: a cure is not a test")
end)

test("a cure serum that cures clears the infection, the fee and the drug", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    c.infected, c.time = true, 50
    Infection.tested(r, true, 0.4)
    Infection.dose(r, "long", 0, 10)
    Serums.cureStatus = function() return "ok", 3 end
    local item = newItem("CureSerum")
    truthy(Serums.use(c, item, "inf"))
    eq(c.infected, false)
    eq(Infection.state(r, 1), nil)
    eq(Infection.feeRate(r), 0)
    eq(told.titles[1].key, "IGUI_OA_Title_Cured")
    eq(told.titles[1].style, "stamp")
    eq(told.titles[1].tone, "green")
end)

test("serum kinds of the infection items", function()
    eq((Serums.kind("DelayDrug")), "delay")
    local kind, length = Serums.kind("DelayDrugLong")
    eq(kind, "delay"); eq(length, "long")
    kind, length = Serums.kind("DelayDrug")
    eq(length, "short")
    eq((Serums.kind("InfectionReversal")), "reversal")
    eq((Serums.kind("InfectionTestKit")), "test")
end)

-- ---- what the body shows once a minute ---------------------------------------------------------------------------

test("an infection the record does not know of is untested; a known one that is gone is dropped", function()
    local r = record()
    truthy(Infection.wantsSeen(r, true, nil, 0))
    truthy(Infection.seen(r, true, nil, 0))
    eq(r.infection.untested, true)
    eq(Infection.wantsSeen(r, true, nil, 0), false, "nothing more to tell")
    eq(Infection.seen(r, true, nil, 0), false)
    Infection.tested(r, true, 0.1)
    eq(Infection.wantsSeen(r, true, 0.102, 0), false, "the same percent")
    truthy(Infection.wantsSeen(r, true, 0.11, 0), "a percent more")
    truthy(Infection.seen(r, true, 0.11, 0))
    near(r.infection.progress, 0.11)
    truthy(Infection.wantsSeen(r, false, nil, 0))
    truthy(Infection.seen(r, false, nil, 0))
    eq(r.infection.known, nil)
    eq(Infection.wantsSeen(r, false, nil, 0), false)
end)

test("a wound left untested stays so when no infection shows; a drug taken before an infection ends when it shows", function()
    local r = record()
    Infection.wounded(r, "scratch", 0)
    eq(Infection.wantsSeen(r, false, nil, 0), false)
    local r2 = record("two")
    Infection.dose(r2, "long", 0, nil)
    truthy(Infection.wantsSeen(r2, true, nil, 5), "an infection with a drug that holds nothing")
    truthy(Infection.seen(r2, true, nil, 5))
    eq(r2.infection.drug, nil)
    eq(r2.infection.untested, true)
end)

-- ---- the server's side of a wound --------------------------------------------------------------------------------

test("server: a zombie wound is untested from now and ends a drug, with the wound named", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.dose(r, "long", 0, 10)
    TEST.hours = 5
    sendClientCommand(c, OA.MOD, "infection.wound", { id = "inf", kind = "scratch" })
    eq(r.infection.untested, true)
    eq(r.infection.drug, nil)
    eq(#told.notices, 1)
    eq(told.notices[1].key, "IGUI_OA_Tree_DrugLost")
    eq(told.notices[1].args[1], "scratch")
    eq(#told.changes, 1)
    -- no drug, no notice
    sendClientCommand(c, OA.MOD, "infection.wound", { id = "inf", kind = "bite" })
    eq(#told.notices, 1)
end)

test("server: a wound does not make a known infection untested; a made-up kind is refused", function()
    local c = newCharacter()
    local r = record()
    Infection.tested(r, true, 0.2)
    sendClientCommand(c, OA.MOD, "infection.wound", { id = "inf", kind = "cut" })
    eq(r.infection.known, true)
    eq(r.infection.untested, nil)
    local r2 = record("two")
    sendClientCommand(c, OA.MOD, "infection.wound", { id = "two", kind = "fall" })
    eq(r2.infection, nil, "nothing was made")
end)

test("server: seen tells the record an infection, and its progress after a test", function()
    local c = newCharacter()
    local r = record()
    sendClientCommand(c, OA.MOD, "infection.seen", { id = "inf", infected = true })
    eq(r.infection.untested, true)
    Infection.tested(r, true, 0.5)
    sendClientCommand(c, OA.MOD, "infection.seen", { id = "inf", infected = true, progress = 0.62 })
    near(r.infection.progress, 0.62)
    sendClientCommand(c, OA.MOD, "infection.seen", { id = "inf", infected = false })
    eq(r.infection.known, nil)
end)

-- ---- finding a new zombie wound ----------------------------------------------------------------------------------

local function zombieNear(c, distance)
    c.by = { class = "IsoZombie", DistTo = function() return distance end }
end

test("the watch reads nothing of the body while no zombie has attacked", function()
    local c = newCharacter(5)
    Infection.resetWatch()
    c.since = Infection.GATE + 1
    for _ = 1, 20 do eq(Infection.watch(c), nil) end
    for _, p in ipairs(c.parts) do eq(p.reads, 0, "no part was read") end
    eq(Infection.watching(), false)
end)

test("a flag that goes on while a zombie attacks is a new wound of its kind, with the zombie near", function()
    for _, case in ipairs({ { "b", "bite" }, { "s", "scratch" }, { "c", "cut" } }) do
        local c = newCharacter(5)
        Infection.resetWatch()
        zombieNear(c, 1.2)
        c.since = 0
        eq(Infection.watch(c), nil, "the first look is only the baseline")
        eq(Infection.watch(c), nil, "nothing changed")
        c.parts[3][case[1]] = true
        c.parts[3][case[1] == "b" and "bt" or case[1] == "s" and "st" or "ct"] = 12
        eq(Infection.watch(c), case[2])
        eq(Infection.watch(c), nil, "once: the next update sees the same state")
    end
end)

test("a wound counts only when the last attacker is a zombie within two tiles", function()
    local c = newCharacter(4)
    Infection.resetWatch()
    c.since = 0
    zombieNear(c, 1)
    Infection.watch(c)
    c.parts[2].s, c.parts[2].st = true, 9
    c.by = nil
    eq(Infection.watch(c), nil, "no attacker (glass, a fall)")
    Infection.resetWatch()
    c.parts[2].s = false
    c.by = { class = "IsoPlayer", DistTo = function() return 1 end }
    Infection.watch(c)
    c.parts[2].s, c.parts[2].st = true, 9
    eq(Infection.watch(c), nil, "an attacker that is no zombie")
    Infection.resetWatch()
    c.parts[2].s = false
    zombieNear(c, 3.5)
    Infection.watch(c)
    c.parts[2].s, c.parts[2].st = true, 9
    eq(Infection.watch(c), nil, "a zombie too far")
end)

test("a wound on a part that was already wounded shows by its time set afresh, not by the time running out", function()
    local c = newCharacter(4)
    Infection.resetWatch()
    zombieNear(c, 1)
    c.since = 0
    c.parts[1].s, c.parts[1].st = true, 10
    Infection.watch(c)
    for _ = 1, 50 do
        c.parts[1].st = c.parts[1].st - 0.004
        eq(Infection.watch(c), nil, "healing is not a wound")
    end
    c.parts[1].st = 14
    eq(Infection.watch(c), "scratch", "a new random time, higher")
    c.parts[1].st = 8
    eq(Infection.watch(c), "scratch", "or a lower one")
end)

test("the worst wound of one update is named: a bite before a laceration before a scratch", function()
    local c = newCharacter(6)
    Infection.resetWatch()
    zombieNear(c, 1)
    c.since = 0
    Infection.watch(c)
    c.parts[1].s, c.parts[1].st = true, 8
    c.parts[2].c, c.parts[2].ct = true, 14
    eq(Infection.watch(c), "cut")
    Infection.resetWatch()
    Infection.watch(c)
    c.parts[5].b, c.parts[5].bt = true, 60
    eq(Infection.watch(c), "bite")
end)

test("the gate closing forgets the baseline: wounds from other causes between attacks are not new", function()
    local c = newCharacter(4)
    Infection.resetWatch()
    zombieNear(c, 1)
    c.since = 0
    Infection.watch(c)
    c.since = Infection.GATE + 5
    Infection.watch(c)
    eq(Infection.watching(), false)
    c.parts[1].c, c.parts[1].ct = true, 12     -- a cut by glass while no zombie was near
    c.since = 0
    eq(Infection.watch(c), nil, "the baseline is taken with the wound already there")
    eq(Infection.watch(c), nil)
end)

test("a new body (a new character) starts a new baseline", function()
    local c = newCharacter(4)
    Infection.resetWatch()
    zombieNear(c, 1)
    c.since = 0
    Infection.watch(c)
    local other = newCharacter(4)
    other.since = 0
    zombieNear(other, 1)
    other.parts[1].s, other.parts[1].st = true, 9
    eq(Infection.watch(other), nil, "another body: nothing to compare with yet")
end)
