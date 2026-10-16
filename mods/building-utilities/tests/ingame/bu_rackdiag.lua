-- Each rack: its container, what it takes, its items and its records. "[burack]" lines.
local BU = BuildingUtilities
for _, rack in ipairs(BU.Store.unitList("rack")) do
    local object = BU.Units.object(rack)
    local box = object and object:getContainer()
    print("[burack]", rack.id, "object", tostring(object ~= nil), "container", box and box:getType() or "none",
        box and box:getCapacity() or "", box and tostring(box:getAcceptItemFunction()) or "", "items", box and box:getItems():size() or "",
        "records", #rack.batteries)
    for _, record in ipairs(rack.batteries) do print("[burack]  ", record.id, record.type) end
end
