-- The tile names of Sprites.lua against the footprints, the facings and what the .tiles files define.
require "OperationAcorn/Core"
require "OperationAcorn/Sprites"
local OA = OperationAcorn
local Sprites = OA.Sprites

local MEDIA = "OperationAcorn/42/media/"
local DIRS = { "S", "E", "N", "W" }
local FOOT = {
    shredBench = { 2, 1 }, bulkShredder = { 2, 1 }, cutter = { 2, 1 }, woodSaw = { 2, 1 }, researchStorage = { 2, 1 },
    propaneRefiner = { 2, 2 }, oilRefiner = { 2, 2 }, rainStorage = { 2, 2 },
}
local KINDS = { "shredBench", "bulkShredder", "cutter", "woodSaw", "researchStorage", "propaneRefiner", "oilRefiner",
    "rainStorage" }
local RUNS = { bulkShredder = true, cutter = true, woodSaw = true, propaneRefiner = true, oilRefiner = true }

-- The properties of every tile of a .tiles file: places[index] = { key = value }. The file is binary (tdef, 2 ints,
-- the sheet name and image lines, 4 ints, then per tile an int count and key/value lines); readfile(path, "bytes") gives one character
-- a byte, so the integers are read as the bytes they are.
local function readTiles(file, sheet)
    local text = readfile(MEDIA .. file, "bytes")
    truthy(text, file .. " is there")
    eq(string.sub(text, 1, 4), "tdef")
    local pos = string.find(text, sheet .. ".png\n", 1, true)
    truthy(pos, "sheet image line")
    pos = pos + string.len(sheet .. ".png\n")
    local count = string.byte(text, pos + 12) + 256 * string.byte(text, pos + 13)  -- the tile count
    pos = pos + 16
    local places = {}
    for index = 0, count - 1 do
        local n = string.byte(text, pos) + 256 * string.byte(text, pos + 1)
        pos = pos + 4
        local props = {}
        for _ = 1, n do
            local e1 = string.find(text, "\n", pos, true)
            local key = string.sub(text, pos, e1 - 1)
            local e2 = string.find(text, "\n", e1 + 1, true)
            props[key] = string.sub(text, e1 + 1, e2 - 1)
            pos = e2 + 1
        end
        places[index] = props
    end
    return places, count
end

local function indexOf(sprite)
    return tonumber(string.match(sprite, "^oa_machines_01_(%d+)$"))
end

test("footprints and their east/west swap", function()
    for _, kind in ipairs(KINDS) do
        local f = FOOT[kind]
        local w, h = Sprites.footprint(kind, "S")
        eq(w, f[1], kind .. " S w")
        eq(h, f[2], kind .. " S h")
        w, h = Sprites.footprint(kind, "N")
        eq(w, f[1], kind .. " N w")
        eq(h, f[2], kind .. " N h")
        w, h = Sprites.footprint(kind, "E")
        eq(w, f[2], kind .. " E w")
        eq(h, f[1], kind .. " E h")
        w, h = Sprites.footprint(kind, "W")
        eq(w, f[2], kind .. " W w")
        eq(h, f[1], kind .. " W h")
        eq(Sprites.FOOTPRINT[kind].w, f[1])
        eq(Sprites.FOOTPRINT[kind].h, f[2])
    end
    for _, kind in ipairs({ "terminal", "deliveryBox", "supplyCrate", "parachuteCrate", "lure" }) do
        eq(Sprites.FOOTPRINT[kind].w, 1, kind)
        eq(Sprites.FOOTPRINT[kind].h, 1, kind)
        local w, h = Sprites.footprint(kind, "E")
        eq(w, 1)
        eq(h, 1)
    end
    eq(Sprites.footprint("nothing", "S"), nil)
    eq(Sprites.machineTiles("nothing", "S", false), nil)
end)

