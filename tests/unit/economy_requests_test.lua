-- Requests: the groups, the candidate table, the commonness score, the weekly list and its counters, and a list saved
-- before the groups.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
local OA = OperationAcorn
local R = OA.Requests

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

test("the stage opens the rarer items", function()
    truthy(R.eligible(1.0, 0)); truthy(R.eligible(5, 0))
    truthy(not R.eligible(0.99, 0)); truthy(R.eligible(0.99, 1)); truthy(R.eligible(0.3, 1))
    truthy(not R.eligible(0.29, 1)); truthy(R.eligible(0.29, 2))
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

test("the list has 6 items at the start, drawn from the common ones only", function()
    install(40, function(i) return i <= 10 and 2.0 or (i <= 20 and 0.5 or 0.1) end)
    local record = OA.Store.ensure("p", "P")
    local list = R.list(record)
    eq(#list, 6)
    local seen = {}
    for _, t in ipairs(list) do
        local n = tonumber(string.match(t, "%d+"))
        truthy(n <= 10, t .. " is a common item")
        truthy(not seen[t], "no duplicates")
        seen[t] = true
    end
    eq(R.list(record)[1], list[1], "the same list within the week")
end)

test("the list grows with the stage and gains rarer items", function()
    install(40, function(i) return i <= 10 and 2.0 or (i <= 20 and 0.5 or 0.1) end)
    local record = OA.Store.ensure("p", "P")
    local first = {}
    for i, t in ipairs(R.list(record)) do first[i] = t end
    OA.Trust.add(record, 2300)            -- stage 2
    eq(#R.list(record), 6, "trust alone does not lengthen it")
    OA.Support.setLevel(record, "reqcount", 1)   -- the flight support upgrade: 8 items, all scores
    local list = R.list(record)
    eq(#list, 8)
    for i = 1, 6 do eq(list[i], first[i], "the first six stay") end
    OA.Trust.add(record, 3200 + 17500 + 14000 + 21000)   -- up to milestone 2
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

test("the bands: 1 and more is common, 0.3 to 1 normal, less rare, with a price, a quantity and a trust bonus", function()
    eq(R.band(20.9), "common"); eq(R.band(1), "common")
    eq(R.band(0.79), "normal"); eq(R.band(0.3), "normal")
    eq(R.band(0.29), "rare"); eq(R.band(0.08), "rare")
    local b = R.BANDS
    eq(b.common.price, 600); eq(b.common.qty, 10); eq(b.common.trust, 5)
    eq(b.normal.price, 1500); eq(b.normal.qty, 5); eq(b.normal.trust, 10)
    eq(b.rare.price, 4000); eq(b.rare.qty, 3); eq(b.rare.trust, 20)
end)

test("entry gives the fixed price, the week's quantity and what is left of it", function()
    install(10, function() return 2.0 end)
    local record = OA.Store.ensure("p", "P")
    local item = R.list(record)[1]
    local e = R.entry(record, item)
    eq(e.band, "common"); eq(e.price, 600); eq(e.qty, 10); eq(e.trust, 5)
    eq(e.used, 0); eq(e.left, 10); eq(e.full, false)
    R.consume(record, item, 7)
    e = R.entry(record, item)
    eq(e.used, 7); eq(e.left, 3); eq(e.full, false)
    R.consume(record, item, 3)
    e = R.entry(record, item)
    eq(e.left, 0); eq(e.full, true)
    eq(R.entry(record, "Base.NotListed"), nil)
end)

test("an item's band follows its score: 600 x10, 1,500 x5, 4,000 x3", function()
    install(30, function(i) return i <= 10 and 2.0 or (i <= 20 and 0.5 or 0.1) end)
    local record = OA.Store.ensure("p", "P")
    OA.Trust.add(record, 2300)           -- stage 2: every band is drawn
    OA.Support.setLevel(record, "reqcount", 3)   -- all 12
    local seen = { common = false, normal = false, rare = false }
    for _, e in ipairs(R.entries(record)) do
        local n = tonumber(string.match(e.fullType, "%d+"))
        local band = n <= 10 and "common" or (n <= 20 and "normal" or "rare")
        eq(e.band, band, e.fullType)
        eq(e.price, R.BANDS[band].price); eq(e.qty, R.BANDS[band].qty)
        seen[band] = true
    end
    truthy(seen.common and seen.normal and seen.rare, "all three bands on a 12 item list")
end)

test("entries come by band, common first, each band in the order drawn", function()
    install(30, function(i) return i <= 10 and 2.0 or (i <= 20 and 0.5 or 0.1) end)
    local record = OA.Store.ensure("p", "P")
    OA.Trust.add(record, 2300)
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
        { 4, 4 / 3, 800, 2000, 5330 } }
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

test("an item the house loot does not hand out is rare", function()
    install(10, function() return 2.0 end)
    eq(R.scoreOf("Base.Item3"), 2.0)
    eq(R.scoreOf("Base.Harmonica"), 0)
    eq(R.band(R.scoreOf("Base.Harmonica")), "rare")
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

test("the band comes from how the group is come by: charcoal and watermelons are common, so are skill books", function()
    local function bandOf(t) return R.band(R.group(R.keyOf(t)).score) end
    eq(bandOf("Base.CharcoalCrafted"), "common", "a kiln makes twelve from two logs")
    eq(bandOf("Base.Watermelon"), "common", "a farm grows them")
    eq(bandOf("Base.BookCarpentry3"), "common", "any skill book")
    eq(bandOf("Base.TvBlack"), "normal", "a television (of any brand) comes out of a TV crate now and then")
end)

test("a group's price is never below its dearest member's value: a television is 6,000, not 600", function()
    local key = R.keyOf("Base.TvBlack")
    eq(R.floorOf(key), 6000, "10 weight of electronics at 600")
    R.install(R.build({}, infoOf, { R.group(key) }))
    local record = OA.Store.ensure("p", "P")
    eq(R.line(record, key, {}).price, 6000)
    eq(R.floorOf("Base.Nothing"), 0, "a kind no group has has no floor")
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

test("a list saved before the groups is moved to them and keeps what the week settled", function()
    installGroups(5)
    local record = OA.Store.ensure("p", "P")
    local codex = OA.Store.section(record, "codex")
    codex.req = { week = OA.week(), extra = 0, items = { "Base.Charcoal", "Base.Item1", "Base.CharcoalCrafted" },
        used = { ["Base.Charcoal"] = 3, ["Base.CharcoalCrafted"] = 2, ["Base.Item1"] = 1 } }
    codex.reqPin = "Base.CharcoalCrafted"
    OA.Store.upgrade(record)
    local list = R.list(record)
    eq(list[1], "base:charcoal"); eq(list[2], "Base.Item1")
    for i = 3, #list do truthy(list[i] ~= "base:charcoal", "charcoal once") end
    eq(R.used(record)["base:charcoal"], 5, "3 and 2 of its kinds")
    eq(R.used(record)["Base.Item1"], 1)
    eq(R.entry(record, "Base.Charcoal").left, 5)
    eq(codex.reqPin, "base:charcoal")
    eq(codex.req.groups, true)
    codex.req.groups = nil
    codex.req.items = { "Base.CharcoalCrafted" }
    codex.req.used = {}
    eq(R.list(record)[1], "base:charcoal", "a list not upgraded yet is moved when it is read")
end)

test("one appliance of several brands is one group by hand: any television, any radio", function()
    eq(R.keyOf("Base.TvBlack"), "tv"); eq(R.keyOf("Base.TvWideScreen"), "tv"); eq(R.keyOf("Base.TvAntique"), "tv")
    eq(R.keyOf("Base.RadioRed"), "radio"); eq(R.keyOf("Base.RadioMakeShift"), "radio", "a home-made one too")
    eq(R.group("tv").name, "IGUI_OA_ReqGroup_tv")
end)
