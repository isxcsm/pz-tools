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
-- Past the game's own capacity limits a container needs PZ Extension API: it adds the number in the
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

-- ---- the improved fuel cans ------------------------------------------------------------------------------------

-- What the cans weigh carried (the extension API's carrying efficiency, carry.fullTypeEfficiency): each holds more
-- than the plain can (10 L) and, full, weighs no more than it full (11.6: its 1.6 and petrol at 1 a litre), the later
-- ones less. litres: the script's capacity (scripts/OA_gear.txt says the same); full: what a full can weighs carried.
Gear.PLAIN_CAN_FULL = 11.6
Gear.CAN_WEIGHT = 1.6
Gear.FUEL_CANS = {
    FuelCanMk1 = { litres = 15, full = 11.6 },
    FuelCanMk2 = { litres = 20, full = 10.0 },
    FuelCanMk3 = { litres = 25, full = 8.5 },
}

-- The efficiency that makes a full can weigh its `full` (the game divides an item's weight, fluid included, by 1 plus it).
function Gear.canEfficiency(name)
    local can = Gear.FUEL_CANS[name]
    return (Gear.CAN_WEIGHT + can.litres) / can.full - 1
end

-- Declares the cans' efficiencies to the API, once a game. Returns true when it took them.
function Gear.declareCans()
    local api = OA.api()
    local handle = OA.handle()
    if not (api and handle and type(api.formulas) == "table" and type(api.formulas.set) == "function") then return false end
    local efficiencies = {}
    for name in pairs(Gear.FUEL_CANS) do efficiencies[OA.MOD .. "." .. name] = Gear.canEfficiency(name) end
    local ok, err = pcall(api.formulas.set, handle, "carry.fullTypeEfficiency", efficiencies)
    if not ok then OA.log("gear: the fuel cans' weight not declared:", tostring(err)) end
    return ok
end

-- What a can weighs as carried now (its fluid in it), or nil without the API's answer.
function Gear.carriedWeight(item)
    local api = OA.api()
    local formulas = api and api.formulas
    if type(formulas) ~= "table" or type(formulas.weight) ~= "function" then return nil end
    local ok, weight = pcall(formulas.weight, item)
    if ok and type(weight) == "number" then return weight end
    return nil
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

-- The item an action works on, for the checks that run every tick (isValid): the object the action was made with (in
-- the field `field`), as long as it is in the character's inventory (a walk up from its container, no search). Only
-- when the action has no object (made again from its ids) or the object left the inventory is the inventory searched,
-- once; what that finds is kept.
function Gear.heldItem(action, field, idField)
    local item = action[field]
    if item and OA.inInventory(item, action.character) then return item end
    -- oa-scan: ok (an action made from ids, or the item moved: once, and kept)
    item = Gear.findItem(action.character, action[idField])
    action[field] = item
    return item
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

-- The kind of a kit item, or nil when the item is not one.
function Gear.kindOfItem(kit)
    return kit and Rules.kindOf(kit:getFullType()) or nil
end

-- The name of a vehicle as the mechanics window shows it (IGUI_VehicleName<model>).
function Gear.vehicleName(vehicle)
    local script = vehicle:getScript()
    local name = script and script:getName() or ""
    local model = script and script.getCarModelName and script:getCarModelName() or name
    local text = getTextOrNull and (getTextOrNull("IGUI_VehicleName" .. tostring(model))
        or getTextOrNull("IGUI_VehicleName" .. name))
    return text or name
end

-- Whether an item is a bag the bag kits go to: one worn on the back (a backpack; not a key ring, a fanny pack, a
-- satchel or a bag held in the hand).
function Gear.isBackpack(item)
    if not (item and item:IsInventoryContainer()) then return false end
    local slot = item.canBeEquipped and item:canBeEquipped()
    return slot ~= nil and ItemBodyLocation ~= nil and slot == ItemBodyLocation.BACK
end

-- The backpacks and the kits a character carries, in any container: { key, bags = { item }, kits = { [kind] = { item } } }.
-- Found in one pass through the inventory, and kept while the inventory's signature (OA.signature) is the same: the
-- menus and tooltips that need them are drawn again and again, and the inventory may hold thousands of items. A kit or
-- a bag moved between two bags of the inventory changes no signature, but is still carried, and that is all this says.
local carriedCache = setmetatable({}, { __mode = "k" })

function Gear.carried(character)
    local inventory = character:getInventory()
    local key = OA.signature(inventory)
    local hit = carriedCache[character]
    if hit and hit.key == key then return hit end
    local found = { key = key, bags = {}, kits = {} }
    -- oa-scan: ok (the one pass for a signature that changed)
    local list = inventory:getAllEvalRecurse(function(item)
        return item:IsInventoryContainer() or (item:getModule() == OA.MOD and Gear.kindOfItem(item) ~= nil)
    end)
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local kind = item:getModule() == OA.MOD and Gear.kindOfItem(item) or nil
        if kind then
            found.kits[kind] = found.kits[kind] or {}
            table.insert(found.kits[kind], item)
        end
        if Gear.isBackpack(item) then table.insert(found.bags, item) end
    end
    carriedCache[character] = found
    return found
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
-- (the capacity, or the weight reduction), or false and the reason: "kit" (not a bag kit), "bag" (not a backpack).
function Gear.fitBag(character, kit, bag)
    local kind = Gear.kindOfItem(kit)
    if Rules.SCOPE[kind] ~= "bag" then return false, "kit" end
    if not bag or not bag.IsInventoryContainer or not Gear.isBackpack(bag) or bag == kit then return false, "bag" end
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
-- "far", "part" (no trunk).
function Gear.fitTrunk(character, kit, vehicle)
    if Gear.kindOfItem(kit) ~= "trunk" then return false, "kit" end
    if not vehicle then return false, "gone" end
    if not Gear.near(character, vehicle) then return false, "far" end
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

-- Redeems a kit voucher: the voucher is used up and the character gets one kit of the kind. The kit is not bought:
-- the shop does not count it, so the price of the next kit of the kind does not rise (NUMBERS 7). Fitting it counts
-- on the bag or the vehicle like any kit. Returns true, or false and the reason.
function Gear.redeem(character, voucher, kind)
    if not voucher or voucher:getFullType() ~= Gear.VOUCHER then return false, "voucher" end
    local fullType = Rules.kitType(kind)
    if not fullType then return false, "kind" end
    local kit = instanceItem(fullType)
    if not kit then return false, "kind" end
    removeItem(voucher)
    giveItem(character, kit)
    notice(character, "IGUI_OA_Gear_Redeemed", { kit:getDisplayName() })
    return true
end

return Gear
