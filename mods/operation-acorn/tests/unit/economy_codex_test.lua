-- Codex: first finds, kind and category milestones, searched buildings, kills; credits into trade.bonus.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Codex"
local OA = OperationAcorn
local C = OA.Codex

local function kind(i, display)
    return { fullType = "Base.Thing" .. i, baseType = "Thing" .. i, weight = 0.1, displayCategory = display or "Junk" }
end

-- No house loot table: kinds count, but no category completes.
local function noTable()
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
end

-- A record whose character has used the terminal (the first contact): the codex pays and the kills count.
local function contact(r)
    OA.Trust.section(r).stage = math.max(1, OA.Trust.section(r).stage)
    return r
end

local function record()
    return contact(OA.Store.ensure("c", "C"))
end

test("a kind pays 100 credits once", function()
    noTable()
    local r = record()
    local new, events = C.acquire(r, kind(1))
    truthy(new)
    eq(#events, 0)
    near(r.trade.bonus, 100)
    new = C.acquire(r, kind(1))
    eq(new, false)
    near(r.trade.bonus, 100, 1e-9, "no second time")
    eq(r.codex.n, 1)
end)

test("colour variants count as one kind", function()
    noTable()
    local r = record()
    local a = { fullType = "Base.CapTINT", baseType = "Cap", weight = 0.3, displayCategory = "Clothing" }
    local b = { fullType = "Base.CapTINT", baseType = "Cap", weight = 0.3, displayCategory = "Clothing" }
    truthy(C.acquire(r, a))
    eq(C.acquire(r, b), false)
    eq(r.codex.n, 1)
end)

test("what is no loot is not counted", function()
    noTable()
    local r = record()
    eq(C.acquire(r, { fullType = "Base.ZedDmg_Cut", baseType = "ZedDmg_Cut", weight = 0, displayCategory = "ZedDmg" }), false)
    eq(C.acquire(r, { fullType = "Base.Hammer", baseType = "Hammer", weight = 1, displayCategory = "Tool", bought = true }), false)
    eq(C.acquire(r, { fullType = "OperationAcorn.SampleBundle", baseType = "OperationAcorn.SampleBundle", weight = 0.1,
        displayCategory = "Junk", own = "SampleBundle" }), false)
    eq(r.codex.n, 0)
    truthy(C.acquire(r, { fullType = "Base.Bullets9mm", baseType = "Bullets9mm", weight = 0.01, displayCategory = "Ammo" }),
        "ammo is a kind the codex counts")
end)

test("100 kinds pay 10,000 and the milestone is told once", function()
    noTable()
    local r = record()
    local told = {}
    OA.Sync.listen("title", function(id, detail) table.insert(told, detail) end)
    local events
    for i = 1, 100 do
        local _, e = C.acquire(r, kind(i))
        if #e > 0 then events = e end
    end
    near(r.trade.bonus, 100 * 100 + 10000)
    eq(events[1].kind, "Kinds"); eq(events[1].count, 100); eq(events[1].credits, 10000)
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_CodexKinds")
    eq(told[1].args[1], 100)
    eq(told[1].style, "discovery")
    eq(told[1].sub, "IGUI_OA_Title_Bonus")
    eq(told[1].subArgs[1], 10000)
    eq(r.codex.paid.kinds, 1)
end)

test("kind milestones and the shared serums at 500, 1,000 and 1,500", function()
    noTable()
    local r = record()
    for i = 1, 1500 do C.acquire(r, kind(i)) end
    local bonus = 1500 * 100 + 10000 + 25000 + 50000 + 100000 + 150000 + 225000 + 300000
    near(r.trade.bonus, bonus)
    eq(r.trade.sharedSerums, 3)
    eq(r.codex.paid.kinds, 7)
    C.acquire(r, kind(1501))
    eq(r.codex.paid.kinds, 7, "nothing past 1,500")
end)

test("BonusMultiplier scales the credits, not the serums", function()
    SandboxVars.OperationAcorn.BonusMultiplier = 0.5
    noTable()
    local r = record()
    for i = 1, 500 do C.acquire(r, kind(i)) end
    near(r.trade.bonus, (500 * 100 + 10000 + 25000 + 50000) * 0.5)
    eq(r.trade.sharedSerums, 1)
    SandboxVars.OperationAcorn.BonusMultiplier = 0
    local r2 = contact(OA.Store.ensure("z", "Z"))
    C.acquire(r2, kind(9999))
    near(r2.trade.bonus, 0)
end)

test("a category pays at half and at nine tenths of its house loot kinds", function()
    -- 10 kinds in category E: 5 pay 10,000, 9 pay 30,000.
    local kinds, total = {}, { E = 10 }
    for i = 1, 10 do kinds["Thing" .. i] = "E" end
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = kinds, total = total, n = 0 })
    local r = record()
    for i = 1, 4 do C.acquire(r, kind(i)) end
    near(r.trade.bonus, 4 * 100)
    local _, events = C.acquire(r, kind(5))
    near(r.trade.bonus, 5 * 100 + 50000)
    eq(events[1].kind, "Category"); eq(events[1].letter, "E"); eq(events[1].index, 1)
    for i = 6, 8 do C.acquire(r, kind(i)) end
    near(r.trade.bonus, 8 * 100 + 50000)
    _, events = C.acquire(r, kind(9))
    near(r.trade.bonus, 9 * 100 + 50000 + 150000)
    C.acquire(r, kind(10))
    near(r.trade.bonus, 10 * 100 + 200000, 1e-6, "no third payment")
    local have, all = C.categoryProgress(r, "E")
    eq(have, 10); eq(all, 10)
end)

