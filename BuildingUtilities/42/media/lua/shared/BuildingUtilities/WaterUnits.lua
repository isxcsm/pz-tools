-- The water units (BU.Units, utility "water"), each wired to a main panel and working for one of its water groups
-- (BU.Water): the pump fills the group's tanks from a river, a lake or a well beside it while the panel has power
-- (it goes anywhere, but without water beside it it runs dry: it draws its power and lifts nothing); the
-- sprinkler waters the crops around it from the group; the filter purifies the group's water while the
-- RiskPlumbingUnpurified option leaves the pipes unpurified. What they do each minute is the server's
-- (server/BuildingUtilities/WaterRun.lua); their art is the bu_water_01 sheet (tools/water_art.py).
require "BuildingUtilities/Units"
require "BuildingUtilities/Water"
local BU = BuildingUtilities
local Units, Water, Store = BU.Units, BU.Water, BU.Store
local WaterUnits = {}
BU.WaterUnits = WaterUnits

-- The pump stands beside the water, its suction on that side.
WaterUnits.PUMP_SPRITES = { E = "bu_water_01_0", S = "bu_water_01_1", W = "bu_water_01_2", N = "bu_water_01_3" }
WaterUnits.SPRINKLER_SPRITES = { idle = "bu_water_01_4", spraying = "bu_water_01_5" }
-- The filter's pipe runs W-E or N-S.
WaterUnits.FILTER_SPRITES = { across = "bu_water_01_6", along = "bu_water_01_7" }
-- Litres a pump lifts an hour, and the load it puts on its panel's power while it runs.
WaterUnits.PUMP_RATE = 20
WaterUnits.PUMP_LOAD = 0.12
-- Squares around a sprinkler it waters (5 by 5), and the litres one use of a watering can gives a plant (+10 water).
WaterUnits.SPRINKLER_RADIUS = 2
WaterUnits.LITRES_PER_USE = ((ZomboidGlobals and ZomboidGlobals.farmingFluidContainerMillilitresPerUse) or 200) / 1000
-- How long a sprinkler shows its spray after it watered: about the ten minutes to its next look.
WaterUnits.SPRAY_HOURS = 0.2
-- Hours of use a charge of filter media lasts (while the pipes do not purify), and what a charge takes.
WaterUnits.FILTER_HOURS = 24 * 30
WaterUnits.MEDIA = { { type = "Base.Charcoal", count = 2 }, { type = "Base.RippedSheets", count = 1 } }
WaterUnits.TIER = 2

-- Whether the pipes leave water as its tanks hold it (the RiskPlumbingUnpurified option): then only a filter
-- purifies a group's water.
function WaterUnits.unpurifiedPipes() return BU.sandbox("RiskPlumbingUnpurified", false) == true end

-- The group a unit works for: its own, while its panel still has it, else the first.
function WaterUnits.group(unit)
    local panel = Store.get(unit.panel)
    if unit.group and panel and Water.group(panel, unit.group) then return unit.group end
    return Water.FIRST
end

