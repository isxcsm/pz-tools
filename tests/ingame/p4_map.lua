-- P4: the map overlay (Story/Maps). Needs an active mission (run p4_missions.lua first). Opens the world map the way the
-- terminal's "show on map" does: it must hold the character and the circle together. The circle: a soft teal disc (sky
-- blue for a story mission) in a ring of outlined dashes slowly marching round, a pulse running out of it every couple
-- of seconds, a pin dropping onto its middle with a bounce, then bobbing, a ripple at its tip each time it lands. The
-- way: thick outlined dashes from the character to the circle's edge, marching toward it. The character: a coral pin
-- with a person on it, ripples breathing out under it. Each crate left: a small orange crate badge. Zoom in and out:
-- the dashes, pins and badges keep their size; switch the map to isometric: the circle becomes an ellipse, the pins
-- stay upright. Close the map and open it again: the pin drops again. Then the minimap: the disc, the ring and the way
-- (smaller, the pin still), clipped to the minimap. The numbers are the zoom the fit chose and the game's own scale.
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
