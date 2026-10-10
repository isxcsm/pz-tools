-- What a helicopter does when it arrives, apart from the world: it settles every sealed box, repays a debt, adds
-- credits and trust, pays the orders in order and then the flight support requests, loads the crate and works out
-- what to take away and put down. The game's economy (P1) and shop come in as services so that the whole can be
-- tested outside the game; the world objects are the helicopter's physical part (server/Trade/Heli).
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Ledger"
require "OperationAcorn/Upgrades/Infection"
local OA = OperationAcorn
local Trade = OA.Trade
local Rules, Boxes, Ledger = Trade.Rules, Trade.Boxes, Trade.Ledger
local Settle = {}
Trade.Settle = Settle

-- A small thing the team sometimes adds that nobody ordered (DESIGN 9: only pleasant surprises), from stage 2 on.
Settle.BONUS_CHANCE = 25
Settle.BONUS_FROM_STAGE = 2
Settle.BONUS_POOL = {
    { type = "Base.Battery", count = 2, key = "IGUI_OA_Trade_Bonus_Battery" },
    { type = "Base.Socks_Ankle", count = 1, key = "IGUI_OA_Trade_Bonus_Socks" },
    { type = "Base.CardDeck", count = 1, key = "IGUI_OA_Trade_Bonus_Cards" },
    { type = "Base.Bandage", count = 2, key = "IGUI_OA_Trade_Bonus_Bandage" },
    { type = "Base.Matchbox", count = 1, key = "IGUI_OA_Trade_Bonus_Matches" },
}

