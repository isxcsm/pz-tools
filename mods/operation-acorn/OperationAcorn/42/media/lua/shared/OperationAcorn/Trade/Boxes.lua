-- The delivery boxes of a record as plain data (DESIGN 9): one active box, earlier ones as previous boxes, the states
-- a box goes through, and the entries a sealed box keeps. The world objects are made by Trade/Objects; this is what
-- the save knows, so the helicopter can settle while the box's square is not loaded.
--
-- record.boxes = { seq, active = id or nil, list = { [id] = box } }
-- box = { id, state, x, y, z, created, sealed = { at, entries, count, weight } or nil }
--   state "placed"  standing in the world, open: filled and emptied like a chest
--   state "carried" an item: taken up by a character, or packed in the supply crate it came in (x, y, z the last spot
--                   it stood, or where its crate came down)
--   state "sealed"  fixed in the world, waiting for the helicopter
-- entries = { { info = <OA.Value.info table>, count = n } }
require "OperationAcorn/Store"
local OA = OperationAcorn
local Store = OA.Store
local Boxes = {}
OA.Trade = OA.Trade or {}
OA.Trade.Boxes = Boxes

function Boxes.data(record)
    local d = Store.section(record, "boxes")
    d.seq = d.seq or 0
    d.list = d.list or {}
    return d
end

-- A box id no other record has: the record's collection point number and a running number.
function Boxes.nextId(record)
    local d = Boxes.data(record)
    d.seq = d.seq + 1
    return string.format("%04d-%d", record.number or 0, d.seq)
end

function Boxes.get(record, id)
    return id and Boxes.data(record).list[id] or nil
end

function Boxes.active(record)
    local d = Boxes.data(record)
    return d.active and d.list[d.active] or nil
end

-- Adds a box: spec = { id (made when missing), state ("placed"), x, y, z, active (true to take the active place,
-- false to be a previous box; by default it becomes active when there is no active box) }. A new active box makes
-- the former one a previous box (it stays in the list).
function Boxes.add(record, spec)
    local d = Boxes.data(record)
    local id = spec.id or Boxes.nextId(record)
    local box = d.list[id]
    if not box then
        box = { id = id, created = OA.hours() }
        d.list[id] = box
    end
    box.state = spec.state or box.state or "placed"
    box.x, box.y, box.z = spec.x or box.x, spec.y or box.y, spec.z or box.z
    local becomes = spec.active
    if becomes == nil then becomes = d.active == nil or d.list[d.active] == nil end
    if becomes then d.active = id end
    return box
end

-- A box as the item it travels as: the helicopter packs a new one in its supply crate (the first supply, the empty box
-- that comes back for a sealed one, a reissue), and the player puts it down where they want. The keys are those of
-- Trade/Objects (BOX, OWNER), which the item keeps as a taken-up box does.
Boxes.ITEM = "OperationAcorn.DeliveryBox"
function Boxes.itemSpec(record, box)
    return { type = Boxes.ITEM, count = 1, mod = { OA_Box = box.id, OA_Owner = record.id } }
end

-- Whether a call can be made: the active box must stand in the world. Returns true, or false and a reason.
function Boxes.canCall(record)
    local box = Boxes.active(record)
    if not box then return false, "noBox" end
    if box.state == "carried" then return false, "carried" end
    return true
end

-- Whether a call has something to carry: a sealed box to take up, or something to bring down (the cart's orders, a
-- support request, what the story sends: a mission's case, the field caller). A flight for nothing is not made.
function Boxes.hasCargo(record)
    if #Boxes.sealed(record) > 0 then return true end
    local drop = record.heli and record.heli.drop
    if drop and #drop > 0 then return true end
    local cart = record.orders and record.orders.cart
    if cart and #cart > 0 then return true end
    for _ in pairs(record.trade and record.trade.pendingLevels or {}) do return true end
    return false
end

-- A box put down at x, y, z (in a world with the same box id from a taken-up item or newly made).
function Boxes.place(record, id, x, y, z)
    local box = Boxes.get(record, id)
    if not box then return nil end
    box.state, box.x, box.y, box.z = "placed", x, y, z
    return box
end

-- A box taken up: only a box that is not sealed can be.
function Boxes.carry(record, id)
    local box = Boxes.get(record, id)
    if not box or box.state == "sealed" then return nil end
    box.state = "carried"
    return box
end

-- The entries of a box sealed: only an open box standing in the world. `weight` is what the items weighed.
function Boxes.seal(record, id, entries, weight, now)
    local box = Boxes.get(record, id)
    if not box then return false, "noBox" end
    if box.state ~= "placed" then return false, "state" end
    local count = 0
    for _, e in ipairs(entries) do count = count + e.count end
    box.state = "sealed"
    box.sealed = { at = now or OA.hours(), entries = entries, count = count, weight = weight or 0 }
    return true
end

-- Takes a box out of the record (the helicopter took it, or it was destroyed). Returns it, and whether it was the
-- active box. The active place is empty afterwards.
function Boxes.remove(record, id)
    local d = Boxes.data(record)
    local box = d.list[id]
    if not box then return nil, false end
    local wasActive = d.active == id
    d.list[id] = nil
    if wasActive then d.active = nil end
    return box, wasActive
end

-- The sealed boxes, the active one first and then the others in the order they were made.
function Boxes.sealed(record)
    local d = Boxes.data(record)
    local list = {}
    for _, box in pairs(d.list) do
        if box.state == "sealed" then list[#list + 1] = box end
    end
    table.sort(list, function(a, b)
        local aa, bb = a.id == d.active, b.id == d.active
        if aa ~= bb then return aa end
        if a.created ~= b.created then return a.created < b.created end
        return a.id < b.id
    end)
    return list
end

-- All boxes in the order they were made.
function Boxes.all(record)
    local list = {}
    for _, box in pairs(Boxes.data(record).list) do list[#list + 1] = box end
    table.sort(list, function(a, b)
        if a.created ~= b.created then return a.created < b.created end
        return a.id < b.id
    end)
    return list
end

-- The sealed boxes' entries together, for one settlement.
function Boxes.sealedEntries(record)
    local entries = {}
    for _, box in ipairs(Boxes.sealed(record)) do
        for _, e in ipairs(box.sealed and box.sealed.entries or {}) do entries[#entries + 1] = e end
    end
    return entries
end

-- Every field OA.Value.info (and infoFromScript) gives, in the order the key is written. Each is a plain value. A field
-- added to the info belongs here too: the unit test fails while one is missing, since items that differ only in it
-- would group as one.
Boxes.INFO_FIELDS = { "fullType", "baseType", "weight", "displayCategory", "moveable", "cash", "own", "food", "condition",
    "filled", "bought", "cell", "mission" }
local INFO_FIELDS = Boxes.INFO_FIELDS
local keyParts = {}

-- A key that is the same for items that settle the same: their info fields, in the fixed order.
local function infoKey(info)
    for i = 1, #INFO_FIELDS do keyParts[i] = tostring(info[INFO_FIELDS[i]]) end
    return table.concat(keyParts, "|", 1, #INFO_FIELDS)
end

-- Items as infos (one per item) written into entries { info, count } by like with like, in the order first seen.
function Boxes.group(infos)
    local entries, byKey = {}, {}
    for _, info in ipairs(infos) do
        local key = infoKey(info)
        local e = byKey[key]
        if not e then
            e = { info = info, count = 0 }
            byKey[key] = e
            entries[#entries + 1] = e
        end
        e.count = e.count + 1
    end
    return entries
end

return Boxes
