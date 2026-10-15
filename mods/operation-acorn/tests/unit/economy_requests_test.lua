-- Requests: the groups, the candidate table, the commonness score, the weekly list and its counters, and a list saved
-- before the groups.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
local OA = OperationAcorn
local R = OA.Requests
local REAL_GROUPS = OA.RequestGroups      -- the generated table (other tests put their own rows in)

-- A tiny set of loot tables in the game's shape.
local function tables()
    local dist = {
        kitchen = {
            counter = { rolls = 1, items = { "Apple", 10, "Pan", 4, "Pan", 2 }, junk = { rolls = 1, items = { "Pencil", 3 } } },
            shelves = { procedural = true, procList = { { name = "Cans", min = 0, max = 2 }, { name = "Tools", min = 0, max = 1 } } },
            fridge = { procedural = true, procList = { { name = "Cans" } } },
        },
        bedroom = { wardrobe = { rolls = 1, items = { "Shirt", 8, "Bullets9mm", 5 } } },
        gunstore = { counter = { rolls = 1, items = { "Pistol", 100 } } },   -- not a house
    }
    local procedural = {
        Cans = { rolls = 1, items = { "TinnedBeans", 20, "Apple", 5 }, junk = { rolls = 1, items = { "Pencil", 1 } } },
        Tools = { rolls = 1, items = { "Hammer", 6 } },
    }
    return dist, procedural
end

local scripts = {
    Apple = { fullType = "Base.Apple", weight = 0.2, displayCategory = "Food" },
    Pan = { fullType = "Base.Pan", weight = 0.5, displayCategory = "Cooking" },
    Pencil = { fullType = "Base.Pencil", weight = 0.01, displayCategory = "Junk" },
    TinnedBeans = { fullType = "Base.TinnedBeans", weight = 0.3, displayCategory = "Food" },
    Hammer = { fullType = "Base.Hammer", weight = 1.0, displayCategory = "Tool" },
    Shirt = { fullType = "Base.Shirt", weight = 0.5, displayCategory = "Clothing" },
    Bullets9mm = { fullType = "Base.Bullets9mm", weight = 0.01, displayCategory = "Ammo" },
    Pistol = { fullType = "Base.Pistol", weight = 1, displayCategory = "Weapon" },
}
local function infoOf(name)
    local s = scripts[name]
    if not s then return nil end
    local t = { fullType = s.fullType, baseType = OA.Categories.baseType(s.fullType), weight = s.weight,
        displayCategory = s.displayCategory }
    return t
end

test("weights sum a list once per container that draws it, junk included", function()
    local dist, procedural = tables()
    local sums = R.weights(dist, procedural)
    eq(sums.Apple, 10 + 5 * 2, "counter 10, and the Cans list drawn by shelves and the fridge")
    eq(sums.Pan, 6, "a name listed twice adds up")
    eq(sums.TinnedBeans, 40)
    eq(sums.Pencil, 3 + 1 * 2, "junk of a container and of a list")
    eq(sums.Hammer, 6)
    eq(sums.Shirt, 8)
    eq(sums.Pistol, nil, "a gun store is no house")
end)

test("build takes the candidates from the groups, with their score and category", function()
    local groups = {
        { id = "base:charcoal", score = 1, wt = 0.8, dc = "Material",
            items = { "Base.Charcoal", "Base.CharcoalCrafted" } },
        { id = "Base.Pan", score = 0.5, wt = 0.5, dc = "Cooking", items = { "Base.Pan" } },
        { id = "n:Gone", score = 3, wt = 1, dc = "Junk", items = { "Base.GoneA", "Base.GoneB" } },
    }
    local function exists(t) return not string.find(t, "Gone", 1, true) end
    local data = R.build({}, infoOf, groups, exists)
    eq(data.n, 2, "a group none of whose kinds the game has is left out")
    eq(data.types[1], "base:charcoal"); eq(data.score[1], 1); eq(data.cat[1], "K")
    eq(data.types[2], "Base.Pan"); eq(data.score[2], 0.5); eq(data.cat[2], "F")
end)

test("kinds list every house loot kind with its category, ammo too", function()
    local dist, procedural = tables()
    local data = R.build(R.weights(dist, procedural), infoOf)
    eq(data.kinds.Apple, "A")
    eq(data.kinds.Bullets9mm, nil, "ammo has no category")
    eq(data.kinds.Hammer, "H")
    eq(data.total.A, 2)       -- Apple, TinnedBeans
    eq(data.total.F, 1)
    eq(data.total.E, 1)
end)

