-- The solar panel (a unit, BU.Units): outside under the sky, on the ground or a flat roof. What it makes is worked out
-- in BU.Energy; snow on it there too.
require "BuildingUtilities/Units"
require "BuildingUtilities/Energy"
local BU = BuildingUtilities
local Units, Energy = BU.Units, BU.Energy
local Solar = {}
BU.Solar = Solar

-- On the ground it stands on a frame facing W or N; on a roof it lies flat.
Solar.SPRITES = { flat = "bu_solar_01_8", W = "bu_solar_01_9", N = "bu_solar_01_10" }
-- Snow on it shows over it (an overlay): light from a trace (Energy.SNOW_TRACE), heavy from HEAVY_SNOW.
local SHAPES = { "flat", "W", "N" }
Solar.SNOW_OVERLAYS = { light = Units.sheetSprites(48, SHAPES), heavy = Units.sheetSprites(51, SHAPES) }
Solar.HEAVY_SNOW = 0.5
local SHAPE = {}
for shape, name in pairs(Solar.SPRITES) do SHAPE[name] = shape end

-- The overlay a panel shows for its snow, or nil.
function Solar.snowOverlay(unit, object)
    local sprite = object:getSprite()
    local shape = sprite and SHAPE[sprite:getName()]
    local snow = unit.snow or 0
    if not shape or snow < Energy.SNOW_TRACE then return nil end
    return Solar.SNOW_OVERLAYS[snow >= Solar.HEAVY_SNOW and "heavy" or "light"][shape]
end

function Solar.show(unit, object) Units.setOverlay(object, Solar.snowOverlay(unit, object)) end

Units.define("solar", {
    item = "BuildingUtilities.SolarPanel",
    sprites = { Solar.SPRITES.flat, Solar.SPRITES.W, Solar.SPRITES.N },
    utility = "power",
    colour = { 1, 1, 0.55 },
    canPlace = function(square)
        if not square:isOutside() then return nil, "notOutside" end
        return true
    end,
    -- Above the ground it lies flat; on the ground its frame faces a side: west and east as one, north and south.
    sprite = function(square, side)
        if square and square:getZ() > 0 then return Solar.SPRITES.flat end
        return (side == "E" or side == "W") and Solar.SPRITES.W or Solar.SPRITES.N
    end,
    -- Its snow, as its square loads (on the server) and each minute.
    onLoad = function(unit, object)
        if not isClient() then Solar.show(unit, object) end
    end,
    sync = Solar.show,
    title = function(unit, text)
        if (unit.snow or 0) < Energy.SNOW_TRACE then return text end
        return text .. "  " .. getText("IGUI_BU_SolarSnow", BU.percent(unit.snow * 100))
    end,
    options = function(unit)
        if (unit.snow or 0) <= 0 then return {} end
        return { { text = getText("ContextMenu_BU_ClearSnow"),
            action = function(character, target) return ISBUClearSnow:new(character, target) end } }
    end,
})

return Solar
