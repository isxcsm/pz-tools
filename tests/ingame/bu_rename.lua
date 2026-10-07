-- Puts a box down in the gas station, opens its window and the rename box; RUN again with BURENAME_DONE to take it away.
local BU = BuildingUtilities
if BURENAME_DONE then
    for _, panel in ipairs(BU.Store.list()) do BU.Panels.remove(panel) end
    ModData.remove("BUTEST")
    print("[burename] removed; panels", #BU.Store.list())
    return
end
local square = getCell():getGridSquare(3571, 10892, 0)
local panel = BU.Panels.install(square, BU.PANEL_SPRITES[2])
local window = BU.PanelWindow.open(getPlayer(), panel)
window:onRename()
print("[burename] window at", window:getAbsoluteX(), window:getAbsoluteY())
