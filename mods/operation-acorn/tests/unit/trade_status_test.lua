-- The status tab's model (Trade/StatusModel): the helicopter's state and the waybill's sums, what each level of the
-- trust road opens, the flight support cards' states, the infection box, the record's texts, the field terminal's
-- first-open board and the layouts at the default and the smallest window. getText here gives the key and its
-- arguments, so the texts are checked by their keys.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/StatusModel"
local OA = OperationAcorn
local M = OA.Trade.StatusModel
local Boxes, Ledger = OA.Trade.Boxes, OA.Trade.Ledger

-- Every item type is defined (another test file may leave a script manager of its own behind).
getScriptManager = function() return { FindItem = function() return {} end } end

local function newRecord(stage, milestones, credits)
    local r = OA.Store.ensure("st", "Tester")
    r.trade = { credits = credits or 50000, trust = 0, stage = stage or 0, milestones = milestones or 0, bonus = 0,
        sharedSerums = 0, levels = {} }
    -- (its first supply came: the terminal is its own)
    r.first = { done = true }
    OA.Trust.reset()
    return r
end

local function ids(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.id end
    return table.concat(out, ",")
end

local function has(list, text)
    for _, s in ipairs(list) do if s == text then return true end end
    return false
end

-- Parts and names ----------------------------------------------------------------------------------------------------

test("a translated text is cut into parts that know their argument", function()
    local parts = M.parts("IGUI_OA_Status_LastSettleLine", "2일 전", "18,400", "+172")
    eq(M.plain(parts), "IGUI_OA_Status_LastSettleLine 2일 전 18,400 +172")
    eq(parts[1].arg, nil); eq(parts[1].s, "IGUI_OA_Status_LastSettleLine ")
    eq(parts[2].arg, 1); eq(parts[2].s, "2일 전")
    eq(parts[4].arg, 2); eq(parts[4].s, "18,400")
    eq(parts[6].arg, 3); eq(parts[6].s, "+172")
    -- A language that puts the arguments in another order keeps their numbers.
    local swapped = M.split("a \0012\003X\002 b \0011\003Y\002")
    eq(swapped[2].arg, 2); eq(swapped[2].s, "X"); eq(swapped[4].arg, 1); eq(swapped[4].s, "Y")
end)

test("the road's nodes and the levels' names: stages, the levels after them, the handover, the endless ones", function()
    eq(M.nodeName(3), "IGUI_OA_Status_Node 3 IGUI_OA_Econ_Stage_3")
    eq(M.nodeName(6), "IGUI_OA_Econ_Stage_Milestone 6")
    eq(M.nodeName(8, 8), "IGUI_OA_Status_Node 8 IGUI_OA_Terminal_LevelHandover", "the handover named once reached")
    eq(M.nodeName(8, 7), "IGUI_OA_Econ_Stage_Milestone 8", "not named ahead: the story's turn")
    eq(M.nodeName(8), "IGUI_OA_Econ_Stage_Milestone 8")
    eq(M.levelName(8, 9), "IGUI_OA_Status_LevelName 8 IGUI_OA_Terminal_LevelHandover")
    eq(M.levelName(8, 2), "IGUI_OA_Econ_Stage_Milestone 8")
    eq(M.nodeName(9), "IGUI_OA_Status_NodeLast 9")
    eq(M.levelName(2), "IGUI_OA_Status_LevelName 2 IGUI_OA_Econ_Stage_2")
    eq(M.levelName(7), "IGUI_OA_Econ_Stage_Milestone 7")
    eq(M.levelName(9), "IGUI_OA_Status_LevelFrom 9")
    eq(M.threshold(1), 0); eq(M.threshold(3), 900); eq(M.threshold(6), 3400); eq(M.threshold(9), 11800)
end)

-- What each level opens -----------------------------------------------------------------------------------------------

test("each level's goods split into every terminal's and the field terminal's lane", function()
    local lanes = M.lanes()
    local a2, b2 = ids(lanes[2].all), ids(lanes[2].field)
    truthy(string.find(a2, "petrol_can", 1, true)); truthy(string.find(a2, "field_terminal", 1, true))
    truthy(string.find(a2, "bait_trap", 1, true))
    truthy(string.find(b2, "^team_fuel_can,team_locker,team_crate,fabric_cutter,log_saw,field_"), b2)
    local tools = 0
    for _, e in ipairs(lanes[2].field) do if e.group == M.TOOLS then tools = tools + 1 end end
    eq(tools, 20, "the field tools of the level, each a good of its own (the screens show them as one row)")
    eq(string.find(ids(lanes[1].all), "serum_", 1, true), nil, "the upgrade serums have their own section")
    eq(string.find(ids(lanes[1].all), "box_reissue", 1, true), nil, "the box is the reissue button's")
    eq(ids(lanes[9].all), ""); eq(ids(lanes[9].field), "")
    eq(#lanes[6].field, 8, "the kits at the first level after the stages (the weapon kits too)")
    local rec = { dense = { got = {} } }
    eq(#M.lanes(rec)[6].field, 4, "a record's road: no weapon kit before a dense place is cleared")
    rec.dense.got.p1 = "damage"
    eq(ids(M.lanes(rec)[6].field):find("kit_weapon_damage", 1, true) ~= nil, true, "the kit of the place cleared")
    eq(#M.lanes(rec)[6].field, 5)
    SandboxVars.OperationAcorn.KitsForSale = false
    eq(#M.lanes()[6].field, 0, "not when kits are off")
end)

test("the short words and the full lines of what a level opens", function()
    local c1 = M.chipsA(1)
    eq(c1[1], "IGUI_OA_Status_Chip_missions"); eq(c1[2], "IGUI_OA_Status_Chip_common"); eq(#c1, 2)
    local c2 = M.chipsA(2)
    eq(c2[1], "IGUI_OA_Status_Chip_rare"); eq(c2[2], "IGUI_OA_Status_Chip_serum")
    local c6 = M.chipsA(6)
    eq(c6[1], "IGUI_OA_Status_Chip_accel 10"); eq(c6[2], "IGUI_OA_Status_Chip_serum")
    local c8 = M.chipsA(8, 8)
    eq(c8[1], "IGUI_OA_Status_Chip_handover"); eq(c8[2], "IGUI_OA_Status_Chip_accel 20")
    eq(M.chipsA(8, 1)[1], "IGUI_OA_Status_Chip_accel 20", "no handover ahead of it")
    local c9 = M.chipsA(9)
    eq(c9[#c9], "IGUI_OA_Status_Chip_endless")
    local m8 = M.moreA(8, 8)
    eq(table.concat(m8, "|"), "IGUI_OA_Status_More_handover|IGUI_OA_Status_More_accel 20|IGUI_OA_Status_More_kitVoucher|"
        .. "IGUI_OA_Status_More_serum")
    eq(table.concat(M.moreA(8, 7), "|"), "IGUI_OA_Status_More_accel 20|IGUI_OA_Status_More_kitVoucher|IGUI_OA_Status_More_serum")
    eq(M.moreA(9)[1], "IGUI_OA_Status_More_serumEach")
    eq(#M.moreA(1), 2)
    eq(#M.moreA(4), 1, "a serum only")
    -- Every few milestones only, when the option says so.
    SandboxVars.OperationAcorn.SharedSerumMilestones = 2
    eq(has(M.chipsA(6), "IGUI_OA_Status_Chip_serum"), false)
    eq(has(M.chipsA(7), "IGUI_OA_Status_Chip_serum"), true)
end)

test("the field lane's words: special requests at 2, how many upgrades open, the box at the endless levels", function()
    local b2 = M.chipsB(2)
    eq(b2[1], "IGUI_OA_Status_Chip_special"); eq(b2[2], "IGUI_OA_Status_Chip_upgrades 4")
    eq(M.chipsB(3)[1], "IGUI_OA_Status_Chip_upgrades 6")
    eq(M.chipsB(6)[1], "IGUI_OA_Status_Chip_upgrades 3")
    eq(M.chipsB(7)[1], "IGUI_OA_Status_Chip_upgrades 6")
    eq(M.chipsB(8)[1], "IGUI_OA_Status_Chip_upgrades 2")
    eq(M.chipsB(9)[1], "IGUI_OA_Status_Chip_box 50")
    eq(#M.chipsB(1), 0)
    local ups = M.upgradeLines(5)
    eq(#ups, 6)
    truthy(has(ups, "IGUI_OA_Status_Bin_night"), "a yes-or-no upgrade by its own name")
    eq(ups[1], "IGUI_OA_Support_Name_box IGUI_OA_Support_V_box 200")
    eq(M.upgradeLines(1)[1], "IGUI_OA_Status_Nothing")
    eq(M.upgradeLines(9)[2], "IGUI_OA_Status_Up_boxPrice 40,000")
end)

test("where the road stands and the chosen level's note", function()
    local r = newRecord(2, 0)
    r.trade.trust = 864
    local at, frac = M.roadPosition(r)
    eq(at, 2); near(frac, (864 - 400) / (900 - 400), 1e-9)
    eq(M.plain(M.detailNote(r, 3)), "IGUI_OA_Status_TrustLeft 36")
    eq(M.plain(M.detailNote(r, 2)), "IGUI_OA_Status_Got")
    eq(M.plain(M.detailNote(r, 4)), "IGUI_OA_Status_AtTrust 1,500", "a later stage says its trust")
    eq(M.plain(M.detailNote(r, 9)), "IGUI_OA_Status_AtTrustOn 11,800")
    -- past the five stages, the next level is still the trust left
    r.trade.stage, r.trade.milestones, r.trade.trust = 5, 1, 3400
    eq(M.plain(M.detailNote(r, 7)), "IGUI_OA_Status_TrustLeft 2,100")
    eq(M.plain(M.detailNote(r, 8)), "IGUI_OA_Status_AtTrust " .. M.plain({ { s = OA.Trade.Text.credits(M.threshold(8)) } }))
    r.trade.stage, r.trade.milestones = 5, 6
    eq((M.roadPosition(r)), 9, "every level past 8 stands on the last node")
end)

-- Support -----------------------------------------------------------------------------------------------------------

test("an upgrade's state at the crude and at the field terminal", function()
    local r = newRecord(3, 0)
    local cur, nxt, state = M.upgradeState(r, "box", true)
    eq(cur, 0); eq(nxt, 1); eq(state, "avail")
    eq(select(3, M.upgradeState(r, "box", false)), "field", "open, but asked at the crude terminal")
    eq(select(3, M.upgradeState(r, "night", true)), "locked")
    r.trade.levels.forecast = 1
    eq(select(3, M.upgradeState(r, "forecast", true)), "max")
    r.trade.pendingLevels = { call = 1 }
    cur, nxt, state = M.upgradeState(r, "call", true)
    eq(state, "pending"); eq(nxt, 1)
    r.trade.credits = -10
    eq(select(3, M.upgradeState(r, "box", true)), "debt")
    eq(M.countAvail(r, true), 0, "none may be asked for in debt")
end)

test("how many may be asked for: none at the crude terminal, by group at the field terminal", function()
    local r = newRecord(2, 0)
    eq(M.countAvail(r, true), 4, "the call interval, the request count, the mission pay and days at stage 2")
    eq(M.countAvail(r, true, "heli"), 1); eq(M.countAvail(r, true, "trade"), 1); eq(M.countAvail(r, true, "mission"), 2)
    eq(M.countAvail(r, false), 0)
    r.trade.stage = 3
    eq(M.countAvail(r, true), 10)
    r.trade.pendingLevels = { box = 1 }
    eq(M.countAvail(r, true), 9, "one asked for is not counted")
end)

test("two values of one unit are written with the unit once", function()
    local a, b = M.shortPair("4~6시간", "3~4시간")
    eq(a, "4~6"); eq(b, "3~4시간")
    a, b = M.shortPair("3일", "2일")
    eq(a, "3"); eq(b, "2일")
    a, b = M.shortPair("+0%", "+5%")
    eq(a, "+0%"); eq(b, "+5%")
    a, b = M.shortPair("50", "100")
    eq(a, "50"); eq(b, "100")
    a, b = M.shortPair("낮에만", "밤에도")
    eq(a, "낮에만"); eq(b, "밤에도")
    eq(M.firstSentence("One. Two."), "One.")
end)

test("the ladder: every level, the box going on past its table", function()
    local rows = M.ladder("box", 0)
    eq(#rows, 7)
    eq(rows[1].level, 0); eq(rows[2].price, 30000); eq(rows[2].tier, 3)
    eq(rows[7].more, true); eq(rows[7].tier, 9); eq(rows[7].step, 40000)
    eq(rows[7].value, "IGUI_OA_Status_BoxOn IGUI_OA_Support_V_box 400")
    rows = M.ladder("box", 6)
    eq(#rows, 9, "the levels up to the one after the record's, then the 'and on' row")
    eq(rows[8].price, 300000); eq(rows[9].value, "IGUI_OA_Status_BoxOn IGUI_OA_Support_V_box 500")
    eq(#M.ladder("night", 0), 2)
end)

test("the requests for the form and the waybill, values shortened together", function()
    local r = newRecord(3, 0)
    r.trade.pendingLevels = { box = 1, call = 1 }
    local list = M.requests(r)
    eq(#list, 2)
    eq(list[1].id, "box"); eq(list[1].price, 30000)
    eq(list[1].from, "IGUI_OA_Support_V_box 50"); eq(list[1].to, "IGUI_OA_Support_V_box 100")
    eq(list[2].id, "call"); eq(list[2].price, 40000)
end)

-- The helicopter -------------------------------------------------------------------------------------------------

local function withBox(r, state)
    local box = Boxes.add(r, { x = 10, y = 10, z = 0 })
    if state then box.state = state end
    return box
end

test("the helicopter can be called: the call button on, the reissue off with its reason", function()
    local r = newRecord(2, 0)
    withBox(r)
    -- a box standing with nothing sealed or ordered: a flight for nothing is not made
    local s = M.heli(r, 100, 12)
    eq(s.state, "IGUI_OA_Status_Heli_Cannot")
    eq(s.subs[1].text, "IGUI_OA_Trade_Heli_Empty")
    eq(s.callable, false); eq(s.callWhy, "IGUI_OA_Trade_Reason_empty")
    r.orders = { cart = { { id = "x", count = 1 } } }
    eq(M.heli(r, 100, 12).callable, true, "an order alone is something to bring")
    r.orders = nil
    r.heli = { drop = { { type = "OperationAcorn.SampleCase", count = 1 } } }
    eq(M.heli(r, 100, 12).callable, true, "what the story sends (a mission's case) is something to bring")
    r.heli = nil
    Boxes.add(r, { state = "sealed", active = false })
    s = M.heli(r, 100, 12)
    eq(s.state, "IGUI_OA_Status_Heli_Ready"); eq(s.colour, "bright")
    eq(#s.subs, 0, "midday: no night line")
    eq(s.callable, true); eq(s.reissue, false)
    eq(s.reissueWhy, "IGUI_OA_Trade_Heli_ReissueOnly")
    s = M.heli(r, 100, 16)
    eq(s.subs[1].text, "IGUI_OA_Status_Heli_Night", "four to six hours from 16:00 reaches the night")
    eq(s.subs[1].colour, "warn"); eq(s.night, true)
end)

test("on its way, waiting, no box, carried, and in debt", function()
    local r = newRecord(2, 0)
    withBox(r)
    r.heli = { call = { at = 90, arrive = 96 }, next = 162 }
    local s = M.heli(r, 92, 10)
    eq(s.state, "IGUI_OA_Status_Heli_Coming"); eq(s.eta.from, 90); eq(s.eta.to, 96)
    truthy(string.find(s.subs[1].text, "IGUI_OA_Status_Heli_Arrive", 1, true))
    eq(s.callable, false); eq(s.callWhy, "IGUI_OA_Trade_Reason_pending"); eq(s.reissueWhy, "IGUI_OA_Trade_Reason_pending")
    r.heli = { next = 162 }
    s = M.heli(r, 100, 10)
    eq(s.state, "IGUI_OA_Status_Heli_Cannot"); eq(s.nextAt, 162)
    eq(s.callWhy, "IGUI_OA_Trade_Reason_wait")
    r.heli = {}
    Boxes.data(r).active = nil
    s = M.heli(r, 100, 10)
    eq(s.subs[1].text, "IGUI_OA_Trade_Heli_NoBox"); eq(s.reissue, true); eq(s.callWhy, "IGUI_OA_Trade_Reason_noBox")
    withBox(r, "carried")
    s = M.heli(r, 100, 10)
    eq(s.subs[1].text, "IGUI_OA_Trade_Heli_BoxCarried")
    r.trade.credits = -12300
    s = M.heli(r, 100, 10)
    eq(s.subs[#s.subs].text, "IGUI_OA_Status_Heli_Debt"); eq(s.subs[#s.subs].colour, "bad")
end)

test("a call reaches the night unless night drops are bought", function()
    local rewards = { nightDrop = false, arrival = { min = 4, max = 6 } }
    eq(M.nightCall(8, rewards), false)
    eq(M.nightCall(14, rewards), true, "14 + 6 = 20, past 19:00")
    eq(M.nightCall(2, rewards), true, "02 + 4 = 06, before 07:00")
    rewards.nightDrop = true
    eq(M.nightCall(14, rewards), false)
end)

test("the four values of the helicopter now, the last settlement, the crates", function()
    local r = newRecord(0, 0)
    local spec = M.spec(r)
    eq(spec[1].value, "IGUI_OA_Support_V_box 50")
    eq(spec[2].value, "IGUI_OA_Support_V_arrive 4 6")
    eq(spec[3].value, "IGUI_OA_Support_V_call 3")
    eq(spec[4].value, "IGUI_OA_Support_night_false")
    eq(M.lastSettle(r, 100), nil)
    r.trade.lastSettle = { at = 50, credits = 18400, trust = 171.6, boxes = 1 }
    eq(M.plain(M.lastSettle(r, 100)), "IGUI_OA_Status_LastSettleLine IGUI_OA_Status_Ago_Days 2 18,400 +172")
    eq(M.ago(0.5), "IGUI_OA_Status_Ago_Now"); eq(M.ago(5.9), "IGUI_OA_Status_Ago_Hours 5")
    eq(M.crates({}, 0, 0), nil)
    local text = M.crates({ { x = 300, y = 0 }, { x = 0, y = 400 } }, 0, 0)
    truthy(string.find(text, "^IGUI_OA_Status_CratesMore"), text)
    truthy(string.find(text, "IGUI_OA_Place_Dir_E", 1, true), "the nearest one, to the east")
end)

test("the delivery box's line: where the active box stands, sealed, carried off, or still in its crate", function()
    local Boxes = OA.Trade.Boxes
    local r = { id = 1, number = 1 }
    eq(M.box(r, 0, 0), nil, "none")
    local box = Boxes.add(r, { state = "placed", x = 400, y = 0, z = 0 })
    local text = M.box(r, 0, 0)
    truthy(string.find(text, "^IGUI_OA_Place_Squares"), text)
    truthy(string.find(text, "IGUI_OA_Place_Dir_E", 1, true), "to the east")
    box.state = "sealed"
    truthy(string.find(M.box(r, 0, 0), "^IGUI_OA_Status_BoxSealed"))
    box.state = "carried"
    truthy(string.find(M.box(r, 0, 0), "^IGUI_OA_Status_BoxCarried"), "where it last stood")
    r.heli = { markers = { { kind = "crate", x = 400, y = 0 } } }
    truthy(string.find(M.box(r, 0, 0), "^IGUI_OA_Status_BoxInCrate"), "packed in the crate on its spot")
end)

test("the waybill's sums: the gain repays a debt first, orders wait while it is a debt", function()
    local r = M.receipt(48200, 31400, 25000, {})
    eq(r.after, 54600); eq(r.orders, 25000); eq(r.support, 0)
    r = M.receipt(-12300, 31400, 0, {})
    eq(r.after, 19100)
    r = M.receipt(-50000, 10000, 5000, {})
    eq(r.orders, 0); eq(r.after, -40000)
    r = M.receipt(63700, 38900, 60000, { 30000 })
    eq(r.support, 30000); eq(r.after, 12600)
    r = M.receipt(1000, 0, 0, { 30000, 500 })
    eq(r.support, 500, "a request the balance cannot pay waits"); eq(r.after, 500)
    eq(r.paid[1], false); eq(r.paid[2], true)
end)

test("the waybill of a placed box, an order and a request", function()
    local r = newRecord(3, 0, 48200)
    withBox(r)
    r.orders = { cart = { { id = "petrol_can", count = 1 } } }
    r.trade.pendingLevels = { box = 1 }
    local flight = OA.Trade.Estimate.flight(r)
    local w = M.waybill(r, flight)
    eq(w.serial, OA.Trade.Ledger.nextSerial(r), "the number of the manifest being written")
    truthy(w.serial >= OA.Trade.Ledger.FIRST_MIN, "a middle number")
    eq(w.send[1].name, "IGUI_OA_Status_SendPlaced")
    eq(#w.recv, 2)
    eq(w.recv[1].kind, "item"); eq(w.recv[1].price, "15,000"); eq(w.recv[1].type, "Base.PetrolCan")
    eq(w.recv[2].kind, "plan"); eq(w.recv[2].price, "30,000")
    eq(#w.calc, 3, "balance, orders, flight support")
    eq(w.calc[1].label, "IGUI_OA_Status_Calc_Balance"); eq(w.calc[1].amount, "48,200")
    eq(w.calc[2].amount, "-15,000"); eq(w.calc[3].amount, "-30,000")
    eq(w.total.amount, "3,200"); eq(w.total.colour, "value")
    eq(w.recv[2].waits, nil, "paid this flight")
    -- a balance short of it: the line waits for the next settlement and the sums leave it out
    r.trade.credits = 20000
    w = M.waybill(r, OA.Trade.Estimate.flight(r))
    eq(w.recv[2].waits, true)
    eq(#w.calc, 2, "balance, orders")
end)

test("the waybill lists what the story sends down, issued without a price", function()
    local r = newRecord(2, 0, 1000)
    withBox(r)
    r.heli = { drop = { { type = "OperationAcorn.SampleCase", count = 1 } } }
    local w = M.waybill(r, OA.Trade.Estimate.flight(r))
    eq(#w.recv, 1); eq(w.recvNone, nil)
    eq(w.recv[1].type, "OperationAcorn.SampleCase"); eq(w.recv[1].price, "IGUI_OA_Status_RecvSent")
    eq(w.total.amount, "1,000", "it costs nothing")
end)

test("the waybill while a call flies: its own orders, not the cart for the next", function()
    local r = newRecord(3, 0, 10000)
    withBox(r)
    r.orders = { cart = { { id = "petrol_can", count = 2 } } }
    r.heli = { call = { at = 0, arrive = 5, orders = { { id = "battery_pack", count = 1 } } } }
    local w = M.waybill(r, OA.Trade.Estimate.flight(r))
    eq(#w.recv, 1); eq(w.recv[1].price, "4,000")
    eq(w.total.amount, "6,000")
end)

test("the waybill with no box and in debt", function()
    local r = newRecord(2, 0, -12300)
    local w = M.waybill(r, OA.Trade.Estimate.flight(r))
    eq(w.send[1].name, "IGUI_OA_Status_SendNone"); eq(w.send[1].warn, true)
    eq(w.send[1].sub, "IGUI_OA_Status_SendNoneSub 10,000")
    eq(w.recvNone, "IGUI_OA_Status_RecvDebt")
    eq(w.calc[1].label, "IGUI_OA_Status_Calc_Debt"); eq(w.calc[1].colour, "bad"); eq(w.calc[1].amount, "-12,300")
    eq(w.total.colour, "bad")
    eq(M.waybill(newRecord(2, 0, 0), OA.Trade.Estimate.flight(newRecord(2, 0, 0))).recvNone, "IGUI_OA_Status_RecvNone")
end)

test("a fee from the infection part: the send line says it, the sum is named after it", function()
    local r = newRecord(3, 0, 1000)
    withBox(r)
    local flight = { boxes = 1, sealed = 38900, net = 27230, bonus = 0, fee = 11670, feeRate = 0.3 }
    local w = M.waybill(r, flight)
    eq(w.send[1].name, "IGUI_OA_Status_SendSealed 1"); eq(w.send[1].worth, "27,230")
    eq(w.send[1].sub, "IGUI_OA_Status_SendFee 30 11,670")
    eq(w.calc[2].label, "IGUI_OA_Status_Calc_SettleFee"); eq(w.calc[2].amount, "+27,230")
    eq(w.total.amount, "28,230")
end)

test("the sealed missions' rewards: their own line, in the gain and the balance after", function()
    local r = newRecord(3, 0, 1000)
    withBox(r)
    local flight = { boxes = 1, sealed = 0, net = 0, bonus = 0, fee = 0, feeRate = 0, missions = 22500 }
    local w = M.waybill(r, flight)
    eq(w.send[1].worth, "22,500", "what goes up earns the reward")
    eq(#w.calc, 2, "a box of the mission's item alone: no settlement line of nothing")
    eq(w.calc[2].label, "IGUI_OA_Status_Calc_Missions"); eq(w.calc[2].amount, "+22,500")
    eq(w.gain, 22500)
    eq(w.total.amount, "23,500")
    flight.sealed, flight.net = 4000, 4000
    w = M.waybill(r, flight)
    eq(w.send[1].worth, "26,500")
    eq(w.calc[2].label, "IGUI_OA_Status_Calc_Settle"); eq(w.calc[2].amount, "+4,000")
    eq(w.calc[3].label, "IGUI_OA_Status_Calc_Missions")
    eq(w.total.amount, "27,500")
end)

-- Infection, the tab's dot -------------------------------------------------------------------------------------------

test("the infection box: infected and held, a wound not tested, nothing", function()
    eq(M.infection(nil), nil)
    eq(M.infection({ infected = false, untested = false }), nil)
    local lines = M.infection({ infected = true, progress = 0.38, drug = { kind = "long", hoursLeft = 102.5 }, fee = 0.3 })
    eq(lines[1], "IGUI_OA_Status_Inf_Infected" .. OA.Trade.Text.DOT .. "IGUI_OA_Status_Inf_Drug_long IGUI_OA_Status_DaysHours 4 6")
    eq(lines[2], "IGUI_OA_Status_Inf_Paused 38" .. OA.Trade.Text.DOT .. "IGUI_OA_Status_Inf_Fee 30")
    lines = M.infection({ untested = true, fee = 0.3 })
    eq(lines[1], "IGUI_OA_Status_Inf_Untested"); eq(lines[2], "IGUI_OA_Status_Inf_Fee 30")
    lines = M.infection({ infected = true, drug = { kind = "short", hoursLeft = 5 } })
    eq(lines[1], "IGUI_OA_Status_Inf_Infected" .. OA.Trade.Text.DOT .. "IGUI_OA_Status_Inf_Drug_short IGUI_OA_Status_Hours 5")
    eq(lines[2], nil)
    eq(M.infection({ infected = true, progress = 0.5 })[2], "IGUI_OA_Status_Inf_Progress 50")
end)

test("the status tab's dot is red in debt, infected or with a wound not tested", function()
    local r = newRecord(1, 0, 100)
    eq(M.statusMark(r), nil, "no infection part: nothing")
    r.trade.credits = -1
    eq(M.statusMark(r), "bad")
    r.trade.credits = 100
    local state = { infected = false, untested = true }
    OA.Infection = { state = function() return state end }
    eq(M.statusMark(r), "bad")
    state = { infected = true }
    eq(M.statusMark(r), "bad")
    state = { infected = false, untested = false }
    eq(M.statusMark(r), nil)
    local function broken() error("broken") end   -- (named: Kahlua's error() in an unnamed function throws its own exception)
    OA.Infection = { state = broken }
    local logged = {}
    local log = OA.log
    OA.log = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end
    eq(M.statusMark(r), nil, "a failing part shows nothing")
    OA.log = log
    eq(#logged, 1, "told once")
end)

test("the progress sub-tab's dot: the field terminal can be bought", function()
    eq(M.fieldTerminalBuyable(newRecord(1, 0)), false, "not before stage 2")
    eq(M.fieldTerminalBuyable(newRecord(2, 0)), true)
    eq(M.fieldTerminalBuyable(newRecord(2, 0, -5)), false, "not in debt")
end)

test("the progress screen's level not shown yet: lit until the window has seen it, the dot with it", function()
    local r = newRecord(1, 0)
    eq(M.roadFresh(r), nil, "the first stage is the start, not new")
    eq(M.roadFresh(newRecord(0, 0)), nil, "nor before the first contact")
    r.trade.stage = 2
    eq(M.roadFresh(r), 2, "the next level is new again")
    r = newRecord(5, 2)
    eq(M.roadFresh(r), 7, "a level after the stages")
end)

test("the progress sub-tab's dot: the field terminal to buy, a level not shown yet", function()
    local r = newRecord(2, 0)
    OA.Terminal.setSeen(r, "road", 2)
    eq(M.progressMark(r, false, "records"), "new", "the crude terminal: the field terminal can be bought")
    eq(M.progressMark(r, true, "records"), nil, "the field terminal is the one")
    OA.Terminal.setSeen(r, "fieldTerminal", 1)
    eq(M.progressMark(r, false, "records"), nil, "once the screen has shown it")
    r = newRecord(3, 0)
    eq(M.progressMark(r, true, "records"), "new", "a level not shown yet")
    eq(M.progressMark(r, true, "progress"), nil, "not while the screen is on show")
    OA.Terminal.setSeen(r, "road", 3)
    eq(M.progressMark(r, true, "records"), nil)
end)

test("the support tab's dot: an upgrade a level opened since the tab was looked at, not one that opens again", function()
    local r = newRecord(2, 0)
    truthy(M.countAvail(r, true) > 0, "upgrades open at the 2nd stage")
    eq(M.supportFresh(r), 2, "never looked at: what is open is new")
    OA.Terminal.setSeen(r, "support", 2)
    eq(M.supportFresh(r), nil, "looked at")
    r.trade.credits = -5
    eq(M.supportFresh(newRecord(1, 0)), nil, "nothing open at the first stage")
    OA.Terminal.setSeen(r, "support", 0)
    eq(M.supportFresh(r), nil, "in debt nothing may be asked for")
    r.trade.credits = 0
    OA.Terminal.setSeen(r, "support", 2)
    r.trade.stage = 3
    eq(M.supportFresh(r), 3, "a new level lights it (the box opens at the 3rd)")
end)

-- The record ------------------------------------------------------------------------------------------------------

test("the record's texts: the codex's next bonus, the sweep, the kills, the missions", function()
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = { A = 10 }, n = 0 })
    local r = newRecord(1, 0)
    local c = OA.Codex.section(r)
    c.n, c.paid.kinds = 436, 2
    c.cat.A = 6
    c.paid.cats.A = 1
    c.nb, c.paid.buildings = 38, 1
    c.kills, c.paid.kills = 1284, 6
    r.missions = { results = { done = 3, expired = 0 }, streak = 2, bestStreak = 2 }
    local d = M.records(r)
    eq(M.plain(d.kinds), "IGUI_OA_Status_Rec_KindsLine 436 500 64")
    eq(M.plain(d.kindsBonus), "IGUI_OA_Status_Rec_NextBonus IGUI_OA_Status_Rec_KindPay 500 50,000IGUI_OA_Status_Rec_PlusSerum")
    eq(#d.cats, 11)
    eq(d.cats[1].count, "6/10"); near(d.cats[1].frac, 0.6); eq(d.cats[1].nextText, "IGUI_OA_Status_Rec_CatNext 90 150,000")
    eq(d.cats[2].count, "0/0"); eq(d.cats[2].frac, 0)
    near(d.buildings.bar, (38 - 25) / (100 - 25))
    eq(M.plain(d.buildings.lines[2]), "IGUI_OA_Status_Rec_SweepNext 100 62 10,000")
    near(d.kills.bar, (1284 - 1000) / (1500 - 1000))
    eq(M.plain(d.kills.lines[2]), "IGUI_OA_Status_Rec_KillsNext 1,500 216 40,000")
    eq(M.plain(d.missions.lines[1]), "IGUI_OA_Status_Rec_Late 0 2")
    eq(M.plain(d.missions.lines[2]), "IGUI_OA_Status_Rec_Best 2")
    -- All paid.
    c.n, c.paid.kinds = 1512, 7
    c.paid.cats.A = 2
    c.nb, c.paid.buildings = 2100, 6
    d = M.records(r)
    eq(M.plain(d.kinds), "IGUI_OA_Status_Rec_KindsDone 1,512"); eq(d.kindsBonus, nil)
    eq(d.cats[1].nextText, "IGUI_OA_Status_Rec_CatDone")
    eq(M.plain(d.buildings.lines[2]), "IGUI_OA_Status_Rec_SweepDone"); eq(d.buildings.bar, 1)
end)

test("the record's bonuses follow BonusMultiplier", function()
    OA.Requests.install({ version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 0 })
    SandboxVars.OperationAcorn.BonusMultiplier = 2
    local r = newRecord(1, 0)
    local c = OA.Codex.section(r)
    c.kills, c.paid.kills = 10, 0
    eq(M.plain(M.records(r).kills.lines[2]), "IGUI_OA_Status_Rec_KillsNext 50 40 10,000")
end)

-- The field terminal's first open -------------------------------------------------------------------------------------

test("the new board counts the team's goods open now and later, and the upgrades to ask for", function()
    local news = M.news(newRecord(2, 0))
    -- the field tools open now are one name of the board, where the first of them stands
    eq(news[1].lines[1], "IGUI_OA_Status_News_TeamNow 6 IGUI_OA_Status_News_TeamRest IGUI_OA_Econ_Shop_Item_team_fuel_can, "
        .. "IGUI_OA_Econ_Shop_Item_team_locker, IGUI_OA_Econ_Shop_Item_team_crate, IGUI_OA_Econ_Shop_Item_fabric_cutter 2")
    eq(news[1].lines[2], "IGUI_OA_Status_News_TeamMore 24", "the field tools still to come one of them; no weapon kit before a clearing")
    eq(news[3].lines[2], "IGUI_OA_Status_News_SupportNow 4")
    news = M.news(newRecord(3, 0))
    eq(news[1].lines[2], "IGUI_OA_Status_News_TeamMore 12")
    -- a late stage: four names and the rest counted
    news = M.news(newRecord(5, 0))
    local first = news[1].lines[1]
    truthy(string.find(first, "^IGUI_OA_Status_News_TeamNow %d+ IGUI_OA_Status_News_TeamRest "), first)
    local _, commas = string.gsub(first, ", ", "")
    eq(commas, 3, "four names")
    news = M.news(newRecord(1, 0))
    eq(news[3].lines[2], "IGUI_OA_Status_News_SupportLater", "the upgrades open at the 2nd stage")
end)

-- Layouts ----------------------------------------------------------------------------------------------------------

test("the layouts at the default and the smallest window", function()
    eq(M.heroWidth(700), 250); eq(M.heroWidth(580), 214)
    local road = M.roadLayout(700, 312)
    eq(road.lx, 64); eq(road.colw, 70); eq(road.roomy, true); eq(road.trackH, 32 + 52 + 4 + 52)
    road = M.roadLayout(580, 252)
    eq(road.lx, 56); eq(road.colw, 58); eq(road.roomy, false); eq(road.trackH, 28 + 38 + 4 + 38)
    local up = M.upgradesLayout(700, 312, 4)
    eq(up.rw, 268); eq(up.formH, 46); eq(up.ch, 104); eq(up.cw, 209); eq(up.scroll, false)
    up = M.upgradesLayout(700, 312, 6)
    eq(up.ch, 104, "every group has the same card"); eq(up.scroll, true); eq(up.contentH, 3 * 110 - 6)
    eq(up.cw, 204, "the scroll bar takes its width")
    up = M.upgradesLayout(580, 252, 4)
    eq(up.rw, 236); eq(up.formH, 40); eq(up.ch, 104); eq(up.scroll, true, "two rows do not fit the smallest window")
    eq(M.recordRowHeight(312), 21); eq(M.recordRowHeight(252), 18)
    local roomy, gap = M.heroSpacing(312, 16, 2)
    eq(roomy, true); eq(gap, 19, "the room left shared by the three gaps")
    roomy, gap = M.heroSpacing(312, 16 + 14 + 46, 2)
    eq(roomy, false, "the infection box takes the room of the two-line facts")
    roomy = M.heroSpacing(252, 16, 2)
    eq(roomy, false)
    local spec, facts
    roomy, gap, spec = M.heroSpacing(252, 16 + 14, 2)
    eq(spec, true, "the smallest window, flying: the four values still fit")
    roomy, gap, spec = M.heroSpacing(252, 16 + 14 + 46, 2)
    eq(spec, false, "with the infection box they go to the upgrades screen")
    eq(gap >= 4, true)
    -- The new-document card takes its place over the buttons; the infection box and the card come before the extras.
    roomy, gap, spec, facts = M.heroSpacing(312, 16, 2, true)
    eq(roomy, true, "the default window has the room for both"); eq(spec, true); eq(facts, true)
    roomy, gap, spec, facts = M.heroSpacing(252, 16 + 14 + 46, 2, true)
    eq(spec, false); eq(facts, false, "the smallest window, flying, infected, with the card: the facts go too")
    roomy, gap, spec, facts = M.heroSpacing(252, 16 + 14, 2, true)
    eq(facts, true, "flying with the card, they still fit")
    eq(select(4, M.heroSpacing(252, 16 + 14 + 46, 2)), true, "without the card the facts stay as before")
end)

test("before its first supply a record calls nothing and is told the box comes in that crate", function()
    local r = newRecord(0, 0)
    r.first = { mode = "late", day = 3, hour = 8 }
    r.heli = nil
    local s = M.heli(r, 100, 12)
    eq(s.state, "IGUI_OA_Status_Heli_Cannot")
    eq(s.subs[1].text, "IGUI_OA_Trade_Heli_FirstWait")
    eq(#s.subs, 1)
    eq(s.callable, false); eq(s.callWhy, "IGUI_OA_Trade_Heli_FirstWait")
    eq(s.reissue, false); eq(s.reissueWhy, "IGUI_OA_Trade_Heli_FirstWait")
    r.first.done = true
    eq(M.heli(r, 100, 12).subs[1].text, "IGUI_OA_Trade_Heli_NoBox", "once it came, the box's own state")
end)
