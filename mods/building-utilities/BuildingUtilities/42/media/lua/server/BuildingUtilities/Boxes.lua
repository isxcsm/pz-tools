-- Where the world is decided, each box shows its state, tier and place (BU.PanelLook): as its square loads, and each
-- minute, for what changed without a change of the mod's (a generator ran out, the grid went off). What a change of
-- the mod's does shows at once (Sync.changed).
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/Nearby"
local BU = BuildingUtilities
local Panels, PanelLook = BU.Panels, BU.PanelLook

-- A multiplayer client is told by the server.
if isClient() then return end

-- A tile without mod data is not a box (one placed by other means).
for _, sprite in ipairs(PanelLook.ALL) do
    MapObjects.OnLoadWithSprite(sprite, function(object)
        local panel = object:hasModData() and Panels.ofObject(object)
        if panel then PanelLook.show(panel, object) end
    end, 5)
end

-- Each minute, the boxes near a player (BU.Nearby): a far one is not loaded, and shows as its square loads.
Events.EveryOneMinute.Add(function()
    local _, near = BU.Nearby.hotPanels()
    for _, panel in ipairs(near) do PanelLook.show(panel) end
end)
