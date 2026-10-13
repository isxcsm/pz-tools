-- Delivery box states, the active box, sealed boxes, grouping items into entries, and the ledger's numbers and compaction.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Ledger"
local OA = OperationAcorn
local Boxes, Ledger = OA.Trade.Boxes, OA.Trade.Ledger

local function newRecord(id)
    return OA.Store.ensure(id or "rec", "Tester")
end

test("the first box becomes the active box", function()
    local record = newRecord()
    local box = Boxes.add(record, { x = 10, y = 20, z = 0 })
    eq(Boxes.active(record), box)
    eq(box.state, "placed")
    truthy(string.find(box.id, "^%d%d%d%d%-1$"), "id is the number and a running count")
    local second = Boxes.add(record, { x = 11, y = 20, z = 0 })
    eq(Boxes.active(record), box, "a later box is a previous box unless made active")
    eq(second.id ~= box.id, true)
    Boxes.add(record, { x = 12, y = 20, z = 0, active = true })
    eq(Boxes.active(record).x, 12, "a new active box takes the place")
    eq(Boxes.get(record, box.id).state, "placed", "the former stays")
end)

test("a box can be taken up and put down again", function()
    local record = newRecord()
    local box = Boxes.add(record, { x = 1, y = 2, z = 0 })
    eq(Boxes.canCall(record), true)
    Boxes.carry(record, box.id)
    eq(box.state, "carried")
    local ok, why = Boxes.canCall(record)
    eq(ok, false)
    eq(why, "carried")
    eq(box.x, 1, "the last spot stays while it is carried")
    Boxes.place(record, box.id, 5, 6, 0)
    eq(box.state, "placed")
    eq(box.x, 5)
    eq(Boxes.canCall(record), true)
end)

test("without an active box there is no call", function()
    local record = newRecord()
    local ok, why = Boxes.canCall(record)
    eq(ok, false)
    eq(why, "noBox")
end)

test("only an open box standing in the world can be sealed, and a sealed one cannot be taken up", function()
    local record = newRecord()
    local box = Boxes.add(record, { x = 1, y = 2, z = 0 })
    local entries = { { info = { fullType = "Base.Rag" }, count = 3 }, { info = { fullType = "Base.Sock" }, count = 2 } }
    Boxes.carry(record, box.id)
    local ok, why = Boxes.seal(record, box.id, entries, 4.5)
    eq(ok, false)
    eq(why, "state")
    Boxes.place(record, box.id, 1, 2, 0)
    ok = Boxes.seal(record, box.id, entries, 4.5, 77)
    eq(ok, true)
    eq(box.state, "sealed")
    eq(box.sealed.count, 5)
    eq(box.sealed.weight, 4.5)
    eq(box.sealed.at, 77)
    eq(Boxes.carry(record, box.id), nil, "no taking up when sealed")
    eq(box.state, "sealed")
    ok, why = Boxes.seal(record, box.id, entries)
    eq(ok, false)
    eq(Boxes.canCall(record), true, "a sealed active box still stands in the world")
    eq(Boxes.seal(record, "nope", entries), false)
end)

