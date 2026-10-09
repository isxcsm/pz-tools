-- The trade part's ten-minute wiring: the arrivals and the first supply every ten game minutes, the looks at the world
-- (marks, lost boxes, the terminal's light) at most once each of their real-time intervals.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Handlers"
local OA = OperationAcorn
local Trade = OA.Trade
local Handlers = Trade.Handlers

-- Counts the calls of each piece of work, with fakes in place of the game.
local function counted()
    local n = { arrivals = 0, first = 0, marks = 0, boxes = 0, terminals = 0 }
    Trade.Heli.check = function() n.arrivals = n.arrivals + 1 end
    Trade.FirstSupply.check = function() n.first = n.first + 1 end
    Trade.Markers.checkAll = function() n.marks = n.marks + 1 end
    Trade.Things.reconcile = function() n.boxes = n.boxes + 1 end
    OA.Chunks.list = function(kind)
        if kind == "trade.terminal" then n.terminals = n.terminals + 1 end
        return {}
    end
    OA.Store.ensure("p", "P").boxes = {}
    return n
end

test("fast-forwarded, the world looks keep to real time and the game-time checks do not", function()
    local n = counted()
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    TEST.fire("EveryTenMinutes")
    eq(n.arrivals, 1); eq(n.first, 1); eq(n.marks, 1); eq(n.boxes, 1); eq(n.terminals, 1)
    -- x40: ten game minutes some 0.6 s apart
    for _ = 1, 7 do
        clock = clock + 600
        TEST.fire("EveryTenMinutes")
    end
    eq(n.arrivals, 8, "arrivals each ten game minutes")
    eq(n.first, 8, "the first supply each ten game minutes")
    eq(n.marks, 1, "marks: within MARKS_MS")
    eq(n.boxes, 1, "lost boxes: within BOXES_MS")
    eq(n.terminals, 1, "terminals: within TERMINALS_MS")
    clock = clock + Handlers.TERMINALS_MS
    TEST.fire("EveryTenMinutes")
    eq(n.terminals, 2, "the terminal light after TERMINALS_MS")
    eq(n.marks, 1); eq(n.boxes, 1)
    clock = clock + Handlers.MARKS_MS
    TEST.fire("EveryTenMinutes")
    eq(n.marks, 2); eq(n.boxes, 2); eq(n.terminals, 3)
end)

test("at the default speed every ten minutes runs everything", function()
    local n = counted()
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    -- ten game minutes are 25 real seconds at the default day length
    for _ = 1, 4 do
        TEST.fire("EveryTenMinutes")
        clock = clock + 25000
    end
    eq(n.arrivals, 4); eq(n.marks, 4); eq(n.boxes, 4); eq(n.terminals, 4)
    truthy(Handlers.TERMINALS_MS < 25000 and Handlers.BOXES_MS < 25000 and Handlers.MARKS_MS < 25000)
end)

test("a failing look does not stop the others, and waits its interval like them", function()
    local n = counted()
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    Trade.Markers.checkAll = function() n.marks = n.marks + 1; error("boom") end
    TEST.fire("EveryTenMinutes")
    eq(n.marks, 1); eq(n.boxes, 1); eq(n.terminals, 1)
    clock = clock + 600
    TEST.fire("EveryTenMinutes")
    eq(n.marks, 1, "a failed run waits its interval too")
end)
