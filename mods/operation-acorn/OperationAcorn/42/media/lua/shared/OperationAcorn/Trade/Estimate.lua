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

-- Entries ({ info, count }) valued as one flight: { credits (whole), trust, lines, requests, filled } or nil when
-- there is no economy. `requests` is what this week's request lines fetch: { credits (whole), units, lines = { {
-- fullType, key (its request group), units, credits } the biggest first } }; `filled` are the request lines the
-- flight would make full (their trust is in `trust`).
function Estimate.entries(record, entries)
    local Value = OA.Value
    if not (Value and Value.context and Value.flight) then return nil end
    local flight = Value.flight(Value.context(record), entries)
    local requests = { credits = 0, units = 0, lines = {} }
    local byType = {}
    for _, line in ipairs(flight.lines) do
        if line.requestUnits > 0 then
            local r = byType[line.fullType]
            if not r then
                r = { fullType = line.fullType, key = line.requestKey, units = 0, credits = 0 }
                byType[line.fullType] = r
                requests.lines[#requests.lines + 1] = r
            end
            r.units = r.units + line.requestUnits
            r.credits = r.credits + (line.requestCredits or 0)
            requests.units = requests.units + line.requestUnits
            requests.credits = requests.credits + (line.requestCredits or 0)
        end
    end
    table.sort(requests.lines, function(a, b)
        if a.credits ~= b.credits then return a.credits > b.credits end
        return a.fullType < b.fullType
    end)
    requests.credits = OA.round(requests.credits)
    return { credits = OA.round(flight.credits), trust = flight.trust, lines = flight.lines, requests = requests,
        filled = flight.fills }
end

-- Items of a container (their infos) grouped and valued.
function Estimate.infos(record, infos)
    return Estimate.entries(record, Boxes.group(infos))
end

-- The whole flight a call would make: the sealed boxes' worth, the bonus waiting, the cart's cost and the balance
-- that would be left. { sealed, fee, feeRate, net, missions, boxes, bonus, orders, cart, before, after, blocked,
-- requests, filled }: sealed is the worth before the infection handling fee, fee the credits it withholds (0 or more; the same
-- before a test as after, so the estimate does not tell whether there is an infection), feeRate its share (0 when
-- none applies), net sealed less fee; missions what the sealed missions pay at the same settlement (Story/Missions,
-- none without a sealed box); after is what is left with the fee and the orders taken. `requests` and
-- `filled` as Estimate.entries gives them for the sealed boxes (empty when there are none).
function Estimate.flight(record)
    local account = Trade.account(record)
    local entries = Boxes.sealedEntries(record)
    local worth = Estimate.entries(record, entries)
    local credits = worth and worth.credits or 0
    local bonus = OA.round(account.bonus or 0)
    local cost = Orders.estimate(record, 0)
    local balance = account.credits
    local fee, feeRate = OA.Infection.fee(record, credits)
    local boxes = #Boxes.sealed(record)
    local missions = (boxes > 0 and OA.Missions) and OA.Missions.sealedPay(record) or 0
    local gain = credits - fee + bonus + missions
    -- A debt takes the gain first, then the orders are paid from what is left.
    local after = balance + gain
    local orders = (after >= 0) and cost or 0
    return {
        boxes = boxes, sealed = credits, fee = fee, feeRate = feeRate, net = credits - fee, missions = missions,
        bonus = bonus, orders = orders, cart = cost,
        before = balance, after = after - orders, blocked = after < 0 and cost > 0,
        requests = worth and worth.requests or { credits = 0, units = 0, lines = {} },
        filled = worth and worth.filled or {},
    }
end

return Estimate
