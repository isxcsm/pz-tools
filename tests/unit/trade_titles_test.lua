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

test("a drop at the loud moment has the radio line and a title, marked when its crate came down", function()
    local record = OA.Store.ensure("h", "H")
    local told = listenTitles()
    local radio = {}
    local realRadio = OA.Trade.radio
    OA.Trade.radio = function(rec, key) radio[#radio + 1] = key end
    local realSetDown = Heli.setDown
    Heli.setDown = function() return true end
    OA.Trade.heli(record).landing = { owner = record.id, x = 1, y = 2, z = 0, cargo = { { type = "Base.Axe" } } }
    Heli.landNow(record.id)
    eq(radio[1], "IGUI_OA_Trade_Radio_Dropped")
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
    Heli.setDown, OA.Trade.radio = realSetDown, realRadio
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
