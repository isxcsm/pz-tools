-- The modification kits and the improved gear on the game side (REWARDS, NUMBERS 7). The rules are pure numbers
-- (Gear/Rules.lua); this reads and writes the game's objects and is what the timed actions and the server commands
-- call. Where a kit's effect lives:
--
--   bag capacity / weight kit  the bag item's modData (count, original capacity and reduction); the bag's own capacity
--                              (InventoryContainer.setCapacity) and weight reduction (setWeightReduction), which the
--                              game saves with the item.
--   trunk kit                  the modData of each trunk part (TruckBed, TruckBedOpen), saved with the vehicle.
--   engine kit                 the modData of the engine part (count and the original power and loudness) and the
--                              engine's own features (BaseVehicle.setEngineFeature), which the game saves with the
--                              vehicle.
--
-- Past the game's own capacity limits a container needs the extension API (PZ Tools): it adds the number in the
-- holder's modData OA_Capacity to the raw capacity and lifts the limits (docs/design/extension-api.md,
-- capacity.modDataKey). Without it the kits are written into the raw capacity and the game cuts them at its limits;
-- the tooltip says so. The count of kits stays either way, and the value is worked out again from it (refresh*), so a
-- game started later with the API gets the full value.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Gear/Rules"
local OA = OperationAcorn
local Gear = OA.Gear
local Rules = Gear.Rules
local K = Rules.KEY

Gear.VOUCHER = "OperationAcorn.KitVoucher"
-- The names of a vehicle's parts that the kits change.
Gear.TRUNK_PARTS = { "TruckBed", "TruckBedOpen" }
Gear.ENGINE_PART = "Engine"
-- How near (squares) a character must be to a vehicle to fit a kit.
Gear.REACH = 6
-- The names of the extension API's point and of the key it reads, as the upgrades part declares them.
Gear.POINT = "capacity.modDataKey"

local function pointName()
    local effects = OA.Upgrades and OA.Upgrades.Effects
    return effects and effects.POINTS and effects.POINTS.capacityKey or Gear.POINT
end

local function keyName()
    local effects = OA.Upgrades and OA.Upgrades.Effects
    return effects and effects.CAPACITY_KEY or K.CAPACITY
end

-- ---- the extension API ----------------------------------------------------------------------------------------

local declared = false
local liftsAt, liftsValue = nil, false

-- Whether the extension API applies the capacity key, so that a holder with OA_Capacity is held to none of the
-- game's limits. The upgrades part declares the key when the game starts; if it has not yet, this declares the same
-- value itself once (a key declared twice is the same key). Kept for a few game minutes: the question is asked often.
function Gear.lifts(force)
    local now = OA.hours()
    if not force and liftsAt and math.abs(now - liftsAt) < 0.05 then return liftsValue end
    local value = false
    local api = OA.api()
    local formulas = api and api.formulas
    if type(formulas) == "table" and type(formulas.points) == "function" then
        local function applied()
            local ok, status = pcall(formulas.points)
            return ok and type(status) == "table" and status[pointName()] == "applied"
        end
        value = applied()
        if not value and not declared then
            declared = true
            local handle = OA.handle()
            if handle and type(formulas.set) == "function" then
                local ok, err = pcall(formulas.set, handle, pointName(), keyName())
                if not ok then OA.log("gear: declaring the capacity key failed:", tostring(err)) end
            end
            value = applied()
        end
    end
    liftsAt, liftsValue = now, value
    return value
end

-- ---- finding things -------------------------------------------------------------------------------------------

-- An item of a character's inventory by id (inside bags too), or nil.
function Gear.findItem(character, id)
    if not id then return nil end
    local inventory = character:getInventory()
    local item = inventory:getItemWithIDRecursiv(id)
    if item then return item end
    return inventory:getItemById(id)
end

-- The vehicle with an id, or nil.
function Gear.findVehicle(id)
    if not id then return nil end
    return getVehicleById(id)
end

-- Whether a character stands near a vehicle.
function Gear.near(character, vehicle)
    local dx, dy = vehicle:getX() - character:getX(), vehicle:getY() - character:getY()
    return dx * dx + dy * dy <= Gear.REACH * Gear.REACH
