-- The serums as items: what injecting an upgrade serum, using a cure serum or taking a delay drug does. These run where
-- the world is decided (the server, or the game alone), from the timed actions in Actions.lua. The rules themselves
-- (Rules.lua) are pure; this file touches the character, the item and the save.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Serums = {}
OA.Upgrades.Serums = Serums

-- The side effects of an upgrade serum before 혈청 적응: food sickness (0 to 100) and fatigue (0 to 1) it raises to.
Serums.NAUSEA = 30
Serums.FATIGUE = 0.15
-- The infection must be this young (hours) for the polling bite shield to count it as the bite's.
Serums.BITE_FRESH_HOURS = 2

-- What kind of serum an item type is: "upgrade" (with its tree), "shared", "cure", "delay", or nil.
function Serums.kind(itemType)
    for tree, name in pairs(Data.SERUM_ITEM) do
        if itemType == name then return "upgrade", tree end
    end
    if itemType == Data.SHARED_ITEM then return "shared" end
    if itemType == "CureSerum" then return "cure" end
    if itemType == "DelayDrug" then return "delay" end
    return nil
end

-- Takes an item out of its container (the server tells the clients).
local function consume(item)
    local container = item and item:getContainer()
    if not container then return false end
    container:DoRemoveItem(item)
    if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, item) end
    return true
end

local function recordOf(character, id)
    local name = character.getUsername and character:getUsername() or nil
    return OA.Store.ensure(id or OA.Store.idOf(character), name)
end

-- ---- upgrade serums ---------------------------------------------------------------------------------------------

-- The side effects: a short nausea and tiredness, smaller with 혈청 적응 (none at rank 2). Set, not added, so the
-- API's endurance and infection hooks do not see them.
function Serums.sideEffects(character, share)
    if share <= 0 then return end
    local stats = character:getStats()
    local nausea = Serums.NAUSEA * share
    if stats:get(CharacterStat.FOOD_SICKNESS) < nausea then stats:set(CharacterStat.FOOD_SICKNESS, nausea) end
    local tired = math.min(1, stats:get(CharacterStat.FATIGUE) + Serums.FATIGUE * share)
    stats:set(CharacterStat.FATIGUE, tired)
end

-- Injects an upgrade or shared serum: the item goes, the point is added, the tree opens with its first serum (the
-- event the player is told of), the body reacts. Returns true when it was done.
function Serums.inject(character, item, id)
    local kind, tree = Serums.kind(item:getType())
    if kind ~= "upgrade" and kind ~= "shared" then return false end
    id = id or OA.Store.idOf(character)
    local record = recordOf(character, id)
    local u = Rules.section(record)
    if not consume(item) then return false end
    local share = Rules.sideEffects(u)
    local first = false
    if kind == "upgrade" then
        first = Rules.inject(u, tree)
    else
        Rules.injectShared(u)
    end
    Serums.sideEffects(character, share)
    if first then
        OA.Sync.notice(id, "IGUI_OA_Tree_Event_" .. tree, {})
    elseif kind == "upgrade" then
        OA.Sync.notice(id, "IGUI_OA_Tree_PointGained", { tree })
    else
        OA.Sync.notice(id, "IGUI_OA_Tree_SharedGained", {})
    end
    -- The hallucination at the meteor site (혈청 적응 rank 2): the story part shows it, if it is there.
    if Rules.rank(u, "serumAdapt") >= 2 and OA.Story and OA.Story.onSerum then
        pcall(OA.Story.onSerum, character, record, kind == "upgrade" and tree or "shared")
    end
    OA.Sync.changed("upgrades", id, { kind = kind, tree = tree })
    return true
end

-- ---- cure serum and delay drug ----------------------------------------------------------------------------------

-- Whether the character has the infection (the real one, or a fake one that a serum would end too).
function Serums.infected(character)
    local body = character:getBodyDamage()
    return body:IsInfected() or body:IsFakeInfected()
end

-- Ends the infection: the body's flag and its timers, every part's flag (a part still marked would infect the body
-- again at the next update), the stats.
function Serums.cureBody(character)
    local body = character:getBodyDamage()
    body:setInfected(false)
    body:setInfectionTime(-1.0)
    body:setInfectionMortalityDuration(-1.0)
    local parts = body:getBodyParts()
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        part:SetInfected(false)
        if part:IsFakeInfected() then part:DisableFakeInfection() end
    end
    body:setIsFakeInfected(false)
    local stats = character:getStats()
    stats:reset(CharacterStat.ZOMBIE_INFECTION)
    stats:reset(CharacterStat.ZOMBIE_FEVER)
