-- The client's side of the adaptation after an upgrade serum dose (DESIGN-terminal 19, shared Upgrades/Adapt.lua): the
-- moodle `적응 중` while the record has doses adapting, and, once a game minute, the ask to the server when the end
-- the record keeps (a world age hour, so it holds across saving and loading) has passed. The server decides and
-- gives the points; a reload that finds the end passed asks at its first minute.
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Moodles"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Moodles = OA.Upgrades.Moodles
local Adapting = {}
OA.Upgrades.Adapting = Adapting

-- The moodle follows the record (call when the record changed, and at the start): its level says about how long is
-- left (Rules.adaptLevel).
function Adapting.moodle(u, now)
    Moodles.set("adapting", u and Rules.adaptLevel(u, now or OA.hours()) or 0)
end

-- Once a game minute for the local character: asks the server for the end when it has come, and keeps the moodle.
function Adapting.minute(player, u, now)
    Adapting.moodle(u, now)
    if Rules.adaptDone(u, now) then OA.Sync.send(player, "upgrades.adapt", {}) end
end

return Adapting
