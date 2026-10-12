-- A generator switched on or off, by the player, out of fuel or broken (the API's OnPZToolsGeneratorPower): the machines
-- and the terminals take the power they have now, instead of at the next ten-minute step (some 25 s of real time at the
-- default day length). The API tells it twice: before the squares around the generator change, when the machines work up
-- to now with the power they had, and after, when all take the new one, so no work is lost or given. Without the API the
-- ten-minute step alone does it.
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Trade/Handlers"
local OA = OperationAcorn
local Machines = OA.Machines

local function onGeneratorPower(_, _, after)
    local ok, err = pcall(Machines.tick)
    if not ok then OA.log("machines on a generator's change failed:", tostring(err)) end
    if not after then return end
    ok, err = pcall(OA.Trade.Handlers.refreshTerminals)
    if not ok then OA.log("terminals on a generator's change failed:", tostring(err)) end
end

if Events.OnPZToolsGeneratorPower then Events.OnPZToolsGeneratorPower.Add(onGeneratorPower) end