test("a colour variant counts as one kind", function()
    local sums = { CapTINT = 5, CapTINT_Reverse = 3, Cap = 1 }
    local function of(name)
        local full = "Base." .. name
        return { fullType = full, baseType = OA.Categories.baseType(full), weight = 0.3, displayCategory = "Clothing" }
    end
    local data = R.build(sums, of)
    eq(data.total.B, 2, "Cap and Cap_Reverse")
    eq(data.kinds.Cap, "B")
    eq(data.kinds.Cap_Reverse, "B")
end)

test("a name no item has is skipped", function()
    local data = R.build({ Ghost = 5, Apple = 5 }, infoOf)
    eq(data.total.A, 1)
    eq(data.kinds.Ghost, nil)
end)

test("the stage opens the rarer bands", function()
    truthy(R.eligible("common", 0)); truthy(not R.eligible("normal", 0)); truthy(not R.eligible("rare", 0))
    truthy(R.eligible("normal", 1)); truthy(not R.eligible("rare", 1))
    truthy(R.eligible("rare", 2)); truthy(R.eligible("normal", 2))
end)

local function install(count, scoreOf)
    local data = { version = 1, types = {}, score = {}, kinds = {}, total = {}, n = count }
    for i = 1, count do
        data.types[i] = "Base.Item" .. i
        data.score[i] = scoreOf(i)
        data.kinds["Item" .. i] = (i % 2 == 0) and "A" or "B"
    end
    R.install(data)
end

-- Forty items, the lower the number the easier: 1..20 common, 21..34 normal, 35..40 rare (50% / 35% / 15%).
local function falling(i) return 100 - i end
local function bandByNumber(n) return n <= 20 and "common" or (n <= 34 and "normal" or "rare") end

test("the bands go by rank: the easiest half common, the next 35% normal, the last 15% rare", function()
    install(40, falling)
    for i = 1, 40 do eq(R.bandOf("Base.Item" .. i), bandByNumber(i), "Item" .. i) end
    -- Within a band the quantity runs from qtyMax (its easiest) down to qtyMin (its last).
    eq(R.qtyOf("Base.Item1"), R.BANDS.common.qtyMax); eq(R.qtyOf("Base.Item20"), R.BANDS.common.qtyMin)
    eq(R.qtyOf("Base.Item21"), R.BANDS.normal.qtyMax); eq(R.qtyOf("Base.Item34"), R.BANDS.normal.qtyMin)
    eq(R.qtyOf("Base.Item35"), R.BANDS.rare.qtyMax); eq(R.qtyOf("Base.Item40"), R.BANDS.rare.qtyMin)
    for i = 2, 40 do
        local a, b = R.qtyOf("Base.Item" .. (i - 1)), R.qtyOf("Base.Item" .. i)
        if bandByNumber(i) == bandByNumber(i - 1) then truthy(a >= b, "easier never asks fewer: Item" .. i) end
    end
    -- Along the rank squared: the tenth of twenty common asks 5 + 15 x (10/19)^2 = 9.16, so 9.
    eq(R.qtyOf("Base.Item10"), math.floor(5 + 15 * (10 / 19) ^ 2 + 0.5))
end)

test("a band's mean quantity stays what a line used to take: 10, 5 and 3", function()
    install(200, falling)
    local sum, n = { common = 0, normal = 0, rare = 0 }, { common = 0, normal = 0, rare = 0 }
    for i = 1, 200 do
        local key = "Base.Item" .. i
        local band = R.bandOf(key)
        sum[band], n[band] = sum[band] + R.qtyOf(key), n[band] + 1
    end
    eq(n.common, 100); eq(n.normal, 70); eq(n.rare, 30)
    for _, band in ipairs(R.BAND_ORDER) do
        local mean = sum[band] / n[band]
        truthy(math.abs(mean - R.BANDS[band].qty) < 0.6, band .. " mean " .. mean)
    end
end)

test("groups of an equal score are never told apart: they take the first one's band and quantity", function()
    install(4, function() return 1.0 end)
    for i = 1, 4 do
        eq(R.bandOf("Base.Item" .. i), "common"); eq(R.qtyOf("Base.Item" .. i), R.BANDS.common.qtyMax)
    end
    install(6, function(i) return i <= 2 and 5 or 1 end)   -- 3 common by share; the four of score 1 tie at the 3rd
    for i = 3, 6 do eq(R.bandOf("Base.Item" .. i), "common", "Item" .. i) end
    eq(R.qtyOf("Base.Item6"), R.qtyOf("Base.Item3"))
end)

