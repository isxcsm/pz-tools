-- Four tiers and the name: capacity, ranges and unlocks per tier. "[bu12]" lines. Leaves nothing behind.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local say = BUT.say("bu12")
say("tiers", BU.TIERS, "cut", BU.CUT_TIER, "timer", BU.TIMER_TIER, "log", BU.LOG_TIER, "graph", BU.GRAPH_TIER)
for tier = 1, BU.TIERS do
    say("tier", tier, "capacity", BU.capacity(tier), "ranges", BU.connectRange(tier), "floors", tostring(BU.floorReach(tier)),
        "cost skill", BU.Costs.upgrade(tier) and BU.Costs.upgrade(tier).skill or "-")
end
for tier = 2, BU.TIERS do
    say("upgrade note " .. tier .. ":", (BU.Panels.upgradeNote(tier, true):gsub("\n", " | ")))
end
say("names", getText("IGUI_BU_PanelDefault"), getText("ContextMenu_BU_Install"),
    getItemNameFromFullType("BuildingUtilities.BreakerBox"), "tabs", getText("IGUI_BU_Tab_power"), getText("IGUI_BU_Tab_water"))
