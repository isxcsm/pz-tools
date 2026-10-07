-- Batch 2 of the plan (DESIGN 12): flows on the plan, the status lights, the relay's click. "[bu19]" lines. Opens
-- the test panel's window with the plan shown and leaves it open.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Units, Networks, PanelWindow = BU.Store, BU.Units, BU.Networks, BU.PanelWindow
local say = BUT.say("bu19")
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local state = Networks.state(panel, "power")
say("supplied", state.supplied, "in use", state.producer and (state.producer.source or "square") or "none", "bankFlow",
    string.format("%.3f", panel.bankFlow or 0), "sun", string.format("%.2f", BU.Energy.sunlight()))
for _, unit in ipairs(Store.unitList(nil, panel.id)) do
    say("unit", unit.kind, unit.x, unit.y, "flow", tostring(Units.flow(unit, panel, state)))
end
-- The rack's flow by the bank's way, with the state as it is.
local saved = panel.bankFlow
for _, flow in ipairs({ -0.2, 0.2, 0 }) do
    panel.bankFlow = flow
    for _, unit in ipairs(Store.unitList("rack", panel.id)) do
        say("bankFlow", flow, "rack flow", tostring(Units.flow(unit, panel, state)), "(in use", BU.Energy.inUse(state), ")")
    end
end
panel.bankFlow = saved
PanelWindow.planShown = true
PanelWindow.open(getPlayer(), panel)
say("lights element", ISBUStatusLights ~= nil)
-- The plan zoomed in on the box, so the short paths of the test scene show their dots.
local window = PanelWindow.get(panel.id)
window:setPlanShown(true)
window:refresh()
local plan = window.plan
local box = plan.squares[#plan.squares]
plan:zoomAt(box.x, box.y - 30, 3)
local count = 0
for _, flow in ipairs(plan.flows) do
    count = count + 1
    say("flow", count, "points", #flow.points, "length", string.format("%.1f", flow.length), "toBox", flow.toBox)
end
say("flows", count)
say("done")
