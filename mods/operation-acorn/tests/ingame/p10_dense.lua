-- P10 dense: the dense places (Story/Dense, NUMBERS 7 'Dense places'), for tuning DENSE_MIN (Dense.MIN 7: B42 maps run 0 to 10) and
-- DENSE_CHUNKS (Dense.CHUNKS 20) and for the clearing end to end.
--   1. the world's list made once: the count, the first places' x, y, r, chunks and kind, the same table asked again,
--      the kinds rotating damage / crit / repair in the density order;
--   2. the tuning data: how many places the map gives (the vanilla map unless a map mod is on) and each place's peak and
--      mean intensity and its chunks, at the numbers in use, then a grid of other minimums and chunk counts (the API's
--      zombies.dense read with each; the first call of a new pair is slow, the ms are printed);
--   3. the maps: from tier 6 each place a circle in its kit's colour (crimson damage, magenta crit, lime repair), below
--      tier 6 none;
--   4. the clearing, with scratch records and the real one's look held back: the character is sent to the first place that
--      is not cleared yet (god mode), still harmless zombies are made round it (Dev style: addZombiesInOutfit + setUseless),
--      a tier-6 record standing at the middle takes the baseline (the most counted, at least Dense.LEAST); half of the
--      zombies gone changes nothing; down to 10% of the baseline clears the place: the title, the record's reward, the
--      shop's kit of that kind restocking to 2 (the other two kinds stay 1), the circle gone from that record's map; a
--      second record (a new character) standing there only inherits it ("had" title, no new count); a tier-5 record and
--      one far away get nothing; the world's baseline and cleared marks for the place are put back, the character comes back.
-- Setup: PZ Extension API on; the character anywhere (it goes to the place and back, 20 to 60 s). The zombies made are
-- taken away again; to reach 10% some of the place's own are taken away too (the place fills up again as it loads).
-- Prints "[p10dense]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

