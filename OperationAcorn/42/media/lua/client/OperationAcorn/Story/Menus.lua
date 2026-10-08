-- The story's context menus: reading an item's paper, the field call device, leaving the sealed case at a drop, a
-- soil sample from the ground, and a survey stake. Each only offers what the character's mission asks for; the
-- server judges the rest.
require "ISUI/ISInventoryPane"
require "ISUI/ISWorldObjectContextMenu"
require "TimedActions/ISTimedActionQueue"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/Viewer"
require "OperationAcorn/Story/Action"
local OA = OperationAcorn
local Data, Places, Docs = OA.StoryData, OA.Places, OA.StoryDocs
local Menus = {}
OA.StoryMenus = Menus

local SOIL_NEAR = 25

local function activeMission(player)
    local record = OA.Client.record(player)
    return record and record.missions and record.missions.active or nil, record
end

-- ---------------------------------------------------------------------------------------------------------------
-- Inventory.

local function onFillInventory(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    local m, record = activeMission(player)
    local read, field, swap = false, false, false
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        local name = Data.itemName(item:getFullType())
        if name then
            local md = item:getModData()
            if not read then
                local docs = Docs.forItem(record, name, md)
                if #docs > 0 then
                    read = true
                    context:addOption(getText("ContextMenu_OA_Story_Read"), player, function(p)
                        OA.StoryViewer.open(p, docs)
                    end)
                end
            end
            if name == "FieldCallDevice" and not field and m and m.field and m.state == "open" then
                field = true
                context:addOption(getText("ContextMenu_OA_Story_FieldCall"), player, function(p)
                    OA.Sync.send(p, "story_field", {})
                end)
            end
            if name == "SampleCase" and not swap and m and m.swap and m.swap.stage == "needcase" and m.state == "open" then
                swap = true
                context:addOption(getText("ContextMenu_OA_Story_LeaveCase"), player, function(p)
                    OA.Sync.send(p, "story_swap", {})
                end)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The ground and the stakes.

local function stakeObject(worldobjects)
    for _, obj in ipairs(worldobjects) do
        local md = obj.getModData and obj:getModData()
        if md and md.OA_StakeNo then return obj, md.OA_StakeNo, md.OA_StakeDate end
    end
    return nil
end

local function onFillWorld(playerNum, context, worldobjects, test)
    if test then return true end
    local player = getSpecificPlayer(playerNum)
    if player:getVehicle() then return end
    local m = activeMission(player)

    local obj, stake, date = stakeObject(worldobjects)
    if obj then
        context:addOption(getText("ContextMenu_OA_Story_ReadStake"), worldobjects, function()
            local square = obj:getSquare()
            if square and luautils.walkAdj(player, square, true) then
                ISTimedActionQueue.add(ISOAStoryAction:new(player, "stake", { stake = stake, date = date }, 40))
            end
        end)
    end

    if m and m.soil and m.state == "open" and not m.soil.taken then
        local square
        for _, o in ipairs(worldobjects) do
            if o.getSquare then square = o:getSquare(); break end
        end
        if square and square:isOutside() and square:getFloor() then
            local near = true
            if m.soil.variant == "site" then
                near = Places.distance(player:getX(), player:getY(), m.soil.x, m.soil.y) <= SOIL_NEAR
            end
            local option = context:addOption(getText("ContextMenu_OA_Story_TakeSoil"), worldobjects, function()
                if luautils.walkAdj(player, square, true) then
                    ISTimedActionQueue.add(ISOAStoryAction:new(player, "soil", {}, 200))
                end
            end)
            if not near then
                option.notAvailable = true
                local tip = ISWorldObjectContextMenu.addToolTip()
                tip.description = getText("Tooltip_OA_Story_SoilFar")
                option.toolTip = tip
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- What the server says about the story's own tries (a device with no signal, a case too far from its place).

local function onNotice(playerId, detail)
    if not (detail and type(detail.key) == "string" and string.find(detail.key, "^IGUI_OA_Story_") ~= nil) then return end
    local player = getPlayer()
    if not player or OA.Store.idOf(player) ~= playerId then return end
    local args = detail.args or {}
    local text = getText(detail.key, args[1], args[2], args[3])
    if HaloTextHelper and HaloTextHelper.addText then
        HaloTextHelper.addText(player, text)
    else
        player:Say(text)
    end
end

OA.Sync.listen("notice", onNotice)
Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)
Events.OnFillWorldObjectContextMenu.Add(onFillWorld)

return Menus
