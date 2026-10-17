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

-- The game keeps one function for a sprite at a priority (MapObjects.OnLoadWithSprite): one given at the same priority
-- replaces it. Every function of this mod for a sprite's square loading goes through one, each called in turn, one
-- failing not keeping the others from running.
local onLoads = {}
function BU.onLoadSprite(sprite, fn)
    local list = onLoads[sprite]
    if not list then
        list = {}
        onLoads[sprite] = list
        MapObjects.OnLoadWithSprite(sprite, function(object)
            for _, each in ipairs(list) do
                local ok, err = pcall(each, object)
                if not ok then BU.log("a square loading:", err) end
            end
        end, 5)
    end
    list[#list + 1] = fn
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

-- The API's version of the buildings (buildings.version, a call into Java), read at most once a tick: what is kept of
-- the buildings goes with it, and a change within a tick is seen at the next. Returns the version and the API, or nil.
local ticks, versionTick, versionRoot, versionApi, versionKept = 0, -1, nil, nil, nil
Events.OnTick.Add(function() ticks = ticks + 1 end)

function BU.buildingsVersion()
    if versionTick == ticks and versionRoot == PZExtAPI then return versionKept, versionApi end
    local api = BU.api()
    versionTick, versionRoot, versionApi = ticks, PZExtAPI, api
    versionKept = api and api.buildings.version() or nil
    return versionKept, api
end

-- This mod's handle: every network change goes through it.
function BU.handle()
    local api = BU.api()
    return api and api.client(BU.MOD) or nil
end

-- Tells the API that this mod outlines devices with the game's own outline (the box window's lists): the game leaves out
-- the objects it draws as models (3D furniture, doors) and vehicles until some mod declares the formulas point
-- outline.models. Once a game, where the game draws; returns true when the API took it. An API without the point is
-- said once in the log; without the API there is nothing to declare.
local outlinesDeclared, outlinesFailed = false, false
function BU.declareOutlines()
    if outlinesDeclared then return true end
    local api, handle = BU.api(), BU.handle()
    if not (api and handle and type(api.formulas) == "table" and type(api.formulas.set) == "function") then return false end
    local ok, err = pcall(api.formulas.set, handle, "outline.models", true)
    if ok then
        outlinesDeclared = true
    elseif not outlinesFailed then
        outlinesFailed = true
        BU.log("outlines of models not declared:", tostring(err))
    end
    return ok
end

-- Water and its purification need hooks of the API in the game, by the names PZExtAPI.hooks() gives them: a
-- game started by an older install, or whose IsoObject another mod changed, may lack them. Water needs the plumbing's
-- questions; water that keeps its taint (only a filter purifies) also the purification's two.
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

-- Whether water can keep its taint (only a filter purifies): true, or false and why. Without it the pipes purify.
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

-- The air a saved thing sits in (a box, a unit: a table with x, y, z), in degrees. Its square's while loaded (a heated
-- building is warmer, a basement milder), kept as the difference from the air outside (record.warmth, to a tenth);
-- while not loaded, the air outside now with the difference last seen: a far basement's rack does not take a winter
-- night's cold, a far heated building's pipes do not freeze, while the weather still moves it.
function BU.airAt(record)
    local climate = getClimateManager()
    local outside = climate:getTemperature()
    local square = getCell():getGridSquare(record.x, record.y, record.z)
    if not square then return outside + (record.warmth or 0) end
    local air = climate:getAirTemperatureForSquare(square)
    local warmth = math.floor((air - outside) * 10 + 0.5) / 10
    record.warmth = warmth ~= 0 and warmth or nil
    return air
end

-- "x,y,z": how a square is named in the saved lists (a room of a zone, by one of its squares).
function BU.placeKey(x, y, z) return x .. "," .. y .. "," .. z end

function BU.parsePlace(key)
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z)
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
    pump = { option = "EnablePumps", needs = { "water", "power" } },
    sprinkler = { option = "EnableSprinklers", needs = { "water" } },
    firesprinkler = { option = "EnableFireSprinklers", needs = { "water" } },
    filter = { option = "EnableFilters", needs = { "water" } },
    booster = { option = "EnableBoosters", needs = { "water", "power" } },
    junction = { needs = { "power" } },
    hydrant = { needs = { "water" } },
}
BU.FEATURES = { "power", "water", "solar", "rack", "pump", "sprinkler", "firesprinkler", "filter", "booster", "junction",
    "hydrant" }

