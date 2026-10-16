-- Light from this mod's things at night, by what their lamps show (the look of their sprite): a breaker box's green
-- lamps while power reaches it and its red one while tripped, a pump's, a booster's and a filter's lamp (green at work,
-- amber running dry, red with a spent filter), a battery rack's charge lights while it holds batteries. A solar panel
-- and a sprinkler have none. A game light source on the thing's square (the cell's lamppost list), only where the game
-- draws. The game saves none and drops one whose square leaves the loaded area (LightingJNI.checkLights): a thing sets
-- its light as its square loads and as it takes a look (Units.setSprite, Rack.show), and the things near a player set
-- theirs again each game minute (BU.Nearby: a thing already lit costs a look in the cell's list). A light goes with its
-- thing (OnObjectAboutToBeRemoved).
require "BuildingUtilities/Units"
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/WaterUnits"
require "BuildingUtilities/Rack"
require "BuildingUtilities/Nearby"
local BU = BuildingUtilities
local Lights = {}
BU.Lights = Lights

-- An indicator lamp's glow: faint, on its own square only, so the thing shows in the dark without colouring the room.
local GREEN = { 0.11, 0.18, 0.11, 1 }
local RED = { 0.22, 0.08, 0.07, 1 }
local AMBER = { 0.20, 0.15, 0.07, 1 }
local RACK = { 0.09, 0.14, 0.20, 1 }

-- The light of each sprite that has one, worked out once the looks are defined (the first time it is asked).
local bySprite
local function spriteLights()
    if bySprite then return bySprite end
    bySprite = {}
    local function give(sprites, spec)
        for _, name in pairs(sprites or {}) do bySprite[name] = spec end
    end
    for _, look in pairs(BU.PanelLook and BU.PanelLook.SPRITES or {}) do
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

-- verify: also look that the game still has the light it was given (it drops one as its square leaves the loaded area).
local function set(object, spec, verify)
    local square = object:getSquare()
    local cell = getCell and getCell()
    if not (square and cell and cell.addLamppost) then return end
    local key = keyOf(square)
    local entry = lit[key]
    if entry and spec and entry.spec == spec and entry.object == object
        and not (verify and not cell:getLamppostPositions():contains(entry.source)) then
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
function Lights.refresh(object, verify)
    if isServer() or not object then return end
    set(object, Lights.of(object), verify)
end

-- Each loaded box and unit near a player sets its light again.
function Lights.everyMinute()
    local players = BU.Nearby.players()
    local _, panels = BU.Nearby.hotPanels(players)
    for _, panel in ipairs(panels) do
        local object = BU.Panels.object(panel)
        if object then Lights.refresh(object, true) end
    end
    for _, unit in ipairs(BU.Nearby.units(players)) do
        local object = BU.Units.object(unit)
        if object then Lights.refresh(object, true) end
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
    -- A square loads: what stands on it lights as it should (a thing's square may load without it taking a look).
    local function onLoad(object) Lights.refresh(object) end
    for sprite in pairs(spriteLights()) do MapObjects.OnLoadWithSprite(sprite, onLoad, 5) end
    for _, sprite in ipairs(BU.Units.definition("rack").sprites) do MapObjects.OnLoadWithSprite(sprite, onLoad, 5) end
end

return Lights