end

-- An item's modData if it has any (reading it with getModData would make an empty table on every item it looks at).
local function dataOf(item)
    return item:hasModData() and item:getModData() or nil
end

-- What a kit was ordered for: an item type, a script name, or "" for any.
function Gear.targetOf(kit)
    local md = dataOf(kit)
    local target = md and md[K.TARGET]
    return type(target) == "string" and target or ""
end

-- The kind of a kit item, or nil when the item is not one.
function Gear.kindOfItem(kit)
    return kit and Rules.kindOf(kit:getFullType()) or nil
end

-- The key a vehicle's kits are counted under (the shop's: the script name).
function Gear.vehicleKey(vehicle)
    local script = vehicle:getScript()
    return script and script:getName() or ""
end

-- The name of a vehicle as the mechanics window shows it.
function Gear.vehicleName(vehicle)
    local key = Gear.vehicleKey(vehicle)
    local script = vehicle:getScript()
    local model = script and script.getCarModelName and script:getCarModelName() or key
    local text = getTextOrNull and (getTextOrNull("IGUI_VehicleName" .. tostring(model))
        or getTextOrNull("IGUI_VehicleName" .. key))
    return text or key
end

-- The name a kit's target is shown under (a bag's item name, a vehicle's name, or "any").
function Gear.targetName(kind, target)
    if target == nil or target == "" then return getText("IGUI_OA_Gear_AnyTarget") end
    if Rules.SCOPE[kind] == "bag" then
        return getItemNameFromFullType and getItemNameFromFullType(target) or target
    end
    return getTextOrNull and getTextOrNull("IGUI_VehicleName" .. target) or target
end

-- ---- removing and giving items --------------------------------------------------------------------------------

local function removeItem(item)
    local container = item:getContainer()
    if not container then return false end
    container:DoRemoveItem(item)
    if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, item) end
    return true
end

local function giveItem(character, item)
    local inventory = character:getInventory()
    inventory:AddItem(item)
    if sendAddItemToContainer then sendAddItemToContainer(inventory, item) end
end

local function syncItem(item)
    if item.syncItemFields then pcall(item.syncItemFields, item) end
end

local function notice(character, key, args)
    OA.Sync.notice(OA.Store.idOf(character), key, args)
end

-- ---- bags -----------------------------------------------------------------------------------------------------

-- The kits fitted to a bag: capacity kits, weight kits.
function Gear.bagKits(bag)
    local md = dataOf(bag)
    if not md then return 0, 0 end
    return md[K.BAG_CAP] or 0, md[K.BAG_WEIGHT] or 0
end

-- What a bag's kits make of it, worked out from the counts and its original values: { capacity (kits), weight (kits),
-- total (the capacity), limit (what the game holds the bag to), cut (the game would cut it), reduction (percent) }; nil
-- when the bag has no kit.
function Gear.bagInfo(bag)
    local n, w = Gear.bagKits(bag)
    if n == 0 and w == 0 then return nil end
    local md = bag:getModData()
    local info = { capacity = n, weight = w }
    local baseCap = md[K.BAG_BASE_CAP]
    if baseCap then
        info.total = Rules.capacity(baseCap, n)
        info.limit = Rules.bagLimit(bag:getActualWeight())
        info.cut = Rules.cut(info.total, info.limit, Gear.lifts())
    end
    local baseRed = md[K.BAG_BASE_RED]
    if baseRed then info.reduction = Rules.reductionInt(baseRed, w) end
    return info
end

