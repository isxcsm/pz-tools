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

Units.define("solar", {
    item = "BuildingUtilities.SolarPanel",
    sprites = { Solar.SPRITES.flat, Solar.SPRITES.W, Solar.SPRITES.N },
    utility = "power",
    colour = { 1, 1, 0.55 },
    canPlace = function(square)
        if not square:isOutside() then return nil, "notOutside" end
        return true
    end,
    -- Above the ground it lies flat; on the ground its frame faces the side the character stands on more.
    sprite = function(square, character)
        if square:getZ() > 0 then return Solar.SPRITES.flat end
        local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
        return math.abs(dx) > math.abs(dy) and Solar.SPRITES.W or Solar.SPRITES.N
    end,
    title = function(unit, text)
        if (unit.snow or 0) < Energy.SNOW_TRACE then return text end
        return text .. "  " .. getText("IGUI_BU_SolarSnow", BU.percent(unit.snow * 100))
    end,
    -- What it makes runs to the box while the source carries the load or a bank takes it (bankFlow: nil without one).
    flow = function(unit, panel, state)
        if Energy.panelOutput(unit) <= 0 then return nil end
        local carrying = Energy.inUse(state) and state.supplied
        if carrying or (panel.bankFlow or 0) > 0.0005 then return 1 end
        return nil
    end,
    options = function(unit)
        if (unit.snow or 0) <= 0 then return {} end
        return { { text = getText("ContextMenu_BU_ClearSnow"),
            action = function(character, target) return ISBUClearSnow:new(character, target) end } }
    end,
})

return Solar
