-- P5 work: what the machines make on real items. Electricity is pretended (the real power rule is p5_power.lua), and
-- the clocks are set back instead of waiting. Checks: bulk shredder (sample bundles, the record is booked), cutter
-- (vanilla rip results), wood saw (6 planks a log), propane refiner (rotten food into an empty tank), oil refiner (oil
-- into a petrol can), the hand bench, parts in/out and wear (a worn part slows, a broken one stops with a notice), the
-- generator load, the noise. Setup: single player, a character with a record (the first hello makes it) standing in
-- open ground with a clear patch 20 x 20 east and south. It gives itself the items. A section that errors prints
-- BAD and the next runs. P5_CLEAN() removes the machines. Lines are tagged "[p5work]", each "ok" or "BAD".
RUN("p5_lib.lua")
local say = P5T.say("p5work")
local function check(...) return P5T.check(say, ...) end
local M = P5T.machines()
local near = P5T.near
local player = getPlayer()
local sounds = {}

local function section(name, fn)
    say("----", name)
    local ok, err = pcall(fn)
    if not ok then say("BAD", name, "error", tostring(err)) end
end

-- Works a machine `hours` back in time, in as many steps as its batch limit needs.
local function grind(object, hours)
    M.update(object)
    local state = M.state(object)
    state.last = state.last - hours
    for _ = 1, 12 do
        local result = M.update(object)
        if not result or not result.debt then break end
    end
end

