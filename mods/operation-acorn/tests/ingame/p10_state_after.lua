-- P10 state after a reload: compares the record p10_keep and the world's P10X marks that p10_state.lua left with the
-- values it wrote to Zomboid/Lua/oadev/p10_state.txt (E2E.md 10.3, "save and load"), then takes the record and the marks
-- away. Run it after `pzdev reload` (or a save and a load) following p10_state.lua.
--   - the restock window: its start and end as written (not rolled, though the game went on), the two bought, one left, the
--     next window's factor 0.9, the town still taken;
--   - the dense marks: the baseline 77, the cleared mark, the record's reward and the kit's restock of 2;
--   - the survey zone as written (the same circle);
--   - the eggs: 40 acorns, the Furbert, the conversion rate +5 points.
-- Prints "[p10statea]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

local FILE = "oadev/p10_state.txt"

P10T.start("p10statea", function(a)
    local Shop, Dense, Eggs, Survey = OA.Shop, OA.Dense, OA.Eggs, OA.StorySurvey
    local shared = Shop.entry("serum_shared")
    local lines = P10T.read(FILE)
    if not a.check("the file of p10_state.lua is there", lines ~= nil and #lines >= 2 and string.sub(lines[1], 1, 9) == "p10state ",
        lines and lines[1] or "none") then return end
    local want = {}
    for i = 2, #lines do
        local key, value = string.match(lines[i], "^([^=]+)=(.*)$")
        if key then want[key] = value end
    end
    local r = OA.Store.player("p10_keep")
    local world = OA.Store.world("dense")
    a.cleanup(function()
        P10T.drop("p10_keep")
        if world.baseline then world.baseline.P10X = nil end
        if world.cleared then world.cleared.P10X = nil end
        P10T.write(FILE, { "p10state used" })
    end)
    if not a.check("the record p10_keep is in the save", r ~= nil) then return end
    local function num(key) return tonumber(want[key]) end

    -- the restock window
    local window = r.shop and r.shop.restock
    if a.check("the restock window is in the record", window ~= nil) then
        a.check("the window's start as written", P10T.near(window.start, num("restock.start"), 1e-3),
            string.format("%.4f", window.start) .. " written " .. tostring(want["restock.start"]))
        a.check("the window did not roll", P10T.near(Shop.restock(r).start, num("restock.start"), 1e-3))
        a.check("the window's end as written", P10T.near(Shop.restockEnd(r), num("restock.end"), 1e-3),
            string.format("%.4f", Shop.restockEnd(r)))
        a.check("two bought, as written", Shop.restockBought(shared, r) == num("restock.bought"), Shop.restockBought(shared, r))
        a.check("one left, as written", (Shop.available(shared, r)) == num("restock.left"), tostring((Shop.available(shared, r))))
        a.check("the next window's factor as written (0.9)", P10T.near(window.nextFactor, num("restock.nextFactor"), 1e-9),
            window.nextFactor)
        a.check("the town is still taken", window.towns.P10TOWN == true)
        a.check("the price of the next unit is the third's", Shop.price(shared, r) == OA.round(OA.scaled(Shop.SHARED_SERUM_PRICE,
            "UpgradeSerumPriceMultiplier") * 4), Shop.price(shared, r))
    end

    -- the dense marks
    a.check("the dense baseline as written", world.baseline and world.baseline.P10X == num("dense.baseline"),
        world.baseline and world.baseline.P10X)
    local cleared = Dense.cleared("P10X")
    a.check("the cleared mark and who cleared it", cleared ~= nil and cleared.by == want["dense.cleared"], cleared and cleared.by or "none")
    a.check("the record's reward", Dense.got(r).P10X == "crit" and Dense.count(r, "crit") == 1)
    a.check("the critical kit restocks to 2", Shop.restockQuantity(Shop.entry("kit_weapon_crit"), r) == num("dense.critKit"),
        Shop.restockQuantity(Shop.entry("kit_weapon_crit"), r))

    -- the survey zone
    if want["survey.x"] then
        local z = Survey.zones(r)[1]
        a.check("the survey zone as written", z ~= nil and z.x == num("survey.x") and z.y == num("survey.y") and z.r == num("survey.r"),
            z and (z.x .. "," .. z.y .. " r " .. z.r) or "none")
    else
        a.say("no survey zone was kept")
    end

    -- the eggs
    a.check("the acorns counted: 40", r.eggs and r.eggs.acorns == num("eggs.acorns"), r.eggs and r.eggs.acorns)
    a.check("the Furbert is kept", Eggs.has(r, "furbert") == (want["eggs.furbert"] == "true"))
    OA.Trust.reset()
    a.check("the conversion rate +5 points", P10T.near(OA.Trust.rewards(r).rate, num("eggs.rate"), 1e-9), OA.Trust.rewards(r).rate)
    a.say("the record and the marks are taken away")
end)
