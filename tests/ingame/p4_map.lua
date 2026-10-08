-- P4: the mission circle on the world map and the minimap. Needs an active mission (run p4_missions.lua first).
-- Opens the world map centred on the circle (blue for a story mission, amber otherwise). Close the map and open it
-- again: the circle must come back. Then look at the minimap.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4map")
local record = P4T.record()
local m = record and OA.Missions.active(record)
if not m then say("no active mission"); return end
local circles = OA.StoryMaps.circles(m)
P4T.check(say, "a circle to draw", #circles >= 1, #circles)
say("circle", circles[1].x, circles[1].y, circles[1].r)
ISWorldMap.ShowWorldMap(0, circles[1].x, circles[1].y, 14)
OA.StoryMaps.refresh()
say("world map opened")
