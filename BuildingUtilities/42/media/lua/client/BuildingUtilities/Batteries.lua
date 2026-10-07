-- Batteries on the player's side: a rack in the loot window with its icon and taking car batteries only, and a car
-- battery's tooltip naming its kind and what it holds in a rack next to a standard one.
require "ISUI/ISInventoryPage"
require "ISUI/ISToolTipInv"
require "BuildingUtilities/Units"
local BU = BuildingUtilities
local Units = BU.Units

ContainerButtonIcons = ContainerButtonIcons or {}
ContainerButtonIcons[Units.CONTAINER] = getTexture("media/textures/Item_BUBatteryRack.png")

-- What a container accepts does not come to clients with the rack (nor stays in the save): the loot window sets it
-- again on each rack it lists, so a player cannot drop anything else in.
Events.OnRefreshInventoryWindowContainers.Add(function(page, state)
    if state ~= "end" then return end
    for _, button in ipairs(page.backpacks or {}) do
        local container = button.inventory
        if container and container:getType() == Units.CONTAINER and container:getAcceptItemFunction() ~= Units.ACCEPT then
            container:setAcceptItemFunction(Units.ACCEPT)
        end
    end
end)

-- The tooltip's line: given to the item only while the tooltip draws, so nothing of it stays on the item.
local render = ISToolTipInv.render
function ISToolTipInv:render()
    local item = self.item
    if not Units.isBattery(item) or item:getTooltip() ~= nil then return render(self) end
    item:setTooltip("IGUI_BU_BatteryKindTip_" .. Units.batteryKind(item:getFullType()))
    local ok, err = pcall(render, self)
    item:setTooltip(nil)
    if not ok then error(err) end
end
