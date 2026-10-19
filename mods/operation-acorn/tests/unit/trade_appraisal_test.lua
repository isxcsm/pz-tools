-- The appraisal line on an item's tooltip: an item of a running mission says the mission pays for it, not "about 0
-- credits" (its worth alone is nothing: Value.OWN.MissionItem). The economy's answers are fakes.
require "OperationAcorn/Core"
local OA = OperationAcorn

local loaded

local function load(own, credits)
    if loaded then return loaded(own, credits) end
    UIFont = { Small = "Small" }
    ISPanel = { derive = function() return {} end }
    ISToolTipInv = { render = function() end }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/UI" or name == "OperationAcorn/Trade/Estimate"
            or name == "OperationAcorn/Client" then
            return true
        end
        return real(name)
    end
    OA.Trade = OA.Trade or {}
    OA.Trade.UI = { textWidthPx = function(text) return #text * 6 end }
    OA.Trade.Objects, OA.Trade.Things, OA.Trade.Estimate = {}, {}, {}
    OA.Trade.Text = { credits = function(n) return tostring(n) end, markText = function() return nil end,
        tr = function(key) return key end }
    local ok, err = pcall(real, "OperationAcorn/Trade/Appraisal")
    require = real
    if not ok then error(err, 0) end
    loaded = function(own_, credits_)
        own, credits = own_, credits_
        return OA.Trade.Appraisal
    end
    OA.Value = {
        info = function() return { own = own } end,
        context = function() return {} end,
        accepts = function() return true end,
        appraise = function() return { credits = credits } end,
    }
    OA.Trust = OA.Trust or {}
    OA.Trust.tier = function() return 1 end
    return OA.Trade.Appraisal
end

test("a running mission's item says the mission pays for it", function()
    local Appraisal = load("MissionItem", 0)
    local line = Appraisal.lineFor({}, {})
    eq(line.text, getText("IGUI_OA_Trade_Tip_Mission"))
end)

test("another taken item says about what it is worth", function()
    local Appraisal = load(nil, 660)
    local line = Appraisal.lineFor({}, {})
    eq(line.text, getText("IGUI_OA_Trade_Tip_Worth", "660"))
end)

test("the tooltip line is worked out again after half a second, and at once when the settlement number changes", function()
    local Appraisal = load(nil, 100)
    local calls = 0
    OA.Value.appraise = function() calls = calls + 1 return { credits = 100 + calls } end
    local now = 5000
    getTimestampMs = function() return now end
    local item, record = {}, { trade = { serial = 7 } }
    local first = Appraisal.lineFor(item, record)
    eq(Appraisal.lineFor(item, record), first, "kept within the time")
    now = now + 499
    eq(Appraisal.lineFor(item, record), first, "kept just inside")
    eq(calls, 1)
    now = now + 1
    local second = Appraisal.lineFor(item, record)
    truthy(second ~= first, "made again at 500 ms")
    eq(calls, 2)
    record.trade.serial = 8
    Appraisal.lineFor(item, record)
    eq(calls, 3, "a settlement changes the serial: made again at once")
    OA.Trust.tier = function() return 2 end
    Appraisal.lineFor(item, record)
    eq(calls, 4, "a new tier: made again at once")
    now = now - 10000
    Appraisal.lineFor(item, record)
    eq(calls, 5, "a clock gone back is not a hit")
end)

test("the tooltip lines kept are those of the last half second: the items hovered before are let go", function()
    local Appraisal = load(nil, 100)
    local now = 9000
    getTimestampMs = function() return now end
    local record = { trade = { serial = 1 } }
    local items = {}
    for i = 1, 300 do
        items[i] = {}
        Appraisal.lineFor(items[i], record)
        now = now + 1
    end
    eq(Appraisal.cache.n, 300)
    now = now + Appraisal.KEEP_MS
    local last = {}
    Appraisal.lineFor(last, record)
    eq(Appraisal.cache.n, 1, "the expired entries went")
    eq(Appraisal.cache.t[items[1]], nil)
end)
