-- The lines under an item's tooltip: the request line (price of the band, the flight support's multiplier, the week's
-- count), "not seen before", the mission's first line, how they are cached, and where the strips go.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Requests"
require "OperationAcorn/Economy/ItemTip"
local OA = OperationAcorn
local Tip = OA.ItemTip

-- The world's request table: Pencil common, Thread common, Hammer middling, Ring rare.
local function world()
    OA.Requests.install({ version = 1, types = { "Base.Pencil", "Base.Thread", "Base.Hammer", "Base.Ring" },
        score = { 2.5, 1.2, 0.5, 0.1 }, kinds = {}, total = {}, n = 4 })
end

-- A record with a list for the week, and a reward level for the request price.
local function record(level)
    local r = OA.Store.ensure("t", "T")
    r.trade = { stage = 3, milestones = 0, credits = 0, trust = 0, serial = 1, levels = { reqprice = level or 0 } }
    r.codex = { kinds = {}, n = 0, req = { week = 5, items = { "Base.Pencil", "Base.Hammer", "Base.Ring" }, used = { ["Base.Pencil"] = 7 } } }
    return r
end

-- A script for Value.infoFromScript: only what it reads.
local function script(fullType, display)
    return { getFullName = function() return fullType end, getActualWeight = function() return 0.1 end,
        getDisplayCategory = function() return display or "Junk" end, isItemType = function() return false end }
end

local function scripts(map)
    ItemType = { MOVEABLE = 1 }
    getScriptManager = function() return { FindItem = function(_, t) return map[t] end } end
end

test("a price is the band's, in tens, with the support's multiplier", function()
    local price, count = Tip.band(2.5)
    eq(price, 600)
    eq(count, 10)
    price, count = Tip.band(1)
    eq(price, 600, "a score of 1 is common")
    price, count = Tip.band(0.99)
    eq(price, 1500)
    eq(count, 5)
    price, count = Tip.band(0.3)
    eq(price, 1500, "0.3 is the middle band")
    price, count = Tip.band(0.29)
    eq(price, 4000)
    eq(count, 3)
    eq(Tip.tens(600 * 1.1), 660)
    eq(Tip.tens(1500 * 1.1), 1650)
    eq(Tip.tens(4000 * 1.2), 4800)
    eq(Tip.tens(4000 * 1.33), 5320)
end)

test("an item on the list has its price, the count a week and what is settled", function()
    world()
    local r = record(0)
    local price, count, done = Tip.requestOf(r, "Base.Pencil")
    eq(price, 600)
    eq(count, 10)
    eq(done, 7)
    price, count, done = Tip.requestOf(r, "Base.Ring")
    eq(price, 4000)
    eq(count, 3)
    eq(done, 0)
    eq(Tip.requestOf(r, "Base.Thread"), nil, "a candidate that is not on this week's list")
    eq(Tip.requestOf(r, "Base.Unknown"), nil)
end)

test("the request price level raises the price, and the count settled never passes the count", function()
    world()
    local r = record(1)
    eq((Tip.requestOf(r, "Base.Pencil")), 660)
    eq((Tip.requestOf(r, "Base.Hammer")), 1650)
    r.codex.req.used["Base.Ring"] = 9
    local _, _, done = Tip.requestOf(r, "Base.Ring")
    eq(done, 3)
end)

test("without the world's table or a list there is no request line, and nothing is made or changed", function()
    local r = record(0)
    eq(Tip.requestOf(r, "Base.Pencil"), nil, "no table yet")
    world()
    r.codex.req = nil
    eq(Tip.requestOf(r, "Base.Pencil"), nil, "no list yet: the server draws it, this does not")
    eq(r.codex.req, nil, "the record is not changed")
    eq(Tip.requestOf({}, "Base.Pencil"), nil)
end)

