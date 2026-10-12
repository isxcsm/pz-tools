-- P3: the bite shield stand-in (polled once a minute until the API shield exists).
-- Setup: a single-player world, the mod on. Changes the record and the character's body: use a throwaway save.
-- Prints "[p3bite]" lines; wait one game minute after the bite for the result.
RUN("p3_lib.lua")
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Serums = OA.Upgrades.Serums
local Effects = OA.Upgrades.Effects
local say = P3T.say("p3bite")
local record, player, u, id = P3T.record()

P3T.points(u, "survival", 12)
for _, nid in ipairs({ "resist", "resist", "resist", "resistPlus", "resistPlus" }) do
    local ok, why = Rules.buy(u, nid)
    if not ok then say("could not buy", nid, why) end
end
P3T.changed(record)
say("bite ready", Rules.biteReady(u, OA.hours()), "API shield applied", Effects.biteShieldApplied())
local body = player:getBodyDamage()
local part = body:getBodyPart(BodyPartType.Hand_R)
part:SetBitten(true)
part:SetInfected(true)
body:setInfected(true)
body:setInfectionTime(OA.hours())
body:setInfectionMortalityDuration(60)
say("bitten and infected now; wait one game minute: the infection should be undone, with a notice of the days to the next save")
say("infected now", Serums.infected(player), "(then check biteAt after the minute)", tostring(u.biteAt))
