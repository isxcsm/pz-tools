-- A lure taken back while it worked says in its tooltip how long it has left (it goes on from there when it is put
-- down again). The line is put on the item while its tooltip is drawn and taken off after, as the gear's lines are.
require "ISUI/ISToolTipInv"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data

local LURE = Machines.itemFullType("lure")

local originalRender = ISToolTipInv.render
function ISToolTipInv:render()
    local item = self.item
    local left = item and item:getFullType() == LURE and item:getModData()[Data.LURE_LEFT_KEY]
    if type(left) ~= "number" then return originalRender(self) end
    local old = item:getTooltip()
    -- hours to a tenth, no ".0"
    local tenths = math.floor(left * 10 + 0.5)
    local hours = tenths % 10 == 0 and tostring(tenths / 10) or string.format("%.1f", tenths / 10)
    local text = getText("IGUI_OA_Machine_LureLeft") .. ": " .. getText("IGUI_OA_Machine_Hours", hours)
    if old and old ~= "" then text = getText(old) .. " <LINE> " .. text end
    item:setTooltip(OA.tooltipText(text))
    local ok, err = pcall(originalRender, self)
    item:setTooltip(old)
    if not ok then error(err, 0) end
end
