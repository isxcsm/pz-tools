-- The base machines' pure logic: parts, wear, work over time, catch-up, outputs, the lure. NUMBERS.md chapter 11.
require "OperationAcorn/Core"
require "OperationAcorn/Machines/Logic"
local OA = OperationAcorn
local Data, Logic = OA.Machines.Data, OA.Machines.Logic

-- A machine state for the tests.
local function machine(kind, parts)
    return { kind = kind, parts = parts or Logic.newParts(kind), last = 0, carry = 0, idle = false }
end

-- An io of identical jobs: `count` jobs of `cost`, and a log of what finished.
local function jobs(count, cost)
    local io = { left = count, finished = 0 }
    io.next = function(fx)
        if io.left <= 0 then return nil, "noInput" end
        return { cost = cost }
    end
    io.finish = function(job, fx)
        io.left = io.left - 1
        io.finished = io.finished + 1
    end
    return io
end

test("a new machine ships with old parts at full condition", function()
    local parts = Logic.newParts("bulkShredder")
    eq(parts.motor.tier, "old")
    eq(parts.motor.cond, 100)
    eq(parts.blade.tier, "old")
    eq(parts.cover, nil)
    -- A saw has a sound cover slot but ships without one.
    local saw = Logic.newParts("woodSaw")
    truthy(saw.motor and saw.blade, "motor and blade")
    eq(saw.cover, nil, "no cover")
    eq(Logic.effects("woodSaw", saw).stopped, false, "runs without a cover")
    -- The bench, the storage, the rain storage and the lure have no parts.
    eq(OA.isEmpty(Logic.newParts("shredBench")), true)
end)

test("motor tiers set speed and electricity", function()
    local parts = Logic.newParts("bulkShredder")
    local fx = Logic.effects("bulkShredder", parts)
    near(fx.speed, 1.0)
    near(fx.power, 1.0)
    parts.motor = { tier = "normal", cond = 100 }
    fx = Logic.effects("bulkShredder", parts)
    near(fx.speed, 1.5)
    near(fx.power, 1.25)
    parts.motor = { tier = "modern", cond = 100 }
    fx = Logic.effects("bulkShredder", parts)
    near(fx.speed, 2.0)
    near(fx.power, 1.5)
end)

test("blades and catalysts carry their numbers", function()
    local parts = Logic.newParts("bulkShredder")
    parts.blade = { tier = "modern", cond = 100 }
    near(Logic.effects("bulkShredder", parts).shred, 1.2)
    parts = Logic.newParts("cutter")
    parts.blade = { tier = "normal", cond = 100 }
    near(Logic.effects("cutter", parts).pieces, 0.5)
    parts = Logic.newParts("woodSaw")
    near(Logic.effects("woodSaw", parts).planks, 6)
    parts.blade = { tier = "modern", cond = 100 }
    near(Logic.effects("woodSaw", parts).planks, 7)
    parts = Logic.newParts("oilRefiner")
    parts.catalyst = { tier = "modern", cond = 100 }
    near(Logic.effects("oilRefiner", parts).use, 0.6)
end)

test("a sound cover quiets the saw and slows it", function()
    local parts = Logic.newParts("woodSaw")
    local fx = Logic.effects("woodSaw", parts)
    eq(Logic.noiseRadius("woodSaw", fx), 40)
    parts.cover = { tier = "normal", cond = 100 }
    fx = Logic.effects("woodSaw", parts)
    near(fx.speed, 0.85)
    eq(Logic.noiseRadius("woodSaw", fx), 20)
    -- Under 25 it has lost its damping; at 0 it is as good as gone.
    parts.cover.cond = 20
    fx = Logic.effects("woodSaw", parts)
    eq(Logic.noiseRadius("woodSaw", fx), 40)
    parts.cover.cond = 0
    fx = Logic.effects("woodSaw", parts)
    near(fx.speed, 1.0)
    eq(fx.stopped, false)
end)

test("noise radii by kind", function()
    eq(Logic.noiseRadius("bulkShredder", Logic.effects("bulkShredder", Logic.newParts("bulkShredder"))), 20)
    eq(Logic.noiseRadius("cutter", Logic.effects("cutter", Logic.newParts("cutter"))), 10)
    eq(Logic.noiseRadius("propaneRefiner", Logic.effects("propaneRefiner", Logic.newParts("propaneRefiner"))), 8)
    eq(Logic.noiseRadius("oilRefiner", Logic.effects("oilRefiner", Logic.newParts("oilRefiner"))), 8)
end)

