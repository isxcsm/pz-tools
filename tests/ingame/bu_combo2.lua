-- For bu_combo: what the water units installed by hand do now, the crops' water, the box's power; then the box's
-- window on its water tab. "[bucombo2]" lines.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Networks, Units, WaterUnits, PanelWindow = BU.Store, BU.Networks, BU.Units, BU.WaterUnits, BU.PanelWindow
local say = BUT.say("bucombo2")
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local power = Networks.state(panel, "power")
say("power supplied", power and power.supplied, "load", power and power.load, "extra", power and power.extraLoad,
    "producer", power and power.producer and (power.producer.x .. "," .. power.producer.y), "pumps load",
    panel.extraLoads and panel.extraLoads.pumps)
local group = Networks.groupState(panel, BU.Water.FIRST)
say("water group 1 held", group and group.amount, "of", group and group.capacity, "purify", group and group.purify)
for _, unit in ipairs(Units.of(panel.id, "water")) do
    say(unit.kind, unit.id, "at", unit.x, unit.y, "running", unit.running, "idle", unit.idle, "fluid", unit.fluid,
        "sprayedAt", unit.sprayedAt, "media", unit.media and string.format("%.1f", unit.media))
end
local system = SFarmingSystem.instance
for _, at in ipairs({ { 3577, 10890 }, { 3578, 10890 } }) do
    local plant = system:getLuaObjectAt(at[1], at[2], 0)
    say("crop", at[1], at[2], plant and plant.state, "water", plant and plant.waterLvl, "needs", plant and plant.waterNeeded)
end
PanelWindow.planShown = true
PanelWindow.open(getPlayer(), panel)
local window = PanelWindow.get(panel.id)
window.tabs:activateView(getText("IGUI_BU_Tab_water"))
window:refresh()