test("a kind that is not house loot does not count toward a category", function()
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = { Thing1 = "E" }, total = { E = 1 }, n = 0 })
    local r = record()
    C.acquire(r, kind(2))
    eq(r.codex.cat.E, nil)
    C.acquire(r, kind(1))
    eq(r.codex.cat.E, 1)
    near(r.trade.bonus, 200 + 50000 + 150000, 1e-6, "one of one is both steps")
end)

test("a building searched pays 100 plus 10 a container, however big", function()
    noTable()
    local r = record()
    local credits = C.buildingSearched(r, "b1", 15)
    eq(credits, 250)
    near(r.trade.bonus, 250)
    eq(C.buildingSearched(r, "b1", 15), nil, "only the first time")
    near(r.trade.bonus, 250)
    eq(C.buildingSearched(r, "b2", 1900), 19100, "no cap: an office of 1,900 containers")
    eq(C.buildingSearched(r, "b3", 0), 100)
    eq(r.codex.nb, 3)
end)

test("building count milestones: 25, 100, 250 ...", function()
    noTable()
    local r = record()
    local events
    for i = 1, 25 do
        local _, e = C.buildingSearched(r, "b" .. i, 10)
        if #e > 0 then events = e end
    end
    near(r.trade.bonus, 25 * 200 + 3000)
    eq(events[1].kind, "Buildings"); eq(events[1].count, 25)
    for i = 26, 100 do C.buildingSearched(r, "b" .. i, 10) end
    near(r.trade.bonus, 100 * 200 + 3000 + 10000)
    local s = C.summary(r)
    eq(s.buildings, 100); eq(s.nextBuildings, 250)
end)

test("kills pay at 50, 100, 250 ... 25,000, and 150,000 every 5,000 after", function()
    noTable()
    local r = record()
    local events = C.kill(r, 49)
    eq(#events, 0)
    near(r.trade.bonus, 0)
    events = C.kill(r)
    eq(#events, 1)
    near(r.trade.bonus, 5000)
    C.kill(r, 50)
    near(r.trade.bonus, 10000)
    C.kill(r, 24900)
    -- 25,000 kills: all sixteen steps
    near(r.trade.bonus, 1240000)
    C.kill(r, 4999)
    near(r.trade.bonus, 1240000, 1e-6, "29,999 is not yet the next")
    events = C.kill(r)
    eq(#events, 1); eq(events[1].count, 30000); eq(events[1].credits, 150000)
    eq(r.codex.paid.kills, 17)
    eq(C.killThreshold(17), 30000); eq(C.killThreshold(18), 35000)
end)

test("one big step can cross several milestones", function()
    noTable()
    local r = record()
    local events = C.kill(r, 1200)
    eq(#events, 6)
    near(r.trade.bonus, 100000, 1e-6, "50 to 1,000: about 100 credits a kill")
end)

test("one big step that crosses several milestones has one title: the last count, the bonus of all", function()
    noTable()
    local r = record()
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = { id = id, detail = detail } end)
    C.kill(r, 1200)
    eq(#told, 1)
    eq(told[1].id, r.id)
    eq(told[1].detail.key, "IGUI_OA_Title_CodexKills")
    eq(told[1].detail.args[1], 1000)
    eq(told[1].detail.subArgs[1], 100000)
    eq(told[1].detail.style, "brief", "the kill milestones to 1,000 are told lightly")
    C.kill(r, 1)
    eq(#told, 1, "no milestone, no title")
    C.kill(r, 299)
    eq(#told, 2)
    eq(told[2].detail.args[1], 1500)
    eq(told[2].detail.style, "dust", "past 1,000 the big title")
    for i = 1, 25 do C.buildingSearched(r, "b" .. i, 0) end
    eq(#told, 3)
    eq(told[3].detail.key, "IGUI_OA_Title_CodexBuildings")
    eq(told[3].detail.args[1], 25)
    eq(told[3].detail.style, "dust")
end)

test("a category's title names it as a text the player's side translates", function()
    local kinds = {}
    for i = 1, 2 do kinds["Thing" .. i] = "E" end
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = kinds, total = { E = 2 }, n = 0 })
    local r = record()
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    C.acquire(r, kind(1))
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_CodexCategory_1")
    eq(told[1].args[1].key, OA.Categories.nameKey("E"))
    eq(told[1].style, "discovery")
    C.acquire(r, kind(2))
    eq(told[2].key, "IGUI_OA_Title_CodexCategory_2")
end)

test("kills are per record", function()
    noTable()
    local a = contact(OA.Store.ensure("a", "A"))
    local b = OA.Store.ensure("b", "B")
    C.kill(a, 100)
    near(a.trade.bonus, 10000)
    eq(b.trade, nil)
end)

test("before the first contact the codex and the search count, nothing is paid or told, and kills do not count", function()
    noTable()
    local r = OA.Store.ensure("pre", "Pre")
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    for i = 1, 100 do C.acquire(r, kind(i)) end
    eq(r.codex.n, 100, "the kinds counted")
    eq(r.codex.paid.kinds, 1, "the 100 kinds milestone passed")
    near(r.trade.bonus, 0, 1e-9, "nothing paid")
    local credits = C.buildingSearched(r, "b1", 5)
    eq(credits, nil)
    eq(r.codex.nb, 1, "the building counted")
    C.kill(r, 150)
    eq(r.codex.kills, 0, "the kills wait for the team")
    eq(#told, 0, "no title")
    -- met: the next find pays its own credits, and the milestone passed before is not paid late
    OA.Trust.section(r).stage = 1
    C.acquire(r, kind(101))
    near(r.trade.bonus, 100)
    C.kill(r, 100)
    near(r.trade.bonus, 10100)
    eq(#told, 1, "the kill milestone's title")
end)
