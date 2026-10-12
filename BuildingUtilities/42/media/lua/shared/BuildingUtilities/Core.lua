-- Building Utilities: one breaker box powers and waters a whole building through the PZ Extension API.
-- The rules (what joins, how far, one box per building) are this mod's; the API runs the networks.
BuildingUtilities = BuildingUtilities or {}
local BU = BuildingUtilities

BU.MOD = "BuildingUtilities"
BU.UTILITIES = { "power", "water" }
-- Water "nearest": a fixture takes from its own floor's tanks first and from higher floors' only once those are dry,
-- so that the higher floors keep the water only they can reach; "fullest" (every draw from the fullest tank in reach)
-- where the game's API does not have it (Networks finds that out by asking).
BU.POLICY = { power = "sequential", water = "nearest", waterFallback = "fullest" }
BU.API_VERSION = 1
-- Breaker box tiers: an upgrade carries more load, reaches farther and can do more (below).
BU.TIERS = 4

function BU.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildingUtilities] " .. table.concat(parts, " "))
end

-- The extension API, or nil with the reason it is missing: PZ Extension API not installed, or another version.
function BU.api()
    local api = PZExtAPI
    if type(api) ~= "table" or not api.networks then return nil, "missing" end
    if api.version ~= BU.API_VERSION then return nil, "version" end
    -- Water groups take a water network's own producers besides its parents' (API with draw and fill).
    if not api.networks.draw then return nil, "version" end
    -- What is kept of buildings goes with the API's version of them, and the rooms built onto a building come from it
    -- (BU.Panels: an API with buildings.version and buildings.attached).
    if not (api.buildings and api.buildings.version and api.buildings.attached) then return nil, "version" end
    return api
end

-- This mod's handle: every network change goes through it.
function BU.handle()
    local api = BU.api()
    return api and api.client(BU.MOD) or nil
end

-- Water and its purification need hooks of the API in the game, by the names PZExtAPI.hooks() gives them: a
-- game started by an older install, or whose IsoObject another mod changed, may lack them. Water needs the plumbing's
-- questions; water that keeps its taint (the RiskPlumbingUnpurified option) also the purification's two.
local WATER_HOOKS = { "IsoObject.waterQuestions", "IsoObject.checkExternalFluidSource" }
local PURIFY_HOOKS = { "IsoObject.createSampleAndPurifyWater", "IsoObject.isTaintedWater" }
-- Why each is missing (false: it is not), once known for this game; and what a call refused (BU.hookFault).
local known, faults = {}, {}

-- Why one of the hooks is missing: "label: reason", or nil. "not-loaded" (IsoObject has not loaded yet; it has by the
-- time a world starts) counts as there, and is asked again next time. An API from before hooks(), or one whose
-- bootstrap predates the list (an empty table), says nothing: then a call that needs the hooks tells (BU.hookFault).
local function missing(name, labels)
    if known[name] ~= nil then return known[name] or nil end
    local api = BU.api()
    if not api then return "PZExtAPI" end
    local ok, hooks = pcall(function() return type(api.hooks) == "function" and api.hooks() or nil end)
    if not ok or type(hooks) ~= "table" then known[name] = false; return nil end
    local settled = true
    for _, label in ipairs(labels) do
        local state = hooks[label]
        if state == "not-loaded" then settled = false
        elseif state ~= nil and state ~= "applied" then
            known[name] = label .. ": " .. tostring(state)
            return known[name]
        end
    end
    if settled then known[name] = false end
    return nil
end

-- A call the API refused for want of hooks: water (a water network it cannot define) or purify (setPurify(false)).
-- What it said stands as the reason for this world, logged once.
function BU.hookFault(name, reason)
    if faults[name] then return end
    faults[name] = tostring(reason)
    BU.log(name == "water" and "water networks are not in this game - boxes give no water:"
        or "water that keeps its taint is not in this game - the pipes purify:", faults[name])
end

-- Forgets what was learnt, for a world that starts.
function BU.resetHooks() known, faults = {}, {} end

-- Whether boxes can give water in this game: true, or false and why (for the player: a hook and its state, or what
-- the API said).
function BU.waterAvailable()
    local reason = faults.water or missing("water", WATER_HOOKS)
    if reason then return false, reason end
    return true
end

-- Whether water can keep its taint (RiskPlumbingUnpurified): true, or false and why. Without it the pipes purify.
function BU.purifyAvailable()
    local ok, reason = BU.waterAvailable()
    if not ok then return false, reason end
    reason = faults.purify or missing("purify", PURIFY_HOOKS)
    if reason then return false, reason end
    return true
