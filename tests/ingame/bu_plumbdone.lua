-- Takes away what bu_plumb.lua and bu_rainbarrel.lua put down: the barrel above the sink, the sink's plumbing as it
-- was, and the rain barrel outside.
local t = BUPLUMB
if t then
    t.above:transmitRemoveItemFromSquare(t.barrel)
    t.sink:setUsesExternalWaterSource(t.wasPlumbed)
    print("[buplumb] removed, sink plumbed", tostring(t.sink:getUsesExternalWaterSource()))
end
if BURB then BURBDONE = true RUN("bu_rainread.lua") end
