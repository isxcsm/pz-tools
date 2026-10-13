-- P3: the serums. Injects each serum through the code the timed action runs, checks that the point waits for the
-- adaptation and comes when it is over (Adapt.finish, which the server runs once the record's end has passed), then the cure serum (owner, shelf life, expired) and the delay drug against a real infection.
-- Setup: a single-player world, the mod on. Changes the record and the character's infection: use a throwaway save.
-- Prints "[p3serums]" lines; the on-screen notices and the banner of a tree opening are for you to look at.
RUN("p3_lib.lua")
local OA = OperationAcorn
local Serums = OA.Upgrades.Serums
local Rules = OA.Upgrades.Rules
local say = P3T.say("p3serums")
local record, player, u, id = P3T.record()

for tree, item in pairs(OA.Upgrades.Data.SERUM_ITEM) do
    local before = Rules.ownPool(u, tree)
    local opened = Rules.treeOpen(u, tree)
    local serum = P3T.give("OperationAcorn." .. item)
    P3T.check(say, item .. " exists", serum ~= nil)
    if serum then
        local ok = Serums.use(player, serum, id)
        P3T.check(say, item .. " used", ok)
        P3T.check(say, item .. " gives no point before the adaptation is over", Rules.ownPool(u, tree) == before)
        P3T.check(say, item .. " is adapting", u.adapt ~= nil and (u.adapt.doses[tree] or 0) >= 1)
        OA.Upgrades.Adapt.finish(record, OA.hours() + OA.Upgrades.Data.ADAPT_HOURS + 0.01)
        P3T.check(say, item .. " gave a point", Rules.ownPool(u, tree) == before + 1)
        P3T.check(say, item .. " opened the tree", Rules.treeOpen(u, tree), "was open: " .. tostring(opened))
        P3T.check(say, item .. " is gone from the bag", not player:getInventory():contains(serum))
    end
end
local shared = P3T.give("OperationAcorn.UpgradeSerumShared")
if shared then
    local before = Rules.sharedPool(u)
    Serums.use(player, shared, id)
    OA.Upgrades.Adapt.finish(record, OA.hours() + OA.Upgrades.Data.ADAPT_HOURS + 0.01)
    P3T.check(say, "a shared serum adds a shared point", Rules.sharedPool(u) == before + 1)
end

-- infection: the game's own bite state
local body = player:getBodyDamage()
local function infect()
    local part = body:getBodyPart(BodyPartType.Hand_L)
    part:SetBitten(true)
    part:SetInfected(true)
    body:setInfected(true)
    body:setInfectionTime(getGameTime():getWorldAgeHours())
    body:setInfectionMortalityDuration(60)
end
infect()
P3T.check(say, "the character is infected", Serums.infected(player))

local cure = P3T.give("OperationAcorn.CureSerum")
if cure then
    cure:getModData().OA_Owner = "somebody else"
    cure:getModData().OA_Issued = OA.hours()
    Serums.use(player, cure, id)
    P3T.check(say, "a cure serum of another owner does nothing", Serums.infected(player))
    cure:getModData().OA_Owner = id
    cure:getModData().OA_Issued = OA.hours() - OA.scaled(7, "CureSerumShelfLifeMultiplier") * 24 - 1
    Serums.use(player, cure, id)
    P3T.check(say, "an expired cure serum does nothing", Serums.infected(player))
    cure:getModData().OA_Issued = OA.hours()
    local status, left = Serums.cureStatus(cure, id)
    say("fresh cure status", status, "days left", left)
    Serums.use(player, cure, id)
    P3T.check(say, "a fresh cure serum of its owner cures", not Serums.infected(player))
    for i = 0, body:getBodyParts():size() - 1 do
        if body:getBodyParts():get(i):IsInfected() then say("BAD a part is still infected", i) end
    end
end

infect()
local drug = P3T.give("OperationAcorn.DelayDrug")
if drug then
    local ok = Serums.use(player, drug, id)
    P3T.check(say, "the delay drug is taken while infected", ok)
    local d = record.infection and record.infection.drug
    P3T.check(say, "the drug is recorded with its age", d ~= nil and d.age ~= nil and d.till > OA.hours(), tostring(d and d.till))
    say("let game time pass: the infection percentage should stay where it is while the drug lasts (held once a minute)")
end
