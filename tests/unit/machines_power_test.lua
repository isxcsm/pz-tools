-- A generator the player switches, plugs or takes: the machines and terminals take its power at once
-- (server/OperationAcorn/Machines/Power.lua), the machines working up to then with the power they had.
require "OperationAcorn/Core"
local OA = OperationAcorn

test("switching a generator works the machines before, and shows the power of all after", function()
    local log = {}
    OA.Machines = OA.Machines or {}
    OA.Trade = OA.Trade or {}
    local tick, handlers = OA.Machines.tick, OA.Trade.Handlers
    OA.Machines.tick = function() log[#log + 1] = "machines" end
    OA.Trade.Handlers = { refreshTerminals = function() log[#log + 1] = "terminals" end }
    local function action()
        local a = {}
        function a:complete() log[#log + 1] = "complete" return true end
        return a
    end
    ISActivateGenerator, ISPlugGenerator, ISTakeGenerator = action(), action(), action()
    local real = require
    require = function(file)
        if file == "OperationAcorn/Machines/Machines" or file == "OperationAcorn/Trade/Handlers" then return true end
        return real(file)
    end
    local ok, err = pcall(real, "OperationAcorn/Machines/Power")
    require = real
    if not ok then error(err, 0) end
    eq(ISActivateGenerator:complete(), true, "the game's result is kept")
    eq(table.concat(log, " "), "machines terminals complete machines terminals")
    log = {}
    ISTakeGenerator:complete()
    ISPlugGenerator:complete()
    eq(#log, 10)
    OA.Machines.tick, OA.Trade.Handlers = tick, handlers
    ISActivateGenerator, ISPlugGenerator, ISTakeGenerator = nil, nil, nil
end)
