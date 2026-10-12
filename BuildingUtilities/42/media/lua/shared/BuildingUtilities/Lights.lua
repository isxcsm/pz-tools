-- Light from this mod's things at night, by what their lamps show (the look of their sprite): a breaker box's green
-- lamps while power reaches it and its red one while tripped, a pump's, a booster's and a filter's lamp (green at work,
-- amber running dry, red with a spent filter), a battery rack's charge lights while it holds batteries. A solar panel
-- and a sprinkler have none. A game light source on the thing's square (the cell's lamppost list), only where the game
-- draws. The game saves none and drops one whose square leaves the loaded area (LightingJNI.checkLights): a thing sets
-- its light as it takes a look (Units.setSprite, Rack.show), and the loaded things set theirs again each game minute
-- (a few lookups; setting the light a thing already has costs a look in that list). A light goes with its thing
-- (OnObjectAboutToBeRemoved).
require "BuildingUtilities/Units"
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/WaterUnits"
require "BuildingUtilities/Rack"
local BU = BuildingUtilities
local Lights = {}
BU.Lights = Lights

local GREEN = { 0.35, 0.65, 0.30, 2 }
local RED = { 0.85, 0.18, 0.12, 2 }
local AMBER = { 0.75, 0.50, 0.12, 2 }
local RACK = { 0.25, 0.50, 0.75, 2 }

-- The light of each sprite that has one, worked out once the looks are defined (the first time it is asked).
local bySprite
local function spriteLights()
    if bySprite then return bySprite end
    bySprite = {}
    local function give(sprites, spec)
        for _, name in pairs(sprites or {}) do bySprite[name] = spec end
    end
    local look = BU.PanelLook and BU.PanelLook.SPRITES
    if look then
        give(look.on, GREEN)
        give(look.tripped, RED)
        give(look.trippedDark, RED)
    end
    local water = BU.WaterUnits
    if water then
        give(water.PUMP_LOOKS.running, GREEN)
        give(water.PUMP_LOOKS.dry, AMBER)
        give(water.BOOSTER_LOOKS.running, GREEN)
        give(water.BOOSTER_LOOKS.dry, AMBER)
        give(water.FILTER_LOOKS.working, GREEN)
        give(water.FILTER_LOOKS.spent, RED)
    end
    return bySprite
end

-- "x,y,z" -> { source, object, spec }; how many there are (the removal handler returns at once while none).
local lit, count = {}, 0

local function keyOf(square)
    return square:getX() .. "," .. square:getY() .. "," .. square:getZ()
end

local function drop(key)
    local entry = lit[key]
    if not entry then return end
    lit[key] = nil
    count = count - 1
    local cell = getCell and getCell()
    if cell then cell:removeLamppost(entry.source) end
end

local function set(object, spec)
    local square = object:getSquare()
    local cell = getCell and getCell()
    if not (square and cell and cell.addLamppost) then return end
    local key = keyOf(square)
    local entry = lit[key]
    if entry and spec and entry.spec == spec and entry.object == object
        and cell:getLamppostPositions():contains(entry.source) then
        return
    end
    drop(key)
    if not spec then return end
    local source = cell:addLamppost(square:getX(), square:getY(), square:getZ(), spec[1], spec[2], spec[3], spec[4])
    lit[key] = { source = source, object = object, spec = spec }
    count = count + 1
end

-- The light an object of this mod gives off now: by its sprite, or a rack's by its batteries; nil for none.
function Lights.of(object)
    local unit = BU.Units.ofObject(object)
    if unit and unit.kind == "rack" then return #(unit.batteries or {}) > 0 and RACK or nil end
    local sprite = object:getSprite()
    return sprite and spriteLights()[sprite:getName()] or nil
end

-- The object gives off the light its state calls for (where the game draws).
function Lights.refresh(object)
    if isServer() or not object then return end
    set(object, Lights.of(object))
end

-- Each loaded box and unit sets its light again.
function Lights.everyMinute()
    for _, panel in pairs(BU.Store.panels() or {}) do
        local object = BU.Panels.object(panel)
        if object then Lights.refresh(object) end
    end
    for _, unit in pairs(BU.Store.units() or {}) do
        local object = BU.Units.object(unit)
        if object then Lights.refresh(object) end
    end
end

function Lights.onRemoved(object)
    if count == 0 or not object then return end
    local square = object:getSquare()
    if not square then return end
    local key = keyOf(square)
    local entry = lit[key]
    if entry and entry.object == object then drop(key) end
end

-- A thing that takes a look takes its light with it.
local setSprite = BU.Units.setSprite
function BU.Units.setSprite(object, name)
    setSprite(object, name)
    Lights.refresh(object)
end

-- A rack shows its batteries (its overlay): its light follows.
local rackShow = BU.Rack.show
function BU.Rack.show(unit, object)
    rackShow(unit, object)
    Lights.refresh(object or BU.Units.object(unit))
end

if not isServer() then
    Events.OnObjectAboutToBeRemoved.Add(Lights.onRemoved)
    Events.EveryOneMinute.Add(Lights.everyMinute)
end

return Lights
