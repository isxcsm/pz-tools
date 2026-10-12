-- The serums as items: what injecting an upgrade serum, using a cure serum or a reversal, taking a delay drug or a test
-- kit does. These run where the world is decided (the server, or the game alone), from the timed actions in
-- Actions.lua. The rules themselves (Rules.lua, Infection.lua) are pure; this file touches the character, the item and
-- the save.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Upgrades/Infection"
require "OperationAcorn/Upgrades/Guides"
require "OperationAcorn/Upgrades/Adapt"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Infection = OA.Infection
local Guides = OA.Upgrades.Guides
local Adapt = OA.Upgrades.Adapt
local Serums = {}
OA.Upgrades.Serums = Serums

-- The side effects of an upgrade serum before 혈청 적응: the pain in the arm it went into (the game's pain units, which
-- fade by themselves within the hour) and the tiredness it adds (fatigue, 0 to 1: enough to show the moodle on a rested
-- character), never past FATIGUE_MAX (the character does not drop asleep from a dose).
Serums.PAIN = 25
Serums.FATIGUE = 0.5
Serums.FATIGUE_MAX = 0.95
-- The infection must be this young (hours) for the polling bite shield to count it as the bite's.
Serums.BITE_FRESH_HOURS = 2

-- The delay drugs by item type: how long each holds the infection ("short": a day, "long": seven).
Serums.DELAY = { DelayDrug = "short", DelayDrugLong = "long" }

-- What kind of serum an item type is: "upgrade" (with its tree), "shared", "cure", "delay" (with "long" or "short"),
-- "reversal", "test", or nil.
function Serums.kind(itemType)
    for tree, name in pairs(Data.SERUM_ITEM) do
        if itemType == name then return "upgrade", tree end
    end
    if itemType == Data.SHARED_ITEM then return "shared" end
    if itemType == "CureSerum" then return "cure" end
    if Serums.DELAY[itemType] then return "delay", Serums.DELAY[itemType] end
    if itemType == "InfectionReversal" then return "reversal" end
    if itemType == "InfectionTestKit" then return "test" end
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

-- The side effects: a sore arm and tiredness, smaller with 혈청 적응 (none at rank 2). Set, not added, so the API's
-- hooks do not see them. A character already as tired as FATIGUE_MAX or more is left as tired as it is.
function Serums.sideEffects(character, share)
    if share <= 0 then return end
    local arm = character:getBodyDamage():getBodyPart(BodyPartType.UpperArm_L)
    local pain = Serums.PAIN * share
    if arm and arm:getAdditionalPain() < pain then arm:setAdditionalPain(pain) end
    local stats = character:getStats()
    local now = stats:get(CharacterStat.FATIGUE)
    if now < Serums.FATIGUE_MAX then
        stats:set(CharacterStat.FATIGUE, math.min(Serums.FATIGUE_MAX, now + Serums.FATIGUE * share))
    end
end

-- Injects an upgrade or shared serum: the item goes, the body reacts, and the body adapts (Adapt.lua): the point comes,
-- and the tree opens with its first serum, when the adaptation is over. The first dose ever brings the research
-- plan to the terminal's folder. Returns true when it was done.
function Serums.inject(character, item, id)
    local kind, tree = Serums.kind(item:getType())
    if kind ~= "upgrade" and kind ~= "shared" then return false end
    id = id or OA.Store.idOf(character)
    local record = recordOf(character, id)
    local u = Rules.section(record)
    if not consume(item) then return false end
    local share = Rules.sideEffects(u)
    Serums.sideEffects(character, share)
    if Adapt.start(record, kind == "upgrade" and tree or "shared") then
        OA.Sync.notice(id, "IGUI_OA_Tree_GuideSent", {})
    end
    -- The hallucination at the meteor site (혈청 적응 rank 2): the story part shows it, if it is there.
    if Rules.rank(u, "serumAdapt") >= 2 and OA.Story and OA.Story.onSerum then
        pcall(OA.Story.onSerum, character, record, kind == "upgrade" and tree or "shared")
    end
    OA.Sync.changed("upgrades", id, { kind = kind, tree = tree })
    return true
end

-- ---- the infection medicines ------------------------------------------------------------------------------------

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
    return Rules.cureStatus(data.OA_Issued, data.OA_Owner, id, now or OA.hours(), OA.scaled(7, "CureSerumShelfLifeMultiplier"))
end

-- The infection's progress (0 to 1) as the body has it.
function Serums.progress(character)
    return OA.clamp(character:getStats():get(CharacterStat.ZOMBIE_INFECTION) / 100, 0, 1)
end

-- Real seconds from the cure's stamp to the line the character says, and to the certificate's notice.
Serums.CURED_SAY_DELAY = 2.5

