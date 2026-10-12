-- The water units (BU.Units, utility "water"), each wired to a main panel and working for one of its water groups
-- (BU.Water): the pump fills the group's tanks from a river, a lake or a well beside it while the panel has power
-- (it goes anywhere, but without water beside it it runs dry: it draws its power and lifts nothing); the
-- sprinkler waters the crops around it from the group; the filter purifies the group's water while the
-- RiskPlumbingUnpurified option leaves the pipes unpurified; the booster pump lifts the group's water from its floor
-- to the floors above it (BU.Water.boostPlan). What they do each minute is the server's
-- (server/BuildingUtilities/WaterRun.lua); their art is the bu_water_01 sheet (tools/tile_art.py), a lamp on each
-- telling how it runs.
require "BuildingUtilities/Units"
require "BuildingUtilities/Water"
local BU = BuildingUtilities
local Units, Water, Store = BU.Units, BU.Water, BU.Store
local WaterUnits = {}
BU.WaterUnits = WaterUnits

-- The pump stands beside the water, its suction on that side; put down stopped. Its lamp: dark stopped, green running,
-- amber running dry (no water beside it); under rime while its box's pipes are frozen (WaterUnits.pumpLook).
local PUMP_SIDES, PUMP_ORDER = { "E", "S", "W", "N" }, { "stopped", "running", "dry", "frozen" }
WaterUnits.PUMP_SPRITES = Units.sheetSprites(0, PUMP_SIDES)
WaterUnits.PUMP_LOOKS = { stopped = WaterUnits.PUMP_SPRITES, running = Units.sheetSprites(16, PUMP_SIDES),
    dry = Units.sheetSprites(20, PUMP_SIDES), frozen = Units.sheetSprites(24, PUMP_SIDES) }
local PUMP_LOOK_OF = Units.lookOf(WaterUnits.PUMP_LOOKS)
-- A spraying sprinkler's head goes round: its frames in turn (client/BuildingUtilities/SprinklerSpray.lua).
WaterUnits.SPRINKLER_SPRITES = { idle = "bu_water_01_4", spraying = { "bu_water_01_5", "bu_water_01_8", "bu_water_01_9",
    "bu_water_01_10", "bu_water_01_11", "bu_water_01_12", "bu_water_01_13", "bu_water_01_14" } }
local SPRAY_FRAME = {}
for _, name in ipairs(WaterUnits.SPRINKLER_SPRITES.spraying) do SPRAY_FRAME[name] = true end
-- The filter's pipe runs W-E (across) or N-S (along); put down resting. Its lamp: dark resting, green working, red
-- with its media spent (WaterUnits.filterLook).
local FILTER_WAYS, FILTER_ORDER = { "across", "along" }, { "resting", "working", "spent" }
WaterUnits.FILTER_SPRITES = Units.sheetSprites(6, FILTER_WAYS)
WaterUnits.FILTER_LOOKS = { resting = WaterUnits.FILTER_SPRITES, working = Units.sheetSprites(28, FILTER_WAYS),
    spent = Units.sheetSprites(30, FILTER_WAYS) }
local FILTER_LOOK_OF = Units.lookOf(WaterUnits.FILTER_LOOKS)
-- The booster pump faces the character who put it down (its control box in front); put down stopped. Its lamp: dark
-- stopped, green boosting, amber with power but no water reaching its floor; under rime while its box's pipes are
-- frozen (WaterUnits.boosterLook).
local BOOSTER_SIDES, BOOSTER_ORDER = { "S", "E", "N", "W" }, { "stopped", "running", "dry", "frozen" }
WaterUnits.BOOSTER_SPRITES = Units.sheetSprites(56, BOOSTER_SIDES)
WaterUnits.BOOSTER_LOOKS = { stopped = WaterUnits.BOOSTER_SPRITES, running = Units.sheetSprites(60, BOOSTER_SIDES),
    dry = Units.sheetSprites(64, BOOSTER_SIDES), frozen = Units.sheetSprites(68, BOOSTER_SIDES) }
local BOOSTER_LOOK_OF = Units.lookOf(WaterUnits.BOOSTER_LOOKS)
-- The load a booster puts on its panel's power while it lifts.
WaterUnits.BOOSTER_LOAD = 0.25
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

-- Whether a sprinkler sprays now: it watered within the last SPRAY_HOURS.
function WaterUnits.spraying(unit)
    return unit.sprayedAt ~= nil and getGameTime():getWorldAgeHours() - unit.sprayedAt < WaterUnits.SPRAY_HOURS
end

-- Whether a sprite is one of a spraying sprinkler's frames.
function WaterUnits.isSprayFrame(name) return SPRAY_FRAME[name] == true end

-- How a pump looks: frozen while its box's pipes are (with water on), else running (lifting), dry (running with no
-- water beside it) or stopped.
function WaterUnits.pumpLook(unit)
    local panel = Store.get(unit.panel)
    if panel and panel.water.frozen and BU.enabled("water") then return "frozen" end
    if unit.running then return unit.fluid and "running" or "dry" end
    return "stopped"
end

-- How a booster looks: frozen while its box's pipes are (with water on), else running (lifting), dry (its power on
-- but no water reaching its floor) or stopped.
function WaterUnits.boosterLook(unit)
    local panel = Store.get(unit.panel)
    if panel and panel.water.frozen and BU.enabled("water") then return "frozen" end
    if unit.boosting then return "running" end
    if unit.idle == "noWater" then return "dry" end
    return "stopped"
