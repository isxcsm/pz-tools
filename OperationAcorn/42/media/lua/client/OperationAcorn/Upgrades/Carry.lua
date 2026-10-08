-- 옮기기 속도: the time it takes to move an item between containers, or to pick one up from the floor, shrinks with the
-- node (and the board's transfer node), and with the weight the carry nodes take off (the time follows the weight up
-- to 3). The vanilla actions are wrapped, not replaced: the original builds the action and the time is scaled after,
-- so other mods that wrap them (SOTO, ETW) keep working in their own order.
require "TimedActions/ISInventoryTransferAction"
require "ISUI/ISWorldObjectContextMenu"
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Effects = OA.Upgrades.Effects
local Carry = {}
OA.Upgrades.Carry = Carry

-- How much of its time an action moving `item` keeps for this character (1: unchanged).
function Carry.timeFactor(character, item)
    local record = OA.Client.record(character)
    if not record then return 1 end
    local u = Rules.section(record)
    local factor = Rules.transferTime(u)
    if item then
        local eff = Effects.efficiencyOf(item)
        if eff > 0 then factor = factor * Rules.weightRatio(item:getActualWeight(), eff) end
    end
    return factor
end

local originalNew = ISInventoryTransferAction.new

function ISInventoryTransferAction:new(character, item, srcContainer, destContainer, time)
    local o = originalNew(self, character, item, srcContainer, destContainer, time)
    -- an explicit time, an instant action, or a server-timed one (-1) is left alone
    if time or not o or not o.maxTime or o.maxTime <= 1 or not item then return o end
    local factor = Carry.timeFactor(character, item)
    if factor < 1 then
        o.maxTime = o.maxTime * factor
        if o.queueList and o.queueList[1] then o.queueList[1].time = o.maxTime end
    end
    return o
end

local originalGrab = ISWorldObjectContextMenu.grabItemTime

ISWorldObjectContextMenu.grabItemTime = function(playerObj, witem)
    local time = originalGrab(playerObj, witem)
    if time <= 1 then return time end
    local ok, factor = pcall(Carry.timeFactor, playerObj, witem and witem:getItem())
    if ok and factor < 1 then return time * factor end
    return time
end

return Carry
