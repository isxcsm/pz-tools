-- P3: the hunch widget (육감), presence sense (기척 감지), alarm reading (경보 읽기) and the looting ledger (털이 기록).
-- Setup: a single-player world, the mod on; stand near a few zombies (debug spawn 3 at about 10 tiles), then near an
-- alarmed house or car if you can. Changes the record (gives the ranks).
-- Prints "[p3senses]" lines; the HUD marks are for you to look at (sneak: marks around the edge; standing: nothing,
-- until Presence Sense Boost rank 1, which this script gives, so standing walks shows them too).
RUN("p3_lib.lua")
local OA = OperationAcorn
local Senses = OA.Upgrades.Senses
local Rules = OA.Upgrades.Rules
local say = P3T.say("p3senses")
local record, player, u = P3T.record()

P3T.points(u, "scout", 12)
for _, id in ipairs({ "sixth", "sixth", "alarm", "ledger", "ledger", "ledger", "sense", "sense", "sensePlus", "sensePlus",
    "sensePlus" }) do
    local ok, why = Rules.buy(u, id, { fragments = 0 })
    if not ok then say("could not buy", id, why) end
end
P3T.changed(record)
OA.Upgrades.Hooks.refresh()
P3T.check(say, "the shared timer is on", OA.Upgrades.Pulse.enabled())
local S = Senses.state
local marks = 0
for _ in pairs(S.dirs or {}) do marks = marks + 1 end
say("ring on", S.ring, "hunch on", S.sixth, "marks", marks, "alarms", #(S.alarms or {}))
say("sneaking now", player:isSneaking(), "(check again while sneaking: ring should be true, marks > 0 near zombies)")
local l = Senses.ledger
say("ledger: building", tostring(l.key), "total", l.total, "opened", l.opened, "complete", tostring(l.complete))
say("enter a building, open containers: a halo text with the count of unopened containers appears; open the rest: done text")
