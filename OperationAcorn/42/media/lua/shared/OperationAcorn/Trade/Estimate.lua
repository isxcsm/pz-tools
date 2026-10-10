-- What a delivery would be worth, worked out the way the helicopter settles it but without changing anything: the
-- estimate shown before a box is sealed and before the helicopter is called. Values come from the economy part
-- (OA.Value); the request counters and new-region weights a flight uses up are followed here too, line by line.
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Upgrades/Infection"
local OA = OperationAcorn
local Trade = OA.Trade
local Boxes, Orders = Trade.Boxes, Trade.Orders
local Estimate = {}
Trade.Estimate = Estimate

-- Entries ({ info, count }) valued as one flight: { credits (whole), trust, lines } or nil when there is no economy.
function Estimate.entries(record, entries)
    local Value = OA.Value
    if not (Value and Value.context and Value.appraiseLine) then return nil end
    local ctx = Value.context(record)
    local taken = { requests = {}, cells = {} }
    local credits, trust, cashTrust = 0, 0, 0
    local lines = {}
    for _, entry in ipairs(entries) do
        local line = Value.appraiseLine(entry.info, entry.count or 1, ctx, taken)
        lines[#lines + 1] = line
        credits = credits + line.credits
        trust = trust + line.trust
        cashTrust = cashTrust + (line.cashTrust or 0)
        if line.requestUnits and line.requestUnits > 0 then
            taken.requests[line.fullType] = (taken.requests[line.fullType] or 0) + line.requestUnits
        end
        if line.regionWeight and line.regionWeight > 0 and entry.info.cell then
            taken.cells[entry.info.cell] = (taken.cells[entry.info.cell] or 0) + line.regionWeight
        end
    end
    cashTrust = math.min(cashTrust, Value.CASH_TRUST_CAP or cashTrust)
    return { credits = OA.round(credits), trust = trust + cashTrust, lines = lines }
end

-- Items of a container (their infos) grouped and valued.
function Estimate.infos(record, infos)
    return Estimate.entries(record, Boxes.group(infos))
end

-- The whole flight a call would make: the sealed boxes' worth, the bonus waiting, the cart's cost and the balance
-- that would be left. { sealed, fee, feeRate, net, boxes, bonus, orders, cart, before, after, blocked }: sealed is the
-- worth before the infection handling fee, fee the credits it withholds (0 or more; the same before a test as after, so
-- the estimate does not tell whether there is an infection), feeRate its share (0 when none applies), net sealed
-- less fee; after is what is left with the fee and the orders taken.
function Estimate.flight(record)
    local account = Trade.account(record)
    local entries = Boxes.sealedEntries(record)
    local worth = Estimate.entries(record, entries)
    local credits = worth and worth.credits or 0
    local bonus = OA.round(account.bonus or 0)
    local cost = Orders.estimate(record, 0)
    local balance = account.credits
    local fee, feeRate = OA.Infection.fee(record, credits)
    local gain = credits - fee + bonus
    -- A debt takes the gain first, then the orders are paid from what is left.
    local after = balance + gain
    local orders = (after >= 0) and cost or 0
    return {
        boxes = #Boxes.sealed(record), sealed = credits, fee = fee, feeRate = feeRate, net = credits - fee,
        bonus = bonus, orders = orders, cart = cost,
        before = balance, after = after - orders, blocked = after < 0 and cost > 0,
    }
end

return Estimate
