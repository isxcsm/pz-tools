-- Noon, and the test scene again if the restart lost it (bu_setup, bu_visual).
getGameTime():setTimeOfDay(12)
local BU = BuildingUtilities
local id = ModData.getOrCreate("BUTEST").panel
local panel = BU.Store.get(id)
if not panel or not BU.Panels.object(panel) then
    if panel then BU.Changes.remove(panel) end
    RUN("bu_setup.lua")
end
if #BU.Store.unitList() == 0 then RUN("bu_visual.lua") end
print("[bunoon] panel", ModData.getOrCreate("BUTEST").panel, "units", #BU.Store.unitList())