end

function BU.networkId(panelId, utility) return "bu-" .. panelId .. "-" .. utility end

-- "x,y,z,sprite": how an object is named in the saved lists.
function BU.thingKey(x, y, z, sprite) return x .. "," .. y .. "," .. z .. "," .. sprite end

function BU.parseThing(key)
    local x, y, z, sprite = key:match("^(-?%d+),(-?%d+),(-?%d+),(.+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z), sprite
end

-- What is left of value over whole sizes, from 0 up to size. Kahlua's % differs from Lua's on negative numbers and
-- is wrong on the clock's milliseconds (getTimestampMs).
function BU.remainder(value, size) return value - math.floor(value / size) * size end

-- A percentage as an argument of a text: "63%". The texts themselves hold no %, which the game's formatting takes
-- for its own.
function BU.percent(value) return tostring(math.floor(value + 0.5)) .. "%" end

function BU.sandbox(name, default)
    local page = SandboxVars and SandboxVars.BuildingUtilities
    local value = page and page[name]
    if value == nil then return default end
    return value
end

-- Whether generators power things outside: the game's own AllowExteriorGenerator (on by default; a value this world
-- lacks counts as on). The API leaves it to the mod for a device it adds on its own, so a box gives no power to the
-- devices it connected outside while the option is off, and connects no more.
function BU.exteriorPower() return not (SandboxVars and SandboxVars.AllowExteriorGenerator == false) end

-- What the sandbox's features page (Sandbox_BuildingUtilitiesFeatures) turns off, each on by default: by name, its
-- option and the features it needs. The unit kinds go by their names (BU.Units.KINDS); the box itself ("panel") is on
-- while either utility is. A feature that is off cannot be made or put down, its menus, tabs and rows are hidden, and
-- what of it stands in the world does nothing, its saved data kept for when it is on again (BU.Changes.applyFeatures).
local FEATURES = {
    power = { option = "EnablePower" },
    water = { option = "EnableWater" },
    solar = { option = "EnableSolar", needs = { "power" } },
    rack = { option = "EnableBatteries", needs = { "power" } },
    controller = { option = "EnableChargeController", needs = { "rack" } },
    pump = { option = "EnablePumps", needs = { "water", "power" } },
    sprinkler = { option = "EnableSprinklers", needs = { "water" } },
    filter = { option = "EnableFilters", needs = { "water" } },
    booster = { option = "EnableBoosters", needs = { "water", "power" } },
}
BU.FEATURES = { "power", "water", "solar", "rack", "controller", "pump", "sprinkler", "filter", "booster" }

-- Whether a feature is on: its option, and those of the features it needs. A name that is no feature's is on.
function BU.enabled(name)
    if name == "panel" then return BU.enabled("power") or BU.enabled("water") end
    local feature = name and FEATURES[name]
    if not feature then return true end
    if BU.sandbox(feature.option, true) ~= true then return false end
    for _, need in ipairs(feature.needs or {}) do
        if not BU.enabled(need) then return false end
    end
    return true
end

