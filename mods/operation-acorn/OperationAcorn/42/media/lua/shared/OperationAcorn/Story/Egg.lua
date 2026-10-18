-- The Furbert's call (the "egg" branch of the team's calls, Story/Branches; easter egg 1, NUMBERS 13): a record that
-- delivered the Furbert squirrel before the handover hears Branscomb once, a short call that comes into the comms tab
-- at the settlement (he has not put it in the ledger; it is on the squad leader's desk). After the handover there is no
-- call: the receipt's remark is all (Eggs.NOTES), and a call fired but not played by then gives way.
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Eggs"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Comms"
require "OperationAcorn/Story/Branches"
local OA = OperationAcorn
local Egg = {}
OA.StoryEgg = Egg

Egg.CALL = "C_egg_furbert"
Egg.TRIGGER = "egg:furbert"

OA.StoryBranches.define("egg", {
    at = { "settled" },
    fires = function(record)
        if OA.Story.handedOver(record) or not OA.Eggs.furbertCall(record) or OA.Comms.done(record, Egg.CALL) then
            return {}
        end
        return { Egg.TRIGGER }
    end,
    unwanted = function(record)
        return OA.Story.handedOver(record) and { Egg.CALL } or {}
    end,
})

return Egg
