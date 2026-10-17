-- The opened supply crate in the loot window: things are only taken out of it, and once it is empty it breaks (its
-- wood and nails fall where it stood). It is not a storage box: a crate comes with every drop, and one kept as a box
-- of 100 each time would be free storage.
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Objects"
require "OperationAcorn/Trade/Things"
local OA = OperationAcorn
local Objects, Things = OA.Trade.Objects, OA.Trade.Things

-- crate -> true once this client asked for it to break (the server answers by taking it away)
local asked = setmetatable({}, { __mode = "k" })
-- the crates asked for and not yet gone: the loot windows are refreshed when they go (the game does not, and would
-- show the crate empty), looked at each tick only while there is one, and given up after WAIT_MS of real time. The tick
-- handler, once added, stays (one taken off inside its event makes the game skip the next one that tick).
local waiting, askedAt, hooked = {}, 0, false
local WAIT_MS = 5000

local function watch()
    if waiting[1] == nil then return end
    local gone = false
    for i = #waiting, 1, -1 do
        if waiting[i]:getObjectIndex() < 0 then
            table.remove(waiting, i)
            gone = true
        end
    end
    if gone then ISInventoryPage.dirtyUI() end
    if getTimestampMs() - askedAt > WAIT_MS then waiting = {} end
end

local function onRefresh(page, state)
    if state ~= "buttonsAdded" or page.onCharacter then return end
    local character = getSpecificPlayer(page.player)
    if not character then return end
    for _, backpack in ipairs(page.backpacks or {}) do
        local container = backpack.inventory
        local object = container and container:getParent()
        if object and Objects.kindOf(object) == Objects.CRATE then
            -- the game does not keep the take-only rule; this client checks what it drags against it
            if container:getAcceptItemFunction() ~= Objects.TAKE_ONLY then container:setAcceptItemFunction(Objects.TAKE_ONLY) end
            if not asked[object] and Things.crateEmpty(object) then
                asked[object] = true
                local square = object:getSquare()
                OA.Sync.send(character, "crateEmptied", { x = square:getX(), y = square:getY(), z = square:getZ() })
                if #waiting == 0 then askedAt = getTimestampMs() end
                if not hooked then
                    hooked = true
                    Events.OnTick.Add(watch)
                end
                waiting[#waiting + 1] = object
            end
        end
    end
end
Events.OnRefreshInventoryWindowContainers.Add(onRefresh)

-- Taking a heavy thing up with both hands refreshes the loot window only in multiplayer (the game's ISEquipHeavyItem
-- marks it dirty under isClient() alone), so the last thing taken out of a crate that way left it standing, shown
-- empty, until the player moved. Marked here for a crate as every other way of taking does.
local equipHeavy = ISEquipHeavyItem.complete
function ISEquipHeavyItem:complete()
    local source = self.item:getContainer()
    local object = source and source:getParent()
    local done = equipHeavy(self)
    if object and Objects.kindOf(object) == Objects.CRATE then ISInventoryPage.renderDirty = true end
    return done
end
