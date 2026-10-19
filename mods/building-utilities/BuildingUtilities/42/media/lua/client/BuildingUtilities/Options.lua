-- The mod's section in the game's mod options (B42 PZAPI.ModOptions): how the mod looks to the player, nothing of how
-- it works.
--   BU_FloorLines: the lines laid to the devices outside drawn on the ground (FloorLines). On unless switched off.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Options = {}
BU.Options = Options

Options.FLOOR_LINES = "BU_FloorLines"

local function section()
    if not (PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create) then return nil end
    return PZAPI.ModOptions:getOptions(BU.MOD) or PZAPI.ModOptions:create(BU.MOD, getText("IGUI_BU_OptionsTitle"))
end

-- Whether the lines on the ground are drawn.
function Options.floorLinesShown()
    local options = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions(BU.MOD)
    local option = options and options:getOption(Options.FLOOR_LINES)
    if option and option.getValue then return option:getValue() ~= false end
    return true
end

local function make()
    local options = section()
    if not options then return end
    local option = options:addTickBox(Options.FLOOR_LINES, getText("IGUI_BU_OptionFloorLines"), true,
        getText("IGUI_BU_OptionFloorLinesTip"))
    -- (switched in the options screen: the ground shows it at once)
    option.onChangeApply = function(_, value)
        if BU.FloorLines then BU.FloorLines.setShown(value) end
    end
end

make()

return Options
