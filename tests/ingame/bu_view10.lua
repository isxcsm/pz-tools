-- Reloads the plan and window, then opens the test box with the range shown and devices outside being chosen.
local BU = BuildingUtilities
local id = ModData.get("BU10TEST").panel
local player = getPlayer()
if BU.PanelWindow.isOpen(id) then BU.PanelWindow.open(player, BU.Store.get(id)):close() end
local base = "C:/Users/isxcs/Zomboid/mods/BuildingUtilities/42/media/lua/"
for _, file in ipairs({ "client/BuildingUtilities/PanelPlan.lua", "client/BuildingUtilities/PanelWindow.lua" }) do
    print("[bv] reload", file, pcall(reloadLuaFile, base .. file))
end
BU.PanelWindow.planShown = true
local w = BU.PanelWindow.open(player, BU.Store.get(id))
w:onRange()
w:setChoosing("power", true)
local list = w.lists.power
for index, item in ipairs(list.items) do
    if item.item.kind == "batch" then list:ensureVisible(math.min(#list.items, index + 8)) end
end
-- Two chosen, to show the total.
local n = 0
for _, device in ipairs(w.views.power.devices) do
    if not device.inside and device.state == "off" and n < 2 then w:toggleChosen(device.key); n = n + 1 end
end
print("[bv] edges", #w.plan.edges, "scale", w.plan.scale)
