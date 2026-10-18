-- The trade part's titles: a drop done (marked on the map when its crate is down), the first supply.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Heli"
require "OperationAcorn/Trade/FirstSupply"
local OA = OperationAcorn
local Heli, FirstSupply = OA.Trade.Heli, OA.Trade.FirstSupply

local function listenTitles()
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = { id = id, detail = detail } end)
    return told
end

test("a drop at the loud moment has a title, marked when its crate came down", function()
    local record = OA.Store.ensure("h", "H")
    local told = listenTitles()
    local realSetDown = Heli.setDown
    Heli.setDown = function() return true end
    OA.Trade.heli(record).landing = { owner = record.id, x = 1, y = 2, z = 0, cargo = { { type = "Base.Axe" } } }
    Heli.landNow(record.id)
    eq(#told, 1)
    eq(told[1].id, record.id)
    eq(told[1].detail.key, "IGUI_OA_Title_Dropped")
    eq(told[1].detail.style, "notice")
    eq(told[1].detail.sub, "IGUI_OA_Title_Marked")
    -- a box only (no crate): nothing on the map to say
    OA.Trade.heli(record).landing = { owner = record.id, x = 1, y = 2, z = 0, box = "b1" }
    Heli.landNow(record.id)
    eq(#told, 2)
    eq(told[2].detail.sub, nil)
    Heli.setDown = realSetDown
    eq(record.radio, nil, "no radio line is written")
end)

test("the first supply put down is a strange thing on the map, once", function()
    local record = OA.Store.ensure("f", "F")
    record.first = { mode = "test" }
    local told = listenTitles()
    local real = { drop = FirstSupply.drop, characterOf = OA.Trade.characterOf, due = OA.Trade.Rules.firstDue,
        time = getGameTime }
    FirstSupply.drop = function() return true end
    OA.Trade.characterOf = function() return {} end
    OA.Trade.Rules.firstDue = function(plan) return not plan.done end
    getGameTime = function()
        return { getNightsSurvived = function() return 1 end, getTimeOfDay = function() return 9 end }
    end
    FirstSupply.check()
    FirstSupply.check()
    eq(#told, 1)
    eq(told[1].id, record.id)
    eq(told[1].detail.key, "IGUI_OA_Title_FirstSupply")
    eq(told[1].detail.style, "unveil")
    eq(told[1].detail.sub, "IGUI_OA_Title_Marked")
    FirstSupply.drop, OA.Trade.characterOf, OA.Trade.Rules.firstDue, getGameTime = real.drop, real.characterOf, real.due,
        real.time
end)

-- The helicopter's call is a notice with the day and the hour it comes, not a radio line.
local function listenNotices()
    local told = {}
    OA.Sync.listen("notice", function(id, detail) told[#told + 1] = { id = id, detail = detail } end)
    return told
end

test("a helicopter call sends a notice with when it comes, read from today, the reissue its own", function()
    local record = OA.Store.ensure("c", "C")
    record.trade = { stage = 1, credits = 50000, trust = 0 }
    OA.Trade.Boxes.add(record, { x = 5, y = 6, z = 0 })
    local told = listenNotices()
    local character = { getX = function() return 5 end, getY = function() return 6 end }
    local ok, why = Heli.call(character, record, "normal", 5, 6)
    eq(ok, false, "nothing sealed or ordered")
    eq(why, "empty")
    OA.Trade.Boxes.add(record, { state = "sealed", active = false })
    truthy(Heli.call(character, record, "normal", 5, 6))
    eq(#told, 1)
    eq(told[1].id, record.id)
    eq(told[1].detail.key, "IGUI_OA_Trade_Notice_Called")
    local arrive = OA.Trade.heli(record).call.arrive
    local _, h, m = OA.Trade.clockText(arrive)
    local when = told[1].detail.args[1]
    eq(when.key, OA.Trade.when(arrive).key, "today's, tomorrow's or days ahead, not the world's day number")
    eq(when.args[#when.args], string.format("%02d:%02d", h, m))
    eq(record.radio, nil, "no radio line is written")
    -- A second call has to wait; the reissue after the interval has its own text.
    OA.Trade.heli(record).call = nil
    OA.Trade.heli(record).next = nil
    truthy(Heli.call(character, record, "reissue", 5, 6))
    eq(#told, 2)
    eq(told[2].detail.key, "IGUI_OA_Trade_Notice_ReissueCalled")
    eq(#told[2].detail.args, 1)
end)

test("a call that is refused sends nothing", function()
    local record = OA.Store.ensure("c2", "C")
    local told = listenNotices()
    eq(Heli.call({}, record, "normal"), false, "no box to call for")
    eq(#told, 0)
end)

test("a delivery that leaves the account in debt sends the debt title, one in credit does not", function()
    local record = OA.Store.ensure("d", "D")
    local told = listenTitles()
    local real = { deliver = Heli.deliver, refresh = Heli.refreshBoxes }
    Heli.deliver, Heli.refreshBoxes = function() end, function() end
    OA.Trade.heli(record).call = { at = 0, arrive = 1, kind = "normal", orders = {} }
    record.trade = { stage = 1, credits = -500, trust = 0 }
    truthy(Heli.arrive(record))
    local debt = {}
    for _, t in ipairs(told) do if t.detail.key == "IGUI_OA_Title_Debt" then debt[#debt + 1] = t end end
    eq(#debt, 1)
    eq(debt[1].id, record.id)
    eq(debt[1].detail.sub, "IGUI_OA_Title_DebtSub")
    eq(debt[1].detail.tone, "red")
    eq(record.radio, nil)
    OA.Trade.heli(record).call = { at = 0, arrive = 1, kind = "normal", orders = {} }
    record.trade.credits = 500
    Heli.arrive(record)
    debt = {}
    for _, t in ipairs(told) do if t.detail.key == "IGUI_OA_Title_Debt" then debt[#debt + 1] = t end end
    eq(#debt, 1, "no new debt title")
    Heli.deliver, Heli.refreshBoxes = real.deliver, real.refresh
end)

test("a lost box is a red title: the active box, or a sealed one with its items", function()
    local Things, Objects = OA.Trade.Things, OA.Trade.Objects
    local record = OA.Store.ensure("b", "B")
    local told = listenTitles()
    local function thing(id)
        return { kind = Objects.DELIVERY_BOX, x = 1, y = 2, z = 0, box = id, data = { [Objects.OWNER] = record.id } }
    end
    local active = OA.Trade.Boxes.add(record, { x = 1, y = 2, z = 0 })
    Things.destroyed(thing(active.id))
    eq(#told, 1)
    eq(told[1].id, record.id)
    eq(told[1].detail.key, "IGUI_OA_Trade_Notice_BoxLost")
    eq(told[1].detail.sub, "IGUI_OA_Title_BoxLostSub")
    eq(told[1].detail.tone, "red")
    local sealed = OA.Trade.Boxes.add(record, { x = 3, y = 4, z = 0 })
    OA.Trade.Boxes.seal(record, sealed.id, { { info = { fullType = "Base.Rag" }, count = 1 } })
    Things.destroyed(thing(sealed.id))
    eq(#told, 2)
    eq(told[2].detail.key, "IGUI_OA_Trade_Notice_BoxLost")
    eq(told[2].detail.sub, "IGUI_OA_Title_BoxLostSealedSub")
    eq(record.radio, nil)
end)

test("an empty previous box that is lost is not announced", function()
    local Things, Objects = OA.Trade.Things, OA.Trade.Objects
    local record = OA.Store.ensure("b2", "B")
    local told = listenTitles()
    OA.Trade.Boxes.add(record, { x = 1, y = 2, z = 0 })
    local previous = OA.Trade.Boxes.add(record, { x = 7, y = 8, z = 0, active = false })
    Things.destroyed({ kind = Objects.DELIVERY_BOX, x = 7, y = 8, z = 0, box = previous.id,
        data = { [Objects.OWNER] = record.id } })
    eq(#told, 0)
end)

test("the first field terminal opens the record's line once, with a gold title", function()
    local Things = OA.Trade.Things
    local record = OA.Store.ensure("f", "F")
    local told = listenTitles()
    truthy(Things.lineOpened(record))
    eq(record.heli.line, true)
    eq(#told, 1)
    eq(told[1].detail.key, "IGUI_OA_Title_LineOpened")
    eq(told[1].detail.tone, "gold")
    eq(Things.lineOpened(record), false, "a second field terminal opens nothing")
    eq(#told, 1)
end)

test("the helicopter's noise is a world sound at the drop, as far as the option says", function()
    Heli.noise(10, 20, 0)
    eq(#TEST.worldSounds, 1)
    eq(TEST.worldSounds[1].x, 10); eq(TEST.worldSounds[1].y, 20)
    eq(TEST.worldSounds[1].radius, OA.BALANCE.noiseRadius)
    SandboxVars = { OperationAcorn = { HelicopterNoiseMultiplier = 0 } }
    Heli.noise(10, 20, 0)
    eq(#TEST.worldSounds, 1, "no sound at zero")
end)

test("a time is read from today: today's, tomorrow's, so many days ahead, an earlier one by its day", function()
    local now = OA.hours()
    local start = OA.dayStart(OA.day())
    eq(OA.Trade.when(start + 23).key, "IGUI_OA_Trade_WhenToday")
    eq(OA.Trade.when(start + 24 + 8.5).key, "IGUI_OA_Trade_WhenTomorrow")
    eq(OA.Trade.when(start + 24 + 8.5).args[1], OA.Trade.when(start + 8.5).args[1], "the clock alone")
    local ahead = OA.Trade.when(start + 72 + 1)
    eq(ahead.key, "IGUI_OA_Trade_WhenInDays")
    eq(ahead.args[1], 3)
    if OA.day() > 0 then eq(OA.Trade.when(start - 1).key, "IGUI_OA_Trade_When") end
    truthy(now >= start)
end)

test("a drop's title says what the flight paid for the boxes it took, with the map's mark when there is one", function()
    eq(Heli.settled({ boxes = 0, credits = 0, trust = 0 }), nil, "no box settled: nothing paid to say")
    local s = Heli.settled({ boxes = 2, credits = 500, fee = 50, trust = 3 })
    eq(s.credits, 450, "less the infection fee")
    eq(s.trust, 3)
    local record = OA.Store.ensure("hp", "HP")
    local told = listenTitles()
    local realSetDown = Heli.setDown
    Heli.setDown = function() return true end
    OA.Trade.heli(record).landing = { owner = record.id, x = 1, y = 2, z = 0, cargo = { { type = "Base.Axe" } },
        settled = s }
    Heli.landNow(record.id)
    local d = told[#told].detail
    eq(d.key, "IGUI_OA_Title_Dropped")
    eq(d.sub, "IGUI_OA_Title_Join")
    eq(d.subArgs[1].key, "IGUI_OA_Title_DroppedPaidTrust")
    eq(d.subArgs[1].args[1], 450)
    eq(d.subArgs[1].args[2], 3)
    eq(d.subArgs[2].key, "IGUI_OA_Title_Marked")
    -- no trust, no crate on the map
    Heli.dropped(record, false, { credits = 120, trust = 0 })
    d = told[#told].detail
    eq(d.sub, "IGUI_OA_Title_DroppedPaid")
    eq(d.subArgs[1], 120)
    Heli.setDown = realSetDown
end)
