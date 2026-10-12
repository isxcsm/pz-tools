-- The adapter to PZ Extension API: what the character's ranks mean for the game's own numbers. The API
-- changes the game where its hooks are; this file only declares, per point, one value for the local character:
--   PZExtAPI.formulas.set(handle, pointName, value)   value nil clears the point
--   PZExtAPI.formulas.points()  ->  { [pointName] = "applied" | another status }
-- POINTS below is the one place that names the points (a rename is one line). MAP says which nodes feed which.
-- Without the API, or without a point, the node's tooltip says it needs PZ Extension API, and nothing else changes: this mod
-- never changes vanilla numbers itself.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Effects = {}
OA.Upgrades.Effects = Effects

-- The points' names. The keys are the code's names for them; the values are what the API is told.
Effects.POINTS = {
    carryCategory = "carry.categoryEfficiency",
    carryItem = "carry.itemEfficiency",
    carryTag = "carry.containerTagMultiplier",
    maxWeightAdd = "capacity.maxWeightAdd",
    capacityKey = "capacity.modDataKey",
    storage = "capacity.effectiveMultiplier",
    limitAdd = "capacity.characterLimitAdd",
    overload = "overload.compress",
    runPenalty = "move.runPenaltyReduction",
    combatPenalty = "move.combatPenaltyReduction",
    walk = "move.walkMultiplier",
    treeSlow = "move.treeSlowMultiplier",
    treeScratch = "move.treeScratchChance",
    endurance = "body.enduranceDrainMultiplier",
    poison = "body.poisonMultiplier",
    fatigue = "body.fatigueMultiplier",
    cold = "body.coldMultiplier",
    discomfort = "body.discomfortMultiplier",
    corpseCount = "body.corpseCountMultiplier",
    corpseSickness = "body.corpseSicknessMultiplier",
    stiffness = "body.stiffnessMultiplier",
    hole = "body.holeChance",
    woundChance = "infection.woundChance",
    biteShield = "infection.biteShield",
    height = "fall.heightMultiplier",
    impact = "fall.impactMultiplier",
    loot = "loot.spawnMultiplier",
    ammo = "loot.ammoMultiplier",
    darkness = "vision.darknessRestore",
    cone = "vision.coneAdd",
    nightSight = "vision.nightSight",
    hiddenZombie = "vision.hiddenZombieFix",
}
local P = Effects.POINTS
-- The modData key that lifts the game's capacity caps on a container (the other packages set it to true).
Effects.CAPACITY_KEY = "OA_Capacity"

-- Which points each API node feeds (node id -> list of point keys). Lua-only nodes are not here.
Effects.MAP = {
    sight = { "cone" }, rich = { "loot" }, night = { "darkness", "nightSight" }, ammo = { "ammo" },
    nightEye = { "darkness", "nightSight" },
    overload = { "overload" }, keyring = { "carryTag" }, furniture = { "carryItem" },
    materials = { "carryCategory" }, materialsPlus = { "carryCategory" }, runSpeed = { "runPenalty" },
    capacity = { "maxWeightAdd", "limitAdd" }, combatSpeed = { "combatPenalty" }, storage = { "storage" },
    armor = { "discomfort" }, stiff = { "stiffness" }, fall = { "height" }, brush = { "treeSlow", "treeScratch" },
    gear = { "hole" }, resist = { "poison", "cold", "corpseCount", "corpseSickness" }, walk = { "walk" },
    resistPlus = { "woundChance", "biteShield" },
    bHeavy = { "carryCategory", "carryItem" }, bFamily = { "carryCategory" }, bGear = { "discomfort" },
    bSpeedPen = { "runPenalty", "combatPenalty" }, bOverload = { "overload" },
    bLimit = { "maxWeightAdd", "limitAdd" }, bStorage = { "storage" }, bWound = { "woundChance" },
    bIllness = { "poison", "cold", "corpseCount", "corpseSickness" }, bStiff = { "stiffness" },
    bEndurance = { "endurance" }, bSleep = { "fatigue" }, bGearLoss = { "hole" }, bFall = { "impact" },
    bWalk = { "walk" }, bLoot = { "loot" },
}

