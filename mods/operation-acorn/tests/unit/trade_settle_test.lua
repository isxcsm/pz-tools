-- What a helicopter does on arrival: settles the sealed boxes, repays a debt, pays orders with partial delivery,
-- loads the crate, takes boxes away and returns one empty box, writes the receipt.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Ledger"
require "OperationAcorn/Trade/Rules"
require "OperationAcorn/Trade/Settle"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Trade, Boxes, Ledger, Settle = OA.Trade, OA.Trade.Boxes, OA.Trade.Ledger, OA.Trade.Settle

local function newRecord(credits)
    local record = OA.Store.ensure("rec", "Tester")
    local account = Trade.account(record)
    account.credits = credits or 0
    return record
end

-- Services: a settlement worth `credits`/`trust`, a trust that passes the stages in `events`, and a two-entry shop.
local function services(options)
    options = options or {}
    local sold = {}
    local svc
    svc = {
        now = options.now or 100,
        day = options.day or 4,
        settled = {},
        settle = function(record, entries)
            svc.settled[#svc.settled + 1] = entries
            return { credits = options.credits or 0, trust = options.trust or 0, lines = options.lines or {},
                cashTrust = 0 }
        end,
        trustAdd = function(record, amount)
            record.trade.trust = (record.trade.trust or 0) + amount
            record.trade.sharedSerums = (record.trade.sharedSerums or 0) + (options.serums or 0)
            return options.events or {}
        end,
        rnd = function(a, b) return options.roll or b end,
        onStage = options.onStage,
        shop = {
            entry = function(line) return line.id == "cheap" and { id = "cheap" } or line.id == "dear" and { id = "dear" } or nil end,
            available = function() return true end,
            price = function(entry) return entry.id == "cheap" and 100 or 1000 end,
            bought = function(entry) sold[entry.id] = (sold[entry.id] or 0) + 1 end,
            items = function(entry) return { { type = "Base." .. entry.id, count = 1 } } end,
        },
    }
    svc.sold = sold
    return svc
end

local function seal(record, spot, entries, active)
    local box = Boxes.add(record, { x = spot, y = 0, z = 0, active = active })
    Boxes.seal(record, box.id, entries or { { info = { fullType = "Base.Rag" }, count = 2 } })
    return box
end

test("a delivery pays credits and trust and returns an empty box to the active spot", function()
    local record = newRecord(500)
    local box = seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ credits = 1000, trust = 12, lines = { { name = "Base.Rag", count = 2, credits = 1000 } } }))
    eq(record.trade.credits, 1500)
    eq(record.trade.trust, 12)
    eq(plan.receipt.credits, 1000)
    eq(plan.receipt.debtPaid, 0)
    eq(plan.receipt.balance, 1500)
    eq(plan.receipt.boxes, 1)
    eq(#plan.removals, 1)
    eq(plan.removals[1].id, box.id)
    eq(plan.removals[1].x, 10)
    truthy(plan.newBox, "an empty box comes back")
    eq(plan.newBox.x, 10)
    eq(plan.newBox.state, "placed")
    eq(Boxes.active(record), plan.newBox)
    eq(Boxes.get(record, box.id), nil, "the sealed box left the record")
    eq(plan.spot.x, 10)
    eq(record.trade.serial, plan.receipt.id, "the receipt has the next serial")
    local last = Ledger.last(record)
    eq(last.credits, 1000)
    eq(last.trust, 12)
    eq(last.boxes, 1)
end)

