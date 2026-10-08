-- The delivery ledger: one receipt for each helicopter that came, kept in detail for the last 30 days and then folded
-- into totals so the save does not grow without end (DESIGN 12, save data rule).
--
-- record.ledger = { seq, receipts = { receipt }, totals = { ... } }
-- receipt = { id, at, day, kind ("settle"), boxes, credits, trust, bonus, debtPaid, spent, balance,
--   lines = { { name, count, credits, trust, marks } }, orders = { { id, target, ordered, delivered, paid, reason } },
--   note = { key, args }, gifts = { { type, count } }, events = { { kind, n } }, extra = { ... } }
require "OperationAcorn/Store"
local OA = OperationAcorn
local Store = OA.Store
local Ledger = {}
OA.Trade = OA.Trade or {}
OA.Trade.Ledger = Ledger

Ledger.KEEP_DAYS = 30
-- The lines of one receipt: more are folded into one "other" line.
Ledger.MAX_LINES = 40

function Ledger.data(record)
    local d = Store.section(record, "ledger")
    d.seq = d.seq or 0
    d.receipts = d.receipts or {}
    d.totals = d.totals or {}
    local t = d.totals
    t.receipts = t.receipts or 0
    t.boxes = t.boxes or 0
    t.credits = t.credits or 0
    t.trust = t.trust or 0
    t.bonus = t.bonus or 0
    t.spent = t.spent or 0
    t.delivered = t.delivered or 0
    t.first = t.first or nil
    return d
end

-- Lines folded to at most `max`: the ones worth most credits stay (in their order), the rest become one line with
-- name = nil and `other` = how many lines were folded.
function Ledger.compactLines(lines, max)
    if #lines <= max then return lines end
    local ranked = {}
    for i, line in ipairs(lines) do ranked[i] = { line = line, index = i } end
    table.sort(ranked, function(a, b)
        local ca, cb = a.line.credits or 0, b.line.credits or 0
        if ca ~= cb then return ca > cb end
        return a.index < b.index
    end)
    local keep, folded = {}, { count = 0, credits = 0, trust = 0, other = 0 }
    for rank, r in ipairs(ranked) do
        if rank < max then
            keep[#keep + 1] = r
        else
            folded.count = folded.count + (r.line.count or 0)
            folded.credits = folded.credits + (r.line.credits or 0)
            folded.trust = folded.trust + (r.line.trust or 0)
            folded.other = folded.other + 1
        end
    end
    table.sort(keep, function(a, b) return a.index < b.index end)
    local result = {}
    for _, r in ipairs(keep) do result[#result + 1] = r.line end
    result[#result + 1] = folded
    return result
end

-- One receipt into the totals.
local function fold(totals, receipt)
    totals.receipts = totals.receipts + 1
    totals.boxes = totals.boxes + (receipt.boxes or 0)
    totals.credits = totals.credits + (receipt.credits or 0)
    totals.trust = totals.trust + (receipt.trust or 0)
    totals.bonus = totals.bonus + (receipt.bonus or 0)
    totals.spent = totals.spent + (receipt.spent or 0)
    for _, o in ipairs(receipt.orders or {}) do totals.delivered = totals.delivered + (o.delivered or 0) end
    totals.first = totals.first or receipt.day
end

-- Receipts older than the keep days (by the day they were written) folded into the totals.
function Ledger.compact(ledger, nowDay, keepDays)
    keepDays = keepDays or Ledger.KEEP_DAYS
    local receipts = ledger.receipts
    local kept, dropped = {}, 0
    for _, receipt in ipairs(receipts) do
        if nowDay - (receipt.day or nowDay) > keepDays then
            fold(ledger.totals, receipt)
            dropped = dropped + 1
        else
            kept[#kept + 1] = receipt
        end
    end
    if dropped > 0 then ledger.receipts = kept end
    return dropped
end

-- Writes a receipt: numbers it, shortens its lines and folds the old ones away. Returns the receipt.
function Ledger.add(record, receipt, nowDay)
    local d = Ledger.data(record)
    d.seq = d.seq + 1
    receipt.id = d.seq
    receipt.day = nowDay
    if receipt.lines then receipt.lines = Ledger.compactLines(receipt.lines, Ledger.MAX_LINES) end
    d.receipts[#d.receipts + 1] = receipt
    Ledger.compact(d, nowDay)
    return receipt
end

function Ledger.find(record, id)
    for _, receipt in ipairs(Ledger.data(record).receipts) do
        if receipt.id == id then return receipt end
    end
    return nil
end

-- The latest receipt, or nil.
function Ledger.last(record)
    local list = Ledger.data(record).receipts
    return list[#list]
end

return Ledger