test("under 25 a part slows the machine and cuts its output; at 0 it stops", function()
    local parts = Logic.newParts("bulkShredder")
    parts.blade.cond = 24
    local fx = Logic.effects("bulkShredder", parts)
    eq(fx.worn, true)
    near(fx.speed, 0.5)
    near(fx.yield, 0.8)
    eq(fx.stopped, false)
    parts.blade.cond = 25
    fx = Logic.effects("bulkShredder", parts)
    eq(fx.worn, false)
    near(fx.speed, 1.0)
    -- Two worn parts do not stack.
    parts.blade.cond = 10
    parts.motor.cond = 10
    fx = Logic.effects("bulkShredder", parts)
    near(fx.speed, 0.5)
    near(fx.yield, 0.8)
    parts.motor.cond = 0
    fx = Logic.effects("bulkShredder", parts)
    eq(fx.stopped, true)
    eq(fx.broken, "motor")
end)

test("a missing part stops the machine", function()
    local parts = Logic.newParts("cutter")
    parts.blade = nil
    local fx = Logic.effects("cutter", parts)
    eq(fx.stopped, true)
    eq(fx.missing, "blade")
end)

test("generator load: the kind's load times the motor's multiplier, only while running", function()
    local parts = Logic.newParts("bulkShredder")
    near(Logic.load("bulkShredder", parts, true), 0.6)
    eq(Logic.load("bulkShredder", parts, false), 0)
    eq(Logic.loadMultiplier("bulkShredder", parts, true), 1.0)
    eq(Logic.loadMultiplier("bulkShredder", parts, false), 0)
    eq(Logic.loadMultiplier("shredBench", {}, true), 0)
    parts.motor = { tier = "normal", cond = 100 }
    near(Logic.load("bulkShredder", parts, true), 0.75)
    parts.motor = { tier = "modern", cond = 100 }
    near(Logic.load("bulkShredder", parts, true), 0.9)
    near(Logic.load("cutter", Logic.newParts("cutter"), true), 0.4)
    near(Logic.load("propaneRefiner", Logic.newParts("propaneRefiner"), true), 0.3)
    near(Logic.load("oilRefiner", Logic.newParts("oilRefiner"), true), 0.3)
    local saw = Logic.newParts("woodSaw")
    near(Logic.load("woodSaw", saw, true), 0.8)
    saw.motor = { tier = "modern", cond = 100 }
    near(Logic.load("woodSaw", saw, true), 1.2)
    -- No power use: the bench, the storage, the rain storage, the lure.
    eq(Logic.load("shredBench", {}, true), 0)
    eq(Logic.load("lure", {}, true), 0)
    eq(Logic.load("researchStorage", {}, true), 0)
end)

test("wear per running hour by tier", function()
    local parts = { motor = { tier = "old", cond = 100 }, blade = { tier = "normal", cond = 100 } }
    Logic.wear("bulkShredder", parts, 10)
    near(parts.motor.cond, 80)
    near(parts.blade.cond, 85)
    parts.motor = { tier = "modern", cond = 100 }
    Logic.wear("bulkShredder", parts, 10)
    near(parts.motor.cond, 90)
    -- It does not go under 0, and says so when a part reaches 0 or falls under 25.
    parts.motor = { tier = "old", cond = 30 }
    local changed = Logic.wear("bulkShredder", parts, 3)
    eq(changed.motor, "worn")
    changed = Logic.wear("bulkShredder", parts, 100)
    eq(changed.motor, "broken")
    eq(parts.motor.cond, 0)
end)

test("an old-motor bulk shredder grinds about 1500 weight before its motor is done", function()
    local state = machine("bulkShredder")
    local io = jobs(100000, 1)
    local ground = 0
    for step = 1, 200 do
        local r = Logic.advance(state, step, io, 1000)
        ground = ground + r.done
    end
    -- 30 weight an hour for the 50 hours an old motor lasts is 1500; the worn-part slowdown over its last 12.5
    -- hours (under 25 the speed halves) takes it to about 1310. Its blade (old too) wears out at the same hour.
    truthy(ground > 1250 and ground < 1500, "ground " .. tostring(ground))
    eq(state.parts.motor.cond, 0)
end)