P10T.start("p10dense", function(a)
    local Dense, Shop, View = OA.Dense, OA.Shop, OA.StoryView
    local api = OA.api()
    if not a.check("the API has the dense places call", api and api.zombies and type(api.zombies.dense) == "function"
        and type(api.zombies.near) == "function") then return end

    -- 1. the world list
    local list = Dense.ensure()
    if not a.check("the list is made", list ~= nil and OA.Store.world("dense").made == true, list and #list or "nil") then return end
    a.say("places in this world", #list, "numbers in use: min", Dense.MIN, "chunks", Dense.CHUNKS)
    a.check("asking again gives the same list, made once", Dense.ensure() == list)
    local kindsOk = true
    for i, p in ipairs(list) do
        if p.id ~= "D" .. i or p.kind ~= Dense.kindAt(i) then kindsOk = false end
    end
    a.check("ids D1.. in the density order, kinds rotating", kindsOk)
    for i = 1, math.min(#list, 12) do
        local p = list[i]
        a.say("place", p.id, "x", p.x, "y", p.y, "r", p.r, "chunks", p.chunks, "kind", p.kind)
    end
    if not a.check("the map has dense places", #list >= 1, #list) then return end

    -- 2. the tuning data
    local t0 = getTimestampMs()
    local ok, found = pcall(api.zombies.dense, { min = Dense.MIN, minChunks = Dense.CHUNKS })
    a.check("the API answers at the numbers in use", ok and type(found) == "table", ok and ((found and #found) or 0) or tostring(found))
    if ok and type(found) == "table" then
        local merged = Dense.merge(found)
        a.say("zombies.dense at", Dense.MIN, Dense.CHUNKS, "->", #found, "places in", getTimestampMs() - t0, "ms;", #merged,
            "once the overlapping ones are made one")
        a.check("the world list is what the numbers in use give, overlapping places made one", #merged == #list,
            #merged .. " vs " .. #list)
        local apart = true
        for i = 1, #list do
            for j = i + 1, #list do
                local p, q = list[i], list[j]
                local dx, dy = p.x - q.x, p.y - q.y
                if dx * dx + dy * dy < (p.r + q.r - 2) * (p.r + q.r - 2) then apart = false end
            end
        end
        a.check("no two circles overlap", apart)
        local peak, mean = 0, 0
        for i, p in ipairs(found) do
            peak, mean = math.max(peak, p.peak or 0), mean + (p.mean or 0)
            if i <= 12 then
                a.say("figures", "rank", p.rank or i, "chunks", p.chunks, "peak", p.peak, "mean", string.format("%.1f", p.mean or 0),
                    "r", string.format("%.0f", p.r or 0), "at", string.format("%.0f", p.x), string.format("%.0f", p.y))
            end
        end
        if #found > 0 then a.say("highest peak", peak, "mean of the means", string.format("%.1f", mean / #found)) end
    end
    local mins, chunks = { 5, 6, 7, 8, 9, 10 }, { 3, 6, 10, 20, 30 }
    for _, c in ipairs(chunks) do
        local row = {}
        for _, m in ipairs(mins) do
            local started = getTimestampMs()
            local good, res = pcall(api.zombies.dense, { min = m, minChunks = c })
            row[#row + 1] = m .. ":" .. (good and type(res) == "table" and (#res .. "/" .. #Dense.merge(res)) or "err")
                .. "(" .. (getTimestampMs() - started) .. "ms)"
        end
        a.say("tuning: chunks >=", c, "| min:places/merged", table.concat(row, " "))
    end
    a.check("the tuning grid was read", true)

    -- 3. the maps
    local low = P10T.scratch(a, "dense_low", 5, 0)
    local high = P10T.scratch(a, "dense_high", 5, 1)
    a.check("below tier 6 no place is shown", #Dense.shown(low) == 0 and View ~= nil, #Dense.shown(low))
    a.check("from tier 6 every place is shown", #Dense.shown(high) == #list, #Dense.shown(high))
    if View then
        local sceneLow, sceneHigh = View.scene(low, nil), View.scene(high, nil)
        local function dense(scene)
            local n = 0
            for _, c in ipairs(scene.circles) do
                for _, color in pairs(View.MAP_DENSE) do
                    if c.color == color then n = n + 1 end
                end
            end
            return n
        end
        a.check("no dense circle on the map below tier 6", dense(sceneLow) == 0, dense(sceneLow))
        a.check("a circle for each place from tier 6", dense(sceneHigh) == #list, dense(sceneHigh))
        local right = true
        for _, p in ipairs(list) do
            local hit = false
            for _, c in ipairs(sceneHigh.circles) do
                if c.x == p.x + 0.5 and c.y == p.y + 0.5 and c.r == p.r and c.color == View.MAP_DENSE[p.kind] and c.dim then hit = true end
            end
            if not hit then right = false end
        end
        a.check("each circle in its kit's colour, dim, at the place", right)
    end
    for _, k in ipairs(Shop.WEAPON_KITS) do
        local entry = Shop.entry(k[1])
        local r6 = P10T.scratch(a, "dense_shop_" .. k[2], 5, 1)
        a.check("the " .. k[2] .. " kit restocks to 1 before any place is cleared", Shop.restockQuantity(entry, r6) == 1,
            Shop.restockQuantity(entry, r6))
    end

    -- 4. the clearing
    local place
    for _, p in ipairs(list) do
        if not Dense.cleared(p.id) then place = p; break end
    end
    if not place then
        a.say("every place is cleared in this world already: the clearing was skipped")
        return
    end
    local world = OA.Store.world("dense")
    world.baseline, world.cleared = world.baseline or {}, world.cleared or {}
    local oldBase, oldCleared = world.baseline[place.id], world.cleared[place.id]
    a.cleanup(function()
        world.baseline[place.id] = oldBase
        world.cleared[place.id] = oldCleared
    end)
    local titles = P10T.capture(a, "title")
    -- the real record's look is held back while this runs (the minute event would count and clear for it). The event calls
    -- Dense.minute(record, position) (not Dense.look), so both are held back; this file's own looks are Dense.look of
    -- scratch records.
    local realLook, realMinute = Dense.look, Dense.minute
    Dense.look = function(record, x, y)
        if P10T.isScratch(record.id) then return realLook(record, x, y) end
    end
    if realMinute then
        Dense.minute = function(record, position)
            if P10T.isScratch(record.id) then return realMinute(record, position) end
        end
    end
    a.cleanup(function()
        Dense.look = realLook
        Dense.minute = realMinute
    end)

    local ox, oy, oz = P10T.where()
    P10T.god(a)
    local player = getPlayer()
    local mine, isMine = {}, {}
    a.cleanup(function()
        for _, z in ipairs(mine) do
            pcall(function()
                z:removeFromWorld()
                z:removeFromSquare()
            end)
        end
        P10T.tp(ox, oy, oz)
    end)
    local A = P10T.scratch(a, "dense_a", 5, 1)
    local B = P10T.scratch(a, "dense_b", 5, 1)
    local C = P10T.scratch(a, "dense_c", 5, 0)
    local base, real0
    local kitEntry = Shop.entry("kit_weapon_" .. place.kind)

    local function remove(z)
        z:removeFromWorld()
        z:removeFromSquare()
    end
    -- The zombies of the place on the ground floor, nearest first: { zombie, ours }.
    local function around()
        local out = {}
        local zs = getCell():getZombieList()
        for i = 0, zs:size() - 1 do
            local z = zs:get(i)
            if math.floor(z:getZ()) == 0 then
                local d = IsoUtils.DistanceTo(z:getX(), z:getY(), place.x + 0.5, place.y + 0.5)
                if d <= Dense.COUNT_R + 1 then out[#out + 1] = { z = z, d = d, ours = isMine[z] == true } end
            end
        end
        table.sort(out, function(x, y)
            if x.ours ~= y.ours then return x.ours end
            return x.d < y.d
        end)
        return out
    end
    -- Takes zombies away (ours first) so that the API should count `target`: the count is read at the next step, when
    -- the game has taken the removed ones out of its lists. Returns how many were taken.
    local function removeTo(target)
        local count = Dense.countAt(place.x, place.y, math.max(Dense.COUNT_R, place.r)) or 0
        local drop = count - target
        if drop <= 0 then return 0 end
        local list2 = around()
        local n = math.min(drop, #list2)
        for i = 1, n do remove(list2[i].z) end
        return n
    end

    local steps = {}
    steps[#steps + 1] = { after = 200, name = "go", run = function()
        a.say("going to", place.id, "at", place.x, place.y, "kind", place.kind, "r", place.r)
        P10T.tp(place.x, place.y, 0)
    end }
    steps[#steps + 1] = { after = 3000, name = "arrived", within = 40000,
        ready = function() return getCell():getGridSquare(place.x, place.y, 0) ~= nil end,
        run = function(_, timedOut)
            if not a.check("the place's square is loaded", not timedOut, place.x .. "," .. place.y) then return end
            real0 = Dense.countAt(place.x, place.y, math.max(Dense.COUNT_R, place.r)) or 0
            a.say("the place holds", real0, "zombies of its own now")
            local n = math.min(150, math.max(30, 9 * real0 + 10))
            local px, py, pz = P10T.where()
            local spots = { { 4, 4 }, { -4, 4 }, { 4, -4 }, { -4, -4 }, { 8, 0 }, { -8, 0 }, { 0, 8 }, { 0, -8 } }
            local each = math.ceil(n / #spots)
            for _, s in ipairs(spots) do
                local zs = addZombiesInOutfit(px + s[1], py + s[2], pz, each, "Generic01", 50)
                for i = 0, zs:size() - 1 do
                    local z = zs:get(i)
                    z:setUseless(true)
                    mine[#mine + 1] = z
                    isMine[z] = true
                end
            end
            a.say("zombies made", #mine, "of", n, "wanted; standing at", px, py)
        end }
    steps[#steps + 1] = { after = 1500, name = "baseline", run = function()
        local count = Dense.countAt(place.x, place.y, math.max(Dense.COUNT_R, place.r))
        a.say("counted now", count, "(the API's zombies.near within", Dense.COUNT_R, ")")
        Dense.look(A, place.x, place.y)
        base = world.baseline[place.id]
        a.check("a baseline is taken: the most counted", base ~= nil and base == count and base >= Dense.LEAST,
            tostring(base) .. " counted " .. tostring(count) .. " least " .. Dense.LEAST)
        a.check("not cleared at the baseline", Dense.cleared(place.id) == nil and Dense.got(A)[place.id] == nil)
    end }
    steps[#steps + 1] = { after = 1300, name = "half cut", run = function()
        if not base then return end
        local n = removeTo(math.floor(base * 0.5))
        a.say("taking zombies away down to half of", base, ":", n, "removed")
    end }
    steps[#steps + 1] = { after = 1300, name = "half", run = function()
        if not base then return end
        local count = Dense.countAt(place.x, place.y, math.max(Dense.COUNT_R, place.r))
        Dense.look(A, place.x, place.y)
        a.check("half the zombies gone: still not cleared", Dense.cleared(place.id) == nil and Dense.got(A)[place.id] == nil,
            tostring(count) .. " of " .. base)
        a.check("the baseline stays the most counted", world.baseline[place.id] == base, world.baseline[place.id])
    end }
    steps[#steps + 1] = { after = 100, name = "tenth cut", run = function()
        if not base then return end
        local n = removeTo(math.floor(base * Dense.CLEARED_SHARE))
        a.say("taking zombies away down to a tenth of", base, ":", n, "removed")
    end }
    steps[#steps + 1] = { after = 1300, name = "tenth top up", run = function()
        if not base then return end
        -- (what the first cut left over, once the game has taken the removed ones out of its lists)
        local n = removeTo(math.floor(base * Dense.CLEARED_SHARE))
        if n > 0 then a.say("a few left over:", n, "more removed") end
    end }
    steps[#steps + 1] = { after = 1300, name = "tenth", run = function()
        if not base then return end
        local count = Dense.countAt(place.x, place.y, math.max(Dense.COUNT_R, place.r))
        a.check("the count is at 10% of the baseline", count ~= nil and count <= base * Dense.CLEARED_SHARE, tostring(count) .. " of " .. base)
        local before = #titles
        Dense.look(A, place.x, place.y)
        local c = Dense.cleared(place.id)
        a.check("cleared by the record", c ~= nil and c.by == A.id, c and c.by or "no")
        a.check("the record got the kit of the place: " .. place.kind, Dense.got(A)[place.id] == place.kind, Dense.got(A)[place.id])
        local t = titles[#titles]
        a.check("the title: cleared", #titles == before + 1 and t.detail.key == "IGUI_OA_Title_DenseCleared"
            and t.detail.sub == "IGUI_OA_Title_DenseClearedSub" and t.detail.style == "discovery"
            and t.detail.subArgs[1].key == "IGUI_OA_Dense_Kit_" .. place.kind, P10T.keys(titles))
        if t and #titles == before + 1 then
            a.say("title reads:", getText(t.detail.key), "|", getText(t.detail.sub, getText(t.detail.subArgs[1].key)))
        end
        a.check("the shop restocks the kit to 2", Shop.restockQuantity(kitEntry, A) == 2, Shop.restockQuantity(kitEntry, A))
        for _, k in ipairs(Shop.WEAPON_KITS) do
            if k[2] ~= place.kind then
                a.check("the " .. k[2] .. " kit stays 1", Shop.restockQuantity(Shop.entry(k[1]), A) == 1)
            end
        end
        if OA.option("KitsForSale") then
            local n = Shop.available(kitEntry, A)
            a.check("the shop offers 2 of it", n == 2, n)
        end
        a.check("the place is off that record's map", #Dense.shown(A) == #list - 1)
        if View then
            local scene = View.scene(A, nil)
            local still = false
            for _, circle in ipairs(scene.circles) do
                if circle.x == place.x + 0.5 and circle.y == place.y + 0.5 then still = true end
            end
            a.check("its circle is gone from that record's map", not still)
        end
    end }
    steps[#steps + 1] = { after = 1300, name = "inherit", run = function()
        if not a.check("the place is cleared, so that a new character can inherit it", Dense.cleared(place.id) ~= nil) then return end
        local before = #titles
        Dense.look(A, place.x, place.y)
        a.check("looking again gives the first record nothing more", #titles == before)
        Dense.look(B, place.x, place.y)
        local t = titles[#titles]
        a.check("a new character standing there inherits it", Dense.got(B)[place.id] == place.kind, Dense.got(B)[place.id])
        a.check("its title is the 'had' one", #titles == before + 1 and t.detail.key == "IGUI_OA_Title_DenseCleared"
            and t.detail.sub == "IGUI_OA_Title_DenseHadSub", P10T.keys(titles))
        if t and #titles == before + 1 then
            a.say("title reads:", getText(t.detail.key), "|", getText(t.detail.sub, getText(t.detail.subArgs[1].key)))
        end
        a.check("the cleared mark is still the first one's", Dense.cleared(place.id).by == A.id)
        a.check("its shop restocks the kit to 2 too", Shop.restockQuantity(kitEntry, B) == 2)
        before = #titles
        Dense.look(C, place.x, place.y)
        a.check("a record below tier 6 gets nothing", Dense.got(C)[place.id] == nil and #titles == before)
        local far = P10T.scratch(a, "dense_far", 5, 1)
        Dense.look(far, place.x + math.max(Dense.NEAR, place.r) + Dense.NEAR * 3, place.y)
        a.check("a record far from the place gets nothing", Dense.got(far)[place.id] == nil and #titles == before)
    end }
    steps[#steps + 1] = { after = 500, name = "back", run = function()
        P10T.tp(ox, oy, oz)
        a.say("the character is sent back; the zombies made are taken away and the place's marks put back")
    end }
    P10T.run(a, steps)
end)