-- Whether a feature is on: its option, and those of the features it needs. A name that is no feature's is on.
function BU.enabled(name)
    if name == "panel" then return BU.enabled("power") or BU.enabled("water") end
    local feature = name and FEATURES[name]
    if not feature then return true end
    if feature.option and BU.sandbox(feature.option, true) ~= true then return false end
    for _, need in ipairs(feature.needs or {}) do
        if not BU.enabled(need) then return false end
    end
    return true
end

-- The ways a feature is on, as BU.enabled tells it: a list of alternatives, each the options (their names on the
-- features page) that are all on in it. The box ("panel") is on with either utility; any other feature with its own
-- option and those of the features it needs. A name that is no feature's is always on: one alternative of none.
function BU.featureOptions(name)
    if name == "panel" then return { BU.featureOptions("power")[1], BU.featureOptions("water")[1] } end
    local feature = FEATURES[name]
    local options, seen = {}, {}
    local function add(each)
        if each and each.option and not seen[each.option] then seen[each.option] = true; options[#options + 1] = each.option end
        for _, need in ipairs(each and each.needs or {}) do add(FEATURES[need]) end
    end
    add(feature)
    return { options }
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
    MakeWaterPump = "pump", MakeSprinkler = "sprinkler", MakeWaterFilter = "filter", MakeBoosterPump = "booster",
    MakeJunctionBox = "junction", MakeYardHydrant = "hydrant", MakeFireSprinkler = "firesprinkler" }
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
-- RangePerTier percent of it more for each tier above. One range for everything (the API reads at most 32): devices
-- outside, producers and units join within it of a box.
local function reach(name, default, tier)
    tier = math.max(1, math.min(BU.TIERS, tier or 1))
    local perTier = math.max(0, BU.sandbox("RangePerTier", 50))
    return math.floor(BU.sandbox(name, default) * (1 + (tier - 1) * perTier / 100))
end
function BU.connectRange(tier) return math.max(1, math.min(32, reach("ConnectRange", 5, tier))) end

-- How many floors above and below its own a box's zone takes, the sandbox's at tier 1 and more by RangePerTier as
-- the ranges; nil without a limit (FloorReach 0). A tall building takes more boxes.
function BU.floorReach(tier)
    if BU.sandbox("FloorReach", 2) <= 0 then return nil end
    return math.max(1, reach("FloorReach", 2, tier))
end

-- Tiles of line a floor up or down adds to a line's length (the ranges are measured on the ground).
function BU.tilesPerFloor() return math.max(0, BU.sandbox("TilesPerFloor", 3)) end

-- Lines reach out from a box's zone (BU.Links): the first from a wall as far as the box's tier reaches
-- (BU.connectRange), one from a relay RelayRange, one from a device on the line to the next ChainRange (as far as a
-- sprinkler is from the next that waters every square between). A box has relays by its tier, and a device on a
-- line (its head, hung on a wall or a relay) has at most CHAIN_LIMIT more hung on it and on them. A relay in a
-- building lets its box's zone take rooms RELAY_FLOORS above and below it.
local RELAY_LIMITS = { 0, 2, 4, 8 }
function BU.relayLimit(tier) return RELAY_LIMITS[math.max(1, math.min(BU.TIERS, tier or 1))] end
function BU.relayRange() return math.max(1, math.min(32, BU.sandbox("RelayRange", 12))) end
function BU.chainRange() return math.max(1, math.min(32, BU.sandbox("ChainRange", 6))) end
BU.CHAIN_LIMIT = 8
BU.RELAY_FLOORS = 2
-- The relays' unit kinds (BU.Units), each with the utility its line carries.
BU.RELAY_KINDS = { junction = "power", hydrant = "water" }

-- Connections cost wire or pipe by length; taken away, they give back a share.
function BU.costsEnabled() return BU.sandbox("CostsEnabled", true) == true end
function BU.tilesPerPiece() return math.max(1, BU.sandbox("TilesPerPiece", 5)) end
function BU.refundPercent() return math.max(0, math.min(100, BU.sandbox("RefundPercent", 50))) end

-- A box carries so much power for its tier; past it, its breaker trips.
local CAPACITY_DEFAULTS = { 0.5, 1.0, 2.0, 4.0 }
function BU.overloadEnabled() return BU.sandbox("OverloadEnabled", true) == true end
function BU.capacity(tier)
    tier = math.max(1, math.min(BU.TIERS, tier or 1))
    return BU.sandbox("Capacity" .. tier, CAPACITY_DEFAULTS[tier])
end
function BU.lowFuelHours() return math.max(0, BU.sandbox("LowFuelHours", 6)) end

