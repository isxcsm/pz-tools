-- P2: the first supply. Prints the plan the vanilla schedule gives and drops the box with the manual by hand near the
-- character. Changes the record (a new active box): use a throwaway save. Prints "[p2first]" lines.
RUN("p2_lib.lua")
local OA = OperationAcorn
local T = OA.Trade
local say = P2T.say("p2first")
local record, player = P2T.record()
if not record then say("no record") return end
local facts = T.FirstSupply.facts()
say("option", facts.option, "nights", facts.nights, "tod", facts.tod, "heliDay", tostring(facts.heliDay),
    "heliEnd", tostring(facts.heliEnd))
local plan = T.FirstSupply.plan(record)
say("plan", plan.mode, "night", plan.day, "hour", plan.hour, "done", tostring(plan.done))
local done = T.FirstSupply.drop(record, player)
P2T.check(say, "box and manual dropped near the character", done == true)
local marks = record.heli.markers or {}
P2T.check(say, "a mark was made", #marks > 0)
if #marks > 0 then say("mark at", marks[#marks].x, marks[#marks].y, "kind", marks[#marks].kind) end
say("take the manual out of the box and the mark goes at the next ten minutes; open the world map to see it")