-- The utilities that are on, in BU.UTILITIES' order.
function BU.utilities()
    local result = {}
    for _, utility in ipairs(BU.UTILITIES) do
        if BU.enabled(utility) then result[#result + 1] = utility end
    end
    return result
end

-- The features on, as one text ("power,water,solar"): compared to tell when the sandbox changed them.
function BU.featureKey()
    local on = {}
    for _, name in ipairs(BU.FEATURES) do
        if BU.enabled(name) then on[#on + 1] = name end
    end
    return table.concat(on, ",")
end

-- The crafting window lists a recipe of this mod only while what it makes is on: the scripts name this global as each
-- recipe's OnAddToMenu, which the game looks up by its plain name. Each recipe's OnTest (BU.RecipeTest) refuses every
-- input meanwhile, so that one reached another way (an item's Craft menu) cannot be made either.
BU.RECIPE_FEATURES = { MakeBreakerBox = "panel", MakeSolarPanel = "solar", MakeBatteryRack = "rack",
    MakeWaterPump = "pump", MakeSprinkler = "sprinkler", MakeWaterFilter = "filter", MakeBoosterPump = "booster" }
function BuildingUtilitiesRecipeShown(param)
    local name = param and param.recipe and param.recipe:getName()
    local feature = name and BU.RECIPE_FEATURES[name:match("[^%.]+$")]
    return feature == nil or BU.enabled(feature)
end
BU.RecipeTest = {}
for recipe, feature in pairs(BU.RECIPE_FEATURES) do
    BU.RecipeTest[recipe] = function() return BU.enabled(feature) end
end

-- How far a box of a tier reaches, in squares from its building's outline: the sandbox's range at tier 1, and
-- RangePerTier percent of it more for each tier above. Devices outside join within the exterior range of their own
-- box (the API reads at most 32); producers and sub-panels within the producer and sub-panel range of the main box.
local function reach(name, default, tier)
    tier = math.max(1, math.min(BU.TIERS, tier or 1))
    local perTier = math.max(0, BU.sandbox("RangePerTier", 50))
    return math.floor(BU.sandbox(name, default) * (1 + (tier - 1) * perTier / 100))
end
function BU.exteriorRange(tier) return math.max(0, math.min(32, reach("ExteriorRange", 5, tier))) end
function BU.producerRange(tier) return math.max(1, reach("ProducerRange", 20, tier)) end
function BU.subPanelRange(tier) return math.max(1, reach("SubPanelRange", 50, tier)) end

-- How many floors above and below its own a box's zone takes, the sandbox's at tier 1 and more by RangePerTier as
-- the ranges; nil without a limit (FloorReach 0). A tall building takes more boxes, sub-panels of one.
function BU.floorReach(tier)
    if BU.sandbox("FloorReach", 2) <= 0 then return nil end
    return math.max(1, reach("FloorReach", 2, tier))
end

-- Tiles of line a floor up or down adds to a line's length (the ranges are measured on the ground).
function BU.tilesPerFloor() return math.max(0, BU.sandbox("TilesPerFloor", 3)) end

-- Connections cost wire or pipe by length; taken away, they give back a share.
function BU.costsEnabled() return BU.sandbox("CostsEnabled", true) == true end
function BU.tilesPerPiece() return math.max(1, BU.sandbox("TilesPerPiece", 5)) end
function BU.refundPercent() return math.max(0, math.min(100, BU.sandbox("RefundPercent", 50))) end

-- A box carries so much power for its tier; past it, its breaker trips.
local CAPACITY_DEFAULTS = { 0.3, 0.6, 1.0, 1.5 }
function BU.overloadEnabled() return BU.sandbox("OverloadEnabled", true) == true end
function BU.capacity(tier)
    tier = math.max(1, math.min(BU.TIERS, tier or 1))
    return BU.sandbox("Capacity" .. tier, CAPACITY_DEFAULTS[tier])
end
function BU.lowFuelHours() return math.max(0, BU.sandbox("LowFuelHours", 6)) end

-- The power line into a box loses so much of the load per piece of wire it took (Costs.pieces), in percent: the
-- sandbox's at tier 1, two thirds of it at tier 2, one third at tier 3, none at tier 4.
function BU.lossPerPiece(tier)
    tier = math.max(1, math.min(BU.TIERS, tier or 1))
    return math.max(0, BU.sandbox("LossPerWire", 1)) * (BU.TIERS - tier) / (BU.TIERS - 1)
end

-- What a box can do from a tier: put devices on timers, give supply to sub-panels, and shed its devices that are
-- not essential, the largest first, before its breaker trips.
BU.TIMER_TIER = 2
BU.LINK_TIER = 2
-- Battery racks join from tier 2 (the bank: BU.Energy); from tier 3 a charge controller runs it.
BU.BANK_TIER = 2
BU.CONTROLLER_TIER = 3
BU.SMART_TIER = 4

-- Electricity experience for wiring: so much times the sandbox's multiplier (0: none).
function BU.xpMultiplier() return math.max(0, BU.sandbox("ExperienceMultiplier", 1)) end
function BU.giveXp(character, amount)
    local multiplier = BU.xpMultiplier()
    if multiplier > 0 and amount > 0 then addXp(character, Perks.Electricity, amount * multiplier) end
end

-- When a device on a timer is connected: "always" (no timer), "night" (from dusk to dawn) or "day". Dusk and dawn
-- move with the season, as the game's own.
BU.SCHEDULES = { "always", "night", "day" }
function BU.scheduleOn(schedule)
    if schedule ~= "night" and schedule ~= "day" then return true end
    local season = getClimateManager():getSeason()
    local hour = getGameTime():getTimeOfDay()
    local night = hour >= season:getDusk() or hour < season:getDawn()
    return (schedule == "night") == night
end

-- The breaker box: this mod's console, one sprite per facing (S, E, N, W), put down with its lamps dark; its other
-- looks are BU.PanelLook's. Boxes of older saves stood as a vanilla terminal, and take the console as they load.
BU.PANEL_SPRITES = { "bu_water_01_32", "bu_water_01_33", "bu_water_01_34", "bu_water_01_35" }
BU.OLD_PANEL_SPRITES = { "security_01_0", "security_01_1", "security_01_2", "security_01_3" }
BU.OLD_PANEL_SPRITE_SET = {}
for _, name in ipairs(BU.OLD_PANEL_SPRITES) do BU.OLD_PANEL_SPRITE_SET[name] = true end
BU.PANEL_ITEM = "BuildingUtilities.BreakerBox"

-- A water producer: an object the game fills with rain or water (rain barrels, metal drums), with a fluid container.
function BU.isWaterContainer(object)
    if not object or instanceof(object, "IsoGenerator") then return false end
    local properties = object:getProperties()
    if not properties or not properties:has("IsWaterCollector") then return false end
    local container = object:getFluidContainer()
    return container ~= nil and container:getCapacity() > 0
end

-- The name an object is known by, as the API's networks know it (buildings.name): its sprite's, or the one a mod
-- gives that sprite, so a machine that changes its look (lit, running) stays the device it was. The sprite's own
-- without the API.
function BU.objectName(object)
    local api = PZExtAPI
    local name = type(api) == "table" and api.buildings and api.buildings.name
    if name then return name(object) end
    return object:getSpriteName() or (object:getSprite() and object:getSprite():getName())
end

-- The objects on a square with a sprite name, as a device entry names them.
function BU.objectsWithSprite(x, y, z, sprite)
    local result = {}
    local square = getCell():getGridSquare(x, y, z)
    if not square then return result end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if BU.objectName(object) == sprite then result[#result + 1] = object end
    end
    return result
end

-- An object and, for one that covers several squares (a double fridge), its other parts.
function BU.objectParts(object)
    if not object:hasSpriteGrid() then return { object } end
    local list = object:getSpriteGridObjectsIncludingSelf(ArrayList.new())
    if list:size() == 0 then return { object } end
    local result = {}
    for i = 0, list:size() - 1 do result[#result + 1] = list:get(i) end
    return result
end

-- The keys of an object's parts, sorted; one key for an object on one square.
function BU.partKeys(object)
    local keys = {}
    for _, part in ipairs(BU.objectParts(object)) do
        local square = part:getSquare()
        local sprite = BU.objectName(part)
        if square and sprite then keys[#keys + 1] = BU.thingKey(square:getX(), square:getY(), square:getZ(), sprite) end
    end
    table.sort(keys)
    return keys
end

-- What players call an object: its moveable name, or its sprite name when the square is not loaded. A moveable
-- name the game has no translation for ("Light Switch") may have one here.
local function translated(name)
    return getTextOrNull("IGUI_BU_Name_" .. name:gsub("%W", "")) or name
end

-- Without a moveable name: a name for its tileset ("location_shop_gas2go_01_15" by IGUI_BU_Name_locationshopgas2go01),
-- else its object name unless that is only its Java class ("IsoObject"), else "a device".
function BU.displayName(x, y, z, sprite)
    local object = BU.objectsWithSprite(x, y, z, sprite)[1]
    if object then
        local name = Translator.getMoveableDisplayName(object)
        if name and name ~= "" then return translated(name) end
    end
    local tileset = sprite:match("^(.+)_%d+$")
    local named = tileset and getTextOrNull("IGUI_BU_Name_" .. tileset:gsub("%W", ""))
    if named then return named end
    local objectName = object and object:getObjectName()
    if objectName and objectName ~= "" and not objectName:match("^Iso%u") then return translated(objectName) end
    return object and getText("IGUI_BU_Name_Unknown") or sprite
end

-- A notice's text (BU.Sync.notice, the box's log): its key with its arguments, at most four, each as text.
function BU.noticeText(key, args)
    args = args or {}
    local parts = {}
    for index = 1, 4 do parts[index] = args[index] ~= nil and tostring(args[index]) or "" end
    return getText(key, parts[1], parts[2], parts[3], parts[4])
end

-- A floor in a few letters, for the plan's floor strip: "B1", "1", "2".
function BU.floorShort(level)
    if level < 0 then return "B" .. tostring(-level) end
    return tostring(level + 1)
end

-- A level of a building as players count floors: 1F for the ground, B1 below it.
function BU.floorName(level)
    if level < 0 then return getText("IGUI_BU_Basement", -level) end
    return getText("IGUI_BU_Floor", level + 1)
end

-- A room name of the map ("kitchen", "gasstore") as words.
function BU.roomName(name)
    local text = getTextOrNull("IGUI_BU_Room_" .. name)
    if text then return text end
    return (name:gsub("^%l", string.upper))
end

return BU