test("work carries over steps: a job longer than a step finishes on a later one", function()
    local state = machine("propaneRefiner")
    -- Rotten food of weight 1 at 2 an hour: 30 minutes a piece.
    local io = jobs(5, 1)
    local r = Logic.advance(state, 1 / 6, io, 80)
    eq(r.done, 0, "after 10 minutes")
    near(state.carry, 2 / 6, 1e-6, "carry")
    r = Logic.advance(state, 2 / 6, io, 80)
    eq(r.done, 0, "after 20 minutes")
    r = Logic.advance(state, 3 / 6, io, 80)
    eq(r.done, 1, "after 30 minutes")
    near(state.carry, 0, 1e-6)
    r = Logic.advance(state, 3, io, 80)
    eq(r.done, 5 - 1, "the rest in 2.5 more hours is 4 more")
end)

test("a long absence is caught up in one go (a few at a time)", function()
    local state = machine("cutter")
    -- 20 clothes an hour; 300 clothes; away for 5 hours: 100 done.
    local io = jobs(300, 1)
    local r = Logic.advance(state, 5, io, 1000)
    eq(r.done, 100)
    eq(io.left, 200)
    eq(r.debt, nil)
    -- With a batch of 80 the rest of the time is left for the next step.
    state = machine("cutter")
    io = jobs(300, 1)
    r = Logic.advance(state, 5, io, 80)
    eq(r.done, 80)
    truthy(r.debt and r.debt > 0, "debt")
    near(state.last, 4, 1e-6, "80 clothes took four hours")
    r = Logic.advance(state, 5, io, 80)
    eq(r.done, 20)
    eq(r.debt, nil)
    near(state.last, 5, 1e-6)
end)

test("time without input does not count: work starts when input comes", function()
    local state = machine("cutter")
    state.idle = true
    local io = jobs(0, 1)
    local r = Logic.advance(state, 1, io, 80)
    eq(r.done, 0)
    eq(state.idle, true)
    eq(state.last, 1)
    -- Input arrives: the first step only starts the clock.
    io.left = 100
    r = Logic.advance(state, 2, io, 80)
    eq(r.done, 0)
    eq(r.started, true)
    eq(state.idle, false)
    eq(state.last, 2)
    -- The next hour does 20 clothes.
    r = Logic.advance(state, 3, io, 80)
    eq(r.done, 20)
end)

test("running out of input ends the run and the machine goes idle", function()
    local state = machine("cutter")
    local io = jobs(5, 1)
    local r = Logic.advance(state, 10, io, 80)
    eq(r.done, 5)
    eq(r.reason, "noInput")
    eq(state.idle, true)
    eq(state.last, 10)
    -- Only the 15 minutes that the five clothes needed were worked (and worn).
    near(r.hours, 0.25, 1e-6)
    near(state.parts.motor.cond, 100 - 2 * 0.25, 1e-6)
end)

test("a faster motor does the same work in less time and wears less per job", function()
    local slow, fast = machine("cutter"), machine("cutter")
    fast.parts.motor = { tier = "modern", cond = 100 }
    local a, b = jobs(100, 1), jobs(100, 1)
    local ra = Logic.advance(slow, 2, a, 1000)
    local rb = Logic.advance(fast, 2, b, 1000)
    eq(ra.done, 40)
    eq(rb.done, 80)
    -- Per job: old wears 2 an hour at 20 an hour; modern wears 1 an hour at 40 an hour.
    near(100 - slow.parts.motor.cond, 4, 1e-6)
    near(100 - fast.parts.motor.cond, 2, 1e-6)
end)

test("a stopped machine does not work and keeps its clock current", function()
    local state = machine("cutter")
    state.parts.blade.cond = 0
    local io = jobs(10, 1)
    local r = Logic.advance(state, 3, io, 80)
    eq(r.done, 0)
    eq(r.reason, "stopped")
    eq(state.last, 3)
end)

test("a worn part halves the speed", function()
    local state = machine("cutter")
    state.parts.blade.cond = 10
    local io = jobs(100, 1)
    local r = Logic.advance(state, 2, io, 1000)
    eq(r.done, 20, "10 an hour for 2 hours")
end)

test("ripping: the vanilla range", function()
    local low, high = Logic.ripRange(4, 0, 0)
    eq(low, 2)
    eq(high, 4)
    low, high = Logic.ripRange(1, 0, 0)
    eq(low, 1)
    eq(high, 1)
    -- Holes and patches take parts off, never under 1.
    low, high = Logic.ripRange(3, 1, 1)
    eq(low, 1)
    eq(high, 1)
    low, high = Logic.ripRange(6, 1, 0)
    eq(high, 5)
    low, high = Logic.ripRange(nil, nil, nil)
    eq(high, 1)
end)

