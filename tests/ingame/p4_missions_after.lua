-- P4: second half of p4_missions.lua. Run it after the character has stood at the mission item's place for a few
-- seconds: counts the item's copies in the building (exactly one per piece), and tells what to look at for the
-- evidence room (a locked door, the key in the same building).
-- Duplicate check: walk 300 squares away, come back, run it again: the count must still be one.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4after")
local record, player = P4T.record()
local m = record and OA.Missions.active(record)
if not m then say("no active mission"); return end
for _, it in ipairs(m.items) do
    local found = P4T.scan(m.id, it.x1, it.y1, it.x2, it.y2, it.z1, it.z2)
    for _, f in ipairs(found) do say("found", f.item, f.container, f.x, f.y, f.z) end
    P4T.check(say, "piece " .. it.key .. " found once", #found == 1, #found)
    P4T.check(say, "piece " .. it.key .. " marked placed", it.placed == true, tostring(it.placed))
    if it.lock then
        say("locked room: check by hand that the door of the room is locked and a key lies elsewhere in the building",
            "keyId", tostring(it.keyId), "keyPlaced", tostring(it.keyPlaced))
    end
end