test("only one empty box returns and previous boxes are just taken", function()
    local record = newRecord(0)
    local prev1 = seal(record, 5, nil, false)
    local prev2 = seal(record, 6, nil, false)
    local active = seal(record, 7, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local svc = services({ credits = 300, trust = 3 })
    local plan = Settle.run(record, svc)
    eq(#plan.removals, 3)
    eq(#svc.settled[1], 3, "one settlement for all the entries")
    local count = 0
    for _ in ipairs(Boxes.all(record)) do count = count + 1 end
    eq(count, 1, "just the returned box")
    eq(plan.newBox.x, 7)
    eq(Boxes.get(record, prev1.id), nil)
    eq(Boxes.get(record, prev2.id), nil)
end)

test("an open active box stays and no box comes back", function()
    local record = newRecord(1000)
    local active = Boxes.add(record, { x = 7, y = 0, z = 0 })
    local sealedPrev = seal(record, 3, nil, false)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ credits = 50, trust = 1 }))
    eq(plan.newBox, nil)
    eq(Boxes.active(record), active)
    eq(plan.spot.x, 7, "the crate comes to the active box")
    eq(#plan.removals, 1)
end)

test("an orders-only call settles nothing and still pays the orders", function()
    local record = newRecord(450)
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal",
        orders = { { id = "cheap", count = 3 }, { id = "dear", count = 1 } } }
    local svc = services({ credits = 999 })
    local plan = Settle.run(record, svc)
    eq(#svc.settled, 0, "no sealed box, no settlement")
    eq(plan.receipt.credits, 0)
    eq(record.trade.credits, 150, "three cheap ones, the dear one is not affordable")
    eq(plan.receipt.orders[1].delivered, 3)
    eq(plan.receipt.orders[2].delivered, 0)
    eq(plan.receipt.orders[2].reason, "credits")
    eq(plan.receipt.spent, 300)
    eq(#plan.cargo, 3)
    eq(plan.cargo[1].mod.OA_Bought, true)
    eq(svc.sold.cheap, 3)
end)

test("the settlement repays a debt before the orders", function()
    local record = newRecord(-800)
    seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = { { id = "cheap", count = 5 } } }
    local plan = Settle.run(record, services({ credits = 1000, trust = 10 }))
    eq(plan.receipt.debtPaid, 800)
    -- 1000 - 800 = 200 left: two cheap ones.
    eq(plan.receipt.orders[1].delivered, 2)
    eq(record.trade.credits, 0)
end)

test("a debt that stays blocks the orders", function()
    local record = newRecord(-800)
    seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = { { id = "cheap", count = 5 } } }
    local plan = Settle.run(record, services({ credits = 300, trust = 10 }))
    eq(plan.receipt.debtPaid, 300)
    eq(record.trade.credits, -500)
    eq(plan.receipt.orders[1].reason, "debt")
    eq(#plan.cargo, 0)
end)

test("the discovery bonus comes with the settlement and starts again", function()
    local record = newRecord(0)
    record.trade.bonus = 250
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services())
    eq(record.trade.credits, 250)
    eq(record.trade.bonus, 0)
    eq(plan.receipt.bonus, 250)
end)

test("stage events bring shared serums into the crate", function()
    local record = newRecord(0)
    seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ credits = 100, trust = 800, events = { { kind = "stage", n = 1 }, { kind = "stage", n = 2 }, { kind = "milestone", n = 1 } }, serums = 2 }))
    eq(#plan.events, 3)
    eq(plan.cargo[1].type, "OperationAcorn.UpgradeSerumShared")
    eq(plan.cargo[1].count, 2, "stage 2 and the milestone")
    eq(plan.cargo[1].mod.OA_Owner, record.id)
    eq(plan.cargo[1].mod.OA_Issued, 100)
    eq(record.trade.sharedSerums, 0, "the account starts again")
    eq(plan.receipt.gifts[1].count, 2)
end)

test("serums and cure drugs are issued to the record", function()
    local spec = Settle.markBought({ type = "OperationAcorn.CureSerum" }, { id = "r1" }, 42)
    eq(spec.mod.OA_Bought, true)
    eq(spec.mod.OA_Issued, 42)
    eq(spec.mod.OA_Owner, "r1")
    local plain = Settle.markBought({ type = "Base.Battery" }, { id = "r1" }, 42)
    eq(plain.mod.OA_Bought, true)
    eq(plain.mod.OA_Issued, nil)
    eq(Settle.isIssued("OperationAcorn.UpgradeSerumScout"), true)
    eq(Settle.isIssued("OperationAcorn.DelayDrug"), true)
    eq(Settle.isIssued("OperationAcorn.MeteorFragment"), false)
end)

