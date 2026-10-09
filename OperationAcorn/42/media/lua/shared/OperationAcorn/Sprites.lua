-- The mod's own tiles, by what they show. The art is drawn by tools/tile_art.py into two sheets (8 tiles a row);
-- a save names a tile by its sheet position, so a used position never changes and new tiles take free ones.
-- Rotating objects have four looks in the order south, east, north, west.
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

-- Machines sheet. The big machines are several tiles; a machine takes states x facings x tiles places, in this order:
-- state (stopped, running), facing (S E N W), then the tiles of that facing's footprint row by row (y outer, x inner).
-- FOOTPRINT is the footprint facing south, w along x by h along y; the east and west facings swap w and h. Each
-- machine is one object drawn whole and split over its squares; the tile at (dx = 0, dy = 0) is the anchor, the
-- footprint's min-x, min-y square, and the only one with the container (research storage) or the rain collector flag.
local KINDS = {
    shredBench = { base = 0, w = 2, h = 1, states = 1, facings = 4 },
    bulkShredder = { base = 8, w = 2, h = 1, states = 2, facings = 4, ready = 160 },
    cutter = { base = 24, w = 2, h = 1, states = 2, facings = 4, ready = 168 },
    woodSaw = { base = 40, w = 2, h = 1, states = 2, facings = 4, ready = 176 },
    researchStorage = { base = 56, w = 2, h = 1, states = 1, facings = 4 },
    propaneRefiner = { base = 64, w = 2, h = 2, states = 2, facings = 4, ready = 184 },
    oilRefiner = { base = 96, w = 2, h = 2, states = 2, facings = 4, ready = 200 },
    rainStorage = { base = 128, w = 2, h = 2, states = 1, facings = 1 },
}

Sprites.FOOTPRINT = {}
for kind, k in pairs(KINDS) do
    Sprites.FOOTPRINT[kind] = { w = k.w, h = k.h }
end
-- The machines of the sheet that stand in four directions and are installed from items (not the rain storage or the lure):
-- kind -> its footprint facing south.
Sprites.MACHINE_KINDS = {}
for kind, k in pairs(KINDS) do
    if k.facings == 4 then Sprites.MACHINE_KINDS[kind] = Sprites.FOOTPRINT[kind] end
end
-- The 1x1 objects, for callers that ask for every kind.
Sprites.FOOTPRINT.terminal = { w = 1, h = 1 }
Sprites.FOOTPRINT.deliveryBox = { w = 1, h = 1 }
Sprites.FOOTPRINT.supplyCrate = { w = 1, h = 1 }
Sprites.FOOTPRINT.parachuteCrate = { w = 1, h = 1 }
Sprites.FOOTPRINT.lure = { w = 1, h = 1 }

-- The footprint (w, h) of a kind facing dir ("S", "E", "N", "W"); nil for an unknown kind.
function Sprites.footprint(kind, dir)
    local f = Sprites.FOOTPRINT[kind]
    if not f then return nil end
    if dir == "E" or dir == "W" then return f.h, f.w end
    return f.w, f.h
end

-- The looks of a machine with a running look, as machineTiles takes them: stopped (switched off or no power), running
-- (working), "ready" (switched on and waiting: its lamps lit, nothing moving). The ready looks are at `ready`: facings
-- x tiles, after the rain storage's overlays.
Sprites.LOOKS = { false, true, "ready" }

-- The tiles of one machine standing in direction dir: a list of { dx =, dy =, sprite = }, one per square of its
-- footprint, dx and dy from the anchor (the min-x, min-y square), row by row. look: false (stopped), true (running) or
-- "ready"; a machine without a running look has only the stopped one. nil for a kind that is not a machine of this sheet.
function Sprites.machineTiles(kind, dir, look)
    local k = KINDS[kind]
    if not k then return nil end
    if kind == "rainStorage" then return Sprites.rainStorageTiles() end
    local f = k.facings == 4 and facing(dir) or 0
    local w, h = Sprites.footprint(kind, k.facings == 4 and dir or "S")
    local first
    if look == "ready" and k.ready then
        first = k.ready + f * w * h
    else
        local state = (look == true and k.states == 2) and 1 or 0
        first = k.base + (state * k.facings + f) * w * h
    end
    local tiles = {}
    for dy = 0, h - 1 do
        for dx = 0, w - 1 do
            tiles[#tiles + 1] = { dx = dx, dy = dy, sprite = tile(Sprites.MACHINES, first + dy * w + dx) }
        end
    end
    return tiles
end

-- The big rain storage (2x2, the same from every side) is placed as the EMPTY tank (rainStorageTiles: the object's
-- sprites; the anchor's is the one the entity's SpriteConfig names and carries the rain collector flag). Its water level is an
-- overlay on each of the four squares (IsoObject.setOverlaySprite): level 1 a quarter, 2 a half, 3 full; level 0 is no
-- overlay. An overlay tile holds only the pixels that differ from the empty tile, so the empty tile with it drawn over is
-- exactly the level's picture. (128-131 are the full tank as one picture, used for the item icon.)
Sprites.RAIN_LEVELS = 4
local RAIN_BASE = 134
local RAIN_OVERLAY = { [1] = 146, [2] = 150, [3] = 154 }

local function rainTiles(first)
    local tiles = {}
    for dy = 0, 1 do
        for dx = 0, 1 do
            tiles[#tiles + 1] = { dx = dx, dy = dy, sprite = tile(Sprites.MACHINES, first + dy * 2 + dx) }
        end
    end
    return tiles
end

function Sprites.rainStorageTiles() return rainTiles(RAIN_BASE) end

-- The four overlay sprites of a water level (1 to 3, higher is held to 3), { dx, dy, sprite } like the base tiles. An
-- empty list for level 0 or less (or nil): no overlay.
function Sprites.rainOverlayTiles(level)
    if type(level) ~= "number" or level < 1 then return {} end
    return rainTiles(RAIN_OVERLAY[math.min(Sprites.RAIN_LEVELS - 1, math.floor(level))])
end

-- The lure is one tile and does not rotate.
function Sprites.lure(on) return tile(Sprites.MACHINES, on and 132 or 133) end

return Sprites