-- Writes a bag's kits into the bag: the capacity (with the API the original stays and OA_Capacity adds the kits;
-- without it the kits go into the capacity, cut at the game's limit) and the weight reduction. Only what differs is
-- written. Safe to call again at any time.
function Gear.refreshBag(bag)
    local md = bag:getModData()
    local n, w = Gear.bagKits(bag)
    local baseCap, baseRed = md[K.BAG_BASE_CAP], md[K.BAG_BASE_RED]
    if baseCap and n > 0 then
        local total = Rules.capacity(baseCap, n)
        local lifted = Gear.lifts()
        local raw = Rules.raw(baseCap, total, Rules.bagLimit(bag:getActualWeight()), lifted)
        if md[K.RAW] ~= raw then
            bag:setCapacity(raw)
            md[K.RAW] = raw
        end
        local extra = lifted and (total - baseCap) or nil
        if md[K.CAPACITY] ~= extra then md[K.CAPACITY] = extra end
    end
    if baseRed and w > 0 then
        local reduction = Rules.reductionInt(baseRed, w)
        if bag:getWeightReduction() ~= reduction then bag:setWeightReduction(reduction) end
    end
end

-- Fits a bag kit to a bag: counts it, writes it into the bag, uses the kit up. Returns true and the bag's new value
-- (the capacity, or the weight reduction), or false and the reason: "kit" (not a bag kit), "bag" (not a bag),
-- "target" (the kit was ordered for another bag).
function Gear.fitBag(character, kit, bag)
    local kind = Gear.kindOfItem(kit)
    if Rules.SCOPE[kind] ~= "bag" then return false, "kit" end
    if not bag or not bag.IsInventoryContainer or not bag:IsInventoryContainer() or bag == kit then return false, "bag" end
    if not Rules.matches(Gear.targetOf(kit), bag:getFullType()) then return false, "target" end
    local md = bag:getModData()
    if md[K.BAG_BASE_CAP] == nil then
        md[K.BAG_BASE_CAP] = bag:getItemContainer():getCapacity()
        md[K.BAG_BASE_RED] = bag:getWeightReduction()
    end
    if kind == "bagCapacity" then
        md[K.BAG_CAP] = (md[K.BAG_CAP] or 0) + 1
    else
        md[K.BAG_WEIGHT] = (md[K.BAG_WEIGHT] or 0) + 1
    end
    Gear.refreshBag(bag)
    removeItem(kit)
    syncItem(bag)
    local value
    if kind == "bagCapacity" then
        value = Rules.capacity(md[K.BAG_BASE_CAP], md[K.BAG_CAP])
    else
        value = tostring(Rules.reductionInt(md[K.BAG_BASE_RED], md[K.BAG_WEIGHT])) .. "%"
    end
    notice(character, "IGUI_OA_Gear_Fitted_" .. kind, { bag:getDisplayName(), tostring(value) })
    return true, value
end

-- Every bag a character has (in any container) that carries a kit: written again from its counts (a save loaded with
-- the API, or without it, after the bag was fitted in the other way). Called when the game starts.
function Gear.refreshAll(character)
    local list = character:getInventory():getAllEvalRecurse(function(item)
        if not item:IsInventoryContainer() then return false end
        local md = dataOf(item)
        return md ~= nil and (md[K.BAG_CAP] or md[K.BAG_WEIGHT]) ~= nil
    end)
    for i = 0, list:size() - 1 do Gear.refreshBag(list:get(i)) end
    return list:size()
end

-- ---- trunks ---------------------------------------------------------------------------------------------------

