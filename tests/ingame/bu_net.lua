-- The test panel's power network as the API sees it: version, producers (source or square, available, fuel), the one
-- in use, supply and load. "[bunet]" lines.
local BU = BuildingUtilities
local panel = BU.Store.get(ModData.getOrCreate("BUTEST").panel)
local state = BU.Networks.state(panel, "power")
print("[bunet] api", PZToolsAPI and PZToolsAPI.version, "panel", panel.id, "tier", panel.tier, "producers saved", #panel.power.producers,
    "units", #BU.Store.unitList(nil, panel.id), "sourceOn", tostring(panel.sourceOn))
if not state then print("[bunet] no state") return end
print("[bunet] supplied", tostring(state.supplied), "enabled", tostring(state.enabled), "load", string.format("%.3f", state.load or 0),
    "in use", state.producer and (state.producer.source or (state.producer.x .. "," .. state.producer.y)) or "none")
for i, producer in ipairs(state.producers or {}) do
    print("[bunet]  ", i, producer.source or (producer.x .. "," .. producer.y .. "," .. producer.z), "available", tostring(producer.available),
        "fuel", tostring(producer.fuel), "activated", tostring(producer.activated))
end
