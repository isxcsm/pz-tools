-- The mod's own tiles, by what they show. The art is drawn by tools/tile_art.py into two sheets (8 tiles a row);
-- a save names a tile by its sheet position, so a used position never changes and new tiles take free ones.
-- Rotating objects have four tiles in the order south, east, north, west.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Sprites = {}
OA.Sprites = Sprites

Sprites.TRADE = "oa_trade_01"
Sprites.MACHINES = "oa_machines_01"
Sprites.DIRECTIONS = { "S", "E", "N", "W" }

local function tile(sheet, index)
    return sheet .. "_" .. tostring(index)
end

-- Index of a direction ("S", "E", "N", "W"), 0 to 3.
local function facing(dir)
    for i, d in ipairs(Sprites.DIRECTIONS) do
        if d == dir then return i - 1 end
    end
    return 0
end

-- Trade sheet.
function Sprites.terminal(dir, on) return tile(Sprites.TRADE, (on and 4 or 0) + facing(dir)) end
function Sprites.deliveryBox(sealed) return tile(Sprites.TRADE, sealed and 9 or 8) end
function Sprites.supplyCrate(opened) return tile(Sprites.TRADE, opened and 11 or 10) end
Sprites.PARACHUTE_CRATE = tile(Sprites.TRADE, 12)
Sprites.SCORCHED_GROUND = tile(Sprites.TRADE, 13)
Sprites.METEOR_ROCKS = tile(Sprites.TRADE, 14)
Sprites.SITE_STAKE = tile(Sprites.TRADE, 15)

-- Machines sheet: four directions each, a stopped and a running look for the machines that run.
local MACHINES = {
    shredBench = { stopped = 0 },
    bulkShredder = { stopped = 4, running = 8 },
    cutter = { stopped = 12, running = 16 },
    propaneRefiner = { stopped = 20, running = 24 },
    oilRefiner = { stopped = 28, running = 32 },
    woodSaw = { stopped = 36, running = 40 },
    researchStorage = { stopped = 44 },
}
Sprites.MACHINE_KINDS = MACHINES

function Sprites.machine(kind, dir, running)
    local m = MACHINES[kind]
    if not m then return nil end
    local base = running and m.running or m.stopped
    return tile(Sprites.MACHINES, base + facing(dir))
end

-- One tile each: they do not rotate.
Sprites.RAIN_STORAGE = tile(Sprites.MACHINES, 48)
function Sprites.lure(on) return tile(Sprites.MACHINES, on and 49 or 50) end

return Sprites