test("sealed boxes come in order, the active one first, and their entries together", function()
    local record = newRecord()
    TEST.hours = 1
    local a = Boxes.add(record, { x = 1, y = 1, z = 0, active = false })
    TEST.hours = 2
    local b = Boxes.add(record, { x = 2, y = 1, z = 0, active = false })
    TEST.hours = 3
    local c = Boxes.add(record, { x = 3, y = 1, z = 0, active = true })
    local e1 = { { info = { fullType = "A" }, count = 1 } }
    local e2 = { { info = { fullType = "B" }, count = 2 } }
    local e3 = { { info = { fullType = "C" }, count = 3 } }
    Boxes.seal(record, a.id, e1)
    Boxes.seal(record, b.id, e2)
    Boxes.seal(record, c.id, e3)
    local list = Boxes.sealed(record)
    eq(#list, 3)
    eq(list[1].id, c.id, "active first")
    eq(list[2].id, a.id)
    eq(list[3].id, b.id)
    local entries = Boxes.sealedEntries(record)
    eq(#entries, 3)
    eq(entries[1].info.fullType, "C")
    eq(entries[3].info.fullType, "B")
end)

test("removing the active box leaves no active box", function()
    local record = newRecord()
    local a = Boxes.add(record, { x = 1, y = 1, z = 0 })
    local b = Boxes.add(record, { x = 2, y = 1, z = 0 })
    local box, wasActive = Boxes.remove(record, b.id)
    eq(box, b)
    eq(wasActive, false)
    eq(Boxes.active(record), a)
    box, wasActive = Boxes.remove(record, a.id)
    eq(wasActive, true)
    eq(Boxes.active(record), nil)
    eq(Boxes.remove(record, "none"), nil)
    -- A box added now becomes active again.
    local c = Boxes.add(record, { x = 3, y = 3, z = 0 })
    eq(Boxes.active(record), c)
end)

test("items group into entries by what they settle as", function()
    local infos = {
        { fullType = "Base.Rag", weight = 0.2, condition = 1, bought = false },
        { fullType = "Base.Sock", weight = 0.1 },
        { fullType = "Base.Rag", weight = 0.2, condition = 1, bought = false },
        { fullType = "Base.Rag", weight = 0.2, condition = 0.5, bought = false },
    }
    local entries = Boxes.group(infos)
    eq(#entries, 3)
    eq(entries[1].count, 2)
    eq(entries[1].info.fullType, "Base.Rag")
    eq(entries[2].info.fullType, "Base.Sock")
    eq(entries[3].count, 1, "another condition is another entry")
    eq(#Boxes.group({}), 0)
end)

local function receipt(day, credits)
    return { at = day * 24, kind = "settle", boxes = 1, credits = credits, trust = credits / 100, bonus = 5, spent = 10,
        orders = { { id = "a", ordered = 2, delivered = 2, paid = 10 } }, lines = {} }
end

test("the ledger numbers receipts and keeps the last settlement as one summary", function()
    local record = newRecord("ledger")
    local first = Ledger.nextSerial(record)
    truthy(first >= Ledger.FIRST_MIN and first <= Ledger.FIRST_MAX, "the first number is a middle one")
    eq(Ledger.last(record), nil, "none before the first")
    local r1 = Ledger.add(record, receipt(1, 1000), 1)
    eq(r1.id, first, "the number the status tab showed is the one the receipt gets")
    eq(r1.day, 1)
    eq(record.trade.serial, first)
    local second = Ledger.nextSerial(record)
    truthy(second > first and second <= first + Ledger.STEP_MAX)
    local first = Ledger.last(record)
    eq(first.at, 24)
    eq(first.credits, 1000)
    eq(first.trust, 10)
    eq(first.boxes, 1)
    local r2 = Ledger.add(record, receipt(10, 2000), 10)
    eq(r2.id, second)
    eq(r2.day, 10)
    local third = Ledger.nextSerial(record)
    local last = Ledger.last(record)
    eq(last.at, 240)
    eq(last.credits, 2000)
    eq(last.trust, 20)
    eq(last, record.trade.lastSettle)
    eq(record.ledger, nil, "no ledger section is kept")
    eq(record.trade.serial, second, "only the counter and the summary stay")
    -- Far later: the numbering goes on, and the summary is the newest one only.
    local r = Ledger.add(record, receipt(200, 5), 200)
    eq(r.id, third)
    eq(Ledger.last(record).credits, 5)
    -- A receipt without numbers gives zeros.
    Ledger.add(record, { at = 1 }, 201)
    local empty = Ledger.last(record)
    eq(empty.credits, 0); eq(empty.trust, 0); eq(empty.boxes, 0)
end)

test("the ledger folds a long list of lines into one", function()
    local lines = {}
    for i = 1, 100 do lines[i] = { name = "item" .. i, count = 1, credits = i, trust = 0.1 } end
    local compact = Ledger.compactLines(lines, 40)
    eq(#compact, 40)
    local folded = compact[40]
    eq(folded.name, nil)
    eq(folded.other, 61)
    eq(folded.count, 61)
    -- The kept lines are the 39 worth most, in their old order.
    eq(compact[1].name, "item62")
    eq(compact[39].name, "item100")
    eq(#Ledger.compactLines({ { name = "x", credits = 1 } }, 40), 1)
end)

test("a receipt with many lines is shortened when written", function()
    local record = newRecord()
    local lines = {}
    for i = 1, 100 do lines[i] = { name = "item" .. i, count = 1, credits = i } end
    local r = receipt(1, 1)
    r.lines = lines
    local written = Ledger.add(record, r, 1)
    eq(#written.lines, Ledger.MAX_LINES)
    eq(Ledger.last(record).lines, nil, "the summary carries no lines")
end)

-- The upgrade of a save from before: the ledger section becomes the serial and the last settlement.

local function upgrade(record, name)
    record.upgrades = record.upgrades or {}
    record.upgrades[name] = nil
    OA.Store.upgrade(record)
end

test("the ledger upgrade is registered and a new record has it done", function()
    local found = false
    for _, step in ipairs(OA.Store.UPGRADES) do if step.name == "trade.ledger" then found = true end end
    truthy(found, "registered")
    eq(newRecord("fresh").upgrades["trade.ledger"], true)
end)

test("an old ledger becomes the serial and the newest receipt's summary, and goes", function()
    local record = newRecord("old1")
    record.ledger = { seq = 7, totals = { receipts = 3 }, receipts = {
        { id = 6, at = 100, day = 4, credits = 500, trust = 5, boxes = 2, lines = {} },
        { id = 7, at = 200, day = 8, credits = 900, trust = 9, boxes = 1, lines = {} },
    } }
    upgrade(record, "trade.ledger")
    eq(record.ledger, nil)
    eq(record.trade.serial, 7)
    truthy(Ledger.nextSerial(record) > 7 and Ledger.nextSerial(record) <= 7 + Ledger.STEP_MAX)
    local last = Ledger.last(record)
    eq(last.at, 200)
    eq(last.credits, 900)
    eq(last.trust, 9)
    eq(last.boxes, 1)
    eq(record.upgrades["trade.ledger"], true)
    -- Run once: a ledger that shows up later is not touched.
    record.ledger = { seq = 99, receipts = {} }
    OA.Store.upgrade(record)
    eq(record.trade.serial, 7)
    eq(record.ledger.seq, 99)
end)

test("an old ledger with no receipts keeps only its counter; a record without one is left alone", function()
    local record = newRecord("old2")
    record.ledger = { seq = 3, receipts = {}, totals = {} }
    upgrade(record, "trade.ledger")
    eq(record.trade.serial, 3)
    eq(Ledger.last(record), nil)
    eq(record.ledger, nil)
    local plain = newRecord("plain")
    upgrade(plain, "trade.ledger")
    eq(plain.ledger, nil)
    eq(Ledger.last(plain), nil)
    truthy(Ledger.nextSerial(plain) >= Ledger.FIRST_MIN, "a record with no ledger starts at a middle number")
    -- A serial the new code already has is not lowered.
    local newer = newRecord("newer")
    newer.trade = { serial = 10 }
    newer.ledger = { seq = 4, receipts = {} }
    upgrade(newer, "trade.ledger")
    eq(newer.trade.serial, 10)
end)

test("the manifest numbers start in the middle, step 1 to 5, and differ from one collection point to another", function()
    local record = newRecord("serials")
    record.number = 347
    local last, steps, seen = nil, {}, {}
    for i = 1, 300 do
        local n = Ledger.serialAfter(record, last)
        if last then
            local step = n - last
            truthy(step >= 1 and step <= Ledger.STEP_MAX, "step " .. step)
            steps[step] = true
        else
            truthy(n >= Ledger.FIRST_MIN and n <= Ledger.FIRST_MAX)
        end
        eq(Ledger.serialAfter(record, last), n, "the same last number gives the same next one")
        last = n
    end
    for step = 1, Ledger.STEP_MAX do truthy(steps[step], "a step of " .. step .. " comes") end
    local starts = {}
    for number = 1000, 1060 do
        starts[Ledger.serialAfter({ number = number }, nil)] = true
    end
    local distinct = 0
    for _ in pairs(starts) do distinct = distinct + 1 end
    truthy(distinct > 20, "the first number differs by collection point (" .. distinct .. ")")
end)