-- The water beside a square and the side it is on: "Water" from a well (clean, as the game's wells), "TaintedWater"
-- from a river or lake; nil when there is none.
local SIDES = { { 1, 0, "E" }, { 0, 1, "S" }, { -1, 0, "W" }, { 0, -1, "N" } }
function WaterUnits.waterBeside(square)
    local cell = getCell()
    for _, side in ipairs(SIDES) do
        local other = cell:getGridSquare(square:getX() + side[1], square:getY() + side[2], square:getZ())
        if other then
            local objects = other:getObjects()
            for i = 0, objects:size() - 1 do
                local properties = objects:get(i):getProperties()
                if properties and properties:has("waterAmount") then return "Water", side[3] end
            end
            local properties = other:getProperties()
            if properties and properties:has(IsoFlagType.water) then return "TaintedWater", side[3] end
        end
    end
    return nil
end

Units.define("pump", {
    item = "BuildingUtilities.WaterPump",
    sprites = { WaterUnits.PUMP_SPRITES.E, WaterUnits.PUMP_SPRITES.S, WaterUnits.PUMP_SPRITES.W, WaterUnits.PUMP_SPRITES.N },
    utility = "water",
    minTier = WaterUnits.TIER,
    tierReason = "waterUnitTier",
    colour = { 0.35, 0.6, 1 },
    canPlace = function() return true end,
    -- Its suction on the water's side; without water, on the side away from the character.
    sprite = function(square, character)
        local _, side = WaterUnits.waterBeside(square)
        if not side then
            local dx, dy = square:getX() + 0.5 - character:getX(), square:getY() + 0.5 - character:getY()
            if math.abs(dx) > math.abs(dy) then side = dx > 0 and "E" or "W" else side = dy > 0 and "S" or "N" end
        end
        return WaterUnits.PUMP_SPRITES[side]
    end,
    -- The water it lifts; nil while there is none beside it (the server looks again while its square is loaded).
    create = function(unit, object)
        unit.fluid = WaterUnits.waterBeside(object:getSquare())
    end,
    title = function(unit, text)
        return text .. "  " .. getText(unit.running and "IGUI_BU_PumpRunning" or "IGUI_BU_PumpStopped")
    end,
    -- What it lifts runs to the box's tanks.
    flow = function(unit) return unit.running and unit.fluid and 1 or nil end,
})

Units.define("sprinkler", {
    item = "BuildingUtilities.Sprinkler",
    sprites = { WaterUnits.SPRINKLER_SPRITES.idle, WaterUnits.SPRINKLER_SPRITES.spraying },
    utility = "water",
    minTier = WaterUnits.TIER,
    tierReason = "waterUnitTier",
    colour = { 0.45, 0.85, 0.55 },
    canPlace = function(square)
        if not square:isOutside() then return nil, "notOutside" end
        return true
    end,
    sprite = function() return WaterUnits.SPRINKLER_SPRITES.idle end,
    -- It shows its spray for a while after it watered.
    sync = function(unit, object)
        local spraying = unit.sprayedAt and getGameTime():getWorldAgeHours() - unit.sprayedAt < WaterUnits.SPRAY_HOURS
        local sprite = spraying and WaterUnits.SPRINKLER_SPRITES.spraying or WaterUnits.SPRINKLER_SPRITES.idle
        if object:getSprite() and object:getSprite():getName() ~= sprite then
            object:setSprite(getSprite(sprite))
            if isServer() then object:transmitUpdatedSpriteToClients() end
        end
    end,
    flow = function(unit)
        local recent = unit.sprayedAt and getGameTime():getWorldAgeHours() - unit.sprayedAt < WaterUnits.SPRAY_HOURS
        return recent and -1 or nil
    end,
})

-- How much of its media a filter has left, 0 to 1.
function WaterUnits.mediaLeft(unit) return math.max(0, math.min(1, (unit.media or 0) / WaterUnits.FILTER_HOURS)) end

-- Whether a character carries what a charge of filter media takes.
function WaterUnits.hasMedia(character)
    local inventory = character:getInventory()
    for _, need in ipairs(WaterUnits.MEDIA) do
        if inventory:getCountTypeRecurse(need.type) < need.count then return false end
    end
    return true
end

Units.define("filter", {
    item = "BuildingUtilities.WaterFilter",
    sprites = { WaterUnits.FILTER_SPRITES.across, WaterUnits.FILTER_SPRITES.along },
    utility = "water",
    minTier = WaterUnits.TIER,
    tierReason = "waterUnitTier",
    colour = { 0.85, 0.9, 1 },
    canPlace = function() return true end,
    -- Its pipe runs across the character's view.
    sprite = function(square, character)
        local dx, dy = character:getX() - (square:getX() + 0.5), character:getY() - (square:getY() + 0.5)
        return math.abs(dx) > math.abs(dy) and WaterUnits.FILTER_SPRITES.along or WaterUnits.FILTER_SPRITES.across
    end,
    -- Put down with a fresh charge.
    create = function(unit) unit.media = WaterUnits.FILTER_HOURS end,
    title = function(unit, text)
        return text .. "  " .. getText("IGUI_BU_FilterMedia", BU.percent(WaterUnits.mediaLeft(unit) * 100))
    end,
    options = function(unit, character)
        local entry = { text = getText("ContextMenu_BU_ReplaceMedia"),
            action = function(character, target) return ISBUReplaceMedia:new(character, target) end }
        if WaterUnits.mediaLeft(unit) >= 1 then entry.reason = getText("IGUI_BU_Reason_mediaFull")
        elseif not WaterUnits.hasMedia(character) then entry.reason = getText("IGUI_BU_Reason_noMedia") end
        return { entry }
    end,
})

return WaterUnits