test("one tile for each square of the footprint, from the anchor", function()
    for _, kind in ipairs(KINDS) do
        for _, dir in ipairs(DIRS) do
            for _, running in ipairs(Sprites.LOOKS) do
                local tiles = Sprites.machineTiles(kind, dir, running)
                local w, h = Sprites.footprint(kind, kind == "rainStorage" and "S" or dir)
                eq(#tiles, w * h, kind .. dir)
                local seen, anchor = {}, false
                for _, t in ipairs(tiles) do
                    truthy(t.dx >= 0 and t.dx < w and t.dy >= 0 and t.dy < h, kind .. dir .. " inside the footprint")
                    local key = t.dx .. "," .. t.dy
                    truthy(not seen[key], kind .. dir .. " a square once")
                    seen[key] = true
                    truthy(type(t.sprite) == "string", "a sprite name")
                    if t.dx == 0 and t.dy == 0 then anchor = true end
                end
                truthy(anchor, kind .. dir .. " has its anchor")
            end
        end
    end
end)

test("running changes only the machines that run; the rain storage does not turn", function()
    for _, kind in ipairs(KINDS) do
        for _, dir in ipairs(DIRS) do
            local a = Sprites.machineTiles(kind, dir, false)
            local b = Sprites.machineTiles(kind, dir, true)
            local c = Sprites.machineTiles(kind, dir, "ready")
            for i = 1, #a do
                if RUNS[kind] then
                    truthy(a[i].sprite ~= b[i].sprite, kind .. dir .. " running look")
                    truthy(c[i].sprite ~= a[i].sprite and c[i].sprite ~= b[i].sprite, kind .. dir .. " ready look")
                else
                    eq(a[i].sprite, b[i].sprite, kind .. dir .. " no running look")
                    eq(a[i].sprite, c[i].sprite, kind .. dir .. " no ready look")
                end
            end
        end
    end
    local first = Sprites.rainStorageTiles()
    for _, dir in ipairs(DIRS) do
        local t = Sprites.machineTiles("rainStorage", dir, false)
        for i = 1, #first do eq(t[i].sprite, first[i].sprite, "rain " .. dir) end
    end
end)

test("every tile is its own: no place is used by two looks", function()
    local owner, count = {}, 0
    for _, kind in ipairs(KINDS) do
        for _, dir in ipairs(DIRS) do
            for _, running in ipairs(Sprites.LOOKS) do
                for _, t in ipairs(Sprites.machineTiles(kind, dir, running)) do
                    local look = kind .. (RUNS[kind] and tostring(running) or "") .. (kind == "rainStorage" and "" or dir)
                    if owner[t.sprite] then
                        eq(owner[t.sprite], look .. t.dx .. t.dy, t.sprite)
                    else
                        owner[t.sprite] = look .. t.dx .. t.dy
                        count = count + 1
                    end
                end
            end
        end
    end
    eq(count, 188, "tiles of the machines (132, and the ready looks 56)")
    truthy(Sprites.lure(true) ~= Sprites.lure(false), "lure looks")
    truthy(not owner[Sprites.lure(true)] and not owner[Sprites.lure(false)], "lure places are free")
end)

test("the machines tiles are defined in oa_machines.tiles, with matching properties", function()
    local places, count = readTiles("oa_machines.tiles", "oa_machines_01")
    eq(count, 216, "27 rows of 8")
    for _, kind in ipairs(KINDS) do
        for _, dir in ipairs(DIRS) do
            for _, running in ipairs(Sprites.LOOKS) do
                local group
                for _, t in ipairs(Sprites.machineTiles(kind, dir, running)) do
                    local index = indexOf(t.sprite)
                    truthy(index and index < count, t.sprite .. " is in the sheet")
                    local p = places[index]
                    truthy(p and p.CustomName, t.sprite .. " is defined")
                    eq(p.SpriteGridPos, t.dx .. "," .. t.dy, t.sprite .. " grid position")
                    if kind == "rainStorage" then
                        eq(p.Facing, "S", t.sprite .. " faces S (the game builds a grid only for a facing tile)")
                    else
                        eq(p.Facing, dir, t.sprite .. " facing")
                    end
                    group = group or p.GroupName
                    truthy(p.GroupName, t.sprite .. " has a group")
                    eq(p.GroupName, group, t.sprite .. " one group for the machine")
                    local anchor = t.dx == 0 and t.dy == 0
                    if kind == "researchStorage" then
                        eq(p.container, "locker", t.sprite .. " a locker on every square")
                        eq(p.ContainerCapacity, "100", t.sprite .. " capacity on every square")
                    else
                        eq(p.container, nil, t.sprite .. " no container")
                    end
                    if kind == "rainStorage" then
                        eq(p.IsWaterCollector, anchor and "" or nil, t.sprite .. " collector only on the anchor")
                    else
                        eq(p.IsWaterCollector, nil, t.sprite .. " not a collector")
                    end
                    truthy(p.BlocksPlacement ~= nil and p.solidtrans ~= nil, t.sprite .. " solid")
                end
            end
        end
    end
    for _, on in ipairs({ true, false }) do
        local p = places[indexOf(Sprites.lure(on))]
        eq(p.CustomName, "Lure")
        eq(p.SpriteGridPos, nil)
    end
end)

test("rain storage: the empty tank is the object, the water levels are overlays", function()
    eq(Sprites.RAIN_LEVELS, 4)
    local places, count = readTiles("oa_machines.tiles", "oa_machines_01")
    local base = Sprites.rainStorageTiles()
    eq(#base, 4)
    eq(base[1].sprite, "oa_machines_01_134", "the anchor is the empty tank")
    for i, expect in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
        eq(base[i].dx, expect[1])
        eq(base[i].dy, expect[2])
        eq(base[i].sprite, "oa_machines_01_" .. (133 + i))
    end
    local viaKind = Sprites.machineTiles("rainStorage", "N", true)
    for i = 1, 4 do eq(viaKind[i].sprite, base[i].sprite, "machineTiles is the base") end
    -- the base tiles carry the properties; only the anchor the rain collector flag
    for _, t in ipairs(base) do
        local p = places[indexOf(t.sprite)]
        eq(p.CustomName, "Big Rain Storage")
        eq(p.GroupName, "OA_rainStorage")
        eq(p.SpriteGridPos, t.dx .. "," .. t.dy)
        eq(p.Facing, "S", "one facing: it does not turn")
        eq(p.IsWaterCollector, (t.dx == 0 and t.dy == 0) and "" or nil, t.sprite .. " collector only on the anchor")
        eq(p.IsLow, "")
        truthy(p.solidtrans ~= nil and p.BlocksPlacement ~= nil, t.sprite .. " solid")
    end
    -- no overlay for level 0 or less
    eq(#Sprites.rainOverlayTiles(0), 0)
    eq(#Sprites.rainOverlayTiles(-2), 0)
    eq(#Sprites.rainOverlayTiles(nil), 0)
    -- the overlays: 4 tiles each at 146-157, in the order of the base tiles, decoration only
    local seen = {}
    for level = 1, 3 do
        local tiles = Sprites.rainOverlayTiles(level)
        eq(#tiles, 4, "level " .. level)
        for i, t in ipairs(tiles) do
            eq(t.dx, base[i].dx)
            eq(t.dy, base[i].dy)
            eq(t.sprite, "oa_machines_01_" .. (146 + (level - 1) * 4 + i - 1), "level " .. level)
            truthy(not seen[t.sprite], "an overlay tile in one level only")
            seen[t.sprite] = true
            local index = indexOf(t.sprite)
            truthy(index and index < count, t.sprite .. " is in the sheet")
            local p = places[index]
            truthy(p, t.sprite .. " is defined")
            for _, key in ipairs({ "IsWaterCollector", "BlocksPlacement", "solidtrans", "container", "IsLow", "Facing", "SpriteGridPos" }) do
                eq(p[key], nil, t.sprite .. " has no " .. key)
            end
        end
    end
    eq(Sprites.rainOverlayTiles(9)[1].sprite, Sprites.rainOverlayTiles(3)[1].sprite, "higher levels are held to full")
    eq(Sprites.rainOverlayTiles(2.7)[1].sprite, Sprites.rainOverlayTiles(2)[1].sprite)
    -- the full tank as one picture keeps 128-131
    for i = 128, 131 do truthy(places[i] and places[i].CustomName, "full tank tile " .. i) end
    -- no machine look uses the places of the overlays or the full tank
    local used = {}
    for _, kind in ipairs(KINDS) do
        for _, dir in ipairs(DIRS) do
            for _, running in ipairs(Sprites.LOOKS) do
                for _, t in ipairs(Sprites.machineTiles(kind, dir, running)) do used[t.sprite] = true end
            end
        end
    end
    for name in pairs(seen) do truthy(not used[name], name .. " is only an overlay") end
    truthy(not used[Sprites.lure(true)] and not used[Sprites.lure(false)])
end)

test("the trade tiles keep their places", function()
    local places, count = readTiles("oa_trade.tiles", "oa_trade_01")
    eq(count, 16)
    eq(Sprites.terminal("S", false), "oa_trade_01_0")
    eq(Sprites.terminal("W", false), "oa_trade_01_3")
    eq(Sprites.terminal("S", true), "oa_trade_01_4")
    eq(Sprites.terminal("W", true), "oa_trade_01_7")
    eq(Sprites.deliveryBox(false), "oa_trade_01_8")
    eq(Sprites.deliveryBox(true), "oa_trade_01_9")
    eq(Sprites.supplyCrate(false), "oa_trade_01_10")
    eq(Sprites.supplyCrate(true), "oa_trade_01_11")
    eq(Sprites.PARACHUTE_CRATE, "oa_trade_01_12")
    eq(Sprites.SCORCHED_GROUND, "oa_trade_01_13")
    eq(Sprites.METEOR_ROCKS, "oa_trade_01_14")
    eq(Sprites.SITE_STAKE, "oa_trade_01_15")
    for _, name in ipairs({ Sprites.terminal("E", true), Sprites.deliveryBox(true), Sprites.supplyCrate(true),
        Sprites.PARACHUTE_CRATE, Sprites.METEOR_ROCKS, Sprites.SITE_STAKE }) do
        local index = tonumber(string.match(name, "(%d+)$"))
        truthy(places[index].CustomName, name .. " is defined")
    end
    eq(places[0].Facing, "S")
    eq(places[3].Facing, "W")
end)
