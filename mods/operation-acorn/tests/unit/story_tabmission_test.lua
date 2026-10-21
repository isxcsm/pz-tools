-- The mission tab's layout (client/Story/TabMission): a short offer card is as tall as what it says, the special
-- request's panel under it too; any other card takes what the panel leaves.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
local OA = OperationAcorn

local function load()
    local class = function()
        local c = {}
        c.derive = function(self)
            local d = {}
            d.__index = d
            return setmetatable(d, { __index = self })
        end
        return c
    end
    OATab, PZUIButton = class(), class()
    OA.Trade = OA.Trade or {}
    OA.Trade.UI = OA.Trade.UI or {}
    local UI = OA.Trade.UI
    UI.fontHeight = function() return 16 end
    UI.textWidth = function(s) return #tostring(s or "") * 7 end
    UI.fit = function(s) return s end
    UIFont = UIFont or { Small = "Small", Medium = "Medium" }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" or name == "PZUIKit/Button"
            or name == "PZUIKit/Confirm" or name == "OperationAcorn/Trade/StatusDraw" then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Story/TabMission")
    require = real
    if not ok then error(err, 0) end
end

local function button() return { width = 100, height = 24, setX = function() end, setY = function() end,
    setVisible = function() end, setTitle = function() end } end

-- A tab `h` high with a card in `state` and an offer of two special requests.
local function tab(h, state)
    local t = setmetatable({ width = 600, height = h }, { __index = OATabMission })
    for _, k in ipairs({ "mapButton", "launchButton", "commsButton", "rerollButton", "shopButton", "acceptButton",
        "specialMapButton" }) do t[k] = button() end
    t.optionButtons = { a = button(), b = button() }
    t.info = { state = state }
    t.card = { brief = "short brief", lines = {}, badges = {}, title = "t", right = { w = 40 }, where = {},
        options = { a = "A", b = "B" } }
    t.special = { kind = "offer", head = "special", hint = "pick", options = { a = { title = "a", form = "f", where = "w" },
        b = { title = "b", form = "f", where = "w" } } }
    return t
end

test("an offer card and the special offer under it are each as tall as what they say; a taken card takes the rest", function()
    load()
    local t = tab(700, "waiting")
    t:layout()
    local panel = t:layoutSpecial(t.width)
    eq(t.slot.y, t.cardH + 8)
    eq(t.slot.h, panel, "the panel as tall as what it says")
    truthy(t.slot.y + t.slot.h < 700, "the rest of the tab left empty below")
    t = tab(700, "active")
    t:layout()
    eq(t.slot.y + t.slot.h, 700, "a taken card: the panel at the foot")
    eq(t.slot.h, panel)
end)
