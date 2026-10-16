-- Trust from every source goes through Trade.addTrust: a stage or milestone is dealt with once (the story part is told,
-- the player hears of the new items), a mission's pay takes the same road as a settlement, and no radio log is written.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Ledger"
require "OperationAcorn/Trade/Settle"
require "OperationAcorn/Trade/Gain"
require "OperationAcorn/Trade/Text"
local OA = OperationAcorn
local Trade, Settle, Boxes = OA.Trade, OA.Trade.Settle, OA.Trade.Boxes

-- The economy's trust, as P1 makes it: it adds the trust, puts shared serums into the account, tells the events.
local function fakeTrust(events)
    OA.Trust = {
        calls = 0,
        add = function(record, amount)
            OA.Trust.calls = OA.Trust.calls + 1
            local t = Trade.account(record)
            t.trust = t.trust + amount
            if events and #events > 0 then
                t.stage = t.stage + 1
                t.sharedSerums = t.sharedSerums + 1
            end
            return events or {}
        end,
    }
end

-- Notices the client would hear.
-- The titles the player is shown (the stage's replaces the old new-items notice).
local function listenTitles()
    local heard = {}
    OA.Sync.listen("title", function(playerId, detail) heard[#heard + 1] = detail end)
    return heard
end

local function fakeStory()
    OA.Story = { stages = 0, onStage = function(record) OA.Story.stages = OA.Story.stages + 1 end }
end

test("a stage passed is dealt with once: story told, one title and no radio line, serums stay in the account", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({ { kind = "stage", stage = 2, sharedSerums = 1 } })
    fakeStory()
    local heard = listenTitles()
    local events = Trade.addTrust(record, 900, "mission")
    eq(#events, 1)
    eq(events[1].kind, "stage")
    eq(events[1].n, 2)
    eq(OA.Story.stages, 1)
    eq(record.radio, nil, "no radio line is written")
    eq(#heard, 1)
    eq(heard[1].key, "IGUI_OA_Title_Stage")
    eq(heard[1].args[1], 2)
    eq(heard[1].sub, "IGUI_OA_Title_NewItems")
    eq(heard[1].style, "dust")
    eq(Trade.account(record).sharedSerums, 1, "the economy put it there; the next crate carries it")
    eq(Trade.account(record).trust, 900)
end)

test("trust that passes nothing tells nobody", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({})
    fakeStory()
    local heard = listenTitles()
    eq(#Trade.addTrust(record, 50, "mission"), 0)
    eq(OA.Story.stages, 0)
    eq(record.radio, nil)
    eq(#heard, 0)
    eq(#Trade.addTrust(record, 0, "mission"), 0)
    eq(OA.Trust.calls, 1, "no trust, no call")
end)

test("the first contact opens the first stage the same way, once", function()
    OA.Trust = require "OperationAcorn/Economy/Trust"
    local record = OA.Store.ensure("rec", "T")
    fakeStory()
    local heard = listenTitles()
    local events = Trade.openContact(record)
    eq(#events, 1)
    eq(events[1].kind, "stage"); eq(events[1].n, 1)
    eq(Trade.account(record).stage, 1)
    eq(OA.Story.stages, 1)
    eq(#heard, 1)
    eq(heard[1].args[1], 1)
    eq(#Trade.openContact(record), 0, "already in contact")
    eq(OA.Story.stages, 1)
end)

test("a milestone is a new-items event too", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({ { kind = "milestone", index = 1, sharedSerums = 1 } })
    fakeStory()
    local heard = listenTitles()
    local events = Trade.addTrust(record, 9000, "settle")
    eq(events[1].kind, "milestone")
    eq(events[1].n, 1)
    eq(OA.Story.stages, 1)
    eq(record.radio, nil)
    eq(#heard, 1)
    eq(heard[1].key, "IGUI_OA_Title_Stage", "a milestone has no title of its own")
    eq(heard[1].args[1], 6, "milestone 1 is level 6")
end)

test("trust that passes a stage and a milestone at once has one title, the last one's", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({ { kind = "stage", stage = 5, sharedSerums = 1 }, { kind = "milestone", index = 1, sharedSerums = 1 } })
    fakeStory()
    local heard = listenTitles()
    eq(#Trade.addTrust(record, 20000, "settle"), 2)
    eq(#heard, 1)
    eq(heard[1].key, "IGUI_OA_Title_Stage")
    eq(heard[1].args[1], 6, "the milestone's level, 5 + 1")
end)

test("the cause of the trust (a request paid) goes under the level's title, one title for the one event", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({ { kind = "milestone", index = 1, sharedSerums = 1 } })
    fakeStory()
    local heard = listenTitles()
    local cause = { key = "IGUI_OA_Title_Paid", sub = "IGUI_OA_Title_PaidSub", subArgs = { "x", 300 } }
    local events, merged = Trade.addTrust(record, 9000, "mission", cause)
    eq(#events, 1)
    eq(merged, true)
    eq(#heard, 1)
    eq(heard[1].key, "IGUI_OA_Title_Stage")
    eq(heard[1].sub, "IGUI_OA_Title_PaidSub", "the request under the level instead of the new items")
    eq(heard[1].subArgs[2], 300)
    -- a named stage has no title now (its card comes at the terminal): the cause is left to the caller
    OA.Story.stageTitle = function() return nil end
    fakeTrust({ { kind = "stage", stage = 2, sharedSerums = 0 } })
    local _, alone = Trade.addTrust(record, 900, "mission", cause)
    eq(alone, false)
    eq(#heard, 1)
end)

test("a mission's pay and a settlement give the same events, each handled once", function()
    -- A mission pays through the story part, which calls Trade.addTrust.
    require "OperationAcorn/Story/Story"
    local mission = OA.Store.ensure("m", "M")
    fakeTrust({ { kind = "stage", stage = 1, sharedSerums = 0 } })
    local stages = 0
    OA.Story.onStage = function() stages = stages + 1 end
    OA.Story.addTrust(mission, 700)
    eq(stages, 1)
    eq(mission.radio, nil)

    -- A settlement of the same size for another record.
    local record = OA.Store.ensure("s", "S")
    OA.Story.onStage = function() stages = stages + 1 end
    fakeTrust({ { kind = "stage", stage = 1, sharedSerums = 0 } })
    local box = Boxes.add(record, { x = 1, y = 1, z = 0 })
    Boxes.seal(record, box.id, { { info = { fullType = "Base.Rag" }, count = 1 } })
    Trade.heli(record).call = { at = 0, arrive = 1, kind = "normal", orders = {} }
    local plan = Settle.run(record, {
        now = 10, day = 1,
        settle = function() return { credits = 100, trust = 700, lines = {} } end,
        trustAdd = function(r, amount) return Trade.addTrust(r, amount, "settle") end,
        shop = { entry = function() return nil end },
        rnd = function(a, b) return b end,
    })
    eq(stages, 2, "one more call for the settlement, none repeated")
    eq(record.radio, nil)
    eq(#plan.events, 1)
    eq(plan.events[1].kind, "stage")
    eq(plan.events[1].n, 1)
end)

test("a manifest in the old form carries the story part's column names", function()
    OA.Story = { OLD_LABELS = { serial = true, remarks = true, receivers = true } }
    local lines = Trade.Text.receipt({ id = 4, day = 9, number = 347, oldForm = true, balanceBefore = 0, balance = 0,
        note = { key = "IGUI_OA_Story_Note_x" } })
    eq(lines[1].text, "IGUI_OA_Trade_Rc_HeadOld IGUI_OA_Story_Form_serial 4 9")
    eq(lines[2].text, "IGUI_OA_Trade_Rc_Row IGUI_OA_Story_Form_receivers 0347")
    local fresh = Trade.Text.receipt({ id = 4, day = 9, number = 347, balanceBefore = 0, balance = 0,
        note = { key = "IGUI_OA_Story_Note_x" } })
    eq(fresh[1].text, "IGUI_OA_Trade_Rc_Head 4 9")
    eq(fresh[2].text, "IGUI_OA_Trade_Rc_Row IGUI_OA_Trade_Rc_Label_receivers 0347")
end)

test("the record knows where its terminal stands", function()
    local record = OA.Store.ensure("rec", "T")
    eq(Trade.terminalPosition(record), nil)
    record.heli = { terminal = { x = 10, y = 20, z = 0 } }
    local x, y = Trade.terminalPosition(record)
    eq(x, 10)
    eq(y, 20)
end)
