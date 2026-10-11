-- A generator the player switches on or off, plugs in or out, or takes away (the game's timed actions, whose
-- complete() changes the power of the squares around it at once): the machines and the terminals take the power they
-- have now, instead of at the next ten-minute step (some 25 s of real time at the default day length). The machines
-- work up to now with the power they had, then take the new one, so no work is lost or given. A generator that stops
-- by itself (out of fuel) is still the ten-minute step's: the game tells nothing then.
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Trade/Handlers"
local OA = OperationAcorn
local Machines = OA.Machines

local function refresh()
    local ok, err = pcall(Machines.tick)
    if not ok then OA.log("machines on a generator's change failed:", tostring(err)) end
    ok, err = pcall(OA.Trade.Handlers.refreshTerminals)
    if not ok then OA.log("terminals on a generator's change failed:", tostring(err)) end
end

-- Wraps an action's complete(): the machines work before it, and all take the power after it.
local function around(action)
    if not action or not action.complete then return end
    local complete = action.complete
    action.complete = function(self, ...)
        refresh()
        local result = complete(self, ...)
        refresh()
        return result
    end
end

around(ISActivateGenerator)
around(ISPlugGenerator)
around(ISTakeGenerator)