-- Uses a cure serum. Not the owner's or past its shelf life: nothing happens and the serum stays (the player is
-- told). Not infected: it is used up and nothing is said, so that it cannot be a test. Cured: the green stamp with the
-- days it took and the drugs, a line a moment later, the certificate of its length in the folder (DESIGN-terminal
-- 17.6). Returns true when the infection was cured.
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
    if not consume(item) then return false end
    if not Serums.infected(character) then return false end
    Serums.cureBody(character)
    local record = recordOf(character, id)
    local days, doses, length = Infection.summary(record, OA.hours())
    Infection.cured(record)
    OA.Sync.changed("infection", id, { kind = "cured" })
    OA.Sync.title(id, { key = "IGUI_OA_Title_Cured", sub = doses > 0 and "IGUI_OA_Title_CuredSubDrugs" or "IGUI_OA_Title_CuredSub",
        subArgs = { days, doses }, style = "dust", tone = "green", fallback = "good" })
    OA.Say.tell(id, "Cured", { length = length }, Serums.CURED_SAY_DELAY)
    local sent, paper = Guides.certify(record, length, days, doses)
    if sent then Guides.title(id, paper) end
    return true
end

-- Takes a delay drug ("long" or "short"): the infection's progress is held for its days, whether or not there is an
-- infection (the player is told the same either way). It replaces the drug before it. The holding itself is done by
-- Serums.holdInfection, once a minute.
function Serums.delay(character, item, id)
    local kind, length = Serums.kind(item:getType())
    if kind ~= "delay" then return false end
    id = id or OA.Store.idOf(character)
    local record = recordOf(character, id)
    if not consume(item) then return false end
    local age = nil
    local body = character:getBodyDamage()
    if body:IsInfected() then
        local time = body:getInfectionTime()
        if time >= 0 then age = math.max(0, character:getHoursSurvived() - time) end
    end
    Infection.dose(record, length, OA.hours(), age)
    OA.Sync.notice(id, "IGUI_OA_Tree_DelayDone", { Infection.DRUG_HOURS[length] / 24 })
    OA.Sync.changed("infection", id, { kind = "drug" })
    -- the first drug has a line, once (the same whether or not there is an infection)
    local inf = Infection.section(record)
    inf.told = inf.told or {}
    if not inf.told.delay then
        inf.told.delay = true
        OA.Say.tell(id, "DelayFirst")
    end
    return true
end

-- Takes a reversal: an infection starts over from nothing (its start time is now, so the nausea and the health limit
-- of its progress go) but stays, and a drug goes on holding it. Without an infection it is used up and the player is
-- told the same.
function Serums.reverse(character, item, id)
    if Serums.kind(item:getType()) ~= "reversal" then return false end
    id = id or OA.Store.idOf(character)
    local record = recordOf(character, id)
    if not consume(item) then return false end
    local body = character:getBodyDamage()
    if body:IsInfected() then
        body:setInfectionTime(character:getHoursSurvived())
        character:getStats():set(CharacterStat.ZOMBIE_INFECTION, 0)
        Infection.reversed(record)
        OA.Sync.changed("infection", id, { kind = "reversed" })
    end
    OA.Sync.title(id, { key = "IGUI_OA_Title_Reversal", style = "notice", tone = "green", fallback = "good" })
    OA.Say.tell(id, "Reversal")
    return true
end

-- Uses a test kit: the real infection is found or not, and the player knows from now on (a wound is tested for either
-- way). A positive test is a red stamp and a line, and the first one brings the handling notice to the folder; a
-- negative one is the news title `음성 · 수수료 없음` and a line (DESIGN-terminal 17.6).
function Serums.test(character, item, id)
    if Serums.kind(item:getType()) ~= "test" then return false end
    id = id or OA.Store.idOf(character)
    local record = recordOf(character, id)
    if not consume(item) then return false end
    local infected = character:getBodyDamage():IsInfected()
    local positives = Infection.tested(record, infected, infected and Serums.progress(character) or nil, OA.hours())
    OA.Sync.changed("infection", id, { kind = "tested" })
    if infected then
        OA.Sync.title(id, { key = "IGUI_OA_Title_TestPositive", style = "dust", tone = "red", fallback = "bad" })
        OA.Say.tell(id, "TestPositive", { first = positives == 1 })
        if Guides.deliver(record, Guides.NOTICE) then Guides.title(id, Guides.NOTICE) end
    else
        OA.Sync.title(id, { key = "IGUI_OA_Title_TestNegative", sub = "IGUI_OA_Title_TestNegativeSub", style = "notice",
            tone = "green", fallback = "good" })
        OA.Say.tell(id, "TestNegative")
    end
    return true
end

-- Dispatches an item to what it does.
function Serums.use(character, item, id)
    local kind = Serums.kind(item:getType())
    if kind == "upgrade" or kind == "shared" then return Serums.inject(character, item, id) end
    if kind == "cure" then return Serums.cure(character, item, id) end
    if kind == "delay" then return Serums.delay(character, item, id) end
    if kind == "reversal" then return Serums.reverse(character, item, id) end
    if kind == "test" then return Serums.test(character, item, id) end
    return false
end

-- ---- the infection, once a minute --------------------------------------------------------------------------------

-- Holds the infection where the drug took it: while a drug lasts, the infection's start time is set so that its age
-- stays the same (the progress, the nausea and the health limit stay as they were). Call about once a minute for the
-- local character, with its record. Returns true when it set the time.
function Serums.holdInfection(character, record, now)
    local age = Infection.holdAge(record, now)
    if not age then return false end
    local body = character:getBodyDamage()
    if not body:IsInfected() or body:getInfectionTime() < 0 then return false end
    body:setInfectionTime(math.max(0, character:getHoursSurvived() - age))
    return true
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
