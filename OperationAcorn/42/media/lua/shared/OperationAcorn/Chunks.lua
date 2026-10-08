-- Work that waits for a place to load: a sealed box to take away, a supply crate to put down, a mission item, a
-- meteor drop site. Never per square (Lua LoadGridsquare runs tens of thousands of times a second while driving):
-- the vanilla LoadChunk event comes once per 8x8 chunk, and a chunk with nothing waiting returns on the first line
-- (DESIGN 12, performance rules).
require "OperationAcorn/Store"
local OA = OperationAcorn
local Chunks = {}
OA.Chunks = Chunks

Chunks.SIZE = 8

-- What runs a kind of waiting work: handlers[kind] = function(entry, chunk) return done end. The entry is the
-- table that was added (with x, y, z and anything the part put in it); done = true removes it from the table.
local handlers = {}

function Chunks.handle(kind, fn)
    handlers[kind] = fn
end

function Chunks.key(x, y)
    return tostring(math.floor(x / Chunks.SIZE)) .. "," .. tostring(math.floor(y / Chunks.SIZE))
end

-- The pending table: { [chunk key] = { entry, ... } }, kept in the save.
local function pending()
    return OA.Store.world("pending")
end

-- Adds work for the square x, y, z: entry = { kind = ..., x = ..., y = ..., z = ..., ... }. If the square is
-- loaded now the part should do the work at once instead; this is for when it is not.
function Chunks.add(entry)
    local key = Chunks.key(entry.x, entry.y)
    local list = pending()[key]
    if not list then
        list = {}
        pending()[key] = list
    end
    table.insert(list, entry)
end

-- Removes waiting entries a predicate picks (a mission that ended, a box that was destroyed).
function Chunks.remove(predicate)
    for key, list in pairs(pending()) do
        for i = #list, 1, -1 do
            if predicate(list[i]) then table.remove(list, i) end
        end
        if #list == 0 then pending()[key] = nil end
    end
end

-- The waiting entries of a kind, for a part that wants to show them (the terminal's map) or count them.
function Chunks.list(kind)
    local found = {}
    for _, list in pairs(pending()) do
        for _, entry in ipairs(list) do
            if entry.kind == kind then table.insert(found, entry) end
        end
    end
    return found
end

-- The chunk's key from the chunk object: its first square. IsoChunk keeps wx, wy as fields, which Lua may not
-- read, so the square's coordinates are used.
local function chunkKey(chunk)
    local square = chunk:getGridSquare(0, 0, 0)
    if not square then return nil end
    return Chunks.key(square:getX(), square:getY())
end

function Chunks.loaded(chunk)
    local table0 = pending()
    if OA.isEmpty(table0) then return end
    local key = chunkKey(chunk)
    local list = key and table0[key]
    if not list then return end
    for i = #list, 1, -1 do
        local entry = list[i]
        local fn = handlers[entry.kind]
        if fn then
            local ok, done = pcall(fn, entry, chunk)
            if not ok then
                OA.log("chunk work", entry.kind, "failed:", tostring(done))
            elseif done then
                table.remove(list, i)
            end
        end
    end
    if #list == 0 then table0[key] = nil end
end

return Chunks
