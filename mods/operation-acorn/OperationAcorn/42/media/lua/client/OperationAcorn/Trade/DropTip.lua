-- Items dropped on the delivery box that it does not take (DESIGN 9): the game leaves them where they were, with no
-- word. The reason the item's tooltip gives is shown where the mouse let go, for a moment (a hint of the screen, not a
-- title or self-talk: the eye is on the drop). Only what the player dragged is looked at, once, as it is dropped.
require "ISUI/ISToolTip"
require "ISUI/ISInventoryPane"
require "ISUI/ISInventoryPage"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/Objects"
local OA = OperationAcorn
local Objects = OA.Trade.Objects
local DropTip = {}
OA.Trade.DropTip = DropTip

DropTip.SHOW_MS = 2000
DropTip.COLOR = "<RGB:0.9,0.55,0.5>"

-- Why the box's container does not take the item: a translation key (the appraisal's reason), or nil when it does.
function DropTip.reason(container, item)
    if container:isItemAllowed(item) then return nil end
    if Objects.abandoned(container:getParent()) then return "IGUI_OA_Trade_Drop_Abandoned" end
    local Value = OA.Value
    if not (Value and Value.info and Value.accepts) then return "IGUI_OA_Trade_Tip_NotTaken" end
    local ok, info = OA.try("drop tip: the info of an item", Value.info, item)
    if not ok or not info then return "IGUI_OA_Trade_Tip_NotTaken" end
    local _, why = Value.accepts(info)
    return why or "IGUI_OA_Trade_Tip_NotTaken"
end

-- The lines for a drop on a container: nil when it is not a delivery box or it took all. `items`: what was dragged.
-- Several dragged: how many were left out first; then each reason once (two at most).
function DropTip.lines(container, items)
    if not (container and container:getAcceptItemFunction() == Objects.ACCEPT) then return nil end
    local left, reasons, seen = 0, {}, {}
    for _, item in ipairs(items) do
        if item:getContainer() ~= container and not container:isInside(item) then
            local why = DropTip.reason(container, item)
            if why then
                left = left + 1
                if not seen[why] and #reasons < 2 then
                    seen[why] = true
                    reasons[#reasons + 1] = why
                end
            end
        end
    end
    if left == 0 then return nil end
    local lines = {}
    if #items > 1 then lines[1] = getText("IGUI_OA_Trade_Drop_Some", left) end
    for _, why in ipairs(reasons) do lines[#lines + 1] = getText(why) end
    return lines
end

-- One tip at a time, where the mouse let go; it takes itself away when its time is up.
local current
function DropTip.show(lines)
    if current then current:removeFromUIManager() end
    local tip = ISToolTip:new()
    tip:initialise()
    tip.description = DropTip.COLOR .. table.concat(lines, " <LINE> " .. DropTip.COLOR)
    tip:setDesiredPosition(getMouseX() + 16, getMouseY() + 8)
    tip:addToUIManager()
    tip:setAlwaysOnTop(true)
    local until_ = getTimestampMs() + DropTip.SHOW_MS
    local prerender = tip.prerender
    tip.prerender = function(self)
        if getTimestampMs() >= until_ then
            self:removeFromUIManager()
            if current == self then current = nil end
            return
        end
        prerender(self)
    end
    current = tip
end

local function dropped(container, dragging)
    local lines = DropTip.lines(container, ISInventoryPane.getActualItems(dragging))
    if lines then DropTip.show(lines) end
end

-- The game's functions below are left as they are while the mod is off (OA.off).
if OA.off then return DropTip end

-- A drop on an inventory pane (the box's window), and on a container's button at the side: what was dragged is
-- known only before the game's handler clears it.
local paneUp = ISInventoryPane.onMouseUp
-- (silent: the game's own handler sounds the drop, as it did)
function ISInventoryPane:onMouseUp(x, y)
    local dragging = self.player == 0 and ISMouseDrag.dragging
    local onto = dragging and ISMouseDrag.draggingFocus and ISMouseDrag.draggingFocus ~= self and self.inventory
    local result = paneUp(self, x, y)
    if onto then OA.try("drop tip: a pane", dropped, onto, dragging) end
    return result
end

local pageDrop = ISInventoryPage.dropItemsInContainer
function ISInventoryPage:dropItemsInContainer(button)
    local dragging = self.player == 0 and ISMouseDrag.dragging
    local onto = dragging and self.mouseOverButton and self.mouseOverButton.inventory
    local result = pageDrop(self, button)
    if onto then OA.try("drop tip: a container button", dropped, onto, dragging) end
    return result
end

return DropTip