test("the list has 6 items at the start, drawn from the common ones only", function()
    install(40, falling)
    local record = OA.Store.ensure("p", "P")
    local list = R.list(record)
    eq(#list, 6)
    local seen = {}
    for _, t in ipairs(list) do
        local n = tonumber(string.match(t, "%d+"))
        truthy(n <= 20, t .. " is a common item")
        truthy(not seen[t], "no duplicates")
        seen[t] = true
    end
    eq(R.list(record)[1], list[1], "the same list within the week")
end)

test("the list grows with the stage and gains rarer items", function()
    install(40, falling)
    local record = OA.Store.ensure("p", "P")
    local first = {}
    for i, t in ipairs(R.list(record)) do first[i] = t end
    OA.Trust.add(record, 700)             -- stage 2
    eq(#R.list(record), 6, "trust alone does not lengthen it")
    OA.Support.setLevel(record, "reqcount", 1)   -- the flight support upgrade: 8 items, all scores
    local list = R.list(record)
    eq(#list, 8)
    for i = 1, 6 do eq(list[i], first[i], "the first six stay") end
    OA.Trust.add(record, 5800 - 700)                     -- up to milestone 2
    OA.Support.setLevel(record, "reqcount", 3)           -- 12 items
    eq(#R.list(record), 12)
end)

test("the list changes when the week does", function()
    install(60, function() return 2.0 end)
    local record = OA.Store.ensure("p", "P")
    local week0 = {}
    for i, t in ipairs(R.list(record)) do week0[i] = t end
    R.consume(record, week0[1], 5)
    eq(R.used(record)[week0[1]], 5)
    TEST.hours = 24 * 7 + 1
    local week1 = R.list(record)
    eq(#week1, 6)
    local same = 0
    for i = 1, 6 do if week1[i] == week0[i] then same = same + 1 end end
    truthy(same < 6, "a new draw")
    eq(R.used(record)[week0[1]], nil, "the counters start over")
end)

test("the categories the team wants at the stage are twice as likely", function()
    -- Stage 1 wants B and G. 20 B items against 20 A items: B should show about twice as often.
    install(40, function() return 2.0 end)
    local record = OA.Store.ensure("p", "P")
    record.trade = { stage = 1, milestones = 0 }
    local b, a = 0, 0
    for week = 0, 199 do
        TEST.hours = week * 24 * 7 + 1
        for _, t in ipairs(R.list(record)) do
            local n = tonumber(string.match(t, "%d+"))
            if n % 2 == 1 then b = b + 1 else a = a + 1 end
        end
    end
    truthy(b > a * 1.5 and b < a * 2.6, "B " .. b .. " vs A " .. a)
end)

test("the bands' prices, mean quantities and trust bonuses", function()
    local b = R.BANDS
    eq(b.common.price, 600); eq(b.common.qty, 10); eq(b.common.trust, 5)
    eq(b.normal.price, 1500); eq(b.normal.qty, 5); eq(b.normal.trust, 10)
    eq(b.rare.price, 4000); eq(b.rare.qty, 3); eq(b.rare.trust, 20)
    eq(b.common.qtyMin, 5); eq(b.common.qtyMax, 20)
    near(R.BAND_SHARE.common, 0.5, 1e-9); near(R.BAND_SHARE.normal, 0.35, 1e-9)
end)

test("entry gives the fixed price, the week's quantity and what is left of it", function()
    install(10, function(i) return 20 - i end)
    local record = OA.Store.ensure("p", "P")
    local item = R.list(record)[1]
    local e = R.entry(record, item)
    local qty = R.qtyOf(item)
    eq(e.band, "common"); eq(e.price, 600); eq(e.qty, qty); eq(e.trust, 5)
    eq(e.used, 0); eq(e.left, qty); eq(e.full, false)
    R.consume(record, item, qty - 3)
    e = R.entry(record, item)
    eq(e.used, qty - 3); eq(e.left, 3); eq(e.full, false)
    R.consume(record, item, 3)
    e = R.entry(record, item)
    eq(e.left, 0); eq(e.full, true)
    eq(R.entry(record, "Base.NotListed"), nil)
end)

test("an item's band follows its rank: 600, 1,500 and 4,000 a unit, its quantity by its rank", function()
    install(40, falling)
    local record = OA.Store.ensure("p", "P")
    OA.Trust.add(record, 700)            -- stage 2: every band is drawn
    OA.Support.setLevel(record, "reqcount", 3)   -- all 12
    local seen = { common = false, normal = false, rare = false }
    for _ = 1, 20 do
        TEST.hours = (TEST.hours or 0) + 24 * 7
        for _, e in ipairs(R.entries(record)) do
            local band = bandByNumber(tonumber(string.match(e.fullType, "%d+")))
            eq(e.band, band, e.fullType)
            eq(e.price, R.BANDS[band].price); eq(e.qty, R.qtyOf(e.key))
            seen[band] = true
        end
    end
    truthy(seen.common and seen.normal and seen.rare, "all three bands drawn")
end)

test("a line keeps the band and quantity it was drawn with for the week, whatever the table does", function()
    install(40, falling)
    local record = OA.Store.ensure("p", "P")
    local item = R.list(record)[1]
    local before = R.entry(record, item)
    install(40, function(i) return i end)          -- the table turned upside down: item is now rare
    eq(R.bandOf(item), "rare")
    local e = R.entry(record, item)
    eq(e.band, before.band); eq(e.qty, before.qty)
    TEST.hours = 24 * 7 + 1
    for _, key in ipairs(R.list(record)) do eq(R.entry(record, key).band, "common", "next week draws by the new table") end
end)

test("entries come by band, common first, each band in the order drawn", function()
    install(40, falling)
    local record = OA.Store.ensure("p", "P")
    OA.Trust.add(record, 700)
    OA.Support.setLevel(record, "reqcount", 3)
    local rank = { common = 1, normal = 2, rare = 3 }
    local last = 0
    local list = R.entries(record)
    eq(#list, 12)
    for _, e in ipairs(list) do
        truthy(rank[e.band] >= last, "bands only go up")
        last = rank[e.band]
    end
end)

test("the request price reward multiplies the price, to ten credits", function()
    install(10, function() return 2.0 end)
    local record = OA.Store.ensure("p", "P")
    eq(R.unitPrice(record, "common"), 600); eq(R.unitPrice(record, "normal"), 1500); eq(R.unitPrice(record, "rare"), 4000)
    local want = { { 1, 1.0, 600, 1500, 4000 }, { 2, 1.1, 660, 1650, 4400 }, { 3, 1.2, 720, 1800, 4800 },
        { 4, 1.3, 780, 1950, 5200 } }
    for _, w in ipairs(want) do
        OA.Support.setLevel(record, "reqprice", w[1] - 1)
        near(OA.Trust.rewards(record).requestPrice, w[2], 1e-9)
        eq(R.unitPrice(record, "common"), w[3], "common at x" .. w[2])
        eq(R.unitPrice(record, "normal"), w[4])
        eq(R.unitPrice(record, "rare"), w[5])
    end
    SandboxVars.OperationAcorn.RequestPrice = 50
    OA.Trust.reset()
    OA.Support.setLevel(record, "reqprice", 0)
    eq(R.unitPrice(record, "common"), 300, "the option scales the price")
end)

test("an item the house loot does not hand out is rare, at the band's usual quantity", function()
    install(10, function() return 2.0 end)
    eq(R.scoreOf("Base.Item3"), 2.0)
    eq(R.scoreOf("Base.Harmonica"), 0)
    eq(R.bandOf("Base.Harmonica"), "rare")
    eq(R.qtyOf("Base.Harmonica"), R.BANDS.rare.qty)
end)

test("a refused category is left out, and comes back two to a list when due", function()
    install(40, function() return 2.0 end)
    local record = OA.Store.ensure("p", "P")
    OA.randomFloat = function() return 0 end
    OA.Market.update(0)
    local st = OA.Market.state()
    st.refused.A = 100
    TEST.hours = 24 * 7 + 1
    for _, t in ipairs(R.list(record)) do
        truthy(tonumber(string.match(t, "%d+")) % 2 == 1, "no A items while A is refused")
    end
    st.refused.A = nil
    st.due = { { cat = "A", day = 21 } }
    TEST.hours = 24 * 7 * 3 + 1
    local list = R.list(record)
    eq(OA.week(), 3)
    local a = 0
    for i = 1, 2 do if tonumber(string.match(list[i], "%d+")) % 2 == 0 then a = a + 1 end end
    eq(a, 2, "the first two are the returning category")
end)

test("a pinned item leads next week's list", function()
    install(40, function() return 2.0 end)
    local record = OA.Store.ensure("p", "P")
    R.list(record)
    R.pinNext(record, "Base.Item39")
    TEST.hours = 24 * 7 + 1
    local list = R.list(record)
    eq(list[1], "Base.Item39")
    eq(#list, 6)
end)

test("the table is built once and kept in the world save", function()
    install(5, function() return 1 end)
    local data = R.data()
    eq(data.n, 5)
    eq(OA.Store.world("requests").n, 5)
    eq(R.kindCategory("Item2"), "A")
    eq(R.kindCategory("Nothing"), nil)
    eq(R.categoryTotal("B"), 0, "no totals installed")
end)

-- The groups made from the game's files (RequestGroups.lua) -----------------------------------------------------

test("a group is one level above the item type: a narrow tag, the book families, a variant", function()
    eq(R.keyOf("Base.Charcoal"), "base:charcoal")
    eq(R.keyOf("Base.CharcoalCrafted"), "base:charcoal", "the kiln's charcoal is the looted charcoal's group")
    eq(R.keyOf("Base.BookCarpentry1"), "skillbook")
    eq(R.keyOf("Base.BookFirstAid5"), "skillbook", "any skill, any volume")
    eq(R.keyOf("Base.Book"), "books")
    eq(R.keyOf("Base.Paperback"), "books", "hardcover and softcover together")
    eq(R.keyOf("Base.Book_MilitaryHistory"), "books")
    eq(R.keyOf("Base.BookFancy_Bible"), "books", "the leather-bound ones too")
    eq(R.keyOf("Base.Magazine"), "reading")
    eq(R.keyOf("Base.ComicBook"), "reading")
    eq(R.keyOf("Base.ChessBlack"), R.keyOf("Base.ChessWhite"), "black and white chess pieces")
    eq(R.keyOf("Base.Shirt_Bowling_Blue"), R.keyOf("Base.Shirt_Bowling_Pink"), "a bowling shirt of any colour")
    eq(R.keyOf("Base.Harmonica"), "Base.Harmonica", "a kind on its own is its own group")
end)

test("the bras are underwear however vanilla's names misspell them; the hide bra is not", function()
    local key = R.keyOf("Base.Bra_Strapless_White")
    eq(key, "underwear")
    for _, t in ipairs({ "Base.Bra_Strapless_Black", "Base.Bra_Strapless_AnimalPrint", "Base.Bra_Strapless_RedSpots",
        "Base.Bra_Strapless_FrillyBlack", "Base.Bra_Strapless_FrillyPink", "Base.Bra_Strapless_FrillyRed",
        "Base.Bra_Straps_Black", "Base.Briefs_White", "Base.Boxers_White" }) do
        eq(R.keyOf(t), key, t)
    end
    truthy(R.keyOf("Base.Bra_Strapless_Hide") ~= key, "made from raw hide: never a family's (MAKESHIFT)")
    eq(R.group(key).name, "IGUI_OA_ReqGroup_underwear")
end)

test("a family is one ordinary noun above the kinds: any can, any ball, any hat", function()
    for _, t in ipairs({ "Base.CannedPeas", "Base.CannedCarrots2", "Base.TinnedBeans", "Base.TunaTin",
        "Base.MysteryCan", "Base.CannedMilk" }) do
        eq(R.keyOf(t), "cans", t)
    end
    truthy(R.keyOf("Base.CannedPeasOpen") ~= "cans", "an opened tin is not the thing bought")
    truthy(R.keyOf("Base.Dogfood") ~= "cans", "a tin of dog food is pet food")
    eq(R.keyOf("Base.CannedCarrots"), "jarred", "a home-canned jar is not a tin")
    eq(R.keyOf("Base.CannedPeas_Box"), "cannedbox", "a box of twelve tins is a store's stock")
    for _, t in ipairs({ "Base.SoccerBall", "Base.Baseball", "Base.Basketball", "Base.GolfBall", "Base.TennisBall" }) do
        eq(R.keyOf(t), "balls", t)
    end
    eq(R.keyOf("Base.Icecream"), "icecream"); eq(R.keyOf("Base.Popsicle"), "icecream")
    eq(R.keyOf("Base.Hat_BaseballCap"), "hats"); eq(R.keyOf("Base.Hat_Beret"), "hats")
    truthy(R.keyOf("Base.Hat_HardHat") ~= "hats", "a hard hat is a helmet")
    eq(R.group("hats").dc, "Accessory", "a few keepsake hats do not make the hats keepsakes")
    eq(R.iconType("cans"), "Base.TinnedBeans")
end)

test("any member of a family fills its line, and the units of all its kinds count together", function()
    R.useGroups({
        { id = "cans", score = 3, wt = 0.8, dc = "Food", name = "IGUI_OA_ReqGroup_cans",
            items = { "Base.CannedPeas", "Base.CannedCarrots2", "Base.TinnedBeans" } },
        { id = "Base.Item1", score = 2, wt = 0.1, dc = "Junk", items = { "Base.Item1" } },
    })
    R.install(R.build({}, infoOf, OA.RequestGroups))
    local record = OA.Store.ensure("p", "P")
    OA.Support.setLevel(record, "reqcount", 3)
    local e = R.entry(record, "Base.CannedCarrots2")
    truthy(e, "the family is on the list")
    eq(e.key, "cans")
    eq(R.entry(record, "Base.CannedPeas").key, "cans", "one line for all its kinds")
    R.consume(record, R.keyOf("Base.CannedPeas"), 4)
    R.consume(record, R.keyOf("Base.TinnedBeans"), 3)
    eq(R.entry(record, "Base.CannedCarrots2").used, 7, "peas and beans fill the same line")
    eq(R.memberNames("cans")[3], "Base.TinnedBeans", "the tooltip lists the kinds")
    R.useGroups(REAL_GROUPS)
end)

test("a saved list holding the old variant ids moves to their family, once, the settled units summed", function()
    R.useGroups(REAL_GROUPS)
    R.install(R.build({}, infoOf, REAL_GROUPS))
    local record = OA.Store.ensure("p", "P")
    local codex = OA.Store.section(record, "codex")
    codex.req = { week = OA.week(), extra = 0, groups = true,
        items = { "n:Canned_Peas", "Base.Harmonica", "n:Canned_Carrots", "Base.TunaTin" },
        used = { ["n:Canned_Peas"] = 2, ["n:Canned_Carrots"] = 3, ["Base.TunaTin"] = 1, ["Base.Harmonica"] = 1 },
        strange = "n:Canned_Carrots" }
    codex.reqPin = "n:Canned_Tuna"
    local list = R.list(record)
    eq(list[1], "cans", "the first old id's place is kept")
    eq(list[2], "Base.Harmonica")
    local n = 0
    for _, key in ipairs(list) do if key == "cans" then n = n + 1 end end
    eq(n, 1, "three old lines are one family line")
    eq(R.used(record)["cans"], 6, "2 + 3 + 1")
    eq(R.used(record)["n:Canned_Peas"], nil, "the old keys are gone")
    eq(codex.req.strange, "cans")
    eq(codex.reqPin, "cans")
    eq(R.entry(record, "Base.CannedTomato2").used, 6, "found by any can")
    R.useGroups(REAL_GROUPS)
end)

test("a group's name is the shortest name the others have inside them, else what they share", function()
    R.useGroups({
        { id = "n:Mugs", score = 1, wt = 0.1, dc = "Cooking", items = { "Base.M1", "Base.M2", "Base.M3" } },
        { id = "n:Boards", score = 1, wt = 0.1, dc = "Cooking", items = { "Base.B1", "Base.B2" } },
        { id = "n:Mixed", score = 1, wt = 0.1, dc = "Cooking", items = { "Base.X1", "Base.X2" } },
    })
    local names = { ["Base.M1"] = "Mug [Red]", ["Base.M2"] = "Red Mug [Hot]", ["Base.M3"] = "Mug ]",
        ["Base.B1"] = "Plastic Board", ["Base.B2"] = "Wooden Board", ["Base.X1"] = "Foo [A", ["Base.X2"] = "Bar" }
    local was = getItemNameFromFullType
    getItemNameFromFullType = function(t) return names[t] end
    eq(R.nameOf("n:Mugs"), "Mug", "less the variant and the stray bracket")
    eq(R.nameOf("n:Boards"), "Board", "no name inside the other: the words they end with")
    eq(R.nameOf("n:Mixed"), "Foo A", "a bracket never closed is dropped; nothing in common: the first kind's")
    getItemNameFromFullType = was
end)

test("the ids the table dropped are kept in the group that took them over", function()
    local ids, items = {}, {}
    for _, row in ipairs(REAL_GROUPS) do
        ids[row.id] = true
        for _, t in ipairs(row.items) do items[t] = true end
    end
    local n = 0
    for _, row in ipairs(REAL_GROUPS) do
        for _, old in ipairs(row.was or {}) do
            n = n + 1
            truthy(not ids[old], old .. " is still a group of its own")
            truthy(not items[old], old .. " is a kind (its group is found by the kind)")
        end
    end
    truthy(n > 0, "some groups were joined")
    R.useGroups(REAL_GROUPS)
    eq(R.keyOf("n:Bra_Strapless_"), "underwear", "an id two tables old (the frilly strapless bras') still finds it")
    eq(R.keyOf("n:Bra_Strapless"), "underwear", "the variant group's id finds its family")
    eq(R.keyOf("n:Nothing_Like_It"), "n:Nothing_Like_It", "an id nobody knows stays what it is")
end)

test("a saved week's list with ids the table no longer has is moved to their groups, nothing dropped", function()
    R.useGroups(REAL_GROUPS)
    R.install(R.build({}, infoOf, REAL_GROUPS))
    local record = OA.Store.ensure("p", "P")
    local codex = OA.Store.section(record, "codex")
    codex.req = { week = OA.week(), extra = 0, groups = true,
        items = { "Base.Bra_Strapless_Black", "n:Bra_Strapless_", "Base.Harmonica", "n:Bra_Strapless" },
        used = { ["Base.Bra_Strapless_Black"] = 2, ["n:Bra_Strapless_"] = 3, ["Base.Harmonica"] = 1 },
        strange = "n:Bra_Strapless_" }
    codex.reqPin = "n:Bra_Strapless_"
    local list = R.list(record)
    eq(list[1], "underwear", "the old kind's place is kept")
    eq(list[2], "Base.Harmonica")
    local n = 0
    for _, key in ipairs(list) do if key == "underwear" then n = n + 1 end end
    eq(n, 1, "the three ids are one group, once")
    eq(R.used(record)["underwear"], 5, "what the week settled of each adds up")
    eq(R.used(record)["Base.Harmonica"], 1)
    eq(codex.req.strange, "underwear")
    eq(codex.reqPin, "underwear")
    eq(R.entry(record, "Base.Bra_Strapless_FrillyRed").used, 5, "found by any kind of the group")
    eq(R.entry(record, "n:Bra_Strapless_").left, R.entry(record, "n:Bra_Strapless").left, "and by the old id")
    R.useGroups(REAL_GROUPS)
end)

test("what is left out is in no group: keys, maps, specimens, hollow books, newspapers, cartons", function()
    for _, t in ipairs({ "Base.Key1", "Base.CarKey", "Base.MuldraughMap", "Base.Specimen_MonkeyHead",
        "Base.HollowBook", "Base.Newspaper", "Base.NailsCarton", "Base.Photo", "Base.IDcard" }) do
        eq(R.group(R.keyOf(t)), nil, t)
    end
end)

test("every kind is in one group at most, and every group takes something", function()
    local seen, ids = {}, {}
    for _, row in ipairs(OA.RequestGroups) do
        truthy(not ids[row.id], "one row for " .. row.id)
        ids[row.id] = true
        truthy(#row.items > 0, row.id .. " takes something")
        for _, t in ipairs(row.items) do
            truthy(not seen[t], t .. " is in " .. tostring(seen[t]) .. " and " .. row.id)
            seen[t] = row.id
        end
    end
end)

test("the band comes from every way a group is come by, ranked: kiln charcoal and any tin are common", function()
    R.useGroups(REAL_GROUPS)
    R.install(R.build({}, infoOf, REAL_GROUPS))
    local function bandOf(t) return R.bandOf(R.keyOf(t)) end
    eq(bandOf("Base.CharcoalCrafted"), "common", "a kiln makes twelve from two logs")
    eq(bandOf("Base.BookCarpentry3"), "common", "any skill book")
    eq(bandOf("Base.CannedPeas"), "common", "any tin")
    eq(bandOf("Base.Watermelon"), "normal", "a garden grows a few, slowly; houses have some")
    eq(bandOf("Base.TvBlack"), "normal", "any television")
    -- A family turns up more than any one of its kinds would: the cans rank above the beans tin on its own did.
    truthy(R.qtyOf("cans") >= R.qtyOf(R.keyOf("Base.Charcoal")), "cans ask at least as many as charcoal")
    local counts = { common = 0, normal = 0, rare = 0 }
    for _, row in ipairs(REAL_GROUPS) do counts[R.bandOf(row.id)] = counts[R.bandOf(row.id)] + 1 end
    -- The shares, but a group as easy as the last one in a band joins it (the table has such ties at its cuts).
    local scores = {}
    for i, row in ipairs(REAL_GROUPS) do scores[i] = row.score end
    table.sort(scores, function(a, b) return a > b end)
    local function upTo(cut)
        local k = cut
        while scores[k + 1] == scores[cut] do k = k + 1 end
        return k
    end
    local n = #REAL_GROUPS
    eq(counts.common, upTo(math.floor(n * 0.5 + 0.5)))
    eq(counts.common + counts.normal, upTo(math.floor(n * 0.85 + 0.5)))
end)

-- A script manager that knows the given types ({ fullType = { w, dc } }; `all` for any type, 0.1 of junk).
local function scriptsOf(made, all)
    ItemType = ItemType or { MOVEABLE = 1 }
    return function()
        return { FindItem = function(_, t)
            local s = made[t] or (all and { w = 0.1, dc = "Junk" })
            if not s then return nil end
            return { getFullName = function() return t end, getActualWeight = function() return s.w end,
                getDisplayCategory = function() return s.dc end, isItemType = function() return false end }
        end }
    end
end

test("each kind of a group is paid its own worth: a television 6,000, a radio its own, never the dearest's", function()
    -- Scripts: a big television (10 weight of electronics, 6,000) and a small radio (0.5 weight, 300) in one group.
    local was = getScriptManager
    getScriptManager = scriptsOf({ ["Base.TvX"] = { w = 10, dc = "Electronics" },
        ["Base.RadioX"] = { w = 0.5, dc = "Electronics" } })
    R.useGroups({ { id = "sets", score = 1, wt = 10, dc = "Electronics", items = { "Base.TvX", "Base.RadioX" } } })
    eq(R.worthOf("Base.TvX"), 6000, "10 weight of electronics at 600")
    eq(R.worthOf("Base.RadioX"), 300)
    eq(R.worthOf("Base.Nothing"), 0, "a kind with no script is worth nothing by weight")
    R.install(R.build({}, infoOf, OA.RequestGroups))
    local record = OA.Store.ensure("p", "P")
    local line = R.line(record, "sets", {})
    eq(line.price, 600, "the band's price"); eq(line.priceMin, 600, "the radio fetches the band's price")
    eq(line.priceMax, 6000, "the television its own worth")
    eq(R.priceOf(line, R.worthOf("Base.RadioX")), 600)
    eq(R.priceOf(line, R.worthOf("Base.TvX")), 6000)
    OA.Support.setLevel(record, "reqprice", 1)   -- x1.1
    line = R.line(record, "sets", {})
    eq(R.priceOf(line, 300), 660); eq(R.priceOf(line, 6000), 6600, "the reward multiplies its own worth too")
    getScriptManager = was
    R.forget()
    R.useGroups(REAL_GROUPS)
end)

test("a group's name: the family's text, the words its kinds' names start with, or the first kind's", function()
    R.useGroups({
        { id = "skillbook", score = 5, wt = 1, dc = "SkillBook", name = "IGUI_OA_ReqGroup_skillbook",
            items = { "Base.B1" } },
        { id = "n:Bowling_Shirt", score = 1, wt = 0.2, dc = "Clothing", items = { "Base.SB", "Base.SP" } },
        { id = "n:Chess", score = 1, wt = 0.1, dc = "Entertainment", items = { "Base.CB", "Base.CW" } },
        { id = "base:charcoal", score = 1, wt = 0.8, dc = "Material",
            items = { "Base.Charcoal", "Base.CharcoalCrafted" } },
    })
    local names = { ["Base.SB"] = "Bowling Shirt - Blue", ["Base.SP"] = "Bowling Shirt - Pink",
        ["Base.CB"] = "Chess Piece [Black]", ["Base.CW"] = "Chess Piece [White]",
        ["Base.Charcoal"] = "Charcoal", ["Base.CharcoalCrafted"] = "Wood Charcoal", ["Base.Lone"] = "Lamp [On]" }
    getItemNameFromFullType = function(t) return names[t] end
    eq(R.nameOf("skillbook"), "IGUI_OA_ReqGroup_skillbook")
    eq(R.nameOf("n:Bowling_Shirt"), "Bowling Shirt")
    eq(R.nameOf("n:Chess"), "Chess Piece")
    eq(R.nameOf("base:charcoal"), "Charcoal", "no words in common: the first kind's name")
    eq(R.nameOf("Base.Lone"), "Lamp", "a kind on its own, less its variant")
    local list = R.memberNames("base:charcoal")
    eq(#list, 2); eq(list[2], "Wood Charcoal")
    eq(R.iconType("base:charcoal"), "Base.Charcoal")
end)

-- A world of groups for the list tests: charcoal (two kinds) and plain kinds.
local function installGroups(count)
    local rows = { { id = "base:charcoal", score = 2, wt = 0.8, dc = "Material",
        items = { "Base.Charcoal", "Base.CharcoalCrafted" } } }
    for i = 1, count do
        rows[#rows + 1] = { id = "Base.Item" .. i, score = 2, wt = 0.1, dc = "Junk", items = { "Base.Item" .. i } }
    end
    R.useGroups(rows)
    R.install(R.build({}, infoOf, rows))
end

test("a group is on a week's list once, even when the pin and the strange item are of it", function()
    installGroups(3)
    local record = OA.Store.ensure("p", "P")
    R.list(record)
    R.pinNext(record, "Base.CharcoalCrafted")
    OA.Story = { strangeItem = function() return "Base.Charcoal" end }
    TEST.hours = 24 * 7 + 1
    local list = R.list(record)
    eq(list[1], "base:charcoal", "the pinned kind's group leads")
    local n = 0
    for _, key in ipairs(list) do if key == "base:charcoal" then n = n + 1 end end
    eq(n, 1)
    eq(#list, 4, "the three other groups and charcoal: nothing twice")
    OA.Story = nil
end)

test("charcoal from the kiln is a line of the charcoal request", function()
    installGroups(10)
    local record = OA.Store.ensure("p", "P")
    OA.Support.setLevel(record, "reqcount", 3)
    local e = R.entry(record, "Base.CharcoalCrafted")
    truthy(e, "the group is on the list")
    eq(e.key, "base:charcoal")
    R.consume(record, e.key, 4)
    eq(R.entry(record, "Base.Charcoal").used, 4, "the looted and the made kind count together")
end)

test("one appliance of several brands is one group by hand: any television, any radio", function()
    eq(R.keyOf("Base.TvBlack"), "tv"); eq(R.keyOf("Base.TvWideScreen"), "tv"); eq(R.keyOf("Base.TvAntique"), "tv")
    eq(R.keyOf("Base.RadioRed"), "radio"); eq(R.keyOf("Base.RadioMakeShift"), "radio", "a home-made one too")
    eq(R.group("tv").name, "IGUI_OA_ReqGroup_tv")
end)