test("the cutter plan: vanilla fabric, the unrippable table, the refusals", function()
    local plan = Logic.cutterPlan({ fullType = "Tshirt_ArmyGreen", fabric = "Cotton", location = "tshirt", covered = 3, holes = 0, patches = 0, dirt = 20, blood = 10 })
    eq(plan.material, "Cotton")
    eq(plan.low, 2)
    eq(plan.high, 3)
    eq(plan.dirt, 30)
    plan = Logic.cutterPlan({ fullType = "Jacket_Black", fabric = "Leather", location = "jacket", covered = 5 })
    eq(plan.material, "Leather")
    -- Hats and gloves with no fabric: 1 to 2 pieces.
    plan = Logic.cutterPlan({ fullType = "Hat_BunnyEarsBlack", location = "hat" })
    eq(plan.low, 1)
    eq(plan.high, 2)
    eq(plan.material, "Cotton")
    plan = Logic.cutterPlan({ fullType = "Gloves_FingerlessGloves", location = "hands" })
    eq(plan.high, 2)
    eq(plan.material, "Leather", "fingerless gloves are leather")
    plan = Logic.cutterPlan({ fullType = "Gloves_Woolen", location = "hands" })
    eq(plan.material, "Cotton")
    -- Shoes: leather, 2.
    plan = Logic.cutterPlan({ fullType = "Shoes_ArmyBoots", location = "shoes" })
    eq(plan.material, "Leather")
    eq(plan.low, 2)
    eq(plan.high, 2)
    -- Not cloth: helmets, armor, jewelry.
    eq(Logic.cutterPlan({ fullType = "Hat_Army_Helmet", location = "hat" }), nil)
    eq(Logic.cutterPlan({ fullType = "Hat_HardHat", location = "hat" }), nil)
    eq(Logic.cutterPlan({ fullType = "Necklace_Gold", location = "necklace" }), nil)
    eq(Logic.cutterPlan({ fullType = "Vest_CatcherVest", location = "torsoextravestbullet" }), nil)
end)

test("cutter pieces: a blade adds, wear cuts, dirt is rolled", function()
    local plan = { material = "Cotton", low = 2, high = 4, dirt = 0 }
    local fx = Logic.effects("cutter", Logic.newParts("cutter"))
    local total, dirty = 0, 0
    for _ = 1, 2000 do
        local n, d = Logic.cutterPieces(plan, fx)
        truthy(n >= 2 and n <= 4, "range")
        total = total + n
        dirty = dirty + d
    end
    near(total / 2000, 3, 0.1, "the vanilla average of 2 to 4")
    eq(dirty, 0, "clean clothes")
    -- A modern blade adds one.
    local parts = Logic.newParts("cutter")
    parts.blade = { tier = "modern", cond = 100 }
    fx = Logic.effects("cutter", parts)
    total = 0
    for _ = 1, 2000 do total = total + Logic.cutterPieces(plan, fx) end
    near(total / 2000, 4, 0.1, "one more")
    -- A normal blade: half a piece more on average.
    parts.blade = { tier = "normal", cond = 100 }
    fx = Logic.effects("cutter", parts)
    total = 0
    for _ = 1, 4000 do total = total + Logic.cutterPieces(plan, fx) end
    near(total / 4000, 3.5, 0.1, "half a piece more")
    -- A worn blade: 0.8 of it (and the normal rolls).
    parts.blade = { tier = "old", cond = 10 }
    fx = Logic.effects("cutter", parts)
    total = 0
    for _ = 1, 4000 do total = total + Logic.cutterPieces(plan, fx) end
    near(total / 4000, 2.4, 0.12, "0.8 of 3")
    -- Dirt: filthy clothes give dirty pieces.
    plan.dirt = 100
    fx = Logic.effects("cutter", Logic.newParts("cutter"))
    local n, d = Logic.cutterPieces(plan, fx)
    eq(d, n, "all dirty")
end)

