-- The rack's state (bu_rackdiag) and the test panel's window opened.
RUN("bu_rackdiag.lua")
local BU = BuildingUtilities
BU.PanelWindow.open(getPlayer(), BU.Store.get(ModData.getOrCreate("BUTEST").panel))
