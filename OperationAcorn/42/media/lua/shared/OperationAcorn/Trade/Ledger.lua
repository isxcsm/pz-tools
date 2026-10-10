-- The settlement numbers: each helicopter's receipt gets the next serial (the supply manifest's number), and the last
-- settlement stays as one summary line. The receipts themselves are not kept: the manifest paper carries its own copy
-- and the document folder the latest few (DESIGN-terminal 13).
--
-- record.trade.serial = the last number given; record.trade.lastSettle = { at, credits, trust, boxes }
-- receipt = { id, at, day, kind ("settle" | "reissue"), boxes, credits, trust, bonus, debtPaid, spent, balance,
--   lines = { { name, count, credits, trust, marks } }, orders = { { id, target, ordered, delivered, paid, reason } },
--   filled = { { fullType, band, trust } } (request lines made full), note = { key, args }, gifts = { { type, count } }, events = { { kind, n } }, extra = { ... } }
require "OperationAcorn/Store"
local OA = OperationAcorn
local Store = OA.Store
local Ledger = {}
OA.Trade = OA.Trade or {}
OA.Trade.Ledger = Ledger

-- The lines of one receipt: more are folded into one "other" line.
Ledger.MAX_LINES = 40

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

-- The summary line of a receipt.
local function summary(receipt)
    return { at = receipt.at, credits = receipt.credits or 0, trust = receipt.trust or 0, boxes = receipt.boxes or 0 }
end

-- Numbers a receipt, shortens its lines and keeps its summary as the last settlement. Returns the receipt.
function Ledger.add(record, receipt, nowDay)
    local t = Store.section(record, "trade")
    t.serial = (t.serial or 0) + 1
    receipt.id = t.serial
    receipt.day = nowDay
    if receipt.lines then receipt.lines = Ledger.compactLines(receipt.lines, Ledger.MAX_LINES) end
    t.lastSettle = summary(receipt)
    return receipt
end

-- The number the next receipt gets.
function Ledger.nextSerial(record)
    local t = record.trade
    return (t and t.serial or 0) + 1
end

-- The last settlement's summary, or nil before the first.
function Ledger.last(record)
    return record.trade and record.trade.lastSettle or nil
end

-- A save from before: the ledger section's counter becomes the serial, its newest receipt the last settlement.
Store.addUpgrade("trade.ledger", function(record)
    local old = record.ledger
    if not old then return end
    local t = Store.section(record, "trade")
    t.serial = math.max(t.serial or 0, old.seq or 0)
    local receipts = old.receipts or {}
    local newest = receipts[#receipts]
    if newest and not t.lastSettle then t.lastSettle = summary(newest) end
    record.ledger = nil
end)

return Ledger
