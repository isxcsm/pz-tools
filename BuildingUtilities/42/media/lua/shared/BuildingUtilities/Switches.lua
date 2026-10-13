-- A device's own switch, read for its box's window: lights, stoves and microwaves, washers and dryers, battery
-- chargers, televisions and radios. The box never throws it (its tick only supplies or cuts the device): the player
-- does, at the device, and the window shows which way it is. A fridge has none, nor a stacked washer and dryer (two
-- switches). Another mod's things with a switch of their own come in through the global list BuildingUtilitiesSwitches:
-- each entry { state = function(object) -> true, false, or nil when not its thing }, added as that mod loads, in any
-- order.
BuildingUtilitiesSwitches = BuildingUtilitiesSwitches or {}
local BU = BuildingUtilities
local Switches = {}
BU.Switches = Switches

local ACTIVATED = { "IsoClothingWasher", "IsoClothingDryer", "IsoCombinationWasherDryer", "IsoCarBatteryCharger" }

local function activated(object)
    for _, class in ipairs(ACTIVATED) do
        if instanceof(object, class) then return true end
    end
    return false
end

-- Whether an object's switch is on; nil when it has none.
function Switches.state(object)
    if instanceof(object, "IsoLightSwitch") then return object:isActivated() end
    if instanceof(object, "IsoStove") then return object:Activated() end
    if activated(object) then return object:isActivated() end
    if instanceof(object, "IsoWaveSignal") then
        local data = object:getDeviceData()
        if data then return data:getIsTurnedOn() end
        return nil
    end
    for _, hook in ipairs(BuildingUtilitiesSwitches) do
        local on = hook.state(object)
        if on ~= nil then return on end
    end
    return nil
end

return Switches
