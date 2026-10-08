-- The timed actions that fit a kit: a bag kit to a bag the character has, a trunk or engine kit to a vehicle. The work
-- is done in complete(), where the world is decided (on a server, there); an action names its kit, bag and vehicle by
-- id, not by object. A failed fit tells the character why and leaves the kit where it was.
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

-- ---- a bag kit ------------------------------------------------------------------------------------------------

ISOAFitBagKit = ISBaseTimedAction:derive("ISOAFitBagKit")

function ISOAFitBagKit:isValid()
    local kit = Gear.findItem(self.character, self.kitId)
    local bag = Gear.findItem(self.character, self.bagId)
    return kit ~= nil and bag ~= nil and Gear.kindOfItem(kit) ~= nil
end

function ISOAFitBagKit:start()
    self:setActionAnim("Craft")
    self:setOverrideHandModels(nil, nil)
end

function ISOAFitBagKit:perform()
    ISBaseTimedAction.perform(self)
end

function ISOAFitBagKit:complete()
    local kit = Gear.findItem(self.character, self.kitId)
    local bag = Gear.findItem(self.character, self.bagId)
    if not kit or not bag then
        failed(self.character, "gone")
        return false
    end
    local ok, why = Gear.fitBag(self.character, kit, bag)
    if not ok then failed(self.character, why) end
    return ok
end

function ISOAFitBagKit:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Rules.workTicks("bag")
end

function ISOAFitBagKit:new(character, kit, bag)
    local o = ISBaseTimedAction.new(self, character)
    o.kitId, o.bagId = kit:getID(), bag:getID()
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end

-- ---- a trunk or an engine kit ---------------------------------------------------------------------------------

ISOAFitVehicleKit = ISBaseTimedAction:derive("ISOAFitVehicleKit")

function ISOAFitVehicleKit:isValid()
    local kit = Gear.findItem(self.character, self.kitId)
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
    local ok, why = Gear.fitVehicle(self.character, kit, vehicle)
    if not ok then
        failed(self.character, why)
        return false
    end
    if addXp and Perks then addXp(self.character, Perks.Mechanics, Actions.XP) end
    return true
end

function ISOAFitVehicleKit:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Rules.workTicks(self.kind, self.character:getPerkLevel(Perks.Mechanics))
end

function ISOAFitVehicleKit:new(character, kit, vehicle)
    local o = ISBaseTimedAction.new(self, character)
    o.kitId, o.vehicleId = kit:getID(), vehicle:getId()
    o.kind = Gear.kindOfItem(kit)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end

return Actions