-- The cone the sight node may add at most (degrees), whatever the effect option says.
local MAX_CONE = 90
-- Night sight (PZ Extension API: the dark is lifted to the value, in grey; what a light lights keeps its colour) by the rank of
-- 밤눈, and with 야행성 눈. Measured at 2 a.m. in an office with no light: 0.1 barely lifts it, 0.3 showed all of it
-- (too much for a rank before the capstone), 0.5 shows it plainly.
local NIGHT_SIGHT = { 0.1, 0.2, 0.25 }
local NIGHT_SIGHT_EYE = 0.5
-- The cone the dark takes back (vision.darknessRestore) never brings the night's cone up to the day's: in the full dark
-- 야행성 눈 leaves it NIGHT_MARGIN degrees under the character's day cone. Vanilla (LightingJNI.calculateVisionCone): the
-- dark takes up to DARK_CONE degrees; the Night Vision trait adds TRAIT_CONE by the dark and Eagle Eyed TRAIT_CONE by the
-- daylight, so with Night Vision a full restore made the night 36 degrees wider than the day.
local DARK_CONE, TRAIT_CONE, NIGHT_MARGIN = 126, 36, 18

-- The most of the dark's cone 야행성 눈 gives back, for a character with or without the two traits: 1 - 18/126 (0.857)
-- with neither, 1 - 54/126 (0.571) with Night Vision alone, all of it with Eagle Eyed alone.
function Effects.darknessCap(nightVision, eagleEyed)
    local over = TRAIT_CONE * ((nightVision and 1 or 0) - (eagleEyed and 1 or 0)) + NIGHT_MARGIN
    return OA.clamp(1 - over / DARK_CONE, 0, 1)
end
-- The share of a fall's height 낙법 counts by its rank: the game works out everything of a landing from its height
-- (the kind of landing and its animation, being thrown down, the damage, the lethal height of 3.5 floors), so all of it
-- follows. The damage is linear in the height.
local FALL_HEIGHT = { 0.5, 0.25, 0.125 }
-- Every fall lands with at least the light landing, and from rank 2 faster (media/AnimSets/player/falling/
-- oa_land_*_r<rank>.xml, written by tools/land_nodes.py): the character variable they ask for, set to the rank.
Effects.LAND_VARIABLE = "OALandRank"

-- Whether the Zombie Visibility Fix mod is active: then the hidden zombie fix stands aside (DESIGN 7).
function Effects.visibilityModActive()
    if type(getActivatedMods) ~= "function" then return false end
    local ok, result = pcall(function()
        local mods = getActivatedMods()
        for i = 0, mods:size() - 1 do
            local id = string.lower(tostring(mods:get(i)))
            if string.find(id, "visibilityfix", 1, true) or string.find(id, "zombievisibility", 1, true) then
                return true
            end
        end
        return false
    end)
    return ok and result or false
end

local function positive(x)
    if x > 1e-9 then return x end
    return nil
end

