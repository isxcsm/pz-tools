-- The easter eggs (NUMBERS 13): each fires once, at a settlement or at 07:30; the acorns add up across settlements;
-- the receipt gets its remarks; every effect really changes the formula it is for; the handover turns the Furbert's
-- call into a remark only; the walkie-talkie counts only marked, turned on, and only at 07:30.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Settle"
require "OperationAcorn/Trade/Text"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Economy/Eggs"
require "OperationAcorn/Story/Egg"
require "OperationAcorn/Story/Data"
local OA = OperationAcorn
local Trade, Boxes, Settle, Eggs = OA.Trade, OA.Trade.Boxes, OA.Trade.Settle, OA.Eggs
local Shop, Trust = OA.Shop, OA.Trust

local n = 0
-- A record in the trade (a stage, the flight support levels, a balance).
local function newRecord(levels, credits)
    n = n + 1
    local record = OA.Store.ensure("egg" .. n, "Tester")
    record.trade = { credits = credits or 0, trust = 0, stage = 3, milestones = 0, bonus = 0, sharedSerums = 0,
        levels = levels or {} }
    Trust.reset()
    return record
end

-- The titles and the sounds told to anyone while a test runs.
local titles, sounds
local function listen()
    titles, sounds = {}, {}
    OA.Sync.listen("title", function(_, detail) titles[#titles + 1] = detail end)
    OA.Sync.listen("sound", function(_, detail) sounds[#sounds + 1] = detail.cue end)
end

local function services()
    return {
        now = 100, day = 4,
        settle = function() return { credits = 0, trust = 0, lines = {}, cashTrust = 0 } end,
        trustAdd = function() return {} end,
        rnd = function(a, b) return b end,
        shop = {},
    }
end

-- One settlement of a record: the entries as { type, count } sealed in its box, run through the helicopter's arrival.
local function settle(record, items)
    local box = Boxes.add(record, { x = 10, y = 0, z = 0, active = true })
    local entries = {}
    for _, item in ipairs(items) do
        entries[#entries + 1] = { info = { fullType = item[1] }, count = item[2] or 1 }
    end
    Boxes.seal(record, box.id, entries)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services())
    -- an egg's title waits for the drop's (Heli.dropped releases it)
    local before = titles and #titles or 0
    Eggs.release(record)
    plan.titledBeforeDrop = before
    return plan
end

local function hasNote(plan, key)
    for _, k in ipairs(plan.receipt.eggs or {}) do if k == key then return true end end
    return false
end

test("the Furbert pays 100,000 once, with its remark and title; the second pays only its appraisal", function()
    listen()
    local record = newRecord({}, 500)
    local plan = settle(record, { { "Base.FurbertSquirrel" } })
    eq(plan.titledBeforeDrop, 0, "no title before the drop's")
    eq(record.eggs.held, nil, "released")
    eq(record.trade.credits, 500 + 100000)
    eq(plan.receipt.bonus, 100000)
    truthy(hasNote(plan, "IGUI_OA_Trade_Egg_1"), "the remark before the handover")
    eq(#titles, 1)
    eq(titles[1].key, "IGUI_OA_Title_Egg_1")
    eq(titles[1].sub, "IGUI_OA_Title_Egg_1Sub")
    eq(titles[1].style, "discovery")
    truthy(Eggs.has(record, "furbert"))
    local again = settle(record, { { "Base.FurbertSquirrel" } })
    eq(record.trade.credits, 500 + 100000, "once")
    eq(again.receipt.eggs, nil, "no remark the second time")
    eq(#titles, 1)
end)

test("the remarks are written into the receipt's lines", function()
    local record = newRecord()
    local plan = settle(record, { { "Base.FurbertSquirrel" }, { "Base.Acorn", 3 } })
    eq(#plan.receipt.eggs, 2)
    local found = {}
    for _, line in ipairs(Trade.Text.receipt(plan.receipt)) do found[line.text] = true end
    truthy(found["IGUI_OA_Trade_Rc_Row IGUI_OA_Trade_Rc_Label_remarks IGUI_OA_Trade_Egg_1"], "E1 in its row")
    truthy(found["IGUI_OA_Trade_Rc_Row IGUI_OA_Trade_Rc_Label_remarks IGUI_OA_Trade_Egg_2"], "E2 in its row")
end)

test("acorns add up across settlements, a remark each time, and the hundredth stamps the title once", function()
    listen()
    local record = newRecord({ box = 1 })
    eq(Trust.rewards(record).boxCapacity, 100, "the upgraded capacity")
    local first = settle(record, { { "Base.Acorn", 60 } })
    truthy(hasNote(first, "IGUI_OA_Trade_Egg_2"))
    eq(#titles, 0)
    eq(Eggs.has(record, "acorns"), false)
    eq(Trust.rewards(record).boxCapacity, 100)
    local second = settle(record, { { "Base.Acorn", 30 }, { "Base.Acorn", 9 } })
    truthy(hasNote(second, "IGUI_OA_Trade_Egg_2"), "a remark with every settlement of acorns")
    eq(record.eggs.acorns, 99)
    eq(#titles, 0, "99 is not enough")
    local third = settle(record, { { "Base.Acorn", 1 } })
    eq(record.eggs.acorns, 100)
    eq(#titles, 1)
    eq(titles[1].key, "IGUI_OA_Title_Egg_2")
    eq(titles[1].sub, "IGUI_OA_Title_Egg_2Sub")
    eq(titles[1].style, "seal")
    truthy(Eggs.has(record, "acorns"))
    eq(Trust.rewards(record).boxCapacity, 150, "50 more than the upgrade's")
    local fourth = settle(record, { { "Base.Acorn", 5 } })
    truthy(hasNote(fourth, "IGUI_OA_Trade_Egg_2"))
    eq(#titles, 1, "the title only once")
    eq(record.eggs.acorns, 105)
    local none = settle(record, { { "Base.Rag" } })
    eq(none.receipt.eggs, nil, "no acorns, no remark")
end)

test("a dead squirrel and any of the four Spiffo things each fire once", function()
    listen()
    local record = newRecord()
    local plan = settle(record, { { "Base.DeadSquirrel", 2 } })
    truthy(hasNote(plan, "IGUI_OA_Trade_Egg_3"))
    eq(titles[#titles].key, "IGUI_OA_Title_Egg_3")
    eq(titles[#titles].style, "discovery")
    eq(settle(record, { { "Base.DeadSquirrel" } }).receipt.eggs, nil)
    eq(#titles, 1)
    for i, spiffo in ipairs({ "Base.Spiffo", "Base.SpiffoBig", "Base.SpiffoSuit", "Base.SpiffoTail" }) do
        local other = newRecord()
        local p = settle(other, { { spiffo } })
        truthy(hasNote(p, "IGUI_OA_Trade_Egg_4"), spiffo)
        truthy(Eggs.has(other, "spiffo"), spiffo)
        eq(settle(other, { { spiffo } }).receipt.eggs, nil, spiffo .. " the second time")
    end
    eq(titles[#titles].key, "IGUI_OA_Title_Egg_4")
    eq(titles[#titles].sub, "IGUI_OA_Title_Egg_4Sub")
end)

test("other things on the same flight give nothing", function()
    listen()
    local record = newRecord()
    local plan = settle(record, { { "Base.Rag", 4 }, { "Base.SpiffoXmas" } })
    eq(plan.receipt.eggs, nil)
    eq(#titles, 0)
    eq(record.eggs, nil, "no section made")
end)

test("the Furbert's conversion rate goes to credits only, never to trust", function()
    local record = newRecord({})
    local info = { fullType = "OperationAcorn.SampleBundle", own = "SampleBundle", baseType = "SampleBundle" }
    local before = OA.Value.appraiseLine(info, 1, OA.Value.buildContext(record))
    near(before.credits, 600)
    near(before.trust, 6)
    settle(record, { { "Base.FurbertSquirrel" } })
    near(Trust.rewards(record).rate, 0.05)
    local after = OA.Value.appraiseLine(info, 1, OA.Value.buildContext(record))
    near(after.credits, 630, 1e-9, "5 points more")
    near(after.trust, 6, 1e-9, "trust as it was")
    -- on top of the upgrade, whatever its step
    local upgraded = newRecord({ rate = 2 })
    near(Trust.rewards(upgraded).rate, 0.10)
    settle(upgraded, { { "Base.FurbertSquirrel" } })
    near(Trust.rewards(upgraded).rate, 0.15)
end)

test("serums cost 0.9: the per-tree ones and the shared one", function()
    local record = newRecord({})
    local tree = Shop.entry("serum_scout")
    local shared = Shop.entry("serum_shared")
    local treePrice, sharedPrice = Shop.price(tree, record), Shop.price(shared, record)
    eq(treePrice, 8000)
    eq(Shop.serumPrice("scout", record), 8000)
    eq(Shop.serumPrice("scout", record, 4), Shop.serumPriceAt(5))
    settle(record, { { "Base.DeadSquirrel" } })
    eq(Shop.price(tree, record), 7200)
    eq(Shop.serumPrice("scout", record), 7200)
    eq(Shop.serumPrice("scout", record, 4), OA.round(Shop.serumPriceAt(5) * 0.9))
    eq(Shop.serumPriceAt(5), Shop.serumPriceAt(5, nil), "the price without a record is the base")
    eq(Shop.price(shared, record), OA.round(sharedPrice * 0.9))
    -- a second, bought, serum: the next is the second's price, scaled
    eq(Shop.serumPriceAt(2, record), OA.round(Shop.serumPriceAt(2) * 0.9))
end)

test("the Spiffo's 5 points go to the shop discount, only where one applies", function()
    local record = newRecord({ discount = 1 })
    local battery, cure = Shop.entry("battery_pack"), Shop.entry("cure_serum")
    eq(Shop.price(battery, record), 3800, "the upgrade's 5 points")
    local cureBefore = Shop.price(cure, record)
    settle(record, { { "Base.Spiffo" } })
    near(Trust.rewards(record).discount, 0.10)
    eq(Shop.price(battery, record), 3600, "10 points now")
    eq(Shop.price(cure, record), cureBefore, "a fixed price has no discount")
    -- with no upgrade there is the egg's 5 alone
    local plain = newRecord({})
    eq(Shop.price(battery, plain), 4000)
    settle(plain, { { "Base.SpiffoBig" } })
    eq(Shop.price(battery, plain), 3800)
end)

test("the radio's 0.8 multiplies both ends of the arrival hours, whatever the upgrade", function()
    local record = newRecord({ arrive = 1 })
    near(Trust.rewards(record).arrival.min, 3)
    near(Trust.rewards(record).arrival.max, 4)
    local plain = newRecord({})
    local lo, hi = Trust.rewards(plain).arrival.min, Trust.rewards(plain).arrival.max
    Eggs.section(record).radio = true
    Eggs.section(plain).radio = true
    Trust.reset()
    near(Trust.rewards(record).arrival.min, 2.4)
    near(Trust.rewards(record).arrival.max, 3.2)
    near(Trust.rewards(plain).arrival.min, lo * 0.8)
    near(Trust.rewards(plain).arrival.max, hi * 0.8)
end)

test("a rewards table made before an egg is made again after it", function()
    local record = newRecord({})
    near(Trust.rewards(record).rate, 0)
    settle(record, { { "Base.FurbertSquirrel" } })
    near(Trust.rewards(record).rate, 0.05, 1e-9, "without a Trust.reset")
end)

test("before the handover the Furbert brings Branscomb's call once; after it only the remark, and no call", function()
    local before = newRecord()
    local plan = settle(before, { { "Base.FurbertSquirrel" } })
    truthy(hasNote(plan, "IGUI_OA_Trade_Egg_1"))
    eq(OA.Comms.done(before, "C_egg_furbert"), false)
    local fired = OA.StoryBranches.look(before, "settled")
    eq(#fired, 1)
    eq(fired[1], "C_egg_furbert")
    eq(OA.Comms.next(before, "terminal", 1000).id, "C_egg_furbert")
    eq(#OA.StoryBranches.look(before, "settled"), 0, "once")
    -- played: nothing again
    OA.Comms.played(before, "C_egg_furbert", 3, 1000)
    eq(#OA.StoryBranches.look(before, "settled"), 0)

    local after = newRecord()
    OA.Story.section(after).handover = true
    local late = settle(after, { { "Base.FurbertSquirrel" } })
    truthy(hasNote(late, "IGUI_OA_Trade_Egg_1k"), "the management's remark")
    eq(hasNote(late, "IGUI_OA_Trade_Egg_1"), false)
    eq(#OA.StoryBranches.look(after, "settled"), 0, "no call after the handover")
    eq(OA.Comms.next(after, "terminal", 1000), nil)
    eq(after.trade.credits, 100000, "the pay is the same")
    eq(Eggs.has(after, "furbert"), true)
end)

test("a call not yet played gives way when the handover comes first", function()
    local record = newRecord()
    settle(record, { { "Base.FurbertSquirrel" } })
    eq(#OA.StoryBranches.look(record, "settled"), 1)
    truthy(OA.Comms.ready(record, "C_egg_furbert", 1000))
    OA.Story.section(record).handover = true
    OA.StoryBranches.look(record, "settled")
    eq(OA.Comms.ready(record, "C_egg_furbert", 1000), false)
end)

test("the call is a short one with the greeting, and the radio is the last crate's, marked", function()
    local entry = OA.CommsData.BY_ID.C_egg_furbert
    eq(entry.kind, "short")
    eq(entry.branch, "egg")
    eq(entry.greet, true)
    local items = OA.StoryData.NOTE_ITEMS.last_b
    eq(items[1][1], "Base.WalkieTalkie5")
    eq(items[1][3][Eggs.RADIO_MARK], true)
end)

-- ---------------------------------------------------------------------------------------------------------------
-- The walkie-talkie at 07:30.

local function item(o)
    o = o or {}
    local data = {}
    if o.marked ~= false then data[Eggs.RADIO_MARK] = true end
    if o.noData then data = nil end
    return {
        hasModData = function() return data ~= nil end,
        getModData = function() return data end,
        getDeviceData = function() return { getIsTurnedOn = function() return o.on ~= false end } end,
    }
end

-- A character carrying the items (the typed lookup is the game's own: the fake answers it with the list).
local function character(id, items)
    local asked = { n = 0 }
    local ch = {
        asked = asked,
        getModData = function() return { OA_Id = id } end,
        getX = function() return 0 end, getY = function() return 0 end,
        getInventory = function()
            return {
                getAllTypeRecurse = function(_, fullType)
                    asked.n = asked.n + 1
                    asked.type = fullType
                    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
                end,
            }
        end,
    }
    return ch
end

-- The game clock at hour and minute (the harness's clock answers by the world age).
local function clock(hour, minute)
    TEST.hours = (hour + minute / 60 - 9) % 24
end

test("the 07:30 moment is exact: one clock compare, true at 07:30 and no other minute", function()
    clock(7, 30)
    truthy(Eggs.radioTime())
    for _, hm in ipairs({ { 7, 29 }, { 7, 31 }, { 7, 0 }, { 19, 30 }, { 0, 30 }, { 8, 30 } }) do
        clock(hm[1], hm[2])
        eq(Eggs.radioTime(), false, hm[1] .. ":" .. hm[2])
    end
end)

test("at 07:30, a marked radio turned on gives the tone, the title and the effect, once", function()
    listen()
    local record = newRecord({ arrive = 1 })
    local ch = character(record.id, { item() })
    clock(7, 30)
    truthy(Eggs.radioLook(record, ch))
    eq(ch.asked.type, "Base.WalkieTalkie5", "the typed lookup")
    eq(ch.asked.n, 1)
    truthy(Eggs.has(record, "radio"))
    eq(sounds[1], "oa.egg.radio")
    eq(#sounds, 1)
    eq(#titles, 1)
    eq(titles[1].key, "IGUI_OA_Title_Egg_5")
    eq(titles[1].sub, "IGUI_OA_Title_Egg_5Sub")
    eq(titles[1].style, "discovery")
    near(Trust.rewards(record).arrival.min, 2.4)
    -- once: the next day finds nothing to do, and does not even look
    eq(Eggs.radioLook(record, ch), false)
    eq(ch.asked.n, 1)
    eq(#sounds, 1)
    eq(#titles, 1)
end)

test("an unmarked walkie-talkie, or a marked one turned off, gives nothing", function()
    listen()
    local record = newRecord()
    clock(7, 30)
    eq(Eggs.radioLook(record, character(record.id, { item({ marked = false }) })), false, "unmarked")
    eq(Eggs.radioLook(record, character(record.id, { item({ noData = true }) })), false, "no modData")
    eq(Eggs.radioLook(record, character(record.id, { item({ on = false }) })), false, "turned off")
    eq(Eggs.radioLook(record, character(record.id, {})), false, "none carried")
    eq(Eggs.has(record, "radio"), false)
    eq(#sounds, 0)
    eq(#titles, 0)
    -- the one that is turned on among others
    truthy(Eggs.radioLook(record, character(record.id, { item({ marked = false }), item({ on = false }), item() })))
end)

test("the minute event looks at nothing until 07:30, then at the characters of living records", function()
    require "OperationAcorn/Economy"
    listen()
    local record = newRecord()
    local dead = newRecord()
    dead.dead = 1
    local mine = character(record.id, { item() })
    local theirs = character(dead.id, { item() })
    getOnlinePlayers = function()
        local list = { mine, theirs }
        return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
    end
    isServer = function() return true end
    -- (the economy's own minute work is throttled by the real clock)
    clock(7, 29)
    TEST.fire("EveryOneMinute")
    eq(mine.asked.n, 0, "no search before 07:30")
    clock(7, 31)
    TEST.fire("EveryOneMinute")
    eq(mine.asked.n, 0, "none after it")
    clock(7, 30)
    TEST.fire("EveryOneMinute")
    eq(mine.asked.n, 1)
    truthy(Eggs.has(record, "radio"))
    eq(theirs.asked.n, 0, "a dead record's character is not looked at")
    eq(Eggs.has(dead, "radio"), false)
end)

test("the effects are neutral for a record without eggs, and without a record", function()
    local record = newRecord()
    eq(Eggs.conversionBonus(record), 0)
    eq(Eggs.capacityBonus(record), 0)
    eq(Eggs.serumScale(record), 1)
    eq(Eggs.discountBonus(record), 0)
    eq(Eggs.arrivalScale(record), 1)
    eq(Eggs.conversionBonus(nil), 0)
    eq(Eggs.serumScale(nil), 1)
    eq(record.eggs, nil, "reading makes no section")
end)
