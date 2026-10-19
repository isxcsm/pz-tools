-- The story's context menus: reading an item's paper, the field call device, leaving the sealed case at a drop, a
-- soil sample from the ground, and a survey stake. Each only offers what the character's mission asks for; the
-- server judges the rest. Each goes on top of the game's menu, in the order named here.
require "ISUI/ISInventoryPane"
require "ISUI/ISWorldObjectContextMenu"
require "TimedActions/ISTimedActionQueue"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Titles"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/View"
require "OperationAcorn/Story/Viewer"
require "OperationAcorn/Story/Action"
require "OperationAcorn/Trade/UI"
require "PZUIKit/Confirm"
local OA = OperationAcorn
local Data, Places, Docs = OA.StoryData, OA.Places, OA.StoryDocs
local Menus = {}

-- Asks before a command that uses up an item (the field call device and the mission item, the sample case).
local function ask(player, key, command)
    local text = string.gsub(getText(key), "\\n", "\n")
    OA.Trade.UI.confirm(player, text, player, function(p) OA.Sync.send(p, command, {}) end)
end
OA.StoryMenus = Menus

local function activeMission(player)
    local record = OA.Client.record(player)
    return record and record.missions and record.missions.active or nil, record
end

-- Is there a mission running (the main one, or the special request) that `test` says yes to.
local function anyMission(record, test)
    for _, m in ipairs(OA.StoryView.live(record)) do
        if test(m) then return true end
    end
    return false
end

local function wantsDevice(m) return m.field ~= nil and m.state == "open" end
local function wantsCase(m) return m.swap ~= nil and m.swap.stage == "needcase" and m.state == "open" end

-- ---------------------------------------------------------------------------------------------------------------
-- Inventory.

-- Puts the options of a list on top of a menu, so that the first of the list is the first of the menu: added from the
-- last (each one pushes the others down). A list holds { name, target, fn } tables.
local function onTop(context, list)
    for i = #list, 1, -1 do
        local o = list[i]
        context:addOptionOnTop(o.name, o.target, o.fn)
    end
end

local function onFillInventory(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    local _, record = activeMission(player)
    local read, field, swap = false, false, false
    local options = {}
    for _, item in ipairs(OA.menuItems(items)) do
        local name = Data.itemName(item:getFullType())
        if name then
            local md = item:getModData()
            if not read then
                local docs = Docs.forItem(record, name, md)
                if #docs > 0 then
                    read = true
                    options[#options + 1] = { name = getText("ContextMenu_OA_Story_Read"), target = player,
                        fn = function(p) OA.StoryViewer.open(p, docs) end }
                end
            end
            if name == "FieldCallDevice" and not field and anyMission(record, wantsDevice) then
                field = true
                options[#options + 1] = { name = getText("ContextMenu_OA_Story_FieldCall"), target = player,
                    fn = function(p) ask(p, "IGUI_OA_Story_FieldCallAsk", "story_field") end }
            end
            if name == "SampleCase" and not swap and anyMission(record, wantsCase) then
                swap = true
                options[#options + 1] = { name = getText("ContextMenu_OA_Story_LeaveCase"), target = player,
                    fn = function(p) ask(p, "IGUI_OA_Story_LeaveCaseAsk", "story_swap") end }
            end
        end
    end
    onTop(context, options)
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

-- Whether soil can be taken on a square: outdoors, its floor natural ground (grass, dirt, sand: the API's `natural`, as
-- the game's own digging asks it): not a road, a pavement or a floor someone laid.
local BARE = { outside = true, natural = true }
local function bareGround(square)
    return OA.api().squares.test(square, BARE)
end

local function onFillWorld(playerNum, context, worldobjects, test)
    if test then return true end
    local player = getSpecificPlayer(playerNum)
    if player:getVehicle() then return end
    local m = activeMission(player)

    -- the stake is the first of the two options and the soil sample the second, so the stake is added last
    local obj, stake, date = stakeObject(worldobjects)

    if m and m.soil and m.state == "open" and not m.soil.taken then
        local square
        for _, o in ipairs(worldobjects) do
            if o.getSquare then square = o:getSquare(); break end
        end
        if square and bareGround(square) then
            local near = true
            if m.soil.variant == "site" then
                near = Places.distance(player:getX(), player:getY(), m.soil.x, m.soil.y) <= Data.SOIL_RANGE
            end
            local option = context:addOptionOnTop(getText("ContextMenu_OA_Story_TakeSoil"), worldobjects, function()
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

    if obj then
        context:addOptionOnTop(getText("ContextMenu_OA_Story_ReadStake"), worldobjects, function()
            local square = obj:getSquare()
            if square and luautils.walkAdj(player, square, true) then
                ISTimedActionQueue.add(ISOAStoryAction:new(player, "stake", { stake = stake, date = date }, 40))
            end
        end)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- What the server says about the story's own tries (a device with no signal, a case too far from its place).

-- The notices of the terminal's own buttons (a brief title's tone: red for a refusal).
local TERMINAL = { IGUI_OA_Story_RerollFail = "red", IGUI_OA_Story_SpecialFail = "red", IGUI_OA_Story_LaunchFail = "amber" }

local function onNotice(playerId, detail)
    if not (detail and type(detail.key) == "string" and string.find(detail.key, "^IGUI_OA_Story_") ~= nil) then return end
    local player = getPlayer()
    if not player or OA.Store.idOf(player) ~= playerId then return end
    local args = detail.args or {}
    if detail.key == "IGUI_OA_Story_UI_Field_calling" then
        -- the team's word on the field caller: a radio title
        OA.Titles.notice(playerId, { key = "IGUI_OA_Title_FieldCalling", style = "notice" }, detail.key, args)
        return
    end
    if detail.key == "IGUI_OA_Story_Notice_BranchCall" then
        -- word on the terminal: a radio title
        OA.Titles.notice(playerId, { alone = true, style = "notice" }, detail.key, args)
    elseif TERMINAL[detail.key] then
        -- what the terminal could not do: a brief title, over its window
        OA.Titles.brief(playerId, detail.key, args, TERMINAL[detail.key])
    elseif detail.key == "IGUI_OA_Story_Harvested" then
        OA.Titles.brief(playerId, detail.key, args)
    else
        -- the character's own tries (a field call, a sample, a case): said, as the texts are written
        OA.Titles.say(playerId, detail.key, args)
    end
end

OA.Sync.listen("notice", onNotice)
OA.on("OnFillInventoryObjectContextMenu", onFillInventory)
OA.on("OnFillWorldObjectContextMenu", onFillWorld)

return Menus
