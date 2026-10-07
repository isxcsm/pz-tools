-- The open plan's flow paths and squares, to see where the dots should be. "[buflow]" lines.
local BU = BuildingUtilities
local panel = BU.Store.get(ModData.getOrCreate("BUTEST").panel)
local window = BU.PanelWindow.get(panel.id)
if not window then print("[buflow] no window") return end
local plan = window.plan
print("[buflow] visible", plan:getIsVisible(), "size", plan.width, plan.height, "map", plan.map and plan.map.left, plan.map and plan.map.top)
for i, flow in ipairs(plan.flows) do
    local parts = {}
    for _, p in ipairs(flow.points) do parts[#parts + 1] = string.format("(%.0f,%.0f)", p[1], p[2]) end
    print("[buflow] flow", i, table.concat(parts, " "), "len", string.format("%.1f", flow.length), "rgb", flow.r, flow.g, flow.b)
end
for i, s in ipairs(plan.squares) do print("[buflow] square", i, s.x, s.y, s.size) end
print("[buflow] moved", BU.remainder(getTimestampMs() / 1000 * 24, 14))
