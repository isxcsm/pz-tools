-- Test helpers (BURACK): car batteries into a rack's container and out of it as a player does in the loot window,
-- each followed by the rack's sync (Changes.syncRack), as the server does every minute.
local BU = BuildingUtilities
BURACK = {}

local function container(rack) return BU.Units.rackContainer(BU.Units.object(rack)) end

-- A battery of spec { type, charge, condition } put in; returns the item.
function BURACK.put(rack, spec)
    local item = instanceItem(spec.type)
    item:setUsedDelta(spec.charge)
    item:setCondition(spec.condition)
    container(rack):AddItem(item)
    BU.Changes.syncRack(rack)
    return item
end

-- The battery at an index taken out, with what the bank made of it; returns the item.
function BURACK.take(rack, index)
    BU.Changes.syncRack(rack)
    local items = container(rack):getItems()
    local item = items:get(index - 1)
    container(rack):DoRemoveItem(item)
    BU.Changes.syncRack(rack)
    return item
end

function BURACK.empty(rack)
    local items = container(rack):getItems()
    while items:size() > 0 do container(rack):DoRemoveItem(items:get(0)) end
    BU.Changes.syncRack(rack)
end
