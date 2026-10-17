-- The corpse menu of the zombie samples (Story/Harvest): 'quick harvest' on a zombie's corpse, and 'precise harvest'
-- too for a character that has received tweezers. Opening the menu looks at the mark only; the kit and the
-- tweezers are looked for once, when a harvest is chosen: a kit carried but not held is taken into the hand first
-- (the game's equipping, from a bag too). A corpse that gives nothing shows the options greyed with the reason. The
-- action takes the time; the server gives the sample.
require "ISUI/ISWorldObjectContextMenu"
require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISTimedActionQueue"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Harvest"
local OA = OperationAcorn
local Harvest = OA.Harvest

ISOAHarvestAction = ISBaseTimedAction:derive("ISOAHarvestAction")

function ISOAHarvestAction:new(character, body, precise)
    local o = ISBaseTimedAction.new(self, character)
    o.body = body
    o.precise = precise == true
    local time = precise and Harvest.PRECISE_TIME or Harvest.QUICK_TIME
    o.maxTime = (character:isTimedActionInstant() and 1) or time
    o.stopOnWalk = true
    o.stopOnRun = true
    return o
end

function ISOAHarvestAction:isValid()
    return self.body:getSquare() ~= nil and Harvest.holdsKit(self.character)
end

function ISOAHarvestAction:waitToStart()
    self.character:faceThisObject(self.body)
    return self.character:shouldBeTurning()
end

function ISOAHarvestAction:update()
    self.character:faceThisObject(self.body)
end

function ISOAHarvestAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
end

function ISOAHarvestAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISOAHarvestAction:perform()
    local sq = self.body:getSquare()
    if sq then
        OA.Sync.send(self.character, "story_harvest", { x = sq:getX(), y = sq:getY(), z = sq:getZ(),
            death = self.body:getDeathTime(), precise = self.precise })
    end
    ISBaseTimedAction.perform(self)
end

local function harvest(player, body, precise)
    local inventory = player:getInventory()
    -- oa-scan: ok (once, as a harvest is chosen)
    local kit = not Harvest.holdsKit(player) and inventory:getFirstTypeRecurse(Harvest.KIT) or nil
    if not Harvest.holdsKit(player) and not kit then
        HaloTextHelper.addText(player, getText("IGUI_OA_Story_HarvestFail_kit"))
        return
    end
    -- oa-scan: ok (once, as the precise harvest is chosen)
    if precise and not inventory:containsTypeRecurse(Harvest.TWEEZERS) then
        HaloTextHelper.addText(player, getText("IGUI_OA_Story_HarvestFail_tweezers"))
        return
    end
    local sq = body:getSquare()
    if sq and luautils.walkAdj(player, sq, true) then
        if kit then ISInventoryPaneContextMenu.equipWeapon(kit, true, false, player:getPlayerNum()) end
        ISTimedActionQueue.add(ISOAHarvestAction:new(player, body, precise))
    end
end

local function onFillWorld(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    -- (the samples are the team's: nothing to harvest for before the terminal is used)
    if not OA.Trust.contacted(OA.Client.record(player)) then return end
    local body = ISWorldObjectContextMenu.fetchVars and ISWorldObjectContextMenu.fetchVars.body
    if not (body and instanceof(body, "IsoDeadBody") and body:isZombie()) then return end
    local why = Harvest.refusal(Harvest.describe(body), OA.hours())
    -- on top of the game's menu, the quick harvest first (each option added goes above the last)
    local function add(key, precise)
        local option = context:addOptionOnTop(getText(key), player, function(p) harvest(p, body, precise) end)
        if why then
            option.notAvailable = true
            local tip = ISWorldObjectContextMenu.addToolTip()
            tip.description = getText("Tooltip_OA_Harvest_" .. why)
            option.toolTip = tip
        end
    end
    if Harvest.precise(OA.Client.record(player)) then add("ContextMenu_OA_Harvest_Precise", true) end
    add("ContextMenu_OA_Harvest_Quick", false)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorld)
