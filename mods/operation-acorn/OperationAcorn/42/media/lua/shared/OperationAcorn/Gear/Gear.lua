-- The modification kits and the team's gear on the game side (REWARDS, NUMBERS 7). The rules are pure numbers
-- (Gear/Rules.lua); this reads and writes the game's objects and is what the timed actions and the server commands
-- call. What a kit fits and where its effect lives:
--
--   expansion kit      a bag: its capacity (InventoryContainer.setCapacity), saved with the item. The fuel can: its
--                      fluid container's capacity, saved. The welder: its uses (OA_Uses, which the extension API
--                      reads). A vehicle's storage part (any part that holds items, not a seat): the part's capacity,
--                      saved with the vehicle.
--   lightening kit     a bag: its weight reduction, saved. A team item (the fuel can, the welder, a field tool): what
--                      it weighs carried (OA_Carry, which the extension API reads; without the API its weight, which the
--                      game does not save, so it is written again when the game starts and when the item is looked at).
--   reinforcement kit  a field tool: its most condition (setConditionMax), saved.
--   engine kit         the engine part: the engine's own features (BaseVehicle.setEngineFeature), saved.
--   weapon kits        a HandWeapon, melee or firearm. Damage: its least and most damage (HandWeapon.setMinDamage and
--                      setMaxDamage), +10% of the script's per kit; the weapon parts' damage (they add to it as they
--                      are attached) is added on top. Critical: its critical chance (setCriticalChance), +5 points of the
--                      chance it had before the first critical kit (the script has no getter for it, only a field) per
--                      kit. Repair: the weapon's condition up by a tenth of its most, once; only counted.
-- The counts of kits live in the target's modData; the values are worked out again from them (refresh*), so a game
-- started later with or without the API gets the right value.
--
-- Past the game's own capacity limits a container needs PZ Extension API: it adds the number in the holder's modData
-- OA_Capacity to the raw capacity and lifts the limits (docs/design/extension-api.md, capacity.modDataKey). Without it
-- the kits are written into the raw capacity and the game cuts them at its limits; the tooltip says so.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Gear/Rules"
local OA = OperationAcorn
local Gear = OA.Gear
local Rules = Gear.Rules
local K = Rules.KEY
local Shop = OA.Shop

Gear.VOUCHER = "OperationAcorn.KitVoucher"
-- The vehicle part the engine kit changes.
Gear.ENGINE_PART = "Engine"
-- How near (squares) a character must be to a vehicle to fit a kit.
Gear.REACH = 6
-- The extension API's points the kits use besides the capacity key (OA.CAPACITY_POINT), and what this part declares for
-- them when the game starts.
Gear.CARRY_POINT = "carry.efficiencyKey"
Gear.USES_POINT = "uses.modDataKey"
Gear.CRAFT_POINT = "craft.carryKeys"
Gear.NAME_POINT = "item.nameKey"
-- The keys a refilled welder keeps (the recipe makes a new torch from the one it uses up), its icon and name with them.
Gear.CRAFT_KEYS = { K.TEAM, K.USES, K.CARRY, K.KIT_CAP, K.KIT_LIGHT, K.NAME, K.ICON }

-- ---- the extension API ----------------------------------------------------------------------------------------

local function formulas()
    local api = OA.api()
    local f = api and api.formulas
    if type(f) == "table" and type(f.points) == "function" then return f end
    return nil
end

local function applied(f, point)
    local ok, status = OA.try("gear: the API points", f.points)
    return ok and type(status) == "table" and status[point] == "applied"
end

