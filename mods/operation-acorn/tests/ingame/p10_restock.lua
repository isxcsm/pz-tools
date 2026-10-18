-- P10 restock: the shop's restock windows (Economy/Shop restock, NUMBERS 7) and the towns that shorten them, on scratch
-- records (the real one is left alone). The "ten days later" is the window's start put back by ten days (the shop
-- compares the world age with the window's start and nothing else), so no clock is touched.
--   1. the shared serum's stock floor(tier / 3) + 1 at tiers 1, 3, 6 and 12 (1, 2, 3, 5); the weapon kits locked below
--      tier 6 and stocked from it (1 each; the kits-for-sale option off says so);
--   2. one window: the shared serum's prices 20,000 / 40,000 / 80,000 (the sandbox's serum multiplier on the base) as
--      units are bought, the one-order lookahead, the cart's total the sum of the units' own prices;
--   3. the sold-out reason and the card's "out of stock, back <when>" key and text;
--   4. the window rolled (10 days + 1 hour on): stock full again with nothing carried over (one bought: 2 left; after
--      the roll 3, not 5), the prices back to the first, the new window starting where the old one ended; many windows
--      skipped in one go (35 days) refill once and keep the clock in the window;
--   5. a town's 0.9: the current window is as long as it was, the next 0.9 of it; two towns 0.81; a town takes its share
--      once;
--   6. the real towns of this world (Towns.index: how many, the sizes), the two smallest searched through by 90% of
--      their buildings: the title, the share taken, the second town 0.81, a new record that only comes into the town
--      taking its share (the world's towns section is put back as it was).
-- Setup: PZ Extension API on (for 6; the rest does not need it). Changes nothing that stays.
-- Prints "[p10restock]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

P10T.start("p10restock", function(a)
    local Shop, Trust, Towns = OA.Shop, OA.Trust, OA.Towns
    local shared = Shop.entry("serum_shared")
    if not a.check("the shared serum entry exists", shared ~= nil) then return end
    local WINDOW = Shop.RESTOCK_DAYS * 24
    local base = OA.scaled(Shop.SHARED_SERUM_PRICE, "UpgradeSerumPriceMultiplier")
    a.say("window", Shop.RESTOCK_DAYS, "days; shared serum base", base, "(sandbox multiplier on", Shop.SHARED_SERUM_PRICE, ")")

    local function atTier(name, tier)
        local stage = math.min(tier, 5)
        return P10T.scratch(a, name, stage, tier - stage)
    end

    -- 1. the stock by tier
    local want = { [1] = 1, [3] = 2, [6] = 3, [12] = 5 }
    for _, t in ipairs({ 1, 3, 6, 12 }) do
        local r = atTier("stock" .. t, t)
        local quantity = Shop.restockQuantity(shared, r)
        a.check("tier " .. t .. " is tier " .. t, Trust.tier(r) == t, Trust.tier(r))
        a.check("tier " .. t .. " stocks floor(t/3)+1 = " .. want[t], quantity == want[t] and quantity == math.floor(t / 3) + 1,
            quantity)
        local n, why = Shop.available(shared, r)
        a.check("tier " .. t .. " the shop offers " .. want[t], n == want[t] and why == nil, tostring(n) .. " " .. tostring(why))
    end
    for _, k in ipairs(Shop.WEAPON_KITS) do
        local entry = Shop.entry(k[1])
        local low = atTier("kit_low_" .. k[1], 5)
        local n, why = Shop.available(entry, low)
        a.check(k[1] .. " is locked below tier 6", n == 0 and why == "IGUI_OA_Econ_Shop_Locked", tostring(n) .. " " .. tostring(why))
        local r = atTier("kit_" .. k[1], 6)
        n, why = Shop.available(entry, r)
        if OA.option("KitsForSale") then
            a.check(k[1] .. " is stocked from tier 6: 1", n == 1 and why == nil and Shop.stocked(entry),
                tostring(n) .. " " .. tostring(why) .. " stocked " .. tostring(Shop.stocked(entry)))
        else
            a.check(k[1] .. " says kits are not for sale", n == 0 and why == "IGUI_OA_Econ_Shop_KitsOff", tostring(n) .. " " .. tostring(why))
        end
        a.check(k[1] .. " price fixed " .. k[3], Shop.price(entry, r) == k[3], Shop.price(entry, r))
    end

    -- 2. prices in one window, the cart
    local r = atTier("window", 6)
    local first = Shop.restock(r).start
    a.check("the window starts at the first look", P10T.near(first, OA.hours(), 0.01), first)
    local prices = {}
    a.check("lookahead: the second unit of one order", Shop.price(shared, r, 1) == OA.round(base * 2), Shop.price(shared, r, 1))
    local Orders = OA.Trade and OA.Trade.Orders
    if Orders then
        Orders.set(r, { { id = "serum_shared", count = 3 } })
        local total = Orders.estimate(r, 10000000)
        a.check("the cart's total is the units' own prices", total == OA.round(base) + OA.round(base * 2) + OA.round(base * 4),
            total .. " (" .. OA.round(base) .. "+" .. OA.round(base * 2) .. "+" .. OA.round(base * 4) .. ")")
        Orders.set(r, {})
    else
        a.say("Orders not loaded: the cart's total skipped")
    end
    for n = 1, 3 do
        prices[n] = Shop.price(shared, r)
        a.check("unit " .. n .. " costs " .. OA.round(base * 2 ^ (n - 1)), prices[n] == OA.round(base * 2 ^ (n - 1)), prices[n])
        Shop.bought(shared, r, 1)
    end
    a.check("three bought in the window", Shop.restockBought(shared, r) == 3)

    -- 3. sold out
    local n, why, refill = Shop.available(shared, r)
    a.check("sold out after three", n == 0 and why == "IGUI_OA_Econ_Shop_SoldOut", tostring(n) .. " " .. tostring(why))
    a.check("the sold-out answer carries the refill time", refill == Shop.restockEnd(r) and refill > OA.hours(), refill)
    a.check("the window is ten days long", P10T.near(refill - first, WINDOW, 1e-6), refill - first)
    local View = OA.Trade and OA.Trade.ShopView
    if View then
        local card = View.state(shared, { n = n, why = why, reopen = refill }, { tier = 6, whenText = function() return "WHEN" end })
        a.check("the card says out of stock with the time", card.key == "IGUI_OA_Terminal_Shop_SoldOutFrom" and card.tone == "timer",
            tostring(card.key) .. " " .. tostring(card.tone))
        local text = getText("IGUI_OA_Terminal_Shop_SoldOutFrom", "WHEN")
        a.check("the card's text reads", text ~= "IGUI_OA_Terminal_Shop_SoldOutFrom" and string.find(text, "WHEN", 1, true) ~= nil, text)
    else
        a.say("ShopView not loaded: the card's key skipped")
    end

    -- 4. the window rolled
    local restock = Shop.restock(r)
    local oldStart = restock.start
    restock.start = restock.start - (WINDOW + 1)
    local rolledStart = Shop.restock(r).start
    a.check("ten days later the stock is back", Shop.restockBought(shared, r) == 0 and (Shop.available(shared, r)) == 3,
        tostring((Shop.available(shared, r))))
    a.check("the prices are back to the first", Shop.price(shared, r) == prices[1], Shop.price(shared, r))
    a.check("the new window starts where the old one ended", P10T.near(rolledStart, oldStart - (WINDOW + 1) + WINDOW, 1e-6),
        rolledStart)
    local part = atTier("carry", 6)
    Shop.restock(part)
    Shop.bought(shared, part, 1)
    a.check("one bought: two left", (Shop.available(shared, part)) == 2)
    Shop.restock(part).start = Shop.restock(part).start - (WINDOW + 1)
    a.check("nothing carried over: three after the roll, not five", (Shop.available(shared, part)) == 3,
        tostring((Shop.available(shared, part))))
    local skip = atTier("skip", 6)
    Shop.restock(skip)
    Shop.bought(shared, skip, 2)
    Shop.restock(skip).start = Shop.restock(skip).start - 35 * 24
    local rolled = Shop.restock(skip)
    a.check("35 days skipped refill once", Shop.restockBought(shared, skip) == 0 and (Shop.available(shared, skip)) == 3)
    a.check("the clock sits in the current window", rolled.start <= OA.hours() and OA.hours() < rolled.start + WINDOW,
        string.format("start %.2f now %.2f", rolled.start, OA.hours()))
    local again = Shop.restock(skip).start
    a.check("asking again changes nothing", again == rolled.start)

    -- 5. a town's 0.9
    local t1 = atTier("town1", 6)
    local end0 = Shop.restockEnd(t1)
    a.check("a town is new to the record", Shop.townDone(t1, "A") == true)
    a.check("the same town gives nothing twice", Shop.townDone(t1, "A") == false)
    a.check("the current window is as long as it was", Shop.restockEnd(t1) == end0)
    a.check("the next window takes 0.9", P10T.near(Shop.restock(t1).nextFactor, 0.9, 1e-9), Shop.restock(t1).nextFactor)
    Shop.restock(t1).start = Shop.restock(t1).start - (WINDOW + 1)
    local w1 = Shop.restock(t1)
    a.check("the window after is 0.9 as long", P10T.near(Shop.restockEnd(t1) - w1.start, WINDOW * 0.9, 1e-6),
        Shop.restockEnd(t1) - w1.start)
    local t2 = atTier("town2", 6)
    Shop.townDone(t2, "A")
    Shop.townDone(t2, "B")
    a.check("two towns: 0.81", P10T.near(Shop.restock(t2).nextFactor, 0.81, 1e-9), Shop.restock(t2).nextFactor)
    Shop.restock(t2).start = Shop.restock(t2).start - (WINDOW + 1)
    a.check("the window after two towns is 0.81 as long", P10T.near(Shop.restockEnd(t2) - Shop.restock(t2).start, WINDOW * 0.81, 1e-6),
        Shop.restockEnd(t2) - Shop.restock(t2).start)
    Shop.townDone(t1, "B")
    a.check("a second town after the first: 0.81 for the same record", P10T.near(Shop.restock(t1).nextFactor, 0.81, 1e-9))

    -- 6. the real towns
    local titles = P10T.capture(a, "title")
    local t0 = getTimestampMs()
    local okIndex, w = pcall(Towns.index)
    local took = getTimestampMs() - t0
    if not (okIndex and w) then
        a.say("no towns index (the API's zones.clusters missing?)", tostring(w))
        a.check("the towns index", false, "not made")
        return
    end
    local count = #w.list
    a.say("towns", count, "index read in", took, "ms; limit", Towns.MIN_BUILDINGS, "buildings; share", Towns.SHARE)
    for i = 1, math.min(count, 8) do
        local t = w.list[i]
        a.say("town", i, t.n, "buildings", "at", t.x1, t.y1, "to", t.x2, t.y2, "rects", #t.rects / 4)
    end
    a.check("the map has towns", count >= 1, count)
    if count < 2 then return end
    local order = {}
    for i = 1, count do order[i] = i end
    table.sort(order, function(x, y)
        if w.list[x].n ~= w.list[y].n then return w.list[x].n < w.list[y].n end
        return x < y
    end)
    -- the world's state put back when the area ends
    local snap = { seen = P10T.copy(w.seen), found = P10T.copy(w.found), done = P10T.copy(w.done), ndone = w.ndone }
    a.cleanup(function()
        P10T.restoreInto(w.seen, snap.seen)
        P10T.restoreInto(w.found, snap.found)
        P10T.restoreInto(w.done, snap.done)
        w.ndone = snap.ndone
    end)
    local A = atTier("townA", 3)
    local doneByA = 0
    for k = 1, 2 do
        local town = order[k]
        local keys = {}
        for key, ti in pairs(w.of) do
            if ti == town and not w.seen[key] then keys[#keys + 1] = key end
        end
        table.sort(keys)
        -- the buildings still to be searched for the town to reach its share (the world may have found some already)
        local need = math.ceil(Towns.SHARE * w.list[town].n) - (w.found[town] or 0)
        local label = "town " .. town .. " (" .. w.list[town].n .. " buildings)"
        local alreadyDone = w.done[town] == true
        if alreadyDone or need < 1 or #keys < need then
            a.say(label, "skipped: already searched through in this world, or too few unsearched buildings", #keys, need)
        else
            local before = #titles
            local ndone = w.ndone
            for i = 1, need - 1 do Towns.searched(A, keys[i]) end
            a.check(label .. " not done at " .. (need - 1) .. " of " .. need, not w.done[town] and #titles == before)
            Towns.searched(A, keys[need])
            a.check(label .. " done at 90%", w.done[town] == true and w.ndone == ndone + 1, w.found[town])
            a.check(label .. " the record took its share", Shop.restock(A).towns[town] == true)
            a.check(label .. " the title told once", #titles == before + 1 and titles[#titles].detail.key == "IGUI_OA_Title_TownSearched"
                and titles[#titles].detail.sub == "IGUI_OA_Title_TownSearchedSub" and titles[#titles].detail.style == "discovery",
                P10T.keys(titles))
            doneByA = doneByA + 1
            local expected = 0.9 ^ doneByA
            a.check(label .. " the next window is " .. expected, P10T.near(Shop.restock(A).nextFactor, expected, 1e-9),
                Shop.restock(A).nextFactor)
            -- a new record coming into the town takes its share by being there
            local B = atTier("townB" .. k, 3)
            local rect = w.list[town].rects
            local cx, cy = rect[1] + math.floor(rect[3] / 2), rect[2] + math.floor(rect[4] / 2)
            local mark = #titles
            a.check(label .. " is found at its middle", Towns.at(w, cx, cy) == town, tostring(Towns.at(w, cx, cy)))
            a.check(label .. " a new record takes the share by coming in", Towns.enter(B, cx, cy) == true and Shop.restock(B).towns[town] == true)
            a.check(label .. " its title is the known one", #titles == mark + 1 and titles[#titles].detail.sub == "IGUI_OA_Title_TownSearchedSubKnown",
                P10T.keys(titles))
            a.check(label .. " once only", Towns.enter(B, cx, cy) == false)
            local C = atTier("townC" .. k, 3)
            a.check(label .. " nobody takes it from outside", Towns.enter(C, -5, -5) == false)
        end
    end
end)
