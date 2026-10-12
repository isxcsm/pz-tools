-- The box's and the units' tiles are the game's furniture tiles once loaded (IsMoveAble, naming the item), so that the
-- game gives their items a tile; an item made before has its script's tile given back.
local props = {}
local function prop() return { set = function(self, key, value) self[key] = value end } end
getSprite = function(name)
    props[name] = props[name] or prop()
    return { getProperties = function() return props[name] end }
end
ISMoveableSpriteProps = {
    new = function() return {} end,
    canPickUpMoveable = function() end, pickUpMoveable = function() end, canPlaceMoveable = function() end,
    placeMoveable = function() end, canRotateMoveable = function() end, getInfoPanelDescription = function() end,
}
instanceItem = function() return nil end
TEST.gameFile("Moveables/ISMoveableSpriteProps")
require "BuildingUtilities/Core"
require "BuildingUtilities/Solar"
require "BuildingUtilities/WaterUnits"
require "BuildingUtilities/Moveables"
local BU = BuildingUtilities

test("the tiles a box and the units show are furniture naming their items", function()
    TEST.fire("OnLoadedTileDefinitions")
    for _, name in ipairs({ BU.Solar.SPRITES.flat, BU.Solar.SPRITES.W, BU.Solar.SPRITES.N }) do
        eq(props[name].IsMoveAble, "true", name)
        eq(props[name].CustomItem, BU.Units.definition("solar").item, name)
    end
    eq(props[BU.panelSprite("N")].CustomItem, BU.PANEL_ITEM)
end)

test("an item without its tile takes its script's", function()
    instanceof = function(_, class) return class == "Moveable" end
    local read
    local item = {
        getWorldSprite = function() return "" end,
        getScriptItem = function() return { getWorldObjectSprite = function() return "bu_solar_01_10" end } end,
        ReadFromWorldSprite = function(_, name) read = name end,
    }
    BU.giveTile(item)
    eq(read, "bu_solar_01_10")
    read = nil
    item.getWorldSprite = function() return "bu_solar_01_10" end
    BU.giveTile(item)
    eq(read, nil, "an item with its tile is left")
end)