local realAddSound = addSound
addSound = function(...)
    sounds[#sounds + 1] = { ... }
    return realAddSound(...)
end

P5T.fakePower()

section("bulk shredder", function()
    local object, reason = P5T.place("bulkShredder", 3, 2, "S")
    if not check("placed", object ~= nil, reason) then return end
    local state = M.state(object)
    local inC, outC = M.container(object, "in"), M.container(object, "out")
    for _ = 1, 6 do inC:AddItem("Base.Hammer") end
    for _ = 1, 4 do inC:AddItem("Base.Plank") end
    local before = #P5T.placed
    sounds = {}
    grind(object, 1)
    local left = inC:getItems():size()
    local bundles = P5T.count(outC, "OperationAcorn.SampleBundle")
    check("it shredded some of the load in an hour", left < 10, left .. " items left")
    check("sample bundles in the output", bundles > 0, bundles)
    check("it was running", state.running == true or state.idle == true, tostring(state.reason))
    check("it made noise", #sounds > 0, #sounds)
    check("generator load of an old-motor shredder is 0.6", near(M.load(object), 0.6, 0.001) or not state.running, M.load(object))
    say("info bundles", bundles, "left", left, "status reason", tostring(state.reason))
end)

section("cutter", function()
    local object = P5T.place("cutter", 3, 5, "S")
    if not check("placed", object ~= nil) then return end
    local inC, outC = M.container(object, "in"), M.container(object, "out")
    inC:AddItem("Base.Tshirt_DefaultTEXTURE")
    inC:AddItem("Base.Tshirt_DefaultTEXTURE")
    grind(object, 1)
    local sheets = P5T.count(outC, "Base.RippedSheets") + P5T.count(outC, "Base.RippedSheetsDirty")
    check("the shirts became ripped sheets", sheets > 0, sheets)
    check("the shirts are gone", P5T.count(inC, "Base.Tshirt_DefaultTEXTURE") == 0)
end)

section("wood saw", function()
    local object = P5T.place("woodSaw", 3, 8, "S")
    if not check("placed", object ~= nil) then return end
    local inC, outC = M.container(object, "in"), M.container(object, "out")
    for _ = 1, 3 do inC:AddItem("Base.Log") end
    grind(object, 1)
    local planks = P5T.count(outC, "Base.Plank")
    check("3 logs gave planks", planks >= 12, planks)
    check("the logs are gone", P5T.count(inC, "Base.Log") == 0)
    say("info no carpentry XP should have been given: look at the XP bar")
end)

section("propane refiner", function()
    local object = P5T.place("propaneRefiner", 3, 11, "S")
    if not check("placed", object ~= nil) then return end
    local inC = M.container(object, "in")
    -- the tank goes in the tank container (the refiner fills tanks there; the input takes the food)
    local tank = M.container(object, "tank"):AddItem("Base.PropaneTank")
    if tank.setUsedDelta then tank:setUsedDelta(0) end
    local weight = 0
    for _ = 1, 30 do
        local food = inC:AddItem("Base.Steak")
        if food.setAge and food.getOffAgeMax then food:setAge(food:getOffAgeMax() + 5) end
        weight = weight + (M.rottenFood(food) or 0)
    end
    grind(object, 30)
    local filled = tank:getCurrentUsesFloat()
    -- old filter: the rotten weight over PROPANE_WEIGHT fills that share of the tank
    local want = math.min(1, weight / OperationAcorn.Machines.Data.PROPANE_WEIGHT)
    check("the tank got propane from rotten food", want > 0 and near(filled, want, 0.02), filled .. " for " .. want)
    say("info tank", filled, "state buffer", M.state(object).buffer)
end)

section("oil refiner", function()
    local object = P5T.place("oilRefiner", 7, 2, "S")
    if not check("placed", object ~= nil) then return end
    local inC = M.container(object, "in")
    local can = M.container(object, "tank"):AddItem("Base.PetrolCan")
    local fluid = can.getFluidContainer and can:getFluidContainer()
    if fluid then fluid:Empty() end
    for _ = 1, 4 do inC:AddItem("Base.OilVegetable") end
    grind(object, 20)
    local amount = fluid and fluid:getAmount() or -1
    check("the can got petrol from oil", amount > 0, amount)
    say("info petrol litres", amount)
end)

section("hand bench", function()
    local object = P5T.place("shredBench", 7, 5, "S")
    if not check("placed", object ~= nil) then return end
    P5T.give("Base.Hammer", 2)
    local entries = M.benchCandidates(player, 20)
    check("the bench sees shreddable items", #entries > 0, #entries)
    local minutes = M.benchMinutesFor(entries)
    check("time is 5 game minutes a weight, at least 30 seconds", minutes >= 0.5, minutes)
    local record = OperationAcorn.Store.player(player:getModData().OA_Id)
    if not check("a record exists", record ~= nil) then return end
    -- two hammers (heavy enough for a whole bundle each; light things only add to what the record keeps)
    local items = {}
    for _, e in ipairs(entries) do
        if #items < 2 and e.item:getFullType() == "Base.Hammer" then items[#items + 1] = e.item end
    end
    local n = M.shredByHand(player, record, items)
    check("hand shredding gave bundles", n > 0, n)
    say("info minutes", minutes, "bundles", n)
end)

section("parts: install, wear, break", function()
    local object = P5T.place("bulkShredder", 7, 8, "S")
    if not check("placed", object ~= nil) then return end
    local state = M.state(object)
    local inC, outC = M.container(object, "in"), M.container(object, "out")
    check("ships with old parts at 100", state.parts.motor.tier == "old" and state.parts.motor.cond == 100)
    -- Install a modern motor.
    local motor = P5T.give("OperationAcorn.MotorModern")
    check("a modern motor fits", M.canInstall(object, "motor", motor) ~= nil)
    check("installed", M.installPart(object, "motor", motor, player))
    check("the modern motor is in", state.parts.motor.tier == "modern")
    check("the old motor came back to the inventory", player:getInventory():containsTypeRecurse("MotorOld"))
    -- Load with the modern motor: 0.6 x 1.5.
    for _ = 1, 4 do inC:AddItem("Base.Hammer") end
    P5T.work(object, 0.2)
    check("load with a modern motor is 0.9", near(M.load(object), 0.9, 0.01) or not state.running, M.load(object))
    check("the anchor keeps the multiplier for the API (OA_Load 1.5 while switched on)", object:getModData().OA_Load == (state.on ~= false and 1.5 or 0), tostring(object:getModData().OA_Load))
    -- Wear: an old shredder blade wears 2 an hour.
    -- (it wears only while it runs: give it a load that lasts)
    for _ = 1, 40 do inC:AddItem("Base.Hammer") end
    local before = state.parts.blade.cond
    grind(object, 5)
    local after = state.parts.blade.cond
    check("the blade wore in 5 hours of work", after < before, before .. " -> " .. after)
    -- A part under 25 gives the slow, thin rate; at 0 it stops.
    state.parts.blade.cond = 20
    local st = M.status(object)
    check("a worn blade slows the machine", st.worn == true or st.speed < 1, tostring(st.speed))
    state.parts.blade.cond = 1
    for _ = 1, 20 do inC:AddItem("Base.Hammer") end
    grind(object, 5)
    check("a broken blade stops the machine", M.status(object).stopped == true, tostring(M.status(object).broken))
    -- Take it out and put it back.
    check("remove the blade", M.removePart(object, "blade", player))
    check("the slot is empty", state.parts.blade == nil)
    check("a machine without its blade is stopped for it", M.status(object).missing == "blade", tostring(M.status(object).missing))
end)

section("power rule", function()
    P5T.realPower()
    local object = P5T.place("woodSaw", 11, 8, "S")
    if not check("placed", object ~= nil) then return end
    local on = M.hasPower(object)
    say("info hasPower here (outside, no generator):", tostring(on))
    check("no electricity out here without a generator", on == false)
    P5T.fakePower()
end)

addSound = realAddSound
P5T.realPower()
say("done; P5_CLEAN() takes the machines away")
