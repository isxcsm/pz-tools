-- A breaker box is a terminal tile the vanilla moveables code could pick up or disassemble, which would lose the
-- box item. It is taken down with this mod's action only, which gives the item back.
require "Moveables/ISMoveableSpriteProps"
require "BuildingUtilities/Panels"
local BU = BuildingUtilities

local fromObject = ISMoveableSpriteProps.fromObject
function ISMoveableSpriteProps.fromObject(object)
    local props = fromObject(object)
    if props and object and BU.Panels.ofObject(object) then
        props.isMoveable = false
        props.canScrap = false
    end
    return props
end
