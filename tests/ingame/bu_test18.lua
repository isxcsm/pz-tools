-- Batch 1 of the plan (DESIGN 12): the window's status line, the time format, stats, the empty hint. "[bu18]" lines.
-- The trip and quiet cut are set on the panel's data only for the reading and put back; the window opens at the end.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, PanelWindow, Ui = BU.Store, BU.PanelWindow, BU.PanelUi
local say = BUT.say("bu18")
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local function show(label)
    for _, utility in ipairs(BU.UTILITIES) do
        local s = PanelWindow.status(panel, utility)
        say(label, utility, s.level, "|", s.text, "|", s.left or "-", "|", s.reason or "-")
    end
end
say("grid", tostring(getWorld():isHydroPowerOn()), "tier", panel.tier, "bankFlow", panel.bankFlow or "-")
show("now")
say("durations", Ui.duration(0.4), "/", Ui.duration(5.4), "/", Ui.duration(71))
local tripped, quiet = panel.tripped, panel.quietCut
panel.tripped = true
show("tripped")
panel.tripped, panel.quietCut = tripped, true
show("quiet")
panel.quietCut = quiet
local stats = panel.stats
say("stats", stats and string.format("since %.2f carried %.3f saved %s outage %s", stats.since, stats.carried or 0,
    tostring(stats.saved), tostring(stats.outage)) or "none yet")
for _, child in ipairs(Store.children(panel.id)) do
    local s = PanelWindow.status(child, "power")
    say("child", child.id, s.level, "|", s.text, "|", s.reason or "-")
end
PanelWindow.open(getPlayer(), panel)
say("done")