test("the saw: 6 planks from a log, 6.5 and 7 expected with better blades, 0.8 worn", function()
    local parts = Logic.newParts("woodSaw")
    local fx = Logic.effects("woodSaw", parts)
    eq(Logic.sawPlanks(fx), 6)
    parts.blade = { tier = "normal", cond = 100 }
    fx = Logic.effects("woodSaw", parts)
    local total = 0
    for _ = 1, 4000 do total = total + Logic.sawPlanks(fx) end
    near(total / 4000, 6.5, 0.05)
    parts.blade = { tier = "modern", cond = 100 }
    fx = Logic.effects("woodSaw", parts)
    eq(Logic.sawPlanks(fx), 7)
    parts.blade = { tier = "old", cond = 10 }
    fx = Logic.effects("woodSaw", parts)
    total = 0
    for _ = 1, 4000 do total = total + Logic.sawPlanks(fx) end
    near(total / 4000, 4.8, 0.1, "0.8 of 6")
end)

test("saw speed: a log every five minutes", function()
    local state = machine("woodSaw")
    local io = jobs(100, 1)
    local r = Logic.advance(state, 1, io, 1000)
    eq(r.done, 12)
end)

test("propane: weight 50 of rotten food fills a tank, a catalyst cuts the material", function()
    local fx = Logic.effects("propaneRefiner", Logic.newParts("propaneRefiner"))
    near(Logic.propaneGain(50, fx), 1.0)
    near(Logic.propaneGain(5, fx), 0.1, 1e-9, "5 weight is 10%")
    local parts = Logic.newParts("propaneRefiner")
    parts.catalyst = { tier = "normal", cond = 100 }
    fx = Logic.effects("propaneRefiner", parts)
    near(Logic.propaneGain(40, fx), 1.0)
    parts.catalyst = { tier = "modern", cond = 100 }
    fx = Logic.effects("propaneRefiner", parts)
    near(Logic.propaneGain(30, fx), 1.0)
    parts.catalyst = { tier = "old", cond = 10 }
    fx = Logic.effects("propaneRefiner", parts)
    near(Logic.propaneGain(50, fx), 0.8, 1e-9, "a worn catalyst: 0.8")
end)

test("propane speed: weight 2 an hour", function()
    local state = machine("propaneRefiner")
    local io = jobs(100, 5)
    local r = Logic.advance(state, 10, io, 1000)
    eq(r.done, 4, "20 weight in 10 hours")
end)

test("oil: litres of oil by item, petrol from oil", function()
    near(Logic.oilLitres("Base.OilVegetable", 1), 1)
    near(Logic.oilLitres("Base.OilOlive", 0.5), 0.5, 1e-9, "half a bottle")
    near(Logic.oilLitres("Base.Lard", 1), 0.3)
    near(Logic.oilLitres("Base.SunflowerSeeds") * 90, 1, 1e-9, "90 sunflower seeds a litre")
    near(Logic.oilLitres("Base.FlaxSeed") * 450, 1, 1e-9, "450 flax seeds a litre")
    near(Logic.oilLitres("Base.HempSeed") * 450, 1, 1e-9, "450 hemp seeds a litre")
    eq(Logic.oilLitres("Base.Sugar"), nil)
    local fx = Logic.effects("oilRefiner", Logic.newParts("oilRefiner"))
    near(Logic.petrolGain(1, fx), 0.8)
    near(Logic.petrolGain(12.5, fx), 10, 1e-9, "12.5 L of oil fills a can")
    local parts = Logic.newParts("oilRefiner")
    parts.catalyst = { tier = "normal", cond = 100 }
    fx = Logic.effects("oilRefiner", parts)
    near(Logic.petrolGain(10, fx), 10, 1e-9, "a normal catalyst: 10 L of oil fill a can")
    parts.catalyst = { tier = "old", cond = 0 }
    fx = Logic.effects("oilRefiner", parts)
    eq(fx.stopped, true)
end)

test("oil speed: half a litre an hour", function()
    local state = machine("oilRefiner")
    local io = jobs(100, 1)
    local r = Logic.advance(state, 4, io, 1000)
    eq(r.done, 2)
end)

test("the hand bench: two minutes a weight, never under fifteen seconds", function()
    near(Logic.benchMinutes(1), 2)
    near(Logic.benchMinutes(0.2), 0.4)
    near(Logic.benchMinutes(0.05), 0.25)
    near(Logic.benchMinutes(0), 0.25)
    near(Logic.benchMinutes(5), 10)
end)