test("items others queued and a small extra come with the crate", function()
    local record = newRecord(0)
    record.trade.stage = 2
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    Trade.addToDrop(record, { "OperationAcorn.SomeDocument", { type = "Base.Pen", count = 2, junk = "dropped" } })
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    -- roll 1 is within the chance: the first pool item comes.
    local plan = Settle.run(record, services({ roll = 1 }))
    eq(#plan.cargo, 3)
    eq(plan.cargo[1].type, "OperationAcorn.SomeDocument")
    eq(plan.cargo[2].count, 2)
    eq(plan.cargo[2].junk, nil, "only the known fields stay")
    eq(plan.cargo[3].type, "Base.Battery")
    eq(plan.receipt.bonusNote, "IGUI_OA_Trade_Bonus_Battery")
    eq(#Trade.takeDrop(record), 0, "the queue is emptied")
end)

test("no extra before stage 2 and none for an empty crate", function()
    local record = newRecord(0)
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    Trade.addToDrop(record, { "Base.Pen" })
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ roll = 1 }))
    eq(#plan.cargo, 1)
    eq(plan.receipt.bonusNote, nil)
    local record2 = OA.Store.ensure("other", "O")
    Trade.account(record2).stage = 3
    Boxes.add(record2, { x = 7, y = 0, z = 0 })
    Trade.heli(record2).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan2 = Settle.run(record2, services({ roll = 1 }))
    eq(#plan2.cargo, 0, "nothing to send, so no extra either")
end)

test("a reissue brings one new active box and takes the sealed ones", function()
    local record = newRecord(-500)
    local oldActive = seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "reissue", x = 40, y = 50, z = 0, orders = {} }
    local plan = Settle.run(record, services({ credits = 2000, trust = 5 }))
    eq(plan.reissue, true)
    eq(plan.receipt.kind, "reissue")
    eq(#plan.removals, 1)
    eq(plan.newBox.x, 40)
    eq(plan.newBox.y, 50)
    eq(Boxes.active(record), plan.newBox)
    eq(plan.spot, nil, "the physical part looks for a clear spot near the terminal")
    local count = 0
    for _ in ipairs(Boxes.all(record)) do count = count + 1 end
    eq(count, 1)
    eq(record.trade.credits, 1500)
end)

test("the hooks hear of the settlement and a failing one does not stop the rest", function()
    local record = newRecord(0)
    seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local heard
    Trade.onSettled(function() error("boom") end)
    Trade.onSettled(function(r, result) heard = result end)
    Settle.run(record, services({ credits = 70, trust = 1 }))
    truthy(heard)
    eq(heard.credits, 70)
    eq(heard.boxes, 1)
end)

test("the note providers write the team's line", function()
    local record = newRecord(0)
    seal(record, 10, nil, true)
    Trade.addNoteProvider(function() return nil end)
    Trade.addNoteProvider(function(r, receipt) return "IGUI_OA_Trade_Note_Test", { receipt.boxes } end)
    Trade.addNoteProvider(function() return "IGUI_OA_Trade_Note_Later" end)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ credits = 70, trust = 1 }))
    eq(plan.receipt.note.key, "IGUI_OA_Trade_Note_Test")
    eq(plan.receipt.note.args[1], 1)
end)

test("the providers see the crate: the orders, the cargo so far, the number the manifest gets", function()
    local record = newRecord(5000)
    seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = { { id = "cheap", count = 2 } } }
    local next = Ledger.nextSerial(record)
    local seen
    Trade.addNoteProvider(function(r, draft) seen = draft; return nil end)
    Settle.run(record, services({ credits = 70, trust = 1, lines = { { name = "Base.Rag", count = 2, credits = 70 } } }))
    eq(seen.boxes, 1)
    eq(seen.serial, next)
    eq(seen.lastSerial, 0)
    eq(#seen.orders, 1)
    eq(seen.orders[1].delivered, 2)
    eq(seen.cargo[1].type, "Base.cheap")
    eq(#seen.lines, 1)
end)

test("a remark that encloses things puts them in the crate, and the chance extra stays away", function()
    local record = newRecord(0)
    record.trade.stage = 2
    seal(record, 10, nil, true)
    Trade.addNoteProvider(function()
        return "IGUI_OA_Story_Note_battery", { "0347" }, { items = { { type = "Base.Battery", count = 2 } } }
    end)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    -- roll 1 would bring the chance extra, a pair of batteries in the pool's first place.
    local plan = Settle.run(record, services({ roll = 1, credits = 70, trust = 1 }))
    eq(#plan.cargo, 1, "the batteries of the remark alone")
    eq(plan.cargo[1].type, "Base.Battery")
    eq(plan.cargo[1].count, 2)
    eq(plan.receipt.bonusNote, nil, "the same line is not on the paper twice")
    eq(plan.receipt.note.key, "IGUI_OA_Story_Note_battery")
end)

test("a flight with nothing to carry has no remark, and the providers are not asked", function()
    local record = newRecord(0)
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    local asked = 0
    Trade.addNoteProvider(function() asked = asked + 1; return "IGUI_OA_Story_Note_battery", {}, { items = { { type = "Base.Battery", count = 2 } } } end)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ roll = 1 }))
    eq(asked, 0)
    eq(#plan.cargo, 0)
    eq(plan.receipt.note, nil)
end)

