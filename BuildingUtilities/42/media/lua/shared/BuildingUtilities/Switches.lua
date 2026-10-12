-- A device's own switch, thrown from its box's window as the game's actions throw it (ISToggleLightAction,
-- ISToggleStoveAction, ISToggleClothingWasher, ISToggleClothingDryer, ISToggleComboWasherDryer,
-- ISActivateCarBatteryChargerAction, ISRadioAction's ToggleOnOff): lights, stoves and microwaves, washers and dryers,
-- battery chargers, televisions and radios. A fridge or a machine has none, nor a stacked washer and dryer (two
-- switches).
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
    end
    return nil
end

-- Throws an object's switch to on or off. Returns whether it moved.
function Switches.set(object, on)
    local now = Switches.state(object)
    if now == nil or now == on then return false end
    if instanceof(object, "IsoLightSwitch") then
        local props = object:getProperties()
        if not props or not props:has("streetlight") then object:getSquare():playSound("LightSwitch") end
        object:toggle()
    elseif instanceof(object, "IsoStove") then
        object:PlayToggleSound()
        object:Toggle()
    elseif instanceof(object, "IsoCarBatteryCharger") then
        object:getSquare():playSound("LightSwitch")
        object:setActivated(on)
        object:sync()
    elseif activated(object) then
        object:setActivated(on)
        local washer = instanceof(object, "IsoClothingWasher")
            or instanceof(object, "IsoCombinationWasherDryer") and object:isModeWasher()
        object:sendObjectChange(washer and IsoObjectChange.WASHER_STATE or IsoObjectChange.DRYER_STATE)
    else
        local data = object:getDeviceData()
        if data:getIsTelevision() then data:playSoundSend(on and "TelevisionOn" or "TelevisionOff", false)
        else data:playSoundSend("RadioButton", false) end
        data:setIsTurnedOn(on)
    end
    return true
end

-- The object with a switch of a device entry (its x, y, z and sprite), or nil.
function Switches.objectOf(entry)
    for _, object in ipairs(BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)) do
        if Switches.state(object) ~= nil then return object end
    end
    return nil
end

return Switches
