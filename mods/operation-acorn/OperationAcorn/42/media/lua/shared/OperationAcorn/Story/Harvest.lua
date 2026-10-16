-- Zombie samples (DESIGN 6 '좀비 시료', NUMBERS 4): a fresh zombie corpse gives one sample, once. The quick harvest wants
-- the scalpel in a hand; the precise one takes twice as long, wants the tweezers anywhere in the inventory and rolls the
-- better grades more often. A character offered the precise harvest is one who has received tweezers (marked then: the
-- corpse menu reads the mark, not the inventory). A target mission's corpse gives that mission's sample instead
-- (Story/Zombies).
--
-- The rules are plain functions; Harvest.take is the server's part that finds the corpse and gives the item.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Zombies"
local OA = OperationAcorn
local Data, Missions, Zombies = OA.StoryData, OA.Missions, OA.ZombieMissions
local Harvest = {}
OA.Harvest = Harvest

Harvest.SCALPEL = Data.fullType("HarvestScalpel")
Harvest.TWEEZERS = Data.fullType("PrecisionTweezers")

-- The grades, commonest first, their items, and the chance of each (percent) for the quick and the precise harvest.
Harvest.GRADES = { "common", "infected", "neural", "anomalous" }
Harvest.TYPES = {
    common = Data.fullType("TissueCommon"), infected = Data.fullType("TissueInfected"),
    neural = Data.fullType("TissueNeural"), anomalous = Data.fullType("TissueAnomalous"),
}
Harvest.QUICK = { 70, 22, 7, 1 }
Harvest.PRECISE = { 55, 28, 12, 5 }

-- The action's length (ticks) and how fresh a corpse must be (hours since death).
Harvest.QUICK_TIME, Harvest.PRECISE_TIME = 150, 300
Harvest.FRESH_HOURS = Zombies.FRESH_HOURS

-- The mark a harvested corpse carries (its modData).
Harvest.MARK = "OA_Harvested"

-- A grade by chance.
function Harvest.roll(precise, int)
    int = int or OA.random
    local odds = precise and Harvest.PRECISE or Harvest.QUICK
    local roll = int(1, 100)
    for i, chance in ipairs(odds) do
        roll = roll - chance
        if roll <= 0 then return Harvest.GRADES[i] end
    end
    return Harvest.GRADES[1]
end

-- Why a corpse gives nothing, or nil when it gives a sample. `corpse` = { zombie, skeleton, death (world hours), taken }.
-- "none": not a zombie's; "old": a skeleton, or dead too long; "taken": harvested already.
function Harvest.refusal(corpse, now)
    if not corpse.zombie then return "none" end
    if corpse.taken then return "taken" end
    if corpse.skeleton or now - (corpse.death or 0) > Harvest.FRESH_HOURS then return "old" end
    return nil
end

-- The character's harvest section: { precise = true once tweezers came }.
function Harvest.section(record)
    return OA.Store.section(record, "harvest")
end

-- The shop delivered a harvest tool (Shop.bought): `mark` is what it opens ("precise").
function Harvest.received(record, mark)
    if mark == "precise" then Harvest.section(record).precise = true end
end

function Harvest.precise(record)
    local s = record and record.harvest
    return s ~= nil and s.precise == true
end

-- Whether a hand holds the scalpel (the menu's look: the two hands only).
function Harvest.holdsScalpel(character)
    local a, b = character:getPrimaryHandItem(), character:getSecondaryHandItem()
    return (a ~= nil and a:getFullType() == Harvest.SCALPEL) or (b ~= nil and b:getFullType() == Harvest.SCALPEL)
end

-- What a corpse is, for Harvest.refusal.
function Harvest.describe(body)
    local md = body:getModData()
    return { zombie = body:isZombie(), skeleton = body:isSkeleton(), death = body:getDeathTime(), taken = md[Harvest.MARK] == true }
end

-- The corpse the menu named: on its square, dead at `death` (the nearest in time when the square holds several).
local function corpseAt(x, y, z, death)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return nil end
    local list = sq:getStaticMovingObjects()
    local best, bestD
    for i = 0, list:size() - 1 do
        local o = list:get(i)
        if instanceof(o, "IsoDeadBody") and o:isZombie() then
            local d = math.abs(o:getDeathTime() - (death or 0))
            if not bestD or d < bestD then best, bestD = o, d end
        end
    end
    return best
end

local function give(character, fullType)
    local item = instanceItem(fullType)
    if not item then return nil end
    local inv = character:getInventory()
    inv:AddItem(item)
    if isServer() then sendAddItemToContainer(inv, item) end
    return item
end

-- The harvest is done (the server): args = { x, y, z, death, precise }. Returns the sample's name, or nil and why not
-- ("scalpel", "tweezers", "gone", and Harvest.refusal's).
function Harvest.take(character, record, args)
    local precise = args.precise == true
    if not Harvest.holdsScalpel(character) then return nil, "scalpel" end
    if precise and not character:getInventory():containsTypeRecurse(Harvest.TWEEZERS) then return nil, "tweezers" end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local body = x and y and z and corpseAt(x, y, z, tonumber(args.death))
    if not body then return nil, "gone" end
    local why = Harvest.refusal(Harvest.describe(body), OA.hours())
    if why then return nil, why end
    body:getModData()[Harvest.MARK] = true
    if isServer() then body:transmitModData() end
    local item
    local key = Missions.game and Missions.game.markOf and Missions.game.markOf(body)
    local m, it, id = Zombies.takeTarget(record, key, body:getDeathTime())
    if m then
        item = Missions.game and Missions.game.giveMissionItem(character, it.type, id, nil, record)
        if item then Missions.found(record, m, it, item) end
    else
        item = give(character, Harvest.TYPES[Harvest.roll(precise)])
    end
    if not item then return nil, "gone" end
    return item:getDisplayName()
end

return Harvest