-- The items of the mod that are issued to a record (a serum's shelf life counts from the receipt; the serum is
-- the record's alone).
local ISSUED = { "OperationAcorn.UpgradeSerum", "OperationAcorn.CureSerum", "OperationAcorn.DelayDrug" }

function Settle.isIssued(fullType)
    for _, prefix in ipairs(ISSUED) do
        if string.sub(fullType, 1, #prefix) == prefix then return true end
    end
    return false
end

-- A purchased item spec: marked as bought (the team does not take it back); serums are issued to this record.
function Settle.markBought(spec, record, now)
    spec.mod = spec.mod or {}
    spec.mod.OA_Bought = true
    if Settle.isIssued(spec.type) then
        spec.mod.OA_Issued = now
        spec.mod.OA_Owner = record.id
    end
    return spec
end

-- Shared serums the account holds become items in the crate, and the count starts again.
local function sharedSerumSpecs(account, record, now)
    local specs = {}
    local count = math.floor(account.sharedSerums or 0)
    if count > 0 then
        specs[1] = Settle.markBought({ type = "OperationAcorn.UpgradeSerumShared", count = count }, record, now)
        account.sharedSerums = 0
    end
    return specs
end

-- Plain lines of a settlement kept for the receipt: what the team said about each kind.
local function receiptLines(lines)
    local out = {}
    for _, line in ipairs(lines or {}) do
        local keep = {}
        for k, v in pairs(line) do
            local t = type(v)
            if t == "number" or t == "string" or t == "boolean" then keep[k] = v
            elseif t == "table" and k == "marks" then
                keep.marks = {}
                for mk, mv in pairs(v) do if mv then keep.marks[mk] = true end end
            end
        end
        out[#out + 1] = keep
    end
    return out
end
Settle.receiptLines = receiptLines

-- Runs one arrival for a record. svc:
--   svc.now                       the world age (hours), svc.day the game day
--   svc.settle(record, entries)   OA.Value.settle: { credits, trust, lines }
--   svc.trustAdd(record, trust)   Trade.addTrust: adds the trust and handles what a new stage or milestone brings once;
--                                 it gives back the events
--   svc.oldForm                   whether the manifest keeps the old form (the story part, from the 4th stage)
--   svc.shop                      for Rules.payOrders
--   svc.rnd(a, b)                 a whole number from a to b
-- Returns the plan for the world: { receipt, removals = { { id, x, y, z } }, newBox, cargo = { specs }, spot,
-- reissue }. The caller does the physical part and then clears the call.
function Settle.run(record, svc)
    local heli = Trade.heli(record)
    local call = heli.call or {}
    local account = Trade.account(record)
    local now, day = svc.now, svc.day

    -- 1. The sealed boxes of this record, settled at the market of the moment.
    local sealed = Boxes.sealed(record)
    local entries = Boxes.sealedEntries(record)
    local result = { credits = 0, trust = 0, lines = {} }
    if #entries > 0 then
        result = svc.settle(record, entries) or result
    end
    local bonus = OA.round(account.bonus or 0)
    account.bonus = 0
    -- The infection handling fee (a zombie wound not yet tested for, or a known infection) comes off this flight's
    -- delivery credits, the requests' among them, before a debt takes its share.
    local fee, feeRate = OA.Infection.fee(record, result.credits or 0)
    local gain = (result.credits or 0) - fee + bonus
    local balanceBefore = account.credits
    local debtPaid
    account.credits, debtPaid = Rules.applyGain(account.credits, gain)

    -- 2. Trust, and what passing a stage or a milestone brings (OA.Trust.add puts the shared serums into the account).
    local events = {}
    if (result.trust or 0) > 0 then
        events = Rules.stageEvents(svc.trustAdd(record, result.trust))
    end

    -- 3. The orders, in order, with what the balance allows.
    local balance, spent, orderResults, items = Rules.payOrders(account.credits, call.orders or {}, svc.shop)
    account.credits = balance

    -- 3b. The flight support requests: paid from what is left and applied at once (a box this settlement returns
    -- already has the new capacity). One the balance cannot pay waits for the next settlement.
    local support = {}
    if OA.Support then account.credits, support = OA.Support.settle(record, account.credits) end

    -- 4. The crate: what was bought, shared serums, what others queued, and now and then a small extra.
    local cargo = {}
    for _, spec in ipairs(items) do cargo[#cargo + 1] = Settle.markBought(spec, record, now) end
    local gifts = {}
    for _, spec in ipairs(sharedSerumSpecs(account, record, now)) do
        cargo[#cargo + 1] = spec
        gifts[#gifts + 1] = { type = spec.type, count = spec.count }
    end
    for _, spec in ipairs(Trade.takeDrop(record)) do
        cargo[#cargo + 1] = spec
        gifts[#gifts + 1] = { type = spec.type, count = spec.count }
    end
    local bonusKey
    if (account.stage or 0) >= Settle.BONUS_FROM_STAGE and #cargo > 0 and svc.rnd(1, 100) <= Settle.BONUS_CHANCE then
        local pick = Settle.BONUS_POOL[svc.rnd(1, #Settle.BONUS_POOL)]
        cargo[#cargo + 1] = { type = pick.type, count = pick.count }
        bonusKey = pick.key
    end

    -- 5. The sealed boxes leave the record; an empty box comes back for the active one, to its spot.
    local removals, newBox, spot = {}, nil, nil
    local activeBefore = Boxes.active(record)
    local activeSealed = false
    local reissue = call.kind == "reissue"
    for _, box in ipairs(sealed) do
        removals[#removals + 1] = { id = box.id, x = box.x, y = box.y, z = box.z }
        local _, wasActive = Boxes.remove(record, box.id)
        if wasActive then activeSealed = true end
    end
    if activeSealed and activeBefore and not reissue then
        spot = { x = activeBefore.x, y = activeBefore.y, z = activeBefore.z }
        newBox = Boxes.add(record, { state = "placed", x = spot.x, y = spot.y, z = spot.z, active = true })
    elseif activeBefore and Boxes.get(record, activeBefore.id) then
        spot = { x = activeBefore.x, y = activeBefore.y, z = activeBefore.z }
    end
    -- A reissue brings a new active box to a spot the physical part finds near the terminal.
    if reissue then
        newBox = Boxes.add(record, { state = "placed", x = call.x, y = call.y, z = call.z, active = true })
        spot = nil
    end

    -- 6. The receipt: its serial and the last settlement's summary.
    local receipt = {
        at = now,
        kind = reissue and "reissue" or "settle",
        oldForm = svc.oldForm and true or nil,
        number = record.number,
        boxes = #sealed,
        credits = result.credits or 0,
        fee = fee > 0 and fee or nil,
        feeRate = fee > 0 and feeRate or nil,
        trust = result.trust or 0,
        bonus = bonus,
        debtPaid = debtPaid,
        spent = spent,
        balanceBefore = balanceBefore,
        balance = account.credits,
        lines = receiptLines(result.lines),
        orders = orderResults,
        gifts = gifts,
        bonusNote = bonusKey,
        events = events,
        cashTrust = result.cashTrust,
        support = #support > 0 and support or nil,
    }
    local key, args = Trade.noteFor(record, receipt)
    if key then receipt.note = { key = key, args = args } end
    receipt = Ledger.add(record, receipt, day)

    local plan = {
        receipt = receipt,
        removals = removals,
        newBox = newBox,
        cargo = cargo,
        spot = spot,
        reissue = reissue,
        events = events,
        result = result,
        support = support,
    }
    Trade.fireSettled(record, { receipt = receipt, credits = result.credits, trust = result.trust,
        lines = result.lines, events = events, boxes = #sealed })
    return plan
end

return Settle