-- Every point's value for a section of upgrades at world age `now` (hours): { [point name] = value }, a name left out
-- is cleared. Pure; the unit tests check it against the formulas of TREES and NUMBERS.
function Effects.compute(u, now, options)
    options = options or {}
    local R = Rules
    local m = R.mult()
    local out = {}
    -- not a node: the delivery box, the research storage and the kits mark their containers with this modData key
    -- to be held to none of the game's capacity limits
    out[P.capacityKey] = Effects.CAPACITY_KEY
    local function rank(id) return R.rank(u, id) end
    local function board(id) return R.boardAmount(u, id) end

    -- vision
    if rank("sight") > 0 then out[P.cone] = math.min(R.value(u, "sight"), MAX_CONE) end
    if rank("nightEye") > 0 then
        -- never less than 밤눈 3 gave (with Night Vision the cap is under it; 밤눈's own ranks stay under the day as they are)
        out[P.darkness] = math.max(Effects.darknessCap(options.nightVision, options.eagleEyed),
            OA.clamp(R.fraction(u, "night"), 0, 1))
        out[P.nightSight] = NIGHT_SIGHT_EYE
    elseif rank("night") > 0 then
        out[P.darkness] = OA.clamp(R.fraction(u, "night"), 0, 1)
        out[P.nightSight] = NIGHT_SIGHT[rank("night")]
    end

    -- loot
    if rank("rich") > 0 or board("bLoot") > 0 then out[P.loot] = 1 + R.fraction(u, "rich") + board("bLoot") end
    if rank("ammo") > 0 then out[P.ammo] = 1 + R.fraction(u, "ammo") end

    -- carry: the efficiencies add up, the API divides a weight by (1 + sum)
    local material = R.fraction(u, "materials")
    if rank("materialsPlus") > 0 then material = R.fraction(u, "materialsPlus") end
    material = material + board("bHeavy")
    local category = {}
    if material > 0 then
        for _, name in ipairs(Data.MATERIAL_CATEGORIES) do category[name] = material end
    end
    for _, family in ipairs(Data.FAMILY_ORDER) do
        local amount = R.familyAmount(u, family)
        if amount > 0 then
            for _, name in ipairs(Data.FAMILIES[family]) do category[name] = (category[name] or 0) + amount end
        end
    end
    if not OA.isEmpty(category) then out[P.carryCategory] = category end
    local item = {}
    local furniture = R.fraction(u, "furniture") + board("bHeavy")
    if furniture > 0 then item["base:moveable"] = furniture end
    if not OA.isEmpty(item) then out[P.carryItem] = item end
    if rank("keyring") > 0 then out[P.carryTag] = { ["base:keyring"] = 0 } end

    -- capacity
    local add = R.value(u, "capacity") + board("bLimit")
    if add > 0 then
        -- both points take whole numbers
        out[P.maxWeightAdd] = math.floor(add + 0.5)
        out[P.limitAdd] = math.floor(add * Data.LIMIT_PER_WEIGHT + 0.5)
    end
    local storage = R.fraction(u, "storage") + board("bStorage")
    if storage > 0 then out[P.storage] = 1 + storage end
    if rank("overload") > 0 or board("bOverload") > 0 then
        local kept = 1
        if rank("overload") > 0 then
            local cut = OA.clamp((100 - Data.byId.overload.values[rank("overload")]) / 100 * m, 0, Rules.MAX_CUT)
            kept = 1 - cut
        end
        out[P.overload] = 1 - kept * R.divide(board("bOverload"))
    end

    -- move
    if rank("runSpeed") > 0 or board("bSpeedPen") > 0 then
        out[P.runPenalty] = 1 - (1 - R.cut(u, "runSpeed")) * R.divide(board("bSpeedPen"))
    end
    if rank("combatSpeed") > 0 or board("bSpeedPen") > 0 then
        out[P.combatPenalty] = 1 - (1 - R.cut(u, "combatSpeed")) * R.divide(board("bSpeedPen"))
    end
    if rank("walk") > 0 or board("bWalk") > 0 then out[P.walk] = 1 + R.fraction(u, "walk") + board("bWalk") end
    if rank("brush") > 0 then
        out[P.treeSlow] = 1 - R.cutFull(u, "brush")
        if rank("brush") >= 2 then out[P.treeScratch] = 0.5 end
    end

    -- body
    if positive(board("bEndurance")) then out[P.endurance] = R.divide(board("bEndurance")) end
    if positive(board("bSleep")) then out[P.fatigue] = R.divide(board("bSleep")) end
    if rank("resist") > 0 or board("bIllness") > 0 then
        local rate = (1 - R.cut(u, "resist")) * R.divide(board("bIllness"))
        out[P.poison] = rate
        out[P.cold] = rate
        out[P.corpseSickness] = rate
        out[P.corpseCount] = R.divide(R.fraction(u, "resist") + board("bIllness"))
    end
    local discomfort = board("bGear")
    if rank("armor") > 0 then discomfort = discomfort + m end
    if discomfort > 0 then out[P.discomfort] = R.divide(discomfort) end
    if rank("stiff") > 0 or board("bStiff") > 0 then
        out[P.stiffness] = (1 - R.cut(u, "stiff")) * R.divide(board("bStiff"))
    end
    if rank("gear") > 0 or board("bGearLoss") > 0 then
        out[P.hole] = (1 - R.cut(u, "gear")) * R.divide(board("bGearLoss"))
    end

    -- infection
    if rank("resistPlus") > 0 or board("bWound") > 0 then
        out[P.woundChance] = (1 - R.cut(u, "resistPlus")) * R.divide(board("bWound"))
    end
    if R.biteReady(u, now) then out[P.biteShield] = true end

    -- fall
    if rank("fall") > 0 then out[P.height] = FALL_HEIGHT[rank("fall")] end
    if positive(board("bFall")) then out[P.impact] = R.divide(board("bFall")) end

    -- the hidden zombie fix: a base feature of the mod, not a node
    if options.hiddenZombieFix then out[P.hiddenZombie] = true end
    return out
end

-- ---- declaring to the API --------------------------------------------------------------------------------------

local declared = {}
local statuses = nil

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- The value of LAND_VARIABLE for a section of upgrades: the rank of 낙법, else nil (the game's landing).
function Effects.landRank(u)
    local r = Rules.rank(u, "fall")
    if r >= 1 then return tostring(r) end
    return nil
end

-- Forgets what was declared (a new world, a new handle): the next apply declares everything again.
function Effects.reset()
    declared = {}
    statuses = nil
end

-- Whether the hidden zombie fix should be declared: the option on and no other mod doing the same.
function Effects.hiddenZombieFix()
    return OA.option("HiddenZombieFix") == true and not Effects.visibilityModActive()
end

-- Declares the character's values to the API, only the points that changed since the last time. Returns the number
-- of declarations made, or nil with the reason when there is no API.
function Effects.apply(record)
    local api, why = OA.api()
    if not api then return nil, why end
    local formulas = api.formulas
    local handle = OA.handle()
    if type(formulas) ~= "table" or type(formulas.set) ~= "function" or not handle then return nil, "formulas" end
    local u = record and Rules.section(record) or Rules.blank()
    local player = getPlayer and getPlayer()
    local values = Effects.compute(u, OA.hours(), { hiddenZombieFix = Effects.hiddenZombieFix(),
        nightVision = player and player:hasTrait(CharacterTrait.NIGHT_VISION) or false,
        eagleEyed = player and player:hasTrait(CharacterTrait.EAGLE_EYED) or false })
    local count = 0
    for _, name in pairs(P) do
        local value = values[name]
        if not same(declared[name], value) then
            local ok, err = pcall(formulas.set, handle, name, value)
            if ok then
                declared[name] = Rules.copy(value)
                count = count + 1
            else
                OA.log("formulas.set", name, "failed:", tostring(err))
            end
        end
    end
    if type(formulas.points) == "function" then
        local ok, result = pcall(formulas.points)
        statuses = ok and type(result) == "table" and result or nil
    else
        statuses = nil
    end
    return count
end

-- What the API has declared so far (for the in-game check scripts).
function Effects.declared()
    return declared
end

-- Whether the API applies the bite shield point (then the polling stand-in stays off).
function Effects.biteShieldApplied()
    return statuses ~= nil and statuses[P.biteShield] == "applied"
end

-- The carry efficiency the character's declared points give an item (0 when none), for the time of moving it; the
-- weight itself is the API's. The API knows every mod's declarations, so it is asked first (it answers the factor the
-- item's weight is multiplied by: 1 for none, 0.5 for +100%); else the points this mod declared are added up.
function Effects.efficiencyOf(item)
    local api = OA.api()
    local formulas = api and api.formulas
    if type(formulas) == "table" and type(formulas.efficiency) == "function" then
        local ok, factor = pcall(formulas.efficiency, item)
        if ok and type(factor) == "number" and factor > 0 then return 1 / factor - 1 end
    end
    local eff = 0
    local category = declared[P.carryCategory]
    if category then eff = eff + (category[item:getDisplayCategory()] or 0) end
    local special = declared[P.carryItem]
    if special and special["base:moveable"] and instanceof(item, "Moveable") then eff = eff + special["base:moveable"] end
    return eff
end

-- The state of a node's API side: "lua" (the node needs no API), "noApi" (no API, with the reason second), or the
-- name of the first point it feeds that the API does not apply ("noPoint", point name), or "ok".
function Effects.status(id)
    local node = Data.byId[id]
    if not node or node.kind ~= "api" then return "lua" end
    local api, why = OA.api()
    if not api then return "noApi", why end
    local list = Effects.MAP[id]
    if not list then return "ok" end
    if not statuses then return "ok" end
    for _, key in ipairs(list) do
        local name = P[key]
        if statuses[name] ~= "applied" then return "noPoint", name end
    end
    return "ok"
end

return Effects
