-- The vanilla "move furniture" would turn a machine into a generic Moveable item and lose its state (parts and their
-- condition). Machines are put down and taken up by this mod's own actions only (Actions.lua), like Building
-- Utilities' units: the vanilla move is not offered for them.
require "Moveables/ISMoveableSpriteProps"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines

local fromObject = ISMoveableSpriteProps.fromObject
function ISMoveableSpriteProps.fromObject(object)
    local props = fromObject(object)
    if props and object and Machines.isMachineObject(object) then
        props.isMoveable = false
        props.canScrap = false
    end
    return props
end
