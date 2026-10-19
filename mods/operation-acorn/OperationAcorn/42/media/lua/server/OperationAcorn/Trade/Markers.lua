-- Finding what the helicopter left: a mark in the record, until the thing is picked up (DESIGN 9 and 3). (No smoke:
-- the game's own came and went at once, with no fading, and could not be kept going.) The marks are kept in the record (heli.markers); the clients list them (the helicopter tab's
-- crates, the maps by Story/View). Only a loaded square can be looked at, so a mark lives until its square is seen
-- without the thing.
require "OperationAcorn/Server"
require "OperationAcorn/Trade/Objects"
local OA = OperationAcorn
local Store, Trade = OA.Store, OA.Trade
local Objects = Trade.Objects
local Markers = {}
Trade.Markers = Markers

function Markers.list(record)
    local heli = Trade.heli(record)
    heli.markers = heli.markers or {}
    return heli.markers
end

-- Marks a square. kind "crate" (a supply crate); extra goes into the mark.
function Markers.add(record, square, kind, extra)
    local list = Markers.list(record)
    local mark = { kind = kind, x = square:getX(), y = square:getY(), z = square:getZ(), at = OA.hours() }
    for k, v in pairs(extra or {}) do mark[k] = v end
    list[#list + 1] = mark
    OA.Sync.changed("trade", record.id)
    return mark
end

-- Whether a mark's crate is gone from its (loaded) square or opened.
local function done(mark, square)
    local object = Objects.find(square, Objects.CRATE)
    return object == nil or not object:getModData()[Objects.SEALED]
end

-- Looks at the marks of a record whose squares are loaded: the finished ones go. Returns how many were removed.
function Markers.check(record)
    local list = Markers.list(record)
    local removed = 0
    for i = #list, 1, -1 do
        local mark = list[i]
        local square = Objects.square(mark.x, mark.y, mark.z)
        if square then
            if done(mark, square) then
                table.remove(list, i)
                removed = removed + 1
            end
        end
    end
    if removed > 0 then OA.Sync.changed("trade", record.id) end
    return removed
end

function Markers.checkAll()
    for _, record in pairs(Store.players()) do
        if record.heli and record.heli.markers and #record.heli.markers > 0 then Markers.check(record) end
    end
end

return Markers