test("the crate providers' papers go in the crate and are listed on the manifest", function()
    local record = newRecord(0)
    seal(record, 10, nil, true)
    Trade.addCrateProvider(function(r, draft)
        return { { type = "OperationAcorn.AnalysisReply", count = 1, mod = { OA_Doc = "reply_first" }, junk = 1 } }
    end)
    Trade.addCrateProvider(function() error("boom") end)
    Trade.addCrateProvider(function() return nil end)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ credits = 70, trust = 1 }))
    eq(#plan.cargo, 1)
    eq(plan.cargo[1].type, "OperationAcorn.AnalysisReply")
    eq(plan.cargo[1].mod.OA_Doc, "reply_first")
    eq(plan.cargo[1].junk, nil, "an item spec keeps its known fields only")
    eq(plan.receipt.gifts[1].type, "OperationAcorn.AnalysisReply")
end)

test("flight support requests are paid after the orders, from what is left", function()
    local record = newRecord(0)
    seal(record, 10, nil, true)
    record.trade.stage = 5
    OA.Support.request(record, "box", 1, true)       -- 30,000
    OA.Support.request(record, "reqcount", 1, true)  -- 20,000
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = { { id = "cheap", count = 3 } } }
    local plan = Settle.run(record, services({ credits = 100000, trust = 5 }))
    eq(plan.receipt.spent, 300)
    eq(record.trade.credits, 100000 - 300 - 30000 - 20000)
    eq(plan.receipt.balance, record.trade.credits)
    eq(#plan.support, 2)
    eq(#plan.receipt.support, 2)
    local s = plan.receipt.support[1]
    eq(s.id, "box"); eq(s.from, 0); eq(s.to, 1); eq(s.price, 30000); eq(s.paid, true)
    eq(plan.receipt.support[2].id, "reqcount"); eq(plan.receipt.support[2].paid, true)
    eq(record.trade.levels.box, 1); eq(record.trade.levels.reqcount, 1)
    eq(#OA.Support.requests(record), 0)
    eq(plan.support[1].id, "box")
end)

test("a support request only gets what the orders left: an order that eats the balance leaves it waiting", function()
    local record = newRecord(0)
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    record.trade.stage = 5
    OA.Support.request(record, "reqcount", 1, true)  -- 20,000
    record.trade.credits = 20250
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = { { id = "cheap", count = 3 } } }
    local plan = Settle.run(record, services())
    eq(record.trade.credits, 19950, "the orders were paid first")
    eq(#plan.receipt.support, 1)
    eq(plan.receipt.support[1].paid, false)
    eq(record.trade.pendingLevels.reqcount, 1, "it waits for the next settlement")
    eq(OA.Support.level(record, "reqcount"), 0, "nothing was bought")
end)

test("a support request the balance cannot pay waits; the one after it is still paid", function()
    local record = newRecord(25000)
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    record.trade.stage = 5
    OA.Support.request(record, "box", 1, true)       -- 30,000
    OA.Support.request(record, "reqcount", 1, true)  -- 20,000
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services())
    eq(plan.receipt.support[1].id, "box"); eq(plan.receipt.support[1].paid, false)
    eq(plan.receipt.support[2].id, "reqcount"); eq(plan.receipt.support[2].paid, true)
    eq(record.trade.credits, 5000)
    eq(record.trade.pendingLevels.box, 1)
    eq(record.trade.levels.reqcount, 1)
end)

test("the credits of the sealed boxes pay for the support too", function()
    local record = newRecord(0)
    seal(record, 10, nil, true)
    record.trade.stage = 5
    OA.Support.request(record, "call", 1, true)      -- 40,000
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ credits = 45000, trust = 1 }))
    eq(plan.receipt.support[1].paid, true)
    eq(record.trade.credits, 5000)
