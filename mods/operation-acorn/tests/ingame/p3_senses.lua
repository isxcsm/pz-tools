-- P3: the hunch widget (육감), presence sense (기척 감지), alarm reading (경보 읽기) and the looting ledger (털이 기록).
-- Setup: a single-player world, the mod on; stand near a few zombies (debug spawn 3 at about 10 tiles), then near an
-- alarmed house or car (the dev panel's Zombies tab, or OperationAcorn.Dev.alarmHouse() / alarmCar(), alarms the
-- nearest). Changes the record (gives the ranks).
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
    local ok, why = Rules.buy(u, id)
    if not ok then say("could not buy", id, why) end
end
P3T.changed(record)
OA.Upgrades.Hooks.refresh()
P3T.check(say, "the shared timer is on", OA.Upgrades.Pulse.enabled())
local S = Senses.state
local marks = 0
for _ in pairs(S.zombies or {}) do marks = marks + 1 end
say("ring on", S.ring, "hunch on", S.sixth, "marks", marks, "alarm near", S.alarm)
P3T.check(say, "ThumpState is exposed (zombies beating on a door shake their arc)",
    ThumpState ~= nil and ThumpState.instance() ~= nil)
P3T.check(say, "at most eight zombie marks", marks <= OA.Upgrades.Sense.ZOMBIE_MARKS)
for i, m in ipairs(S.zombies or {}) do say("zombie sound", i, m.kind, "at", m.x, m.y, m.z, "until", m.untilMs) end
for i, m in ipairs(S.sounds or {}) do say("noise", i, m.kind, "at", m.x, m.y, m.z, "until", m.untilMs) end
say("look: arcs grow with the zoom; a zombie at a door shakes its arc with strokes outside it; an alarm near beats fast",
    "close round the body, a far one sits small and still on the outer ring")
say("sneaking now", player:isSneaking(), "(check again while sneaking: ring should be true, marks > 0 near zombies)")
local l = Senses.ledger
say("ledger: building", tostring(l.key), "told", tostring(l.told), "done", tostring(l.done))
say("enter a building: a line on how much is left; open containers and step away: a line as a floor's stage goes up;",
    "open the rest and step away: the searched title")
