-- P4: the mission circle, the dots to it and the supply crates on the world map, and the circle on the minimap. Needs an
-- active mission (run p4_missions.lua first). Opens the world map the way the terminal's "show on map" does: it must
-- hold the character and the circle together, the circle teal (sky blue for a story mission) with ten small dots from
-- the character to its edge and an orange mark for each crate left. Close the map and open it again: all must come
-- back. Then look at the minimap: the circle only. The numbers are the zoom the fit chose and the game's own scale.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4map")
local record = P4T.record()
local m = record and OA.Missions.active(record)
if not m then say("no active mission"); return end
local circles = OA.StoryView.circles(m)
P4T.check(say, "a circle to draw", #circles >= 1, #circles)
say("circle", circles[1].x, circles[1].y, circles[1].r)
OA.StoryMaps.show(getPlayer())
local api = ISWorldMap_instance.mapAPI
say("zoom", api:getZoomF(), "base", api:getBaseZoom(), "isometric", api:getBoolean("Isometric"))
say("screen scale of the game vs the formula (once the zoom has settled)", api:getWorldScale(),
    2 ^ api:getZoomF() * ISWorldMap_instance:getHeight() / OA.StoryView.EARTH)
say("world map opened")