-- What a box can do from a tier: cut its devices one by one at the box (below it, everything it reaches is
-- supplied), put them on timers and show its log, show the energy graph on the log.
BU.CUT_TIER = 2
BU.TIMER_TIER = 3
BU.LOG_TIER = 3
BU.GRAPH_TIER = 4

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

-- The breaker box: this mod's tiles (the bu_water_01 sheet, tools/tile_art.py), a look for each tier, indoors and
-- outdoors (on a pedestal), each 16 sprites from its first: off, on, tripped and tripped with its lamp dark, each
-- facing S, E, N, W. It is put down with its lamps dark; its other looks are BU.PanelLook's. An item for each tier, so
-- that its icon and the tile it puts down are the tier's; a new box (made or found) is of tier 1.
BU.PANEL_FIRST = { indoor = { 72, 88, 104, 32 }, outdoor = { 120, 136, 152, 168 } }
BU.PANEL_ITEMS = { "BuildingUtilities.BreakerBox", "BuildingUtilities.BreakerBox2", "BuildingUtilities.BreakerBox3",
    "BuildingUtilities.BreakerBox4" }
BU.PANEL_ITEM = BU.PANEL_ITEMS[1]
-- The mod data mark on the owner of a container the game spawned a box into (Loot.foundBox), which the loot window looks for
-- (Finds).
BU.BOX_MARK = "buBox"
BU.PANEL_ITEM_TIER = {}
for tier, fullType in ipairs(BU.PANEL_ITEMS) do BU.PANEL_ITEM_TIER[fullType] = tier end

-- The sides of a square, in the order the game's building cursor turns through them (its nSprite, 1 to 4).
BU.SIDES = { "W", "N", "E", "S" }

-- The side of a square a character stands on: S, E, N or W (a thing put down there faces them by it).
function BU.sideOf(square, character)
    local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
    if math.abs(dx) > math.abs(dy) then return dx > 0 and "E" or "W" end
    return dy > 0 and "S" or "N"
end

-- The box's sprite of a tier (1 without), indoors or out, its lamps dark, facing a side.
local PANEL_SPRITE_OF = { S = 1, E = 2, N = 3, W = 4 }
function BU.panelSprite(side, tier, outdoor)
    local first = BU.PANEL_FIRST[outdoor and "outdoor" or "indoor"][tier or 1]
    return "bu_water_01_" .. (first + (PANEL_SPRITE_OF[side] or 1) - 1)
end

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
    -- A generator by its item's name: the game's moveable names for them are not translated.
    if object and instanceof(object, "IsoGenerator") then
        local itemName = getItemNameFromFullType(object:getGeneratorItemType())
        if itemName and itemName ~= "" then return itemName end
    end
    if object then
        local name = Translator.getMoveableDisplayName(object)
        if name and name ~= "" then return translated(name) end
    end
    local tileset = sprite and sprite:match("^(.+)_%d+$")
    local named = tileset and getTextOrNull("IGUI_BU_Name_" .. tileset:gsub("%W", ""))
    if named then return named end
    local objectName = object and object:getObjectName()
    if objectName and objectName ~= "" and not objectName:match("^Iso%u") then return translated(objectName) end
    return (object or not sprite) and getText("IGUI_BU_Name_Unknown") or sprite
end

-- A text cut to at most so many letters: a name a player typed, kept short. (The game's Lua keeps a string as Java's
-- characters: a Hangul letter is one place of it, so a cut never splits one.)
function BU.cutText(text, most)
    if #text <= most then return text end
    return text:sub(1, most)
end

-- A notice's text (BU.Sync.notice, the box's log): its key with its arguments, at most four, each as text.
-- How the notices read in the log: the keys of those that went well, and of those that did not; the rest are
-- neither.
BU.NOTICE_GOOD = { IGUI_BU_Log_Reset = true, IGUI_BU_Log_Upgraded = true, IGUI_BU_Notice_Thawed = true,
    IGUI_BU_Notice_SwitchedOn = true, IGUI_BU_Notice_Switched = true, IGUI_BU_Notice_SolarOn = true }
BU.NOTICE_BAD = { IGUI_BU_Notice_Tripped = true, IGUI_BU_Notice_PowerLost = true, IGUI_BU_Notice_WaterEmpty = true,
    IGUI_BU_Notice_WaterEmptyPipe = true, IGUI_BU_Notice_LowFuel = true, IGUI_BU_Notice_Frozen = true,
    IGUI_BU_Notice_FilterSpent = true, IGUI_BU_Notice_BankLow = true, IGUI_BU_Notice_BankEmpty = true }

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
