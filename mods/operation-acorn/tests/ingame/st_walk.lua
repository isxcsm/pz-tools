-- The character walked toward a point (ST_TO = { x, y }) by the game's own path (as a click on the ground moves it).
local p = getPlayer()
local to = ST_TO
local sq = getCell():getGridSquare(to[1], to[2], 0)
if not sq then ST.say("WALK: square not loaded", to[1], to[2]) return end
ISTimedActionQueue.clear(p)
ISTimedActionQueue.add(ISWalkToTimedAction:new(p, sq))
ST.say("WALK to", to[1], to[2])
