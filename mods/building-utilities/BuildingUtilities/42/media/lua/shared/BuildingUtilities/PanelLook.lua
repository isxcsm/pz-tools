-- How a breaker box looks: its tier's box (BU.PANEL_FIRST, the bu_water_01 sheet, tools/tile_art.py), on a pedestal
-- when it stands outdoors, facing S, E, N or W, its lamps telling its power: off (all dark: no power, or its main
-- switch off), on (the green lamps lit) or tripped (the red one lit, the main switch's handle fallen). A tripped box's
-- red lamp blinks: the client turns it between two frames (client/BuildingUtilities/PanelBlink.lua), and either counts
-- as tripped here. Where the world is decided the box takes the look of its state, its tier and its place as they
-- change (Sync.changed: an upgrade too) and each minute (server/BuildingUtilities/Boxes.lua).
require "BuildingUtilities/Units"
require "BuildingUtilities/Networks"
local BU = BuildingUtilities
local Panels, Networks, Units = BU.Panels, BU.Networks, BU.Units
local PanelLook = {}
BU.PanelLook = PanelLook

local FACINGS = { 1, 2, 3, 4 }
local ORDER = { "off", "on", "tripped", "trippedDark" }

-- A box's kind of look: its tier, and 4 more outdoors.
function PanelLook.variant(tier, outdoor) return (tier or 1) + (outdoor and BU.TIERS or 0) end

-- The sprites: { [variant] = { [look] = { [facing] = name } } }; every sprite a box may stand as; what each shows.
PanelLook.SPRITES = {}
PanelLook.ALL = {}
local LOOK_OF = {}
for _, place in ipairs({ "indoor", "outdoor" }) do
    for tier = 1, BU.TIERS do
        local first, looks = BU.PANEL_FIRST[place][tier], {}
        for index, look in ipairs(ORDER) do looks[look] = Units.sheetSprites(first + (index - 1) * #FACINGS, FACINGS) end
        local variant = PanelLook.variant(tier, place == "outdoor")
        PanelLook.SPRITES[variant] = looks
        for name, shown in pairs(Units.lookOf(looks)) do
            shown.variant, shown.tier = variant, tier
            LOOK_OF[name] = shown
        end
        for _, name in ipairs(Units.lookSprites(looks, ORDER, FACINGS)) do PanelLook.ALL[#PanelLook.ALL + 1] = name end
    end
end

-- What a sprite shows of a box: { look, facing, variant, tier }, or nil for a sprite that is not a box's.
function PanelLook.ofSprite(name) return name and LOOK_OF[name] or nil end

-- What a box shows of its sprite, or nil.
function PanelLook.of(object)
    local sprite = object:getSprite()
    return sprite and LOOK_OF[sprite:getName()] or nil
end

-- The look a box's state calls for: off while power is off in the sandbox; tripped while its breaker is down; off
-- while its main switch is, also with the grid alive (the lamps tell the box's own power, which the switch cuts; the
-- grid still powers the building past the box); on while power reaches it (the grid, or its network supplied), else
-- off.
function PanelLook.wanted(panel)
    if not BU.enabled("power") then return "off" end
    if panel.tripped then return "tripped" end
    if panel.switchedOff then return "off" end
    if getWorld():isHydroPowerOn() then return "on" end
    local state = Networks.state(panel, "power")
    return state and state.supplied and "on" or "off"
end

-- A box takes the look of its state, tier and place, when its square is loaded. Every box's tile blocks the square
-- alike (BlocksPlacement, solidtrans), so the square's flags stay right.
function PanelLook.show(panel, object)
    object = object or Panels.object(panel)
    local shown = object and PanelLook.of(object)
    if not shown then return end
    local look, variant = PanelLook.wanted(panel), PanelLook.variant(panel.tier, panel.outdoor)
    if shown.variant == variant and (shown.look == look or look == "tripped" and shown.look == "trippedDark") then
        return
    end
    Units.setSprite(object, PanelLook.SPRITES[variant][look][shown.facing])
end

-- A tripped box's red lamp, lit or dark (the client's blink).
function PanelLook.blink(object, lit)
    local shown = PanelLook.of(object)
    if shown and (shown.look == "tripped" or shown.look == "trippedDark") then
        local name = PanelLook.SPRITES[shown.variant][lit and "tripped" or "trippedDark"][shown.facing]
        if object:getSprite():getName() ~= name then object:setSprite(getSprite(name)) end
    end
end

return PanelLook
