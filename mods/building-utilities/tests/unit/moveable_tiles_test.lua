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
    eq(props[BU.panelSprite("W", 3)].CustomItem, BU.PANEL_ITEMS[3], "a tier's box gives its tier's item")
    eq(props[BU.PanelLook.SPRITES[BU.PanelLook.variant(4, true)].tripped[2]].CustomItem, BU.PANEL_ITEMS[4],
        "outdoors and in any look")
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

test("a filter's spent media goes with its item and comes back when put down", function()
    getItemNameFromFullType = function() return "Water Filter" end
    local Units, hours = BU.Units, BU.WaterUnits.FILTER_HOURS
    local function newItem()
        local item = { modData = {} }
        item.getModData = function() return item.modData end
        item.getFullType = function() return "BuildingUtilities.WaterFilter" end
        item.setName = function(_, name) item.name = name end
        item.setCustomName = function(_, on) item.custom = on end
        return item
    end
    local filter = Units.definition("filter")
    local unit = { kind = "filter" }
    filter.create(unit, nil, nil)
    eq(unit.media, hours, "a new filter: a full charge")
    eq(Units.keep(unit), nil, "a full charge: nothing to carry")
    local item = newItem()
    Units.keepOnItem("filter", item, Units.keep(unit))
    eq(item.name, nil, "a full one keeps its name")
    eq(Units.keptOnItem(item), nil)

    unit.media = hours * 0.25
    item = newItem()
    Units.keepOnItem("filter", item, Units.keep(unit))
    eq(Units.keptOnItem(item).media, hours * 0.25)
    eq(item.name, "Water Filter (IGUI_BU_FilterMedia 25%)")
    eq(item.custom, true)
    local placed = { kind = "filter" }
    filter.create(placed, nil, Units.keptOnItem(item))
    eq(placed.media, hours * 0.25, "put down with what it carried")

    filter.create(placed, nil, { media = hours * 5 })
    eq(placed.media, hours, "never above a charge")
    item.modData[Units.KEPT] = "junk"
    eq(Units.keptOnItem(item), nil, "what is not a table is nothing")
end)
