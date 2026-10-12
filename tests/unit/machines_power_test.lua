-- A generator switched (the API's OnPZExtGeneratorPower): the machines and terminals take its power at once
-- (server/OperationAcorn/Machines/Power.lua), the machines working up to then with the power they had.
require "OperationAcorn/Core"
local OA = OperationAcorn

test("a generator switched works the machines before, and shows the power of all after", function()
    local log = {}
    OA.Machines = OA.Machines or {}
    OA.Trade = OA.Trade or {}
    local tick, handlers = OA.Machines.tick, OA.Trade.Handlers
    OA.Machines.tick = function() log[#log + 1] = "machines" end
    OA.Trade.Handlers = { refreshTerminals = function() log[#log + 1] = "terminals" end }
    local handler
    local event = Events.OnPZExtGeneratorPower
    Events.OnPZExtGeneratorPower = { Add = function(f) handler = f end }
    local real = require
    require = function(file)
        if file == "OperationAcorn/Machines/Machines" or file == "OperationAcorn/Trade/Handlers" then return true end
        return real(file)
    end
    local ok, err = pcall(real, "OperationAcorn/Machines/Power")
    require = real
    Events.OnPZExtGeneratorPower = event
    if not ok then error(err, 0) end
    eq(type(handler), "function", "the event has a handler")
    handler({}, false, false)
    eq(table.concat(log, " "), "machines", "before: the machines work with the power they had")
    log = {}
    handler({}, false, true)
    eq(table.concat(log, " "), "machines terminals", "after: all take the new power")
    OA.Machines.tick, OA.Trade.Handlers = tick, handlers
end)
