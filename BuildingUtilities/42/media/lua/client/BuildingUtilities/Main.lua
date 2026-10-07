-- Wiring: the networks from the save as the world starts, boxes that went missing, and windows that show changes.
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/PanelWindow"
local BU = BuildingUtilities

local function onGameStart()
    local api, reason = BU.api()
    if not api then
        BU.log("the PZ Tools extension API is", reason == "version" and "another version" or "missing", "- boxes do nothing")
        return
    end
    BU.Networks.defineAll()
    BU.log("defined the networks of", #BU.Store.list(), "panels")
end

local function onNetworkChange(id) BU.PanelWindow.onNetworkChange(id) end

Events.OnGameStart.Add(onGameStart)
Events.EveryTenMinutes.Add(BU.Panels.checkObjects)
if Events.OnPZToolsNetworkChange then Events.OnPZToolsNetworkChange.Add(onNetworkChange) end
