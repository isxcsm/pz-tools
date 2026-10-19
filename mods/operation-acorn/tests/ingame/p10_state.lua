-- P10 state, before a save and a reload (E2E.md 10.3, "save and load"): puts what the round keeps in the save into a record
-- of its own that stays (id p10_keep, tier 6; the real record is left alone) and writes the values to
-- Zomboid/Lua/oadev/p10_state.txt. After `pzdev reload` (or a save and a load) p10_state_after.lua compares them and takes
-- the record away.
--   - the restock window: its start (put back 3 days), the two shared serums bought in it, the next window's factor after a
--     town (0.9), the town taken;
--   - the dense places: a baseline and a cleared mark under a place id no map has (P10X, so that no real place is touched),
--     the record's reward of it (a critical kit: the shop's kit of that kind restocking to 2);
--   - the survey: the scout tree's capstone waiting for its fragment, its call played, the zone on the maps;
--   - the eggs: 40 acorns of the hundred and the Furbert (the conversion rate +5 points).
-- Setup: none. Leaves the record p10_keep and the world's P10X marks until p10_state_after.lua has run.
-- Prints "[p10state]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

local FILE = "oadev/p10_state.txt"

P10T.start("p10state", function(a)
    local Shop, Dense, Eggs, Survey = OA.Shop, OA.Dense, OA.Eggs, OA.StorySurvey
    local Rules, Data = OA.Upgrades.Rules, OA.Upgrades.Data
    local shared = Shop.entry("serum_shared")
    P10T.capture(a, "title")
    P10T.capture(a, "notice")
    P10T.drop("p10_keep")
    local r = P10T.scratch(a, "keep", 5, 1, true)
    local out = { "p10state v1 id " .. r.id }
    local function put(key, value)
        out[#out + 1] = key .. "=" .. tostring(value)
        a.say("kept", key, "=", value)
    end

    -- the restock window
    local window = Shop.restock(r)
    Shop.bought(shared, r, 2)
    Shop.townDone(r, "P10TOWN")
    window.start = window.start - 72
    put("restock.start", string.format("%.4f", window.start))
    put("restock.end", string.format("%.4f", Shop.restockEnd(r)))
    put("restock.bought", Shop.restockBought(shared, r))
    put("restock.left", (Shop.available(shared, r)))
    put("restock.nextFactor", window.nextFactor)
    a.check("the window holds two bought and one left at tier 6", Shop.restockBought(shared, r) == 2 and (Shop.available(shared, r)) == 1)

    -- the dense places (a place id no map has)
    local world = OA.Store.world("dense")
    world.baseline, world.cleared = world.baseline or {}, world.cleared or {}
    world.baseline.P10X = 77
    world.cleared.P10X = { by = r.id, at = OA.hours() }
    local critBefore = Shop.restockQuantity(Shop.entry("kit_weapon_crit"), r)
    Dense.got(r).P10X = "crit"
    put("dense.baseline", world.baseline.P10X)
    put("dense.cleared", world.cleared.P10X.by)
    put("dense.critKit", Shop.restockQuantity(Shop.entry("kit_weapon_crit"), r))
    a.check("the critical kit restocks to one more", Shop.restockQuantity(Shop.entry("kit_weapon_crit"), r) == critBefore + 1)

    -- the survey zone
    if Survey.siteOf("scout") then
        local u = Rules.section(r)
        for _ = 1, 40 do Rules.inject(u, "scout") end
        local progress = true
        while progress do
            progress = false
            for _, node in ipairs(Data.treeNodes("scout")) do
                if not node.capstone then
                    for _ = 1, node.ranks + 1 do
                        if Rules.blocked(u, node.id) ~= nil or not Rules.buy(u, node.id) then break end
                        progress = true
                    end
                end
            end
        end
        OA.StoryBranches.look(r, "approved")
        OA.Comms.played(r, "C_scout", 3)
        OA.Story.callPlayed(r, "C_scout")
        local z = Survey.zones(r)[1]
        if a.check("the survey zone is marked", z ~= nil) then
            put("survey.x", z.x)
            put("survey.y", z.y)
            put("survey.r", z.r)
        end
    else
        a.say("no drop site for the scout tree: the survey zone is not kept")
    end

    -- the eggs
    Eggs.settle(r, { { info = { fullType = "Base.Acorn" }, count = 40 }, { info = { fullType = "Base.FurbertSquirrel" }, count = 1 } })
    put("eggs.acorns", r.eggs.acorns)
    put("eggs.furbert", Eggs.has(r, "furbert"))
    put("eggs.rate", OA.Trust.rewards(r).rate)

    P10T.write(FILE, out)
    a.say("written to Zomboid/Lua/" .. FILE .. "; save, reload, then run p10_state_after.lua")
end)
