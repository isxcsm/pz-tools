-- The map's generators get their spawned boxes (BU.Spawned), where the world is decided: the server, or the game alone.
-- The game turns a map's generator tile into a generator as its chunk loads the first time (MOGenerator.lua): this
-- hears the tile first and keeps its square, and the box is put down on a later tick, once the squares around the
-- generator are all there: one at a chunk's edge waits for the chunk beside to load (at most WAIT_TICKS; the map's
-- edge has none). A square that is gone again before is let go. The game keeps one function for a sprite at a
-- priority, one given at the same priority replacing it, and calls the higher first, each while the tile stays: this
-- one is above the game's (5), at a number no other is likely to take.
require "BuildingUtilities/Spawned"
local BU = BuildingUtilities

if isClient() then return end

local PRIORITY = 47
local WAIT_TICKS = 600
local pending, ticking = {}, false

-- Whether the squares around are all loaded.
local function surrounded(cell, x, y, z)
    for dx = -1, 1 do
        for dy = -1, 1 do
            if not cell:getGridSquare(x + dx, y + dy, z) then return false end
        end
    end
    return true
end

local function onTick()
    local cell = getCell()
    local waiting = {}
    for _, at in ipairs(pending) do
        local square = cell and cell:getGridSquare(at[1], at[2], at[3])
        if square then
            at[4] = at[4] + 1
            if at[4] >= WAIT_TICKS or surrounded(cell, at[1], at[2], at[3]) then
                local ok, err = pcall(BU.Spawned.beside, square)
                if not ok then BU.log("a spawned box:", err) end
            else
                waiting[#waiting + 1] = at
            end
        end
    end
    pending = waiting
    if #pending == 0 then
        ticking = false
        Events.OnTick.Remove(onTick)
    end
end

local function onGenerator(object)
    local square = object:getSquare()
    if not square or BU.Spawned.chance() <= 0 then return end
    pending[#pending + 1] = { square:getX(), square:getY(), square:getZ(), 0 }
    if not ticking then
        ticking = true
        Events.OnTick.Add(onTick)
    end
end

for index = 0, 15 do MapObjects.OnNewWithSprite("appliances_misc_01_" .. index, onGenerator, PRIORITY) end
