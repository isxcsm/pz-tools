-- The timed actions that fit a kit: to an item the character has (a bag, the fuel can, the welder, a field tool), or to
-- a vehicle's storage or engine. The work is done in complete(), where the world is decided (on a server, there); an
-- action names its kit, item and vehicle by id, not by object. A failed fit tells the character why and leaves the kit
-- where it was.
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Gear/Gear"
local OA = OperationAcorn
local Gear = OA.Gear
local Rules = Gear.Rules
local Actions = {}
Gear.Actions = Actions

-- The work, in ticks (Rules.workTicks); mechanics experience for a vehicle kit fitted.
Actions.XP = 5

local function failed(character, why)
    OA.Sync.notice(OA.Store.idOf(character), "IGUI_OA_Gear_Failed", { why })
end

-- ---- a kit to an item -----------------------------------------------------------------------------------------

ISOAFitItemKit = ISBaseTimedAction:derive("ISOAFitItemKit")

function ISOAFitItemKit:isValid()
    local kit = Gear.heldItem(self, "kit", "kitId")
    local item = Gear.heldItem(self, "item", "itemId")
    return kit ~= nil and item ~= nil and Gear.kindOfItem(kit) ~= nil
end

function ISOAFitItemKit:start()
    self:setActionAnim("Craft")
    self:setOverrideHandModels(nil, nil)
end

function ISOAFitItemKit:perform()
    ISBaseTimedAction.perform(self)
end

function ISOAFitItemKit:complete()
    local kit = Gear.findItem(self.character, self.kitId)
    local item = Gear.findItem(self.character, self.itemId)
    if not kit or not item then
        failed(self.character, "gone")
        return false
    end
    local ok, why = Gear.fitItem(self.character, kit, item)
    if not ok then failed(self.character, why) end
    return ok
end

function ISOAFitItemKit:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Rules.workTicks("item")
end

function ISOAFitItemKit:new(character, kit, item)
    local o = ISBaseTimedAction.new(self, character)
    o.kit, o.item, o.kitId, o.itemId = kit, item, kit:getID(), item:getID()
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end

-- ---- a kit to a vehicle's storage or engine -------------------------------------------------------------------

ISOAFitVehicleKit = ISBaseTimedAction:derive("ISOAFitVehicleKit")

function ISOAFitVehicleKit:isValid()
    local kit = Gear.heldItem(self, "kit", "kitId")
    local vehicle = Gear.findVehicle(self.vehicleId)
    return kit ~= nil and vehicle ~= nil and Gear.near(self.character, vehicle)
end

function ISOAFitVehicleKit:waitToStart()
    local vehicle = Gear.findVehicle(self.vehicleId)
    if not vehicle then return false end
    self.character:faceThisObject(vehicle)
    return self.character:shouldBeTurning()
end

function ISOAFitVehicleKit:update()
    local vehicle = Gear.findVehicle(self.vehicleId)
    if vehicle then self.character:faceThisObject(vehicle) end
    self.character:setMetabolicTarget(Metabolics.MediumWork)
end

function ISOAFitVehicleKit:start()
    self:setActionAnim("VehicleWorkOnMid")
end

function ISOAFitVehicleKit:perform()
    ISBaseTimedAction.perform(self)
end

function ISOAFitVehicleKit:complete()
    local kit = Gear.findItem(self.character, self.kitId)
    local vehicle = Gear.findVehicle(self.vehicleId)
    if not kit or not vehicle then
        failed(self.character, "gone")
        return false
    end
    local ok, why = Gear.fitVehicle(self.character, kit, vehicle, self.partId)
    if not ok then
        failed(self.character, why)
        return false
    end
    if addXp and Perks then addXp(self.character, Perks.Mechanics, Actions.XP) end
    return true
end

function ISOAFitVehicleKit:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Rules.workTicks(self.target, self.character:getPerkLevel(Perks.Mechanics))
end

-- part: the vehicle part the kit goes to (an expansion kit's storage, the engine).
function ISOAFitVehicleKit:new(character, kit, part)
    local o = ISBaseTimedAction.new(self, character)
    o.kit, o.kitId, o.vehicleId, o.partId = kit, kit:getID(), part:getVehicle():getId(), part:getId()
    o.target = part:getId() == Gear.ENGINE_PART and "engine" or "storage"
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end

return Actions
