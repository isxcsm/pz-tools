-- Delivery box states, the active box, sealed boxes, grouping items into entries, and the ledger's compaction.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Ledger"
local OA = OperationAcorn
local Boxes, Ledger = OA.Trade.Boxes, OA.Trade.Ledger

local function newRecord()
    return OA.Store.ensure("rec", "Tester")
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

test("the ledger numbers receipts and keeps 30 days in detail", function()
    local record = newRecord()
    local r1 = Ledger.add(record, receipt(1, 1000), 1)
    local r2 = Ledger.add(record, receipt(10, 2000), 10)
    eq(r1.id, 1)
    eq(r2.id, 2)
    eq(Ledger.find(record, 2), r2)
    eq(Ledger.last(record), r2)
    local d = Ledger.data(record)
    eq(#d.receipts, 2)
    -- Day 31: the receipt of day 1 is 30 days old, still detailed. Day 32: folded.
    Ledger.add(record, receipt(31, 100), 31)
    eq(#d.receipts, 3)
    Ledger.add(record, receipt(32, 100), 32)
    eq(#d.receipts, 3, "day 1 folded, day 32 added")
    eq(d.totals.receipts, 1)
    eq(d.totals.credits, 1000)
    eq(d.totals.bonus, 5)
    eq(d.totals.spent, 10)
    eq(d.totals.delivered, 2)
    eq(d.totals.first, 1)
    -- Far later: everything old goes into the totals; the sequence goes on.
    local r = Ledger.add(record, receipt(200, 5), 200)
    eq(#d.receipts, 1)
    eq(d.totals.receipts, 4)
    eq(d.totals.credits, 1000 + 2000 + 100 + 100)
    eq(r.id, 5)
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
    Ledger.add(record, r, 1)
    eq(#Ledger.last(record).lines, Ledger.MAX_LINES)
end)
