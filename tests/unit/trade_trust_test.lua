-- Trust from every source goes through Trade.addTrust: a stage or milestone is dealt with once (the story part is told,
-- the player hears of the new items), a mission's pay takes the same road as a settlement, the radio greeting follows
-- the story part's call sign, and the first contact is said once.
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
local function listenNotices()
    local heard = {}
    OA.Sync.listen("notice", function(playerId, detail) heard[#heard + 1] = detail.key end)
    return heard
end

local function fakeStory()
    OA.Story = { stages = 0, onStage = function(record) OA.Story.stages = OA.Story.stages + 1 end }
end

local function radioKeys(record)
    local keys = {}
    for _, line in ipairs(OA.Store.section(record, "radio")) do keys[#keys + 1] = line.key end
    return keys
end

test("a stage passed is dealt with once: story told, one radio line, one notice, serums stay in the account", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({ { kind = "stage", stage = 2, sharedSerums = 1 } })
    fakeStory()
    local heard = listenNotices()
    local events = Trade.addTrust(record, 900, "mission")
    eq(#events, 1)
    eq(events[1].kind, "stage")
    eq(events[1].n, 2)
    eq(OA.Story.stages, 1)
    eq(#radioKeys(record), 1)
    eq(radioKeys(record)[1], "IGUI_OA_Trade_Radio_NewItems")
    eq(#heard, 1)
    eq(Trade.account(record).sharedSerums, 1, "the economy put it there; the next crate carries it")
    eq(Trade.account(record).trust, 900)
end)

test("trust that passes nothing tells nobody", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({})
    fakeStory()
    local heard = listenNotices()
    eq(#Trade.addTrust(record, 50, "mission"), 0)
    eq(OA.Story.stages, 0)
    eq(#radioKeys(record), 0)
    eq(#heard, 0)
    eq(#Trade.addTrust(record, 0, "mission"), 0)
    eq(OA.Trust.calls, 1, "no trust, no call")
end)

test("a milestone is a new-items event too", function()
    local record = OA.Store.ensure("rec", "T")
    fakeTrust({ { kind = "milestone", index = 1, sharedSerums = 1 } })
    fakeStory()
    local events = Trade.addTrust(record, 9000, "settle")
    eq(events[1].kind, "milestone")
    eq(events[1].n, 1)
    eq(OA.Story.stages, 1)
    eq(#radioKeys(record), 1)
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
    eq(#radioKeys(mission), 1)

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
    eq(#radioKeys(record), 1)
    eq(#plan.events, 1)
    eq(plan.events[1].kind, "stage")
    eq(plan.events[1].n, 1)
end)

test("the radio greeting is the story part's, kept with the line", function()
    local record = OA.Store.ensure("rec", "T")
    record.number = 347
    OA.Story = { greeting = function() return "IGUI_OA_Story_Greeting_2" end }
    Trade.radio(record, "IGUI_OA_Trade_Radio_Dropped")
    local entry = OA.Store.section(record, "radio")[1]
    eq(entry.greet, "IGUI_OA_Story_Greeting_2")
    eq(entry.number, "0347")
    eq(OA.Trade.Text.radio(entry), "IGUI_OA_Story_Greeting_2 0347 IGUI_OA_Trade_Radio_Dropped IGUI_OA_Trade_Radio_Over")
    -- After the handover the story's greeting changes; the line already said keeps the one it was said with.
    OA.Story.greeting = function() return "IGUI_OA_Story_Greeting_H" end
    Trade.radio(record, "IGUI_OA_Trade_Radio_Dropped")
    eq(OA.Store.section(record, "radio")[2].greet, "IGUI_OA_Story_Greeting_H")
    eq(OA.Store.section(record, "radio")[1].greet, "IGUI_OA_Story_Greeting_2")
    -- Without a greeting from the story part (the start, the last stage) the trade part's own is used.
    OA.Story.greeting = function() return nil end
    Trade.radio(record, "IGUI_OA_Trade_Radio_Dropped")
    local third = OA.Store.section(record, "radio")[3]
    eq(third.greet, nil)
    eq(OA.Trade.Text.radio(third), "IGUI_OA_Trade_Greet_0 IGUI_OA_Trade_Radio_Dropped IGUI_OA_Trade_Radio_Over")
    third.stage = 5
    eq(OA.Trade.Text.radio(third), "IGUI_OA_Trade_Radio_Dropped IGUI_OA_Trade_Radio_Over", "no greeting at the last stage")
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
