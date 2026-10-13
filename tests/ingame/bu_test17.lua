-- Batch 6: the energy record. "[bu17]" lines. Leaves the panel as it was.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store = BU.Store
local say = BUT.say("bu17")
local panel = BUT.nearPanel(true)
if not panel then say("no panel"); return end
say("store version", Store.data().version, "panels fn ok", Store.panels() == Store.data().panels)


-- The energy record: two made-up hours.
local log, now = panel.energyLog, panel.energyNow
panel.energyLog, panel.energyNow = nil, nil
Store.recordEnergy(panel, 0.2, 0.3, 0.5)
Store.recordEnergy(panel, 0.4, 0.1, 0.6)
panel.energyNow.hour = panel.energyNow.hour - 1
Store.recordEnergy(panel, 0.1, 0.1, nil)
local first = panel.energyLog and panel.energyLog[1]
say("record", panel.energyLog and #panel.energyLog, "made", first and string.format("%.2f", first.made), "used", first and string.format("%.2f", first.used),
    "charge", first and first.charge, "now n", panel.energyNow.n)
for _ = 1, 60 do
    panel.energyNow.hour = panel.energyNow.hour - 1
    Store.recordEnergy(panel, 0, 0, nil)
end
say("kept", #panel.energyLog, "of", Store.ENERGY_HOURS)
panel.energyLog, panel.energyNow = log, now
say("restored")