test("the lure: a sound every 15 minutes for 24 hours, then a spent shell", function()
    local lure = { start = 100, slot = -1 }
    local r = Logic.lureStep(lure, 100)
    eq(r.sound, true, "the first sound at once")
    eq(r.expired, false)
    r = Logic.lureStep(lure, 100.1)
    eq(r.sound, false, "6 minutes later nothing")
    r = Logic.lureStep(lure, 100.2)
    eq(r.sound, false, "12 minutes")
    r = Logic.lureStep(lure, 100.26)
    eq(r.sound, true, "past 15 minutes")
    -- A ten-minute step sees a sound due every 15 minutes: at 20, 30, 50 ... never two in one step.
    local sounds = 0
    local t = 100.26
    for _ = 1, 100 do
        t = t + 1 / 6
        if Logic.lureStep(lure, t).sound then sounds = sounds + 1 end
    end
    -- 100 steps of ten minutes is 16.7 hours: about 4 sounds an hour.
    near(sounds, 66, 3)
    r = Logic.lureStep(lure, 123.9)
    eq(r.expired, false)
    r = Logic.lureStep(lure, 124)
    eq(r.expired, true)
    eq(r.sound, false)
    eq(lure.spent, true)
    -- A lure that loads long after its end is only a shell.
    local old = { start = 0, slot = -1 }
    r = Logic.lureStep(old, 1000)
    eq(r.expired, true)
    eq(r.sound, false)
end)

test("lure time left", function()
    local lure = { start = 10 }
    near(Logic.lureLeft(lure, 10), 24)
    near(Logic.lureLeft(lure, 22), 12)
    near(Logic.lureLeft(lure, 100), 0)
end)

test("a lure catching up on load makes no sound burst: the slot moves on", function()
    local lure = { start = 0, slot = -1 }
    -- Loaded 10 hours later: one sound is due, not forty.
    local r = Logic.lureStep(lure, 10)
    eq(r.sound, true)
    eq(r.slot, 40)
    r = Logic.lureStep(lure, 10.01)
    eq(r.sound, false)
end)

test("parts fit only the slots of their machines", function()
    truthy(Logic.fits("bulkShredder", "blade", "shredBlade", "normal"))
    truthy(not Logic.fits("bulkShredder", "blade", "cutBlade", "normal"), "a cutting blade is not a shredding one")
    truthy(not Logic.fits("cutter", "blade", "shredBlade", "old"))
    truthy(Logic.fits("woodSaw", "cover", "cover", "normal"))
    truthy(not Logic.fits("woodSaw", "cover", "cover", "modern"), "the cover has one grade")
    truthy(Logic.fits("oilRefiner", "catalyst", "catalyst", "modern"))
    truthy(Logic.fits("cutter", "motor", "motor", "old"))
    truthy(not Logic.fits("shredBench", "motor", "motor", "old"))
    eq(Data.PART_ITEMS.MotorOld.part, "motor")
    eq(Data.PART_ITEMS.ShredBladeModern.tier, "modern")
    eq(Data.PART_ITEMS.SoundproofCover.part, "cover")
    eq(Data.PART_ITEMS.SoundproofCover.tier, "normal")
    eq(Data.partItem("catalyst", "normal"), "FilterNormal")
    eq(Data.partItem("cover", "normal"), "SoundproofCover")
end)

test("every machine kind has an item, a sprite kind and a hint", function()
    local Sprites = require "OperationAcorn/Sprites"
    for _, kind in ipairs(Data.ORDER) do
        local def = Data.KINDS[kind]
        truthy(def, kind)
        truthy(def.item, kind .. " item")
        eq(Data.ITEM_KINDS[def.item], kind)
        if kind ~= "rainStorage" and kind ~= "lure" then
            truthy(Sprites.MACHINE_KINDS[kind], kind .. " sprite")
        end
    end
end)

test("numbers from NUMBERS 11", function()
    local k = Data.KINDS
    eq(k.bulkShredder.rate, 30)
    eq(k.bulkShredder.load, 0.6)
    eq(k.bulkShredder.noise, 20)
    eq(k.cutter.rate, 20)
    eq(k.cutter.load, 0.4)
    eq(k.cutter.noise, 10)
    eq(k.propaneRefiner.rate, 2)
    eq(k.propaneRefiner.load, 0.3)
    eq(k.oilRefiner.rate, 0.5)
    eq(k.oilRefiner.load, 0.3)
    eq(k.woodSaw.rate, 12)
    eq(k.woodSaw.load, 0.8)
    eq(k.woodSaw.noise, 40)
    eq(Data.RAIN_CAPACITY, 4000)
    eq(Data.RAIN_FACTOR, 4.0)
    eq(Data.CONTAINERS.store.capacity, 300)
    eq(Data.LURE.hours, 24)
    eq(Data.LURE.interval, 0.25)
    eq(Data.LURE.radius, 60)
end)
