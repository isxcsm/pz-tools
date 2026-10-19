-- 옮기기 속도: the time it takes to move an item between containers, or to pick one up from the floor, shrinks with the
-- node (and the board's transfer node), and with the weight the carry nodes take off (the time follows the weight up
-- to 3). The vanilla actions are wrapped, not replaced: the original builds the action and the time is scaled after,
-- so other mods that wrap them (SOTO, ETW) keep working in their own order. The first time a transfer leaves the bags over
-- the game's weight limit with 과적 적응 taken is that node's first effect (First.lua).
require "TimedActions/ISInventoryTransferAction"
require "ISUI/ISWorldObjectContextMenu"
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/First"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Effects = OA.Upgrades.Effects
local First = OA.Upgrades.First
local Carry = {}
OA.Upgrades.Carry = Carry

-- The transfer nodes' factor of a section, worked out once until the record is told to have changed (the research
-- tab's "upgrades" and "all" changes): section -> { revision, factor }. It follows the ranks and the effect size
-- option, which does not change under a running game.
local revision = 0
local transferOf = {}
local function changed() revision = revision + 1 end
OA.Sync.listen("upgrades", changed)
OA.Sync.listen("all", changed)

-- How much of its time an action moving `item` keeps for this character (1: unchanged).
function Carry.timeFactor(character, item)
    local record = OA.Client.record(character)
    if not record then return 1 end
    local u = Rules.section(record)
    local kept = transferOf[u]
    if not kept then
        kept = { revision = -1, factor = 1 }
        transferOf[u] = kept
    end
    if kept.revision ~= revision then
        kept.revision, kept.factor = revision, Rules.transferTime(u)
    end
    local factor = kept.factor
    if item then
        local eff = Effects.efficiencyOf(item)
        if eff > 0 then factor = factor * Rules.weightRatio(item:getActualWeight(), eff) end
    end
    return factor
end

local originalNew = ISInventoryTransferAction.new

function ISInventoryTransferAction:new(character, item, srcContainer, destContainer, time, ...)
    local o = originalNew(self, character, item, srcContainer, destContainer, time, ...)
    -- an explicit time, an instant action, or a server-timed one (-1) is left alone
    if time or not o or not o.maxTime or o.maxTime <= 1 or not item then return o end
    local factor = Carry.timeFactor(character, item)
    if factor < 1 then
        o.maxTime = o.maxTime * factor
        if o.queueList and o.queueList[1] then o.queueList[1].time = o.maxTime end
    end
    return o
end

-- Whether the character carries more than the game's limit, told when the weight of what it carries has changed (a
-- transfer is done): reports 과적 적응's first effect, once. Reads nothing once the node has told it or is not taken.
function Carry.checkOverload(character)
    local record = OA.Client.record(character)
    if not record then return end
    local u = Rules.section(record)
    if u.firstEffect.overload or Rules.rank(u, "overload") < 1 then return end
    if character:getInventory():getCapacityWeight() > character:getMaxWeight() then
        First.report("overload", character)
    end
end

local originalPerform = ISInventoryTransferAction.perform

-- (after the original, whose results are passed on)
local function performed(self, ...)
    local character = self.character
    if character then OA.try("carry: the overload check", Carry.checkOverload, character) end
    return ...
end

function ISInventoryTransferAction:perform(...)
    return performed(self, originalPerform(self, ...))
end

local originalGrab = ISWorldObjectContextMenu.grabItemTime

ISWorldObjectContextMenu.grabItemTime = function(playerObj, witem, ...)
    local time = originalGrab(playerObj, witem, ...)
    if time <= 1 then return time end
    local ok, factor = OA.try("carry: the pickup time", Carry.timeFactor, playerObj, witem and witem:getItem())
    if ok and factor < 1 then return time * factor end
    return time
end

return Carry
