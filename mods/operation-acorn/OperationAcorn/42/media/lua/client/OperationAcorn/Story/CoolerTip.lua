-- The sample cooler a mission has the player carry says in its tooltip how warm it is now: the temperature sets what
-- the mission pays, and the card at the terminal is far while it is carried. The line goes on the item's tooltip by
-- TipLines, as the gear's lines do.
require "OperationAcorn/TipLines"
require "OperationAcorn/Client"
require "OperationAcorn/Story/Missions"
local OA = OperationAcorn
local Missions = OA.Missions

local function coolerLines(item)
    if not item:hasModData() then return nil end
    local id = item:getModData().OA_Mission
    if not id then return nil end
    local player = getPlayer()
    local record = player and OA.Client.record(player)
    local m = record and Missions.pieceOf(record, id)
    if not (m and m.carry) then return nil end
    return { getText("Tooltip_OA_CoolerTemp", string.format("%.1f", Missions.coolerTemp(m, OA.hours()))) }
end
OA.TipLines.add("cooler", coolerLines)
