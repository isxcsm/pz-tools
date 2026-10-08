-- The base machines on the server side (alone, the game runs this too): the ten-minute work, the catch-up when a
-- chunk loads, the commands from the windows. Nothing runs per tick or per square.
require "OperationAcorn/Server"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
local OA = OperationAcorn
local Machines = OA.Machines

-- A window's switch: a machine on or off.
OA.Server.on("machineSwitch", function(character, record, args)
    if type(args.machine) ~= "string" then return end
    local object = Machines.find(args.machine)
    if not object then return end
    Machines.setOn(object, args.on == true)
    OA.Sync.changed("machines", args.id, { machine = args.machine })
end)

-- The generator load of the machines, declared to the extension API once the game runs.
Events.OnGameStart.Add(Machines.declarePower)
-- Every ten game minutes the loaded machines work on what is in them.
Events.EveryTenMinutes.Add(Machines.tick)
-- A chunk loads: the machines in it catch up the time they were away.
Events.LoadChunk.Add(Machines.onChunk)
-- A machine destroyed by other means (a sledgehammer, fire): it leaves the registry.
Events.OnDestroyIsoThumpable.Add(function(object) Machines.forget(object) end)