end

-- How a filter looks: spent without media, working while it purifies its group's water (WaterRun.filters), else
-- resting.
function WaterUnits.filterLook(unit)
    if (unit.media or 0) <= 0 then return "spent" end
    if unit.working and unit.panel then return "working" end
    return "resting"
end

-- Whether the pipes leave water as its tanks hold it (the RiskPlumbingUnpurified option, in a game whose API can:
-- BU.purifyAvailable): then only a filter purifies a group's water.
function WaterUnits.unpurifiedPipes()
    return BU.sandbox("RiskPlumbingUnpurified", false) == true and BU.purifyAvailable()
end

-- The group a unit works for: its own, while its panel still has it, else the first.
function WaterUnits.group(unit)
    local panel = Store.get(unit.panel)
    if unit.group and panel and Water.group(panel, unit.group) then return unit.group end
    return Water.FIRST
end

-- The side across a square from a side.
local OPPOSITE = { E = "W", W = "E", N = "S", S = "N" }

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
    sprites = Units.lookSprites(WaterUnits.PUMP_LOOKS, PUMP_ORDER, PUMP_SIDES),
    utility = "water",
    minTier = WaterUnits.TIER,
    tierReason = "waterUnitTier",
    colour = { 0.35, 0.6, 1 },
    canPlace = function() return true end,
    -- Its suction on the water's side; without water, on the side away from the one it faces.
    sprite = function(square, side)
        local _, water = WaterUnits.waterBeside(square)
        return WaterUnits.PUMP_SPRITES[water or OPPOSITE[side]]
    end,
    -- The water it lifts; nil while there is none beside it (the server looks again while its square is loaded).
    create = function(unit, object)
        unit.fluid = WaterUnits.waterBeside(object:getSquare())
    end,
    sync = function(unit, object) Units.showLook(object, WaterUnits.PUMP_LOOKS, WaterUnits.pumpLook(unit), PUMP_LOOK_OF) end,
    title = function(unit, text)
        return text .. "  " .. getText(unit.running and "IGUI_BU_PumpRunning" or "IGUI_BU_PumpStopped")
    end,
})

local sprinklerSprites = { WaterUnits.SPRINKLER_SPRITES.idle }
for _, name in ipairs(WaterUnits.SPRINKLER_SPRITES.spraying) do sprinklerSprites[#sprinklerSprites + 1] = name end
Units.define("sprinkler", {
    item = "BuildingUtilities.Sprinkler",
    sprites = sprinklerSprites,
    utility = "water",
    minTier = WaterUnits.TIER,
    tierReason = "waterUnitTier",
    colour = { 0.45, 0.85, 0.55 },
    canPlace = function(square)
        if not square:isOutside() then return nil, "notOutside" end
        return true
    end,
    sprite = function() return WaterUnits.SPRINKLER_SPRITES.idle end,
    -- It shows its spray for a while after it watered: any of the frames the client turns it through.
    sync = function(unit, object)
        local current = object:getSprite() and object:getSprite():getName()
        if not current then return end
        local spraying = WaterUnits.spraying(unit)
        if spraying == WaterUnits.isSprayFrame(current) then return end
        Units.setSprite(object, spraying and WaterUnits.SPRINKLER_SPRITES.spraying[1] or WaterUnits.SPRINKLER_SPRITES.idle)
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
    sprites = Units.lookSprites(WaterUnits.FILTER_LOOKS, FILTER_ORDER, FILTER_WAYS),
    utility = "water",
    minTier = WaterUnits.TIER,
    tierReason = "waterUnitTier",
    colour = { 0.85, 0.9, 1 },
    canPlace = function() return true end,
    -- Its pipe runs across the side it faces.
    sprite = function(square, side)
        return (side == "E" or side == "W") and WaterUnits.FILTER_SPRITES.along or WaterUnits.FILTER_SPRITES.across
    end,
    -- Put down with a fresh charge.
    create = function(unit) unit.media = WaterUnits.FILTER_HOURS end,
    sync = function(unit, object)
        Units.showLook(object, WaterUnits.FILTER_LOOKS, WaterUnits.filterLook(unit), FILTER_LOOK_OF)
    end,
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

Units.define("booster", {
    item = "BuildingUtilities.BoosterPump",
    sprites = Units.lookSprites(WaterUnits.BOOSTER_LOOKS, BOOSTER_ORDER, BOOSTER_SIDES),
    utility = "water",
    minTier = WaterUnits.TIER,
    tierReason = "waterUnitTier",
    colour = { 0.3, 0.75, 0.95 },
    canPlace = function() return true end,
    -- Its front to the side it faces.
    sprite = function(square, side) return WaterUnits.BOOSTER_SPRITES[side] end,
    sync = function(unit, object)
        Units.showLook(object, WaterUnits.BOOSTER_LOOKS, WaterUnits.boosterLook(unit), BOOSTER_LOOK_OF)
    end,
    title = function(unit, text)
        return text .. "  " .. getText(unit.boosting and "IGUI_BU_PumpRunning" or "IGUI_BU_PumpStopped")
    end,
})

return WaterUnits
