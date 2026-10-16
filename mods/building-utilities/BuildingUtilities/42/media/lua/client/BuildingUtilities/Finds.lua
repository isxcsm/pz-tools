-- The first utility panel a character finds, in one of two ways, and the character says what it is good for. Once for
-- each character (FOUND, their mod data), on the loot window's refresh (the game runs it as the character steps onto
-- another square or turns, and as a container's contents change): nothing runs while they stand, nor once they have
-- found one.
--   * In a container the loot put one in (its owner marked: BU.BOX_MARK), as the loot window shows it: its line is lit
--     (the game's own blink, as the tutorial's). Only the marked owners are looked into, never the containers' items
--     as such.
--   * Standing where the map put one beside a generator (BU.Spawned), in sight within REACH squares: the game's object
--     outline is turned on around it for a while. Only the kept places of the cells around the character are looked
--     at; one whose box is gone is forgotten.
require "BuildingUtilities/Core"
require "BuildingUtilities/Panels"
require "BuildingUtilities/Spawned"
local BU = BuildingUtilities
local Finds = {}
BU.Finds = Finds

Finds.FOUND = "buFoundBox"
Finds.REACH = 6
local MARK, BOX = BU.BOX_MARK, BU.PANEL_ITEM
local BOX_TYPE = BOX:match("[^%.]+$")
-- How long the line blinks and the outline stays, in milliseconds.
local BLINK_MS = 20000
-- The outline's colour.
local OUTLINE = { 1, 0.82, 0.4 }

-- The spawned box lit, by the loot page's player: { object, at, x, y }.
local lit = {}

-- Whether the loot put a utility panel in a container (its object's or its vehicle part's mark).
local function marked(container)
    local owner = container:getVehiclePart() or container:getParent()
    return owner ~= nil and owner:hasModData() and owner:getModData()[MARK] == true
end

-- The outline goes after a while, or once the character has walked away from it.
local function dim(playerNum, player)
    local shown = lit[playerNum]
    if not shown then return end
    local far = math.abs(player:getX() - shown.x) > Finds.REACH + 2 or math.abs(player:getY() - shown.y) > Finds.REACH + 2
    if not far and getTimestampMs() - shown.at <= BLINK_MS then return end
    shown.object:setOutlineHighlight(playerNum, false)
    lit[playerNum] = nil
end

local function found(player)
    player:getModData()[Finds.FOUND] = true
    player:Say(getText("IGUI_BU_SayFoundBox"))
end

-- A spawned box in sight near the character: outlined, and found.
local function spawnedNear(playerNum, player)
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local cell = getCell()
    for _, place in ipairs(BU.Spawned.near(x, y, z, Finds.REACH)) do
        local square = cell:getGridSquare(place.x, place.y, place.z)
        local box = square and BU.Panels.bareOn(square)
        if square and not box then
            -- taken up or gone: where the world is decided, it is no longer kept
            if not isClient() then BU.Spawned.forget(place) end
        elseif box and square:isCanSee(playerNum) then
            box:setOutlineHighlightCol(playerNum, OUTLINE[1], OUTLINE[2], OUTLINE[3], 1)
            box:setOutlineHighlight(playerNum, true)
            lit[playerNum] = { object = box, at = getTimestampMs(), x = place.x, y = place.y }
            found(player)
            return
        end
    end
end

-- The loot window refreshed: a blink or outline that has had its time ends; for a character who has found none yet,
-- the first marked container that still holds a panel, else a spawned box in sight.
function Finds.onRefresh(page, state)
    if state ~= "buttonsAdded" or page.onCharacter then return end
    local pane = page.inventoryPane
    if pane.highlightItem == BOX_TYPE and getTimestampMs() - (page.buBlinkAt or 0) > BLINK_MS then
        pane.highlightItem = nil
    end
    local player = getSpecificPlayer(page.player)
    if not player then return end
    dim(page.player, player)
    if player:getModData()[Finds.FOUND] or not BU.enabled("panel") then return end
    for _, button in ipairs(page.backpacks) do
        local container = button.inventory
        if container and marked(container) and container:containsType(BOX) then
            pane.highlightItem = BOX_TYPE
            page.buBlinkAt = getTimestampMs()
            found(player)
            return
        end
    end
    spawnedNear(page.player, player)
end

Events.OnRefreshInventoryWindowContainers.Add(Finds.onRefresh)

return Finds
