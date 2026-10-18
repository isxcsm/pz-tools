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
