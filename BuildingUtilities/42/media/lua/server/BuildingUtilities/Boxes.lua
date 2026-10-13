-- Where the world is decided, each box shows its state (BU.PanelLook): as its square loads, where a box of an older
-- save takes this mod's console, and each minute, for what changed without a change of the mod's (a generator ran
-- out, the grid went off). What a change of the mod's does shows at once (Sync.changed).
require "BuildingUtilities/PanelLook"
require "BuildingUtilities/Nearby"
local BU = BuildingUtilities
local Panels, PanelLook = BU.Panels, BU.PanelLook

-- A multiplayer client is told by the server.
if isClient() then return end

-- The old sprites are the game's own terminal too: one without mod data is not a box.
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
