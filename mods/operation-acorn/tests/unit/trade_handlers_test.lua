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

-- Flight support requests (tradeUpgrade, tradeUpgradeCancel): the upgrade goes as args.upgrade.
local function supportAt(field, why)
    require "OperationAcorn/Economy/Trust"
    local heard = {}
    OA.Sync.listen("notice", function(playerId, detail) heard[#heard + 1] = { player = playerId, key = detail.key } end)
    local changed = 0
    OA.Sync.listen("trade", function() changed = changed + 1 end)
    Trade.Objects.isUpgraded = function(object) return field end
    Handlers.terminalFor = function(character, args)
        if why then return nil, why end
        return {}
    end
    local record = OA.Store.ensure("sup", "T")
    record.trade = { credits = 100000, trust = 0, stage = 3, milestones = 0, bonus = 0, sharedSerums = 0 }
    local character = { getUsername = function() return "T" end }
    return record, character, heard, function() return changed end
end

test("a support request at a field terminal is kept for the next settlement", function()
    local record, character, heard, changed = supportAt(true)
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = 1, x = 1, y = 2, z = 0 })
    eq(record.trade.pendingLevels.rate, 1)
    eq(changed(), 1, "the window is told")
    eq(#heard, 0)
end)

test("a support request at a crude terminal is refused with its reason", function()
    local record, character, heard, changed = supportAt(false)
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = 1, x = 1, y = 2, z = 0 })
    eq(OA.Support.pending(record).rate, nil)
    eq(#heard, 1)
    eq(heard[1].key, "IGUI_OA_Support_Why_field")
    eq(changed(), 0)
end)

test("a support request the rules refuse says why", function()
    local record, character, heard = supportAt(true)
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = 2, x = 1, y = 2, z = 0 })
    eq(heard[1].key, "IGUI_OA_Support_Why_next")
    record.trade.stage = 0
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = 1, x = 1, y = 2, z = 0 })
    eq(heard[2].key, "IGUI_OA_Support_Why_tier")
    record.trade.stage = 3
    record.trade.credits = -5
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = 1, x = 1, y = 2, z = 0 })
    eq(heard[3].key, "IGUI_OA_Support_Why_debt")
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = "x", x = 1, y = 2, z = 0 })
    eq(heard[4].key, "IGUI_OA_Support_Why_max", "a level that is no number")
    eq(OA.Support.pending(record).rate, nil)
end)

test("a support request without a usable terminal is refused by the terminal's reason", function()
    local record, character, heard, changed = supportAt(true, "far")
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = 1, x = 1, y = 2, z = 0 })
    eq(record.trade.pendingLevels, nil)
    eq(heard[1].key, "IGUI_OA_Trade_Reason_far")
    sendClientCommand(character, OA.MOD, "tradeUpgradeCancel", { id = "sup", upgrade = "rate", x = 1, y = 2, z = 0 })
    eq(heard[2].key, "IGUI_OA_Trade_Reason_far")
end)

test("a support request is taken back at a terminal, and only when there is one", function()
    local record, character, heard, changed = supportAt(true)
    sendClientCommand(character, OA.MOD, "tradeUpgrade", { id = "sup", upgrade = "rate", level = 1, x = 1, y = 2, z = 0 })
    eq(record.trade.pendingLevels.rate, 1)
    sendClientCommand(character, OA.MOD, "tradeUpgradeCancel", { id = "sup", upgrade = "rate", x = 1, y = 2, z = 0 })
    eq(record.trade.pendingLevels.rate, nil)
    eq(changed(), 2)
    sendClientCommand(character, OA.MOD, "tradeUpgradeCancel", { id = "sup", upgrade = "rate", x = 1, y = 2, z = 0 })
    eq(changed(), 2, "nothing to take back, nobody told")
end)

test("a pending support request can be taken back at a crude terminal too (only asking needs the field one)", function()
    local record, character, heard, changed = supportAt(false)
    OA.Support.pending(record).rate = 1
    sendClientCommand(character, OA.MOD, "tradeUpgradeCancel", { id = "sup", upgrade = "rate", x = 1, y = 2, z = 0 })
    eq(record.trade.pendingLevels.rate, nil)
end)
