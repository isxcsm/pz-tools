-- P10 eggs: the five easter eggs (Economy/Eggs, NUMBERS 13), the effects through the real formulas, and the 07:30 radio.
--   1. Eggs.settle on a scratch record (the real one is left alone) with fake sealed entries, as the helicopter's
--      settlement hands them: the Furbert squirrel (100,000 credits once, its remark and title, the conversion rate
--      +5 points in Value's context, Branscomb's call before the handover, none after it, a fired call giving way at the
--      handover); 100 acorns over two settlements (40 + 60: a remark each time, the title only at the hundredth, the
--      box +50); a dead squirrel (serums x0.9: the shared one, the per-tree one, the n-th); a Spiffo and the three other
--      Spiffo things (the shop discount +5 points through the real price, a fixed price unmoved); other things nothing;
--      each egg once; the egg stays on a retired record;
--   2. the radio: Base.WalkieTalkie5 with the OA_Branscomb mark, turned on, at 07:30 (Eggs.radioTime exact to the
--      minute, findRadio refusing an unmarked one or one that is off, radioLook giving the tone cue once, the title and
--      the arrival hours x0.8 at both ends);
--   3. the same on the real record through the game's own minute event: the time set to 07:29, a minute let pass (the
--      tone, once, and the egg), then 07:24 at the fastest speed button with the minute passing in a fast-forward (the
--      egg given once, not skipped); the record is put back as it was, the time and the speed too.
-- Setup: the character on open ground with no zombies near (the time passes at the fastest speed for a short while; god
-- mode is on during it). A character with a record for part 3. About 40 s.
-- Prints "[p10eggs]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

