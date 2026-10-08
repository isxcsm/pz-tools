-- What a sealed box turned away is told to the economy (the big meteorite's radio line is its business).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Things"
local OA = OperationAcorn
local Things = OA.Trade.Things

test("each refused item is told to the economy with its info", function()
    local record = OA.Store.ensure("rec", "T")
    local told = {}
    OA.Value = { noteRefusal = function(r, info) told[#told + 1] = { r, info } return true end }
    local meteor, ammo = { fullType = "Base.LargeMeteorite" }, { fullType = "Base.Bullets9mm" }
    Things.noteRefusals(record, { meteor, ammo })
    eq(#told, 2)
    eq(told[1][1], record)
    eq(told[1][2], meteor)
    eq(told[2][2], ammo)
    OA.Value = nil
end)

test("without the economy's hook, or with a failing one, sealing goes on", function()
    local record = OA.Store.ensure("rec", "T")
    OA.Value = {}
    Things.noteRefusals(record, { { fullType = "Base.Rag" } })
    local count = 0
    OA.Value = { noteRefusal = function() count = count + 1 error("boom") end }
    Things.noteRefusals(record, { { fullType = "A" }, { fullType = "B" } })
    eq(count, 2, "a failure does not stop the next")
    Things.noteRefusals(record, nil)
    OA.Value = nil
end)
