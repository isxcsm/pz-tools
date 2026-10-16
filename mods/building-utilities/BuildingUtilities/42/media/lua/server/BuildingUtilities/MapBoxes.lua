-- The map's generators get their spawned boxes (BU.Spawned), where the world is decided: the server, or the game alone.
-- The game turns a map's generator tile into a generator as its chunk loads the first time (MOGenerator.lua): this
-- hears the tile first and keeps its square, and the box is put down on the next tick, once the chunk's squares are
-- all there. The game keeps one function for a sprite at a priority, one given at the same priority replacing it, and
-- calls the higher first, each while the tile stays: this one is above the game's (5), at a number no other is likely
-- to take.
require "BuildingUtilities/Spawned"
local BU = BuildingUtilities

if isClient() then return end

local PRIORITY = 47
local pending, ticking = {}, false

local function onTick()
    local cell = getCell()
    for _, at in ipairs(pending) do
        local square = cell and cell:getGridSquare(at[1], at[2], at[3])
        if square then
            local ok, err = pcall(BU.Spawned.beside, square)
            if not ok then BU.log("a spawned box:", err) end
        end
    end
    pending = {}
    ticking = false
    Events.OnTick.Remove(onTick)
end

local function onGenerator(object)
    local square = object:getSquare()
    if not square or BU.Spawned.chance() <= 0 then return end
    pending[#pending + 1] = { square:getX(), square:getY(), square:getZ() }
    if not ticking then
        ticking = true
        Events.OnTick.Add(onTick)
    end
end

for index = 0, 15 do MapObjects.OnNewWithSprite("appliances_misc_01_" .. index, onGenerator, PRIORITY) end
