-- The comms tab's record (client/Story/TabComms, OACommsLog): at its foot the newest call is near the top with the
-- row before it (an older call's folded head) still in sight above it, so the record is seen to go on up.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Comms"
require "OperationAcorn/Story/CommsScript"
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
    ISPanel, OATab = class(), class()
    OA.Trade = OA.Trade or {}
    OA.Trade.UI = OA.Trade.UI or {}
    OA.Trade.UI.scaled = OA.Trade.UI.scaled or function() end
    PZUIKit.Sound = PZUIKit.Sound or {}
    PZUIKit.Tape = PZUIKit.Tape or {}
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" or name == "OperationAcorn/Sounds"
            or name == "PZUIKit/Tape" then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Story/TabComms")
    require = real
    if not ok then error(err, 0) end
end

-- A record panel `height` high scrolled to `scroll`.
local function log(height, scroll)
    return setmetatable({ height = height, scroll = scroll or 0, rows = {}, full = 0 }, { __index = OACommsLog })
end

local function head(h) return { kind = "head", h = h } end
local function line(h) return { kind = "line", h = h } end

test("at its foot the newest call's head is near the top, the folded head before it in sight above", function()
    load()
    local l = log(300)
    local rows = { head(24), head(24), head(24), line(20), line(20) }
    l:setRows(rows, true)
    -- the newest head at 4 + 48, the one before it at 4 + 24: the scroll shows that one at the top's margin
    eq(rows[3].y, 52)
    eq(l.scroll, rows[2].y - 4, "the head before it at the top")
    eq(rows[3].y - l.scroll, 4 + 24, "the newest under it")
    -- an opened block before it: as much of its last row as a head is high
    rows = { head(24), line(60), head(24), line(20) }
    l = log(300)
    l:setRows(rows, true)
    eq(rows[3].y - l.scroll, 4 + 24)
    -- the only call: at the top
    rows = { head(24), line(20) }
    l = log(300)
    l:setRows(rows, true)
    eq(l.scroll, 0)
    eq(rows[1].y - l.scroll, 4)
end)