P10T.start("p10eggs", function(a)
    local Eggs, Trust, Shop, Value = OA.Eggs, OA.Trust, OA.Shop, OA.Value
    local titles = P10T.capture(a, "title")
    local sounds = P10T.capture(a, "sound")
    local notices = P10T.capture(a, "notice")
    local shared = Shop.entry("serum_shared")
    local battery = Shop.entry("battery_pack")
    local cure = Shop.entry("cure_serum")
    if not a.check("the egg branch, the branches and the comms are loaded", OA.StoryEgg and OA.StoryBranches and OA.Comms
        and shared and battery and cure) then return end

    local function entries(items)
        local out = {}
        for _, item in ipairs(items) do out[#out + 1] = { info = { fullType = item[1] }, count = item[2] or 1 } end
        return out
    end

    -- Everything the eggs touch, read through the game's own formulas.
    local function effects(r)
        Trust.reset()
        local rw = Trust.rewards(r)
        local e = { rate = rw.rate, box = rw.boxCapacity, discount = rw.discount, amin = rw.arrival.min, amax = rw.arrival.max,
            shared = Shop.price(shared, r), tree = Shop.serumPrice("scout", r), nth = Shop.serumPriceAt(5, r),
            battery = Shop.price(battery, r), cure = Shop.price(cure, r) }
        local Objects = OA.Trade and OA.Trade.Objects
        e.cap = Objects and Objects.capacityFor and Objects.capacityFor(r) or nil
        local ok, ctx = pcall(Value.buildContext, r)
        e.ctxRate = ok and ctx.rate or nil
        return e
    end
    local function same(x, y) return P10T.near(x, y, 1e-9) end

    local R = P10T.scratch(a, "egg_before", 3, 0)
    R.trade.credits = 500
    local zero = effects(R)
    a.say("neutral: rate", zero.rate, "box", zero.box, "discount", zero.discount, "arrival", zero.amin, zero.amax,
        "serum", zero.shared, zero.tree, "ctx rate", zero.ctxRate)
    a.check("no egg: neutral effects", zero.rate == 0 and zero.discount == 0, zero.rate .. " " .. zero.discount)
    local mult = OA.option("CreditMultiplier") or 1.0

    -- 1. the Furbert
    local nTitles, nNotices = #titles, #notices
    local out = Eggs.settle(R, entries({ { "Base.FurbertSquirrel" } }))
    a.check("furbert: 100,000 credits", out.credits == Eggs.CREDITS, out.credits)
    a.check("furbert: the remark before the handover", out.notes[1] == "IGUI_OA_Trade_Egg_1" and #out.notes == 1, table.concat(out.notes, ","))
    a.check("furbert: the title", #titles == nTitles + 1 and titles[#titles].detail.key == "IGUI_OA_Title_Egg_1"
        and titles[#titles].detail.sub == "IGUI_OA_Title_Egg_1Sub" and titles[#titles].detail.style == "discovery", P10T.keys(titles))
    local e = effects(R)
    a.check("furbert: conversion +5 points (rewards)", same(e.rate - zero.rate, 0.05), e.rate)
    if e.ctxRate and zero.ctxRate then
        a.check("furbert: conversion +5 points in Value's context", P10T.near(e.ctxRate - zero.ctxRate, 0.05 * mult, 1e-9),
            zero.ctxRate .. " -> " .. e.ctxRate)
    else
        a.say("Value.buildContext could not be read for a scratch record: the context's rate skipped")
    end
    a.check("furbert: nothing else moved", e.box == zero.box and e.discount == zero.discount and e.shared == zero.shared)
    local again = Eggs.settle(R, entries({ { "Base.FurbertSquirrel" } }))
    a.check("furbert: once only", again.credits == 0 and #again.notes == 0 and #titles == nTitles + 1)
    a.check("furbert: the call is due before the handover", Eggs.furbertCall(R))
    local fired = OA.StoryBranches.look(R, "settled")
    a.check("furbert: Branscomb's call comes once", #fired == 1 and fired[1] == OA.StoryEgg.CALL and #OA.StoryBranches.look(R, "settled") == 0,
        table.concat(fired, ","))
    a.check("furbert: the call waits in the terminal", OA.Comms.ready(R, OA.StoryEgg.CALL))
    OA.Story.section(R).handover = true
    OA.StoryBranches.look(R, "settled")
    a.check("furbert: a call not played gives way at the handover", OA.Comms.done(R, OA.StoryEgg.CALL))
    local H = P10T.scratch(a, "egg_after", 5, 3)
    OA.Story.section(H).handover = true
    local outH = Eggs.settle(H, entries({ { "Base.FurbertSquirrel" } }))
    a.check("furbert after the handover: the remark only", outH.notes[1] == "IGUI_OA_Trade_Egg_1k" and not Eggs.furbertCall(H)
        and #OA.StoryBranches.look(H, "settled") == 0, table.concat(outH.notes, ","))

    -- 100 acorns over two settlements
    nTitles = #titles
    local first = Eggs.settle(R, entries({ { "Base.Acorn", 40 } }))
    a.check("acorns 40: a remark, no title yet", first.notes[1] == "IGUI_OA_Trade_Egg_2" and #titles == nTitles and not Eggs.has(R, "acorns"),
        R.eggs.acorns)
    local second = Eggs.settle(R, entries({ { "Base.Acorn", 60 } }))
    a.check("acorns 100: a remark and the stamp", second.notes[1] == "IGUI_OA_Trade_Egg_2" and #titles == nTitles + 1
        and titles[#titles].detail.key == "IGUI_OA_Title_Egg_2" and titles[#titles].detail.style == "stamp" and Eggs.has(R, "acorns"),
        P10T.keys(titles))
    local e2 = effects(R)
    a.check("acorns: the box +50", e2.box == zero.box + Eggs.CAPACITY, e2.box)
    if zero.cap and e2.cap then
        a.check("acorns: the box the player gets (Objects.capacityFor) +50", e2.cap == zero.cap + Eggs.CAPACITY, zero.cap .. " -> " .. e2.cap)
    end
    Eggs.settle(R, entries({ { "Base.Acorn", 10 } }))
    a.check("acorns: the title only once", #titles == nTitles + 1 and R.eggs.acorns == 110, R.eggs.acorns)
    local line = getText(Eggs.NOTES.acorns)
    a.check("acorns: the remark reads and says the egg", line ~= Eggs.NOTES.acorns, line)

    -- the dead squirrel
    nTitles = #titles
    local sq = Eggs.settle(R, entries({ { "Base.DeadSquirrel" } }))
    a.check("squirrel: remark and title", sq.notes[1] == "IGUI_OA_Trade_Egg_3" and #titles == nTitles + 1
        and titles[#titles].detail.key == "IGUI_OA_Title_Egg_3", P10T.keys(titles))
    local e3 = effects(R)
    a.check("squirrel: the shared serum x0.9", e3.shared == OA.round(e2.shared * 0.9), e2.shared .. " -> " .. e3.shared)
    a.check("squirrel: the tree serum x0.9", e3.tree == OA.round(Shop.serumPriceAt(1) * 0.9), zero.tree .. " -> " .. e3.tree)
    a.check("squirrel: the n-th serum x0.9", e3.nth == OA.round(Shop.serumPriceAt(5) * 0.9), e3.nth)
    a.check("squirrel: a cure is no serum of the shop's curve", e3.cure == zero.cure, e3.cure)
    a.check("squirrel: once", #Eggs.settle(R, entries({ { "Base.DeadSquirrel" } })).notes == 0)

    -- Spiffo
    nTitles = #titles
    local sp = Eggs.settle(R, entries({ { "Base.Spiffo" } }))
    a.check("spiffo: remark and title", sp.notes[1] == "IGUI_OA_Trade_Egg_4" and #titles == nTitles + 1
        and titles[#titles].detail.key == "IGUI_OA_Title_Egg_4", P10T.keys(titles))
    local e4 = effects(R)
    a.check("spiffo: discount +5 points", same(e4.discount - zero.discount, 0.05), e4.discount)
    local priceMult = OA.option("ShopPriceMultiplier") or 1.0
    a.check("spiffo: the shop price through the formula", e4.battery == OA.round(battery.price * priceMult * (1 - e4.discount)),
        zero.battery .. " -> " .. e4.battery)
    a.check("spiffo: a fixed price has no discount", e4.cure == zero.cure)
    for _, t in ipairs({ "Base.SpiffoBig", "Base.SpiffoSuit", "Base.SpiffoTail" }) do
        a.check("spiffo: " .. t .. " gives nothing more", #Eggs.settle(R, entries({ { t } })).notes == 0 and #titles == nTitles + 1)
    end
    local other = Eggs.settle(R, entries({ { "Base.Apple", 3 }, { "Base.Battery", 2 } }))
    a.check("other things give nothing", other.credits == 0 and #other.notes == 0 and #titles == nTitles + 1)
    local plain = P10T.scratch(a, "egg_spiffo", 3, 0)
    for _, t in ipairs({ "Base.SpiffoBig", "Base.SpiffoSuit", "Base.SpiffoTail" }) do
        local rec = P10T.scratch(a, "egg_spiffo_" .. t, 3, 0)
        Eggs.settle(rec, entries({ { t } }))
        a.check("spiffo: " .. t .. " alone gives the egg", Eggs.has(rec, "spiffo"))
    end
    a.check("a record without eggs is neutral", effects(plain).discount == 0)
    -- the eggs stay with the record when its character dies
    OA.Store.retire(R)
    a.check("the eggs stay on a retired record", Eggs.has(R, "furbert") and Eggs.has(R, "acorns") and Eggs.has(R, "squirrel")
        and Eggs.has(R, "spiffo"))
    a.check("the receipt remarks read in the language", getText("IGUI_OA_Trade_Egg_1") ~= "IGUI_OA_Trade_Egg_1"
        and getText("IGUI_OA_Trade_Egg_1k") ~= "IGUI_OA_Trade_Egg_1k" and getText("IGUI_OA_Trade_Egg_3") ~= "IGUI_OA_Trade_Egg_3"
        and getText("IGUI_OA_Trade_Egg_4") ~= "IGUI_OA_Trade_Egg_4")

    -- 2. the radio, on a scratch record
    local player = getPlayer()
    local was = P10T.hourBack(a)
    local env = P10T.env()
    local function setHour(h)
        if env and env.time then env.time(h) else getGameTime():setTimeOfDay(h) end
    end
    local speedControls = UIManager.getSpeedControls()
    local wasSpeed = speedControls:getCurrentGameSpeed()
    a.cleanup(function() speedControls:SetCurrentGameSpeed(wasSpeed) end)
    P10T.god(a)
    local inventory = player:getInventory()
    local given = {}
    local function radioItem(marked, on)
        local item = inventory:AddItem(Eggs.RADIO_TYPE)
        given[#given + 1] = item
        if marked then item:getModData()[Eggs.RADIO_MARK] = true end
        local data = item:getDeviceData()
        if data then
            if on then
                data:setPower(1.0)
                data:setIsTurnedOn(true)
            else
                data:setIsTurnedOn(false)
            end
        end
        return item, data
    end
    a.cleanup(function()
        for _, item in ipairs(given) do
            if item:getContainer() then item:getContainer():Remove(item) end
        end
    end)
    setHour(7.5)
    a.check("07:30 is the radio's minute", Eggs.radioTime())
    setHour(7.49)
    a.check("07:29 is not", not Eggs.radioTime())
    setHour(7.51)
    a.check("07:31 is not", not Eggs.radioTime())
    setHour(7.5)
    local W = P10T.scratch(a, "egg_radio", 3, 0)
    if Eggs.findRadio(player) ~= nil then
        a.say("the character carries a marked radio that is on already: the negative checks are skipped")
    else
        radioItem(false, true)
        a.check("an unmarked walkie-talkie on is no radio", Eggs.findRadio(player) == nil and not Eggs.radioLook(W, player)
            and not Eggs.has(W, "radio"))
        radioItem(true, false)
        a.check("a marked one that is off is no radio", Eggs.findRadio(player) == nil and not Eggs.radioLook(W, player))
    end
    local marked, data = radioItem(true, false)
    if data then
        data:setPower(1.0)
        data:setIsTurnedOn(true)
    end
    a.check("the marked radio is on", data ~= nil and data:getIsTurnedOn(), data and tostring(data:getIsTurnedOn()))
    local before = effects(W)
    local nSounds = #sounds
    nTitles = #titles
    a.check("a marked radio on is found", Eggs.findRadio(player) ~= nil)
    a.check("the radio gives the egg at 07:30", Eggs.radioLook(W, player) == true and Eggs.has(W, "radio"))
    a.check("one tone, the egg's cue", #sounds == nSounds + 1 and sounds[#sounds].detail == Eggs.RADIO_CUE, P10T.keys(sounds))
    a.check("the title", #titles == nTitles + 1 and titles[#titles].detail.key == "IGUI_OA_Title_Egg_5"
        and titles[#titles].detail.sub == "IGUI_OA_Title_Egg_5Sub", P10T.keys(titles))
    local after = effects(W)
    a.check("arrival x0.8 at both ends", same(after.amin, before.amin * 0.8) and same(after.amax, before.amax * 0.8),
        before.amin .. "-" .. before.amax .. " -> " .. after.amin .. "-" .. after.amax)
    a.check("once: no second tone", not Eggs.radioLook(W, player) and #sounds == nSounds + 1)
    local cue = OA.Sounds and OA.Sounds.CUES and OA.Sounds.CUES[Eggs.RADIO_CUE]
    a.check("the cue is a known sound", cue ~= nil and GameSounds.isKnownSound(cue.sound), Eggs.RADIO_CUE .. " -> " .. tostring(cue and cue.sound))

    -- 3. the real record through the minute event
    local real = P10T.record()
    if not real then
        a.say("no record for this character: the minute event path skipped")
        return
    end
    local saved = real.eggs and P10T.copy(real.eggs) or nil
    local function refresh()
        local t = OA.Store.section(real, "trade")
        t.levelsRev = (t.levelsRev or 0) + 1
        Trust.reset()
        OA.Sync.changed("trade", real.id)
    end
    a.cleanup(function()
        real.eggs = saved
        refresh()
    end)
    local watchedSounds = P10T.capture(a, "sound", true)
    local watchedTitles = P10T.capture(a, "title", true)
    local baseMin, baseMax
    local marks = {}
    -- How many times the real record was told the tone and the title since the marks.
    local function told()
        local tones, shown = 0, 0
        for i = marks.sounds, #watchedSounds do
            if watchedSounds[i].id == real.id and watchedSounds[i].detail == Eggs.RADIO_CUE then tones = tones + 1 end
        end
        for i = marks.titles, #watchedTitles do
            if watchedTitles[i].id == real.id and watchedTitles[i].detail.key == "IGUI_OA_Title_Egg_5" then shown = shown + 1 end
        end
        return tones, shown
    end
    local function mark() marks.sounds, marks.titles = #watchedSounds + 1, #watchedTitles + 1 end
    local function tod() return getGameTime():getTimeOfDay() end
    local steps = {}
    steps[#steps + 1] = { after = 200, name = "set 07:29", run = function()
        real.eggs = real.eggs or {}
        real.eggs.radio = nil
        refresh()
        baseMin, baseMax = Trust.rewards(real).arrival.min, Trust.rewards(real).arrival.max
        mark()
        setHour(7.49)
        a.say("the time set to", string.format("%.3f", tod()), "; waiting for the game's minute event (about 3 s at the default day length)")
    end }
    steps[#steps + 1] = { after = 500, name = "minute", within = 45000,
        ready = function() return real.eggs and real.eggs.radio == true end,
        run = function(_, timedOut)
            a.check("the minute event gave the egg at 07:30", not timedOut and real.eggs.radio == true,
                string.format("time now %.3f", tod()))
            local tones, shown = told()
            a.check("one tone for the real record", tones == 1, tones)
            a.check("one title for the real record", shown == 1, shown)
            Trust.reset()
            local rw = Trust.rewards(real).arrival
            a.check("the real arrival hours x0.8", same(rw.min, baseMin * 0.8) and same(rw.max, baseMax * 0.8),
                baseMin .. "-" .. baseMax .. " -> " .. rw.min .. "-" .. rw.max)
        end }
    -- the same minute passed in a fast-forward: the faster forward button (3), then the waiting speed (4)
    for _, speed in ipairs({ 3, 4 }) do
        steps[#steps + 1] = { after = 3000, name = "fast set " .. speed, run = function()
            real.eggs.radio = nil
            refresh()
            mark()
            setHour(7.40)
            speedControls:SetCurrentGameSpeed(speed)
            a.say("the time set to", string.format("%.3f", tod()), "at speed", speedControls:getCurrentGameSpeed(),
                "; waiting for the minute to pass in a fast-forward")
        end }
        steps[#steps + 1] = { after = 500, name = "fast pass " .. speed, within = 120000,
            ready = function() return (real.eggs and real.eggs.radio == true) or tod() > 7.75 end,
            run = function(_, timedOut)
                speedControls:SetCurrentGameSpeed(1)
                local gotIt = real.eggs and real.eggs.radio == true
                a.check("speed " .. speed .. ": a fast-forward through 07:30 gives the egg, not skipped", gotIt and not timedOut,
                    string.format("time now %.3f", tod()))
                local tones, shown = told()
                a.check("speed " .. speed .. ": the tone once", tones == (gotIt and 1 or 0), tones)
                a.check("speed " .. speed .. ": the title once", shown == (gotIt and 1 or 0), shown)
            end }
    end
    steps[#steps + 1] = { after = 4000, name = "settle", run = function()
        local tones = told()
        a.check("it went on once: the egg is kept and no later tone", real.eggs.radio == true and tones <= 1, tones)
    end }
    P10T.run(a, steps)
end)
