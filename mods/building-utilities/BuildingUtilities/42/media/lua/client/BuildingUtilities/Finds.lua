-- The first utility panel a character finds: as the loot window shows a container the loot put one in (its owner
-- marked: BU.BOX_MARK), its line is lit (the game's own blink, as the tutorial's) and the character says what it
-- is good for. Once for each character (FOUND, their mod data). Only the marked owners are looked into, never the
-- containers' items as such.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Finds = {}
BU.Finds = Finds

Finds.FOUND = "buFoundBox"
local MARK, BOX = BU.BOX_MARK, BU.PANEL_ITEM
local BOX_TYPE = BOX:match("[^%.]+$")
-- How long the line blinks, in milliseconds.
local BLINK_MS = 20000

-- Whether the loot put a utility panel in a container (its object's or its vehicle part's mark).
local function marked(container)
    local owner = container:getVehiclePart() or container:getParent()
    return owner ~= nil and owner:hasModData() and owner:getModData()[MARK] == true
end

-- The loot window's containers as it is refreshed: the first marked one that still holds a panel, for a character
-- who has found none yet; the blink ends after a while.
function Finds.onRefresh(page, state)
    if state ~= "buttonsAdded" or page.onCharacter then return end
    local pane = page.inventoryPane
    if pane.highlightItem == BOX_TYPE and getTimestampMs() - (page.buBlinkAt or 0) > BLINK_MS then
        pane.highlightItem = nil
    end
    local player = getSpecificPlayer(page.player)
    if not player or player:getModData()[Finds.FOUND] or not BU.enabled("panel") then return end
    for _, button in ipairs(page.backpacks) do
        local container = button.inventory
        if container and marked(container) and container:containsType(BOX) then
            player:getModData()[Finds.FOUND] = true
            pane.highlightItem = BOX_TYPE
            page.buBlinkAt = getTimestampMs()
            player:Say(getText("IGUI_BU_SayFoundBox"))
            return
        end
    end
end

Events.OnRefreshInventoryWindowContainers.Add(Finds.onRefresh)

return Finds