-- The trunk parts of a vehicle (the ones it has).
function Gear.trunkParts(vehicle)
    local found = {}
    for _, id in ipairs(Gear.TRUNK_PARTS) do
        local part = vehicle:getPartById(id)
        if part and part:isContainer() then found[#found + 1] = part end
    end
    return found
end

-- The trunk kits fitted to a vehicle.
function Gear.trunkKits(vehicle)
    local best = 0
    for _, part in ipairs(Gear.trunkParts(vehicle)) do
        best = math.max(best, part:getModData()[K.TRUNK] or 0)
    end
    return best
end

-- A trunk's capacity before any kit: the capacity of the part's installed trunk item, or the container's own.
local function nominalTrunk(part)
    local item = part:getInventoryItem()
    local capacity = item and item.getMaxCapacity and item:getMaxCapacity() or 0
    if capacity <= 0 then capacity = part:getContainerCapacity() end
    return capacity
end

-- What a vehicle's trunk is worth with its kits: { kits, total, limit, cut }; nil when it has none.
function Gear.trunkInfo(vehicle)
    local kits = Gear.trunkKits(vehicle)
    if kits == 0 then return nil end
    local info = { kits = kits, limit = Rules.VEHICLE_LIMIT }
    for _, part in ipairs(Gear.trunkParts(vehicle)) do
        local base = part:getModData()[K.TRUNK_BASE]
        if base then
            info.total = math.max(info.total or 0, Rules.capacity(base, part:getModData()[K.TRUNK] or 0))
        end
    end
    info.cut = info.total ~= nil and Rules.cut(info.total, info.limit, Gear.lifts())
    return info
end

-- Writes a trunk part's kits into the part (see refreshBag).
function Gear.refreshTrunk(vehicle, part)
    local md = part:getModData()
    local n, base = md[K.TRUNK] or 0, md[K.TRUNK_BASE]
    if not base or n == 0 then return end
    local total = Rules.capacity(base, n)
    local lifted = Gear.lifts()
    local changed = false
    if lifted then
        -- the API adds the kits: take back what an earlier game without it wrote into the capacity
        if md[K.RAW] ~= nil then
            part:setContainerCapacity(base)
            md[K.RAW] = nil
            changed = true
        end
        if md[K.CAPACITY] ~= total - base then
            md[K.CAPACITY] = total - base
            changed = true
        end
    else
        local raw = Rules.raw(base, total, Rules.VEHICLE_LIMIT, false)
        if md[K.RAW] ~= raw then
            part:setContainerCapacity(raw)
            md[K.RAW] = raw
            changed = true
        end
        if md[K.CAPACITY] ~= nil then
            md[K.CAPACITY] = nil
            changed = true
        end
    end
    if changed and vehicle.transmitPartModData then vehicle:transmitPartModData(part) end
end

-- Fits a trunk kit to a vehicle. Returns true and the new capacity, or false and the reason: "kit", "gone",
-- "far", "target" (ordered for another vehicle), "part" (no trunk).
function Gear.fitTrunk(character, kit, vehicle)
    if Gear.kindOfItem(kit) ~= "trunk" then return false, "kit" end
    if not vehicle then return false, "gone" end
    if not Gear.near(character, vehicle) then return false, "far" end
    if not Rules.matches(Gear.targetOf(kit), Gear.vehicleKey(vehicle)) then return false, "target" end
    local parts = Gear.trunkParts(vehicle)
    if #parts == 0 then return false, "part" end
    local total = 0
    for _, part in ipairs(parts) do
        local md = part:getModData()
        if md[K.TRUNK_BASE] == nil then md[K.TRUNK_BASE] = nominalTrunk(part) end
        md[K.TRUNK] = (md[K.TRUNK] or 0) + 1
        Gear.refreshTrunk(vehicle, part)
        total = math.max(total, Rules.capacity(md[K.TRUNK_BASE], md[K.TRUNK]))
    end
    removeItem(kit)
    notice(character, "IGUI_OA_Gear_Fitted_trunk", { Gear.vehicleName(vehicle), tostring(total) })
    return true, total
end

-- ---- engines --------------------------------------------------------------------------------------------------

-- The engine kits fitted to a vehicle.
function Gear.engineKits(vehicle)
    local part = vehicle:getPartById(Gear.ENGINE_PART)
    return part and part:getModData()[K.ENGINE] or 0
end

-- What an engine is worth with its kits: { kits, power, loudness } (the game's numbers: power in tenths of a
-- horsepower as the mechanics window divides by ten, loudness as stored); nil when it has none.
function Gear.engineInfo(vehicle)
    local part = vehicle:getPartById(Gear.ENGINE_PART)
    if not part then return nil end
    local md = part:getModData()
    local n = md[K.ENGINE] or 0
    if n == 0 or not md[K.ENGINE_POWER] then return nil end
    return {
        kits = n,
        power = Rules.engine(md[K.ENGINE_POWER], n, Rules.POWER_STEP),
        loudness = Rules.engine(md[K.ENGINE_LOUD], n, Rules.LOUDNESS_STEP),
    }
end

-- Writes an engine's kits into the vehicle's engine features, when they differ (the game saves them with the
-- vehicle; a repair of the engine part by a debug tool puts the script's values back).
function Gear.refreshEngine(vehicle)
    local info = Gear.engineInfo(vehicle)
    if not info then return false end
    if vehicle:getEnginePower() == info.power and vehicle:getEngineLoudness() == info.loudness then return false end
    vehicle:setEngineFeature(vehicle:getEngineQuality(), Rules.loudnessArgument(info.loudness), info.power)
    if vehicle:getEngineLoudness() ~= info.loudness then
        -- the stored loudness is off by the game's own rounding: set it as it is stored
        local part = vehicle:getPartById(Gear.ENGINE_PART)
        local engine = part and part.getVehicleEngine and part:getVehicleEngine()
        if engine and engine.setLoudness then pcall(engine.setLoudness, engine, info.loudness) end
    end
    if vehicle.transmitEngine then vehicle:transmitEngine() end
    return true
end

-- Fits an engine kit to a vehicle. Returns true and the new power, or false and the reason (see fitTrunk).
function Gear.fitEngine(character, kit, vehicle)
    if Gear.kindOfItem(kit) ~= "engine" then return false, "kit" end
    if not vehicle then return false, "gone" end
    if not Gear.near(character, vehicle) then return false, "far" end
    if not Rules.matches(Gear.targetOf(kit), Gear.vehicleKey(vehicle)) then return false, "target" end
    local part = vehicle:getPartById(Gear.ENGINE_PART)
    if not part then return false, "part" end
    local md = part:getModData()
    if md[K.ENGINE_POWER] == nil then
        md[K.ENGINE_POWER] = vehicle:getEnginePower()
        md[K.ENGINE_LOUD] = vehicle:getEngineLoudness()
    end
    md[K.ENGINE] = (md[K.ENGINE] or 0) + 1
    Gear.refreshEngine(vehicle)
    if vehicle.transmitPartModData then vehicle:transmitPartModData(part) end
    removeItem(kit)
    local info = Gear.engineInfo(vehicle)
    notice(character, "IGUI_OA_Gear_Fitted_engine", { Gear.vehicleName(vehicle), tostring(info.power / 10) })
    return true, info.power
end

-- Fits a vehicle kit by its kind.
function Gear.fitVehicle(character, kit, vehicle)
    local kind = Gear.kindOfItem(kit)
    if kind == "trunk" then return Gear.fitTrunk(character, kit, vehicle) end
    if kind == "engine" then return Gear.fitEngine(character, kit, vehicle) end
    return false, "kit"
end

-- Refreshes everything a vehicle's kits have written: the trunks and the engine.
function Gear.refreshVehicle(vehicle)
    for _, part in ipairs(Gear.trunkParts(vehicle)) do Gear.refreshTrunk(vehicle, part) end
    Gear.refreshEngine(vehicle)
end

-- ---- texts about fitted kits ----------------------------------------------------------------------------------

-- The lines about a bag's fitted kits (for its tooltip), or nil when it has none.
function Gear.bagLines(bag)
    local info = Gear.bagInfo(bag)
    if not info then return nil end
    local lines = {}
    if info.capacity > 0 and info.total then
        lines[#lines + 1] = getText("Tooltip_OA_Gear_BagCapacity", tostring(info.capacity), tostring(info.total))
    end
    if info.weight > 0 and info.reduction then
        lines[#lines + 1] = getText("Tooltip_OA_Gear_BagWeight", tostring(info.weight), tostring(info.reduction) .. "%")
    end
    if info.cut then lines[#lines + 1] = getText("Tooltip_OA_Gear_BagCut", tostring(info.limit)) end
    return lines
end

-- The lines about a vehicle's fitted trunk kits, or nil.
function Gear.trunkLines(vehicle)
    local info = Gear.trunkInfo(vehicle)
    if not info then return nil end
    local lines = { getText("Tooltip_OA_Gear_TrunkKits", tostring(info.kits), tostring(info.total or "?")) }
    if info.cut then lines[#lines + 1] = getText("Tooltip_OA_Gear_TrunkCut", tostring(info.limit)) end
    return lines
end

-- The lines about a vehicle's fitted engine kits, or nil.
function Gear.engineLines(vehicle)
    local info = Gear.engineInfo(vehicle)
    if not info then return nil end
    return { getText("Tooltip_OA_Gear_EngineKits", tostring(info.kits), tostring(info.power / 10),
        tostring(info.loudness)) }
end

-- ---- the voucher ----------------------------------------------------------------------------------------------

-- Redeems a kit voucher: the voucher is used up and the character gets one kit of the kind, for any target. The kit
-- is not bought: the shop does not count it, so the price of the next kit bought for the same target does not rise
-- (NUMBERS 5). Fitting it counts on the bag or the vehicle like any kit. Returns true, or false and the reason.
function Gear.redeem(character, voucher, kind)
    if not voucher or voucher:getFullType() ~= Gear.VOUCHER then return false, "voucher" end
    local fullType = Rules.kitType(kind)
    if not fullType then return false, "kind" end
    local kit = instanceItem(fullType)
    if not kit then return false, "kind" end
    local md = kit:getModData()
    md[K.TARGET] = ""
    md[K.VOUCHER] = true
    removeItem(voucher)
    giveItem(character, kit)
    notice(character, "IGUI_OA_Gear_Redeemed", { kit:getDisplayName() })
    return true
end

-- ---- the improved torches in the vanilla recipes --------------------------------------------------------------

Gear.TORCH = "Base.BlowTorch"
Gear.TORCHES = { "OperationAcorn.TorchMk1", "OperationAcorn.TorchMk2", "OperationAcorn.TorchMk3" }
-- The vanilla recipes that must keep taking the vanilla torch only: refilling replaces the torch with a vanilla one.
Gear.TORCH_SKIP = { RefillBlowTorch = true }

-- Adds the improved torches to every craft input (a recipe's and a buildable's) that lists the vanilla torch: the
-- recipes are keyed on the exact item type Base.BlowTorch, so a torch of another type would not do. The input keeps
-- its list of the items it accepts (InputScript.getPossibleInputItems), which the crafting code asks. Done once when
-- the game starts; returns the number of inputs it changed.
function Gear.extendRecipes()
    local scripts = getScriptManager and getScriptManager()
    if not scripts then return 0 end
    local vanilla = scripts:FindItem(Gear.TORCH)
    if not vanilla then return 0 end
    local torches = {}
    for _, fullType in ipairs(Gear.TORCHES) do
        local script = scripts:FindItem(fullType)
        if script then torches[#torches + 1] = script end
    end
    if #torches == 0 then return 0 end
    local changed = 0
    local seen = {}
    local function extend(recipe)
        if not recipe or seen[recipe] or Gear.TORCH_SKIP[recipe:getName()] then return end
        seen[recipe] = true
        local inputs = recipe:getInputs()
        for i = 0, inputs:size() - 1 do
            local input = inputs:get(i)
            if not input:isAcceptsAnyItem() and input:containsItem(vanilla) then
                local items = input:getPossibleInputItems()
                local added = false
                for _, script in ipairs(torches) do
                    if not input:containsItem(script) then
                        local ok = pcall(items.add, items, script)
                        added = added or ok
                    end
                end
                if added then changed = changed + 1 end
            end
        end
    end
    for _, list in ipairs({ scripts:getAllCraftRecipes(), scripts:getAllBuildableRecipes() }) do
        for i = 0, list:size() - 1 do
            local ok, err = pcall(extend, list:get(i))
            if not ok then OA.log("gear: a recipe was not extended:", tostring(err)) end
        end
    end
    OA.log("gear: improved torches added to", changed, "recipe inputs")
    return changed
end

-- Done when the game starts (a client or a single-player game), and when a dedicated server does. Doing it again is
-- harmless: an input that already lists the torches is left alone.
local function onStart()
    local ok, err = pcall(Gear.extendRecipes)
    if not ok then OA.log("gear: extending the recipes failed:", tostring(err)) end
end
Events.OnGameStart.Add(onStart)
Events.OnServerStarted.Add(onStart)

return Gear
