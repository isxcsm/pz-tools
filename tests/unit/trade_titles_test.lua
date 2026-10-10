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

test("the first supply put down is a find on the map, once", function()
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
    eq(told[1].detail.style, "discovery")
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

test("a helicopter call sends a notice with the day and the time, the reissue its own", function()
    local record = OA.Store.ensure("c", "C")
    record.trade = { stage = 1, credits = 50000, trust = 0 }
    OA.Trade.Boxes.add(record, { x = 5, y = 6, z = 0 })
    local told = listenNotices()
    local character = { getX = function() return 5 end, getY = function() return 6 end }
    truthy(Heli.call(character, record, "normal", 5, 6))
    eq(#told, 1)
    eq(told[1].id, record.id)
    eq(told[1].detail.key, "IGUI_OA_Trade_Notice_Called")
    local arrive = OA.Trade.heli(record).call.arrive
    local day, h, m = OA.Trade.clockText(arrive)
    eq(told[1].detail.args[1], day)
    eq(told[1].detail.args[2], string.format("%02d:%02d", h, m))
    eq(record.radio, nil, "no radio line is written")
    -- A second call has to wait; the reissue after the interval has its own text.
    OA.Trade.heli(record).call = nil
    OA.Trade.heli(record).next = nil
    truthy(Heli.call(character, record, "reissue", 5, 6))
    eq(#told, 2)
    eq(told[2].detail.key, "IGUI_OA_Trade_Notice_ReissueCalled")
    eq(#told[2].detail.args, 2)
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
