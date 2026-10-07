-- How a breaker box looks: this mod's console (the bu_water_01 sheet, tools/tile_art.py) facing S, E, N or W, its
-- lamps telling its power: off (all dark: no power, or its main switch off), on (the green and amber lamps lit) or
-- tripped (the red one lit, the main breaker's handle fallen). A tripped box's red lamp blinks: the client turns it
-- between two frames (client/BuildingUtilities/PanelBlink.lua), and either counts as tripped here. Where the world is decided the box
-- takes the look of its state as that changes (Sync.changed) and each minute (server/BuildingUtilities/Boxes.lua); a
-- box of an older save, a vanilla terminal (BU.OLD_PANEL_SPRITES), takes this mod's console the same way.
require "BuildingUtilities/Units"
require "BuildingUtilities/Networks"
local BU = BuildingUtilities
local Panels, Networks, Units = BU.Panels, BU.Networks, BU.Units
local PanelLook = {}
BU.PanelLook = PanelLook

local FACINGS = { 1, 2, 3, 4 }
PanelLook.SPRITES = { off = BU.PANEL_SPRITES, on = Units.sheetSprites(36, FACINGS),
    tripped = Units.sheetSprites(40, FACINGS), trippedDark = Units.sheetSprites(44, FACINGS) }
-- Every sprite a box may stand as, old ones included.
PanelLook.ALL = Units.lookSprites(PanelLook.SPRITES, { "off", "on", "tripped", "trippedDark" }, FACINGS)
local LOOK_OF = Units.lookOf(PanelLook.SPRITES)
for facing, name in ipairs(BU.OLD_PANEL_SPRITES) do
    LOOK_OF[name] = { facing = facing }
    PanelLook.ALL[#PanelLook.ALL + 1] = name
end

-- What a box shows of its sprite: { look (nil for an old one's), facing }, or nil for a sprite that is not a box's.
function PanelLook.of(object)
    local sprite = object:getSprite()
    return sprite and LOOK_OF[sprite:getName()] or nil
end

-- The look a box's state calls for: tripped while its breaker is down; off while its main switch is, also with the
-- grid alive (the lamps tell the box's own power, which the switch cuts; the grid still powers the building past the
-- box); on while power reaches it (the grid, or its network supplied: a sub-panel's is while its main panel's is),
-- else off.
function PanelLook.wanted(panel)
    if panel.tripped then return "tripped" end
    if panel.switchedOff then return "off" end
    if getWorld():isHydroPowerOn() then return "on" end
    local state = Networks.state(panel, "power")
    return state and state.supplied and "on" or "off"
end

-- A box takes the look of its state, when its square is loaded.
function PanelLook.show(panel, object)
    object = object or Panels.object(panel)
    local shown = object and PanelLook.of(object)
    if not shown then return end
    local look = PanelLook.wanted(panel)
    if shown.look == look or look == "tripped" and shown.look == "trippedDark" then return end
    if not shown.look then
        -- An old box: the console faces as the terminal did, and is its sprite from now on. Both block the square
        -- alike (BlocksPlacement, solidtrans), so the square's flags stay right.
        BU.log("the box of", panel.id, "takes the console's look")
        panel.sprite = BU.PANEL_SPRITES[shown.facing]
    end
    Units.setSprite(object, PanelLook.SPRITES[look][shown.facing])
end

-- A tripped box's red lamp, lit or dark (the client's blink).
function PanelLook.blink(object, lit)
    local shown = PanelLook.of(object)
    if shown and (shown.look == "tripped" or shown.look == "trippedDark") then
        local name = PanelLook.SPRITES[lit and "tripped" or "trippedDark"][shown.facing]
        if object:getSprite():getName() ~= name then object:setSprite(getSprite(name)) end
    end
end

return PanelLook