-- What this part declares itself, by point (the capacity key is the upgrades part's, declared the same way).
local function declaredValue(point)
    if point == Gear.CARRY_POINT then return K.CARRY end
    if point == Gear.USES_POINT then return K.USES end
    if point == Gear.CRAFT_POINT then return Gear.CRAFT_KEYS end
    if point == Gear.NAME_POINT then return K.NAME end
    return OA.CAPACITY_KEY
end

-- The points declared, per API table (a newer API that takes over is a new table, and is told again).
local declaredBy = {}
local known = {}

-- Whether the extension API applies a point (the points above): its hooks went in, and this part's
-- value is declared (it declares it here once, if it has not yet; a key declared twice is the same key). Kept for a
-- few game minutes: the question is asked often.
function Gear.applies(point, force)
    local now = OA.hours()
    local hit = known[point]
    if not force and hit and math.abs(now - hit.at) < 0.05 then return hit.value end
    local value = false
    local f = formulas()
    if f then
        local declared = declaredBy[f] or {}
        declaredBy[f] = declared
        if not declared[point] then
            declared[point] = true
            local handle = OA.handle()
            if handle and type(f.set) == "function" then
                local ok, err = pcall(f.set, handle, point, declaredValue(point))
                if not ok then OA.log("gear: declaring", point, "failed:", tostring(err)) end
            end
        end
        value = applied(f, point)
    end
    known[point] = { at = now, value = value }
    return value
end

-- Whether the extension API lifts a container held by the capacity key above the game's limits.
function Gear.lifts(force)
    return Gear.applies(OA.CAPACITY_POINT, force)
end

-- Declares the team items' keys to the API, once a game (when it starts).
function Gear.declare()
    for _, point in ipairs({ Gear.CARRY_POINT, Gear.USES_POINT, Gear.CRAFT_POINT, Gear.NAME_POINT }) do Gear.applies(point, true) end
end

-- Whether an item is named by its key (K.NAME): it holds one, and the extension API has the point that reads it (its
-- hooks may wait for their classes to load). Such an item is not named as a player names it, which would hide the key.
function Gear.namedByKey(item)
    local md = item:hasModData() and item:getModData() or nil
    if not (md and type(md[K.NAME]) == "string") then return false end
    local f = formulas()
    if not f then return false end
    Gear.applies(Gear.NAME_POINT)
    local ok, status = OA.try("gear: the API points", f.points)
    return ok and type(status) == "table" and status[Gear.NAME_POINT] ~= nil
end

-- What an item weighs as carried now (a bag with what is in it, a can with its fuel), or nil without the API's answer.
function Gear.carriedWeight(item)
    local f = formulas()
    if not f or type(f.weight) ~= "function" then return nil end
    local ok, weight = OA.try("gear: the API weight", f.weight, item)
    if ok and type(weight) == "number" then return weight end
    return nil
end

-- ---- finding things -------------------------------------------------------------------------------------------

-- An item of a character's inventory by id, and the item an action works on (OA.findItem, OA.heldItem).
Gear.findItem, Gear.heldItem = OA.findItem, OA.heldItem

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

-- The field tools' item types (Shop.FIELD_TOOLS).
local fieldTypes
local function isFieldTool(fullType)
    if not fieldTypes then
        fieldTypes = {}
        for _, t in ipairs(Shop.FIELD_TOOLS) do fieldTypes[Shop.fieldType(t[1])] = true end
    end
    return fieldTypes[fullType] == true
end
Gear.isFieldTool = isFieldTool

-- Whether an item is a bag the kits go to: one worn on the back (a backpack; not a key ring, a fanny pack, a satchel
-- or a bag held in the hand), or the team's waist bag, worn either way.
function Gear.isKitBag(item)
    if not (item and item:IsInventoryContainer()) then return false end
    local fullType = item:getFullType()
    if fullType == Shop.TYPES.waistBag or fullType == Shop.TYPES.waistBagBack then return true end
    local slot = item.canBeEquipped and item:canBeEquipped()
    return slot ~= nil and ItemBodyLocation ~= nil and slot == ItemBodyLocation.BACK
end

-- What kind of target an item is for the kits: "bag", "can", "welder", "tool", "weapon" (a HandWeapon that is no field
-- tool), or nil.
function Gear.targetOf(item)
    if not item then return nil end
    if Gear.isKitBag(item) then return "bag" end
    local fullType = item:getFullType()
    if fullType == Shop.TYPES.fuelCan then return "can" end
    if isFieldTool(fullType) then return "tool" end
    if fullType == Shop.TYPES.welder then
        local md = dataOf(item)
        if md and md[K.TEAM] then return "welder" end
    end
    if item:IsWeapon() then return "weapon" end
    return nil
end

-- Whether an item might be a target, judged cheaply (the pass in refreshAll asks it of every item).
local function maybeTarget(item)
    return item:IsInventoryContainer() or item:getModule() == OA.MOD or item:getType() == "BlowTorch" or item:IsWeapon()
end

-- What a character carries, in any container, is asked of the game, which counts and fetches by item type and category
-- in Java (no Lua runs per item), and only as much as is needed: a menu counts the kits, the entry the player picks
-- fetches the first kit, and a kit's menu lists the targets it can go to.

-- How many kits of a kind a character carries.
function Gear.kitCount(character, kind)
    local fullType = Rules.kitType(kind)
    -- oa-scan: ok (counted in Java by item type, no Lua per item)
    return fullType and character:getInventory():getCountTypeRecurse(fullType) or 0
end

-- The first kit of a kind a character carries, or nil. Fetched when an entry is picked, never to build a menu.
function Gear.firstKit(character, kind)
    local fullType = Rules.kitType(kind)
    -- oa-scan: ok (when the player picks an entry; Java stops at the first)
    return fullType and character:getInventory():getFirstTypeRecurse(fullType) or nil
end

-- The item types of the targets that are no bags: the fuel can, the welder, the field tools.
local targetTypes
local function otherTargetTypes()
    if not targetTypes then
        targetTypes = { Shop.TYPES.fuelCan, Shop.TYPES.welder }
        for _, t in ipairs(Shop.FIELD_TOOLS) do targetTypes[#targetTypes + 1] = Shop.fieldType(t[1]) end
    end
    return targetTypes
end

-- The kit targets a character carries, in any container, in the order the game lists them: bags (found by the game's
-- category Container), then the fuel can, the welders and the field tools. Built when a kit is right-clicked, to say
-- where it can go. A weapon kit's targets are the weapons (found by the game's category Weapon), no others.
function Gear.targets(character, weapons)
    local inventory = character:getInventory()
    local found, seen = {}, {}
    local function take(list)
        for i = 0, list:size() - 1 do
            local item = list:get(i)
            if not seen[item] and Gear.targetOf(item) then
                seen[item] = true
                found[#found + 1] = item
            end
        end
    end
    if weapons then
        -- oa-scan: ok (a kit's own menu; Java picks by category, Lua sees the weapons)
        take(inventory:getAllCategoryRecurse("Weapon", ArrayList.new()))
        return found
    end
    -- oa-scan: ok (a kit's own menu; Java picks by category and by type, Lua sees the few that match)
    take(inventory:getAllCategoryRecurse("Container", ArrayList.new()))
    for _, fullType in ipairs(otherTargetTypes()) do
        -- oa-scan: ok (as above)
        take(inventory:getAllTypeRecurse(fullType))
    end
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
    if item.syncItemFields then OA.try("gear: syncing an item", item.syncItemFields, item) end
end

local function notice(character, key, args)
    OA.Sync.notice(OA.Store.idOf(character), key, args)
end

-- ---- items ----------------------------------------------------------------------------------------------------

-- The kits fitted to an item: expansion, lightening, reinforcement.
function Gear.itemKits(item)
    local md = dataOf(item)
    if not md then return 0, 0, 0 end
    return md[K.KIT_CAP] or 0, md[K.KIT_LIGHT] or 0, md[K.KIT_TOUGH] or 0
end

-- The weapon kits fitted to a weapon: damage, critical, repair (used).
function Gear.weaponKits(item)
    local md = dataOf(item)
    if not md then return 0, 0, 0 end
    return md[K.KIT_WDAMAGE] or 0, md[K.KIT_WCRIT] or 0, md[K.KIT_WREPAIR] or 0
end

-- The script's weight and most condition of an item (the field tool's, before any kit).
local function scriptWeight(item)
    local script = item:getScriptItem()
    return script and script:getActualWeight() or item:getActualWeight()
end

local function scriptCondition(item)
    local script = item:getScriptItem()
    return script and script:getConditionMax() or item:getConditionMax()
end

-- A bag's kits written into it: the capacity (with the API the original stays and OA_Capacity adds the kits; without
-- it the kits go into the capacity, cut at the game's limit) and the weight reduction. The item the kits were written
-- into is remembered: the waist bag worn the other way is a new item with the modData copied and the script's values.
local function refreshBag(bag, md, n, w)
    local fresh = md[K.BAG_ID] ~= bag:getID()
    if fresh then md[K.BAG_ID] = bag:getID() end
    local baseCap, baseRed = md[K.BAG_BASE_CAP], md[K.BAG_BASE_RED]
    if baseCap and n > 0 then
        local total = Rules.capacity(baseCap, n)
        local lifted = Gear.lifts()
        local raw = Rules.raw(baseCap, total, Rules.bagLimit(bag:getActualWeight()), lifted)
        if fresh or md[K.RAW] ~= raw then
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

-- A team item's lightening kits written into it: with the API its own carrying efficiency (the item then tells the
-- game its weight changed); without it its weight, which the game does not save.
local function refreshWeight(item, md, w)
    if Gear.applies(Gear.CARRY_POINT) then
        local efficiency = w > 0 and Rules.efficiency(w) or nil
        if md[K.CARRY] ~= efficiency then
            md[K.CARRY] = efficiency
            item:setActualWeight(item:getActualWeight())
        end
    elseif w > 0 then
        if md[K.CARRY] ~= nil then md[K.CARRY] = nil end
        local weight = scriptWeight(item) * Rules.lightness(w)
        if math.abs(item:getActualWeight() - weight) > 1e-4 then item:setActualWeight(weight) end
    end
end

-- The damage the weapon parts attached to a weapon add (to the least and the most damage alike, as HandWeapon
-- attachWeaponPart does). The part list is the game's, read here only when the weapon has damage kits.
local function partsDamage(weapon)
    local parts = weapon:getAllWeaponParts()
    local sum = 0
    for i = 0, (parts and parts:size() or 0) - 1 do sum = sum + parts:get(i):getDamage() end
    return sum
end

-- A weapon's damage and critical kits written into it, worked out from the script's damage (getScriptItem; the script
-- has no critical getter, so that one starts from the chance the weapon had at the first critical kit) and the counts.
local function refreshWeapon(weapon, md)
    local d, c = Gear.weaponKits(weapon)
    if d > 0 then
        local script = weapon:getScriptItem()
        if script then
            local parts = partsDamage(weapon)
            local least = Rules.damage(script:getMinDamage(), d) + parts
            local most = Rules.damage(script:getMaxDamage(), d) + parts
            if math.abs(weapon:getMinDamage() - least) > 1e-4 then weapon:setMinDamage(least) end
            if math.abs(weapon:getMaxDamage() - most) > 1e-4 then weapon:setMaxDamage(most) end
        end
    end
    if c > 0 and md[K.WEAPON_CRIT] then
        local chance = Rules.crit(md[K.WEAPON_CRIT], c)
        if math.abs(weapon:getCriticalChance() - chance) > 1e-4 then weapon:setCriticalChance(chance) end
    end
end

-- Writes an item's kits into it. Only what differs is written. Safe to call again at any time.
function Gear.refreshItem(item)
    local target = Gear.targetOf(item)
    local md = target and dataOf(item)
    if not md then return end
    if target == "weapon" then
        refreshWeapon(item, md)
        return
    end
    local n, w, t = Gear.itemKits(item)
    if target == "bag" then
        if n > 0 or w > 0 then refreshBag(item, md, n, w) end
        return
    end
    refreshWeight(item, md, w)
    if target == "can" and n > 0 and md[K.BAG_BASE_CAP] then
        local container = item:getFluidContainer()
        local litres = Rules.canLitres(md[K.BAG_BASE_CAP], n)
        if container and container:getCapacity() ~= litres then container:setCapacity(litres) end
    elseif target == "welder" then
        local uses = Rules.uses(n)
        if md[K.USES] ~= uses then md[K.USES] = uses end
    elseif target == "tool" and t > 0 then
        local most = Rules.toughness(scriptCondition(item), t)
        if item:getConditionMax() ~= most then item:setConditionMax(most) end
    end
end

-- What an item's kits make of it, for the tooltip and the notices: { target, capacity, weight, tough (kits), total,
-- limit, cut (a bag's capacity), reduction (a bag's), litres (the can's), uses (the welder's), share (the part of its
-- weight a team item weighs), condition (a tool's most) }; nil when it is no target.
function Gear.itemInfo(item)
    local target = Gear.targetOf(item)
    if not target then return nil end
    if target == "weapon" then
        local d, c, r = Gear.weaponKits(item)
        return { target = target, damage = d, crit = c, repair = r, chance = item:getCriticalChance(),
            condition = item:getCondition(), most = item:getConditionMax() }
    end
    local n, w, t = Gear.itemKits(item)
    local info = { target = target, capacity = n, weight = w, tough = t }
    local md = dataOf(item)
    if target == "bag" then
        local baseCap, baseRed = md and md[K.BAG_BASE_CAP], md and md[K.BAG_BASE_RED]
        if baseCap then
            info.total = Rules.capacity(baseCap, n)
            info.limit = Rules.bagLimit(item:getActualWeight())
            info.cut = Rules.cut(info.total, info.limit, Gear.lifts())
        end
        if baseRed then info.reduction = Rules.reductionInt(baseRed, w) end
        return info
    end
    info.share = Rules.lightness(w)
    if target == "can" then
        local container = item:getFluidContainer()
        info.litres = container and container:getCapacity() or nil
    elseif target == "welder" then
        info.uses = item:getMaxUses()
    elseif target == "tool" then
        info.condition = item:getConditionMax()
    end
    return info
end

-- Why a kit cannot be fitted to an item now, or nil when it can: "kit" (not a kit), "target" (it does not fit that
-- item), "most" (the tool has all the reinforcement it takes), "api" (the welder's uses need the extension API), "full"
-- (the weapon is at its most condition, a repair kit would be wasted).
function Gear.refusal(kit, item)
    local kind = Gear.kindOfItem(kit)
    if not kind then return "kit" end
    if not item or item == kit then return "target" end
    return Gear.refusalFor(kind, item)
end

-- The same for a kind of kit, before any kit is picked (the menus ask it of the kinds the character carries).
function Gear.refusalFor(kind, item)
    local target = Gear.targetOf(item)
    if not Rules.fits(kind, target) then return "target" end
    local _, _, t = Gear.itemKits(item)
    if kind == "reinforcement" and t >= Rules.TOUGH_MOST then return "most" end
    if kind == "capacity" and target == "welder" and not Gear.applies(Gear.USES_POINT) then return "api" end
    if kind == "weaponRepair" and item:getCondition() >= item:getConditionMax() then return "full" end
    return nil
end

-- The notice that tells what a fitted kit made of the item: its key and the value.
local function fittedText(kind, target, info)
    if target == "weapon" then
        if kind == "weaponDamage" then
            return "IGUI_OA_Gear_Fitted_weaponDamage", "+" .. tostring(OA.round(info.damage * Rules.DAMAGE_STEP * 100)) .. "%"
        end
        if kind == "weaponCrit" then return "IGUI_OA_Gear_Fitted_weaponCrit", tostring(OA.round(info.chance)) .. "%" end
        return "IGUI_OA_Gear_Fitted_weaponRepair", tostring(info.condition) .. "/" .. tostring(info.most)
    end
    if target == "bag" then
        if kind == "capacity" then return "IGUI_OA_Gear_Fitted_bagCapacity", tostring(info.total) end
        return "IGUI_OA_Gear_Fitted_bagWeight", tostring(info.reduction) .. "%"
    end
    if kind == "capacity" and target == "can" then return "IGUI_OA_Gear_Fitted_litres", tostring(info.litres) end
    if kind == "capacity" then return "IGUI_OA_Gear_Fitted_uses", tostring(info.uses) end
    if kind == "lightening" then return "IGUI_OA_Gear_Fitted_lighter", tostring(OA.round(info.share * 100)) .. "%" end
    return "IGUI_OA_Gear_Fitted_tough", tostring(info.condition)
end

-- A weapon kit counted on the weapon: damage and critical kits are counted (the critical kit first notes the chance the
-- weapon has now), and the values written from the counts; a repair kit puts back its part of the condition, and does
-- not touch the count of repairs the game keeps (HaveBeenRepaired), which sets how well the weapon is repaired by hand.
function Gear.fitWeapon(kind, weapon, md)
    if kind == "weaponDamage" then
        md[K.KIT_WDAMAGE] = (md[K.KIT_WDAMAGE] or 0) + 1
    elseif kind == "weaponCrit" then
        if md[K.WEAPON_CRIT] == nil then md[K.WEAPON_CRIT] = weapon:getCriticalChance() end
        md[K.KIT_WCRIT] = (md[K.KIT_WCRIT] or 0) + 1
    else
        md[K.KIT_WREPAIR] = (md[K.KIT_WREPAIR] or 0) + 1
        weapon:setCondition(Rules.repaired(weapon:getCondition(), weapon:getConditionMax()), false)
    end
end

-- Fits a kit to an item the character has: counts it, writes it into the item, uses the kit up. Returns true and the
-- item's new value (as the notice says it), or false and the reason (Gear.refusal).
function Gear.fitItem(character, kit, item)
    local why = Gear.refusal(kit, item)
    if why then return false, why end
    local kind, target = Gear.kindOfItem(kit), Gear.targetOf(item)
    local md = item:getModData()
    if target == "weapon" then
        Gear.fitWeapon(kind, item, md)
    elseif kind == "capacity" then
        if target == "bag" and md[K.BAG_BASE_CAP] == nil then
            md[K.BAG_BASE_CAP] = item:getItemContainer():getCapacity()
        elseif target == "can" and md[K.BAG_BASE_CAP] == nil then
            local container = item:getFluidContainer()
            md[K.BAG_BASE_CAP] = container and container:getCapacity() or 0
        end
        md[K.KIT_CAP] = (md[K.KIT_CAP] or 0) + 1
    elseif kind == "lightening" then
        if target == "bag" and md[K.BAG_BASE_RED] == nil then md[K.BAG_BASE_RED] = item:getWeightReduction() end
        md[K.KIT_LIGHT] = (md[K.KIT_LIGHT] or 0) + 1
    else
        -- reinforcement: the new most condition, and the condition (and a head's) up by as much
        local before = item:getConditionMax()
        md[K.KIT_TOUGH] = (md[K.KIT_TOUGH] or 0) + 1
        local most = Rules.toughness(scriptCondition(item), md[K.KIT_TOUGH])
        item:setConditionMax(most)
        local gain = most - before
        item:setCondition(math.min(most, item:getCondition() + gain), false)
        if item:hasHeadCondition() then item:setHeadCondition(item:getHeadCondition() + gain) end
    end
    Gear.refreshItem(item)
    removeItem(kit)
    syncItem(item)
    local key, value = fittedText(kind, target, Gear.itemInfo(item))
    notice(character, key, { item:getDisplayName(), value })
    return true, value
end

-- Every target a character has (in any container) that carries a kit, written again from its counts (a save loaded
-- with the API, or without it, after the item was fitted the other way; a lightened item's weight, which the game does
-- not save). Called when the game starts.
function Gear.refreshAll(character)
    local list = character:getInventory():getAllEvalRecurse(function(item)
        if not maybeTarget(item) then return false end
        local md = dataOf(item)
        return md ~= nil and (md[K.KIT_CAP] or md[K.KIT_LIGHT] or md[K.KIT_TOUGH] or md[K.TEAM] or md[K.KIT_WDAMAGE]
            or md[K.KIT_WCRIT]) ~= nil
    end)
    for i = 0, list:size() - 1 do Gear.refreshItem(list:get(i)) end
    return list:size()
end

-- ---- vehicle storage -----------------------------------------------------------------------------------------

-- Whether a vehicle part is a storage the expansion kit fits: any part that holds items (a trunk, a truck bed, a roof
-- rack, a trailer's, a glove box, a modded vehicle's own), not a seat.
function Gear.isStoragePart(part)
    if not part or not part:getItemContainer() then return false end
    if part:getCategory() == "seat" then return false end
    return string.find(part:getId(), "^Seat") == nil
end

-- A vehicle's storage parts.
function Gear.storageParts(vehicle)
    local found = {}
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if Gear.isStoragePart(part) then found[#found + 1] = part end
    end
    return found
end

-- A storage's capacity before any kit: the capacity of the part's installed item (a trunk), or the container's own.
local function nominalStorage(part)
    local item = part:getInventoryItem()
    local capacity = item and item.getMaxCapacity and item:getMaxCapacity() or 0
    if capacity <= 0 then capacity = part:getContainerCapacity() end
    return capacity
end

-- What a storage part is worth with its kits: { kits, total, limit, cut }; nil when it has none.
function Gear.storageInfo(part)
    local md = part:getModData()
    local kits, base = md[K.KIT_CAP] or 0, md[K.STORAGE_BASE]
    if kits == 0 or not base then return nil end
    local info = { kits = kits, limit = Rules.VEHICLE_LIMIT, total = Rules.capacity(base, kits) }
    info.cut = Rules.cut(info.total, info.limit, Gear.lifts())
    return info
end

-- Writes a storage part's kits into the part (see refreshBag), and sends the part's data to the clients when it wrote
-- anything. Returns whether it did.
function Gear.refreshStorage(vehicle, part)
    local md = part:getModData()
    local n, base = md[K.KIT_CAP] or 0, md[K.STORAGE_BASE]
    if not base or n == 0 then return false end
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
    return changed
end

-- Fits an expansion kit to one storage part of a vehicle. Returns true and the part's new capacity, or false and the
-- reason: "kit", "gone", "far", "part" (not a storage).
function Gear.fitStorage(character, kit, vehicle, partId)
    if not Rules.fits(Gear.kindOfItem(kit), "storage") then return false, "kit" end
    if not vehicle then return false, "gone" end
    if not Gear.near(character, vehicle) then return false, "far" end
    local part = partId and vehicle:getPartById(partId)
    if not Gear.isStoragePart(part) then return false, "part" end
    local md = part:getModData()
    if md[K.STORAGE_BASE] == nil then md[K.STORAGE_BASE] = nominalStorage(part) end
    md[K.KIT_CAP] = (md[K.KIT_CAP] or 0) + 1
    -- (the kit count is a change of its own when the refresh found nothing else to write)
    if not Gear.refreshStorage(vehicle, part) and vehicle.transmitPartModData then vehicle:transmitPartModData(part) end
    local total = Rules.capacity(md[K.STORAGE_BASE], md[K.KIT_CAP])
    removeItem(kit)
    notice(character, "IGUI_OA_Gear_Fitted_storage", { Gear.vehicleName(vehicle), Gear.partName(part), tostring(total) })
    return true, total
end

-- The name the mechanics window gives a part.
function Gear.partName(part)
    return getText("IGUI_VehiclePart" .. part:getId())
end

-- ---- engines --------------------------------------------------------------------------------------------------

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
        if engine and engine.setLoudness then OA.try("gear: the engine loudness", engine.setLoudness, engine, info.loudness) end
    end
    if vehicle.transmitEngine then vehicle:transmitEngine() end
    return true
end

-- Fits an engine kit to a vehicle. Returns true and the new power, or false and the reason (see fitStorage).
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

-- Fits a vehicle kit to the part named: an expansion kit to a storage, an engine kit to the engine.
function Gear.fitVehicle(character, kit, vehicle, partId)
    local kind = Gear.kindOfItem(kit)
    if partId == Gear.ENGINE_PART and kind == "engine" then return Gear.fitEngine(character, kit, vehicle) end
    if Rules.fits(kind, "storage") then return Gear.fitStorage(character, kit, vehicle, partId) end
    return false, "kit"
end

-- Refreshes everything a vehicle's kits have written: the storage parts and the engine.
function Gear.refreshVehicle(vehicle)
    for _, part in ipairs(Gear.storageParts(vehicle)) do Gear.refreshStorage(vehicle, part) end
    Gear.refreshEngine(vehicle)
end

-- ---- texts about fitted kits ----------------------------------------------------------------------------------

-- The lines about an item's kits (for its tooltip), or nil when it has none and is no team item.
function Gear.itemLines(item)
    local info = Gear.itemInfo(item)
    if not info then return nil end
    local lines = {}
    local function add(key, ...) lines[#lines + 1] = getText(key, ...) end
    if info.target == "weapon" then
        if info.damage > 0 then
            add("Tooltip_OA_Gear_WeaponDamage", tostring(info.damage), tostring(OA.round(info.damage * Rules.DAMAGE_STEP * 100)))
        end
        if info.crit > 0 then
            add("Tooltip_OA_Gear_WeaponCrit", tostring(info.crit), tostring(info.crit * Rules.CRIT_STEP))
        end
        if info.repair > 0 then add("Tooltip_OA_Gear_WeaponRepair", tostring(info.repair)) end
        return #lines > 0 and lines or nil
    end
    if info.target == "bag" then
        if info.capacity > 0 and info.total then add("Tooltip_OA_Gear_BagCapacity", tostring(info.capacity), tostring(info.total)) end
        if info.weight > 0 and info.reduction then
            add("Tooltip_OA_Gear_BagWeight", tostring(info.weight), tostring(info.reduction) .. "%")
        end
        if info.cut then add("Tooltip_OA_Gear_BagCut", tostring(info.limit)) end
        return #lines > 0 and lines or nil
    end
    if info.target == "welder" then add("Tooltip_OA_Gear_WelderUses", tostring(info.uses)) end
    if info.capacity > 0 then
        if info.target == "can" then
            add("Tooltip_OA_Gear_CanKits", tostring(info.capacity), tostring(info.litres))
        else
            add("Tooltip_OA_Gear_UsesKits", tostring(info.capacity))
        end
    end
    if info.weight > 0 then add("Tooltip_OA_Gear_LightKits", tostring(info.weight), tostring(OA.round(info.share * 100)) .. "%") end
    if info.tough > 0 then add("Tooltip_OA_Gear_ToughKits", tostring(info.tough), tostring(info.condition)) end
    return #lines > 0 and lines or nil
end

-- The lines about a storage part's fitted kits, or nil.
function Gear.storageLines(part)
    local info = Gear.storageInfo(part)
    if not info then return nil end
    local lines = { getText("Tooltip_OA_Gear_StorageKits", tostring(info.kits), tostring(info.total)) }
    if info.cut then lines[#lines + 1] = getText("Tooltip_OA_Gear_StorageCut", tostring(info.limit)) end
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

-- Redeems a kit voucher: the voucher is used up and the character gets one kit of the kind (not bought: the shop's
-- price of a kit is flat, NUMBERS 7). Fitting it counts on its target like any kit. Returns true, or false and the
-- reason.
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
