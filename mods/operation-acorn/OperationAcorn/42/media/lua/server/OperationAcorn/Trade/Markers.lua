-- Finding what the helicopter left: smoke over the drop for a while and a mark in the record, until the thing is picked
-- up (DESIGN 9 and 3). The marks are kept in the record (heli.markers); the clients list them (the helicopter tab's
-- crates, the maps by Story/View). Only a loaded square can be looked at, so a mark lives until its square is seen
-- without the thing.
require "OperationAcorn/Server"
require "OperationAcorn/Trade/Objects"
local OA = OperationAcorn
local Store, Trade = OA.Store, OA.Trade
local Objects = Trade.Objects
local Markers = {}
Trade.Markers = Markers

-- The item whose leaving the box ends the first supply's mark.
Markers.MANUAL = "TerminalManual"

function Markers.list(record)
    local heli = Trade.heli(record)
    heli.markers = heli.markers or {}
    return heli.markers
end

-- A little smoke over a square (best effort: the game's own call for it).
function Markers.smoke(square)
    local ok, err = pcall(function() IsoFireManager.StartSmoke(getCell(), square, true, 100, 500) end)
    if not ok then OA.log("smoke failed:", tostring(err)) end
end

-- Marks a square. kind "first" (the first supply's box, extra.box its id) or "crate" (a supply crate).
function Markers.add(record, square, kind, extra)
    local list = Markers.list(record)
    local mark = { kind = kind, x = square:getX(), y = square:getY(), z = square:getZ(), at = OA.hours() }
    for k, v in pairs(extra or {}) do mark[k] = v end
    list[#list + 1] = mark
    Markers.smoke(square)
    OA.Sync.changed("trade", record.id)
    return mark
end

-- Whether a mark's thing is gone from its (loaded) square: picked up, opened, destroyed.
local function done(mark, square)
    if mark.kind == "crate" then
        local object = Objects.find(square, Objects.CRATE)
        return object == nil or not object:getModData()[Objects.SEALED]
    end
    local object = Objects.find(square, Objects.DELIVERY_BOX, mark.box)
    if not object then return true end
    local container = object:getContainer()
    return container == nil or not container:containsType(Markers.MANUAL)
end

-- Looks at the marks of a record whose squares are loaded: the finished ones go, the others smoke again. Returns
-- how many were removed.
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
            else
                Markers.smoke(square)
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
