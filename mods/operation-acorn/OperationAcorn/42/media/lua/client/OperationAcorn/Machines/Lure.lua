-- The lure where it is drawn: the extension API is told to step the working lures' rings (Machines.declareAnim), and a
-- lure taken back while it worked says in its tooltip how long it has left (it goes on from there when it is put down
-- again). The line goes on the item's tooltip by TipLines, as the gear's lines do.
require "OperationAcorn/TipLines"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data

local LURE = Machines.itemFullType("lure")

-- The lines a lure adds to its tooltip: the time it has left, or nil.
local function leftLines(item)
    if item:getFullType() ~= LURE or not item:hasModData() then return nil end
    local left = item:getModData()[Data.LURE_LEFT_KEY]
    if type(left) ~= "number" then return nil end
    -- hours to a tenth, no ".0"
    local tenths = math.floor(left * 10 + 0.5)
    local hours = OA.remainder(tenths, 10) == 0 and tostring(tenths / 10) or string.format("%.1f", tenths / 10)
    return { getText("IGUI_OA_Machine_LureLeft") .. ": " .. getText("IGUI_OA_Machine_Hours", hours) }
end
OA.TipLines.add("lure", leftLines)

Events.OnGameStart.Add(Machines.declareAnim)