test("the request line says the price, the count settled and the count", function()
    world()
    scripts({})
    local r = record(0)
    local rows = Tip.rows(r, "Base.Pencil", nil)
    eq(#rows, 1)
    eq(rows[1].text, "IGUI_OA_ItemTip_Request 600 7 10")
    eq(rows[1].color, Tip.REQUEST_COLOR)
    r.codex.req.used["Base.Pencil"] = 10
    r.trade.serial = 2
    rows = Tip.rows(r, "Base.Pencil", nil)
    eq(rows[1].text, "IGUI_OA_ItemTip_RequestFull 600 10 10")
    r.trade.levels.reqprice = 3
    r.trade.levelsRev = 1   -- what flight support does with each level
    r.trade.serial = 3
    eq(Tip.rows(r, "Base.Ring", nil)[1].text, "IGUI_OA_ItemTip_Request 5,320 0 3", "thousands as the terminal writes them")
end)

test("a kind the codex has not seen is new, but only a kind the codex counts, and never a bought item", function()
    world()
    scripts({ ["Base.Pen"] = script("Base.Pen"), ["Base.Bruise"] = script("Base.Bruise", "Wound"),
        ["OperationAcorn.Serum"] = script("OperationAcorn.Serum") })
    local r = record(0)
    local rows = Tip.rows(r, "Base.Pen", nil)
    eq(#rows, 1)
    eq(rows[1].text, "IGUI_OA_ItemTip_New")
    eq(rows[1].color, Tip.NEW_COLOR)
    eq(#Tip.rows(r, "Base.Pen", true), 0, "bought from the shop: the codex never counts it")
    eq(#Tip.rows(r, "Base.Bruise", nil), 0, "a wound is no loot")
    eq(#Tip.rows(r, "OperationAcorn.Serum", nil), 0, "this mod's goods are no loot")
    eq(#Tip.rows(r, "Base.NoScript", nil), 0, "a type with no script")
    r.codex.kinds["Pen"] = true
    eq(#Tip.rows(r, "Base.Pen", nil), 0, "seen: the line goes at once")
end)

test("a colour variant is its base kind", function()
    world()
    scripts({ ["Base.Shirt_TINT"] = script("Base.Shirt_TINT") })
    local r = record(0)
    eq(#Tip.rows(r, "Base.Shirt_TINT", nil), 1)
    r.codex.kinds["Shirt"] = true
    eq(#Tip.rows(r, "Base.Shirt_TINT", nil), 0)
end)

test("an item that is both requested and new has two lines, the request first", function()
    world()
    scripts({ ["Base.Hammer"] = script("Base.Hammer") })
    local r = record(0)
    local rows = Tip.rows(r, "Base.Hammer", nil)
    eq(#rows, 2)
    eq(rows[1].text, "IGUI_OA_ItemTip_Request 1,500 0 5")
    eq(rows[2].text, "IGUI_OA_ItemTip_New")
end)

test("an item that is neither has no line", function()
    world()
    scripts({ ["Base.Pen"] = script("Base.Pen") })
    local r = record(0)
    r.codex.kinds["Pen"] = true
    eq(#Tip.rows(r, "Base.Pen", nil), 0)
end)

test("the lines are made once for the same type, week's list and settlements, and again when one changes", function()
    world()
    scripts({ ["Base.Pencil"] = script("Base.Pencil") })
    local calls = 0
    local plain = getText
    getText = function(...) calls = calls + 1 return plain(...) end
    local r = record(0)
    local a = Tip.rows(r, "Base.Pencil", nil)
    local made = calls
    truthy(made > 0)
    for _ = 1, 50 do
        eq(Tip.rows(r, "Base.Pencil", nil), a, "the same lines")
    end
    eq(calls, made, "frames after the first make no text")
    r.codex.kinds["Pencil"] = true
    local b = Tip.rows(r, "Base.Pencil", nil)
    eq(calls, made, "the codex changing is a table lookup, not a new line")
    eq(#b, 1)
    r.trade.serial = 2
    r.codex.req.used["Base.Pencil"] = 8
    local c = Tip.rows(r, "Base.Pencil", nil)
    truthy(calls > made, "a settlement makes it again")
    eq(c[1].text, "IGUI_OA_ItemTip_Request 600 8 10")
    made = calls
    r.codex.req = { week = 6, items = { "Base.Pencil" }, used = {} }
    eq(Tip.rows(r, "Base.Pencil", nil)[1].text, "IGUI_OA_ItemTip_Request 600 0 10", "a new week's list")
    truthy(calls > made)
    made = calls
    table.insert(r.codex.req.items, "Base.Hammer")
    Tip.rows(r, "Base.Pencil", nil)
    truthy(calls > made, "the list grew (a level of the count)")
    made = calls
    local other = OA.Store.ensure("u", "U")
    other.trade = { stage = 3, milestones = 0, serial = 1, levels = {} }
    other.codex = { kinds = {}, req = { week = 6, items = { "Base.Pencil" }, used = {} } }
    Tip.rows(other, "Base.Pencil", nil)
    truthy(calls > made, "another record")
end)

test("the mission's line is one line in the colour it is given, kept for the colour", function()
    local a = Tip.missionRows(OA.StoryView and OA.StoryView.TEAL or { 0.3, 0.9, 0.85 })
    eq(#a, 1)
    eq(a[1].text, "IGUI_OA_ItemTip_Mission")
    eq(Tip.missionRows(a[1].color), a)
    local sky = { 0.55, 0.78, 1.0 }
    truthy(Tip.missionRows(sky) ~= a)
    eq(Tip.missionRows(sky)[1].color, sky)
end)

test("the strips go below the panel and the mission's above, with the room there is", function()
    -- a panel at y 300, 80 high, on a 1080 screen; a strip 26 high
    local topY, bottomY = Tip.place(300, 80, 1080, 0, 0, 26, 52)
    eq(bottomY, 79, "below, overlapping the panel's border by one")
    eq(topY, -25, "above")
    eq(select(2, Tip.place(300, 80, 1080, 0, 0, 0, 26)), 79)
    eq(Tip.place(300, 80, 1080, 0, 0, 0, 26), nil, "no mission strip")
    eq(select(2, Tip.place(300, 80, 1080, 0, 0, 26, 0)), nil, "no lower strip")
end)

test("another strip's room is left to it", function()
    -- the appraisal took 24 below the panel
    local _, bottomY = Tip.place(300, 80, 1080, 0, 24, 0, 26)
    eq(bottomY, 79 + 24)
    -- and 24 above (the panel was at the bottom)
    local topY = Tip.place(300, 80, 1080, 24, 0, 26, 0)
    eq(topY, -(24 + 26) + 1)
end)

test("at the bottom of the screen the request strip goes above, the mission's farther out", function()
    local topY, bottomY = Tip.place(980, 80, 1080, 0, 0, 26, 52)
    eq(bottomY, -52 + 1, "no room below: above, next to the panel")
    eq(topY, -(52 + 26) + 1, "the mission's strip beyond it")
end)

test("at the top of the screen the mission strip goes below, after the others", function()
    local topY, bottomY = Tip.place(10, 80, 1080, 0, 0, 26, 52)
    eq(bottomY, 79)
    eq(topY, 80 + 52 - 1, "no room above")
end)
