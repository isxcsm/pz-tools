-- What this mod adds to the world's loot, put into the game's distribution lists as any item is (each list with a
-- weight, OnPreDistributionMerge) and rolled by the game:
--   - finished solar panels, so a player can start on solar before learning glassmaking (the recipe takes glass
--     panels);
--   - water machines where a farm, a garden store or a plumber would have kept one: pumps and sprinklers, fire
--     sprinkler heads, and filters with part of their media spent;
--   - the two volumes of the water systems magazine, which teach the water machines' recipes (a player with the
--     skill learns them without: the recipes' AutoLearnAny);
--   - control boards where electrical parts are kept, and utility panels in technical rooms and generator crates, a
--     way to a first one: its recipe is learned from one (ISBUReverseEngineer). Rooms of the kinds the game rolls
--     generators for also get one standing (Spawned.lua).
-- Each item is of a kind of loot of this mod's (PZExtAPI.loot), so the game multiplies its chance by this mod's option
-- for it (SolarPanelLoot, BreakerBoxLoot, WaterLoot: 0 to 4, 0.6 by default, as the game's loot options are) instead of
-- its "other loot", and rolls it at 0 while its feature is off. How a found item is set is the game's as it spawns it
-- (the item's ItemConfig, scripts/BuildingUtilities.txt): a filter gets part of its media spent (Loot.foundFilter); a
-- box marks its container's owner for the first find (Loot.foundBox).
require "BuildingUtilities/Core"
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Loot = {}
BU.Loot = Loot

-- Each: the kind's id, the option that scales it, the features its items need (any of them on: the magazines teach
-- several), and its items, each by the game's lists (ProceduralDistributions.list) and vehicles' lists
-- (VehicleDistributions) with its weight there. Weight 1 is a 0.6 percent chance a roll at the option's default; the
-- game's lists roll 3 or 4 times. For comparison: electric wire is 10 and 20 in a technical room's list, a generator
-- 0.1 in an electrician's truck bed.
Loot.KINDS = {
    { id = "SolarPanel", option = "SolarPanelLoot", features = { "solar" }, items = {
        ["BuildingUtilities.SolarPanel"] = {
            lists = { ElectronicStoreAppliances = 2, CampingStoreGear = 1, ToolStoreMisc = 0.5, CrateFarming = 0.3 },
            vehicles = { FarmerTruckBed = 0.3 } } } },
    { id = "Panel", option = "BreakerBoxLoot", features = { "panel" }, items = {
        ["BuildingUtilities.BreakerBox"] = {
            lists = { GeneratorRoom = 2, CrateGenerator = 5 },
            vehicles = { ElectricianTruckBed = 0.5 } },
        ["BuildingUtilities.ControlBoard"] = {
            lists = { GeneratorRoom = 4, ElectricianTools = 3, RadioFactoryComponents = 4, WireFactoryElectric = 2, CrateElectronics = 1 },
            vehicles = { ElectricianTruckBed = 2 } } } },
    { id = "WaterPump", option = "WaterLoot", features = { "pump" }, items = {
        ["BuildingUtilities.WaterPump"] = {
            lists = { CrateFarming = 1, BarnTools = 1, ToolCabinetFarming = 0.5, GardenStoreTools = 0.5 },
            vehicles = { FarmerTruckBed = 0.5, PlumberTruckBed = 1 } } } },
    { id = "Sprinkler", option = "WaterLoot", features = { "sprinkler" }, items = {
        ["BuildingUtilities.Sprinkler"] = {
            lists = { GardenStoreTools = 2, CrateGardening = 1.5, CrateFarming = 1, GardenStoreMisc = 1, BarnTools = 0.5 } } } },
    { id = "FireSprinkler", option = "WaterLoot", features = { "firesprinkler" }, items = {
        ["BuildingUtilities.FireSprinkler"] = {
            lists = { FireStorageTools = 0.5, GeneratorRoom = 0.5, CrateMetalwork = 0.3 },
            vehicles = { PlumberTruckBed = 2 } } } },
    { id = "WaterFilter", option = "WaterLoot", features = { "filter" }, items = {
        ["BuildingUtilities.WaterFilter"] = {
            lists = { GardenStoreMisc = 0.5, CampingStoreGear = 0.5, GeneratorRoom = 0.3, CrateFarming = 0.3 },
            vehicles = { PlumberTruckBed = 1.5 } } } },
    { id = "WaterSystemsMag1", option = "WaterLoot", features = { "pump", "sprinkler" }, items = {
        ["BuildingUtilities.WaterSystemsMag1"] = {
            lists = { BookstoreBlueCollar = 1, OutdoorSupplyMagazines = 1, GardenStoreMisc = 0.5, CrateMagazines = 0.3 } } } },
    { id = "WaterSystemsMag2", option = "WaterLoot", features = { "booster", "filter", "firesprinkler" }, items = {
        ["BuildingUtilities.WaterSystemsMag2"] = {
            lists = { BookstoreBlueCollar = 1, ToolStoreBooks = 0.5, CrateMagazines = 0.3 },
            vehicles = { PlumberTruckBed = 1 } } } },
}

-- A filter found used: some of its media left (a share of a charge, at random between these).
Loot.USED_MEDIA = { 0.1, 0.5 }

local PAGE = "BuildingUtilities."

-- The boolean options a kind requires (PZExtAPI.loot's requires) for its items to come while one of its features is
-- on: every way any of them is on (BU.featureOptions) turned into options that must all be on, each one of a list,
-- by picking one option of each way in every combination; a list that holds another is left out. Nil when a way
-- needs nothing.
function Loot.requires(features)
    local ways = {}
    for _, feature in ipairs(features) do
        for _, way in ipairs(BU.featureOptions(feature)) do
            if #way == 0 then return nil end
            ways[#ways + 1] = way
        end
    end
    local groups = {}
    local function pick(index, chosen)
        if index > #ways then
            local group, seen = {}, {}
            for _, option in ipairs(chosen) do
                if not seen[option] then seen[option] = true; group[#group + 1] = option end
            end
            table.sort(group)
            groups[#groups + 1] = group
            return
        end
        for _, option in ipairs(ways[index]) do
            chosen[index] = option
            pick(index + 1, chosen)
        end
    end
    pick(1, {})
    local function holds(big, small)
        local inBig = {}
        for _, option in ipairs(big) do inBig[option] = true end
        for _, option in ipairs(small) do if not inBig[option] then return false end end
        return true
    end
    local result = {}
    for i, group in ipairs(groups) do
        local kept = true
        for j, other in ipairs(groups) do
            -- Another that this one holds says the same with less (of two alike, the first stands).
            if i ~= j and holds(group, other) and (#other < #group or j < i) then kept = false; break end
        end
        if kept then
            local entry = {}
            for _, option in ipairs(group) do entry[#entry + 1] = PAGE .. option end
            result[#result + 1] = #entry == 1 and entry[1] or entry
        end
    end
    return result
end

-- The kinds, defined with the API as this file loads: before the world's first squares roll their loot. Without the
-- API's loot kinds the items roll as the game's other loot, said once in the log.
function Loot.define()
    local api, handle = BU.api(), BU.handle()
    if not (api and handle and type(api.loot) == "table" and type(api.loot.define) == "function") then
        print("[BuildingUtilities] the PZ Extension API has no loot kinds: this mod's items roll as the game's other loot")
        return false
    end
    for _, kind in ipairs(Loot.KINDS) do
        local items = {}
        for item in pairs(kind.items) do items[#items + 1] = item end
        table.sort(items)
        local spec = { option = PAGE .. kind.option, items = items, requires = Loot.requires(kind.features) }
        local ok, err = pcall(api.loot.define, handle, kind.id, spec)
        if not ok then print("[BuildingUtilities] loot kind " .. kind.id .. ": " .. tostring(err)) end
    end
    return true
end

-- Into one of the game's lists, as its items do: a list the game does not have (a version that renamed it) is said in
-- the log and left out.
local function put(list, item, weight, where)
    if type(list) ~= "table" or type(list.items) ~= "table" then
        print("[BuildingUtilities] loot: the game has no list " .. where .. "; " .. item .. " is not put there")
        return
    end
    table.insert(list.items, item)
    table.insert(list.items, weight)
end

function Loot.distribute()
    local lists = ProceduralDistributions and ProceduralDistributions.list or {}
    for _, kind in ipairs(Loot.KINDS) do
        for item, where in pairs(kind.items) do
            for name, weight in pairs(where.lists or {}) do put(lists[name], item, weight, name) end
            for name, weight in pairs(where.vehicles or {}) do
                put(VehicleDistributions and VehicleDistributions[name], item, weight, "VehicleDistributions." .. name)
            end
        end
    end
end

-- As the game spawns a filter into loot (its ItemConfig): part of its media spent.
function Loot.foundFilter(item)
    local share = Loot.USED_MEDIA[1] + ZombRandFloat(0, 1) * (Loot.USED_MEDIA[2] - Loot.USED_MEDIA[1])
    BU.Units.keepOnItem("filter", item, { media = BU.WaterUnits.FILTER_HOURS * share })
end

-- As the game spawns a box into loot (its ItemConfig), in the container it was put into: the container's owner (its
-- object, or the vehicle's part) is marked (BU.BOX_MARK), so that the loot window looks only at those (Finds.lua).
function Loot.foundBox(item)
    local container = item and item:getContainer()
    if not container then return end
    local owner = container:getVehiclePart() or container:getParent()
    if owner then owner:getModData()[BU.BOX_MARK] = true end
end

Loot.define()
Events.OnPreDistributionMerge.Add(Loot.distribute)

return Loot
