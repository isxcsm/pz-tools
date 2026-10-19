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

-- A window watching a machine: its job is due (or something new was put in), so it works now instead of at the next
-- ten-minute step. The work is the time since it last worked, as at a step, so asking often changes nothing else.
OA.Server.on("machineWork", function(character, record, args)
    if type(args.machine) ~= "string" then return end
    local object = Machines.find(args.machine)
    if object then Machines.update(object) end
end)

-- The generator load of the machines, declared to the extension API once the game runs.
OA.on("OnGameStart", Machines.declarePower)
-- Every ten game minutes the loaded machines work on what is in them.
OA.on("EveryTenMinutes", Machines.tick)
-- A chunk loads: the machines in it catch up the time they were away.
OA.on("LoadChunk", Machines.onChunk)
-- A machine destroyed by other means (a sledgehammer, fire): it leaves the registry.
OA.on("OnDestroyIsoThumpable", function(object) Machines.forget(object) end)
