-- Opens the nearest Building Utilities box's window (raised to tier 4, so every tab shows) on its tab number
-- BU_TAB (1 first), for a look at its text; closes the terminal first. Prints the tabs' names.
local BU = BuildingUtilities
local player = getPlayer()
local term = OATerminalWindow and OATerminalWindow.instances[player:getPlayerNum()]
if term then term:close() end
local best, bestD
for _, panel in pairs(BU.Store.list()) do
    local d = math.abs(panel.x - player:getX()) + math.abs(panel.y - player:getY())
    if panel.z == math.floor(player:getZ()) and (not bestD or d < bestD) then best, bestD = panel, d end
end
if not best then print("BUWIN no box") return end
if (best.tier or 1) < 4 then best.tier = 4; BU.Sync.changed(best.id) end
local window = BU.PanelWindow.open(player, best)
if window.utilitiesKey then window.utilitiesKey = nil; window:refresh() end
window = BU.PanelWindow.get(best.id) or window
local names = {}
for i, view in ipairs(window.tabs.viewList) do names[i] = view.name end
print("BUWIN tabs " .. table.concat(names, " | "))
local tab = names[BU_TAB or 1]
if tab then window.tabs:activateView(tab) end
print("BUWIN shown " .. tostring(tab))