end)

test("a settlement without support requests has no support in the receipt", function()
    local record = newRecord(500)
    seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    local plan = Settle.run(record, services({ credits = 10 }))
    eq(plan.receipt.support, nil)
    eq(#plan.support, 0)
    eq(record.trade.credits, 510)
end)

test("a settlement that applies support changes the rewards the same flight reads", function()
    local record = newRecord(100000)
    Boxes.add(record, { x = 7, y = 0, z = 0 })
    eq(OA.Trust.rewards(record).boxCapacity, 50)
    record.trade.stage = 3
    OA.Support.request(record, "box", 1, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    Settle.run(record, services())
    eq(OA.Trust.rewards(record).boxCapacity, 100)
end)

-- ---- the infection handling fee (DESIGN-terminal 17.3) ---------------------------------------------------------------

local function flight(record, options)
    seal(record, 10, nil, true)
    Trade.heli(record).call = { at = 90, arrive = 100, kind = "normal", orders = {} }
    return Settle.run(record, services(options))
end

test("an untested zombie wound or a known infection takes 30% of the delivery credits, on the receipt", function()
    for i, set in ipairs({ function(r) OA.Infection.wounded(r, "scratch", 0) end,
                           function(r) OA.Infection.tested(r, true, 0.4) end }) do
        local record = OA.Store.ensure("fee" .. i, "Tester")
        OA.Trade.account(record).credits = 500
        set(record)
        local plan = flight(record, { credits = 1000, trust = 10 })
        eq(record.trade.credits, 500 + 700, "the credits less the fee")
        eq(plan.receipt.credits, 1000, "the receipt keeps what was settled")
        eq(plan.receipt.fee, 300)
        eq(plan.receipt.feeRate, 0.3)
        eq(record.trade.trust, 10, "the trust is not touched")
        eq(plan.receipt.balance, 1200)
    end
end)

test("no fee without an untested wound or a known infection, and none after a negative test", function()
    local record = newRecord(500)
    local plan = flight(record, { credits = 1000 })
    eq(record.trade.credits, 1500)
    eq(plan.receipt.fee, nil)
    eq(plan.receipt.feeRate, nil)
    local other = OA.Store.ensure("rec2", "Tester")
    OA.Trade.account(other).credits = 0
    OA.Infection.wounded(other, "cut", 0)
    OA.Infection.tested(other, false)
    plan = flight(other, { credits = 1000 })
    eq(other.trade.credits, 1000)
    eq(plan.receipt.fee, nil)
end)

test("the fee comes off the delivery credits before a debt and not off the bonus or the orders-only call", function()
    local record = newRecord(-800)
    OA.Infection.wounded(record, "bite", 0)
    record.trade.bonus = 100
    local plan = flight(record, { credits = 1000, trust = 10 })
    eq(plan.receipt.fee, 300)
    eq(record.trade.credits, -800 + 700 + 100, "700 of the delivery and the whole bonus")
    eq(plan.receipt.debtPaid, 800)
    local orders = OA.Store.ensure("rec3", "Tester")
    OA.Trade.account(orders).credits = 450
    OA.Infection.wounded(orders, "scratch", 0)
    Boxes.add(orders, { x = 7, y = 0, z = 0 })
    Trade.heli(orders).call = { at = 90, arrive = 100, kind = "normal", orders = { { id = "cheap", count = 3 } } }
    plan = Settle.run(orders, services({ credits = 999 }))
    eq(plan.receipt.fee, nil, "nothing was delivered: nothing to take a share of")
    eq(orders.trade.credits, 150)
end)

test("the fee is the same before and after a test shows the infection, so the receipt tells nothing", function()
    local a, b = newRecord(0), OA.Store.ensure("rec2", "Tester")
    OA.Trade.account(b).credits = 0
    OA.Infection.wounded(a, "scratch", 0)           -- untested, perhaps no infection at all
    OA.Infection.wounded(b, "scratch", 0)
    OA.Infection.tested(b, true, 0.2)               -- known
    local planA = flight(a, { credits = 1000 })
    local planB = flight(b, { credits = 1000 })
    eq(planA.receipt.fee, planB.receipt.fee)
    eq(a.trade.credits, b.trade.credits)
end)