end

-- Whether a cure serum item works for the character now: "ok" and the days left, "expired" or "notOwner".
function Serums.cureStatus(item, id, now)
    local data = item:getModData()
    return Rules.cureStatus(data.OA_Issued, data.OA_Owner, id, now or OA.hours(), OA.option("CureSerumShelfLife") or 7)
end

-- Uses a cure serum. Not the owner's or past its shelf life: nothing happens and the serum stays (the player is
-- told). Returns true when the infection was cured.
function Serums.cure(character, item, id)
    if Serums.kind(item:getType()) ~= "cure" then return false end
    id = id or OA.Store.idOf(character)
    local status = Serums.cureStatus(item, id)
    if status == "expired" then
        OA.Sync.notice(id, "IGUI_OA_Tree_CureExpired", {})
        return false
    elseif status == "notOwner" then
        OA.Sync.notice(id, "IGUI_OA_Tree_CureNotOwner", {})
        return false
    end
    if not Serums.infected(character) then
        OA.Sync.notice(id, "IGUI_OA_Tree_CureNotInfected", {})
        return false
    end
    if not consume(item) then return false end
    Serums.cureBody(character)
    OA.Sync.notice(id, "IGUI_OA_Tree_CureDone", {})
    return true
end

-- Takes a delay drug: infection runs at a quarter of its speed for DelayDrugHours (drugs taken in that time add to
-- it). The slowing itself is done by Infection.lua, once a minute, while the window lasts.
function Serums.delay(character, item, id)
    if Serums.kind(item:getType()) ~= "delay" then return false end
    id = id or OA.Store.idOf(character)
    if not Serums.infected(character) then
        OA.Sync.notice(id, "IGUI_OA_Tree_DelayNotInfected", {})
        return false
    end
    local record = recordOf(character, id)
    local u = Rules.section(record)
    if not consume(item) then return false end
    local hours = OA.option("DelayDrugHours") or 24
    Rules.addDelay(u, OA.hours(), hours)
    OA.Sync.notice(id, "IGUI_OA_Tree_DelayDone", { hours })
    OA.Sync.changed("upgrades", id, { kind = "delay" })
    return true
end

-- Dispatches an item to what it does.
function Serums.use(character, item, id)
    local kind = Serums.kind(item:getType())
    if kind == "upgrade" or kind == "shared" then return Serums.inject(character, item, id) end
    if kind == "cure" then return Serums.cure(character, item, id) end
    if kind == "delay" then return Serums.delay(character, item, id) end
    return false
end

-- ---- the infection, once a minute --------------------------------------------------------------------------------

-- Holds infection back while a delay drug lasts: the infection's start time moves forward by the share of the time
-- from `from` (the last check) to `now` that the drug held back (Rules.delayShift). Call about once a minute for the
-- local character. Returns the hours it moved the start by.
function Serums.slowInfection(character, u, from, now)
    if u.delayUntil <= 0 then return 0 end
    local shift = Rules.delayShift(u, from, now)
    if shift <= 0 then return 0 end
    local body = character:getBodyDamage()
    if not body:IsInfected() then return 0 end
    local time = body:getInfectionTime()
    if time < 0 then return 0 end
    body:setInfectionTime(time + shift)
    return shift
end

-- The polling bite shield (until the API's): when the character has a fresh infection that came from a bite and the
-- shield is armed, the infection of the bitten parts is undone. Returns true when it saved a bite (the caller tells
-- the server, which starts the shield's rest). The bitten parts stay wounded; only the infection goes.
function Serums.shieldBite(character, u, now)
    if not Rules.biteReady(u, now) then return false end
    local body = character:getBodyDamage()
    if not body:IsInfected() then return false end
    local time = body:getInfectionTime()
    if time < 0 or (character:getHoursSurvived() - time) > Serums.BITE_FRESH_HOURS then return false end
    local parts = body:getBodyParts()
    local bitten = false
    local other = false
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        if part:IsInfected() then
            if part:bitten() then
                bitten = true
            else
                other = true
            end
        end
    end
    if not bitten then return false end
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        if part:bitten() and part:IsInfected() then part:SetInfected(false) end
    end
    if not other then
        body:setInfected(false)
        body:setInfectionTime(-1.0)
        body:setInfectionMortalityDuration(-1.0)
        local stats = character:getStats()
        stats:reset(CharacterStat.ZOMBIE_INFECTION)
        stats:reset(CharacterStat.ZOMBIE_FEVER)
    end
    return true
end

return Serums
