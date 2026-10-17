-- The first utility panel a character finds, in one of two ways, and the character says what it is good for. Once for
-- each character (FOUND, their mod data), on the loot window's refresh (the game runs it as the character steps onto
-- another square or turns, and as a container's contents change): nothing runs while they stand, nor once they have
-- found one. It is pointed out by the UI kit's spotlight (PZUIKit.Spotlight), which ends it by itself.
--   * In a container the loot put one in (its owner marked: BU.BOX_MARK), as the loot window shows it: its line
--     blinks. Only the marked owners are looked into, never the containers' items as such.
--   * Standing where the map put one beside a generator (BU.Spawned), within REACH squares in the character's line of
--     sight (dark or not): it is outlined until a while has passed, the character has walked away or touched it, or
--     it is taken up. Only the kept places of the cells around the character are looked at; one whose box is gone is
--     forgotten.
require "PZUIKit/Spotlight"
require "BuildingUtilities/Core"
require "BuildingUtilities/Panels"
require "BuildingUtilities/Spawned"
local BU = BuildingUtilities
local Spotlight = PZUIKit.Spotlight
local Finds = {}
BU.Finds = Finds

Finds.FOUND = "buFoundBox"
Finds.REACH = 6
local MARK, BOX = BU.BOX_MARK, BU.PANEL_ITEM
local BOX_TYPE = BOX:match("[^%.]+$")
-- The outline goes once the character is this far from the box; its colour, apart from Operation Acorn's outlines
-- (amber, red, teal, sky blue).
local AWAY = Finds.REACH + 2
local OUTLINE = { 0.62, 1, 0.45, 1 }

-- Whether the loot put a utility panel in a container (its object's or its vehicle part's mark).
local function marked(container)
    local owner = container:getVehiclePart() or container:getParent()
    return owner ~= nil and owner:hasModData() and owner:getModData()[MARK] == true
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
        elseif box and square:isCouldSee(playerNum) then
            Spotlight.object(playerNum, box, { reach = AWAY, color = OUTLINE })
            found(player)
            return
        end
    end
end

-- The loot window refreshed: for a character who has found none yet, the first marked container that still holds a
-- panel, else a spawned box in sight.
function Finds.onRefresh(page, state)
    if state ~= "buttonsAdded" or page.onCharacter then return end
    local player = getSpecificPlayer(page.player)
    if not player or player:getModData()[Finds.FOUND] or not BU.enabled("panel") then return end
    for _, button in ipairs(page.backpacks) do
        local container = button.inventory
        if container and marked(container) and container:containsType(BOX) then
            Spotlight.lootLine(page.player, BOX_TYPE)
            found(player)
            return
        end
    end
    spawnedNear(page.player, player)
end

Events.OnRefreshInventoryWindowContainers.Add(Finds.onRefresh)

return Finds
