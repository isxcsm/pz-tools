-- The game's furniture tool (ISMoveableSpriteProps) over a mod's own tiles: what each mod that gives its objects to the
-- tool would otherwise repeat. A mod still wraps the tool's functions with its own rules; these are the pieces they
-- share.
PZUIKit = PZUIKit or {}
local Furniture = {}
PZUIKit.Furniture = Furniture

-- Makes a tile's props those of a one-tile object the tool takes up as its mod does (its tiles need no IsMoveAble
-- property, nor the furniture properties the tool reads from one): moveable, not scrapped, no other faces, nothing
-- linked, no wall overlay, one item. With `item`, the tool shows that item's name and weight.
function Furniture.oneTile(props, item)
    props.isMoveable = true
    props.canScrap = false
    props.type = "Object"
    props.isMultiSprite = false
    props.customItem, props.pickUpTool, props.placeTool, props.pickUpLevel = nil, nil, nil, 0
    props.Noffset, props.Soffset, props.Woffset, props.Eoffset = 0, 0, 0, 0
    props.linkedOffset, props.linkedLoc, props.isClosedState, props.wallOverlay = 0, nil, false, false
    props.ignoreSurfaceSnap, props.isGridExtensionTile, props.allowDoorFrame, props.isForceSingleItem = false, false, false, false
    if item then
        props.name = item:getName()
        props.weight = item:getActualWeight()
        props.rawWeight = props.weight * 10
    end
end

-- A line in the tool's panel saying why not, in the colour of the game's own such lines.
function Furniture.reasonLine(info, text)
    local c = ISMoveableSpriteProps.bhc
    ISMoveableSpriteProps.addLineToInfoTable(info, "- " .. text, c:getR() * 255, c:getG() * 255, c:getB() * 255)
end

return Furniture
